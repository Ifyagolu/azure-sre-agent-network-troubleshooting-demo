[CmdletBinding()]
param(
    [string]$ContextPath = (Join-Path $PSScriptRoot 'deployment-context.json'),
    [string]$RuleName = 'Deny-Client-To-Web-Demo',
    [string]$EvidenceDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'evidence'),
    [switch]$Execute,
    [string]$Confirmation
)

. (Join-Path $PSScriptRoot 'Common.ps1')
$context = Get-DeploymentContext -Path $ContextPath
Assert-SafeDemoResourceGroup $context.resourceGroupName
if ($RuleName -cne 'Deny-Client-To-Web-Demo') { throw 'Only the planned demo deny rule name is permitted.' }
if (-not (Assert-Execute -Execute $Execute -Operation "remove only $RuleName from $($context.workloadNsgName)")) { return }
Assert-DeploymentSubscription -SubscriptionId $context.subscriptionId
Confirm-ExactText -Prompt 'This restores the planned network baseline.' -Expected 'RESTORE NETWORK' -Confirmation $Confirmation

$nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $context.resourceGroupName -Name $context.workloadNsgName
if ($nsg.SecurityRules.Name -notcontains $RuleName) {
    Write-Host "Rule '$RuleName' is already absent; no NSG mutation was made."
    return
}
$changed = Remove-AzNetworkSecurityRuleConfig -NetworkSecurityGroup $nsg -Name $RuleName
$saved = Set-AzNetworkSecurityGroup -NetworkSecurityGroup $changed
$evidence = [ordered]@{
    scenario = 'network-restore'
    restorationUtc = (Get-Date).ToUniversalTime().ToString('o')
    nsgId = $saved.Id
    removedRuleName = $RuleName
}
Save-JsonEvidence $evidence (New-EvidencePath -Prefix 'network-restored' -EvidenceDirectory $EvidenceDirectory)
