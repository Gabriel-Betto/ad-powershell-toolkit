#Requires -Version 5.1
<#
.SYNOPSIS
    Executa o desligamento (offboarding) de contas de usuário no Active Directory.

.DESCRIPTION
    Para cada login informado, na ordem:
      1. Desabilita a conta;
      2. (opcional, -ResetPassword) redefine a senha para um valor aleatório;
      3. Registra na descrição a data do desligamento e o chamado;
      4. (opcional, -RemoveGroups) remove a conta de todos os grupos,
         registrando no log a lista de grupos para eventual reversão;
      5. (opcional, -DisabledOU) move a conta para a OU de desligados.

    Cada etapa passa por ShouldProcess: use -WhatIf para simular.
    Como as ações são de alto impacto, o script pede confirmação por padrão
    (ConfirmImpact High); use -Confirm:$false em execuções automatizadas.

.PARAMETER Identity
    Um ou mais logins (sAMAccountName).

.PARAMETER CsvPath
    CSV com a coluna Login, alternativa a -Identity.

.PARAMETER DisabledOU
    Distinguished Name da OU de destino das contas desligadas.

.PARAMETER RemoveGroups
    Remove a conta de todos os grupos (exceto o grupo primário).

.PARAMETER ResetPassword
    Redefine a senha para um valor aleatório que não é exibido nem gravado.

.PARAMETER Ticket
    Número do chamado/requisição, gravado na descrição da conta (ex.: CHG-0001).

.PARAMETER Server
    Controlador de domínio a ser usado (opcional).

.PARAMETER Delimiter
    Separador do CSV: ';' (padrão), ',' ou tabulação.

.PARAMETER LogPath
    Arquivo de log. Padrão: logs/Invoke-ADOffboarding_aaaaMMdd.log na raiz do projeto.

.EXAMPLE
    .\Invoke-ADOffboarding.ps1 -Identity ana.exemplo -RemoveGroups -ResetPassword -Ticket CHG-0001 -WhatIf

.EXAMPLE
    .\Invoke-ADOffboarding.ps1 -CsvPath .\desligamentos.csv -DisabledOU 'OU=Desligados,DC=corp,DC=example,DC=com' -Confirm:$false

.OUTPUTS
    PSCustomObject com Login, Status (Concluido, Simulado, NaoEncontrado, Erro) e Mensagem.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Identity')]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory, ParameterSetName = 'Identity')]
    [ValidateNotNullOrEmpty()]
    [string[]]$Identity,

    [Parameter(Mandatory, ParameterSetName = 'Csv')]
    [ValidateScript({
            if (-not (Test-Path -LiteralPath $_ -PathType Leaf)) { throw "Arquivo não encontrado: $_" }
            if ([System.IO.Path]::GetExtension($_) -ne '.csv') { throw "O arquivo deve ter extensão .csv: $_" }
            $true
        })]
    [string]$CsvPath,

    [ValidateNotNullOrEmpty()]
    [string]$DisabledOU,

    [switch]$RemoveGroups,

    [switch]$ResetPassword,

    [ValidatePattern('^[A-Za-z0-9-]{1,32}$')]
    [string]$Ticket,

    [ValidateNotNullOrEmpty()]
    [string]$Server,

    [Parameter(ParameterSetName = 'Csv')]
    [ValidateSet(';', ',', "`t")]
    [string]$Delimiter = ';',

    [ValidateNotNullOrEmpty()]
    [string]$LogPath = (Join-Path -Path (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'logs') -ChildPath "Invoke-ADOffboarding_$(Get-Date -Format 'yyyyMMdd').log")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$libPath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'lib'
. (Join-Path -Path $libPath -ChildPath 'Write-Log.ps1')
. (Join-Path -Path $libPath -ChildPath 'Validation.ps1')

function New-Result {
    param([string]$Login, [string]$Status, [string]$Message)
    [pscustomobject]@{ Login = $Login; Status = $Status; Mensagem = $Message }
}

try {
    Write-Log -Path $LogPath -Message "Início. Modo: $($PSCmdlet.ParameterSetName). WhatIf: $([bool]$WhatIfPreference). RemoveGroups: $RemoveGroups. ResetPassword: $ResetPassword. DisabledOU: '$DisabledOU'."

    # 1. Monta e valida a lista de logins
    if ($PSCmdlet.ParameterSetName -eq 'Csv') {
        $header = @((Get-Content -LiteralPath $CsvPath -TotalCount 1 -Encoding UTF8).TrimStart([char]0xFEFF).Split($Delimiter) | ForEach-Object { $_.Trim().Trim('"') })
        $missing = @(Get-MissingCsvColumn -Header $header -RequiredColumn 'Login')
        if ($missing.Count -gt 0) {
            Write-Log -Path $LogPath -Level ERROR -Message "O CSV '$CsvPath' não tem a coluna obrigatória 'Login'."
            exit 1
        }
        $logins = @(Import-Csv -LiteralPath $CsvPath -Delimiter $Delimiter -Encoding UTF8 | ForEach-Object { Get-CsvValue -Row $_ -Column 'Login' })
    }
    else {
        $logins = @($Identity | ForEach-Object { "$_".Trim() })
    }

    $logins = @($logins | Where-Object { $_ } | Sort-Object -Unique)
    if ($logins.Count -eq 0) {
        Write-Log -Path $LogPath -Level ERROR -Message 'Nenhum login informado.'
        exit 1
    }

    $invalid = @($logins | Where-Object { -not (Test-SamAccountName -Login $_) })
    if ($invalid.Count -gt 0) {
        Write-Log -Path $LogPath -Level ERROR -Message "Login(s) inválido(s): $($invalid -join ', '). Nenhuma conta foi alterada."
        exit 1
    }

    if ($DisabledOU -and -not (Test-DistinguishedName -DistinguishedName $DisabledOU)) {
        Write-Log -Path $LogPath -Level ERROR -Message "DisabledOU '$DisabledOU' não é um Distinguished Name válido."
        exit 1
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

    if ($DisabledOU) {
        try {
            $null = Get-ADOrganizationalUnit @adParams -Identity $DisabledOU -ErrorAction Stop
        }
        catch {
            Write-Log -Path $LogPath -Level ERROR -Message "OU de desligados '$DisabledOU' não encontrada: $($_.Exception.Message)"
            exit 1
        }
    }

    $today = Get-Date -Format 'yyyy-MM-dd'
    $description = if ($Ticket) { "Desligado em $today (chamado $Ticket)" } else { "Desligado em $today" }

    # 3. Desligamento conta a conta
    $results = foreach ($login in $logins) {
        $step = 'busca'
        try {
            # Login já validado por Test-SamAccountName: não contém aspas, então o filtro é seguro.
            $user = Get-ADUser @adParams -Filter "SamAccountName -eq '$login'" -Properties MemberOf, Description -ErrorAction Stop
            if (-not $user) {
                Write-Log -Path $LogPath -Level WARN -Message "Usuário '$login' não encontrado no AD."
                New-Result -Login $login -Status 'NaoEncontrado' -Message 'Login não encontrado no AD'
                continue
            }

            $id = $user.ObjectGUID
            $done = [System.Collections.Generic.List[string]]::new()

            $step = 'desabilitar'
            if (-not $user.Enabled) {
                Write-Log -Path $LogPath -Message "'$login' já estava desabilitado."
            }
            elseif ($PSCmdlet.ShouldProcess($login, 'Desabilitar conta')) {
                Disable-ADAccount @adParams -Identity $id -Confirm:$false -ErrorAction Stop
                Write-Log -Path $LogPath -Message "'$login' desabilitado."
                $done.Add('desabilitada')
            }

            $step = 'redefinir senha'
            if ($ResetPassword -and $PSCmdlet.ShouldProcess($login, 'Redefinir senha para valor aleatório')) {
                $randomPassword = Get-RandomPassword
                Set-ADAccountPassword @adParams -Identity $id -Reset -NewPassword $randomPassword -Confirm:$false -ErrorAction Stop
                $randomPassword.Dispose()
                Write-Log -Path $LogPath -Message "Senha de '$login' redefinida para um valor aleatório (não registrado)."
                $done.Add('senha redefinida')
            }

            $step = 'descrição'
            if ($PSCmdlet.ShouldProcess($login, "Alterar descrição para '$description'")) {
                Set-ADUser @adParams -Identity $id -Description $description -Confirm:$false -ErrorAction Stop
                Write-Log -Path $LogPath -Message "Descrição de '$login' alterada (anterior: '$($user.Description)')."
                $done.Add('descrição')
            }

            $step = 'remover grupos'
            if ($RemoveGroups) {
                $groups = @($user.MemberOf | Where-Object { $_ })
                if ($groups.Count -eq 0) {
                    Write-Log -Path $LogPath -Message "'$login' não é membro de grupos (além do primário)."
                }
                else {
                    # Registro para reversão manual, se necessário.
                    Write-Log -Path $LogPath -Message "Grupos atuais de '$login': $($groups -join ' | ')"
                    $removed = 0
                    foreach ($group in $groups) {
                        if ($PSCmdlet.ShouldProcess($login, "Remover do grupo '$group'")) {
                            Remove-ADGroupMember @adParams -Identity $group -Members $id -Confirm:$false -ErrorAction Stop
                            Write-Log -Path $LogPath -Message "'$login' removido de '$group'."
                            $removed++
                        }
                    }
                    if ($removed -gt 0) { $done.Add("removida de $removed grupo(s)") }
                }
            }

            $step = 'mover'
            if ($DisabledOU -and $PSCmdlet.ShouldProcess($login, "Mover para '$DisabledOU'")) {
                Move-ADObject @adParams -Identity $id -TargetPath $DisabledOU -Confirm:$false -ErrorAction Stop
                Write-Log -Path $LogPath -Message "'$login' movido para '$DisabledOU'."
                $done.Add('movida')
            }

            if ($done.Count -gt 0) {
                New-Result -Login $login -Status 'Concluido' -Message ($done -join ', ')
            }
            else {
                Write-Log -Path $LogPath -Message "[Simulação] Nenhuma alteração aplicada em '$login'."
                New-Result -Login $login -Status 'Simulado' -Message 'Nenhuma alteração aplicada'
            }
        }
        catch {
            Write-Log -Path $LogPath -Level ERROR -Message "Falha no desligamento de '$login' (etapa: $step): $($_.Exception.Message)"
            New-Result -Login $login -Status 'Erro' -Message "Etapa '$step': $($_.Exception.Message)"
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
