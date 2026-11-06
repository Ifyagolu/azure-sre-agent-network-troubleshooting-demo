[CmdletBinding()]
param(
    [string]$TemplateFile = (Join-Path (Split-Path -Parent $PSScriptRoot) 'infra\main.bicep'),
    [string]$ParameterFile = (Join-Path (Split-Path -Parent $PSScriptRoot) 'infra\parameters.bicepparam'),
    [string]$Location,
    [string]$SubscriptionId,
    [string]$DeploymentName = ('sre-network-demo-{0}' -f (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')),
    [string]$ContextPath = (Join-Path $PSScriptRoot 'deployment-context.json'),
    [switch]$Execute,
    [string]$Confirmation
)

. (Join-Path $PSScriptRoot 'Common.ps1')

if (-not (Test-Path -LiteralPath $TemplateFile -PathType Leaf)) {
    throw "Template not found: $TemplateFile"
}
if (-not (Test-Path -LiteralPath $ParameterFile -PathType Leaf)) {
    throw "Parameter file not found: $ParameterFile"
}

$bicepCommand = Get-Command bicep -ErrorAction SilentlyContinue
$bicepPath = if ($bicepCommand) {
    $bicepCommand.Source
} else {
    Join-Path $HOME '.azure\bin\bicep.exe'
}
if (-not (Test-Path -LiteralPath $bicepPath -PathType Leaf)) {
    throw 'Standalone Bicep CLI is required for Az PowerShell deployment with a .bicepparam file. Azure CLI Bicep is not accepted.'
}
$bicepDirectory = Split-Path -Parent $bicepPath
if (($env:PATH -split ';') -notcontains $bicepDirectory) {
    $env:PATH = "$bicepDirectory;$env:PATH"
}
$validationFile = Join-Path $PSScriptRoot '.main.validation.json'
try {
    & $bicepPath build $TemplateFile --outfile $validationFile
    if ($LASTEXITCODE -ne 0) { throw 'Bicep build/lint failed.' }
    $template = Get-Content -LiteralPath $validationFile -Raw | ConvertFrom-Json
} finally {
    if (Test-Path -LiteralPath $validationFile) { Remove-Item -LiteralPath $validationFile -Force }
}
Write-Host 'Local Bicep build/lint succeeded.'

if (-not (Assert-Execute -Execute $Execute -Operation "validate, preview, and deploy '$DeploymentName'")) {
    return
}
$adminPassword = [Environment]::GetEnvironmentVariable('AZURE_VM_ADMIN_PASSWORD')
if ([string]::IsNullOrWhiteSpace($adminPassword)) {
    throw 'Set AZURE_VM_ADMIN_PASSWORD in the deployment process before execution. Do not store it in the parameter file.'
}
if ($adminPassword.Length -lt 14) {
    throw 'AZURE_VM_ADMIN_PASSWORD must contain at least 14 characters.'
}
if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
    throw 'Execution requires -SubscriptionId. The script never selects or switches a subscription.'
}
Assert-DeploymentSubscription -SubscriptionId $SubscriptionId
$parameterText = & $bicepPath build-params $ParameterFile --stdout
if ($LASTEXITCODE -ne 0) { throw 'Bicep parameter compilation failed.' }
$parameterBuild = ($parameterText -join "`n") | ConvertFrom-Json
if (-not $parameterBuild.parametersJson) { throw 'Bicep did not return compiled parameter JSON.' }
$compiledParameters = $parameterBuild.parametersJson | ConvertFrom-Json
$resolvedParameters = @{}
foreach ($property in $template.parameters.PSObject.Properties) {
    if ($property.Value.PSObject.Properties['defaultValue']) {
        $resolvedParameters[$property.Name] = $property.Value.defaultValue
    }
}
foreach ($property in $compiledParameters.parameters.PSObject.Properties) {
    $resolvedParameters[$property.Name] = $property.Value.value
}
if (-not $PSBoundParameters.ContainsKey('Location')) {
    $Location = $resolvedParameters.resourceLocation
}
Assert-SafeDemoResourceGroup -Name $resolvedParameters.resourceGroupName
Assert-DemoNetworkPrefixes `
    -ClientVnetPrefix $resolvedParameters.clientVnetPrefix `
    -ClientSubnetPrefix $resolvedParameters.clientSubnetPrefix `
    -WorkloadVnetPrefix $resolvedParameters.workloadVnetPrefix `
    -WorkloadSubnetPrefix $resolvedParameters.workloadSubnetPrefix

$arguments = @{
    Name = $DeploymentName
    Location = $Location
    TemplateFile = $TemplateFile
    TemplateParameterFile = $ParameterFile
    resourceLocation = $Location
}
$networkWatcher = Resolve-RegionalNetworkWatcher -Location $Location `
    -DefaultResourceGroupName $resolvedParameters.networkWatcherResourceGroupName -AllowPlanned
if ($networkWatcher.ResourceGroupName -ieq $resolvedParameters.resourceGroupName) {
    throw 'The Network Watcher must remain outside the dedicated demo group.'
}
if (-not $networkWatcher.Exists) {
    Get-AzResourceGroup -Name $networkWatcher.ResourceGroupName -ErrorAction Stop | Out-Null
}
$arguments.networkWatcherResourceGroupName = $networkWatcher.ResourceGroupName
$arguments.networkWatcherName = $networkWatcher.Name
$arguments.createNetworkWatcher = -not $networkWatcher.Exists
Write-Host ("Network Watcher: {0} in {1} ({2})" -f $networkWatcher.Name, $networkWatcher.ResourceGroupName, $(if ($networkWatcher.Exists) { 'existing' } else { 'will be created by the template' }))
$validationResults = @(Test-AzSubscriptionDeployment @arguments)
$validationErrors = @(
    $validationResults |
        Where-Object { $_ -is [Microsoft.Azure.Commands.ResourceManager.Cmdlets.SdkModels.PSResourceManagerError] }
)
$validationDiagnostics = @(
    $validationResults |
        Where-Object { $_ -isnot [Microsoft.Azure.Commands.ResourceManager.Cmdlets.SdkModels.PSResourceManagerError] }
)
$validationDiagnostics | Out-Host
if ($validationErrors.Count -gt 0) {
    $validationErrors | Format-List -Force | Out-Host
    throw 'Azure subscription deployment validation failed. Deployment was not attempted.'
}
Write-Host 'Azure subscription deployment validation succeeded.'
New-AzSubscriptionDeployment @arguments -WhatIf
Confirm-ExactText -Prompt 'Review the validation and what-if output above. Deployment changes Azure resources.' -Expected "DEPLOY $DeploymentName" -Confirmation $Confirmation
$deployment = New-AzSubscriptionDeployment @arguments
& (Join-Path $PSScriptRoot 'get-deployment-context.ps1') `
    -DeploymentObject $deployment `
    -ContextPath $ContextPath
