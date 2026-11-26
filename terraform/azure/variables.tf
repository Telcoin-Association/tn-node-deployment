# The network ranges a worker gateway's upstream may sit in (setup-gateway.sh
# takes no public upstream), as CIDRs whose prefix is at least the range's own.
# host-plan holds the same pattern.
locals {
  private_cidr_re = "^(10\\.[0-9.]+/([89]|[12][0-9]|3[0-2])|172\\.(1[6-9]|2[0-9]|3[01])\\.[0-9.]+/(1[2-9]|2[0-9]|3[0-2])|192\\.168\\.[0-9.]+/(1[6-9]|2[0-9]|3[0-2])|100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.[0-9.]+/(1[0-9]|2[0-9]|3[0-2]))$"
}

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
  description = "Prefix of every resource name, and the deployment tag."
  type        = string
  default     = "tn"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.name_prefix))
    error_message = "name_prefix must be a lowercase letter, then 1 to 20 lowercase letters, digits or -."
  }
}

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

variable "gateway_enabled" {
  description = "Build a worker-gateway host in front of the validator's RPC. False builds the validator host alone."
  type        = bool
  default     = true
  nullable    = false
}

variable "rpc_domain" {
  description = "The public RPC name the worker gateway serves. Empty until it is chosen: the gateway VM is built by the apply that sets it."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.rpc_domain == "" || (length(var.rpc_domain) <= 253 && can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$", var.rpc_domain)))
    error_message = "rpc_domain must be empty or a lowercase host name such as rpc.example.org: no scheme, no path, no trailing dot, no IP address."
  }
}

variable "admin_ssh_public_key" {
  description = "The operator's SSH public key (ssh-ed25519, or ssh-rsa of at least 2048 bits), installed for admin_username on both hosts."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^(ssh-ed25519 AAAAC3NzaC1lZDI1NTE5|ssh-rsa AAAAB3NzaC1yc2E)[A-Za-z0-9+/]+={0,2}( [^\\n]*)?$", trimspace(var.admin_ssh_public_key)))
    error_message = "admin_ssh_public_key must be one ssh-ed25519 or ssh-rsa public key line, such as the content of ~/.ssh/id_ed25519.pub. Azure takes no other key type."
  }
}

variable "admin_username" {
  description = "The admin user Azure creates on both hosts at first boot: the login user, who runs the installer and owns the scripts."
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
    error_message = "admin_username cannot be telcoin or telcoin-ui (the node's service accounts), root, or a name Azure reserves such as admin or user."
  }
}

variable "admin_ssh_cidrs" {
  description = "IPv4 CIDRs that may reach TCP 22 of both hosts, such as [\"198.51.100.7/32\"]. Empty leaves SSH to Azure Bastion."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for c in var.admin_ssh_cidrs : can(regex("^[0-9.]+/[0-9]{1,2}$", c)) && try(cidrhost(c, 0) == split("/", c)[0], false)])
    error_message = "Each admin_ssh_cidrs entry must be an IPv4 CIDR with no host bits set, such as 198.51.100.7/32 or 192.0.2.0/24."
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

variable "vpc_cidr" {
  description = "The virtual network's address space."
  type        = string
  default     = "10.42.0.0/16"
  nullable    = false

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && can(regex(local.private_cidr_re, var.vpc_cidr))
    error_message = "vpc_cidr must be a CIDR inside 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 or 100.64.0.0/10, such as 10.42.0.0/16: the gateway's upstream must be a private address."
  }
}

variable "subnet_cidr" {
  description = "The hosts' subnet. The validator takes its 10th address, the gateway its 20th."
  type        = string
  default     = "10.42.1.0/24"
  nullable    = false

  validation {
    condition = (
      can(regex(local.private_cidr_re, var.subnet_cidr)) &&
      try(tonumber(split("/", var.subnet_cidr)[1]) <= 27, false) &&
      try(tonumber(split("/", var.subnet_cidr)[1]) >= tonumber(split("/", var.vpc_cidr)[1]) &&
      cidrhost("${split("/", var.subnet_cidr)[0]}/${split("/", var.vpc_cidr)[1]}", 0) == cidrhost(var.vpc_cidr, 0), false)
    )
    error_message = "subnet_cidr must be a private CIDR of /27 or larger inside vpc_cidr, such as 10.42.1.0/24."
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

# Sizes are held to the Dsv5, Ddsv5, Dasv5, Dadsv5 families and their E
# counterparts: each takes Premium SSD v2 and Trusted Launch, attaches data
# disks over SCSI (data_device depends on it), needs accelerated networking,
# runs two vCPUs on each core and gives at least 4 GiB a vCPU.
variable "validator_instance_type" {
  description = "The validator's VM size. Null is Standard_D8s_v5 on testnet (4 cores, 32 GiB) and Standard_D16s_v5 on mainnet (8 cores, 64 GiB)."
  type        = string
  default     = null

  validation {
    condition     = var.validator_instance_type == null || can(regex("^Standard_[DE][0-9]+a?d?s_v5$", var.validator_instance_type))
    error_message = "validator_instance_type must be a v5 D or E size with premium storage and no l or p, such as Standard_D16s_v5 or Standard_E16ds_v5."
  }

  validation {
    condition     = var.validator_instance_type == null || try(tonumber(regex("^Standard_[DE]([0-9]+)", var.validator_instance_type)[0]) >= (var.network == "mainnet" ? 16 : 8), false)
    error_message = "A mainnet validator needs 8 physical cores, 16 vCPUs on these sizes (such as Standard_D16s_v5); a testnet validator 4 cores, 8 vCPUs."
  }
}

variable "gateway_instance_type" {
  description = "The worker gateway's VM size. Null is Standard_D2s_v5."
  type        = string
  default     = null

  validation {
    condition     = var.gateway_instance_type == null || can(regex("^Standard_[DE][0-9]+a?d?s_v5$", var.gateway_instance_type))
    error_message = "gateway_instance_type must be a v5 D or E size with premium storage and no l or p, such as Standard_D2s_v5."
  }
}

# The size floors are setup-node.sh's validator minimums (HW_*_VAL_MIN_DISK_GB
# of lib/common.sh); the IOPS and throughput bounds are Premium SSD v2's own:
# 3000 IOPS and 125 MB/s at least, up to 500 IOPS a GiB and 80000, and up to
# 0.25 MB/s an IOPS and 2000.
variable "data_disk_size_gb" {
  description = "The data disk's size in GiB. Null is 500 on testnet and 2000 on mainnet."
  type        = number
  default     = null

  validation {
    condition     = var.data_disk_size_gb == null || try(floor(var.data_disk_size_gb) == var.data_disk_size_gb && var.data_disk_size_gb >= (var.network == "mainnet" ? 2000 : 350) && var.data_disk_size_gb <= 65536, false)
    error_message = "data_disk_size_gb must be a whole number of GiB from the validator minimum (350 on testnet, 2000 on mainnet) to 65536."
  }
}

variable "data_disk_iops" {
  description = "The data disk's provisioned IOPS. Null is 15000 on testnet and 20000 on mainnet."
  type        = number
  default     = null

  validation {
    condition = var.data_disk_iops == null || try(
      floor(var.data_disk_iops) == var.data_disk_iops && var.data_disk_iops >= 3000 && var.data_disk_iops <= 80000 &&
      var.data_disk_iops <= 500 * coalesce(var.data_disk_size_gb, var.network == "mainnet" ? 2000 : 500),
      false,
    )
    error_message = "data_disk_iops must be a whole number from 3000 to 80000, and at most 500 per GiB of the disk."
  }
}

variable "data_disk_throughput" {
  description = "The data disk's provisioned throughput in MB/s. Null is 300."
  type        = number
  default     = null

  validation {
    condition = var.data_disk_throughput == null || try(
      floor(var.data_disk_throughput) == var.data_disk_throughput && var.data_disk_throughput >= 125 && var.data_disk_throughput <= 2000 &&
      var.data_disk_throughput <= floor(coalesce(var.data_disk_iops, var.network == "mainnet" ? 20000 : 15000) / 4),
      false,
    )
    error_message = "data_disk_throughput must be a whole number of MB/s from 125 to 2000, and at most a quarter of data_disk_iops."
  }
}

variable "encryption_at_host_enabled" {
  description = "Encrypt the VMs' caches and temporary data on the host too. The subscription must have the Microsoft.Compute EncryptionAtHost feature registered. Managed disks are encrypted at rest either way."
  type        = bool
  default     = false
  nullable    = false
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

variable "validator_address" {
  description = "The validator's execution address (on mainnet its Safe), filled into the printed key generation command. Empty prints a placeholder."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.validator_address == "" || can(regex("^0[xX][0-9a-fA-F]{40}$", var.validator_address))
    error_message = "validator_address must be empty or 0x followed by 40 hex digits."
  }
}

variable "trusted_nodes_file" {
  description = "A local path to the trusted hubs map (public data), written to the validator at first boot. Empty: copy it to the host by hand, as next_steps says."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.trusted_nodes_file == "" || try(length(file(var.trusted_nodes_file)) <= 65536, false)
    error_message = "trusted_nodes_file must name a readable file of at most 64 KiB, or be empty."
  }
}

variable "redirect_queries_url" {
  description = "The public RPC the worker gateway sends queries to. Empty means the network's own."
  type        = string
  default     = ""
  nullable    = false
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

variable "allow_no_tpm" {
  description = "Print --allow-no-tpm in the key generation command. Both hosts have a vTPM here, so this stays false."
  type        = bool
  default     = false
  nullable    = false
}

variable "node_release_tag" {
  description = "The testnet node release the printed key generation installs, such as v0.18.0-adiri. Empty prints a placeholder."
  type        = string
  default     = ""
  nullable    = false
}
