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
7. Create an Azure Monitor action group.
8. Run a fresh Phase 5 deployment as a realistic telemetry event.
9. Generate application traffic.
10. Query container logs, pod inventory, Kubernetes events, audit logs, and control-plane logs.
11. Validate the notification path.
12. Confirm Terraform remains synchronized.
13. Capture evidence.

> **Important Phase 5 dependency:** Workstream 6 does not replace or bypass the GitHub deployment pipeline. The pipeline remains application-only and continues to deploy `app-release.yaml`.

---

## Target Resources

| Resource | Name | Location / Scope |
|---|---|---|
| Log Analytics workspace | `law-eaap-ops-dev-scus-001` | `rg-eaap-operations-dev` |
| AKS diagnostic setting | `diag-eaap-aks-dev` | Existing AKS cluster |
| Action group | `ag-eaap-platform-dev-scus-001` | `rg-eaap-operations-dev` |
| Container Insights | Existing AKS add-on | `aks-eaap-dev-scus-001` |
| Diagnostic destination | Resource-specific tables | Log Analytics |

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

Do not create another AKS resource.

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

## Step 10 — Create the Operations Action Group

Append:

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

## Step 11 — Add Monitoring Outputs

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
  }
}
```

---

## Step 12 — Format, Validate, and Plan

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
- Action group

Update in place:
- Existing AKS cluster to enable Container Insights
```

Stop immediately if Terraform proposes:

```text
-/+ azurerm_kubernetes_cluster.platform
```

or any AKS replacement.

---

## Step 13 — Apply Workstream 6

```powershell
terraform apply phase6.tfplan
```

Then:

```powershell
terraform output monitoring
```

Allow monitoring data time to begin flowing.

---

## Step 14 — Verify Container Insights

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

---

## Step 15 — Verify the AKS Diagnostic Setting

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

## Step 16 — Run a Fresh Workstream 5 Deployment

After monitoring is enabled, use the real CD pipeline as a controlled telemetry event.

In GitHub:

```text
Actions
→ EAAP Deploy to AKS
→ Run workflow
→ main
```

Confirm it succeeds.

This generates:

```text
new Git-SHA image
Kubernetes Deployment update
pod rollout
Kubernetes API writes
```

Do not modify `platform.yaml` just to create monitoring data.

---

## Step 17 — Generate Application Traffic

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

## Step 18 — Get the Workspace Customer ID

```powershell
$workspaceId = az monitor log-analytics workspace show `
  --resource-group "rg-eaap-operations-dev" `
  --workspace-name "law-eaap-ops-dev-scus-001" `
  --query customerId `
  --output tsv

Write-Host $workspaceId
```

---

## Step 19 — Query EAAP Container Logs

```powershell
az monitor log-analytics query `
  --workspace "$workspaceId" `
  --analytics-query "ContainerLogV2 | where TimeGenerated > ago(1h) | where PodNamespace == 'eaap-app' | project TimeGenerated, PodName, ContainerName, LogSource, LogMessage | order by TimeGenerated desc | take 50" `
  --output table
```

If no rows appear immediately, wait for ingestion and retry.

---

## Step 20 — Query Pod Inventory and Restarts

```powershell
az monitor log-analytics query `
  --workspace "$workspaceId" `
  --analytics-query "KubePodInventory | where TimeGenerated > ago(1h) | where Namespace == 'eaap-app' | summarize LastSeen=max(TimeGenerated), RestartCount=max(ContainerRestartCount) by Name, PodStatus | order by RestartCount desc" `
  --output table
```

---

## Step 21 — Query Kubernetes Events

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

## Step 22 — Query AKS Audit Activity

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

## Step 23 — Query AKS Control-Plane Logs

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

## Step 24 — Verify the Action Group

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

## Step 25 — Understand the GitHub Actions Dependency

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

## Step 26 — Clean Terraform Plan

```powershell
cd .\terraform\environments\dev
terraform plan
```

Expected:

```text
No changes. Your infrastructure matches the configuration.
```

---

## Step 27 — Capture Evidence

Save under:

```text
screenshots/phase-6/
```

Recommended:

```text
01-log-analytics-workspace.png
02-aks-monitoring.png
03-phase5-deployment.png
04-containerlogv2-query.png
05-pod-inventory-query.png
06-kubeevents-query.png
07-aks-diagnostics.png
08-action-group.png
09-alert-test.png
10-clean-plan.png
```

Sanitize personal email addresses and full sensitive identifiers before publishing.

---

## Step 28 — Commit Workstream 6

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
git add .\terraform\environments\dev\aks.tf
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

Generate HTTP traffic and wait for ingestion.

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

## Workstream Completion Criteria

Workstream 6 is complete when:

- [ ] Workstream 5 deployment remains healthy
- [ ] Monitoring resource providers are registered
- [ ] Dedicated Log Analytics workspace exists
- [ ] Existing AKS cluster is updated in place with Container Insights
- [ ] Diagnostic setting uses resource-specific destination mode
- [ ] `ContainerLogV2` contains EAAP application logs
- [ ] `KubePodInventory` shows `eaap-app` pods
- [ ] Kubernetes event query is validated
- [ ] `AKSAuditAdmin` and/or `AKSAudit` contains expected audit activity
- [ ] `AKSControlPlane` contains control-plane data
- [ ] Fresh Workstream 5 deployment is observable
- [ ] Action group exists and test notification succeeds
- [ ] Follow-up Terraform plan is clean
- [ ] Evidence is captured and sanitized

---

## Next Workstream

After centralized monitoring is validated, EAAP is ready for the next application-focused workstream: replacing the sample workload with the real SaaS application/data services, followed by Layer 7 ingress/WAF and resilience/recovery validation.
