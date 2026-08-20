resource "azurerm_user_assigned_identity" "github_actions" {
  name                = "id-eaap-github-actions-${var.environment}-scus-001"
  location            = azurerm_resource_group.landing_zone["platform"].location
  resource_group_name = azurerm_resource_group.landing_zone["platform"].name

  tags = merge(
    local.common_tags,
    {
      ResourcePurpose = "GitHub-Actions-CICD-Identity"
    }
  )
}

resource "azurerm_federated_identity_credential" "github_dev" {
  name                      = "fic-eaap-github-dev"
  user_assigned_identity_id = azurerm_user_assigned_identity.github_actions.id
  issuer                    = "https://token.actions.githubusercontent.com"
  subject                   = var.github_oidc_subject
  audience                  = ["api://AzureADTokenExchange"]
}


resource "azuread_application" "github_actions" {
  display_name     = "app-eaap-github-actions-${var.environment}"
  sign_in_audience = "AzureADMyOrg"
}

resource "azuread_service_principal" "github_actions" {
  client_id = azuread_application.github_actions.client_id
}

resource "azuread_application_federated_identity_credential" "github_dev" {
  application_id = azuread_application.github_actions.id
  display_name   = "fic-eaap-github-dev"

  audiences = [
    "api://AzureADTokenExchange"
  ]

  issuer  = "https://token.actions.githubusercontent.com"
  subject = var.github_oidc_subject
}

resource "azurerm_role_assignment" "github_acr_push" {
  scope                = azurerm_container_registry.platform.id
  role_definition_name = "AcrPush"
  principal_id         = azurerm_user_assigned_identity.github_actions.principal_id
}

resource "azurerm_role_assignment" "github_aks_contributor" {
  scope                = azurerm_kubernetes_cluster.platform.id
  role_definition_name = "Azure Kubernetes Service Contributor Role"
  principal_id         = azurerm_user_assigned_identity.github_actions.principal_id
}

resource "azurerm_role_assignment" "github_aks_cluster_user" {
  scope                = azurerm_kubernetes_cluster.platform.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = azurerm_user_assigned_identity.github_actions.principal_id
}

resource "azurerm_role_assignment" "github_aks_namespace_writer" {
  scope                = "${azurerm_kubernetes_cluster.platform.id}/namespaces/eaap-app"
  role_definition_name = "Azure Kubernetes Service RBAC Writer"
  principal_id         = azurerm_user_assigned_identity.github_actions.principal_id
}

resource "azurerm_role_assignment" "github_sp_acr_push" {
  scope                = azurerm_container_registry.platform.id
  role_definition_name = "AcrPush"
  principal_id         = azuread_service_principal.github_actions.object_id
}

resource "azurerm_role_assignment" "github_sp_aks_contributor" {
  scope                = azurerm_kubernetes_cluster.platform.id
  role_definition_name = "Azure Kubernetes Service Contributor Role"
  principal_id         = azuread_service_principal.github_actions.object_id
}

resource "azurerm_role_assignment" "github_sp_aks_cluster_user" {
  scope                = azurerm_kubernetes_cluster.platform.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = azuread_service_principal.github_actions.object_id
}

resource "azurerm_role_assignment" "github_sp_aks_namespace_writer" {
  scope                = "${azurerm_kubernetes_cluster.platform.id}/namespaces/eaap-app"
  role_definition_name = "Azure Kubernetes Service RBAC Writer"
  principal_id         = azuread_service_principal.github_actions.object_id
}

resource "azurerm_role_assignment" "github_sp_workload_subnet_network_contributor" {
  scope                = azurerm_subnet.app_workload.id
  role_definition_name = "Network Contributor"
  principal_id         = azuread_service_principal.github_actions.object_id
}

resource "azurerm_role_assignment" "github_sp_log_analytics_contributor" {
  scope                = azurerm_log_analytics_workspace.platform.id
  role_definition_name = "Log Analytics Contributor"
  principal_id         = azuread_service_principal.github_actions.object_id
}