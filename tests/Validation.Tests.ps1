#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Testes das funções de lib/Validation.ps1. Nenhum teste depende de Active Directory.

BeforeAll {
    . (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'lib/Validation.ps1')

    $script:SampleCsv = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'data/usuarios_exemplo.csv'

    function Write-TestCsv {
        param([string]$Name, [string[]]$Line)
        $path = Join-Path -Path $TestDrive -ChildPath $Name
        [System.IO.File]::WriteAllLines($path, $Line, [System.Text.UTF8Encoding]::new($true))
        return $path
    }

    $script:Header = 'Nome;Sobrenome;Login;Email;Departamento;Cargo;OU'
    $script:Ou = 'OU=Usuarios,DC=corp,DC=example,DC=com'
}

Describe 'Test-SamAccountName' {
    It 'aceita o login válido <_>' -ForEach @(
        'ana.exemplo'
        'bruno_ficticio'
        'carla-teste'
        'usuario01'
        'a'
        'A1'
        ('x' * 20)
    ) {
        Test-SamAccountName -Login $_ | Should -BeTrue
    }

    It 'rejeita o login inválido "<Login>" (<Motivo>)' -ForEach @(
        @{ Login = ''; Motivo = 'vazio' }
        @{ Login = $null; Motivo = 'nulo' }
        @{ Login = ('x' * 21); Motivo = 'mais de 20 caracteres' }
        @{ Login = 'ana exemplo'; Motivo = 'espaço' }
        @{ Login = ' ana'; Motivo = 'espaço no início' }
        @{ Login = 'ana@exemplo'; Motivo = 'arroba' }
        @{ Login = 'ana/exemplo'; Motivo = 'barra' }
        @{ Login = 'ana\exemplo'; Motivo = 'barra invertida' }
        @{ Login = 'ana;exemplo'; Motivo = 'ponto e vírgula' }
        @{ Login = 'ana,exemplo'; Motivo = 'vírgula' }
        @{ Login = 'ana*'; Motivo = 'asterisco' }
        @{ Login = "ana'x"; Motivo = 'aspas simples' }
        @{ Login = 'joão'; Motivo = 'acento' }
        @{ Login = '.ana'; Motivo = 'começa com ponto' }
        @{ Login = '-ana'; Motivo = 'começa com hífen' }
        @{ Login = 'ana.'; Motivo = 'termina com ponto' }
        @{ Login = 'ana..exemplo'; Motivo = 'pontos consecutivos' }
    ) {
        Test-SamAccountName -Login $Login | Should -BeFalse
    }
}

Describe 'Test-DistinguishedName' {
    It 'aceita "<_>"' -ForEach @(
        'DC=example,DC=com'
        'OU=Usuarios,DC=corp,DC=example,DC=com'
        'OU=Usuarios,OU=TI,DC=corp,DC=example,DC=com'
        'CN=Ana Exemplo,OU=Usuarios,DC=corp,DC=example,DC=com'
        'ou=usuarios,dc=corp,dc=example,dc=com'
    ) {
        Test-DistinguishedName -DistinguishedName $_ | Should -BeTrue
    }

    It 'rejeita "<_>"' -ForEach @(
        ''
        'Usuarios'
        'OU=Usuarios'
        'OU=Usuarios,DC=corp,DC=example,DC=com,'
        'OU=,DC=corp,DC=example,DC=com'
        'corp.example.com'
    ) {
        Test-DistinguishedName -DistinguishedName $_ | Should -BeFalse
    }
}

Describe 'Get-MissingCsvColumn' {
    It 'não retorna nada quando todas as colunas existem' {
        Get-MissingCsvColumn -Header 'Nome', 'Sobrenome', 'Login', 'OU', 'Email' -RequiredColumn 'Nome', 'Login', 'OU' |
            Should -BeNullOrEmpty
    }

    It 'retorna as colunas ausentes, na ordem das obrigatórias' {
        $missing = Get-MissingCsvColumn -Header 'Nome', 'Email' -RequiredColumn 'Nome', 'Login', 'OU'
        $missing | Should -Be @('Login', 'OU')
    }

    It 'compara sem diferenciar maiúsculas e ignora espaços nas pontas' {
        Get-MissingCsvColumn -Header ' nome ', 'LOGIN', 'ou' -RequiredColumn 'Nome', 'Login', 'OU' |
            Should -BeNullOrEmpty
    }

    It 'retorna todas as obrigatórias quando o cabeçalho está vazio' {
        Get-MissingCsvColumn -Header @() -RequiredColumn 'Nome', 'Login' | Should -Be @('Nome', 'Login')
    }
}

Describe 'Import-UserCsv' {
    Context 'arquivo de exemplo do repositório' {
        It 'é válido e tem 5 usuários' {
            $result = Import-UserCsv -Path $script:SampleCsv
            $result.Errors | Should -BeNullOrEmpty
            $result.Rows | Should -HaveCount 5
        }

        It 'preserva acentos (UTF-8)' {
            $result = Import-UserCsv -Path $script:SampleCsv
            ($result.Rows | Where-Object Login -EQ 'elisa.demo').Sobrenome | Should -Be 'Demonstração'
        }

        It 'usa apenas domínios reservados para exemplo (example.com)' {
            $result = Import-UserCsv -Path $script:SampleCsv
            $result.Rows | Where-Object { $_.Email } | ForEach-Object { $_.Email | Should -Match '@corp\.example\.com$' }
            $result.Rows | ForEach-Object { $_.OU | Should -Match 'DC=example,DC=com$' }
        }
    }

    Context 'estrutura do arquivo' {
        It 'informa arquivo inexistente' {
            $result = Import-UserCsv -Path (Join-Path -Path $TestDrive -ChildPath 'nao_existe.csv')
            $result.Errors | Should -HaveCount 1
            $result.Errors[0] | Should -Match 'não encontrado'
            $result.Rows | Should -BeNullOrEmpty
        }

        It 'informa arquivo vazio' {
            $path = Join-Path -Path $TestDrive -ChildPath 'vazio.csv'
            Set-Content -LiteralPath $path -Value '' -NoNewline
            (Import-UserCsv -Path $path).Errors[0] | Should -Match 'vazio'
        }

        It 'informa CSV só com cabeçalho' {
            $path = Write-TestCsv -Name 'so_cabecalho.csv' -Line $script:Header
            (Import-UserCsv -Path $path).Errors[0] | Should -Match 'não contém linhas'
        }

        It 'lista as colunas obrigatórias ausentes' {
            $path = Write-TestCsv -Name 'sem_colunas.csv' -Line @('Nome;Email', 'Ana;ana@corp.example.com')
            $result = Import-UserCsv -Path $path
            $result.Errors | Should -HaveCount 1
            $result.Errors[0] | Should -Match 'Sobrenome, Login, OU'
        }

        It 'aponta separador incorreto como coluna ausente' {
            $path = Write-TestCsv -Name 'virgula.csv' -Line @('Nome,Sobrenome,Login,OU', 'Ana,Exemplo,ana.exemplo,DC=example')
            (Import-UserCsv -Path $path).Errors[0] | Should -Match 'separador'
        }

        It 'aceita outro separador com -Delimiter' {
            $path = Write-TestCsv -Name 'virgula_ok.csv' -Line @('Nome,Sobrenome,Login,OU', "Ana,Exemplo,ana.exemplo,`"$script:Ou`"")
            $result = Import-UserCsv -Path $path -Delimiter ','
            $result.Errors | Should -BeNullOrEmpty
            $result.Rows[0].OU | Should -Be $script:Ou
        }

        It 'aceita somente as colunas obrigatórias (opcionais ausentes)' {
            $path = Write-TestCsv -Name 'minimo.csv' -Line @('Nome;Sobrenome;Login;OU', "Ana;Exemplo;ana.exemplo;$script:Ou")
            $result = Import-UserCsv -Path $path
            $result.Errors | Should -BeNullOrEmpty
            $result.Rows[0].Email | Should -Be ''
        }

        It 'não diferencia maiúsculas no cabeçalho' {
            $path = Write-TestCsv -Name 'caixa.csv' -Line @('NOME;sobrenome;Login;ou', "Ana;Exemplo;ana.exemplo;$script:Ou")
            (Import-UserCsv -Path $path).Errors | Should -BeNullOrEmpty
        }
    }

    Context 'validação por linha' {
        It 'remove espaços nas pontas dos valores' {
            $path = Write-TestCsv -Name 'espacos.csv' -Line @($script:Header, " Ana ; Exemplo ; ana.exemplo ;;;; $script:Ou ")
            $row = (Import-UserCsv -Path $path).Rows[0]
            $row.Nome | Should -Be 'Ana'
            $row.Login | Should -Be 'ana.exemplo'
            $row.OU | Should -Be $script:Ou
        }

        It 'reporta coluna obrigatória vazia com o número da linha' {
            $path = Write-TestCsv -Name 'vazia.csv' -Line @(
                $script:Header
                "Ana;Exemplo;ana.exemplo;;;;$script:Ou"
                "Bruno;;bruno.ficticio;;;;$script:Ou"
            )
            $result = Import-UserCsv -Path $path
            $result.Errors | Should -Be @("Linha 3: coluna 'Sobrenome' está vazia")
            $result.Rows | Should -HaveCount 1
        }

        It 'reporta login inválido' {
            $path = Write-TestCsv -Name 'login.csv' -Line @($script:Header, "Ana;Exemplo;ana exemplo;;;;$script:Ou")
            (Import-UserCsv -Path $path).Errors[0] | Should -Match "^Linha 2: login 'ana exemplo' é inválido"
        }

        It 'reporta login duplicado sem diferenciar maiúsculas' {
            $path = Write-TestCsv -Name 'duplicado.csv' -Line @(
                $script:Header
                "Ana;Exemplo;ana.exemplo;;;;$script:Ou"
                "Ana;Outra;ANA.EXEMPLO;;;;$script:Ou"
            )
            $result = Import-UserCsv -Path $path
            $result.Errors | Should -HaveCount 1
            $result.Errors[0] | Should -Match "^Linha 3: login 'ANA.EXEMPLO' está duplicado"
        }

        It 'reporta e-mail inválido' {
            $path = Write-TestCsv -Name 'email.csv' -Line @($script:Header, "Ana;Exemplo;ana.exemplo;ana.example.com;;;$script:Ou")
            (Import-UserCsv -Path $path).Errors[0] | Should -Match "e-mail 'ana.example.com' é inválido"
        }

        It 'reporta OU que não é Distinguished Name' {
            $path = Write-TestCsv -Name 'ou.csv' -Line @($script:Header, 'Ana;Exemplo;ana.exemplo;;;;Usuarios')
            (Import-UserCsv -Path $path).Errors[0] | Should -Match "OU 'Usuarios' não é um Distinguished Name"
        }

        It 'reporta todos os erros de uma mesma linha' {
            $path = Write-TestCsv -Name 'varios.csv' -Line @($script:Header, ';Exemplo;ana exemplo;x;;;Usuarios')
            $errors = (Import-UserCsv -Path $path).Errors
            $errors | Should -HaveCount 4
            $errors | ForEach-Object { $_ | Should -Match '^Linha 2: ' }
        }
    }
}

Describe 'Get-RandomPassword' {
    BeforeAll {
        function ConvertTo-PlainText {
            param([securestring]$Secure)
            [System.Net.NetworkCredential]::new('', $Secure).Password
        }
    }

    It 'retorna SecureString somente leitura' {
        $secure = Get-RandomPassword
        $secure | Should -BeOfType [System.Security.SecureString]
        $secure.IsReadOnly() | Should -BeTrue
    }

    It 'respeita o tamanho pedido (<_>)' -ForEach 16, 24, 64 {
        (Get-RandomPassword -Length $_).Length | Should -Be $_
    }

    It 'rejeita tamanho menor que 16' {
        { Get-RandomPassword -Length 8 } | Should -Throw
    }

    It 'contém maiúscula, minúscula, dígito e símbolo' {
        1..20 | ForEach-Object {
            $plain = ConvertTo-PlainText -Secure (Get-RandomPassword -Length 16)
            $plain | Should -MatchExactly '[A-Z]'
            $plain | Should -MatchExactly '[a-z]'
            $plain | Should -Match '[0-9]'
            $plain | Should -Match '[^A-Za-z0-9]'
        }
    }

    It 'gera valores diferentes a cada chamada' {
        $values = 1..20 | ForEach-Object { ConvertTo-PlainText -Secure (Get-RandomPassword) }
        @($values | Sort-Object -Unique) | Should -HaveCount 20
    }
}
