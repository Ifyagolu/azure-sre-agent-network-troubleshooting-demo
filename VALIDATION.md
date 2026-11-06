# Validation

Local checks validate syntax and contracts, not Azure deployment or service behavior. Live acceptance remains a separate, explicitly approved operator activity.

## Local/static gate

```powershell
.\scripts\test-local.ps1
```

- [ ] All PowerShell files and embedded guest scripts parse.
- [ ] All Bicep files build locally; parameter compilation uses a synthetic test credential only.
- [ ] CIDR containment/non-overlap and private-address validation reject invalid inputs.
- [ ] Generic names, event-source writers, DCR XPath, health KQL, VM scope, and context outputs remain coordinated.
- [ ] Dry runs with synthetic context make no Azure calls; mutation confirmations and exact-name guards remain intact.
- [ ] Publication scan finds no customer branding, credential literals, or unexplained tenant identifiers in publishable text.
- [ ] Local document links resolve; retired internal artifacts are absent.
- [ ] Ignore patterns cover deployment context, evidence, local parameters, compiled JSON, environment/key material, logs and archives; the actual parameter template remains available.

The validator never reads or rewrites the real runtime context. It creates and removes only ignored synthetic validation files inside this repository.

## Before live deployment

- [ ] Dedicated group, explicit subscription, operator permissions, and cost approval confirmed.
- [ ] Providers registered through a separate approved process.
- [ ] Selected-region image/version, VM SKU, family vCPU quota, and service availability verified.
- [ ] Agent availability, residency, and onboarding verified separately.
- [ ] Standard public-IP egress accepted, or an alternative explicitly designed and validated.
- [ ] Shared watcher ownership/group permissions confirmed.
- [ ] Retention and daily cap accepted; cap will not interrupt required evidence.
- [ ] Password supplied only in the process environment and never in outputs/logs.
- [ ] ARM validation and exact-scope what-if reviewed before typed deployment approval.

## Infrastructure

- [ ] Both peered VNets/subnets/NSGs exist; peering is connected.
- [ ] Actual private addresses and all new scope IDs are captured from outputs in ignored local context.
- [ ] Both Windows VMs, guest agents, bootstrap extensions, and AMA are healthy.
- [ ] IIS/W3SVC runs on the workload and responds locally.
- [ ] No public inbound RDP/HTTP rule exists.
- [ ] DCR uses `windowsEventLogs`, `Microsoft-Event`, and the `SRE-Network-Demo` XPath.
- [ ] Destination-scoped `Event` health samples contain `demo_health` and `iis_state=running`.

## Flow telemetry

- [ ] Both enabled flow logs target VNets, not NSGs, and use the intended Storage/workspace.
- [ ] Group-derived flow names do not collide with another lab's logs.
- [ ] Traffic Analytics uses 10-minute processing; actual latency is measured.
- [ ] `NTANetAnalytics | getschema` and recent sample queries succeed with nonempty results.
- [ ] Endpoint, protocol, time, action/counter, and ACL fields/types are reviewed.
- [ ] Optional `FlowStatus` is used only after live semantic validation.
- [ ] Flow/interval timestamps match the test window; ingestion time is not treated as event time.
- [ ] Related observations from both VNets/monitor probes are not counted as unique HTTP requests.

## Scenario acceptance

For each scenario preserve exact UTC times and local evidence.

- [ ] Healthy: attempts occur, TCP/HTTP failures are zero, matching flows and running health events arrive.
- [ ] NSG failure: only the demo priority-100 deny is added; fresh attempts fail while IIS remains healthy; matching denied flows and rule context correlate.
- [ ] NSG recovery: only the exact injected rule is removed; new requests and post-recovery evidence succeed.
- [ ] Application failure: demo deny is absent, allow/peering remain valid, operator-approved Run Command proves W3SVC stopped, and destination health events confirm it.
- [ ] Application conclusion distinguishes policy allow from service health; absent flows are labeled incomplete.
- [ ] Application recovery: separately approved service start proves running/HTTP 200; fresh client requests and evidence succeed.
- [ ] Telemetry scripts fail explicitly for missing required flow or health evidence; schema validation needs both schema and samples.

Follow [DEMO.md](./DEMO.md); do not infer an NSG deny from timeout or missing records.

## Optional Connection Monitor

- [ ] Local dry run makes no Azure calls.
- [ ] Additive-only what-if changes only the source extension if needed, monitor, and deployment records.
- [ ] Existing watcher, workspace, current endpoints, and source AMA are verified.
- [ ] Healthy source Network Watcher extension is reused; conflicting/unhealthy extensions are not overwritten.
- [ ] No destination listener/extension, NSG, IIS, AMA, DCR, or workspace redesign occurs.
- [ ] Monitor outputs include ID/URL/breadcrumb and group-derived name.
- [ ] TCP/80, 30-second probes, 10% failed checks and 100 ms RTT are workshop settings, not an SLA.
- [ ] Multiple healthy, failed, and recovered samples are visible in appropriate time windows; allow propagation/portal delay.
- [ ] RTT may be absent when probes fail; missing data/topology alone does not attribute an NSG denial.
- [ ] Live `NWConnectionMonitorTestResult` and `NWConnectionMonitorPathResult` schemas are inspected.
- [ ] HTTP and passive flow/application checks remain independent.
- [ ] Agent monitor access is separately scoped; no service-managed DCR is changed.
- [ ] Exact monitor cleanup is separately approved before baseline deletion.

## Azure SRE Agent

- [ ] Effective identity roles are minimal; no unintended subscription contributor permissions remain.
- [ ] Review mode, global write/guest-execution denies, and no OBO/allow-hook override are verified.
- [ ] Agent reads demo configuration and scoped flow/health/optional monitor evidence.
- [ ] Agent cannot change NSGs, restart services, invoke VM Run Command, or remediate.
- [ ] Responses use all four evidence labels, exact scope/window, citations, confidence and evidence gaps.

## Cleanup and publication

- [ ] Exact resources and ownership are reviewed before irreversible typed confirmation.
- [ ] Optional monitor, demo flow logs, demo role assignments, dedicated group, and separately created agent resources are handled in the approved order.
- [ ] Shared watcher/group and providers remain intact; no orphaned lab charges remain.
- [ ] Real context, evidence, local parameters and secrets are excluded from the actual publication payload.
- [ ] A suitable reuse license is selected before public distribution.
