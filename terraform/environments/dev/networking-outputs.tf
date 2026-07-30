output "hub_vnet" {
  description = "Hub virtual network name and ID."
  value = {
    name = azurerm_virtual_network.hub.name
    id   = azurerm_virtual_network.hub.id
  }
}

output "app_vnet" {
  description = "Application spoke virtual network name and ID."
  value = {
    name = azurerm_virtual_network.app.name
    id   = azurerm_virtual_network.app.id
  }
}

output "network_subnet_ids" {
  description = "Subnet IDs used by later workstreams."
  value = {
    hub_shared_services = azurerm_subnet.hub_shared_services.id
    hub_bastion         = azurerm_subnet.hub_bastion.id
    app_ingress         = azurerm_subnet.app_ingress.id
    app_workload        = azurerm_subnet.app_workload.id
    private_endpoints   = azurerm_subnet.app_private_endpoints.id
  }
}

output "network_security_group_ids" {
  description = "Network security group IDs."
  value = {
    ingress  = azurerm_network_security_group.ingress.id
    workload = azurerm_network_security_group.workload.id
  }
}

output "app_route_table_id" {
  description = "Application spoke route table ID."
  value       = azurerm_route_table.app.id
}

output "private_dns_zone" {
  description = "Private DNS zone name and ID."
  value = {
    name = azurerm_private_dns_zone.internal.name
    id   = azurerm_private_dns_zone.internal.id
  }
}
