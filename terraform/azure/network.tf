resource "azurerm_resource_group" "this" {
  name     = "${var.name_prefix}-rg"
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "this" {
  name                = "${var.name_prefix}-vnet"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  address_space       = [var.vpc_cidr]
  tags                = local.tags
}

# Both hosts reach the internet through their own static public IPs, so the
# subnet needs no default outbound access.
resource "azurerm_subnet" "hosts" {
  name                            = "${var.name_prefix}-hosts"
  resource_group_name             = azurerm_resource_group.this.name
  virtual_network_name            = azurerm_virtual_network.this.name
  address_prefixes                = [var.subnet_cidr]
  default_outbound_access_enabled = false
}

# Azure Bastion needs a subnet of its own with exactly this name, /26 or
# larger.
resource "azurerm_subnet" "bastion" {
  count = var.enable_bastion ? 1 : 0

  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.bastion_subnet_cidr]
}
