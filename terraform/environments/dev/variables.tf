variable "location" {
  description = "Primary Azure region for the development environment."
  type        = string
  default     = "southcentralus"
}

variable "environment" {
  description = "Deployment environment."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "Environment must be dev, test, or prod."
  }
}

variable "project_name" {
  description = "Long-form project name used in tags."
  type        = string
  default     = "Enterprise-Azure-Application-Platform"
}

variable "owner" {
  description = "Operational owner applied to Azure tags."
  type        = string
  default     = "Cloud-Platform-Team"
}

variable "cost_center" {
  description = "Cost allocation value applied to Azure tags."
  type        = string
  default     = "Platform-Engineering"
}

variable "data_classification" {
  description = "Baseline data classification."
  type        = string
  default     = "Internal"
}

variable "criticality" {
  description = "Operational criticality for the environment."
  type        = string
  default     = "Medium"
}