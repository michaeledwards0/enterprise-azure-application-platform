resource "azurerm_virtual_network" "hub" {
  name                = "vnet-eaap-hub-${var.environment}-scus-001"
  location            = azurerm_resource_group.landing_zone["network"].location
  resource_group_name = azurerm_resource_group.landing_zone["network"].name
  address_space       = var.hub_vnet_address_space

  tags = merge(
    local.common_tags,
    {
      ResourcePurpose = "Hub-Network"
    }
  )
}

resource "azurerm_virtual_network" "app" {
  name                = "vnet-eaap-app-${var.environment}-scus-001"
  location            = azurerm_resource_group.landing_zone["network"].location
  resource_group_name = azurerm_resource_group.landing_zone["network"].name
  address_space       = var.app_vnet_address_space

  tags = merge(
    local.common_tags,
    {
      ResourcePurpose = "Application-Spoke-Network"
    }
  )
}

resource "azurerm_subnet" "hub_shared_services" {
  name                 = "snet-shared-services-${var.environment}-scus-001"
  resource_group_name  = azurerm_resource_group.landing_zone["network"].name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = var.hub_shared_services_subnet_prefix
}

resource "azurerm_subnet" "hub_bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.landing_zone["network"].name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = var.hub_bastion_subnet_prefix
}

resource "azurerm_subnet" "app_ingress" {
  name                 = "snet-ingress-${var.environment}-scus-001"
  resource_group_name  = azurerm_resource_group.landing_zone["network"].name
  virtual_network_name = azurerm_virtual_network.app.name
  address_prefixes     = var.app_ingress_subnet_prefix
}

resource "azurerm_subnet" "app_workload" {
  name                 = "snet-workload-${var.environment}-scus-001"
  resource_group_name  = azurerm_resource_group.landing_zone["network"].name
  virtual_network_name = azurerm_virtual_network.app.name
  address_prefixes     = var.app_workload_subnet_prefix
}

resource "azurerm_subnet" "app_private_endpoints" {
  name                 = "snet-private-endpoints-${var.environment}-scus-001"
  resource_group_name  = azurerm_resource_group.landing_zone["network"].name
  virtual_network_name = azurerm_virtual_network.app.name
  address_prefixes     = var.app_private_endpoints_subnet_prefix
}

resource "azurerm_virtual_network_peering" "hub_to_app" {
  name                      = "peer-hub-to-app-${var.environment}"
  resource_group_name       = azurerm_resource_group.landing_zone["network"].name
  virtual_network_name      = azurerm_virtual_network.hub.name
  remote_virtual_network_id = azurerm_virtual_network.app.id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

resource "azurerm_virtual_network_peering" "app_to_hub" {
  name                      = "peer-app-to-hub-${var.environment}"
  resource_group_name       = azurerm_resource_group.landing_zone["network"].name
  virtual_network_name      = azurerm_virtual_network.app.name
  remote_virtual_network_id = azurerm_virtual_network.hub.id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}
