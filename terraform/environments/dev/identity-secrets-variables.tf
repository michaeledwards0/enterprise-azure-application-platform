variable "key_vault_name" {
  description = "Globally unique Key Vault name."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9-]{3,24}$", var.key_vault_name))
    error_message = "The Key Vault name must contain 3-24 letters, numbers, or hyphens."
  }
}

variable "admin_public_ip_cidr" {
  description = "Current administrator public IP in CIDR notation for temporary Key Vault access."
  type        = string
  sensitive   = true
}