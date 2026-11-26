# Validations that compare two variables need 1.9. Each provider is held to one
# major version; .terraform.lock.hcl records the exact release and its hashes.
# No backend block: where the state lives is the operator's choice.
terraform {
  required_version = ">= 1.9, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.72"
    }
    dns = {
      source  = "hashicorp/dns"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Deployment = var.name_prefix
      Network    = var.network
    }
  }
}
