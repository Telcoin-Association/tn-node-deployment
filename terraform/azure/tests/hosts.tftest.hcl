# The two hosts, their addresses, disks and boot settings, and the two-apply
# gating on rpc_domain.

mock_provider "azurerm" {
  override_during = plan
}

override_resource {
  target          = azurerm_public_ip.validator
  override_during = plan
  values          = { ip_address = "203.0.113.10" }
}

override_resource {
  target          = azurerm_public_ip.gateway
  override_during = plan
  values          = { ip_address = "203.0.113.20" }
}

override_resource {
  target          = azurerm_resource_group.this
  override_during = plan
  values          = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/telcoin-rg" }
}

# Known IDs, so the provider can check the data disk attachment at plan time.
override_resource {
  target          = azurerm_managed_disk.data
  override_during = plan
  values          = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/telcoin-rg/providers/Microsoft.Compute/disks/telcoin-validator-data" }
}

override_resource {
  target          = azurerm_linux_virtual_machine.validator
  override_during = plan
  values          = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/telcoin-rg/providers/Microsoft.Compute/virtualMachines/telcoin-validator" }
}

variables {
  admin_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBERERERERERERERERERERERERERERERERERERERERER operator@example"
  admin_ssh_cidrs      = ["198.51.100.7/32"]
}

# First apply: no rpc_domain yet.
run "first_apply" {
  command = plan

  assert {
    condition     = length(azurerm_linux_virtual_machine.gateway) == 0 && !output.gateway_created && output.session_command.gateway == null
    error_message = "The gateway VM, and a command to reach it, must not exist while rpc_domain is empty."
  }

  assert {
    condition = (
      azurerm_public_ip.validator.sku == "Standard" && azurerm_public_ip.validator.allocation_method == "Static" &&
      azurerm_public_ip.validator.zones == toset(["1"]) &&
      length(azurerm_public_ip.gateway) == 1 &&
      azurerm_public_ip.gateway[0].sku == "Standard" && azurerm_public_ip.gateway[0].allocation_method == "Static" &&
      azurerm_public_ip.gateway[0].zones == toset(["1"])
    )
    error_message = "Both static public IPs (Standard, Static, zonal) must exist from the first apply."
  }

  assert {
    condition = (
      length(azurerm_network_interface.gateway) == 1 &&
      azurerm_network_interface.gateway[0].ip_configuration[0].private_ip_address_allocation == "Static" &&
      azurerm_network_interface.gateway[0].ip_configuration[0].private_ip_address == "10.42.1.20" &&
      azurerm_network_interface.gateway[0].ip_configuration[0].public_ip_address_id == azurerm_public_ip.gateway[0].id &&
      azurerm_network_interface.validator.ip_configuration[0].private_ip_address_allocation == "Static" &&
      azurerm_network_interface.validator.ip_configuration[0].private_ip_address == "10.42.1.10" &&
      azurerm_network_interface.validator.ip_configuration[0].public_ip_address_id == azurerm_public_ip.validator.id
    )
    error_message = "Both NICs hold their fixed private address and static public IP from the first apply."
  }

  assert {
    condition = (
      output.validator_public_ip == "203.0.113.10" && output.validator_private_ip == "10.42.1.10" &&
      output.gateway_public_ip == "203.0.113.20" && output.gateway_private_ip == "10.42.1.20"
    )
    error_message = "The address outputs are wrong."
  }

  assert {
    condition     = output.tao_handoff.ipv4 == "203.0.113.20" && output.tao_handoff.name == null && output.tao_handoff.record == "A"
    error_message = "Before rpc_domain is set the handoff names the gateway's address and no name."
  }
}

# Second apply: rpc_domain set. The validator's user data must not change.
run "second_apply" {
  command = plan

  variables {
    rpc_domain = "rpc.example.org"
  }

  assert {
    condition     = length(azurerm_linux_virtual_machine.gateway) == 1 && output.gateway_created
    error_message = "The gateway VM must exist once rpc_domain is set."
  }

  assert {
    condition     = output.validator_user_data_sha256 == run.first_apply.validator_user_data_sha256
    error_message = "The validator's user data must be the same with and without rpc_domain."
  }

  assert {
    condition     = azurerm_linux_virtual_machine.validator.custom_data == base64gzip(module.host_plan.validator_user_data) && output.validator_user_data_sha256 == sha256(module.host_plan.validator_user_data)
    error_message = "The validator boots from the host plan's user data, gzipped."
  }

  assert {
    condition     = azurerm_linux_virtual_machine.gateway[0].custom_data == base64gzip(module.host_plan.gateway_user_data)
    error_message = "The gateway boots from the host plan's user data, gzipped."
  }

  assert {
    condition = alltrue([for want in [
      "TN_FB_ROLE='gateway'\n",
      "TN_FB_CLOUD='azure'\n",
      "TN_FB_LOGIN_USER='ubuntu'\n",
      "TN_FB_UPSTREAM='10.42.1.10'\n",
      "TN_FB_DOMAIN='rpc.example.org'\n",
      "TN_FB_PUBLIC_IP='203.0.113.20'\n",
      "TN_FB_SSH_FROM='198.51.100.7/32,10.42.0.0/16'\n",
    ] : strcontains(module.host_plan.gateway_env, want)])
    error_message = "The gateway env must point the gateway at the validator's private address, 10.42.1.10."
  }

  assert {
    condition     = strcontains(module.host_plan.validator_env, "TN_FB_DATA_DEVICE='/dev/disk/azure/scsi1/lun0'\n") && strcontains(module.host_plan.validator_env, "TN_FB_LOGIN_USER='ubuntu'\n")
    error_message = "The validator's data device is LUN 0 of the SCSI data controller and its login user the admin user."
  }

  assert {
    condition     = output.tao_handoff.name == "rpc.example.org" && output.tao_handoff.ipv4 == "203.0.113.20"
    error_message = "The handoff names rpc_domain at the gateway's address."
  }
}

run "trusted_launch_and_login" {
  command = plan

  variables {
    rpc_domain = "rpc.example.org"
  }

  assert {
    condition = alltrue([for vm in concat([azurerm_linux_virtual_machine.validator], azurerm_linux_virtual_machine.gateway) :
      vm.secure_boot_enabled && vm.vtpm_enabled &&
      vm.disable_password_authentication &&
      vm.admin_username == "ubuntu" &&
      length(vm.admin_ssh_key) == 1 &&
      one(vm.admin_ssh_key).username == "ubuntu" &&
      one(vm.admin_ssh_key).public_key == var.admin_ssh_public_key &&
      !vm.allow_extension_operations &&
      vm.zone == "1" &&
      vm.source_image_reference[0].publisher == "Canonical" &&
      vm.source_image_reference[0].offer == "ubuntu-26_04-lts" &&
      vm.source_image_reference[0].sku == "server" &&
      length(vm.identity) == 0
    ])
    error_message = "Both VMs boot Ubuntu 26.04 Gen2 with Secure Boot and vTPM, take the operator's SSH key for the admin user only, refuse passwords and extensions, and carry no managed identity."
  }

  assert {
    condition     = azurerm_linux_virtual_machine.validator.size == "Standard_D8s_v5" && azurerm_linux_virtual_machine.gateway[0].size == "Standard_D2s_v5"
    error_message = "The testnet defaults are Standard_D8s_v5 (4 cores, 32 GiB) and Standard_D2s_v5 for the gateway."
  }

  assert {
    condition = alltrue([for nic in concat([azurerm_network_interface.validator], azurerm_network_interface.gateway) :
    nic.accelerated_networking_enabled && !nic.ip_forwarding_enabled])
    error_message = "The Dsv5 sizes require accelerated networking; neither NIC forwards."
  }
}

run "data_disk_testnet" {
  command = plan

  assert {
    condition = (
      azurerm_managed_disk.data.storage_account_type == "PremiumV2_LRS" &&
      azurerm_managed_disk.data.create_option == "Empty" &&
      azurerm_managed_disk.data.zone == "1" &&
      azurerm_managed_disk.data.disk_size_gb >= 350 &&
      azurerm_managed_disk.data.disk_size_gb == 500 &&
      azurerm_managed_disk.data.disk_iops_read_write == 15000 &&
      azurerm_managed_disk.data.disk_mbps_read_write == 300
    )
    error_message = "The testnet data disk is a zonal Premium SSD v2 of 500 GiB at 15000 IOPS and 300 MB/s, over the 350 GB floor."
  }

  # Managed disks are always encrypted at rest with platform keys; these close
  # the routes that export the disk's content through a SAS URL.
  assert {
    condition     = azurerm_managed_disk.data.network_access_policy == "DenyAll" && !azurerm_managed_disk.data.public_network_access_enabled
    error_message = "The data disk must refuse export and import over the network."
  }

  assert {
    condition = (
      azurerm_virtual_machine_data_disk_attachment.data.lun == 0 &&
      azurerm_virtual_machine_data_disk_attachment.data.caching == "None" &&
      azurerm_virtual_machine_data_disk_attachment.data.managed_disk_id == azurerm_managed_disk.data.id &&
      azurerm_virtual_machine_data_disk_attachment.data.virtual_machine_id == azurerm_linux_virtual_machine.validator.id
    )
    error_message = "The data disk attaches to the validator at LUN 0 with no host caching (Premium SSD v2 has none)."
  }

  assert {
    condition     = !azurerm_linux_virtual_machine.validator.encryption_at_host_enabled
    error_message = "Encryption at host is off unless asked for: it needs a subscription feature."
  }
}

run "data_disk_mainnet" {
  command = plan

  variables {
    network                    = "mainnet"
    encryption_at_host_enabled = true
    ubuntu_version             = "24.04"
  }

  assert {
    condition = (
      azurerm_managed_disk.data.disk_size_gb >= 2000 &&
      azurerm_managed_disk.data.disk_iops_read_write == 20000 &&
      azurerm_managed_disk.data.disk_mbps_read_write == 300
    )
    error_message = "The mainnet data disk is at least 2000 GiB at 20000 IOPS and 300 MB/s."
  }

  assert {
    condition     = azurerm_linux_virtual_machine.validator.size == "Standard_D16s_v5"
    error_message = "The mainnet default is Standard_D16s_v5 (8 cores, 64 GiB)."
  }

  assert {
    condition     = azurerm_linux_virtual_machine.validator.encryption_at_host_enabled
    error_message = "encryption_at_host_enabled must reach the validator."
  }

  assert {
    condition     = azurerm_linux_virtual_machine.validator.source_image_reference[0].offer == "ubuntu-24_04-lts" && azurerm_linux_virtual_machine.validator.source_image_reference[0].sku == "server"
    error_message = "ubuntu_version 24.04 selects Canonical's ubuntu-24_04-lts Gen2 image."
  }
}

run "hubs_file" {
  command = plan

  variables {
    trusted_nodes_file = "tests/trusted-nodes.yaml"
  }

  assert {
    condition     = strcontains(module.host_plan.validator_env, "TN_FB_TRUSTED_NODES='/etc/telcoin-first-boot/trusted-nodes.yaml'\n") && contains([for f in yamldecode(module.host_plan.validator_user_data).write_files : f.path], "/etc/telcoin-first-boot/trusted-nodes.yaml")
    error_message = "A hubs file reaches the validator through its user data."
  }

  assert {
    condition     = module.host_plan.validator_user_data_gzip_bytes <= 65535
    error_message = "The validator's custom data must fit Azure's 65535 bytes."
  }
}

run "single_node_without_gateway" {
  command = plan

  variables {
    gateway_enabled = false
  }

  assert {
    condition = (
      length(azurerm_linux_virtual_machine.gateway) == 0 &&
      length(azurerm_network_interface.gateway) == 0 &&
      length(azurerm_public_ip.gateway) == 0 &&
      output.gateway_public_ip == null && output.gateway_private_ip == null && !output.gateway_created
    )
    error_message = "gateway_enabled = false builds no gateway resources."
  }
}

run "session_commands" {
  command = plan

  variables {
    rpc_domain = "rpc.example.org"
  }

  assert {
    condition = (
      output.session_command.validator == "ssh ubuntu@203.0.113.10" &&
      output.session_command.gateway == "ssh ubuntu@203.0.113.20"
    )
    error_message = "Without Bastion the operator connects with plain ssh to the static public IPs."
  }

  assert {
    condition     = strcontains(output.next_steps, "ssh ubuntu@203.0.113.10")
    error_message = "next_steps must say how to open a shell on the validator."
  }
}

run "session_commands_bastion" {
  command = plan

  variables {
    admin_ssh_cidrs = []
    enable_bastion  = true
    rpc_domain      = "rpc.example.org"
  }

  assert {
    condition = (
      output.session_command.validator == "az network bastion ssh --name telcoin-bastion --resource-group telcoin-rg --target-resource-id /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/telcoin-rg/providers/Microsoft.Compute/virtualMachines/telcoin-validator --auth-type ssh-key --username ubuntu --ssh-key <private key of admin_ssh_public_key>" &&
      output.session_command.gateway == "az network bastion ssh --name telcoin-bastion --resource-group telcoin-rg --target-resource-id /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/telcoin-rg/providers/Microsoft.Compute/virtualMachines/telcoin-gateway --auth-type ssh-key --username ubuntu --ssh-key <private key of admin_ssh_public_key>"
    )
    error_message = "With Bastion the operator connects through az network bastion ssh to each VM's resource ID, naming the private key by a placeholder."
  }
}

# The private key's path cannot be read from the public key: the command
# names a placeholder rather than a guess.
run "session_commands_bastion_rsa_key" {
  command = plan

  variables {
    admin_ssh_cidrs      = []
    enable_bastion       = true
    admin_ssh_public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCjNhN+2MKoPwNBnm/mt7I+q6Z1jLbVyGkaavGIrSFn6d5Jv/hcY7xD5dN7qSlVpFEeeJp02UXyKN1O/fKF7I0ypWAr/uzRP3HnaD5O0OIBf0GfviXaVDqO0of2bcE9Vo5e26W6/PQNyZO/ZfUHFFefSXEp2Ezvj2ZviM3ux53X3WUNPK6OW0aeZbSTzbEstKOv4RAdQV1iTDM7/S55ltW25/Kwt50x7NTV6acchoMqmRIhPu26bXR3PI9oM0otTFNOFOysrmX1m+KiLpwSZOc1YtFhUO5meK5QSfirB1ia0vIWeFDQk/8utSZM8u93XVO9vXHnCsS4ks6wlAM70nhF operator@example"
  }

  assert {
    condition     = endswith(output.session_command.validator, " --ssh-key <private key of admin_ssh_public_key>") && !strcontains(output.next_steps, "~/.ssh/")
    error_message = "The Bastion command must name the private key by a placeholder, never a guessed path."
  }
}

run "next_steps_testnet" {
  command = plan

  variables {
    rpc_domain = "rpc.example.org"
  }

  assert {
    condition = alltrue([for want in [
      "--phase=finalize",
      "firewall-setup.sh --enable --gateway-from 10.42.1.20 --ssh-from 198.51.100.7/32,10.42.0.0/16\n",
      "--set gateway_upstream=10.42.1.20\n",
      "--admission closed",
      "/home/ubuntu/telcoin-node-scripts/",
    ] : strcontains(output.next_steps, want)])
    error_message = "The testnet steps must hold finalize, --gateway-from 10.42.1.20, gateway_upstream=10.42.1.20 and --admission closed."
  }
}

run "next_steps_mainnet" {
  command = plan

  variables {
    network    = "mainnet"
    rpc_domain = "rpc.example.org"
  }

  assert {
    condition     = strcontains(output.next_steps, "--admission closed") && length(split("==== At launch ====", output.next_steps)) == 2
    error_message = "The mainnet steps take --admission closed and have one At launch block."
  }

  assert {
    condition     = !strcontains(split("==== At launch ====", output.next_steps)[0], "--phase=finalize") && strcontains(split("==== At launch ====", output.next_steps)[1], "--phase=finalize")
    error_message = "On mainnet finalize comes only under the At launch block."
  }
}
