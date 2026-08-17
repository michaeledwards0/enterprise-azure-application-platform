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

  rbac_authorization_enabled    = true
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