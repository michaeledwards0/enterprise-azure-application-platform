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