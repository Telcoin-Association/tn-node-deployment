# Inputs the module refuses before it plans anything.

mock_provider "azurerm" {
  override_during = plan
}

variables {
  admin_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBERERERERERERERERERERERERERERERERERERERERER operator@example"
  admin_ssh_cidrs      = ["198.51.100.7/32"]
}

run "bad_network" {
  command = plan

  variables {
    network = "devnet"
  }

  expect_failures = [var.network]
}

run "public_vpc_cidr" {
  command = plan

  variables {
    vpc_cidr = "8.8.0.0/16"
  }

  expect_failures = [var.vpc_cidr]
}

run "public_subnet_cidr" {
  command = plan

  variables {
    subnet_cidr = "8.8.8.0/24"
  }

  expect_failures = [var.subnet_cidr]
}

run "subnet_outside_the_network" {
  command = plan

  variables {
    subnet_cidr = "10.43.1.0/24"
  }

  expect_failures = [var.subnet_cidr]
}

run "bastion_subnet_too_small" {
  command = plan

  variables {
    enable_bastion      = true
    bastion_subnet_cidr = "10.42.2.0/27"
  }

  expect_failures = [var.bastion_subnet_cidr]
}

run "bastion_subnet_overlaps_hosts" {
  command = plan

  variables {
    enable_bastion      = true
    bastion_subnet_cidr = "10.42.1.0/26"
  }

  expect_failures = [var.bastion_subnet_cidr]
}

run "invalid_admin_cidr" {
  command = plan

  variables {
    admin_ssh_cidrs = ["198.51.100.300/32"]
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

run "neither_access_route" {
  command = plan

  variables {
    admin_ssh_cidrs = []
    enable_bastion  = false
  }

  expect_failures = [var.enable_bastion]
}

run "four_cores_on_mainnet" {
  command = plan

  variables {
    network                 = "mainnet"
    validator_instance_type = "Standard_D8s_v5"
  }

  expect_failures = [var.validator_instance_type]
}

run "nvme_or_unlisted_size" {
  command = plan

  variables {
    validator_instance_type = "Standard_D16s_v6"
  }

  expect_failures = [var.validator_instance_type]
}

run "low_memory_size" {
  command = plan

  variables {
    validator_instance_type = "Standard_D8ls_v5"
  }

  expect_failures = [var.validator_instance_type]
}

run "disk_under_the_mainnet_floor" {
  command = plan

  variables {
    network           = "mainnet"
    data_disk_size_gb = 500
  }

  expect_failures = [var.data_disk_size_gb]
}

run "iops_below_floor" {
  command = plan

  variables {
    data_disk_iops = 10000
  }

  expect_failures = [var.data_disk_iops]
}

# The mainnet floors are above the testnet ones: a disk that meets
# testnet's is still refused on mainnet.
run "mainnet_iops_below_floor" {
  command = plan

  variables {
    network        = "mainnet"
    data_disk_iops = 15000
  }

  expect_failures = [var.data_disk_iops]
}

run "mainnet_throughput_below_floor" {
  command = plan

  variables {
    network              = "mainnet"
    data_disk_throughput = 240
  }

  expect_failures = [var.data_disk_throughput]
}

run "throughput_below_floor" {
  command = plan

  variables {
    data_disk_throughput = 125
  }

  expect_failures = [var.data_disk_throughput]
}

run "throughput_over_premium_v2" {
  command = plan

  variables {
    data_disk_throughput = 2500
  }

  expect_failures = [var.data_disk_throughput]
}

run "service_account_as_admin_user" {
  command = plan

  variables {
    admin_username = "telcoin"
  }

  expect_failures = [var.admin_username]
}

run "reserved_admin_user" {
  command = plan

  variables {
    admin_username = "admin"
  }

  expect_failures = [var.admin_username]
}

run "not_an_ssh_public_key" {
  command = plan

  variables {
    admin_ssh_public_key = "-----BEGIN OPENSSH PRIVATE KEY-----"
  }

  expect_failures = [var.admin_ssh_public_key]
}

run "bad_name_prefix" {
  command = plan

  variables {
    name_prefix = "TN_node"
  }

  expect_failures = [var.name_prefix]
}

run "bad_ubuntu_version" {
  command = plan

  variables {
    ubuntu_version = "22.04"
  }

  expect_failures = [var.ubuntu_version]
}

run "missing_hubs_file" {
  command = plan

  variables {
    trusted_nodes_file = "tests/no-such-file.yaml"
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
