# Architecture

## Evidence path

The baseline combines two peered VNets, Windows client/workload VMs, subnet NSGs, Virtual Network Flow Logs, Azure Storage, Traffic Analytics, Log Analytics, and Azure SRE Agent.

```text
Client VM -> private TCP/80 -> IIS workload VM
     |                            |
VNet + NSG                  VNet + NSG
     +------ VNet Flow Logs ------+
                    |
                 Storage
                    |
             Traffic Analytics
                    |
           NTANetAnalytics workspace
                    ^
      Windows AMA / DCR -> Event
                    |
       SRE Agent queries + ARM/Resource Graph reads
                    |
       Observed Fact / Configuration Fact /
       Inference / Recommendation
```

Traffic Analytics does not push telemetry to SRE Agent. The agent queries the workspace through managed identity and RBAC.

## Networking and guests

- Default client VNet/subnet: `10.10.0.0/16`, `10.10.1.0/24`.
- Default workload VNet/subnet: `10.20.0.0/16`, `10.20.1.0/24`.
- Parameters support canonical RFC1918 CIDRs; the deployment script validates containment, non-overlap, and a minimum subnet size of /29 before deployment.
- Bidirectional peering permits VNet access, without gateway transit or forwarded traffic.
- Both private IPs are dynamic; scripts consume actual deployment outputs, never expected `.4` addresses.
- Two Windows Server 2022 Datacenter Azure Edition VMs with a parameterized size and image version. The workload runs IIS/W3SVC; the client tests TCP and HTTP separately.
- Both NICs have Standard public IPs for explicit egress. Subnets disable default outbound access. No public inbound RDP or web rule is added.

This topology is a synthetic lab, not a hub/spoke, hybrid, firewall, or production policy reference architecture. If public IPs are prohibited, design and validate an explicit alternative egress path before deployment; that alternative is not implemented by a switch here.

## Resource ownership and naming

The dedicated group defaults to `rg-sre-network-demo`. A lowercase suffix permits multiple labs. Workspace, network, NSG, NIC, DCR, and flow-log names derive from the group. Short VM names `vm-sre-client` and `vm-sre-web` remain unique within their group and valid Windows computer names. Storage uses a bounded, globally unique name.

Flow logs are children of the regional Network Watcher, outside the dedicated group. Their group-derived names prevent collisions between labs sharing that watcher. Existing watchers are discovered and referenced; only an explicitly planned missing watcher is created, in an already existing group. Cleanup never deletes the shared watcher or its group.

## Passive network telemetry

[Virtual Network Flow Logs](https://learn.microsoft.com/azure/network-watcher/vnet-flow-logs-overview) target each VNet and write raw flow records to Standard Storage in the same region. [Traffic Analytics](https://learn.microsoft.com/azure/network-watcher/traffic-analytics) enriches and aggregates the records into `NTANetAnalytics`.

NSG Flow Logs are legacy: new creation stopped June 30, 2025; retirement is September 30, 2027. No new NSG Flow Logs are created by this repository.

The baseline retains flow-log format version 2 and 10-minute analytics processing. Newer format availability is not a reason to change a working evidence contract automatically. Regional capability, ingestion timing, and schema must be validated live.

Aggregation removes source-port detail and may combine observations across a processing window. Query flow/interval timestamps, not ingestion time alone. Records can take up to an hour to appear; bounded polling allows 75 minutes. Logging both VNets may produce related observations; do not interpret record counts as unique requests or packets.

Validate endpoint fields, `L4Protocol`, `Action`, allow/deny counters, optional `FlowStatus`, `AclGroup`, and `AclRule` before attributing a denial. Current protocol encodings include `T` for TCP. Raw logs remain an optional deeper-evidence source, requiring separately approved blob-data access.

## Application-health contract

The custom Windows Application event source is **`SRE-Network-Demo`** everywhere: bootstrap, generated health script, traffic writers, stop/start scripts, DCR XPath, and KQL.

| Event IDs | Meaning |
|---|---|
| 1000 | Client bootstrap ready |
| 1100 / 1101 | Healthy synthetic test start/end |
| 1200 / 1201 | Failure synthetic test start/end |
| 2000 | Workload health sample, emitted every minute |
| 2001 / 2002 | Operator-approved IIS stop/restore |

Health messages contain `demo_health`, `iis_state`, `scenario`, and UTC time. The `SRE-Network-Demo-IIS-Health` scheduled task runs a script beneath `C:\ProgramData\SRE-Network-Demo`.

AMA and a Windows Event Logs DCR collect this custom provider into `Event`; these are synthetic health markers, not a general IIS request-log collector. KQL filters the destination VM's `_ResourceId`, source, and UTC window. No event means unknown, not stopped.

## Scenarios and attribution

- Healthy: fresh TCP/HTTP tests succeed and matching flow plus application evidence arrives.
- NSG failure: the operator creates only `Deny-Client-To-Web-Demo`, inbound TCP/80 priority 100, above the priority-200 allow. Restore removes only this rule.
- Application failure: the injected deny is absent and an operator stops `W3SVC`. Correlate stopped-service evidence with network configuration and any matching allowed flows.

An allow policy decision is not proof of successful HTTP service. An NSG configuration read alone does not prove the historical outcome. Missing telemetry is always an evidence gap.

## Optional Connection Monitor

A separate incremental template installs the source `NetworkWatcherAgentWindows` extension only if absent and healthy-state checks allow it, then creates a group-derived monitor under the existing watcher. The TCP destination uses the real IIS listener, not a synthetic listener; no destination extension is required for this test.

Thirty-second probes and 10% failed-check / 100 ms RTT workshop thresholds provide continuous reachability evidence. They are not an SLA, application health test, or exact-rule attribution mechanism. Probe/portal/ingestion delays differ from Traffic Analytics.

Monitor configuration and metrics require separately reviewed access to the exact child resource. Workspace results use `NWConnectionMonitorTestResult` and `NWConnectionMonitorPathResult`. Keep the existing AMA/DCRs and do not modify service-managed ingestion resources.

## SRE Agent boundary

The baseline uses manual agent setup, least-privilege runtime roles, global tool denies, Review mode, and no OBO/hook write overrides. Azure SRE Agent is not deployed by the handcrafted Bicep.

Keep active guest diagnostics and Connection Troubleshoot outside the baseline. Built-in active network investigation can invoke guest Run Command and therefore must not be enabled by accident. See [DEPLOYMENT.md](./DEPLOYMENT.md), [SECURITY.md](./SECURITY.md), and [Microsoft's passive/active diagnostics guidance](https://learn.microsoft.com/azure/sre-agent/diagnose-azure-observability).
