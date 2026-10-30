#Requires -Version 5.1
<#
.SYNOPSIS
    Lista contas de usuário do Active Directory sem logon há N dias.

.DESCRIPTION
    Script somente leitura: não altera o AD.

    Usa o atributo LastLogonTimestamp (exposto como LastLogonDate), que é
    replicado entre os controladores de domínio, mas pode ter atraso de até
    ~14 dias. Por isso, use valores de -DaysInactive bem acima de 14.

    Contas que nunca fizeram logon só entram no relatório se foram criadas
    antes da data de corte (para não listar contas recém-criadas).

.PARAMETER DaysInactive
    Dias sem logon para considerar a conta inativa (1 a 3650). Padrão: 90.

.PARAMETER SearchBase
    Distinguished Name da OU onde buscar (opcional; padrão: domínio inteiro).

.PARAMETER IncludeDisabled
    Inclui contas já desabilitadas.

.PARAMETER ExportPath
    Caminho de um arquivo .csv para exportar o relatório (opcional).

.PARAMETER Server
    Controlador de domínio a ser usado (opcional).

.PARAMETER LogPath
    Arquivo de log. Padrão: logs/Get-InactiveADAccounts_aaaaMMdd.log na raiz do projeto.

.EXAMPLE
    .\Get-InactiveADAccounts.ps1 -DaysInactive 120 -SearchBase 'OU=Usuarios,DC=corp,DC=example,DC=com'

.EXAMPLE
    .\Get-InactiveADAccounts.ps1 -ExportPath ..\reports\inativos.csv

.OUTPUTS
    PSCustomObject com SamAccountName, Name, Enabled, LastLogonDate, DaysSinceLastLogon,
    NeverLoggedOn, WhenCreated, Department e DistinguishedName.
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [ValidateRange(1, 3650)]
    [int]$DaysInactive = 90,

    [ValidateNotNullOrEmpty()]
    [string]$SearchBase,

    [switch]$IncludeDisabled,

    [ValidateNotNullOrEmpty()]
    [string]$ExportPath,

    [ValidateNotNullOrEmpty()]
    [string]$Server,

    [ValidateNotNullOrEmpty()]
    [string]$LogPath = (Join-Path -Path (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'logs') -ChildPath "Get-InactiveADAccounts_$(Get-Date -Format 'yyyyMMdd').log")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$libPath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'lib'
. (Join-Path -Path $libPath -ChildPath 'Write-Log.ps1')
. (Join-Path -Path $libPath -ChildPath 'Validation.ps1')

try {
    Write-Log -Path $LogPath -Message "Início. DaysInactive: $DaysInactive. SearchBase: '$SearchBase'. IncludeDisabled: $IncludeDisabled."

    # 1. Validação dos parâmetros
    if ($SearchBase -and -not (Test-DistinguishedName -DistinguishedName $SearchBase)) {
        Write-Log -Path $LogPath -Level ERROR -Message "SearchBase '$SearchBase' não é um Distinguished Name válido."
        exit 1
    }

    if ($ExportPath) {
        if ([System.IO.Path]::GetExtension($ExportPath) -ne '.csv') {
            Write-Log -Path $LogPath -Level ERROR -Message "ExportPath deve ter extensão .csv: '$ExportPath'."
            exit 1
        }
        $exportDir = Split-Path -Path $ExportPath -Parent
        if ($exportDir -and -not (Test-Path -LiteralPath $exportDir -PathType Container)) {
            Write-Log -Path $LogPath -Level ERROR -Message "Pasta de destino não existe: '$exportDir'."
            exit 1
        }
    }

    # 2. Módulo ActiveDirectory (RSAT)
    try {
        Import-Module -Name ActiveDirectory -ErrorAction Stop -Verbose:$false
    }
    catch {
        Write-Log -Path $LogPath -Level ERROR -Message "Não foi possível carregar o módulo ActiveDirectory (RSAT): $($_.Exception.Message)"
        exit 1
    }

    # 3. Consulta: o filtro por LastLogonTimestamp roda no controlador de domínio
    $now = Get-Date
    $cutoff = $now.AddDays(-$DaysInactive)
    $filter = "(LastLogonTimestamp -lt $($cutoff.ToFileTimeUtc()) -or LastLogonTimestamp -notlike '*')"
    if (-not $IncludeDisabled) {
        $filter = "Enabled -eq 'True' -and $filter"
    }

    $query = @{
        Filter     = $filter
        Properties = @('LastLogonDate', 'WhenCreated', 'Department')
    }
    if ($SearchBase) { $query.SearchBase = $SearchBase }
    if ($Server) { $query.Server = $Server }

    try {
        $users = @(Get-ADUser @query -ErrorAction Stop)
    }
    catch {
        Write-Log -Path $LogPath -Level ERROR -Message "Falha na consulta ao AD: $($_.Exception.Message)"
        exit 1
    }

    # 4. Monta o relatório (ignora contas que nunca logaram, mas foram criadas depois do corte)
    $report = @(
        foreach ($user in $users) {
            $neverLoggedOn = $null -eq $user.LastLogonDate
            if ($neverLoggedOn -and $user.WhenCreated -gt $cutoff) {
                continue
            }
            [pscustomobject]@{
                SamAccountName     = $user.SamAccountName
                Name               = $user.Name
                Enabled            = $user.Enabled
                LastLogonDate      = $user.LastLogonDate
                DaysSinceLastLogon = if ($neverLoggedOn) { $null } else { [int]($now - $user.LastLogonDate).TotalDays }
                NeverLoggedOn      = $neverLoggedOn
                WhenCreated        = $user.WhenCreated
                Department         = $user.Department
                DistinguishedName  = $user.DistinguishedName
            }
        }
    ) | Sort-Object -Property @{ Expression = 'NeverLoggedOn'; Descending = $true }, @{ Expression = 'DaysSinceLastLogon'; Descending = $true }

    Write-Log -Path $LogPath -Message "$(@($report).Count) conta(s) inativa(s) há mais de $DaysInactive dia(s)."

    if ($ExportPath) {
        $report | Export-Csv -LiteralPath $ExportPath -NoTypeInformation -Encoding UTF8 -Delimiter ';'
        Write-Log -Path $LogPath -Message "Relatório exportado para '$ExportPath'."
    }

    $report
}
catch {
    Write-Log -Path $LogPath -Level ERROR -Message "Erro inesperado: $($_.Exception.Message)"
    exit 1
}
