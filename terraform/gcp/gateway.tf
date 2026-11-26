# The worker gateway is disposable: first boot builds all of it, so a new
# configuration means a new VM. Compute Engine would update the user-data key
# in place and cloud-init would never read it again, hence the replacement.
# The image is part of the trigger by family only, so a newer Ubuntu image in
# the same family does not take the RPC endpoint down on an unrelated apply.
resource "terraform_data" "gateway_cfg" {
  count = local.gateway_vm ? 1 : 0

  input = {
    user_data    = module.host_plan.gateway_user_data
    image_family = local.image_family
  }
}

resource "google_compute_instance" "gateway" {
  count = local.gateway_vm ? 1 : 0

  name         = local.name.gateway
  zone         = local.zone
  machine_type = local.gateway_type
  tags         = [local.tag.gateway]

  allow_stopping_for_update = true

  boot_disk {
    kms_key_self_link = local.kms_key

    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = local.boot_disk_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.main.id
    network_ip = google_compute_address.gateway_internal[0].address
    nic_type   = "GVNIC"
    stack_type = "IPV4_ONLY"

    access_config {
      nat_ip       = google_compute_address.gateway_public[0].address
      network_tier = "PREMIUM"
    }
  }

  metadata = {
    "enable-oslogin"         = "TRUE"
    "block-project-ssh-keys" = "TRUE"
    "user-data"              = module.host_plan.gateway_user_data
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
    ignore_changes       = [boot_disk[0].initialize_params[0].image]
    replace_triggered_by = [terraform_data.gateway_cfg[count.index]]

    precondition {
      condition     = length(module.host_plan.gateway_user_data) <= local.metadata_value_limit
      error_message = "The worker gateway's user data is ${length(module.host_plan.gateway_user_data)} bytes, over the ${local.metadata_value_limit} bytes one instance metadata value holds."
    }
  }
}
