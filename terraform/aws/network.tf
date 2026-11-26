locals {
  # Fixed private addresses, so the security group rules, the env files and
  # the printed commands can name them before either host exists.
  validator_private_ip = cidrhost(var.subnet_cidr, 10)
  gateway_private_ip   = cidrhost(var.subnet_cidr, 20)

  # The gateway host exists only once its name is chosen; its addresses exist
  # from the first apply.
  gateway_vm = var.gateway_enabled && var.rpc_domain != ""

  validator_type = coalesce(var.validator_instance_type, var.network == "mainnet" ? "m7i.4xlarge" : "m7i.2xlarge")
  gateway_type   = coalesce(var.gateway_instance_type, "m7i.large")
  instance_types = distinct(concat([local.validator_type], var.gateway_enabled ? [local.gateway_type] : []))

  # Zone => the wanted types it offers. The given zone must offer all of them,
  # so the gateway's second apply cannot fail on a type the zone lacks. Only
  # the precondition reads this: the zone itself is never worked out here.
  zone_offers     = { for i, z in data.aws_ec2_instance_type_offerings.zone.locations : z => data.aws_ec2_instance_type_offerings.zone.instance_types[i]... }
  zone_candidates = sort([for z, types in local.zone_offers : z if length(setsubtract(local.instance_types, types)) == 0])
}

data "aws_ec2_instance_type_offerings" "zone" {
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = local.instance_types
  }
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = var.name_prefix
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = var.name_prefix
  }
}

# One public subnet: both hosts take their public address from an Elastic IP,
# never from the subnet.
resource "aws_subnet" "main" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.name_prefix}-public"
  }

  lifecycle {
    precondition {
      condition     = contains(local.zone_candidates, var.availability_zone)
      error_message = "${var.availability_zone} does not offer every instance type in use (${join(", ", local.instance_types)}). Zones of ${var.region} that do: ${length(local.zone_candidates) > 0 ? join(", ", local.zone_candidates) : "none"}. Set availability_zone to one of them, or pick another instance type."
    }
  }
}

resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.name_prefix}-public"
  }
}

resource "aws_route" "internet" {
  route_table_id         = aws_route_table.main.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "main" {
  subnet_id      = aws_subnet.main.id
  route_table_id = aws_route_table.main.id
}

resource "aws_network_interface" "validator" {
  description     = "${var.name_prefix} validator"
  subnet_id       = aws_subnet.main.id
  private_ips     = [local.validator_private_ip]
  security_groups = [aws_security_group.validator.id]

  tags = {
    Name = "${var.name_prefix}-validator"
  }
}

# The gateway's interface outlives its instance, so the address the validator
# admits never moves.
resource "aws_network_interface" "gateway" {
  count = var.gateway_enabled ? 1 : 0

  description     = "${var.name_prefix} worker gateway"
  subnet_id       = aws_subnet.main.id
  private_ips     = [local.gateway_private_ip]
  security_groups = [aws_security_group.gateway[0].id]

  tags = {
    Name = "${var.name_prefix}-gateway"
  }
}

# Peers dial the validator's address and the RPC name points at the
# gateway's, so neither may change.
resource "aws_eip" "validator" {
  domain = "vpc"

  tags = {
    Name = "${var.name_prefix}-validator"
  }

  depends_on = [aws_internet_gateway.main]

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_eip" "gateway" {
  count = var.gateway_enabled ? 1 : 0

  domain = "vpc"

  tags = {
    Name = "${var.name_prefix}-gateway"
  }

  depends_on = [aws_internet_gateway.main]

  lifecycle {
    prevent_destroy = true
  }
}

# Associated with the interface before the instance boots, so first boot
# already has its public address.
resource "aws_eip_association" "validator" {
  allocation_id        = aws_eip.validator.allocation_id
  network_interface_id = aws_network_interface.validator.id
}

resource "aws_eip_association" "gateway" {
  count = local.gateway_vm ? 1 : 0

  allocation_id        = aws_eip.gateway[0].allocation_id
  network_interface_id = aws_network_interface.gateway[0].id
}
