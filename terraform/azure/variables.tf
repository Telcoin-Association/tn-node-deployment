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
  # and MB/s; the sizes here are GiB, the larger unit, so meeting them meets
  # the table, and Premium SSD v2 takes MB/s, the table's own unit.
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

variable "subscription_id" {
  description = "The Azure subscription to deploy into. Null reads ARM_SUBSCRIPTION_ID."
  type        = string
  default     = null

  validation {
    condition     = var.subscription_id == null || can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a subscription ID (a GUID), or null."
  }
}

variable "location" {
  description = "The Azure region. It must offer zonal Premium SSD v2 disks (see the region list in Azure's Premium SSD v2 documentation)."
  type        = string
  default     = "eastus2"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9]+$", var.location))
    error_message = "location must be a region name such as eastus2: lowercase letters and digits."
  }
}

variable "zone" {
  description = "The availability zone of both hosts, the data disk and the static IPs."
  type        = string
  default     = "1"
  nullable    = false

  validation {
    condition     = contains(["1", "2", "3"], var.zone)
    error_message = "zone must be 1, 2 or 3."
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
  description = "Starts the name of every resource, and tags them all as deployment."
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
  description = "IPv4 networks that may reach TCP 22 of both hosts, such as [\"198.51.100.7/32\"], each /8 or narrower: SSH from anywhere is not offered. Empty (the default) opens no public SSH port: admins come in through Azure Bastion."
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

variable "admin_ssh_public_key" {
  description = "The operator's SSH public key (ssh-ed25519, or ssh-rsa of at least 2048 bits), installed for admin_username on both hosts. A later change replaces the gateway and is ignored on the validator: a new key would replace that VM, whose root disk holds the stored passphrase credential, so its key is rotated on the host."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^(ssh-ed25519 AAAAC3NzaC1lZDI1NTE5|ssh-rsa AAAAB3NzaC1yc2E)[A-Za-z0-9+/]+={0,2}( [^\\n]*)?$", trimspace(var.admin_ssh_public_key)))
    error_message = "admin_ssh_public_key must be one ssh-ed25519 or ssh-rsa public key line, such as the content of ~/.ssh/id_ed25519.pub. Azure takes no other key type."
  }
}

variable "admin_username" {
  description = "The admin user Azure creates on both hosts at first boot: the login user, who runs the installer and owns the scripts. Never telcoin, the node's service account."
  type        = string
  default     = "ubuntu"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.admin_username))
    error_message = "admin_username must be a Linux user name: a lowercase letter or _, then up to 31 lowercase letters, digits, _ or -."
  }

  # telcoin and telcoin-ui are the node's and the UI's service accounts, which
  # setup-node.sh refuses to share with a login user.
  validation {
    condition = !contains([
      "telcoin", "telcoin-ui", "root",
      "administrator", "admin", "user", "user1", "test", "user2", "test1", "user3", "admin1", "1", "123", "a",
      "actuser", "adm", "admin2", "aspnet", "backup", "console", "david", "guest", "john", "owner", "server",
      "sql", "support", "support_388945a0", "sys", "test2", "test3", "user4", "user5",
    ], var.admin_username)
    error_message = "admin_username must not be telcoin or telcoin-ui, the node's and the UI's service accounts, which setup-node.sh refuses to share with a login user; nor root or a name Azure reserves, such as admin or user."
  }
}

variable "enable_bastion" {
  description = "Build Azure Bastion (Standard SKU, native-client tunnelling) for az network bastion ssh to both hosts."
  type        = bool
  default     = false
  nullable    = false

  validation {
    condition     = var.enable_bastion || length(var.admin_ssh_cidrs) > 0
    error_message = "Set admin_ssh_cidrs, enable_bastion = true, or both: otherwise nothing can reach either host's shell."
  }
}

# --- Private network ---------------------------------------------------------

variable "vpc_cidr" {
  description = "The virtual network's private address space, which holds subnet_cidr and, with enable_bastion, bastion_subnet_cidr. The worker gateway's own firewall lets SSH in from it."
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

variable "bastion_subnet_cidr" {
  description = "AzureBastionSubnet, used when enable_bastion is true: /26 or larger, inside vpc_cidr, apart from subnet_cidr."
  type        = string
  default     = "10.42.2.0/26"
  nullable    = false

  validation {
    condition = !var.enable_bastion || try(
      tonumber(split("/", var.bastion_subnet_cidr)[1]) <= 26 &&
      tonumber(split("/", var.bastion_subnet_cidr)[1]) >= tonumber(split("/", var.vpc_cidr)[1]) &&
      cidrhost("${split("/", var.bastion_subnet_cidr)[0]}/${split("/", var.vpc_cidr)[1]}", 0) == cidrhost(var.vpc_cidr, 0) &&
      # Apart from the hosts' subnet: neither holds the other's first address.
      cidrhost("${split("/", var.bastion_subnet_cidr)[0]}/${split("/", var.subnet_cidr)[1]}", 0) != cidrhost(var.subnet_cidr, 0) &&
      cidrhost("${split("/", var.subnet_cidr)[0]}/${split("/", var.bastion_subnet_cidr)[1]}", 0) != cidrhost(var.bastion_subnet_cidr, 0),
      false,
    )
    error_message = "bastion_subnet_cidr must be /26 or larger, inside vpc_cidr and apart from subnet_cidr, such as 10.42.2.0/26."
  }
}

# --- Machines and disks ------------------------------------------------------

# Sizes are held to the Dsv5, Ddsv5, Dasv5, Dadsv5 families and their E
# counterparts: each takes Premium SSD v2 and Trusted Launch, attaches data
# disks over SCSI (data_device depends on it), needs accelerated networking,
# runs two vCPUs on each core and gives at least 4 GiB a vCPU.
variable "validator_instance_type" {
  description = "The validator's VM size, a v5 D or E size with premium storage. Null means Standard_D8s_v5 on testnet (4 cores, 32 GiB) and Standard_D16s_v5 on mainnet (8 cores, 64 GiB). Mainnet refuses a type with fewer than 8 physical cores or less than 32 GiB nominal, the node scripts' validator floor. The default has 64 GiB because the host reads a 32 GiB machine as 31 GiB, and the scripts' hardware check then warns."
  type        = string
  default     = null

  validation {
    condition     = var.validator_instance_type == null || can(regex("^Standard_[DE][0-9]+a?d?s_v5$", var.validator_instance_type))
    error_message = "validator_instance_type must be null or a v5 D or E size with premium storage and no l or p, such as Standard_D16s_v5 or Standard_E16ds_v5."
  }

  # No data source reads a size's cores or memory, so the floor is read from
  # the name: 16 vCPUs on these sizes are 8 cores and at least 64 GiB.
  validation {
    condition     = var.validator_instance_type == null || var.network != "mainnet" || try(tonumber(regex("^Standard_[DE]([0-9]+)", var.validator_instance_type)[0]) >= 16, false)
    error_message = "On mainnet the validator needs at least 8 physical cores and 32 GiB of memory, the node scripts' validator floor: 16 vCPUs on these sizes, such as Standard_D16s_v5."
  }
}

variable "gateway_instance_type" {
  description = "The worker gateway's VM size, a v5 D or E size with premium storage. Null means Standard_D2s_v5."
  type        = string
  default     = null

  validation {
    condition     = var.gateway_instance_type == null || can(regex("^Standard_[DE][0-9]+a?d?s_v5$", var.gateway_instance_type))
    error_message = "gateway_instance_type must be null or a v5 D or E size with premium storage and no l or p, such as Standard_D2s_v5."
  }
}

variable "data_disk_size_gb" {
  description = "The validator's Premium SSD v2 data disk in GiB. Null means 500 on testnet and 2000 on mainnet; the floor is 350 and 2000. A disk can grow later but never shrink."
  type        = number
  default     = null

  validation {
    condition     = var.data_disk_size_gb == null || try(var.data_disk_size_gb >= local.disk_floor[var.network].size && var.data_disk_size_gb <= 65536 && floor(var.data_disk_size_gb) == var.data_disk_size_gb, false)
    error_message = "data_disk_size_gb must be a whole number of GiB from the network's floor (testnet 350, mainnet 2000) to 65536, Premium SSD v2's largest disk."
  }
}

variable "data_disk_iops" {
  description = "The data disk's provisioned IOPS. Null means 15000 on testnet and 20000 on mainnet, which are also the floors."
  type        = number
  default     = null

  # Premium SSD v2 provisions at most 80000 IOPS, and 500 per GiB, which the
  # size floor already allows.
  validation {
    condition     = var.data_disk_iops == null || try(var.data_disk_iops >= local.disk_floor[var.network].iops && var.data_disk_iops <= 80000 && floor(var.data_disk_iops) == var.data_disk_iops, false)
    error_message = "data_disk_iops must be a whole number from the network's floor (testnet 15000, mainnet 20000) to 80000, Premium SSD v2's most."
  }
}

variable "data_disk_throughput" {
  description = "The data disk's provisioned throughput in MB/s. Null means 300; the floor is 240 on testnet and 300 on mainnet."
  type        = number
  default     = null

  # Premium SSD v2 provisions at most 2000 MB/s, and 0.25 MB/s per IOPS, which
  # the IOPS floor already allows.
  validation {
    condition     = var.data_disk_throughput == null || try(var.data_disk_throughput >= local.disk_floor[var.network].throughput && var.data_disk_throughput <= 2000 && floor(var.data_disk_throughput) == var.data_disk_throughput, false)
    error_message = "data_disk_throughput must be a whole number of MB/s from the network's floor (testnet 240, mainnet 300) to 2000, Premium SSD v2's most."
  }
}

# Managed disks are always encrypted at rest. A key of your own would need a
# disk encryption set, which this root does not build, so the one encryption
# input here is encryption at host.
variable "encryption_at_host_enabled" {
  description = "Encrypt the VMs' caches and temporary data on the host too. The subscription must have the Microsoft.Compute EncryptionAtHost feature registered. Managed disks are encrypted at rest either way."
  type        = bool
  default     = false
  nullable    = false
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
    condition     = can(regex(local.re.release, var.min_scripts_release))
    error_message = "min_scripts_release must be a node-scripts release tag, such as scripts-v2.3.0: each part 0 or a number of up to four digits with no leading zero."
  }
}

variable "trusted_nodes_file" {
  description = "A local path to the trusted hubs map (public data), written to the validator at first boot as /etc/telcoin-first-boot/trusted-nodes.yaml; it travels in the VM's custom data. Empty means you copy it to the host yourself; next_steps names the path."
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
