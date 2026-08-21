<div align="center">

# Workstream 8 Runbook: Platform Security
### Microsoft Defender for Cloud, Azure Policy Governance, and AKS Admission Control

</div>

---

## Purpose

This runbook adds detective and enforcing security controls to the EAAP platform after Workstream 7 is complete.

You will:

1. Confirm Workstream 7 is healthy and Terraform is clean.
2. Enable Microsoft Defender for Cloud plans at subscription scope.
3. Enable the AKS Azure Policy add-on.
4. Assign a scoped set of built-in Azure Policy definitions in Audit mode.
5. Validate Gatekeeper constraints inside the cluster.
6. Push a fresh image and validate a real vulnerability finding.
7. Review policy compliance state and Secure Score.
8. Capture evidence and commit.

> **Subscription-scope note:** Defender for Cloud plans apply to the entire subscription, which is shared with the Azure AI Infrastructure project. This is expected and documented — do not attempt to scope these to a resource group; Azure does not support that for Defender plans.

---

## Target Resources

| Resource | Scope | Effect |
|---|---|---|
| Defender plan: Containers | Subscription | Standard |
| Defender plan: KeyVaults | Subscription | Standard |
| Defender plan: CloudPosture | Subscription | Standard |
| AKS Azure Policy add-on | `aks-eaap-dev-scus-001` | Enabled |
| Policy: privileged containers | `rg-eaap-platform-dev` | Audit |
| Policy: host PID/IPC namespace sharing | `rg-eaap-platform-dev` | Audit |
| Policy: allowed container images | `rg-eaap-platform-dev` | Audit |
| Policy: ACR network access | `rg-eaap-platform-dev` | Audit |

---

## Step 1 — Restore the Engineering Session

```powershell
cd "$HOME\Documents\enterprise-azure-application-platform"
code .

az account show --query "{Name:name,State:state,IsDefault:isDefault}" --output table
$env:ARM_SUBSCRIPTION_ID = az account show --query id -o tsv
$env:AZURE_SUBSCRIPTION_ID = $env:ARM_SUBSCRIPTION_ID
```

---

## Step 2 — Confirm Workstream 7 Is Healthy

```powershell
kubectl get nodes
kubectl get hpa -n eaap-app
kubectl get pdb -n eaap-app
kubectl get deployment -n eaap-app
```

```powershell
cd .\terraform\environments\dev
terraform init -upgrade -reconfigure -backend-config="backend.hcl"
terraform validate
terraform plan
```

Expected: `No changes. Your infrastructure matches the configuration.`

---

## Step 3 — Register the Security Resource Provider

```powershell
az provider register --namespace Microsoft.Security --wait
az provider register --namespace Microsoft.PolicyInsights --wait

az provider list `
  --query "[?namespace=='Microsoft.Security' || namespace=='Microsoft.PolicyInsights'].{Provider:namespace,State:registrationState}" `
  --output table
```

---

## Step 4 — Enable Microsoft Defender for Cloud Plans

Create `security-center.tf`:

```powershell
New-Item -ItemType File -Name "security-center.tf" -Force
code .\security-center.tf
```

Paste:

```hcl
resource "azurerm_security_center_subscription_pricing" "containers" {
  tier          = "Standard"
  resource_type = "Containers"
}

resource "azurerm_security_center_subscription_pricing" "key_vaults" {
  tier          = "Standard"
  resource_type = "KeyVaults"
}

resource "azurerm_security_center_subscription_pricing" "cloud_posture" {
  tier          = "Standard"
  resource_type = "CloudPosture"

  extension {
    name = "ContainerRegistriesVulnerabilityAssessments"
  }
}
```

These are subscription-scoped resources — they do not accept a `resource_group_name` argument, and they will affect Defender status for every resource of that type in the subscription, including the sibling Azure AI Infrastructure project.

---

## Step 5 — Enable the AKS Azure Policy Add-on

Open:

```powershell
code .\aks.tf
```

Inside the existing `azurerm_kubernetes_cluster "platform"` resource, alongside the other top-level cluster arguments (near `oidc_issuer_enabled` and `workload_identity_enabled`), add:

```hcl
  azure_policy_enabled = true
```

Do not create another AKS resource, and confirm the separate `azurerm_kubernetes_cluster_node_pool.apps` resource below the cluster block is still present before saving.

---

## Step 6 — Look Up the Built-In Policy Definitions

Create `policy-governance.tf`:

```powershell
New-Item -ItemType File -Name "policy-governance.tf" -Force
code .\policy-governance.tf
```

Paste the data source lookups first — using `display_name` avoids hardcoding policy definition GUIDs that can vary by cloud environment:

```hcl
data "azurerm_policy_definition_built_in" "no_privileged_containers" {
  display_name = "Kubernetes cluster should not allow privileged containers"
}

data "azurerm_policy_definition_built_in" "no_host_namespace_sharing" {
  display_name = "Kubernetes cluster containers should not share host process ID or host IPC namespace"
}

data "azurerm_policy_definition_built_in" "allowed_container_images" {
  display_name = "Kubernetes cluster containers should only use allowed images"
}

data "azurerm_policy_definition_built_in" "acr_network_restriction" {
  display_name = "Container registries should not allow unrestricted network access"
}
```

> **Note:** `display_name` is not guaranteed unique across the full built-in policy catalog. If `terraform plan` reports more than one match, switch to `name` (the built-in policy's GUID) instead — look it up once in the Azure Portal under **Policy → Definitions** by searching the same display name, or via `az policy definition list --query "[?displayName=='<name>'].name" --output tsv`.

---

## Step 7 — Assign the Policies in Audit Mode

Append to `policy-governance.tf`:

```hcl
resource "azurerm_resource_group_policy_assignment" "no_privileged_containers" {
  name                 = "eaap-no-privileged-containers"
  resource_group_id    = azurerm_resource_group.landing_zone["platform"].id
  policy_definition_id = data.azurerm_policy_definition_built_in.no_privileged_containers.id
  display_name         = "EAAP - No privileged containers (Audit)"

  parameters = jsonencode({
    effect = {
      value = "Audit"
    }
  })
}

resource "azurerm_resource_group_policy_assignment" "no_host_namespace_sharing" {
  name                 = "eaap-no-host-namespace-sharing"
  resource_group_id    = azurerm_resource_group.landing_zone["platform"].id
  policy_definition_id = data.azurerm_policy_definition_built_in.no_host_namespace_sharing.id
  display_name         = "EAAP - No host PID/IPC namespace sharing (Audit)"

  parameters = jsonencode({
    effect = {
      value = "Audit"
    }
  })
}

resource "azurerm_resource_group_policy_assignment" "allowed_container_images" {
  name                 = "eaap-allowed-container-images"
  resource_group_id    = azurerm_resource_group.landing_zone["platform"].id
  policy_definition_id = data.azurerm_policy_definition_built_in.allowed_container_images.id
  display_name         = "EAAP - Allowed container image registries (Audit)"

  parameters = jsonencode({
    effect = {
      value = "Audit"
    }
    excludedNamespaces = {
      value = ["kube-system", "gatekeeper-system", "dataprotection-microsoft"]
    }
    allowedContainerImagesRegex = {
      value = "^acreaapdev5803\\.azurecr\\.io/.+$"
    }
  })
}

resource "azurerm_resource_group_policy_assignment" "acr_network_restriction" {
  name                 = "eaap-acr-network-restriction"
  resource_group_id    = azurerm_resource_group.landing_zone["platform"].id
  policy_definition_id = data.azurerm_policy_definition_built_in.acr_network_restriction.id
  display_name         = "EAAP - ACR network restriction (Audit)"

  parameters = jsonencode({
    effect = {
      value = "Audit"
    }
  })
}
```

> **Parameter names vary by policy.** Built-in policy parameter names (`effect`, `excludedNamespaces`, `allowedContainerImagesRegex`, etc.) are specific to each definition and occasionally change between Azure Policy catalog updates. Before applying, check each policy's actual parameter schema:
>
> ```powershell
> az policy definition show --name "<policy-definition-guid-or-name>" --query "parameters" --output json
> ```
>
> Adjust the `parameters` block in this step to match what the installed catalog actually expects rather than assuming the names above are exact for your subscription's policy catalog version.

All four assignments are deliberately scoped to `rg-eaap-platform-dev` only — not the subscription, and not the network resource group — so this workstream's governance stays inside the same resource-group boundary the platform has used since Workstream 1.

---

## Step 8 — Format, Validate, Plan, and Apply

```powershell
terraform fmt -recursive
terraform validate
terraform plan -out=phase8.tfplan
terraform show phase8.tfplan
```

Expected: several new `azurerm_security_center_subscription_pricing`, `azurerm_resource_group_policy_assignment` resources, and one **in-place update** to the existing AKS cluster for `azure_policy_enabled`. Stop if AKS shows as replaced or destroyed.

```powershell
terraform apply phase8.tfplan
```

Allow several minutes for the AKS Azure Policy add-on to deploy its Gatekeeper components, and for policy assignments to propagate to the evaluation engine.

---

## Step 9 — Validate Defender for Cloud Plans

```powershell
az security pricing list `
  --query "value[?name=='Containers' || name=='KeyVaults' || name=='CloudPosture'].{Plan:name,Tier:pricingTier}" `
  --output table
```

Expected: `Standard` for all three.

---

## Step 10 — Validate the AKS Policy Add-on and Gatekeeper

```powershell
az aks show `
  --resource-group "rg-eaap-platform-dev" `
  --name "aks-eaap-dev-scus-001" `
  --query "addonProfiles.azurepolicy" `
  --output json
```

Expected: `enabled: true`.

```powershell
kubectl get pods -n gatekeeper-system
kubectl get constrainttemplates
kubectl get constraints
```

Constraint templates and constraints should appear a few minutes after the assignments in Step 7 propagate — Azure Policy periodically syncs assignments into the cluster rather than instantly.

---

## Step 11 — Validate Policy Compliance State

```powershell
az policy state list `
  --resource-group "rg-eaap-platform-dev" `
  --query "[].{Policy:policyDefinitionName,Resource:resourceId,Compliance:complianceState}" `
  --output table
```

Compliance state may show `Unknown` for a period after assignment while the first evaluation cycle runs. Re-check after 15–30 minutes if results look incomplete rather than assuming the assignment failed.

---

## Step 12 — Generate a Real Vulnerability Finding

Use the existing Phase 5 pipeline to push a fresh image now that Defender for Containers is scanning:

```text
GitHub
→ Actions
→ EAAP Deploy to AKS
→ Run workflow
→ main
```

After the workflow completes and the image has had time to be scanned (this is not instantaneous), review findings:

```powershell
az acr repository show-tags `
  --name "acreaapdev5803" `
  --repository "eaap-sample-web" `
  --orderby time_desc `
  --top 5 `
  --output table
```

Review vulnerability assessment results in the Azure Portal under:

```text
Microsoft Defender for Cloud
→ Recommendations
→ "Container registry images should have vulnerability findings resolved"
```

An `nginx:1.27-alpine` base image will likely surface at least low-severity OS package findings — that is expected and is itself the evidence: the scanning pipeline is real and working, not that the sample image is production-hardened.

---

## Step 13 — Review Secure Score

In the Azure Portal:

```text
Microsoft Defender for Cloud
→ Overview
→ Secure Score
```

Capture the score and the specific recommendations tied to the EAAP resource groups. The score reflects the entire subscription, so note explicitly in your evidence which recommendations are attributable to EAAP resources versus the sibling project.

---

## Step 14 — Clean Terraform Plan

```powershell
cd .\terraform\environments\dev
terraform plan
```

Expected: `No changes. Your infrastructure matches the configuration.`

---

## Step 15 — Capture Evidence

Save under:

```text
screenshots/phase-8/
```

Recommended:

```text
01-defender-plans.png
02-secure-score.png
03-aks-policy-addon.png
04-gatekeeper-constraints.png
05-policy-compliance.png
06-acr-vulnerability.png
07-clean-plan.png
```

---

## Step 16 — Commit Workstream 8

```powershell
cd ..\..\..

git add .\docs\phase-8-platform-security-case-study.md
git add .\runbooks\phase-8-platform-security-runbook.md
git add .\terraform\environments\dev\security-center.tf
git add .\terraform\environments\dev\policy-governance.tf
git add .\terraform\environments\dev\aks.tf
git add .\screenshots\phase-8

git status
git diff --cached --name-only

git commit -m "Complete Workstream 8 platform security"
git pull --rebase origin main
git push origin main
```

---

## Troubleshooting

### `terraform plan` shows AKS being replaced after adding `azure_policy_enabled`

Stop. This should always be an in-place update. Confirm the attribute was added inside the existing `azurerm_kubernetes_cluster "platform"` block and not accidentally placed in a way that changes an immutable argument.

### Gatekeeper pods never appear

Confirm the add-on actually reports enabled (Step 10) before checking pods — allow several minutes after apply for AKS to reconcile the add-on and deploy Gatekeeper.

### Policy assignment `terraform apply` fails with a parameter validation error

The built-in policy's actual parameter names or allowed values don't match what was assumed in Step 7. Run:

```powershell
az policy definition show --name "<policy-name-or-guid>" --query "parameters" --output json
```

and correct the `parameters` block in `policy-governance.tf` to match exactly.

### `data.azurerm_policy_definition_built_in` returns "more than one policy definition found"

Switch from `display_name` to the exact built-in `name` (GUID) for that lookup, found via:

```powershell
az policy definition list --query "[?displayName=='<exact display name>'].{Name:name,DisplayName:displayName}" --output table
```

### ACR vulnerability findings never appear

Confirm the `CloudPosture` plan's `ContainerRegistriesVulnerabilityAssessments` extension was actually applied (Step 4), and allow more time — initial image scans after enabling the plan are not instantaneous and can take longer than a routine rescan of a previously scanned image.

### Policy compliance state stays `Unknown`

This is normal immediately after assignment. Azure Policy's evaluation cycle runs on its own schedule; re-check after 15–30 minutes before troubleshooting further.

---

## Cost Control

Defender for Cloud Standard tier plans and Azure Policy evaluation both carry cost implications at the subscription level. Review:

```text
Microsoft Defender for Cloud
→ Environment settings
→ <subscription>
→ Pricing tiers
```

before leaving these enabled indefinitely in a personal-lab subscription, and be aware that disabling a Defender plan later resets it to `Free` rather than partially refunding usage already incurred.

---

## Workstream Completion Criteria

Workstream 8 is complete when:

- [ ] Defender for Cloud plans for Containers, Key Vaults, and CloudPosture report `Standard`
- [ ] AKS Azure Policy add-on reports `enabled: true`
- [ ] Gatekeeper pods are Running and constraint templates/constraints exist
- [ ] All four policy assignments exist, scoped to `rg-eaap-platform-dev`, in `Audit` mode
- [ ] Policy compliance state has been reviewed for the EAAP resource groups
- [ ] A real vulnerability assessment finding exists on a pushed EAAP image
- [ ] Secure Score has been reviewed and EAAP-attributable recommendations identified
- [ ] Follow-up Terraform plan is clean
- [ ] Evidence is captured and sanitized

---

## Next Workstream

**Workstream 9 — Operations and Handoff** closes out the portfolio project with cost and cleanup automation, consolidated troubleshooting and support documentation, and a final end-to-end validation pass across all eight prior workstreams.
