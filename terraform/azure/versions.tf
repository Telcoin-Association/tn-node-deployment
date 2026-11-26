# Validations that compare two variables need 1.9. There is no backend block:
# where the state lives is the operator's choice, and nothing in it is secret.
terraform {
  required_version = ">= 1.9, < 2.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.14"
    }
  }
}

provider "azurerm" {
  # Null leaves the subscription to ARM_SUBSCRIPTION_ID.
  subscription_id = var.subscription_id

  features {}
}
