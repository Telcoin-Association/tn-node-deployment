locals {
  ami_id = var.ami_id != "" ? var.ami_id : data.aws_ssm_parameter.ubuntu[0].insecure_value
  # Null lets EBS use the account's AWS managed key.
  kms_key_id = var.disk_kms_key != "" ? var.disk_kms_key : null

  disk = {
    size       = coalesce(var.data_disk_size_gb, local.disk_default[var.network].size)
    iops       = coalesce(var.data_disk_iops, local.disk_default[var.network].iops)
    throughput = coalesce(var.data_disk_throughput, local.disk_default[var.network].throughput)
  }

  # On a Nitro instance an EBS volume is an NVMe device whose serial is the
  # volume ID without its dash, and udev names the device after it.
  data_device = "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${replace(aws_ebs_volume.data.id, "-", "")}"

  trusted_nodes_content = var.trusted_nodes_file != "" ? file(var.trusted_nodes_file) : ""

  validator_hw = data.aws_ec2_instance_type.validator
  # NitroTPM needs both an image registered for it and a type that has it.
  tpm_ready = data.aws_ami.host.tpm_support == "v2.0" && local.validator_hw.nitro_tpm_support == "supported"

  ssm_session = "aws ssm start-session --region ${var.region} --target"
  session_commands = {
    validator = "${local.ssm_session} ${aws_instance.validator.id}"
    gateway   = local.gateway_vm ? "${local.ssm_session} ${aws_instance.gateway[0].id}" : ""
  }
}

# Canonical's public parameter always names the current image of a release.
data "aws_ssm_parameter" "ubuntu" {
  count = var.ami_id == "" ? 1 : 0

  name = "/aws/service/canonical/ubuntu/server/${var.ubuntu_version}/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

data "aws_ami" "host" {
  # An image pinned through ami_id may be deprecated by now and still boot.
  include_deprecated = true

  filter {
    name   = "image-id"
    values = [local.ami_id]
  }
}

data "aws_ec2_instance_type" "validator" {
  instance_type = local.validator_type
}

# What both hosts boot from: the env files, the first-boot scripts and the
# commands the operator runs next.
module "host_plan" {
  source = "../modules/host-plan"

  role_set                       = { validator = true, gateway = var.gateway_enabled }
  network                        = var.network
  cloud                          = "aws"
  login_user                     = "ubuntu"
  validator_public_ip            = aws_eip.validator.public_ip
  validator_private_ip           = local.validator_private_ip
  gateway_public_ip              = var.gateway_enabled ? aws_eip.gateway[0].public_ip : ""
  gateway_private_ip             = var.gateway_enabled ? local.gateway_private_ip : ""
  vpc_cidr                       = var.vpc_cidr
  admin_ssh_cidrs                = var.admin_ssh_cidrs
  rpc_domain                     = var.rpc_domain
  data_device                    = local.data_device
  trusted_nodes_content          = local.trusted_nodes_content
  redirect_queries_url           = var.redirect_queries_url
  gateway_rate_limit_submissions = var.gateway_rate_limit_submissions
  validator_address              = var.validator_address
  allow_no_tpm                   = var.allow_no_tpm
  session_commands               = local.session_commands
  node_release_tag               = var.node_release_tag
}

# The node's keys and chain data. Kept whatever happens to the instance, and
# never snapshotted: a snapshot of this volume is a copy of the node keys.
resource "aws_ebs_volume" "data" {
  availability_zone = var.availability_zone
  type              = "gp3"
  size              = local.disk.size
  iops              = local.disk.iops
  throughput        = local.disk.throughput
  encrypted         = true
  kms_key_id        = local.kms_key_id

  tags = {
    Name = "${var.name_prefix}-data"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_instance" "validator" {
  ami                  = local.ami_id
  instance_type        = local.validator_type
  iam_instance_profile = aws_iam_instance_profile.host.name
  ebs_optimized        = true
  user_data_base64     = base64gzip(module.host_plan.validator_user_data)

  primary_network_interface {
    network_interface_id = aws_network_interface.validator.id
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # The OS, the node binary and the stored passphrase credential; the chain
  # data lives on the data volume.
  root_block_device {
    volume_type           = "gp3"
    volume_size           = 50
    encrypted             = true
    kms_key_id            = local.kms_key_id
    delete_on_termination = true

    tags = {
      Name = "${var.name_prefix}-validator-root"
    }
  }

  tags = {
    Name = "${var.name_prefix}-validator"
  }

  depends_on = [aws_eip_association.validator, aws_route.internet, aws_route_table_association.main]

  # The root volume holds the passphrase credential, which a new instance
  # would not have: a newer image or changed first-boot input never replaces
  # this host.
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [ami, user_data_base64]

    precondition {
      condition     = module.host_plan.validator_user_data_gzip_bytes <= 16384
      error_message = "The validator's user data is ${module.host_plan.validator_user_data_gzip_bytes} bytes gzipped, over the 16384 bytes EC2 takes: the hubs file is too large for instance user data. Leave trusted_nodes_file empty and copy the file to the host by hand; next_steps names the path."
    }

    precondition {
      condition     = contains(local.validator_hw.supported_architectures, "x86_64") && local.validator_hw.ebs_nvme_support == "required"
      error_message = "validator_instance_type ${local.validator_type} must be an x86_64 Nitro type, whose EBS volumes are NVMe devices: the image is amd64, and first boot finds the data volume by its NVMe name."
    }

    precondition {
      condition     = var.network != "mainnet" || (local.validator_hw.default_cores >= 8 && local.validator_hw.memory_size >= 32768)
      error_message = "On mainnet the validator needs at least 8 physical cores and 32 GiB of memory, the node scripts' validator floor. ${local.validator_type} has ${local.validator_hw.default_cores} cores and ${floor(local.validator_hw.memory_size / 1024)} GiB; leave validator_instance_type null for m7i.4xlarge (8 cores, 64 GiB), or name a larger type."
    }

    precondition {
      condition     = var.network != "mainnet" || local.tpm_ready || var.allow_no_tpm
      error_message = "On mainnet key generation seals the BLS passphrase credential to a TPM2, and this host would have none: image ${local.ami_id} reports tpm_support \"${data.aws_ami.host.tpm_support}\" and ${local.validator_type} NitroTPM \"${local.validator_hw.nitro_tpm_support}\". Set ami_id to a copy of the Ubuntu image registered with --boot-mode uefi --tpm-support v2.0, or set allow_no_tpm = true to keep the credential encrypted with the host key alone."
    }
  }
}

# Attached once the instance runs; first boot waits for the device. Stopping
# the instance first keeps a detach from pulling the volume out from under a
# running node.
resource "aws_volume_attachment" "data" {
  device_name                    = "/dev/sdf"
  volume_id                      = aws_ebs_volume.data.id
  instance_id                    = aws_instance.validator.id
  stop_instance_before_detaching = true
}
