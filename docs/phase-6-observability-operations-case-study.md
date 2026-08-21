<div align="center">

# Workstream 6: Observability and Operations
### Azure Monitor, Log Analytics, Container Insights, AKS Diagnostics, KQL, and Alerting

**Contoso Digital Services | Microsoft Azure | Azure Monitor | Log Analytics | AKS | KQL | Terraform**

</div>

---

> **Status:** Execution in progress. Two real implementation gaps were found and resolved during hands-on deployment (see **Implementation Issues and Resolutions** below). Final Results/Evidence tables should be updated once the full runbook — including the fresh Phase 5 telemetry run and action-group test — completes end to end.

## Executive Summary

Workstream 6 adds centralized observability to the existing EAAP platform after the successful GitHub-to-AKS deployment pipeline from Workstream 5.

The design adds a dedicated Log Analytics workspace, Container Insights on the existing AKS cluster, a Container Insights Data Collection Rule and association, AKS resource-specific control-plane diagnostics, an Azure Monitor action group, and practical KQL validation.

The successful Workstream 5 deployment pipeline is reused as a realistic telemetry generator: GitHub Actions authenticates through OIDC, pushes a new application image, updates AKS, and applies Kubernetes release objects while monitoring captures the resulting application and control-plane activity.

> **Target outcome:** EAAP should move from “the app is running” to “the platform can explain what changed, what the cluster observed, and what an engineer should investigate.”

---

## Workstream 5 Dependency

Workstream 6 assumes these Workstream 5 controls are already healthy:

```text
EAAP CI Validation                         PASS
EAAP Deploy to AKS                         PASS
GitHub OIDC → Entra application            PASS
ACR push                                   PASS
AKS authentication                         PASS
app-release.yaml deployment                PASS
Two Ready application pods                 PASS
AKS API allowlist restoration              PASS
```

The application deployment path now updates only:

```text
Deployment
Service
```

The platform baseline remains separately managed:

```text
Namespace
ServiceAccount
SecretProviderClass
Workload Identity / Key Vault integration
```

This separation is important for Workstream 6 because monitoring should observe the running application without changing the platform security baseline.

---

## Project Snapshot

| Category | Details |
|---|---|
| **Platform** | Microsoft Azure |
| **Business scenario** | Centralized monitoring and operational readiness for a CI/CD-managed AKS application |
| **Primary focus** | Container logs, pod inventory, Kubernetes events, control-plane diagnostics, KQL, notification path |
| **Key services** | Azure Monitor, Log Analytics, Container Insights, Data Collection Rules, AKS diagnostic settings, Action Groups |
| **Engineering tools** | Terraform, Azure CLI, KQL, kubectl, PowerShell, Git, GitHub Actions |
| **Deployment model** | Monitoring added to the existing EAAP Terraform state; Workstream 5 CD remains application-only |
| **Diagnostic mode** | Resource-specific Log Analytics tables (`AKSAudit`, `AKSAuditAdmin`, `AKSControlPlane`) |
| **Validation** | ContainerLogV2, KubeEvents, KubePodInventory, AKS control-plane data, action-group test, clean Terraform plan |

---

## Business Context

A successful deployment pipeline is not enough by itself.

Operations still needs durable answers to questions such as:

- Which application version was deployed?
- Did the new pods become Ready?
- Did any pods restart afterward?
- What did the application write to stdout/stderr?
- What Kubernetes API changes were made?
- Did the control plane report warnings?
- Can engineers correlate a GitHub deployment with AKS telemetry?
- Is there a notification path for future alerts?

Workstream 6 adds those day-two operational capabilities.

---

## Target Architecture

```mermaid
flowchart LR
    GH[GitHub Actions CD]
    ACR[Azure Container Registry]
    AKS[AKS Cluster]
    Pods[EAAP Application Pods]
    AMA[Container Insights / Azure Monitor Agent]
    DCR[Data Collection Rule]
    LAW[Log Analytics Workspace]
    DIAG[AKS Diagnostic Setting]
    KQL[KQL Investigation]
    AG[Action Group]
    Engineer[Cloud Engineer]

    GH -->|New release| ACR
    GH -->|kubectl apply| AKS
    ACR --> Pods
    AKS --> Pods

    Pods --> AMA
    AMA --> DCR
    DCR --> LAW

    AKS --> DIAG
    DIAG -->|Resource-specific logs| LAW

    LAW --> KQL
    KQL --> Engineer
    LAW --> AG
    AG --> Engineer
```

---

## What Will Be Implemented

### Dedicated Log Analytics Workspace

A dedicated operations workspace in:

```text
rg-eaap-operations-dev
```

provides the centralized log destination.

### Container Insights

Container Insights is enabled on the existing AKS resource in place.

Expected data includes:

- application stdout/stderr in `ContainerLogV2`
- Kubernetes inventory in `KubePodInventory`
- Kubernetes events in `KubeEvents`
- AKS monitoring views and inventory

### Container Insights Data Collection Rule

Enabling the AKS `oms_agent` add-on profile is necessary but not sufficient. A dedicated Data Collection Rule (DCR), targeting the `Microsoft-ContainerInsights-Group-Default` stream, and a Data Collection Rule Association bound to the AKS cluster are required for the modern Azure Monitor Agent–based collection path to actually ingest data. This gap — and how it was found — is documented in **Implementation Issues and Resolutions** below.

### Resource-Specific AKS Diagnostics

The AKS diagnostic setting uses:

```hcl
log_analytics_destination_type = "Dedicated"
```

so control-plane data lands in AKS-specific tables instead of the legacy catch-all `AzureDiagnostics` table.

Primary tables:

```text
AKSAudit
AKSAuditAdmin
AKSControlPlane
```

### CI/CD as a Telemetry Generator

After monitoring is enabled, run a fresh successful `EAAP Deploy to AKS` workflow.

This gives Workstream 6 a real operational event to investigate:

```text
GitHub OIDC login
ACR image publish
AKS API allowlist update
kubectl Deployment update
pod rollout
allowlist restoration
```

Kubernetes API changes from the release can then be correlated with audit/control-plane logs.

### Operational KQL

The validation queries focus on practical troubleshooting:

- recent application logs
- pod inventory and restart counts
- Kubernetes warnings/events
- Kubernetes API audit activity
- AKS control-plane messages

### Alerting Foundation

An Azure Monitor action group establishes the notification path that later metric and scheduled-query alerts can reuse.

---

## Key Engineering Decisions and Tradeoffs

| Decision | Rationale | Tradeoff |
|---|---|---|
| Reuse existing operations RG | Preserves the EAAP landing-zone boundary | Monitoring shares the operations lifecycle |
| Enable Container Insights in place | Adds observability without rebuilding AKS | Adds ingestion cost and agents |
| Explicitly declare the Container Insights DCR | Terraform's `oms_agent` block does not create it automatically; without it, no data is ever ingested regardless of agent health | One more resource to maintain outside the AKS resource itself |
| Use `ContainerLogV2` | Current container-log schema | Older examples may reference legacy tables |
| Use resource-specific AKS logs | Easier queries and better cost control than `AzureDiagnostics` | Queries differ from older tutorials |
| Reuse Phase 5 deployment as test activity | Validates monitoring against a real release path | Generates a controlled AKS change |
| Keep CD application-only | Preserves least privilege and platform baseline separation | Platform monitoring remains Terraform/workstation managed |
| Grant GitHub SP scoped `Log Analytics Contributor` | Enabling monitoring changes the linked-authorization requirements for any `az aks update` call, including the CD pipeline's allowlist steps | One more narrowly scoped role assignment to maintain alongside the existing ACR/AKS/subnet grants |
| Defer Managed Grafana | Keeps portfolio cost and complexity lower | No dedicated Grafana visualization layer yet |

---

## Implementation Issues and Resolutions

### Container Insights agent healthy but zero data ingested

**Issue:** After applying the `oms_agent` block and the AKS diagnostic setting, the `ama-logs` DaemonSet reported healthy Ready pods on every node, and `addonProfiles.omsagent` correctly referenced the workspace with `useAADAuth: true`. Despite this, `ContainerLogV2` and `KubePodInventory` returned zero rows even after well over an hour — beyond any reasonable first-time ingestion delay.

**Root cause:** `az monitor data-collection rule list` confirmed there was no Data Collection Rule in the platform resource group at all. Setting `oms_agent` on `azurerm_kubernetes_cluster` only configures the AKS add-on profile; it does not create the DCR and DCR association that tell the Azure Monitor Agent what to collect and where to send it. The Azure Portal performs this step automatically when monitoring is enabled through the UI — Terraform requires it to be declared explicitly.

**Resolution:** Added an `azurerm_monitor_data_collection_rule` targeting the `Microsoft-ContainerInsights-Group-Default` stream and an `azurerm_monitor_data_collection_rule_association` binding it to the AKS cluster. Verified the fix independently of query results, using `az monitor data-collection rule association list --resource <aksId>`, before re-attempting any KQL query.

**Lesson:** A healthy agent DaemonSet proves the agent is running, not that it has anywhere to send data. When Container Insights is enabled purely through Infrastructure as Code rather than the Portal, verify the Data Collection Rule association explicitly rather than inferring pipeline health from pod status alone.

### GitHub Actions CD pipeline broke after enabling monitoring

**Issue:** Re-running the Phase 5 `EAAP Deploy to AKS` workflow after Workstream 6 was applied failed at both the **Temporarily allow GitHub runner to AKS API** and **Restore original AKS authorized IP ranges** steps with `LinkedAuthorizationFailed`.

**Root cause:** Once AKS is linked to a Log Analytics workspace via Container Insights, Azure validates linked-resource authorization on every `az aks update` call, not only calls that touch monitoring settings directly. The GitHub Actions service principal already held `Microsoft.ContainerService/managedClusters/write`, but had no permission on the newly linked workspace, so both allowlist-update calls failed the `Microsoft.OperationalInsights/workspaces/sharedkeys/read` check. This is the same category of problem as the Phase 5 workload-subnet `subnets/join/action` requirement, just triggered against a different linked resource.

**Resolution:** Granted the GitHub Actions service principal `Log Analytics Contributor`, scoped to only the EAAP Log Analytics workspace — not a subscription- or resource-group-level grant — matching the existing least-privilege pattern used for the Phase 5 workload-subnet `Network Contributor` assignment.

**Lesson:** Enabling monitoring on a resource can silently change the permission surface required by anything else that manages that resource. A CI/CD identity that worked perfectly before a monitoring change can start failing for reasons that have nothing to do with its original RBAC design — the fix is to extend the same least-privilege pattern to the newly linked resource, not to broaden the identity's existing grants.

---

## Validation Plan

| Target | Validation |
|---|---|
| Operations workspace | `law-eaap-ops-dev-scus-001` exists |
| Container Insights | AKS monitoring add-on enabled |
| Data Collection Rule | `dcr-eaap-container-insights-dev-scus-001` exists and is associated with the AKS cluster |
| Application logs | `ContainerLogV2` returns `eaap-app` logs |
| Pod inventory | `KubePodInventory` returns EAAP pods |
| Kubernetes events | `KubeEvents` query executes and returns available events |
| Audit logs | `AKSAuditAdmin` / `AKSAudit` contain Kubernetes API activity |
| Control-plane logs | `AKSControlPlane` contains selected categories |
| Deployment correlation | Fresh Phase 5 deployment produces observable Kubernetes activity |
| GitHub Actions RBAC | CD pipeline succeeds end to end with monitoring enabled |
| Action group | Test notification path succeeds |
| Terraform state | Follow-up plan reports no unexpected changes |

---

## Evidence Plan

| Evidence | What It Proves | Screenshot |
|---|---|---|
| Log Analytics workspace | Central destination exists | `../../screenshots/phase-6/01-log-analytics-workspace.png` |
| AKS monitoring | Container Insights enabled | `../../screenshots/phase-6/02-aks-monitoring.png` |
| DCR association | Collection rule is bound to the cluster | `../../screenshots/phase-6/03-dcr-association.png` |
| Successful Phase 5 release | Monitoring is observing the real CD path | `../../screenshots/phase-6/04-phase5-deployment.png` |
| Container logs | Application logs centralized | `../../screenshots/phase-6/05-containerlogv2-query.png` |
| Pod inventory | EAAP pod state centralized | `../../screenshots/phase-6/06-pod-inventory-query.png` |
| Kubernetes events | Event query works | `../../screenshots/phase-6/07-kubeevents-query.png` |
| AKS audit/control-plane | Resource-specific AKS diagnostics present | `../../screenshots/phase-6/08-aks-diagnostics.png` |
| Action group | Notification path exists | `../../screenshots/phase-6/09-action-group.png` |
| Alert test | Notification path validated | `../../screenshots/phase-6/10-alert-test.png` |
| Clean plan | Monitoring configuration synchronized | `../../screenshots/phase-6/11-clean-plan.png` |

---

## Skills Demonstrated

`Azure Monitor` · `Log Analytics` · `Container Insights` · `AKS Monitoring` · `Diagnostic Settings` · `Data Collection Rules` · `Resource-Specific Logs` · `KQL` · `ContainerLogV2` · `AKSAudit` · `AKSControlPlane` · `KubeEvents` · `KubePodInventory` · `Terraform` · `GitHub Actions` · `Linked-Resource RBAC` · `Operational Troubleshooting`

---

## Repository Navigation

- **Detailed implementation:** [Workstream 6 Runbook](../../runbooks/phase-6-observability-operations-runbook.md)
- **Previous workstream:** [Workstream 5 — CI/CD Automation](../phase-5-cicd-automation/README.md)
- **Next workstream:** [Workstream 7 — Reliability and Recovery](../phase-7-reliability-recovery-case-study.md)
- **Project overview:** [Enterprise Azure Application Platform](../../README.md)
