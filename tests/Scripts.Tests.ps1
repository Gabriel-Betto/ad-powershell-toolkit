#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Testes dos scripts apenas nos caminhos que terminam antes de acessar o Active Directory
# (validação de parâmetros e do CSV). Nenhum teste precisa do módulo ActiveDirectory.

BeforeAll {
    $root = Split-Path -Path $PSScriptRoot -Parent
    $script:BulkScript = Join-Path -Path $root -ChildPath 'scripts/New-BulkADUsers.ps1'
    $script:OffboardingScript = Join-Path -Path $root -ChildPath 'scripts/Invoke-ADOffboarding.ps1'
    $script:InactiveScript = Join-Path -Path $root -ChildPath 'scripts/Get-InactiveADAccounts.ps1'
    $script:SampleCsv = Join-Path -Path $root -ChildPath 'data/usuarios_exemplo.csv'
}

Describe 'Ajuda e -WhatIf' {
    It '<_> tem ajuda baseada em comentários' -ForEach 'New-BulkADUsers.ps1', 'Invoke-ADOffboarding.ps1', 'Get-InactiveADAccounts.ps1' {
        $help = Get-Help -Name (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath "scripts/$_")
        $help.Synopsis | Should -Not -BeNullOrEmpty
        @($help.Examples.Example).Count | Should -BeGreaterOrEqual 1
    }

    It '<_> suporta -WhatIf e -Confirm' -ForEach 'New-BulkADUsers.ps1', 'Invoke-ADOffboarding.ps1' {
        $command = Get-Command -Name (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath "scripts/$_")
        $command.Parameters.Keys | Should -Contain 'WhatIf'
        $command.Parameters.Keys | Should -Contain 'Confirm'
    }
}

Describe 'New-BulkADUsers.ps1' {
    BeforeEach {
        $script:LogFile = Join-Path -Path $TestDrive -ChildPath "bulk_$([guid]::NewGuid()).log"
    }

    It 'valida o CSV de exemplo com -ValidateOnly' {
        $result = & $script:BulkScript -CsvPath $script:SampleCsv -ValidateOnly -LogPath $script:LogFile
        $result | Should -HaveCount 5
        $result.Status | Should -Not -Contain 'Erro'
        $result | ForEach-Object { $_.Status | Should -Be 'Valido' }
        Get-Content -LiteralPath $script:LogFile -Raw | Should -Match 'nenhuma alteração foi feita'
    }

    It 'sai com código 1 e registra os erros quando o CSV é inválido' {
        $csv = Join-Path -Path $TestDrive -ChildPath 'invalido.csv'
        Set-Content -LiteralPath $csv -Encoding UTF8 -Value @(
            'Nome;Sobrenome;Login;OU'
            'Ana;Exemplo;ana exemplo;OU=Usuarios,DC=corp,DC=example,DC=com'
        )
        $result = & $script:BulkScript -CsvPath $csv -ValidateOnly -LogPath $script:LogFile 3>$null
        $LASTEXITCODE | Should -Be 1
        $result | Should -BeNullOrEmpty
        Get-Content -LiteralPath $script:LogFile -Raw | Should -Match "\[ERROR\] Validação do CSV: Linha 2: login 'ana exemplo'"
    }

    It 'rejeita arquivo inexistente na validação do parâmetro' {
        { & $script:BulkScript -CsvPath (Join-Path -Path $TestDrive -ChildPath 'nao_existe.csv') -ValidateOnly } |
            Should -Throw -ExpectedMessage '*não encontrado*'
    }

    It 'rejeita arquivo que não é .csv' {
        $txt = Join-Path -Path $TestDrive -ChildPath 'usuarios.txt'
        Set-Content -LiteralPath $txt -Value 'x'
        { & $script:BulkScript -CsvPath $txt -ValidateOnly } | Should -Throw -ExpectedMessage '*.csv*'
    }

    It 'rejeita sufixo de UPN inválido "<_>"' -ForEach 'corp', '-corp.example.com', 'corp..example.com', 'corp example.com' {
        $secure = [System.Security.SecureString]::new()
        { & $script:BulkScript -CsvPath $script:SampleCsv -UpnSuffix $_ -InitialPassword $secure -WhatIf } | Should -Throw
    }

    It 'não aceita -ValidateOnly junto com -UpnSuffix' {
        { & $script:BulkScript -CsvPath $script:SampleCsv -ValidateOnly -UpnSuffix 'corp.example.com' } | Should -Throw
    }
}

Describe 'Invoke-ADOffboarding.ps1' {
    BeforeEach {
        $script:LogFile = Join-Path -Path $TestDrive -ChildPath "off_$([guid]::NewGuid()).log"
    }

    It 'sai com código 1 para login inválido sem alterar nada' {
        & $script:OffboardingScript -Identity 'ana exemplo', 'bruno.ficticio' -LogPath $script:LogFile -WhatIf 3>$null
        $LASTEXITCODE | Should -Be 1
        Get-Content -LiteralPath $script:LogFile -Raw | Should -Match "Login\(s\) inválido\(s\): ana exemplo\. Nenhuma conta foi alterada"
    }

    It 'sai com código 1 para DisabledOU inválida' {
        & $script:OffboardingScript -Identity 'ana.exemplo' -DisabledOU 'Desligados' -LogPath $script:LogFile -WhatIf 3>$null
        $LASTEXITCODE | Should -Be 1
        Get-Content -LiteralPath $script:LogFile -Raw | Should -Match "DisabledOU 'Desligados' não é um Distinguished Name"
    }

    It 'sai com código 1 quando o CSV não tem a coluna Login' {
        $csv = Join-Path -Path $TestDrive -ChildPath 'sem_login.csv'
        Set-Content -LiteralPath $csv -Encoding UTF8 -Value @('Usuario', 'ana.exemplo')
        & $script:OffboardingScript -CsvPath $csv -LogPath $script:LogFile -WhatIf 3>$null
        $LASTEXITCODE | Should -Be 1
        Get-Content -LiteralPath $script:LogFile -Raw | Should -Match "coluna obrigatória 'Login'"
    }

    It 'rejeita chamado com caracteres inválidos' {
        { & $script:OffboardingScript -Identity 'ana.exemplo' -Ticket 'CHG 0001;x' -WhatIf } | Should -Throw
    }
}

Describe 'Get-InactiveADAccounts.ps1' {
    BeforeEach {
        $script:LogFile = Join-Path -Path $TestDrive -ChildPath "inativos_$([guid]::NewGuid()).log"
    }

    It 'rejeita -DaysInactive fora do intervalo (<_>)' -ForEach 0, -5, 3651 {
        { & $script:InactiveScript -DaysInactive $_ } | Should -Throw
    }

    It 'sai com código 1 para SearchBase inválido' {
        & $script:InactiveScript -SearchBase 'Usuarios' -LogPath $script:LogFile 3>$null
        $LASTEXITCODE | Should -Be 1
    }

    It 'sai com código 1 para ExportPath sem extensão .csv' {
        & $script:InactiveScript -ExportPath (Join-Path -Path $TestDrive -ChildPath 'relatorio.txt') -LogPath $script:LogFile 3>$null
        $LASTEXITCODE | Should -Be 1
    }
}
