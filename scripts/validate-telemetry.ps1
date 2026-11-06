[CmdletBinding()]
param(
    [string]$ContextPath = (Join-Path $PSScriptRoot 'deployment-context.json'),
    [Parameter(Mandatory)][datetime]$TestStartUtc,
    [Parameter(Mandatory)][datetime]$TestEndUtc,
    [string]$QueryDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'queries'),
    [string]$EvidenceDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'evidence'),
    [switch]$ActionValidated,
    [switch]$FlowStatusValidated,
    [switch]$Execute
)

. (Join-Path $PSScriptRoot 'Common.ps1')
$context = Get-DeploymentContext -Path $ContextPath
if ($TestEndUtc.ToUniversalTime() -lt $TestStartUtc.ToUniversalTime()) {
    throw 'TestEndUtc must not precede TestStartUtc.'
}
$files = @(
    'client-connectivity-investigation.kql',
    'application-health.kql'
)
foreach ($name in $files) {
    if (-not (Test-Path -LiteralPath (Join-Path $QueryDirectory $name) -PathType Leaf)) {
        throw "Required query not found: $name"
    }
}
if (-not (Assert-Execute -Execute $Execute -Operation 'query flow and application-health telemetry')) { return }
Assert-DeploymentSubscription -SubscriptionId $context.subscriptionId

$results = [ordered]@{}
foreach ($name in $files) {
    $text = Get-Content -LiteralPath (Join-Path $QueryDirectory $name) -Raw
    $text = $text.
        Replace('__SOURCE_IP__', [string]$context.clientPrivateIp).
        Replace('__DESTINATION_IP__', [string]$context.workloadPrivateIp).
        Replace('__WORKLOAD_VM_ID__', [string]$context.workloadVmId).
        Replace('__START_UTC__', $TestStartUtc.ToUniversalTime().ToString('o')).
        Replace('__END_UTC__', $TestEndUtc.ToUniversalTime().ToString('o'))
    if ($name -eq 'client-connectivity-investigation.kql') {
        $text = $text.
            Replace(
                'let ActionValidated = false;',
                ('let ActionValidated = {0};' -f $ActionValidated.ToString().ToLowerInvariant())
            ).
            Replace(
                'let FlowStatusValidated = false;',
                ('let FlowStatusValidated = {0};' -f $FlowStatusValidated.ToString().ToLowerInvariant())
            )
    }
    try {
        $response = Invoke-AzOperationalInsightsQuery -WorkspaceId $context.workspaceCustomerId -Query $text
        $results[$name] = [ordered]@{
            succeeded = $true
            recordCount = @($response.Results).Count
            records = @($response.Results)
            diagnostic = if (@($response.Results).Count) { $null } else { 'No matching telemetry. This does not imply deny.' }
        }
    } catch {
        Write-Warning "Query '$name' failed: $($_.Exception.Message)"
        $results[$name] = [ordered]@{
            succeeded = $false
            recordCount = 0
            records = @()
            diagnostic = $_.Exception.Message
        }
    }
}
$flowCount = $results['client-connectivity-investigation.kql'].recordCount
$healthCount = $results['application-health.kql'].recordCount
$report = [ordered]@{
    validatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    testStartUtc = $TestStartUtc.ToUniversalTime().ToString('o')
    testEndUtc = $TestEndUtc.ToUniversalTime().ToString('o')
    actionFieldValidated = [bool]$ActionValidated
    flowStatusFieldValidated = [bool]$FlowStatusValidated
    flowTelemetryComplete = $flowCount -gt 0
    applicationTelemetryComplete = $healthCount -gt 0
    conclusion = if ($flowCount -gt 0) { 'Flow records are available for evidence-based review.' } else { 'Network-flow validation is incomplete. No allow or deny is inferred.' }
    queryResults = $results
}
Save-JsonEvidence $report (New-EvidencePath -Prefix 'telemetry-validation' -EvidenceDirectory $EvidenceDirectory)
if ($flowCount -eq 0) { throw $report.conclusion }
if ($healthCount -eq 0) { throw 'Application-health validation is incomplete. No stopped/running state is inferred from missing events.' }
