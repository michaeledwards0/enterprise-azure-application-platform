<div align="center">

# Workstream 5 Runbook: CI/CD Automation
### GitHub Actions, Entra OIDC Federation, ACR Publishing, and Controlled AKS Deployment

</div>

---

## Purpose

This is the execution-corrected Workstream 5 runbook.

It reflects the configuration that successfully deployed the EAAP sample application after the original design was revised during hands-on troubleshooting.

You will:

1. Confirm the Workstream 4 AKS platform is healthy.
2. Confirm the complete Terraform root module is committed.
3. Configure the AzureAD Terraform provider.
4. Create a dedicated Entra application registration and service principal for GitHub Actions.
5. Configure branch-scoped GitHub OIDC federation.
6. Assign least-privilege ACR, AKS, Kubernetes, and subnet permissions.
7. Store identifiers and deployment settings at GitHub repository scope.
8. Run CI validation without a remote backend or Terraform apply.
9. Build and push Git-SHA-tagged images.
10. Temporarily allow a GitHub-hosted runner to reach the restricted AKS API.
11. Deploy only application release objects.
12. Restore the original AKS API allowlist.
13. Reconcile the successful flexible FIC into Terraform and remove troubleshooting-only identity objects.
14. Validate the release and capture evidence.

> **Security model:** No Azure client secret or service-principal password is stored in GitHub. GitHub uses a short-lived OIDC token to authenticate to Microsoft Entra ID.

> **Execution correction:** The final deployment does **not** use the GitHub `dev` Environment in the job. It uses branch-based OIDC trust for `main` and repository-scoped secrets/variables.

---

## Final Target Resources and Files

| Item | Final Resource / Path |
|---|---|
| Entra application | `app-eaap-github-actions-dev` |
| Service principal | Created from the Entra application |
| Working federation | Branch-scoped flexible FIC for `main` + immutable `repository_id` |
| CI workflow | `.github/workflows/eaap-ci.yml` |
| CD workflow | `.github/workflows/eaap-deploy.yml` |
| Application release manifest | `app/k8s/app-release.yaml` |
| Platform baseline manifest | `app/k8s/platform.yaml` |
| Kubernetes namespace | `eaap-app` |
| Image repository | `eaap-sample-web` |
| Terraform identity file | `terraform/environments/dev/cicd-identity.tf` |
| Terraform variables | `terraform/environments/dev/cicd-variables.tf` |
| Terraform outputs | `terraform/environments/dev/cicd-outputs.tf` |
| Provider versions | `terraform/environments/dev/versions.tf` |

---

## Phase 4 Baseline — Confirm Before Continuing

The working Workstream 4 state should have:

- `Deny-Other-Inbound-To-Workload` removed.
- AKS-required platform traffic preserved.
- AKS cluster identity with required networking access.
- System and `apps` node pools Ready.
- Two Ready application pods.
- Internal LoadBalancer frontend `10.20.1.10`.
- Existing `eaap-workload-sa`.
- Existing `eaap-key-vault-secrets` `SecretProviderClass`.
- Existing application workload identity `id-eaap-workload-dev-scus-001`.

Do **not** remove the application workload identity. It is unrelated to the GitHub deployment identity.

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

## Step 2 — Start and Validate AKS

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

Expected application baseline:

```text
Deployment: 2/2 Ready
Pods:       2 Running
Service:    10.20.1.10
```

---

## Step 3 — Confirm the Complete Terraform Root Module Is in Git

A clean GitHub runner cannot validate resources whose `.tf` files exist only on the workstation.

From the repository root:

```powershell
git status
git ls-files .\terraform\environments\dev
```

Confirm the root module includes the Phase 3 and Phase 4 source files it references, including identity/Key Vault and container-platform files.

Then:

```powershell
cd .\terraform\environments\dev
terraform init -backend=false
terraform validate
```

If CI reports undeclared resources, compare the Git-tracked Terraform files with the workstation folder before changing Terraform logic.

---

## Step 4 — Configure the AzureAD Provider

In `versions.tf`, keep the existing AzureRM provider and add AzureAD:

```hcl
terraform {
  required_version = ">= 1.6.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0, < 5.0"
    }

    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.9"
    }
  }
}

provider "azuread" {}
```

Keep the existing AzureRM provider configuration wherever it already exists:

```hcl
provider "azurerm" {
  features {}
}
```

Initialize:

```powershell
terraform init -upgrade -reconfigure -backend-config="backend.hcl"
```

---

## Step 5 — Create CI/CD Variables

Create or update `cicd-variables.tf`:

```hcl
variable "github_repository_owner" {
  description = "GitHub repository owner name used in the OIDC subject."
  type        = string
  default     = "michaeledwards0"
}

variable "github_repository_name" {
  description = "GitHub repository name used in the OIDC subject."
  type        = string
  default     = "enterprise-azure-application-platform"
}

variable "github_repository_id" {
  description = "Immutable GitHub repository ID used by the flexible OIDC trust."
  type        = string
}
```

In ignored `terraform.tfvars`:

```hcl
github_repository_id = "1311239206"
```

In `terraform.tfvars.example`:

```hcl
github_repository_id = "REPLACE_WITH_GITHUB_REPOSITORY_ID"
```

The repository ID is an identifier, not a password.

---

## Step 6 — Create the Entra Application and Service Principal

In `cicd-identity.tf`:

```hcl
resource "azuread_application" "github_actions" {
  display_name     = "app-eaap-github-actions-${var.environment}"
  sign_in_audience = "AzureADMyOrg"
}

resource "azuread_service_principal" "github_actions" {
  client_id = azuread_application.github_actions.client_id
}
```

Simple meaning:

```text
App Registration
= definition of the external automation application

Service Principal
= tenant-local security identity that receives Azure RBAC
```

---

## Step 7 — Configure the Working Branch-Scoped Flexible FIC

The successful OIDC test used a branch-based token from `main` and matched the immutable GitHub `repository_id`.

With AzureAD provider `~> 3.9`, represent the final trust in Terraform:

```hcl
resource "azuread_application_flexible_federated_identity_credential" "github_main" {
  application_id = azuread_application.github_actions.id
  display_name   = "fic-eaap-github-repoid-test"

  audience = "api://AzureADTokenExchange"
  issuer   = "https://token.actions.githubusercontent.com"

  claims_matching_expression = "claims['sub'] matches 'repo:${var.github_repository_owner}@*/${var.github_repository_name}@*:ref:refs/heads/main' and claims['repository_id'] eq '${var.github_repository_id}'"
}
```

This limits the trust to:

```text
GitHub issuer
+ EAAP repository
+ main branch
+ immutable repository_id
```

### Execution note — the working credential was originally created with Microsoft Graph

During troubleshooting, the working flexible FIC was created with `az rest`.

If it already exists, **import it instead of creating a duplicate**.

Get the application client ID and object ID:

```powershell
$githubIdentity = terraform output -json github_actions_identity | ConvertFrom-Json
$githubClientId = $githubIdentity.client_id

$appObjectId = az ad app show `
  --id "$githubClientId" `
  --query id `
  --output tsv
```

List FICs:

```powershell
az rest `
  --method GET `
  --uri "https://graph.microsoft.com/beta/applications/$appObjectId/federatedIdentityCredentials" `
  --query "value[].{Name:name,Id:id,Subject:subject,Expression:claimsMatchingExpression}" `
  --output json
```

Capture the ID of:

```text
fic-eaap-github-repoid-test
```

Then import:

```powershell
$flexFicId = az rest `
  --method GET `
  --uri "https://graph.microsoft.com/beta/applications/$appObjectId/federatedIdentityCredentials" `
  --query "value[?name=='fic-eaap-github-repoid-test'].id | [0]" `
  --output tsv

terraform import `
  "azuread_application_flexible_federated_identity_credential.github_main" `
  "$appObjectId/federatedIdentityCredential/$flexFicId"
```

Run:

```powershell
terraform plan
```

The imported credential should no longer appear as an unmanaged gap.

---

## Step 8 — Assign Azure RBAC

Append to `cicd-identity.tf`:

```hcl
resource "azurerm_role_assignment" "github_sp_acr_push" {
  scope                = azurerm_container_registry.platform.id
  role_definition_name = "AcrPush"
  principal_id         = azuread_service_principal.github_actions.object_id
}

resource "azurerm_role_assignment" "github_sp_aks_contributor" {
  scope                = azurerm_kubernetes_cluster.platform.id
  role_definition_name = "Azure Kubernetes Service Contributor Role"
  principal_id         = azuread_service_principal.github_actions.object_id
}

resource "azurerm_role_assignment" "github_sp_aks_cluster_user" {
  scope                = azurerm_kubernetes_cluster.platform.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = azuread_service_principal.github_actions.object_id
}

resource "azurerm_role_assignment" "github_sp_aks_namespace_writer" {
  scope                = "${azurerm_kubernetes_cluster.platform.id}/namespaces/eaap-app"
  role_definition_name = "Azure Kubernetes Service RBAC Writer"
  principal_id         = azuread_service_principal.github_actions.object_id
}

resource "azurerm_role_assignment" "github_sp_workload_subnet_network_contributor" {
  scope                = azurerm_subnet.app_workload.id
  role_definition_name = "Network Contributor"
  principal_id         = azuread_service_principal.github_actions.object_id
}
```

Why the subnet role exists:

```text
az aks update
    ↓
AKS resource update
    ↓
Azure validates access to linked workload subnet
    ↓
subnets/join/action required
```

Scope `Network Contributor` only to the AKS workload subnet.

---

## Step 9 — Add Phase 5 Outputs

`cicd-outputs.tf`:

```hcl
output "github_actions_identity" {
  description = "Entra application and service principal used by GitHub Actions OIDC."

  value = {
    display_name = azuread_application.github_actions.display_name
    client_id    = azuread_application.github_actions.client_id
    object_id    = azuread_service_principal.github_actions.object_id
  }
}
```

---

## Step 10 — Format, Validate, Plan, and Apply

```powershell
terraform fmt -recursive
terraform validate
terraform plan -out=phase5.tfplan
terraform show phase5.tfplan
```

Review every destroy.

Apply only the reviewed plan:

```powershell
terraform apply phase5.tfplan
```

Then:

```powershell
terraform output github_actions_identity
```

Allow RBAC time to propagate before the first deployment.

---

## Step 11 — Configure GitHub Repository Secrets and Variables

The final deployment job does **not** use:

```yaml
environment: dev
```

Use:

```text
Repository
→ Settings
→ Secrets and variables
→ Actions
```

### Repository secrets

```text
AZURE_CLIENT_ID
AZURE_TENANT_ID
AZURE_SUBSCRIPTION_ID
```

`AZURE_CLIENT_ID` must be the Entra application client ID.

There is no Azure client secret.

### Repository variables

```text
ACR_NAME=acreaapdev5803
ACR_LOGIN_SERVER=acreaapdev5803.azurecr.io
AKS_RESOURCE_GROUP=rg-eaap-platform-dev
AKS_NAME=aks-eaap-dev-scus-001
K8S_NAMESPACE=eaap-app
```

After the repository-scoped values are confirmed working, old duplicate `dev` Environment secrets can be removed.

---

## Step 12 — Create the CI Workflow

`.github/workflows/eaap-ci.yml`:

```yaml
name: EAAP CI Validation

on:
  pull_request:
    paths:
      - "terraform/**"
      - "app/**"
      - ".github/workflows/eaap-ci.yml"

  push:
    branches:
      - main
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

CI validates source. It does not apply infrastructure.

---

## Step 13 — Separate Platform Baseline from Application Release

Keep `app/k8s/platform.yaml` for the platform baseline:

```text
Namespace
ServiceAccount
SecretProviderClass
Deployment
Service
```

Create `app/k8s/app-release.yaml` containing **only** the application Deployment and Service.

Example:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: eaap-sample-web
  namespace: eaap-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: eaap-sample-web
  template:
    metadata:
      labels:
        app: eaap-sample-web
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: eaap-workload-sa
      nodeSelector:
        workload: applications
      containers:
        - name: eaap-sample-web
          image: acreaapdev5803.azurecr.io/eaap-sample-web:v1
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 10
          volumeMounts:
            - name: secrets-store
              mountPath: /mnt/secrets-store
              readOnly: true
      volumes:
        - name: secrets-store
          csi:
            driver: secrets-store.csi.k8s.io
            readOnly: true
            volumeAttributes:
              secretProviderClass: eaap-key-vault-secrets

---
apiVersion: v1
kind: Service
metadata:
  name: eaap-sample-web
  namespace: eaap-app
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
    service.beta.kubernetes.io/azure-load-balancer-internal-subnet: "snet-ingress-dev-scus-001"
spec:
  type: LoadBalancer
  loadBalancerIP: 10.20.1.10
  selector:
    app: eaap-sample-web
  ports:
    - port: 80
      targetPort: 80
      protocol: TCP
```

The CD pipeline references the existing ServiceAccount and SecretProviderClass but does not manage them.

---

## Step 14 — Create the Final CD Workflow

`.github/workflows/eaap-deploy.yml`:

```yaml
name: EAAP Deploy to AKS

on:
  workflow_dispatch:

  push:
    branches:
      - main
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

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Azure login with OIDC
        uses: azure/login@v3
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
            --output json | jq -r '(. // []) | join(",")')

          echo "ORIGINAL_AKS_RANGES=$ORIGINAL_RANGES" >> "$GITHUB_ENV"
          echo "AKS_RANGES_CAPTURED=true" >> "$GITHUB_ENV"

      - name: Wait for AKS to be ready
        shell: bash
        run: |
          for attempt in {1..60}; do
            STATE=$(az aks show \
              --resource-group "${{ vars.AKS_RESOURCE_GROUP }}" \
              --name "${{ vars.AKS_NAME }}" \
              --query provisioningState \
              --output tsv)

            echo "AKS provisioning state: $STATE"

            if [ "$STATE" = "Succeeded" ]; then
              exit 0
            fi

            if [ "$STATE" = "Failed" ] || [ "$STATE" = "Canceled" ]; then
              exit 1
            fi

            sleep 15
          done

          echo "Timed out waiting for AKS."
          exit 1

      - name: Temporarily allow GitHub runner to AKS API
        shell: bash
        run: |
          RUNNER_IP=$(curl -fsSL https://api.ipify.org)

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
        run: |
          az acr login --name "${{ vars.ACR_NAME }}"

      - name: Build and push image
        shell: bash
        run: |
          IMAGE_TAG="${GITHUB_SHA::12}"
          IMAGE="${{ vars.ACR_LOGIN_SERVER }}/${IMAGE_REPOSITORY}:${IMAGE_TAG}"

          echo "IMAGE=$IMAGE" >> "$GITHUB_ENV"

          docker build \
            -t "$IMAGE" \
            ./app/sample-web

          docker push "$IMAGE"

      - name: Setup kubectl
        uses: azure/setup-kubectl@v4

      - name: Setup kubelogin
        uses: azure/use-kubelogin@v1
        with:
          kubelogin-version: "v0.2.18"

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
          cp app/k8s/app-release.yaml app/k8s/app-release-rendered.yaml

          sed -i \
            "s#image: .*eaap-sample-web.*#image: ${IMAGE}#" \
            app/k8s/app-release-rendered.yaml

      - name: Deploy to AKS
        run: |
          kubectl apply -f app/k8s/app-release-rendered.yaml

      - name: Validate rollout
        shell: bash
        run: |
          kubectl rollout status \
            deployment/eaap-sample-web \
            -n "${{ vars.K8S_NAMESPACE }}" \
            --timeout=180s

          kubectl get pods \
            -n "${{ vars.K8S_NAMESPACE }}" \
            -o wide

          kubectl get service \
            -n "${{ vars.K8S_NAMESPACE }}"

      - name: Restore original AKS authorized IP ranges
        if: always()
        shell: bash
        run: |
          if [ "${AKS_RANGES_CAPTURED:-false}" != "true" ]; then
            echo "Original ranges were not captured. Skipping restore."
            exit 0
          fi

          for attempt in {1..60}; do
            STATE=$(az aks show \
              --resource-group "${{ vars.AKS_RESOURCE_GROUP }}" \
              --name "${{ vars.AKS_NAME }}" \
              --query provisioningState \
              --output tsv)

            echo "AKS provisioning state: $STATE"

            if [ "$STATE" = "Succeeded" ]; then
              break
            fi

            sleep 15
          done

          az aks update \
            --resource-group "${{ vars.AKS_RESOURCE_GROUP }}" \
            --name "${{ vars.AKS_NAME }}" \
            --api-server-authorized-ip-ranges "$ORIGINAL_AKS_RANGES" \
            --output none
```

An empty original range is valid here: Azure CLI accepts an empty value to disable authorized IP ranges on a cluster that was previously restricted.

Do not commit `app-release-rendered.yaml`; it is generated on the runner.

---

## Step 15 — Commit and Push

From repo root:

```powershell
cd "$HOME\Documents\enterprise-azure-application-platform"

git status

git add .\.github\workflows\eaap-ci.yml
git add .\.github\workflows\eaap-deploy.yml
git add .\app\k8s\app-release.yaml
git add .\terraform\environments\dev\cicd-variables.tf
git add .\terraform\environments\dev\cicd-identity.tf
git add .\terraform\environments\dev\cicd-outputs.tf
git add .\terraform\environments\dev\versions.tf

git diff --cached --name-only
git diff --cached

git commit -m "Finalize Workstream 5 CI/CD automation"
git push origin main
```

If `git pull --rebase` is needed but local changes exist, resolve or stash intentionally before pulling. Do not force push for ordinary synchronization.

---

## Step 16 — Validate the Successful Workflow

In GitHub:

```text
Actions
→ EAAP CI Validation
```

Confirm CI passes.

Then:

```text
Actions
→ EAAP Deploy to AKS
```

Confirm:

```text
Azure login with OIDC                 PASS
Capture original AKS ranges          PASS
Wait for AKS                         PASS
Temporary runner allowlist           PASS
ACR login                            PASS
Docker build and push                PASS
Setup kubectl                        PASS
Setup kubelogin                      PASS
Connect to AKS                       PASS
Prepare release manifest             PASS
Deploy to AKS                        PASS
Validate rollout                     PASS
Restore original AKS ranges          PASS
```

---

## Step 17 — Validate from the Workstation

Latest ACR tags:

```powershell
az acr repository show-tags `
  --name "acreaapdev5803" `
  --repository "eaap-sample-web" `
  --orderby time_desc `
  --top 10 `
  --output table
```

Deployment image:

```powershell
kubectl get deployment eaap-sample-web `
  -n eaap-app `
  -o jsonpath="{.spec.template.spec.containers[0].image}"
```

Runtime:

```powershell
kubectl get deployment -n eaap-app
kubectl get pods -n eaap-app -o wide
kubectl get service -n eaap-app
```

API authorized ranges:

```powershell
az aks show `
  --resource-group "rg-eaap-platform-dev" `
  --name "aks-eaap-dev-scus-001" `
  --query "apiServerAccessProfile.authorizedIpRanges" `
  --output table
```

---

## Step 18 — Post-Success Identity Cleanup

During troubleshooting, multiple temporary identity objects and FICs may exist.

Keep:

```text
app-eaap-github-actions-dev
service principal for that application
working branch-scoped flexible FIC
new service-principal RBAC assignments
```

Remove only after verifying the final Terraform plan:

```text
old GitHub UAMI: id-eaap-github-actions-dev-scus-001
old UAMI FIC
old duplicate UAMI RBAC assignments
unused standard environment FIC
temporary OIDC test FICs
```

Do **not** remove:

```text
id-eaap-workload-dev-scus-001
azurekeyvaultsecretsprovider-aks-eaap-dev-scus-001
```

Those are separate application/platform identities.

After reconciling the flexible FIC into Terraform:

```powershell
terraform plan
```

Review the destroy list carefully.

Apply only expected cleanup.

Then run:

```powershell
terraform plan
```

Expected:

```text
No changes. Your infrastructure matches the configuration.
```

---

## Troubleshooting Reference

### `AADSTS700016`

The client/application ID presented by GitHub could not be resolved in the target tenant.

Verify:

```powershell
az ad app show --id "<CLIENT_ID>"
az ad sp show --id "<CLIENT_ID>"
```

### `AADSTS700213`

No matching FIC was found.

For this repository, validate the actual GitHub JWT claims and the final flexible branch FIC. Do not reintroduce the failed `environment: dev` subject path.

### `LinkedAuthorizationFailed`

If the error mentions:

```text
Microsoft.Network/virtualNetworks/subnets/join/action
```

verify `Network Contributor` for the GitHub service principal on:

```text
snet-workload-dev-scus-001
```

### kubelogin cannot resolve latest

Pin:

```yaml
kubelogin-version: "v0.2.18"
```

### `$GITHUB_ENV` invalid format

Do not write multiline AKS authorized ranges directly to `$GITHUB_ENV`.

Use:

```bash
--output json | jq -r '(. // []) | join(",")'
```

### `OperationNotAllowed`

Another AKS control-plane update is still in progress.

Wait until:

```powershell
az aks show `
  --resource-group "rg-eaap-platform-dev" `
  --name "aks-eaap-dev-scus-001" `
  --query provisioningState `
  --output tsv
```

returns:

```text
Succeeded
```

### `SecretProviderClass` is Forbidden

Do not grant cluster admin simply to make the pipeline pass.

Deploy `app-release.yaml`, not the full platform baseline.

---

## Cost Control

Stop AKS during extended pauses:

```powershell
az aks stop `
  --resource-group "rg-eaap-platform-dev" `
  --name "aks-eaap-dev-scus-001"
```

Restart:

```powershell
az aks start `
  --resource-group "rg-eaap-platform-dev" `
  --name "aks-eaap-dev-scus-001"
```

Do not delete the Terraform backend while later workstreams continue.

---

## Workstream Completion Criteria

Workstream 5 is complete when:

- [x] Entra application registration exists for GitHub Actions
- [x] Service principal exists
- [x] Branch-scoped OIDC authentication succeeds
- [x] No Azure client secret is stored in GitHub
- [x] `AcrPush` is scoped to the EAAP registry
- [x] AKS management permissions are scoped
- [x] Workload-subnet `Network Contributor` is present for the deployment SP
- [x] CI validates Terraform and Docker builds
- [x] CD builds a Git-SHA-tagged image
- [x] Image is pushed to ACR
- [x] Pipeline deploys `app-release.yaml` to `eaap-app`
- [x] Two application replicas return Ready
- [x] Temporary GitHub runner IP is removed after deployment
- [ ] Working flexible FIC is imported/reconciled into Terraform
- [ ] Obsolete troubleshooting identities/FICs are removed
- [ ] Follow-up Terraform plan is clean
- [ ] Evidence is captured and sanitized

---

## Next Workstream

**Workstream 6 — Observability and Operations** builds directly on the successful Phase 5 deployment path. Monitoring will be enabled on the existing AKS cluster, then a fresh Phase 5 deployment can be used as a realistic telemetry-generation event for Container Insights and AKS control-plane diagnostics.
