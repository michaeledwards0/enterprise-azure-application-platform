variable "log_analytics_retention_days" {
  description = "Retention period for the EAAP Log Analytics workspace."
  type        = number
  default     = 30
}

variable "operations_alert_email" {
  description = "Email address used by the EAAP operations action group."
  type        = string
  sensitive   = true
}