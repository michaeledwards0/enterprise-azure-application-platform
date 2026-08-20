output "github_actions_identity" {
  description = "Microsoft Entra application used by GitHub Actions OIDC authentication."

  value = {
    display_name = azuread_application.github_actions.display_name
    client_id    = azuread_application.github_actions.client_id
    object_id    = azuread_service_principal.github_actions.object_id
  }
}