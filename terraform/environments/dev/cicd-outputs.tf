output "github_actions_identity" {
  description = "Identity used by GitHub Actions OIDC authentication."
  value = {
    name      = azurerm_user_assigned_identity.github_actions.name
    client_id = azurerm_user_assigned_identity.github_actions.client_id
  }
}