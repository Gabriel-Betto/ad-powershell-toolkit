<#
.SYNOPSIS
    Função simples de log usada pelos scripts do toolkit.

.DESCRIPTION
    Escreve a mensagem no console (com cor por nível) e anexa a mesma linha
    em um arquivo de log. Cria a pasta do log se ela não existir.
    Este arquivo é carregado pelos scripts com "dot-sourcing":  . .\lib\Write-Log.ps1
#>

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')]
        [string]$Level = 'INFO',

        [Parameter(Mandatory)]
        [string]$Path
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    # Em modo -WhatIf (simulação) o script chamador tem $WhatIfPreference = $true.
    # Marcamos a linha para ninguém confundir um teste com uma execução real.
    $tag = if ($WhatIfPreference) { '[SIMULAÇÃO] ' } else { '' }
    $line = "[$timestamp] [$Level] $tag$Message"

    # Garante que a pasta do log exista.
    # -WhatIf:$false => o log é gravado mesmo na simulação (sem o ruído de "What if: Add Content").
    $folder = Split-Path -Path $Path -Parent
    if ($folder -and -not (Test-Path -Path $folder)) {
        New-Item -ItemType Directory -Path $folder -Force -WhatIf:$false | Out-Null
    }

    Add-Content -Path $Path -Value $line -Encoding UTF8 -WhatIf:$false

    $color = switch ($Level) {
        'INFO'  { 'Gray' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'OK'    { 'Green' }
    }
    Write-Host $line -ForegroundColor $color
}
