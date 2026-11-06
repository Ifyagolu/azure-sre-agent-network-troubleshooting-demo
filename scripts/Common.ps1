Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Execute {
    param(
        [Parameter(Mandatory)][bool]$Execute,
        [Parameter(Mandatory)][string]$Operation
    )
    if (-not $Execute) {
        Write-Host "DRY RUN: $Operation"
        Write-Host 'No Azure command was run. Re-run with -Execute to authorize this operation.'
        return $false
    }
    return $true
}

function Confirm-ExactText {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$Expected,
        [string]$Confirmation
    )
    $actual = if ($PSBoundParameters.ContainsKey('Confirmation') -and -not [string]::IsNullOrEmpty($Confirmation)) {
        $Confirmation
    } else {
        Read-Host "$Prompt Type exactly: $Expected"
    }
    if ($actual -cne $Expected) {
        throw "Confirmation did not exactly match '$Expected'. Nothing was changed."
    }
}

function Get-ProjectRoot {
    Split-Path -Parent $PSScriptRoot
}

function ConvertTo-AzureLocationKey {
    param([Parameter(Mandatory)][string]$Location)
    ($Location -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
}

function Resolve-RegionalNetworkWatcher {
    param(
        [Parameter(Mandatory)][string]$Location,
        [string]$DefaultResourceGroupName = 'NetworkWatcherRG',
        [switch]$AllowPlanned
    )
    $locationKey = ConvertTo-AzureLocationKey -Location $Location
    $regionalWatchers = @(
        Get-AzNetworkWatcher |
            Where-Object {
                (ConvertTo-AzureLocationKey -Location ([string]$_.Location)) -eq $locationKey
            }
    )
    if ($regionalWatchers.Count -gt 1) {
        $watcherIds = $regionalWatchers.Id -join ', '
        throw "Multiple Network Watchers exist in '$Location'. Specify one explicitly after reviewing: $watcherIds"
    }
    if ($regionalWatchers.Count -eq 1) {
        return [pscustomobject]@{
            Name = $regionalWatchers[0].Name
            ResourceGroupName = $regionalWatchers[0].ResourceGroupName
            Location = $regionalWatchers[0].Location
            Exists = $true
            Id = $regionalWatchers[0].Id
        }
    }
    if (-not $AllowPlanned) {
        throw "No Network Watcher exists in '$Location'."
    }
    return [pscustomobject]@{
        Name = "NetworkWatcher_$locationKey"
        ResourceGroupName = $DefaultResourceGroupName
        Location = $Location
        Exists = $false
        Id = $null
    }
}

function Get-DeploymentContext {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Deployment context not found: $Path. Create it from deployment outputs with get-deployment-context.ps1."
    }
    $context = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    foreach ($name in @(
        'resourceGroupName', 'clientVmName', 'workloadVmName', 'clientPrivateIp',
        'workloadPrivateIp', 'workloadNsgName', 'workspaceCustomerId', 'subscriptionId',
        'resourceGroupId', 'location', 'workspaceResourceId', 'networkWatcherResourceGroup',
        'networkWatcherName', 'clientVnetId', 'workloadVnetId', 'clientVmId',
        'workloadVmId', 'clientSubnetPrefix', 'workloadSubnetPrefix', 'flowLogNames'
    )) {
        if (-not $context.PSObject.Properties[$name] -or [string]::IsNullOrWhiteSpace([string]$context.$name)) {
            throw "Deployment context is missing required output '$name'."
        }
    }
    Assert-SafeDemoResourceGroup -Name $context.resourceGroupName
    if ($context.networkWatcherResourceGroup -ieq $context.resourceGroupName) {
        throw 'The shared Network Watcher must be outside the dedicated demo resource group.'
    }
    $subscriptionGuid = [guid]::Empty
    if (-not [guid]::TryParse([string]$context.subscriptionId, [ref]$subscriptionGuid) -or
        $subscriptionGuid -eq [guid]::Empty) {
        throw 'Deployment context subscriptionId must be a nonzero GUID.'
    }
    $workspaceGuid = [guid]::Empty
    if (-not [guid]::TryParse([string]$context.workspaceCustomerId, [ref]$workspaceGuid) -or
        $workspaceGuid -eq [guid]::Empty) {
        throw "Deployment context workspaceCustomerId is not a Log Analytics workspace GUID."
    }
    $groupId = '/subscriptions/{0}/resourceGroups/{1}' -f $context.subscriptionId, $context.resourceGroupName
    $demoName = $context.resourceGroupName.Substring(3)
    $expectedIds = @{
        resourceGroupId = $groupId
        workspaceResourceId = "$groupId/providers/Microsoft.OperationalInsights/workspaces/law-$demoName"
        clientVnetId = "$groupId/providers/Microsoft.Network/virtualNetworks/vnet-$demoName-client"
        workloadVnetId = "$groupId/providers/Microsoft.Network/virtualNetworks/vnet-$demoName-workload"
        clientVmId = "$groupId/providers/Microsoft.Compute/virtualMachines/vm-sre-client"
        workloadVmId = "$groupId/providers/Microsoft.Compute/virtualMachines/vm-sre-web"
    }
    foreach ($name in $expectedIds.Keys) {
        if ($context.$name -ine $expectedIds[$name]) {
            throw "Deployment context '$name' does not match the dedicated demo scope. Regenerate context from the new deployment."
        }
    }
    if ($context.clientVmName -cne 'vm-sre-client' -or $context.workloadVmName -cne 'vm-sre-web' -or
        $context.workloadNsgName -cne "nsg-$demoName-workload") {
        throw 'Deployment context resource names do not match this demo. Regenerate it from deployment outputs.'
    }
    $expectedFlowNames = @("fl-$demoName-client", "fl-$demoName-workload")
    if (@($context.flowLogNames).Count -ne 2 -or
        @($context.flowLogNames | Select-Object -Unique).Count -ne 2 -or
        @($context.flowLogNames | Where-Object { $_ -cnotin $expectedFlowNames }).Count -gt 0) {
        throw 'Deployment context must contain only the two flow-log names owned by this demo.'
    }
    foreach ($endpoint in @(
        @{ Ip = $context.clientPrivateIp; Prefix = $context.clientSubnetPrefix },
        @{ Ip = $context.workloadPrivateIp; Prefix = $context.workloadSubnetPrefix }
    )) {
        $range = Get-PrivateCidrRange -Prefix $endpoint.Prefix
        $address = [System.Net.IPAddress]::None
        if ($endpoint.Ip -notmatch '^(?:\d{1,3}\.){3}\d{1,3}$' -or
            -not [System.Net.IPAddress]::TryParse([string]$endpoint.Ip, [ref]$address)) {
            throw 'Deployment context endpoint must be a valid IPv4 address.'
        }
        $value = ConvertTo-IPv4Number -Address $address
        if ($value -lt ($range.Start + 4) -or $value -ge $range.End) {
            throw 'Deployment context endpoint is not a usable address in its recorded private subnet.'
        }
    }
    return $context
}

function Get-OutputValue {
    param(
        [Parameter(Mandatory)]$Outputs,
        [Parameter(Mandatory)][string[]]$Names,
        [switch]$Required
    )
    foreach ($name in $Names) {
        $candidate = $null
        $found = $false
        if ($Outputs -is [System.Collections.IDictionary]) {
            $key = $Outputs.Keys | Where-Object { [string]$_ -ieq $name } | Select-Object -First 1
            if ($null -ne $key) {
                $candidate = $Outputs[$key]
                $found = $true
            }
        } else {
            $property = $Outputs.PSObject.Properties |
                Where-Object Name -ieq $name |
                Select-Object -First 1
            if ($property) {
                $candidate = $property.Value
                $found = $true
            }
        }
        if ($found) {
            if ($candidate -is [System.Collections.IDictionary] -and $candidate.Contains('value')) {
                return $candidate['value']
            }
            if ($candidate.PSObject.Properties['Value']) {
                return $candidate.Value
            }
            return $candidate
        }
    }
    if ($Required) {
        throw "Deployment output not found. Expected one of: $($Names -join ', ')."
    }
    return $null
}

function New-EvidencePath {
    param(
        [Parameter(Mandatory)][string]$Prefix,
        [string]$EvidenceDirectory = (Join-Path (Get-ProjectRoot) 'evidence')
    )
    if (-not (Test-Path -LiteralPath $EvidenceDirectory)) {
        New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
    }
    Join-Path $EvidenceDirectory ('{0}-{1}.json' -f $Prefix, (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))
}

function Save-JsonEvidence {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Path
    )
    $InputObject | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
    Write-Host "Evidence saved: $Path"
}

function Invoke-DemoRunCommand {
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][string]$Script
    )
    $result = Invoke-AzVMRunCommand `
        -ResourceGroupName $ResourceGroupName `
        -VMName $VmName `
        -CommandId 'RunPowerShellScript' `
        -ScriptString $Script
    $messages = @($result.Value | ForEach-Object {
        [ordered]@{
            code = $_.Code
            level = $_.Level
            displayStatus = $_.DisplayStatus
            message = $_.Message
        }
    })
    [ordered]@{
        status = $result.Status
        messages = $messages
    }
}

function Test-RequiredCommand {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' is not available."
    }
}

function Assert-SafeDemoResourceGroup {
    param([Parameter(Mandatory)][string]$Name)
    if ($Name.Length -gt 40 -or $Name -cnotmatch '^rg-sre-network-demo(?:-[a-z0-9]+(?:-[a-z0-9]+)*)?$') {
        throw 'Refusing operation outside rg-sre-network-demo or its bounded lowercase suffix variants.'
    }
}

function Assert-DeploymentSubscription {
    param([Parameter(Mandatory)][string]$SubscriptionId)
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($SubscriptionId, [ref]$parsed) -or $parsed -eq [guid]::Empty) {
        throw 'Supply an explicit nonzero subscription GUID before execution.'
    }
    $azContext = Get-AzContext
    if (-not $azContext -or -not $azContext.Subscription -or
        $azContext.Subscription.Id -ine $SubscriptionId) {
        throw 'The authenticated Az PowerShell subscription does not match the requested deployment scope. Select it explicitly; this script never switches subscriptions.'
    }
}

function ConvertTo-IPv4Number {
    param([Parameter(Mandatory)][System.Net.IPAddress]$Address)
    if ($Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw 'Only IPv4 addresses are supported by this demo.'
    }
    $bytes = $Address.GetAddressBytes()
    [uint64]$bytes[0] * 16777216 + [uint64]$bytes[1] * 65536 + [uint64]$bytes[2] * 256 + [uint64]$bytes[3]
}

function Get-PrivateCidrRange {
    param([Parameter(Mandatory)][string]$Prefix)
    if ($Prefix -notmatch '^(?:\d{1,3}\.){3}\d{1,3}/\d{1,2}$') {
        throw 'Network prefixes must use canonical IPv4 CIDR notation.'
    }
    $parts = $Prefix.Split('/')
    $address = [System.Net.IPAddress]::None
    $length = [int]$parts[1]
    if ($length -lt 8 -or $length -gt 29 -or
        -not [System.Net.IPAddress]::TryParse($parts[0], [ref]$address)) {
        throw 'Private demo address spaces must be valid IPv4 prefixes between /8 and /29.'
    }
    $start = ConvertTo-IPv4Number -Address $address
    $size = [uint64][Math]::Pow(2, 32 - $length)
    $end = $start + $size - 1
    if ($start % $size -ne 0) {
        throw 'CIDR prefixes must start at their network address, not a host address.'
    }
    $privateRanges = @(
        @{ Start = [uint64]167772160; End = [uint64]184549375 },
        @{ Start = [uint64]2886729728; End = [uint64]2887778303 },
        @{ Start = [uint64]3232235520; End = [uint64]3232301055 }
    )
    if (-not @($privateRanges | Where-Object { $start -ge $_.Start -and $end -le $_.End }).Count) {
        throw 'Use only RFC1918 private address spaces for this synthetic demo.'
    }
    [pscustomobject]@{ Start = $start; End = $end; PrefixLength = $length }
}

function Assert-DemoNetworkPrefixes {
    param(
        [Parameter(Mandatory)][string]$ClientVnetPrefix,
        [Parameter(Mandatory)][string]$ClientSubnetPrefix,
        [Parameter(Mandatory)][string]$WorkloadVnetPrefix,
        [Parameter(Mandatory)][string]$WorkloadSubnetPrefix
    )
    $client = Get-PrivateCidrRange $ClientVnetPrefix
    $workload = Get-PrivateCidrRange $WorkloadVnetPrefix
    if ($client.Start -le $workload.End -and $workload.Start -le $client.End) {
        throw 'Client and workload VNet address spaces must not overlap.'
    }
    foreach ($pair in @(
        @{ Vnet = $client; Subnet = (Get-PrivateCidrRange $ClientSubnetPrefix) },
        @{ Vnet = $workload; Subnet = (Get-PrivateCidrRange $WorkloadSubnetPrefix) }
    )) {
        if ($pair.Subnet.Start -lt $pair.Vnet.Start -or $pair.Subnet.End -gt $pair.Vnet.End) {
            throw 'Each subnet must be contained within its corresponding VNet.'
        }
    }
}
