<#
.SYNOPSIS
    Gera um relatório (CSV) de contas de usuário ativas que não fazem logon há X dias.

.DESCRIPTION
    Lista as contas habilitadas cujo último logon é mais antigo que o limite informado.
    Contas que nunca fizeram logon entram no relatório se foram criadas antes do limite.
    O script só LÊ o AD: não altera nem desativa nada. Use o relatório para decidir o que fazer
    (por exemplo, abrir chamado de desligamento com Invoke-ADOffboarding.ps1).

    Observação: o campo LastLogonDate vem do atributo lastLogonTimestamp, que é replicado
    entre controladores de domínio com atraso de até ~14 dias. Por isso, use limites de 30 dias
    ou mais e trate o resultado como uma lista para revisão, não como verdade absoluta.

.PARAMETER DaysInactive
    Quantidade de dias sem logon. Padrão: 90.

.PARAMETER SearchBase
    (Opcional) OU onde buscar. Se omitido, busca no domínio inteiro.

.PARAMETER OutputPath
    Caminho do CSV de saída. Padrão: reports\contas_inativas_AAAA-MM-DD.csv

.EXAMPLE
    .\Get-InactiveADAccounts.ps1 -DaysInactive 90

.EXAMPLE
    .\Get-InactiveADAccounts.ps1 -DaysInactive 60 -SearchBase "OU=Usuarios,DC=empresa,DC=local"
#>

#Requires -Version 5.1
#Requires -Modules ActiveDirectory

[CmdletBinding()]
param(
    [ValidateRange(1, 3650)]
    [int]$DaysInactive = 90,

    [string]$SearchBase,

    [string]$OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath ("..\reports\contas_inativas_{0}.csv" -f (Get-Date -Format 'yyyy-MM-dd')))
)

$limit = (Get-Date).AddDays(-$DaysInactive)

$getParams = @{
    Filter      = 'Enabled -eq $true'
    Properties  = @('LastLogonDate', 'Department', 'Title', 'Description', 'whenCreated')
    ErrorAction = 'Stop'
}
if ($SearchBase) {
    $getParams['SearchBase'] = $SearchBase
}

try {
    $accounts = Get-ADUser @getParams
}
catch {
    Write-Error "Falha ao consultar o Active Directory: $($_.Exception.Message)"
    return
}

$inactive = $accounts | Where-Object {
    ($_.LastLogonDate -and $_.LastLogonDate -lt $limit) -or
    (-not $_.LastLogonDate -and $_.whenCreated -lt $limit)
} | Select-Object `
    @{ Name = 'Login';         Expression = { $_.SamAccountName } },
    @{ Name = 'Nome';          Expression = { $_.Name } },
    @{ Name = 'Departamento';  Expression = { $_.Department } },
    @{ Name = 'Cargo';         Expression = { $_.Title } },
    @{ Name = 'UltimoLogon';   Expression = { if ($_.LastLogonDate) { $_.LastLogonDate.ToString('yyyy-MM-dd') } else { 'Nunca' } } },
    @{ Name = 'DiasSemLogon';  Expression = {
            $reference = if ($_.LastLogonDate) { $_.LastLogonDate } else { $_.whenCreated }
            [int]((Get-Date) - $reference).TotalDays
        } },
    @{ Name = 'CriadoEm';      Expression = { $_.whenCreated.ToString('yyyy-MM-dd') } },
    @{ Name = 'Descricao';     Expression = { $_.Description } } |
    Sort-Object -Property DiasSemLogon -Descending

# Garante que a pasta de saída exista
$outFolder = Split-Path -Path $OutputPath -Parent
if ($outFolder -and -not (Test-Path -Path $outFolder)) {
    New-Item -ItemType Directory -Path $outFolder -Force | Out-Null
}

if ($inactive) {
    $inactive | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Host "Encontradas $(@($inactive).Count) conta(s) sem logon há mais de $DaysInactive dias." -ForegroundColor Yellow
    Write-Host "Relatório salvo em: $OutputPath"
}
else {
    Write-Host "Nenhuma conta ativa está sem logon há mais de $DaysInactive dias." -ForegroundColor Green
}
