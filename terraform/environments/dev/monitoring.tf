resource "azurerm_log_analytics_workspace" "platform" {
  name                = "law-eaap-ops-${var.environment}-scus-001"
  location            = azurerm_resource_group.landing_zone["operations"].location
  resource_group_name = azurerm_resource_group.landing_zone["operations"].name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_analytics_retention_days

  tags = merge(
    local.common_tags,
    {
      ResourcePurpose = "Platform-Observability"
    }
  )
}

data "azurerm_monitor_diagnostic_categories" "aks" {
  resource_id = azurerm_kubernetes_cluster.platform.id
}

locals {
  desired_aks_log_categories = toset([
    "kube-apiserver",
    "kube-audit-admin",
    "kube-controller-manager",
    "kube-scheduler",
    "cluster-autoscaler"
  ])

  available_aks_log_categories = toset(
    data.azurerm_monitor_diagnostic_categories.aks.log_category_types
  )

  enabled_aks_log_categories = setintersection(
    local.desired_aks_log_categories,
    local.available_aks_log_categories
  )
}

resource "azurerm_monitor_diagnostic_setting" "aks" {
  name                           = "diag-eaap-aks-${var.environment}"
  target_resource_id             = azurerm_kubernetes_cluster.platform.id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.platform.id
  log_analytics_destination_type = "Dedicated"

  dynamic "enabled_log" {
    for_each = local.enabled_aks_log_categories

    content {
      category = enabled_log.value
    }
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_action_group" "platform_operations" {
  name                = "ag-eaap-platform-${var.environment}-scus-001"
  resource_group_name = azurerm_resource_group.landing_zone["operations"].name
  short_name          = "eaapops"

  email_receiver {
    name                    = "Primary-Engineer"
    email_address           = var.operations_alert_email
    use_common_alert_schema = true
  }

  tags = merge(
    local.common_tags,
    {
      ResourcePurpose = "Platform-Alert-Notifications"
    }
  )
}