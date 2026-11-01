<#
.SYNOPSIS
    Testes automatizados dos scripts do toolkit, sem precisar de um Active Directory.

.DESCRIPTION
    Carrega um módulo "ActiveDirectory" FALSO (tests\FakeActiveDirectory), que guarda tudo em
    memória, e executa os três scripts em vários cenários: simulação (-WhatIf), execução real,
    entradas inválidas e erros esperados. Mostra [PASSOU]/[FALHOU] por verificação e termina
    com código 1 se algo falhar.

    Pode rodar em Windows, Linux ou macOS com PowerShell 5.1 ou 7. Os logs e relatórios dos
    testes vão para uma pasta temporária e são apagados no final.

.EXAMPLE
    .\tests\Run-Tests.ps1
#>

#Requires -Version 5.1

$root = Split-Path -Path $PSScriptRoot -Parent
$tmp  = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ("adtk-tests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

# Garante que só o módulo falso esteja carregado (nunca o AD real)
Remove-Module ActiveDirectory -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $PSScriptRoot 'FakeActiveDirectory\ActiveDirectory.psd1') -Force

$script:pass = 0
$script:fail = 0
function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { $script:pass++; Write-Host "[PASSOU] $Name" -ForegroundColor Green }
    else            { $script:fail++; Write-Host "[FALHOU] $Name" -ForegroundColor Red }
}
function Get-Throws { param([scriptblock]$Code) try { & $Code *> $null; $false } catch { $true } }

$ouUsers    = 'OU=Usuarios,DC=empresa,DC=local'
$ouDisabled = 'OU=Desativados,DC=empresa,DC=local'
$csv        = Join-Path $root 'data\usuarios_exemplo.csv'
$senha      = ConvertTo-SecureString 'Troca@123' -AsPlainText -Force
$scripts    = Join-Path $root 'scripts'

try {
    # ---------- New-BulkADUsers ----------
    Write-Host "`n== New-BulkADUsers ==" -ForegroundColor Cyan
    Initialize-FakeAD
    $log = Join-Path $tmp 'criacao.log'
    & "$scripts\New-BulkADUsers.ps1" -CsvPath $csv -OUPath $ouUsers -UpnSuffix empresa.local -InitialPassword $senha -LogPath $log -WhatIf *> $null
    Assert-True (@(Get-FakeCalls | Where-Object { $_ -like 'New-ADUser*' }).Count -eq 0) 'Simulação (-WhatIf) não cria usuários'
    $logTxt = Get-Content $log -Raw
    Assert-True ($logTxt -match 'SIMULAÇÃO') 'Simulação grava o log com a marca [SIMULAÇÃO]'
    Assert-True ($logTxt -match 'Não executados \(simulação\): 4') 'Resumo da simulação informa 4 não executados'

    Initialize-FakeAD
    $log = Join-Path $tmp 'criacao2.log'
    & "$scripts\New-BulkADUsers.ps1" -CsvPath $csv -OUPath $ouUsers -UpnSuffix empresa.local -InitialPassword $senha -LogPath $log *> $null
    $novos = @(Get-FakeCalls | Where-Object { $_ -like 'New-ADUser*' })
    Assert-True ($novos.Count -eq 4) 'Execução real cria os 4 usuários do CSV'
    Assert-True (@($novos | Where-Object { $_ -notmatch 'chg=True' }).Count -eq 0) 'Todos exigem troca de senha no primeiro logon'
    Assert-True (@($novos | Where-Object { $_ -notmatch 'pwdType=SecureString' }).Count -eq 0) 'Senha é passada como SecureString'
    Assert-True ((Get-FakeUser 'ana.souza').MemberOf.Count -eq 2) 'ana.souza entrou nos 2 grupos do CSV'
    Assert-True ((Get-Content $log -Raw) -notmatch 'Troca@123') 'A senha não aparece no log'

    & "$scripts\New-BulkADUsers.ps1" -CsvPath $csv -OUPath $ouUsers -UpnSuffix empresa.local -InitialPassword $senha -LogPath $log *> $null
    Assert-True (@(Get-FakeCalls | Where-Object { $_ -like 'New-ADUser*' }).Count -eq 4) 'Rodar de novo não recria nem sobrescreve usuários'

    $ruim = Join-Path $tmp 'ruim.csv'
    "Nome,Sobrenome,Login,Departamento,Cargo,Grupos`nA,B,a',X,Y,GRP_TI`nC,D,x y z!,X,Y,GRP_TI" | Set-Content $ruim -Encoding UTF8
    Initialize-FakeAD
    & "$scripts\New-BulkADUsers.ps1" -CsvPath $ruim -OUPath $ouUsers -UpnSuffix empresa.local -InitialPassword $senha -LogPath (Join-Path $tmp 'ruim.log') *> $null
    Assert-True (@(Get-FakeCalls | Where-Object { $_ -like 'New-ADUser*' }).Count -eq 0) 'Logins inválidos (aspas, espaço, símbolo) são rejeitados'

    $falta = Join-Path $tmp 'falta.csv'
    "Nome,Sobrenome,Login`nA,B,a.b" | Set-Content $falta -Encoding UTF8
    $logFalta = Join-Path $tmp 'falta.log'
    & "$scripts\New-BulkADUsers.ps1" -CsvPath $falta -OUPath $ouUsers -UpnSuffix empresa.local -InitialPassword $senha -LogPath $logFalta *> $null
    Assert-True ((Get-Content $logFalta -Raw) -match 'Colunas ausentes') 'CSV sem colunas obrigatórias é recusado com mensagem clara'

    Assert-True (Get-Throws { & "$scripts\New-BulkADUsers.ps1" -CsvPath $csv -OUPath 'OU=Nada,DC=x' -UpnSuffix a.b -InitialPassword $senha -LogPath (Join-Path $tmp 'ou.log') }) 'OU de destino inexistente interrompe o script'

    # ---------- Invoke-ADOffboarding ----------
    Write-Host "`n== Invoke-ADOffboarding ==" -ForegroundColor Cyan
    Initialize-FakeAD
    $logOff = Join-Path $tmp 'off.log'
    & "$scripts\Invoke-ADOffboarding.ps1" -Login joao.silva -DisabledOU $ouDisabled -Reason 'Chamado 1' -LogPath $logOff -WhatIf *> $null
    $u = Get-FakeUser 'joao.silva'
    Assert-True ($u.Enabled -and $u.MemberOf.Count -eq 2 -and $u.DistinguishedName -like '*OU=Usuarios*') 'Simulação não altera o usuário'
    Assert-True ((Get-Content $logOff -Raw) -match 'Simulação concluída') 'Simulação não diz que desligou de verdade'

    & "$scripts\Invoke-ADOffboarding.ps1" -Login joao.silva -DisabledOU $ouDisabled -Reason 'Chamado 1' -LogPath $logOff *> $null
    $u = Get-FakeUser 'joao.silva'
    Assert-True (-not $u.Enabled) 'Desligamento real desativa a conta'
    Assert-True ($u.MemberOf.Count -eq 0) 'Desligamento remove de todos os grupos'
    Assert-True ($u.Description -match 'Chamado 1') 'Descrição recebe a data e o motivo'
    Assert-True ($u.DistinguishedName -like "*$ouDisabled") 'Conta é movida para a OU de desativados'
    Assert-True ((Get-Content $logOff -Raw) -match 'Grupos atuais de joao.silva') 'Grupos originais ficam registrados no log (para reverter)'

    Assert-True (Get-Throws { & "$scripts\Invoke-ADOffboarding.ps1" -Login fantasma -DisabledOU $ouDisabled -LogPath $logOff }) 'Usuário inexistente interrompe o script'
    Assert-True (Get-Throws { & "$scripts\Invoke-ADOffboarding.ps1" -Login 'a b!' -DisabledOU $ouDisabled -LogPath $logOff }) 'Login com caracteres inválidos é recusado'
    Assert-True (Get-Throws { & "$scripts\Invoke-ADOffboarding.ps1" -Login maria.velha -DisabledOU 'OU=Nada,DC=x' -LogPath $logOff }) 'OU de desativados inexistente interrompe o script'

    # ---------- Get-InactiveADAccounts ----------
    Write-Host "`n== Get-InactiveADAccounts ==" -ForegroundColor Cyan
    Initialize-FakeAD
    $rel = Join-Path $tmp 'inativas.csv'
    & "$scripts\Get-InactiveADAccounts.ps1" -DaysInactive 90 -OutputPath $rel *> $null
    $linhas = @(Import-Csv $rel)
    $logins = $linhas.Login
    Assert-True ($logins -contains 'maria.velha') 'Lista quem está há 200 dias sem logon'
    Assert-True ($logins -contains 'nunca.logou') 'Lista quem nunca fez logon e foi criado há mais de 90 dias'
    Assert-True ($logins -notcontains 'joao.silva') 'Não lista quem logou há 5 dias'
    Assert-True ($logins -notcontains 'recente.novo') 'Não lista conta nova (10 dias) que ainda não logou'
    Assert-True ($logins -notcontains 'ja.desativ') 'Não lista contas que já estão desativadas'
    Assert-True ([int]$linhas[0].DiasSemLogon -ge [int]$linhas[-1].DiasSemLogon) 'Relatório vem ordenado do mais antigo para o mais recente'
    Assert-True (Get-Throws { & "$scripts\Get-InactiveADAccounts.ps1" -DaysInactive 0 -OutputPath $rel }) 'DaysInactive fora do limite é recusado'
}
finally {
    Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Module ActiveDirectory -Force -ErrorAction SilentlyContinue
}

Write-Host ("`nResultado: {0} passaram, {1} falharam" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
if ($script:fail -gt 0) { exit 1 }
