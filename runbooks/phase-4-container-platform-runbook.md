<div align="center">

# Workstream 4 Runbook: Container Platform
### Azure Container Registry, AKS, Node Pools, Workload Identity, Key Vault CSI, and Private Exposure

</div>

---

## Purpose

This runbook deploys the EAAP container platform.

You will:

1. Confirm Workstream 3 is healthy.
2. Install and verify Docker, kubectl, and Helm.
3. Deploy Azure Container Registry.
4. Update the Phase 2 NSG for AKS traffic.
5. Deploy AKS into the workload subnet.
6. Create separate system and user node pools.
7. Assign ACR and subnet permissions.
8. Create Workload Identity federation.
9. Build and push a sample container image.
10. Deploy a sample workload.
11. Mount a Key Vault secret through the CSI driver.
12. Expose the workload through an internal Load Balancer in the ingress subnet.
13. Validate and capture evidence.

> **Cost warning:** AKS node pools create ongoing compute charges. Review the Terraform plan and stop or destroy the cluster when it is no longer needed.

---

## Target Resources

| Resource | Suggested Name |
|---|---|
| Azure Container Registry | `acreaapdev<unique-suffix>` |
| AKS cluster | `aks-eaap-dev-scus-001` |
| System node pool | `system` |
| User node pool | `apps` |
| Kubernetes namespace | `eaap-app` |
| Kubernetes service account | `eaap-workload-sa` |
| Internal service IP | `10.20.1.10` |

---

## Step 1 — Install and Verify Local Tools

From Administrator PowerShell:

```powershell
winget install --id Docker.DockerDesktop -e
winget install --id Kubernetes.kubectl -e
winget install --id Helm.Helm -e
```

Restart PowerShell and verify:

```powershell
docker version
kubectl version --client
helm version
az version
terraform version
```

Start Docker Desktop before building the sample image.

---

## Step 2 — Restore the Project Context

```powershell
cd "$HOME\Documents\enterprise-azure-application-platform"
code .
```

Confirm Azure authentication:

```powershell
az account show `
  --query "{Name:name,State:state,IsDefault:isDefault}" `
  --output table
```

Restore subscription variables:

```powershell
$env:ARM_SUBSCRIPTION_ID = az account show --query id -o tsv
$env:AZURE_SUBSCRIPTION_ID = $env:ARM_SUBSCRIPTION_ID
```

Retrieve the current public IP:

```powershell
$myPublicIp = (Invoke-RestMethod -Uri "https://api.ipify.org").Trim()
"$myPublicIp/32"
```

---

## Step 3 — Confirm Existing Terraform State

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

## Step 4 — Create Container Platform Variables

Create and open:

```powershell
New-Item -ItemType File -Name "container-platform-variables.tf" -Force
code .\container-platform-variables.tf
```

Paste:

```hcl
variable "container_registry_name" {
  description = "Globally unique Azure Container Registry name."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9]{5,50}$", var.container_registry_name))
    error_message = "The registry name must contain 5-50 letters or numbers."
  }
}

variable "aks_admin_public_ip_cidr" {
  description = "Public CIDR allowed to administer the AKS API server."
  type        = string
  sensitive   = true
}

variable "aks_kubernetes_version" {
  description = "Supported AKS Kubernetes version selected during deployment."
  type        = string
}

variable "aks_system_node_vm_size" {
  description = "VM size for the system pool."
  type        = string
  default     = "Standard_D2s_v3"
}

variable "aks_user_node_vm_size" {
  description = "VM size for the application pool."
  type        = string
  default     = "Standard_D2s_v3"
}
```

Add safe examples to `terraform.tfvars.example`:

```hcl
container_registry_name  = "acreaapdevREPLACE"
aks_admin_public_ip_cidr = "203.0.113.10/32"
aks_kubernetes_version   = "REPLACE_WITH_SUPPORTED_VERSION"
```

List supported versions:

```powershell
az aks get-versions `
  --location southcentralus `
  --query "values[?isPreview==null || isPreview==``false``].version" `
  --output table
```

Add the real values to ignored `terraform.tfvars`.

---

## Step 5 — Create Azure Container Registry

Create and open:

```powershell
New-Item -ItemType File -Name "container-registry.tf" -Force
code .\container-registry.tf
```

Paste:

```hcl
resource "azurerm_container_registry" "platform" {
  name                = var.container_registry_name
  resource_group_name = azurerm_resource_group.landing_zone["platform"].name
  location            = azurerm_resource_group.landing_zone["platform"].location
  sku                 = "Standard"
  admin_enabled       = false

  public_network_access_enabled = true

  tags = merge(
    local.common_tags,
    {
      ResourcePurpose = "Container-Image-Registry"
    }
  )
}

resource "azurerm_role_assignment" "current_user_acr_push" {
  scope                = azurerm_container_registry.platform.id
  role_definition_name = "AcrPush"
  principal_id         = data.azurerm_client_config.current.object_id
}
```

The ACR admin account remains disabled. Authentication uses Microsoft Entra RBAC.

---

## Step 6 — Update the Workload NSG for AKS

Open:

```powershell
code .\network-security.tf
```

Add these rules before the existing deny rule:

```hcl
resource "azurerm_network_security_rule" "allow_workload_internal" {
  name                        = "Allow-Workload-Subnet-Internal"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = var.app_workload_subnet_prefix[0]
  destination_address_prefix  = var.app_workload_subnet_prefix[0]
  resource_group_name         = azurerm_resource_group.landing_zone["network"].name
  network_security_group_name = azurerm_network_security_group.workload.name
}

resource "azurerm_network_security_rule" "allow_azure_load_balancer_to_workload" {
  name                        = "Allow-AzureLoadBalancer-To-Workload"
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "30000-32767"
  source_address_prefix       = "AzureLoadBalancer"
  destination_address_prefix  = var.app_workload_subnet_prefix[0]
  resource_group_name         = azurerm_resource_group.landing_zone["network"].name
  network_security_group_name = azurerm_network_security_group.workload.name
}
```

Keep the Phase 2 deny rule at priority `400`.

---

## Step 7 — Create AKS

Create and open:

```powershell
New-Item -ItemType File -Name "aks.tf" -Force
code .\aks.tf
```

Paste:

```hcl
resource "azurerm_kubernetes_cluster" "platform" {
  name                = "aks-eaap-${var.environment}-scus-001"
  location            = azurerm_resource_group.landing_zone["platform"].location
  resource_group_name = azurerm_resource_group.landing_zone["platform"].name
  dns_prefix          = "aks-eaap-${var.environment}"
  kubernetes_version  = var.aks_kubernetes_version

  role_based_access_control_enabled = true
  local_account_disabled            = true
  oidc_issuer_enabled               = true
  workload_identity_enabled         = true

  api_server_access_profile {
    authorized_ip_ranges = [var.aks_admin_public_ip_cidr]
  }

  default_node_pool {
    name                         = "system"
    vm_size                      = var.aks_system_node_vm_size
    vnet_subnet_id               = azurerm_subnet.app_workload.id
    auto_scaling_enabled         = true
    min_count                    = 1
    max_count                    = 2
    only_critical_addons_enabled = true
    os_disk_size_gb              = 64
    type                         = "VirtualMachineScaleSets"
  }

  identity {
    type = "SystemAssigned"
  }

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = data.azurerm_client_config.current.tenant_id
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "cilium"
    network_data_plane  = "cilium"
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"
    service_cidr        = "10.30.0.0/16"
    dns_service_ip      = "10.30.0.10"
  }

  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  tags = merge(
    local.common_tags,
    {
      ResourcePurpose = "Managed-Kubernetes-Platform"
    }
  )
}

resource "azurerm_kubernetes_cluster_node_pool" "apps" {
  name                  = "apps"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.platform.id
  vm_size               = var.aks_user_node_vm_size
  vnet_subnet_id        = azurerm_subnet.app_workload.id
  mode                  = "User"

  auto_scaling_enabled = true
  min_count            = 1
  max_count            = 2
  os_disk_size_gb      = 64

  node_labels = {
    workload = "applications"
  }

  tags = merge(
    local.common_tags,
    {
      ResourcePurpose = "Application-Node-Pool"
    }
  )
}
```

Run `terraform validate`. Stop and correct any provider-schema error before planning.

---

## Step 8 — Create Role Assignments and Federation

Create and open:

```powershell
New-Item -ItemType File -Name "aks-identity.tf" -Force
code .\aks-identity.tf
```

Paste:

```hcl
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                = azurerm_container_registry.platform.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.platform.kubelet_identity[0].object_id
}

resource "azurerm_role_assignment" "aks_ingress_subnet_network_contributor" {
  scope                = azurerm_subnet.app_ingress.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.platform.identity[0].principal_id
}

resource "azurerm_federated_identity_credential" "sample_app" {
  name                = "fic-eaap-sample-app-${var.environment}"
  resource_group_name = azurerm_resource_group.landing_zone["platform"].name
  parent_id           = azurerm_user_assigned_identity.workload.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.platform.oidc_issuer_url
  subject             = "system:serviceaccount:eaap-app:eaap-workload-sa"
}
```

---

## Step 9 — Create Outputs

Create and open:

```powershell
New-Item -ItemType File -Name "container-platform-outputs.tf" -Force
code .\container-platform-outputs.tf
```

Paste:

```hcl
output "container_registry" {
  value = {
    name         = azurerm_container_registry.platform.name
    login_server = azurerm_container_registry.platform.login_server
  }
}

output "aks_cluster" {
  value = {
    name            = azurerm_kubernetes_cluster.platform.name
    resource_group  = azurerm_kubernetes_cluster.platform.resource_group_name
    oidc_issuer_url = azurerm_kubernetes_cluster.platform.oidc_issuer_url
  }
}

output "workload_identity_client_id" {
  value = azurerm_user_assigned_identity.workload.client_id
}
```

---

## Step 10 — Plan and Apply

```powershell
terraform fmt -recursive
terraform validate
terraform plan -out=phase4.tfplan
terraform show phase4.tfplan
```

Review costs and verify that no earlier resources are destroyed.

Apply:

```powershell
terraform apply phase4.tfplan
terraform output
```

---

## Step 11 — Connect kubectl

```powershell
$aksOutput = terraform output -json aks_cluster | ConvertFrom-Json
$aksName = $aksOutput.name
$aksResourceGroup = $aksOutput.resource_group
```

```powershell
az aks get-credentials `
  --resource-group "$aksResourceGroup" `
  --name "$aksName" `
  --overwrite-existing
```

Validate:

```powershell
kubectl get nodes -o wide
kubectl get namespaces
```

---

## Step 12 — Create and Push the Sample Image

Return to the repository root:

```powershell
cd ..\..\..
```

Create folders:

```powershell
New-Item -ItemType Directory -Force -Path ".\app\sample-web"
New-Item -ItemType Directory -Force -Path ".\app\k8s"
```

Create `app/sample-web/index.html`:

```html
<!doctype html>
<html>
  <head><title>EAAP Sample Application</title></head>
  <body>
    <h1>Enterprise Azure Application Platform</h1>
    <p>Workstream 4 container deployment succeeded.</p>
  </body>
</html>
```

Create `app/sample-web/Dockerfile`:

```dockerfile
FROM nginx:1.27-alpine
COPY index.html /usr/share/nginx/html/index.html
EXPOSE 80
```

Read ACR outputs:

```powershell
cd .\terraform\environments\dev
$acrOutput = terraform output -json container_registry | ConvertFrom-Json
$acrName = $acrOutput.name
$acrLoginServer = $acrOutput.login_server
cd ..\..\..
```

Build and push:

```powershell
az acr login --name "$acrName"

docker build `
  -t "$acrLoginServer/eaap-sample-web:v1" `
  .\app\sample-web

docker push "$acrLoginServer/eaap-sample-web:v1"
```

Validate:

```powershell
az acr repository show-tags `
  --name "$acrName" `
  --repository "eaap-sample-web" `
  --output table
```

---

## Step 13 — Create the Kubernetes Manifest

Read the required values:

```powershell
cd .\terraform\environments\dev

$workloadClientId = terraform output -raw workload_identity_client_id
$keyVaultName = (terraform output -json key_vault | ConvertFrom-Json).name
$tenantId = az account show --query tenantId -o tsv
$acrLoginServer = (terraform output -json container_registry | ConvertFrom-Json).login_server

cd ..\..\..
```

Create `app/k8s/platform.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: eaap-app
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: eaap-workload-sa
  namespace: eaap-app
  annotations:
    azure.workload.identity/client-id: "<WORKLOAD_IDENTITY_CLIENT_ID>"
  labels:
    azure.workload.identity/use: "true"
---
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: eaap-key-vault-secrets
  namespace: eaap-app
spec:
  provider: azure
  parameters:
    usePodIdentity: "false"
    clientID: "<WORKLOAD_IDENTITY_CLIENT_ID>"
    keyvaultName: "<KEY_VAULT_NAME>"
    tenantId: "<TENANT_ID>"
    objects: |
      array:
        - |
          objectName: sample-app-message
          objectType: secret
---
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
        - name: web
          image: <ACR_LOGIN_SERVER>/eaap-sample-web:v1
          ports:
            - containerPort: 80
          volumeMounts:
            - name: secrets-store
              mountPath: "/mnt/secrets-store"
              readOnly: true
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 10
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
    service.beta.kubernetes.io/azure-load-balancer-ipv4: "10.20.1.10"
spec:
  type: LoadBalancer
  selector:
    app: eaap-sample-web
  ports:
    - name: http
      protocol: TCP
      port: 80
      targetPort: 80
```

Replace placeholders:

```powershell
$manifestPath = ".\app\k8s\platform.yaml"

(Get-Content $manifestPath -Raw) `
  -replace "<WORKLOAD_IDENTITY_CLIENT_ID>", $workloadClientId `
  -replace "<KEY_VAULT_NAME>", $keyVaultName `
  -replace "<TENANT_ID>", $tenantId `
  -replace "<ACR_LOGIN_SERVER>", $acrLoginServer |
  Set-Content $manifestPath
```

Review before applying:

```powershell
code $manifestPath
```

---

## Step 14 — Deploy and Validate the Application

```powershell
kubectl apply -f .\app\k8s\platform.yaml
```

Check resources:

```powershell
kubectl get pods -n eaap-app -o wide
kubectl get service -n eaap-app
kubectl get secretproviderclass -n eaap-app
```

Validate that the mounted secret filename exists without printing its value:

```powershell
$podName = kubectl get pods `
  -n eaap-app `
  -l app=eaap-sample-web `
  -o jsonpath="{.items[0].metadata.name}"

kubectl exec `
  -n eaap-app `
  "$podName" `
  -- ls -l /mnt/secrets-store
```

Expected:

```text
sample-app-message
```

Test the web application with port forwarding:

```powershell
kubectl port-forward `
  -n eaap-app `
  service/eaap-sample-web `
  8080:80
```

Open:

```text
http://localhost:8080
```

Stop with `Ctrl + C`.

---

## Step 15 — Final Validation

```powershell
kubectl get nodes
kubectl get deployment -n eaap-app
kubectl get pods -n eaap-app
kubectl get service -n eaap-app
```

Return to Terraform:

```powershell
cd .\terraform\environments\dev
terraform plan
```

Expected:

```text
No changes. Your infrastructure matches the configuration.
```

---

## Step 16 — Capture Evidence

Save under:

```text
screenshots/phase-4/
```

Recommended names:

```text
01-acr-overview.png
02-acr-image.png
03-aks-overview.png
04-node-pools.png
05-api-authorized-ip.png
06-workload-identity.png
07-key-vault-secret-mount.png
08-running-pods.png
09-private-service-ip.png
10-clean-plan.png
```

---

## Step 17 — Commit Workstream 4

```powershell
cd ..\..\..
```

Stage only Phase 4 files:

```powershell
git add .\docs\phase-4-container-platform
git add .\runbooks\phase-4-container-platform-runbook.md
git add .\terraform\environments\dev\container-platform-variables.tf
git add .\terraform\environments\dev\container-registry.tf
git add .\terraform\environments\dev\aks.tf
git add .\terraform\environments\dev\aks-identity.tf
git add .\terraform\environments\dev\container-platform-outputs.tf
git add .\terraform\environments\dev\network-security.tf
git add .\terraform\environments\dev\terraform.tfvars.example
git add .\app
git add .\screenshots\phase-4
```

Review:

```powershell
git status
git diff --cached --name-only
```

Do not commit:

```text
terraform.tfvars
backend.hcl
*.tfplan
*.tfstate
```

Commit and push:

```powershell
git commit -m "Complete Workstream 4 container platform"
git pull --rebase origin main
git push origin main
```

---

## Cost Control

Stop AKS during a short pause:

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

## Future-State Note

This phase uses a private Layer 4 LoadBalancer service as the first controlled application entry point.

A later phase should add Kubernetes Gateway API or Application Gateway for Containers for TLS policy, WAF, hostname routing, and advanced Layer 7 traffic management.
