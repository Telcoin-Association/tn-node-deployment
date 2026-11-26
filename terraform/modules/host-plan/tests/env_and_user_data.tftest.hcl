# The env files and the cloud-config the hosts boot from. The assertions read
# the scripts' entries by path, mode and encoding only, so they hold whatever
# the scripts in terraform/first-boot/ contain.

variables {
  role_set              = { validator = true, gateway = true }
  network               = "testnet"
  cloud                 = "aws"
  login_user            = "ubuntu"
  validator_public_ip   = "203.0.113.10"
  validator_private_ip  = "10.42.1.10"
  gateway_public_ip     = "203.0.113.20"
  gateway_private_ip    = "10.42.1.20"
  vpc_cidr              = "10.42.0.0/16"
  admin_ssh_cidrs       = ["198.51.100.7/32"]
  rpc_domain            = "rpc.example.org"
  data_device           = "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol0123456789abcdef0"
  trusted_nodes_content = "hub-key:\n  primary:\n    network_address: /ip4/192.0.2.1/udp/49590/quic-v1\n"
  validator_address     = "0x1111111111111111111111111111111111111111"
  session_commands = {
    validator = "aws ssm start-session --target i-0validator"
    gateway   = "aws ssm start-session --target i-0gateway"
  }
}

run "env_keys_per_role" {
  command = plan

  assert {
    condition     = join(",", [for l in compact(split("\n", output.validator_env)) : split("=", l)[0]]) == "TN_FB_ROLE,TN_FB_NETWORK,TN_FB_CLOUD,TN_FB_LOGIN_USER,TN_FB_INSTALLER_URL,TN_FB_MIN_RELEASE,TN_FB_DATA_DEVICE,TN_FB_TRUSTED_NODES"
    error_message = "The validator env must hold exactly the shared keys plus TN_FB_DATA_DEVICE and TN_FB_TRUSTED_NODES."
  }

  assert {
    condition     = join(",", [for l in compact(split("\n", output.gateway_env)) : split("=", l)[0]]) == "TN_FB_ROLE,TN_FB_NETWORK,TN_FB_CLOUD,TN_FB_LOGIN_USER,TN_FB_INSTALLER_URL,TN_FB_MIN_RELEASE,TN_FB_UPSTREAM,TN_FB_DOMAIN,TN_FB_PUBLIC_IP,TN_FB_REDIRECT_QUERIES,TN_FB_RATE_LIMIT_SUBMISSIONS,TN_FB_SSH_FROM"
    error_message = "The gateway env must hold exactly the shared keys plus the six gateway keys."
  }

  assert {
    condition = alltrue([for l in compact(split("\n", "${output.validator_env}${output.gateway_env}")) :
    can(regex("^TN_FB_[A-Z_]+='[A-Za-z0-9._:/,@-]*'$", l))])
    error_message = "Every env line must be KEY='value' with a value of the allowed characters."
  }

  assert {
    condition = alltrue([for want in [
      "TN_FB_ROLE='validator'\n",
      "TN_FB_NETWORK='testnet'\n",
      "TN_FB_CLOUD='aws'\n",
      "TN_FB_LOGIN_USER='ubuntu'\n",
      "TN_FB_INSTALLER_URL='https://install.telcoin.network'\n",
      "TN_FB_MIN_RELEASE='scripts-v2.3.0'\n",
      "TN_FB_DATA_DEVICE='/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol0123456789abcdef0'\n",
      "TN_FB_TRUSTED_NODES='/etc/telcoin-first-boot/trusted-nodes.yaml'\n",
    ] : strcontains(output.validator_env, want)])
    error_message = "The validator env values are wrong."
  }

  assert {
    condition = alltrue([for want in [
      "TN_FB_ROLE='gateway'\n",
      "TN_FB_MIN_RELEASE='scripts-v2.3.0'\n",
      "TN_FB_UPSTREAM='10.42.1.10'\n",
      "TN_FB_DOMAIN='rpc.example.org'\n",
      "TN_FB_PUBLIC_IP='203.0.113.20'\n",
      "TN_FB_REDIRECT_QUERIES='https://rpc.adiri.tel'\n",
      "TN_FB_RATE_LIMIT_SUBMISSIONS='300'\n",
      "TN_FB_SSH_FROM='198.51.100.7/32,10.42.0.0/16'\n",
    ] : strcontains(output.gateway_env, want)])
    error_message = "The gateway env values are wrong: TN_FB_UPSTREAM must be the validator's private address."
  }
}

# First boot refuses scripts older than the release both env files name.
run "min_release_given" {
  command = plan

  variables {
    min_scripts_release = "scripts-v2.4.1"
  }

  assert {
    condition     = strcontains(output.validator_env, "TN_FB_MIN_RELEASE='scripts-v2.4.1'\n") && strcontains(output.gateway_env, "TN_FB_MIN_RELEASE='scripts-v2.4.1'\n")
    error_message = "Both env files must carry min_scripts_release as TN_FB_MIN_RELEASE."
  }

  assert {
    condition     = strcontains(output.next_steps, "node scripts scripts-v2.4.1 or newer")
    error_message = "next_steps must name the release each host needs."
  }
}

# The URL shapes first boot takes: a port of five digits and a path with
# : @ , in it.
run "url_shapes_first_boot_takes" {
  command = plan

  variables {
    installer_url        = "https://install.example.org:65535/a"
    redirect_queries_url = "http://rpc.example.org:8545/v1:a@b,c"
  }

  assert {
    condition     = strcontains(output.gateway_env, "TN_FB_INSTALLER_URL='https://install.example.org:65535/a'\n") && strcontains(output.gateway_env, "TN_FB_REDIRECT_QUERIES='http://rpc.example.org:8545/v1:a@b,c'\n")
    error_message = "A URL first boot takes must reach the env file unchanged."
  }
}

run "user_data_shape" {
  command = plan

  assert {
    condition     = startswith(output.validator_user_data, "#cloud-config\n") && startswith(output.gateway_user_data, "#cloud-config\n")
    error_message = "Both user data documents must start with #cloud-config."
  }

  assert {
    condition = join(",", [for f in yamldecode(output.validator_user_data).write_files : "${f.path}:${f.permissions}:${f.encoding}:${f.owner}"]) == join(",", [
      "/usr/local/libexec/telcoin-first-boot/first-boot-lib.sh:0700:gz+b64:root:root",
      "/usr/local/libexec/telcoin-first-boot/first-boot-validator.sh:0700:gz+b64:root:root",
      "/etc/telcoin-first-boot/first-boot.env:0600:b64:root:root",
      "/etc/telcoin-first-boot/trusted-nodes.yaml:0644:b64:root:root",
    ])
    error_message = "The validator's write_files must carry the library and the validator script (0700, gzipped), the env file (0600) and the hubs file, and no gateway script."
  }

  assert {
    condition = join(",", [for f in yamldecode(output.gateway_user_data).write_files : "${f.path}:${f.permissions}:${f.encoding}"]) == join(",", [
      "/usr/local/libexec/telcoin-first-boot/first-boot-lib.sh:0700:gz+b64",
      "/usr/local/libexec/telcoin-first-boot/first-boot-gateway.sh:0700:gz+b64",
      "/etc/telcoin-first-boot/first-boot.env:0600:b64",
    ])
    error_message = "The gateway's write_files must carry the library, the gateway script and the env file, and no validator script or hubs file."
  }

  assert {
    condition     = base64decode(yamldecode(output.validator_user_data).write_files[2].content) == output.validator_env && base64decode(yamldecode(output.gateway_user_data).write_files[2].content) == output.gateway_env
    error_message = "The env file each host gets must be that role's env output."
  }

  assert {
    condition     = base64decode(yamldecode(output.validator_user_data).write_files[3].content) == var.trusted_nodes_content
    error_message = "The hubs file must hold trusted_nodes_content as given."
  }

  assert {
    condition     = yamldecode(output.validator_user_data).write_files[0].content == yamldecode(output.gateway_user_data).write_files[0].content
    error_message = "Both hosts must carry the same library."
  }

  assert {
    condition     = jsonencode(yamldecode(output.validator_user_data).runcmd) == jsonencode([["/usr/local/libexec/telcoin-first-boot/first-boot-validator.sh"]])
    error_message = "The validator's runcmd must run first-boot-validator.sh and nothing else."
  }

  assert {
    condition     = jsonencode(yamldecode(output.gateway_user_data).runcmd) == jsonencode([["/usr/local/libexec/telcoin-first-boot/first-boot-gateway.sh"]])
    error_message = "The gateway's runcmd must run first-boot-gateway.sh and nothing else."
  }
}

run "no_hubs_file" {
  command = plan

  variables {
    trusted_nodes_content = ""
  }

  assert {
    condition     = strcontains(output.validator_env, "TN_FB_TRUSTED_NODES=''\n")
    error_message = "With no hubs map TN_FB_TRUSTED_NODES must be empty."
  }

  assert {
    condition     = length(yamldecode(output.validator_user_data).write_files) == 3
    error_message = "With no hubs map the validator gets no hubs file."
  }
}

# The second apply sets rpc_domain; the validator's user data must not change
# with it, or that apply would plan a change to the validator.
run "validator_without_domain" {
  command = plan

  variables {
    rpc_domain = ""
  }

  assert {
    condition     = output.gateway_env == "" && output.gateway_user_data == "" && output.gateway_user_data_gzip_bytes == 0
    error_message = "Without rpc_domain there is no gateway host, so nothing is rendered for it."
  }
}

run "validator_with_domain" {
  command = plan

  assert {
    condition     = output.validator_user_data == run.validator_without_domain.validator_user_data
    error_message = "The validator's user data must be the same with rpc_domain empty and set."
  }

  assert {
    condition     = output.validator_env == run.validator_without_domain.validator_env
    error_message = "The validator's env must be the same with rpc_domain empty and set."
  }
}

run "mainnet_defaults" {
  command = plan

  variables {
    network                        = "mainnet"
    cloud                          = "gcp"
    gateway_rate_limit_submissions = 0
  }

  assert {
    condition     = strcontains(output.gateway_env, "TN_FB_REDIRECT_QUERIES='https://rpc.telcoin.network'\n") && strcontains(output.gateway_env, "TN_FB_RATE_LIMIT_SUBMISSIONS='0'\n") && strcontains(output.gateway_env, "TN_FB_NETWORK='mainnet'\n")
    error_message = "On mainnet the gateway redirects queries to the mainnet public RPC by default."
  }
}

run "no_gateway" {
  command = plan

  variables {
    role_set           = { validator = true, gateway = false }
    gateway_public_ip  = ""
    gateway_private_ip = ""
  }

  assert {
    condition     = output.gateway_env == "" && output.gateway_user_data == ""
    error_message = "With no gateway nothing is rendered for one."
  }

  assert {
    condition     = output.tao_handoff.ipv4 == null
    error_message = "With no gateway the handoff names no address."
  }
}
