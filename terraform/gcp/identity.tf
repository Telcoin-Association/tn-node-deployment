# Both hosts run as this account so neither gets the Compute Engine default
# service account, which often holds Editor on the project. It is granted no
# roles: the hosts call no Google API.
resource "google_service_account" "host" {
  account_id   = "${var.name_prefix}-host"
  display_name = "Telcoin Network hosts (${var.name_prefix})"
  description  = "Attached to the validator and worker gateway hosts. Holds no roles."
}

# Admins log in through OS Login. Each member gets, on these instances only:
# osAdminLogin (sudo is needed to run the node scripts), the IAP tunnel when
# IAP is on, and serviceAccountUser on the hosts' account, which OS Login
# requires on an instance that has a service account. gcloud compute ssh also
# needs compute.instances.get and compute.projects.get on the project, which
# this module does not grant.

resource "google_service_account_iam_member" "admin_act_as" {
  for_each = toset(var.admin_members)

  service_account_id = google_service_account.host.name
  role               = "roles/iam.serviceAccountUser"
  member             = each.value
}

resource "google_compute_instance_iam_member" "validator_os_admin" {
  for_each = toset(var.admin_members)

  zone          = local.zone
  instance_name = google_compute_instance.validator.name
  role          = "roles/compute.osAdminLogin"
  member        = each.value
}

resource "google_iap_tunnel_instance_iam_member" "validator_tunnel" {
  for_each = var.enable_iap ? toset(var.admin_members) : toset([])

  zone     = local.zone
  instance = google_compute_instance.validator.name
  role     = "roles/iap.tunnelResourceAccessor"
  member   = each.value
}

# An instance's IAM policy goes with it, and the replacement keeps the name,
# so the gateway's grants are made again whenever the gateway is replaced.
resource "google_compute_instance_iam_member" "gateway_os_admin" {
  for_each = local.gateway_vm ? toset(var.admin_members) : toset([])

  zone          = local.zone
  instance_name = google_compute_instance.gateway[0].name
  role          = "roles/compute.osAdminLogin"
  member        = each.value

  lifecycle {
    replace_triggered_by = [google_compute_instance.gateway[0].instance_id]
  }
}

resource "google_iap_tunnel_instance_iam_member" "gateway_tunnel" {
  for_each = local.gateway_vm && var.enable_iap ? toset(var.admin_members) : toset([])

  zone     = local.zone
  instance = google_compute_instance.gateway[0].name
  role     = "roles/iap.tunnelResourceAccessor"
  member   = each.value

  lifecycle {
    replace_triggered_by = [google_compute_instance.gateway[0].instance_id]
  }
}
