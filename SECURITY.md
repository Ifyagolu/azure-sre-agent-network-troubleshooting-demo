# Security and safety

## Lab scope

Use a dedicated non-production resource group, synthetic RFC1918 addresses, and no production data or topology. This public sample is not a hardened production deployment.

## Credentials and local state

- The VM password is supplied only through process environment variable `AZURE_VM_ADMIN_PASSWORD` into a secure Bicep parameter. Clear it after deployment.
- Do not publish passwords, keys, tokens, connection strings, resolved parameter JSON, or credential-bearing transcripts.
- Never commit or upload `scripts/deployment-context.json`. It contains real identifiers and private topology, is permanently ignored, and is absent from a clean checkout.
- Generated evidence also contains identifiers and diagnostic results. Keep it local under ignored paths; custom output paths must be excluded too.
- The Bicep parameter template contains an environment-variable binding, not a password literal. Keep the template in source control; local copies use `*.local.bicepparam`.
- Ignore rules do not prevent forced additions, already tracked files, or manual ZIP/folder uploads. Inspect the actual publication payload and scan it before publishing.

## Operator safety

Scripts make no Azure calls without `-Execute`. Deployment additionally requires an explicit subscription ID, and context-dependent scripts validate the recorded subscription before Azure operations. Scripts never switch subscriptions.

Mutation scripts require exact typed confirmation. Resource-group names are constrained to `rg-sre-network-demo` and bounded lowercase suffix variants. Context validation checks resource IDs, owned flow-log names, and usable private endpoint addresses. Cleanup additionally checks demo ownership tags and flow-log target VNets.

Do not relax these checks to reuse a stale context or act on another environment. Regenerate context from the generic deployment's outputs.

## Agent least privilege

- Reader on the dedicated demo group.
- Log Analytics Reader on its workspace.
- Monitoring Reader only after demonstrated need.
- Separately reviewed Reader on an optional exact Connection Monitor resource when necessary.
- No Contributor, Network Contributor, Monitoring Contributor, VM Contributor, or blanket subscription access for this baseline.
- Raw Storage blob access is not granted by default; deeper raw-log inspection needs separate scoped data-role approval.

Review effective assignments after onboarding. The preconfigured SRE Agent role bundle can include subscription-level Monitoring Contributor even when Reader is selected. Use manual scoped assignments and verify the result, rather than relying on the label.

## Agent tool controls

Use Review mode with global tool denies for write operations, Run Command/service control, and general shell/terminal/Python execution. Permit only required read tools and scoped queries.

Configure actual runtime tool names and arguments, not hypothetical tool labels. A read-oriented CLI tool must not provide an indirect route to `az vm run-command`.

Review mode and an instruction saying "do not remediate" are not security boundaries:

- Allow rules can bypass normal approval.
- User-defined allow hooks can override global denies.
- OBO can temporarily elevate using an administrator's permissions.

Do not install bypass hooks or authorize OBO write elevation for this lab. Optional active diagnostics require separate review, roles, and explicit human approval and remain outside the public baseline.

See [agent permissions](https://learn.microsoft.com/azure/sre-agent/permissions) and [tool policies](https://learn.microsoft.com/azure/sre-agent/tool-access-policies).

## Network and data exposure

Standard public IPs provide explicit egress; no public inbound RDP/HTTP rule is created. Traffic remains between the peered lab VNets. Verify guest firewall, platform connectivity, and egress policy without opening public inbound access to make the demo work.

Storage disables anonymous blob access and requires HTTPS/TLS 1.2, but enables shared-key access for the flow-log integration. Storage and workspace endpoints are public in the lab design. Private-endpoint/firewall hardening needs a separately validated design, not an untested switch.

Short raw-log/workspace retention and a daily cap reduce exposure/cost, but the cap can interrupt collection. Review SRE Agent residency, service data handling, and organizational requirements independently.

## Evidence model

Every conclusion separates **Observed Fact**, **Configuration Fact**, **Inference**, and **Recommendation**. State confidence, alternatives, and evidence gaps. Missing logs, absent RTT, or an incomplete topology are not proof of network denial.

Stopping/starting `W3SVC` and changing the one demo NSG deny are human-approved operator actions. The investigator must never perform them.

## Cleanup

Use [CLEANUP.md](./CLEANUP.md). Never delete the shared Network Watcher, its group, sibling monitors/flow logs, or provider registrations. Separately created agent resources require their own approved lifecycle and cleanup.
