# Ingress rules, one per purpose, applied by network tag. Anything not allowed
# here is dropped by the network's implied deny-ingress rule.

resource "google_compute_firewall" "validator_p2p" {
  name          = "${var.name_prefix}-validator-p2p"
  network       = google_compute_network.main.id
  direction     = "INGRESS"
  source_ranges = ["0.0.0.0/0"]
  target_tags   = [local.tag.validator]

  allow {
    protocol = "udp"
    ports    = ["49590", "49594"]
  }
}

# RPC and the health port answer the worker gateway only, by its fixed private
# address rather than its tag: a tag can be put on any instance in the network.
resource "google_compute_firewall" "validator_from_gateway" {
  count = var.gateway_enabled ? 1 : 0

  name          = "${var.name_prefix}-validator-from-gateway"
  network       = google_compute_network.main.id
  direction     = "INGRESS"
  source_ranges = ["${local.gateway_private_ip}/32"]
  target_tags   = [local.tag.validator]

  allow {
    protocol = "tcp"
    ports    = ["8545", "43174"]
  }
}

resource "google_compute_firewall" "gateway_web" {
  count = var.gateway_enabled ? 1 : 0

  name          = "${var.name_prefix}-gateway-web"
  network       = google_compute_network.main.id
  direction     = "INGRESS"
  source_ranges = ["0.0.0.0/0"]
  target_tags   = [local.tag.gateway]

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }
}

resource "google_compute_firewall" "admin_ssh" {
  count = length(var.admin_ssh_cidrs) > 0 ? 1 : 0

  name          = "${var.name_prefix}-admin-ssh"
  network       = google_compute_network.main.id
  direction     = "INGRESS"
  source_ranges = var.admin_ssh_cidrs
  target_tags   = local.host_tags

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# IAP TCP forwarding reaches port 22 from Google's forwarding range only; who
# may open a tunnel is decided by IAM (identity.tf), not by this rule.
resource "google_compute_firewall" "iap_ssh" {
  count = var.enable_iap ? 1 : 0

  name          = "${var.name_prefix}-iap-ssh"
  network       = google_compute_network.main.id
  direction     = "INGRESS"
  source_ranges = [local.iap_range]
  target_tags   = local.host_tags

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}
