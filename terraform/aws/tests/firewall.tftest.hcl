# What each host admits. A security group denies whatever no rule allows, so
# each run checks the whole set of rules, not just that the wanted ones exist.

mock_provider "aws" {
  source          = "./tests/mocks"
  override_during = plan
}

variables {
  region            = "us-east-1"
  availability_zone = "us-east-1a"
}

run "first_apply" {
  command = plan

  assert {
    condition = toset([for r in aws_vpc_security_group_ingress_rule.validator : "${r.ip_protocol} ${r.from_port}-${r.to_port} ${r.cidr_ipv4}"]) == toset([
      "udp 49590-49590 0.0.0.0/0",
      "udp 49594-49594 0.0.0.0/0",
      "tcp 8545-8545 10.42.1.20/32",
      "tcp 43174-43174 10.42.1.20/32",
    ])
    error_message = "The validator must admit UDP 49590 and 49594 from anywhere and TCP 8545 and 43174 from the gateway's private address only, and nothing else."
  }

  assert {
    condition = alltrue([for r in concat(values(aws_vpc_security_group_ingress_rule.validator), values(aws_vpc_security_group_ingress_rule.gateway)) :
    r.cidr_ipv6 == null && r.prefix_list_id == null && r.referenced_security_group_id == null])
    error_message = "Every rule's source must be its IPv4 CIDR alone: no IPv6, prefix list or referenced group may widen it."
  }

  assert {
    condition     = length([for r in aws_vpc_security_group_ingress_rule.validator : r if contains([8545, 43174], r.from_port) || contains([8545, 43174], r.to_port)]) == 2
    error_message = "Exactly one rule each may open 8545 and 43174."
  }

  assert {
    condition = toset([for r in aws_vpc_security_group_ingress_rule.gateway : "${r.ip_protocol} ${r.from_port}-${r.to_port} ${r.cidr_ipv4}"]) == toset([
      "tcp 80-80 0.0.0.0/0",
      "tcp 443-443 0.0.0.0/0",
    ])
    error_message = "The gateway must admit TCP 80 and 443 from anywhere, and nothing else."
  }

  assert {
    condition     = length([for r in concat(values(aws_vpc_security_group_ingress_rule.validator), values(aws_vpc_security_group_ingress_rule.gateway)) : r if r.from_port == 22]) == 0
    error_message = "With no admin_ssh_cidrs no host may admit TCP 22."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.validator.ip_protocol == "-1" && aws_vpc_security_group_egress_rule.validator.cidr_ipv4 == "0.0.0.0/0" && length(aws_vpc_security_group_egress_rule.gateway) == 1
    error_message = "Both hosts must reach anywhere outbound."
  }

  assert {
    condition     = aws_network_interface.validator.security_groups == toset([aws_security_group.validator.id]) && aws_network_interface.gateway[0].security_groups == toset([aws_security_group.gateway[0].id])
    error_message = "Each interface must sit in its own host's group and no other."
  }
}

# The second apply creates the gateway host and changes no rule.
run "second_apply" {
  command = plan

  variables {
    rpc_domain = "rpc.example.org"
  }

  assert {
    condition = toset([for r in aws_vpc_security_group_ingress_rule.validator : "${r.ip_protocol} ${r.from_port}-${r.to_port} ${r.cidr_ipv4}"]) == toset([
      "udp 49590-49590 0.0.0.0/0",
      "udp 49594-49594 0.0.0.0/0",
      "tcp 8545-8545 10.42.1.20/32",
      "tcp 43174-43174 10.42.1.20/32",
    ])
    error_message = "Setting rpc_domain must not change the validator's rules."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.gateway) == 2
    error_message = "Setting rpc_domain must not change the gateway's rules."
  }
}

run "admin_ssh" {
  command = plan

  variables {
    admin_ssh_cidrs = ["198.51.100.7/32", "192.0.2.0/24"]
  }

  assert {
    condition     = toset([for r in aws_vpc_security_group_ingress_rule.validator : r.cidr_ipv4 if r.from_port == 22]) == toset(["198.51.100.7/32", "192.0.2.0/24"])
    error_message = "The validator must admit TCP 22 from exactly the admin_ssh_cidrs."
  }

  assert {
    condition     = toset([for r in aws_vpc_security_group_ingress_rule.gateway : r.cidr_ipv4 if r.from_port == 22]) == toset(["198.51.100.7/32", "192.0.2.0/24"])
    error_message = "The gateway must admit TCP 22 from exactly the admin_ssh_cidrs."
  }

  assert {
    condition     = alltrue([for r in concat(values(aws_vpc_security_group_ingress_rule.validator), values(aws_vpc_security_group_ingress_rule.gateway)) : r.ip_protocol == "tcp" && r.to_port == 22 if r.from_port == 22])
    error_message = "An SSH rule must open TCP 22 alone."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.validator) == 6 && length(aws_vpc_security_group_ingress_rule.gateway) == 4
    error_message = "admin_ssh_cidrs may add the SSH rules and nothing else."
  }
}

# A single node: no gateway, so nothing admits the RPC or health port at all.
run "no_gateway" {
  command = plan

  variables {
    gateway_enabled = false
  }

  assert {
    condition = toset([for r in aws_vpc_security_group_ingress_rule.validator : "${r.ip_protocol} ${r.from_port}-${r.to_port} ${r.cidr_ipv4}"]) == toset([
      "udp 49590-49590 0.0.0.0/0",
      "udp 49594-49594 0.0.0.0/0",
    ])
    error_message = "Without a gateway the validator must admit its P2P ports and nothing else."
  }

  assert {
    condition     = length(aws_security_group.gateway) == 0 && length(aws_vpc_security_group_ingress_rule.gateway) == 0 && length(aws_vpc_security_group_egress_rule.gateway) == 0
    error_message = "Without a gateway there is no gateway group and no gateway rule."
  }
}
