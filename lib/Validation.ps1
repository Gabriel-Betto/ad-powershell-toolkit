<#
.SYNOPSIS
    Funções de validação que não dependem do Active Directory.

.DESCRIPTION
    Carregue com dot-sourcing:  . "$PSScriptRoot/../lib/Validation.ps1"

    Todas as funções deste arquivo são puras (ou só leem arquivos locais),
    por isso podem ser testadas com Pester em qualquer máquina, sem AD.
    O código é compatível com Windows PowerShell 5.1 e PowerShell 7+.
#>

function Test-SamAccountName {
    <#
    .SYNOPSIS
        Valida um login (sAMAccountName) segundo a política do toolkit.
    .DESCRIPTION
        Regras:
          - 1 a 20 caracteres (limite do sAMAccountName);
          - apenas letras ASCII, dígitos, ponto, hífen e sublinhado;
          - começa com letra ou dígito e não termina com ponto;
          - sem pontos consecutivos.
    .EXAMPLE
        Test-SamAccountName -Login 'joao.silva'   # True
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Login
    )

    if ([string]::IsNullOrEmpty($Login) -or $Login.Length -gt 20) {
        return $false
    }
    # -cmatch evita que [A-Za-z] case com caracteres especiais por folding de caixa.
    return ($Login -cmatch '^(?!.*\.\.)[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9_-])?$')
}

function Test-DistinguishedName {
    <#
    .SYNOPSIS
        Verifica se o texto tem formato de Distinguished Name (ex.: OU=Usuarios,DC=corp,DC=example,DC=com).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$DistinguishedName
    )

    if ([string]::IsNullOrWhiteSpace($DistinguishedName)) {
        return $false
    }
    $rdn = '(?:CN|OU)=(?:[^,=\\]|\\.)+'
    $dc = 'DC=[A-Za-z0-9-]+'
    return ($DistinguishedName -match "^(?:$rdn,)*$dc(?:,$dc)*$")
}

function Get-MissingCsvColumn {
    <#
    .SYNOPSIS
        Retorna as colunas obrigatórias que não estão no cabeçalho (comparação sem diferenciar maiúsculas).
    .EXAMPLE
        Get-MissingCsvColumn -Header 'Nome','Login' -RequiredColumn 'Nome','Login','OU'   # 'OU'
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Header,

        [Parameter(Mandatory)]
        [string[]]$RequiredColumn
    )

    $present = @($Header | ForEach-Object { "$_".Trim() })
    return @($RequiredColumn | Where-Object { $present -notcontains $_ })
}

function Get-CsvValue {
    # Lê uma coluna de uma linha do CSV sem falhar sob Set-StrictMode quando a coluna não existe.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [psobject]$Row,

        [Parameter(Mandatory)]
        [string]$Column
    )

    $property = $Row.PSObject.Properties[$Column]
    if ($null -eq $property -or $null -eq $property.Value) {
        return ''
    }
    return "$($property.Value)".Trim()
}

function Import-UserCsv {
    <#
    .SYNOPSIS
        Lê e valida o CSV de usuários usado pelo New-BulkADUsers.ps1.
    .DESCRIPTION
        Colunas obrigatórias: Nome, Sobrenome, Login, OU.
        Colunas opcionais:    Email, Departamento, Cargo.

        Retorna um objeto com:
          - Rows:   linhas válidas, normalizadas (valores sem espaços nas pontas);
          - Errors: mensagens de erro no formato "Linha N: ...".
        A função não lança exceção por dados inválidos; quem chama decide o que fazer.
    .PARAMETER Path
        Caminho do arquivo CSV (UTF-8).
    .PARAMETER Delimiter
        Separador de colunas. Padrão: ponto e vírgula (padrão do Excel em pt-BR).
    .EXAMPLE
        $resultado = Import-UserCsv -Path ./data/usuarios_exemplo.csv
        if ($resultado.Errors) { $resultado.Errors }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [ValidateLength(1, 1)]
        [string]$Delimiter = ';'
    )

    $requiredColumns = @('Nome', 'Sobrenome', 'Login', 'OU')
    $errors = [System.Collections.Generic.List[string]]::new()
    $rows = [System.Collections.Generic.List[object]]::new()

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $errors.Add("Arquivo CSV não encontrado: $Path")
        return [pscustomobject]@{ Rows = @(); Errors = $errors.ToArray() }
    }

    $headerLine = Get-Content -LiteralPath $Path -TotalCount 1 -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($headerLine)) {
        $errors.Add('O arquivo CSV está vazio ou não tem cabeçalho.')
        return [pscustomobject]@{ Rows = @(); Errors = $errors.ToArray() }
    }

    $header = @($headerLine.TrimStart([char]0xFEFF).Split($Delimiter) | ForEach-Object { $_.Trim().Trim('"').Trim() })
    $missing = @(Get-MissingCsvColumn -Header $header -RequiredColumn $requiredColumns)
    if ($missing.Count -gt 0) {
        $errors.Add("Colunas obrigatórias ausentes: $($missing -join ', '). Verifique também o separador (atual: '$Delimiter').")
        return [pscustomobject]@{ Rows = @(); Errors = $errors.ToArray() }
    }

    $data = @(Import-Csv -LiteralPath $Path -Delimiter $Delimiter -Encoding UTF8)
    if ($data.Count -eq 0) {
        $errors.Add('O arquivo CSV não contém linhas de dados.')
        return [pscustomobject]@{ Rows = @(); Errors = $errors.ToArray() }
    }

    $seenLogins = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    for ($i = 0; $i -lt $data.Count; $i++) {
        $lineNumber = $i + 2   # linha 1 é o cabeçalho
        $rowErrors = [System.Collections.Generic.List[string]]::new()

        $user = [pscustomobject]@{
            Nome         = Get-CsvValue -Row $data[$i] -Column 'Nome'
            Sobrenome    = Get-CsvValue -Row $data[$i] -Column 'Sobrenome'
            Login        = Get-CsvValue -Row $data[$i] -Column 'Login'
            Email        = Get-CsvValue -Row $data[$i] -Column 'Email'
            Departamento = Get-CsvValue -Row $data[$i] -Column 'Departamento'
            Cargo        = Get-CsvValue -Row $data[$i] -Column 'Cargo'
            OU           = Get-CsvValue -Row $data[$i] -Column 'OU'
        }

        foreach ($column in $requiredColumns) {
            if ([string]::IsNullOrEmpty($user.$column)) {
                $rowErrors.Add("coluna '$column' está vazia")
            }
        }

        if ($user.Login) {
            if (-not (Test-SamAccountName -Login $user.Login)) {
                $rowErrors.Add("login '$($user.Login)' é inválido (1-20 caracteres: letras sem acento, dígitos, '.', '-', '_')")
            }
            elseif (-not $seenLogins.Add($user.Login)) {
                $rowErrors.Add("login '$($user.Login)' está duplicado no arquivo")
            }
        }

        if ($user.Email -and $user.Email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
            $rowErrors.Add("e-mail '$($user.Email)' é inválido")
        }

        if ($user.OU -and -not (Test-DistinguishedName -DistinguishedName $user.OU)) {
            $rowErrors.Add("OU '$($user.OU)' não é um Distinguished Name válido")
        }

        if ($rowErrors.Count -gt 0) {
            foreach ($rowError in $rowErrors) {
                $errors.Add("Linha ${lineNumber}: $rowError")
            }
        }
        else {
            $rows.Add($user)
        }
    }

    return [pscustomobject]@{ Rows = $rows.ToArray(); Errors = $errors.ToArray() }
}

function Get-RandomPassword {
    <#
    .SYNOPSIS
        Gera uma senha aleatória forte e a devolve como SecureString.
    .DESCRIPTION
        Usa gerador criptográfico e garante ao menos uma maiúscula, uma minúscula,
        um dígito e um símbolo. A senha nunca é devolvida em texto puro.
    .PARAMETER Length
        Tamanho da senha (16 a 128). Padrão: 24.
    #>
    [CmdletBinding()]
    [OutputType([System.Security.SecureString])]
    param(
        [ValidateRange(16, 128)]
        [int]$Length = 24
    )

    # Sem caracteres ambíguos (O/0, l/1/I) para facilitar eventual digitação.
    $sets = @(
        'ABCDEFGHJKLMNPQRSTUVWXYZ',
        'abcdefghijkmnopqrstuvwxyz',
        '23456789',
        '!@#$%&*-_=+?'
    )
    $all = -join $sets

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        # Inteiro aleatório uniforme em [0, max) com rejeição para evitar viés de módulo.
        $getIndex = {
            param([int]$Max)
            $buffer = New-Object byte[] 4
            $limit = [uint32]::MaxValue - ([uint32]::MaxValue % [uint32]$Max)
            do {
                $rng.GetBytes($buffer)
                $value = [System.BitConverter]::ToUInt32($buffer, 0)
            } while ($value -ge $limit)
            return [int]($value % [uint32]$Max)
        }

        $chars = [System.Collections.Generic.List[char]]::new()
        foreach ($set in $sets) {
            $chars.Add($set[(& $getIndex $set.Length)])
        }
        while ($chars.Count -lt $Length) {
            $chars.Add($all[(& $getIndex $all.Length)])
        }

        # Embaralhamento Fisher-Yates para não deixar os caracteres obrigatórios no início.
        for ($i = $chars.Count - 1; $i -gt 0; $i--) {
            $j = & $getIndex ($i + 1)
            $temp = $chars[$i]
            $chars[$i] = $chars[$j]
            $chars[$j] = $temp
        }

        $secure = New-Object System.Security.SecureString
        foreach ($char in $chars) {
            $secure.AppendChar($char)
        }
        $secure.MakeReadOnly()
        return $secure
    }
    finally {
        $rng.Dispose()
    }
}
