# Investigation prompts

## General connectivity complaint

> Client `<source-ip>` reports that it cannot connect to `<destination-ip>:<port>` over `<protocol>`. The destination VM resource ID is `<workload-vm-resource-id>`. Investigate the issue using existing Azure telemetry and read-only resource configuration. Use the UTC window `<start>` through `<end>`. Determine whether matching traffic was observed, how Azure network policy evaluated it, whether resource configuration explains the symptom, and what the operator should review next. Do not modify resources or run active diagnostics.

## NSG-deny demonstration

> Investigate failed TCP traffic from `<client-ip>` to `<workload-ip>:80` during `<utc-window>`. Query the validated live Traffic Analytics schema and inspect the relevant NSG configuration. Format the answer with explicit `Observed Fact`, `Configuration Fact`, `Inference`, and `Recommendation` headings, followed by evidence gaps. Missing telemetry is not evidence of denial. Do not remediate.

## Application-unavailable demonstration

> Investigate failed TCP traffic from `<client-ip>` to `<workload-ip>:80` during `<utc-window>`. Determine whether network policy appears permissive and inspect the Log Analytics `Event` table for `SRE-Network-Demo` health events scoped to `<workload-vm-resource-id>`, containing `demo_health` and `iis_state`. Format the answer with explicit `Observed Fact`, `Configuration Fact`, `Inference`, and `Recommendation` headings. Do not assume every failure is caused by an NSG. If matching flow telemetry is unavailable, state that network-path validation is incomplete. Do not invoke VM Run Command, restart the service, or modify resources.

## Follow-up evidence request

> List the exact Log Analytics records and Azure resource properties supporting your conclusion. Label every statement as `Observed Fact`, `Configuration Fact`, `Inference`, or `Recommendation`.
