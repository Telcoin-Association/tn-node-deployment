# The hosts themselves: machine types, the data disk and its floors, Shielded
# VM, OS Login, the service account and the admin grants.

mock_provider "google" {
  override_during = plan

  override_data {
    target = data.google_compute_image.ubuntu
    values = { self_link = "https://www.googleapis.com/compute/v1/projects/ubuntu-os-cloud/global/images/ubuntu-2604-lts-amd64-v20261101" }
  }

  override_data {
    target = data.google_compute_machine_types.validator
    values = { machine_types = [{ name = "c3-standard-8", guest_cpus = 8, memory_mb = 32768 }] }
  }

  override_resource {
    target = google_compute_address.validator_public
    values = { address = "203.0.113.10" }
  }

  override_resource {
    target = google_compute_address.gateway_public
    values = { address = "203.0.113.20" }
  }

  override_resource {
    target = google_service_account.host
    values = {
      email = "telcoin-host@tn-test-project.iam.gserviceaccount.com"
      name  = "projects/tn-test-project/serviceAccounts/telcoin-host@tn-test-project.iam.gserviceaccount.com"
    }
  }
}

variables {
  project    = "tn-test-project"
  rpc_domain = "rpc.example.org"
}

run "testnet_hosts" {
  command = plan

  assert {
    condition     = google_compute_instance.validator.machine_type == "c3-standard-8" && google_compute_instance.gateway[0].machine_type == "e2-standard-2"
    error_message = "Testnet defaults: c3-standard-8 (4 cores, 32 GB) for the validator, e2-standard-2 for the gateway."
  }

  assert {
    condition = (
      google_compute_disk.data.type == "hyperdisk-balanced" &&
      google_compute_disk.data.size == 500 &&
      google_compute_disk.data.provisioned_iops == 15000 &&
      google_compute_disk.data.provisioned_throughput == 300 &&
      google_compute_disk.data.zone == "us-central1-a"
    )
    error_message = "The testnet data disk is Hyperdisk Balanced at the defaults: 500 GiB, 15000 IOPS, 300 MiB/s, in the hosts' zone."
  }

  # Compute Engine encrypts every disk; what the module controls is that no
  # customer-supplied key (which would sit in state) is ever configured.
  assert {
    condition     = length(google_compute_disk.data.disk_encryption_key) == 0
    error_message = "Without disk_kms_key the data disk uses Google's key, and never a raw or RSA-wrapped key."
  }

  assert {
    condition = (
      one(google_compute_instance.validator.attached_disk).device_name == "tn-data" &&
      strcontains(module.host_plan.validator_env, "TN_FB_DATA_DEVICE='/dev/disk/by-id/google-tn-data'\n")
    )
    error_message = "The data disk is attached as tn-data and first boot looks for /dev/disk/by-id/google-tn-data."
  }

  assert {
    condition = alltrue([for i in [google_compute_instance.validator, google_compute_instance.gateway[0]] :
      i.shielded_instance_config[0].enable_secure_boot && i.shielded_instance_config[0].enable_vtpm && i.shielded_instance_config[0].enable_integrity_monitoring
    ])
    error_message = "Both hosts run as Shielded VMs: Secure Boot, vTPM and integrity monitoring on."
  }

  assert {
    condition = alltrue([for i in [google_compute_instance.validator, google_compute_instance.gateway[0]] :
      i.metadata["enable-oslogin"] == "TRUE" && i.metadata["block-project-ssh-keys"] == "TRUE" &&
      length(setsubtract(keys(i.metadata), ["user-data", "enable-oslogin", "block-project-ssh-keys"])) == 0
    ])
    error_message = "Both hosts use OS Login, block project SSH keys and carry no other metadata (no ssh-keys, no serial port access)."
  }

  assert {
    condition = alltrue([for i in [google_compute_instance.validator, google_compute_instance.gateway[0]] :
      i.service_account[0].email == "telcoin-host@tn-test-project.iam.gserviceaccount.com" && i.can_ip_forward != true
    ])
    error_message = "Both hosts run as the deployment's own service account, not the Compute Engine default."
  }

  assert {
    condition = (
      google_compute_instance.validator.network_interface[0].network_ip == "10.42.1.10" &&
      google_compute_instance.validator.network_interface[0].access_config[0].nat_ip == "203.0.113.10" &&
      google_compute_instance.validator.network_interface[0].nic_type == "GVNIC" &&
      google_compute_instance.gateway[0].network_interface[0].network_ip == "10.42.1.20" &&
      google_compute_instance.gateway[0].network_interface[0].access_config[0].nat_ip == "203.0.113.20"
    )
    error_message = "Each host takes its reserved private address (10.42.1.10, 10.42.1.20) and its static public address."
  }

  assert {
    condition = (
      google_compute_address.validator_internal.address == "10.42.1.10" && google_compute_address.validator_internal.address_type == "INTERNAL" &&
      google_compute_address.gateway_internal[0].address == "10.42.1.20" && google_compute_address.gateway_internal[0].address_type == "INTERNAL" &&
      google_compute_address.validator_public.address_type == "EXTERNAL" && google_compute_address.gateway_public[0].address_type == "EXTERNAL"
    )
    error_message = "The private addresses are the subnet's 10th and 20th, and both public addresses are reserved external addresses."
  }

  assert {
    condition = (
      google_compute_instance.validator.deletion_protection == true &&
      google_compute_instance.validator.allow_stopping_for_update == false &&
      google_compute_instance.validator.boot_disk[0].initialize_params[0].type == "hyperdisk-balanced" &&
      google_compute_instance.gateway[0].boot_disk[0].initialize_params[0].type == "pd-balanced" &&
      google_compute_instance.validator.boot_disk[0].initialize_params[0].image == "https://www.googleapis.com/compute/v1/projects/ubuntu-os-cloud/global/images/ubuntu-2604-lts-amd64-v20261101"
    )
    error_message = "The validator is protected from deletion and never stopped for an update; both boot Ubuntu."
  }

  assert {
    condition     = output.session_command.validator == "gcloud compute ssh telcoin-validator --project tn-test-project --zone us-central1-a --tunnel-through-iap" && output.session_command.gateway == "gcloud compute ssh telcoin-gateway --project tn-test-project --zone us-central1-a --tunnel-through-iap"
    error_message = "The session commands go through IAP by default and name the real instances."
  }

  assert {
    condition     = strcontains(output.next_steps, "open a shell: gcloud compute ssh telcoin-validator --project tn-test-project --zone us-central1-a --tunnel-through-iap\n")
    error_message = "The printed steps tell the operator how to open a shell on the validator."
  }

  assert {
    condition     = length(google_compute_instance_iam_member.validator_os_admin) == 0 && length(google_iap_tunnel_instance_iam_member.validator_tunnel) == 0 && length(google_service_account_iam_member.admin_act_as) == 0
    error_message = "With no admin_members nothing is granted."
  }
}

run "mainnet_hosts" {
  command = plan

  variables {
    network = "mainnet"
  }

  override_data {
    target = data.google_compute_machine_types.validator
    values = { machine_types = [{ name = "c3d-standard-16", guest_cpus = 16, memory_mb = 65536 }] }
  }

  assert {
    condition     = google_compute_instance.validator.machine_type == "c3d-standard-16"
    error_message = "The mainnet default is c3d-standard-16: 8 cores and 64 GB, with Hyperdisk Balanced."
  }

  assert {
    condition     = google_compute_disk.data.size == 2000 && google_compute_disk.data.provisioned_iops == 20000 && google_compute_disk.data.provisioned_throughput == 300
    error_message = "The mainnet data disk is at the floors: 2000 GiB, 20000 IOPS, 300 MiB/s."
  }

  assert {
    condition     = google_compute_instance.validator.shielded_instance_config[0].enable_vtpm
    error_message = "A mainnet validator has a vTPM for the stored passphrase credential."
  }
}

run "bigger_disk_and_cmek" {
  command = plan

  variables {
    data_disk_size_gb    = 4000
    data_disk_iops       = 40000
    data_disk_throughput = 1000
    disk_kms_key         = "projects/tn-test-project/locations/us-central1/keyRings/tn/cryptoKeys/data"
    ubuntu_version       = "24.04"
  }

  assert {
    condition     = google_compute_disk.data.size == 4000 && google_compute_disk.data.provisioned_iops == 40000 && google_compute_disk.data.provisioned_throughput == 1000
    error_message = "Disk sizes above the floors are taken as given."
  }

  assert {
    condition = alltrue([for k in [
      google_compute_disk.data.disk_encryption_key[0].kms_key_self_link,
      google_compute_instance.validator.boot_disk[0].kms_key_self_link,
      google_compute_instance.gateway[0].boot_disk[0].kms_key_self_link,
    ] : k == var.disk_kms_key])
    error_message = "disk_kms_key encrypts the data disk and both boot disks with the operator's Cloud KMS key."
  }

  assert {
    condition     = data.google_compute_image.ubuntu.family == "ubuntu-2404-lts-amd64" && data.google_compute_image.ubuntu.project == "ubuntu-os-cloud"
    error_message = "ubuntu_version 24.04 boots the ubuntu-2404-lts-amd64 family."
  }
}

run "admin_members" {
  command = plan

  variables {
    admin_members = ["user:ops@example.org", "group:validators@example.org"]
  }

  assert {
    condition = (
      toset([for m in google_compute_instance_iam_member.validator_os_admin : m.member]) == toset(["user:ops@example.org", "group:validators@example.org"]) &&
      alltrue([for m in google_compute_instance_iam_member.validator_os_admin : m.role == "roles/compute.osAdminLogin" && m.instance_name == "telcoin-validator"]) &&
      alltrue([for m in google_compute_instance_iam_member.gateway_os_admin : m.role == "roles/compute.osAdminLogin" && m.instance_name == "telcoin-gateway"]) &&
      length(google_compute_instance_iam_member.gateway_os_admin) == 2
    )
    error_message = "Each admin gets OS Login with sudo on each instance, and nowhere else."
  }

  assert {
    condition = (
      length(google_iap_tunnel_instance_iam_member.validator_tunnel) == 2 && length(google_iap_tunnel_instance_iam_member.gateway_tunnel) == 2 &&
      alltrue([for m in concat(values(google_iap_tunnel_instance_iam_member.validator_tunnel), values(google_iap_tunnel_instance_iam_member.gateway_tunnel)) : m.role == "roles/iap.tunnelResourceAccessor"])
    )
    error_message = "With IAP on each admin may open a tunnel to each instance."
  }

  assert {
    condition = (
      length(google_service_account_iam_member.admin_act_as) == 2 &&
      alltrue([for m in google_service_account_iam_member.admin_act_as : m.role == "roles/iam.serviceAccountUser" && m.service_account_id == "projects/tn-test-project/serviceAccounts/telcoin-host@tn-test-project.iam.gserviceaccount.com"])
    )
    error_message = "OS Login on an instance with a service account needs serviceAccountUser on that account, granted on the account alone."
  }
}

run "admin_members_without_iap" {
  command = plan

  variables {
    admin_members   = ["user:ops@example.org"]
    enable_iap      = false
    admin_ssh_cidrs = ["198.51.100.7/32"]
  }

  assert {
    condition     = length(google_iap_tunnel_instance_iam_member.validator_tunnel) == 0 && length(google_iap_tunnel_instance_iam_member.gateway_tunnel) == 0 && length(google_compute_instance_iam_member.validator_os_admin) == 1
    error_message = "With IAP off no tunnel access is granted; OS Login still is."
  }
}
