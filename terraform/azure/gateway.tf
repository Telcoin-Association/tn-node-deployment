# The address the RPC name's A record points at. It exists from the first
# apply so the record can be published before the gateway VM is built.
resource "azurerm_public_ip" "gateway" {
  count = var.gateway_enabled ? 1 : 0

  name                = "${local.vm_name.gateway}-ip"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "Standard"
  allocation_method   = "Static"
  zones               = [var.zone]
  tags                = local.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_network_interface" "gateway" {
  count = var.gateway_enabled ? 1 : 0

  name                           = "${local.vm_name.gateway}-nic"
  resource_group_name            = azurerm_resource_group.this.name
  location                       = azurerm_resource_group.this.location
  accelerated_networking_enabled = true
  ip_forwarding_enabled          = false
  tags                           = local.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.hosts.id
    private_ip_address_allocation = "Static"
    private_ip_address            = local.gateway_ip
    public_ip_address_id          = azurerm_public_ip.gateway[0].id
  }
}

# Disposable: it keeps no state the validator needs. A change to its user data
# or image replaces it, since Azure cannot change either in place.
resource "azurerm_linux_virtual_machine" "gateway" {
  count = local.gateway_vm ? 1 : 0

  name                            = local.vm_name.gateway
  resource_group_name             = azurerm_resource_group.this.name
  location                        = azurerm_resource_group.this.location
  zone                            = var.zone
  size                            = local.gateway_size
  network_interface_ids           = [azurerm_network_interface.gateway[0].id]
  admin_username                  = var.admin_username
  disable_password_authentication = true
  custom_data                     = base64gzip(module.host_plan.gateway_user_data)
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
    name                 = "${local.vm_name.gateway}-os"
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

  boot_diagnostics {}

  # Caddy asks for its certificate as soon as the gateway boots: 80 and 443
  # must already be open.
  depends_on = [azurerm_network_security_rule.inbound, azurerm_subnet_network_security_group_association.hosts]

  lifecycle {
    precondition {
      condition     = module.host_plan.gateway_user_data_gzip_bytes <= local.custom_data_max_bytes
      error_message = "The gateway's user data is ${module.host_plan.gateway_user_data_gzip_bytes} bytes gzipped, over the ${local.custom_data_max_bytes} bytes Azure takes as custom data."
    }
  }
}
