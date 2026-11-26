# The subnet's security group. A rule with one port, source or destination
# names it in the singular argument and a list in the plural one, so the
# checks that look at every rule read both.

mock_provider "azurerm" {
  override_during = plan
}

override_resource {
  target          = azurerm_public_ip.validator
  override_during = plan
  values          = { ip_address = "203.0.113.10", id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/tn-rg/providers/Microsoft.Network/publicIPAddresses/tn-validator-ip" }
}

override_resource {
  target          = azurerm_public_ip.gateway
  override_during = plan
  values          = { ip_address = "203.0.113.20", id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/tn-rg/providers/Microsoft.Network/publicIPAddresses/tn-gateway-ip" }
}

override_resource {
  target          = azurerm_subnet.hosts
  override_during = plan
  values          = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/tn-rg/providers/Microsoft.Network/virtualNetworks/tn-vnet/subnets/tn-hosts" }
}

override_resource {
  target          = azurerm_network_security_group.hosts
  override_during = plan
  values          = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/tn-rg/providers/Microsoft.Network/networkSecurityGroups/tn-hosts-nsg" }
}

variables {
  admin_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBERERERERERERERERERERERERERERERERERERERERER operator@example"
  admin_ssh_cidrs      = ["198.51.100.7/32"]
  rpc_domain           = "rpc.example.org"
}

run "rpc_and_health_only_from_the_gateway" {
  command = plan

  assert {
    condition = (
      azurerm_network_security_rule.inbound["validator-rpc-from-gateway"].access == "Allow" &&
      azurerm_network_security_rule.inbound["validator-rpc-from-gateway"].protocol == "Tcp" &&
      azurerm_network_security_rule.inbound["validator-rpc-from-gateway"].source_address_prefix == "10.42.1.20/32" &&
      azurerm_network_security_rule.inbound["validator-rpc-from-gateway"].destination_address_prefix == "10.42.1.10" &&
      toset(azurerm_network_security_rule.inbound["validator-rpc-from-gateway"].destination_port_ranges) == toset(["8545", "43174"])
    )
    error_message = "TCP 8545 and 43174 on the validator must be allowed from the gateway's private address, 10.42.1.20/32, only."
  }

  assert {
    condition = alltrue([for k, r in azurerm_network_security_rule.inbound :
      r.access != "Allow" || k == "validator-rpc-from-gateway" || length(setintersection(
        r.destination_port_range == null ? [] : [r.destination_port_range],
        ["8545", "43174", "*"],
        )) + length(setintersection(
        r.destination_port_ranges == null ? [] : r.destination_port_ranges,
        ["8545", "43174", "*"],
      )) == 0
    ])
    error_message = "No other allow rule may admit TCP 8545, 43174 or every port."
  }

  # AllowVnetInBound (65000) would admit the whole network to every port, so
  # an explicit deny from VirtualNetwork must come after the allows and before
  # it.
  assert {
    condition = (
      azurerm_network_security_rule.inbound["deny-vnet"].access == "Deny" &&
      azurerm_network_security_rule.inbound["deny-vnet"].direction == "Inbound" &&
      azurerm_network_security_rule.inbound["deny-vnet"].protocol == "*" &&
      azurerm_network_security_rule.inbound["deny-vnet"].source_address_prefix == "VirtualNetwork" &&
      azurerm_network_security_rule.inbound["deny-vnet"].destination_port_range == "*" &&
      azurerm_network_security_rule.inbound["deny-vnet"].destination_address_prefix == "*" &&
      azurerm_network_security_rule.inbound["deny-vnet"].priority < 65000 &&
      alltrue([for r in azurerm_network_security_rule.inbound : r.access == "Deny" || r.priority < azurerm_network_security_rule.inbound["deny-vnet"].priority])
    )
    error_message = "The deny rule from VirtualNetwork must cover every port and protocol, after every allow and before AllowVnetInBound at 65000."
  }

  assert {
    condition     = length([for r in azurerm_network_security_rule.inbound : r if r.access == "Deny"]) == 1
    error_message = "deny-vnet must be the only deny rule."
  }

  assert {
    condition     = alltrue([for r in azurerm_network_security_rule.inbound : r.direction == "Inbound" && r.network_security_group_name == azurerm_network_security_group.hosts.name])
    error_message = "Every rule must be an inbound rule of the hosts' security group."
  }

  assert {
    condition     = azurerm_subnet_network_security_group_association.hosts.subnet_id == azurerm_subnet.hosts.id && azurerm_subnet_network_security_group_association.hosts.network_security_group_id == azurerm_network_security_group.hosts.id
    error_message = "The hosts' security group must guard the hosts' subnet."
  }
}

run "p2p_and_web_from_anywhere" {
  command = plan

  assert {
    condition = (
      azurerm_network_security_rule.inbound["validator-p2p"].access == "Allow" &&
      azurerm_network_security_rule.inbound["validator-p2p"].protocol == "Udp" &&
      azurerm_network_security_rule.inbound["validator-p2p"].source_address_prefix == "*" &&
      azurerm_network_security_rule.inbound["validator-p2p"].destination_address_prefix == "10.42.1.10" &&
      toset(azurerm_network_security_rule.inbound["validator-p2p"].destination_port_ranges) == toset(["49590", "49594"])
    )
    error_message = "UDP 49590 and 49594 on the validator must be open to anywhere."
  }

  assert {
    condition = (
      azurerm_network_security_rule.inbound["gateway-web"].access == "Allow" &&
      azurerm_network_security_rule.inbound["gateway-web"].protocol == "Tcp" &&
      azurerm_network_security_rule.inbound["gateway-web"].source_address_prefix == "*" &&
      azurerm_network_security_rule.inbound["gateway-web"].destination_address_prefix == "10.42.1.20" &&
      toset(azurerm_network_security_rule.inbound["gateway-web"].destination_port_ranges) == toset(["80", "443"])
    )
    error_message = "TCP 80 and 443 on the gateway must be open to anywhere."
  }

  assert {
    condition     = toset(keys(azurerm_network_security_rule.inbound)) == toset(["validator-p2p", "validator-rpc-from-gateway", "gateway-web", "ssh-admin", "deny-vnet"])
    error_message = "With a gateway and one admin CIDR the group holds exactly the P2P, RPC, web, SSH and deny rules."
  }
}

run "ssh_exactly_the_admin_cidrs" {
  command = plan

  variables {
    admin_ssh_cidrs = ["198.51.100.7/32", "192.0.2.0/28"]
  }

  assert {
    condition = (
      azurerm_network_security_rule.inbound["ssh-admin"].access == "Allow" &&
      azurerm_network_security_rule.inbound["ssh-admin"].protocol == "Tcp" &&
      azurerm_network_security_rule.inbound["ssh-admin"].destination_port_range == "22" &&
      toset(azurerm_network_security_rule.inbound["ssh-admin"].source_address_prefixes) == toset(["198.51.100.7/32", "192.0.2.0/28"]) &&
      toset(azurerm_network_security_rule.inbound["ssh-admin"].destination_address_prefixes) == toset(["10.42.1.10", "10.42.1.20"])
    )
    error_message = "TCP 22 on both hosts must be open to exactly the admin CIDRs."
  }

  assert {
    condition = alltrue([for k, r in azurerm_network_security_rule.inbound :
      r.access != "Allow" || k == "ssh-admin" || length(setintersection(
        r.destination_port_range == null ? [] : [r.destination_port_range],
        ["22", "*"],
        )) + length(setintersection(
        r.destination_port_ranges == null ? [] : r.destination_port_ranges,
        ["22", "*"],
      )) == 0
    ])
    error_message = "No other allow rule may admit TCP 22 while Bastion is off."
  }

  assert {
    condition     = length(azurerm_bastion_host.this) == 0 && length(azurerm_subnet.bastion) == 0 && length(azurerm_public_ip.bastion) == 0
    error_message = "Bastion is opt-in: nothing of it exists unless enable_bastion is true."
  }
}

run "ssh_only_from_bastion_without_admin_cidrs" {
  command = plan

  variables {
    admin_ssh_cidrs = []
    enable_bastion  = true
  }

  assert {
    condition     = !contains(keys(azurerm_network_security_rule.inbound), "ssh-admin")
    error_message = "With no admin CIDRs there is no SSH rule from outside the network."
  }

  assert {
    condition = (
      azurerm_network_security_rule.inbound["ssh-bastion"].access == "Allow" &&
      azurerm_network_security_rule.inbound["ssh-bastion"].protocol == "Tcp" &&
      azurerm_network_security_rule.inbound["ssh-bastion"].destination_port_range == "22" &&
      azurerm_network_security_rule.inbound["ssh-bastion"].source_address_prefix == "10.42.2.0/26" &&
      toset(azurerm_network_security_rule.inbound["ssh-bastion"].destination_address_prefixes) == toset(["10.42.1.10", "10.42.1.20"])
    )
    error_message = "TCP 22 on both hosts must be open to the Bastion subnet only."
  }

  assert {
    condition = alltrue([for k, r in azurerm_network_security_rule.inbound :
      r.access != "Allow" || k == "ssh-bastion" || length(setintersection(
        r.destination_port_range == null ? [] : [r.destination_port_range],
        ["22", "*"],
        )) + length(setintersection(
        r.destination_port_ranges == null ? [] : r.destination_port_ranges,
        ["22", "*"],
      )) == 0
    ])
    error_message = "Only the Bastion rule may admit TCP 22."
  }

  assert {
    condition = (
      length(azurerm_bastion_host.this) == 1 &&
      azurerm_bastion_host.this[0].sku == "Standard" &&
      azurerm_bastion_host.this[0].tunneling_enabled &&
      azurerm_subnet.bastion[0].name == "AzureBastionSubnet" &&
      azurerm_subnet.bastion[0].address_prefixes == tolist(["10.42.2.0/26"]) &&
      azurerm_public_ip.bastion[0].sku == "Standard" &&
      azurerm_public_ip.bastion[0].allocation_method == "Static"
    )
    error_message = "Bastion needs the Standard SKU with tunneling for az network bastion ssh, in AzureBastionSubnet, with a Standard static address."
  }
}

run "no_gateway_rules_without_a_gateway" {
  command = plan

  variables {
    gateway_enabled = false
  }

  assert {
    condition     = toset(keys(azurerm_network_security_rule.inbound)) == toset(["validator-p2p", "ssh-admin", "deny-vnet"])
    error_message = "Without a gateway nothing reaches 8545 or 43174 and there is no web rule."
  }

  assert {
    condition     = azurerm_network_security_rule.inbound["ssh-admin"].destination_address_prefix == "10.42.1.10"
    error_message = "Without a gateway SSH reaches the validator only."
  }
}
