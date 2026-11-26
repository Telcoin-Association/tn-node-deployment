# The operator's command list. The order checks compare how much text comes
# before each command.

variables {
  role_set              = { validator = true, gateway = true }
  network               = "testnet"
  cloud                 = "gcp"
  login_user            = "ubuntu"
  validator_public_ip   = "203.0.113.10"
  validator_private_ip  = "10.42.1.10"
  gateway_public_ip     = "203.0.113.20"
  gateway_private_ip    = "10.42.1.20"
  vpc_cidr              = "10.42.0.0/16"
  admin_ssh_cidrs       = []
  rpc_domain            = ""
  data_device           = "/dev/disk/by-id/google-tn-data"
  trusted_nodes_content = "hub-key: {}\n"
  validator_address     = "0x1111111111111111111111111111111111111111"
  session_commands = {
    validator = "gcloud compute ssh tn-validator --tunnel-through-iap"
    gateway   = "gcloud compute ssh tn-gateway --tunnel-through-iap"
  }
}

run "testnet" {
  command = plan

  variables {
    rpc_domain = "rpc.example.org"
  }

  assert {
    condition = alltrue([for want in [
      "ARGS=(--network testnet --install-method release --release-tag vX.Y.Z-adiri\n",
      "Replace vX.Y.Z-adiri with the current testnet release\n#    from the telcoin-network releases page",
      "--address 0x1111111111111111111111111111111111111111\n",
      "--external-primary /ip4/203.0.113.10/udp/49590/quic-v1\n",
      "--external-worker  /ip4/203.0.113.10/udp/49594/quic-v1\n",
      "--listener-primary /ip4/10.42.1.10/udp/49590/quic-v1\n",
      "--listener-worker  /ip4/10.42.1.10/udp/49594/quic-v1\n",
      "--admission closed --trusted-nodes /etc/telcoin-first-boot/trusted-nodes.yaml)\n",
      "printf '%s\\n' \"$PASS\" | sudo bash /home/ubuntu/telcoin-node-scripts/setup-node.sh --json --phase=keygen --passphrase-stdin \"$${ARGS[@]}\"\n",
      "sudo bash /home/ubuntu/telcoin-node-scripts/firewall-setup.sh --enable --gateway-from 10.42.1.20 --ssh-from 10.42.0.0/16\n",
      "sudo bash /home/ubuntu/telcoin-node-scripts/setup-node.sh --json --phase=finalize \"$${ARGS[@]}\"\n",
      "sudo bash /home/ubuntu/telcoin-node-scripts/edit-config.sh --set gateway_upstream=10.42.1.20\n",
      "sudo bash /home/ubuntu/telcoin-node-scripts/install-caddy.sh --phase=rpc-advertise --rpc-domain rpc.example.org\n",
      "sudo bash /home/ubuntu/telcoin-node-scripts/check-node.sh\n",
      "gcloud compute ssh tn-validator --tunnel-through-iap",
    ] : strcontains(output.next_steps, want)])
    error_message = "The testnet steps must hold key generation, the firewall with --gateway-from 10.42.1.20, finalize, gateway_upstream=10.42.1.20 and the advertisement, with the real addresses."
  }

  assert {
    condition = (
      length(split("--phase=keygen", output.next_steps)[0]) < length(split("firewall-setup.sh --enable", output.next_steps)[0]) &&
      length(split("firewall-setup.sh --enable", output.next_steps)[0]) < length(split("--phase=finalize", output.next_steps)[0]) &&
      length(split("--phase=finalize", output.next_steps)[0]) < length(split("gateway_upstream=", output.next_steps)[0]) &&
      length(split("gateway_upstream=", output.next_steps)[0]) < length(split("--phase=rpc-advertise", output.next_steps)[0]) &&
      length(split("--phase=rpc-advertise", output.next_steps)[0]) < length(split("check-node.sh", output.next_steps)[0])
    )
    error_message = "The steps must run key generation, firewall, finalize, gateway_upstream, rpc-advertise and check-node in that order."
  }

  assert {
    condition     = !strcontains(output.next_steps, "--allow-no-tpm") && !strcontains(output.next_steps, "At launch") && !strcontains(output.next_steps, "TAO")
    error_message = "Testnet has no launch block, no TAO handoff and, without allow_no_tpm, no --allow-no-tpm."
  }

  assert {
    condition     = length(split("--rpc-domain", output.next_steps)) == 2
    error_message = "Only the advertisement takes --rpc-domain: key generation on testnet must not, or it would put Caddy on the validator."
  }
}

run "testnet_no_domain_yet" {
  command = plan

  assert {
    condition     = strcontains(output.next_steps, "--rpc-domain <rpc_domain>\n") && strcontains(output.next_steps, "a name of your own at the gateway's static IP,\n# 203.0.113.20.\n") && strcontains(output.next_steps, "Then set rpc_domain")
    error_message = "Before rpc_domain is set the steps say how to choose the name and apply again."
  }

  assert {
    condition     = output.tao_handoff.name == null && output.tao_handoff.record == "A" && output.tao_handoff.ipv4 == "203.0.113.20" && output.tao_handoff.note != ""
    error_message = "tao_handoff.name must stay null until rpc_domain is set."
  }
}

run "domain_set" {
  command = plan

  variables {
    rpc_domain = "rpc.example.org"
  }

  assert {
    condition     = output.tao_handoff.name == "rpc.example.org" && output.tao_handoff.ipv4 == "203.0.113.20"
    error_message = "tao_handoff must name rpc_domain once it is set."
  }
}

run "mainnet" {
  command = plan

  variables {
    network         = "mainnet"
    admin_ssh_cidrs = ["198.51.100.7/32", "198.51.100.8/32"]
  }

  assert {
    condition     = length(split("==== At launch ====", output.next_steps)) == 2
    error_message = "The mainnet steps must have one At launch heading."
  }

  assert {
    condition = alltrue([for want in [
      "ARGS=(--network mainnet --install-method existing --binary-path /usr/local/bin/telcoin-network\n",
      "--address 0x1111111111111111111111111111111111111111\n",
      "--admission closed --trusted-nodes /etc/telcoin-first-boot/trusted-nodes.yaml)\n",
      "--phase=keygen --passphrase-stdin",
      "firewall-setup.sh --enable --gateway-from 10.42.1.20 --ssh-from 198.51.100.7/32,198.51.100.8/32,10.42.0.0/16\n",
    ] : strcontains(split("==== At launch ====", output.next_steps)[0], want)])
    error_message = "Before the launch heading the mainnet steps hold key generation with an existing binary and the firewall."
  }

  assert {
    condition     = !strcontains(split("==== At launch ====", output.next_steps)[0], "--phase=finalize") && !strcontains(split("==== At launch ====", output.next_steps)[0], "gateway_upstream=")
    error_message = "On mainnet no finalize and no gateway_upstream may come before the At launch heading."
  }

  assert {
    condition     = strcontains(split("==== At launch ====", output.next_steps)[1], "--phase=finalize \"$${ARGS[@]}\"\n") && strcontains(split("==== At launch ====", output.next_steps)[1], "--set gateway_upstream=10.42.1.20\n")
    error_message = "Finalize and gateway_upstream belong under the At launch heading."
  }

  assert {
    condition     = strcontains(output.next_steps, "https://v<label>.telcoin.network/") && strcontains(output.next_steps, "Telcoin Association (TAO)") && strcontains(output.next_steps, "203.0.113.20") && strcontains(output.next_steps, "Then set rpc_domain")
    error_message = "The mainnet steps end with the default name, the TAO handoff with the gateway's static IP, and the second apply."
  }

  assert {
    condition     = !strcontains(output.next_steps, "--allow-no-tpm") && !strcontains(output.next_steps, "--release-tag")
    error_message = "Mainnet key generation takes an existing binary, and --allow-no-tpm only when asked for."
  }
}

run "mainnet_no_tpm_no_address" {
  command = plan

  variables {
    network           = "mainnet"
    allow_no_tpm      = true
    validator_address = ""
  }

  assert {
    condition     = strcontains(output.next_steps, "--admission closed --trusted-nodes /etc/telcoin-first-boot/trusted-nodes.yaml --allow-no-tpm)\n")
    error_message = "allow_no_tpm must add --allow-no-tpm to key generation."
  }

  assert {
    condition     = strcontains(output.next_steps, "--address 0xYOUR_VALIDATOR_SAFE\n")
    error_message = "With no validator_address the mainnet steps show the Safe placeholder."
  }
}

run "no_gateway" {
  command = plan

  variables {
    role_set           = { validator = true, gateway = false }
    gateway_public_ip  = ""
    gateway_private_ip = ""
    rpc_domain         = "rpc.example.org"
  }

  assert {
    condition = !anytrue([for gone in [
      "--gateway-from", "gateway_upstream", "rpc-advertise", "--rpc-domain", "Worker gateway host", "TAO", "rpc_domain",
    ] : strcontains(output.next_steps, gone)])
    error_message = "With no gateway the steps must hold no gateway line."
  }

  assert {
    condition     = strcontains(output.next_steps, "firewall-setup.sh --enable --ssh-from 10.42.0.0/16\n") && strcontains(output.next_steps, "--phase=finalize") && strcontains(output.next_steps, "--admission closed --trusted-nodes")
    error_message = "With no gateway the validator steps stay, admission included."
  }
}

run "hubs_by_hand" {
  command = plan

  variables {
    trusted_nodes_content = ""
    login_user            = "telcoin"
  }

  assert {
    condition     = strcontains(output.next_steps, "host at /etc/telcoin-first-boot/trusted-nodes.yaml") && strcontains(output.next_steps, "--trusted-nodes /etc/telcoin-first-boot/trusted-nodes.yaml)\n")
    error_message = "Without a hubs map the steps say where to put it, and key generation still names it."
  }

  assert {
    condition     = strcontains(output.next_steps, "sudo bash /home/telcoin/telcoin-node-scripts/setup-node.sh") && !strcontains(output.next_steps, "/home/ubuntu/")
    error_message = "The scripts are where the installer puts them: the login user's ~/telcoin-node-scripts."
  }
}

run "release_tag_given" {
  command = plan

  variables {
    node_release_tag = "v0.18.0-adiri"
  }

  assert {
    condition     = strcontains(output.next_steps, "ARGS=(--network testnet --install-method release --release-tag v0.18.0-adiri\n") && !strcontains(output.next_steps, "vX.Y.Z") && !strcontains(output.next_steps, "Replace")
    error_message = "A given node_release_tag is printed in place of the placeholder."
  }
}

run "release_tag_ignored_on_mainnet" {
  command = plan

  variables {
    network          = "mainnet"
    node_release_tag = "v1.0.0"
  }

  assert {
    condition     = !strcontains(output.next_steps, "--release-tag") && strcontains(output.next_steps, "--install-method existing")
    error_message = "Mainnet key generation takes an existing binary, whatever node_release_tag says."
  }
}
