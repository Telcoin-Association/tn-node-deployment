# Terraform deployment

This directory builds the hosts of a Telcoin Network validator and its worker gateway on AWS, Google Cloud or Azure.
Each cloud has its own root module, `aws/`, `gcp/` and `azure/`, and you apply one of them.
They share `modules/host-plan/`, which renders each host's first-boot input and the commands you run next, and `first-boot/`, the scripts cloud-init runs once on each host.
It is the preferred way to stand up a validator with its worker gateway; the runbook is [OPERATOR.md](../OPERATOR.md), and this page covers what Terraform does around it.

## Read this first

Terraform never sees the BLS key passphrase.
The validator's first boot only prepares the host: it mounts the data disk and installs the node scripts, and it never runs `setup-node.sh`.
You generate the keys by hand, in a shell on the validator host, with the commands `terraform output -raw next_steps` prints, and the passphrase goes from your keyboard to `setup-node.sh` on that host and nowhere else.
Nothing in the Terraform input, state or outputs is secret.

Both hosts install whatever node-scripts release the public installer, `https://install.telcoin.network`, serves when they boot.
This deployment needs `min_scripts_release` or newer, by default `scripts-v2.3.0`, the first release whose `setup-gateway.sh`, key generation and checks it relies on.
Until the installer serves that release, the first boot of both hosts stops at its `scripts-release` step, right after the scripts are installed: on the validator that is its last step, and on the gateway host it comes before Docker.
The log then says `The installer put the node scripts <release> on this host; this deployment needs scripts-v2.3.0 or newer. Once https://install.telcoin.network serves scripts-v2.3.0 or newer, run this script again: sudo bash /usr/local/libexec/telcoin-first-boot/first-boot-<role>.sh`, and the console line is `TELCOIN-FIRST-BOOT <role>: FAILED at scripts-release`.
Once the release is out, run that command on each host; it starts again from the top and repeats nothing destructive.
Do not lower `min_scripts_release` to get past the step: an older release lacks what first boot and the printed commands use, such as `setup-gateway.sh --rate-limit-submissions`.

## What it builds

- One private network with one subnet, in one zone: the validator takes the subnet's 10th address and the worker gateway its 20th (`10.42.1.10` and `10.42.1.20` with the defaults).
- A validator host with a static public IPv4 for P2P (UDP 49590 and 49594 from anywhere) and a data disk, mounted at `/var/lib/telcoin` by its first boot.
- Firewall rules that let the validator's RPC (TCP 8545) and health port (TCP 43174) be reached from the worker gateway's private address alone.
- A worker-gateway host with a static public IPv4 and TCP 80 and 443 open from anywhere, which runs the worker gateway in standalone mode behind Caddy for your RPC name (OPERATOR.md section 4.15).
- No TCP 22 from the internet, unless `admin_ssh_cidrs` lists networks (see [Admin access](#admin-access)).

The gateway VM is created only once `rpc_domain` is set.
Its static IP, its private address and every firewall rule exist from the first apply, so the address the RPC name points at is known before the VM boots.

`gateway_enabled = false` builds a single node with no gateway resources at all, for an observer or an RPC node.

## Prerequisites

- Terraform 1.9 or later, below 2.0.
  Each root's `.terraform.lock.hcl` pins the provider release and its hashes.
- The cloud's CLI and credentials that Terraform's provider can read: the AWS CLI v2 with the Session Manager plugin, `gcloud`, or `az`.
- An account allowed to create a network, VMs, disks, static IPs and firewall rules, plus an IAM role and instance profile on AWS, a service account and instance IAM bindings on Google Cloud, and Azure Bastion when you turn it on.
- A checkout of this repository at a release tag that holds `terraform/`.
  The roots read `first-boot/` and `modules/host-plan/` from the checkout, so the first-boot scripts are those of that tag.
- For a validator: its execution address (on mainnet its Safe), the trusted hubs map from the Telcoin Association, and on mainnet a `telcoin-network` binary built as OPERATOR.md section 2.12 says.
- An RPC name for the worker gateway: on mainnet the validator's default name or a name of your own, on testnet a name of your own in a domain you control.

## Deploy

### 1. The first apply

```bash
cd terraform/aws                     # or terraform/gcp, terraform/azure
cp terraform.tfvars.example terraform.tfvars
${EDITOR:-vi} terraform.tfvars       # leave rpc_domain = ""
terraform init
terraform apply
```

It creates the network, both static IPs, every firewall rule and the validator host; no gateway VM yet.
Then read what to do next:

```bash
terraform output -raw next_steps
terraform output session_command
terraform output tao_handoff
```

### 2. On the validator host

Open a shell with the `session_command` output's `validator` command.
Wait until `sudo ls /var/lib/telcoin-first-boot` shows `done`; `failed` means a step stopped, and [First boot](#first-boot) says where to look.
Run the commands of `next_steps` in order, as printed.

On testnet they are key generation, the host firewall, finalize (which writes the configuration and starts the node) and `edit-config.sh --set gateway_upstream=<gateway private IP>`.
On mainnet they are installing the binary, key generation and the host firewall; finalize and `gateway_upstream` follow under `==== At launch ====`, once the script release that enables mainnet is out.

Key generation runs `read -rs PASS` first: type the passphrase and press Enter, and nothing is shown.
Back up `node-keys/` and `node-info.yaml` offline right after it (OPERATOR.md section 2.5).
Without `trusted_nodes_file`, copy the hubs map to `/etc/telcoin-first-boot/trusted-nodes.yaml` on the host (root-owned, mode 0644, at most 64 KiB) before key generation.
Without `validator_address`, the printed command holds a placeholder that `setup-node.sh` refuses; set the variable and apply again, which changes only the output.
On testnet the same goes for `node_release_tag`, whose placeholder is `vX.Y.Z-adiri`.

### 3. The RPC name and the second apply

On mainnet, key generation prints the validator's default name, `https://v<label>.telcoin.network/`, and `node-info.yaml` advertises it from then on (OPERATOR.md section 2.12).
Send `v<label>.telcoin.network` and `tao_handoff.ipv4`, the gateway's static IP, to the Telcoin Association (TAO), which creates the A record; or create an A record for a name of your own at that address.
On testnet, create an A record for a name of your own at `gateway_public_ip`.

Once the name resolves to that address, set `rpc_domain` to it (lowercase, no `https://`, no trailing dot or slash) and apply again:

```bash
terraform apply
```

This apply creates the gateway VM (on AWS with its Elastic IP association) and changes nothing on the validator: `validator_user_data_sha256` stays the same, and the plan shows no change to the validator host.
The gateway's first boot installs Docker and the node scripts, waits up to 30 minutes for the name to reach it, enables the gateway, turns on its firewall and runs `check-node.sh`; open a shell with `session_command.gateway` and wait for `done` as on the validator.

### 4. Back on the validator host

`terraform output -raw next_steps` now fills in the name.
On testnet, run its last step: `install-caddy.sh --phase=rpc-advertise --rpc-domain <rpc_domain>`, which makes `node-info.yaml` advertise the gateway, then `check-node.sh`.
Run `sudo bash /home/<login user>/telcoin-node-scripts/check-node.sh` on the gateway host too.
On mainnet that step sits under `==== At launch ====` with finalize, and `rpc-advertise` is needed only for a name of your own, since key generation already advertises the default one; before the node exists it records the name with a warning that it is not verified yet (OPERATOR.md section 4.15).

## First boot

cloud-init runs `/usr/local/libexec/telcoin-first-boot/first-boot-validator.sh` or `first-boot-gateway.sh` once, as root, with the values of `/etc/telcoin-first-boot/first-boot.env`.
Every value is checked before anything on the host changes.

| Step | Validator | Worker gateway |
|---|---|---|
| `env` | The env file | The env file |
| `trusted-nodes` | The hubs file is readable, when one was given | |
| `apt-lock` | apt waits up to 15 minutes for the dpkg lock | The same |
| `cve-2026-31431` | The `algif_aead` modprobe line `setup-node.sh` asks for; the module unloaded if loaded | The same |
| `swap` | Swap off | The same |
| `data-disk` | Waits up to 10 minutes for the disk, formats it ext4 only when it carries no signature at all, refuses any other filesystem, and mounts it by UUID with `nofail` at `/var/lib/telcoin` | |
| `node-scripts` | The installer, run as the login user, three tries | The same |
| `scripts-release` | The installed release is `min_scripts_release` or newer | The same, before Docker |
| `docker` | | Docker Engine from Docker's apt repository, its signing key checked against a pinned fingerprint first |
| `docker-service` | | The Docker daemon enabled and answering |
| `dns` | | Up to 30 minutes for `rpc_domain` to reach this host; a name that never does is logged and the boot goes on |
| `gateway` | | `setup-gateway.sh --enable --mode standalone ... --json`, up to three tries 60 seconds apart while it exits 1; exit 3 stops the boot before the firewall step |
| `firewall` | | `firewall-setup.sh --enable --ssh-from <admin_ssh_cidrs and vpc_cidr>`, which keeps 80 and 443 open for Caddy |
| `check-node` | | `check-node.sh`, its output into the log; it never stops the boot |

The validator's first boot never runs `setup-node.sh` or `firewall-setup.sh`.

Where to look:

- `/var/log/telcoin-first-boot.log` has every step and the output of the scripts it ran; the same lines go to cloud-init's output log and to the journal (`journalctl -t telcoin-first-boot`).
- `/var/lib/telcoin-first-boot/` holds `done` or `failed` (root only); `failed` names the step and the reason.
- The last line of a run reaches the console: `TELCOIN-FIRST-BOOT <role>: ok` or `TELCOIN-FIRST-BOOT <role>: FAILED at <step>`.
  Read it without a shell with `aws ec2 get-console-output --instance-id <id> --latest --output text`, `gcloud compute instances get-serial-port-output <name> --zone <zone>` or `az vm boot-diagnostics get-boot-log --name <name> --resource-group <name_prefix>-rg`.

After a fix, run the script again with `sudo bash /usr/local/libexec/telcoin-first-boot/first-boot-<role>.sh`, as the log says.
It starts at the top and repeats nothing destructive: a data disk that holds a filesystem is never formatted, and its fstab line is added once.

When the gateway's name resolves late, the gateway is set up anyway and Caddy keeps asking for the certificate by itself, with growing pauses; `sudo systemctl reload caddy` starts a new attempt at once.

## Admin access

| Cloud | Way in | Notes |
|---|---|---|
| AWS | Session Manager, with no port open. | The instance role trusts `ec2.amazonaws.com` and carries only `AmazonSSMManagedInstanceCore`. `session_command` is `aws ssm start-session --region <region> --target <instance id>`. `admin_ssh_cidrs` opens TCP 22 to those networks, but the root installs no SSH key: add yours to `/home/ubuntu/.ssh/authorized_keys` from a Session Manager shell first. |
| Google Cloud | IAP TCP forwarding with OS Login (`enable_iap`, on by default). | `admin_members` get OS Login with sudo and, with `enable_iap`, the IAP tunnel on both instances, and `roles/iam.serviceAccountUser` on the hosts' service account. `gcloud compute ssh` also needs `compute.instances.get` and `compute.projects.get` on the project (`roles/compute.viewer` has both), which the root does not grant. Project-wide SSH keys are blocked, and the hosts' service account holds no roles. |
| Azure | SSH from `admin_ssh_cidrs`, Azure Bastion (`enable_bastion`), or both; the plan refuses a deployment with neither. | `admin_ssh_public_key` is installed for `admin_username` on both hosts, passwords are off, VM extensions are off and neither host has a managed identity. With Bastion, `session_command` is `az network bastion ssh ...`, with the path of your private key in place of its placeholder; without it, `ssh <admin_username>@<public IP>`. A new `admin_ssh_public_key` replaces the gateway and is ignored on the validator: rotate the validator's key on the host. |

The login user, who runs the installer and owns `~/telcoin-node-scripts`, is `ubuntu` on AWS and Google Cloud and `admin_username` on Azure (default `ubuntu`, never `telcoin`).
On Google Cloud you log in as your own OS Login user; the scripts stay under `/home/ubuntu`, and the printed commands give their full path.
The hosts' own firewall, which the printed command turns on for the validator and first boot for the gateway, lets SSH in from `admin_ssh_cidrs` and from `vpc_cidr`, where Bastion and other tunnels inside the network connect from; on Google Cloud `firewall-setup.sh` adds IAP's range to that list by itself.

## Variables

Copy `terraform.tfvars.example` to `terraform.tfvars`; every value in it is public.
All three roots take these:

| Variable | Default | What it sets |
|---|---|---|
| `network` | `testnet` | `testnet` or `mainnet`. |
| `name_prefix` | `telcoin` | The start of every resource name, also set as a tag (a label on Google Cloud): a lowercase letter, then 1 to 20 lowercase letters, digits or `-`; on AWS not `sg-...`. |
| `gateway_enabled` | `true` | `false` builds a single node with no gateway resources. |
| `rpc_domain` | `""` | The RPC name the worker gateway serves. Empty on the first apply; setting it creates the gateway VM. Refused with `gateway_enabled = false`. |
| `admin_ssh_cidrs` | `[]` | IPv4 networks that may reach TCP 22 of both hosts, each /8 or narrower and never `0.0.0.0`, given by their network address (`198.51.100.7/24` is refused). |
| `vpc_cidr` | `10.42.0.0/16` | The private range, inside 10/8, 172.16/12, 192.168/16 or 100.64/10; on AWS from /16 to /27. |
| `subnet_cidr` | `10.42.1.0/24` | The hosts' subnet, /27 or larger, inside `vpc_cidr`. |
| `validator_instance_type` | `null` | The validator's type; null takes the defaults below. Mainnet refuses fewer than 8 physical cores or less than 32 GiB nominal. |
| `gateway_instance_type` | `null` | The gateway's type; null takes the default below. |
| `data_disk_size_gb` | `null` | 500 GiB on testnet, 2000 on mainnet; the floors are 350 and 2000. A disk can grow later but never shrink. |
| `data_disk_iops` | `null` | 15000 on testnet, 20000 on mainnet, which are also the floors. |
| `data_disk_throughput` | `null` | 300; the floors are 240 on testnet and 300 on mainnet. MiB/s on AWS and Google Cloud, MB/s on Azure; on Google Cloud at least `data_disk_iops`/256. |
| `ubuntu_version` | `26.04` | `26.04` or `24.04`. |
| `validator_address` | `""` | The execution address (on mainnet the Safe) in the printed key generation command; empty prints a placeholder. |
| `node_release_tag` | `""` | The testnet release the printed key generation installs (`--release-tag`), such as `v0.18.0-adiri`; empty prints `vX.Y.Z-adiri`. Mainnet key generation takes an existing binary and does not use it. |
| `min_scripts_release` | `scripts-v2.3.0` | The oldest node-scripts release first boot accepts on either host. |
| `trusted_nodes_file` | `""` | A local path to the trusted hubs map, written to the validator as `/etc/telcoin-first-boot/trusted-nodes.yaml` through its user data. At most 64 KiB, and it must fit the cloud's user data limit, which the plan checks: 16 KiB gzipped on AWS, one 256 KiB metadata value on Google Cloud, 65535 bytes gzipped on Azure. Empty means you copy it by hand. |
| `redirect_queries_url` | `""` | Where the gateway sends queries; empty means the network's public RPC (`https://rpc.adiri.tel` on testnet, `https://rpc.telcoin.network` on mainnet). The plan refuses a URL that points at the validator's own RPC or readiness port (8545, 43174), or at the gateway's own ports on a loopback name, as `setup-gateway.sh` does. |
| `gateway_rate_limit_submissions` | `300` | Submissions a second the gateway keeps for `eth_sendRawTransaction`, 0 to 999999; 0 turns the reservation off. |

AWS:

| Variable | Default | What it sets |
|---|---|---|
| `region` | none, required | The region, such as `eu-central-1`. |
| `availability_zone` | none, required | A zone of `region`, such as `eu-central-1a` (a Local Zone is refused). It must offer both hosts' instance types; a plan that finds it does not names the zones that do. Given once and kept: the subnet and the data volume cannot move. |
| `disk_kms_key` | `""` | The ARN of a KMS key of your own (not an alias) for every volume; empty uses the account's AWS managed EBS key. Honoured at the first apply only. |
| `ami_id` | `""` | An amd64 Ubuntu image instead of Canonical's current one, which the root reads from Canonical's public SSM parameter. |
| `allow_no_tpm` | `false` | Accept a mainnet host without NitroTPM (see [The TPM on AWS](#the-tpm-on-aws)). |

Google Cloud:

| Variable | Default | What it sets |
|---|---|---|
| `project` | none, required | The project ID. |
| `region` | `us-central1` | The region of the network, the subnet and the static addresses. |
| `zone` | `null` | The zone of both hosts and the data disk; null means `<region>-a`. It must offer the validator's machine type and Hyperdisk Balanced. |
| `enable_iap` | `true` | IAP TCP forwarding to TCP 22 of both hosts, from `35.235.240.0/20`. The plan refuses `false` with an empty `admin_ssh_cidrs`. |
| `admin_members` | `[]` | IAM members (`user:`, `group:`, `serviceAccount:`, `domain:`) given OS Login with sudo and the IAP tunnel. |
| `disk_kms_key` | `""` | A Cloud KMS key, `projects/P/locations/L/keyRings/R/cryptoKeys/K`, for every disk; the project's Compute Engine service agent needs `roles/cloudkms.cryptoKeyEncrypterDecrypter` on it. Empty uses Google's own key. Honoured at the first apply only. |

Azure:

| Variable | Default | What it sets |
|---|---|---|
| `subscription_id` | `null` | The subscription; null reads `ARM_SUBSCRIPTION_ID`. |
| `location` | `eastus2` | The region, which must offer zonal Premium SSD v2 disks. |
| `zone` | `"1"` | `1`, `2` or `3`. |
| `admin_ssh_public_key` | none, required | One `ssh-ed25519` or `ssh-rsa` (2048 bits or more) public key line. |
| `admin_username` | `ubuntu` | The admin user Azure creates on both hosts; never `telcoin`, `telcoin-ui`, `root` or a name Azure reserves. |
| `enable_bastion` | `false` | Azure Bastion, Standard SKU with native-client tunnelling. |
| `bastion_subnet_cidr` | `10.42.2.0/26` | `AzureBastionSubnet`, /26 or larger, inside `vpc_cidr` and apart from `subnet_cidr`. |
| `encryption_at_host_enabled` | `false` | Encrypts the VMs' caches and temporary data on the host too; the subscription needs the `EncryptionAtHost` feature. Managed disks are encrypted at rest either way; a key of your own is not offered. |

The machine defaults:

| | AWS | Google Cloud | Azure |
|---|---|---|---|
| Validator, testnet (4 cores, 32 GiB) | `m7i.2xlarge` | `c3-standard-8` | `Standard_D8s_v5` |
| Validator, mainnet (8 cores, 64 GiB) | `m7i.4xlarge` | `c3d-standard-16` | `Standard_D16s_v5` |
| Worker gateway | `m7i.large` | `e2-standard-2` | `Standard_D2s_v5` |
| Data disk | gp3 | Hyperdisk Balanced | Premium SSD v2 |
| Other types | x86_64 Nitro types | Validator: a series that takes Hyperdisk Balanced, such as C3, C3D, C4 or N4. Gateway: one that takes pd-balanced, such as E2, N2 or C3 | v5 D or E sizes with premium storage (Dsv5, Ddsv5, Dasv5, Dadsv5 and their E counterparts) |

The mainnet default has twice the 32 GiB floor because a 32 GiB VM reports a little less to the host, which the node scripts' hardware check reads as under the floor.
On Azure, `Standard_D8s_v5` sustains 12,800 uncached IOPS and 290 MB/s, a little under the testnet disk's 15,000 and 300, and bursts to 20,000 for up to 30 minutes.

## Outputs

The three roots give the same outputs.

| Output | Value |
|---|---|
| `validator_public_ip` | The validator's static public IPv4, which peers dial. |
| `validator_private_ip` | The validator's fixed private IPv4, the gateway's upstream. |
| `gateway_public_ip` | The gateway's static public IPv4, where the RPC name's A record points; null with `gateway_enabled = false`. |
| `gateway_private_ip` | The gateway's fixed private IPv4, the only source the validator's RPC and health port admit; null with `gateway_enabled = false`. |
| `gateway_created` | Whether the gateway VM exists: true once `rpc_domain` is set. |
| `session_command` | `validator` and `gateway`, the command that opens a shell on each host; `gateway` is null until its VM exists. |
| `next_steps` | The commands to run on the validator host, in order, with this deployment's addresses. Print it with `terraform output -raw next_steps`. |
| `tao_handoff` | The DNS record the RPC name needs: `record` (`A`), `name` (null until `rpc_domain` is set), `ipv4` (the gateway's static IP) and a `note` that says what to do with it. |
| `validator_user_data_sha256` | The SHA-256 of the validator's first-boot input; the second apply leaves it unchanged. |

## State

The roots have no backend block, so the state is a local `terraform.tfstate` unless you add a backend of your own beside the root.
Where to keep it is your choice.
It holds resource IDs, addresses and the rendered first-boot input, the hubs map included: all public, nothing secret.
Keep it anyway: without it Terraform no longer knows the resources it made, and they stay in the cloud.
`.gitignore` keeps state files and `terraform.tfvars` out of git.

## Updating

The node and the scripts are updated on the host, with the repository's own update scripts: `update-scripts.sh` (OPERATOR.md section 4.1) and `update-node.sh` (section 4.2) on the validator, and on the gateway host `update-scripts.sh`, then `setup-gateway.sh --refresh` when it says so (section 4.15).
Nothing updates them on its own.

Terraform never replaces the validator VM to update it.
Its boot disk holds the stored passphrase credential, which a new VM would not have, so the root ignores a newer image and any later change to the validator's first-boot input.
A change that would replace the validator VM, its data disk or a static IP, such as another zone, region or `disk_kms_key`, stops the plan at `prevent_destroy`.
A data disk can grow (`data_disk_size_gb`); then grow its filesystem on the host with `sudo resize2fs "$(findmnt -no SOURCE /var/lib/telcoin)"`.

The gateway VM holds nothing that its first boot cannot build again, so it can be replaced.
A change to its first-boot input, such as `rpc_domain`, `redirect_queries_url` or `gateway_rate_limit_submissions`, replaces it, and the new VM sets the gateway up again unattended.
A newer Ubuntu image does not replace it on its own; take one on purpose with `terraform apply -replace='aws_instance.gateway[0]'`, `-replace='google_compute_instance.gateway[0]'` or `-replace='azurerm_linux_virtual_machine.gateway[0]'`.
A new gateway VM gets a new certificate when it boots.
After a change of `rpc_domain`, advertise the new name on the validator (`install-caddy.sh --phase=rpc-advertise --rpc-domain <name>`, OPERATOR.md section 4.15).

## Teardown

The data disk, both static IPs and the validator VM carry `prevent_destroy`, so `terraform destroy` stops before it deletes anything, and so does any plan that would delete one of them (turning `gateway_enabled` off after the first apply deletes the gateway's static IP).
The data disk holds the node keys and the chain data: deleting it deletes the keys, so back up `node-keys/` and `node-info.yaml` first if you will need them (OPERATOR.md section 4.12).

- To remove only the gateway VM, set `rpc_domain = ""` and apply; its static IP stays, and the A record still points at it.
- To delete everything on purpose, as after a rehearsal, set `prevent_destroy = false` in the lifecycle blocks of the data disk, the static IPs and the validator VM in your checkout and run `terraform destroy`; or run `terraform state rm` on those resources, `terraform destroy`, and delete them in the cloud console.

## Costs

The costs are the two VMs, the data disk with its provisioned IOPS and throughput, the boot disks, both static public IPv4 addresses (billed while they exist, with a VM or without), data transfer out (P2P traffic and the gateway's replies), a KMS key of your own, and Azure Bastion when it is on.
Use the cloud's own pricing calculator for figures.

## What it does not do

- No automatic updates of the node, the scripts or the OS packages.
- One zone, one validator and one worker gateway; no second zone and no load balancer.
- No DNS records: you, or the TAO for a mainnet default name, create the A record.
- No key generation, and nothing for the BLS passphrase: no input, no secret store, no output.
- No snapshots or backups of the data disk: a snapshot is a copy of the node keys.
- No remote state backend.

## The TPM on AWS

On mainnet, key generation seals the passphrase credential to a TPM2.
The plan of a mainnet deployment checks that the image reports NitroTPM support (`tpm_support = v2.0`) and the validator's instance type supports NitroTPM, and stops otherwise, naming both.
Either set `ami_id` to a copy of the Ubuntu image registered with `--boot-mode uefi --tpm-support v2.0`, or set `allow_no_tpm = true`, which adds `--allow-no-tpm` to the printed key generation and keeps the credential encrypted with the host key alone.
The Google Cloud and Azure roots turn a vTPM on for both hosts and have no such input.

## Checking a change

`bash tools/check-terraform.sh` runs `terraform fmt`, `validate` and `terraform test` with mocked providers for `modules/host-plan` and each root, then tflint and checkov, each from a Docker image pinned by digest.
It needs Docker and no cloud credentials, and runs no plan or apply outside `terraform test`.
It exits 0 when every check passed, 1 when one failed and 2 when the checks cannot run, such as with no `docker` or a Docker daemon that does not answer.
CI runs it as the `terraform static checks` job on pull requests and pushes to `main`, not on release tags; it is not a required check.
`tools/tests/terraform_static_test.sh` and `tools/tests/first_boot_test.sh` need neither Terraform nor Docker.

[REHEARSAL.md](REHEARSAL.md) has the checklists for a testnet rehearsal on each cloud.
