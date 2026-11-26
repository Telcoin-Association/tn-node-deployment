# Inputs the root refuses at plan, before anything is created.

mock_provider "google" {
  override_during = plan

  override_data {
    target = data.google_compute_image.ubuntu
    values = { self_link = "https://www.googleapis.com/compute/v1/projects/ubuntu-os-cloud/global/images/ubuntu-2604-lts-amd64-v20261101" }
  }

  override_data {
    target = data.google_compute_machine_types.validator
    values = { machine_types = [{ name = "c3-standard-8", guest_cpus = 8, memory_mb = 32768 }] }
  }

  override_resource {
    target = google_compute_address.validator_public
    values = { address = "203.0.113.10" }
  }

  override_resource {
    target = google_compute_address.gateway_public
    values = { address = "203.0.113.20" }
  }
}

variables {
  project = "tn-test-project"
}

run "bad_network" {
  command = plan

  variables {
    network = "devnet"
  }

  expect_failures = [var.network]
}

run "public_subnet" {
  command = plan

  variables {
    vpc_cidr    = "10.42.0.0/16"
    subnet_cidr = "203.0.113.0/24"
  }

  expect_failures = [var.subnet_cidr]
}

run "public_vpc" {
  command = plan

  variables {
    vpc_cidr    = "198.18.0.0/15"
    subnet_cidr = "10.42.1.0/24"
  }

  expect_failures = [var.vpc_cidr]
}

run "subnet_outside_vpc" {
  command = plan

  variables {
    subnet_cidr = "10.43.1.0/24"
  }

  expect_failures = [var.subnet_cidr]
}

run "subnet_too_small" {
  command = plan

  variables {
    subnet_cidr = "10.42.1.0/28"
  }

  expect_failures = [var.subnet_cidr]
}

run "bad_admin_cidr" {
  command = plan

  variables {
    admin_ssh_cidrs = ["198.51.100.7"]
  }

  expect_failures = [var.admin_ssh_cidrs]
}

run "no_access_route" {
  command = plan

  variables {
    enable_iap      = false
    admin_ssh_cidrs = []
  }

  expect_failures = [var.enable_iap]
}

run "bad_admin_member" {
  command = plan

  variables {
    admin_members = ["ops@example.org"]
  }

  expect_failures = [var.admin_members]
}

run "four_cores_on_mainnet" {
  command = plan

  variables {
    network                 = "mainnet"
    validator_instance_type = "c3-standard-8"
  }

  expect_failures = [google_compute_instance.validator]
}

run "type_not_in_zone" {
  command = plan

  variables {
    validator_instance_type = "c3-standard-9"
  }

  override_data {
    target = data.google_compute_machine_types.validator
    values = { machine_types = [] }
  }

  expect_failures = [google_compute_instance.validator]
}

run "mainnet_disk_below_floor" {
  command = plan

  variables {
    network           = "mainnet"
    data_disk_size_gb = 500
  }

  override_data {
    target = data.google_compute_machine_types.validator
    values = { machine_types = [{ name = "c3d-standard-16", guest_cpus = 16, memory_mb = 65536 }] }
  }

  expect_failures = [var.data_disk_size_gb]
}

run "mainnet_iops_below_floor" {
  command = plan

  variables {
    network        = "mainnet"
    data_disk_iops = 15000
  }

  override_data {
    target = data.google_compute_machine_types.validator
    values = { machine_types = [{ name = "c3d-standard-16", guest_cpus = 16, memory_mb = 65536 }] }
  }

  expect_failures = [var.data_disk_iops]
}

run "mainnet_throughput_below_floor" {
  command = plan

  variables {
    network              = "mainnet"
    data_disk_throughput = 240
  }

  override_data {
    target = data.google_compute_machine_types.validator
    values = { machine_types = [{ name = "c3d-standard-16", guest_cpus = 16, memory_mb = 65536 }] }
  }

  expect_failures = [var.data_disk_throughput]
}

run "iops_over_hyperdisk_limit" {
  command = plan

  variables {
    data_disk_iops = 200000
  }

  expect_failures = [var.data_disk_iops]
}

run "throughput_over_iops_ratio" {
  command = plan

  variables {
    data_disk_iops       = 15000
    data_disk_throughput = 4000
  }

  expect_failures = [var.data_disk_throughput]
}

run "zone_outside_region" {
  command = plan

  variables {
    region = "us-central1"
    zone   = "europe-west4-a"
  }

  expect_failures = [var.zone]
}

run "missing_hubs_file" {
  command = plan

  variables {
    trusted_nodes_file = "tests/fixtures/no-such-file.yaml"
  }

  expect_failures = [var.trusted_nodes_file]
}
