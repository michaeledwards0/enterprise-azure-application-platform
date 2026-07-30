<div align="center">

# Workstream 3 Runbook: Identity and Secrets
### Managed Identity, Key Vault RBAC, Private Endpoint, and Secret Validation

</div>

---

## Purpose

This runbook adds identity and secret-management controls to the existing EAAP environment.

You will:

1. Confirm Workstreams 1 and 2 are healthy.
2. Create a user-assigned managed identity for future AKS workloads.
3. Deploy an Azure Key Vault using Azure RBAC.
4. Restrict the Key Vault firewall to the current workstation public IP.
5. Create a Key Vault private endpoint.
6. Create and link the Key Vault Private Link DNS zone.
7. Assign least-privilege Key Vault roles.
8. Create a test secret outside Terraform.
9. Validate the deployment and capture evidence.

> **State continuity:** Add these files to `terraform/environments/dev`. Continue using the existing EAAP backend and state key. Do not create a separate Phase 3 state file.

---

## Target Resources

| Resource | Suggested Name | Location |
|---|---|---|
| Workload managed identity | `id-eaap-workload-dev-scus-001` | `rg-eaap-platform-dev` |
| Key Vault | `kveaapdev<unique-suffix>` | `rg-eaap-platform-dev` |
| Key Vault private endpoint | `pep-eaap-keyvault-dev-scus-001` | Private-endpoints subnet |
| Private DNS zone | `privatelink.vaultcore.azure.net` | `rg-eaap-network-dev` |

---

## Step 1 — Restore the Engineering Session

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

Restore the subscription variables:

```powershell
$env:ARM_SUBSCRIPTION_ID = az account show --query id -o tsv
$env:AZURE_SUBSCRIPTION_ID = $env:ARM_SUBSCRIPTION_ID
```

Retrieve the current workstation public IP:

```powershell
$myPublicIp = (Invoke-RestMethod -Uri "https://api.ipify.org").Trim()
Write-Host $myPublicIp
```

---

## Step 2 — Confirm the Existing Terraform Environment

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

Stop if Terraform reports unexplained drift.

---

## Step 3 — Create Phase 3 Variables

Create and open the file:

```powershell
New-Item -ItemType File -Name "identity-secrets-variables.tf" -Force
code .\identity-secrets-variables.tf
```

Paste only this Terraform code:

```hcl
variable "key_vault_name" {
  description = "Globally unique Key Vault name."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9-]{3,24}$", var.key_vault_name))
    error_message = "The Key Vault name must contain 3-24 letters, numbers, or hyphens."
  }
}

variable "admin_public_ip_cidr" {
  description = "Current administrator public IP in CIDR notation for temporary Key Vault access."
  type        = string
  sensitive   = true
}
```

Add safe example values to `terraform.tfvars.example`:

```hcl
key_vault_name       = "kveaapdevREPLACE"
admin_public_ip_cidr = "203.0.113.10/32"
```

Add the real values to the ignored `terraform.tfvars`:

```hcl
key_vault_name       = "kveaapdev<unique-suffix>"
admin_public_ip_cidr = "<YOUR_CURRENT_PUBLIC_IP>/32"
```

Format the current IP as CIDR:

```powershell
"$myPublicIp/32"
```

---

## Step 4 — Create the Identity and Key Vault Configuration

Create and open:

```powershell
New-Item -ItemType File -Name "identity-secrets.tf" -Force
code .\identity-secrets.tf
```

Paste:

```hcl
data "azurerm_client_config" "current" {}

resource "azurerm_user_assigned_identity" "workload" {
  name                = "id-eaap-workload-${var.environment}-scus-001"
  location            = azurerm_resource_group.landing_zone["platform"].location
  resource_group_name = azurerm_resource_group.landing_zone["platform"].name

  tags = merge(
    local.common_tags,
    {
      ResourcePurpose = "Application-Workload-Identity"
    }
  )
}

resource "azurerm_key_vault" "platform" {
  name                = var.key_vault_name
  location            = azurerm_resource_group.landing_zone["platform"].location
  resource_group_name = azurerm_resource_group.landing_zone["platform"].name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  enable_rbac_authorization     = true
  purge_protection_enabled      = true
  soft_delete_retention_days    = 7
  public_network_access_enabled = true

  network_acls {
    bypass         = "AzureServices"
    default_action = "Deny"
    ip_rules       = [var.admin_public_ip_cidr]
  }

  tags = merge(
    local.common_tags,
    {
      ResourcePurpose = "Platform-Secrets-Management"
    }
  )
}

resource "azurerm_role_assignment" "current_user_key_vault_admin" {
  scope                = azurerm_key_vault.platform.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "workload_key_vault_secrets_user" {
  scope                = azurerm_key_vault.platform.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.workload.principal_id
}
```

Simple meaning:

> Terraform creates the identity, vault, firewall rule, and RBAC. It does not create the secret value.

---

## Step 5 — Create the Private Endpoint and DNS Zone

Create and open:

```powershell
New-Item -ItemType File -Name "key-vault-private-link.tf" -Force
code .\key-vault-private-link.tf
```

Paste:

```hcl
resource "azurerm_private_dns_zone" "key_vault" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = azurerm_resource_group.landing_zone["network"].name

  tags = merge(
    local.common_tags,
    {
      ResourcePurpose = "Key-Vault-Private-DNS"
    }
  )
}

resource "azurerm_private_dns_zone_virtual_network_link" "key_vault_hub" {
  name                  = "link-key-vault-dns-to-hub-${var.environment}"
  resource_group_name   = azurerm_resource_group.landing_zone["network"].name
  private_dns_zone_name = azurerm_private_dns_zone.key_vault.name
  virtual_network_id    = azurerm_virtual_network.hub.id
  registration_enabled  = false

  tags = local.common_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "key_vault_app" {
  name                  = "link-key-vault-dns-to-app-${var.environment}"
  resource_group_name   = azurerm_resource_group.landing_zone["network"].name
  private_dns_zone_name = azurerm_private_dns_zone.key_vault.name
  virtual_network_id    = azurerm_virtual_network.app.id
  registration_enabled  = false

  tags = local.common_tags
}

resource "azurerm_private_endpoint" "key_vault" {
  name                = "pep-eaap-keyvault-${var.environment}-scus-001"
  location            = azurerm_resource_group.landing_zone["network"].location
  resource_group_name = azurerm_resource_group.landing_zone["network"].name
  subnet_id           = azurerm_subnet.app_private_endpoints.id

  private_service_connection {
    name                           = "psc-eaap-keyvault-${var.environment}"
    private_connection_resource_id = azurerm_key_vault.platform.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "key-vault-private-dns"
    private_dns_zone_ids = [azurerm_private_dns_zone.key_vault.id]
  }

  tags = merge(
    local.common_tags,
    {
      ResourcePurpose = "Key-Vault-Private-Endpoint"
    }
  )
}
```

---

## Step 6 — Create Phase 3 Outputs

Create and open:

```powershell
New-Item -ItemType File -Name "identity-secrets-outputs.tf" -Force
code .\identity-secrets-outputs.tf
```

Paste:

```hcl
output "workload_identity" {
  description = "Managed identity used by future AKS workloads."
  value = {
    name         = azurerm_user_assigned_identity.workload.name
    id           = azurerm_user_assigned_identity.workload.id
    client_id    = azurerm_user_assigned_identity.workload.client_id
    principal_id = azurerm_user_assigned_identity.workload.principal_id
  }
}

output "key_vault" {
  description = "Key Vault deployment details."
  value = {
    name      = azurerm_key_vault.platform.name
    id        = azurerm_key_vault.platform.id
    vault_uri = azurerm_key_vault.platform.vault_uri
  }
}

output "key_vault_private_endpoint_ip" {
  description = "Private IP assigned to the Key Vault private endpoint."
  value       = azurerm_private_endpoint.key_vault.private_service_connection[0].private_ip_address
}
```

---

## Step 7 — Format, Validate, Plan, and Apply

```powershell
terraform fmt -recursive
terraform validate
terraform plan -out=phase3.tfplan
terraform show phase3.tfplan
```

Confirm the plan does not destroy Phase 1 or Phase 2 resources.

Apply:

```powershell
terraform apply phase3.tfplan
terraform output
```

Allow several minutes for RBAC propagation.

---

## Step 8 — Create the Test Secret Outside Terraform

Read the Key Vault name:

```powershell
$keyVaultName = terraform output -json key_vault |
  ConvertFrom-Json |
  Select-Object -ExpandProperty name
```

Create a non-sensitive lab secret:

```powershell
az keyvault secret set `
  --vault-name "$keyVaultName" `
  --name "sample-app-message" `
  --value "EAAP Workload Identity Validation"
```

Validate metadata without printing the secret:

```powershell
az keyvault secret show `
  --vault-name "$keyVaultName" `
  --name "sample-app-message" `
  --query "{Name:name,Enabled:attributes.enabled,Created:attributes.created,Updated:attributes.updated}" `
  --output table
```

---

## Step 9 — Validate the Deployment

Managed identity:

```powershell
az identity show `
  --name "id-eaap-workload-dev-scus-001" `
  --resource-group "rg-eaap-platform-dev" `
  --query "{Name:name,ClientId:clientId,PrincipalId:principalId}" `
  --output table
```

Key Vault:

```powershell
az keyvault show `
  --name "$keyVaultName" `
  --query "{Name:name,RBAC:properties.enableRbacAuthorization,PublicAccess:properties.publicNetworkAccess,DefaultAction:properties.networkAcls.defaultAction,PurgeProtection:properties.enablePurgeProtection}" `
  --output table
```

Private endpoint:

```powershell
az network private-endpoint show `
  --name "pep-eaap-keyvault-dev-scus-001" `
  --resource-group "rg-eaap-network-dev" `
  --query "{Name:name,State:privateLinkServiceConnections[0].privateLinkServiceConnectionState.status,Subnet:subnet.id}" `
  --output table
```

DNS links:

```powershell
az network private-dns link vnet list `
  --zone-name "privatelink.vaultcore.azure.net" `
  --resource-group "rg-eaap-network-dev" `
  --output table
```

Clean plan:

```powershell
terraform plan
```

Expected:

```text
No changes. Your infrastructure matches the configuration.
```

---

## Step 10 — Capture Evidence

Save screenshots under:

```text
screenshots/phase-3/
```

Recommended names:

```text
01-managed-identity.png
02-key-vault-overview.png
03-key-vault-networking.png
04-key-vault-private-endpoint.png
05-key-vault-private-dns.png
06-key-vault-rbac.png
07-test-secret-metadata.png
08-terraform-apply.png
09-clean-plan.png
```

Do not expose the secret value or unsanitized IDs.

---

## Step 11 — Commit Workstream 3

```powershell
cd ..\..\..
```

Stage only Phase 3 files:

```powershell
git add .\docs\phase-3-identity-secrets
git add .\runbooks\phase-3-identity-secrets-runbook.md
git add .\terraform\environments\dev\identity-secrets-variables.tf
git add .\terraform\environments\dev\identity-secrets.tf
git add .\terraform\environments\dev\key-vault-private-link.tf
git add .\terraform\environments\dev\identity-secrets-outputs.tf
git add .\terraform\environments\dev\terraform.tfvars.example
git add .\screenshots\phase-3
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
git commit -m "Complete Workstream 3 identity and secrets"
git pull --rebase origin main
git push origin main
```

---

## Cleanup Guidance

Keep these resources while continuing to Workstream 4. Workstream 4 uses the Key Vault and workload identity for AKS secret access.
