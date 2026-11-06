[CmdletBinding()]
param(
    [string]$ContextPath = (Join-Path $PSScriptRoot 'deployment-context.json'),
    [ValidateRange(10, 300)][int]$DurationSeconds = 180,
    [ValidateRange(1, 30)][int]$IntervalSeconds = 5,
    [string]$EvidenceDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'evidence'),
    [switch]$Execute,
    [string]$Confirmation
)

. (Join-Path $PSScriptRoot 'Common.ps1')
$context = Get-DeploymentContext -Path $ContextPath
$operation = "generate healthy TCP/80 traffic from $($context.clientVmName) to deployment output $($context.workloadPrivateIp)"
if (-not (Assert-Execute -Execute $Execute -Operation $operation)) { return }
Assert-DeploymentSubscription -SubscriptionId $context.subscriptionId
Confirm-ExactText -Prompt 'VM Run Command will generate synthetic RFC1918 traffic.' -Expected 'GENERATE GOOD TRAFFIC' -Confirmation $Confirmation

$testId = 'good-{0}' -f ([guid]::NewGuid().ToString('N'))
$start = (Get-Date).ToUniversalTime()
$script = @'
$ErrorActionPreference = 'Continue'
$eventSource = 'SRE-Network-Demo'
$end = [DateTime]::UtcNow.AddSeconds(__DURATION__)
$attempts = 0
$failures = 0
$tcpFailures = 0
$webFailures = 0

Write-EventLog -LogName Application -Source $eventSource -EventId 1100 -EntryType Information `
    -Message "demo_test scenario=healthy test_id=__TEST_ID__ state=start utc=$([DateTime]::UtcNow.ToString('o'))"

while ([DateTime]::UtcNow -lt $end) {
    $attempts++
    $connection = Test-NetConnection -ComputerName '__DEST__' -Port 80 -InformationLevel Detailed -WarningAction SilentlyContinue
    $tcpSucceeded = [bool]$connection.TcpTestSucceeded
    if (-not $tcpSucceeded) { $tcpFailures++ }

    $webSucceeded = $false
    try {
        $uri = "http://__DEST__:80/?test_id=__TEST_ID__&attempt=$attempts&nonce=$([guid]::NewGuid().ToString('N'))"
        $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -DisableKeepAlive -TimeoutSec 10
        $webSucceeded = $response.StatusCode -eq 200
    } catch {
        Write-Output "http_error=$($_.Exception.Message)"
        $webSucceeded = $false
    }
    if (-not $webSucceeded) { $webFailures++ }
    if (-not ($tcpSucceeded -and $webSucceeded)) { $failures++ }

    Write-Output "attempt=$attempts tcp_succeeded=$($tcpSucceeded.ToString().ToLowerInvariant()) web_succeeded=$($webSucceeded.ToString().ToLowerInvariant()) utc=$([DateTime]::UtcNow.ToString('o'))"
    Start-Sleep -Seconds __INTERVAL__
}

Write-EventLog -LogName Application -Source $eventSource -EventId 1101 -EntryType Information `
    -Message "demo_test scenario=healthy test_id=__TEST_ID__ state=end attempts=$attempts failures=$failures tcp_failures=$tcpFailures web_failures=$webFailures utc=$([DateTime]::UtcNow.ToString('o'))"
Write-Output "summary attempts=$attempts failures=$failures tcp_failures=$tcpFailures web_failures=$webFailures"
'@
$script = $script.Replace('__TEST_ID__', $testId).
    Replace('__DEST__', [string]$context.workloadPrivateIp).
    Replace('__DURATION__', [string]$DurationSeconds).
    Replace('__INTERVAL__', [string]$IntervalSeconds)
$result = Invoke-DemoRunCommand -ResourceGroupName $context.resourceGroupName -VmName $context.clientVmName -Script $script
$end = (Get-Date).ToUniversalTime()
$runCommandText = (@($result.messages | ForEach-Object { $_.message }) -join "`n")
$summaryMatch = [regex]::Match($runCommandText, 'summary\s+attempts=(\d+)\s+failures=(\d+)\s+tcp_failures=(\d+)\s+web_failures=(\d+)')
$attemptCount = if ($summaryMatch.Success) { [int]$summaryMatch.Groups[1].Value } else { $null }
$failureCount = if ($summaryMatch.Success) { [int]$summaryMatch.Groups[2].Value } else { $null }
$tcpFailureCount = if ($summaryMatch.Success) { [int]$summaryMatch.Groups[3].Value } else { $null }
$webFailureCount = if ($summaryMatch.Success) { [int]$summaryMatch.Groups[4].Value } else { $null }
$evidence = [ordered]@{
    scenario = 'healthy'
    testId = $testId
    sourceIp = $context.clientPrivateIp
    destinationIp = $context.workloadPrivateIp
    destinationPort = 80
    testStartUtc = $start.ToString('o')
    testEndUtc = $end.ToString('o')
    durationSeconds = $DurationSeconds
    attempts = $attemptCount
    failures = $failureCount
    tcpFailures = $tcpFailureCount
    webFailures = $webFailureCount
    runCommand = $result
}
Save-JsonEvidence $evidence (New-EvidencePath -Prefix $testId -EvidenceDirectory $EvidenceDirectory)
if (-not $summaryMatch.Success) { throw 'Healthy traffic Run Command output did not contain the required summary.' }
if ($attemptCount -le 0) { throw 'Healthy traffic Run Command reported no attempts.' }
if ($failureCount -gt 0) { throw "Healthy traffic Run Command reported $failureCount failed attempt(s)." }
