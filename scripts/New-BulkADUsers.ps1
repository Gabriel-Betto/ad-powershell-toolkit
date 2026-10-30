#Requires -Version 5.1
<#
.SYNOPSIS
    Cria usuários no Active Directory em lote a partir de um arquivo CSV.

.DESCRIPTION
    1. Valida o CSV inteiro (colunas, logins, duplicidade, e-mail e OU).
       Se houver qualquer erro, nada é criado (tudo ou nada na validação).
    2. Para cada linha, verifica se o login já existe no AD e, se não existir,
       cria a conta habilitada e com troca de senha obrigatória no primeiro logon.

    Suporta -WhatIf e -Confirm. A senha inicial é recebida como SecureString
    e nunca é gravada no log nem exibida.

    Colunas obrigatórias: Nome, Sobrenome, Login, OU
    Colunas opcionais:    Email, Departamento, Cargo

.PARAMETER CsvPath
    Caminho do CSV (UTF-8). Veja data/usuarios_exemplo.csv.

.PARAMETER UpnSuffix
    Sufixo do UserPrincipalName (ex.: corp.example.com). O UPN será Login@UpnSuffix.

.PARAMETER InitialPassword
    Senha inicial (SecureString) aplicada a todas as contas criadas.
    Se omitida, o PowerShell solicita de forma segura.

.PARAMETER Server
    Controlador de domínio a ser usado (opcional).

.PARAMETER ValidateOnly
    Apenas valida o CSV. Não precisa do módulo ActiveDirectory.

.PARAMETER Delimiter
    Separador do CSV: ';' (padrão), ',' ou tabulação.

.PARAMETER LogPath
    Arquivo de log. Padrão: logs/New-BulkADUsers_aaaaMMdd.log na raiz do projeto.

.EXAMPLE
    .\New-BulkADUsers.ps1 -CsvPath ..\data\usuarios_exemplo.csv -ValidateOnly

.EXAMPLE
    $senha = Read-Host -AsSecureString -Prompt 'Senha inicial'
    .\New-BulkADUsers.ps1 -CsvPath ..\data\usuarios_exemplo.csv -UpnSuffix corp.example.com -InitialPassword $senha -WhatIf

.OUTPUTS
    PSCustomObject com Login, Status (Criado, Simulado, Existente, Erro, Valido) e Mensagem.
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Create')]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)]
    [ValidateScript({
            if (-not (Test-Path -LiteralPath $_ -PathType Leaf)) { throw "Arquivo não encontrado: $_" }
            if ([System.IO.Path]::GetExtension($_) -ne '.csv') { throw "O arquivo deve ter extensão .csv: $_" }
            $true
        })]
    [string]$CsvPath,

    [Parameter(Mandatory, ParameterSetName = 'Create')]
    [ValidatePattern('^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$')]
    [string]$UpnSuffix,

    [Parameter(Mandatory, ParameterSetName = 'Create')]
    [System.Security.SecureString]$InitialPassword,

    [Parameter(ParameterSetName = 'Create')]
    [ValidateNotNullOrEmpty()]
    [string]$Server,

    [Parameter(Mandatory, ParameterSetName = 'ValidateOnly')]
    [switch]$ValidateOnly,

    [ValidateSet(';', ',', "`t")]
    [string]$Delimiter = ';',

    [ValidateNotNullOrEmpty()]
    [string]$LogPath = (Join-Path -Path (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'logs') -ChildPath "New-BulkADUsers_$(Get-Date -Format 'yyyyMMdd').log")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$libPath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'lib'
. (Join-Path -Path $libPath -ChildPath 'Write-Log.ps1')
. (Join-Path -Path $libPath -ChildPath 'Validation.ps1')

function ConvertTo-Result {
    [OutputType([pscustomobject])]
    param([string]$Login, [string]$Status, [string]$Message)
    [pscustomobject]@{ Login = $Login; Status = $Status; Mensagem = $Message }
}

try {
    Write-Log -Path $LogPath -Message "Início. CSV: '$CsvPath'. Modo: $($PSCmdlet.ParameterSetName). WhatIf: $([bool]$WhatIfPreference)."

    # 1. Validação completa do CSV antes de qualquer alteração no AD
    $csv = Import-UserCsv -Path $CsvPath -Delimiter $Delimiter
    if ($csv.Errors.Count -gt 0) {
        foreach ($validationError in $csv.Errors) {
            Write-Log -Path $LogPath -Level ERROR -Message "Validação do CSV: $validationError"
        }
        Write-Log -Path $LogPath -Level ERROR -Message "CSV reprovado com $($csv.Errors.Count) erro(s). Nenhuma conta foi criada."
        exit 1
    }
    Write-Log -Path $LogPath -Message "CSV válido: $($csv.Rows.Count) usuário(s)."

    if ($ValidateOnly) {
        $csv.Rows | ForEach-Object { ConvertTo-Result -Login $_.Login -Status 'Valido' -Message $_.OU }
        Write-Log -Path $LogPath -Message 'Modo -ValidateOnly: nenhuma alteração foi feita.'
        return
    }

    # 2. Módulo ActiveDirectory (RSAT)
    try {
        Import-Module -Name ActiveDirectory -ErrorAction Stop -Verbose:$false
    }
    catch {
        Write-Log -Path $LogPath -Level ERROR -Message "Não foi possível carregar o módulo ActiveDirectory (RSAT): $($_.Exception.Message)"
        exit 1
    }

    $adParams = @{}
    if ($Server) { $adParams.Server = $Server }

    # 3. Criação das contas
    $results = foreach ($user in $csv.Rows) {
        $login = $user.Login
        try {
            # Login já validado por Test-SamAccountName: não contém aspas, então o filtro é seguro.
            $existing = Get-ADUser @adParams -Filter "SamAccountName -eq '$login'" -ErrorAction Stop
            if ($existing) {
                Write-Log -Path $LogPath -Level WARN -Message "Usuário '$login' já existe no AD. Ignorado."
                ConvertTo-Result -Login $login -Status 'Existente' -Message 'Login já existe no AD'
            }
            else {
                $displayName = "$($user.Nome) $($user.Sobrenome)"
                $newUserParams = @{
                    Name                  = $displayName
                    GivenName             = $user.Nome
                    Surname               = $user.Sobrenome
                    DisplayName           = $displayName
                    SamAccountName        = $login
                    UserPrincipalName     = "$login@$UpnSuffix"
                    Path                  = $user.OU
                    AccountPassword       = $InitialPassword
                    Enabled               = $true
                    ChangePasswordAtLogon = $true
                }
                if ($user.Email) { $newUserParams.EmailAddress = $user.Email }
                if ($user.Departamento) { $newUserParams.Department = $user.Departamento }
                if ($user.Cargo) { $newUserParams.Title = $user.Cargo }

                if ($PSCmdlet.ShouldProcess("$login em '$($user.OU)'", 'Criar usuário no AD')) {
                    New-ADUser @adParams @newUserParams -ErrorAction Stop
                    Write-Log -Path $LogPath -Message "Usuário '$login' criado em '$($user.OU)'."
                    ConvertTo-Result -Login $login -Status 'Criado' -Message $user.OU
                }
                else {
                    Write-Log -Path $LogPath -Message "[Simulação] Usuário '$login' seria criado em '$($user.OU)'."
                    ConvertTo-Result -Login $login -Status 'Simulado' -Message $user.OU
                }
            }
        }
        catch {
            Write-Log -Path $LogPath -Level ERROR -Message "Falha ao processar '$login': $($_.Exception.Message)"
            ConvertTo-Result -Login $login -Status 'Erro' -Message $_.Exception.Message
        }
    }

    $summary = ($results | Group-Object -Property Status | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '
    Write-Log -Path $LogPath -Message "Fim. Resumo: $summary."
    $results
}
catch {
    Write-Log -Path $LogPath -Level ERROR -Message "Erro inesperado: $($_.Exception.Message)"
    exit 1
}
