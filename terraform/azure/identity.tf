# Admin access. Both hosts take the operator's SSH public key for the admin
# user and refuse passwords; neither carries a managed identity, and VM
# extensions (which run commands as root) are turned off. The way in is SSH
# from admin_ssh_cidrs, Azure Bastion, or both.
#
# Bastion needs the Standard SKU for native-client tunnelling, which
# az network bastion ssh uses. It reaches the hosts' private addresses on TCP
# 22 from AzureBastionSubnet.

resource "azurerm_public_ip" "bastion" {
  count = var.enable_bastion ? 1 : 0

  name                = "${var.name_prefix}-bastion-ip"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "Standard"
  allocation_method   = "Static"
  tags                = local.tags
}

resource "azurerm_bastion_host" "this" {
  count = var.enable_bastion ? 1 : 0

  name                = "${var.name_prefix}-bastion"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "Standard"
  tunneling_enabled   = true
  tags                = local.tags

  ip_configuration {
    name                 = "primary"
    subnet_id            = azurerm_subnet.bastion[0].id
    public_ip_address_id = azurerm_public_ip.bastion[0].id
  }
}
