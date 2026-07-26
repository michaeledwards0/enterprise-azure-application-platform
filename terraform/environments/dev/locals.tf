locals {
  common_tags = {
    Project            = var.project_name
    Environment        = var.environment
    ManagedBy          = "Terraform"
    Owner              = var.owner
    CostCenter         = var.cost_center
    DataClassification = var.data_classification
    Criticality        = var.criticality
  }

  resource_groups = {
    platform   = "rg-eaap-platform-${var.environment}"
    network    = "rg-eaap-network-${var.environment}"
    operations = "rg-eaap-operations-${var.environment}"
    workload   = "rg-eaap-workload-${var.environment}"
  }
}