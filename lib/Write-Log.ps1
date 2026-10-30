<#
.SYNOPSIS
    Funções de log compartilhadas pelos scripts do ad-powershell-toolkit.

.DESCRIPTION
    Carregue com dot-sourcing:  . "$PSScriptRoot/../lib/Write-Log.ps1"

    Cada linha é gravada no formato "aaaa-MM-dd HH:mm:ss [NIVEL] mensagem".
    Antes de gravar, a mensagem passa por Protect-LogMessage, que mascara
    valores no formato "senha=...", "password: ..." etc. Isso é uma camada
    extra de proteção: os scripts não devem enviar senhas para o log.
#>

function Protect-LogMessage {
    <#
    .SYNOPSIS
        Mascara valores sensíveis (senhas, segredos, tokens) em uma mensagem.
    .EXAMPLE
        Protect-LogMessage -Message 'senha=Abc123'   # retorna 'senha=********'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    $pattern = '(?i)\b(password|passwd|pwd|senha|secret|segredo|token)\b(\s*[:=]\s*)(\S+)'
    return [regex]::Replace($Message, $pattern, '$1$2********')
}

function Write-Log {
    <#
    .SYNOPSIS
        Grava uma mensagem no arquivo de log e no fluxo apropriado do console.
    .DESCRIPTION
        INFO e DEBUG vão para o fluxo Verbose; WARN e ERROR para o fluxo Warning.
        O arquivo é gravado mesmo quando o script chamador roda com -WhatIf,
        para que a simulação também fique registrada.
    .PARAMETER Message
        Texto da mensagem. Nunca inclua senhas.
    .PARAMETER Level
        INFO (padrão), WARN, ERROR ou DEBUG.
    .PARAMETER Path
        Caminho do arquivo de log. A pasta é criada se não existir.
    .EXAMPLE
        Write-Log -Path ./logs/exemplo.log -Message 'Início da execução'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')]
        [string]$Level = 'INFO',

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $safeMessage = Protect-LogMessage -Message $Message
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $safeMessage

    try {
        $directory = Split-Path -Path $Path -Parent
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            $null = New-Item -ItemType Directory -Path $directory -Force -WhatIf:$false -Confirm:$false -ErrorAction Stop
        }
        Add-Content -LiteralPath $Path -Value $line -Encoding UTF8 -WhatIf:$false -Confirm:$false -ErrorAction Stop
    }
    catch {
        Write-Warning "Falha ao gravar o log em '$Path': $($_.Exception.Message)"
    }

    switch ($Level) {
        'WARN'  { Write-Warning $safeMessage }
        'ERROR' { Write-Warning "ERRO: $safeMessage" }
        default { Write-Verbose $safeMessage }
    }
}
