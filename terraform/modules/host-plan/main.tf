locals {
  re = {
    # The characters an env value may hold: first-boot-lib.sh checks the same set.
    env  = "^[A-Za-z0-9._:/,@-]*$"
    ipv4 = "^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$"
    # The ranges setup-gateway.sh takes for --upstream, less link-local.
    private = "^(10\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.|100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.)"
    # The same ranges as a CIDR whose prefix is at least the range's own.
    private_cidr = "^(10\\.[0-9.]+/([89]|[12][0-9]|3[0-2])|172\\.(1[6-9]|2[0-9]|3[01])\\.[0-9.]+/(1[2-9]|2[0-9]|3[0-2])|192\\.168\\.[0-9.]+/(1[6-9]|2[0-9]|3[0-2])|100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.[0-9.]+/(1[0-9]|2[0-9]|3[0-2]))$"
    # first-boot-lib.sh's TN_FB_DOMAIN rule, lowercase: labels that start and
    # end with a letter or digit, and a last label of 2 to 63 letters.
    dns_name = "^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$"
    # What fb_url_ok takes after the scheme: a host that starts and ends with
    # a letter or digit, a port of at most five digits, an optional path.
    url_rest = "://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?(/[A-Za-z0-9._/:@,-]*)?$"
  }

  # Host paths. Every first-boot script finds the others, the env file and the
  # hubs file here.
  libexec_dir = "/usr/local/libexec/telcoin-first-boot"
  env_path    = "/etc/telcoin-first-boot/first-boot.env"
  hubs_path   = "/etc/telcoin-first-boot/trusted-nodes.yaml"
  done_marker = "/var/lib/telcoin-first-boot/done"
  fail_marker = "/var/lib/telcoin-first-boot/failed"
  log_path    = "/var/log/telcoin-first-boot.log"

  first_boot_dir = "${path.module}/../../first-boot"

  # TESTNET_RPC_URL and MAINNET_RPC_URL of lib/common.sh.
  public_rpc_url = {
    testnet = "https://rpc.adiri.tel"
    mainnet = "https://rpc.telcoin.network"
  }

  # Where the installer, run as the login user, puts the scripts.
  scripts_dir          = "/home/${var.login_user}/telcoin-node-scripts"
  redirect_queries_url = var.redirect_queries_url != "" ? var.redirect_queries_url : local.public_rpc_url[var.network]
  hubs_given           = var.trusted_nodes_content != ""
  # The gateway host exists only once its name is chosen.
  gateway_vm = var.role_set.gateway && var.rpc_domain != ""
  # SSH sources for both hosts: the operator's list plus the private network,
  # where a bastion or a tunnel endpoint connects from.
  ssh_from = join(",", concat(var.admin_ssh_cidrs, [var.vpc_cidr]))

  # Ordered key/value pairs, so the files read the same on every apply. The
  # validator's pairs never take rpc_domain: the apply that sets it must leave
  # the validator's user data alone.
  shared_env = [
    ["TN_FB_NETWORK", var.network],
    ["TN_FB_CLOUD", var.cloud],
    ["TN_FB_LOGIN_USER", var.login_user],
    ["TN_FB_INSTALLER_URL", var.installer_url],
    ["TN_FB_MIN_RELEASE", var.min_scripts_release],
  ]
  validator_env_pairs = concat([["TN_FB_ROLE", "validator"]], local.shared_env, [
    ["TN_FB_DATA_DEVICE", var.data_device],
    ["TN_FB_TRUSTED_NODES", local.hubs_given ? local.hubs_path : ""],
  ])
  gateway_env_pairs = concat([["TN_FB_ROLE", "gateway"]], local.shared_env, [
    ["TN_FB_UPSTREAM", var.validator_private_ip],
    ["TN_FB_DOMAIN", var.rpc_domain],
    ["TN_FB_PUBLIC_IP", var.gateway_public_ip],
    ["TN_FB_REDIRECT_QUERIES", local.redirect_queries_url],
    ["TN_FB_RATE_LIMIT_SUBMISSIONS", tostring(var.gateway_rate_limit_submissions)],
    ["TN_FB_SSH_FROM", local.ssh_from],
  ])

  validator_env = join("", [for kv in local.validator_env_pairs : "${kv[0]}='${kv[1]}'\n"])
  gateway_env   = join("", [for kv in local.gateway_env_pairs : "${kv[0]}='${kv[1]}'\n"])

  # Each host carries the library and its own role's script, gzipped: AWS
  # takes 16 KiB of user data, and a root sends this text gzipped again
  # (cloud-init unpacks both layers).
  script_file = { for s in ["first-boot-lib.sh", "first-boot-validator.sh", "first-boot-gateway.sh"] : s => {
    path        = "${local.libexec_dir}/${s}"
    owner       = "root:root"
    permissions = "0700"
    encoding    = "gz+b64"
    content     = base64gzip(file("${local.first_boot_dir}/${s}"))
  } }
  # setup-node.sh wants the hubs map readable by other users; it is public data.
  hubs_file = {
    path        = local.hubs_path
    owner       = "root:root"
    permissions = "0644"
    encoding    = "b64"
    content     = base64encode(var.trusted_nodes_content)
  }

  validator_user_data = join("", ["#cloud-config\n", yamlencode({
    write_files = concat([local.script_file["first-boot-lib.sh"], local.script_file["first-boot-validator.sh"], {
      path        = local.env_path
      owner       = "root:root"
      permissions = "0600"
      encoding    = "b64"
      content     = base64encode(local.validator_env)
    }], local.hubs_given ? [local.hubs_file] : [])
    runcmd = [["${local.libexec_dir}/first-boot-validator.sh"]]
  })])

  gateway_user_data = join("", ["#cloud-config\n", yamlencode({
    write_files = concat([local.script_file["first-boot-lib.sh"], local.script_file["first-boot-gateway.sh"], {
      path        = local.env_path
      owner       = "root:root"
      permissions = "0600"
      encoding    = "b64"
      content     = base64encode(local.gateway_env)
    }])
    runcmd = [["${local.libexec_dir}/first-boot-gateway.sh"]]
  })])

  # Mainnet has one step more up front: installing the binary by hand.
  binary_step = var.network == "mainnet" ? 1 : 0
  next_steps = templatefile("${path.module}/next_steps.tftpl", {
    network           = var.network
    mainnet           = var.network == "mainnet"
    gateway           = var.role_set.gateway
    dir               = local.scripts_dir
    vpub              = var.validator_public_ip
    vpriv             = var.validator_private_ip
    gpub              = var.gateway_public_ip
    gpriv             = var.gateway_private_ip
    ssh_from          = local.ssh_from
    hubs              = local.hubs_path
    hubs_given        = local.hubs_given
    allow_no_tpm      = var.allow_no_tpm
    release_tag       = var.node_release_tag
    min_release       = var.min_scripts_release
    domain            = var.rpc_domain
    session_validator = var.session_commands.validator
    session_gateway   = var.session_commands.gateway
    done_marker       = local.done_marker
    fail_marker       = local.fail_marker
    log_path          = local.log_path
    step = {
      firewall = 2 + local.binary_step
      finalize = 3 + local.binary_step
      upstream = 4 + local.binary_step
      check    = (var.role_set.gateway ? 5 : 4) + local.binary_step
    }
    # The OPERATOR.md placeholders, which setup-node.sh refuses before it
    # changes anything.
    address = var.validator_address != "" ? var.validator_address : (var.network == "mainnet" ? "0xYOUR_VALIDATOR_SAFE" : "0xYOUR_EXECUTION_ADDRESS")
  })

  tao_handoff_note = (
    !var.role_set.gateway ? "This deployment has no worker gateway, so there is no RPC name to publish." :
    var.rpc_domain != "" ? "The A record for ${var.rpc_domain} must point at ${var.gateway_public_ip} before the gateway can get its certificate." :
    var.network == "mainnet" ? "Send the name key generation prints (https://v<label>.telcoin.network/) and this address to the Telcoin Association, or point a name of your own at it, then set rpc_domain and apply again." :
    "Point an A record for a name of your own at this address, then set rpc_domain and apply again."
  )
}
