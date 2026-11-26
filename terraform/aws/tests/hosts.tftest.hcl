# The two applies: the first builds the network, both addresses and the
# validator; setting rpc_domain adds the gateway host and leaves the
# validator alone.

mock_provider "aws" {
  source          = "./tests/mocks"
  override_during = plan
}

variables {
  region            = "us-east-1"
  availability_zone = "us-east-1a"
  validator_address = "0x1111111111111111111111111111111111111111"
}

run "first_apply" {
  command = plan

  assert {
    condition     = length(aws_instance.gateway) == 0 && length(aws_eip_association.gateway) == 0 && !output.gateway_created
    error_message = "With rpc_domain empty there is no gateway instance and no association for its address."
  }

  assert {
    condition     = length(aws_eip.gateway) == 1 && output.validator_public_ip == "203.0.113.10" && output.gateway_public_ip == "203.0.113.20"
    error_message = "Both static public IPs must exist from the first apply."
  }

  assert {
    condition     = aws_network_interface.validator.private_ips == toset(["10.42.1.10"]) && aws_network_interface.gateway[0].private_ips == toset(["10.42.1.20"])
    error_message = "Both fixed private addresses must exist from the first apply: the validator at the subnet's 10th address, the gateway at its 20th."
  }

  assert {
    condition     = aws_eip_association.validator.network_interface_id == aws_network_interface.validator.id && aws_eip_association.validator.allocation_id == "eipalloc-0validator"
    error_message = "The validator's Elastic IP must be associated with its interface."
  }

  assert {
    condition     = aws_instance.validator.primary_network_interface[0].network_interface_id == aws_network_interface.validator.id
    error_message = "The validator must boot on its pre-created interface."
  }

  assert {
    condition     = aws_subnet.main.availability_zone == "us-east-1a" && aws_ebs_volume.data.availability_zone == "us-east-1a" && !aws_subnet.main.map_public_ip_on_launch
    error_message = "The subnet and the data volume must be in the given zone, and the subnet must give no public address."
  }

  assert {
    condition     = aws_instance.validator.instance_type == "m7i.2xlarge"
    error_message = "The testnet validator defaults to m7i.2xlarge."
  }

  assert {
    condition     = aws_instance.validator.user_data_base64 == base64gzip(module.host_plan.validator_user_data)
    error_message = "The validator must boot the host-plan cloud-config, gzipped."
  }

  assert {
    condition = alltrue([for want in [
      "TN_FB_ROLE='validator'\n",
      "TN_FB_CLOUD='aws'\n",
      "TN_FB_LOGIN_USER='ubuntu'\n",
      "TN_FB_DATA_DEVICE='/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol0123456789abcdef0'\n",
      "TN_FB_TRUSTED_NODES=''\n",
    ] : strcontains(module.host_plan.validator_env, want)])
    error_message = "The validator env must name AWS, ubuntu, the data volume's NVMe path, and no hubs file."
  }

  assert {
    condition     = output.session_command.validator == "aws ssm start-session --region us-east-1 --target i-0a1b2c3d4e5f60001" && output.session_command.gateway == null
    error_message = "The validator's session command must name its instance; the gateway has none before it exists."
  }

  assert {
    condition     = output.tao_handoff.ipv4 == "203.0.113.20" && output.tao_handoff.name == null
    error_message = "Before rpc_domain is set the handoff names the gateway's address and no name."
  }
}

run "second_apply" {
  command = plan

  variables {
    rpc_domain = "rpc.example.org"
  }

  assert {
    condition     = length(aws_instance.gateway) == 1 && length(aws_eip_association.gateway) == 1 && output.gateway_created
    error_message = "Setting rpc_domain must create the gateway instance and associate its address."
  }

  assert {
    condition     = output.validator_user_data_sha256 == run.first_apply.validator_user_data_sha256
    error_message = "The validator's user data must be the same with and without rpc_domain."
  }

  assert {
    condition     = aws_eip_association.gateway[0].network_interface_id == aws_network_interface.gateway[0].id && aws_eip_association.gateway[0].allocation_id == "eipalloc-0gateway"
    error_message = "The gateway's Elastic IP must be associated with its interface."
  }

  assert {
    condition     = aws_instance.gateway[0].primary_network_interface[0].network_interface_id == aws_network_interface.gateway[0].id && aws_instance.gateway[0].instance_type == "m7i.large"
    error_message = "The gateway must boot an m7i.large on its pre-created interface."
  }

  assert {
    condition     = aws_instance.gateway[0].user_data_base64 == base64gzip(module.host_plan.gateway_user_data) && aws_instance.gateway[0].user_data_replace_on_change
    error_message = "The gateway must boot the host-plan cloud-config, gzipped, and be replaced when it changes."
  }

  assert {
    condition = alltrue([for want in [
      "TN_FB_ROLE='gateway'\n",
      "TN_FB_UPSTREAM='10.42.1.10'\n",
      "TN_FB_DOMAIN='rpc.example.org'\n",
      "TN_FB_PUBLIC_IP='203.0.113.20'\n",
      "TN_FB_SSH_FROM='10.42.0.0/16'\n",
    ] : strcontains(module.host_plan.gateway_env, want)])
    error_message = "The gateway env must hold TN_FB_UPSTREAM='10.42.1.10', the domain and the gateway's own public address."
  }

  assert {
    condition     = output.session_command.gateway == "aws ssm start-session --region us-east-1 --target i-0a1b2c3d4e5f60002"
    error_message = "Once the gateway exists its session command names its instance."
  }

  assert {
    condition     = output.tao_handoff.name == "rpc.example.org" && output.tao_handoff.ipv4 == "203.0.113.20"
    error_message = "The handoff must name rpc_domain and the gateway's address."
  }
}

run "next_steps_testnet" {
  command = plan

  assert {
    condition = alltrue([for want in [
      "--phase=finalize",
      "--gateway-from 10.42.1.20",
      "--set gateway_upstream=10.42.1.20\n",
      "--admission closed --trusted-nodes /etc/telcoin-first-boot/trusted-nodes.yaml",
      "--external-primary /ip4/203.0.113.10/udp/49590/quic-v1",
      "--listener-primary /ip4/10.42.1.10/udp/49590/quic-v1",
      "open a shell: aws ssm start-session --region us-east-1 --target i-0a1b2c3d4e5f60001",
    ] : strcontains(output.next_steps, want)])
    error_message = "The testnet steps must hold finalize, --gateway-from 10.42.1.20, gateway_upstream=10.42.1.20, Closed admission and this deployment's addresses."
  }
}

run "next_steps_mainnet" {
  command = plan

  variables {
    network = "mainnet"
  }

  assert {
    condition     = !strcontains(split("==== At launch ====", output.next_steps)[0], "--phase=finalize") && strcontains(split("==== At launch ====", output.next_steps)[1], "--phase=finalize")
    error_message = "On mainnet finalize may appear only under the At launch heading."
  }

  assert {
    condition     = strcontains(output.next_steps, "--admission closed --trusted-nodes") && strcontains(output.next_steps, "--gateway-from 10.42.1.20")
    error_message = "The mainnet steps must hold Closed admission and the firewall with --gateway-from."
  }

  assert {
    condition     = aws_instance.validator.instance_type == "m7i.4xlarge"
    error_message = "The mainnet validator defaults to m7i.4xlarge."
  }
}

run "hubs_file" {
  command = plan

  variables {
    trusted_nodes_file = "tests/fixtures/trusted-nodes.yaml"
  }

  assert {
    condition     = strcontains(module.host_plan.validator_env, "TN_FB_TRUSTED_NODES='/etc/telcoin-first-boot/trusted-nodes.yaml'\n")
    error_message = "With trusted_nodes_file the validator env must name the hubs file."
  }

  assert {
    condition     = base64decode(yamldecode(module.host_plan.validator_user_data).write_files[3].content) == file("tests/fixtures/trusted-nodes.yaml")
    error_message = "The hubs file written at first boot must be trusted_nodes_file as given."
  }
}

run "single_node" {
  command = plan

  variables {
    gateway_enabled = false
  }

  assert {
    condition = alltrue([
      length(aws_instance.gateway) == 0, length(aws_eip.gateway) == 0, length(aws_eip_association.gateway) == 0,
      length(aws_network_interface.gateway) == 0, output.gateway_public_ip == null, output.gateway_private_ip == null,
    ])
    error_message = "gateway_enabled = false must build no gateway resource at all."
  }

  assert {
    condition     = !strcontains(output.next_steps, "--gateway-from") && !strcontains(output.next_steps, "gateway_upstream")
    error_message = "A single node's steps name no gateway."
  }
}

# The zone is the one given, never the first that offers every type: here
# us-east-1a, which sorts first, offers both types too.
run "zone_given_is_the_zone_used" {
  command = plan

  variables {
    availability_zone = "us-east-1c"
    rpc_domain        = "rpc.example.org"
  }

  override_data {
    target = data.aws_ec2_instance_type_offerings.zone
    values = {
      locations      = ["us-east-1a", "us-east-1a", "us-east-1c", "us-east-1c"]
      instance_types = ["m7i.2xlarge", "m7i.large", "m7i.2xlarge", "m7i.large"]
    }
  }

  assert {
    condition     = aws_subnet.main.availability_zone == "us-east-1c" && aws_ebs_volume.data.availability_zone == "us-east-1c"
    error_message = "The subnet and the data volume must be in the given zone."
  }

  # An instance runs in the zone of its interface's subnet.
  assert {
    condition = alltrue([
      aws_network_interface.validator.subnet_id == aws_subnet.main.id,
      aws_network_interface.gateway[0].subnet_id == aws_subnet.main.id,
      aws_instance.validator.primary_network_interface[0].network_interface_id == aws_network_interface.validator.id,
      aws_instance.gateway[0].primary_network_interface[0].network_interface_id == aws_network_interface.gateway[0].id,
    ])
    error_message = "Both hosts must boot on interfaces in the subnet of the given zone."
  }
}
