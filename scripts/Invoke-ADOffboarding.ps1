<#
.SYNOPSIS
    Desligamento padronizado de um usuário no Active Directory.

.DESCRIPTION
    Executa sempre os mesmos passos, para não depender da memória de quem atende o chamado:
      1. Registra no log os grupos atuais do usuário (para conseguir reverter).
      2. Desativa a conta.
      3. Remove o usuário de todos os grupos (exceto o grupo primário, "Domain Users").
      4. Grava na descrição da conta a data do desligamento e o motivo/chamado.
      5. Move a conta para a OU de desativados.
    Suporta -WhatIf para simular. Não exclui nada: a conta fica guardada na OU de desativados.

.PARAMETER Login
    SamAccountName do usuário a ser desligado.

.PARAMETER DisabledOU
    Distinguished Name da OU de contas desativadas. Ex.: "OU=Desativados,DC=empresa,DC=local"

.PARAMETER Reason
    Texto livre, normalmente o número do chamado. Ex.: "Chamado 1234"

.PARAMETER LogPath
    Arquivo de log. Padrão: logs\offboarding.log

.EXAMPLE
    .\Invoke-ADOffboarding.ps1 -Login joao.silva -DisabledOU "OU=Desativados,DC=empresa,DC=local" `
        -Reason "Chamado 1234" -WhatIf

.EXAMPLE
    .\Invoke-ADOffboarding.ps1 -Login joao.silva -DisabledOU "OU=Desativados,DC=empresa,DC=local" `
        -Reason "Chamado 1234"
#>

#Requires -Version 5.1
#Requires -Modules ActiveDirectory

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-zA-Z0-9._-]{3,20}$')]
    [string]$Login,

    [Parameter(Mandatory)]
    [string]$DisabledOU,

    [string]$Reason = 'Sem motivo informado',

    [string]$LogPath = (Join-Path -Path $PSScriptRoot -ChildPath '..\logs\offboarding.log')
)

. (Join-Path -Path $PSScriptRoot -ChildPath '..\lib\Write-Log.ps1')

# Busca o usuário; se não achar, para aqui
try {
    $user = Get-ADUser -Identity $Login -Properties MemberOf, Description -ErrorAction Stop
}
catch {
    Write-Log -Message "Usuário não encontrado: $Login" -Level ERROR -Path $LogPath
    throw
}

# Confere se a OU de destino existe
try {
    $null = Get-ADOrganizationalUnit -Identity $DisabledOU -ErrorAction Stop
}
catch {
    Write-Log -Message "OU de desativados não encontrada: $DisabledOU" -Level ERROR -Path $LogPath
    throw
}

Write-Log -Message "Iniciando desligamento de $Login ($($user.Name)) - Motivo: $Reason" -Path $LogPath

# 1) Guarda os grupos atuais no log, para permitir reverter depois
$groups = @($user.MemberOf)
if ($groups.Count -gt 0) {
    Write-Log -Message "Grupos atuais de ${Login}: $($groups -join ' | ')" -Path $LogPath
}
else {
    Write-Log -Message "$Login não pertence a grupos além do grupo primário." -Path $LogPath
}

try {
    # 2) Desativa a conta
    if ($PSCmdlet.ShouldProcess($Login, 'Desativar conta')) {
        Disable-ADAccount -Identity $user -ErrorAction Stop
        Write-Log -Message "Conta desativada: $Login" -Level OK -Path $LogPath
    }

    # 3) Remove de todos os grupos listados em MemberOf
    foreach ($groupDn in $groups) {
        if ($PSCmdlet.ShouldProcess($Login, "Remover do grupo $groupDn")) {
            Remove-ADGroupMember -Identity $groupDn -Members $user -Confirm:$false -ErrorAction Stop
            Write-Log -Message "  Removido do grupo: $groupDn" -Path $LogPath
        }
    }

    # 4) Atualiza a descrição com a data e o motivo
    $newDescription = "Desligado em $(Get-Date -Format 'yyyy-MM-dd') - $Reason"
    if ($PSCmdlet.ShouldProcess($Login, "Atualizar descrição para '$newDescription'")) {
        Set-ADUser -Identity $user -Description $newDescription -ErrorAction Stop
        Write-Log -Message "Descrição atualizada: $newDescription" -Path $LogPath
    }

    # 5) Move para a OU de desativados
    if ($PSCmdlet.ShouldProcess($Login, "Mover para $DisabledOU")) {
        Move-ADObject -Identity $user.DistinguishedName -TargetPath $DisabledOU -ErrorAction Stop
        Write-Log -Message "Conta movida para $DisabledOU" -Path $LogPath
    }

    if ($WhatIfPreference) {
        Write-Log -Message "Simulação concluída, nada foi alterado: $Login" -Path $LogPath
    }
    else {
        Write-Log -Message "Desligamento concluído: $Login" -Level OK -Path $LogPath
    }
}
catch {
    Write-Log -Message "Falha no desligamento de $Login : $($_.Exception.Message)" -Level ERROR -Path $LogPath
    throw
}
