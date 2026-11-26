# A custom-mode network holds one subnet and nothing else. Unlike the default
# network it has no default-allow-internal rule, so the only ingress either
# host takes is what firewall.tf allows; the implied rules deny all other
# ingress and allow egress, which apt and the installer need.
resource "google_compute_network" "main" {
  name                    = "${var.name_prefix}-net"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "main" {
  name                     = "${var.name_prefix}-subnet"
  network                  = google_compute_network.main.id
  region                   = var.region
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true

  # A record of who talked to the hosts, sampled and aggregated so a busy
  # P2P port stays cheap to log.
  log_config {
    aggregation_interval = "INTERVAL_5_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# The private addresses are fixed so the validator's firewall rule and the
# gateway's upstream can name them before either host exists.
resource "google_compute_address" "validator_internal" {
  name         = "${var.name_prefix}-validator-internal"
  region       = var.region
  address_type = "INTERNAL"
  subnetwork   = google_compute_subnetwork.main.id
  address      = local.validator_private_ip
}

resource "google_compute_address" "gateway_internal" {
  count = var.gateway_enabled ? 1 : 0

  name         = "${var.name_prefix}-gateway-internal"
  region       = var.region
  address_type = "INTERNAL"
  subnetwork   = google_compute_subnetwork.main.id
  address      = local.gateway_private_ip
}

# Peers dial the validator's public address and the RPC name's A record points
# at the gateway's, so neither may change once published.
resource "google_compute_address" "validator_public" {
  name         = "${var.name_prefix}-validator-public"
  region       = var.region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"

  lifecycle {
    prevent_destroy = true
  }
}

# Reserved from the first apply, so the A record can be published before the
# gateway host exists.
resource "google_compute_address" "gateway_public" {
  count = var.gateway_enabled ? 1 : 0

  name         = "${var.name_prefix}-gateway-public"
  region       = var.region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"

  lifecycle {
    prevent_destroy = true
  }
}
