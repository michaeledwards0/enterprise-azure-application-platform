resource "azurerm_private_dns_zone" "internal" {
  name                = var.private_dns_zone_name
  resource_group_name = azurerm_resource_group.landing_zone["network"].name

  tags = merge(
    local.common_tags,
    {
      ResourcePurpose = "Internal-Name-Resolution"
    }
  )
}

resource "azurerm_private_dns_zone_virtual_network_link" "hub" {
  name                  = "link-internal-dns-to-hub-${var.environment}"
  resource_group_name   = azurerm_resource_group.landing_zone["network"].name
  private_dns_zone_name = azurerm_private_dns_zone.internal.name
  virtual_network_id    = azurerm_virtual_network.hub.id
  registration_enabled  = false

  tags = local.common_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "app" {
  name                  = "link-internal-dns-to-app-${var.environment}"
  resource_group_name   = azurerm_resource_group.landing_zone["network"].name
  private_dns_zone_name = azurerm_private_dns_zone.internal.name
  virtual_network_id    = azurerm_virtual_network.app.id
  registration_enabled  = false

  tags = local.common_tags
}
