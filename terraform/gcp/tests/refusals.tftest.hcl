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

# The floor is the node scripts' own, 8 cores and 32 GiB, in vCPUs here.
run "mainnet_under_32_gib" {
  command = plan

  variables {
    network = "mainnet"
  }

  override_data {
    target = data.google_compute_machine_types.validator
    values = { machine_types = [{ name = "c3d-standard-16", guest_cpus = 16, memory_mb = 31744 }] }
  }

  expect_failures = [google_compute_instance.validator]
}

run "mainnet_32_gib" {
  command = plan

  variables {
    network = "mainnet"
  }

  override_data {
    target = data.google_compute_machine_types.validator
    values = { machine_types = [{ name = "c3d-standard-16", guest_cpus = 16, memory_mb = 32768 }] }
  }

  assert {
    condition     = google_compute_instance.validator.machine_type == "c3d-standard-16"
    error_message = "A mainnet type at the floor, 8 cores and 32 GiB, is accepted."
  }
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

run "throughput_over_hyperdisk" {
  command = plan

  variables {
    data_disk_throughput = 2500
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

run "domain_without_gateway" {
  command = plan

  variables {
    gateway_enabled = false
    rpc_domain      = "rpc.example.org"
  }

  expect_failures = [var.rpc_domain]
}

run "admin_cidr_ipv6" {
  command = plan

  variables {
    admin_ssh_cidrs = ["2001:db8::/32"]
  }

  expect_failures = [var.admin_ssh_cidrs]
}

run "admin_cidr_with_host_bits" {
  command = plan

  variables {
    admin_ssh_cidrs = ["198.51.100.7/24"]
  }

  expect_failures = [var.admin_ssh_cidrs]
}

run "vpc_with_host_bits" {
  command = plan

  variables {
    vpc_cidr = "10.42.0.5/16"
  }

  expect_failures = [var.vpc_cidr]
}

run "zero_validator_address" {
  command = plan

  variables {
    validator_address = "0x0000000000000000000000000000000000000000"
  }

  expect_failures = [var.validator_address]
}

run "mainnet_release_tag_on_testnet" {
  command = plan

  variables {
    node_release_tag = "v0.18.0"
  }

  expect_failures = [var.node_release_tag]
}

run "redirect_not_a_url" {
  command = plan

  variables {
    redirect_queries_url = "rpc.example.org"
  }

  expect_failures = [var.redirect_queries_url]
}

run "rate_limit_not_whole" {
  command = plan

  variables {
    gateway_rate_limit_submissions = 1.5
  }

  expect_failures = [var.gateway_rate_limit_submissions]
}

# Hyperdisk Balanced needs at least IOPS/256 MiB/s: 100000 IOPS need 391.
run "throughput_under_iops_share" {
  command = plan

  variables {
    data_disk_iops       = 100000
    data_disk_throughput = 300
  }

  expect_failures = [var.data_disk_throughput]
}
