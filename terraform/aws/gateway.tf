# The worker gateway holds nothing that cannot be rebuilt: a change to its
# first-boot input replaces it, and first boot installs it again unattended.
resource "aws_instance" "gateway" {
  count = local.gateway_vm ? 1 : 0

  ami                         = local.ami_id
  instance_type               = local.gateway_type
  iam_instance_profile        = aws_iam_instance_profile.host.name
  ebs_optimized               = true
  user_data_base64            = base64gzip(module.host_plan.gateway_user_data)
  user_data_replace_on_change = true

  primary_network_interface {
    network_interface_id = aws_network_interface.gateway[0].id
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # The OS, Docker and the gateway image.
  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    kms_key_id            = var.kms_key_id
    delete_on_termination = true

    tags = {
      Name = "${var.name_prefix}-gateway-root"
    }
  }

  tags = {
    Name = "${var.name_prefix}-gateway"
  }

  depends_on = [aws_eip_association.gateway, aws_route.internet, aws_route_table_association.main]

  # Canonical publishes a new image every few weeks. Following it would
  # replace the gateway, and issue it a new certificate, on any later apply;
  # take one on purpose with terraform apply -replace=aws_instance.gateway[0].
  lifecycle {
    ignore_changes = [ami]

    precondition {
      condition     = module.host_plan.gateway_user_data_gzip_bytes <= 16384
      error_message = "The worker gateway's user data is ${module.host_plan.gateway_user_data_gzip_bytes} bytes gzipped, over the 16384 bytes EC2 takes."
    }
  }
}

# Caddy gets the gateway's certificate only once the name resolves to the
# gateway's address. This warns, never fails: a lookup that errors is a
# warning too. A nested data block takes no count, so before rpc_domain is set
# it looks up localhost, which the machine answers itself.
check "rpc_domain_points_at_gateway" {
  data "dns_a_record_set" "rpc" {
    host = var.rpc_domain != "" ? var.rpc_domain : "localhost"
  }

  assert {
    condition     = !local.gateway_vm || contains(data.dns_a_record_set.rpc.addrs, aws_eip.gateway[0].public_ip)
    error_message = "${var.rpc_domain} does not resolve to the gateway's address ${try(aws_eip.gateway[0].public_ip, "")} yet. The gateway's first boot waits up to 30 minutes for it and then installs anyway, and Caddy keeps retrying the certificate; point the A record at that address (tao_handoff) first."
  }
}
