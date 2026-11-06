[CmdletBinding(DefaultParameterSetName = 'Object')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Object')]$DeploymentObject,
    [Parameter(Mandatory, ParameterSetName = 'Azure')][string]$DeploymentName,
    [Parameter(ParameterSetName = 'Azure')][switch]$Execute,
    [string]$ContextPath = (Join-Path $PSScriptRoot 'deployment-context.json')
)

. (Join-Path $PSScriptRoot 'Common.ps1')

if ($PSCmdlet.ParameterSetName -eq 'Azure') {
    if (-not (Assert-Execute -Execute $Execute -Operation "read deployment '$DeploymentName' outputs")) {
        return
    }
    $DeploymentObject = Get-AzSubscriptionDeployment -Name $DeploymentName
}

$outputs = $DeploymentObject.Outputs
if (-not $outputs) { throw 'The deployment has no outputs.' }
$normalized = [ordered]@{
    schemaVersion = 1
    capturedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    deploymentName = if ($DeploymentObject.DeploymentName) { $DeploymentObject.DeploymentName } else { $DeploymentObject.Name }
    subscriptionId = Get-OutputValue $outputs @('subscriptionId')
    resourceGroupName = Get-OutputValue $outputs @('resourceGroupName') -Required
    resourceGroupId = Get-OutputValue $outputs @('resourceGroupId') -Required
    location = Get-OutputValue $outputs @('location')
    clientVnetId = Get-OutputValue $outputs @('clientVnetId') -Required
    workloadVnetId = Get-OutputValue $outputs @('workloadVnetId') -Required
    clientVmId = Get-OutputValue $outputs @('clientVmId') -Required
    workloadVmId = Get-OutputValue $outputs @('workloadVmId') -Required
    clientVmName = Get-OutputValue $outputs @('clientVmName') -Required
    workloadVmName = Get-OutputValue $outputs @('workloadVmName', 'webVmName') -Required
    clientPrivateIp = Get-OutputValue $outputs @('clientPrivateIp', 'clientPrivateIPAddress') -Required
    workloadPrivateIp = Get-OutputValue $outputs @('workloadPrivateIp', 'webPrivateIp', 'workloadPrivateIPAddress') -Required
    clientSubnetPrefix = Get-OutputValue $outputs @('clientSubnetPrefix') -Required
    workloadSubnetPrefix = Get-OutputValue $outputs @('workloadSubnetPrefix') -Required
    workloadNsgName = Get-OutputValue $outputs @('workloadNsgName') -Required
    workspaceCustomerId = Get-OutputValue $outputs @('workspaceCustomerId') -Required
    workspaceResourceId = Get-OutputValue $outputs @('workspaceResourceId')
    networkWatcherResourceGroup = Get-OutputValue $outputs @('networkWatcherResourceGroup') -Required
    networkWatcherName = Get-OutputValue $outputs @('networkWatcherName') -Required
    flowLogNames = @(
        Get-OutputValue $outputs @('flowLogNames') -Required |
            ForEach-Object { [string]$_ }
    )
    roleAssignmentIds = @(
        Get-OutputValue $outputs @('roleAssignmentIds') |
            Where-Object { $null -ne $_ } |
            ForEach-Object { [string]$_ }
    )
}
Assert-SafeDemoResourceGroup -Name $normalized.resourceGroupName
$workspaceGuid = [guid]::Empty
if (-not [guid]::TryParse([string]$normalized.workspaceCustomerId, [ref]$workspaceGuid)) {
    throw "Deployment output 'workspaceCustomerId' must be the workspace GUID, not its Azure resource ID."
}
Save-JsonEvidence -InputObject $normalized -Path $ContextPath
