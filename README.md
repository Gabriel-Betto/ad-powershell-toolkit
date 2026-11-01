# AD PowerShell Toolkit

Scripts em PowerShell para automatizar as tarefas mais repetitivas de administração do Active Directory em ambientes corporativos: **criar usuários em lote**, **desligar usuários de forma padronizada** e **listar contas inativas**.

Nasceu da rotina de suporte N1/N2 e infraestrutura, onde cadastro e desligamento de pessoas aparecem todo dia e, feitos à mão, geram erro e esquecimento (grupos que ficam, contas que ninguém desativa).

> Todos os dados deste repositório (nomes, logins, domínios e OUs) são **fictícios**. Ajuste os parâmetros para o seu ambiente.

## O que tem aqui

| Script | O que faz |
| --- | --- |
| `scripts/New-BulkADUsers.ps1` | Cria usuários a partir de um CSV, com validação, grupos e troca de senha no primeiro logon |
| `scripts/Invoke-ADOffboarding.ps1` | Desliga um usuário: registra grupos, desativa, remove dos grupos, anota na descrição e move para a OU de desativados |
| `scripts/Get-InactiveADAccounts.ps1` | Gera um CSV com contas ativas sem logon há X dias (somente leitura) |
| `lib/Write-Log.ps1` | Função de log usada pelos scripts (console colorido + arquivo) |
| `data/usuarios_exemplo.csv` | CSV de exemplo com usuários fictícios |
| `tests/Run-Tests.ps1` | Testes automatizados (29 verificações) que rodam sem um AD real |

## Estrutura

```
ad-powershell-toolkit/
├── scripts/
│   ├── New-BulkADUsers.ps1
│   ├── Invoke-ADOffboarding.ps1
│   └── Get-InactiveADAccounts.ps1
├── lib/
│   └── Write-Log.ps1
├── data/
│   └── usuarios_exemplo.csv
├── tests/
│   ├── Run-Tests.ps1
│   └── FakeActiveDirectory/   # módulo AD falso, em memória, só para os testes
├── logs/        # gerado pelos scripts (ignorado pelo Git)
└── reports/     # relatórios gerados (ignorado pelo Git)
```

## Pré-requisitos

- Windows PowerShell 5.1 ou PowerShell 7 em uma máquina que alcance o domínio
- Módulo **ActiveDirectory** (RSAT: *Ferramentas de Administração de Servidor Remoto*)
- Permissões delegadas no AD para criar usuários, alterar grupos e mover objetos nas OUs usadas
- Política de execução que permita rodar os scripts (ex.: `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser`)

## Como usar

Sempre teste primeiro com **`-WhatIf`**: ele mostra o que seria feito sem alterar nada.

### 1. Criar usuários em lote

O CSV precisa ter as colunas `Nome, Sobrenome, Login, Departamento, Cargo, Grupos` (grupos separados por `;`). Veja `data/usuarios_exemplo.csv`.

```powershell
# Simulação
.\scripts\New-BulkADUsers.ps1 -CsvPath .\data\usuarios_exemplo.csv `
    -OUPath "OU=Usuarios,DC=empresa,DC=local" -UpnSuffix "empresa.local" -WhatIf

# Execução real (o script pergunta a senha inicial)
.\scripts\New-BulkADUsers.ps1 -CsvPath .\data\usuarios_exemplo.csv `
    -OUPath "OU=Usuarios,DC=empresa,DC=local" -UpnSuffix "empresa.local"
```

Comportamento:
- Login fora do padrão (3 a 20 caracteres, só letras, números, `.`, `-` e `_`) é rejeitado.
- Se o login já existe, a linha é ignorada: o script nunca sobrescreve uma conta.
- A conta nasce habilitada, com a senha inicial informada e **troca obrigatória no primeiro logon**.
- A senha não é gravada em log.

### 2. Desligar um usuário

```powershell
.\scripts\Invoke-ADOffboarding.ps1 -Login joao.silva `
    -DisabledOU "OU=Desativados,DC=empresa,DC=local" -Reason "Chamado 1234" -WhatIf
```

Passos executados, sempre na mesma ordem:
1. Grava no log os grupos atuais (permite reverter depois).
2. Desativa a conta.
3. Remove o usuário de todos os grupos (menos o grupo primário).
4. Registra na descrição a data e o motivo.
5. Move a conta para a OU de desativados.

O script **não exclui** a conta. Para o e-mail e as licenças no Microsoft 365, siga o procedimento da sua empresa (conversão da caixa, remoção de licença etc.).

### 3. Listar contas inativas

```powershell
.\scripts\Get-InactiveADAccounts.ps1 -DaysInactive 90
.\scripts\Get-InactiveADAccounts.ps1 -DaysInactive 60 -SearchBase "OU=Usuarios,DC=empresa,DC=local"
```

Gera `reports\contas_inativas_AAAA-MM-DD.csv`, ordenado por quem está há mais tempo sem logon. O script **só lê** o AD. Use o relatório para decidir quem entra no fluxo de desligamento.

> O campo de último logon (`LastLogonDate`) é replicado entre controladores de domínio com atraso de até cerca de 14 dias. Trate o resultado como uma lista para revisão, não como verdade absoluta.

## Testes

Os testes não precisam de domínio: eles carregam um módulo `ActiveDirectory` **falso** (em memória) e executam os três scripts em cenários de simulação, execução real e erro.

```powershell
.\tests\Run-Tests.ps1
```

Saída esperada: uma linha `[PASSOU]` por verificação e, no final, `Resultado: 29 passaram, 0 falharam`. Se algo falhar, o script termina com código 1 (útil para CI).

O que é coberto: `-WhatIf` não altera nada, login inválido é rejeitado, usuário existente não é sobrescrito, senha não vai para o log, desligamento remove grupos e move a conta, e o relatório de inativos respeita o limite de dias.

> Os testes validam a **lógica** dos scripts. Antes de usar em produção, rode também com `-WhatIf` em um ambiente de laboratório com um AD de verdade.

Em modo `-WhatIf`, o log também é gravado, com a marca `[SIMULAÇÃO]` em cada linha.

## Boas práticas incluídas

- `SupportsShouldProcess`: suporte a `-WhatIf` e `-Confirm` nos scripts que alteram o AD
- Validação de parâmetros e do CSV antes de qualquer alteração
- Tratamento de erros com `try/catch` e log por ação
- Nenhuma senha em código ou em log
- `.gitignore` para evitar versionar logs, relatórios e CSVs com dados reais

## Aviso

Teste em um ambiente de laboratório antes de usar em produção. Os scripts alteram objetos do Active Directory.

## Próximos passos

- [ ] Versão para Microsoft 365 / Entra ID com Microsoft Graph (licenças, caixas de e-mail)
- [ ] Relatório de grupos sem membros e de contas com senha que nunca expira
- [ ] Migrar os testes para Pester e rodar em CI (GitHub Actions)

## Licença

MIT. Veja o arquivo [LICENSE](LICENSE).
