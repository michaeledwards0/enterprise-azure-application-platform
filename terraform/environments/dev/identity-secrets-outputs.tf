output "workload_identity" {
  description = "Managed identity used by future AKS workloads."
  value = {
    name         = azurerm_user_assigned_identity.workload.name
    id           = azurerm_user_assigned_identity.workload.id
    client_id    = azurerm_user_assigned_identity.workload.client_id
    principal_id = azurerm_user_assigned_identity.workload.principal_id
  }
}

output "key_vault" {
  description = "Key Vault deployment details."
  value = {
    name      = azurerm_key_vault.platform.name
    id        = azurerm_key_vault.platform.id
    vault_uri = azurerm_key_vault.platform.vault_uri
  }
}

output "key_vault_private_endpoint_ip" {
  description = "Private IP assigned to the Key Vault private endpoint."
  value       = azurerm_private_endpoint.key_vault.private_service_connection[0].private_ip_address
}