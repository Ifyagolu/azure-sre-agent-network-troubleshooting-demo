[CmdletBinding()]
param(
    [string]$ContextPath = (Join-Path $PSScriptRoot 'deployment-context.json'),
    [string]$QueryFile = (Join-Path (Split-Path -Parent $PSScriptRoot) 'queries\client-connectivity-investigation.kql'),
    [Parameter(Mandatory)][datetime]$TestStartUtc,
    [Parameter(Mandatory)][datetime]$TestEndUtc,
    [ValidateRange(1, 75)][int]$TimeoutMinutes = 75,
    [ValidateRange(10, 300)][int]$PollSeconds = 120,
    [ValidateRange(0, 30)][int]$MarginMinutes = 5,
    [string]$EvidenceDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'evidence'),
    [switch]$ActionValidated,
    [switch]$FlowStatusValidated,
    [switch]$Execute
)

. (Join-Path $PSScriptRoot 'Common.ps1')
$context = Get-DeploymentContext -Path $ContextPath
if (-not (Test-Path -LiteralPath $QueryFile -PathType Leaf)) { throw "Query not found: $QueryFile" }
if ($TestEndUtc.ToUniversalTime() -lt $TestStartUtc.ToUniversalTime()) {
    throw 'TestEndUtc must not precede TestStartUtc.'
}
if (-not (Assert-Execute -Execute $Execute -Operation "poll telemetry for at most $TimeoutMinutes minutes")) { return }
Assert-DeploymentSubscription -SubscriptionId $context.subscriptionId

$query = Get-Content -LiteralPath $QueryFile -Raw
$windowStart = $TestStartUtc.ToUniversalTime().AddMinutes(-$MarginMinutes)
$windowEnd = $TestEndUtc.ToUniversalTime().AddMinutes($MarginMinutes)
$query = $query.
    Replace('__SOURCE_IP__', [string]$context.clientPrivateIp).
    Replace('__DESTINATION_IP__', [string]$context.workloadPrivateIp).
    Replace('__START_UTC__', $windowStart.ToString('o')).
    Replace('__END_UTC__', $windowEnd.ToString('o'))
$query = $query.
    Replace(
        'let ActionValidated = false;',
        ('let ActionValidated = {0};' -f $ActionValidated.ToString().ToLowerInvariant())
    ).
    Replace(
        'let FlowStatusValidated = false;',
        ('let FlowStatusValidated = {0};' -f $FlowStatusValidated.ToString().ToLowerInvariant())
    )
$deadline = (Get-Date).ToUniversalTime().AddMinutes($TimeoutMinutes)
$attempts = [System.Collections.Generic.List[object]]::new()
$lastResponse = $null
$matched = $false

do {
    $attemptUtc = (Get-Date).ToUniversalTime()
    try {
        $response = Invoke-AzOperationalInsightsQuery -WorkspaceId $context.workspaceCustomerId -Query $query
        $lastResponse = @($response.Results)
        $attempts.Add([ordered]@{
            attemptedAtUtc = $attemptUtc.ToString('o')
            resultCount = $lastResponse.Count
            error = $null
        })
        if ($lastResponse.Count -gt 0) { $matched = $true; break }
    } catch {
        Write-Warning "Telemetry query failed: $($_.Exception.Message)"
        $lastResponse = $_.Exception.Message
        $attempts.Add([ordered]@{
            attemptedAtUtc = $attemptUtc.ToString('o')
            resultCount = 0
            error = $_.Exception.Message
        })
    }
    $remainingSeconds = [Math]::Floor(($deadline - (Get-Date).ToUniversalTime()).TotalSeconds)
    if ($remainingSeconds -le 0) { break }
    $sleepSeconds = [Math]::Min($PollSeconds, $remainingSeconds)
    Start-Sleep -Seconds $sleepSeconds
} while ((Get-Date).ToUniversalTime() -lt $deadline)

$report = [ordered]@{
    telemetryMatched = $matched
    conclusion = if ($matched) { 'Matching records arrived; inspect evidence classification.' } else { 'Network-flow validation is incomplete. No allow or deny is inferred.' }
    workspaceCustomerId = $context.workspaceCustomerId
    sourceIp = $context.clientPrivateIp
    destinationIp = $context.workloadPrivateIp
    destinationPort = 80
    actionFieldValidated = [bool]$ActionValidated
    flowStatusFieldValidated = [bool]$FlowStatusValidated
    testStartUtc = $TestStartUtc.ToUniversalTime().ToString('o')
    testEndUtc = $TestEndUtc.ToUniversalTime().ToString('o')
    queryWindowStartUtc = $windowStart.ToString('o')
    queryWindowEndUtc = $windowEnd.ToString('o')
    table = 'NTANetAnalytics'
    attempts = $attempts
    lastResponse = $lastResponse
}
Save-JsonEvidence $report (New-EvidencePath -Prefix 'telemetry-wait' -EvidenceDirectory $EvidenceDirectory)
if (-not $matched) { throw $report.conclusion }
$lastResponse | Format-Table -AutoSize
