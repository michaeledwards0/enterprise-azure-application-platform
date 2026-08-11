output "container_registry" {
  value = {
    name         = azurerm_container_registry.platform.name
    login_server = azurerm_container_registry.platform.login_server
  }
}

output "aks_cluster" {
  value = {
    name            = azurerm_kubernetes_cluster.platform.name
    resource_group  = azurerm_kubernetes_cluster.platform.resource_group_name
    oidc_issuer_url = azurerm_kubernetes_cluster.platform.oidc_issuer_url
  }
}

output "workload_identity_client_id" {
  value = azurerm_user_assigned_identity.workload.client_id
}