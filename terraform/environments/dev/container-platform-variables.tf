variable "container_registry_name" {
  description = "Globally unique Azure Container Registry name."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9]{5,50}$", var.container_registry_name))
    error_message = "The registry name must contain 5-50 letters or numbers."
  }
}

variable "aks_admin_public_ip_cidr" {
  description = "Public CIDR allowed to administer the AKS API server."
  type        = string
  sensitive   = true
}

variable "aks_kubernetes_version" {
  description = "Supported AKS Kubernetes version selected during deployment."
  type        = string
}

variable "aks_system_node_vm_size" {
  description = "VM size for the system pool."
  type        = string
  default     = "Standard_D2s_v3"
}

variable "aks_user_node_vm_size" {
  description = "VM size for the application pool."
  type        = string
  default     = "Standard_D2s_v3"
}