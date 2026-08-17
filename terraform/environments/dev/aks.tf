resource "azurerm_kubernetes_cluster" "platform" {
  name                = "aks-eaap-${var.environment}-scus-001"
  location            = azurerm_resource_group.landing_zone["platform"].location
  resource_group_name = azurerm_resource_group.landing_zone["platform"].name
  dns_prefix          = "aks-eaap-${var.environment}"
  kubernetes_version  = var.aks_kubernetes_version

  role_based_access_control_enabled = true
  local_account_disabled            = true
  oidc_issuer_enabled               = true
  workload_identity_enabled         = true

  api_server_access_profile {
    authorized_ip_ranges = [var.aks_admin_public_ip_cidr]
  }

  default_node_pool {
    name                         = "system"
    vm_size                      = var.aks_system_node_vm_size
    vnet_subnet_id               = azurerm_subnet.app_workload.id
    auto_scaling_enabled         = true
    min_count                    = 1
    max_count                    = 2
    only_critical_addons_enabled = true
    os_disk_size_gb              = 64
    type                         = "VirtualMachineScaleSets"

    upgrade_settings {
      max_surge                     = "10%"
      drain_timeout_in_minutes      = 0
      node_soak_duration_in_minutes = 0
    }
  }

  identity {
    type = "SystemAssigned"
  }

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = data.azurerm_client_config.current.tenant_id
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "cilium"
    network_data_plane  = "cilium"
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"
    service_cidr        = "10.30.0.0/16"
    dns_service_ip      = "10.30.0.10"
  }

  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  tags = merge(
    local.common_tags,
    {
      ResourcePurpose = "Managed-Kubernetes-Platform"
    }
  )
}

resource "azurerm_kubernetes_cluster_node_pool" "apps" {
  name                  = "apps"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.platform.id
  vm_size               = var.aks_user_node_vm_size
  vnet_subnet_id        = azurerm_subnet.app_workload.id
  mode                  = "User"

  auto_scaling_enabled = true
  min_count            = 1
  max_count            = 2
  os_disk_size_gb      = 64

  node_labels = {
    workload = "applications"
  }

  tags = merge(
    local.common_tags,
    {
      ResourcePurpose = "Application-Node-Pool"
    }
  )

  upgrade_settings {
    max_surge                     = "10%"
    drain_timeout_in_minutes      = 0
    node_soak_duration_in_minutes = 0
  }
}