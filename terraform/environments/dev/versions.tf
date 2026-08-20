terraform {
  required_version = ">= 1.6.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0, < 5.0"
    }

    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.9"
    }
  }
}

provider "azuread" {}