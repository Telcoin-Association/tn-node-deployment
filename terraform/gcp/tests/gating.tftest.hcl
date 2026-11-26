# The two applies. The first builds everything but the gateway VM; the second,
# with rpc_domain set, adds the gateway and leaves the validator alone.

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
  project           = "tn-test-project"
  validator_address = "0x1111111111111111111111111111111111111111"
}

run "first_apply" {
  command = plan

  assert {
    condition     = length(google_compute_instance.gateway) == 0 && length(terraform_data.gateway_cfg) == 0 && output.gateway_created == false
    error_message = "With rpc_domain empty there is no gateway VM."
  }

  assert {
    condition = (
      length(google_compute_address.gateway_public) == 1 && length(google_compute_address.gateway_internal) == 1 &&
      output.validator_public_ip == "203.0.113.10" && output.gateway_public_ip == "203.0.113.20" &&
      output.validator_private_ip == "10.42.1.10" && output.gateway_private_ip == "10.42.1.20"
    )
    error_message = "Both static public addresses and both fixed private addresses exist from the first apply."
  }

  assert {
    condition     = length(google_compute_firewall.validator_from_gateway) == 1 && length(google_compute_firewall.gateway_web) == 1
    error_message = "Every firewall rule exists from the first apply."
  }

  assert {
    condition     = output.session_command.gateway == null && !strcontains(output.next_steps, "telcoin-gateway")
    error_message = "No session command is printed for a gateway that does not exist yet."
  }

  assert {
    condition     = output.tao_handoff.record == "A" && output.tao_handoff.name == null && output.tao_handoff.ipv4 == "203.0.113.20"
    error_message = "The handoff names the gateway's address before rpc_domain is set."
  }

  assert {
    condition     = google_compute_instance.validator.metadata["user-data"] == module.host_plan.validator_user_data && startswith(google_compute_instance.validator.metadata["user-data"], "#cloud-config\n")
    error_message = "The validator boots from host-plan's cloud-config, as plain text in the user-data key cloud-init reads on Compute Engine."
  }

  assert {
    condition     = strcontains(module.host_plan.validator_env, "TN_FB_CLOUD='gcp'\n") && strcontains(module.host_plan.validator_env, "TN_FB_LOGIN_USER='ubuntu'\n") && strcontains(module.host_plan.validator_env, "TN_FB_TRUSTED_NODES=''\n")
    error_message = "The validator's env names the cloud, the image's login user and no hubs file."
  }
}

# The validator's user data is built from inputs that exclude rpc_domain
# (host-plan's own tests compare the two renderings); here the root must pass
# it through unchanged and add nothing that carries the domain.
run "second_apply" {
  command = plan

  variables {
    rpc_domain = "rpc.example.org"
  }

  assert {
    condition     = length(google_compute_instance.gateway) == 1 && length(terraform_data.gateway_cfg) == 1 && output.gateway_created == true
    error_message = "Setting rpc_domain creates the gateway VM."
  }

  assert {
    condition = (
      google_compute_instance.validator.metadata["user-data"] == module.host_plan.validator_user_data &&
      !strcontains(jsonencode(google_compute_instance.validator.metadata), "rpc.example.org") &&
      !strcontains(module.host_plan.validator_env, "rpc.example.org")
    )
    error_message = "The validator's metadata must not change with rpc_domain."
  }

  assert {
    condition     = output.session_command.validator == run.first_apply.session_command.validator && output.validator_public_ip == run.first_apply.validator_public_ip
    error_message = "The validator keeps its name, its route in and its public address across the two applies."
  }

  assert {
    condition = alltrue([for want in [
      "TN_FB_ROLE='gateway'\n",
      "TN_FB_CLOUD='gcp'\n",
      "TN_FB_UPSTREAM='10.42.1.10'\n",
      "TN_FB_DOMAIN='rpc.example.org'\n",
      "TN_FB_PUBLIC_IP='203.0.113.20'\n",
      "TN_FB_REDIRECT_QUERIES='https://rpc.adiri.tel'\n",
      "TN_FB_SSH_FROM='10.42.0.0/16'\n",
    ] : strcontains(module.host_plan.gateway_env, want)])
    error_message = "The gateway's env holds TN_FB_UPSTREAM='10.42.1.10', its domain and its own static address."
  }

  assert {
    condition = (
      google_compute_instance.gateway[0].metadata["user-data"] == module.host_plan.gateway_user_data &&
      terraform_data.gateway_cfg[0].input.user_data == module.host_plan.gateway_user_data &&
      terraform_data.gateway_cfg[0].input.image_family == "ubuntu-2604-lts-amd64"
    )
    error_message = "The gateway boots from its own cloud-config, and a change to it replaces the gateway."
  }

  assert {
    condition     = output.tao_handoff.name == "rpc.example.org" && output.tao_handoff.ipv4 == "203.0.113.20"
    error_message = "The handoff asks for an A record for rpc_domain at the gateway's address."
  }

  assert {
    condition = alltrue([for want in [
      "--admission closed --trusted-nodes /etc/telcoin-first-boot/trusted-nodes.yaml)\n",
      "firewall-setup.sh --enable --gateway-from 10.42.1.20 --ssh-from 10.42.0.0/16\n",
      "--phase=finalize",
      "--set gateway_upstream=10.42.1.20\n",
      "--external-primary /ip4/203.0.113.10/udp/49590/quic-v1",
      "--listener-primary /ip4/10.42.1.10/udp/49590/quic-v1",
      "install-caddy.sh --phase=rpc-advertise --rpc-domain rpc.example.org",
    ] : strcontains(output.next_steps, want)])
    error_message = "The testnet steps hold closed admission, the firewall with --gateway-from 10.42.1.20, finalize and gateway_upstream=10.42.1.20, with this deployment's addresses."
  }
}

run "mainnet_steps" {
  command = plan

  variables {
    network    = "mainnet"
    rpc_domain = "rpc.example.org"
  }

  override_data {
    target = data.google_compute_machine_types.validator
    values = { machine_types = [{ name = "c3d-standard-16", guest_cpus = 16, memory_mb = 65536 }] }
  }

  assert {
    condition     = length(split("==== At launch ====", output.next_steps)) == 2
    error_message = "The mainnet steps have one At launch heading."
  }

  assert {
    condition     = !strcontains(split("==== At launch ====", output.next_steps)[0], "--phase=finalize") && strcontains(split("==== At launch ====", output.next_steps)[1], "--phase=finalize")
    error_message = "On mainnet finalize is printed under At launch only."
  }

  assert {
    condition     = strcontains(split("==== At launch ====", output.next_steps)[0], "--admission closed --trusted-nodes /etc/telcoin-first-boot/trusted-nodes.yaml") && strcontains(output.next_steps, "--gateway-from 10.42.1.20")
    error_message = "Mainnet key generation runs with closed admission, and the firewall admits the gateway."
  }

  assert {
    condition     = strcontains(module.host_plan.gateway_env, "TN_FB_REDIRECT_QUERIES='https://rpc.telcoin.network'\n") && strcontains(module.host_plan.gateway_env, "TN_FB_NETWORK='mainnet'\n")
    error_message = "A mainnet gateway redirects queries to the mainnet public RPC."
  }
}

run "no_gateway" {
  command = plan

  variables {
    gateway_enabled = false
  }

  assert {
    condition = (
      length(google_compute_instance.gateway) == 0 && length(google_compute_address.gateway_public) == 0 &&
      length(google_compute_address.gateway_internal) == 0 && length(terraform_data.gateway_cfg) == 0
    )
    error_message = "gateway_enabled false builds no gateway resources."
  }

  assert {
    condition     = output.gateway_public_ip == null && output.gateway_private_ip == null && output.gateway_created == false && output.tao_handoff.ipv4 == null
    error_message = "Without a gateway the outputs name no gateway address."
  }

  assert {
    condition     = !strcontains(output.next_steps, "--gateway-from") && strcontains(output.next_steps, "--phase=finalize")
    error_message = "Without a gateway the validator's steps stay and admit no gateway."
  }
}

run "hubs_file" {
  command = plan

  variables {
    trusted_nodes_file = "tests/fixtures/trusted-nodes.yaml"
  }

  assert {
    condition = (
      strcontains(module.host_plan.validator_env, "TN_FB_TRUSTED_NODES='/etc/telcoin-first-boot/trusted-nodes.yaml'\n") &&
      base64decode(yamldecode(google_compute_instance.validator.metadata["user-data"]).write_files[3].content) == file("tests/fixtures/trusted-nodes.yaml")
    )
    error_message = "trusted_nodes_file reaches the validator through its user data."
  }
}
