output "resource_group_names" {
  description = "Landing-zone resource groups by purpose."
  value = {
    for purpose, resource_group in azurerm_resource_group.landing_zone :
    purpose => resource_group.name
  }
}

output "resource_group_ids" {
  description = "Landing-zone resource group IDs by purpose."
  value = {
    for purpose, resource_group in azurerm_resource_group.landing_zone :
    purpose => resource_group.id
  }
}

output "common_tags" {
  description = "Required tags applied by the landing-zone configuration."
  value       = local.common_tags
}