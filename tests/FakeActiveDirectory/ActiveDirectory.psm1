# Módulo ActiveDirectory FALSO, usado só nos testes (tests\Run-Tests.ps1).
# Imita, em memória, os comandos do AD que os scripts usam. NÃO fala com nenhum domínio real.
$script:OUs = @('OU=Usuarios,DC=empresa,DC=local','OU=Desativados,DC=empresa,DC=local')
$script:Groups = @{ 'GRP_Financeiro'=@(); 'GRP_VPN'=@(); 'GRP_Comercial'=@(); 'GRP_TI'=@(); 'GRP_Logistica'=@() }
$script:Users = [ordered]@{}
$script:Calls = New-Object System.Collections.ArrayList

function Add-Call($n){ [void]$script:Calls.Add($n) }
function Get-FakeCalls { $script:Calls }
function Initialize-FakeAD {
  $script:Users = [ordered]@{}
  $script:Calls.Clear()
  $script:Groups = @{ 'GRP_Financeiro'=@(); 'GRP_VPN'=@(); 'GRP_Comercial'=@(); 'GRP_TI'=@(); 'GRP_Logistica'=@() }
  $now = Get-Date
  $mk = { param($sam,$name,$dept,$last,$created,$member,$enabled)
    [pscustomobject]@{ SamAccountName=$sam; Name=$name; Department=$dept; Title='Analista'; Description='';
      LastLogonDate=$last; whenCreated=$created; Enabled=$enabled; MemberOf=@($member);
      DistinguishedName="CN=$name,OU=Usuarios,DC=empresa,DC=local" } }
  $script:Users['joao.silva']  = & $mk 'joao.silva' 'Joao Silva' 'Vendas' $now.AddDays(-5) $now.AddDays(-900) @('CN=GRP_Comercial,OU=Grupos,DC=empresa,DC=local','CN=GRP_VPN,OU=Grupos,DC=empresa,DC=local') $true
  $script:Users['maria.velha'] = & $mk 'maria.velha' 'Maria Velha' 'RH' $now.AddDays(-200) $now.AddDays(-1200) @() $true
  $script:Users['nunca.logou'] = & $mk 'nunca.logou' 'Nunca Logou' 'TI' $null $now.AddDays(-400) @() $true
  $script:Users['recente.novo']= & $mk 'recente.novo' 'Recente Novo' 'TI' $null $now.AddDays(-10) @() $true
  $script:Users['ja.desativ']  = & $mk 'ja.desativ' 'Ja Desativ' 'TI' $now.AddDays(-500) $now.AddDays(-1500) @() $false
}
function Get-ADOrganizationalUnit { [CmdletBinding()] param($Identity) Add-Call "Get-ADOrganizationalUnit $Identity"
  if($script:OUs -notcontains $Identity){ throw "OU nao encontrada: $Identity" } ; [pscustomobject]@{DistinguishedName=$Identity} }
function Get-ADUser { [CmdletBinding()] param($Identity,$Filter,$Properties,$SearchBase)
  Add-Call "Get-ADUser Identity=$Identity Filter=$Filter"
  if($Identity){ $k = if($Identity -is [string]){$Identity}else{$Identity.SamAccountName}
    if(-not $script:Users.Contains($k)){ throw "Cannot find an object with identity: '$k'" }; return $script:Users[$k] }
  if($Filter -match "SamAccountName -eq '(.+)'"){ $k=$Matches[1]; if($script:Users.Contains($k)){ return $script:Users[$k] }; return $null }
  if($Filter -match 'Enabled -eq \$true'){ return @($script:Users.Values | Where-Object Enabled) }
  throw "Filtro nao suportado no fake: $Filter" }
function New-ADUser { [CmdletBinding()] param($Name,$GivenName,$Surname,$DisplayName,$SamAccountName,$UserPrincipalName,$Department,$Title,$Path,$AccountPassword,[bool]$ChangePasswordAtLogon,[bool]$Enabled)
  Add-Call "New-ADUser $SamAccountName upn=$UserPrincipalName path=$Path chg=$ChangePasswordAtLogon pwdType=$($AccountPassword.GetType().Name)"
  if($script:Users.Contains($SamAccountName)){ throw "The specified account already exists" }
  $script:Users[$SamAccountName] = [pscustomobject]@{ SamAccountName=$SamAccountName; Name=$Name; Department=$Department; Title=$Title; Description=''; LastLogonDate=$null; whenCreated=(Get-Date); Enabled=$Enabled; MemberOf=@(); DistinguishedName="CN=$Name,$Path" } }
function Add-ADGroupMember { [CmdletBinding()] param($Identity,$Members)
  Add-Call "Add-ADGroupMember $Identity <- $Members"
  if(-not $script:Groups.ContainsKey($Identity)){ throw "Cannot find group $Identity" }
  $script:Groups[$Identity] += $Members
  $script:Users[$Members].MemberOf += "CN=$Identity,OU=Grupos,DC=empresa,DC=local" }
function Disable-ADAccount { [CmdletBinding()] param($Identity) Add-Call "Disable-ADAccount $($Identity.SamAccountName)"; $script:Users[$Identity.SamAccountName].Enabled=$false }
function Remove-ADGroupMember { [CmdletBinding()] param($Identity,$Members,[switch]$Confirm) Add-Call "Remove-ADGroupMember $Identity -$($Members.SamAccountName)"
  $u=$script:Users[$Members.SamAccountName]; $u.MemberOf = @($u.MemberOf | Where-Object { $_ -ne $Identity }) }
function Set-ADUser { [CmdletBinding()] param($Identity,$Description) Add-Call "Set-ADUser $($Identity.SamAccountName) desc=$Description"; $script:Users[$Identity.SamAccountName].Description=$Description }
function Move-ADObject { [CmdletBinding()] param($Identity,$TargetPath) Add-Call "Move-ADObject $Identity -> $TargetPath"
  $u = $script:Users.Values | Where-Object DistinguishedName -eq $Identity; $cn=($Identity -split ',')[0]; $u.DistinguishedName="$cn,$TargetPath" }
function Get-FakeUser($s){ $script:Users[$s] }
Export-ModuleMember -Function *
