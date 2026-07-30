resource "azurerm_route_table" "app" {
  name                = "rt-eaap-app-${var.environment}-scus-001"
  location            = azurerm_resource_group.landing_zone["network"].location
  resource_group_name = azurerm_resource_group.landing_zone["network"].name

  bgp_route_propagation_enabled = true

  tags = merge(
    local.common_tags,
    {
      ResourcePurpose = "Application-Spoke-Routing"
    }
  )
}

resource "azurerm_subnet_route_table_association" "app_workload" {
  subnet_id      = azurerm_subnet.app_workload.id
  route_table_id = azurerm_route_table.app.id
}

resource "azurerm_subnet_route_table_association" "app_private_endpoints" {
  subnet_id      = azurerm_subnet.app_private_endpoints.id
  route_table_id = azurerm_route_table.app.id
}