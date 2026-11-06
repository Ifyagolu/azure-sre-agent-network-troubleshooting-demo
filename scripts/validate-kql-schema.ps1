[CmdletBinding()]
param(
    [string]$ContextPath = (Join-Path $PSScriptRoot 'deployment-context.json'),
    [string]$QueryDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'queries'),
    [string]$EvidenceDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'evidence'),
    [switch]$Execute
)

. (Join-Path $PSScriptRoot 'Common.ps1')
$context = Get-DeploymentContext -Path $ContextPath
$schemaFile = Join-Path $QueryDirectory 'schema-discovery.kql'
$sampleFile = Join-Path $QueryDirectory 'sample-record-validation.kql'
foreach ($file in @($schemaFile, $sampleFile)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Required query not found: $file" }
}

$schemaText = Get-Content -LiteralPath $schemaFile -Raw
$sampleText = Get-Content -LiteralPath $sampleFile -Raw
if ($schemaText -notmatch 'getschema' -or $sampleText -match '(?i)FlowStatus\s*(==|=~|in)') {
    throw 'Static KQL gate failed: schema discovery or sample validation is unsafe.'
}
Write-Host 'Static schema-query inspection succeeded.'
if (-not (Assert-Execute -Execute $Execute -Operation 'query live Log Analytics schema and sample records')) { return }
Assert-DeploymentSubscription -SubscriptionId $context.subscriptionId

$started = (Get-Date).ToUniversalTime()
$report = [ordered]@{
    checkedAtUtc = $started.ToString('o')
    workspaceCustomerId = $context.workspaceCustomerId
    tableReady = $false
    samplesReady = $false
    schema = $null
    sampleRecords = $null
    diagnostic = $null
}
try {
    $schema = Invoke-AzOperationalInsightsQuery -WorkspaceId $context.workspaceCustomerId -Query $schemaText
    $report.schema = @($schema.Results)
    $report.tableReady = @($schema.Results).Count -gt 0
    if ($report.tableReady) {
        $sample = Invoke-AzOperationalInsightsQuery -WorkspaceId $context.workspaceCustomerId -Query $sampleText
        $report.sampleRecords = @($sample.Results)
        $report.samplesReady = $report.sampleRecords.Count -gt 0
        if (-not $report.samplesReady) {
            $report.diagnostic = 'No live sample records are available. Field semantics remain unvalidated.'
        }
    } else {
        $report.diagnostic = 'NTANetAnalytics schema returned no columns. Table readiness is incomplete.'
    }
} catch {
    $report.diagnostic = "Schema query failed or table is absent: $($_.Exception.Message)"
    Write-Warning $report.diagnostic
}
$path = New-EvidencePath -Prefix 'kql-schema-validation' -EvidenceDirectory $EvidenceDirectory
Save-JsonEvidence $report $path
if (-not $report.tableReady -or -not $report.samplesReady -or $report.diagnostic) {
    throw 'KQL schema gate is incomplete. No allow/deny conclusion was made.'
}
