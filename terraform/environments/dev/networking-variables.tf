variable "hub_vnet_address_space" {
  description = "Address space for the development hub virtual network."
  type        = list(string)
  default     = ["10.10.0.0/16"]
}

variable "app_vnet_address_space" {
  description = "Address space for the development application spoke virtual network."
  type        = list(string)
  default     = ["10.20.0.0/16"]
}

variable "hub_shared_services_subnet_prefix" {
  description = "CIDR prefix for the hub shared-services subnet."
  type        = list(string)
  default     = ["10.10.1.0/24"]
}

variable "hub_bastion_subnet_prefix" {
  description = "CIDR prefix reserved for Azure Bastion."
  type        = list(string)
  default     = ["10.10.2.0/26"]
}

variable "app_ingress_subnet_prefix" {
  description = "CIDR prefix for future ingress components."
  type        = list(string)
  default     = ["10.20.1.0/24"]
}

variable "app_workload_subnet_prefix" {
  description = "CIDR prefix for application platform workloads."
  type        = list(string)
  default     = ["10.20.2.0/23"]
}

variable "app_private_endpoints_subnet_prefix" {
  description = "CIDR prefix for Azure Private Endpoints."
  type        = list(string)
  default     = ["10.20.4.0/24"]
}

variable "private_dns_zone_name" {
  description = "Internal private DNS namespace used by the platform."
  type        = string
  default     = "internal.contoso.com"
}
