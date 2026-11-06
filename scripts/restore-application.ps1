[CmdletBinding()]
param(
    [string]$ContextPath = (Join-Path $PSScriptRoot 'deployment-context.json'),
    [string]$EvidenceDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'evidence'),
    [switch]$Execute,
    [string]$Confirmation
)

. (Join-Path $PSScriptRoot 'Common.ps1')
$context = Get-DeploymentContext -Path $ContextPath
Assert-SafeDemoResourceGroup $context.resourceGroupName
if (-not (Assert-Execute -Execute $Execute -Operation "start IIS W3SVC on $($context.workloadVmName)")) { return }
Assert-DeploymentSubscription -SubscriptionId $context.subscriptionId
Confirm-ExactText -Prompt 'This restores the demo web application.' -Expected 'START IIS' -Confirmation $Confirmation

$script = @'
$ErrorActionPreference = 'Stop'
Start-Service -Name W3SVC
$service = Get-Service -Name W3SVC
$service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(30))
$service.Refresh()
if ($service.Status -ne 'Running') {
    throw "W3SVC did not start; current state is $($service.Status)."
}
$response = Invoke-WebRequest -Uri 'http://127.0.0.1/' -UseBasicParsing -DisableKeepAlive -TimeoutSec 15
if ($response.StatusCode -ne 200) {
    throw "Local IIS validation returned HTTP $($response.StatusCode)."
}
Write-EventLog -LogName Application -Source 'SRE-Network-Demo' -EventId 2002 -EntryType Information `
    -Message "demo_health scenario=application_restore iis_state=running utc=$([DateTime]::UtcNow.ToString('o'))"
Write-Output "summary service=W3SVC state=$($service.Status.ToString().ToLowerInvariant()) http_status=$($response.StatusCode)"
'@
$result = Invoke-DemoRunCommand `
    -ResourceGroupName $context.resourceGroupName `
    -VmName $context.workloadVmName `
    -Script $script
$runCommandText = (@($result.messages | ForEach-Object { $_.message }) -join "`n")
if ($runCommandText -notmatch 'summary\s+service=W3SVC\s+state=running\s+http_status=200') {
    throw 'Application restoration Run Command did not prove that IIS is healthy.'
}
$evidence = [ordered]@{
    scenario = 'application-restore'
    restorationUtc = (Get-Date).ToUniversalTime().ToString('o')
    workloadVmName = $context.workloadVmName
    serviceName = 'W3SVC'
    serviceState = 'running'
    httpStatus = 200
    runCommand = $result
}
Save-JsonEvidence $evidence (New-EvidencePath -Prefix 'application-restored' -EvidenceDirectory $EvidenceDirectory)
