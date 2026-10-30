#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Testes de lib/Write-Log.ps1.

BeforeAll {
    . (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'lib/Write-Log.ps1')
}

Describe 'Protect-LogMessage' {
    It 'mascara "<Entrada>"' -ForEach @(
        @{ Entrada = 'senha=Abc123!'; Esperado = 'senha=********' }
        @{ Entrada = 'Password: S3cr3t'; Esperado = 'Password: ********' }
        @{ Entrada = 'pwd = x'; Esperado = 'pwd = ********' }
        @{ Entrada = 'token=abc segredo:xyz'; Esperado = 'token=******** segredo:********' }
        @{ Entrada = 'usuário ana.exemplo SENHA=Abc fim'; Esperado = 'usuário ana.exemplo SENHA=******** fim' }
    ) {
        Protect-LogMessage -Message $Entrada | Should -BeExactly $Esperado
    }

    It 'não altera mensagens sem dados sensíveis' {
        $message = "Senha de 'ana.exemplo' redefinida para um valor aleatório (não registrado)."
        Protect-LogMessage -Message $message | Should -BeExactly $message
    }

    It 'aceita mensagem vazia' {
        Protect-LogMessage -Message '' | Should -BeExactly ''
    }
}

Describe 'Write-Log' {
    BeforeEach {
        $script:LogFile = Join-Path -Path $TestDrive -ChildPath "logs/$([guid]::NewGuid()).log"
    }

    It 'cria a pasta e grava no formato "data [NIVEL] mensagem"' {
        Write-Log -Path $script:LogFile -Message 'Início da execução'
        $script:LogFile | Should -Exist
        Get-Content -LiteralPath $script:LogFile -Encoding UTF8 |
            Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \[INFO\] Início da execução$'
    }

    It 'registra o nível <_>' -ForEach 'INFO', 'WARN', 'ERROR', 'DEBUG' {
        Write-Log -Path $script:LogFile -Message 'teste' -Level $_ -WarningAction SilentlyContinue
        Get-Content -LiteralPath $script:LogFile | Should -Match "\[$_\] teste$"
    }

    It 'rejeita nível desconhecido' {
        { Write-Log -Path $script:LogFile -Message 'x' -Level 'FATAL' } | Should -Throw
    }

    It 'acrescenta linhas sem apagar as anteriores' {
        Write-Log -Path $script:LogFile -Message 'primeira'
        Write-Log -Path $script:LogFile -Message 'segunda'
        Get-Content -LiteralPath $script:LogFile | Should -HaveCount 2
    }

    It 'nunca grava a senha no arquivo' {
        Write-Log -Path $script:LogFile -Message 'Falha ao autenticar com senha=MinhaSenha123'
        $content = Get-Content -LiteralPath $script:LogFile -Raw
        $content | Should -Not -Match 'MinhaSenha123'
        $content | Should -Match 'senha=\*{8}'
    }

    It 'grava mesmo quando o chamador está em -WhatIf' {
        $WhatIfPreference = $true
        Write-Log -Path $script:LogFile -Message 'simulação'
        $WhatIfPreference = $false
        Get-Content -LiteralPath $script:LogFile | Should -Match 'simulação'
    }

    It 'envia WARN e ERROR para o fluxo de aviso' {
        $warnings = @()
        Write-Log -Path $script:LogFile -Message 'algo' -Level ERROR -WarningVariable warnings -WarningAction SilentlyContinue
        $warnings | Should -HaveCount 1
        "$($warnings[0])" | Should -Be 'ERRO: algo'
    }

    It 'não interrompe o script se o arquivo não puder ser gravado' {
        # Um diretório no lugar do arquivo força falha de escrita.
        $directory = Join-Path -Path $TestDrive -ChildPath 'sou_pasta'
        $null = New-Item -ItemType Directory -Path $directory
        { Write-Log -Path $directory -Message 'x' -WarningAction SilentlyContinue } | Should -Not -Throw
    }
}
