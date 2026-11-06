$ErrorActionPreference = 'Stop'

$eventSource = 'SRE-Network-Demo'
if (-not [System.Diagnostics.EventLog]::SourceExists($eventSource)) {
    New-EventLog -LogName Application -Source $eventSource
}

Write-EventLog `
    -LogName Application `
    -Source $eventSource `
    -EventId 1000 `
    -EntryType Information `
    -Message "demo_test scenario=client-bootstrap state=ready utc=$([DateTime]::UtcNow.ToString('o'))"
