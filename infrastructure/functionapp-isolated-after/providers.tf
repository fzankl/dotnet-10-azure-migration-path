terraform {
  required_version = ">= 1.15.8, < 1.16.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "= 5.0.0"
    }
  }
}

provider "azurerm" {
  features {}
}
