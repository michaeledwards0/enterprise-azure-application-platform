<div align="center">

# Workstream 7 Runbook: Reliability and Recovery
### Autoscaling, Pod Disruption Budgets, Azure Backup for AKS, and Failure-Injection Testing

</div>

---

## Purpose

This runbook adds reliability and recovery controls to the EAAP platform after the Workstream 6 observability stack is confirmed healthy.

You will:

1. Confirm Workstream 6 is healthy and Terraform is clean.
2. Add resource requests and limits to the sample application.
3. Deploy a HorizontalPodAutoscaler and PodDisruptionBudget.
4. Generate load and validate pod-level and node-level autoscaling.
5. Run a live node-drain failure-injection test.
6. Deploy Azure Backup for AKS (vault, extension, policy, instance).
7. Trigger and validate a real backup.
8. Delete and restore the application namespace to validate recovery.
9. Correlate every test against the Workstream 6 Log Analytics workspace.
10. Capture evidence and commit.

> **Cost and safety note:** The node-drain test and cluster-autoscaler validation briefly increase node count and reduce available capacity on one node. Run this during a low-traffic window. Nothing in this runbook should affect the sibling Azure AI Infrastructure project's resources — all new resources are scoped to existing EAAP resource groups.

---

## Target Resources

| Resource | Suggested Name | Location / Scope |
|---|---|---|
| HPA | `eaap-sample-web` | `eaap-app` namespace |
| PDB | `eaap-sample-web-pdb` | `eaap-app` namespace |
| Backup storage account | `steaapbackupdev<suffix>` | `rg-eaap-operations-dev` |
| Backup vault | `bvault-eaap-dev-scus-001` | `rg-eaap-operations-dev` |
| Backup policy | `bkp-policy-eaap-aks-dev` | `bvault-eaap-dev-scus-001` |
| Backup instance | `bkp-instance-eaap-aks-dev` | `bvault-eaap-dev-scus-001` |
| Snapshot resource group | `rg-eaap-workload-dev` (existing) | Reused from the Phase 1 landing zone |
| AKS backup extension | `aks-backup-extension` | Existing AKS cluster |
| Trusted access role binding | `eaap-backup-trusted-access` | Existing AKS cluster |

---

## Step 1 — Restore the Engineering Session

```powershell
cd "$HOME\Documents\enterprise-azure-application-platform"
code .
```

```powershell
az account show `
  --query "{Name:name,State:state,IsDefault:isDefault}" `
  --output table

$env:ARM_SUBSCRIPTION_ID = az account show --query id -o tsv
$env:AZURE_SUBSCRIPTION_ID = $env:ARM_SUBSCRIPTION_ID
```

---

## Step 2 — Confirm Workstream 6 Is Healthy

```powershell
az aks show `
  --resource-group "rg-eaap-platform-dev" `
  --name "aks-eaap-dev-scus-001" `
  --query "{PowerState:powerState.code,ProvisioningState:provisioningState}" `
  --output table

kubectl get nodes
kubectl get deployment -n eaap-app
kubectl get pods -n eaap-app
```

```powershell
$aksId = az aks show `
  --resource-group "rg-eaap-platform-dev" `
  --name "aks-eaap-dev-scus-001" `
  --query id --output tsv

az monitor data-collection rule association list --resource "$aksId" --output table
```

Confirm the DCR association from Workstream 6 is still present before continuing — every KQL correlation step in this runbook depends on it.

---

## Step 3 — Confirm the Terraform Baseline Is Clean

```powershell
cd .\terraform\environments\dev
terraform init -upgrade -reconfigure -backend-config="backend.hcl"
terraform validate
terraform plan
```

Expected: `No changes. Your infrastructure matches the configuration.`

---

## Step 4 — Add Resource Requests and Limits

Open the application release manifest:

```powershell
cd ..\..\..
code .\app\k8s\app-release.yaml
```

Inside the `eaap-sample-web` container spec, add:

```yaml
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "250m"
              memory: "256Mi"
```

Place it alongside the existing `volumeMounts` and `readinessProbe` entries in the same container block. Do not change the image, ports, service account, or volume configuration.

---

## Step 5 — Create the Reliability Manifest (HPA and PDB)

These are platform-level reliability policies, not part of the per-release CD manifest, so they live in their own file and are applied directly rather than through the GitHub Actions pipeline — consistent with how `platform.yaml` is kept separate from `app-release.yaml`.

Create `app/k8s/app-reliability.yaml`:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: eaap-sample-web
  namespace: eaap-app
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: eaap-sample-web
  minReplicas: 2
  maxReplicas: 6
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: eaap-sample-web-pdb
  namespace: eaap-app
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: eaap-sample-web
```

Confirm the metrics pipeline AKS needs for CPU-based HPA is already present (it ships with AKS by default):

```powershell
kubectl get apiservice v1beta1.metrics.k8s.io
kubectl top nodes
kubectl top pods -n eaap-app
```

If `kubectl top` returns data, the metrics pipeline is working and the HPA will have real numbers to act on.

---

## Step 6 — Apply the Reliability Manifest and Updated Release

Apply the reliability policy objects directly:

```powershell
kubectl apply -f .\app\k8s\app-reliability.yaml
```

Validate:

```powershell
kubectl get hpa -n eaap-app
kubectl get pdb -n eaap-app
```

Commit and push the `app-release.yaml` resource-limit change through the normal pipeline so the running Deployment picks up the new requests/limits:

```powershell
git add .\app\k8s\app-release.yaml .\app\k8s\app-reliability.yaml
git commit -m "Add resource requests/limits, HPA, and PDB for Workstream 7"
git push origin main
```

Confirm in GitHub:

```text
Actions
→ EAAP CI Validation      PASS
→ EAAP Deploy to AKS      PASS
```

Re-check the HPA once the new pods are running:

```powershell
kubectl get hpa -n eaap-app
```

`TARGETS` should now show a real percentage (for example `3%/70%`) instead of `<unknown>/70%`.

---

## Step 7 — Generate Load and Validate Autoscaling

Deploy a temporary in-cluster load generator:

```powershell
kubectl run load-generator `
  -n eaap-app `
  --image=busybox `
  --restart=Never `
  -- /bin/sh -c "while true; do wget -q -O- http://eaap-sample-web.eaap-app.svc.cluster.local > /dev/null; done"
```

If a single generator pod is not enough to push CPU past 70% against the configured limits, scale out the pressure with a few more:

```powershell
1..4 | ForEach-Object {
  kubectl run "load-generator-$_" `
    -n eaap-app `
    --image=busybox `
    --restart=Never `
    -- /bin/sh -c "while true; do wget -q -O- http://eaap-sample-web.eaap-app.svc.cluster.local > /dev/null; done"
}
```

Watch the HPA and node count over the next several minutes:

```powershell
kubectl get hpa -n eaap-app -w
```

In a second window:

```powershell
kubectl get nodes -w
```

Expected: `REPLICAS` climbs toward `maxReplicas` as `TARGETS` exceeds 70%. If the existing 2-node cap on the `apps` pool cannot schedule the new replicas, watch for a new node joining — that is the cluster autoscaler doing its job, not a problem.

Confirm scheduling pressure if a node doesn't appear immediately:

```powershell
kubectl get pods -n eaap-app -o wide
kubectl describe pod -n eaap-app -l app=eaap-sample-web | Select-String "FailedScheduling"
```

---

## Step 8 — Tear Down the Load Generator

```powershell
kubectl delete pod load-generator -n eaap-app --ignore-not-found
1..4 | ForEach-Object {
  kubectl delete pod "load-generator-$_" -n eaap-app --ignore-not-found
}
```

Allow several minutes for the HPA to scale back down and, if a node was added, for the cluster autoscaler to scale it back in.

```powershell
kubectl get hpa -n eaap-app -w
kubectl get nodes -w
```

---

## Step 9 — Failure Injection: Node Drain Under the PDB

Identify a node running an application pod:

```powershell
kubectl get pods -n eaap-app -o wide
```

Start continuous polling against the internal service from a workstation with VNet-level reachability, or via port-forward in a dedicated window:

```powershell
kubectl port-forward -n eaap-app service/eaap-sample-web 8080:80
```

In another window, poll continuously and log failures:

```powershell
1..120 | ForEach-Object {
  try {
    Invoke-WebRequest -Uri "http://localhost:8080" -UseBasicParsing -TimeoutSec 2 | Out-Null
    Write-Host "$(Get-Date -Format o) OK"
  } catch {
    Write-Host "$(Get-Date -Format o) FAILED"
  }
  Start-Sleep -Seconds 1
}
```

While that is running, cordon and drain the node identified above:

```powershell
kubectl cordon <NODE_NAME>
kubectl drain <NODE_NAME> --ignore-daemonsets --delete-emptydir-data
```

The PDB (`minAvailable: 1`) should prevent Kubernetes from evicting every `eaap-sample-web` pod at once — the drain should complete, but only after the evicted pod's replacement is Ready elsewhere. Watch for any `FAILED` lines in the polling output; there should be none if the PDB and readiness probe are both working correctly.

Uncordon the node once validation is complete:

```powershell
kubectl uncordon <NODE_NAME>
```

---

## Step 10 — Create Backup Infrastructure Variables

```powershell
cd .\terraform\environments\dev
New-Item -ItemType File -Name "backup-variables.tf" -Force
code .\backup-variables.tf
```

Paste:

```hcl
variable "backup_storage_account_name" {
  description = "Globally unique storage account name used as the AKS backup extension's storage location."
  type        = string
}

variable "backup_retention_duration" {
  description = "Default retention duration for AKS namespace backups, in ISO 8601 duration format."
  type        = string
  default     = "P30D"
}
```

In `terraform.tfvars.example`:

```hcl
backup_storage_account_name = "steaapbackupdevREPLACE"
```

Add the real value to ignored `terraform.tfvars` using the same random-suffix pattern established in Phase 1.

---

## Step 11 — Create the Backup Storage Account

Create `backup.tf`:

```powershell
New-Item -ItemType File -Name "backup.tf" -Force
code .\backup.tf
```

Paste the storage account first:

```hcl
resource "azurerm_storage_account" "backup" {
  name                     = var.backup_storage_account_name
  resource_group_name      = azurerm_resource_group.landing_zone["operations"].name
  location                 = azurerm_resource_group.landing_zone["operations"].location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  min_tls_version                = "TLS1_2"
  allow_nested_items_to_be_public = false

  tags = merge(
    local.common_tags,
    {
      ResourcePurpose = "AKS-Backup-Storage-Location"
    }
  )
}

resource "azurerm_storage_container" "backup" {
  name                  = "aks-backups"
  storage_account_name  = azurerm_storage_account.backup.name
  container_access_type = "private"
}
```

---

## Step 12 — Create the Backup Vault

Append to `backup.tf`:

```hcl
resource "azurerm_data_protection_backup_vault" "platform" {
  name                = "bvault-eaap-${var.environment}-scus-001"
  resource_group_name = azurerm_resource_group.landing_zone["operations"].name
  location            = azurerm_resource_group.landing_zone["operations"].location
  datastore_type      = "VaultStore"
  redundancy          = "LocallyRedundant"

  identity {
    type = "SystemAssigned"
  }

  tags = merge(
    local.common_tags,
    {
      ResourcePurpose = "AKS-Namespace-Backup"
    }
  )
}
```

`LocallyRedundant` keeps this consistent with the project's cost-conscious dev-environment posture, matching the Log Analytics workspace's `PerGB2018` choice in Workstream 6.

---

## Step 13 — Grant Trusted Access and the Backup Extension

The AKS cluster needs to trust the backup vault, and the cluster needs the Data Protection extension installed before a backup instance can be created. Append to `backup.tf`:

```hcl
resource "azurerm_kubernetes_cluster_trusted_access_role_binding" "backup" {
  kubernetes_cluster_id = azurerm_kubernetes_cluster.platform.id
  name                  = "eaap-backup-trusted-access"
  roles                 = ["Microsoft.DataProtection/backupVaults/backup-operator"]
  source_resource_id    = azurerm_data_protection_backup_vault.platform.id
}

resource "azurerm_kubernetes_cluster_extension" "backup" {
  name              = "aks-backup-extension"
  cluster_id        = azurerm_kubernetes_cluster.platform.id
  extension_type    = "Microsoft.DataProtection.Kubernetes"
  release_train     = "stable"
  release_namespace = "dataprotection-microsoft"

  configuration_settings = {
    "configuration.backupStorageLocation.bucket"                = azurerm_storage_container.backup.name
    "configuration.backupStorageLocation.config.resourceGroup"  = azurerm_resource_group.landing_zone["operations"].name
    "configuration.backupStorageLocation.config.storageAccount" = azurerm_storage_account.backup.name
    "configuration.backupStorageLocation.config.subscriptionId" = data.azurerm_client_config.current.subscription_id
    "credentials.tenantId"                                      = data.azurerm_client_config.current.tenant_id
  }
}
```

---

## Step 14 — Grant the Role Assignments the Extension and Vault Require

Append to `backup.tf`. This block deliberately mirrors the exact set of scoped role assignments Microsoft's own reference configuration requires — no broader than necessary:

```hcl
resource "azurerm_role_assignment" "backup_extension_storage_contributor" {
  scope                = azurerm_storage_account.backup.id
  role_definition_name = "Storage Account Contributor"
  principal_id         = azurerm_kubernetes_cluster_extension.backup.aks_assigned_identity[0].principal_id
}

resource "azurerm_role_assignment" "backup_vault_reader_on_cluster" {
  scope                = azurerm_kubernetes_cluster.platform.id
  role_definition_name = "Reader"
  principal_id         = azurerm_data_protection_backup_vault.platform.identity[0].principal_id
}

resource "azurerm_role_assignment" "backup_vault_reader_on_snapshot_rg" {
  scope                = azurerm_resource_group.landing_zone["workload"].id
  role_definition_name = "Reader"
  principal_id         = azurerm_data_protection_backup_vault.platform.identity[0].principal_id
}

resource "azurerm_role_assignment" "backup_vault_snapshot_contributor" {
  scope                = azurerm_resource_group.landing_zone["workload"].id
  role_definition_name = "Disk Snapshot Contributor"
  principal_id         = azurerm_data_protection_backup_vault.platform.identity[0].principal_id
}

resource "azurerm_role_assignment" "backup_vault_data_operator" {
  scope                = azurerm_resource_group.landing_zone["workload"].id
  role_definition_name = "Data Operator for Managed Disks"
  principal_id         = azurerm_data_protection_backup_vault.platform.identity[0].principal_id
}

resource "azurerm_role_assignment" "backup_vault_storage_data_contributor" {
  scope                = azurerm_storage_account.backup.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_data_protection_backup_vault.platform.identity[0].principal_id
}

resource "azurerm_role_assignment" "aks_cluster_contributor_on_snapshot_rg" {
  scope                = azurerm_resource_group.landing_zone["workload"].id
  role_definition_name = "Contributor"
  principal_id         = azurerm_kubernetes_cluster.platform.identity[0].principal_id
}
```

The `rg-eaap-workload-dev` resource group from the Phase 1 landing zone is reused here as the snapshot resource group — it has been reserved for workload-related resources since Workstream 1 and has been otherwise unused.

---

## Step 15 — Create the Backup Policy

Append to `backup.tf`:

```hcl
resource "azurerm_data_protection_backup_policy_kubernetes_cluster" "aks" {
  name                = "bkp-policy-eaap-aks-${var.environment}"
  resource_group_name = azurerm_resource_group.landing_zone["operations"].name
  vault_name          = azurerm_data_protection_backup_vault.platform.name

  backup_repeating_time_intervals = ["R/2025-01-01T02:00:00+00:00/P1W"]

  default_retention_rule {
    life_cycle {
      duration        = var.backup_retention_duration
      data_store_type = "OperationalStore"
    }
  }
}
```

The repeating interval's start date only anchors the schedule's day-of-week and time — it does not need to be updated to a future date.

---

## Step 16 — Create the Backup Instance

Append to `backup.tf`:

```hcl
resource "azurerm_data_protection_backup_instance_kubernetes_cluster" "aks" {
  name                          = "bkp-instance-eaap-aks-${var.environment}"
  location                      = azurerm_resource_group.landing_zone["operations"].location
  vault_id                      = azurerm_data_protection_backup_vault.platform.id
  kubernetes_cluster_id         = azurerm_kubernetes_cluster.platform.id
  snapshot_resource_group_name  = azurerm_resource_group.landing_zone["workload"].name
  backup_policy_id              = azurerm_data_protection_backup_policy_kubernetes_cluster.aks.id

  backup_datasource_parameters {
    included_namespaces              = ["eaap-app"]
    cluster_scoped_resources_enabled = false
    volume_snapshot_enabled          = false
  }

  depends_on = [
    azurerm_role_assignment.backup_extension_storage_contributor,
    azurerm_role_assignment.backup_vault_reader_on_cluster,
    azurerm_role_assignment.backup_vault_reader_on_snapshot_rg,
    azurerm_role_assignment.backup_vault_snapshot_contributor,
    azurerm_role_assignment.backup_vault_data_operator,
    azurerm_role_assignment.backup_vault_storage_data_contributor,
    azurerm_role_assignment.aks_cluster_contributor_on_snapshot_rg,
    azurerm_kubernetes_cluster_trusted_access_role_binding.backup,
  ]
}
```

`volume_snapshot_enabled = false` is intentional and documented — the sample application has no persistent volumes yet. This backup instance protects the namespace's Kubernetes object definitions (Deployment, Service, and related objects), not application data. The explicit `depends_on` list matters here: this resource will fail if Azure evaluates it before the role assignments it depends on have propagated.

---

## Step 17 — Add Backup Outputs, Format, Validate, and Plan

Create `backup-outputs.tf`:

```hcl
output "backup" {
  description = "EAAP AKS backup resources."
  value = {
    vault_name    = azurerm_data_protection_backup_vault.platform.name
    policy_name   = azurerm_data_protection_backup_policy_kubernetes_cluster.aks.name
    instance_name = azurerm_data_protection_backup_instance_kubernetes_cluster.aks.name
  }
}
```

```powershell
terraform fmt -recursive
terraform validate
terraform plan -out=phase7.tfplan
terraform show phase7.tfplan
```

Review carefully: this plan should only **create** new backup and reliability-related resources. Stop if it proposes replacing or destroying the AKS cluster, existing node pools, or any Workstream 1–6 resource.

Apply:

```powershell
terraform apply phase7.tfplan
terraform output backup
```

> **Provider schema note:** Azure Backup for AKS is a comparatively newer capability area, and exact resource attribute names can shift between provider versions. If `terraform validate` reports an unrecognized argument on any resource in this step, check `terraform providers` for the installed `azurerm` version and consult the current registry documentation for that resource rather than guessing or removing the attribute silently.

---

## Step 18 — Validate the Backup Infrastructure

```powershell
az dataprotection backup-vault show `
  --resource-group "rg-eaap-operations-dev" `
  --vault-name "bvault-eaap-dev-scus-001" `
  --query "{Name:name,ProvisioningState:properties.provisioningState}" `
  --output table

az k8s-extension show `
  --resource-group "rg-eaap-platform-dev" `
  --cluster-name "aks-eaap-dev-scus-001" `
  --cluster-type managedClusters `
  --name "aks-backup-extension" `
  --query "{Name:name,State:provisioningState}" `
  --output table
```

Both should report `Succeeded`.

---

## Step 19 — Trigger and Validate a Backup

The scheduled policy will run on its own interval, but for evidence purposes trigger an on-demand backup rather than waiting a full week:

```powershell
az dataprotection backup-instance list `
  --resource-group "rg-eaap-operations-dev" `
  --vault-name "bvault-eaap-dev-scus-001" `
  --output table
```

```powershell
$backupInstanceId = az dataprotection backup-instance list `
  --resource-group "rg-eaap-operations-dev" `
  --vault-name "bvault-eaap-dev-scus-001" `
  --query "[0].id" --output tsv

az dataprotection backup-instance adhoc-backup `
  --ids "$backupInstanceId" `
  --rule-name "Default"
```

Track the job to completion:

```powershell
az dataprotection job list `
  --resource-group "rg-eaap-operations-dev" `
  --vault-name "bvault-eaap-dev-scus-001" `
  --query "[].{Operation:operation,Status:status,StartTime:startTime}" `
  --output table
```

> **CLI syntax note:** `az dataprotection` command flags have changed across CLI versions as this feature matured. If a command in this step returns an "unrecognized argument" error, run `az dataprotection backup-instance adhoc-backup --help` and `az dataprotection job list --help` to confirm current flag names before troubleshooting further.

Do not proceed to the restore test until at least one backup job shows `Status: Completed`.

---

## Step 20 — Restore Test: Delete and Recover the Namespace Objects

Record the start time, then delete the application's Deployment and Service to simulate accidental deletion:

```powershell
$restoreTestStart = Get-Date
Write-Host "Restore test started: $restoreTestStart"

kubectl delete deployment eaap-sample-web -n eaap-app
kubectl delete service eaap-sample-web -n eaap-app
kubectl get pods -n eaap-app
```

Confirm the pods are gone before continuing — this is what makes the restore test real evidence rather than a no-op.

Trigger a restore of the backed-up namespace resources into the same cluster:

```powershell
az dataprotection backup-instance restore initialize-for-data-recovery `
  --datasource-type AzureKubernetesService `
  --restore-location "southcentralus" `
  --source-datastore OperationalStore `
  --recovery-point-id "<RECOVERY_POINT_ID>" `
  --backup-instance-id "$backupInstanceId"
```

> **CLI syntax note:** The exact `az dataprotection backup-instance restore` subcommand and required parameters (recovery point ID, target resource group, conflict policy) depend on the installed CLI/extension version. Retrieve a valid recovery point ID first with `az dataprotection recovery-point list --resource-group "rg-eaap-operations-dev" --vault-name "bvault-eaap-dev-scus-001" --backup-instance-name <name> --output table`, then confirm the exact restore command syntax with `az dataprotection backup-instance restore --help` before running it. Do not guess at required parameters for a destructive-adjacent operation.

Once the restore operation reports success, confirm recovery:

```powershell
kubectl get deployment -n eaap-app
kubectl get pods -n eaap-app
kubectl get service -n eaap-app

$restoreTestEnd = Get-Date
Write-Host "Restore completed: $restoreTestEnd"
Write-Host "Total recovery time: $($restoreTestEnd - $restoreTestStart)"
```

Compare the measured recovery time against a defined RTO target (for example, "under 15 minutes for namespace-level Kubernetes object recovery") and record the actual result in the case study rather than leaving the target aspirational.

---

## Step 21 — Correlate the Tests in Log Analytics

```powershell
$workspaceId = az monitor log-analytics workspace show `
  --resource-group "rg-eaap-operations-dev" `
  --workspace-name "law-eaap-ops-dev-scus-001" `
  --query customerId --output tsv
```

Confirm the scale event:

```powershell
az monitor log-analytics query `
  --workspace "$workspaceId" `
  --analytics-query "KubePodInventory | where TimeGenerated > ago(2h) | where Namespace == 'eaap-app' | summarize Count=dcount(Name) by bin(TimeGenerated, 5m) | order by TimeGenerated asc" `
  --output table
```

Confirm the drain and restore produced Kubernetes events:

```powershell
az monitor log-analytics query `
  --workspace "$workspaceId" `
  --analytics-query "KubeEvents | where TimeGenerated > ago(2h) | where Namespace == 'eaap-app' | project TimeGenerated, Reason, Message | order by TimeGenerated desc | take 50" `
  --output table
```

---

## Step 22 — Clean Terraform Plan

```powershell
cd .\terraform\environments\dev
terraform plan
```

Expected: `No changes. Your infrastructure matches the configuration.`

---

## Step 23 — Capture Evidence

Save under:

```text
screenshots/phase-7/
```

Recommended:

```text
01-hpa-scale-out.png
02-cluster-autoscaler.png
03-pdb.png
04-node-drain.png
05-backup-vault.png
06-backup-job.png
07-deleted-objects.png
08-restore-complete.png
09-kql-correlation.png
10-clean-plan.png
```

---

## Step 24 — Commit Workstream 7

```powershell
cd ..\..\..

git add .\docs\phase-7-reliability-recovery-case-study.md
git add .\runbooks\phase-7-reliability-recovery-runbook.md
git add .\app\k8s\app-release.yaml
git add .\app\k8s\app-reliability.yaml
git add .\terraform\environments\dev\backup-variables.tf
git add .\terraform\environments\dev\backup.tf
git add .\terraform\environments\dev\backup-outputs.tf
git add .\terraform\environments\dev\terraform.tfvars.example
git add .\screenshots\phase-7

git status
git diff --cached --name-only

git commit -m "Complete Workstream 7 reliability and recovery"
git pull --rebase origin main
git push origin main
```

---

## Troubleshooting

### HPA shows `<unknown>/70%` indefinitely

Confirm the metrics pipeline is actually returning data:

```powershell
kubectl top pods -n eaap-app
```

If this also fails, confirm the Deployment has resource requests set (Step 4) — the HPA cannot calculate utilization without a request to divide against.

### Cluster autoscaler never adds a node

Confirm the `apps` node pool actually has headroom to grow:

```powershell
az aks nodepool show `
  --resource-group "rg-eaap-platform-dev" `
  --cluster-name "aks-eaap-dev-scus-001" `
  --name "apps" `
  --query "{Min:minCount,Max:maxCount,Current:count,AutoScaling:enableAutoScaling}" `
  --output table
```

If `Current` already equals `Max`, the autoscaler is working correctly — there is simply no more room, which is itself useful evidence of the lab's intentional cost ceiling.

### `kubectl drain` hangs

A PDB with `minAvailable` set higher than the number of healthy replicas elsewhere will block eviction indefinitely. Confirm replica count and PDB math before assuming this is broken — the drain hanging while the app stays available is the desired outcome; it should still complete once a replacement pod is Ready on another node.

### `azurerm_data_protection_backup_instance_kubernetes_cluster` fails to apply

This resource is extremely sensitive to role-assignment propagation timing. If the apply fails with an authorization error, wait several minutes and re-run `terraform apply` rather than changing the configuration — the `depends_on` list in Step 16 establishes ordering but Azure RBAC propagation can still lag behind Terraform's own completion signal.

### Backup job fails or stays `InProgress` indefinitely

Confirm the extension identity actually has `Storage Account Contributor` on the backup storage account, and that the storage account firewall (if hardened later) is not blocking the extension's access. Check extension pod health directly:

```powershell
kubectl get pods -n dataprotection-microsoft
kubectl logs -n dataprotection-microsoft -l app.kubernetes.io/name=dataprotection-microsoft-generic
```

### Restore fails with a conflict on existing resources

If the delete step in Step 20 did not fully remove the target objects, the restore may refuse to overwrite them depending on the configured conflict policy. Confirm the Deployment and Service are actually gone before retrying:

```powershell
kubectl get deployment,service -n eaap-app
```

---

## Cost Control

```powershell
az aks stop `
  --resource-group "rg-eaap-platform-dev" `
  --name "aks-eaap-dev-scus-001"
```

The backup vault, storage account, and Log Analytics workspace remain available and billed independently of whether AKS is running. Review the backup storage account and vault retention settings if cost becomes a concern for the lab environment — `P30D` default retention keeps this bounded.

---

## Workstream Completion Criteria

Workstream 7 is complete when:

- [ ] Application deployment has explicit resource requests and limits
- [ ] HPA exists and reports real CPU utilization numbers
- [ ] PDB exists and matches the application's pod selector
- [ ] Load test demonstrably scales pod replicas
- [ ] Load test demonstrably scales node count when capacity is exhausted
- [ ] Node drain completes with zero failed requests against the service
- [ ] Backup vault, extension, policy, and instance are all deployed successfully
- [ ] At least one backup job completes with `Status: Completed`
- [ ] Namespace objects are deliberately deleted and successfully restored
- [ ] Measured recovery time is recorded against a defined RTO target
- [ ] KQL queries in the Workstream 6 workspace correlate with the scale, drain, and restore events
- [ ] Follow-up Terraform plan is clean
- [ ] Evidence is captured and sanitized

---

## Next Workstream

**Workstream 8 — Platform Security** builds on this reliability foundation by enabling Microsoft Defender for Cloud plans, applying Azure Policy governance scoped to the EAAP resource groups, and enabling the AKS Azure Policy add-on for in-cluster admission control.
