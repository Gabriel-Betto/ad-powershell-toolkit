# ad-powershell-toolkit

Scripts PowerShell para tarefas rotineiras de administração do Active Directory:
criação de usuários em lote, desligamento (offboarding) de contas e relatório de
contas inativas.

Todos os scripts que alteram o AD suportam `-WhatIf` e `-Confirm`, validam a
entrada antes de qualquer alteração e registram cada passo em log, sem jamais
gravar senhas.

> **Dados fictícios:** todos os nomes, logins, domínios (`corp.example.com`,
> reservado pela RFC 2606) e OUs deste repositório são exemplos. Ajuste-os para
> o seu ambiente.

## Estrutura

```text
ad-powershell-toolkit/
├── scripts/
│   ├── New-BulkADUsers.ps1        # cria usuários em lote a partir de CSV
│   ├── Invoke-ADOffboarding.ps1   # desliga contas (desabilita, remove grupos, move OU...)
│   └── Get-InactiveADAccounts.ps1 # relatório de contas sem logon há N dias (somente leitura)
├── lib/
│   ├── Write-Log.ps1              # log em arquivo com mascaramento de senhas
│   └── Validation.ps1             # validações que não dependem do AD
├── data/
│   └── usuarios_exemplo.csv       # CSV de exemplo (fictício)
├── tests/                         # testes Pester (não precisam de AD)
├── PSScriptAnalyzerSettings.psd1
└── LICENSE
```

## Requisitos

- Windows PowerShell 5.1 ou PowerShell 7+.
- Módulo **ActiveDirectory** (RSAT), apenas para executar contra o AD:
  - Windows 10/11: `Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0`
  - Windows Server: `Install-WindowsFeature RSAT-AD-PowerShell`
- Conta com permissões delegadas nas OUs envolvidas (criar usuários, desabilitar,
  alterar grupos, mover objetos). Evite usar Domain Admin para rotinas.

Se baixou o projeto como `.zip`, desbloqueie os arquivos antes de usar:

```powershell
Get-ChildItem -Recurse -Filter *.ps1 | Unblock-File
```

## Uso

Os exemplos assumem que o terminal está na pasta `scripts/`. A ajuda completa de
cada script está disponível com `Get-Help .\<script>.ps1 -Full`.

### New-BulkADUsers.ps1

Cria contas a partir de um CSV. O arquivo inteiro é validado antes: se houver
qualquer erro, **nenhuma** conta é criada. Logins que já existem no AD são
ignorados (status `Existente`). As contas são criadas habilitadas e com troca de
senha obrigatória no primeiro logon.

```powershell
# 1. Só validar o CSV (não precisa do módulo ActiveDirectory)
.\New-BulkADUsers.ps1 -CsvPath ..\data\usuarios_exemplo.csv -ValidateOnly

# 2. Simular a criação
$senha = Read-Host -AsSecureString -Prompt 'Senha inicial'
.\New-BulkADUsers.ps1 -CsvPath ..\data\usuarios_exemplo.csv -UpnSuffix corp.example.com -InitialPassword $senha -WhatIf

# 3. Executar de verdade e guardar o resultado
.\New-BulkADUsers.ps1 -CsvPath ..\data\usuarios_exemplo.csv -UpnSuffix corp.example.com -InitialPassword $senha |
    Export-Csv -Path ..\reports\criacao.csv -NoTypeInformation -Encoding UTF8
```

| Parâmetro | Descrição |
|---|---|
| `-CsvPath` | CSV de entrada (obrigatório, extensão `.csv`). |
| `-UpnSuffix` | Sufixo do UPN (`login@sufixo`). Validado como nome de domínio. |
| `-InitialPassword` | Senha inicial como `SecureString`. Se omitida, é pedida de forma segura. |
| `-ValidateOnly` | Apenas valida o CSV. |
| `-Delimiter` | `;` (padrão), `,` ou tabulação. |
| `-Server` | Controlador de domínio específico (opcional). |
| `-LogPath` | Arquivo de log (padrão em `logs/`). |

Saída: um objeto por usuário com `Login`, `Status` (`Criado`, `Simulado`,
`Existente`, `Erro`, `Valido`) e `Mensagem`.

### Invoke-ADOffboarding.ps1

Desliga uma ou mais contas. Etapas, na ordem:

1. desabilita a conta;
2. `-ResetPassword`: redefine a senha para um valor aleatório que não é exibido nem gravado;
3. grava na descrição a data do desligamento e o chamado (`-Ticket`);
4. `-RemoveGroups`: remove a conta de todos os grupos — a lista de grupos é
   registrada no log antes, para permitir reversão;
5. `-DisabledOU`: move a conta para a OU de desligados.

Como as ações têm alto impacto (`ConfirmImpact = 'High'`), o script pede
confirmação por padrão. Em automações, use `-Confirm:$false` — de preferência
depois de revisar uma execução com `-WhatIf`.

```powershell
# Simulação para uma conta
.\Invoke-ADOffboarding.ps1 -Identity ana.exemplo -RemoveGroups -ResetPassword -Ticket CHG-0001 -WhatIf

# Lote a partir de CSV com a coluna Login, sem prompts
.\Invoke-ADOffboarding.ps1 -CsvPath .\desligamentos.csv -RemoveGroups -ResetPassword `
    -DisabledOU 'OU=Desligados,DC=corp,DC=example,DC=com' -Ticket CHG-0002 -Confirm:$false
```

Validações antes de tocar no AD: todos os logins precisam ser válidos (senão
nada é alterado), `-DisabledOU` precisa ser um Distinguished Name e existir no
AD, e `-Ticket` aceita apenas letras, dígitos e hífen.

Saída: `Login`, `Status` (`Concluido`, `Simulado`, `NaoEncontrado`, `Erro`) e
`Mensagem` (em caso de erro, indica a etapa que falhou).

### Get-InactiveADAccounts.ps1

Relatório **somente leitura** das contas sem logon há mais de N dias.

```powershell
New-Item -ItemType Directory -Path ..\reports -Force | Out-Null   # pasta ignorada pelo Git
.\Get-InactiveADAccounts.ps1 -DaysInactive 120 -SearchBase 'OU=Usuarios,DC=corp,DC=example,DC=com'
.\Get-InactiveADAccounts.ps1 -IncludeDisabled -ExportPath ..\reports\inativos.csv
```

| Parâmetro | Descrição |
|---|---|
| `-DaysInactive` | Dias sem logon (1 a 3650, padrão 90). |
| `-SearchBase` | OU onde buscar (padrão: domínio inteiro). |
| `-IncludeDisabled` | Inclui contas já desabilitadas. |
| `-ExportPath` | Exporta o relatório para CSV (`;`, UTF-8). |
| `-Server`, `-LogPath` | Como nos demais scripts. |

O script usa `LastLogonTimestamp`, que é replicado entre os DCs mas pode ter
atraso de até ~14 dias; por isso, prefira `-DaysInactive` bem acima de 14.
Contas que nunca fizeram logon só aparecem se foram criadas antes da data de
corte. Combine com o offboarding:

```powershell
$inativos = .\Get-InactiveADAccounts.ps1 -DaysInactive 180
if ($inativos) {
    .\Invoke-ADOffboarding.ps1 -Identity $inativos.SamAccountName -Ticket CHG-0003 -WhatIf
}
```

## Formato do CSV

Separador padrão: ponto e vírgula (padrão do Excel em português). Salve como
**CSV UTF-8** para preservar acentos.

| Coluna | Obrigatória | Exemplo |
|---|---|---|
| `Nome` | sim | `Ana` |
| `Sobrenome` | sim | `Exemplo` |
| `Login` | sim | `ana.exemplo` |
| `OU` | sim | `OU=Usuarios,OU=TI,DC=corp,DC=example,DC=com` |
| `Email` | não | `ana.exemplo@corp.example.com` |
| `Departamento` | não | `TI` |
| `Cargo` | não | `Analista de Suporte` |

Regras de validação por linha (os erros indicam o número da linha no arquivo):

- colunas obrigatórias preenchidas;
- **login**: 1 a 20 caracteres (limite do `sAMAccountName`), somente letras sem
  acento, dígitos, `.`, `-` e `_`; começa com letra ou dígito; não termina com
  ponto; sem pontos consecutivos;
- login sem duplicidade no arquivo (sem diferenciar maiúsculas);
- e-mail, se informado, em formato válido;
- OU em formato de Distinguished Name.

## Segurança

- **`-WhatIf` / `-Confirm`** em todos os scripts que alteram o AD, com
  `ShouldProcess` em cada operação.
- **Validação antes da ação:** CSV e parâmetros são validados por completo
  antes de qualquer alteração; logins inválidos nunca chegam aos filtros do AD.
- **Senhas:** recebidas e geradas apenas como `SecureString`; nunca aparecem em
  log nem na saída. Como camada extra, `Write-Log` mascara padrões como
  `senha=...`, `password: ...` e `token=...`.
- **Logs:** um arquivo por script por dia em `logs/` (ignorado pelo Git), no
  formato `aaaa-MM-dd HH:mm:ss [NIVEL] mensagem`. Execuções com `-WhatIf`
  também são registradas.
- **Erros:** `try/catch` por usuário (um erro não interrompe o lote) e um
  `try/catch` geral; falhas de validação e de pré-requisito encerram com código
  de saída `1`.

## Testes e qualidade

As partes que não dependem de um AD real (validação de login, colunas e linhas
do CSV, geração de senha, log e validação de parâmetros dos scripts) são
cobertas por testes [Pester 5](https://pester.dev).

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force

# Análise estática (deve retornar vazio)
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1

# Testes
Invoke-Pester -Path .\tests -Output Detailed
```

O `PSScriptAnalyzerSettings.psd1` habilita, além das regras padrão, a checagem
de compatibilidade de sintaxe com Windows PowerShell 5.1 e PowerShell 7 e regras
de formatação consistente.

## Licença

[MIT](LICENSE)
