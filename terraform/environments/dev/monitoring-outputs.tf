output "monitoring" {
  description = "EAAP monitoring resources."

  value = {
    log_analytics_workspace_name = azurerm_log_analytics_workspace.platform.name
    log_analytics_workspace_id   = azurerm_log_analytics_workspace.platform.id
    action_group_name            = azurerm_monitor_action_group.platform_operations.name
    aks_diagnostic_setting_name  = azurerm_monitor_diagnostic_setting.aks.name
  }
}
