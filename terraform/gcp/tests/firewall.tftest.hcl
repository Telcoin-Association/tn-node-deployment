# The ingress rules: the validator's RPC and health port answer the worker
# gateway's private address only, SSH is closed to the internet unless
# admin_ssh_cidrs opens it, and IAP is the default way in.

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
}

variables {
  project    = "tn-test-project"
  rpc_domain = "rpc.example.org"
}

run "default_rules" {
  command = plan

  assert {
    condition = (
      one(google_compute_firewall.validator_p2p.allow).protocol == "udp" &&
      one(google_compute_firewall.validator_p2p.allow).ports == tolist(["49590", "49594"]) &&
      google_compute_firewall.validator_p2p.source_ranges == toset(["0.0.0.0/0"]) &&
      google_compute_firewall.validator_p2p.target_tags == toset(["telcoin-validator"])
    )
    error_message = "UDP 49590 and 49594 must reach the validator from anywhere."
  }

  assert {
    condition = (
      length(google_compute_firewall.validator_from_gateway) == 1 &&
      one(google_compute_firewall.validator_from_gateway[0].allow).protocol == "tcp" &&
      one(google_compute_firewall.validator_from_gateway[0].allow).ports == tolist(["8545", "43174"]) &&
      google_compute_firewall.validator_from_gateway[0].source_ranges == toset(["10.42.1.20/32"]) &&
      google_compute_firewall.validator_from_gateway[0].target_tags == toset(["telcoin-validator"]) &&
      try(length(google_compute_firewall.validator_from_gateway[0].source_tags), 0) == 0
    )
    error_message = "TCP 8545 and 43174 on the validator must be open to the gateway's private address 10.42.1.20/32 and nothing else."
  }

  # No other rule that reaches the validator may admit TCP 8545 or 43174,
  # neither by naming the port nor by allowing every port.
  assert {
    condition = alltrue([
      for r in concat([google_compute_firewall.validator_p2p], google_compute_firewall.gateway_web, google_compute_firewall.admin_ssh, google_compute_firewall.iap_ssh) :
      !contains(tolist(r.target_tags), "telcoin-validator") || alltrue([
        for a in r.allow : !(contains(["tcp", "all"], a.protocol) && (length(a.ports) == 0 || contains(a.ports, "8545") || contains(a.ports, "43174")))
      ])
    ])
    error_message = "Only the from-gateway rule may admit TCP 8545 or 43174 on the validator."
  }

  assert {
    condition = (
      length(google_compute_firewall.gateway_web) == 1 &&
      one(google_compute_firewall.gateway_web[0].allow).protocol == "tcp" &&
      one(google_compute_firewall.gateway_web[0].allow).ports == tolist(["80", "443"]) &&
      google_compute_firewall.gateway_web[0].source_ranges == toset(["0.0.0.0/0"]) &&
      google_compute_firewall.gateway_web[0].target_tags == toset(["telcoin-gateway"])
    )
    error_message = "TCP 80 and 443 must reach the gateway, and only the gateway, from anywhere."
  }

  assert {
    condition     = length(google_compute_firewall.admin_ssh) == 0
    error_message = "With no admin_ssh_cidrs there must be no direct SSH rule."
  }

  assert {
    condition = (
      length(google_compute_firewall.iap_ssh) == 1 &&
      google_compute_firewall.iap_ssh[0].source_ranges == toset(["35.235.240.0/20"]) &&
      one(google_compute_firewall.iap_ssh[0].allow).protocol == "tcp" &&
      one(google_compute_firewall.iap_ssh[0].allow).ports == tolist(["22"]) &&
      google_compute_firewall.iap_ssh[0].target_tags == toset(["telcoin-validator", "telcoin-gateway"])
    )
    error_message = "With enable_iap the only SSH rule is TCP 22 from IAP's range 35.235.240.0/20 to both hosts."
  }

  assert {
    condition = alltrue([
      for r in concat([google_compute_firewall.validator_p2p], google_compute_firewall.validator_from_gateway, google_compute_firewall.gateway_web, google_compute_firewall.admin_ssh, google_compute_firewall.iap_ssh) :
      r.direction == "INGRESS"
    ])
    error_message = "Every rule is an ingress allow."
  }

  assert {
    condition     = google_compute_network.main.auto_create_subnetworks == false && google_compute_subnetwork.main.ip_cidr_range == "10.42.1.0/24"
    error_message = "The network must be custom mode with the one 10.42.1.0/24 subnet."
  }

  assert {
    condition     = google_compute_instance.validator.tags == toset(["telcoin-validator"]) && google_compute_instance.gateway[0].tags == toset(["telcoin-gateway"])
    error_message = "Each host carries its own tag only, so the other host's rules never reach it."
  }
}

run "admin_cidrs" {
  command = plan

  variables {
    admin_ssh_cidrs = ["198.51.100.7/32", "192.0.2.0/24"]
  }

  assert {
    condition = (
      length(google_compute_firewall.admin_ssh) == 1 &&
      google_compute_firewall.admin_ssh[0].source_ranges == toset(["198.51.100.7/32", "192.0.2.0/24"]) &&
      one(google_compute_firewall.admin_ssh[0].allow).protocol == "tcp" &&
      one(google_compute_firewall.admin_ssh[0].allow).ports == tolist(["22"]) &&
      google_compute_firewall.admin_ssh[0].target_tags == toset(["telcoin-validator", "telcoin-gateway"])
    )
    error_message = "admin_ssh_cidrs must open TCP 22 on both hosts to exactly the listed CIDRs."
  }

  assert {
    condition     = strcontains(module.host_plan.gateway_env, "TN_FB_SSH_FROM='198.51.100.7/32,192.0.2.0/24,10.42.0.0/16'\n")
    error_message = "The gateway's own firewall must let SSH in from admin_ssh_cidrs and the private network."
  }
}

run "no_iap" {
  command = plan

  variables {
    enable_iap      = false
    admin_ssh_cidrs = ["198.51.100.7/32"]
  }

  assert {
    condition     = length(google_compute_firewall.iap_ssh) == 0
    error_message = "With enable_iap false there must be no IAP rule."
  }

  assert {
    condition     = output.session_command.validator == "gcloud compute ssh telcoin-validator --project tn-test-project --zone us-central1-a"
    error_message = "Without IAP the session command connects over the public address."
  }
}

run "no_gateway" {
  command = plan

  variables {
    gateway_enabled = false
    rpc_domain      = ""
  }

  assert {
    condition     = length(google_compute_firewall.validator_from_gateway) == 0 && length(google_compute_firewall.gateway_web) == 0
    error_message = "Without a gateway the validator's RPC rule and the web rule must not exist."
  }

  assert {
    condition     = google_compute_firewall.iap_ssh[0].target_tags == toset(["telcoin-validator"])
    error_message = "Without a gateway the SSH rules name the validator only."
  }
}
