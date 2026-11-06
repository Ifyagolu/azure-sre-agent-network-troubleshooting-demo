[CmdletBinding()]
param(
    [string]$ContextPath = (Join-Path $PSScriptRoot 'deployment-context.json'),
    [switch]$Execute,
    [string]$Confirmation
)

. (Join-Path $PSScriptRoot 'Common.ps1')
$context = Get-DeploymentContext -Path $ContextPath
Assert-SafeDemoResourceGroup $context.resourceGroupName
if ($context.networkWatcherResourceGroup -ieq $context.resourceGroupName) {
    throw 'The shared Network Watcher resource group must remain outside the demo resource group.'
}
$flowLogNames = @($context.flowLogNames | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
if ($flowLogNames.Count -ne 2) { throw 'Exactly two deployment-output flow-log names are required for cleanup.' }

Write-Host "Cleanup plan for resource group: $($context.resourceGroupName)"
Write-Host "Flow logs to list/remove: $($flowLogNames -join ', ')"
Write-Host 'Protected: the entire shared Network Watcher group, its watcher, and all provider registrations.'
if (-not (Assert-Execute -Execute $Execute -Operation 'list exact demo resources, then request deletion confirmation')) { return }
Assert-DeploymentSubscription -SubscriptionId $context.subscriptionId

$resourceGroup = Get-AzResourceGroup -Name $context.resourceGroupName
if ($context.resourceGroupId -and $resourceGroup.ResourceId -ne $context.resourceGroupId) {
    throw 'Resolved resource group ID does not match the deployment output.'
}
if (-not $resourceGroup.Tags -or $resourceGroup.Tags['workload'] -cne 'sre-network-demo' -or
    $resourceGroup.Tags['environment'] -cne 'demo') {
    throw 'Refusing cleanup without the dedicated demo ownership tags.'
}
Write-Host "Resolved resource group ID: $($resourceGroup.ResourceId)"
$resources = @(Get-AzResource -ResourceGroupName $context.resourceGroupName)
$resources | Select-Object Name, ResourceType, ResourceId | Format-Table -AutoSize

$watcher = Get-AzNetworkWatcher `
    -ResourceGroupName $context.networkWatcherResourceGroup `
    -Name $context.networkWatcherName
$watcherFlowLogs = @(Get-AzResource -ResourceGroupName $context.networkWatcherResourceGroup `
    -ResourceType 'Microsoft.Network/networkWatchers/flowLogs' -ExpandProperties -ErrorAction Stop)
$flowLogs = foreach ($name in $flowLogNames) {
    $id = '{0}/flowLogs/{1}' -f $watcher.Id, $name
    $resource = $watcherFlowLogs | Where-Object ResourceId -ieq $id | Select-Object -First 1
    if ($resource -and $resource.Properties.targetResourceId -notin @($context.clientVnetId, $context.workloadVnetId)) {
        throw 'Refusing to delete a flow log that does not target a VNet owned by this demo.'
    }
    if (-not $resource) { Write-Warning "Expected demo flow log '$name' is already absent; no deletion will be attempted for it." }
    [pscustomobject]@{ Name = $name; ResourceId = $id; Exists = [bool]$resource }
}
$flowLogs | Format-Table -AutoSize

$roleAssignmentIds = @($context.roleAssignmentIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
$roleAssignments = @()
foreach ($id in $roleAssignmentIds) {
    $normalizedId = ([string]$id).TrimEnd('/')
    $marker = '/providers/Microsoft.Authorization/roleAssignments/'
    $markerIndex = $normalizedId.LastIndexOf($marker, [System.StringComparison]::OrdinalIgnoreCase)
    if ($markerIndex -le 0) {
        throw "Role-assignment output is not a fully scoped resource ID: $normalizedId"
    }
    $scope = $normalizedId.Substring(0, $markerIndex)
    if ($scope -ine $context.resourceGroupId -and $scope -ine $context.workspaceResourceId) {
        throw 'Refusing a role assignment outside the demo group or workspace.'
    }
    $assignmentGuid = $normalizedId.Substring($markerIndex + $marker.Length)
    $parsedGuid = [guid]::Empty
    if ($assignmentGuid.Contains('/') -or -not [guid]::TryParse($assignmentGuid, [ref]$parsedGuid)) {
        throw "Role-assignment output has an invalid assignment GUID: $normalizedId"
    }
    $matchedAssignments = @(Get-AzRoleAssignment -Scope $scope | Where-Object {
        $reportedId = if ($_.PSObject.Properties['Id']) { [string]$_.Id } else { '' }
        $reportedAssignmentId = if ($_.PSObject.Properties['RoleAssignmentId']) { [string]$_.RoleAssignmentId } else { '' }
        $reportedId.TrimEnd('/') -ieq $normalizedId -or
            $reportedAssignmentId -ieq $assignmentGuid -or
            $reportedAssignmentId.TrimEnd('/') -ieq $normalizedId
    })
    if ($matchedAssignments.Count -gt 1) {
        throw "Multiple assignments unexpectedly matched exact output '$normalizedId'."
    }
    if ($matchedAssignments.Count -eq 1) {
        $roleAssignments += [pscustomobject]@{
            RequestedId = $normalizedId
            Scope = $scope
            InputObject = $matchedAssignments[0]
        }
    }
}
$roleAssignments | ForEach-Object {
    [pscustomobject]@{
        RequestedId = $_.RequestedId
        RoleDefinitionName = $_.InputObject.RoleDefinitionName
        Scope = $_.Scope
        ObjectId = $_.InputObject.ObjectId
    }
} | Format-Table -AutoSize
$resources |
    Where-Object ResourceType -match '(?i)managedIdentity|SRE|reliability' |
    Select-Object Name, ResourceType, ResourceId |
    Format-Table -AutoSize

$expected = 'DELETE {0} AND FLOW LOGS {1}' -f $context.resourceGroupName, ($flowLogNames -join ',')
Confirm-ExactText -Prompt 'Review the complete lists above. Deletion is irreversible.' -Expected $expected -Confirmation $Confirmation

foreach ($flowLog in $flowLogs | Where-Object Exists) {
    if ($flowLog.ResourceId -notlike "$($watcher.Id)/flowLogs/*") {
        throw "Refusing unexpected flow-log ID: $($flowLog.ResourceId)"
    }
    Remove-AzResource -ResourceId $flowLog.ResourceId -Force
}
foreach ($assignment in $roleAssignments) {
    if ($assignment.RequestedId -notin $roleAssignmentIds -or $assignment.InputObject.Scope -ine $assignment.Scope) {
        throw "Refusing unexpected role assignment: $($assignment.RequestedId)"
    }
    Remove-AzRoleAssignment -InputObject $assignment.InputObject
}
Remove-AzResourceGroup -Name $context.resourceGroupName -Force
Write-Host 'Demo cleanup was submitted. The shared Network Watcher group, watcher, and providers were not deleted or unregistered.'
