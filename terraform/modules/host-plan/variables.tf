# Every value that reaches an env file is held to local.re.env, the characters
# the first-boot scripts take without quoting: they check each value again
# before they change anything, so the two rules must agree.

variable "role_set" {
  description = "The hosts this deployment builds: validator is always true; gateway is true when a worker-gateway host belongs to it."
  type = object({
    validator = bool
    gateway   = bool
  })

  validation {
    condition     = var.role_set.validator
    error_message = "role_set.validator must be true: every deployment has a validator host."
  }
}

variable "network" {
  description = "testnet or mainnet."
  type        = string

  validation {
    condition     = contains(["testnet", "mainnet"], var.network)
    error_message = "network must be testnet or mainnet."
  }
}

variable "cloud" {
  description = "The cloud the hosts run in: aws, gcp or azure."
  type        = string

  validation {
    condition     = contains(["aws", "gcp", "azure"], var.cloud)
    error_message = "cloud must be aws, gcp or azure."
  }
}

variable "login_user" {
  description = "The image's login user, who runs the installer and owns the scripts (ubuntu on AWS and GCP, the admin user on Azure)."
  type        = string

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.login_user))
    error_message = "login_user must be a Linux user name: a lowercase letter or _, then up to 31 lowercase letters, digits, _ or -."
  }
}

variable "installer_url" {
  description = "Where first boot fetches the script installer."
  type        = string
  default     = "https://install.telcoin.network"
  nullable    = false

  validation {
    condition     = can(regex("^https${local.re.url_rest}", var.installer_url))
    error_message = "installer_url must be an https:// URL whose host starts and ends with a letter or digit, with a port of at most five digits and a path of letters, digits and . _ / : @ , - only."
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

variable "validator_public_ip" {
  description = "The validator's static public IPv4, which peers dial for P2P."
  type        = string

  validation {
    condition     = can(regex(local.re.ipv4, var.validator_public_ip))
    error_message = "validator_public_ip must be an IPv4 address, such as 203.0.113.10."
  }
}

variable "validator_private_ip" {
  description = "The validator's fixed private IPv4, which the node listens on and the worker gateway connects to."
  type        = string

  validation {
    condition     = can(regex(local.re.ipv4, var.validator_private_ip)) && can(regex(local.re.private, var.validator_private_ip))
    error_message = "validator_private_ip must be a private IPv4 address (10/8, 172.16/12, 192.168/16 or 100.64/10): a worker gateway's upstream is never a public address."
  }
}

variable "gateway_public_ip" {
  description = "The worker gateway's static public IPv4, which the RPC name's A record points at. Empty when the deployment has no gateway."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.gateway_public_ip == "" || can(regex(local.re.ipv4, var.gateway_public_ip))
    error_message = "gateway_public_ip must be an IPv4 address, or empty."
  }

  validation {
    condition     = !var.role_set.gateway || var.gateway_public_ip != ""
    error_message = "gateway_public_ip is required when role_set.gateway is true."
  }
}

variable "gateway_private_ip" {
  description = "The worker gateway's fixed private IPv4, the only source the validator's RPC and health port admit. Empty when the deployment has no gateway."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.gateway_private_ip == "" || (can(regex(local.re.ipv4, var.gateway_private_ip)) && can(regex(local.re.private, var.gateway_private_ip)))
    error_message = "gateway_private_ip must be a private IPv4 address (10/8, 172.16/12, 192.168/16 or 100.64/10), or empty."
  }

  validation {
    condition     = !var.role_set.gateway || var.gateway_private_ip != ""
    error_message = "gateway_private_ip is required when role_set.gateway is true."
  }

  validation {
    condition     = var.gateway_private_ip != var.validator_private_ip
    error_message = "gateway_private_ip must differ from validator_private_ip: the worker gateway runs on a host of its own."
  }
}

variable "vpc_cidr" {
  description = "The private network both hosts sit in. First boot lets SSH in from it, for a bastion or a tunnel inside the network."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && can(regex(local.re.private_cidr, var.vpc_cidr))
    error_message = "vpc_cidr must be a CIDR inside 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 or 100.64.0.0/10, such as 10.42.0.0/16."
  }
}

variable "admin_ssh_cidrs" {
  description = "Addresses that may reach TCP 22 of both hosts, as CIDRs. Empty keeps SSH to the private network."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for c in var.admin_ssh_cidrs : can(cidrhost(c, 0)) && can(regex("^[0-9a-fA-F.:]+/[0-9]{1,3}$", c))])
    error_message = "Each admin_ssh_cidrs entry must be a CIDR, such as 198.51.100.7/32."
  }
}

variable "rpc_domain" {
  description = "The public RPC name the worker gateway serves, or empty until it is chosen. Never read by the validator's first boot."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.rpc_domain == "" || (length(var.rpc_domain) <= 253 && can(regex(local.re.dns_name, var.rpc_domain)))
    error_message = "rpc_domain must be empty or a lowercase host name of at most 253 characters, such as rpc.example.org, whose last label is 2 to 63 letters: no scheme, no path, no trailing dot, no IP address."
  }
}

variable "data_device" {
  description = "The stable device path of the validator's data disk, such as /dev/disk/by-id/google-tn-data."
  type        = string

  validation {
    condition     = can(regex("^/dev/[A-Za-z0-9._:/,@-]+$", var.data_device))
    error_message = "data_device must be a path under /dev/ of letters, digits and . _ : / , @ - only."
  }
}

variable "trusted_nodes_content" {
  description = "The trusted hubs map, written to the validator host at first boot. Empty when the operator copies it there by hand."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = length(var.trusted_nodes_content) <= 65536
    error_message = "trusted_nodes_content must be at most 64 KiB, the limit setup-node.sh applies to --trusted-nodes."
  }
}

variable "redirect_queries_url" {
  description = "The public RPC the worker gateway sends queries to. Empty means the network's own (local.public_rpc_url)."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.redirect_queries_url == "" || can(regex("^https?${local.re.url_rest}", var.redirect_queries_url))
    error_message = "redirect_queries_url must be empty or an http(s):// URL whose host starts and ends with a letter or digit, with a port of at most five digits and a path of letters, digits and . _ / : @ , - only."
  }
}

variable "gateway_rate_limit_submissions" {
  description = "Submissions a second the worker gateway keeps for eth_sendRawTransaction (setup-gateway.sh --rate-limit-submissions); 0 turns the reservation off."
  type        = number
  default     = 300
  nullable    = false

  validation {
    condition     = var.gateway_rate_limit_submissions >= 0 && var.gateway_rate_limit_submissions <= 999999 && floor(var.gateway_rate_limit_submissions) == var.gateway_rate_limit_submissions
    error_message = "gateway_rate_limit_submissions must be a whole number from 0 to 999999."
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

variable "allow_no_tpm" {
  description = "Print --allow-no-tpm in the key generation command, for a mainnet host with no usable TPM2."
  type        = bool
  default     = false
  nullable    = false
}

variable "session_commands" {
  description = "How the operator opens a shell on each host (an SSM, IAP or Bastion command, or plain ssh), printed in next_steps. Empty leaves the line out."
  type = object({
    validator = string
    gateway   = string
  })
}

variable "node_release_tag" {
  description = "The testnet node release the printed key generation installs, such as v0.18.0-adiri. Empty prints a placeholder to replace. Mainnet key generation takes an existing binary and does not use it."
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
