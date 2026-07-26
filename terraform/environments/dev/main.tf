resource "azurerm_resource_group" "landing_zone" {
  for_each = local.resource_groups

  name     = each.value
  location = var.location

  tags = merge(
    local.common_tags,
    {
      ResourcePurpose = title(each.key)
    }
  )
}