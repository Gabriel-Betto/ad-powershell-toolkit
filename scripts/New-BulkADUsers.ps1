<#
.SYNOPSIS
    Cria usuários no Active Directory em lote a partir de um arquivo CSV.

.DESCRIPTION
    Lê um CSV (colunas: Nome, Sobrenome, Login, Departamento, Cargo, Grupos),
    valida cada linha e cria a conta no AD dentro da OU informada.
    - Se o login já existir, a linha é ignorada (nunca sobrescreve conta).
    - A conta é criada com uma senha inicial única e exige troca no primeiro logon.
    - Os grupos da coluna "Grupos" (separados por ponto e vírgula) são aplicados.
    - Suporta -WhatIf: mostra o que seria feito sem alterar nada.
    - Tudo é registrado em log. A senha NUNCA é escrita no log.

.PARAMETER CsvPath
    Caminho do arquivo CSV (veja data\usuarios_exemplo.csv).

.PARAMETER OUPath
    Distinguished Name da OU de destino. Ex.: "OU=Usuarios,DC=empresa,DC=local"

.PARAMETER UpnSuffix
    Sufixo do UserPrincipalName. Ex.: "empresa.local"

.PARAMETER InitialPassword
    Senha inicial (SecureString). Se não for informada, o script pergunta.

.PARAMETER LogPath
    Arquivo de log. Padrão: logs\criacao_usuarios.log

.EXAMPLE
    .\New-BulkADUsers.ps1 -CsvPath ..\data\usuarios_exemplo.csv `
        -OUPath "OU=Usuarios,DC=empresa,DC=local" -UpnSuffix "empresa.local" -WhatIf

.EXAMPLE
    .\New-BulkADUsers.ps1 -CsvPath ..\data\usuarios_exemplo.csv `
        -OUPath "OU=Usuarios,DC=empresa,DC=local" -UpnSuffix "empresa.local"
#>

#Requires -Version 5.1
#Requires -Modules ActiveDirectory

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
    [string]$CsvPath,

    [Parameter(Mandatory)]
    [string]$OUPath,

    [Parameter(Mandatory)]
    [string]$UpnSuffix,

    [SecureString]$InitialPassword,

    [string]$LogPath = (Join-Path -Path $PSScriptRoot -ChildPath '..\logs\criacao_usuarios.log')
)

. (Join-Path -Path $PSScriptRoot -ChildPath '..\lib\Write-Log.ps1')

$requiredColumns = @('Nome', 'Sobrenome', 'Login', 'Departamento', 'Cargo', 'Grupos')
# Só letras, números, ponto, hífen e underline, de 3 a 20 caracteres.
# Isso também evita que um valor estranho do CSV quebre o filtro do AD.
$loginPattern = '^[a-zA-Z0-9._-]{3,20}$'

# Senha inicial: pergunta se não foi passada como parâmetro
if (-not $InitialPassword) {
    $InitialPassword = Read-Host -Prompt 'Senha inicial dos novos usuários' -AsSecureString
}

# Confere se a OU de destino existe antes de começar
try {
    $null = Get-ADOrganizationalUnit -Identity $OUPath -ErrorAction Stop
}
catch {
    Write-Log -Message "OU de destino não encontrada: $OUPath" -Level ERROR -Path $LogPath
    throw
}

# Lê o CSV e confere as colunas
$users = Import-Csv -Path $CsvPath -Encoding UTF8
if (-not $users) {
    Write-Log -Message "O arquivo $CsvPath está vazio." -Level ERROR -Path $LogPath
    return
}

$missing = $requiredColumns | Where-Object { $_ -notin $users[0].PSObject.Properties.Name }
if ($missing) {
    Write-Log -Message "Colunas ausentes no CSV: $($missing -join ', ')" -Level ERROR -Path $LogPath
    return
}

Write-Log -Message "Início: $($users.Count) linha(s) em $CsvPath" -Path $LogPath

$created      = 0
$skipped      = 0
$failed       = 0
$notExecuted  = 0   # linhas válidas que só foram simuladas (-WhatIf) ou recusadas em -Confirm

foreach ($row in $users) {
    $login = $row.Login.Trim()

    # 1) Valida o login
    if ($login -notmatch $loginPattern) {
        Write-Log -Message "Login inválido ignorado: '$login'" -Level WARN -Path $LogPath
        $failed++
        continue
    }

    # 2) Não mexe em conta que já existe
    if (Get-ADUser -Filter "SamAccountName -eq '$login'" -ErrorAction SilentlyContinue) {
        Write-Log -Message "Usuário já existe, ignorado: $login" -Level WARN -Path $LogPath
        $skipped++
        continue
    }

    $displayName = "$($row.Nome.Trim()) $($row.Sobrenome.Trim())"

    $newUserParams = @{
        Name                  = $displayName
        GivenName             = $row.Nome.Trim()
        Surname               = $row.Sobrenome.Trim()
        DisplayName           = $displayName
        SamAccountName        = $login
        UserPrincipalName     = "$login@$UpnSuffix"
        Department            = $row.Departamento.Trim()
        Title                 = $row.Cargo.Trim()
        Path                  = $OUPath
        AccountPassword       = $InitialPassword
        ChangePasswordAtLogon = $true
        Enabled               = $true
        ErrorAction           = 'Stop'
    }

    # 3) Cria a conta (respeita -WhatIf)
    if ($PSCmdlet.ShouldProcess($login, 'Criar usuário no Active Directory')) {
        try {
            New-ADUser @newUserParams
            Write-Log -Message "Usuário criado: $login ($displayName)" -Level OK -Path $LogPath
            $created++
        }
        catch {
            Write-Log -Message "Falha ao criar $login : $($_.Exception.Message)" -Level ERROR -Path $LogPath
            $failed++
            continue
        }

        # 4) Adiciona aos grupos
        $groups = $row.Grupos -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        foreach ($group in $groups) {
            try {
                Add-ADGroupMember -Identity $group -Members $login -ErrorAction Stop
                Write-Log -Message "  $login adicionado ao grupo '$group'" -Path $LogPath
            }
            catch {
                Write-Log -Message "  Falha ao adicionar $login ao grupo '$group': $($_.Exception.Message)" -Level WARN -Path $LogPath
            }
        }
    }
    else {
        # Simulação (-WhatIf) ou usuário respondeu "não" ao -Confirm: nada foi criado
        $notExecuted++
    }
}

$summary = "Fim. Criados: $created | Ignorados: $skipped | Com erro: $failed"
if ($notExecuted -gt 0) {
    $summary += " | Não executados (simulação): $notExecuted"
}
Write-Log -Message $summary -Path $LogPath
