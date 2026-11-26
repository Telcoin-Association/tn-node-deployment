locals {
  re = {
    # 10/8, 172.16/12, 192.168/16 or 100.64/10, with a prefix at least the
    # range's own: setup-gateway.sh takes only a private --upstream.
    private_cidr = "^(10\\.[0-9.]+/([89]|[12][0-9]|3[0-2])|172\\.(1[6-9]|2[0-9]|3[01])\\.[0-9.]+/(1[2-9]|2[0-9]|3[0-2])|192\\.168\\.[0-9.]+/(1[6-9]|2[0-9]|3[0-2])|100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.[0-9.]+/(1[0-9]|2[0-9]|3[0-2]))$"
    ipv4_cidr    = "^[0-9]{1,3}(\\.[0-9]{1,3}){3}/[1-9][0-9]?$"
    # host-plan's rules, which are first boot's. A lowercase name of two labels
    # or more with a letter in the last (host_tld): no scheme, path or trailing
    # dot. A URL as fb_url_ok takes it, its port at most 65535 (url_port). A
    # release as fb_release_num reads it.
    host_name = "^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$"
    host_tld  = "[a-z][a-z0-9-]*$"
    url       = "^https?://[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*(:[1-9][0-9]{0,4})?(/[A-Za-z0-9._/-]*)?$"
    url_port  = ":([0-9]+)(/|$)"
    release   = "^scripts-v(0|[1-9][0-9]{0,3})\\.(0|[1-9][0-9]{0,3})\\.(0|[1-9][0-9]{0,3})$"
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

variable "region" {
  description = "The AWS region both hosts run in, such as eu-central-1."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", var.region))
    error_message = "region must be an AWS region name, such as eu-central-1."
  }
}

variable "availability_zone" {
  description = "The zone of region both hosts and the data volume sit in, such as eu-central-1a; it must offer the validator's and the gateway's instance types. Given once and kept: the subnet and the data volume cannot move to another zone, so a zone worked out again on a later plan could only plan their replacement."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^${var.region}[a-z]$", var.availability_zone))
    error_message = "availability_zone must be a zone of region, such as eu-central-1a."
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
  description = "Starts the name of every resource, and tags them all as Deployment."
  type        = string
  default     = "telcoin"
  nullable    = false

  # AWS refuses a security group name that starts with sg-.
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.name_prefix)) && !startswith(var.name_prefix, "sg-")
    error_message = "name_prefix must be a lowercase letter followed by 1 to 20 lowercase letters, digits or -, and must not start with sg-."
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
    condition     = var.rpc_domain == "" || (length(var.rpc_domain) <= 253 && can(regex(local.re.host_name, var.rpc_domain)) && can(regex(local.re.host_tld, var.rpc_domain)))
    error_message = "rpc_domain must be empty or a lowercase host name of at most 253 characters, such as rpc.example.org: two labels or more of letters, digits and inner dashes, with a letter in the last (rpc.example.xn--p1ai is one). No scheme, no path, no trailing dot, no IP address."
  }

  validation {
    condition     = var.rpc_domain == "" || var.gateway_enabled
    error_message = "rpc_domain names the worker gateway's site, and gateway_enabled = false builds no gateway: leave rpc_domain empty."
  }
}

# --- Admin access ------------------------------------------------------------

variable "admin_ssh_cidrs" {
  description = "IPv4 networks that may reach TCP 22 of both hosts, such as [\"198.51.100.7/32\"], each /8 or narrower: SSH from anywhere is not offered. Empty (the default) opens no public SSH port: Session Manager needs none."
  type        = list(string)
  default     = []
  nullable    = false

  # The network has no IPv6, and a firewall rule takes only a network address,
  # so 198.51.100.7/24 is refused rather than widened silently. The prefix is
  # /8 or narrower and the address never 0.0.0.0, as first boot and
  # firewall-setup.sh take an SSH source.
  validation {
    condition     = alltrue([for c in var.admin_ssh_cidrs : can(regex(local.re.ipv4_cidr, c)) && try(cidrhost(c, 0) == split("/", c)[0] && tonumber(split("/", c)[1]) >= 8 && split("/", c)[0] != "0.0.0.0", false)])
    error_message = "Each admin_ssh_cidrs entry must be an IPv4 network in CIDR form, such as 198.51.100.7/32 or 198.51.100.0/24: the sources SSH is opened to must be /8 or narrower, and never 0.0.0.0, so SSH from anywhere is not offered."
  }
}

# --- Private network ---------------------------------------------------------

variable "vpc_cidr" {
  description = "The VPC's private range, which holds subnet_cidr. The worker gateway's own firewall lets SSH in from it."
  type        = string
  default     = "10.42.0.0/16"
  nullable    = false

  # AWS takes a VPC from /16 to /28; the subnet needs a /27 at least.
  validation {
    condition = can(regex(local.re.private_cidr, var.vpc_cidr)) && try(
      cidrhost(var.vpc_cidr, 0) == split("/", var.vpc_cidr)[0] && tonumber(split("/", var.vpc_cidr)[1]) >= 16 && tonumber(split("/", var.vpc_cidr)[1]) <= 27,
    false)
    error_message = "vpc_cidr must be a network from /16 to /27 inside 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 or 100.64.0.0/10, such as 10.42.0.0/16: the worker gateway's upstream must be a private address."
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
  description = "The validator's EC2 type, an x86_64 Nitro type. Null means m7i.2xlarge on testnet (4 cores, 32 GiB) and m7i.4xlarge on mainnet (8 cores, 64 GiB). Mainnet refuses a type with fewer than 8 physical cores or less than 32 GiB nominal, the node scripts' validator floor. The default has 64 GiB because the host reads a 32 GiB machine as 31 GiB, and the scripts' hardware check then warns."
  type        = string
  default     = null

  validation {
    condition     = var.validator_instance_type == null || can(regex("^[a-z][a-z0-9-]*\\.[a-z0-9-]+$", var.validator_instance_type))
    error_message = "validator_instance_type must be null or an EC2 instance type such as m7i.4xlarge."
  }
}

variable "gateway_instance_type" {
  description = "The worker gateway's EC2 type, x86_64. Null means m7i.large."
  type        = string
  default     = null

  validation {
    condition     = var.gateway_instance_type == null || can(regex("^[a-z][a-z0-9-]*\\.[a-z0-9-]+$", var.gateway_instance_type))
    error_message = "gateway_instance_type must be null or an EC2 instance type such as m7i.large."
  }
}

variable "data_disk_size_gb" {
  description = "The validator's gp3 data volume in GiB. Null means 500 on testnet and 2000 on mainnet; the floor is 350 and 2000. A volume can grow later but never shrink."
  type        = number
  default     = null

  validation {
    condition     = var.data_disk_size_gb == null || try(var.data_disk_size_gb >= local.disk_floor[var.network].size && var.data_disk_size_gb <= 65536 && floor(var.data_disk_size_gb) == var.data_disk_size_gb, false)
    error_message = "data_disk_size_gb must be a whole number of GiB from the network's floor (testnet 350, mainnet 2000) to 65536, gp3's largest volume."
  }
}

variable "data_disk_iops" {
  description = "The data volume's provisioned IOPS. Null means 15000 on testnet and 20000 on mainnet, which are also the floors."
  type        = number
  default     = null

  # gp3 provisions at most 80000 IOPS, and 500 per GiB, which the size floor
  # already allows.
  validation {
    condition     = var.data_disk_iops == null || try(var.data_disk_iops >= local.disk_floor[var.network].iops && var.data_disk_iops <= 80000 && floor(var.data_disk_iops) == var.data_disk_iops, false)
    error_message = "data_disk_iops must be a whole number from the network's floor (testnet 15000, mainnet 20000) to 80000, gp3's most."
  }
}

variable "data_disk_throughput" {
  description = "The data volume's provisioned throughput in MiB/s. Null means 300; the floor is 240 on testnet and 300 on mainnet."
  type        = number
  default     = null

  # gp3 provisions at most 2000 MiB/s, and 0.25 MiB/s per IOPS, which the
  # IOPS floor already allows.
  validation {
    condition     = var.data_disk_throughput == null || try(var.data_disk_throughput >= local.disk_floor[var.network].throughput && var.data_disk_throughput <= 2000 && floor(var.data_disk_throughput) == var.data_disk_throughput, false)
    error_message = "data_disk_throughput must be a whole number of MiB/s from the network's floor (testnet 240, mainnet 300) to 2000, gp3's most."
  }
}

variable "disk_kms_key" {
  description = "The ARN of a KMS key of your own for every volume: both root volumes and the data volume. Empty encrypts them with the account's AWS managed EBS key. Honoured at the first apply only: a later change would replace the data volume and the validator, whose root volume holds the stored passphrase credential, so the plan stops on their prevent_destroy."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.disk_kms_key == "" || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", var.disk_kms_key))
    error_message = "disk_kms_key must be empty or a KMS key ARN, such as arn:aws:kms:eu-central-1:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab (not an alias)."
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

variable "ami_id" {
  description = "An amd64 Ubuntu image to boot instead of Canonical's current one, such as a copy registered with NitroTPM support. Empty reads Canonical's public SSM parameter for ubuntu_version."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.ami_id == "" || can(regex("^ami-([0-9a-f]{8}|[0-9a-f]{17})$", var.ami_id))
    error_message = "ami_id must be empty or an AMI ID such as ami-0123456789abcdef0."
  }
}

# The GCP and Azure roots turn a vTPM on for every host and have no such
# input. Here the image or the instance type may lack NitroTPM.
variable "allow_no_tpm" {
  description = "Accept a mainnet host whose image or instance type has no NitroTPM: key generation then gets --allow-no-tpm and keeps the passphrase credential encrypted with the host key alone."
  type        = bool
  default     = false
  nullable    = false
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
    condition     = can(regex(local.re.release, var.min_scripts_release))
    error_message = "min_scripts_release must be a node-scripts release tag, such as scripts-v2.3.0: each part 0 or a number of up to four digits with no leading zero."
  }
}

variable "trusted_nodes_file" {
  description = "A local path to the trusted hubs map (public data), written to the validator at first boot as /etc/telcoin-first-boot/trusted-nodes.yaml; it travels in the instance user data. Empty means you copy it to the host yourself; next_steps names the path."
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
    condition     = var.redirect_queries_url == "" || (can(regex(local.re.url, var.redirect_queries_url)) && alltrue([for p in regexall(local.re.url_port, var.redirect_queries_url) : tonumber(p[0]) <= 65535]))
    error_message = "redirect_queries_url must be empty or an http(s):// URL whose host is labels of letters, digits and inner dashes joined by single dots, with a port from 1 to 65535 and no leading zero, and a path of letters, digits and . _ / - only."
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
