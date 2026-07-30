resource "azurerm_network_security_group" "ingress" {
  name                = "nsg-eaap-ingress-${var.environment}-scus-001"
  location            = azurerm_resource_group.landing_zone["network"].location
  resource_group_name = azurerm_resource_group.landing_zone["network"].name

  tags = merge(
    local.common_tags,
    {
      ResourcePurpose = "Ingress-Subnet-Security"
    }
  )
}

resource "azurerm_network_security_group" "workload" {
  name                = "nsg-eaap-workload-${var.environment}-scus-001"
  location            = azurerm_resource_group.landing_zone["network"].location
  resource_group_name = azurerm_resource_group.landing_zone["network"].name

  tags = merge(
    local.common_tags,
    {
      ResourcePurpose = "Workload-Subnet-Security"
    }
  )
}

resource "azurerm_network_security_rule" "allow_ingress_https_to_workload" {
  name                        = "Allow-Ingress-HTTPS-To-Workload"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = var.app_ingress_subnet_prefix[0]
  destination_address_prefix  = var.app_workload_subnet_prefix[0]
  resource_group_name         = azurerm_resource_group.landing_zone["network"].name
  network_security_group_name = azurerm_network_security_group.workload.name
}

resource "azurerm_network_security_rule" "deny_other_inbound_to_workload" {
  name                        = "Deny-Other-Inbound-To-Workload"
  priority                    = 400
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.landing_zone["network"].name
  network_security_group_name = azurerm_network_security_group.workload.name
}

resource "azurerm_subnet_network_security_group_association" "ingress" {
  subnet_id                 = azurerm_subnet.app_ingress.id
  network_security_group_id = azurerm_network_security_group.ingress.id
}

resource "azurerm_subnet_network_security_group_association" "workload" {
  subnet_id                 = azurerm_subnet.app_workload.id
  network_security_group_id = azurerm_network_security_group.workload.id
}
