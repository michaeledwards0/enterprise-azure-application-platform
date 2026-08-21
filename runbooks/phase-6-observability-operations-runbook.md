<div align="center">

# Workstream 6 Runbook: Observability and Operations
### Azure Monitor, Log Analytics, Container Insights, AKS Resource Logs, KQL, and Alerting

</div>

---

## Purpose

This execution-ready runbook adds centralized operational visibility to the EAAP platform after the successful Workstream 5 CI/CD deployment.

You will:

1. Confirm the final Workstream 5 deployment path is healthy.
2. Confirm Terraform is clean after the Phase 5 identity/FIC reconciliation.
3. Register monitoring resource providers.
4. Create a dedicated Log Analytics workspace.
5. Enable Container Insights on the existing AKS cluster in place.
6. Configure AKS resource-specific diagnostic logs.
7. Create the Container Insights Data Collection Rule and association.
8. Create an Azure Monitor action group.
9. Grant the GitHub Actions service principal access to the new workspace.
10. Run a fresh Phase 5 deployment as a realistic telemetry event.
11. Generate application traffic.
12. Query container logs, pod inventory, Kubernetes events, audit logs, and control-plane logs.
13. Validate the notification path.
14. Confirm Terraform remains synchronized.
15. Capture evidence.

> **Important Phase 5 dependency:** Workstream 6 does not replace or bypass the GitHub deployment pipeline. The pipeline remains application-only and continues to deploy `app-release.yaml`.

> **Execution note:** Steps 10, 12, and 18 below were added after hands-on execution surfaced two real gaps that the original design did not anticipate: enabling the `oms_agent` block alone does not create the Data Collection Rule that Container Insights actually needs to ingest data, and enabling monitoring changes the permission surface for anything that calls `az aks update` — including the Phase 5 GitHub Actions pipeline. See **Execution-Specific Engineering Decisions** at the end of this runbook for the full story.

---

## Target Resources

| Resource | Name | Location / Scope |
|---|---|---|
| Log Analytics workspace | `law-eaap-ops-dev-scus-001` | `rg-eaap-operations-dev` |
| AKS diagnostic setting | `diag-eaap-aks-dev` | Existing AKS cluster |
| Data Collection Rule | `dcr-eaap-container-insights-dev-scus-001` | `rg-eaap-platform-dev` |
| Data Collection Rule Association | `ContainerInsightsExtension` | Existing AKS cluster |
| Action group | `ag-eaap-platform-dev-scus-001` | `rg-eaap-operations-dev` |
| Container Insights | Existing AKS add-on | `aks-eaap-dev-scus-001` |
| Diagnostic destination | Resource-specific tables | Log Analytics |
| GitHub SP workspace role | `Log Analytics Contributor` | `law-eaap-ops-dev-scus-001` |

---

## Step 1 — Restore the Engineering Session

```powershell
cd "$HOME\Documents\enterprise-azure-application-platform"
code .
```

Confirm Azure:

```powershell
az account show `
  --query "{Name:name,State:state,IsDefault:isDefault,User:user.name,TenantId:tenantId}" `
  --output table
```

Restore Terraform subscription variables:

```powershell
$env:ARM_SUBSCRIPTION_ID = az account show --query id -o tsv
$env:AZURE_SUBSCRIPTION_ID = $env:ARM_SUBSCRIPTION_ID
```

---

## Step 2 — Confirm Workstream 5 Is Healthy

### GitHub

Confirm the latest:

```text
Actions
→ EAAP Deploy to AKS
```

completed successfully.

### AKS

Check power/provisioning state:

```powershell
az aks show `
  --resource-group "rg-eaap-platform-dev" `
  --name "aks-eaap-dev-scus-001" `
  --query "{PowerState:powerState.code,ProvisioningState:provisioningState}" `
  --output table
```

If stopped:

```powershell
az aks start `
  --resource-group "rg-eaap-platform-dev" `
  --name "aks-eaap-dev-scus-001"
```

Validate application state:

```powershell
kubectl get nodes
kubectl get deployment -n eaap-app
kubectl get pods -n eaap-app
kubectl get service -n eaap-app
```

Confirm the deployed manifest split still exists:

```powershell
Get-Item .\app\k8s\platform.yaml
Get-Item .\app\k8s\app-release.yaml
```

Do not continue until the application is healthy.

---

## Step 3 — Confirm the Phase 5 Terraform Baseline Is Clean

```powershell
cd .\terraform\environments\dev

terraform init -upgrade -reconfigure -backend-config="backend.hcl"
terraform validate
terraform plan
```

Expected:

```text
No changes. Your infrastructure matches the configuration.
```

If Phase 5 troubleshooting objects still exist outside Terraform, reconcile them before adding monitoring. Workstream 6 should start from a known state.

> **Windows note:** If any `az` command fails with a `WinError 5 Access is denied` traceback pointing at `.azure\cliextensions\`, an installed CLI extension (commonly `aks-preview`) has a locked or corrupted install. Close other open terminals, then run `az extension remove --name aks-preview` followed by `az extension add --name aks-preview`. This is a local tooling issue, not an Azure or Terraform problem.

---

## Step 4 — Register Monitoring Resource Providers

```powershell
az provider register --namespace Microsoft.OperationalInsights --wait
az provider register --namespace Microsoft.Insights --wait
az provider register --namespace Microsoft.Monitor --wait
az provider register --namespace Microsoft.AlertsManagement --wait
```

Verify:

```powershell
az provider list `
  --query "[?namespace=='Microsoft.OperationalInsights' || namespace=='Microsoft.Insights' || namespace=='Microsoft.Monitor' || namespace=='Microsoft.AlertsManagement'].{Provider:namespace,State:registrationState}" `
  --output table
```

Expected:

```text
Registered
```

---

## Step 5 — Create Monitoring Variables

Create:

```powershell
New-Item -ItemType File -Name "monitoring-variables.tf" -Force
code .\monitoring-variables.tf
```

Paste:

```hcl
variable "log_analytics_retention_days" {
  description = "Retention period for the EAAP Log Analytics workspace."
  type        = number
  default     = 30
}

variable "operations_alert_email" {
  description = "Email address used by the EAAP operations action group."
  type        = string
  sensitive   = true
}
```

In `terraform.tfvars.example`:

```hcl
operations_alert_email = "alerts@example.com"
```

In ignored `terraform.tfvars`:

```hcl
operations_alert_email = "<YOUR_REAL_EMAIL>"
```

---

## Step 6 — Create the Log Analytics Workspace

Create:

```powershell
New-Item -ItemType File -Name "monitoring.tf" -Force
code .\monitoring.tf
```

Paste:

```hcl
resource "azurerm_log_analytics_workspace" "platform" {
  name                = "law-eaap-ops-${var.environment}-scus-001"
  location            = azurerm_resource_group.landing_zone["operations"].location
  resource_group_name = azurerm_resource_group.landing_zone["operations"].name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_analytics_retention_days

  tags = merge(
    local.common_tags,
    {
      ResourcePurpose = "Platform-Observability"
    }
  )
}
```

---

## Step 7 — Enable Container Insights on the Existing AKS Resource

Open:

```powershell
code .\aks.tf
```

Inside the existing:

```hcl
resource "azurerm_kubernetes_cluster" "platform" {
```

add:

```hcl
  oms_agent {
    log_analytics_workspace_id      = azurerm_log_analytics_workspace.platform.id
    msi_auth_for_monitoring_enabled = true
  }
```

Do not create another AKS resource. Do not delete or restructure the existing `default_node_pool` block, and confirm the separate `azurerm_kubernetes_cluster_node_pool.apps` resource below the cluster block is still intact and untouched — it is easy to accidentally drop while editing this file.

The later plan should show an **in-place** update.

---

## Step 8 — Discover Available AKS Diagnostic Categories

Append to `monitoring.tf`:

```hcl
data "azurerm_monitor_diagnostic_categories" "aks" {
  resource_id = azurerm_kubernetes_cluster.platform.id
}

locals {
  desired_aks_log_categories = toset([
    "kube-apiserver",
    "kube-audit-admin",
    "kube-controller-manager",
    "kube-scheduler",
    "cluster-autoscaler"
  ])

  available_aks_log_categories = toset(
    data.azurerm_monitor_diagnostic_categories.aks.log_category_types
  )

  enabled_aks_log_categories = setintersection(
    local.desired_aks_log_categories,
    local.available_aks_log_categories
  )
}
```

Why `kube-audit-admin` instead of full `kube-audit` by default:

```text
kube-audit
= high-volume audit stream including many read operations

kube-audit-admin
= focuses on modifying operations
```

This is better aligned with a cost-conscious development portfolio.

---

## Step 9 — Create the AKS Diagnostic Setting

Append:

```hcl
resource "azurerm_monitor_diagnostic_setting" "aks" {
  name                           = "diag-eaap-aks-${var.environment}"
  target_resource_id             = azurerm_kubernetes_cluster.platform.id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.platform.id
  log_analytics_destination_type = "Dedicated"

  dynamic "enabled_log" {
    for_each = local.enabled_aks_log_categories

    content {
      category = enabled_log.value
    }
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
```

`Dedicated` sends AKS resource logs to resource-specific tables instead of the legacy `AzureDiagnostics` table.

Expected tables include:

```text
AKSAuditAdmin
AKSControlPlane
```

If you later enable full `kube-audit`, also expect `AKSAudit`.

---

## Step 10 — Create the Container Insights Data Collection Rule and Association

> **Why this step exists:** Setting the `oms_agent` block in Step 7 only configures the AKS add-on profile and deploys the `ama-logs` agent pods. It does **not** create the Data Collection Rule (DCR) that tells the agent what to collect or where to send it. Without this step, the agent pods run healthy indefinitely while `ContainerLogV2`, `KubePodInventory`, and every other Container Insights table stay completely empty. The Azure Portal creates this DCR automatically when you enable monitoring through the UI; Terraform does not, so it has to be declared explicitly.

Create:

```powershell
New-Item -ItemType File -Name "container-insights-dcr.tf" -Force
code .\container-insights-dcr.tf
```

Paste:

```hcl
resource "azurerm_monitor_data_collection_rule" "container_insights" {
  name                = "dcr-eaap-container-insights-${var.environment}-scus-001"
  resource_group_name = azurerm_resource_group.landing_zone["platform"].name
  location            = azurerm_resource_group.landing_zone["platform"].location

  destinations {
    log_analytics {
      workspace_resource_id = azurerm_log_analytics_workspace.platform.id
      name                  = "ciworkspace"
    }
  }

  data_flow {
    streams      = ["Microsoft-ContainerInsights-Group-Default"]
    destinations = ["ciworkspace"]
  }

  data_sources {
    extension {
      streams        = ["Microsoft-ContainerInsights-Group-Default"]
      extension_name = "ContainerInsights"
      extension_json = jsonencode({
        dataCollectionSettings = {
          interval               = "1m"
          namespaceFilteringMode = "Off"
          enableContainerLogV2   = true
        }
      })
      name = "ContainerInsightsExtension"
    }
  }

  tags = merge(
    local.common_tags,
    {
      ResourcePurpose = "Container-Insights-Collection-Rule"
    }
  )
}

resource "azurerm_monitor_data_collection_rule_association" "aks_container_insights" {
  name                     = "ContainerInsightsExtension"
  target_resource_id       = azurerm_kubernetes_cluster.platform.id
  data_collection_rule_id  = azurerm_monitor_data_collection_rule.container_insights.id
}
```

The `Microsoft-ContainerInsights-Group-Default` stream is the bundled stream Container Insights uses to populate `ContainerLogV2`, `KubePodInventory`, `KubeEvents`, `KubeNodeInventory`, and related tables in a single rule.

---

## Step 11 — Create the Operations Action Group

Create/append to `monitoring.tf`:

```hcl
resource "azurerm_monitor_action_group" "platform_operations" {
  name                = "ag-eaap-platform-${var.environment}-scus-001"
  resource_group_name = azurerm_resource_group.landing_zone["operations"].name
  short_name          = "eaapops"

  email_receiver {
    name                    = "Primary-Engineer"
    email_address           = var.operations_alert_email
    use_common_alert_schema = true
  }

  tags = merge(
    local.common_tags,
    {
      ResourcePurpose = "Platform-Alert-Notifications"
    }
  )
}
```

---

## Step 12 — Grant the GitHub Actions Service Principal Access to the Workspace

> **Why this step exists:** Once AKS is linked to a Log Analytics workspace, Azure validates "linked resource" authorization on **every** `az aks update` call — not just ones that touch monitoring. The Phase 5 CD pipeline calls `az aks update` twice per run (to temporarily allow the runner's IP, and to restore the original allowlist afterward). Without this role, both calls fail with `LinkedAuthorizationFailed` on `Microsoft.OperationalInsights/workspaces/sharedkeys/read`, breaking the CI/CD pipeline that Workstream 5 already validated.

Open:

```powershell
code .\cicd-identity.tf
```

Add, alongside the other `github_sp_*` role assignments:

```hcl
resource "azurerm_role_assignment" "github_sp_log_analytics_contributor" {
  scope                = azurerm_log_analytics_workspace.platform.id
  role_definition_name = "Log Analytics Contributor"
  principal_id         = azuread_service_principal.github_actions.object_id
}
```

This mirrors the same pattern used in Phase 5 for the workload-subnet `Network Contributor` grant: a narrowly scoped role on exactly the one linked resource the pipeline needs to touch, not a broad subscription-level grant.

---

## Step 13 — Add Monitoring Outputs

Create:

```powershell
New-Item -ItemType File -Name "monitoring-outputs.tf" -Force
code .\monitoring-outputs.tf
```

Paste:

```hcl
output "monitoring" {
  description = "EAAP monitoring resources."

  value = {
    log_analytics_workspace_name = azurerm_log_analytics_workspace.platform.name
    log_analytics_workspace_id   = azurerm_log_analytics_workspace.platform.id
    action_group_name            = azurerm_monitor_action_group.platform_operations.name
    aks_diagnostic_setting_name  = azurerm_monitor_diagnostic_setting.aks.name
    container_insights_dcr_name  = azurerm_monitor_data_collection_rule.container_insights.name
  }
}
```

---

## Step 14 — Format, Validate, and Plan

```powershell
terraform fmt -recursive
terraform validate
terraform plan -out=phase6.tfplan
terraform show phase6.tfplan
```

Expected general shape:

```text
Create:
- Log Analytics workspace
- AKS diagnostic setting
- Container Insights Data Collection Rule
- Container Insights Data Collection Rule Association
- Action group
- GitHub SP Log Analytics Contributor role assignment

Update in place:
- Existing AKS cluster to enable Container Insights
```

Stop immediately if Terraform proposes:

```text
-/+ azurerm_kubernetes_cluster.platform
```

or any AKS replacement, and stop if it proposes destroying `azurerm_kubernetes_cluster_node_pool.apps` — that means the node pool resource block is missing from the current configuration and must be restored before continuing.

---

## Step 15 — Apply Workstream 6

```powershell
terraform apply phase6.tfplan
```

Then:

```powershell
terraform output monitoring
```

Allow monitoring data time to begin flowing, and allow a few minutes for the new RBAC assignment to propagate.

---

## Step 16 — Verify Container Insights

```powershell
az aks show `
  --resource-group "rg-eaap-platform-dev" `
  --name "aks-eaap-dev-scus-001" `
  --query "addonProfiles.omsagent" `
  --output json
```

Workspace:

```powershell
az monitor log-analytics workspace show `
  --resource-group "rg-eaap-operations-dev" `
  --workspace-name "law-eaap-ops-dev-scus-001" `
  --query "{Name:name,Location:location,Retention:retentionInDays,ProvisioningState:provisioningState}" `
  --output table
```

Also confirm the agent pods are actually running, not just the add-on flag:

```powershell
kubectl get ds -n kube-system | Select-String "ama-logs"
```

Expect `ama-logs` with desired/current/ready columns matching your node count. `ama-logs-windows` will show all zeros if you have no Windows node pool — that is expected.

---

## Step 17 — Verify the AKS Diagnostic Setting

Get AKS resource ID:

```powershell
$aksId = az aks show `
  --resource-group "rg-eaap-platform-dev" `
  --name "aks-eaap-dev-scus-001" `
  --query id `
  --output tsv
```

List settings:

```powershell
az monitor diagnostic-settings list `
  --resource "$aksId" `
  --query "[].{Name:name,WorkspaceId:workspaceId,Logs:logs[].category}" `
  --output json
```

Confirm:

```text
diag-eaap-aks-dev
```

---

## Step 18 — Verify the Data Collection Rule Association

This is the step that catches the gap described in Step 10 before you waste time debugging empty KQL queries later. Confirm `$aksId` from Step 17 is set, then:

```powershell
az monitor data-collection rule association list `
  --resource "$aksId" `
  --output table
```

Expected: one row showing `dcr-eaap-container-insights-dev-scus-001` associated as `ContainerInsightsExtension`. If this list is empty, Terraform did not apply Step 10 successfully — re-run `terraform plan` and confirm the DCR and association resources are actually in state before moving on. Do not proceed to Step 20 with an empty association list; every later query step will silently return nothing.

---

## Step 19 — Run a Fresh Workstream 5 Deployment

After monitoring is enabled, use the real CD pipeline as a controlled telemetry event.

In GitHub:

```text
Actions
→ EAAP Deploy to AKS
→ Run workflow
→ main
```

Confirm it succeeds. If the **Temporarily allow GitHub runner to AKS API** or **Restore original AKS authorized IP ranges** steps fail with `LinkedAuthorizationFailed` on `Microsoft.OperationalInsights/workspaces/sharedkeys/read`, Step 12's role assignment either wasn't applied or hasn't finished propagating — confirm it exists and wait a few minutes before retrying.

This generates:

```text
new Git-SHA image
Kubernetes Deployment update
pod rollout
Kubernetes API writes
```

Do not modify `platform.yaml` just to create monitoring data.

---

## Step 20 — Generate Application Traffic

Use port forwarding:

```powershell
kubectl port-forward `
  -n eaap-app `
  service/eaap-sample-web `
  8080:80
```

Keep that terminal open.

In another PowerShell window:

```powershell
1..20 | ForEach-Object {
  Invoke-WebRequest `
    -Uri "http://localhost:8080" `
    -UseBasicParsing | Out-Null
}
```

Verify:

```powershell
kubectl get pods -n eaap-app
```

---

## Step 21 — Get the Workspace Customer ID

```powershell
$workspaceId = az monitor log-analytics workspace show `
  --resource-group "rg-eaap-operations-dev" `
  --workspace-name "law-eaap-ops-dev-scus-001" `
  --query customerId `
  --output tsv

Write-Host $workspaceId
```

If you open a new terminal window later, this variable will be empty again — rerun this step before retrying any query below rather than assuming a silent empty result means no data exists.

---

## Step 22 — Query EAAP Container Logs

```powershell
az monitor log-analytics query `
  --workspace "$workspaceId" `
  --analytics-query "ContainerLogV2 | where TimeGenerated > ago(1h) | where PodNamespace == 'eaap-app' | project TimeGenerated, PodName, ContainerName, LogSource, LogMessage | order by TimeGenerated desc | take 50" `
  --output table
```

If no rows appear immediately, allow 10–15 minutes for first-time ingestion after Step 15, then confirm `$workspaceId` is actually populated (Step 21) before assuming ingestion is broken.

---

## Step 23 — Query Pod Inventory and Restarts

```powershell
az monitor log-analytics query `
  --workspace "$workspaceId" `
  --analytics-query "KubePodInventory | where TimeGenerated > ago(1h) | where Namespace == 'eaap-app' | summarize LastSeen=max(TimeGenerated), RestartCount=max(ContainerRestartCount) by Name, PodStatus | order by RestartCount desc" `
  --output table
```

---

## Step 24 — Query Kubernetes Events

```powershell
az monitor log-analytics query `
  --workspace "$workspaceId" `
  --analytics-query "KubeEvents | where TimeGenerated > ago(2h) | where Namespace == 'eaap-app' | project TimeGenerated, Name, Reason, Message, Type | order by TimeGenerated desc | take 50" `
  --output table
```

Important:

Container Insights may not collect every Normal Kubernetes event by default.

An empty `KubeEvents` result does not automatically mean monitoring is broken. Confirm other tables are ingesting before changing collection settings.

---

## Step 25 — Query AKS Audit Activity

Because the diagnostic destination is resource-specific, start with:

```powershell
az monitor log-analytics query `
  --workspace "$workspaceId" `
  --analytics-query "AKSAuditAdmin | where TimeGenerated > ago(2h) | order by TimeGenerated desc | take 50" `
  --output table
```

This should surface modifying Kubernetes API operations where available.

If you later enable full `kube-audit`, query:

```powershell
az monitor log-analytics query `
  --workspace "$workspaceId" `
  --analytics-query "AKSAudit | where TimeGenerated > ago(2h) | order by TimeGenerated desc | take 50" `
  --output table
```

---

## Step 26 — Query AKS Control-Plane Logs

```powershell
az monitor log-analytics query `
  --workspace "$workspaceId" `
  --analytics-query "AKSControlPlane | where TimeGenerated > ago(2h) | project TimeGenerated, Category, Level, Message | order by TimeGenerated desc | take 100" `
  --output table
```

Filter API server:

```powershell
az monitor log-analytics query `
  --workspace "$workspaceId" `
  --analytics-query "AKSControlPlane | where TimeGenerated > ago(2h) | where Category == 'kube-apiserver' | project TimeGenerated, Level, Message | order by TimeGenerated desc | take 50" `
  --output table
```

If these tables do not exist, verify:

```hcl
log_analytics_destination_type = "Dedicated"
```

and confirm the deployed diagnostic categories.

---

## Step 27 — Verify the Action Group

```powershell
az monitor action-group show `
  --resource-group "rg-eaap-operations-dev" `
  --name "ag-eaap-platform-dev-scus-001" `
  --query "{Name:name,Enabled:enabled,EmailReceivers:emailReceivers[].name}" `
  --output json
```

In Azure portal:

```text
Action Group
→ Test action group
```

Capture evidence without exposing the personal email address.

---

## Step 28 — Understand the GitHub Actions Dependency

When Workstream 6 Terraform files are committed:

```text
EAAP CI Validation
```

should run because the CI workflow watches:

```text
terraform/**
```

The application CD workflow should **not** run unless a watched application/workflow path changes.

That separation is intentional:

```text
Terraform monitoring change
→ CI validation
→ engineer-reviewed Terraform apply

Application change
→ CI
→ CD to AKS
```

---

## Step 29 — Clean Terraform Plan

```powershell
cd .\terraform\environments\dev
terraform plan
```

Expected:

```text
No changes. Your infrastructure matches the configuration.
```

---

## Step 30 — Capture Evidence

Save under:

```text
screenshots/phase-6/
```

Recommended:

```text
01-log-analytics-workspace.png
02-aks-monitoring.png
03-dcr-association.png
04-phase5-deployment.png
05-containerlogv2-query.png
06-pod-inventory-query.png
07-kubeevents-query.png
08-aks-diagnostics.png
09-action-group.png
10-alert-test.png
11-clean-plan.png
```

Sanitize personal email addresses and full sensitive identifiers before publishing.

---

## Step 31 — Commit Workstream 6

Return to repo root:

```powershell
cd ..\..\..
```

Stage:

```powershell
git add .\docs\phase-6-observability-operations-case-study.md
git add .\runbooks\phase-6-observability-operations-runbook.md
git add .\terraform\environments\dev\monitoring-variables.tf
git add .\terraform\environments\dev\monitoring.tf
git add .\terraform\environments\dev\monitoring-outputs.tf
git add .\terraform\environments\dev\container-insights-dcr.tf
git add .\terraform\environments\dev\aks.tf
git add .\terraform\environments\dev\cicd-identity.tf
git add .\terraform\environments\dev\terraform.tfvars.example
git add .\screenshots\phase-6
```

Review:

```powershell
git status
git diff --cached --name-only
git diff --cached
```

Commit:

```powershell
git commit -m "Complete Workstream 6 observability and operations"
```

Synchronize and push:

```powershell
git pull --rebase origin main
git push origin main
```

If the rebase reports conflicts, resolve each file deliberately rather than guessing — for a "both modified"/"deleted by us" conflict, confirm which version is actually correct before staging it with `git add`, and for a "both deleted" conflict use `git rm <path>` to confirm the deletion. Run `git status` after each resolution to confirm no unmerged paths remain before `git rebase --continue`.

---

## Troubleshooting

### Terraform wants to replace AKS

Stop.

Adding Container Insights should be reviewed as an in-place change.

### `ContainerLogV2` has no rows

Check the monitoring add-on:

```powershell
az aks show `
  --resource-group "rg-eaap-platform-dev" `
  --name "aks-eaap-dev-scus-001" `
  --query "addonProfiles.omsagent" `
  --output json
```

If the add-on config looks correct and the `ama-logs` pods are healthy, the most likely cause is a missing Data Collection Rule association — see Step 18. Confirm:

```powershell
az monitor data-collection rule association list --resource "$aksId" --output table
```

before assuming it's purely an ingestion-timing issue. Generate HTTP traffic and wait for ingestion only after the association is confirmed to exist.

### `KubeEvents` is empty

This can be normal if no collected event type occurred.

Validate `ContainerLogV2` and `KubePodInventory` before treating it as an ingestion failure.

### `AKSAuditAdmin` or `AKSControlPlane` does not exist

Confirm:

```hcl
log_analytics_destination_type = "Dedicated"
```

Then verify categories:

```powershell
az monitor diagnostic-settings categories list `
  --resource "$aksId" `
  --output table
```

Allow ingestion time.

### GitHub Actions deploy fails with `LinkedAuthorizationFailed` on `sharedkeys/read`

This means Step 12's role assignment either was skipped or hasn't propagated yet. Confirm it exists:

```powershell
az role assignment list `
  --scope "/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/rg-eaap-operations-dev/providers/Microsoft.OperationalInsights/workspaces/law-eaap-ops-dev-scus-001" `
  --query "[].{Role:roleDefinitionName,Principal:principalId}" `
  --output table
```

Confirm the GitHub Actions service principal's object ID appears with `Log Analytics Contributor`. If it's missing, re-check that `container-insights-dcr.tf`... actually the role assignment lives in `cicd-identity.tf` — confirm it was applied, then wait a few minutes for RBAC propagation before retrying the workflow.

### Monitoring providers are not registered

```powershell
az provider show --namespace Microsoft.OperationalInsights --query registrationState -o tsv
az provider show --namespace Microsoft.Insights --query registrationState -o tsv
az provider show --namespace Microsoft.Monitor --query registrationState -o tsv
az provider show --namespace Microsoft.AlertsManagement --query registrationState -o tsv
```

### Monitoring cost rises faster than expected

Review:

```text
Log Analytics workspace
→ Usage and estimated costs
```

Keep retention and diagnostic categories appropriate for the dev portfolio environment.

### `az` commands fail with `WinError 5 Access is denied` on a CLI extension

This is a local Windows/file-lock issue, not an Azure problem — see the note at the end of Step 3.

---

## Cost Control

The Log Analytics workspace remains available while AKS is stopped.

Pause AKS:

```powershell
az aks stop `
  --resource-group "rg-eaap-platform-dev" `
  --name "aks-eaap-dev-scus-001"
```

Stopping AKS reduces node compute cost and lowers ongoing cluster telemetry volume.

Do not delete the Terraform backend while later workstreams continue.

---

## Execution-Specific Engineering Decisions

### Container Insights agent healthy but zero data ingested

**Issue:** After enabling the `oms_agent` block and applying, the `ama-logs` DaemonSet reported healthy Ready pods on every node, and the add-on config (`addonProfiles.omsagent`) correctly referenced the workspace with `useAADAuth: true`. Despite this, `ContainerLogV2` and `KubePodInventory` returned zero rows even after well over an hour of runtime — beyond any reasonable ingestion delay.

**Root cause:** `az monitor data-collection rule list` confirmed there was no Data Collection Rule in the resource group at all. The `oms_agent` block only configures the AKS add-on profile; it does not create the DCR + DCRA that tells the AMA-based agent what to collect and where to send it. The Azure Portal performs this step automatically when you enable monitoring through the UI; Terraform does not.

**Resolution:** Added `azurerm_monitor_data_collection_rule` and `azurerm_monitor_data_collection_rule_association` resources targeting the `Microsoft-ContainerInsights-Group-Default` stream (Step 10). Confirmed the association with `az monitor data-collection rule association list` before re-attempting any KQL query.

### GitHub Actions CD pipeline broke after enabling monitoring

**Issue:** After Workstream 6 was applied, re-running the Phase 5 `EAAP Deploy to AKS` workflow failed at both the **Temporarily allow GitHub runner to AKS API** and **Restore original AKS authorized IP ranges** steps with `LinkedAuthorizationFailed`.

**Root cause:** Once AKS is linked to a Log Analytics workspace via Container Insights, Azure validates linked-resource authorization on every `az aks update` call, not only calls that touch monitoring settings. The GitHub Actions service principal had `Microsoft.ContainerService/managedClusters/write` but no permission on the newly linked workspace, so it failed the `Microsoft.OperationalInsights/workspaces/sharedkeys/read` check — the same category of problem as the Phase 5 workload-subnet `join/action` requirement, just against a different linked resource.

**Resolution:** Granted the GitHub Actions service principal `Log Analytics Contributor`, scoped to only the EAAP Log Analytics workspace (Step 12), matching the existing least-privilege pattern used for the workload-subnet role assignment in Phase 5.

---

## Workstream Completion Criteria

Workstream 6 is complete when:

- [ ] Workstream 5 deployment remains healthy
- [ ] Monitoring resource providers are registered
- [ ] Dedicated Log Analytics workspace exists
- [ ] Existing AKS cluster is updated in place with Container Insights
- [ ] Diagnostic setting uses resource-specific destination mode
- [ ] Container Insights Data Collection Rule and association exist and are confirmed via CLI
- [ ] GitHub Actions service principal has `Log Analytics Contributor` on the workspace
- [ ] `ContainerLogV2` contains EAAP application logs
- [ ] `KubePodInventory` shows `eaap-app` pods
- [ ] Kubernetes event query is validated
- [ ] `AKSAuditAdmin` and/or `AKSAudit` contains expected audit activity
- [ ] `AKSControlPlane` contains control-plane data
- [ ] Fresh Workstream 5 deployment succeeds end-to-end with monitoring enabled
- [ ] Action group exists and test notification succeeds
- [ ] Follow-up Terraform plan is clean
- [ ] Evidence is captured and sanitized

---

## Next Workstream

**Workstream 7 — Reliability and Recovery** builds on the observability foundation from Workstream 6 to add autoscaling validation, backup and restore for the AKS application, and resiliency/failure-injection testing — using the Log Analytics workspace and KQL queries established here to observe the platform's behavior under load and failure conditions.
