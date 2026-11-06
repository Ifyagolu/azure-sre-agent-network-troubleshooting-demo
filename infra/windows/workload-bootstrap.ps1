$ErrorActionPreference = 'Stop'

$eventSource = 'SRE-Network-Demo'
$healthDirectory = 'C:\ProgramData\SRE-Network-Demo'
$healthScriptPath = Join-Path $healthDirectory 'Emit-IisHealth.ps1'
$taskName = 'SRE-Network-Demo-IIS-Health'

Install-WindowsFeature -Name Web-Server -IncludeManagementTools
Set-Content `
    -LiteralPath 'C:\inetpub\wwwroot\index.html' `
    -Encoding utf8 `
    -Value '<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Azure SRE Agent Network Troubleshooting Demo</title></head><body><h1>sre-network-demo</h1><p>Windows IIS workload endpoint healthy</p></body></html>'

if (-not [System.Diagnostics.EventLog]::SourceExists($eventSource)) {
    New-EventLog -LogName Application -Source $eventSource
}

New-Item -ItemType Directory -Path $healthDirectory -Force | Out-Null
@'
$service = Get-Service -Name W3SVC
$state = if ($service.Status -eq 'Running') { 'running' } else { 'stopped' }
Write-EventLog `
    -LogName Application `
    -Source 'SRE-Network-Demo' `
    -EventId 2000 `
    -EntryType Information `
    -Message "demo_health scenario=application-health iis_state=$state utc=$([DateTime]::UtcNow.ToString('o'))"
'@ | Set-Content -LiteralPath $healthScriptPath -Encoding utf8

$taskAction = New-ScheduledTaskAction `
    -Execute 'PowerShell.exe' `
    -Argument "-NoLogo -NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"$healthScriptPath`""
$taskTrigger = New-ScheduledTaskTrigger `
    -Once `
    -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 1) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
Register-ScheduledTask `
    -TaskName $taskName `
    -Action $taskAction `
    -Trigger $taskTrigger `
    -User 'SYSTEM' `
    -RunLevel Highest `
    -Force | Out-Null

Set-Service -Name W3SVC -StartupType Automatic
Start-Service -Name W3SVC
& $healthScriptPath

$response = Invoke-WebRequest `
    -Uri 'http://127.0.0.1/' `
    -UseBasicParsing `
    -DisableKeepAlive `
    -TimeoutSec 15
if ($response.StatusCode -ne 200) {
    throw "IIS bootstrap validation returned HTTP $($response.StatusCode)."
}
