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
if (-not (Assert-Execute -Execute $Execute -Operation "add $RuleName to $($context.workloadNsgName)")) { return }
Assert-DeploymentSubscription -SubscriptionId $context.subscriptionId
Confirm-ExactText -Prompt 'This intentionally blocks new client-to-web connections.' -Expected 'INJECT NETWORK FAILURE' -Confirmation $Confirmation

$nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $context.resourceGroupName -Name $context.workloadNsgName
if ($nsg.SecurityRules.Name -contains $RuleName) {
    throw "Rule '$RuleName' already exists; refusing to overwrite it."
}
$changed = Add-AzNetworkSecurityRuleConfig `
    -NetworkSecurityGroup $nsg `
    -Name $RuleName `
    -Description 'Controlled synthetic demo failure; remove only by exact rule name.' `
    -Access Deny `
    -Protocol Tcp `
    -Direction Inbound `
    -Priority 100 `
    -SourceAddressPrefix $context.clientSubnetPrefix `
    -SourcePortRange '*' `
    -DestinationAddressPrefix $context.workloadPrivateIp `
    -DestinationPortRange '80'
$saved = Set-AzNetworkSecurityGroup -NetworkSecurityGroup $changed
$evidence = [ordered]@{
    scenario = 'network-failure'
    injectionUtc = (Get-Date).ToUniversalTime().ToString('o')
    resourceGroupName = $context.resourceGroupName
    nsgName = $saved.Name
    nsgId = $saved.Id
    ruleName = $RuleName
    sourcePrefix = $context.clientSubnetPrefix
    destinationIp = $context.workloadPrivateIp
    destinationPort = 80
}
Save-JsonEvidence $evidence (New-EvidencePath -Prefix 'network-failure-created' -EvidenceDirectory $EvidenceDirectory)
