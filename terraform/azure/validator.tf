resource "azurerm_public_ip" "validator" {
  name                = "${local.vm_name.validator}-ip"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "Standard"
  allocation_method   = "Static"
  zones               = [var.zone]
  tags                = local.tags

  # Peers and the committee know the validator by this address.
  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_network_interface" "validator" {
  name                           = "${local.vm_name.validator}-nic"
  resource_group_name            = azurerm_resource_group.this.name
  location                       = azurerm_resource_group.this.location
  accelerated_networking_enabled = true
  ip_forwarding_enabled          = false
  tags                           = local.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.hosts.id
    private_ip_address_allocation = "Static"
    private_ip_address            = local.validator_ip
    public_ip_address_id          = azurerm_public_ip.validator.id
  }
}

# The node's database. Premium SSD v2 is zonal, has no host caching and is
# offered in some regions only.
resource "azurerm_managed_disk" "data" {
  name                          = "${local.vm_name.validator}-data"
  resource_group_name           = azurerm_resource_group.this.name
  location                      = azurerm_resource_group.this.location
  zone                          = var.zone
  storage_account_type          = "PremiumV2_LRS"
  create_option                 = "Empty"
  disk_size_gb                  = local.disk.size
  disk_iops_read_write          = local.disk.iops
  disk_mbps_read_write          = local.disk.mbps
  network_access_policy         = "DenyAll"
  public_network_access_enabled = false
  tags                          = local.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_linux_virtual_machine" "validator" {
  name                            = local.vm_name.validator
  resource_group_name             = azurerm_resource_group.this.name
  location                        = azurerm_resource_group.this.location
  zone                            = var.zone
  size                            = local.validator_size
  network_interface_ids           = [azurerm_network_interface.validator.id]
  admin_username                  = var.admin_username
  disable_password_authentication = true
  custom_data                     = base64gzip(module.plan.validator_user_data)
  secure_boot_enabled             = true
  vtpm_enabled                    = true
  encryption_at_host_enabled      = var.encryption_at_host_enabled
  allow_extension_operations      = false
  tags                            = local.tags

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.admin_ssh_public_key
  }

  os_disk {
    name                 = "${local.vm_name.validator}-os"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 64
  }

  source_image_reference {
    publisher = local.image.publisher
    offer     = local.image.offer
    sku       = local.image.sku
    version   = local.image.version
  }

  # Managed storage: the serial log carries the first-boot result line.
  boot_diagnostics {}

  # The firewall is in place before the host first boots.
  depends_on = [azurerm_network_security_rule.inbound, azurerm_subnet_network_security_group_association.hosts]

  lifecycle {
    # The root disk holds the stored passphrase credential: replacing the VM
    # loses it. A new image or new custom data, which Azure cannot change in
    # place, is therefore never applied to the validator.
    prevent_destroy = true
    ignore_changes  = [custom_data, source_image_reference]

    precondition {
      condition     = module.plan.validator_user_data_gzip_bytes <= local.custom_data_max_bytes
      error_message = "The validator's user data is ${module.plan.validator_user_data_gzip_bytes} bytes gzipped, over the ${local.custom_data_max_bytes} bytes Azure takes as custom data: the hubs file is too large for it. Leave trusted_nodes_file empty and copy the file to the host by hand, at the path next_steps names."
    }
  }
}

resource "azurerm_virtual_machine_data_disk_attachment" "data" {
  managed_disk_id    = azurerm_managed_disk.data.id
  virtual_machine_id = azurerm_linux_virtual_machine.validator.id
  lun                = 0
  caching            = "None"
}
