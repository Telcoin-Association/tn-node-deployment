# The values first boot takes and refuses, held to the plan: a value the plan
# takes must reach a host whose first boot takes it too, or the host is built
# and stops at its env file. Each run is one value; "taken" runs plan, the
# others name the variable that refuses it. The last runs are values first
# boot takes and the plan refuses on purpose.

variables {
  role_set             = { validator = true, gateway = true }
  network              = "testnet"
  cloud                = "aws"
  login_user           = "ubuntu"
  validator_public_ip  = "203.0.113.10"
  validator_private_ip = "10.42.1.10"
  gateway_public_ip    = "203.0.113.20"
  gateway_private_ip   = "10.42.1.20"
  vpc_cidr             = "10.42.0.0/16"
  rpc_domain           = "gw.example.org"
  data_device          = "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol0123456789abcdef0"
  session_commands = {
    validator = "aws ssm start-session --target i-0validator"
    gateway   = "aws ssm start-session --target i-0gateway"
  }
}

# --- installer_url (TN_FB_INSTALLER_URL) -------------------------------------

run "installer_taken_port_65535" {
  command = plan
  variables { installer_url = "https://install.example.org:65535/a" }
}

run "installer_taken_path" {
  command = plan
  variables { installer_url = "https://install.example.org/v2/latest_1.sh" }
}

run "installer_refused_colon_in_path" {
  command = plan
  variables { installer_url = "https://install.example.org/v2:latest" }
  expect_failures = [var.installer_url]
}

run "installer_refused_empty_label" {
  command = plan
  variables { installer_url = "https://install..telcoin.network" }
  expect_failures = [var.installer_url]
}

run "installer_refused_port_70000" {
  command = plan
  variables { installer_url = "https://install.telcoin.network:70000" }
  expect_failures = [var.installer_url]
}

run "installer_refused_http" {
  command = plan
  variables { installer_url = "http://install.telcoin.network" }
  expect_failures = [var.installer_url]
}

# --- redirect_queries_url (TN_FB_REDIRECT_QUERIES) ---------------------------

run "redirect_taken_port_8545" {
  command = plan
  variables { redirect_queries_url = "https://rpc.example.org:8545/" }
}

run "redirect_taken_validator_other_port" {
  command = plan
  variables { redirect_queries_url = "http://10.42.1.10:8546" }
}

run "redirect_taken_other_host_rpc_port" {
  command = plan
  variables { redirect_queries_url = "http://10.42.1.11:8545" }
}

run "redirect_taken_loopback_rpc_port" {
  command = plan
  variables { redirect_queries_url = "http://localhost:8545" }
}

run "redirect_taken_port_65535" {
  command = plan
  variables { redirect_queries_url = "https://rpc.example.org:65535/v1/rpc" }
}

run "redirect_taken_path" {
  command = plan
  variables { redirect_queries_url = "http://rpc.example.org:8545/v1/a_b-c.d" }
}

run "redirect_refused_port_99999" {
  command = plan
  variables { redirect_queries_url = "https://rpc.example.org:99999/" }
  expect_failures = [var.redirect_queries_url]
}

run "redirect_refused_port_65536" {
  command = plan
  variables { redirect_queries_url = "https://rpc.example.org:65536/" }
  expect_failures = [var.redirect_queries_url]
}

run "redirect_refused_port_0" {
  command = plan
  variables { redirect_queries_url = "https://rpc.example.org:0/" }
  expect_failures = [var.redirect_queries_url]
}

run "redirect_refused_port_leading_zero" {
  command = plan
  variables { redirect_queries_url = "https://rpc.example.org:08545/" }
  expect_failures = [var.redirect_queries_url]
}

run "redirect_refused_empty_label" {
  command = plan
  variables { redirect_queries_url = "https://rpc..example.org/" }
  expect_failures = [var.redirect_queries_url]
}

run "redirect_refused_label_starts_with_dash" {
  command = plan
  variables { redirect_queries_url = "https://rpc.-x.example.org/" }
  expect_failures = [var.redirect_queries_url]
}

run "redirect_refused_host_starts_with_dash" {
  command = plan
  variables { redirect_queries_url = "https://-rpc.example.org/" }
  expect_failures = [var.redirect_queries_url]
}

run "redirect_refused_colon_at_comma_in_path" {
  command = plan
  variables { redirect_queries_url = "http://rpc.example.org:8545/v1:a@b,c" }
  expect_failures = [var.redirect_queries_url]
}

run "redirect_refused_at_in_path" {
  command = plan
  variables { redirect_queries_url = "https://rpc.example.org/a@b" }
  expect_failures = [var.redirect_queries_url]
}

run "redirect_refused_ftp" {
  command = plan
  variables { redirect_queries_url = "ftp://rpc.example.org/" }
  expect_failures = [var.redirect_queries_url]
}

run "redirect_refused_validator_rpc" {
  command = plan
  variables { redirect_queries_url = "http://10.42.1.10:8545" }
  expect_failures = [var.redirect_queries_url]
}

run "redirect_refused_validator_readiness" {
  command = plan
  variables { redirect_queries_url = "http://10.42.1.10:43174/" }
  expect_failures = [var.redirect_queries_url]
}

run "redirect_refused_gateway_listen_port" {
  command = plan
  variables { redirect_queries_url = "http://localhost:8655" }
  expect_failures = [var.redirect_queries_url]
}

run "redirect_refused_gateway_probe_port" {
  command = plan
  variables { redirect_queries_url = "http://LocalHost:8656/x" }
  expect_failures = [var.redirect_queries_url]
}

run "redirect_refused_gateway_metrics_port" {
  command = plan
  variables { redirect_queries_url = "http://127.0.0.1:9655" }
  expect_failures = [var.redirect_queries_url]
}

run "redirect_refused_gateway_any_address" {
  command = plan
  variables { redirect_queries_url = "http://0.0.0.0:8655" }
  expect_failures = [var.redirect_queries_url]
}

# --- rpc_domain (TN_FB_DOMAIN) -----------------------------------------------

run "domain_taken" {
  command = plan
  variables { rpc_domain = "rpc.example.org" }
}

run "domain_taken_punycode_tld" {
  command = plan
  variables { rpc_domain = "rpc.example.xn--p1ai" }
}

run "domain_taken_tld_with_a_digit" {
  command = plan
  variables { rpc_domain = "a.b1" }
}

run "domain_taken_tld_with_a_dash" {
  command = plan
  variables { rpc_domain = "x.y-z" }
}

run "domain_refused_tld_of_digits" {
  command = plan
  variables { rpc_domain = "rpc.example.123" }
  expect_failures = [var.rpc_domain]
}

run "domain_refused_ipv4" {
  command = plan
  variables { rpc_domain = "10.42.1.20" }
  expect_failures = [var.rpc_domain]
}

run "domain_refused_one_label" {
  command = plan
  variables { rpc_domain = "localhost" }
  expect_failures = [var.rpc_domain]
}

run "domain_refused_empty_label" {
  command = plan
  variables { rpc_domain = "rpc..example.org" }
  expect_failures = [var.rpc_domain]
}

run "domain_refused_starts_with_dash" {
  command = plan
  variables { rpc_domain = "-rpc.example.org" }
  expect_failures = [var.rpc_domain]
}

run "domain_refused_trailing_dot" {
  command = plan
  variables { rpc_domain = "rpc.example.org." }
  expect_failures = [var.rpc_domain]
}

# --- admin_ssh_cidrs (TN_FB_SSH_FROM, with vpc_cidr after it) ----------------

run "ssh_taken_host" {
  command = plan
  variables { admin_ssh_cidrs = ["198.51.100.7/32"] }
}

run "ssh_taken_network" {
  command = plan
  variables { admin_ssh_cidrs = ["198.51.100.0/24"] }
}

run "ssh_taken_slash_8" {
  command = plan
  variables { admin_ssh_cidrs = ["10.0.0.0/8"] }
}

run "ssh_taken_host_bits" {
  command = plan
  variables { admin_ssh_cidrs = ["198.51.100.7/24"] }
}

run "ssh_taken_ipv6" {
  command = plan
  variables { admin_ssh_cidrs = ["2001:db8::/32"] }
}

run "ssh_taken_ipv6_full" {
  command = plan
  variables { admin_ssh_cidrs = ["1:2:3:4:5:6:7:8/128"] }
}

run "ssh_refused_anywhere" {
  command = plan
  variables { admin_ssh_cidrs = ["0.0.0.0/0"] }
  expect_failures = [var.admin_ssh_cidrs]
}

run "ssh_refused_zero_network" {
  command = plan
  variables { admin_ssh_cidrs = ["0.0.0.0/8"] }
  expect_failures = [var.admin_ssh_cidrs]
}

run "ssh_refused_slash_1" {
  command = plan
  variables { admin_ssh_cidrs = ["128.0.0.0/1"] }
  expect_failures = [var.admin_ssh_cidrs]
}

run "ssh_refused_slash_7" {
  command = plan
  variables { admin_ssh_cidrs = ["10.0.0.0/7"] }
  expect_failures = [var.admin_ssh_cidrs]
}

run "ssh_refused_slash_33" {
  command = plan
  variables { admin_ssh_cidrs = ["10.0.0.0/33"] }
  expect_failures = [var.admin_ssh_cidrs]
}

run "ssh_refused_prefix_leading_zero" {
  command = plan
  variables { admin_ssh_cidrs = ["10.0.0.0/08"] }
  expect_failures = [var.admin_ssh_cidrs]
}

run "ssh_refused_address_leading_zero" {
  command = plan
  variables { admin_ssh_cidrs = ["010.0.0.0/8"] }
  expect_failures = [var.admin_ssh_cidrs]
}

run "ssh_refused_ipv6_anywhere" {
  command = plan
  variables { admin_ssh_cidrs = ["::/0"] }
  expect_failures = [var.admin_ssh_cidrs]
}

run "ssh_refused_ipv6_unspecified" {
  command = plan
  variables { admin_ssh_cidrs = ["::/8"] }
  expect_failures = [var.admin_ssh_cidrs]
}

run "ssh_refused_ipv6_slash_7" {
  command = plan
  variables { admin_ssh_cidrs = ["2001:db8::/7"] }
  expect_failures = [var.admin_ssh_cidrs]
}

run "ssh_refused_ipv6_slash_129" {
  command = plan
  variables { admin_ssh_cidrs = ["2001:db8::/129"] }
  expect_failures = [var.admin_ssh_cidrs]
}

run "ssh_refused_ipv6_with_ipv4" {
  command = plan
  variables { admin_ssh_cidrs = ["::ffff:198.51.100.7/128"] }
  expect_failures = [var.admin_ssh_cidrs]
}

run "ssh_refused_two_elisions" {
  command = plan
  variables { admin_ssh_cidrs = ["1::2::3/64"] }
  expect_failures = [var.admin_ssh_cidrs]
}

run "ssh_refused_vpc_leading_zero" {
  command = plan
  variables { vpc_cidr = "10.042.0.0/16" }
  expect_failures = [var.vpc_cidr]
}

# --- min_scripts_release (TN_FB_MIN_RELEASE) ---------------------------------

run "release_taken_zeros" {
  command = plan
  variables { min_scripts_release = "scripts-v0.0.0" }
}

run "release_taken_two_digits" {
  command = plan
  variables { min_scripts_release = "scripts-v2.10.0" }
}

run "release_taken_four_digits" {
  command = plan
  variables { min_scripts_release = "scripts-v9999.9999.9999" }
}

run "release_refused_leading_zero" {
  command = plan
  variables { min_scripts_release = "scripts-v2.03.0" }
  expect_failures = [var.min_scripts_release]
}

run "release_refused_five_digits" {
  command = plan
  variables { min_scripts_release = "scripts-v10000.0.0" }
  expect_failures = [var.min_scripts_release]
}

run "release_refused_two_parts" {
  command = plan
  variables { min_scripts_release = "scripts-v2.3" }
  expect_failures = [var.min_scripts_release]
}

run "release_refused_suffix" {
  command = plan
  variables { min_scripts_release = "scripts-v2.3.0-rc1" }
  expect_failures = [var.min_scripts_release]
}

run "release_refused_no_prefix" {
  command = plan
  variables { min_scripts_release = "v2.3.0" }
  expect_failures = [var.min_scripts_release]
}

# --- first boot takes these; the plan refuses them on purpose ------------------

# The A record and the certificate are for the lowercase name.
run "plan_refuses_upper_case_domain" {
  command = plan
  variables { rpc_domain = "RPC.Example.org" }
  expect_failures = [var.rpc_domain]
}

# A cloud firewall rule takes a CIDR, not a bare address.
run "plan_refuses_bare_ssh_address" {
  command = plan
  variables { admin_ssh_cidrs = ["198.51.100.7"] }
  expect_failures = [var.admin_ssh_cidrs]
}

# No cloud gives a host a link-local address as its private one.
run "plan_refuses_link_local_upstream" {
  command = plan
  variables { validator_private_ip = "169.254.10.10" }
  expect_failures = [var.validator_private_ip]
}
