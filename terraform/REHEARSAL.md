# Rehearsal checklists

Each checklist below rehearses this deployment on one cloud with the testnet (Adiri), from `terraform init` to `check-node.sh` passing on both hosts and a transaction sent through the gateway's name, and then tears it down.
[README.md](README.md) explains each step; these lists are what to tick.
A line that starts with "Confirm" names something nobody could check without a cloud account or a real host: note what you saw beside it, and report anything that differs.

## Before any cloud

- [ ] Confirm the installer serves `min_scripts_release` or newer (default `scripts-v2.3.0`): `curl --proto '=https' --tlsv1.2 -fsSL https://install.telcoin.network | grep -m1 'TN_SCRIPTS_TAG='` names that release or a later one.
- [ ] If it names an older release, the first boot of both hosts stops at `scripts-release`: confirm once that the log says so and names the command to run again, and that the console line is `TELCOIN-FIRST-BOOT <role>: FAILED at scripts-release`, then wait for the release before going on.
- [ ] Check out this repository at the release tag, and run `bash tools/check-terraform.sh` (it needs Docker, and exits 2 when Docker does not answer).
- [ ] Have ready a testnet execution address, the current testnet release tag (OPERATOR.md section 7.1), the trusted hubs map and a BLS passphrase.
- [ ] Have ready a test name in a domain you control, whose A record you can create and delete.
- [ ] Have ready a funded testnet account and `cast` on your own machine, for the transaction at the end.

## AWS

Plan and first apply:

- [ ] `aws sts get-caller-identity` names the rehearsal account, and `session-manager-plugin --version` runs.
- [ ] `terraform.tfvars` sets `region`, `availability_zone`, `network = "testnet"`, `validator_address`, `node_release_tag`, `trusted_nodes_file` and `rpc_domain = ""`.
- [ ] Confirm `availability_zone` is required and must be a letter zone of `region`: a plan without it stops, and one with a Local Zone such as `us-west-2-lax-1a` is refused.
- [ ] Confirm m7i reports NVMe EBS as required and NitroTPM as supported: `aws ec2 describe-instance-types --instance-types m7i.large m7i.2xlarge m7i.4xlarge --query 'InstanceTypes[].[InstanceType,EbsInfo.NvmeSupport,NitroTpmSupport]'`.
- [ ] Confirm whether Canonical's stock 24.04 and 26.04 AMIs report `tpm_support = v2.0` (`aws ec2 describe-images --image-ids <ami> --query 'Images[0].TpmSupport'`, the AMI from Canonical's SSM parameter of each release); if not, a mainnet deployment needs `allow_no_tpm = true` or an `ami_id` registered with NitroTPM.
- [ ] `terraform init`, then `terraform plan`: no gateway instance, two Elastic IPs, every security group rule as README.md describes.
- [ ] `terraform apply`.

Validator first boot:

- [ ] Confirm Session Manager reaches the validator with `session_command.validator` (the SSM agent comes with Canonical's AMI and the instance profile is attached).
- [ ] Confirm `TELCOIN-FIRST-BOOT validator: ok` reaches the console: `aws ec2 get-console-output --instance-id <id> --latest --output text`.
- [ ] `sudo ls /var/lib/telcoin-first-boot` shows `done`, and `/var/log/telcoin-first-boot.log` shows every step.
- [ ] Confirm the login user `ubuntu` existed when cloud-init's `runcmd` started: the `node-scripts` step did not stop on it.
- [ ] Confirm the data volume appeared as `/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_<volume id without the dash>`.
- [ ] Confirm `blkid`, `mkfs.ext4`, the fstab line and the mount worked on the real disk: the log says the disk was blank and formatted, `findmnt /var/lib/telcoin` shows ext4, and `/etc/fstab` holds one `UUID=... /var/lib/telcoin ext4 defaults,nofail 0 2` line.
- [ ] Confirm a second run formats nothing: `sudo bash /usr/local/libexec/telcoin-first-boot/first-boot-validator.sh` logs that the disk already carries a filesystem, `/etc/fstab` still holds one line, and after `sudo reboot` the disk is mounted again.
- [ ] Confirm `DPkg::Lock::Timeout` held while unattended-upgrades ran: the log shows no dpkg lock failure.
- [ ] Confirm the Elastic IP is the host's public address from first boot: `curl -4 -s https://checkip.amazonaws.com` on the host prints `validator_public_ip`.

Validator setup:

- [ ] Run the steps of `terraform output -raw next_steps` in order: key generation (its `done` event says `"ok":true`), the offline backup, the firewall, finalize and `gateway_upstream`.
- [ ] `sudo bash /home/ubuntu/telcoin-node-scripts/check-node.sh` shows the node catching up.

The name and the second apply:

- [ ] Create the test name's A record for `gateway_public_ip`, and wait until `dig +short <name>` prints that address.
- [ ] Set `rpc_domain`, then `terraform plan` shows the gateway instance and its Elastic IP association, and no change to the validator.
- [ ] `terraform apply`, and `validator_user_data_sha256` is the same as before.

Gateway first boot:

- [ ] Confirm Session Manager reaches the gateway with `session_command.gateway`, and the console shows `TELCOIN-FIRST-BOOT gateway: ok`.
- [ ] Confirm Docker's apt repository and signing key were reachable and the key's fingerprint matched the pinned one: the `docker` step passed.
- [ ] Confirm the real `install-caddy.sh --phase=gateway-check-dns`, `setup-gateway.sh --enable ... --json` and `firewall-setup.sh --enable --ssh-from ...` ran unattended as root, in that order (the `dns`, `gateway` and `firewall` steps of the log), and `curl -sS https://<rpc_domain>/health` from your own machine answers 200.
- [ ] Confirm `firewall-setup.sh --enable` on this host left 80/tcp and 443/tcp open: `sudo ufw status` lists both from Anywhere.
- [ ] Confirm the Elastic IP is the gateway's public address from first boot: `curl -4 -s https://checkip.amazonaws.com` on the host prints `gateway_public_ip`.

Finish:

- [ ] On the validator, run the last step of `next_steps` (`rpc-advertise`), then `check-node.sh` ends `All checks passed -- node is healthy and caught up` once the node has caught up.
- [ ] On the gateway host, `sudo bash /home/ubuntu/telcoin-node-scripts/check-node.sh` reports no issue: the gateway, its DNS, `https://<rpc_domain>/health` over a verified certificate and `ufw` with 80 and 443.
- [ ] From your own machine, a transaction sent with `cast send --rpc-url https://<rpc_domain>/ ...` from the funded account gets its receipt.

Tear down:

- [ ] Delete the test name's A record.
- [ ] Set `prevent_destroy = false` on the data volume, both Elastic IPs and the validator instance in the checkout, run `terraform destroy`, and check in the console that no volume, Elastic IP or instance of `name_prefix` is left.
- [ ] Put the checkout back (`git checkout -- terraform/aws`).

## Google Cloud

Plan and first apply:

- [ ] `gcloud config get-value project` names the rehearsal project, and `gcloud auth application-default login` has run.
- [ ] Confirm `gcloud compute ssh` needs `compute.instances.get` and `compute.projects.get` on the project, which the root does not grant: your account has `roles/compute.viewer` there, or the shell fails.
- [ ] `terraform.tfvars` sets `project`, `region`, `zone`, `network = "testnet"`, `admin_members` with your account, `validator_address`, `node_release_tag`, `trusted_nodes_file` and `rpc_domain = ""`.
- [ ] Confirm `c3-standard-8` (testnet) and `c3d-standard-16` (mainnet) are offered in the zone: `gcloud compute machine-types describe <type> --zone <zone>` for each.
- [ ] Confirm against Google's documentation the machine series the instance-type descriptions name, which were written from memory: C3, C3D, C4 and N4 take Hyperdisk Balanced, N2 and E2 do not; E2, N2 and C3 take pd-balanced, C4 and N4 do not.
- [ ] `terraform init`, then `terraform plan`: no gateway instance, two static external addresses, the firewall rules as README.md describes.
- [ ] `terraform apply`.

Validator first boot:

- [ ] Confirm IAP and OS Login open a shell with `session_command.validator`.
- [ ] Confirm `TELCOIN-FIRST-BOOT validator: ok` reaches the serial console: `gcloud compute instances get-serial-port-output <name_prefix>-validator --zone <zone>`.
- [ ] `sudo ls /var/lib/telcoin-first-boot` shows `done`, and `/var/log/telcoin-first-boot.log` shows every step.
- [ ] Confirm the `ubuntu` user exists on the image at first boot: the `node-scripts` step did not stop on it.
- [ ] Confirm the Hyperdisk Balanced data disk appeared at `/dev/disk/by-id/google-tn-data` on `c3-standard-8`, and, where you can try one, on `c3d-standard-16`.
- [ ] Confirm `blkid`, `mkfs.ext4`, the fstab line and the mount worked on the real disk: the log says the disk was blank and formatted, `findmnt /var/lib/telcoin` shows ext4, and `/etc/fstab` holds one `UUID=... /var/lib/telcoin ext4 defaults,nofail 0 2` line.
- [ ] Confirm a second run formats nothing: `sudo bash /usr/local/libexec/telcoin-first-boot/first-boot-validator.sh` logs that the disk already carries a filesystem, `/etc/fstab` still holds one line, and after `sudo reboot` the disk is mounted again.
- [ ] Confirm `DPkg::Lock::Timeout` held while unattended-upgrades ran: the log shows no dpkg lock failure.

Validator setup:

- [ ] Run the steps of `terraform output -raw next_steps` in order: key generation (its `done` event says `"ok":true`), the offline backup, the firewall, finalize and `gateway_upstream`.
- [ ] After the firewall step, a new `session_command.validator` shell still opens (IAP's range is in the host's SSH sources).
- [ ] `sudo bash /home/ubuntu/telcoin-node-scripts/check-node.sh` shows the node catching up.

The name and the second apply:

- [ ] Create the test name's A record for `gateway_public_ip`, and wait until `dig +short <name>` prints that address.
- [ ] Set `rpc_domain`, then `terraform plan` shows the gateway instance and no change to the validator.
- [ ] `terraform apply`, and `validator_user_data_sha256` is the same as before.

Gateway first boot:

- [ ] Confirm gVNIC works on the gateway's `e2-standard-2`: the host has its network and `session_command.gateway` opens a shell.
- [ ] Confirm the serial console shows `TELCOIN-FIRST-BOOT gateway: ok`.
- [ ] Confirm Docker's apt repository and signing key were reachable and the key's fingerprint matched the pinned one: the `docker` step passed.
- [ ] Confirm the real `install-caddy.sh --phase=gateway-check-dns`, `setup-gateway.sh --enable ... --json` and `firewall-setup.sh --enable --ssh-from ...` ran unattended as root, in that order (the `dns`, `gateway` and `firewall` steps of the log), and `curl -sS https://<rpc_domain>/health` from your own machine answers 200.
- [ ] Confirm `firewall-setup.sh --enable` on this host left 80/tcp and 443/tcp open: `sudo ufw status` lists both from Anywhere.

Finish:

- [ ] On the validator, run the last step of `next_steps` (`rpc-advertise`), then `check-node.sh` ends `All checks passed -- node is healthy and caught up` once the node has caught up.
- [ ] On the gateway host, `sudo bash /home/ubuntu/telcoin-node-scripts/check-node.sh` reports no issue: the gateway, its DNS, `https://<rpc_domain>/health` over a verified certificate and `ufw` with 80 and 443.
- [ ] From your own machine, a transaction sent with `cast send --rpc-url https://<rpc_domain>/ ...` from the funded account gets its receipt.

Tear down:

- [ ] Delete the test name's A record.
- [ ] Set `prevent_destroy = false` on the data disk, both static external addresses and the validator instance in the checkout, run `terraform destroy`, and check that `gcloud compute disks list` and `gcloud compute addresses list` show nothing of `name_prefix`.
- [ ] Put the checkout back (`git checkout -- terraform/gcp`).

## Azure

Plan and first apply:

- [ ] `az account show` names the rehearsal subscription.
- [ ] Confirm Premium SSD v2 and the `Standard_D8s_v5` and `Standard_D16s_v5` sizes are offered in the region and zone: `az vm list-skus --location <location> --zone --output table` lists `PremiumV2_LRS` and both sizes for that zone.
- [ ] `terraform.tfvars` sets `location`, `zone`, `network = "testnet"`, `admin_ssh_public_key`, `admin_ssh_cidrs` or `enable_bastion = true`, `validator_address`, `node_release_tag`, `trusted_nodes_file` and `rpc_domain = ""`.
- [ ] `terraform init`, then `terraform plan`: no gateway VM, two static public IPs, the security rules as README.md describes.
- [ ] Confirm the Canonical image is Trusted Launch capable: `terraform apply` creates the validator VM with secure boot and vTPM on.

Validator first boot:

- [ ] Confirm `session_command.validator` opens a shell, and with `enable_bastion` that `az network bastion ssh` works.
- [ ] Confirm `TELCOIN-FIRST-BOOT validator: ok` reaches the boot log: `az vm boot-diagnostics get-boot-log --name <name_prefix>-validator --resource-group <name_prefix>-rg`.
- [ ] `sudo ls /var/lib/telcoin-first-boot` shows `done`, and `/var/log/telcoin-first-boot.log` shows every step.
- [ ] Confirm cloud-init created the admin user (default `ubuntu`) before `runcmd`: the `node-scripts` step did not stop on it.
- [ ] Confirm `/dev/disk/azure/scsi1/lun0` appears and the data disk attaches within the 10-minute wait, on 26.04 and on 24.04 (WALinuxAgent's udev rules make the link; without it the validator's first boot times out waiting for the device).
- [ ] Confirm `blkid`, `mkfs.ext4`, the fstab line and the mount worked on the real disk: the log says the disk was blank and formatted, `findmnt /var/lib/telcoin` shows ext4, and `/etc/fstab` holds one `UUID=... /var/lib/telcoin ext4 defaults,nofail 0 2` line.
- [ ] Confirm a second run formats nothing: `sudo bash /usr/local/libexec/telcoin-first-boot/first-boot-validator.sh` logs that the disk already carries a filesystem, `/etc/fstab` still holds one line, and after `sudo reboot` the disk is mounted again.
- [ ] Confirm `DPkg::Lock::Timeout` held while unattended-upgrades ran: the log shows no dpkg lock failure.
- [ ] Confirm what the testnet size gives the data disk: `Standard_D8s_v5` caps uncached disk IOPS at 12,800, below the 15,000 the disk is provisioned with (Azure's size documentation, or a read test on `/var/lib/telcoin` with a tool such as `fio`).

Validator setup:

- [ ] Run the steps of `terraform output -raw next_steps` in order: key generation (its `done` event says `"ok":true`), the offline backup, the firewall, finalize and `gateway_upstream`.
- [ ] Confirm the platform address 168.63.129.16, which network security groups do not filter, reaches nothing on the RPC ports but the node itself: `sudo ufw status` admits 8545 and 43174 from the gateway's private address only.
- [ ] `sudo bash /home/<admin_username>/telcoin-node-scripts/check-node.sh` shows the node catching up.

The name and the second apply:

- [ ] Create the test name's A record for `gateway_public_ip`, and wait until `dig +short <name>` prints that address.
- [ ] Set `rpc_domain`, then `terraform plan` shows the gateway VM and no change to the validator.
- [ ] `terraform apply`, and `validator_user_data_sha256` is the same as before.

Gateway first boot:

- [ ] Confirm `session_command.gateway` opens a shell, and the boot log shows `TELCOIN-FIRST-BOOT gateway: ok`.
- [ ] Confirm Docker's apt repository and signing key were reachable and the key's fingerprint matched the pinned one: the `docker` step passed.
- [ ] Confirm the real `install-caddy.sh --phase=gateway-check-dns`, `setup-gateway.sh --enable ... --json` and `firewall-setup.sh --enable --ssh-from ...` ran unattended as root, in that order (the `dns`, `gateway` and `firewall` steps of the log), and `curl -sS https://<rpc_domain>/health` from your own machine answers 200.
- [ ] Confirm `firewall-setup.sh --enable` on this host left 80/tcp and 443/tcp open: `sudo ufw status` lists both from Anywhere.

Finish:

- [ ] On the validator, run the last step of `next_steps` (`rpc-advertise`), then `check-node.sh` ends `All checks passed -- node is healthy and caught up` once the node has caught up.
- [ ] On the gateway host, `sudo bash /home/<admin_username>/telcoin-node-scripts/check-node.sh` reports no issue: the gateway, its DNS, `https://<rpc_domain>/health` over a verified certificate and `ufw` with 80 and 443.
- [ ] From your own machine, a transaction sent with `cast send --rpc-url https://<rpc_domain>/ ...` from the funded account gets its receipt.

Tear down:

- [ ] Delete the test name's A record.
- [ ] Set `prevent_destroy = false` on the data disk, both static public IPs and the validator VM in the checkout, run `terraform destroy`, and check that `az group show --name <name_prefix>-rg` finds no group.
- [ ] Put the checkout back (`git checkout -- terraform/azure`).

## On any cloud, once

- [ ] Confirm Caddy gets the certificate by itself when the A record appears late: with a name whose record you create only after the gateway has booted, the `dns` step logs its warning after 30 minutes and the boot goes on, `https://<name>/health` answers once the record resolves, and `sudo systemctl reload caddy` starts a new attempt at once.

## Mainnet today

Until the script release that enables mainnet is out, a mainnet deployment goes this far, and no further:

- [ ] The installer serves `min_scripts_release` or newer, as above.
- [ ] `network = "mainnet"`, `validator_address` set to the Safe, the default machine types (8 cores, 64 GiB); on AWS the plan's TPM check passes, or `allow_no_tpm` or `ami_id` is set.
- [ ] The first apply and the validator's first boot end `done`.
- [ ] The binary is at `/usr/local/bin/telcoin-network` (OPERATOR.md section 2.12), and key generation ends `"ok":true` and prints the default name, `https://v<label>.telcoin.network/`.
- [ ] `node-keys/` and `node-info.yaml` are backed up offline, and `node-info.yaml` is sent as OPERATOR.md section 2.12 says.
- [ ] The firewall step of `next_steps` has run.
- [ ] `v<label>.telcoin.network` and `tao_handoff.ipv4` went to the TAO, or a name of your own points at `gateway_public_ip`.
- [ ] Once the name resolves, `rpc_domain` is set and the second apply creates the gateway host, whose first boot ends `done`; its log may hold `setup-gateway.sh`'s warning that the network could not be confirmed, since no node answers yet.
- [ ] `sudo bash <dir>/setup-gateway.sh --status` on the gateway host says the image is a placeholder: the testnet release's image, pinned for mainnet until telcoin-network publishes a mainnet release.
- [ ] The name and the certificate check out before genesis: `curl -sS https://<name>/health` from your own machine answers 200, and `check-node.sh` on the gateway host reports DNS and the https probe as OK and `/ready` not 200 as an issue, because no validator runs yet.
- [ ] Finalize, `gateway_upstream` and the validator's `check-node.sh` wait under `==== At launch ====` for the release that enables mainnet.
