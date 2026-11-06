# Deployment guide

Use an isolated, non-production scope. No command below runs automatically. `-Execute` is explicit authorization for that script's Azure calls; deployment and mutation scripts also require exact typed confirmation.

## 1. Local prerequisites and configuration

Use Windows PowerShell 5.1 or PowerShell 7 on Windows, standalone Bicep CLI, and Azure PowerShell modules listed in [README.md](./README.md). This repository does not promise a tested Linux execution path.

```powershell
.\scripts\test-local.ps1
.\scripts\test-prerequisites.ps1
Copy-Item .\infra\parameters.bicepparam .\infra\parameters.local.bicepparam
```

Edit the ignored local copy:

- `resourceGroupName`: `rg-sre-network-demo` or a lowercase alphanumeric/hyphen suffix, maximum 40 characters. Use a dedicated group, not one containing unrelated resources.
- `resourceLocation`: a region supporting the workload services. The agent region may be different.
- Client/workload VNet and subnet CIDRs: canonical, private, contained, non-overlapping.
- `vmSize`, `windowsImageVersion`: validate actual availability and quota. The image family remains Windows Server 2022 Datacenter Azure Edition.
- Storage name, log retention (30 days default), daily cap (1 GB default), raw retention (7 days default), and optional RBAC settings.

Keep the password binding unchanged. Do not write credentials to this copy or compile resolved parameter JSON for publication.

## 2. Explicit authentication and read-only preflight

Authenticate with Azure PowerShell, not only Azure CLI:

```powershell
Connect-AzAccount
$subscriptionId = Read-Host 'Enter your approved non-production subscription ID'
Set-AzContext -SubscriptionId $subscriptionId
.\scripts\test-prerequisites.ps1 -Execute -SubscriptionId $subscriptionId `
    -Location 'westcentralus' -VmSize 'Standard_D2as_v6' -WindowsImageVersion 'latest'
```

Match the preflight options to your local parameter file. The script reads Azure state; it does not register providers, assign roles, or switch subscriptions.

Required providers: `Microsoft.Network`, `Microsoft.Compute`, `Microsoft.Storage`, `Microsoft.OperationalInsights`, and `Microsoft.Insights`. Resolve missing registrations and quota through an approved operator process. Verify Windows image/extension availability, VM-family vCPU quota, egress requirements, and service support.

Regional watcher discovery uses the existing watcher when present, including a non-default watcher group. If absent, the template can create it after approval, but its group must already exist. Do not use the dedicated demo group for the shared watcher. Never delete shared watcher resources during cleanup.

Review cost and public-IP egress policy before proceeding. Retention/daily caps are not total spend limits and a cap can interrupt evidence collection.

## 3. Approved infrastructure deployment

Read the VM password without displaying it, convert it only for the process environment, and clear it afterward:

```powershell
$password = Read-Host 'Demo VM administrator password (at least 14 characters)' -AsSecureString
$credential = New-Object System.Management.Automation.PSCredential('demo', $password)
try {
    $env:AZURE_VM_ADMIN_PASSWORD = $credential.GetNetworkCredential().Password
    .\scripts\deploy.ps1 -Execute -SubscriptionId $subscriptionId `
        -ParameterFile .\infra\parameters.local.bicepparam
} finally {
    Remove-Item Env:\AZURE_VM_ADMIN_PASSWORD -ErrorAction SilentlyContinue
    $credential = $null
    $password = $null
}
```

Protect the process and avoid recording transcripts around credential handling. The deployment script compiles locally, validates the private network configuration and selected subscription, discovers the watcher, runs ARM validation and what-if, and then requires `DEPLOY <deployment-name>`.

`-Location` is an optional override; otherwise the local parameter file determines resource/deployment location. Review the exact scope and all planned resources. Do not approve an unexpected existing-resource modification.

Actual outputs are saved in ignored `scripts/deployment-context.json`. It records subscription/scope, dynamic private IPs, VM/VNet IDs, workspace GUID/resource ID, flow names, and role-assignment IDs. It is local deployment state, not an example. Refresh it only from this generic deployment's outputs:

```powershell
.\scripts\get-deployment-context.ps1 -Execute -DeploymentName '<your-deployment-name>'
```

Record the deployment name locally. If retaining several labs, pass distinct ignored context paths to context-dependent scripts. Old or unrelated context is deliberately rejected rather than silently retargeted.

Reference: [PowerShell Bicep deployment](https://learn.microsoft.com/azure/azure-resource-manager/bicep/deploy-powershell).
Current subscription-scope cmdlet references are [Test-AzDeployment](https://learn.microsoft.com/powershell/module/az.resources/test-azdeployment), [New-AzDeployment](https://learn.microsoft.com/powershell/module/az.resources/new-azdeployment), and [Get-AzDeployment](https://learn.microsoft.com/powershell/module/az.resources/get-azdeployment); scripts use their subscription-deployment aliases.

## 4. Infrastructure and evidence readiness

Follow [VALIDATION.md](./VALIDATION.md). Confirm peering, bootstrap, AMA/DCR, IIS, and both VNet flow logs. Generate healthy traffic only after approval; collect its UTC window and wait for schema/sample readiness.

```powershell
.\scripts\generate-good-traffic.ps1 -Execute
.\scripts\validate-kql-schema.ps1 -Execute
```

The traffic script requires `GENERATE GOOD TRAFFIC`. Schema validation must find both schema and sample records. Review fields and sample values yourself; the script does not automatically certify optional action/status semantics.

Use [DEMO.md](./DEMO.md) for exact test windows, bounded telemetry polling, and failure/restoration commands. Do not start a failure scenario while baseline evidence is incomplete.

## Configure Azure SRE Agent

1. Verify [agent regional availability](https://learn.microsoft.com/azure/sre-agent/supported-regions), onboarding, cost, and residency. The agent compute region does not restrict the region of resources it can investigate.
2. Create the agent manually through the current [setup workflow](https://learn.microsoft.com/azure/sre-agent/create-and-set-up). Avoid adding managed resource scopes or connector wizards that automatically grant broader roles.
3. Record its user-assigned managed identity's object/principal ID locally.
4. Grant only Reader on the dedicated demo group and Log Analytics Reader on its workspace. Add Monitoring Reader only if a demonstrated investigation requires it. The optional [RBAC module](./infra/rbac.bicep) supports these roles; do not redeploy the baseline to assign roles during a failure scenario. Apply reviewed assignments separately through IAM.
5. Inspect effective permissions. Microsoft's preconfigured agent setup can include subscription-level Monitoring Contributor even for Reader selection. Do not retain Contributor, Network Contributor, Monitoring Contributor, or VM Contributor for this baseline.
6. Use Review mode. Configure global denies for write tools, VM Run Command, service control, and generic shell/terminal/Python execution. Use actual runtime tool names from [tool policies](https://learn.microsoft.com/azure/sre-agent/tool-access-policies), including `RunAzCliWriteCommands`, `RunInTerminal`, `RunShellCommand`, and `ExecutePythonCode`. Read CLI tools must also exclude Run Command actions.
7. Do not authorize OBO write elevation or install user-defined allow hooks that bypass global denies. Review mode alone is not a permission boundary.
8. Configure `network-connectivity-investigator` with [these instructions](./agent/network-connectivity-investigator.md). No special direct Traffic Analytics connector is required for built-in workspace queries.
9. Verify the agent can query scoped `NTANetAnalytics`/`Event` and read demo configuration, and cannot perform remediation. Record the four evidence labels and evidence gaps.

Use [investigation prompts](./agent/investigation-prompts.md). Keep optional active diagnostics outside the baseline; [Microsoft's network investigation](https://learn.microsoft.com/azure/sre-agent/diagnose-azure-observability) can use guest Run Command in Active mode.

## Optional Connection Monitor

Use the separate entry point, never the main deployment:

```powershell
.\scripts\deploy-connection-monitor.ps1
# Only after approval:
.\scripts\deploy-connection-monitor.ps1 -Execute
```

Local mode needs a valid local deployment context but makes no Azure calls. Execute mode verifies subscription, existing watcher/workspace, current endpoint addresses, and healthy source AMA. It reuses a healthy source Network Watcher extension or installs it when absent, validates/what-ifs the incremental deployment, then requires:

```text
DEPLOY CONNECTION MONITOR sre-network-demo-connection-monitor
```

The monitor name derives from the demo group, for example `cm-sre-network-demo-client-to-iis`. Outputs remain on the resource-group deployment named `sre-network-demo-connection-monitor`; the baseline context is not overwritten. Save the output monitor ID locally.

No destination extension or synthetic listener is installed. TCP/80 probes run every 30 seconds; thresholds are workshop defaults, not service guarantees. Permit existing platform/extension connectivity as documented in [Network Watcher agent requirements](https://learn.microsoft.com/azure/network-watcher/network-watcher-agent-manage); no NSG or guest firewall repair is automated.

Operator permissions must cover incremental deployment in both groups, source-extension writes, monitor writes, and workspace access. These are not agent permissions. If the investigator needs monitor configuration/metrics, separately grant Reader on the exact monitor, with only demonstrated parent-read dependencies. Workspace Log Analytics Reader covers its result queries.

Validate multiple healthy/failed/recovered samples, schema-discover the two monitor result tables, and preserve independent HTTP/flow/event checks. Remove the exact monitor before baseline cleanup, as described in [CLEANUP.md](./CLEANUP.md).
