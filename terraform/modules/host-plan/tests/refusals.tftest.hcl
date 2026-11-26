# Values the env files or the printed commands cannot carry are refused at
# plan time, before any host is built.

variables {
  role_set             = { validator = true, gateway = true }
  network              = "testnet"
  cloud                = "azure"
  login_user           = "telcoin"
  validator_public_ip  = "203.0.113.10"
  validator_private_ip = "10.42.1.10"
  gateway_public_ip    = "203.0.113.20"
  gateway_private_ip   = "10.42.1.20"
  vpc_cidr             = "10.42.0.0/16"
  rpc_domain           = "rpc.example.org"
  data_device          = "/dev/disk/azure/scsi1/lun0"
  session_commands = {
    validator = "az network bastion ssh --name tn-bastion"
    gateway   = "az network bastion ssh --name tn-bastion"
  }
}

run "accepted_baseline" {
  command = plan
}

run "quote_in_domain" {
  command = plan
  variables {
    rpc_domain = "rpc.example.org'"
  }
  expect_failures = [var.rpc_domain]
}

run "space_in_installer_url" {
  command = plan
  variables {
    installer_url = "https://install.telcoin.network/a b"
  }
  expect_failures = [var.installer_url]
}

run "quote_in_redirect_url" {
  command = plan
  variables {
    redirect_queries_url = "https://rpc.example.org/'x"
  }
  expect_failures = [var.redirect_queries_url]
}

run "space_in_data_device" {
  command = plan
  variables {
    data_device = "/dev/disk/by-id/a b"
  }
  expect_failures = [var.data_device]
}

run "quote_in_login_user" {
  command = plan
  variables {
    login_user = "ubuntu'"
  }
  expect_failures = [var.login_user]
}

run "space_in_admin_cidr" {
  command = plan
  variables {
    admin_ssh_cidrs = ["198.51.100.7/32 "]
  }
  expect_failures = [var.admin_ssh_cidrs]
}

run "bad_network" {
  command = plan
  variables {
    network = "adiri"
  }
  expect_failures = [var.network]
}

run "public_upstream" {
  command = plan
  variables {
    validator_private_ip = "203.0.113.11"
  }
  expect_failures = [var.validator_private_ip]
}

run "public_vpc" {
  command = plan
  variables {
    vpc_cidr = "8.8.0.0/16"
  }
  expect_failures = [var.vpc_cidr]
}

run "vpc_wider_than_private_range" {
  command = plan
  variables {
    vpc_cidr = "172.16.0.0/11"
  }
  expect_failures = [var.vpc_cidr]
}

run "gateway_without_address" {
  command = plan
  variables {
    gateway_private_ip = ""
  }
  expect_failures = [var.gateway_private_ip]
}

run "zero_address" {
  command = plan
  variables {
    validator_address = "0x0000000000000000000000000000000000000000"
  }
  expect_failures = [var.validator_address]
}

run "oversized_hubs" {
  command = plan
  variables {
    trusted_nodes_content = format("%65537s", "x")
  }
  expect_failures = [var.trusted_nodes_content]
}

run "release_tag_not_a_tag" {
  command = plan
  variables {
    node_release_tag = "latest"
  }
  expect_failures = [var.node_release_tag]
}

run "release_tag_of_another_network" {
  command = plan
  variables {
    node_release_tag = "v1.0.0"
  }
  expect_failures = [var.node_release_tag]
}

# What first-boot-lib.sh refuses at boot is refused here first.
run "punycode_tld" {
  command = plan
  variables {
    rpc_domain = "rpc.example.xn--p1ai"
  }
  expect_failures = [var.rpc_domain]
}

run "domain_over_253_characters" {
  command = plan
  variables {
    rpc_domain = "${join(".", [for i in range(4) : join("", [for j in range(62) : "a"])])}.org"
  }
  expect_failures = [var.rpc_domain]
}

run "redirect_port_of_six_digits" {
  command = plan
  variables {
    redirect_queries_url = "https://rpc.example.org:123456"
  }
  expect_failures = [var.redirect_queries_url]
}

run "installer_host_ending_in_a_dot" {
  command = plan
  variables {
    installer_url = "https://install.telcoin.network./"
  }
  expect_failures = [var.installer_url]
}

run "min_release_not_a_scripts_tag" {
  command = plan
  variables {
    min_scripts_release = "v2.3.0"
  }
  expect_failures = [var.min_scripts_release]
}
