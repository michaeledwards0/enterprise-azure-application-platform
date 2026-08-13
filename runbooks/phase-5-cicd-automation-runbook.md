<div align="center">

# Workstream 5 Runbook: CI/CD Automation
### GitHub Actions, OIDC Federation, Terraform Validation, ACR Publishing, and AKS Deployment

</div>

---

## Purpose

This runbook automates the EAAP application-delivery path after the AKS container platform is healthy.

You will:

1. Confirm the corrected Workstream 4 platform is healthy.
2. Create a dedicated GitHub Actions managed identity.
3. Configure GitHub OIDC federation through the `dev` environment.
4. Assign scoped ACR and AKS permissions.
5. Create a CI workflow for Terraform and Docker validation.
6. Create a CD workflow that builds and pushes a Git-SHA image.
7. Temporarily allow the GitHub-hosted runner to reach the restricted AKS API.
8. Deploy the image to the `eaap-app` namespace.
9. Restore the original AKS API authorized-IP list.
10. Validate the release and capture evidence.

> **Security model:** No Azure client secret or service-principal password is stored in GitHub. The deployment job uses GitHub OIDC and Microsoft Entra workload identity federation.

> **Terraform model:** CI validates Terraform but does not run `terraform apply`. Infrastructure changes remain reviewed and applied from the engineering workstation in this phase.

---

## Phase 4 Execution Correction — Confirm Before Continuing

Workstream 4 originally inherited an explicit catch-all inbound deny rule on the AKS workload subnet. During execution, that rule blocked required AKS admission-webhook/control-plane communication and prevented application pods from being created.

The working Phase 4 state should now have:

- The catch-all `Deny-Other-Inbound-To-Workload` custom rule removed.
- AKS-required platform communication preserved.
- `Network Contributor` for the AKS cluster identity on both the workload and ingress subnets where required.
- Two Ready application pods.
- Internal LoadBalancer frontend `10.20.1.10`.

Do **not** reintroduce the generic catch-all deny rule just to match the earlier Phase 2 draft. Kubernetes/Cilium Network Policies should provide workload-level segmentation later.

---

## Target Resources and Files

| Item | Name or Path |
|---|---|
| GitHub Actions managed identity | `id-eaap-github-actions-dev-scus-001` |
| Federated credential | `fic-eaap-github-dev` |
| GitHub Environment | `dev` |
| CI workflow | `.github/workflows/eaap-ci.yml` |
| CD workflow | `.github/workflows/eaap-deploy.yml` |
| Kubernetes namespace | `eaap-app` |
| Image repository | `eaap-sample-web` |
| Phase 5 Terraform | `terraform/environments/dev/cicd-identity.tf` |
| Phase 5 outputs | `terraform/environments/dev/cicd-outputs.tf` |

---

## Step 1 — Restore the Engineering Session

From PowerShell:

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

Check power state:

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

Validate Kubernetes:

```powershell
kubectl get nodes
kubectl get deployment -n eaap-app
kubectl get pods -n eaap-app
kubectl get service -n eaap-app
```

Expected baseline:

```text
Deployment: 2/2 Ready
Pods:       2 Running
Service IP: 10.20.1.10
```

---

## Step 3 — Confirm Terraform Is Clean

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

Stop if there is unexplained drift.

---

## Step 4 — Add the GitHub Repository Variable

Create:

```powershell
New-Item -ItemType File -Name "cicd-variables.tf" -Force
code .\cicd-variables.tf
```

Paste:

```hcl
variable "github_repository" {
  description = "GitHub repository trusted by the deployment identity in OWNER/REPO format."
  type        = string
  default     = "michaeledwards0/enterprise-azure-application-platform"
}
```

This value is not a secret.

---

## Step 5 — Create the GitHub Actions Identity and Federation

Create:

```powershell
New-Item -ItemType File -Name "cicd-identity.tf" -Force
code .\cicd-identity.tf
```

Paste:

```hcl
resource "azurerm_user_assigned_identity" "github_actions" {
  name                = "id-eaap-github-actions-${var.environment}-scus-001"
  location            = azurerm_resource_group.landing_zone["platform"].location
  resource_group_name = azurerm_resource_group.landing_zone["platform"].name

  tags = merge(
    local.common_tags,
    {
      ResourcePurpose = "GitHub-Actions-CICD-Identity"
    }
  )
}

resource "azurerm_federated_identity_credential" "github_dev" {
  name                      = "fic-eaap-github-dev"
  user_assigned_identity_id = azurerm_user_assigned_identity.github_actions.id
  issuer                    = "https://token.actions.githubusercontent.com"
  subject                   = "repo:${var.github_repository}:environment:dev"
  audience                  = ["api://AzureADTokenExchange"]
}
```

Simple meaning:

> Azure will trust a short-lived GitHub OIDC token only when it comes from this repository and the `dev` GitHub Environment.

---

## Step 6 — Assign ACR and AKS Roles

Append to `cicd-identity.tf`:

```hcl
resource "azurerm_role_assignment" "github_acr_push" {
  scope                = azurerm_container_registry.platform.id
  role_definition_name = "AcrPush"
  principal_id         = azurerm_user_assigned_identity.github_actions.principal_id
}

resource "azurerm_role_assignment" "github_aks_contributor" {
  scope                = azurerm_kubernetes_cluster.platform.id
  role_definition_name = "Azure Kubernetes Service Contributor Role"
  principal_id         = azurerm_user_assigned_identity.github_actions.principal_id
}

resource "azurerm_role_assignment" "github_aks_cluster_user" {
  scope                = azurerm_kubernetes_cluster.platform.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = azurerm_user_assigned_identity.github_actions.principal_id
}

resource "azurerm_role_assignment" "github_aks_namespace_writer" {
  scope                = "${azurerm_kubernetes_cluster.platform.id}/namespaces/eaap-app"
  role_definition_name = "Azure Kubernetes Service RBAC Writer"
  principal_id         = azurerm_user_assigned_identity.github_actions.principal_id
}
```

Why the roles are separate:

```text
AcrPush
= push new application images

AKS Contributor
= manage the AKS resource setting needed for temporary runner IP authorization

AKS Cluster User
= retrieve user-level cluster credentials

AKS RBAC Writer on eaap-app
= create/update application objects only in the application namespace
```

---

## Step 7 — Add Phase 5 Outputs

Create:

```powershell
New-Item -ItemType File -Name "cicd-outputs.tf" -Force
code .\cicd-outputs.tf
```

Paste:

```hcl
output "github_actions_identity" {
  description = "Identity used by GitHub Actions OIDC authentication."
  value = {
    name      = azurerm_user_assigned_identity.github_actions.name
    client_id = azurerm_user_assigned_identity.github_actions.client_id
  }
}
```

---

## Step 8 — Format, Validate, Plan, and Apply the Identity Changes

```powershell
terraform fmt
terraform validate
terraform plan -out=phase5.tfplan
terraform show phase5.tfplan
```

Review for unexpected destroys.

Apply:

```powershell
terraform apply phase5.tfplan
```

Allow several minutes for Azure RBAC propagation before the first GitHub deployment test.

Verify:

```powershell
terraform output github_actions_identity
```

---

## Step 9 — Capture the Azure Values Needed by GitHub

Still in the Terraform folder:

```powershell
$githubClientId = terraform output -json github_actions_identity |
  ConvertFrom-Json |
  Select-Object -ExpandProperty client_id

$tenantId = az account show --query tenantId -o tsv
$subscriptionId = az account show --query id -o tsv
$acrName = terraform output -json container_registry |
  ConvertFrom-Json |
  Select-Object -ExpandProperty name
$acrLoginServer = terraform output -json container_registry |
  ConvertFrom-Json |
  Select-Object -ExpandProperty login_server
```

Verify without publishing screenshots containing full IDs:

```powershell
Write-Host "ACR Name: $acrName"
Write-Host "ACR Login Server: $acrLoginServer"
Write-Host "GitHub identity client ID captured:" (-not [string]::IsNullOrWhiteSpace($githubClientId))
Write-Host "Tenant ID captured:" (-not [string]::IsNullOrWhiteSpace($tenantId))
Write-Host "Subscription ID captured:" (-not [string]::IsNullOrWhiteSpace($subscriptionId))
```

---

## Step 10 — Create the GitHub `dev` Environment

In GitHub:

```text
Repository
→ Settings
→ Environments
→ New environment
→ dev
```

Restrict deployment branches to `main` if the repository settings allow it.

Under the `dev` environment, create these secrets:

```text
AZURE_CLIENT_ID
AZURE_TENANT_ID
AZURE_SUBSCRIPTION_ID
```

Use the values captured in Step 9.

These are identifiers used by OIDC. There is **no Azure client secret**.

Create these repository or environment variables:

```text
ACR_NAME=acreaapdev5803
ACR_LOGIN_SERVER=acreaapdev5803.azurecr.io
AKS_RESOURCE_GROUP=rg-eaap-platform-dev
AKS_NAME=aks-eaap-dev-scus-001
K8S_NAMESPACE=eaap-app
```

Use your actual ACR name/login server if different.

---

## Step 11 — Create the CI Workflow

Return to the repository root:

```powershell
cd ..\..\..
New-Item -ItemType Directory -Force -Path ".\.github\workflows"
code .\.github\workflows\eaap-ci.yml
```

Paste:

```yaml
name: EAAP CI Validation

on:
  pull_request:
    paths:
      - "terraform/**"
      - "app/**"
      - ".github/workflows/eaap-ci.yml"
  push:
    branches: [main]
    paths:
      - "terraform/**"
      - "app/**"
      - ".github/workflows/eaap-ci.yml"

permissions:
  contents: read

jobs:
  validate:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3

      - name: Terraform format check
        run: terraform fmt -check -recursive

      - name: Terraform init without remote backend
        working-directory: terraform/environments/dev
        run: terraform init -backend=false

      - name: Terraform validate
        working-directory: terraform/environments/dev
        run: terraform validate

      - name: Validate Docker build
        run: docker build -t eaap-sample-web:ci ./app/sample-web
```

Simple meaning:

> CI proves the Terraform syntax and Docker build are healthy before deployment. It does not need Azure access and does not change infrastructure.

---

## Step 12 — Create the CD Workflow

Create:

```powershell
code .\.github\workflows\eaap-deploy.yml
```

Paste:

```yaml
name: EAAP Deploy to AKS

on:
  workflow_dispatch:
  push:
    branches: [main]
    paths:
      - "app/sample-web/**"
      - "app/k8s/**"
      - ".github/workflows/eaap-deploy.yml"

permissions:
  contents: read
  id-token: write

env:
  IMAGE_REPOSITORY: eaap-sample-web

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: dev

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Azure login with OIDC
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Capture original AKS authorized IP ranges
        shell: bash
        run: |
          ORIGINAL_RANGES=$(az aks show \
            --resource-group "${{ vars.AKS_RESOURCE_GROUP }}" \
            --name "${{ vars.AKS_NAME }}" \
            --query "apiServerAccessProfile.authorizedIpRanges" \
            --output tsv | tr '\t' ',')

          echo "ORIGINAL_AKS_RANGES=$ORIGINAL_RANGES" >> "$GITHUB_ENV"

      - name: Temporarily allow GitHub runner to AKS API
        shell: bash
        run: |
          RUNNER_IP=$(curl -fsSL https://api.ipify.org)
          echo "Runner IP detected."

          if [ -n "$ORIGINAL_AKS_RANGES" ]; then
            NEW_RANGES="$ORIGINAL_AKS_RANGES,$RUNNER_IP/32"
          else
            NEW_RANGES="$RUNNER_IP/32"
          fi

          az aks update \
            --resource-group "${{ vars.AKS_RESOURCE_GROUP }}" \
            --name "${{ vars.AKS_NAME }}" \
            --api-server-authorized-ip-ranges "$NEW_RANGES" \
            --output none

      - name: Login to ACR
        run: az acr login --name "${{ vars.ACR_NAME }}"

      - name: Build and push image
        shell: bash
        run: |
          IMAGE_TAG="${GITHUB_SHA::12}"
          IMAGE="${{ vars.ACR_LOGIN_SERVER }}/${IMAGE_REPOSITORY}:${IMAGE_TAG}"
          echo "IMAGE=$IMAGE" >> "$GITHUB_ENV"
          docker build -t "$IMAGE" ./app/sample-web
          docker push "$IMAGE"

      - name: Setup kubectl
        uses: azure/setup-kubectl@v4

      - name: Setup kubelogin
        uses: azure/use-kubelogin@v1

      - name: Connect to AKS
        shell: bash
        run: |
          az aks get-credentials \
            --resource-group "${{ vars.AKS_RESOURCE_GROUP }}" \
            --name "${{ vars.AKS_NAME }}" \
            --overwrite-existing
          kubelogin convert-kubeconfig -l azurecli

      - name: Prepare release manifest
        shell: bash
        run: |
          cp app/k8s/platform.yaml app/k8s/platform-release.yaml
          sed -i "s#image: .*eaap-sample-web.*#image: ${IMAGE}#" app/k8s/platform-release.yaml

      - name: Deploy to AKS
        run: kubectl apply -f app/k8s/platform-release.yaml

      - name: Validate rollout
        run: |
          kubectl rollout status deployment/eaap-sample-web \
            -n "${{ vars.K8S_NAMESPACE }}" \
            --timeout=180s
          kubectl get pods -n "${{ vars.K8S_NAMESPACE }}" -o wide
          kubectl get service -n "${{ vars.K8S_NAMESPACE }}"

      - name: Restore original AKS authorized IP ranges
        if: always()
        shell: bash
        run: |
          if [ -n "$ORIGINAL_AKS_RANGES" ]; then
            az aks update \
              --resource-group "${{ vars.AKS_RESOURCE_GROUP }}" \
              --name "${{ vars.AKS_NAME }}" \
              --api-server-authorized-ip-ranges "$ORIGINAL_AKS_RANGES" \
              --output none
          fi
```

> **Important:** The `always()` cleanup step is intentional. It attempts to restore the AKS API allowlist even if the build or deployment fails.

---

## Step 13 — Commit the Phase 5 Files

From the repository root:

```powershell
git status
```

Stage:

```powershell
git add .\docs\phase-5-cicd-automation
git add .\runbooks\phase-5-cicd-automation-runbook.md
git add .\terraform\environments\dev\cicd-variables.tf
git add .\terraform\environments\dev\cicd-identity.tf
git add .\terraform\environments\dev\cicd-outputs.tf
git add .\.github\workflows\eaap-ci.yml
git add .\.github\workflows\eaap-deploy.yml
```

Review:

```powershell
git diff --cached --name-only
git diff --cached
```

Commit:

```powershell
git commit -m "Add Workstream 5 CI/CD automation"
```

Synchronize and push:

```powershell
git pull --rebase origin main
git push origin main
```

---

## Step 14 — Watch the GitHub Actions Run

In GitHub:

```text
Repository
→ Actions
→ EAAP CI Validation
```

Confirm CI passes.

Then open:

```text
EAAP Deploy to AKS
```

Confirm the job successfully completes:

```text
OIDC Azure login
Temporary AKS API allowlist
ACR login
Docker build
Docker push
AKS authentication
Manifest deployment
Rollout validation
AKS API allowlist restoration
```

---

## Step 15 — Validate from the Workstation

Verify the newest image tags:

```powershell
az acr repository show-tags `
  --name "$acrName" `
  --repository "eaap-sample-web" `
  --orderby time_desc `
  --top 10 `
  --output table
```

Verify deployment image:

```powershell
kubectl get deployment eaap-sample-web `
  -n eaap-app `
  -o jsonpath="{.spec.template.spec.containers[0].image}"
```

Verify replicas:

```powershell
kubectl get deployment -n eaap-app
kubectl get pods -n eaap-app -o wide
kubectl get service -n eaap-app
```

Verify AKS API authorized ranges were restored:

```powershell
az aks show `
  --resource-group "rg-eaap-platform-dev" `
  --name "aks-eaap-dev-scus-001" `
  --query "apiServerAccessProfile.authorizedIpRanges" `
  --output table
```

---

## Step 16 — Validate Terraform After the Pipeline

```powershell
cd .\terraform\environments\dev
terraform plan
```

Expected:

```text
No changes. Your infrastructure matches the configuration.
```

The GitHub deployment changes Kubernetes application objects and image versions. It should not create unexplained Terraform drift in Azure infrastructure.

---

## Step 17 — Capture Evidence

Save screenshots under:

```text
screenshots/phase-5/
```

Recommended names:

```text
01-github-actions-identity.png
02-federated-credential.png
03-cicd-rbac.png
04-ci-workflow.png
05-cd-workflow.png
06-acr-sha-image.png
07-aks-rollout.png
08-running-pods.png
09-api-allowlist-restored.png
10-clean-plan.png
```

Do not expose full subscription IDs, tenant IDs, client IDs, access tokens, or GitHub secret values.

---

## Troubleshooting

### OIDC login fails with subject mismatch

Confirm the deployment job contains:

```yaml
environment: dev
```

Then verify the Azure federated credential subject is:

```text
repo:michaeledwards0/enterprise-azure-application-platform:environment:dev
```

### `az acr login` works but Docker push returns unauthorized

Check:

```powershell
$githubPrincipalId = az identity show `
  --name "id-eaap-github-actions-dev-scus-001" `
  --resource-group "rg-eaap-platform-dev" `
  --query principalId -o tsv

az role assignment list `
  --assignee "$githubPrincipalId" `
  --scope "$(az acr show --name $acrName --query id -o tsv)" `
  --output table
```

Look for `AcrPush`.

### `kubectl` returns Forbidden

Confirm both permission layers:

```text
Azure Kubernetes Service Cluster User Role
Azure Kubernetes Service RBAC Writer at /namespaces/eaap-app
```

Allow several minutes for new Azure role assignments to propagate.

### GitHub runner times out connecting to AKS

Check the workflow log to confirm the runner `/32` was successfully added to the API authorized-IP list before `az aks get-credentials` and `kubectl` commands.

### Cleanup did not restore authorized IPs

From your workstation, immediately restore the approved list through Terraform or:

```powershell
az aks update `
  --resource-group "rg-eaap-platform-dev" `
  --name "aks-eaap-dev-scus-001" `
  --api-server-authorized-ip-ranges "<YOUR_APPROVED_CIDR>"
```

Then update the Terraform variable if the approved administrator CIDR has changed.

---

## Cost Control

The GitHub Actions identity itself does not create meaningful compute cost. ACR storage and AKS nodes remain the primary resources in this workstream.

After validation, AKS can be stopped during a pause:

```powershell
az aks stop `
  --resource-group "rg-eaap-platform-dev" `
  --name "aks-eaap-dev-scus-001"
```

Restart before the next deployment:

```powershell
az aks start `
  --resource-group "rg-eaap-platform-dev" `
  --name "aks-eaap-dev-scus-001"
```

---

## Workstream Completion Criteria

Workstream 5 is complete when:

- [ ] Dedicated GitHub Actions managed identity exists
- [ ] OIDC federated credential trusts the EAAP `dev` environment
- [ ] No Azure client secret is stored in GitHub
- [ ] `AcrPush` is scoped to the EAAP registry
- [ ] AKS permissions are scoped appropriately
- [ ] CI validates Terraform and Docker builds
- [ ] CD builds a Git-SHA-tagged image
- [ ] Image is pushed to ACR
- [ ] Pipeline deploys the image to `eaap-app`
- [ ] Two application replicas return Ready
- [ ] Temporary GitHub runner IP is removed after deployment
- [ ] Follow-up Terraform plan is clean
- [ ] Evidence is captured and sanitized

---

## Next Workstream

**Workstream 6 — Observability and Operations** will add a dedicated Log Analytics workspace, Container Insights, AKS control-plane diagnostic logging, operational queries, and alerting so the platform can be monitored and investigated after deployment.
