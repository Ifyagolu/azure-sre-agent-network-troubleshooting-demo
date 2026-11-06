[CmdletBinding()]
param(
    [string]$Location = 'westcentralus',
    [string]$TemplateFile = (Join-Path (Split-Path -Parent $PSScriptRoot) 'infra\main.bicep'),
    [string]$NetworkWatcherResourceGroup = 'NetworkWatcherRG',
    [string]$VmSize = 'Standard_D2as_v6',
    [string]$WindowsImagePublisher = 'MicrosoftWindowsServer',
    [string]$WindowsImageOffer = 'WindowsServer',
    [string]$WindowsImageSku = '2022-datacenter-azure-edition',
    [string]$WindowsImageVersion = 'latest',
    [string]$SubscriptionId,
    [switch]$Execute
)

. (Join-Path $PSScriptRoot 'Common.ps1')

$requiredModules = @('Az.Accounts', 'Az.Resources', 'Az.Compute', 'Az.Network', 'Az.OperationalInsights')
$local = foreach ($module in $requiredModules) {
    $found = Get-Module -ListAvailable -Name $module | Sort-Object Version -Descending | Select-Object -First 1
    [pscustomobject]@{
        module = $module
        installed = [bool]$found
        version = if ($found) { [string]$found.Version } else { $null }
    }
}
$local
if (-not (Test-Path -LiteralPath $TemplateFile -PathType Leaf)) {
    Write-Warning "Bicep template is not present: $TemplateFile"
}

if (-not (Assert-Execute -Execute $Execute -Operation "read Azure prerequisite state in $Location")) {
    return
}

if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
    throw 'Read-only Azure prerequisite checks require -SubscriptionId.'
}
Assert-DeploymentSubscription -SubscriptionId $SubscriptionId
$networkWatcher = Resolve-RegionalNetworkWatcher `
    -Location $Location `
    -DefaultResourceGroupName $NetworkWatcherResourceGroup `
    -AllowPlanned
$networkWatcher | Select-Object Name, ResourceGroupName, Location, Exists, Id | Format-Table -AutoSize

$availableImageSkus = @(
    Get-AzVMImageSku `
        -Location $Location `
        -PublisherName $WindowsImagePublisher `
        -Offer $WindowsImageOffer
)
if ($availableImageSkus.Skus -notcontains $WindowsImageSku) {
    throw "Windows image SKU '$WindowsImageSku' is not available in '$Location' for the current subscription."
}
$image = Get-AzVMImage -Location $Location -PublisherName $WindowsImagePublisher `
    -Offer $WindowsImageOffer -Skus $WindowsImageSku -Version $WindowsImageVersion
if (-not $image) { throw 'The requested Windows image version is not available in the selected region.' }
$availableVmSizes = @(
    Get-AzComputeResourceSku -Location $Location |
        Where-Object ResourceType -eq 'virtualMachines'
)
$vmSku = $availableVmSizes | Where-Object Name -eq $VmSize | Select-Object -First 1
if (-not $vmSku) {
    throw "VM size '$VmSize' is not available in '$Location' for the current subscription."
}
$locationRestrictions = @(
    $vmSku.Restrictions |
        Where-Object {
            $_.Type -eq 'Location' -and (
                $_.Values -contains $Location -or
                $_.RestrictionInfo.Locations -contains $Location
            )
        }
)
if ($locationRestrictions.Count -gt 0) {
    $reasonCodes = $locationRestrictions.ReasonCode | Select-Object -Unique
    throw "VM size '$VmSize' is restricted in '$Location' for the selected subscription. Reason: $($reasonCodes -join ', ')."
}
[pscustomobject]@{
    windowsImageUrn = "$WindowsImagePublisher`:$WindowsImageOffer`:$WindowsImageSku`:$WindowsImageVersion"
    imageAvailable = $true
    vmSize = $VmSize
    vmSizeAvailable = $true
} | Format-List

$requiredResourceTypes = @(
    [pscustomobject]@{ providerNamespace = 'Microsoft.Compute'; resourceType = 'virtualMachines' }
    [pscustomobject]@{ providerNamespace = 'Microsoft.Compute'; resourceType = 'virtualMachines/extensions' }
    [pscustomobject]@{ providerNamespace = 'Microsoft.Network'; resourceType = 'virtualNetworks' }
    [pscustomobject]@{ providerNamespace = 'Microsoft.Network'; resourceType = 'networkSecurityGroups' }
    [pscustomobject]@{ providerNamespace = 'Microsoft.Network'; resourceType = 'networkWatchers' }
    [pscustomobject]@{ providerNamespace = 'Microsoft.Network'; resourceType = 'networkWatchers/flowLogs' }
    [pscustomobject]@{ providerNamespace = 'Microsoft.Storage'; resourceType = 'storageAccounts' }
    [pscustomobject]@{ providerNamespace = 'Microsoft.OperationalInsights'; resourceType = 'workspaces' }
    [pscustomobject]@{ providerNamespace = 'Microsoft.Insights'; resourceType = 'dataCollectionRules' }
    [pscustomobject]@{ providerNamespace = 'Microsoft.Insights'; resourceType = 'dataCollectionRuleAssociations' }
)
$providers = foreach ($providerNamespace in ($requiredResourceTypes.providerNamespace | Select-Object -Unique)) {
    $provider = Get-AzResourceProvider -ProviderNamespace $providerNamespace
    foreach ($requiredType in ($requiredResourceTypes | Where-Object providerNamespace -eq $providerNamespace)) {
        $resourceType = $provider.ResourceTypes |
            Where-Object ResourceTypeName -eq $requiredType.resourceType |
            Select-Object -First 1
        $locationKey = ConvertTo-AzureLocationKey -Location $Location
        $locationSupported = [bool](
            $resourceType.Locations |
                Where-Object {
                    (ConvertTo-AzureLocationKey -Location ([string]$_)) -eq $locationKey
                }
        )
        [pscustomobject]@{
            providerNamespace = $providerNamespace
            resourceType = $requiredType.resourceType
            registrationState = $provider.RegistrationState | Select-Object -Unique
            locationSupported = $locationSupported
        }
    }
}
$providers | Format-Table -AutoSize
if ($providers.registrationState -contains 'NotRegistered') {
    throw 'One or more required providers are not registered. This script never registers providers.'
}
if ($providers.locationSupported -contains $false) {
    throw "One or more required resource types do not support '$Location'."
}
