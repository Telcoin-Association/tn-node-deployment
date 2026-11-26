# Inputs that would build a host the network cannot use, or open more than the
# design allows, are refused at plan time, before anything exists.

mock_provider "aws" {
  source          = "./tests/mocks"
  override_during = plan
}

variables {
  region            = "us-east-1"
  availability_zone = "us-east-1a"
}

run "accepted_baseline" {
  command = plan
}

run "bad_network" {
  command = plan
  variables {
    network = "devnet"
  }
  expect_failures = [var.network]
}

run "name_prefix_like_a_group_id" {
  command = plan
  variables {
    name_prefix = "sg-node"
  }
  expect_failures = [var.name_prefix]
}

run "public_subnet" {
  command = plan
  variables {
    subnet_cidr = "198.51.100.0/24"
  }
  expect_failures = [var.subnet_cidr]
}

run "public_vpc" {
  command = plan
  variables {
    vpc_cidr = "198.51.0.0/16"
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

run "admin_cidr_with_host_bits" {
  command = plan
  variables {
    admin_ssh_cidrs = ["198.51.100.7/24"]
  }
  expect_failures = [var.admin_ssh_cidrs]
}

run "admin_cidr_ipv6" {
  command = plan
  variables {
    admin_ssh_cidrs = ["2001:db8::/32"]
  }
  expect_failures = [var.admin_ssh_cidrs]
}

run "admin_cidr_not_a_cidr" {
  command = plan
  variables {
    admin_ssh_cidrs = ["198.51.100.7"]
  }
  expect_failures = [var.admin_ssh_cidrs]
}

run "domain_without_gateway" {
  command = plan
  variables {
    gateway_enabled = false
    rpc_domain      = "rpc.example.org"
  }
  expect_failures = [var.rpc_domain]
}

run "zone_of_another_region" {
  command = plan
  variables {
    availability_zone = "eu-west-1a"
  }
  expect_failures = [var.availability_zone]
}

run "zone_lacking_the_validator_type" {
  command = plan
  variables {
    availability_zone = "us-east-1b"
  }
  expect_failures = [aws_subnet.main]
}

run "zone_lacking_the_gateway_type" {
  command = plan

  override_data {
    target = data.aws_ec2_instance_type_offerings.zone
    values = {
      locations      = ["us-east-1a", "us-east-1b"]
      instance_types = ["m7i.2xlarge", "m7i.large"]
    }
  }

  expect_failures = [aws_subnet.main]
}

run "zone_is_the_region" {
  command = plan
  variables {
    availability_zone = "us-east-1"
  }
  expect_failures = [var.availability_zone]
}

run "mainnet_disk_below_floor" {
  command = plan
  variables {
    network           = "mainnet"
    data_disk_size_gb = 1000
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

run "throughput_over_gp3" {
  command = plan
  variables {
    data_disk_throughput = 2500
  }
  expect_failures = [var.data_disk_throughput]
}

run "kms_alias" {
  command = plan
  variables {
    disk_kms_key = "arn:aws:kms:us-east-1:111122223333:alias/aws/ebs"
  }
  expect_failures = [var.disk_kms_key]
}

run "missing_hubs_file" {
  command = plan
  variables {
    trusted_nodes_file = "tests/fixtures/absent.yaml"
  }
  expect_failures = [var.trusted_nodes_file]
}

run "mainnet_four_cores" {
  command = plan
  variables {
    network                 = "mainnet"
    validator_instance_type = "m7i.2xlarge"
  }

  override_data {
    target = data.aws_ec2_instance_type.validator
    values = {
      default_cores           = 4
      memory_size             = 32768
      supported_architectures = ["x86_64"]
      ebs_nvme_support        = "required"
      nitro_tpm_support       = "supported"
    }
  }

  expect_failures = [aws_instance.validator]
}

# The floor is the node scripts' own: 8 cores and 32 GiB.
run "mainnet_under_32_gib" {
  command = plan
  variables {
    network = "mainnet"
  }

  override_data {
    target = data.aws_ec2_instance_type.validator
    values = {
      default_cores           = 8
      memory_size             = 31744
      supported_architectures = ["x86_64"]
      ebs_nvme_support        = "required"
      nitro_tpm_support       = "supported"
    }
  }

  expect_failures = [aws_instance.validator]
}

run "mainnet_32_gib" {
  command = plan
  variables {
    network = "mainnet"
  }

  override_data {
    target = data.aws_ec2_instance_type.validator
    values = {
      default_cores           = 8
      memory_size             = 32768
      supported_architectures = ["x86_64"]
      ebs_nvme_support        = "required"
      nitro_tpm_support       = "supported"
    }
  }

  assert {
    condition     = aws_instance.validator.instance_type == "m7i.4xlarge"
    error_message = "A mainnet type at the floor, 8 cores and 32 GiB, is accepted."
  }
}

run "testnet_four_cores" {
  command = plan

  override_data {
    target = data.aws_ec2_instance_type.validator
    values = {
      default_cores           = 4
      memory_size             = 32768
      supported_architectures = ["x86_64"]
      ebs_nvme_support        = "required"
      nitro_tpm_support       = "unsupported"
    }
  }

  assert {
    condition     = aws_instance.validator.instance_type == "m7i.2xlarge"
    error_message = "Testnet takes 4 cores and no TPM."
  }
}

run "mainnet_image_without_tpm" {
  command = plan
  variables {
    network = "mainnet"
  }

  override_data {
    target = data.aws_ami.host
    values = {
      tpm_support = ""
    }
  }

  expect_failures = [aws_instance.validator]
}

run "mainnet_type_without_tpm" {
  command = plan
  variables {
    network = "mainnet"
  }

  override_data {
    target = data.aws_ec2_instance_type.validator
    values = {
      default_cores           = 8
      memory_size             = 65536
      supported_architectures = ["x86_64"]
      ebs_nvme_support        = "required"
      nitro_tpm_support       = "unsupported"
    }
  }

  expect_failures = [aws_instance.validator]
}

# allow_no_tpm is the other route: the host keeps the credential encrypted
# with its own key, and key generation is told so.
run "mainnet_without_tpm_allowed" {
  command = plan
  variables {
    network      = "mainnet"
    allow_no_tpm = true
  }

  override_data {
    target = data.aws_ami.host
    values = {
      tpm_support = ""
    }
  }

  assert {
    condition     = strcontains(output.next_steps, "--allow-no-tpm")
    error_message = "With allow_no_tpm key generation must get --allow-no-tpm."
  }
}

run "arm_type" {
  command = plan
  variables {
    validator_instance_type = "m7g.2xlarge"
  }

  override_data {
    target = data.aws_ec2_instance_type_offerings.zone
    values = {
      locations      = ["us-east-1a", "us-east-1a"]
      instance_types = ["m7g.2xlarge", "m7i.large"]
    }
  }

  override_data {
    target = data.aws_ec2_instance_type.validator
    values = {
      default_cores           = 8
      memory_size             = 32768
      supported_architectures = ["arm64"]
      ebs_nvme_support        = "required"
      nitro_tpm_support       = "supported"
    }
  }

  expect_failures = [aws_instance.validator]
}

run "type_without_nvme" {
  command = plan

  override_data {
    target = data.aws_ec2_instance_type.validator
    values = {
      default_cores           = 4
      memory_size             = 32768
      supported_architectures = ["x86_64"]
      ebs_nvme_support        = "unsupported"
      nitro_tpm_support       = "unsupported"
    }
  }

  expect_failures = [aws_instance.validator]
}

# The hubs file is the only part of the user data that grows with input.
run "user_data_over_the_limit" {
  command = plan

  override_module {
    target          = module.host_plan
    override_during = plan
    outputs = {
      validator_user_data            = "#cloud-config\n"
      gateway_user_data              = ""
      validator_env                  = ""
      gateway_env                    = ""
      validator_user_data_gzip_bytes = 16385
      gateway_user_data_gzip_bytes   = 0
      next_steps                     = ""
      tao_handoff                    = { record = "A", name = null, ipv4 = null, note = "" }
    }
  }

  expect_failures = [aws_instance.validator]
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
