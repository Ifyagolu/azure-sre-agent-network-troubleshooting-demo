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
if (-not (Assert-Execute -Execute $Execute -Operation "stop IIS W3SVC on $($context.workloadVmName)")) { return }
Assert-DeploymentSubscription -SubscriptionId $context.subscriptionId
Confirm-ExactText -Prompt 'This intentionally stops the demo web application.' -Expected 'STOP IIS' -Confirmation $Confirmation

$nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $context.resourceGroupName -Name $context.workloadNsgName
if ($nsg.SecurityRules.Name -contains 'Deny-Client-To-Web-Demo') {
    throw 'The Scenario A deny rule is still present. Restore the network before Scenario B.'
}
$allow = $nsg.SecurityRules | Where-Object {
    $_.Access -eq 'Allow' -and $_.Direction -eq 'Inbound' -and
    $_.DestinationPortRange -eq '80'
}
if (-not $allow) { throw 'No baseline inbound allow rule for TCP/80 was found.' }

$start = (Get-Date).ToUniversalTime()
$script = @'
$ErrorActionPreference = 'Stop'
$service = Get-Service -Name W3SVC
if ($service.Status -ne 'Running') {
    throw "W3SVC must be running before Scenario B; current state is $($service.Status)."
}
Stop-Service -Name W3SVC -Force
$service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(30))
$service.Refresh()
if ($service.Status -ne 'Stopped') {
    throw "W3SVC did not stop; current state is $($service.Status)."
}
Write-EventLog -LogName Application -Source 'SRE-Network-Demo' -EventId 2001 -EntryType Warning `
    -Message "demo_health scenario=application_failure iis_state=stopped utc=$([DateTime]::UtcNow.ToString('o'))"
Write-Output "summary service=W3SVC state=$($service.Status.ToString().ToLowerInvariant())"
'@
$result = Invoke-DemoRunCommand `
    -ResourceGroupName $context.resourceGroupName `
    -VmName $context.workloadVmName `
    -Script $script
$runCommandText = (@($result.messages | ForEach-Object { $_.message }) -join "`n")
if ($runCommandText -notmatch 'summary\s+service=W3SVC\s+state=stopped') {
    throw 'Application failure Run Command did not prove that W3SVC is stopped.'
}
$evidence = [ordered]@{
    scenario = 'application-failure'
    stopUtc = $start.ToString('o')
    workloadVmName = $context.workloadVmName
    workloadPrivateIp = $context.workloadPrivateIp
    denyRuleAbsent = $true
    baselineAllowRules = @($allow.Name)
    serviceName = 'W3SVC'
    serviceState = 'stopped'
    runCommand = $result
}
Save-JsonEvidence $evidence (New-EvidencePath -Prefix 'application-failure-created' -EvidenceDirectory $EvidenceDirectory)
