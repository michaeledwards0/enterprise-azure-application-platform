resource "azurerm_monitor_data_collection_rule" "container_insights" {
  name                = "dcr-eaap-container-insights-${var.environment}-scus-001"
  resource_group_name = azurerm_resource_group.landing_zone["platform"].name
  location            = azurerm_resource_group.landing_zone["platform"].location

  destinations {
    log_analytics {
      workspace_resource_id = azurerm_log_analytics_workspace.platform.id
      name                  = "ciworkspace"
    }
  }

  data_flow {
    streams      = ["Microsoft-ContainerInsights-Group-Default"]
    destinations = ["ciworkspace"]
  }

  data_sources {
    extension {
      streams        = ["Microsoft-ContainerInsights-Group-Default"]
      extension_name = "ContainerInsights"
      extension_json = jsonencode({
        dataCollectionSettings = {
          interval               = "1m"
          namespaceFilteringMode = "Off"
          enableContainerLogV2   = true
        }
      })
      name = "ContainerInsightsExtension"
    }
  }

  tags = merge(
    local.common_tags,
    {
      ResourcePurpose = "Container-Insights-Collection-Rule"
    }
  )
}

resource "azurerm_monitor_data_collection_rule_association" "aks_container_insights" {
  name                    = "ContainerInsightsExtension"
  target_resource_id      = azurerm_kubernetes_cluster.platform.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.container_insights.id
}