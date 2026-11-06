[CmdletBinding()]
param(
    [string]$ContextPath = (Join-Path $PSScriptRoot 'deployment-context.json'),
    [string]$DeploymentName = 'sre-network-demo-connection-monitor',
    [switch]$Execute,
    [string]$Confirmation
)

. (Join-Path $PSScriptRoot 'Common.ps1')
$context = Get-DeploymentContext -Path $ContextPath
Assert-SafeDemoResourceGroup $context.resourceGroupName
foreach ($name in @('subscriptionId', 'location', 'workspaceResourceId', 'networkWatcherResourceGroup', 'networkWatcherName')) {
    if (-not $context.PSObject.Properties[$name] -or [string]::IsNullOrWhiteSpace([string]$context.$name)) {
        throw "Deployment context is missing required output '$name'."
    }
}
if ($context.networkWatcherResourceGroup -ieq $context.resourceGroupName) {
    throw 'The regional Network Watcher must remain in its existing separate resource group.'
}

$templateFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'infra\connection-monitor.bicep'
$bicepCommand = Get-Command bicep -ErrorAction SilentlyContinue
$bicepPath = if ($bicepCommand) { $bicepCommand.Source } else { Join-Path $HOME '.azure\bin\bicep.exe' }
if (-not (Test-Path -LiteralPath $bicepPath -PathType Leaf)) {
    throw 'Standalone Bicep CLI is required. Install it before running this script.'
}
$bicepDirectory = Split-Path -Parent $bicepPath
if (($env:PATH -split ';') -notcontains $bicepDirectory) { $env:PATH = "$bicepDirectory;$env:PATH" }
$validationFile = Join-Path $PSScriptRoot '.connection-monitor.validation.json'
try {
    & $bicepPath build $templateFile --outfile $validationFile
    if ($LASTEXITCODE -ne 0) { throw 'Connection Monitor Bicep build/lint failed.' }
} finally {
    if (Test-Path -LiteralPath $validationFile) { Remove-Item -LiteralPath $validationFile -Force }
}
Write-Host 'Local Connection Monitor Bicep build/lint succeeded.'
$connectionMonitorName = 'cm-{0}-client-to-iis' -f $context.resourceGroupName.Substring(3)
Write-Host "Plan: source agent on $($context.clientVmName); $connectionMonitorName under $($context.networkWatcherName)."
Write-Host "Path: $($context.clientPrivateIp) -> $($context.workloadPrivateIp):80/TCP every 30 seconds."
Write-Host 'Existing NSGs, VMs, AMA, DCRs, flow logs, workspace, IIS and SRE Agent are not redeployed.'
if (-not (Assert-Execute -Execute $Execute -Operation "validate, preview, and deploy Connection Monitor '$DeploymentName'")) { return }

Assert-DeploymentSubscription -SubscriptionId $context.subscriptionId
$watcher = Get-AzNetworkWatcher -ResourceGroupName $context.networkWatcherResourceGroup -Name $context.networkWatcherName
if ((ConvertTo-AzureLocationKey $watcher.Location) -ne (ConvertTo-AzureLocationKey $context.location) -or
    $watcher.ProvisioningState -ne 'Succeeded') {
    throw 'The existing regional Network Watcher must be successfully provisioned in the deployment region.'
}
$expectedWorkspaceId = '/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.OperationalInsights/workspaces/{2}' -f `
    $context.subscriptionId, $context.resourceGroupName, ($context.workspaceResourceId -split '/')[-1]
if ($context.workspaceResourceId -ine $expectedWorkspaceId) {
    throw 'The workspace must be the existing workspace in the demo subscription and resource group.'
}
$workspace = Get-AzResource -ResourceId $context.workspaceResourceId
if ($workspace.ResourceType -ine 'Microsoft.OperationalInsights/workspaces') {
    throw 'The recorded workspace ID does not resolve to a Log Analytics workspace.'
}
foreach ($endpoint in @(
    @{ Name = $context.clientVmName; Ip = $context.clientPrivateIp },
    @{ Name = $context.workloadVmName; Ip = $context.workloadPrivateIp }
)) {
    $vm = Get-AzVM -ResourceGroupName $context.resourceGroupName -Name $endpoint.Name
    if ((ConvertTo-AzureLocationKey $vm.Location) -ne (ConvertTo-AzureLocationKey $context.location)) {
        throw "VM '$($endpoint.Name)' is not in the recorded deployment region."
    }
    if ($vm.NetworkProfile.NetworkInterfaces.Count -ne 1) {
        throw "VM '$($endpoint.Name)' must have the single NIC expected by this demo."
    }
    $nicName = ($vm.NetworkProfile.NetworkInterfaces[0].Id -split '/')[-1]
    $nic = Get-AzNetworkInterface -ResourceGroupName $context.resourceGroupName -Name $nicName
    $primaryIps = @($nic.IpConfigurations | Where-Object Primary | ForEach-Object PrivateIpAddress)
    if ($primaryIps.Count -ne 1 -or $primaryIps[0] -ne $endpoint.Ip) {
        throw "VM '$($endpoint.Name)' private IP differs from the deployment context. Refresh and review the context; no address will be changed."
    }
}

$extensions = @(Get-AzVMExtension -ResourceGroupName $context.resourceGroupName -VMName $context.clientVmName)
$ama = @($extensions | Where-Object { $_.Publisher -eq 'Microsoft.Azure.Monitor' -and $_.ExtensionType -eq 'AzureMonitorWindowsAgent' })
if ($ama.Count -ne 1 -or $ama[0].ProvisioningState -ne 'Succeeded') {
    throw 'The existing source Azure Monitor Agent must be healthy; this deployment will not repair or replace it.'
}
$sourceAgents = @($extensions | Where-Object {
    $_.Publisher -eq 'Microsoft.Azure.NetworkWatcher' -and $_.ExtensionType -eq 'NetworkWatcherAgentWindows'
})
if ($sourceAgents.Count -gt 1 -or ($sourceAgents.Count -eq 1 -and $sourceAgents[0].ProvisioningState -ne 'Succeeded')) {
    throw 'Review the existing Network Watcher extension state before deployment; no extension will be replaced automatically.'
}
if ($sourceAgents.Count -eq 0 -and @($extensions | Where-Object Name -eq 'AzureNetworkWatcherExtension').Count -gt 0) {
    throw 'AzureNetworkWatcherExtension is already used by a different extension. Resolve the name conflict before deployment.'
}
$installSourceAgent = $sourceAgents.Count -eq 0
Write-Host $(if ($installSourceAgent) { 'Source Network Watcher agent will be installed alongside AMA.' } else { 'Existing healthy source Network Watcher agent will be reused without modification.' })
$nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $context.resourceGroupName -Name $context.workloadNsgName
$inboundDenies = @($nsg.SecurityRules | Where-Object { $_.Direction -eq 'Inbound' -and $_.Access -eq 'Deny' })
if ($inboundDenies.Count -gt 0) {
    Write-Warning "Inbound deny rule(s) remain: $($inboundDenies.Name -join ', '). Connection Monitor may initially report failure. Restore and validate the healthy path separately with approval."
}

$arguments = @{
    ResourceGroupName = $context.resourceGroupName
    Mode = 'Incremental'
    TemplateFile = $templateFile
    location = $context.location
    clientVmName = $context.clientVmName
    workloadVmName = $context.workloadVmName
    workloadPrivateIp = $context.workloadPrivateIp
    workspaceResourceId = $context.workspaceResourceId
    networkWatcherResourceGroupName = $context.networkWatcherResourceGroup
    networkWatcherName = $context.networkWatcherName
    connectionMonitorName = $connectionMonitorName
    installSourceAgent = $installSourceAgent
}
$validationResults = @(
    Test-AzResourceGroupDeployment @arguments |
        Where-Object { $_ -isnot [string] -or -not [string]::IsNullOrWhiteSpace($_) }
)
if ($validationResults.Count -gt 0) {
    $validationResults | Format-List -Force | Out-Host
    throw 'Azure resource-group deployment validation returned diagnostics. Deployment was not attempted.'
}
New-AzResourceGroupDeployment @arguments -Name $DeploymentName -WhatIf
Confirm-ExactText -Prompt 'Review the additive-only what-if. This installs the source agent if absent and creates/updates only this Connection Monitor.' `
    -Expected "DEPLOY CONNECTION MONITOR $DeploymentName" -Confirmation $Confirmation
$deployment = New-AzResourceGroupDeployment @arguments -Name $DeploymentName
if ($deployment.ProvisioningState -ne 'Succeeded') { throw 'Connection Monitor deployment did not succeed.' }
$deployment.Outputs | ConvertTo-Json -Depth 10 | Write-Output
Write-Host 'Outputs are retained on the resource-group deployment. The baseline deployment context was not overwritten.'
