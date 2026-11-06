# Azure SRE Agent Network Troubleshooting Demo

`azure-sre-agent-network-troubleshooting-demo` is a reusable, synthetic Azure lab for **AI-assisted network investigation**. Start with a connectivity complaint, then correlate network flow evidence, NSG configuration, and application health using Azure SRE Agent.

The agent investigates and recommends. **It does not remediate, change NSGs, restart services, or execute VM Run Command.** Failure injection and restoration are separate, human-approved operator actions.

## What this demonstrates

- Azure SRE Agent querying Azure Monitor / Log Analytics with KQL.
- Azure Network Watcher **Virtual Network Flow Logs** and Traffic Analytics.
- NSG policy investigation across two peered virtual networks.
- Distinguishing an NSG denial from an unavailable IIS application.
- Optional, additive Connection Monitor TCP probes.
- Evidence-backed conclusions labeled **Observed Fact**, **Configuration Fact**, **Inference**, and **Recommendation**.

NSG Flow Logs are legacy: new creation stopped June 30, 2025, and retirement is September 30, 2027. This deployment targets **VNets, not NSGs**, for flow logging. Virtual Network Flow Logs are the forward-looking implementation.

## Architecture

```text
Client Windows VM ---- TCP/80 over VNet peering ---- Windows VM / IIS
       |                                                |
  Client VNet + NSG                                Workload VNet + NSG
       +---------- Virtual Network Flow Logs -----------+
                              |
                        Azure Storage
                              |
                       Traffic Analytics
                              |
                 Log Analytics: NTANetAnalytics
                              ^
          AMA + Windows Event Logs DCR -> Event
                              |
                    Azure SRE Agent queries
                    telemetry + configuration

Optional: Connection Monitor -> continuous TCP probes + workspace results
```

Defaults: two Windows Server 2022 Datacenter Azure Edition VMs, `Standard_D2as_v6`, client `10.10.0.0/16` / subnet `10.10.1.0/24`, workload `10.20.0.0/16` / subnet `10.20.1.0/24`. CIDRs and VM size are parameters. Private addresses are dynamic and always read from deployment outputs.

Each VM uses a Standard public IP for explicit outbound access; no public inbound RDP/HTTP rule is created. This is an isolated demonstration, not a production network blueprint. See [architecture](./architecture.md) and [security](./SECURITY.md).

## Prerequisites

- Windows with PowerShell 5.1 or PowerShell 7, a standalone Bicep CLI, and Azure PowerShell modules: `Az.Accounts`, `Az.Resources`, `Az.Compute`, `Az.Network`, `Az.OperationalInsights`.
- A dedicated non-production Azure scope, registered resource providers, sufficient quota, and regional availability for the selected image, VM SKU, VNet Flow Logs, Traffic Analytics, and Log Analytics.
- Azure SRE Agent availability/onboarding in your subscription and an approved agent region.
- Reviewed deployment permissions. Optional role assignment requires suitable IAM permissions; those are **operator**, not agent, permissions.
- Access to the regional Network Watcher group. If the watcher is absent, its group must already exist before deployment. Existing watchers are discovered and not redeployed.

Check the [deployment guide](./DEPLOYMENT.md) for authentication, configuration, costs, and agent setup.

## Deployment workflow

Start with local/static validation, then review readiness before enabling deployment:

| Command | Purpose | Azure impact |
|---|---|---|
| [`.\scripts\test-local.ps1`](./scripts/test-local.ps1) | Runs local/static repository validation, including code, Bicep, PowerShell and safety-contract checks. | None. Does not deploy resources or require live Azure changes. |
| [`.\scripts\test-prerequisites.ps1`](./scripts/test-prerequisites.ps1) | Performs pre-deployment readiness checks against the selected Azure environment. | Read-only Azure checks. Does not deploy the demo. |
| [`.\scripts\deploy.ps1`](./scripts/deploy.ps1) | Deploys the Azure SRE Agent network troubleshooting demo infrastructure using the repository's Bicep deployment. | Creates/configures Azure resources and can incur Azure charges. |

The Azure impacts above apply when Azure execution is explicitly enabled with `-Execute`. Without that switch, the prerequisite and deployment scripts perform local checks only. The commands shown below do not contact Azure or require an Azure login or VM password:

```powershell
.\scripts\test-local.ps1
.\scripts\test-prerequisites.ps1
```

Before enabling deployment, review [DEPLOYMENT.md](./DEPLOYMENT.md), confirm the correct Azure subscription/context, understand the resources being created, and configure the required secure environment variables.

```powershell
.\scripts\deploy.ps1
```

Create a local parameter copy, customize supported defaults, authenticate explicitly with Azure PowerShell, and select the intended subscription. Read-only Azure preflight and deployment are **separate opt-in operations**, described in [DEPLOYMENT.md](./DEPLOYMENT.md).

The administrator password must exist only in the deployment process as `AZURE_VM_ADMIN_PASSWORD`. The parameter template uses `readEnvironmentVariable('AZURE_VM_ADMIN_PASSWORD')` with a secure Bicep parameter. Never commit a resolved parameter JSON file or password.

After approved deployment, [get-deployment-context.ps1](./scripts/get-deployment-context.ps1) records actual outputs locally. `scripts/deployment-context.json` is **permanently ignored** and must never be uploaded. A clean checkout intentionally has no runtime context. Do not reuse a context from an earlier or unrelated deployment; regenerate it from the new generic deployment.

## Synthetic scenarios

| Scenario | Operator action | Required investigation |
|---|---|---|
| Healthy baseline | Generate new TCP and HTTP requests | Successful requests, matching flow records, workload health events |
| NSG denial | Add only `Deny-Client-To-Web-Demo`, inbound priority 100 | Denied flow evidence correlated with the matching policy/rule |
| Application unavailable | Stop IIS `W3SVC` while network policy stays permissive | Independent stopped-service events; allowed flow evidence if present |
| Recovery | Remove only the injected rule or start `W3SVC` | Fresh successful requests and post-recovery evidence |

See [DEMO.md](./DEMO.md). All operator Run Command and failure/restore scripts require `-Execute` and exact typed confirmation. Existing stateful connections may outlive an NSG change; generate new connections.

## Azure SRE Agent investigation

Configure the agent manually using [DEPLOYMENT.md](./DEPLOYMENT.md#configure-azure-sre-agent), then use [network-connectivity-investigator](./agent/network-connectivity-investigator.md) and [investigation prompts](./agent/investigation-prompts.md).

Provide actual source/destination IPs, TCP/80, the destination VM resource ID, and an exact UTC window. The agent reads telemetry and configuration and reports the four evidence labels plus evidence gaps. Least-privilege RBAC, global tool denies, Review mode, and no hook/OBO write elevation enforce the non-remediating baseline; prompts alone do not.

## KQL investigation

1. Run [schema discovery](./queries/schema-discovery.kql).
2. Inspect [unclassified sample records](./queries/sample-record-validation.kql).
3. Validate actual `Action`, counters, optional `FlowStatus`, ACL fields, and types.
4. Use [client connectivity investigation](./queries/client-connectivity-investigation.kql) and [application health](./queries/application-health.kql), replacing placeholders with current deployment outputs and UTC times.

The helper scripts bind placeholders, scope health evidence to the destination VM, and default optional action/state validation switches to false. Missing telemetry is **unknown**, never proof of denial.

Traffic Analytics uses a 10-minute processing interval, not a visibility guarantee. Records may arrive substantially later; [bounded polling](./scripts/wait-for-telemetry.ps1) stops after at most 75 minutes. Raw Storage logs remain the unaggregated evidence fallback.

## Optional Connection Monitor

[deploy-connection-monitor.ps1](./scripts/deploy-connection-monitor.ps1) uses a separate [entry point](./infra/connection-monitor.bicep). It installs the source Network Watcher extension only if needed and creates a monitor under the existing regional watcher.

It does **not** redeploy the baseline network, NSGs, VMs, IIS, AMA, DCRs, workspace, or flow logs. Do not redeploy the main template just to add monitoring or restore a failure scenario.

The TCP/80 test runs every 30 seconds with workshop thresholds of 10% failed checks and 100 ms RTT. It checks TCP reachability, not HTTP content health. Schema-discover `NWConnectionMonitorTestResult` and `NWConnectionMonitorPathResult` separately. See [deployment](./DEPLOYMENT.md#optional-connection-monitor), [validation](./VALIDATION.md), and [cleanup](./CLEANUP.md).

## Validation, cleanup, and publication

- [VALIDATION.md](./VALIDATION.md): local/static gates and separate live acceptance checks. Local compilation does not prove Azure deployment, telemetry arrival, or agent behavior.
- [CLEANUP.md](./CLEANUP.md): approval-gated exact-resource removal; preserve the shared watcher and provider registrations.
- [SECURITY.md](./SECURITY.md): credential handling, data boundaries, agent permissions, and publication controls.

Costs include Windows compute/disks, public IPs, Storage, VNet Flow Logs, Traffic Analytics, Log Analytics, Connection Monitor, and SRE Agent. Short retention and a workspace daily cap are safeguards, not guaranteed cost ceilings. Remove the lab and separately created agent resources when finished.

Before publishing, inspect the actual file payload, exclude all local context/evidence/parameters, and select an appropriate reuse license. Ignore rules do not protect manual folder uploads or forced Git additions.

## Microsoft references

- [Virtual Network Flow Logs](https://learn.microsoft.com/azure/network-watcher/vnet-flow-logs-overview) and [NSG Flow Logs retirement](https://learn.microsoft.com/azure/network-watcher/nsg-flow-logs-overview).
- [Traffic Analytics](https://learn.microsoft.com/azure/network-watcher/traffic-analytics), [aggregation/schema](https://learn.microsoft.com/azure/network-watcher/traffic-analytics-schema), and [NTANetAnalytics](https://learn.microsoft.com/azure/azure-monitor/reference/tables/ntanetanalytics).
- [Azure SRE Agent](https://learn.microsoft.com/azure/sre-agent/overview), [observability investigation](https://learn.microsoft.com/azure/sre-agent/diagnose-azure-observability), [permissions](https://learn.microsoft.com/azure/sre-agent/permissions), [tool policies](https://learn.microsoft.com/azure/sre-agent/tool-access-policies), and [regions](https://learn.microsoft.com/azure/sre-agent/supported-regions).
- [Windows event collection](https://learn.microsoft.com/azure/azure-monitor/vm/data-collection-windows-events), [AMA](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-manage), and [Event table](https://learn.microsoft.com/azure/azure-monitor/reference/tables/event).
- [Connection Monitor](https://learn.microsoft.com/azure/network-watcher/connection-monitor-overview) and [Network Watcher agent](https://learn.microsoft.com/azure/network-watcher/network-watcher-agent-manage).

Feature availability, portal labels, and permissions can change. Recheck official guidance before running the live workflow.
