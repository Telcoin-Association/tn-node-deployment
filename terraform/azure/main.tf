locals {
  tags = {
    deployment = var.name_prefix
    network    = var.network
  }

  validator_ip = cidrhost(var.subnet_cidr, 10)
  gateway_ip   = cidrhost(var.subnet_cidr, 20)
  host_ips     = var.gateway_enabled ? [local.validator_ip, local.gateway_ip] : [local.validator_ip]

  # The gateway VM waits for its name; its address, NIC and firewall rules do
  # not, so the A record can be published before it boots.
  gateway_vm = var.gateway_enabled && var.rpc_domain != ""

  vm_name = {
    validator = "${var.name_prefix}-validator"
    gateway   = "${var.name_prefix}-gateway"
  }

  # Dsv5 runs two vCPUs on each physical core: Standard_D8s_v5 is 4 cores and
  # 32 GiB, Standard_D16s_v5 8 cores and 64 GiB. The mainnet size has twice
  # the memory floor, for the reason validator_instance_type gives.
  validator_size = coalesce(var.validator_instance_type, var.network == "mainnet" ? "Standard_D16s_v5" : "Standard_D8s_v5")
  gateway_size   = coalesce(var.gateway_instance_type, "Standard_D2s_v5")

  # Standard_D8s_v5 sustains 12800 uncached IOPS and 290 MB/s, a little under
  # the testnet disk's 15000 and 300; it bursts to 20000 for up to 30 minutes.
  disk = {
    size = coalesce(var.data_disk_size_gb, local.disk_default[var.network].size)
    iops = coalesce(var.data_disk_iops, local.disk_default[var.network].iops)
    mbps = coalesce(var.data_disk_throughput, local.disk_default[var.network].throughput)
  }

  # Canonical's Gen2 x64 images, which Trusted Launch needs.
  image = {
    publisher = "Canonical"
    offer     = "ubuntu-${replace(var.ubuntu_version, ".", "_")}-lts"
    sku       = "server"
    version   = "latest"
  }

  # LUN 0 of the SCSI data controller, linked by the udev rules the Ubuntu
  # image's walinuxagent package installs. The v5 sizes the variables allow
  # attach data disks over SCSI only.
  data_device = "/dev/disk/azure/scsi1/lun0"

  # Azure decodes custom data to at most 65535 bytes.
  custom_data_max_bytes = 65535

  vm_id = { for role, name in local.vm_name : role => "${azurerm_resource_group.this.id}/providers/Microsoft.Compute/virtualMachines/${name}" }
  bastion_ssh = { for role in ["validator", "gateway"] : role => join(" ", [
    "az network bastion ssh --name ${var.name_prefix}-bastion --resource-group ${azurerm_resource_group.this.name}",
    "--target-resource-id ${local.vm_id[role]} --auth-type ssh-key --username ${var.admin_username} --ssh-key <private key of admin_ssh_public_key>",
  ]) }
  session_commands = {
    validator = var.enable_bastion ? local.bastion_ssh.validator : "ssh ${var.admin_username}@${azurerm_public_ip.validator.ip_address}"
    gateway = !local.gateway_vm ? "" : (
      var.enable_bastion ? local.bastion_ssh.gateway : "ssh ${var.admin_username}@${azurerm_public_ip.gateway[0].ip_address}"
    )
  }
}

module "host_plan" {
  source = "../modules/host-plan"

  role_set                       = { validator = true, gateway = var.gateway_enabled }
  network                        = var.network
  cloud                          = "azure"
  login_user                     = var.admin_username
  validator_public_ip            = azurerm_public_ip.validator.ip_address
  validator_private_ip           = local.validator_ip
  gateway_public_ip              = var.gateway_enabled ? azurerm_public_ip.gateway[0].ip_address : ""
  gateway_private_ip             = var.gateway_enabled ? local.gateway_ip : ""
  vpc_cidr                       = var.vpc_cidr
  admin_ssh_cidrs                = var.admin_ssh_cidrs
  rpc_domain                     = var.rpc_domain
  data_device                    = local.data_device
  trusted_nodes_content          = var.trusted_nodes_file != "" ? file(var.trusted_nodes_file) : ""
  redirect_queries_url           = var.redirect_queries_url
  gateway_rate_limit_submissions = var.gateway_rate_limit_submissions
  validator_address              = var.validator_address
  session_commands               = local.session_commands
  node_release_tag               = var.node_release_tag
  min_scripts_release            = var.min_scripts_release
}
