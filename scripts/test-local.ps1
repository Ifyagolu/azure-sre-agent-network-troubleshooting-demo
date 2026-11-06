[CmdletBinding()]
param(
    [string]$BicepPath
)

. (Join-Path $PSScriptRoot 'Common.ps1')
$root = Get-ProjectRoot
$checks = 0
function Assert-Local {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Local validation failed: $Message" }
    $script:checks++
}
function Assert-Rejected {
    param([scriptblock]$Operation, [string]$Expected)
    $rejected = $false
    try { & $Operation | Out-Null } catch {
        if ($_.Exception.Message -notmatch $Expected) { throw }
        $rejected = $true
    }
    Assert-Local $rejected "Expected rejection: $Expected"
}
function Build-LocalBicep {
    param([string]$Path)
    $text = & $BicepPath build $Path --stdout
    if ($LASTEXITCODE -ne 0) { throw "Bicep compilation failed: $([IO.Path]::GetFileName($Path))" }
    ($text -join "`n") | ConvertFrom-Json
}

if ([string]::IsNullOrWhiteSpace($BicepPath)) {
    $command = Get-Command bicep -ErrorAction SilentlyContinue
    $BicepPath = if ($command) { $command.Source } else { Join-Path $HOME '.azure\bin\bicep.exe' }
}
Assert-Local (Test-Path -LiteralPath $BicepPath -PathType Leaf) 'Install standalone Bicep CLI before validation.'

$files = @(Get-ChildItem -LiteralPath $root -Recurse -Force -File)
$azureCommands = @()
foreach ($file in @($files | Where-Object Extension -eq '.ps1')) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    $diagnostics = @($errors | ForEach-Object { $_.Message }) -join '; '
    Assert-Local ($errors.Count -eq 0) "PowerShell syntax: $($file.Name): $diagnostics"
    $azureCommands += @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -match '^(Get|New|Test|Set|Add|Remove|Invoke)-Az'
    }, $true) | ForEach-Object { $_.GetCommandName() })
    foreach ($literal in $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
        $node.Value.Contains("`n") -and $node.Value -match 'Write-EventLog'
    }, $true)) {
        $guest = $literal.Value.Replace('__DURATION__', '180').Replace('__INTERVAL__', '5')
        $guestTokens = $null
        $guestErrors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($guest, [ref]$guestTokens, [ref]$guestErrors) | Out-Null
        Assert-Local ($guestErrors.Count -eq 0) "Embedded guest syntax: $($file.Name)"
    }
}
Write-Host 'PASS: PowerShell and embedded guest-script syntax.'

$templates = @{}
foreach ($file in @($files | Where-Object Extension -eq '.bicep')) {
    $templates[$file.Name] = Build-LocalBicep -Path $file.FullName
    Assert-Local ($null -ne $templates[$file.Name]) "Bicep syntax: $($file.Name)"
}
$main = $templates['main.bicep']
Assert-Local ($main.parameters.adminPassword.type -eq 'secureString') 'VM password must remain secure.'
Assert-Local ($main.parameters.resourceGroupName.defaultValue -ceq 'rg-sre-network-demo') 'Generic resource-group default.'
Assert-Local ($main.parameters.createNetworkWatcher.defaultValue -eq $false) 'Existing shared watcher is not redeployed by default.'
foreach ($name in @('clientVmId', 'workloadVmId', 'clientVnetId', 'workloadVnetId', 'workspaceCustomerId', 'workspaceResourceId', 'flowLogNames')) {
    Assert-Local ($null -ne $main.outputs.PSObject.Properties[$name]) "Required runtime output: $name"
}
$flowTargets = @($templates['flowlogs.bicep'].resources | Where-Object { $_.type -eq 'Microsoft.Network/networkWatchers/flowLogs' } |
    ForEach-Object { $_.properties.targetResourceId })
Assert-Local ($flowTargets -ccontains "[parameters('clientVnetId')]" -and
    $flowTargets -ccontains "[parameters('workloadVnetId')]") 'Flow logs must target VNets.'
Assert-Local ($flowTargets.Count -eq 2) 'Only the two VNet flow-log targets are deployed.'
$monitorText = $templates['connection-monitor.bicep'] | ConvertTo-Json -Depth 100
Assert-Local ($monitorText -notmatch '"type":\s*"Microsoft.Network/networkSecurityGroups"') 'Monitor deployment must remain additive.'

$previousPassword = [Environment]::GetEnvironmentVariable('AZURE_VM_ADMIN_PASSWORD', 'Process')
try {
    $env:AZURE_VM_ADMIN_PASSWORD = [guid]::NewGuid().ToString('N') + '!aA1'
    $text = & $BicepPath build-params (Join-Path $root 'infra\parameters.bicepparam') --stdout
    if ($LASTEXITCODE -ne 0) { throw 'Bicep parameter compilation failed.' }
    $parameterBuild = ($text -join "`n") | ConvertFrom-Json
    $parameters = $parameterBuild.parametersJson | ConvertFrom-Json
    Assert-Local ($parameters.parameters.adminPassword.value -ceq $env:AZURE_VM_ADMIN_PASSWORD) 'Secure environment-variable parameter binding.'
    Assert-DemoNetworkPrefixes `
        -ClientVnetPrefix $parameters.parameters.clientVnetPrefix.value `
        -ClientSubnetPrefix $parameters.parameters.clientSubnetPrefix.value `
        -WorkloadVnetPrefix $parameters.parameters.workloadVnetPrefix.value `
        -WorkloadSubnetPrefix $parameters.parameters.workloadSubnetPrefix.value
} finally {
    [Environment]::SetEnvironmentVariable('AZURE_VM_ADMIN_PASSWORD', $previousPassword, 'Process')
}
Write-Host 'PASS: All Bicep entry points/modules and synthetic parameter compilation.'

foreach ($name in @('rg-sre-network-demo', 'rg-sre-network-demo-lab-2')) {
    Assert-SafeDemoResourceGroup $name
    $checks++
}
foreach ($name in @('NetworkWatcherRG', 'rg-other-lab', 'rg-sre-network-demo-', 'rg-sre-network-demo-UPPER', ('rg-sre-network-demo-' + ('a' * 22)))) {
    Assert-Rejected { Assert-SafeDemoResourceGroup $name } 'Refusing operation'
}
foreach ($prefix in @('10.0.1.0/24', '172.16.0.0/12', '192.168.0.0/16')) {
    Get-PrivateCidrRange $prefix | Out-Null
    $checks++
}
foreach ($prefix in @('8.8.8.0/24', '172.32.0.0/16', '192.169.0.0/16', '10.0.0.1/24', '10.0.0.0/30', '10.0.0.256/24', '::1/64')) {
    Assert-Rejected { Get-PrivateCidrRange $prefix } 'prefix|address|RFC1918|CIDR'
}
Assert-Rejected {
    Assert-DemoNetworkPrefixes '10.10.0.0/16' '10.10.1.0/24' '10.10.2.0/24' '10.10.2.0/29'
} 'overlap'
Assert-Rejected {
    Assert-DemoNetworkPrefixes '10.10.0.0/16' '10.11.1.0/24' '10.20.0.0/16' '10.20.1.0/24'
} 'contained'
Assert-Rejected { Confirm-ExactText -Prompt 'Local test' -Expected 'APPROVED' -Confirmation 'wrong' } 'Confirmation did not'
Assert-Local (-not (Assert-Execute -Execute $false -Operation 'local gate test')) 'Execute gate must reject dry-run execution.'

$writers = @(
    'infra\windows\client-bootstrap.ps1', 'infra\windows\workload-bootstrap.ps1',
    'scripts\generate-good-traffic.ps1', 'scripts\generate-bad-traffic.ps1',
    'scripts\create-application-failure.ps1', 'scripts\restore-application.ps1'
)
foreach ($path in $writers) {
    Assert-Local ((Get-Content -LiteralPath (Join-Path $root $path) -Raw) -match "'SRE-Network-Demo'") "Event source writer: $path"
}
$dcr = Get-Content -LiteralPath (Join-Path $root 'infra\monitoring.bicep') -Raw
Assert-Local ($dcr.Contains('Provider[@Name="SRE-Network-Demo"]')) 'DCR event source contract.'
$health = Get-Content -LiteralPath (Join-Path $root 'queries\application-health.kql') -Raw
Assert-Local ($health.Contains('SRE-Network-Demo') -and $health.Contains('demo_health') -and
    $health.Contains('__WORKLOAD_VM_ID__') -and $health.Contains('_ResourceId =~ WorkloadResourceId')) 'Destination-scoped health query contract.'
$validator = Get-Content -LiteralPath (Join-Path $root 'scripts\validate-telemetry.ps1') -Raw
Assert-Local ($validator.Contains("Replace('__WORKLOAD_VM_ID__'") -and $validator.Contains('if ($healthCount -eq 0)')) 'Health placeholder binding and missing-evidence failure.'

$ignore = @(Get-Content -LiteralPath (Join-Path $root '.gitignore'))
foreach ($rule in @('scripts/deployment-context.json', 'deployment-context*.json', 'evidence/', '*.local.bicepparam',
    '*.local.json', 'scripts/.main.validation.json', 'infra/**/*.json', '.env', '.env.*', '*.pem', '*.key',
    '*.pfx', '*.p12', '*.cer', '*.log', '*.transcript.txt', '*.zip')) {
    Assert-Local ($ignore -ccontains $rule) "Required ignore rule: $rule"
}
Assert-Local ($ignore -cnotcontains '!infra/parameters*.json') 'Generated parameter JSON must not be re-included.'
Assert-Local ($ignore -cnotcontains '*.bicepparam') 'Actual parameter template must not be blanket-ignored.'

foreach ($file in @($files | Where-Object Extension -eq '.md')) {
    $document = Get-Content -LiteralPath $file.FullName -Raw
    foreach ($link in [regex]::Matches($document, '\[[^\]]*\]\(([^)]+)\)')) {
        $target = $link.Groups[1].Value
        if ($target -match '^https?://') { continue }
        $parts = $target.Split('#', 2)
        $resolved = if ($parts[0]) { [IO.Path]::GetFullPath((Join-Path $file.DirectoryName $parts[0].Replace('/', '\'))) } else { $file.FullName }
        Assert-Local ($resolved.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) 'Local documentation link must stay inside the project.'
        Assert-Local (Test-Path -LiteralPath $resolved) "Broken local link in $($file.Name): $target"
        if ($parts.Count -eq 2 -and $parts[1]) {
            $headings = [regex]::Matches((Get-Content -LiteralPath $resolved -Raw), '(?m)^#{1,6}\s+(.+)$') | ForEach-Object {
                (($_.Groups[1].Value.Trim().ToLowerInvariant() -replace '[^a-z0-9\s-]', '') -replace '\s+', '-')
            }
            Assert-Local ($headings -contains $parts[1]) "Broken heading link in $($file.Name): $target"
        }
    }
}
$brandingPattern = '(?i)\b' + ('S' + 'SC') + '\b|Shared Services ' + 'Canada|AI-' + 'Nsg-Logs'
$allowedGuids = @(
    'acdd72a7-3385-48ef-bd42-f606fba81ae7', '73c42c96-874c-492b-b04d-ab87d138a893',
    '43d0d8ad-25c7-4714-9337-8ba259a9fe05',
    # Obviously fictitious IDs used only by the local validation fixture.
    '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222'
)
foreach ($file in @($files | Where-Object { $_.Extension -in @('.md', '.ps1', '.bicep', '.bicepparam', '.kql', '.txt', '.json') })) {
    if ($file.Name -like 'deployment-context*.json' -or $file.Name -like '*.local.*' -or
        ($file.Extension -eq '.json' -and $file.FullName.StartsWith((Join-Path $root 'infra') + '\', [StringComparison]::OrdinalIgnoreCase))) { continue }
    $text = Get-Content -LiteralPath $file.FullName -Raw
    Assert-Local ($text -notmatch $brandingPattern) "Customer branding in $($file.Name)"
    foreach ($guid in [regex]::Matches($text, '(?i)\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b')) {
        Assert-Local ($guid.Value -in $allowedGuids) "Unexplained GUID in $($file.Name); value withheld."
    }
    Assert-Local ($text -notmatch '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|(?i:AccountKey\s*=\s*[A-Za-z0-9+/]{20,}|[?&]sig=[A-Za-z0-9%+/]{20,})') "Potential credential in $($file.Name); value withheld."
}
Assert-Local (@($files | Where-Object Extension -eq '.docx').Count -eq 0) 'No internal Word document in the public project.'
Write-Host 'PASS: Naming, private-network, evidence, ignore-rule, link, and publication checks.'

# Every Azure command is replaced before invoking any dry-run entry point.
foreach ($name in @($azureCommands | Sort-Object -Unique)) {
    Set-Item -Path "Function:\$name" -Value { throw 'Azure command invoked during local-only validation.' }
}
Assert-Rejected { Assert-DeploymentSubscription -SubscriptionId 'not-a-guid' } 'nonzero'
Set-Item -Path 'Function:\Get-AzContext' -Value {
    [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = '11111111-1111-1111-1111-111111111111' } }
}
Assert-DeploymentSubscription -SubscriptionId '11111111-1111-1111-1111-111111111111'
$checks++
Assert-Rejected {
    Assert-DeploymentSubscription -SubscriptionId '22222222-2222-2222-2222-222222222222'
} 'does not match'
Set-Item -Path 'Function:\Get-AzContext' -Value { throw 'Azure command invoked during local-only validation.' }
$fixturePath = Join-Path $PSScriptRoot 'deployment-context.local-validation.json'
$outputPath = Join-Path $PSScriptRoot 'deployment-context.local-output.json'
Assert-Local (-not (Test-Path -LiteralPath $fixturePath) -and -not (Test-Path -LiteralPath $outputPath)) 'Validation fixture paths must not overwrite existing files.'
# Synthetic identifiers and topology; never derived from the real runtime context.
$subscriptionId = '11111111-1111-1111-1111-111111111111'
$groupId = "/subscriptions/$subscriptionId/resourceGroups/rg-sre-network-demo"
$fixture = [ordered]@{
    schemaVersion = 1
    subscriptionId = $subscriptionId
    resourceGroupName = 'rg-sre-network-demo'
    resourceGroupId = $groupId
    location = 'westcentralus'
    clientVmName = 'vm-sre-client'
    workloadVmName = 'vm-sre-web'
    clientVmId = "$groupId/providers/Microsoft.Compute/virtualMachines/vm-sre-client"
    workloadVmId = "$groupId/providers/Microsoft.Compute/virtualMachines/vm-sre-web"
    clientVnetId = "$groupId/providers/Microsoft.Network/virtualNetworks/vnet-sre-network-demo-client"
    workloadVnetId = "$groupId/providers/Microsoft.Network/virtualNetworks/vnet-sre-network-demo-workload"
    clientPrivateIp = '10.10.1.4'
    workloadPrivateIp = '10.20.1.4'
    clientSubnetPrefix = '10.10.1.0/24'
    workloadSubnetPrefix = '10.20.1.0/24'
    workloadNsgName = 'nsg-sre-network-demo-workload'
    workspaceCustomerId = '22222222-2222-2222-2222-222222222222'
    workspaceResourceId = "$groupId/providers/Microsoft.OperationalInsights/workspaces/law-sre-network-demo"
    networkWatcherResourceGroup = 'NetworkWatcherRG'
    networkWatcherName = 'NetworkWatcher_westcentralus'
    flowLogNames = @('fl-sre-network-demo-client', 'fl-sre-network-demo-workload')
    roleAssignmentIds = @()
}
try {
    $fixture | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $fixturePath -Encoding utf8
    Get-DeploymentContext -Path $fixturePath | Out-Null
    $checks++
    foreach ($change in @(
        @{ Key = 'resourceGroupName'; Value = 'NetworkWatcherRG'; Error = 'Refusing operation' },
        @{ Key = 'networkWatcherResourceGroup'; Value = 'rg-sre-network-demo'; Error = 'outside' },
        @{ Key = 'workloadPrivateIp'; Value = '10.20.1.0'; Error = 'usable' },
        @{ Key = 'flowLogNames'; Value = @('fl-other', 'fl-sre-network-demo-client'); Error = 'flow-log names' },
        @{ Key = 'workloadVmId'; Value = "$groupId/providers/Microsoft.Compute/virtualMachines/other"; Error = 'does not match' }
    )) {
        $bad = ($fixture | ConvertTo-Json -Depth 10) | ConvertFrom-Json
        $bad.($change.Key) = $change.Value
        $bad | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $fixturePath -Encoding utf8
        Assert-Rejected { Get-DeploymentContext -Path $fixturePath } $change.Error
    }
    $fixture | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $fixturePath -Encoding utf8
    foreach ($name in @('generate-good-traffic', 'generate-bad-traffic', 'create-network-failure',
        'restore-network', 'create-application-failure', 'restore-application', 'cleanup',
        'validate-kql-schema', 'deploy-connection-monitor')) {
        & (Join-Path $PSScriptRoot "$name.ps1") -ContextPath $fixturePath | Out-Null
        $checks++
    }
    foreach ($name in @('wait-for-telemetry', 'validate-telemetry')) {
        & (Join-Path $PSScriptRoot "$name.ps1") -ContextPath $fixturePath `
            -TestStartUtc ([DateTime]::UtcNow.AddMinutes(-5)) -TestEndUtc ([DateTime]::UtcNow) | Out-Null
        $checks++
    }
    & (Join-Path $PSScriptRoot 'test-prerequisites.ps1') | Out-Null
    & (Join-Path $PSScriptRoot 'deploy.ps1') | Out-Null
    & (Join-Path $PSScriptRoot 'get-deployment-context.ps1') -DeploymentName 'local-test' | Out-Null
    $checks += 3
    & (Join-Path $PSScriptRoot 'get-deployment-context.ps1') `
        -DeploymentObject ([pscustomobject]@{ DeploymentName = 'local-test'; Name = 'local-test'; Outputs = $fixture }) `
        -ContextPath $outputPath | Out-Null
    Get-DeploymentContext -Path $outputPath | Out-Null
    $checks++
} finally {
    foreach ($path in @($fixturePath, $outputPath)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
}
Write-Host "PASS: $checks local checks completed. No Azure calls or real runtime-context reads."
