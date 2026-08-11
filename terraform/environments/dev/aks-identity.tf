resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                = azurerm_container_registry.platform.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.platform.kubelet_identity[0].object_id
}

resource "azurerm_role_assignment" "aks_ingress_subnet_network_contributor" {
  scope                = azurerm_subnet.app_ingress.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.platform.identity[0].principal_id
}

resource "azurerm_federated_identity_credential" "sample_app" {
  name                      = "fic-eaap-sample-app-${var.environment}"
  user_assigned_identity_id = azurerm_user_assigned_identity.workload.id

  audience = ["api://AzureADTokenExchange"]
  issuer   = azurerm_kubernetes_cluster.platform.oidc_issuer_url
  subject  = "system:serviceaccount:eaap-app:eaap-workload-sa"
}
