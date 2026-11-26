# One validator host and, once rpc_domain is set, one worker-gateway host on
# Google Compute Engine. There is no backend block: where the state lives is
# the operator's choice. Validations that compare two variables need 1.9.
terraform {
  required_version = ">= 1.9, < 2.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.12"
    }
  }
}

provider "google" {
  project = var.project
  region  = var.region
  zone    = local.zone

  default_labels = {
    deployment = var.name_prefix
    network    = var.network
  }
}
