# Telcoin Network node operator runbook

Canonical copy: https://github.com/Telcoin-Association/tn-node-deployment

This runbook takes one Linux server from a fresh install to a synced Telcoin Network node, keeps it running, and, for operators the Telcoin Association has approved, walks through staking and activation as a validator.
It covers the scripts in this repository, run on the node itself, plus the `cast` commands you run from the machine that holds your wallet.
The README is the reference; this is the path.
When you need every option of a script, follow the links into the [README](README.md).

Contents:

- [0. Who this is for and vocabulary](#0-who-this-is-for-and-vocabulary)
- [1. Before you start](#1-before-you-start)
- [2. Install](#2-install)
- [3. Confirm the node is syncing, then synced](#3-confirm-the-node-is-syncing-then-synced)
- [4. Day-2 operations](#4-day-2-operations)
- [5. Public RPC (https + wss)](#5-public-rpc-https--wss)
- [6. Validators: stake and activate](#6-validators-stake-and-activate)
- [7. Automation](#7-automation)
- [8. Legacy installs](#8-legacy-installs)
- [9. Troubleshooting](#9-troubleshooting)
- [10. Getting help](#10-getting-help)
- [Appendix: where this repo and the telcoin-network docs disagree](#appendix-where-this-repo-and-the-telcoin-network-docs-disagree)

## 0. Who this is for and vocabulary

Anyone can run a node.
No approval is needed to install one, follow consensus and serve JSON-RPC.
Validating is a separate, on-chain step that only GSMA-approved mobile network operators can take, after the Telcoin Association approves them.
Sections 1 to 5 apply to every operator; section 6 is for validators.

The install is the same for everyone.
Every node is provisioned validator-capable, and nothing in the install decides whether it validates.

| Term | Meaning |
|---|---|
| Node | One `telcoin-network` install on one server, run by the `telcoin` systemd unit. |
| Epoch | The period between committee changes. Testnet epochs are six hours long. |
| Committee | The validators that vote on consensus during one epoch. |
| Validator | A node whose execution address has staked and been activated in the ConsensusRegistry contract. It votes only while it holds a committee seat. |
| Observer | Any node that is not in the current committee. |
| Execution address | The `0x` address you enter at key generation. It stakes, receives rewards, and is signed into the node's proof of possession. |
| BLS key | The node's consensus signing key, stored in `node-keys/` and encrypted with your BLS passphrase. |
| `node-info.yaml` | The node's public identity: BLS public key, proof of possession, P2P addresses and any advertised RPC URLs. |
| ConsensusNFT | A non-transferable token the Association mints to an approved execution address. Staking requires it. |

### Roles are decided on-chain

The protocol derives each node's role every epoch from committee membership.
A node that is not in the current committee is an observer, whether or not it has staked.

There is no `--observer` flag to set.
`v0.15.0-adiri` still accepts `--observer` as a hidden no-op, and later releases reject it with `unexpected argument '--observer'`.
If an old launch file still carries the flag, see [section 8](#8-legacy-installs).

Observers come in two shapes:

- A follower keeps its RPC on `127.0.0.1` and serves only the box it runs on.
- A public-RPC observer also serves `https://` and `wss://` on its own DNS name through Caddy, and advertises those URLs in `node-info.yaml` so wallets and gateways can find it ([section 5](#5-public-rpc-https--wss)).

Becoming a validator takes four steps, in order: Association approval, stake, activation, and committee selection.
The node software does not change between them.

The node reports what it is doing through the `tn_nodeMode` JSON-RPC method:

| `tn_nodeMode` | Meaning |
|---|---|
| `CvvActive` | Voting in the current committee. |
| `CvvInactive` | A committee member that is catching up before it can vote. This should be brief. |
| `Observer` | Not in the current committee. Every follower, every public-RPC observer, and every staked validator between seats reports this. |

## 1. Before you start

### 1.1 Hardware per role

These figures come from the telcoin-network hardware requirements page.
CPU counts are physical cores.
Cloud vCPUs are usually hyperthreads, so an 8 vCPU instance has about 4 physical cores.

| Role | Minimum | Recommended |
|---|---|---|
| Observer, follower | 2 cores, 8 GB RAM | 4 cores, 16 GB RAM |
| Observer, public RPC | 4 cores, 16 GB RAM | 8 cores, 32 GB RAM |
| Validator | 8 cores, 32 GB ECC RAM | 16 cores, 64 GB ECC RAM |

Storage is the same for every role: at least 2 TB of TLC NVMe (10,000 write IOPS, 300 MB/s), 4 TB recommended.
Avoid QLC drives; they wear out under continuous chain writes.

Validators have two network requirements on top of that:

- 200 Mbps symmetric bandwidth at minimum, 1 Gbps recommended.
- A p95 round-trip time well below 1 second to at least 7 of the 10 committee members.

Email support@telcoin.org with your planned hardware before you buy anything for a validator.

The upstream page also recommends turning swap off and running time sync (chrony or systemd-timesyncd) on every node.
A node rejects headers timestamped more than a second ahead of its own clock.
The scripts in this repo check neither, so set both up yourself.

`setup-node.sh` runs a hardware check during preflight and prints one line per role, for example `[OK] Full node (follower): meets minimum` or `[WARN] Validator (minimum): below minimum`.
The check only warns; it never blocks setup.
It counts the logical CPUs that `nproc` reports, so on a cloud instance halve its CPU number before comparing it with the table.
It does not check for ECC memory or NVMe.

### 1.2 Operating system

`setup-node.sh` needs systemd 247 or newer, because it protects the BLS passphrase with systemd `LoadCredential`.
That means Ubuntu 22.04 or later, Debian 12 or later, or RHEL 9 or later.
Older systems stop with `systemd <version> detected -- version 247+ required.`

macOS is not supported by `setup-node.sh`.

A few parts assume a Debian-family system:

- Building from source installs its build dependencies with apt.
- `install-caddy.sh` (public RPC and the public dashboard) installs Caddy from its apt repository.
- `ui/install-ui.sh` installs Python with apt-get when Python 3 is missing.

Preflight also refuses to continue until the CVE-2026-31431 ("Copy Fail") kernel mitigation is in place.
The check passes when a file under `/etc/modprobe.d/`, `/lib/modprobe.d/` or `/run/modprobe.d/` contains `install algif_aead /bin/false` and the `algif_aead` module is not loaded.
Apply the mitigation from https://copy.fail before you start; you may need to unload the module or reboot.
The README has the [detection commands](README.md#cve-2026-31431-copy-fail).

### 1.3 Ports

| Port | Protocol | Open to | Purpose |
|---|---|---|---|
| 49590 | UDP | Everywhere, inbound | Primary P2P (QUIC). Every node. |
| 49594 | UDP | Everywhere, inbound | Worker P2P (QUIC). Every node. |
| 443 | TCP | Everywhere, inbound | Caddy, only when it serves public RPC or the dashboard. |
| 80 | TCP | Everywhere, inbound | Caddy certificate issuance and the http-to-https redirect. Recommended with Caddy. |
| 8545 | TCP | Loopback only | HTTP JSON-RPC. Never open it. |
| 8546 | TCP | Loopback only | WebSocket JSON-RPC. Never open it. |
| 9101 | TCP | Loopback only | Prometheus metrics. |
| 43174 | TCP | 104.155.184.201/32 (plus any monitoring hosts you add) | Health-check endpoint, a testnet add-on. The node listens on it only when you enable the health monitor. |
| 22 (or your SSH port) | TCP | Your admin IPs | SSH. |

Open the two UDP ports on every node, including nodes that may never validate.
A node that stakes later behind a closed port cannot reach the committee and misses consensus without any obvious error.
The UDP ports you open must match the ports in the multiaddrs you advertise at key generation.

Open them in every layer that filters traffic: `ufw` on the host (section 2.6), the cloud provider's firewall or security group, and the router's port forwards if the server is behind NAT.

### 1.4 Have these ready

- The execution address (`0x...`) the node will be registered under. For a validator this is the address that stakes and receives rewards, so it should live in a hardware wallet. It is signed into the proof of possession at key generation; changing it later needs `keytool generate pop` and a new `node-info.yaml`.
- A BLS passphrase, stored somewhere offline. The node needs it on every start.
- The server's public IP, and whether it sits behind NAT. Setup detects the public IP with api.ipify.org and the internal IP from the network interface and builds the default multiaddrs from them; correct them at the prompts if they are wrong.
- A mounted data drive with an `/etc/fstab` entry, if the chain data will not live on the boot disk.
- A DNS A record for the node's public name, if you want public RPC (section 5).
- Somewhere off the server to keep a backup of the node keys (section 2.5).
- For validators: an approval request with the Association in progress (support@telcoin.org), and a machine with Foundry's `cast` and your wallet.

## 2. Install

### 2.1 Get the scripts

Run the installer as your normal user, without `sudo`, so the scripts land in your own home directory at `~/telcoin-node-scripts`:

```bash
curl -fsSL https://install.telcoin.network | bash
```

If `install.telcoin.network` is unreachable, the raw GitHub URL is a drop-in replacement:

```bash
curl -fsSL https://raw.githubusercontent.com/Telcoin-Association/tn-node-deployment/main/install.sh | bash
```

Or clone the repository yourself:

```bash
git clone https://github.com/Telcoin-Association/tn-node-deployment.git ~/telcoin-node-scripts
```

If `~/telcoin-node-scripts` already exists, the installer asks `Re-install and overwrite? [y/N]`.
To pick up newer scripts on an existing install, run `bash ~/telcoin-node-scripts/update-scripts.sh` instead (section 4.1).

### 2.2 Run setup

```bash
sudo bash ~/telcoin-node-scripts/setup-node.sh
```

Setup is interactive and runs in the order below.
Most prompts show their default in brackets; press Enter to accept it.
Yes/no prompts default to No.

1. Welcome. Answer `y` to `Ready to begin node setup?`.
2. Preflight ("Step 1 of 8"). Setup checks that it runs as root, detects the distribution and runs the CVE-2026-31431 gate. It lists your mounted filesystems and physical disks, then asks `Data directory [/var/lib/telcoin]`. Enter a path on your data drive if you have one. It then runs the hardware check, an internet check, a port check (in-use ports only warn), installs `curl` and `git` if missing, and checks for systemd 247 or newer.
3. Network. Choose `1) Adiri Testnet (Chain ID: 2017)`. Mainnet is listed as coming soon and returns you to the menu. Devnet is not offered interactively.
4. Testnet add-ons (testnet only). Each is off by default: the health-monitor endpoint on TCP 43174, log shipping, metrics shipping, a region label if you turned either shipping option on, and VPN admin SSH. See [docs/testnet-addons.md](docs/testnet-addons.md) before you opt in.
5. Install method. See section 2.3. Source builds first ask `Install missing packages now?` if build dependencies are missing (answer y; No exits), then show a version picker whose default on testnet is the latest `-adiri` release tag. Docker installs ask for the image, defaulting to the newest `-adiri` tag. "I already have it" first offers a binary it finds (`Use this binary?`) and asks `Full path to telcoin binary:` only if it finds none or you decline.
6. BLS passphrase protection (not asked for Docker). This menu comes after the source build (20 to 40 minutes) or the Docker install and image pull. For source builds the passphrase question comes only after the build finishes, so stay attached to the session. `1) systemd LoadCredential` suits most operators. `2) TPM/vTPM sealing` ties the passphrase to this machine's TPM; it falls back to LoadCredential if no TPM is found. Type `1` or `2`; Enter alone is not accepted.
7. Node configuration ("Step 3 of 8"). First, RPC access: `1) Private` keeps RPC on `127.0.0.1`; `2) Public` asks for the node's DNS name, then always asks for an optional inbound public IP (Enter auto-detects; set it behind NAT; section 5). Then the ports: P2P primary `49590`, P2P worker `49594`, RPC `8545`, metrics `9101`. Then `Use these default paths?` for the config, log and install directories, and an optional advertised node name.
8. System infrastructure ("Step 4 of 8"). Service user and group, both `telcoin` by default. The user gets no login shell. Docker installs give it UID 1101. Docker and existing installs may be asked `Clone the repository now to get the chain-config files?`; answer y, because No means copying the chain configs by hand before step 10.
9. Keys ("Step 5 of 8"). If `node-keys/` already exists, setup asks `Overwrite existing keys?`. On a re-run, answer No (section 6.12). Otherwise it asks for the execution address, prints the detected public IP (it asks for one only if detection fails), then asks for the external primary and worker addresses and, after printing the detected internal IP, the listener primary and worker addresses. Each shows a default built from the detected IP, such as `/ip4/<public-ip>/udp/49590/quic-v1`; check the IP in them. Then it asks for the BLS passphrase twice. The keytool writes the keys and `node-info.yaml`, setup prints `node-info.yaml` and the on-chain next steps, and it waits at `Press Enter to confirm you have backed up your keys`. Do the backup in section 2.5 before you press Enter.
10. Configuration ("Step 6 of 8"). Copies `genesis.yaml`, `committee.yaml` and `parameters.yaml` into the data directory. If it cannot find them, it prints where to get them and waits for you to copy them in.
11. Service ("Step 7 of 8"). Writes the start wrapper, the systemd unit and `/etc/telcoin/.node-meta`, then asks `Start the node now?`. Only if you answer yes and the service comes up does it ask `Enable auto-start on server reboot?`. Answer yes to both.
12. Public RPC, only if you gave a domain and the node started. Setup checks DNS and enables the endpoint. If DNS is not ready yet, setup still finishes and prints the exact command to run later.
13. Testnet add-ons you opted into are applied. Log or metrics shipping asks for your ingest token (hidden; leave it blank to skip).
14. A summary with the paths, ports and next steps.

Setup has no `--help`, and it ignores arguments it does not recognise without a warning, so check the spelling of any flag you pass.
The public RPC flags are covered in section 5 and the full list in section 7.

### 2.3 Install methods

| Menu choice | `--install-method` | What it does | How it updates |
|---|---|---|---|
| `1) Build from source` | `source` | Installs Rust and the build dependencies, clones telcoin-network to `/opt/telcoin-source`, builds it (20 to 40 minutes; log in `/tmp/tn-build.log`) and installs `/opt/telcoin/telcoin-network`. | `update-node.sh` |
| `3) Docker` | `docker` | Installs Docker if missing and pulls the image from `us-docker.pkg.dev/telcoin-network/tn-public/adiri`. The default tag is the newest `-adiri` tag in the registry, or `v0.15.0-adiri` if the registry cannot be reached. | `update-node.sh` |
| `4) I already have it` | `existing` | Uses a `telcoin-network` binary you supply. | By hand: replace the binary and restart the service. |
| `2) Pre-built binary` | none | Not available yet; the menu sends you back. | |

The README has more on [install options](README.md#binary-installation-options) and [network binding](README.md#network-binding).

### 2.4 Where things land

| Path | What it is |
|---|---|
| `/opt/telcoin/telcoin-network` | The node binary for source builds. An `existing` install runs the binary from the path you gave setup (`Binary=` in its summary). |
| `/opt/telcoin/start-telcoin.sh` | Start wrapper. It reads the BLS passphrase and holds the node's launch command and flags. |
| `/etc/systemd/system/telcoin.service` | The systemd unit, `telcoin`. Docker installs also name the container `telcoin`. |
| `/var/lib/telcoin/node-keys/` | BLS and P2P keys. Back these up. |
| `/var/lib/telcoin/node-info.yaml` | Public identity and advertised URLs. |
| `/var/lib/telcoin/genesis/`, `/var/lib/telcoin/parameters.yaml` | Chain configuration. |
| `/var/lib/telcoin/db/` | Chain database. This is what grows. |
| `/etc/telcoin/bls-passphrase` | BLS passphrase, mode 600, owned by the service user. |
| `/etc/telcoin/.node-meta` | Install settings the other scripts read. Root-only (mode 600), so run the scripts with `sudo`. |
| `/var/log/telcoin/telcoin.log`, `telcoin-error.log` | Node output. |
| `/opt/telcoin-source/` | The telcoin-network source tree (source builds). |

If you chose a different data directory, read it in place of `/var/lib/telcoin` everywhere in this runbook.
The README's [System Layout](README.md#system-layout) shows the full tree.

### 2.5 Back up the keys now

Losing `node-keys/` means losing the node's identity.
If you have not staked yet, you can regenerate keys and carry on.
Once you have staked, you have to go back to the Association.

Back up `node-keys/` and `node-info.yaml` together, and keep the BLS passphrase somewhere else (a password manager or paper in a safe), never next to the archive.
In a second terminal on the server:

```bash
(umask 077; sudo tar -C /var/lib/telcoin -czf - node-keys node-info.yaml > ~/telcoin-keys.tgz)
```

Copy the archive off the server from your own machine, then delete it from the server:

```bash
scp user@SERVER_IP:telcoin-keys.tgz .
ssh user@SERVER_IP 'shred -u ~/telcoin-keys.tgz'
```

Treat the archive as a secret.
Then go back to setup and press Enter.

### 2.6 Firewall

```bash
sudo bash ~/telcoin-node-scripts/firewall-setup.sh
```

Choose `2) Enable firewall with recommended defaults`.
It sets inbound to deny and outbound to allow, allows SSH, allows TCP 43174 from the Association monitor only, and allows UDP 49590 and 49594 when a node is installed.
It asks whether to reset to a clean slate first; No keeps your existing rules.

SSH stays open to the whole internet after this.
To restrict it, use `5) Manage trusted IP whitelist` to add your own IP or range first, then remove the blanket SSH rule from the same menu.
Adding a whitelist entry does not remove the blanket rule by itself.
Test SSH from a new terminal before you close the current one.

`ufw` is only the host layer.
Open UDP 49590 and 49594 in the cloud firewall or security group as well, and forward them on the router if the server sits behind NAT.
The README covers the rest of the [firewall script](README.md#firewall-setup).

## 3. Confirm the node is syncing, then synced

Check that the service is up and watch its log for a minute:

```bash
systemctl status telcoin
journalctl -u telcoin -f
```

Then run the health check:

```bash
sudo bash ~/telcoin-node-scripts/check-node.sh
```

It compares your node with the network's public RPC (`https://rpc.telcoin.network`) and ends with one verdict:

- `CATCHING UP: <N> execution blocks behind` while the node is more than 50 blocks behind the network (the script's `EVM_SYNC_THRESHOLD`).
- `All checks passed -- node is healthy and caught up (EVM lag <N>)` once it has caught up.
- `<N> issue(s) found -- review warnings/errors above` when something else is wrong.

Run it twice a few minutes apart.
The second run also reports how far the local block advanced since the first, which tells you whether the gap is closing.
When the node binary supports `tn_nodeMode`, the report also prints a `Consensus role:` line.
The script always exits 0, so anything that consumes it should read the verdict line, not the exit code.

### Checking by hand

Do not use `eth_syncing`.
On Telcoin Network it returns `false` even while the node is catching up.
Compare `eth_blockNumber` on your node with the public RPC instead:

```bash
bn() { curl -s -X POST -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' "$1" \
  | sed -E 's/.*"result":"(0x[0-9a-fA-F]+)".*/\1/'; }
echo "local:   $(( $(bn http://127.0.0.1:8545) ))"
echo "network: $(( $(bn https://rpc.telcoin.network) ))"
```

The node is synced when the two numbers stay within a few blocks of each other.

To see the node's consensus role:

```bash
curl -s -X POST -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"tn_nodeMode","params":[]}' \
  http://127.0.0.1:8545
```

Any node outside the committee returns `"Observer"`, including a staked validator that has not been seated yet.

### How long it takes

There is no published figure for a first sync; it depends on chain height, disk and bandwidth.
Watch the lag shrink rather than waiting for a fixed time.
Each restart replays recent consensus output before the node catches up again, so a node that is restarted often stays behind.
If the lag does not shrink between runs, see [section 9](#9-troubleshooting).

## 4. Day-2 operations

### 4.1 Keep the scripts current

```bash
bash ~/telcoin-node-scripts/update-scripts.sh
```

Run it as your normal user, without `sudo`.
It compares every tracked file with the latest version on GitHub, asks `Download and install all updates? [Y/n]`, and checks each download against its published SHA-256 before installing it.
If the Node Manager UI is installed and has changed, it redeploys the UI too and may ask for your sudo password.

Run it before every node update.
`update-node.sh` learns how to handle new releases through these updates.

### 4.2 Update the node

```bash
sudo bash ~/telcoin-node-scripts/update-node.sh
```

The script works out whether the node was built from source or runs in Docker and offers the matching versions.
Source installs get the same version picker as setup, defaulting to the latest `-adiri` tag; Docker installs get the recent registry tags, newest first, with the latest and current ones marked.
Then it asks how far to go:

- `1) Prepare only` builds the binary or pulls the image while the node keeps running. Apply it later in a quiet window.
- `2) Prepare AND apply` also stops the node, swaps in the new version, restarts it and checks its health.
- `3) Cancel`, or any other input, cancels.

A prepared update survives between runs.
The next run offers `1) Apply now`, `2) Discard and prepare a different update` or `3) Exit`, and `sudo bash ~/telcoin-node-scripts/update-node.sh --discard` drops it after asking `Discard this pending update?`.

What else to expect:

- On a node registered on-chain as a validator (status 1 to 4), or one whose status cannot be read, the script shows a downtime warning and asks you to type `CONFIRM` before it stops the node.
- After the restart it waits up to 45 seconds for the service to be active and for the node to answer `tn_latestConsensusHeader`. When many nodes restart at once, quorum takes longer to form; raise the window with `TN_UPDATE_VERIFY_TIMEOUT`, in seconds, for example `sudo TN_UPDATE_VERIFY_TIMEOUT=120 bash ~/telcoin-node-scripts/update-node.sh`.
- If that check fails, it offers to roll back to the previous binary or image.
- Only one update runs at a time. A second run stops with `Another update is already running (PID N).`
- It never touches the keys, `node-info.yaml`, the BLS passphrase, the chain configuration, or the listener addresses.
- When the target release is `v0.15.0-adiri` or newer and the launch file still passes `--observer`, it removes the flag.

`existing` installs are not updated by the script: replace the binary yourself and restart the service.
After any update, run `sudo bash ~/telcoin-node-scripts/check-node.sh`.

### 4.3 Change the configuration

```bash
sudo bash ~/telcoin-node-scripts/edit-config.sh
```

The menu covers listener addresses, the metrics address, log verbosity, the BLS passphrase file, P2P ports, the Docker image, refreshing the chain configs, and restarting the node.
Before any change it backs up the launch file to `<file>.bak.<timestamp>`, and changes take effect on the next restart.

Two cautions:

- For public RPC, use `install-caddy.sh` (section 5), not the menu's "RPC access" item. reth must stay on `127.0.0.1`.
- Change the P2P ports only to fix a conflict. The new ports must be open in every firewall layer and must match the multiaddrs in `node-info.yaml`.

### 4.4 Service commands

```bash
sudo systemctl start telcoin
sudo systemctl stop telcoin
sudo systemctl restart telcoin
journalctl -u telcoin -f
sudo tail -f /var/log/telcoin/telcoin.log
sudo systemctl reset-failed telcoin   # after too many failed restarts
```

The README has the full [command reference](README.md#quick-reference--common-commands).

### 4.5 Node Manager UI

The optional web UI shows health, logs and configuration, and can run updates.
Install it on the node:

```bash
sudo bash ~/telcoin-node-scripts/ui/install-ui.sh
```

It listens on `127.0.0.1:8080` only.
Reach it from your own machine through an SSH tunnel, either with the helper script from a local copy of this repo or by hand:

```bash
./open-ui.sh user@SERVER_IP
ssh -L 8080:localhost:8080 user@SERVER_IP   # then open http://localhost:8080
```

To reach the dashboard on a public HTTPS name, run `sudo bash ~/telcoin-node-scripts/install-caddy.sh` and choose `[1] Dashboard`; Caddy then serves it behind a login.
Public access is read-only; management stays on the tunnel.
The dashboard needs its own hostname, such as `dashboard.<your-node-domain>`, separate from the public RPC name.
See [Web UI](README.md#web-ui-optional) and [external dashboard access](README.md#external-dashboard-access-optional-via-caddy).

### 4.6 Testnet add-ons

The health monitor, log shipping, metrics shipping and VPN admin SSH can be turned on after setup:

```bash
sudo bash ~/telcoin-node-scripts/setup-observability.sh   # health, logs, metrics
sudo bash ~/telcoin-node-scripts/setup-vpn.sh             # VPN admin SSH
```

Read [docs/testnet-addons.md](docs/testnet-addons.md) for what each one shares and how to turn it off, and [WGVPN.md](WGVPN.md) before enrolling in the VPN.

### 4.7 Remove a node

If the node serves public RPC, turn that off first, because `remove-node.sh` does not touch Caddy:

```bash
sudo bash ~/telcoin-node-scripts/install-caddy.sh --phase=rpc-disable
sudo bash ~/telcoin-node-scripts/remove-node.sh
```

The removal script asks before each component: service, Docker container and image, chain data, keys, binary, source tree, logs, service user, and the UI.
Deleting the keys needs you to type `DELETE`.
Do not delete the keys of a staked validator unless you hold a tested backup.
Menu option `2) Wipe chain data only` keeps the keys and configuration and makes the node resync from scratch.

## 5. Public RPC (https + wss)

Public RPC serves your node's JSON-RPC at `https://<domain>/` and its WebSocket at `wss://<domain>/`, and advertises both URLs in `node-info.yaml` so wallets and gateways can discover the node.
reth itself stays on `127.0.0.1`.
Caddy holds the TLS certificate on port 443 and proxies to reth on loopback.

It is a deliberate choice.
The Caddy site has no authentication and no rate limiting, so anyone can send requests to it.
It suits observers that are meant to serve the public.
The upstream validator guidance is to keep a validator's RPC off the public internet; read the appendix before you turn this on for a validator.

The README section [Public RPC endpoint](README.md#public-rpc-endpoint-https--wss) covers the internals; the steps are below.

### 5.1 DNS first

Create an A record for the node's public name pointing at the server's inbound public IP, and wait until it resolves, before you enable anything.
Caddy requests a Let's Encrypt certificate as soon as the site loads; if the name does not point at the server yet, issuance fails and repeated attempts get rate-limited.

- Allow inbound TCP 443 (required) and TCP 80 (recommended) in every firewall layer, and forward both on the router if the server is behind NAT.
- Behind NAT, or on a server with several addresses, pass the inbound IP with `--public-ip <ip>`. The address the scripts detect is the outbound one, which can differ.
- The RPC name and the dashboard name must be different, for example `node7.example.com` for RPC and `dashboard.node7.example.com` for the dashboard.

### 5.2 New install

```bash
DOMAIN=node7.example.com   # your node's public name
sudo bash ~/telcoin-node-scripts/setup-node.sh --rpc-domain "$DOMAIN"
sudo bash ~/telcoin-node-scripts/setup-node.sh --rpc-domain "$DOMAIN" --public-ip 203.0.113.10   # behind NAT
```

Or answer `2) Public` at the RPC access prompt.
With a domain, key generation writes `https://<domain>/` and `wss://<domain>/` into `node-info.yaml` when the release's keytool supports advertising RPC (`--rpc-http`, present since `v0.12.0-adiri`).
After the node starts, setup checks DNS and runs `install-caddy.sh --phase=rpc-enable`, which does not restart the node when `node-info.yaml` already holds those URLs.
If DNS is not ready, setup finishes anyway and prints the command to run later.

`--no-public-rpc` keeps RPC private without asking. It cannot be combined with `--rpc-domain` or `--rpc-public`; setup stops with an error (an `error` event in `--json` mode).
`--rpc-public` without `--rpc-domain` leaves RPC private and prints a warning with the command to enable it later.

### 5.3 Existing node

Check DNS first, then enable:

```bash
DOMAIN=node7.example.com   # your node's public name
sudo bash ~/telcoin-node-scripts/install-caddy.sh --phase=rpc-check-dns --rpc-domain "$DOMAIN"
sudo bash ~/telcoin-node-scripts/install-caddy.sh --phase=rpc-enable --rpc-domain "$DOMAIN"
```

`rpc-check-dns` changes nothing and exits 0 only when the name reaches this server.
`rpc-enable` writes the Caddy site, opens 80 and 443 in `ufw` when `ufw` is active, makes sure reth serves WebSocket, sets the advertised URLs in `node-info.yaml`, and restarts the node once if anything there changed.
Add `--public-ip <ip>` behind NAT.
If the dashboard already uses this name, create the A record for `dashboard.<domain>` and add `--move-dashboard-to dashboard.<domain>` to move it in the same run.
For a guided run, start `sudo bash ~/telcoin-node-scripts/install-caddy.sh` and choose `[2] Public RPC endpoint`.

`rpc-enable` does not write any keys to `.node-meta`.

### 5.4 Verify

```bash
curl -s https://$DOMAIN/ -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}'
```

On testnet the answer is `"result":"0x7e1"` (chain ID 2017).
The first request after enabling can take a few seconds while the certificate is issued.

For WebSocket, connect with `websocat wss://$DOMAIN/` or `wscat -c wss://$DOMAIN/` and send the same JSON request.

```bash
sudo bash ~/telcoin-node-scripts/check-node.sh
sudo bash ~/telcoin-node-scripts/install-caddy.sh --phase=rpc-status
```

The health check has a public RPC block that probes https and wss through Caddy, shows what `node-info.yaml` advertises, and ends with `public RPC: OK` or `public RPC: WARN -- <reasons>` plus the command that fixes it.
Run it with `sudo`; without root it can only report `public RPC: unknown (.node-meta not readable — run with sudo)`.
`--phase=rpc-status` shows whether the site is enabled, what is advertised, and whether reth's WebSocket port is listening.

### 5.5 Turn it off

```bash
sudo bash ~/telcoin-node-scripts/install-caddy.sh --phase=rpc-disable
```

This clears the advertised URLs from `node-info.yaml`, restarts the node, removes the Caddy site, and closes 80 and 443 in `ufw` once no Caddy site remains.

## 6. Validators: stake and activate

The stake and activation calls go to the ConsensusRegistry contract at `0x07E17e17E17e17E17e17E17E17E17e17e17E17e1`, the same address on testnet and devnet.
The BLS keys never leave the node: you export the stake calldata on the node, then sign and send the transaction from the machine that holds your wallet.
The telcoin-network "how to stake" page shows outdated `stake` and `unstake` signatures; use the commands below.

### 6.1 Prerequisites

- Association approval. Only GSMA-approved mobile network operators can validate; start with support@telcoin.org.
- Hardware at the validator tier (section 1.1).
- UDP 49590 and 49594 reachable from the internet (section 1.3).
- A synced node (section 3).
- A publicly routable RPC URL advertised in `node-info.yaml` (section 5). Other nodes forward user transactions to the committee's advertised URLs and skip private addresses, unless the chain's `parameters.yaml` sets `allow_private_forward_targets: true` (it defaults to `false`).
- Foundry's `cast` on the wallet machine, and the wallet holding your execution address.

### 6.2 Set variables

On the wallet machine:

```bash
REG=0x07E17e17E17e17E17e17E17E17E17e17e17E17e1
RPC=https://rpc.telcoin.network
ADDR=0xYOUR_EXECUTION_ADDRESS
```

### 6.3 Confirm the ConsensusNFT

```bash
cast call $REG "balanceOf(address)(uint256)" $ADDR --rpc-url $RPC
```

`1` means the Association has minted your ConsensusNFT and you can stake.
`0` means approval is not complete yet.

### 6.4 Export the stake calldata on the node

The keytool reads only `node-info.yaml`; it needs neither the passphrase nor the private keys.
Source builds (an `existing` install uses its own binary path):

```bash
sudo /opt/telcoin/telcoin-network keytool export-staking-args \
  --node-info /var/lib/telcoin/node-info.yaml --calldata
```

Docker installs:

```bash
IMAGE=$(sudo sed -n 's/^DOCKER_IMAGE=//p' /etc/telcoin/.node-meta)
sudo docker run --rm -v /var/lib/telcoin:/home/nonroot/data:ro "$IMAGE" \
  telcoin keytool export-staking-args \
  --node-info /home/nonroot/data/node-info.yaml --calldata
```

`export-staking-args` ships with current releases.
If the keytool does not recognise it, update the node first (section 4.2).

Copy the `0x...` output to the wallet machine and check that it is calldata for the right function:

```bash
CALLDATA=0x...   # paste the output here
[ "${CALLDATA:0:10}" = "$(cast sig 'stake(bytes,(bytes))')" ] && echo "calldata OK"
```

### 6.5 Read the stake amount

```bash
cast call $REG "getCurrentStakeConfig()(uint256,uint256,uint256,uint32)" --rpc-url $RPC
STAKE=$(cast call $REG "getCurrentStakeConfig()(uint256,uint256,uint256,uint32)" --rpc-url $RPC | awk 'NR==1 {print $1}')
```

The four values are the stake amount in wei, the minimum reward withdrawal, the issuance per epoch, and the epoch length in blocks.
`STAKE` holds the first one; send exactly that amount, or the call reverts with `InvalidStakeAmount`.
Read it just before you stake, because a new stake configuration takes effect at the next epoch.
Once you have staked, the amount that applies to your validator is fixed by the stake version recorded on it (the sixth field of `getValidator`), which you can look up with `stakeConfig(uint8)`.

### 6.6 Stake

```bash
cast send $REG $CALLDATA --value $STAKE --from $ADDR --ledger --rpc-url $RPC
```

Use `--trezor` for a Trezor.
`--interactive` asks for a raw private key; avoid it for a funded validator address.

### 6.7 Activate

Once the node is synced and the stake has landed (status `1`, Staked):

```bash
cast send $REG "activate()" --from $ADDR --ledger --rpc-url $RPC
```

Status moves to `2` (PendingActivation) and then to `3` (Active) at the next epoch boundary.

### 6.8 Watch your status

```bash
cast call $REG "getValidator(address)(address,uint32,uint32,uint8,bool,uint8,uint8)" $ADDR --rpc-url $RPC
```

The seven lines are the validator address, activation epoch, exit epoch, status, `isRetired`, stake version and region.
The fourth line is the status (section 6.10).
The same information, with the next step spelled out, comes from:

```bash
sudo bash ~/telcoin-node-scripts/check-node.sh --address $ADDR
```

Other signals:

- The Node Manager UI switches to the validator view once the node is synced and its on-chain status is 1 to 4.
- `tn_nodeMode` (section 3) changes from `Observer` to `CvvActive` while the node holds a committee seat.
- The current epoch and its committee:

```bash
cast call $REG "getCurrentEpoch()(uint32)" --rpc-url $RPC
cast call $REG "getCurrentEpochInfo()((address[],uint256,uint64,uint32,uint32,uint8))" --rpc-url $RPC
```

The second call's output starts with the list of committee addresses.

### 6.9 When you get a committee seat

The committee for each epoch is fixed two epochs in advance.
Expect your first possible seat at the third epoch boundary after `activate()`, which is 12 to 18 hours on testnet's six-hour epochs; the exact lead time is a protocol parameter.
Selection is random only when there are more eligible validators than seats.
Between seats an Active validator reports `Observer`, which is normal.

### 6.10 Status values

| Status | Name | What it means | Your next step |
|---|---|---|---|
| (call reverts) | No record | No ConsensusNFT for this address. | Finish Association approval. |
| 0 | Undefined | NFT minted, not staked. | Stake (6.4 to 6.6). |
| 1 | Staked | Stake received. | `activate()` once synced. |
| 2 | PendingActivation | Activation queued. | Wait for the next epoch boundary. |
| 3 | Active | Eligible for committee seats. | Keep the node healthy. |
| 4 | PendingExit | `beginExit()` called. | Wait until the protocol exits you. |
| 5 | Exited | Out of the validator set. | Wait one more epoch, then `unstake` (6.11). |
| 6 | Any | A reserved sentinel. On its own you should never see it. | Contact the Association. |
| 6 with `isRetired` true | Retired | `unstake` ran: NFT burned, stake returned. | None. This identity cannot stake again. |

`check-node.sh` prints `Status: Retired` for the last row and appends ` (Retired)` to any other status that has `isRetired` set.
The scripts treat statuses 1 to 4 as staked and everything else as not staked.

### 6.11 Rewards and exit

Claim accrued rewards without exiting, once they reach `minWithdrawAmount` (the second value of the stake configuration):

```bash
cast send $REG "claimStakeRewards(address)" $ADDR --from $ADDR --ledger --rpc-url $RPC
```

To leave, call `beginExit()` while Active:

```bash
cast send $REG "beginExit()" --from $ADDR --ledger --rpc-url $RPC
```

It reverts if too few validators would remain.
The status moves to PendingExit (4), and the protocol exits you once no current or upcoming committee needs you.
When the status reads Exited (5), wait one more epoch, then reclaim the stake:

```bash
cast send $REG "unstake(address,bool)" $ADDR false --from $ADDR --ledger --rpc-url $RPC
```

`unstake` permanently retires the validator and burns its ConsensusNFT.
The address cannot be reused, and validating again needs new keys and a new NFT.
The second argument, `acceptRewardShortfall`, stays `false`; `true` forfeits any rewards the Issuance contract cannot cover.
`unstake` also works while the status is still Staked (1), before activation.

### 6.12 What not to do

- Never regenerate keys for a staked identity, and never pass `--force` to the keytool for one. The registered BLS key would no longer match the node.
- Never run the same keys on two servers at once.
- When you re-run `setup-node.sh` on a staked node, answer No to `Overwrite existing keys?`.

## 7. Automation

### 7.1 Setup without prompts

`setup-node.sh --json` runs in two phases so you can back up the keys in between.
Pass the same flags to both phases:

```bash
read -rs TN_BLS_PASSPHRASE && export TN_BLS_PASSPHRASE
IMAGE=us-docker.pkg.dev/telcoin-network/tn-public/adiri:v0.15.0-adiri   # the tag you want
ARGS=(--network testnet --install-method docker --docker-image "$IMAGE"
  --address 0xYOUR_EXECUTION_ADDRESS
  --external-primary /ip4/203.0.113.10/udp/49590/quic-v1
  --external-worker  /ip4/203.0.113.10/udp/49594/quic-v1
  --listener-primary /ip4/10.0.0.5/udp/49590/quic-v1
  --listener-worker  /ip4/10.0.0.5/udp/49594/quic-v1)
sudo --preserve-env=TN_BLS_PASSPHRASE bash ~/telcoin-node-scripts/setup-node.sh --json --phase=keygen "${ARGS[@]}"
# back up node-keys/ and node-info.yaml now (section 2.5)
sudo bash ~/telcoin-node-scripts/setup-node.sh --json --phase=finalize "${ARGS[@]}"
```

- `keygen` runs preflight, installs dependencies, creates the service user and generates the keys. It writes no unit and starts nothing, and it refuses to run if `node-keys/` already exists.
- `finalize` writes the configuration, creates and starts the service, and enables public RPC when you pass `--rpc-domain`.
- The passphrase comes only from `TN_BLS_PASSPHRASE`; keep it off the command line.
- Each phase prints one JSON object per line on stdout, with `event` set to `step`, `log`, `error` or `done`. The last line is `{"event":"done","ok":true|false,...}`. Human-readable output goes to stderr.
- `--network` takes `testnet` (or `adiri`) or `devnet`. Mainnet is coming.
- `--install-method` takes `source` (with `--build-ref <tag>`) or `docker` (with `--docker-image <ref>` on both phases; `--json` mode does not detect the image, and `finalize` would write a launch file with no image). `existing` is not reliable with `--json`: there is no flag for the binary path and `finalize` assumes `/opt/telcoin/telcoin-network`, so install the binary there first or use the interactive setup.
- Other flags: `--data-dir`, `--passphrase-method loadcredential|tpm`, `--public-ip`, `--advertised-name`, `--service-user`, `--service-group`, `--genesis-dir`, `--enable-healthcheck-monitor`, and the public RPC flags from section 5.

### 7.2 Advertised RPC URL flags

`--rpc-domain <d>` fills in all four of these, so most installs never pass them:

| Flag | Written to | Derived from `--rpc-domain <d>` |
|---|---|---|
| `--rpc-http <url>` | `node-info.yaml`, published to the network | `https://<d>/` |
| `--rpc-ws <url>` | `node-info.yaml`; needs `--rpc-http` or `--rpc-domain`, otherwise it is ignored with a warning | `wss://<d>/` |
| `--public-rpc-url <url>` | `.node-meta` `PUBLIC_RPC_URL`, for the UI and tooling only | `https://<d>` |
| `--public-ws-url <url>` | `.node-meta` `PUBLIC_WS_URL` | `wss://<d>` |

An explicit flag wins and is used as given.
Derived URLs reach key generation only when the keytool supports `--rpc-http`; otherwise they are written when `rpc-enable` runs.
If an explicit URL differs from the domain, setup warns that `rpc-enable` will replace it.

### 7.3 Other scripts

| Script | Non-interactive forms |
|---|---|
| `install-caddy.sh` | `--phase=rpc-status`, `rpc-check-dns`, `rpc-enable`, `rpc-disable` and the dashboard phases `status`, `check-dns`, `enable`, `disable`, with or without `--json`. The dashboard password comes from `TN_CADDY_PASSWORD`. |
| `update-node.sh` | `--json --check`, `--json --prepare --ref <ref>`, `--json --apply --yes`, `--json --discard`. A failed apply rolls back; its `done` line carries `"ok":false` and a boolean `rolled_back` (`true` when the rollback succeeded). |
| `firewall-setup.sh` | `--reset`, `--json --status`, `--json --enable`, `--json --port <49590/udp\|49594/udp\|43174/tcp> <on\|off>`. |
| `edit-config.sh` | `--json --set <field>=<value>` for `primary_listener`, `worker_listener`, `metrics`, `verbosity` or `docker_image`. |
| `remove-node.sh` | `--json --remove observer\|validator --scope service\|data\|keys --yes [--remove-ui]`. The `--remove` value is a UI slot name, not a role; either one removes the node. |
| `migrate-node-naming.sh` | `--yes`. |

The status and DNS-check phases and `update-node.sh --json --check` print a single JSON object instead of an event stream.
`TN_ASSUME_YES=true` answers yes to the scripts' yes/no prompts.
`check-node.sh` has no JSON mode and always exits 0, so parse its verdict line.

## 8. Legacy installs

Older versions of these scripts installed role-named units, `telcoin-observer` or `telcoin-validator`, with per-role directories such as `/etc/telcoin/observer` and `/var/lib/telcoin/observer`.
Every script still finds and manages those installs.
To move one to the unified `telcoin` layout:

```bash
sudo bash ~/telcoin-node-scripts/migrate-node-naming.sh
```

It stops the node, moves the directories, rewrites the unit and start wrapper, opens UDP 49590 and 49594 in `ufw`, and restarts the node.
The keys stay as they are, and a custom data mount stays in place.
It strips `--observer` and `--instance` from the launch command, so RPC moves to the default ports 8545 and 8546 (an observer that ran with `--instance` was on other ports, such as 8541 and 8554).
If that node serves public RPC, run `install-caddy.sh --phase=rpc-enable --rpc-domain <domain>` again afterwards so Caddy points at the new ports; until then the public endpoint returns 502.
If any step fails, the script restores the old install and restarts it.
`--yes` skips the confirmation prompt.
Delete the backups it lists once the node is healthy.

If you keep a legacy layout, still get rid of `--observer` before you move past `v0.15.0-adiri`: `update-node.sh` removes it when it updates to `v0.15.0-adiri` or later, and `check-node.sh` warns while the launch file still carries it.
`setup-observer.sh` and `setup-validator.sh` are deprecated shims that forward to `setup-node.sh`.

## 9. Troubleshooting

Start with `sudo bash ~/telcoin-node-scripts/check-node.sh` and `journalctl -u telcoin -n 200`.

| Symptom | Cause | Fix |
|---|---|---|
| The node will not start after an update; the log shows `unexpected argument '--observer'` | The launch file still passes `--observer`, which releases after `v0.15.0-adiri` reject. | `bash ~/telcoin-node-scripts/update-scripts.sh`, then `sudo bash ~/telcoin-node-scripts/update-node.sh`. Or delete the `--observer` token from `/opt/telcoin/start-telcoin.sh` (the unit file on a legacy Docker install), then `sudo systemctl daemon-reload && sudo systemctl restart telcoin`. |
| `check-node.sh` warns `Launch file ... still passes --observer` | Same flag, caught before an update. | Same fix, before you update. |
| `check-node.sh` prints `note: --observer is ignored; the role is decided on-chain each epoch` | Role flags are retired; `update-node.sh` and `edit-config.sh` ignore them too. | Drop `--observer` and `--validator` from your commands. |
| `tn_nodeMode` returns `Observer` while `getValidator` shows Active | Not seated yet, or between seats. | Normal. See section 6.9. |
| `tn_nodeMode` stays at `CvvInactive` | A committee member that has not caught up. | Treat it like a lagging node (next row). |
| `CATCHING UP` and the lag does not shrink between runs | Peers cannot reach the node, the disk is full or slow, or the node keeps restarting. | Check UDP 49590 and 49594 in every firewall layer, check that the external multiaddrs in `node-info.yaml` carry the current public IP, check disk space, and look for restarts in the journal. |
| `eth_syncing` returns `false` while the node is behind | Expected on Telcoin Network. | Compare `eth_blockNumber` instead (section 3). |
| Preflight prints `[WARN] <role>: below minimum` | The server is under that role's minimum. | A warning only. Remember the check counts logical CPUs. |
| `systemd <version> detected -- version 247+ required.` | The OS is too old. | Move to Ubuntu 22.04+, Debian 12+ or RHEL 9+. |
| `CVE-2026-31431 (Copy Fail) -- setup cannot continue` | The `algif_aead` module is not blocked, or is still loaded. | Apply the mitigation from https://copy.fail, unload the module or reboot, re-run setup. |
| `Port <port>/<proto> (...) is already in use.` | Another process holds the port. | Find it with `sudo ss -lunp` (UDP) or `sudo ss -ltnp` (TCP); stop it or choose another port. |
| `<domain> already serves the Node Manager dashboard -- the dashboard and the public RPC endpoint need DIFFERENT hostnames` | RPC and dashboard on one name. | Create `dashboard.<domain>` in DNS, then add `--move-dashboard-to dashboard.<domain>` to `rpc-enable`. |
| `rpc-check-dns` fails, or setup says `Public RPC not enabled yet` | The A record is missing, not propagated, or points at the outbound IP of a NAT host. | Fix the record, pass `--public-ip <inbound-ip>` behind NAT, then re-run `rpc-enable`. |
| The certificate is not issued, or Let's Encrypt reports a rate limit | DNS or ports 80/443 were wrong when Caddy asked. | Fix DNS and the ports first, then wait out the rate limit; repeated attempts extend it. |
| `port 80 is in use by 'apache2'` (or 443, or nginx) | Another web server holds the ports Caddy needs. | `sudo systemctl disable --now apache2` (or nginx), or run `sudo bash ~/telcoin-node-scripts/install-caddy.sh` and let it guide you. |
| `public RPC: unknown (.node-meta not readable — run with sudo)` | `check-node.sh` ran without root. | Run it with `sudo`. |
| `wss://<domain>/` returns 502 | Nothing listens on the WebSocket port 8546 yet. | Wait if the node is still starting. Otherwise check `install-caddy.sh --phase=rpc-status`; after `migrate-node-naming.sh`, re-run `rpc-enable`. |
| The node cannot decrypt its BLS key at start | `/etc/telcoin/bls-passphrase` does not hold the passphrase the keys were generated with, or a TPM install can no longer unseal after a TPM reset or rebuild. | Restore the correct passphrase; `edit-config.sh` option 5 rewrites the file but never re-encrypts the keys. A TPM install needs the passphrase you stored offline ([TPM notes](README.md#option-2--tpmvtpm-sealing-advanced)). |
| `stake` reverts with `RequiresConsensusNFT` | No ConsensusNFT for the sending address. | Check section 6.3 and that `--from` is your execution address. |
| `stake` reverts with `InvalidStakeAmount` | `--value` differs from the stake amount. | Re-read the amount (section 6.5). |
| `stake` reverts with `InvalidProofOfPossession` | The calldata was signed for a different execution address or node. | Re-export on this node and send from the address you entered at keygen. If the address has to change, contact the Association first. |
| `stake` or `activate` reverts with `InvalidStatus` | The validator is not in the status the call needs. | Check the status (section 6.8). |
| `stake` reverts with `DuplicateBLSPubkey` | This BLS key is already registered. | Contact the Association. Do not regenerate keys. |
| `beginExit` reverts | The validator is not Active yet, or too few validators would remain. | Wait, then retry. |
| `unstake` reverts with `IneligibleUnstake` | The validator is neither Staked nor one epoch past Exited. | Wait for Exited plus one epoch. |
| `systemctl status telcoin` shows `start-limit-hit` | Five failed starts within 60 seconds. | Fix the cause from the journal, then `sudo systemctl reset-failed telcoin && sudo systemctl start telcoin`. |

## 10. Getting help

Email support@telcoin.org for everything, validator onboarding, approval and hardware included.

Include:

- The full output of `sudo bash ~/telcoin-node-scripts/check-node.sh` (add `--address <your address>` for validators).
- The last 200 log lines: `journalctl -u telcoin -n 200 --no-pager`.
- The node version (Docker image tag, or the tag you built) and the script versions that `update-scripts.sh` lists.
- The network (testnet or devnet) and your install method.

Never send the contents of `node-keys/` or your BLS passphrase.

## Appendix: where this repo and the telcoin-network docs disagree

| Topic | This repo | telcoin-network docs | Trust |
|---|---|---|---|
| Worker P2P port | UDP 49594 | UDP 49595 | This repo. Whatever you choose, the open port must match the worker multiaddr in `node-info.yaml`. |
| Public RPC URL | `https://rpc.telcoin.network` (and `wss://`) | `https://rpc.adiri.tel`, without WebSocket | This repo. |
| Operating systems | systemd 247+: Ubuntu 22.04+, Debian 12+, RHEL 9+ | Debian 11+, Ubuntu 20.04+, RHEL 8 | This repo for `setup-node.sh`; older systems fail its systemd check. |
| `stake` / `unstake` | `stake(bytes,(bytes))`, `unstake(address,bool)` | `stake(bytes,(bytes,bytes))`, `unstake(address)` | The deployed contracts, which match this runbook. |
| Contact | support@telcoin.org for everything | Two addresses, used for different things on different pages | Section 10. |
| RPC exposure | Any node can serve public RPC through Caddy and advertise it, and the committee's advertised URLs are where other nodes forward transactions. | Keep validator RPC off the public internet; serve the public from observers. | Both hold: a validator must advertise a reachable URL to receive forwarded transactions, so choose deliberately and protect it (section 5). |
| CPU counts | The preflight counts logical CPUs (`nproc`). | Physical cores. | The docs. Halve a cloud instance's vCPU count. |
