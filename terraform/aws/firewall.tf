# Inbound is denied unless a rule below admits it: a security group holds
# allows only. Each host's rules are one map, so every port it opens is in
# one place.
locals {
  ssh_rules = { for c in var.admin_ssh_cidrs : "ssh ${c}" => {
    protocol = "tcp", port = 22, cidr = c, description = "SSH from an admin address"
  } }

  validator_ingress = merge(
    {
      # Peers are any address.
      p2p_primary = { protocol = "udp", port = 49590, cidr = "0.0.0.0/0", description = "Primary P2P (QUIC)" }
      p2p_worker  = { protocol = "udp", port = 49594, cidr = "0.0.0.0/0", description = "Worker P2P (QUIC)" }
    },
    # The RPC and the worker gateway's health port answer the gateway's fixed
    # address alone, never the rest of the VPC.
    var.gateway_enabled ? {
      rpc    = { protocol = "tcp", port = 8545, cidr = "${local.gateway_private_ip}/32", description = "RPC from the worker gateway" }
      health = { protocol = "tcp", port = 43174, cidr = "${local.gateway_private_ip}/32", description = "Health port from the worker gateway" }
    } : {},
    local.ssh_rules,
  )

  gateway_ingress = var.gateway_enabled ? merge(
    {
      http  = { protocol = "tcp", port = 80, cidr = "0.0.0.0/0", description = "ACME HTTP challenge and the redirect to https" }
      https = { protocol = "tcp", port = 443, cidr = "0.0.0.0/0", description = "Public RPC (https and wss)" }
    },
    local.ssh_rules,
  ) : {}
}

# Adopting the VPC's default group with no rules strips the allow-all AWS
# gives it, so an interface that lands in it by mistake admits nothing.
resource "aws_default_security_group" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.name_prefix}-default-closed"
  }
}

resource "aws_security_group" "validator" {
  name        = "${var.name_prefix}-validator"
  description = "Telcoin Network validator: P2P from anywhere, RPC from the worker gateway only"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.name_prefix}-validator"
  }
}

resource "aws_vpc_security_group_ingress_rule" "validator" {
  for_each = local.validator_ingress

  security_group_id = aws_security_group.validator.id
  description       = each.value.description
  ip_protocol       = each.value.protocol
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = each.value.cidr
}

# Out to anywhere: the node dials peers on any address, and Session Manager,
# the installer, updates and time sync go out from the host.
resource "aws_vpc_security_group_egress_rule" "validator" {
  security_group_id = aws_security_group.validator.id
  description       = "Peers, Session Manager, updates and time sync"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "gateway" {
  count = var.gateway_enabled ? 1 : 0

  name        = "${var.name_prefix}-gateway"
  description = "Telcoin Network worker gateway: https from anywhere"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.name_prefix}-gateway"
  }
}

resource "aws_vpc_security_group_ingress_rule" "gateway" {
  for_each = local.gateway_ingress

  security_group_id = aws_security_group.gateway[0].id
  description       = each.value.description
  ip_protocol       = each.value.protocol
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = each.value.cidr
}

# The gateway reaches the validator, the image registry, the ACME server and
# the public RPC it redirects queries to.
resource "aws_vpc_security_group_egress_rule" "gateway" {
  count = var.gateway_enabled ? 1 : 0

  security_group_id = aws_security_group.gateway[0].id
  description       = "The validator, the image registry, ACME, updates and time sync"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
