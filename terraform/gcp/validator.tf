# What both hosts boot from and what the operator runs next. The module creates
# nothing; it renders text from the addresses reserved in network.tf.
module "host_plan" {
  source = "../modules/host-plan"

  role_set                       = { validator = true, gateway = var.gateway_enabled }
  network                        = var.network
  cloud                          = "gcp"
  login_user                     = local.login_user
  validator_public_ip            = google_compute_address.validator_public.address
  validator_private_ip           = google_compute_address.validator_internal.address
  gateway_public_ip              = var.gateway_enabled ? google_compute_address.gateway_public[0].address : ""
  gateway_private_ip             = var.gateway_enabled ? google_compute_address.gateway_internal[0].address : ""
  vpc_cidr                       = var.vpc_cidr
  admin_ssh_cidrs                = var.admin_ssh_cidrs
  rpc_domain                     = var.rpc_domain
  data_device                    = local.data_device
  trusted_nodes_content          = local.trusted_nodes_content
  redirect_queries_url           = var.redirect_queries_url
  gateway_rate_limit_submissions = var.gateway_rate_limit_submissions
  validator_address              = var.validator_address
  session_commands               = local.session_commands
  node_release_tag               = var.node_release_tag
  min_scripts_release            = var.min_scripts_release
}

data "google_compute_image" "ubuntu" {
  project = "ubuntu-os-cloud"
  family  = local.image_family
}

# Read so a mainnet validator is refused at plan on a type below the node
# scripts' minimum, and a type the zone does not offer is named before apply.
data "google_compute_machine_types" "validator" {
  zone   = local.zone
  filter = "name = \"${local.validator_type}\""
}

# Compute Engine encrypts every disk; disk_kms_key swaps Google's key for the
# operator's Cloud KMS key, here and on both boot disks.
resource "google_compute_disk" "data" {
  name                   = "${var.name_prefix}-validator-data"
  zone                   = local.zone
  type                   = "hyperdisk-balanced"
  size                   = local.data_disk.size
  provisioned_iops       = local.data_disk.iops
  provisioned_throughput = local.data_disk.throughput

  dynamic "disk_encryption_key" {
    for_each = local.kms_key != null ? [local.kms_key] : []
    content {
      kms_key_self_link = disk_encryption_key.value
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_compute_instance" "validator" {
  name         = local.name.validator
  zone         = local.zone
  machine_type = local.validator_type
  tags         = [local.tag.validator]

  # The root disk holds the stored passphrase credential, so the VM is never
  # replaced or deleted in passing: a new image or new user data is ignored
  # (first boot ran once and does not run again), and a change that needs the
  # VM stopped fails instead of stopping the validator.
  deletion_protection       = true
  allow_stopping_for_update = false

  boot_disk {
    kms_key_self_link = local.kms_key

    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = local.boot_disk_gb
      type  = "hyperdisk-balanced"
    }
  }

  # device_name gives the disk the stable path /dev/disk/by-id/google-tn-data
  # on NVMe machine series as well as SCSI.
  attached_disk {
    source      = google_compute_disk.data.id
    device_name = local.data_device_name
  }

  network_interface {
    subnetwork = google_compute_subnetwork.main.id
    network_ip = google_compute_address.validator_internal.address
    nic_type   = "GVNIC"
    stack_type = "IPV4_ONLY"

    access_config {
      nat_ip       = google_compute_address.validator_public.address
      network_tier = "PREMIUM"
    }
  }

  # Keys go through OS Login and IAM, never through project-wide SSH keys.
  metadata = {
    "enable-oslogin"         = "TRUE"
    "block-project-ssh-keys" = "TRUE"
    "user-data"              = module.host_plan.validator_user_data
  }

  service_account {
    email  = google_service_account.host.email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      metadata["user-data"],
      boot_disk[0].initialize_params[0].image,
    ]

    precondition {
      condition     = length(module.host_plan.validator_user_data) <= local.metadata_value_limit
      error_message = "The validator's user data is ${length(module.host_plan.validator_user_data)} bytes, over the ${local.metadata_value_limit} bytes one instance metadata value holds: the hubs file is too large for instance metadata. Leave trusted_nodes_file empty and copy the file to the host by hand."
    }

    precondition {
      condition     = length(data.google_compute_machine_types.validator.machine_types) == 1
      error_message = "Machine type ${local.validator_type} is not offered in zone ${local.zone}. Set validator_instance_type to a type the zone offers, or pick another zone."
    }

    # Compute Engine x86 types run two threads per core, so a core is two
    # vCPUs; the floor is the node scripts' mainnet validator minimum.
    precondition {
      condition     = var.network != "mainnet" || try(data.google_compute_machine_types.validator.machine_types[0].guest_cpus >= 16 && data.google_compute_machine_types.validator.machine_types[0].memory_mb >= 32768, false)
      error_message = "On mainnet the validator needs at least 8 physical cores and 32 GiB of memory, the node scripts' validator floor; Compute Engine counts 16 vCPUs for 8 cores. ${local.validator_type} has ${try(data.google_compute_machine_types.validator.machine_types[0].guest_cpus, 0)} vCPUs and ${floor(try(data.google_compute_machine_types.validator.machine_types[0].memory_mb, 0) / 1024)} GiB; leave validator_instance_type null for c3d-standard-16 (8 cores, 64 GiB), or name a larger type."
    }
  }
}
