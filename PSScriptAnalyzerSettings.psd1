@{
    # Executar com: Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
    Severity            = @('Error', 'Warning', 'Information')
    IncludeDefaultRules = $true

    Rules               = @{
        # Os scripts precisam rodar no Windows PowerShell 5.1 (onde fica o módulo ActiveDirectory) e no PowerShell 7.
        PSUseCompatibleSyntax      = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }

        PSPlaceOpenBrace           = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }

        PSPlaceCloseBrace          = @{
            Enable             = $true
            NoEmptyLineBefore  = $false
            IgnoreOneLineBlock = $true
            NewLineAfter       = $true
        }

        PSUseConsistentIndentation = @{
            Enable          = $true
            IndentationSize = 4
            Kind            = 'space'
        }

        PSUseConsistentWhitespace  = @{
            Enable                          = $true
            CheckOpenBrace                  = $true
            CheckOpenParen                  = $true
            CheckOperator                   = $false
            CheckSeparator                  = $true
            CheckPipe                       = $true
            CheckInnerBrace                 = $true
            CheckParameter                  = $true
        }
    }
}
