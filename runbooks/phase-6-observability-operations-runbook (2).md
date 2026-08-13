<div align="center">

# Workstream 6 Runbook: Observability and Operations
### Azure Monitor, Log Analytics, Container Insights, AKS Diagnostics, KQL, and Alerting

</div>

---

## Purpose

This runbook adds centralized monitoring and operational visibility to the existing EAAP container platform.

You will:

1. Confirm Workstream 5 and AKS are healthy.
2. Register required monitoring resource providers.
3. Create a dedicated Log Analytics workspace.
4. Enable Container Insights on the existing AKS cluster.
5. Send AKS control-plane diagnostic logs to Log Analytics.
6. Create an Azure Monitor action group.
7. Generate test application activity.
8. Validate container logs, Kubernetes events, and pod inventory with KQL.
9. Test the notification path.
10. Capture evidence and verify Terraform remains clean.

> **Cost note:** Log Analytics charges are driven mainly by ingestion and retention. This workstream uses a focused monitoring scope and does not deploy Azure Managed Grafana.

---

## Target Resources

| Resource | Suggested Name | Location |
|---|---|---|
| Log Analytics workspace | `law-eaap-ops-dev-scus-001` | `rg-eaap-operations-dev` |
| AKS diagnostic setting | `diag-eaap-aks-dev` | Targets existing AKS cluster |
| Azure Monitor action group | `ag-eaap-platform-dev-scus-001` | `rg-eaap-operations-dev` |
| Container Insights | Existing AKS cluster add-on | `aks-eaap-dev-scus-001` |

---

## Step 1 — Restore the Engineering Session

```powershell
cd "$HOME\Documents\enterprise-azure-application-platform"
code .
```

Confirm Azure authentication:

```powershell
az account show `
  --query "{Name:name,State:state,IsDefault:isDefault,User:user.name}" `
  --output table
```

Restore subscription variables:

```powershell
$env:ARM_SUBSCRIPTION_ID = az account show --query id -o tsv
$env:AZURE_SUBSCRIPTION_ID = $env:ARM_SUBSCRIPTION_ID
```

---

## Step 2 — Start and Validate AKS

Check cluster power state:

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

Validate:

```powershell
kubectl get nodes
kubectl get deployment -n eaap-app
kubectl get pods -n eaap-app
kubectl get service -n eaap-app
```

Do not continue until the existing application is healthy.

---

## Step 3 — Register Monitoring Resource Providers

Because this subscription was recently rebuilt, register the monitoring providers explicitly:

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

Expected state:

```text
Registered
```

---

## Step 4 — Confirm Terraform Baseline

```powershell
cd .\terraform\environments\dev
terraform init -reconfigure -backend-config="backend.hcl"
terraform state list
terraform plan
```

Expected:

```text
No changes. Your infrastructure matches the configuration.
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

Add a safe example to `terraform.tfvars.example`:

```hcl
operations_alert_email = "alerts@example.com"
```

Add your real email only to the ignored `terraform.tfvars`:

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

Simple meaning:

> This workspace becomes the centralized database for EAAP operational logs and Kubernetes monitoring data.

---

## Step 7 — Enable Container Insights on the Existing AKS Resource

Open the existing AKS Terraform file:

```powershell
code .\aks.tf
```

Inside:

```hcl
resource "azurerm_kubernetes_cluster" "platform" {
```

add this block at the resource level:

```hcl
  oms_agent {
    log_analytics_workspace_id      = azurerm_log_analytics_workspace.platform.id
    msi_auth_for_monitoring_enabled = true
  }
```

Do not create a second AKS resource.

> **Safety rule:** When you plan later, the AKS cluster should be updated **in place**. Stop if Terraform proposes destroying and recreating AKS.

---

## Step 8 — Discover Available AKS Diagnostic Categories

Add to `monitoring.tf`:

```hcl
data "azurerm_monitor_diagnostic_categories" "aks" {
  resource_id = azurerm_kubernetes_cluster.platform.id
}

locals {
  desired_aks_log_categories = toset([
    "kube-apiserver",
    "kube-audit",
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

Why discover categories:

> Azure diagnostic categories can vary by resource capability. Terraform enables only the categories that are both desired and actually exposed by this AKS cluster.

---

## Step 9 — Create the AKS Diagnostic Setting

Append to `monitoring.tf`:

```hcl
resource "azurerm_monitor_diagnostic_setting" "aks" {
  name                       = "diag-eaap-aks-${var.environment}"
  target_resource_id         = azurerm_kubernetes_cluster.platform.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.platform.id

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

This sends available selected AKS control-plane logs and platform metrics to the monitoring destination.

---

## Step 10 — Create the Operations Action Group

Append to `monitoring.tf`:

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

This establishes the notification destination that later metric/log alerts can reuse.

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
terraform fmt
terraform validate
terraform plan -out=phase6.tfplan
```

Review:

```powershell
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

or otherwise indicates AKS replacement.

---

## Step 13 — Apply Phase 6

```powershell
terraform apply phase6.tfplan
```

Then:

```powershell
terraform output monitoring
```

Allow monitoring data time to begin flowing before expecting all KQL queries to return records.

---

## Step 14 — Verify Container Insights Is Enabled

```powershell
az aks show `
  --resource-group "rg-eaap-platform-dev" `
  --name "aks-eaap-dev-scus-001" `
  --query "addonProfiles.omsagent" `
  --output json
```

Verify the workspace:

```powershell
az monitor log-analytics workspace show `
  --resource-group "rg-eaap-operations-dev" `
  --workspace-name "law-eaap-ops-dev-scus-001" `
  --query "{Name:name,Location:location,Retention:retentionInDays,ProvisioningState:provisioningState}" `
  --output table
```

---

## Step 15 — Generate Test Application Activity

Use local port forwarding so you can safely send requests to the private application service from the workstation:

```powershell
kubectl port-forward `
  -n eaap-app `
  service/eaap-sample-web `
  8080:80
```

Keep that terminal open.

In a second PowerShell terminal:

```powershell
1..20 | ForEach-Object {
  Invoke-WebRequest -Uri "http://localhost:8080" -UseBasicParsing | Out-Null
}
```

Also confirm the pods remain healthy:

```powershell
kubectl get pods -n eaap-app
```

---

## Step 16 — Get the Log Analytics Workspace ID

```powershell
$workspaceId = az monitor log-analytics workspace show `
  --resource-group "rg-eaap-operations-dev" `
  --workspace-name "law-eaap-ops-dev-scus-001" `
  --query customerId `
  --output tsv
```

Verify:

```powershell
Write-Host $workspaceId
```

This is the workspace customer/workspace ID used by `az monitor log-analytics query`.

---

## Step 17 — Query EAAP Container Logs

Run:

```powershell
az monitor log-analytics query `
  --workspace "$workspaceId" `
  --analytics-query "ContainerLogV2 | where TimeGenerated > ago(30m) | where PodNamespace == 'eaap-app' | project TimeGenerated, PodName, ContainerName, LogMessage | order by TimeGenerated desc | take 50" `
  --output table
```

Simple meaning:

> Show the newest logs generated by containers in the EAAP application namespace.

If no rows appear immediately, wait for ingestion and retry.

---

## Step 18 — Query Kubernetes Events

```powershell
az monitor log-analytics query `
  --workspace "$workspaceId" `
  --analytics-query "KubeEvents | where TimeGenerated > ago(1h) | where Namespace == 'eaap-app' | project TimeGenerated, Name, Reason, Message, Type | order by TimeGenerated desc | take 50" `
  --output table
```

Warnings only:

```powershell
az monitor log-analytics query `
  --workspace "$workspaceId" `
  --analytics-query "KubeEvents | where TimeGenerated > ago(1h) | where Namespace == 'eaap-app' | where Type == 'Warning' | project TimeGenerated, Name, Reason, Message | order by TimeGenerated desc" `
  --output table
```

---

## Step 19 — Query Pod Inventory and Restarts

```powershell
az monitor log-analytics query `
  --workspace "$workspaceId" `
  --analytics-query "KubePodInventory | where TimeGenerated > ago(1h) | where Namespace == 'eaap-app' | summarize LastSeen=max(TimeGenerated), RestartCount=max(ContainerRestartCount) by Name, PodStatus | order by RestartCount desc" `
  --output table
```

Simple meaning:

> Show EAAP pods, their latest observed status, and whether containers have been restarting.

---

## Step 20 — Validate AKS Diagnostic Settings

List the diagnostic setting:

```powershell
$aksId = az aks show `
  --resource-group "rg-eaap-platform-dev" `
  --name "aks-eaap-dev-scus-001" `
  --query id -o tsv

az monitor diagnostic-settings list `
  --resource "$aksId" `
  --query "[].{Name:name,WorkspaceId:workspaceId,Logs:logs[].category}" `
  --output json
```

You should see:

```text
diag-eaap-aks-dev
```

with the available selected control-plane categories.

---

## Step 21 — Query AKS Control-Plane Logs

First inspect which Azure diagnostics categories have produced data:

```powershell
az monitor log-analytics query `
  --workspace "$workspaceId" `
  --analytics-query "AzureDiagnostics | where TimeGenerated > ago(1h) | summarize Count=count() by Category | order by Count desc" `
  --output table
```

Then query recent AKS diagnostics:

```powershell
az monitor log-analytics query `
  --workspace "$workspaceId" `
  --analytics-query "AzureDiagnostics | where TimeGenerated > ago(1h) | where ResourceType =~ 'MANAGEDCLUSTERS' | project TimeGenerated, Category, Level, Resource, log_s | order by TimeGenerated desc | take 50" `
  --output table
```

If your workspace uses resource-specific AKS tables instead of `AzureDiagnostics`, inspect the Tables blade in Log Analytics and adapt the query to the tables created by the deployed diagnostic mode.

---

## Step 22 — Verify the Action Group

```powershell
az monitor action-group show `
  --resource-group "rg-eaap-operations-dev" `
  --name "ag-eaap-platform-dev-scus-001" `
  --query "{Name:name,Enabled:enabled,EmailReceivers:emailReceivers[].name}" `
  --output json
```

From the Azure portal, open the action group and use the built-in **Test action group** function to send a test notification.

Capture evidence that the test was initiated/succeeded, but do not publish your personal email address in the screenshot.

---

## Step 23 — Clean Terraform Plan

```powershell
cd .\terraform\environments\dev
terraform plan
```

Expected:

```text
No changes. Your infrastructure matches the configuration.
```

---

## Step 24 — Capture Evidence

Save under:

```text
screenshots/phase-6/
```

Recommended names:

```text
01-log-analytics-workspace.png
02-aks-monitoring.png
03-containerlogv2-query.png
04-kubeevents-query.png
05-pod-inventory-query.png
06-aks-diagnostics.png
07-action-group.png
08-alert-test.png
09-clean-plan.png
```

Sanitize personal email addresses and full resource IDs before publishing.

---

## Step 25 — Commit Workstream 6

Return to the repository root:

```powershell
cd ..\..\..
```

Stage:

```powershell
git add .\docs\phase-6-observability-operations
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

### `MissingSubscriptionRegistration`

Check:

```powershell
az provider show --namespace Microsoft.OperationalInsights --query registrationState -o tsv
az provider show --namespace Microsoft.Insights --query registrationState -o tsv
az provider show --namespace Microsoft.Monitor --query registrationState -o tsv
az provider show --namespace Microsoft.AlertsManagement --query registrationState -o tsv
```

Register any provider that is not `Registered`.

### Terraform wants to replace AKS

Stop. Do not apply.

The existing cluster is already Terraform-managed. Adding the `oms_agent` block should be reviewed as an in-place update. Reconcile any unrelated AKS drift first.

### `ContainerLogV2` returns no rows

Check:

```powershell
kubectl get pods -n kube-system | Select-String "ama|oms"
```

Then confirm the AKS monitoring add-on is enabled and allow time for ingestion.

### `KubeEvents` is empty

Generate a harmless Kubernetes event, wait for ingestion, and retry. Do not create destructive test failures in production-style resources just to populate a screenshot.

### Control-plane logs are missing

List the enabled diagnostic categories and compare them with the categories exposed by the AKS cluster:

```powershell
az monitor diagnostic-settings categories list `
  --resource "$aksId" `
  --output table
```

### Monitoring costs grow faster than expected

Review:

```text
Log Analytics workspace
→ Usage and estimated costs
```

Keep retention and collected streams appropriate for a development portfolio environment.

---

## Cost Control

The Log Analytics workspace remains available even when AKS is stopped. When pausing work:

```powershell
az aks stop `
  --resource-group "rg-eaap-platform-dev" `
  --name "aks-eaap-dev-scus-001"
```

Stopping AKS reduces node compute cost and also reduces the volume of cluster telemetry generated during the pause.

Do not delete the Terraform backend while later workstreams continue.

---

## Workstream Completion Criteria

Workstream 6 is complete when:

- [ ] Monitoring resource providers are registered
- [ ] Dedicated Log Analytics workspace exists
- [ ] Existing AKS cluster is updated in place with Container Insights
- [ ] `ContainerLogV2` contains EAAP application logs
- [ ] `KubeEvents` returns Kubernetes events
- [ ] `KubePodInventory` shows `eaap-app` pods
- [ ] AKS diagnostic setting targets the operations workspace
- [ ] Available selected control-plane log categories are enabled
- [ ] Action group exists and test notification succeeds
- [ ] Follow-up Terraform plan is clean
- [ ] Evidence is captured and sanitized

---

## Next Workstream

The monitored platform is ready for the next application-focused workstream: replacing the sample workload with a real SaaS application and adding its data services, followed by Layer 7 ingress/WAF and resilience/recovery validation.
