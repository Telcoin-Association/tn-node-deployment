# One security group guards the hosts' subnet; each allow rule names the host
# it admits traffic to. Azure's default AllowVnetInBound (priority 65000) would
# let every address in the virtual network reach every port, the validator's
# RPC (8545) and health port (43174) among them, so deny-vnet turns the
# network away at the last custom priority, after the allows. Traffic from
# the internet that no rule allows falls to DenyAllInBound (65500).
locals {
  nsg_rules = merge(
    {
      validator-p2p = {
        priority     = 100
        protocol     = "Udp"
        ports        = ["49590", "49594"]
        access       = "Allow"
        sources      = ["*"]
        destinations = [local.validator_ip]
      }
    },
    var.gateway_enabled ? {
      validator-rpc-from-gateway = {
        priority     = 110
        protocol     = "Tcp"
        ports        = ["8545", "43174"]
        access       = "Allow"
        sources      = ["${local.gateway_ip}/32"]
        destinations = [local.validator_ip]
      }
      gateway-web = {
        priority     = 120
        protocol     = "Tcp"
        ports        = ["80", "443"]
        access       = "Allow"
        sources      = ["*"]
        destinations = [local.gateway_ip]
      }
    } : {},
    length(var.admin_ssh_cidrs) > 0 ? {
      ssh-admin = {
        priority     = 200
        protocol     = "Tcp"
        ports        = ["22"]
        access       = "Allow"
        sources      = var.admin_ssh_cidrs
        destinations = local.host_ips
      }
    } : {},
    var.enable_bastion ? {
      ssh-bastion = {
        priority     = 210
        protocol     = "Tcp"
        ports        = ["22"]
        access       = "Allow"
        sources      = [var.bastion_subnet_cidr]
        destinations = local.host_ips
      }
    } : {},
    {
      deny-vnet = {
        priority     = 4096
        protocol     = "*"
        ports        = ["*"]
        access       = "Deny"
        sources      = ["VirtualNetwork"]
        destinations = ["*"]
      }
    },
  )
}

resource "azurerm_network_security_group" "hosts" {
  name                = "${var.name_prefix}-hosts-nsg"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags
}

# A single port, address or service tag goes in the singular argument (the
# plural ones take no tags), a list in the plural one.
resource "azurerm_network_security_rule" "inbound" {
  for_each = local.nsg_rules

  name                        = each.key
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.hosts.name
  direction                   = "Inbound"
  access                      = each.value.access
  priority                    = each.value.priority
  protocol                    = each.value.protocol
  source_port_range           = "*"

  destination_port_range       = length(each.value.ports) == 1 ? each.value.ports[0] : null
  destination_port_ranges      = length(each.value.ports) > 1 ? each.value.ports : null
  source_address_prefix        = length(each.value.sources) == 1 ? each.value.sources[0] : null
  source_address_prefixes      = length(each.value.sources) > 1 ? each.value.sources : null
  destination_address_prefix   = length(each.value.destinations) == 1 ? each.value.destinations[0] : null
  destination_address_prefixes = length(each.value.destinations) > 1 ? each.value.destinations : null
}

resource "azurerm_subnet_network_security_group_association" "hosts" {
  subnet_id                 = azurerm_subnet.hosts.id
  network_security_group_id = azurerm_network_security_group.hosts.id
}
