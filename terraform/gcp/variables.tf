locals {
  re = {
    # 10/8, 172.16/12, 192.168/16 or 100.64/10, with a prefix at least the
    # range's own: setup-gateway.sh takes only a private --upstream.
    private_cidr = "^(10\\.[0-9.]+/([89]|[12][0-9]|3[0-2])|172\\.(1[6-9]|2[0-9]|3[01])\\.[0-9.]+/(1[2-9]|2[0-9]|3[0-2])|192\\.168\\.[0-9.]+/(1[6-9]|2[0-9]|3[0-2])|100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.[0-9.]+/(1[0-9]|2[0-9]|3[0-2]))$"
    ipv4_cidr    = "^[0-9]{1,3}(\\.[0-9]{1,3}){3}/[0-9]{1,2}$"
    # Lowercase, no scheme, path or trailing dot, a last label of letters: the
    # same rule as host-plan.
    host_name = "^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$"
  }

  # The storage minimums of the README's hardware table. The table is in GB
  # and MB/s; these are GiB and MiB/s, the larger units, so meeting them meets
  # the table.
  disk_floor = {
    testnet = { size = 350, iops = 15000, throughput = 240 }
    mainnet = { size = 2000, iops = 20000, throughput = 300 }
  }
  disk_default = {
    testnet = { size = 500, iops = 15000, throughput = 300 }
    mainnet = { size = 2000, iops = 20000, throughput = 300 }
  }
}

# --- Where -------------------------------------------------------------------

variable "project" {
  description = "The Google Cloud project ID the hosts are created in."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project))
    error_message = "project must be a Google Cloud project ID: 6 to 30 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "region" {
  description = "The region of the network, the subnet and the static addresses."
  type        = string
  default     = "us-central1"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z]+(-[a-z]+)+[0-9]+$", var.region))
    error_message = "region must be a Compute Engine region such as us-central1 or europe-west4."
  }
}

variable "zone" {
  description = "The zone both hosts and the data disk are created in. Unset means <region>-a. It must offer the validator's machine type and Hyperdisk Balanced."
  type        = string
  default     = null

  validation {
    condition     = var.zone == null || (can(regex("^[a-z]+(-[a-z]+)+[0-9]+-[a-z]$", var.zone)) && startswith(coalesce(var.zone, "-"), "${var.region}-"))
    error_message = "zone must be a zone of region, such as us-central1-a when region is us-central1."
  }
}

# --- What --------------------------------------------------------------------

variable "network" {
  description = "testnet or mainnet."
  type        = string
  default     = "testnet"
  nullable    = false

  validation {
    condition     = contains(["testnet", "mainnet"], var.network)
    error_message = "network must be testnet or mainnet."
  }
}

variable "name_prefix" {
  description = "Starts the name of every resource, and labels them all as deployment."
  type        = string
  default     = "telcoin"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.name_prefix))
    error_message = "name_prefix must be a lowercase letter followed by 1 to 20 lowercase letters, digits or -."
  }
}

variable "gateway_enabled" {
  description = "Build a worker-gateway host beside the validator. False builds a single node (an observer or an RPC node) with no gateway resources at all."
  type        = bool
  default     = true
  nullable    = false
}

variable "rpc_domain" {
  description = "The public RPC name the worker gateway serves. Empty on the first apply; set it once its A record points at gateway_public_ip and apply again to create the gateway host."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.rpc_domain == "" || (length(var.rpc_domain) <= 253 && can(regex(local.re.host_name, var.rpc_domain)))
    error_message = "rpc_domain must be empty or a lowercase host name of at most 253 characters, such as rpc.example.org, whose last label is 2 to 63 letters: no scheme, no path, no trailing dot, no IP address."
  }

  validation {
    condition     = var.rpc_domain == "" || var.gateway_enabled
    error_message = "rpc_domain names the worker gateway's site, and gateway_enabled = false builds no gateway: leave rpc_domain empty."
  }
}

# --- Admin access ------------------------------------------------------------

variable "admin_ssh_cidrs" {
  description = "IPv4 networks that may reach TCP 22 of both hosts, such as [\"198.51.100.7/32\"]. Empty (the default) opens no public SSH port: admins come in through IAP."
  type        = list(string)
  default     = []
  nullable    = false

  # The network has no IPv6, and a firewall rule takes only a network address,
  # so 198.51.100.7/24 is refused rather than widened silently.
  validation {
    condition     = alltrue([for c in var.admin_ssh_cidrs : can(regex(local.re.ipv4_cidr, c)) && try(cidrhost(c, 0) == split("/", c)[0], false)])
    error_message = "Each admin_ssh_cidrs entry must be an IPv4 network in CIDR form, such as 198.51.100.7/32 or 198.51.100.0/24."
  }
}

variable "enable_iap" {
  description = "Let IAP TCP forwarding reach TCP 22 of both hosts (from 35.235.240.0/20), for gcloud compute ssh --tunnel-through-iap."
  type        = bool
  default     = true
  nullable    = false

  validation {
    condition     = var.enable_iap || length(var.admin_ssh_cidrs) > 0
    error_message = "Set admin_ssh_cidrs, enable_iap = true, or both: otherwise nothing can reach either host's shell."
  }
}

variable "admin_members" {
  description = "IAM members (user:, group:, serviceAccount: or domain:) granted OS Login with sudo and, with enable_iap, the IAP tunnel on both instances, plus serviceAccountUser on the hosts' service account. gcloud compute ssh also needs compute.instances.get and compute.projects.get on the project (roles/compute.viewer has both), which is granted outside this module."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for m in var.admin_members : can(regex("^(user|group|serviceAccount|domain):[^[:space:]]+$", m))])
    error_message = "Each admin_members entry must be an IAM member such as user:ops@example.org or group:validators@example.org."
  }
}

# --- Private network ---------------------------------------------------------

variable "vpc_cidr" {
  description = "The private range the deployment owns, which holds subnet_cidr (a VPC network has no range of its own). The worker gateway's own firewall lets SSH in from it."
  type        = string
  default     = "10.42.0.0/16"
  nullable    = false

  validation {
    condition     = can(regex(local.re.private_cidr, var.vpc_cidr)) && try(cidrhost(var.vpc_cidr, 0) == split("/", var.vpc_cidr)[0], false)
    error_message = "vpc_cidr must be a network inside 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 or 100.64.0.0/10, such as 10.42.0.0/16: the worker gateway's upstream must be a private address."
  }
}

variable "subnet_cidr" {
  description = "The subnet both hosts sit in, inside vpc_cidr. The validator takes its 10th address and the worker gateway its 20th."
  type        = string
  default     = "10.42.1.0/24"
  nullable    = false

  validation {
    condition = can(regex(local.re.private_cidr, var.subnet_cidr)) && try(
      cidrhost(var.subnet_cidr, 0) == split("/", var.subnet_cidr)[0] && tonumber(split("/", var.subnet_cidr)[1]) <= 27,
    false)
    error_message = "subnet_cidr must be a network of /27 or larger inside 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 or 100.64.0.0/10, such as 10.42.1.0/24, so its 10th and 20th addresses are usable."
  }

  validation {
    condition = try(
      tonumber(split("/", var.subnet_cidr)[1]) >= tonumber(split("/", var.vpc_cidr)[1]) &&
      cidrhost("${cidrhost(var.subnet_cidr, 0)}/${split("/", var.vpc_cidr)[1]}", 0) == cidrhost(var.vpc_cidr, 0),
    false)
    error_message = "subnet_cidr must lie inside vpc_cidr."
  }
}

# --- Machines and disks ------------------------------------------------------

variable "validator_instance_type" {
  description = "The validator's machine type, which must support Hyperdisk Balanced. Null means c3-standard-8 on testnet (4 cores, 32 GiB) and c3d-standard-16 on mainnet (8 cores, 64 GiB). Mainnet refuses less than 8 physical cores and 32 GiB, the node scripts' validator floor; the default doubles the memory because a 32 GiB VM reports a little less to the host, which the scripts' hardware check reads as under that floor."
  type        = string
  default     = null

  validation {
    condition     = var.validator_instance_type == null || can(regex("^[a-z][a-z0-9]*-[a-z0-9-]+$", var.validator_instance_type))
    error_message = "validator_instance_type must be null or a machine type such as c3d-standard-16."
  }
}

variable "gateway_instance_type" {
  description = "The worker gateway's machine type. Null means e2-standard-2. Its boot disk is pd-balanced, so the type must take Persistent Disk (C4 and N4 do not)."
  type        = string
  default     = null

  validation {
    condition     = var.gateway_instance_type == null || can(regex("^[a-z][a-z0-9]*-[a-z0-9-]+$", var.gateway_instance_type))
    error_message = "gateway_instance_type must be null or a machine type such as e2-standard-2."
  }
}

variable "data_disk_size_gb" {
  description = "The validator's Hyperdisk Balanced data disk in GiB. Null means 500 on testnet and 2000 on mainnet; the floor is 350 and 2000. A disk can grow later but never shrink."
  type        = number
  default     = null

  validation {
    condition     = var.data_disk_size_gb == null || try(var.data_disk_size_gb >= local.disk_floor[var.network].size && var.data_disk_size_gb <= 65536 && floor(var.data_disk_size_gb) == var.data_disk_size_gb, false)
    error_message = "data_disk_size_gb must be a whole number of GiB from the network's floor (testnet 350, mainnet 2000) to 65536, Hyperdisk Balanced's largest disk."
  }
}

variable "data_disk_iops" {
  description = "The data disk's provisioned IOPS. Null means 15000 on testnet and 20000 on mainnet, which are also the floors."
  type        = number
  default     = null

  # Hyperdisk Balanced provisions at most 160000 IOPS, and 500 per GiB, which
  # the size floor already allows.
  validation {
    condition     = var.data_disk_iops == null || try(var.data_disk_iops >= local.disk_floor[var.network].iops && var.data_disk_iops <= 160000 && floor(var.data_disk_iops) == var.data_disk_iops, false)
    error_message = "data_disk_iops must be a whole number from the network's floor (testnet 15000, mainnet 20000) to 160000, Hyperdisk Balanced's most."
  }
}

variable "data_disk_throughput" {
  description = "The data disk's provisioned throughput in MiB/s. Null means 300; the floor is 240 on testnet and 300 on mainnet."
  type        = number
  default     = null

  # Hyperdisk Balanced provisions at most 2400 MiB/s, and IOPS/4, which the
  # IOPS floor already allows.
  validation {
    condition     = var.data_disk_throughput == null || try(var.data_disk_throughput >= local.disk_floor[var.network].throughput && var.data_disk_throughput <= 2400 && floor(var.data_disk_throughput) == var.data_disk_throughput, false)
    error_message = "data_disk_throughput must be a whole number of MiB/s from the network's floor (testnet 240, mainnet 300) to 2400, Hyperdisk Balanced's most."
  }

  # It also needs at least IOPS/256, which a large data_disk_iops can pass.
  validation {
    condition     = var.data_disk_throughput == null || try(var.data_disk_throughput >= coalesce(var.data_disk_iops, local.disk_default[var.network].iops) / 256, false)
    error_message = "data_disk_throughput must be at least data_disk_iops/256 MiB/s, the least Hyperdisk Balanced allows at that IOPS."
  }
}

variable "disk_kms_key" {
  description = "A Cloud KMS key of your own for every disk: both boot disks and the data disk, as projects/P/locations/L/keyRings/R/cryptoKeys/K. Empty encrypts them with Google's own key. The project's Compute Engine service agent needs roles/cloudkms.cryptoKeyEncrypterDecrypter on it."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.disk_kms_key == "" || can(regex("^projects/[a-z0-9-]+/locations/[a-z0-9-]+/keyRings/[A-Za-z0-9_-]+/cryptoKeys/[A-Za-z0-9_-]+$", var.disk_kms_key))
    error_message = "disk_kms_key must be empty or a Cloud KMS key name, such as projects/my-project/locations/us-central1/keyRings/tn/cryptoKeys/data."
  }
}

# --- Image -------------------------------------------------------------------

variable "ubuntu_version" {
  description = "The Ubuntu Server LTS release both hosts boot: 26.04 (recommended) or 24.04, the mainnet floor."
  type        = string
  default     = "26.04"
  nullable    = false

  validation {
    condition     = contains(["24.04", "26.04"], var.ubuntu_version)
    error_message = "ubuntu_version must be 24.04 or 26.04."
  }
}

# --- Key generation ----------------------------------------------------------

variable "validator_address" {
  description = "The validator's execution address (on mainnet its Safe), filled into the printed key generation command. Empty prints a placeholder."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.validator_address == "" || (can(regex("^0[xX][0-9a-fA-F]{40}$", var.validator_address)) && !can(regex("^0[xX]0{40}$", var.validator_address)))
    error_message = "validator_address must be empty or 0x followed by 40 hex digits, and not the zero address."
  }
}

variable "node_release_tag" {
  description = "The testnet node release the printed key generation installs, such as v0.18.0-adiri. Empty prints a placeholder. Mainnet key generation takes an existing binary and does not use it."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.node_release_tag == "" || can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+(-adiri)?(-rc[0-9]+)?$", var.node_release_tag))
    error_message = "node_release_tag must be empty or a release tag such as v0.18.0-adiri."
  }

  validation {
    condition     = var.node_release_tag == "" || var.network != "testnet" || can(regex("-adiri(-rc[0-9]+)?$", var.node_release_tag))
    error_message = "On testnet node_release_tag must be a testnet release, vX.Y.Z-adiri (or a release candidate, vX.Y.Z-adiri-rcN)."
  }
}

variable "min_scripts_release" {
  description = "The oldest node-scripts release whose setup-gateway.sh, key generation and checks this deployment relies on, such as scripts-v2.3.0. First boot refuses a host whose installed scripts are older."
  type        = string
  default     = "scripts-v2.3.0"
  nullable    = false

  validation {
    condition     = can(regex("^scripts-v[0-9]+\\.[0-9]+\\.[0-9]+$", var.min_scripts_release))
    error_message = "min_scripts_release must be a node-scripts release tag, such as scripts-v2.3.0."
  }
}

variable "trusted_nodes_file" {
  description = "A local path to the trusted hubs map (public data), written to the validator at first boot as /etc/telcoin-first-boot/trusted-nodes.yaml; it travels in the instance metadata. Empty means you copy it to the host yourself; next_steps names the path."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.trusted_nodes_file == "" || try(length(file(var.trusted_nodes_file)) <= 65536, false)
    error_message = "trusted_nodes_file must be empty or a readable text file of at most 64 KiB, the limit setup-node.sh applies to --trusted-nodes."
  }
}

# --- Worker gateway ----------------------------------------------------------

variable "redirect_queries_url" {
  description = "The public RPC the worker gateway sends queries to. Empty means the network's own."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.redirect_queries_url == "" || can(regex("^https?://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?(/[A-Za-z0-9._/:@,-]*)?$", var.redirect_queries_url))
    error_message = "redirect_queries_url must be empty or an http(s):// URL whose host starts and ends with a letter or digit, with a port of at most five digits and a path of letters, digits and . _ / : @ , - only."
  }
}

variable "gateway_rate_limit_submissions" {
  description = "Submissions a second the worker gateway keeps for eth_sendRawTransaction; 0 turns the reservation off."
  type        = number
  default     = 300
  nullable    = false

  validation {
    condition     = var.gateway_rate_limit_submissions >= 0 && var.gateway_rate_limit_submissions <= 999999 && floor(var.gateway_rate_limit_submissions) == var.gateway_rate_limit_submissions
    error_message = "gateway_rate_limit_submissions must be a whole number from 0 to 999999."
  }
}

locals {
  zone       = coalesce(var.zone, "${var.region}-a")
  gateway_vm = var.gateway_enabled && var.rpc_domain != ""

  # Physical cores count (a vCPU is a hyperthread); the mainnet type has twice
  # the memory floor, for the reason validator_instance_type gives.
  validator_type = coalesce(var.validator_instance_type, var.network == "mainnet" ? "c3d-standard-16" : "c3-standard-8")
  gateway_type   = coalesce(var.gateway_instance_type, "e2-standard-2")
  data_disk = {
    size       = coalesce(var.data_disk_size_gb, local.disk_default[var.network].size)
    iops       = coalesce(var.data_disk_iops, local.disk_default[var.network].iops)
    throughput = coalesce(var.data_disk_throughput, local.disk_default[var.network].throughput)
  }
  # Null lets Compute Engine use Google's own key.
  kms_key = var.disk_kms_key != "" ? var.disk_kms_key : null

  boot_disk_gb     = 50
  data_device_name = "tn-data"
  data_device      = "/dev/disk/by-id/google-${local.data_device_name}"
  image_family     = { "24.04" = "ubuntu-2404-lts-amd64", "26.04" = "ubuntu-2604-lts-amd64" }[var.ubuntu_version]
  # cloud-init on Ubuntu's images creates this user before it runs user data.
  login_user = "ubuntu"

  validator_private_ip = cidrhost(var.subnet_cidr, 10)
  gateway_private_ip   = cidrhost(var.subnet_cidr, 20)

  name = {
    validator = "${var.name_prefix}-validator"
    gateway   = "${var.name_prefix}-gateway"
  }
  tag       = local.name
  host_tags = var.gateway_enabled ? [local.tag.validator, local.tag.gateway] : [local.tag.validator]
  iap_range = "35.235.240.0/20"

  # Compute Engine's limit for one metadata value (256 KB).
  metadata_value_limit = 262144

  trusted_nodes_content = var.trusted_nodes_file != "" ? file(var.trusted_nodes_file) : ""

  session_flags = "--project ${var.project} --zone ${local.zone}${var.enable_iap ? " --tunnel-through-iap" : ""}"
  session_commands = {
    validator = "gcloud compute ssh ${local.name.validator} ${local.session_flags}"
    gateway   = local.gateway_vm ? "gcloud compute ssh ${local.name.gateway} ${local.session_flags}" : ""
  }
}
