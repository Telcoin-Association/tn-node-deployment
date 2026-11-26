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

variable "name_prefix" {
  description = "Starts the name of every resource, and labels them all as deployment=<name_prefix>."
  type        = string
  default     = "telcoin"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.name_prefix))
    error_message = "name_prefix must be 2 to 21 characters: a lowercase letter, then lowercase letters, digits or hyphens."
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

variable "gateway_enabled" {
  description = "Build a worker-gateway host next to the validator. false builds the validator alone, with no gateway address, rule or host."
  type        = bool
  default     = true
  nullable    = false
}

variable "rpc_domain" {
  description = "The public RPC name the worker gateway serves. Empty until it is chosen: the gateway host is created by the apply that sets it, once its A record points at gateway_public_ip."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.rpc_domain == "" || (length(var.rpc_domain) <= 253 && can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$", var.rpc_domain)))
    error_message = "rpc_domain must be empty or a lowercase host name such as rpc.example.org: no scheme, no path, no trailing dot, no IP address."
  }
}

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
  description = "The testnet node release the printed key generation installs, such as v0.18.0-adiri. Empty prints a placeholder."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.node_release_tag == "" || can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+(-adiri)?(-rc[0-9]+)?$", var.node_release_tag))
    error_message = "node_release_tag must be empty or a release tag such as v0.18.0-adiri."
  }
}

variable "trusted_nodes_file" {
  description = "A trusted hubs map on the machine running Terraform, written to the validator at /etc/telcoin-first-boot/trusted-nodes.yaml. It is public data and ends up in instance metadata. Empty means copying the file to the host by hand."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.trusted_nodes_file == "" || try(length(file(var.trusted_nodes_file)) <= 65536, false)
    error_message = "trusted_nodes_file must be empty or name a readable text file of at most 64 KiB."
  }
}

variable "allow_no_tpm" {
  description = "Print --allow-no-tpm in the key generation command. Both hosts have a vTPM (Shielded VM), so this is for a host where it cannot be used."
  type        = bool
  default     = false
  nullable    = false
}

# --- Worker gateway ----------------------------------------------------------

variable "redirect_queries_url" {
  description = "The public RPC the worker gateway sends queries to. Empty means the network's own."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.redirect_queries_url == "" || can(regex("^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._/-]*)?$", var.redirect_queries_url))
    error_message = "redirect_queries_url must be empty or an http(s):// URL of letters, digits and . _ / - only."
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

# --- Network and access ------------------------------------------------------

variable "vpc_cidr" {
  description = "The private range the deployment owns. The subnet sits inside it, and both hosts' own firewalls let SSH in from it."
  type        = string
  default     = "10.42.0.0/16"
  nullable    = false

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && can(regex(local.re_private_cidr, var.vpc_cidr))
    error_message = "vpc_cidr must be a CIDR inside 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 or 100.64.0.0/10: the worker gateway's upstream must be a private address."
  }
}

variable "subnet_cidr" {
  description = "The subnet both hosts sit in. The validator takes its 10th address and the worker gateway its 20th."
  type        = string
  default     = "10.42.1.0/24"
  nullable    = false

  validation {
    condition     = can(cidrhost(var.subnet_cidr, 0)) && can(regex(local.re_private_cidr, var.subnet_cidr))
    error_message = "subnet_cidr must be a CIDR inside 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 or 100.64.0.0/10: the worker gateway's upstream must be a private address."
  }

  validation {
    condition     = try(cidrhost(var.subnet_cidr, 0) == split("/", var.subnet_cidr)[0] && tonumber(split("/", var.subnet_cidr)[1]) <= 27, false)
    error_message = "subnet_cidr must start at its network address (10.42.1.0/24, not 10.42.1.5/24) and be a /27 or larger, so its 10th and 20th addresses are usable."
  }

  validation {
    condition = try(
      tonumber(split("/", var.subnet_cidr)[1]) >= tonumber(split("/", var.vpc_cidr)[1]) &&
      cidrhost("${split("/", var.subnet_cidr)[0]}/${split("/", var.vpc_cidr)[1]}", 0) == cidrhost(var.vpc_cidr, 0),
    false)
    error_message = "subnet_cidr must lie inside vpc_cidr."
  }
}

variable "admin_ssh_cidrs" {
  description = "Addresses that may reach TCP 22 of both hosts directly, as CIDRs. Empty opens no public SSH: admins come in through IAP."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for c in var.admin_ssh_cidrs : can(cidrhost(c, 0)) && can(regex("^[0-9a-fA-F.:]+/[0-9]{1,3}$", c))])
    error_message = "Each admin_ssh_cidrs entry must be a CIDR, such as 198.51.100.7/32."
  }
}

variable "enable_iap" {
  description = "Let IAP TCP forwarding reach TCP 22 of both hosts (from 35.235.240.0/20), for gcloud compute ssh --tunnel-through-iap."
  type        = bool
  default     = true
  nullable    = false

  validation {
    condition     = var.enable_iap || length(var.admin_ssh_cidrs) > 0
    error_message = "With enable_iap false, admin_ssh_cidrs must list at least one CIDR: otherwise nothing can reach TCP 22 of either host."
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

# --- Machines and disks ------------------------------------------------------

variable "validator_instance_type" {
  description = "The validator's machine type. Unset means c3-standard-8 (4 cores, 32 GB) on testnet and c3d-standard-16 (8 cores, 64 GB) on mainnet. It must support Hyperdisk Balanced."
  type        = string
  default     = null

  validation {
    condition     = var.validator_instance_type == null || can(regex("^[a-z][a-z0-9]*-[a-z0-9-]+$", coalesce(var.validator_instance_type, "-")))
    error_message = "validator_instance_type must be a machine type name such as c3-standard-8."
  }
}

variable "gateway_instance_type" {
  description = "The worker gateway's machine type. Unset means e2-standard-2. Its boot disk is pd-balanced, so the type must take Persistent Disk (C4 and N4 do not)."
  type        = string
  default     = null

  validation {
    condition     = var.gateway_instance_type == null || can(regex("^[a-z][a-z0-9]*-[a-z0-9-]+$", coalesce(var.gateway_instance_type, "-")))
    error_message = "gateway_instance_type must be a machine type name such as e2-standard-2."
  }
}

variable "ubuntu_version" {
  description = "The Ubuntu LTS release both hosts boot: 24.04 or 26.04."
  type        = string
  default     = "26.04"
  nullable    = false

  validation {
    condition     = contains(["24.04", "26.04"], var.ubuntu_version)
    error_message = "ubuntu_version must be 24.04 or 26.04."
  }
}

variable "data_disk_size_gb" {
  description = "The validator's data disk in GiB. Unset means 500 on testnet and 2000 on mainnet, which are also the floors."
  type        = number
  default     = null

  validation {
    condition     = var.data_disk_size_gb == null || try(floor(var.data_disk_size_gb) == var.data_disk_size_gb && var.data_disk_size_gb >= local.net.disk_gb && var.data_disk_size_gb <= 65536, false)
    error_message = "data_disk_size_gb must be a whole number of GiB from ${local.net.disk_gb} (the ${var.network} floor) to 65536."
  }
}

variable "data_disk_iops" {
  description = "The data disk's provisioned IOPS. Unset means 15000 on testnet and 20000 on mainnet, which are also the floors."
  type        = number
  default     = null

  validation {
    condition     = var.data_disk_iops == null || try(floor(var.data_disk_iops) == var.data_disk_iops && var.data_disk_iops >= local.net.iops, false)
    error_message = "data_disk_iops must be a whole number of at least ${local.net.iops}, the ${var.network} floor."
  }

  # Hyperdisk Balanced allows 500 IOPS per GiB, up to 160000.
  validation {
    condition     = var.data_disk_iops == null || try(var.data_disk_iops <= min(500 * coalesce(var.data_disk_size_gb, local.net.disk_gb), 160000), false)
    error_message = "data_disk_iops must be at most 500 per GiB of data_disk_size_gb and at most 160000, the Hyperdisk Balanced limits."
  }
}

variable "data_disk_throughput" {
  description = "The data disk's provisioned throughput in MiB/s. Unset means 240 on testnet and 300 on mainnet, which are also the floors."
  type        = number
  default     = null

  validation {
    condition     = var.data_disk_throughput == null || try(floor(var.data_disk_throughput) == var.data_disk_throughput && var.data_disk_throughput >= local.net.throughput, false)
    error_message = "data_disk_throughput must be a whole number of MiB/s of at least ${local.net.throughput}, the ${var.network} floor."
  }

  # Hyperdisk Balanced allows from IOPS/256 to IOPS/4 MiB/s, at most 2400.
  validation {
    condition     = var.data_disk_throughput == null || try(var.data_disk_throughput <= min(coalesce(var.data_disk_iops, local.net.iops) / 4, 2400) && var.data_disk_throughput >= coalesce(var.data_disk_iops, local.net.iops) / 256, false)
    error_message = "data_disk_throughput must be between data_disk_iops/256 and data_disk_iops/4 MiB/s, and at most 2400, the Hyperdisk Balanced limits."
  }
}

variable "data_disk_kms_key" {
  description = "A Cloud KMS key to encrypt the data disk with, as projects/P/locations/L/keyRings/R/cryptoKeys/K. Empty uses Google's key. The project's Compute Engine service agent needs roles/cloudkms.cryptoKeyEncrypterDecrypter on it."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.data_disk_kms_key == "" || can(regex("^projects/[a-z0-9-]+/locations/[a-z0-9-]+/keyRings/[A-Za-z0-9_-]+/cryptoKeys/[A-Za-z0-9_-]+$", var.data_disk_kms_key))
    error_message = "data_disk_kms_key must be empty or a key name such as projects/my-project/locations/us-central1/keyRings/tn/cryptoKeys/data."
  }
}

locals {
  # The ranges setup-gateway.sh takes for --upstream, as a CIDR whose prefix is
  # at least the range's own (the same rule as modules/host-plan).
  re_private_cidr = "^(10\\.[0-9.]+/([89]|[12][0-9]|3[0-2])|172\\.(1[6-9]|2[0-9]|3[01])\\.[0-9.]+/(1[2-9]|2[0-9]|3[0-2])|192\\.168\\.[0-9.]+/(1[6-9]|2[0-9]|3[0-2])|100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.[0-9.]+/(1[0-9]|2[0-9]|3[0-2]))$"

  zone       = coalesce(var.zone, "${var.region}-a")
  gateway_vm = var.gateway_enabled && var.rpc_domain != ""

  # Physical cores count (a vCPU is a hyperthread), and memory is twice the
  # scripts' floor so the rounded MemTotal clears it with room to spare.
  validator_default = {
    testnet = { type = "c3-standard-8", disk_gb = 500, iops = 15000, throughput = 240 }
    mainnet = { type = "c3d-standard-16", disk_gb = 2000, iops = 20000, throughput = 300 }
  }
  # An unknown network has already failed its own validation; the stricter
  # floors keep the other validations from failing on the lookup.
  net = lookup(local.validator_default, var.network, local.validator_default.mainnet)

  validator_type = coalesce(var.validator_instance_type, local.net.type)
  gateway_type   = coalesce(var.gateway_instance_type, "e2-standard-2")
  data_disk = {
    size       = coalesce(var.data_disk_size_gb, local.net.disk_gb)
    iops       = coalesce(var.data_disk_iops, local.net.iops)
    throughput = coalesce(var.data_disk_throughput, local.net.throughput)
  }
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
