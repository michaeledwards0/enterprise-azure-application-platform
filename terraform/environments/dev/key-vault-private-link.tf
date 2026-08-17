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