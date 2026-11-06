# Demonstration walkthrough

## Preparation

Complete [deployment](./DEPLOYMENT.md) and the live gates in [VALIDATION.md](./VALIDATION.md). Use only synthetic traffic in the dedicated lab.

- Refresh local context from this deployment; never assume private addresses.
- Confirm both peerings, IIS/W3SVC, AMA/DCR, schema/sample readiness, and recent workload health events.
- Confirm the injected `Deny-Client-To-Web-Demo` rule is absent.
- Configure the read-only [network investigator](./agent/network-connectivity-investigator.md).
- Keep all evidence local. Every `-Execute` below is a separate operator-approved operation.

## Healthy baseline

```powershell
$start = [DateTime]::UtcNow
.\scripts\generate-good-traffic.ps1 -Execute
$end = [DateTime]::UtcNow
.\scripts\wait-for-telemetry.ps1 -Execute -TestStartUtc $start -TestEndUtc $end
.\scripts\validate-telemetry.ps1 -Execute -TestStartUtc $start -TestEndUtc $end
```

The traffic script requires `GENERATE GOOD TRAFFIC` and proves that attempts occurred with zero failures in both TCP and HTTP checks. Prefer the exact `testStartUtc`/`testEndUtc` in its local evidence for subsequent investigation; the surrounding timestamps above are a convenient wider window.

If telemetry is not ready, stop the demonstration and investigate collection, timing, schema, or cap issues. Only supply `-ActionValidated` or `-FlowStatusValidated` after actual values and semantics were reviewed. Counter evidence also requires live schema/sample review.

## Scenario A: NSG deny

```powershell
.\scripts\create-network-failure.ps1 -Execute
$start = [DateTime]::UtcNow
.\scripts\generate-bad-traffic.ps1 -Execute
$end = [DateTime]::UtcNow
.\scripts\wait-for-telemetry.ps1 -Execute -TestStartUtc $start -TestEndUtc $end
.\scripts\validate-telemetry.ps1 -Execute -TestStartUtc $start -TestEndUtc $end
```

Confirm `INJECT NETWORK FAILURE`, then `GENERATE BAD TRAFFIC` separately. The injected rule is inbound TCP/80 priority 100, from the actual client subnet to the workload private IP. It wins over the priority-200 baseline allow. Keep IIS running.

NSGs are stateful. Existing connections may continue after a rule change; judge new attempts. The failure traffic script proves failed attempts, not their network cause.

Ask the investigator, using actual deployment values:

> Investigate failed TCP/80 traffic from `<client-ip>` to `<workload-ip>` during `<start-utc>` through `<end-utc>`. The destination VM is `<workload-vm-resource-id>`. Query validated flow evidence and read the relevant network configuration. Do not modify resources or initiate active diagnostics.

Show:

1. **Observed Fact:** matching denied flow evidence, if it arrived.
2. **Configuration Fact:** the relevant NSG/ACL and matching deny rule.
3. **Inference:** attribution supported by those facts, with confidence and alternatives.
4. **Recommendation:** the next human action, not execution.

If matching records are missing or unclassified, show the evidence gap rather than asserting denial.

After separate restoration approval:

```powershell
.\scripts\restore-network.ps1 -Execute
.\scripts\generate-good-traffic.ps1 -Execute
```

Confirm `RESTORE NETWORK`, then separately approve healthy traffic. Only the exact injected demo rule is removed. Verify post-recovery flow and workload health evidence using a new UTC window.

## Scenario B: application unavailable

Confirm the demo deny is absent, the baseline allow/peering remains valid, and healthy TCP/HTTP traffic succeeds.

```powershell
.\scripts\create-application-failure.ps1 -Execute
$start = [DateTime]::UtcNow
.\scripts\generate-bad-traffic.ps1 -Execute
$end = [DateTime]::UtcNow
.\scripts\wait-for-telemetry.ps1 -Execute -TestStartUtc $start -TestEndUtc $end
.\scripts\validate-telemetry.ps1 -Execute -TestStartUtc $start -TestEndUtc $end
```

Confirm `STOP IIS`, then approve failure traffic separately. `Stop-Service W3SVC` is executed only by the operator's VM Run Command workflow, never by SRE Agent.

Use the same complaint, scoped to the new UTC window. Show permissive policy configuration, any matching allowed flow evidence, and destination-scoped `SRE-Network-Demo` events containing `demo_health` and `iis_state=stopped`.

An allowed network policy does not prove an HTTP application is serving. If no matching flow evidence arrives, report network-path validation as incomplete even when service unavailability is observed.

After separate approval:

```powershell
.\scripts\restore-application.ps1 -Execute
.\scripts\generate-good-traffic.ps1 -Execute
```

Confirm `START IIS`, then approve fresh healthy traffic. Verify `iis_state=running`, successful HTTP/TCP tests, and post-recovery flows.

## Optional Connection Monitor comparison

Deploy only through the [additive entry point](./DEPLOYMENT.md#optional-connection-monitor), starting from a healthy baseline.

1. Open the output portal URL and inspect `client-to-iis` / `TCP-80`.
2. Confirm multiple successful 30-second samples, expected endpoints, low failed checks, and nonempty RTT beneath the workshop threshold.
3. Run Scenario A once, record injection UTC time, and observe failed checks rising. Budget several minutes for visible transitions; this is not a guarantee.
4. Preserve separate HTTP tests and passive flow/health evidence. A TCP monitor alone cannot prove HTTP health or the exact denying rule.
5. Restore only the demo deny, verify new healthy requests and multiple post-recovery monitor samples.
6. Discover and query the live monitor result/path schemas. Missing topology hops or missing RTT are not independently proof of an NSG deny.

Connection Monitor probes can add flow observations even while the synthetic traffic scripts are idle. Correlate endpoints, direction, timestamps, and test scope rather than treating every record as a scripted request.

## Closing message

Azure exposes telemetry and configuration; the benefit is an evidence-backed investigation beginning with a user's complaint while humans retain all authority to change the environment. Finish with [approved cleanup](./CLEANUP.md).
