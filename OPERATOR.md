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
`v0.15.0-adiri` still accepts `--observer` as a hidden no-op; `v0.16.0-adiri` and later refuse to start with it (`unexpected argument '--observer'`, exit status 2).
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
| `CvvInactive` | A committee member that is catching up before it can vote, for example after a long restart. This should be brief. From the next release it refuses new transactions meanwhile (section 9). |
| `Observer` | Not in the current committee. Every follower, every public-RPC observer, and every staked validator between seats reports this. |

## 1. Before you start

### 1.1 Hardware per role

The testnet figures follow the five Adiri validators: Google Cloud c3-highcpu-8 machines (4 cores (8 vCPU), 16 GB, Intel Sapphire Rapids), each with a 350 GB pd-ssd disk, which Google caps at 15,000 IOPS and 240 MiB/s on that machine size.
The mainnet validator storage figure comes from Telcoin's published benchmarks at [benchmark.telcoin.network](https://benchmark.telcoin.network).
In the [latest run](https://benchmark.telcoin.network/runs/r20261115-1653/), 10 validators on 8 vCPU and 16 GB with a 20,000 IOPS, 800 MiB/s volume averaged about 9,300 transactions a second, with write IOPS at about 20,000 at the 95th percentile and about 286 MiB/s written.
Execution ran strictly in sequence: the engine was busy about 978 ms of every second while the machine used about 56 % of its 8 vCPUs.
The other mainnet figures come from the hardware requirements page in the telcoin-network documentation.
CPU counts are physical cores, written with the matching cloud vCPU count.
Cloud vCPUs are usually hyperthreads, so an 8 vCPU instance has about 4 physical cores.
Prioritise single-core performance: EVM execution is single-threaded, so a high clock speed matters more than extra cores.

Testnet (Adiri):

| Role | Minimum | Recommended |
|---|---|---|
| Observer, follower | 2 cores (4 vCPU), 8 GB RAM | 4 cores (8 vCPU), 16 GB RAM |
| Observer, public RPC | 4 cores (8 vCPU), 16 GB RAM | 8 cores (16 vCPU), 32 GB RAM |
| Validator | 3 cores (6 vCPU), 16 GB RAM | 4 cores (8 vCPU), 16 GB RAM |
| Storage, every role | 350 GB SSD (15,000 IOPS, 240 MB/s) | 500 GB TLC NVMe |
| Validator bandwidth | 200 Mbps symmetric | 1 Gbps |

Mainnet:

| Role | Minimum | Recommended |
|---|---|---|
| Observer, follower | 2 cores (4 vCPU), 8 GB RAM | 4 cores (8 vCPU), 16 GB RAM |
| Observer, public RPC | 4 cores (8 vCPU), 16 GB RAM | 8 cores (16 vCPU), 32 GB RAM |
| Validator | 8 cores (16 vCPU), 32 GB ECC RAM | 16 cores (32 vCPU), 64 GB ECC RAM |
| Storage, validator | 2 TB TLC NVMe (20,000 write IOPS, 300 MB/s) | 4 TB |
| Storage, observer | 2 TB TLC NVMe (10,000 write IOPS, 300 MB/s) | 4 TB |
| Validator bandwidth | 200 Mbps symmetric | 1 Gbps |

Avoid QLC drives; they wear out under continuous chain writes.

Validators also need a p95 round-trip time well below 1 second to at least 7 of the 10 committee members.

Email support@telcoin.org with your planned hardware before you buy anything for a validator.

The upstream page also recommends turning swap off and running time sync (chrony or systemd-timesyncd) on every node.
A validator holds its vote on a header timestamped ahead of its own clock until that lead has passed, on testnet today for a lead of up to one second.
It rejects a header more than its drift tolerance plus the five-second vote timeout ahead: 5.25 seconds with the default 250 ms tolerance, six seconds on a data dir whose `network-config` still holds the whole-second `max_header_time_drift_tolerance: 1` an older release wrote.
The scripts in this repo check neither, so set both up yourself.

The page recommends three more settings for every node:

- Put the data directory on ext4 or xfs. The node preallocates disk blocks with `fallocate` as its storage files grow, so a full disk fails a write and the node stops cleanly. On a filesystem without `fallocate` (ext2, ext3, NFS, many FUSE filesystems) a full disk can crash it with SIGBUS, and btrfs or ZFS do not guarantee the space.
- Leave the node's virtual address-space limit unlimited: no `ulimit -v`, no systemd `LimitAS=`. From the next release the consensus database reserves about 62 GiB of address space (16 GiB for each of its three logs, 1 GiB for each of its 14 table indexes), which is neither RAM nor disk. Under a limit that release logs `MmapDataFile: could not reserve <n> bytes of address space ...`, and under a tight one a later write fails and the node stops. The unit that setup writes has no `LimitAS=` line, so a default install needs no change.
- On bare metal, turn off CPU and NVMe power saving (the `performance` governor, `nvme_core.default_ps_max_latency_us=0`). Cloud guests usually cannot.

The scripts check neither the filesystem nor the power settings.

`setup-node.sh` runs a hardware check during preflight, once you have picked the network, and prints one line per role against that network's table, for example `[OK] Validator (minimum): meets minimum (3 cores (6 vCPU) / 16 GB / 350 GB)` on testnet.
A role below its minimum gets a warning that lists only what falls short, such as `[WARN] Validator (minimum): below minimum — needs ≥ 8 cores (16 vCPU) (have 4 physical cores)` on mainnet.
The check only warns; it never blocks setup.
It counts physical cores where the server reports them, so an 8 vCPU cloud instance with 4 physical cores meets the testnet validator minimum, 3 cores (6 vCPU), but not the mainnet one, 8 cores (16 vCPU).
Its `Detected:` line says what it counted: `4 physical cores`, or `8 logical CPUs` plus a note when only the logical count can be read.
It compares the RAM and the total size of the filesystem that holds the data directory with the table, and prints the recommended validator row without checking it.
It does not check ECC memory, NVMe, IOPS or throughput.
Devnet uses the testnet table.

### 1.2 Operating system

Ubuntu 26.04 LTS is the recommended OS on every network; Ubuntu 24.04 LTS stays supported.
A mainnet node needs Ubuntu 24.04 or later (systemd 255 or newer), because there the BLS passphrase is kept only as an encrypted systemd credential.
Testnet and devnet need systemd 247 or newer: Ubuntu 22.04 or later, Debian 12 or later, or RHEL 9 or later.
Between 247 and 249, systemd cannot encrypt credentials, so setup warns and keeps the passphrase in the root-only file `/etc/telcoin/bls-passphrase`; once the host runs systemd 250 or later, `sudo bash ~/telcoin-node-scripts/edit-config.sh --migrate-credential` encrypts it (section 4.3).
Older systems stop with `systemd <version> is too old: the node needs 247 or later (Ubuntu 22.04 or later; Ubuntu 24.04 or later for mainnet; Ubuntu 26.04 recommended).`

macOS is not supported by `setup-node.sh`.

A few parts assume a Debian-family system:

- Building from source installs its build dependencies with apt.
- `install-caddy.sh` (public RPC and the public dashboard) installs Caddy from its apt repository.
- `ui/install-ui.sh` installs Python with apt-get when Python 3 is missing.

Preflight also refuses to continue until the CVE-2026-31431 ("Copy Fail") kernel mitigation is in place.
The check passes when a file under `/etc/modprobe.d/`, `/lib/modprobe.d/` or `/run/modprobe.d/` contains `install algif_aead /bin/false` and the `algif_aead` module is not loaded.
Apply the mitigation from https://copy.fail before you start; you may need to unload the module or reboot.
The README has the [detection commands](README.md#cve-2026-31431-copy-fail).

To see how the host stands before you install, run `sudo bash ~/telcoin-node-scripts/setup-node.sh --audit`.
It changes nothing, prints one `ok`, `warn` or `info` line per item and exits 1 when any line warns:

- the systemd version against the credential floor;
- how the BLS passphrase is stored (method, credential key, file owner and mode; never the value), plus any plaintext copy, old TPM-sealed file or unit that still holds the passphrase, each with the `edit-config.sh --migrate-credential` command that clears it;
- whether systemd-creds can use a TPM2;
- whether the data and config directories sit on a dm-crypt device (cloud disk encryption is not visible from the host, so its absence is only `info`);
- core dumps: the unit's `LimitCORE=`, `fs.suid_dumpable` and `kernel.core_pattern`;
- `kernel.yama.ptrace_scope`;
- the host baseline (section 4.13): `HOST_BASELINE` in `.node-meta`, the audit rules file and whether the kernel has the rules loaded, and the AIDE baseline with its age. Without the baseline the line is `info  host baseline: off`; run without `sudo`, the checks that need root say `not checked`.

`sudo bash ~/telcoin-node-scripts/check-node.sh --audit` prints the same report on an installed node.

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
| 43174 | TCP | 104.155.184.201/32 (plus any monitoring hosts you add) | Health-check endpoint, an add-on of testnet and devnet. The node listens on it only when you enable the health monitor. On `v0.16.0-adiri` it listens on every interface; from the next release the bare port the scripts pass listens on `127.0.0.1` only, out of the monitor's reach (section 4.6). |
| 22 (or your SSH port) | TCP | Your admin IPs | SSH. |
| 443 (or your monitor's port) | TCP | Outbound only, to your monitor | Private alerts (section 4.14), when you enable them. No inbound port opens for them. |

Open the two UDP ports on every node, including nodes that may never validate.
A node that stakes later behind a closed port cannot reach the committee and misses consensus without any obvious error.
The UDP ports you open must match the ports in the multiaddrs you advertise at key generation.
49590 and 49594 are conventions, not something the node enforces: it uses the ports in its own multiaddrs.
If you set the node up on other ports, open those instead; `check-node.sh` and `firewall-setup.sh` (`1) View current firewall status`) show the ports the node really uses, every worker included.

Open them in every layer that filters traffic: `ufw` on the host (section 2.6), the cloud provider's firewall or security group, and the router's port forwards if the server is behind NAT.

### 1.4 Have these ready

- The execution address (`0x...`) the node will be registered under. For a validator this is the address that stakes and receives rewards, so it should live in a hardware wallet. It is signed into the proof of possession at key generation. Until it stakes, `prepare-stake.sh --rotate-address` can switch the node to another address (section 6.6); after that it cannot change.
- A BLS passphrase, stored somewhere offline. It cannot be empty, hold a line break, or start or end with whitespace, and on mainnet it needs at least 16 bytes. Setup stores it for the node, which needs it on every start.
- The server's public IP, and whether it sits behind NAT. Setup detects the public IP with api.ipify.org and the internal IP from the network interface and builds the default multiaddrs from them; correct them at the prompts if they are wrong.
- A mounted data drive with an `/etc/fstab` entry, if the chain data will not live on the boot disk.
- A DNS A record for the node's public name, if you want public RPC (section 5).
- Somewhere off the server to keep a backup of the node keys (section 2.5).
- For validators: an approval request with the Association in progress (support@telcoin.org), and a machine with Foundry's `cast` and your wallet.

### 1.5 Networks and endpoints

| Network | Chain ID | Public RPC | Explorer |
|---|---|---|---|
| Adiri testnet | 2017 (`0x7e1`) | `https://rpc.adiri.tel` | `https://telscan.io` or `https://www.telscan.xyz` |
| Mainnet | 731 (`0x2db`) | `https://rpc.telcoin.network` is reserved; the endpoint is confirmed at launch | Not launched yet |
| Devnet | 32285 (`0x7e1d`) | `https://rpc.devnet.telcoin.network` | None |

The public RPCs sit behind a load balancer and answer JSON-RPC over HTTPS only; a WebSocket upgrade gets HTTP 405.
For `wss://`, use a node that serves public RPC (section 5).

Mainnet has not launched, and the scripts still lack two mainnet values that are set at launch:

- the SHA-256 pins of the mainnet `genesis.yaml`, `committee.yaml` and `parameters.yaml`. Without them no mainnet release can be verified, so every mainnet install, release download, Docker image change and chain-config refresh is refused;
- the mainnet public RPC. `https://rpc.telcoin.network` is reserved for it, and today it answers for the testnet (chain 2017).

A script release that sets them is announced at launch; until then a mainnet install stops before it changes anything.
This release also keeps mainnet switched off (`TN_MAINNET_ENABLED=0` in `lib/common.sh`): option 2 of the setup network menu still reads `(coming soon)` and answers `Mainnet has not launched yet.`, `setup-node.sh --json --network mainnet` stops with `Mainnet is not enabled in this script release (lib/common.sh TN_MAINNET_ENABLED); nothing on this host was changed.`, and the Node Manager UI refuses a mainnet setup.
The launch release switches it on together with the pins.
One mainnet step is open before that: validators generate their mainnet keys with their own binary before the genesis exists (section 2.12, `TN_MAINNET_KEYGEN_ENABLED=1` in `lib/common.sh`).
The mainnet image package is already set: `ghcr.io/telcoin-association/tn-mainnet`, where the release pipeline publishes the mainnet images (testnet's are in `ghcr.io/telcoin-association/tn-testnet`; the release tag picks the package).
A mainnet node names its image by its release tag, and the digest comes from the signed release; a digest given alone is taken only when `.node-meta` records it as the image of a mainnet release this node has installed (section 4.3).
Before you treat an endpoint as a given network, check its chain ID:

```bash
curl -s -X POST -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' https://rpc.telcoin.network
```

`"result":"0x7e1"` is the testnet, `0x2db` mainnet and `0x7e1d` devnet.
The scripts run this check themselves: when an RPC serves another chain than the node's, `check-node.sh` warns and skips its network comparison, and `prepare-stake.sh` stops.

Setup records the node's network in `/etc/telcoin/.node-meta` as `NETWORK=testnet`, `mainnet` or `devnet`.
`check-node.sh`, `prepare-stake.sh` and the chain-config refresh in `edit-config.sh` take the network from that line; `check-node.sh` and `prepare-stake.sh` also take the public RPC from it.

## 2. Install

### 2.1 Get the scripts

Run the installer as your normal user, without `sudo`, so the scripts land in your own home directory at `~/telcoin-node-scripts`:

```bash
curl --proto '=https' --tlsv1.2 -fsSL https://install.telcoin.network | bash
```

The installer is pinned to one signed script release (a `scripts-v*` tag).
It checks that release's `MANIFEST.asc` with `gpgv` against the release keys built into the installer and every file against its `MANIFEST` hash, and only then puts the files in `~/telcoin-node-scripts`; on any failure nothing is installed and an existing install stays as it was.
It needs curl or wget, tar, `base64`, `sha256sum` (or `shasum`) and `gpgv`. Stock Ubuntu has them all; where `gpgv` is missing, run `sudo apt-get install -y gpgv` (on macOS, `brew install gnupg`).
There is no raw GitHub fallback: `install.sh` installs only the signed release it names (the copy on `main` names the latest one), never the tip of `main`.

If `~/telcoin-node-scripts` already exists, the installer asks `Re-install and overwrite? [y/N]`; `| bash -s -- --yes` answers yes without the prompt, and the old copy is restored if the new install fails.
To check a release by hand instead, see section 4.10.
To pick up newer scripts on an existing install, run `bash ~/telcoin-node-scripts/update-scripts.sh` instead (section 4.1).

### 2.2 Run setup

```bash
sudo bash ~/telcoin-node-scripts/setup-node.sh
```

Setup is interactive and runs in the order below.
Most prompts show their default in brackets; press Enter to accept it.
Yes/no prompts default to No.
A prompt for a port, a directory, the Docker image, the binary path, the execution address or a multiaddr (external or listener) asks again until the answer is valid.
Directories must be absolute paths of letters, digits and `. _ / -`, without `..`.

1. Welcome. Answer `y` to `Ready to begin node setup?`.
2. Preflight ("Step 1 of 8"). Setup checks that it runs as root, takes the update lock (`/run/telcoin/update.lock`), detects the distribution, tells needrestart not to restart the node and unattended upgrades not to reboot the host, and runs the CVE-2026-31431 gate. It lists your mounted filesystems and physical disks, then asks `Data directory [/var/lib/telcoin]`. Enter a path on your data drive if you have one. It then runs a port check (in-use ports only warn) and installs `curl` and `git` if missing.
3. Network. Choose `1) Adiri Testnet (Chain ID: 2017)`. `2) Mainnet (Chain ID: 731)` is marked coming soon and returns you to the menu. Devnet is not offered interactively. Setup then checks the internet connection, runs the hardware check against that network's table (section 1.1), and checks the systemd floor for the network (section 1.2).
4. Testnet add-ons (testnet only). Each is off by default: the health-monitor endpoint on TCP 43174, log shipping, metrics shipping, a region label if you turned either shipping option on, and VPN admin SSH. The region label keeps only letters, digits, `_` and `-`, up to 32 characters; setup warns when it shortens one. See [docs/testnet-addons.md](docs/testnet-addons.md) before you opt in. Then, on every network, setup asks `Set up private alerts once the node is running?` (section 4.14): a yes only marks them pending, and the monitor URLs are asked for at step 13.
5. Install method. See section 2.3. Source builds first ask `Install missing packages now?` if build dependencies are missing (answer y; No exits), then show a picker of the network's release tags (`vX.Y.Z-adiri` on testnet); a branch or a commit id is refused. The build runs as the `tn-build` account, so stay attached to the session for the 20 to 40 minutes it takes. `2) Signed release` asks for the release tag and downloads and checks it (section 2.3). Docker installs ask for the image: a release tag, the image by digest, or Enter for the newest release (section 2.3); setup resolves a tag to its digest and runs the image by digest only. A testnet release candidate (`vX.Y.Z-adiri-rcN`) is installed only when you type or pass its tag; no default offers one. "I already have it" first offers a binary it finds (`Use this binary?`) and asks `Full path to telcoin binary:` only if it finds none or you decline.
6. Passphrase storage. There is no menu. At the end of preflight setup picks how the node will keep the BLS passphrase: as an encrypted systemd credential, `/etc/telcoin/bls-passphrase.cred`, wherever systemd-creds works (systemd 250 or later), sealed with the TPM2 as well when the host has a usable one; otherwise, on testnet and devnet only, in the root-only file `/etc/telcoin/bls-passphrase`. A mainnet host with no usable TPM2 stops unless you pass `--allow-no-tpm`. Section 2.8 covers the flags.
7. Node configuration ("Step 3 of 8"). First, RPC access: `1) Private` keeps RPC on `127.0.0.1`; `2) Public` asks for the node's DNS name, then always asks for an optional inbound public IP (Enter auto-detects; set it behind NAT; section 5). Then the ports: P2P primary `49590`, P2P worker `49594`, RPC `8545`, metrics `9101`. Then `Use these default paths?` for the config, log and install directories, and an optional advertised node name.
8. System infrastructure ("Step 4 of 8"). Service user and group, both `telcoin` by default. Setup creates the user as a system account with no login shell, and refuses `root`, `telcoin-ui`, an existing account outside the system UID range (1 to 999) and any account in the `sudo`, `adm`, `docker` or `wheel` group. Setup no longer forces a UID; an existing UID 1101 account that an older setup made for a Docker install is accepted when it has no login shell and no admin group. Setup then lays out the directories with root as owner (section 2.4) and creates the `telcoin-log` group for log readers. If you passed node flags (section 2.7), setup asks the installed release here whether it has them, and stops before any key is made if it does not. Then it puts the chain configs in `/etc/telcoin/chain-configs/<network>/` (section 2.4): `genesis.yaml`, `committee.yaml` and `parameters.yaml` as they are at the tag this script release pins (`v0.16.0-adiri` on testnet), never from the default branch. It reads them from the telcoin-network checkout `/opt/telcoin-source` without pulling it or checking anything out, and runs no git at all when the directory already holds the pinned files. Docker, signed-release and existing installs may have no checkout; setup then asks `Clone the repository now to get the chain-config files?`; answer y, which clones at the tag without submodules, because No means copying the chain configs by hand before step 10. When the host cannot reach GitHub, setup reads the tag from the checkout's local copy and says so; section 9 lists the warnings and refusals of this step.
9. Keys ("Step 5 of 8"). If `node-keys/` already exists, setup asks `Overwrite existing keys?`. On a re-run, answer No (section 6.12). Otherwise it asks for the execution address, prints the detected public IP (it asks for one only if detection fails), then asks for the external primary and worker addresses and, after printing the detected internal IP, the listener primary and worker addresses. Each shows a default built from the detected IP, such as `/ip4/<public-ip>/udp/49590/quic-v1`; check the IP in them. Then it asks for the BLS passphrase twice. The keytool writes the keys and `node-info.yaml`, setup prints `node-info.yaml` and the staking steps (with the live stake amount and a pointer to `prepare-stake.sh`, section 6), and it waits at `Press Enter to confirm you have backed up your keys`. Do the backup in section 2.5 before you press Enter.
10. Configuration ("Step 6 of 8"). Copies `genesis.yaml`, `committee.yaml` and `parameters.yaml` into the data directory after checking each against the SHA-256 the script release pins for the network (on testnet, the files of `v0.16.0-adiri`). It looks for them in the `--genesis-dir` directory when you gave one, then, on testnet, in `/etc/telcoin/chain-configs/testnet/`, then in the checkout, and last in `/etc/telcoin/chain-configs/<network>/` on a network without a pinned tag. If it cannot find them, it names the tag and the GitHub page that holds the three files, asks you to copy them into `/etc/telcoin/chain-configs/<network>/`, readable by the service user, or to run setup again with `--genesis-dir <dir>`, and waits for you to copy them in.
11. Service ("Step 7 of 8"). Stores the passphrase (step 6), then writes `/etc/telcoin/node.env` (the listener addresses), the start script `/usr/local/libexec/telcoin/tn-start` (`tn-start-docker` for Docker), the systemd unit and `/etc/telcoin/.node-meta`, then asks `Start the node now?`. Only if you answer yes and the service comes up does it ask `Enable auto-start on server reboot?`. Answer yes to both.
12. Public RPC, only if you gave a domain and the node started. Setup checks DNS and enables the endpoint. If DNS is not ready yet, setup still finishes and prints the exact command to run later.
13. Testnet add-ons you opted into are applied. Log or metrics shipping asks for your ingest token (hidden; leave it blank to skip). If you asked for private alerts and the node is running, setup then runs `setup-alerts.sh --enable`, which asks for the monitor URLs and sends a test heartbeat; otherwise they stay pending, and the summary says `Private alerts: pending. To finish: sudo bash setup-alerts.sh`.
14. A summary with the paths, the P2P ports `node-info.yaml` advertises (every worker), a firewall reminder for those ports, the next steps and a link to this runbook.

`sudo bash ~/telcoin-node-scripts/setup-node.sh --help` lists the public RPC flags and the node flags.
An argument setup does not recognise is reported on stderr as `Unknown argument: <arg>`, and setup carries on without it, so check the spelling of any flag you pass.
The public RPC flags are covered in section 5, the node flags in section 2.7 and the flags for unattended runs in section 7.

### 2.3 Install methods

| Menu choice | `--install-method` | What it does | How it updates |
|---|---|---|---|
| `1) Build from source` | `source` | Clones telcoin-network to `/opt/telcoin-source` over https, checks out a release tag (refused when origin's tag moved or its signature is bad), and builds it as the unprivileged `tn-build` account (home `/var/lib/tn-build`) with a Rust toolchain from a pinned `rustup-init`. The build takes 20 to 40 minutes; its log goes to `/var/lib/telcoin-staging/tn-build-log.*`. Each build command runs as `tn-build` with no inherited file descriptors, and every process of that account is stopped before root copies the output. The build account checks `--version` on a fresh copy (root never runs a downloaded or built binary), and root installs its own copy as `/opt/telcoin/telcoin-network`. `--allow-dirty` (testnet, interactive) discards local changes in the source tree instead of stopping. | `update-node.sh` |
| `2) Signed release` | `release` | Downloads `SHA256SUMS`, `SHA256SUMS.asc`, `IMAGE_DIGEST` and the x86_64 tarball of a release tag into `/var/lib/telcoin-staging`, checks the signature with `gpgv` against the keys in `lib/release-keys/`, checks every file and the chain-config lines against `SHA256SUMS` and the pins, then installs only the binary as `/opt/telcoin/telcoin-network`. Release tarballs are x86_64 only; on aarch64 the install stops with `Release TAG has no aarch64-unknown-linux-gnu tarball`. | `update-node.sh` |
| `3) Docker` | `docker` | Installs Docker from Docker's apt repository after checking its signing key fingerprint, turns on `live-restore` in `/etc/docker/daemon.json` (an empty file counts as `{}`; anything but one JSON object stops setup with the manual step), and pulls the network's image by digest and checks the pulled digest. Images come from the network's package, where the release pipeline publishes them: `ghcr.io/telcoin-association/tn-mainnet` on mainnet, `ghcr.io/telcoin-association/tn-testnet` on testnet; testnet also takes the legacy Artifact Registry repository `us-docker.pkg.dev/telcoin-network/tn-public/adiri`, which holds `v0.16.0-adiri` and older (`TN_TESTNET_IMAGE_REPOS`). The old single package `ghcr.io/telcoin-association/telcoin-network` never held a release and is refused for every new pull. After the pull, setup runs the image's `--version` once and checks its build features against the network (none on mainnet, `adiri` on testnet, `faucet` allowed); an image that does not fit is refused before any container starts or `.node-meta` is written. The default is the newest final release of the network on GitHub, by the digest its signed `IMAGE_DIGEST` names. On testnet only, while the network has no release on GitHub (the next release, planned as `v0.17.0-adiri`, will be the first) or GitHub cannot be read, the default falls back, with a warning, to the newest final tag of the legacy repository by the digest the registry serves, then to `v0.16.0-adiri@sha256:b905b098...`. A tag such as `latest` is refused, and so are `--docker-image` and `--release-tag` together in an interactive run. A mainnet Docker install is refused before anything on the host changes until a mainnet release can be verified (section 1.5). Devnet takes `<repository>@sha256:<digest>` only, from the legacy repository or `ghcr.io/telcoin-association/tn-dev` (`TN_DEVNET_IMAGE_REPOS`), and refuses `--release-tag`: devnet tags end in `-devnet` and have no signed release. Devnet images are not checked for their build features. `tn-public/adiri` also holds testnet images, so on devnet the digest you pin is the guard. | `update-node.sh` |
| `4) I already have it` | `existing` | Uses a `telcoin-network` binary you supply. | By hand: replace the binary the node runs and restart it (section 4.2). |

Release tags are `vX.Y.Z-adiri` on testnet and `vX.Y.Z` on mainnet. Testnet also takes a release candidate, `vX.Y.Z-adiri-rcN`, but only when you name it: `--release-tag`, `--docker-image`, a tag typed at a prompt or in a picker, or an update ref. No default picks one: not setup's Docker default, the source picker's default, `update-node.sh --check`, update-node's Docker tag menu or the UI's default image. Release candidates are accepted on testnet, and taking one only when it is named is the conservative reading of that rule. Mainnet takes final releases only. A release candidate's binary reports the version without the suffix (`Version: X.Y.Z`).

The README has more on [install options](README.md#binary-installation-options) and [network binding](README.md#network-binding).

### 2.4 Where things land

| Path | What it is |
|---|---|
| `/opt/telcoin/telcoin-network` | The node binary for source and release installs, root-owned in root-owned directories. An `existing` install runs the binary from the path you gave setup (`Binary=` in its summary). |
| `/usr/local/libexec/telcoin/tn-start` | The start script (`tn-start-docker` on Docker installs), root 0755. It holds the node's launch command and flags, and feeds the BLS passphrase to the node on standard input. |
| `/etc/telcoin/node.env` | Root 0644. Holds only `PRIMARY_LISTENER_MULTIADDR`, `WORKER_LISTENER_MULTIADDR` and `TN_RPC_ADDR`. |
| `/etc/systemd/system/telcoin.service` | The systemd unit, `telcoin`. Docker installs also name the container `telcoin`. The unit runs the start script, loads the passphrase credential and carries the sandbox settings. |
| `/var/lib/telcoin/` | The data directory, the only tree the service user owns (mode 0700). |
| `/var/lib/telcoin/node-keys/` | BLS and P2P keys. Back these up. |
| `/var/lib/telcoin/node-info.yaml` | Public identity and advertised URLs. |
| `/var/lib/telcoin/genesis/`, `/var/lib/telcoin/parameters.yaml` | Chain configuration. |
| `/var/lib/telcoin/network-config` | The node's network settings (YAML). The scripts write its `hostname` line and, with an admission mode, its `admission`, `trusted_nodes` and `committee_peers` entries (section 2.9). |
| `/var/lib/telcoin/db/` | Chain database. This is what grows. |
| `/var/lib/telcoin/consensus-db/` | Consensus data. `epochs/` holds the consensus packs of finished epochs and the pack of the epoch in progress (`epoch-N`), open for append. The epoch database (the epoch in progress), the peer records and the batch caches are the MDBX databases `epoch/`, `kad/` and `cache/` on `v0.16.0-adiri`, and from the next release tndb, in `tndb/epoch`, `tndb/kad` and `tndb/cache`. |
| `/var/lib/telcoin/consensus-db/state_exports/` | One directory per epoch when state export is on (section 2.7). |
| `/etc/telcoin/` | Config directory, root 0755; every file in it is root-owned. |
| `/etc/telcoin/bls-passphrase.cred` | The BLS passphrase as an encrypted systemd credential, root 0600 (key `host+tpm2` with a usable TPM2, else `host`). |
| `/etc/telcoin/bls-passphrase` | The plaintext passphrase, root 0600, only on testnet or devnet hosts below systemd 250 (section 1.2). |
| `/etc/telcoin/bootstrap-peers.yaml` | The peers map, when the node runs with `--bootstrap-peers` (section 2.7). World-readable. |
| `/etc/telcoin/trusted-nodes.yaml` | The trusted nodes map, root 0644, when setup ran with `--trusted-nodes` or `edit-config.sh` set `trusted_nodes` (section 2.9). World-readable. |
| `/etc/telcoin/gateway/` | Root 0755, only with a worker gateway (section 4.15): `gateway.meta` (root 0600), the settings `/etc/systemd/system/telcoin-gateway.service` is rendered from. |
| `/etc/telcoin/chain-configs/<network>/` | The chain configs this script release pins: `genesis.yaml`, `committee.yaml` and `parameters.yaml` as they are at the pinned tag (`v0.16.0-adiri` on testnet). Setup and `13) Refresh chain configs` install them and copy them from here into the data directory. Root owns `chain-configs/` and `<network>/` (0755) and the three files (0644). A directory that holds the right files with another owner or other modes is installed again; a symlink at either directory, or an entry in the way of one of the three files, is refused. |
| `/etc/telcoin/.node-meta` | Install settings the other scripts read, one `KEY=value` per line: `NETWORK`, `INSTALL_METHOD`, `DOCKER_IMAGE` (and `DOCKER_IMAGE_DIGEST`) or `BINARY_PATH`, `RELEASE_TAG`, `DATA_DIR`, `RPC_PORT`, `VALIDATOR_ADDRESS`, `PASSPHRASE_METHOD`, `CREDENTIAL_KEY`, `LOG_TARGET`, `OWNERSHIP_LAYOUT=2`, `BOOTSTRAP_PEERS_FILE`, `STATE_EXPORT`, `ADMISSION_MODE`, `TRUSTED_NODES_FILE`, and `PUBLIC_RPC_DOMAIN`, `PUBLIC_RPC_URL` and `PUBLIC_WS_URL` while public RPC is on. Root 0600, so run the scripts with `sudo`. |
| `/var/log/telcoin/telcoin.log`, `telcoin-error.log` | Node output with `--log-target file` (section 2.8). The directory is `root:telcoin-log` 0750 and the files 0640, so root and members of `telcoin-log` can read them. With `--log-target journal`, read the journal instead. |
| `/var/log/telcoin/node/` | Logs the node writes itself (the observability add-on's JSON logs), service user:`telcoin-log` 2750 (setgid; the node's unit joins `telcoin-log` and its `UMask=0027` keeps the logs group-readable). |
| `/var/backups/telcoin/` | Root 0700. Every script backs a file up here before it changes it (`<name>.<random>`, root 0600). |
| `/var/lib/telcoin-staging/` | Root 0700. Downloads and build logs before they are checked and installed, in directories named by the run's PID; a run removes its own at exit, also after a signal, and the next locked run removes those of runs that died. |
| `/run/telcoin/update.lock` | The update lock (root 0600 in a root 0755 directory). Setup, `update-node.sh`, `edit-config.sh`, `install-caddy.sh`, `prepare-stake.sh --rotate-address`, `migrate-node-naming.sh`, `remove-node.sh` and the testnet add-ons take it, so only one of them changes the node at a time. |
| `/opt/telcoin-source/` | The telcoin-network source tree (source builds), or the clone setup made for the chain configs (at the pinned tag; on devnet, the default branch). Root owns it; the scripts refuse to read chain configs from one that another account owns or that is a symlink. On testnet, setup and `13) Refresh chain configs` fetch the pinned tag into `refs/tn-remote-tags/<tag>` and read the files from there: they never pull it or check anything out. On devnet both still pull its default branch. |
| `/var/lib/tn-build/` | Home of the `tn-build` build account: its Rust toolchain, cargo cache and build output (source builds). |
| `/usr/local/libexec/telcoin/tn-p2p-allow-sync` | The P2P committee allowlist sync tool, root 0755, only while committee mode is on (section 2.10). |
| `/var/lib/telcoin-p2p-allow/` | Root 0700. The allowlist's `config`, written by `firewall-setup.sh`, and the tool's `floor`, `current.nft`, `state.json`, `status` and `lock`, only while committee mode is on (section 2.10). |

`.node-meta` records no role: the validator view follows the on-chain stake status.
A node set up or migrated by older scripts may still carry a `NODE_TYPE=` line; nothing reads it, and it is safe to leave.

If you chose a different data directory, read it in place of `/var/lib/telcoin` everywhere in this runbook.
The README's [System Layout](README.md#system-layout) shows the full tree.

### 2.5 Back up the keys now

Losing `node-keys/` means losing the node's identity.
If you have not staked yet, you can regenerate keys and carry on.
To do that, move `node-keys/` and `node-info.yaml` aside first, then re-run setup: answering Yes to `Overwrite existing keys?` currently ends with `Key generation failed.`, because the keytool refuses a `node-keys/` that is not empty.
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
Section 4.12 covers what else holds the key (snapshots, the credential), how to restore it on a new host, and what to do when the passphrase is lost.

### 2.6 Firewall

```bash
sudo bash ~/telcoin-node-scripts/firewall-setup.sh
```

Choose `2) Enable firewall with recommended defaults`.
It first asks `Restrict SSH to these sources`: give your admin IPs or CIDRs, comma-separated, or press Enter to keep the current setting.
It then sets inbound to deny and outbound to allow, allows SSH from those sources (from anywhere when there are none), allows TCP 43174 from the Association monitor only (testnet and devnet), and allows the node's P2P ports when a node is installed.
It reads those ports from `/etc/telcoin/node.env`, the node's start script and `node-info.yaml`, every worker included, so a node set up on other ports than 49590 and 49594 gets the right rules.
When Caddy serves the public RPC or the dashboard on this server, it also allows TCP 80 and 443 before it turns `ufw` on, so the site stays up.
The plan it shows before you confirm lists every rule.
It asks whether to reset to a clean slate first; No keeps your existing rules.
It checks every input before it changes anything and saves `ufw`'s rule files first; if a step fails, or the run is stopped with Ctrl-C, SIGTERM or SIGHUP, it puts the old rules back.

The same thing without the menu:

```bash
sudo bash ~/telcoin-node-scripts/firewall-setup.sh --json --enable --ssh-from 198.51.100.7/32,203.0.113.0/24
```

- `--ssh-from CIDR[,CIDR]` or `--ssh-from <file>` (one source per line) limits SSH to those sources; `--p2p-from` does the same for the P2P ports. The lists are stored in `.node-meta` as `SSH_ALLOW_FROM` and `P2P_ALLOW_FROM`, and a new list replaces the old one's rules. Addresses with leading zeros, `/0` and masks wider than `/8` are refused. An IPv6 entry must parse as Rust's `Ipv6Addr` parses it, the grammar `tn-p2p-allow-sync` reads `P2P_ALLOW_FROM` with: hex groups only, at most one `::`, and no zone (`%eth0`), brackets or dotted IPv4 tail (write `::ffff:192.0.2.1` as `::ffff:c000:201`), so a typo is refused before anything is written.
- `--ssh-anywhere` and `--p2p-anywhere` drop a stored list and open the port to every address again. Each cannot be combined with its `-from` twin.
- After `--p2p-committee off` (section 2.10) the stored P2P list is set aside (`P2P_PER_SOURCE=off`): the P2P ports stay open to every address on later runs until `--p2p-from` gives a list again.
- `--gateway-from <list|file>` lets those hosts reach the node's RPC port and health port 43174, on every network, for a worker gateway on another host (section 4.15). It goes with `--enable` or `--reset`, is stored as `GATEWAY_ALLOW_FROM` and applied again by every later `--enable` and `--reset`; `--gateway-from none` removes the list and its rules. While `GATEWAY_UPSTREAM` is set in `.node-meta`, `--reset`, `--gateway-from none` and a list that leaves out a host it names are refused (section 4.15).
- On a Google Cloud VM the IAP range `35.235.240.0/20` is added to the SSH sources, so the console's SSH button keeps working.
- On mainnet, enabling the firewall without SSH sources is refused unless you pass `--ssh-anywhere`. The health port 43174 is never opened to everyone.

`3) Manage SSH access` writes its settings into the drop-in `/etc/ssh/sshd_config.d/00-telcoin-hardening.conf`: `1) Disable password authentication (keys only)` sets `PasswordAuthentication no` and `KbdInteractiveAuthentication no`, and `2) Disable root login` sets `PermitRootLogin no`.
The `00-` prefix makes sshd read it before cloud-init's `50-cloud-init.conf`.
It checks the configuration with `sshd -t` and warns when `/etc/ssh/sshd_config` has no `Include /etc/ssh/sshd_config.d/*.conf` line, because sshd then ignores the drop-in.

To restrict SSH on a host that already allows it from anywhere, you can also use `5) Manage trusted IP whitelist` to add your own IP or range first, then remove the blanket SSH rules from the same menu.
There are two of them: `ufw` keeps an IPv4 rule and a `(v6)` twin, and `2) Remove a whitelist entry` deletes one rule number per run.
Remove both, and list the rules again (`3) Show all firewall rules`) before the second delete, because the numbers shift.
Removing only one leaves SSH open to everyone over IPv6.
Adding a whitelist entry does not remove the blanket rules by itself.
Test SSH from a new terminal before you close the current one.

When P2P is open to every address (no `--p2p-from` list) and a node is installed, every enable also loads a per-source limit on new P2P flows, after the `ufw` rules are in place:

```text
  ->  P2P new-flow limit: UDP 49590 and 49594 accept at most 20 packets of new, not yet answered flows per minute from one IPv4 address or IPv6 /64 after a burst of 40 (nftables table inet tn_p2p).
```

It is the nftables table `inet tn_p2p`, and it only drops: a source that floods the P2P ports with packets of flows the node has not answered loses the packets above the limit, flows the node has answered are never limited, and every other packet goes on to `ufw`.
`TN_P2P_NEW_FLOW_RATE` and `TN_P2P_NEW_FLOW_BURST` (whole numbers from 1 to 100000) change the rate and the burst for one run, for example `sudo TN_P2P_NEW_FLOW_RATE=30 TN_P2P_NEW_FLOW_BURST=60 bash ~/telcoin-node-scripts/firewall-setup.sh --enable`; nothing stores them, so the next enable without them goes back to 20 and 40.
A bad value stops the run before anything changes.
With a P2P source list, in P2P committee mode (section 2.10), or without a node, the table is removed.
Without `nft` the run warns and applies the `ufw` rules as before.
The limit comes back after a reboot: the run writes the table to `/etc/telcoin/p2p-limit.nft` and enables `telcoin-p2p-limit.service`, which loads it after `ufw.service`.
`1) View current firewall status` shows a `New-flow limit:` line and a `New-flow limit at boot:` line; a warning there (the boot copy missing, the unit not enabled, or a boot copy that holds another rate or port set) clears with `2) Enable firewall with recommended defaults` or `--enable`.
Every enable and every change in `Manage node ports` takes the update lock, so it refuses while `update-node.sh` or another script holds it.

A validator can go further and let only the peers its own node lists reach the P2P ports: `--p2p-committee on`, the P2P committee allowlist of section 2.10.

`ufw` is only the host layer.
Open the same UDP ports in the cloud firewall or security group as well, and forward them on the router if the server sits behind NAT.
`1) View current firewall status` lists each P2P port with its label, for example `UDP 49594 is open (worker)`.
The README covers the rest of the [firewall script](README.md#firewall-setup).

### 2.7 Optional node flags

Setup can pass two extra features to the node.
Both are optional, and `edit-config.sh` can add, change or remove them after the install (section 4.3).

`--bootstrap-peers <file>` replaces the bootstrap servers in the genesis with your own list of peers to dial at start.
It needs `v0.15.0-adiri` or later.
The node treats these peers as discovery hints only: it does not keep them connected ahead of other peers or exempt them from load penalties.

- The file is a YAML or JSON map keyed by BLS public key. Each value is that node's `primary` and `workers` entries, copied from under `p2p_info` in its `node-info.yaml`.
- It must be a regular file of at most 64 KiB that other users can read (`chmod 644`). The map does not stay private: setup installs it world-readable as `/etc/telcoin/bootstrap-peers.yaml`, and its check passes the map on the node binary's command line. A file its group or other users cannot read is refused, with the `chmod` to run.
- Setup checks the map with the release's own parser and stops with the parser's reason if a key or value is wrong.
- Every `network_address` is an IP address (`/ip4/<address>/udp/<port>/quic-v1/p2p/<peer id>` or the same with `/ip6`), as for the trusted nodes file (section 2.9): the node does not resolve names and never dials a `/dns...` or `/tcp` address, which its parser takes. Setup and `edit-config.sh` refuse one in the preflight, before the parser runs, naming the line and the entry: `line <n>: the network_address of <key>... is a DNS name (...)`.
- The start script passes `--bootstrap-peers "$(cat /etc/telcoin/bootstrap-peers.yaml)"`, so the node reads the file again at every start. An edit to that file takes effect at the next restart without any check; `edit-config.sh` checks a new map before it installs it.
- With an admission mode (section 2.9) the map is also written into `network-config` as `committee_peers`, but only when it lists every validator of the genesis committee, this node included.
  A map that lists fewer is installed and dialed as usual and left out of `committee_peers`, with a warning.

`--enable-state-export` (`v0.13.0-adiri` or later) writes each epoch's final execution state under `<data dir>/consensus-db/state_exports/epoch-N/`.
Every export is a full copy of the state and none is deleted, so the disk fills over time.
`--state-export-keep <n>` keeps only the newest n exports (1 to 999999) and turns export on by itself; it needs `v0.15.0-adiri` or later.
A value of 2 or more keeps the previous export while the next one is written.

```bash
sudo bash ~/telcoin-node-scripts/setup-node.sh --bootstrap-peers ./peers.yaml --state-export-keep 3
```

Setup asks the release it installs whether it has each flag you give, during System infrastructure ("Step 4 of 8"), and stops before any key is made when it does not.
It records the choices in `.node-meta` as `BOOTSTRAP_PEERS_FILE` (the installed path, empty when none) and `STATE_EXPORT` (`off`, `unlimited` or a number).

The node also reads `<data dir>/network-config`, a YAML file; the scripts write its `hostname` line (the advertised node name, set at setup or in the Node Manager UI) and, with an admission mode, its `admission`, `trusted_nodes` and `committee_peers` entries (section 2.9).
From the next release it accepts six opt-in keys, `process_budget`, `source_admission`, `trusted_nodes`, `committee_peers`, `admission` and `serve_budget`; `v0.16.0-adiri` ignores them, so setting one there changes nothing.
The scripts set `admission`, `trusted_nodes` and `committee_peers` only when you ask for an admission mode, and never set the other three.
The first four are unset by default, which means absent: `{}` for `process_budget` or `source_admission`, or `null` for `trusted_nodes` or `committee_peers`, is a configuration error that stops the node.
Left out, `admission` keeps open admission (`mode: Open`) and `serve_budget` leaves every class of inbound request unbounded.
Leave `process_budget`, `source_admission` and `serve_budget` unset unless support@telcoin.org asks you to set one.
`source_admission` can refuse committee peers once its limits fill, and a node that has it set logs a warning starting `source admission is enabled`.

### 2.8 Passphrase, logs and other setup flags

`sudo bash ~/telcoin-node-scripts/setup-node.sh --help` lists every flag.
These set how the node is hardened:

| Flag | What it does |
|---|---|
| `--passphrase-stdin` | Read the BLS passphrase from standard input: one line, read once, without echo (a trailing CR is dropped). `TN_BLS_PASSPHRASE` in the environment still works for a `--json` keygen, and setup removes it from its own environment before it runs anything; giving both is an error. |
| `--passphrase-method credential\|stdin` | Force how the passphrase is kept. `credential` (the default wherever it works) is the encrypted `/etc/telcoin/bls-passphrase.cred`; `stdin` is the root-only file, taken on testnet and devnet only. Either way the start script feeds the passphrase to the node on standard input (`--bls-passphrase-source stdin`): it is never on a command line and never in the unit's `Environment=`. The old `tpm` method is refused with a pointer to `edit-config.sh --migrate-credential`. |
| `--allow-no-tpm` | On mainnet, accept a credential encrypted with the host key (`/var/lib/systemd/credential.secret`) alone when the host has no usable TPM2. Without it a mainnet host with no TPM2 stops. |
| `--bind-pcrs <list>` | Also bind the credential to these TPM PCRs, joined by `+` (for example `7`). A firmware or Secure Boot change to them stops the node from starting until `edit-config.sh --reseal` runs (section 4.3). |
| `--log-target journal\|file` | Where the node logs. `journal`, the default on mainnet, sends output to the systemd journal and installs a journald drop-in (`/etc/systemd/journald.conf.d/50-telcoin.conf`: `SystemMaxUse=4G`, `SystemKeepFree=2G`). `file`, the default elsewhere, appends to the two files in `/var/log/telcoin`, rotated by logrotate. |
| `--install-method release` | Install from a signed release (section 2.3). |
| `--release-tag <tag>` | The release to install or build: `vX.Y.Z-adiri` on testnet, `vX.Y.Z` on mainnet. `--build-ref` is the older name; when both are given they must agree. With `--install-method docker` it picks that release's image, by digest. |
| `--allow-dirty` | Testnet source builds, interactive only: discard local changes and untracked files in `/opt/telcoin-source` instead of stopping. |
| `--allow-quorum-risk` | When setup re-runs over a running node and restarts it, go ahead even when the committee check refuses (section 4.11). For a coordinated restart only. |
| `--audit` | Print the host hardening report (section 1.2) and exit. |
| `--host-baseline` | Once the node is installed, add auditd watches and an AIDE baseline of the node's files (section 4.13). Off unless you pass it; setup never asks. On a host whose node is installed, `--host-baseline` alone makes the baseline, or makes it again, and changes nothing else. |

### 2.9 Node admission

The node's admission mode decides which peers it takes connections from.
It lives in `<data dir>/network-config`, with the trusted hubs and the committee launch inventory beside it, and needs node release 0.17.0 or later (below).
`setup-node.sh --admission open|grace|closed` writes it, with the hubs of `--trusted-nodes <file>`, and `edit-config.sh` changes it later (menu items `11) Admission mode` and `12) Trusted nodes`, or `--set`; section 4.3).
Without `--admission`, and with no earlier choice recorded, setup leaves the admission settings of `network-config` alone on every network, mainnet validators included.

| Mode | What the node admits |
|---|---|
| `Open` | Every peer ordinary discovery finds, as before. A node whose `network-config` has no `admission` entry runs Open. |
| `Grace` | The same peers as Open: Grace enforces nothing beyond Open and differs only in the status and gauges the node reports. It is the step between Open and Closed. |
| `Closed` | Only the previous, current and next committees, the trusted nodes and the bootstrap peers. Closed takes effect only while the node holds a current committee window and a resolved record for every identity in the previous, current and next committees: until then a Closed node runs as Grace (a committee member without a record, say), or as Open (no window, or a stale one). |

Before you ask for Closed, watch the node's `admission_fallback` gauge in its metrics (`--metrics`) (healthy = 0, missing = 1, stale = 2, contradictory = 3, unresolved = 4) in Grace; `admission_mode` reports the effective mode (Open = 0, Grace = 1, Closed = 2).
The node's own description is `crates/network-libp2p/src/peers/admission.md` in telcoin-network.

Mainnet validators are expected to run `--admission closed --trusted-nodes <hubs>`.
On mainnet, mode closed without a trusted nodes map warns, at setup and in `edit-config.sh`: `Admission closed without --trusted-nodes: the node admits only the previous, current and next committees and the bootstrap peers. Mainnet validators are expected to run --admission closed --trusted-nodes <hubs>.`
Outside the committees, a closed node takes only its trusted hubs and its bootstrap peers.
Put the hubs in the trusted nodes file; the bootstrap peers file must list every validator of the genesis committee, this node included, and may list hubs beside them, because with an admission mode it is also written into `network-config` as `committee_peers` (below), and only when it lists the whole committee.

```bash
sudo bash ~/telcoin-node-scripts/setup-node.sh --admission closed --trusted-nodes ./hubs.yaml --bootstrap-peers ./peers.yaml
```

**The trusted nodes file.**
A YAML map keyed by each hub's BLS public key (base58, as in the hub's `node-info.yaml`).
Each entry holds the hub's `primary`, with its `network_address` and `network_key`, and its `workers`, keyed by worker id, each with its own `network_address` and `network_key`.
Do not paste an entry from a node-info file; workers are keyed by id.
`node-info.yaml` lists the workers under `p2p_info` and adds fields such as `name`, and the node stops at start on either.
Unlike the bootstrap peers map, `workers` is a map by worker id, not a list, and an entry holds nothing besides `primary` and `workers`.
The node wants the worker ids `0` up to its own number of workers less one in every entry (`0` alone with one worker).
Every `network_address` is an IP address: `/ip4/<address>/udp/<port>/quic-v1` or the same with `/ip6`, followed by `/p2p/<peer id>` as in the hub's `node-info.yaml` (the `/p2p/` part may be left out).
The node does not resolve names: it starts with a `/dns`, `/dns4`, `/dns6` or `/dnsaddr` address, or a `/tcp` one, but never dials it, and says so only at debug log level, and the P2P committee allowlist (section 2.10) takes no address from a name.
One correct entry, for a hub with one worker, with the values taken from the hub's `node-info.yaml` (`bls_public_key`, and under `p2p_info` the primary's and the first worker's `network_address` and `network_key`):

```yaml
<hub bls_public_key>:
  primary:
    network_address: /ip4/198.51.100.30/udp/49590/quic-v1/p2p/<primary peer id>
    network_key: <primary network_key>
  workers:
    0:
      network_address: /ip4/198.51.100.30/udp/49594/quic-v1/p2p/<worker peer id>
      network_key: <worker network_key>
```

- It must be a regular file of at most 64 KiB that other users can read (`chmod 644`), as for the peers map (section 2.7).
- Setup installs it as `/etc/telcoin/trusted-nodes.yaml` (root 0644) and writes it into `network-config` under `trusted_nodes`.
- `setup-node.sh` and `edit-config.sh` check its shape with one check before they write anything: keys of 131 or 132 base58 characters, each named once, `primary` and `workers` as above with the worker ids of the workers this node runs (`0` alone for the one worker setup installs), block YAML only (a byte order mark and CRLF line ends are fine), and every `network_address` an IP address as above.
  The node binary then reads the map too, before network-config is written or a running node restarted, and judges every BLS key, `network_key` and `network_address` as it does at start; its refusal reads `--trusted-nodes: <the node binary> does not read <file> (<the node's reason>; the line and column count in that file). ...` at setup, `the node rejects <file> as a trusted nodes map (<the node's reason>; ...)` in `edit-config.sh`.
  Setup runs it in the preflight, before any key generation or install step, on a map it reads back from `.node-meta` on a re-run, and again just before the install; `edit-config.sh` runs it on a root-only copy.
  A refusal writes nothing, restarts nothing and names the line and the entry, with the key shortened: `--trusted-nodes: <reason>.` at setup, `<file> is not a trusted nodes map: <reason>. Each key is a hub's BLS public key, and each entry the hub's primary (network_address, network_key) and its workers keyed by worker id, with the addresses and keys from its node-info.yaml.` in `edit-config.sh`.
  For a name the reason reads `line <n>: the network_address of <key>... is a DNS name (<address>...): the node does not resolve names, so it would never dial it. Give the IP address instead; the node takes /ip4/<address>/udp/<port>/quic-v1/p2p/<peer id> (or /ip6/...), as node-info.yaml writes it`.
- The map needs an admission mode: `--trusted-nodes` with no mode given or recorded stops setup, and `edit-config.sh` says `trusted_nodes needs an admission mode, which goes into network-config with it: set admission to open, grace or closed first`.
- When a peer rotates its network key, a Closed node denies the new key until the peer's new record resolves; switching to Grace for the rotation, or putting the new binding in this file, avoids the wait, because a configured hub wins over a cached record.

**`committee_peers`.**
The scripts write the installed bootstrap peers map (`/etc/telcoin/bootstrap-peers.yaml`, section 2.7) into `network-config` as `committee_peers`, the node's launch inventory, when it lists every validator of the genesis committee (the keys under `authorities` in `<data dir>/genesis/committee.yaml`), this node included; keys beside them, a hub's say, do no harm.
They leave the entry out when the node runs without a map.
A node that starts during epoch 0 with a nonempty `committee_peers` stops unless it lists every member of the committee, each with its primary and the on-chain number of workers (`Error: committee_peers: missing validator <key>`, within a second of the start, in every admission mode); after epoch 0 a gap is only logged and discovery covers it, but a new data dir starts at epoch 0 whenever it is made.
So setup and the `edit-config.sh` edits of `admission`, `trusted_nodes` and `bootstrap_peers` check the map against that `committee.yaml` before they write `network-config`, and leave `committee_peers` out when a validator is missing, with a warning that starts `<map> lacks <n> of the <m> validators of the genesis committee in <committee.yaml> (<the first three keys>), so it is not written to network-config as committee_peers`.
The run goes on: the map stays installed and on the start line, so the node still dials it at start and finds the other validators through peer discovery, and the P2P committee allowlist keeps it in its floor (section 2.10).
To have it written, add the missing validators and install the map again with `edit-config.sh --set bootstrap_peers=FILE`.
Setup copies `committee.yaml` into the data dir in "Step 6 of 8", before it writes `network-config` in "Step 7 of 8", so the check always has the file; when it cannot read it, the map is left out the same way.
The check compares BLS keys only; the number of workers in each entry is still the node's to check.
At any epoch the node also stops on an entry with an empty address, or one whose `/p2p/` part names another peer than its network key.
A `bootstrap_peers` edit on a node with an admission mode writes `network-config` again, so `committee_peers` follows the map.

**The release floor.**
The node reads the three entries from the release `MIN_ADMISSION_VERSION` names in `lib/common.sh`, 0.17.0.
No release carries them yet (`v0.16.0-adiri` ignores them), so that floor is the next minor release and waits for the node team to confirm it.
Setup refuses a release below the floor (`--admission needs node release 0.17.0 or later, and this run installs <release>, which ignores the admission settings of network-config. Pick a newer release, or leave --admission and --trusted-nodes out.`), and so does `edit-config.sh` (`the admission settings need node release 0.17.0 or later, and this node runs <release>, which ignores them; update the node first`).
When they cannot tell the release (an `existing` binary without a version marker beside it, say), they warn and write the settings anyway.

**What setup records.**
`.node-meta` holds `ADMISSION_MODE` (`open`, `grace` or `closed`, or empty) and `TRUSTED_NODES_FILE` (the installed path, or empty).
A `--json` finalize reads both back from what keygen recorded, and an interactive re-run over an earlier install reads them back too, with `BOOTSTRAP_PEERS_FILE` when a mode is in effect, so a re-run keeps the settings it does not name.
Setup writes `network-config` as the service user, before the node starts, replacing the node's own `admission`, `trusted_nodes` and `committee_peers` entries rather than adding second copies (a key that appears twice stops the node), and keeps a `snapshot_max_age_secs` the old `admission` entry holds.

**Restart and verify.**
`edit-config.sh` applies an admission edit with a restart, after the committee quorum check and the epoch wait (section 4.11), and then watches the node.
The node reads `network-config` only once it has started (after its databases, the epoch state and the catch-up), so the service must be active 3 seconds after the restart and then stay active for `TN_EDIT_VERIFY_TIMEOUT` seconds (default 60) without restarting by itself (systemd's `NRestarts`), checked every 5 seconds.
When a check fails, `network-config`, the trusted nodes map and `.node-meta` are put back byte for byte and the node is restarted on them without a wait: `restart failed; rolled back to the previous configuration` (with `--set`), or `Node failed to restart with the edit, so the edit was put back and the node runs the previous configuration again.` (in the menu).
The watch has limits:

- A node that refuses the file after the window is not rolled back; raise `TN_EDIT_VERIFY_TIMEOUT` for a node with a long catch-up.
- Only the restart `edit-config.sh` makes right after the edit is watched: an edit kept for later (No at `Restart the node now to apply changes?`) and a restart by `systemctl` are not.
- Setup checks only that the service is active 3 seconds after its start, as for any install; check a new node with `check-node.sh` and `journalctl -u telcoin`.
- The watch sees a node that stops, not its admission: a Closed node that runs as Grace stays up and passes, so read the gauges above.

**Day 2.**
Move a running validator to Closed through Grace, one edit at a time; each `--set` restarts the node and is watched as above:

```bash
sudo bash ~/telcoin-node-scripts/edit-config.sh --set admission=grace
sudo bash ~/telcoin-node-scripts/edit-config.sh --set trusted_nodes=/home/admin/hubs.yaml
# watch admission_fallback until it reads 0, then
sudo bash ~/telcoin-node-scripts/edit-config.sh --set admission=closed
```

- `trusted_nodes=none` removes the installed map, the `trusted_nodes` entry and the record; on a node in mode closed on mainnet it warns as above.
- To undo, set the earlier value again: `--set admission=open` (there is no `admission=none`; open is what the node does without the entry) or `--set admission=grace`.
  During an incident, set Open or Grace; the node's admission page gives that advice.
- An edit whose value is already in place writes nothing and does not restart the node, and one that only adds a missing key to `.node-meta` keeps it without a restart.
- The Node Manager UI cannot set either field yet; use `edit-config.sh` on the server.

**Known limitations.**

- `MIN_ADMISSION_VERSION` (0.17.0) is a placeholder until the node team names the first release that reads the entries; `setup-node.sh --help` and `edit-config.sh --help` repeat it.
- `committee_peers` comes from the bootstrap peers map and is written only when that map lists the whole genesis committee (above); a map that lists fewer keeps the node starting but leaves it without a launch inventory.
- The node has no check flag for the file, so the scripts check its shape themselves and have the node binary parse it as a bootstrap peers map, which holds the same entries; block YAML only, so a JSON or flow-style map is refused.
  The node still stops at start on a map that passes both when a `/p2p` peer id is not the one of its `network_key`, or a network key is this node's or another hub's, which the node checks only at start: `edit-config.sh` then rolls the change back, but a `setup-node.sh` re-run over a running node leaves it stopped until the map is fixed.
  A node-side check of the file would replace both.
- When the release cannot be told, `--admission` and the two edits warn and write anyway rather than stop.
- A Docker finalize without `--release-tag` asks the image registry which release the recorded image belongs to, because keygen records no release tag; when that lookup fails, it cannot tell the release and warns.
- `update-node.sh` does not check the floor: an update to a release below 0.17.0 leaves the settings in `network-config`, where that release ignores them.
- `check-node.sh` does not report the admission settings or the trusted nodes map yet, and `remove-node.sh` does not name the map: it goes only with the config directory, when you let it remove the keys.
- An interactive setup re-run without `--bootstrap-peers` keeps the recorded peers map only when an admission mode is in effect; without one, it drops the map as before.
- Whether 60 seconds is long enough for every node before it reads `network-config` is not settled; the window is `TN_EDIT_VERIFY_TIMEOUT`.

### 2.10 P2P committee allowlist (validators)

A validator can narrow its P2P ports to the peers its own node lists: `firewall-setup.sh --p2p-committee on` loads the nftables table `inet tn_p2p_allow`, which drops every source to the P2P ports that is not on the list before `ufw` sees it.
The list is every address of the node's admission snapshot (`tn_admissionSnapshot` on its local RPC), in the primary and every worker swarm: the committees, the validators the node tracks for a coming seat, and its trusted and bootstrap peers.
The floor and the P2P source list are always on it too.
The floor is every address in `/etc/telcoin/bootstrap-peers.yaml`, in the genesis `committee.yaml` the data dir holds and in `/etc/telcoin/trusted-nodes.yaml` (the hubs of `--trusted-nodes`), taken from each of those files that exists.
One of the first two must exist: `trusted-nodes.yaml` never stands in for the committee, so with neither (a data dir on a disk that is not mounted, say) `on` and every resync refuse with `... committee.yaml is missing and so is /etc/telcoin/bootstrap-peers.yaml, so the P2P committee allowlist floor was not captured ...`, and the loaded table stays as it is.
Each of the three that exists must be a regular file: a symbolic link, a directory or a FIFO at one of them refuses `on` and every resync, with a message naming the file, what is there and the repair, and the loaded table stays as it is.
The genesis `committee.yaml` sits in the data dir the node's service user writes, and the capture runs as root, so it never follows a link there; remove what is there and put the network's copy back with `13) Refresh chain configs` in `edit-config.sh`, or for a map run `edit-config.sh --set bootstrap_peers=FILE` or `--set trusted_nodes=FILE` again, then `--p2p-committee sync`.
The tool drops a key on the second sync whose snapshot leaves it out, so a hub or committee member the node stops listing (after a restart with another `network-config`, say) stays on the list only through the floor: give a closed validator its hubs with `--trusted-nodes` and the committee with `--bootstrap-peers`.
A genesis `committee.yaml` may carry no address at all, so a validator with neither map can have an empty floor, and `on` and every resync then say so: `The P2P committee allowlist floor holds no address: ... Nothing is protected if the node stops listing a peer: a committee member or trusted hub it leaves out is dropped on the second sync without it.`, with the `edit-config.sh --set bootstrap_peers=FILE` and `--set trusted_nodes=FILE` commands that fill it.
The warning does not stop `on`.
Every resync captures the floor again, and it never takes an address out of the floor on its own.
When the files no longer hold an address the floor has (a hub removed from `trusted-nodes.yaml`, a peers map without an address the old one had, or a genesis `committee.yaml` gone missing), the resync refuses with `The P2P committee allowlist floor was not captured again, so it keeps <addresses>: ...`; the loaded table, those addresses included, stays as it is, and the timer keeps syncing with that floor.
Check the files first.
To remove a hub on purpose, take it out of the map (`edit-config.sh --set trusted_nodes=FILE`, or `=none`), then accept the smaller floor with `sudo bash ~/telcoin-node-scripts/firewall-setup.sh --p2p-committee sync --accept-floor-shrink`: the edit's own resync refuses, since no script passes that flag for you.
The hub then leaves the list at that sync, or, while the node's snapshot still lists it, on the second sync whose snapshot leaves it out.
The signed tool `tn-p2p-allow-sync` builds the table and `telcoin-p2p-allow-sync.timer` keeps it in step every 5 minutes.
The README's [P2P committee allowlist](README.md#p2p-committee-allowlist) is the reference: the verbs, the units, the state dir, the tool's pin and how to verify its release by hand.

It suits a validator that runs Closed admission (section 2.9); a hub or an observer, which other nodes dial from anywhere, keeps it off.
The firewall does not depend on the admission mode, though: it filters by the snapshot's addresses, whatever the node admits.

**Before you turn it on.**

- The firewall is on (`ufw` active, section 2.6) and `nftables` is installed (`sudo apt-get install nftables`), which puts `nft` at `/usr/sbin/nft`, the path the tool runs.
- The node runs a release that serves `tn_admissionSnapshot`, is synced, and holds an authoritative snapshot: right after a restart it may not have its committee window yet, and `on` refuses until it has.
- The host is x86_64, the one architecture the tool is published for.
- These scripts pin the tool's release: `TN_P2P_ALLOW_VERSION` (`v0.1.2`) and `TN_P2P_ALLOW_TARBALL_SHA256` in `lib/common.sh`.
  Both are set; a later script release moves them together.

```bash
sudo bash ~/telcoin-node-scripts/firewall-setup.sh --p2p-committee on
```

`on` installs the pinned tool when it is missing or answers another version, makes `/var/lib/telcoin-p2p-allow` (root 0700), writes its `config`, captures the floor and runs one sync that must see an authoritative snapshot.
Then it enables the boot unit and the timer, keeps the open P2P `ufw` rules, removes the new-flow limit `inet tn_p2p` (an nftables accept is not final across base chains, so the limit would still drop listed peers), records `P2P_COMMITTEE=on` in `.node-meta` and makes the host baseline again:

```text
  [OK]  P2P committee mode is on: only the sources the allowlist lists reach UDP 49590 and 49594 (epoch 42: 12 IPv4 and 2 IPv6 sources (10 keys, 2 floor, 1 static)).
```

**What `on` refuses, and why.**
Every refusal changes nothing and exits 1, with a message that says why.

- No node, `ufw` not active, no executable `/usr/sbin/nft` (the path the tool runs; the message names it), no `nft` on `PATH`, no `systemctl` or `flock`, a bad `TN_P2P_NEW_FLOW_RATE` or `TN_P2P_NEW_FLOW_BURST`, an unusable `P2P_ALLOW_FROM`, or the update lock held by another script.
- The tool could not be installed: `tn-p2p-allow-sync v0.1.2 is not installed, so P2P committee mode was not turned on; nothing was changed.`, after the reason (no pin, another architecture, a bad signature, a sums, pin, member or `--version` mismatch); a failed download exits 2.
  An installed binary stays as it was.
- The snapshot is not authoritative: `P2P committee mode was not turned on: <reason>. Nothing was changed.`
  The first table must come from a full view of the committee, because there is no last-good set to fall back on yet.
  The reasons you are most likely to see are `this node release lacks tn_admissionSnapshot, or tn is not in its --http.api; update the node or add tn to --http.api`, `the node RPC does not answer on 127.0.0.1 (rpc-unreachable)` and `the admission snapshot of the node is not authoritative (<token>)` (`pool-unpublished`, `fallback-missing` or `fallback-stale` right after a restart: wait a few minutes and run it again).
- `the snapshot lists no addresses beyond the floor and static list` (`empty-set`): a table of the floor alone would cut the committee off.

A step after that sync that fails turns committee mode off again and exits 2; exit 3 means that undo did not finish, and the message names `--p2p-committee off`.

**The static list in committee mode.**
`P2P_ALLOW_FROM` (from `--p2p-from`) becomes part of the table: host entries join the allow sets and networks go to the static sets `static_v4` and `static_v6`.
`ufw` keeps its open P2P rule while committee mode is on, and keeps any per-source rules it had, so the table alone decides which sources pass.
Change the list with `sudo bash ~/telcoin-node-scripts/firewall-setup.sh --enable --p2p-from <list>` (or `--p2p-anywhere`), which records it and resyncs the allowlist.
`off` does not turn the list into per-source `ufw` rules: the P2P ports stay open to every source (see Day 2), and the list waits in `.node-meta` for the next `on`.
A multicast, link-local or unspecified host in the list stops the config write, since it is never a peer's source: `P2P_ALLOW_FROM in .node-meta lists <entry>, an unspecified, multicast or link-local address that is never a peer's source, so the P2P committee allowlist config was not written; pass --p2p-from again without it.`

**When a node sends from an address it does not advertise.**
Committee-mode validators admit a peer by the addresses its record carries.
A validator behind NAT, on a multi-homed host, or with IPv6 temporary (privacy) addresses can send from an address that is not in its record, and every committee-mode peer drops those packets; the same happens on your table to a peer that does so.
Keep the address the node sends from equal to the one it advertises (the external multiaddrs in `node-info.yaml`, section 1.3), and turn IPv6 temporary addresses off on its interface.
When a known peer still arrives from another address, add that address to `P2P_ALLOW_FROM` with `--enable --p2p-from`: the static list is always admitted.
Adding it does not change what the kill switch does: after `--p2p-committee off` the P2P ports are open to every source, not only to the static list.
A rising `tn_drop_p2p_unlisted` counter in `--p2p-committee status` while a committee peer cannot connect points at this.

**Day 2.**

- The timer syncs every 5 minutes, and the scripts resync on their own after `--enable` and `--reset`, after an `edit-config.sh` edit of the listener addresses (`node.env`), the bootstrap peers, the trusted nodes or the chain configs once the node came back from its restart, after `14) Restart node`, at the end of every `setup-node.sh` re-run that completes (whatever it changed, so a re-run after one that failed midway catches up too), and after `migrate-node-naming.sh`.
  Each resync captures the floor again, so a hub added to the trusted nodes map is protected from that sync on; a hub removed from it stays on the floor, and those resyncs warn that the allowlist was not synced, until you run `--p2p-committee sync --accept-floor-shrink` (above).
- Run `sudo bash ~/telcoin-node-scripts/firewall-setup.sh --p2p-committee sync` yourself after a change those paths do not cover: a `setup-node.sh` re-run that stopped before it finished, a hand edit of `.node-meta`, `node.env` or one of the maps, or an edit saved with "restart later" and restarted with `systemctl`.
  `check-node.sh` warns about the drift until you do.
- After `update-scripts.sh`, run the `--p2p-committee sync` it prints when it changed `firewall-setup.sh` or `lib/common.sh`: that rewrites the units and installs the tool the new scripts pin.
- Right after a node restart the node's RPC may not answer yet, so a resync then often keeps the last-good set (`sync` exit 3) while it rewrites the config and the floor; the next timer run applies the snapshot.
- `--p2p-committee status` shows whether the table is loaded and what it holds, the last sync and its age, staleness and its reason, the two counters (`packets accepted from listed sources`, `dropped from others`), and whether the timer and the boot unit are in place.
  It warns at once of `rpc-method-missing`, `snapshot-version-*`, `epoch-regressed` and `state-invalid`, of a failed last sync (`its last sync failed (<reason>, failing since <time>)`) and of a failed last run of `telcoin-p2p-allow-sync.service`, in the words `check-node.sh` uses (below), and of any other reason once the tool reports the run stale.
  `journalctl -t tn-p2p-allow` holds the tool's log lines from the timer runs.
- During an incident, `--p2p-committee off` is the kill switch: it never runs the tool, opens the P2P ports to every source behind the new-flow limit, then removes the units, the table, the state dir and the tool.
  It opens them whatever `P2P_ALLOW_FROM` holds, also on a host whose P2P ports took only that list before committee mode was turned on, so no committee peer the allowlist admitted is cut off.
  A list it cannot use (an invalid entry, or the key set twice) does not stop it: the list stays as it is, and a warning says to correct it with `--enable --p2p-from <list>` (or drop it with `--enable --p2p-anywhere`) before you limit the ports to a list or turn committee mode on again.
  It adds the open rule of every P2P port before it deletes any per-source rule, and a `ufw` call that fails does not stop the others.
  When `off` cannot finish it exits 3 and says what is left: a port `ufw` would not open (it keeps its per-source rules; run `--enable` once `ufw` works), per-source rules it could not delete (with the `sudo ufw delete ...` commands; they admit no source the open rules do not), or, when another process held the tool's lock, the state dir it kept after deleting the table.
  The allowlist is removed in each of these cases: it can only drop sources, so without it every port takes at least what it took before.
  An `off` that did not finish (killed, `.node-meta` not writable, the tool's lock held) leaves `P2P_COMMITTEE=on`, and only running `off` again finishes it: `--enable`, `--reset`, `sync`, `on` and the resyncs of `edit-config.sh` and `setup-node.sh` install and load nothing then, and they and `--p2p-committee status` say that the `off` did not finish, whether the table is still loaded, and the command that finishes it.
  It prints `P2P committee mode is off: UDP 49590 and 49594 are open to every source.`, and with a list kept, the command that limits the ports to it again.
  `P2P_ALLOW_FROM` stays in `.node-meta` for the next `on`, and `P2P_PER_SOURCE=off` next to it keeps later `--enable` and `--reset` runs from turning it into per-source rules.
  To limit the P2P ports to a list again, run `sudo bash ~/telcoin-node-scripts/firewall-setup.sh --enable --p2p-from <list>`, which removes `P2P_PER_SOURCE`.
  `on` later starts again from the node's snapshot.

**What `check-node.sh` reports.**
The check runs in the hardening block, needs `sudo` (the state dir is root only) and is silent while committee mode is off or everything is in order.
The epoch length it judges staleness by comes from the node's `tn_getCurrentEpochInfo`, else from the tool's status file, else 21600 seconds.

| Message (shortened) | Level | What to do |
|---|---|---|
| `P2P committee mode is on, but its sync tool ... is missing` | error | `--p2p-committee sync`, which reinstalls the pinned tool |
| `P2P committee mode is on, but nftables has no table inet tn_p2p_allow: P2P is open to every source.` | error | `--p2p-committee sync`, which loads the allowlist again |
| `P2P committee mode is on, but tn-p2p-allow-sync check finds table inet tn_p2p_allow dormant (set by hand): it enforces nothing, and P2P is open to every source until a sync applies it again.` | error, with any committee address the table lacks on the line below | `--p2p-committee sync`, which applies the allowlist again and wakes the table |
| `... the new-flow limit table inet tn_p2p is loaded as well` | warning | `firewall-setup.sh --enable`, which removes the limit in committee mode (`sync` does not) |
| `telcoin-p2p-allow-sync.timer is not enabled and active` | warning | `--p2p-committee sync` |
| `P2P committee allowlist is stale: no good sync for <age>, more than 2 epochs of <length>; failing since <time> (<reason>)` | warning, only for a run that did not fail and a reason not reported at once below | Read `journalctl -t tn-p2p-allow -n 20`, fix the cause (usually the node's RPC), then `--p2p-committee sync` |
| `its last sync failed (<reason>, failing since <time>)` (`RESULT=error` in the status file) | warning, at once | Read `journalctl -u telcoin-p2p-allow-sync.service -n 20`, fix the cause, then `--p2p-committee sync` (for `config-invalid`, `sync` alone rewrites the config) |
| `the last run of telcoin-p2p-allow-sync.service failed (it exited with status <n>)`, `(it was killed by signal <n>)` or `(systemd result <result>)`, such as `timeout` | warning, at once, unless the line above already reported the failed sync; exit 3 (stale) and 4 (busy) count as success | Read `journalctl -u telcoin-p2p-allow-sync.service -n 20`, fix the cause, then `--p2p-committee sync` |
| `this node release lacks tn_admissionSnapshot, or tn is not in its --http.api` (`rpc-method-missing`) | warning, at once | `update-node.sh`, or put `tn` back in the node's `--http.api`; the next timer sync clears it |
| `the node serves admission snapshot version <n>, which the installed tn-p2p-allow-sync does not read` (`snapshot-version-<n>`) | warning, at once | `update-scripts.sh`, then `--p2p-committee sync` |
| `the node reports an epoch below the one the allowlist was built from (epoch-regressed, stale since <time>)` | warning, at once; it clears by itself once the node's tracked epoch is back at or above the applied one (after a startup record-sync replay) | Nothing at first; if it persists past 2 epochs, `--p2p-committee off`, then `--p2p-committee on` |
| `tn-p2p-allow-sync cannot read its own state.json (state-invalid)` | warning, at once | `--p2p-committee off`, then `--p2p-committee on` |
| `P2P committee allowlist lacks <N> address(es) of the current committee (<at most five>, and <M> more)` | error | `--p2p-committee sync`; their packets are dropped until it runs |
| `<N> committee key(s) have node records that list other addresses than the ones this node knows them by` | warning | Nothing on this node: the allowlist admits both; the peer's inventory entry is stale or the peer moved |
| `not compared with the committee: the last sync is behind the snapshot (a newer epoch, or an address it never held)` | info | Nothing; the next sync catches up, also for an address that joined since the last sync |
| `not compared with the committee: the node's admission snapshot cannot be used now (<reason>)` | info | Nothing, unless the stale warning follows |
| `consistency check failed: tn-p2p-allow-sync check ended with reason <token>` | error | `--p2p-committee sync`; details in `journalctl -t tn-p2p-allow -n 20` |
| `The P2P committee allowlist config no longer matches this node`, with `RPC_PORT:`, `P2P_PORTS:` or `P2P_ALLOW_FROM:` lines | warning | `--p2p-committee sync`, which rewrites the config |

The reasons in the consistency lines are the `reason=` word the tool logs on its `error` and `stale` lines, since its result line carries none.
Only the errors count in the closing verdict's `<N> issue(s) found`; the warnings, the at-once ones included, do not, so a node whose allowlist fails every sync can still end with `All checks passed`.
Read the lines above the verdict: while the syncs fail the allowlist keeps its last-good set, and a committee address it then lacks is the error.

**Known limitations.**

- The floor trusts the genesis `committee.yaml` copy in the data dir: that copy is writable by the service user, so a compromised node process could add addresses to the floor.
  Checking it against the network's chain-config pin would close this, and mainnet has no such pins yet; the two maps live root-owned in `/etc/telcoin`.
- The counters `tn_accept_p2p_listed` and `tn_drop_p2p_unlisted` kept their values across reloads on the kernels tried so far; the Ubuntu runner kernels are confirmed by the first CI run of the VM test (`tools/tests/vm.d/P0-p2p-allow.sh`).
  The same first run confirms the sync unit's sandbox on systemd 255, and whether the boot unit could run with `ProtectKernelModules=` on (it is off for the first nftables load after boot).
- The tool ships for x86_64 only until the node ships an aarch64 release, and how fast a release-key rotation must reach the pin is still to be agreed.
- An egress address the record does not carry is dropped (above).
- `--enable` with committee mode on and an older `lib/common.sh` prints the resync's error but exits 0, because the `ufw` rules went through.
- A run of `--p2p-committee sync` stopped between a unit rewrite and its reload is not finished on exit; run it again.

### 2.11 AWS one-click

On AWS, a CloudFormation stack in your own account builds a ready node host: the network, the instance, the data volume, the host preparation and the scripts.
It does not run setup: you run it from a Session Manager shell, so the BLS passphrase never enters AWS.
The stack is for the Adiri testnet; setup's network menu picks the network as on any host, and mainnet stays off (section 1.5).
The template is [aws/node.yaml](aws/node.yaml).

**Launch.**
Telcoin publishes the template with every script release, as `templates/<scripts-vX.Y.Z>/node.yaml` in its template bucket, and the launch link opens it on the CloudFormation console's quick-create page.
Pick the region at the top of the console first.
Without the link, download `aws/node.yaml` from the release tag and create the stack from it (CloudFormation, `Create stack`, `Upload a template file`).
Launch it signed in as an administrator of the account, or as a user allowed to create the VPC, EC2, IAM role and Systems Manager resources listed below: CloudFormation creates them with your permissions.
On the console page, leave `Permissions` (the IAM role) empty and leave deployment validations on.
The stack creates one IAM role, the instance's, so tick `I acknowledge that AWS CloudFormation might create IAM resources`.

| Parameter | Choices |
|---|---|
| `Preset` | `FullNode` (default): c7i.2xlarge, 4 cores (8 vCPU), 16 GiB. `PublicRPC`: c7i.4xlarge, 8 cores (16 vCPU), 32 GiB, plus TCP 80 and 443 for Caddy (section 5). `Validator`: c7i.2xlarge, 4 cores (8 vCPU), 16 GiB, the same size as `FullNode`. |
| `InstanceType` | Empty for the preset's type, or another x86_64 type. Graviton (arm64) types are refused: the image is amd64. |
| `DataVolumeSize` | `500` (default, the recommended testnet size) or `350` GiB (the testnet minimum). `2000` and `4000` stay allowed for stacks launched with them. |
| `AutoUpdate` | `Enabled` (default) or `Disabled`: the daily update association below. |
| `ImageId` | Canonical's public SSM parameter for the current Ubuntu 26.04 amd64 image. Leave it as it is. Ubuntu 24.04 still works: set it to `/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id`. |

Cores, RAM and disk size follow the recommended column of the testnet table in section 1.1; the disk is an EBS network volume, not a local NVMe drive. A validator also needs the Association's approval and a stake (section 6); the host is the same.
The gp3 data volume is provisioned at 15,000 IOPS and 300 MiB/s. A `c7i.2xlarge` sustains 12,000 IOPS and 312.5 MB/s to EBS and bursts above that for 30 minutes at least once every 24 hours, so on `FullNode` and `Validator` the volume gives 12,000 IOPS sustained and 15,000 in bursts. A `c7i.4xlarge` (`PublicRPC`) sustains the full 15,000.

**What the stack creates.**

- A VPC (`10.0.0.0/16`) with one public subnet in the region's first availability zone, an internet gateway and a default route.
- An Elastic IP on the instance's network interface, in place before the instance boots, so setup detects it as the public IP and advertises it in the multiaddrs.
- A security group: UDP 49590 and 49594 in from everywhere, TCP 80 and 443 on `PublicRPC` only, no SSH, everything out. TCP 43174, the testnet health monitor's port (section 4.6), stays closed; add a rule for `104.155.184.201/32` yourself if you turn the health monitor on.
- An Ubuntu 26.04 instance from Canonical's image, with IMDSv2 required and an encrypted 50 GiB gp3 root volume. Its role trusts `ec2.amazonaws.com` only and carries only `AmazonSSMManagedInstanceCore`, the policy Session Manager and Run Command need.
- An encrypted gp3 data volume (15,000 IOPS, 300 MiB/s), mounted at `/var/lib/telcoin` by UUID with `nofail`, and kept when you delete the stack. The stack takes no snapshots and sets up no backups: a snapshot of this volume is a copy of the node keys (section 4.12).
- First-boot preparation, as root: the CVE-2026-31431 mitigation (`/etc/modprobe.d/telcoin-algif-aead.conf`, section 1.2) before anything else, swap off, the data volume formatted ext4 only when it carries no filesystem, and the scripts installed for the `ubuntu` user in `/home/ubuntu/telcoin-node-scripts` by the installer of section 2.1. Time sync stays as Canonical's image sets it up (chrony with the Amazon Time Sync Service).
- The stack reaches `CREATE_COMPLETE` only once that preparation reported success. On a failure it rolls back, the `HostReady` event gives the reason, and `/var/log/cloud-init-output.log` on the instance has the detail.
- The daily update association and two Run Command documents (below).

**Set up the node.**
Open the `SessionManagerUrl` output, or the instance in the EC2 console, `Connect`, `Session Manager`.
The shell runs as `ssm-user`, which has `sudo`.
Run the two commands from the outputs, in this order:

```bash
sudo bash /home/ubuntu/telcoin-node-scripts/setup-node.sh
sudo bash /home/ubuntu/telcoin-node-scripts/firewall-setup.sh --enable --ssh-from 10.0.0.0/16
```

Setup runs as in section 2.2.
Press Enter at `Data directory [/var/lib/telcoin]`: that is the data volume, and setup hands the mount point (root-owned, holding only `lost+found`) to the `telcoin` user.
The second command is the `FirewallCommand` output: it turns `ufw` on as in section 2.6 and allows SSH from inside the VPC only.
Session Manager needs no inbound port, so neither `ufw` nor the security group gets in its way.

To copy the key archive of section 2.5 off the host, run SSH through Session Manager: add your SSH public key to `~/.ssh/authorized_keys` of `ssm-user` in the Session Manager shell, then from your own machine, with the AWS CLI and its Session Manager plugin (the `InstanceId` output in place of the example ID):

```bash
scp -o ProxyCommand="aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p" \
  ssm-user@i-0123456789abcdef0:telcoin-keys.tgz .
```

The stack does not install the Node Manager UI (section 4.5).
To use it, run `sudo bash /home/ubuntu/telcoin-node-scripts/ui/install-ui.sh`, forward its port through Session Manager, and open `http://127.0.0.1:8080/#t=<token>` with the token from `sudo cat /etc/telcoin-ui/token`:

```bash
aws ssm start-session --target i-0123456789abcdef0 \
  --document-name AWS-StartPortForwardingSession --parameters portNumber=8080,localPortNumber=8080
```

`open-ui.sh` needs SSH, so it does not apply here.

**Updates.**
With `AutoUpdate` enabled, a State Manager association runs the stack's update document on the instance every day at 03:00 UTC, after a random wait of up to an hour.
It does nothing until setup has written `/etc/telcoin/.node-meta`; then it runs:

1. `update-scripts.sh` as `ubuntu`, answered `y` (section 4.1).
2. `update-node.sh --json --check`.
3. When it reports `update_available`: `update-node.sh --json --prepare --ref <latest_ref>`, then `update-node.sh --json --apply`, without `--yes`. An update that is already prepared is applied, not prepared again.

The apply runs the quorum check and the epoch wait of section 4.2 like any other.
On a node that is not a staked validator it goes ahead.
On a staked validator, or one whose stake cannot be read, `update-node.sh` refuses an apply without `--yes`: the prepared update waits, and the run ends with `the update is prepared and waits`.
Apply it when the node may restart: in Systems Manager, `Run Command`, run the document the `ApplyUpdateDocument` output names on the instance.
It runs `update-node.sh --json --apply --yes`.
A one-way update (section 4.2; the check reports `storage_migration` true) waits on every node: the association prepares it, never applies it, and ends with `The update is prepared and waits`.
Apply it with the same document once you accept that older releases cannot open the data dir afterwards.
The association never runs `ui/install-ui.sh --update` or `setup-alerts.sh --refresh`: when its output (State Manager, the association, `Execution history`) shows `update-scripts.sh` printing one of them, run it yourself.

**Telcoin's access.**
None.
The stack creates no cross-account role and no Systems Manager hybrid activation, and names no Telcoin principal: the only principal is `ec2.amazonaws.com`.
Updates are pulled: Telcoin publishes signed releases, and the association on your instance downloads and verifies them (section 4.10).
The cfn-guard rules in `aws/rules/` pin this, and CI checks the template against them on every change.

**Changing the stack later.**
Existing stacks keep running as they are; nothing in this release needs a change on them.
Do not update a stack to this template.
Every stack update reads Canonical's image parameter again.
Once a newer Ubuntu image is out, expect an update to try to replace the instance, fail because the old instance holds the network interface, and roll back.
An update of an older stack to this template also changes the data volume's IOPS. Expect that change to land before the failure, and the rollback to wait until the volume modification completes, which can take hours, with the stack in `UPDATE_ROLLBACK_IN_PROGRESS` meanwhile.
If the image has not changed, expect a `Validator` stack's update to stop and start the instance to change its type, outside the epoch-boundary wait of `update-node.sh`.
Make later changes on the resources instead:

- To raise the data volume of an older stack to 15,000 IOPS, use the EC2 console (`Volumes`, `Modify volume`). The node keeps running, and the volume takes no other modification until this one shows `completed` (at most four modifications in 24 hours).
- To move an older `Validator` stack to `c7i.2xlarge`, or to change any instance type, use the EC2 console (stop the instance, `Actions`, `Instance settings`, `Change instance type`, start it) at a time when the node may restart.
- A volume can grow but not shrink, and a stack update that picks a smaller `DataVolumeSize` fails. After you grow a volume, grow its filesystem on the host: `sudo resize2fs "$(findmnt -no SOURCE /var/lib/telcoin)"` (the volume has no partition table, and ext4 grows while mounted). Do not snapshot the volume first: a snapshot is a copy of the node keys (section 4.12).
- To stop the daily updates, delete the association in State Manager.

Stopping the instance stops the node; on a committee node, keep clear of the epoch boundary (section 4.2).

**Deleting the stack.**
It deletes everything but the data volume (the `DataVolumeId` output), which holds the node keys and the chain data.
Back up the keys first (section 2.5), then delete the volume in the EC2 console, `Volumes`, once you no longer need it.
A stack whose creation failed leaves its data volume behind too.

**Quotas.**
Each stack takes one VPC and one Elastic IP, and an AWS region allows 5 of each by default.
Ask for more in Service Quotas before a sixth node in one region.

**Cost.**
You pay AWS directly, mainly for the instance (by the hour, by type), the data volume (its size, plus the provisioned 15,000 IOPS and 300 MiB/s above what gp3 includes, 3,000 IOPS and 125 MiB/s), the Elastic IP (public IPv4 addresses are billed by the hour), and data transfer out to the internet: P2P traffic to peers, and on `PublicRPC` the RPC traffic.
The AWS Pricing Calculator gives the figures for your region.

### 2.12 Generate mainnet keys before genesis

The mainnet genesis is built from the validators' `node-info.yaml` files, so a mainnet validator generates its keys before the genesis, its chain configs or a signed mainnet release exist.
This script release opens that one step on mainnet (`TN_MAINNET_KEYGEN_ENABLED=1` in `lib/common.sh`); every other mainnet path stays refused until the launch release (section 1.5).
The Node Manager UI does not offer it.

You need:

- The Safe address assigned to your validator (`0x` and 40 hex digits). It is signed into the proof of possession, becomes the validator's execution address in the genesis, and receives its rewards.
- A `telcoin-network` binary built with no build features, from the commit the mainnet release is cut from: `cargo build -p telcoin-network --bin telcoin-network --release --locked` at the workspace root. Keep the `-p telcoin-network`: without it cargo builds a test binary (`Build Features: test_utils`). `telcoin-network --version` must print an empty `Build Features:` line; setup refuses a binary whose line names any feature, a testnet build included. Install it root-owned where the service user can run it, for example `sudo install -o root -g root -m 0755 target/release/telcoin-network /usr/local/bin/telcoin-network`.
- The public IP address and the ports the node will use. They go into `node-info.yaml` and from there into the genesis `committee.yaml`. Setup generates one worker.
- A mainnet host as in section 1: Ubuntu 24.04 or later, a usable TPM2 (or `--allow-no-tpm`), and a BLS passphrase of at least 16 bytes.

```bash
ARGS=(--network mainnet --install-method existing --binary-path /usr/local/bin/telcoin-network
  --address 0xYOUR_VALIDATOR_SAFE
  --external-primary /ip4/203.0.113.10/udp/49590/quic-v1
  --external-worker  /ip4/203.0.113.10/udp/49594/quic-v1
  --listener-primary /ip4/10.0.0.5/udp/49590/quic-v1
  --listener-worker  /ip4/10.0.0.5/udp/49594/quic-v1)
read -rs PASS
printf '%s\n' "$PASS" | sudo bash ~/telcoin-node-scripts/setup-node.sh --json --phase=keygen --passphrase-stdin "${ARGS[@]}"
unset PASS
```

The run checks the binary's build features before anything on the host changes, and runs it for that (`--version`, as root, given 30 seconds) only once it is a root-owned file, not group- or other-writable, in root-owned directories; then it runs the preflight, creates the service user and the directories, records the install and `NETWORK=mainnet` in `.node-meta`, has the keytool generate the keys and the proof of possession for the Safe address, and stores the passphrase as an encrypted credential.
It gets no chain configs (`Mainnet chain configs are not published before genesis: keygen goes on without them. ...`), writes no unit and starts nothing.
It ends with `node-info.yaml` and the next steps below; the onboarding and staking steps a testnet run prints do not apply to a genesis validator and are not shown.
It refuses to run over an existing `node-keys/`.
The passphrase is stored before the keys are made, and a hangup (an SSH drop), Ctrl-C or TERM during key generation is held until the keys are checked, so no run leaves keys without their stored passphrase; a run whose keytool fails or is stopped removes what the keytool wrote and the stored passphrase, and you run it again.
Send `node-info.yaml` only from a run whose `done` event says `"ok":true`.
A run killed outright (KILL, a power loss) can still stop between two steps; a second run then names what it found instead of making keys:

- `... all in place: there is nothing to generate.`: the keys, `node-info.yaml` and the stored passphrase are there. Use that `node-info.yaml`.
- `An earlier keygen did not finish ...`: nothing from that run was reported. Remove `node-keys/` and `node-info.yaml` as the message says and run keygen again.
- `... but no stored passphrase ...` (left by an earlier script version): the keys open only with the passphrase typed for that run, and finalize refuses them too. If you still have that passphrase, store it, with `--with-key=host` instead on a host keyed with `--allow-no-tpm`:

  ```bash
  read -rs PASS
  printf '%s\n' "$PASS" | sudo sh -c 'umask 077 && systemd-creds encrypt --name=bls-passphrase --with-key=host+tpm2 - /etc/telcoin/bls-passphrase.cred'
  unset PASS
  sudo sh -c 'printf "PASSPHRASE_METHOD=credential\nCREDENTIAL_KEY=host+tpm2\n" >> /etc/telcoin/.node-meta'
  ```

  Otherwise remove `node-keys/` and `node-info.yaml`, run keygen again, and send the new `node-info.yaml` in place of any you sent.

Before anything on the host changes, `--install-method release`, `docker` or `source` stops with `--install-method <method> cannot install a mainnet node yet: before genesis no mainnet release, image or source tag can be verified. Generate the mainnet keys with --phase=keygen --install-method existing --binary-path <...>`, and a binary with build features with `Refusing the node binary at <path>: it is not a mainnet build (This build has the features <features>; a mainnet build has none.)`.

Send `node-info.yaml` from the data directory (`/var/lib/telcoin/node-info.yaml` by default; the run prints the path, and its `done` event carries the file in `node_info`).
It is public: the node's name, BLS public key, primary and worker addresses and network keys, the execution address and the proof of possession.
Never send or copy anywhere `node-keys/` (`bls.kw` is the BLS private key, wrapped with the passphrase) or the passphrase.
Back both up offline now (section 2.5): together they are the identity the genesis registers, and losing either one loses it.

The proof of possession signs the BLS key and the Safe address only, with no chain ID or genesis hash, so it stays valid for whatever genesis is built.
Once the mainnet release and genesis are published, update the scripts (section 4.1) to the release that enables mainnet and run `setup-node.sh --json --phase=finalize` with the same arguments on this host, as that release's notes say; it uses these keys as they are.
Finalize keeps the install method and the binary path keygen recorded, and refuses a different `--install-method` or `--binary-path`, so keep the binary at that path.
This finalize does not fetch the mainnet chain configs itself, so on install day put the published `genesis.yaml`, `committee.yaml` and `parameters.yaml` in a root-owned directory and pass it with `--genesis-dir`, and install the signed mainnet release binary by hand, root-owned, at the path keygen recorded (`grep BINARY_PATH /etc/telcoin/.node-meta`).
A mainnet BLS key must never sign on another network, so once keygen has recorded `NETWORK=mainnet` (before it makes the keys), setup refuses a finalize, a keygen or an interactive install for testnet or devnet on this host (a `--json` run without `--network` is a testnet run): it stops right after the root check, before anything on the host changes, with `The keys on this host were generated for mainnet (NETWORK=mainnet in /etc/telcoin/.node-meta) and must not be used on another network, ...`.
Set up a testnet node on another host.

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

It compares your node with the public RPC of the network in `.node-meta` (`https://rpc.adiri.tel` on testnet, section 1.5; `--network-rpc <URL>` picks another) and ends with one verdict.
When `.node-meta` has no `NETWORK` and the local RPC reports no Telcoin chain ID, there is nothing to compare with: the header reads `Network RPC:  none (network unknown; give --network-rpc URL to compare)`, the network sections are skipped with that reason, and it does not count as an issue.
The `Network RPC:` line says whose endpoint it is, such as `https://rpc.telcoin.network (mainnet public RPC)` or `<url> (--network-rpc, for testnet)`.
The verdicts:

- `CATCHING UP: <N> execution blocks behind` while the node is more than 50 blocks behind the network (the script's `EVM_SYNC_THRESHOLD`).
- `All checks passed -- node is healthy and caught up (EVM lag <N>)` once it has caught up.
- `<N> issue(s) found -- review warnings/errors above` when something else is wrong.

Run it twice a few minutes apart.
The second run also reports how far the local block advanced since the first, which tells you whether the gap is closing.
The report header has a `Network:` line with the network, its chain ID and where that came from, and the first section lists what the node runs: the Docker image or binary, the bootstrap peers and state export when set, the P2P ports and the RPC URLs it advertises.
When the node binary supports `tn_nodeMode`, the report also prints a `Consensus role:` line.
The script always exits 0, so anything that consumes it should read the verdict line, not the exit code.
The one exception is `check-node.sh --audit`, which prints only the host hardening report (section 1.2) and exits 1 when any line warns.
The regular run checks more of the hardening on an installed node: the root-owned layout and modes (section 2.4; on mainnet the old layout is an error), the update lock, the unit's sandbox settings, a stray cleartext `bls.key`, and that neither the unit nor the start script puts the passphrase in the environment.
Its last block, `Checking the script release...`, reads the installed release record of the scripts (`~/telcoin-node-scripts/MANIFEST`): the tag, serial and release date, and the expiry date (section 4.1). An expired release, or no record at all, is a warning with the command to run; it never counts as an issue, and the block makes no network call.
It also runs on macOS, where it skips the memory check with a note.

If the comparison RPC serves another chain than the node's, the report says so and skips the comparison instead of blaming the node, for example `https://rpc.telcoin.network serves chain 2017 (testnet), not chain 731 (mainnet) -- skipping the network comparison`.
That is what a mainnet node would see today with the default RPC, because mainnet has not launched and its hostname still serves the testnet (section 1.5).
It does not count as an issue; `--network-rpc <URL>` with an RPC for the node's chain brings the comparison back.

### The epoch section

The `Checking epoch and committee...` section shows the current epoch, the time to the next boundary and its UTC time, and committee membership for this epoch and the next two, for example `epoch 581: not a member · 582: not a member · 583: member`.
"Not a member" is normal for a node that is not a validator, for a validator before its first seat, and for an Active validator between seats.
Such a node also gets the info line `Not in recent headers -- expected: this node is not in the committee for epoch 581`.
Only a committee member missing from the latest headers is an error.

It also prints `Committee of epoch <E>: <N> members (on-chain)`.
That count can differ from the `<N> authors in the latest commit` on the `Network: block ... · epoch ...` line, which counts only the validators whose headers made it into the latest commit.
For a staked validator the section adds the activation epoch and the earliest committee seat (section 6.8).
It also compares the node's workers with the number the network requires (`WorkerConfigs.numWorkers()`, 1 on testnet today).
Fewer is an error: workers are fixed when the keys are generated and no script adds one, so email support@telcoin.org before the node is due for a committee seat.

### Checking by hand

Do not use `eth_syncing`.
On Telcoin Network it returns `false` even while the node is catching up.
Compare `eth_blockNumber` on your node with the public RPC instead:

```bash
bn() { curl -s -X POST -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' "$1" \
  | sed -E 's/.*"result":"(0x[0-9a-fA-F]+)".*/\1/'; }
echo "local:   $(( $(bn http://127.0.0.1:8545) ))"
echo "network: $(( $(bn https://rpc.adiri.tel) ))"
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
It reads the current script release from the `RELEASE` file on `main` (a `scripts-v*` tag and its date), downloads that tag's `MANIFEST` and `MANIFEST.asc`, and verifies the OpenPGP signature with `gpgv` against the release keys in `lib/release-keys/` (the keys that also sign node releases).
It needs `gpgv`; without it the updater stops with `gpgv (GnuPG) is needed to verify script releases and is not installed; nothing was changed.` Install it with `sudo apt-get install -y gpgv` and run the updater again.
It refuses a release whose serial is lower than the installed one, or the same serial with a different manifest.
When the manifest asks for a newer updater than the one running (`min_updater`), it stops and prints the installer one-liner from section 2.1.
Then it downloads every file that changed, checks each against its manifest hash (and its `.sha256` sidecar where one is published) and with `bash -n`, and asks `Install these changes? [Y/n]`.
It installs the whole release or nothing: one bad file and the tree stays as it was.
A release that ships a new `update-scripts.sh` runs that verified copy from the staging directory, which installs everything, itself included, in one pass.
The installed release is recorded in `~/telcoin-node-scripts/MANIFEST` and `MANIFEST.asc`.
New scripts, and the release keys in `lib/release-keys/`, arrive the same way.

The updater no longer redeploys the Node Manager UI.
When the UI files changed, it prints the command; run it yourself:

```bash
sudo bash ~/telcoin-node-scripts/ui/install-ui.sh --update
```

In the same way, when the release changes the private alerts runner or its library on a host that has them (section 4.14), it prints `The heartbeat runner or its library changed. Reinstall them on the host:` and the command:

```bash
sudo bash ~/telcoin-node-scripts/setup-alerts.sh --refresh
```

A host on `update-scripts.sh` 1.1.72 or older moves to signed releases once: its old updater takes the new `update-scripts.sh` through the old checksum channel (hashes from `main`, unsigned), which then fetches the release keys once through their published checksums (it warns `First signed release on this host: ...`), and from then on every update is a verified manifest.

A host whose scripts were cloned from `main` before `scripts-v2.1.0` runs update-scripts 2.0.0, which checks SSH signatures that no release carries. It stops with `Release scripts-v2.1.0 has no MANIFEST.sig; nothing was changed.` Run the installer once to move it to signed releases:

```bash
curl --proto '=https' --tlsv1.2 -fsSL https://install.telcoin.network | bash -s -- --yes
```

A leftover `lib/allowed_signers` in the install directory is no longer used and is not removed; you may delete it.

When the updater refuses with `The release manifest is not signed by a Telcoin release key (it is signed by release key <id>, which has expired); nothing was changed.`, the copy of the key on your host has passed its expiry date (the current key expires 2028-10-16), and no later release verifies against it. Run the installer one-liner above: the published installer carries the current keys.
Section 4.9 lists the remaining steps for an existing testnet install.

Run it before every node update.
`update-node.sh` learns how to handle new releases through these updates.

To see whether you are current without changing anything, run the release check:

```bash
bash ~/telcoin-node-scripts/update-scripts.sh --check
```

It needs no root, installs nothing and asks nothing.
It prints the installed release and the newest signed release on GitHub (tag, serial, release date, expiry, each with its signature verified against `lib/release-keys/`), whether an update is pending, and whether either release has expired.
Its exit status: 0 when the installed release is the newest and neither has expired; 1 when an update is pending or a release has expired; 2 when no signed release is installed, a record or the newest release cannot be verified or fetched, or the updater would refuse the newest release (2 wins when both apply).

Each release carries an expiry date, 90 days after its release date unless the release signer chose another.
An expired release still verifies and still installs: expiry means a newer signed release is overdue, not that the old one is unsafe.
From that day on `update-scripts.sh` and `install.sh` warn `Script release <tag> expired on <date>; a newer signed release is overdue. Installing it anyway.`, followed by `The release still verifies. If no newer one appears soon, tell support@telcoin.org.`, and `check-node.sh` shows it in its script release block.

### 4.2 Update the node

```bash
sudo bash ~/telcoin-node-scripts/update-node.sh
```

The script works out whether the node was built from source, installed from a signed release or runs in Docker, and offers the matching versions.
It takes release tags only (`vX.Y.Z-adiri` on testnet, or a release candidate `vX.Y.Z-adiri-rcN` that you name; `vX.Y.Z` on mainnet), never a branch or a commit id.
Source installs get the same release-tag picker as setup and build the tag as `tn-build`; the checkout is refused when origin's tag moved or its signature is bad.
Release installs ask for the release tag (Enter takes the newest final release of the network on GitHub), then download and check it as setup does (section 2.3).
Docker installs get the final release tags of the network's image repositories (on testnet `ghcr.io/telcoin-association/tn-testnet` and the legacy Artifact Registry repository), newest first, and `Custom tag` for any other release tag, a testnet release candidate among them; the script resolves the chosen tag to its digest, pulls by digest, checks after the pull that Docker holds that digest, and checks the image's build features against the network before it prepares anything (a refusal ends `... nothing was prepared and the node was not touched.`).
Then it asks how far to go:

- `1) Prepare only` builds or downloads the binary, or pulls the image, while the node keeps running. Apply it later in a quiet window.
- `2) Prepare AND apply` also stops the node, swaps in the new version, restarts it and checks its health.
- `3) Cancel`, or any other input, cancels.

A prepared update survives between runs.
The next run offers `1) Apply now`, `2) Discard and prepare a different update` or `3) Exit`, and `sudo bash ~/telcoin-node-scripts/update-node.sh --discard` drops it after asking `Discard this pending update?`.
After an apply that was cut short, a discard puts back the unit, start script and `node.env` that apply had rewritten; when it was a one-way update (below) that had already started the new release, the discard keeps them as the apply wrote them and prints how to go back.

What else to expect:

- On a node registered on-chain as a validator (status 1 to 4), or one whose status cannot be read, the script shows a downtime warning and asks you to type `CONFIRM` before it stops the node.
- A release older than the one the node runs is refused (`... is older than the running ...: downgrades are refused.`). Release candidates sort before their final: rc1, rc2, then the final of the same version, then any release candidate of a higher version. So `vX.Y.Z-adiri` over `vX.Y.Z-adiri-rc2`, and `-rc2` over `-rc1`, are upgrades, and `vX.Y.Z-adiri-rc1` over `vX.Y.Z-adiri` is a downgrade. On testnet, an interactive run with `--allow-downgrade` goes ahead anyway; a downgrade across `v0.16.0-adiri` still cannot open the migrated data dir (below). When the running release is not recorded (no version marker, or a digest-only Docker image whose digest differs from the one in `.node-meta`), the script warns that it cannot check for a downgrade and goes on.
- Before it stops a committee node, it runs the committee quorum check (section 4.11); `--allow-quorum-risk` overrides a refusal.
- While the node is stopped, apply writes the start script and unit again from `.node-meta`, so a hand edit to the start script outside the node command line is lost.
- After the restart it waits up to 45 seconds (600 on a one-way update) for the service to be active and for the node to answer `tn_latestConsensusHeader`. When many nodes restart at once, quorum takes longer to form; raise the window with `TN_UPDATE_VERIFY_TIMEOUT`, in seconds, for example `sudo TN_UPDATE_VERIFY_TIMEOUT=120 bash ~/telcoin-node-scripts/update-node.sh`. A number you set always wins, on a one-way update too, so leave it unset there or give it 600 or more.
- Then it checks that the node takes part in consensus: it answers `eth_chainId` with its network's chain ID, its consensus header number advances, and a node that was voting (`CvvActive`) before the update votes again. Both checks share one window, `TN_UPDATE_VOTE_TIMEOUT` (default 600 seconds), polled every `TN_UPDATE_VOTE_POLL` seconds (default 10). A wrong chain ID, a unit that is no longer active or an RPC that no longer answers fails the check whatever the settings.
- When the window runs out while the unit is active and its RPC still answers `eth_chainId`, the update is not failed, because catching up after the restart can take longer than the window. The new release keeps running, nothing is rolled back, and the script warns `... Not rolled back: the unit is active and its RPC answers, so the new release keeps running while it catches up. Watch it with check-node.sh or journalctl -u <service> -f (TN_UPDATE_VOTE_ROLLBACK=1 rolls back on this instead).` A terminal run then says `<service> runs the new release but is not following consensus or voting yet; it was not rolled back.` and `Check it again in a few minutes: bash ~/telcoin-node-scripts/check-node.sh`; a `--json` apply ends with `"ok":true` and `"voting":false` in its `done` line. To treat this case as a failed check, set `TN_UPDATE_VOTE_ROLLBACK=1` (only the value `1` turns it on), for example `sudo TN_UPDATE_VOTE_ROLLBACK=1 bash ~/telcoin-node-scripts/update-node.sh`: the run fails with `(TN_UPDATE_VOTE_ROLLBACK=1: failing the update.)` and offers the rollback like any failed check (a `--json` apply rolls back on its own). After a one-way update (to `v0.16.0-adiri`, or from it to `v0.17.0-adiri`) it fails without a rollback.
- A target older than the network's oldest supported release is refused before anything is fetched, on every install method and with `--json` too: `<ref> is older than v0.13.0, the oldest testnet release these scripts support (...). Pick v0.13.0 or a newer release. Nothing was changed.` Mainnet has no floor until launch. A Docker digest given alone is checked by the release `.node-meta` records for it.
- After a verified apply on a host with the host baseline (section 4.13), it makes the AIDE baseline again before `Update complete`; a failure there is a warning and does not fail the update.
- If either check fails, it offers to roll back to the previous binary or image, except after a one-way update (below). A terminal run asks first; a `--json` run, which the Node Manager UI uses, rolls back without asking.
- On testnet, when the node runs a release older than `v0.16.0-adiri` and the target is `v0.16.0-adiri` or newer, the update is one-way (mainnet and devnet have no storage floor, so no update there is one-way). The new release migrates the consensus store on its first start, and older releases cannot open the data dir afterwards. Snapshot the data dir before you apply (below). The script says the update is one-way, warns when the free space under `consensus-db/epochs` is less than twice its largest `epoch-N` directory, asks whether you have a snapshot, and waits up to 600 seconds. If the check fails it does not roll back and does not stop the node, which may still be migrating, and it leaves the unit, start script and `node.env` on the new release. When the script cannot read which release the node runs, it treats the update as one-way.
- The next release is one-way too. On its first start it copies the consensus database (the epoch in progress, the peer records and the batch caches) from MDBX into tndb, under `consensus-db/tndb/`, and deletes the MDBX files once the copy is durable. An older release does not refuse the migrated data dir: `v0.16.0-adiri` starts on it with empty epoch tables, without this node's record of its own votes and proposals, so a committee member run that way can sign conflicting messages. That release is `v0.17.0-adiri`, and `update-node.sh` has its floor beside the `v0.16.0-adiri` one: an update across it is one-way as above (the warning, the snapshot question, up to 600 seconds, no rollback after a failed check), and `--json --check` reports `"storage_migration":true` for it. Take the snapshot (below) before that update: it is the only way back. Do not go back with `--allow-downgrade`.
- `update-node.sh --json --check` (what the Node Manager UI polls) reports the newest final release as `latest_ref`: for release and Docker installs the newest release of the network on GitHub, for source installs the newest final tag on origin. On testnet, while the network has no release on GitHub or GitHub cannot be read, a Docker install takes the newest final tag the two image repositories list instead. A release candidate is never reported as an update.
- Only one update runs at a time. A second run stops with `Another update is already running (PID N).`
- It never touches the keys, `node-info.yaml`, the BLS passphrase, the chain configuration, or the listener addresses.
- When the target release is `v0.15.0-adiri` or newer and the launch file still passes `--observer`, it removes the flag.
- A ref that is not a release tag is refused: `<ref> is not a testnet release tag (testnet vX.Y.Z-adiri or the release candidate vX.Y.Z-adiri-rcN, mainnet vX.Y.Z; release candidates are testnet only): updates take release tags only, never a branch or a commit id.` A ref that starts with `-` gets `Invalid ref "<ref>": a ref cannot start with "-".` before any git command runs.
- The first run on a host laid out by older scripts moves it to the root-owned layout (section 4.9). A mainnet host on the old layout is refused: `This mainnet node still has the old file ownership layout and must be installed fresh; it is not migrated in place. Nothing was changed.`
- A node whose unit still holds the passphrase or runs the node command inline is refused until `edit-config.sh --migrate-credential` has moved it (section 4.8).

Before a one-way update, snapshot the data dir with the node stopped.
Prepare first (`1) Prepare only`), so the node is down only for the copy:

```bash
sudo systemctl stop telcoin
sudo cp -a /var/lib/telcoin /var/lib/telcoin.pre-v0.16   # or take a disk snapshot instead
sudo systemctl start telcoin
```

The copy needs as much free space as the data dir; a disk snapshot from your cloud provider needs none on the server.
On a committee node, stop it well away from an epoch boundary; `check-node.sh` shows the time to the next one.
Then run `update-node.sh` again, choose `1) Apply now`, and answer yes when it asks about the snapshot.
The first start can take minutes, and `journalctl -u telcoin -f` shows `migrated legacy pack to v2 on open` for each epoch it opens.
If the health check fails, the script leaves the node on the new release and does not stop it, and the unit, start script and `node.env` stay as the update wrote them, so a restart starts the new release again. A node that is still migrating comes up without help, and a node that stopped says why in the journal, so read the journal before you decide to go back.
`v0.16.0-adiri` runs no start-up check of its epoch database, `consensus-db/epoch` (the epoch in progress, not `consensus-db/epochs`, the epoch packs this update migrates): a damaged row there stops the node with a panic, `Invalid bytes!`, while the database opens, and section 9 says what to send support@telcoin.org.
The check that stops a node with `Cannot check database (epoch)` comes with the next release (below).
To go back, stop the node, move the migrated data dir aside and the snapshot back into its place (for the copy above, `/var/lib/telcoin.pre-v0.16` back to `/var/lib/telcoin`), run the copy command from the error message, which puts the old start script back (with the old binary, unit and `node.env` on a source or release install), and start the node.
An older release cannot start on the migrated data dir; it stops with `invalid version (should be 0)`.

The first start of the next release logs `copied <n> rows of the consensus DB from MDBX to tndb` when it copied any, and writes the marker `consensus-db/tndb/mdbx-migrated`.
If it stops with `Cannot migrate the consensus DB from MDBX`, the MDBX files are untouched, because they are deleted only once the copy is durable, and the next start copies again; when that line goes on with `Cannot check database (epoch)`, every retry stops the same way, and section 9 has the fix.
After the migration the epoch database is `consensus-db/tndb/epoch`; do not move it aside, even when the node stops with `Cannot check database (epoch)` (section 9).

When the node votes in the current committee (`tn_nodeMode` is `CvvActive`) and the epoch boundary is within the restart margin, the apply waits before it stops the node, so the node is not down for the epoch change.
It waits until the epoch closes, then a settle time for the new committee, never longer than 30 minutes in all, and prints a progress line every 15 seconds.
The margin and the settle time follow the epoch length the node reports: the margin is 1/72 of the epoch, held between 300 and 900 seconds, and the settle time 1/240 of it, held between 90 and 300 seconds.
Mainnet and testnet both run 6-hour epochs (21600 seconds), which give 300 and 90 seconds; a 7-day epoch would give 900 and 300.
Mainnet's epoch length is confirmed (#49), so these shares stand.
The step line names the values and where they came from:

```text
Waiting for epoch 581 to close before restarting: this node is in the committee and the boundary is due in 3m 20s. Waiting at most 1800s (TN_EPOCH_WAIT_MAX); set TN_SKIP_EPOCH_WAIT=1 to skip. Margin 300s and settle 90s, derived from a 21600 s epoch.
```

Nodes outside the committee are not delayed, and a rollback restart never waits.
To restart at once, pass `--no-epoch-wait` or set `TN_SKIP_EPOCH_WAIT=1`, for example `sudo TN_SKIP_EPOCH_WAIT=1 bash ~/telcoin-node-scripts/update-node.sh`.
`edit-config.sh`, `install-caddy.sh` and the testnet add-ons wait the same way before they restart a committee node; section 7.3 lists the settings.

A committee node that is stopped while the epoch changes anyway (a crash, a restart by hand or a skipped wait) repairs its epoch records when it starts again, and the warnings it logs about them need no action (section 9).
It still misses the epoch votes while it is down, so keep to the wait.

`update-node.sh` does not update an `existing` install.
It names the binary the node runs, taken from the launch file (else `BINARY_PATH` in `.node-meta`), and prints the steps:

```text
[ERROR] Install method is 'existing': this node runs /srv/tn/bin/telcoin-network, which update-node.sh does not replace.
 ->  To update it, stop the node, replace that file with the new release binary, and start it again:
 ->    sudo systemctl stop telcoin
 ->    sudo install -m 0755 <new binary> /srv/tn/bin/telcoin-network
 ->    sudo systemctl start telcoin
 ->  On a committee node, run only the install line instead (it replaces the file while the
 ->  node runs), then restart with edit-config.sh, menu item 14 (Restart node), which waits
 ->  for the epoch boundary: sudo bash ~/telcoin-node-scripts/edit-config.sh
 ->  Check a release before installing it (TAG is the release, such as vX.Y.Z-adiri):
 ->    base=https://github.com/Telcoin-Association/telcoin-network/releases/download/TAG
 ->    curl -fsSL -O "$base/SHA256SUMS" -O "$base/SHA256SUMS.asc" -O "$base/telcoin-network-TAG-x86_64-unknown-linux-gnu.tar.gz"
 ->    cat ~/telcoin-node-scripts/lib/release-keys/*.asc | gpg --dearmor > release-keys.gpg
 ->    gpgv --keyring ./release-keys.gpg SHA256SUMS.asc SHA256SUMS
 ->    sha256sum -c --ignore-missing SHA256SUMS
 ->    tar -xzf telcoin-network-TAG-x86_64-unknown-linux-gnu.tar.gz && telcoin-network-TAG-x86_64-unknown-linux-gnu/telcoin-network --version
 ->  Or let the scripts do all of this: a fresh install with setup-node.sh --install-method release.
```

The path in the example is whatever your node runs.
Section 4.10 walks through the release check, including the chain-config lines and the binary's `--version` lines.
The `gpgv` line the script prints shows `Good signature from` and exits 0 even for a revoked or expired key, so add `--status-fd 1` and read its status lines as section 4.10 says.
After any update, run `sudo bash ~/telcoin-node-scripts/check-node.sh`.

### 4.3 Change the configuration

```bash
sudo bash ~/telcoin-node-scripts/edit-config.sh
```

| Menu item | What it changes |
|---|---|
| `1) Listener addresses` | `PRIMARY_LISTENER_MULTIADDR` and `WORKER_LISTENER_MULTIADDR` in `/etc/telcoin/node.env`. An older install that kept them in the unit is converted on the first edit, with backups. |
| `2) Metrics address` | The `--metrics` address; `off` removes the flag. Only `127.0.0.1` is taken unless you start the script with `--allow-public-metrics` (interactive, as root). |
| `3) Log verbosity` | `-v` to `-vvvvv`. |
| `4) RPC access` | Not for public RPC (see the cautions below). Binding to `0.0.0.0` is refused on mainnet. |
| `5) BLS passphrase` | `1) Change the stored passphrase`, then `2) Seal the credential again (TPM or PCR change)` on a credential install, or `2) Move it to an encrypted credential` on a host that keeps the root-only file. It never re-encrypts the keys. |
| `6) P2P ports` | The P2P listener ports. |
| `7) Docker image` | The image a Docker install runs: a release tag, which the script resolves to its digest, or the network's image by digest. `latest` and other tags that are not release tags are refused, and so is a release older than the network's oldest supported one (`... The image is not changed.`). On mainnet a digest alone is taken only for a mainnet release this node has installed: give the release tag. |
| `8) Bootstrap peers` | A peers map in place of the genesis list (section 2.7), or none. |
| `9) State export` | Off, every epoch's export, or the last N epochs (section 2.7). |
| `10) Private forward targets` | `allow_private_forward_targets` in `parameters.yaml`; private networks only. |
| `11) Admission mode` | Open, Grace or Closed, in `network-config` (section 2.9). |
| `12) Trusted nodes` | The trusted hubs map a closed node admits, or none (section 2.9). |
| `13) Refresh chain configs` | Installs the genesis, committee and parameters files this script release pins for the network (on testnet those of `v0.16.0-adiri`) and copies them into the data directory. It never pulls on testnet or mainnet. |
| `14) Restart node` | |
| `15) Exit` | |

Items 11 and 12 are new in edit-config 2.1.0, which moved Refresh chain configs, Restart node and Exit from 11, 12 and 13 to 13, 14 and 15.
Before the first change to a file, it copies the file into `/var/backups/telcoin` (root 0600).
After an edit it asks `Restart the node now to apply changes?`; No keeps the change for the next restart, unchecked.
Yes restarts it and checks it as `--set` does (below): a node that does not come back has the edit put back and is restarted on the previous files.
The script writes the start script and unit whole, from `.node-meta` and the node command line, so a hand edit elsewhere in those files is lost at the next edit.

For a single edit without the menu, use `--set`, with or without `--json`:

```bash
sudo bash ~/telcoin-node-scripts/edit-config.sh --set state_export=3
```

`--set` restarts the node and checks that it stays up; if it does not, it puts back every file the edit changed and restarts the node on the old configuration.
An edit that writes `network-config` is watched for `TN_EDIT_VERIFY_TIMEOUT` seconds (default 60) after the restart (section 2.9).
When the value is already in place, nothing is written and the node is not restarted; nor is it when the only change is to `.node-meta`, which the node does not read.

| Field | Values |
|---|---|
| `primary_listener`, `worker_listener` | A multiaddr: `/ip4/<addr>/udp/<port>/quic-v1` or `/ip6/...`. |
| `metrics` | `<IPv4>:<port>` adds or changes `--metrics`; `off` removes it. |
| `verbosity` | `-v`, `-vv`, `-vvv`, `-vvvv` or `-vvvvv`. |
| `docker_image` | A release tag (on testnet a release candidate too) or `<repository>@sha256:<digest>` of the network's package, `ghcr.io/telcoin-association/tn-mainnet` or `ghcr.io/telcoin-association/tn-testnet` (on testnet also the legacy `us-docker.pkg.dev/telcoin-network/tn-public/adiri`), Docker installs only. The image is pulled by digest first, the digest is checked after the pull, and the image's build features are checked against the network before the change is made (`refusing <image>: it is not a <network> image (see above); the image is not changed`). A release older than the network's oldest supported one is refused. On mainnet the change is refused until a mainnet release can be verified (section 1.5); after that a digest alone is taken only when `.node-meta` records it as the image of a mainnet release. |
| `bootstrap_peers` | An absolute path to a peers map, checked as at setup (section 2.7) and installed as `/etc/telcoin/bootstrap-peers.yaml`, or `none` to remove the flag and the file. With an admission mode it is also written as `committee_peers` when it lists every genesis validator (section 2.9). Needs `v0.15.0-adiri` or later and a start script (section 4.8). |
| `state_export` | `off`, `unlimited` (every export kept; `v0.13.0-adiri` or later) or a number of epochs to keep, 1 to 999999 (`v0.15.0-adiri` or later). |
| `allow_private_forward_targets` | `true` or `false`. `true` lets the node forward transactions to committee RPC endpoints on private addresses. `true` is refused on testnet and mainnet, so it is for private networks such as a devnet; `false` is accepted everywhere. |
| `admission` | `open`, `grace` or `closed`: the admission mode, written into `network-config` with the recorded trusted nodes map and, as `committee_peers`, the installed bootstrap peers map when it lists every genesis validator. Needs node release 0.17.0 or later (section 2.9). |
| `trusted_nodes` | An absolute path to a trusted nodes map, shape-checked and installed as `/etc/telcoin/trusted-nodes.yaml`, or `none` to remove it. Needs an admission mode first (section 2.9). |
| `gateway_upstream` | `<IPv4>[,<IPv4>...]` or `off`. The list binds the RPC and the health check to every interface (`--http.addr 0.0.0.0`, `--healthcheck 0.0.0.0:43174`) for worker gateways on those hosts, and is refused unless `ufw` already admits them (`firewall-setup.sh --enable --gateway-from`) and keeps every other address out of both ports; `off` puts both back. A stopped node (inactive or failed) stays stopped; a node that is starting, stopping or waiting for its automatic restart is refused. Section 4.15. |

A listener's UDP port must match the advertised external port (`EXTERNAL_PRIMARY_ADDR` or `EXTERNAL_WORKER_ADDR` in `.node-meta`), because that is the port peers dial; a different port is refused unless a NAT or port forward maps the external port to it and you allow the mismatch (`--allow-port-mismatch` or `TN_ALLOW_PORT_MISMATCH=1`; the Node Manager asks you to confirm it).
With `--json`, `verbosity` takes at most `-vvv`.

Each node flag is checked against the installed release before anything changes.
Every edit takes the update lock, so it is refused while another script holds it, such as `update-node.sh` applying an update: `an update is in progress (PID N); try again when it has finished`.
Before every restart or stop it runs the committee quorum check (section 4.11); `--allow-quorum-risk` overrides a refusal.
Before it restarts a node that votes in the current committee, `edit-config.sh` waits for the epoch boundary the way `update-node.sh` does (section 4.2); `--no-epoch-wait` or `TN_SKIP_EPOCH_WAIT=1` skips the wait, passphrase moves included, and a rollback restart never waits.
The edit is written before that wait.
If the run is stopped before the restart is issued (Ctrl-C, SIGTERM or SIGHUP, or a Node Manager tab that is closed), it puts back every file it changed: `Stopped by SIGINT before the restart, so the edit was rolled back: every file it changed is as it was before this run.`
Once the restart has been issued, the edit stays.
On a host with the host baseline (section 4.13), the AIDE baseline is made again after a `--set` restart came back healthy, after a menu edit's restart came back active, after `14) Restart node` came back active (so an edit saved for later is folded in then), and after a passphrase action that went through.
With P2P committee mode on (section 2.10), the same restarts of an edit that changed `node.env`, the bootstrap peers or the trusted nodes, of `13) Refresh chain configs` and of `14) Restart node` also resync the allowlist (`firewall-setup.sh --p2p-committee sync`); a sync that fails is a warning naming that command.

`13) Refresh chain configs` reads `NETWORK` from `.node-meta` and refuses unless the node's genesis and the new one declare the same chain ID.
It copies the network's `genesis.yaml` and `committee.yaml` into `genesis/` and its `parameters.yaml` over the node's, so set `allow_private_forward_targets` again afterwards if you had changed it (item 10).
A refresh stopped during its epoch wait keeps the new files for the next restart.
Before it copies anything it checks the three files against the SHA-256 hashes the script release pins for the network, and stops on a mismatch with `The chain configs in <dir> do not match the <network> pins (see above). Chain configs unchanged.`; mainnet has no pins yet (section 1.5), so a mainnet refresh is refused before any prompt with `This script release pins no mainnet chain configs yet, so there is nothing to install. Chain configs unchanged.`
Without a `NETWORK` line it stops with `Cannot tell which network this node runs: .node-meta has no NETWORK. Chain configs unchanged.`; add `NETWORK=testnet` to `/etc/telcoin/.node-meta` and run it again.
On testnet it puts the files of `v0.16.0-adiri` in `/etc/telcoin/chain-configs/testnet/` the way setup does (section 2.2, step 8) and copies them from there; it never pulls or checks out `/opt/telcoin-source`.
When the node's data directory already holds the pinned files, it changes nothing and does not restart the node: `Nothing to refresh: the node's data dir already holds the testnet chain configs this script release pins (v0.16.0-adiri), so telcoin was not restarted.`
If the node has not been restarted since those files were copied, use `14) Restart node`.
With no checkout and no pinned files in `/etc/telcoin/chain-configs/testnet/`, it offers the clone setup makes, at the tag and without submodules: `Clone the repository at v0.16.0-adiri into /opt/telcoin-source now?`.
If you decline or the clone fails, the chain configs stay as they are, and it prints the clone command (`sudo git clone --branch v0.16.0-adiri https://github.com/Telcoin-Association/telcoin-network.git /opt/telcoin-source`) and the three raw-file URLs of the tag, whose files you can put in `/etc/telcoin/chain-configs/testnet/` (root, 0644) instead.
A pinned directory or checkout the install cannot use is refused before that question, with the warnings section 9 lists; any refusal or failure while the files are read or installed ends `The pinned testnet chain configs (v0.16.0-adiri) were not installed (see above). Chain configs unchanged.` or `... could not be installed (see above). Chain configs unchanged.`
The update lock is free while it asks whether to clone and at every `Press Enter to return to menu...`.
On devnet the refresh still pulls the checkout's default branch.

Two cautions:

- For public RPC, use `install-caddy.sh` (section 5), not the menu's `4) RPC access` item. reth must stay on `127.0.0.1`.
- Change the P2P ports only to fix a conflict. The new ports must be open in every firewall layer and must match the multiaddrs in `node-info.yaml`.

Two flags manage the passphrase credential without the menu:

```bash
sudo bash ~/telcoin-node-scripts/edit-config.sh --migrate-credential
sudo bash ~/telcoin-node-scripts/edit-config.sh --reseal
```

`--migrate-credential` moves the passphrase to the encrypted credential `/etc/telcoin/bls-passphrase.cred`: from the root-only file, from the old TPM sealing, or from a unit that holds it (section 4.8).
It runs the quorum check, writes the credential, the start script and the unit, waits for the epoch boundary, restarts the node, checks that the node unlocked its key, and then shreds every old copy of the passphrase.
If the node does not come back, every file is put back and the node restarts on them.
On mainnet it needs systemd 255.
`--reseal` encrypts the credential again with the host's current TPM and PCR state, for example after a firmware update when the credential was bound with `--bind-pcrs`.
Both take `--allow-no-tpm` and `--bind-pcrs <list>|none` as setup does (section 2.8).
A node whose unit still holds the passphrase, runs the node command inline or uses the old TPM method refuses every other edit until `--migrate-credential` has run.

Before the first write, `--migrate-credential`, `--reseal` and both items of `5) BLS passphrase` check that the passphrase opens the BLS key with `keytool verify`, on node releases whose keytool has that command (telcoin-network #1730; no release has it yet).
The change checks the new passphrase, the reseal the one the credential holds, the move the one it is about to store.
On a release without it the run logs `keytool verify is not in this release; skipped` and goes on as before.
When the release has it and the passphrase does not open the key, nothing is written: `<The new passphrase|The passphrase> does not open the BLS key in <data dir> (keytool verify, exit N); nothing was changed. Use the passphrase the key was created with.`
A verify that cannot start (`keytool verify could not run (exit N); nothing was changed. Fix the cause and try again.`) stops the action too.

### 4.4 Service commands

```bash
sudo systemctl start telcoin
sudo systemctl stop telcoin
sudo systemctl restart telcoin
journalctl -u telcoin -f
sudo tail -f /var/log/telcoin/telcoin.log   # with --log-target file
sudo systemctl reset-failed telcoin   # after too many failed restarts
```

The log files are readable by root and by members of the `telcoin-log` group; on a node set up with `--log-target journal` (the mainnet default) the output is only in the journal.

The README has the full [command reference](README.md#quick-reference--common-commands).

### 4.5 Node Manager UI

The optional web UI shows health, logs and configuration, and can run updates.
Install it on the node:

```bash
sudo bash ~/telcoin-node-scripts/ui/install-ui.sh
```

It listens on `127.0.0.1:8080` only and answers only requests that carry its access token (`/etc/telcoin-ui/token`; `sudo bash ~/telcoin-node-scripts/ui/install-ui.sh --rotate-token` replaces it and closes every open session).
Reach it from your own machine through an SSH tunnel, either with the helper script from a local copy of this repo or by hand:

```bash
./open-ui.sh user@SERVER_IP
ssh -L 127.0.0.1:8080:127.0.0.1:8080 user@SERVER_IP   # then open http://127.0.0.1:8080/#t=<token>
```

`open-ui.sh` reads the token over SSH (`sudo cat /etc/telcoin-ui/token`), opens the tunnel and opens `http://127.0.0.1:8080/#t=<token>` in your browser.
The token travels in the URL fragment, which the browser never sends to the server.
Use `127.0.0.1`, not `localhost`, which can resolve to `::1` and reach another listener.

To reach the dashboard on a public HTTPS name, run `sudo bash ~/telcoin-node-scripts/install-caddy.sh` and choose `[1] Dashboard`; Caddy then serves it behind a login.
Public access is read-only; management stays on the tunnel.
The dashboard needs its own hostname, such as `dashboard.<your-node-domain>`, separate from the public RPC name.
Both names must be DNS names with two or more labels, not IP addresses.
See [Web UI](README.md#web-ui-optional) and [external dashboard access](README.md#external-dashboard-access-optional-via-caddy).

The installer checks everything before it changes anything that is running.
If Flask cannot be installed, a UI source file is missing, the helper does not parse, or `visudo` rejects the new sudo whitelist for the UI's privileged helper, it stops and the running UI, its helper and its whitelist stay as they were.
The whitelist goes in last, so a failure after the helper is replaced leaves the new helper with the old whitelist, which still accepts the old calls; run the installer again.
`update-scripts.sh` does not redeploy the UI: when the UI files change it prints `sudo bash ~/telcoin-node-scripts/ui/install-ui.sh --update`, and the new UI loads only after you run it.
If the UI shows `The privileged helper is outdated.`, the helper is older than the page (this release needs helper API 3), so run that command.

What to expect from the UI:

- The setup wizard can make the node public at install time. Choose Public RPC in the Configure step and give the node's hostname; the field suggests the node's own name, and `Check DNS` tests it. A DNS mismatch is only a warning, because setup checks DNS again and keeps RPC private until the name resolves (section 5.2). The completion card then shows whether public RPC is on and what `node-info.yaml` advertises.
- The validator view follows the chain. The UI asks the network's public RPC for the node's `getValidator` record, then the synced node, then its last saved answer, so a newly staked validator gets the validator view while it is still syncing. A banner says when the view comes from a cached answer, or when the role is unknown and the view defaults to observer.
- The UI also shows Docker containers it did not install as externally deployed nodes, with status and logs only: any running container whose image comes from a repository the scripts recognise for testnet, mainnet or devnet, a dev-team container from `ghcr.io/telcoin-association/tn-dev` among them (remove-node's container scan lists the same ones).
- The wizard installs a signed release, a source build of a release tag, or Docker. The tag field starts at the latest release tag; the Docker field takes a release tag or an image digest and refuses `latest`. The Docker field's default is the image the scripts pick as the newest (section 2.3), never a release candidate; it takes images from both testnet repositories, and a release candidate tag you type on testnet. Testnet defaults to the source build. The Mainnet card stays disabled until the mainnet release.
- The wizard's preflight step judges the hardware against the table of the wizard's network in section 1.1, as setup's check does, and only warns. It comes before the Network step, so it uses the testnet table until you pick another network and go back to it. When the server cannot count physical cores, it shows `Detected 8 logical CPUs / ...` (for an 8-thread host) and a note on logical CPUs like the one setup prints.
- The Config tab has no fields for bootstrap peers, state export or private forward targets yet; set those with `edit-config.sh` (section 4.3).
- The Config tab can move an older install's passphrase to the encrypted credential (`Migrate to an encrypted credential`, the same as `edit-config.sh --migrate-credential`) and re-seal an existing one (`Re-seal the passphrase credential`, `--reseal`). Both run the quorum check and the epoch wait before they restart a running node.
- The System tab shows the Host Security Audit (`check-node.sh --audit`). When the firewall is off, its card asks for the SSH sources (addresses or CIDRs, /8 or narrower, at most 16) and enables the firewall with them as `--ssh-from`; on mainnet an empty list is refused with `firewall-setup.sh`'s own message. Use `firewall-setup.sh` for `--p2p-from` or `--ssh-anywhere`.
- Before public RPC is enabled, the page shows the same exposure summary `install-caddy.sh` prints and waits for you to confirm.
- The update panel reports a refused downgrade, a node that is not voting after an update, and a release tag that now points at another commit.
- When the engine copy under `/opt/telcoin-ui-update` is older than the helper needs, an action stops with a message to run `update-scripts.sh` and then `install-ui.sh --update`.
- The UI installs and updates releases with its own copy of the scripts and of the release keys in `/opt/telcoin-ui-update/lib/release-keys/`. A key that arrives with `update-scripts.sh` (a new maintainer, or a renewed expiry date) reaches the UI only after `install-ui.sh --update`, like every other script file.
- Updates and config saves run the same scripts, so they wait for the epoch boundary too (section 4.2): a progress pane can show `Waiting for epoch N to close` for up to 30 minutes, with a line every 15 seconds. Keep the tab open until the result line appears. Leaving the tab during the wait cancels the update before the node is stopped, and the prepared update stays for a later apply; leaving it once the apply has started can cut the apply off part way. A config save cut off before its restart puts the old settings back (section 4.3).
- A one-way update across `v0.16.0-adiri` (section 4.2) shows its warning in the progress pane when you prepare it; the next release's one-way step does not yet. Apply does not ask about a snapshot, so take it before you press Apply, and expect the health check to take up to 10 minutes after the restart. A discard after a one-way apply that was cut off once the new release had started keeps the unit, start script and `node.env` as that apply wrote them.
- Snapshot the data dir before you update a node to `v0.17.0-adiri` from the UI: its Apply runs `update-node.sh --json`, which does not ask about the snapshot. The update is one-way, and a failed check does not roll back (section 4.2).

### 4.6 Testnet add-ons

The health monitor, log shipping, metrics shipping and VPN admin SSH can be turned on after setup:

```bash
sudo bash ~/telcoin-node-scripts/setup-observability.sh   # health, logs, metrics
sudo bash ~/telcoin-node-scripts/setup-vpn.sh             # VPN admin SSH
```

Read [docs/testnet-addons.md](docs/testnet-addons.md) for what each one shares and how to turn it off, and [WGVPN.md](WGVPN.md) before enrolling in the VPN.

The add-ons are for testnet and devnet only: on mainnet every one of them is refused, and a mainnet setup refuses to start while any add-on is installed.
For alerts that reach you, on every network, see section 4.14.

Turning on the health monitor, log shipping or metrics shipping adds flags to the node command (`--healthcheck`, `--log.file.format json`, `--metrics`) and restarts the node.
The health monitor adds `--healthcheck 43174`, a bare port.
`v0.16.0-adiri` binds it on every interface, so the `ufw` rule that admits only the Association monitor (section 2.6) is its only protection.
From the next release a bare port binds `127.0.0.1` only: the probes the scripts and the Node Manager UI run on the host still reach it, but the Association monitor and any monitoring host you added cannot, whatever `ufw` allows.
A node monitored from outside then needs the flag with an address: `--healthcheck 0.0.0.0:43174` for every interface (keep the `ufw` rule; the node logs a warning that begins `listener bound on every interface`), or `--healthcheck <address>:43174` with an address the host owns (on a cloud VM whose public IP maps to a private interface address, that private address).
`v0.16.0-adiri` does not accept the address form, so match the form to the release.
From the next release a health bind that fails, such as a port in use or an address the host does not own, stops the node at start-up.
Log shipping makes the node write JSON logs under `/var/log/telcoin/node/` (section 2.4).
`setup-observability.sh` holds the update lock for the whole menu session.
Before the restart it runs the committee quorum check (section 4.11); `TN_ALLOW_QUORUM_RISK=1` overrides a refusal.
On a committee node that restart waits for the epoch boundary (section 4.2); `TN_SKIP_EPOCH_WAIT=1` skips the wait.
If a flag cannot be added, for example because the node command ends in a `#` comment, the enable fails without restarting the node, names the flags to add by hand, and does not record the add-on as on.
Add the flags and run it again.

Log and metrics shipping authenticate to the Association hub with one ingest token, kept in `/etc/telcoin/alloy/ingest-token` (root:telcoin-alloy 0640), which Alloy reads as a file over TLS 1.3 to the hub's host name.
To replace it, pipe the new token in; Alloy restarts and the node does not:

```bash
printf '%s\n' "$NEW_TOKEN" | sudo bash ~/telcoin-node-scripts/setup-observability.sh --rotate-token --token-stdin
```

Without `--token-stdin` on a terminal it asks for the token, hidden; the menu has the same action as `8) Rotate the ingest token (Alloy restarts, the node does not)`.
If Alloy does not stay running on the new token, the old files go back and Alloy restarts on them.
A wrong token keeps Alloy running while the hub refuses every push, so check the counters the success message names a minute later.
A node set up before this release keeps the token in `/etc/telcoin/alloy/telcoin-alloy.env` until the next enable, partial disable or rotation; the status screen and `check-node.sh` warn about it, and `--rotate-token` with the same token moves it now.
Turning both pipelines off shreds the token file, so turning either on again asks for the token.
See [docs/testnet-addons.md](docs/testnet-addons.md#the-ingest-token-file) for the details.

### 4.7 Remove a node

If the node serves public RPC, turn that off first, because `remove-node.sh` does not touch Caddy:

```bash
sudo bash ~/telcoin-node-scripts/install-caddy.sh --phase=rpc-disable
sudo bash ~/telcoin-node-scripts/remove-node.sh
```

After `Proceed with node removal?` the removal script takes the update lock, so it refuses while another script holds it.
It removes the service and its Docker container, then asks before each of: Docker image, chain data, keys, binary, source tree, logs, service user, and the UI.
Deleting the keys needs you to type `DELETE`.
Do not delete the keys of a staked validator unless you hold a tested backup.

Secrets are overwritten with `shred` before they are deleted: the passphrase credential and file, the keys when you delete them, and the backups in `/var/backups/telcoin`, which can hold unit and passphrase copies.
Overwriting is best effort on SSDs, copy-on-write and cloud disks, and the script says so: `Decommissioning a host that held a validator key means destroying or crypto-erasing its disk and deleting every snapshot and image taken from it; shred alone does not do that.` (section 4.12).
It shreds the Alloy ingest token file with the add-ons.
It removes private alerts (section 4.14) first, before the node stops, so the removal sends your monitor no down heartbeat; after that the monitor gets none at all, so pause or delete it, as the script reminds you: `Pause or delete this node's monitor: a push monitor alerts on silence.`
It removes a worker gateway (section 4.15) before the node stops too, and keeps the gateway's image and its Caddy site, naming the command that removes each.
With the last node unit on the host it also removes the host baseline (section 4.13) and the P2P new-flow limit (`telcoin-p2p-limit.service`, `/etc/telcoin/p2p-limit.nft` and the nftables table); while another node unit remains, both stay whole for that node, and the run says so.
With the last node it also removes the P2P committee allowlist (section 2.10) without running `firewall-setup.sh` or the tool: the timer first, the sync service and the boot unit with their unit files, the nftables table `inet tn_p2p_allow`, `/usr/local/libexec/telcoin/tn-p2p-allow-sync` and last `/var/lib/telcoin-p2p-allow`, which stays when nft refused the delete.
It deletes the table and removes the state dir holding the tool's lock, as `off` does; when a sync holds the lock for 30 seconds, both stay and the run says so: run `remove-node.sh` again once the sync has finished.
It also offers to remove any container that runs a node image from the ghcr.io packages (`tn-mainnet`, `tn-testnet`, `tn-dev` or the old `telcoin-network`), whatever its name.
When no other node install remains, it also removes the host files every install shares: the start scripts in `/usr/local/libexec/telcoin`, `/etc/telcoin/node.env` (and `/etc/telcoin` once it is empty), `/var/backups/telcoin`, the logrotate file, the journald, needrestart and apt drop-ins, `/var/lib/telcoin-staging`, the `tn-build` account with `/var/lib/tn-build` (its processes are stopped first, and a failed `userdel` is reported).
`/run/telcoin` stays until reboot: it holds the update lock.
If you keep the service user, it asks `Also remove the log-reader group 'telcoin-log'?` before it removes that group.

A removal that stopped part way can be finished: run `remove-node.sh` again, and it removes what is left while `/etc/telcoin`, the backups, the data directory, the start scripts, the allowlist's timer unit or its state dir remain.
Menu option `2) Wipe chain data only` keeps the keys and configuration and makes the node resync from scratch.
It leaves private alerts on, so pause the node's monitor for the resync.

### 4.8 Move a unit-started node to the start script

Nodes set up by the earliest versions of these scripts start straight from the systemd unit, and the unit holds the BLS passphrase.
On a Docker node `ExecStart=` runs `docker run ... telcoin node ...` with the passphrase in a `-e` option; on a source or existing-binary node it runs `<binary> node ...`, and an `Environment=` line holds the passphrase.
`edit-config.sh` and `update-node.sh` refuse such a node, and so do nodes still on the old TPM sealing method, with a pointer to the one command that moves them:

```bash
sudo bash ~/telcoin-node-scripts/edit-config.sh --migrate-credential
```

It reads the passphrase from the unit (it asks for it when the unit holds it in a form that cannot be read back as one plain value), stores it as the encrypted credential (on a testnet host below systemd 250, as the root-only file), writes `/etc/telcoin/node.env` from the unit's listener lines, the start script from the node command and a new unit, and restarts the node the way section 4.3 describes.
It drops a leftover `--observer` or `--validator` from the command.
Every old copy of the passphrase, unit backups included, is shredded once the node is back.
A node command it cannot read is refused, with the steps to move the unit by hand.
On a legacy role-named install (section 8), run it before `migrate-node-naming.sh`.

### 4.9 Migrating an existing testnet install

A testnet node installed by scripts older than `scripts-v2.0.0` has the old layout: the service user owns `/etc/telcoin`, the install directory and the logs, the start script sits in `/opt/telcoin`, and the passphrase sits in a plaintext file.
Move it in this order:

1. Update the scripts once: `bash ~/telcoin-node-scripts/update-scripts.sh`. The old updater installs the current `update-scripts.sh` through the unsigned checksum channel; that is the last unsigned update, and the new updater takes the release keys once through their published checksums (section 4.1). From then on every update is a signed manifest. If the updater stops with `... has no MANIFEST.sig; nothing was changed.`, run the installer once instead (section 4.1).
2. Run any of `update-node.sh`, `edit-config.sh`, `install-caddy.sh` or `prepare-stake.sh` with `sudo`. The first such run takes the update lock and moves the host to the root-owned layout: the install and config directories become `root:root` 0755 with every file in them root-owned, `/var/log/telcoin` becomes `root:telcoin-log` 0750, and the start script moves to `/usr/local/libexec/telcoin/tn-start` (`tn-start-docker` on Docker); JSON logs the node wrote into `/var/log/telcoin` move to `/var/log/telcoin/node` and the unit is rewritten so the node can reach them. It prints what it changed, records `OWNERSHIP_LAYOUT=2` in `.node-meta`, and never restarts the node: the moved start script takes effect at the next restart. It stops, with the list, at a symlink, a special file, a file with other hard links or an owner other than root and the service user. It also warns that the node binary was writable by the service user; reinstall it from a release with the next `update-node.sh`.
3. At a time you choose, move the passphrase to the encrypted credential: `sudo bash ~/telcoin-node-scripts/edit-config.sh --migrate-credential` (section 4.3). The restart waits for the epoch window; a unit that holds the passphrase moves the same way (section 4.8). It needs systemd 250; below that, the node keeps the root-only file.
4. If the Node Manager UI is installed, run `sudo bash ~/telcoin-node-scripts/ui/install-ui.sh --update`, then reopen it from your own machine with the new `open-ui.sh` (section 4.5).
5. On a Docker install, take the new start script and unit with `sudo bash ~/telcoin-node-scripts/update-node.sh`: its apply writes both again (section 4.2).

A mainnet host is never migrated in place.
On the old layout every one of these scripts refuses it with `... must be installed fresh; it is not migrated in place. Nothing was changed.`
Install mainnet fresh on Ubuntu 26.04 (or 24.04), from a verified `scripts-v*` release (section 2.1) and a verified node release (section 4.10).

### 4.10 Verifying a release by hand

The scripts check every release they install.
To check one yourself, for an `existing` install or before you trust a download, use the same keys.
Node releases, script releases and the `tn-p2p-allow-sync` release that P2P committee mode installs (section 2.10) are signed by the same release keys, the `lib/release-keys/*.asc` of your installed scripts.
A release key that is rotated or revoked must change in `lib/release-keys` too: a script release does that, and your host takes it with `update-scripts.sh` (section 4.1).
Work in an empty directory and make the keyring from them once; both checks below use it:

```bash
for f in ~/telcoin-node-scripts/lib/release-keys/*.asc; do gpg --dearmor < "$f"; done > release-keys.gpg
```

In both checks `gpgv` must print a `GOODSIG` line, with its `VALIDSIG` ending in the primary fingerprint of a shipped key, and no `BADSIG`, `EXPSIG`, `EXPKEYSIG`, `REVKEYSIG` or `ERRSIG` line. Read those status lines, not its `Good signature from` message or its exit status: it prints that message, and exits 0, for a revoked or expired key too.

A node release lives at `https://github.com/Telcoin-Association/telcoin-network/releases/download/<tag>/`.
Its `SHA256SUMS` lists five files: `IMAGE_DIGEST`, the tarball `telcoin-network-<tag>-x86_64-unknown-linux-gnu.tar.gz`, and the chain configs `chain-configs/<dir>/committee.yaml`, `genesis.yaml` and `parameters.yaml` (`<dir>` is `testnet` for `-adiri` tags and `mainnet` for mainnet tags).
`SHA256SUMS.asc` is a detached GPG signature by a release key; the public keys ship with the scripts in `lib/release-keys/*.asc`. This script release ships two, `grantkee.asc` (primary key `95A38484E1CBD31D773F6AF928FD56AD2F9FAE47`, expires 2028-11-16) and `MavenRain.asc` (primary key `32F886ADE9C3A88218E4B67CA0A69159FC76DBFD`, expires 2028-11-10), copies of the maintainer keys in `Telcoin-Association/tn-release-signing`; `update-scripts.sh` brings later keys and refreshed expiry dates. The RSA key `4E36D35A4AB61B589861D01AC7173F2377CA7573` that `scripts-v2.1.0` shipped is retired and verifies nothing from `scripts-v2.2.0` on. `v0.16.0-adiri` and older have no release page, and the first signed node release is planned as `v0.17.0-adiri`, so use the tag of a published release in the commands below.

```bash
TAG=vX.Y.Z-adiri   # a published release tag
base=https://github.com/Telcoin-Association/telcoin-network/releases/download/$TAG
curl -fsSL -O "$base/SHA256SUMS" -O "$base/SHA256SUMS.asc" -O "$base/IMAGE_DIGEST" \
  -O "$base/telcoin-network-$TAG-x86_64-unknown-linux-gnu.tar.gz"
gpgv --status-fd 1 --keyring ./release-keys.gpg SHA256SUMS.asc SHA256SUMS
git clone --quiet https://github.com/Telcoin-Association/telcoin-network.git tn-main
git -C tn-main archive "refs/tags/$TAG" chain-configs | tar -xf -
sha256sum --check --ignore-missing SHA256SUMS
tar -xzf telcoin-network-$TAG-x86_64-unknown-linux-gnu.tar.gz
telcoin-network-$TAG-x86_64-unknown-linux-gnu/telcoin-network --version
git -C tn-main rev-parse "refs/tags/$TAG^{commit}"
```

`gpgv` must print the status lines above. The scripts refuse a release when any line reports `BADSIG` (by any key), `EXPKEYSIG`, `REVKEYSIG` or `EXPSIG`, or any `ERRSIG` other than code 9 (a key the scripts do not ship), or when no shipped key signed it. A further signature by a key that is not shipped (`NO_PUBKEY`, or `ERRSIG` for a missing key) only draws a warning that names its key id: the release pipeline publishes only allowlisted signatures, so that is a maintainer key that a later script release ships. Run `update-scripts.sh` to take it.
`sha256sum` must print `OK` for all five names: the `git archive` line puts the tagged chain configs at the paths `SHA256SUMS` names, and without it `--ignore-missing` skips them silently.
The scripts compare those three lines with the hashes they pin for the network as well.
The tarball holds `telcoin-network`, `LICENSE-APACHE`, `LICENSE-MIT` and `NOTICE` and nothing else.
`--version` must print `telcoin-network-cli Version: X.Y.Z`, the tag's version (a release candidate's binary reports `X.Y.Z` too, without `-rcN`), a `Commit SHA:` equal to the commit the last line of the block prints, and `Build Features:` `adiri` (possibly with `faucet`) on an `-adiri` tag, empty on a mainnet tag.
Run `--version` as an unprivileged user, never as root.
For a Docker install, `IMAGE_DIGEST` is one line that names the image by digest in the network's package, `ghcr.io/telcoin-association/tn-mainnet@sha256:<digest>` on mainnet or `ghcr.io/telcoin-association/tn-testnet@sha256:<digest>` on testnet; the scripts refuse a release whose `IMAGE_DIGEST` names another repository. Pull and run it by that digest (`docker pull "$(cat IMAGE_DIGEST)"`), never by a tag. The image's binary is `/usr/local/bin/telcoin`, and its `--version` must print the same three lines. The scripts take the newest image the same way: the digest in the signed `IMAGE_DIGEST` of the newest release, not the registry's answer. When that release cannot be verified (a check fails, or its signed files, gpg or a key file are missing), testnet takes `DEFAULT_DOCKER_IMAGE` with a warning that gives the reason and mainnet stops; the registry's digest is never taken for a release published on GitHub.

A script release is the `scripts-v*` tag of this repository, with `MANIFEST` and `MANIFEST.asc` (detached OpenPGP signatures over `MANIFEST`) at its root.
`scripts-v2.1.0` is the first signed release, signed with the retired RSA key, so the keyring above checks `scripts-v2.2.0` and later.
Check one with it, in the same directory:

```bash
TAG=scripts-v2.2.0
git clone --quiet --branch "$TAG" https://github.com/Telcoin-Association/tn-node-deployment.git tnd-check
gpgv --status-fd 1 --keyring ./release-keys.gpg tnd-check/MANIFEST.asc tnd-check/MANIFEST
(cd tnd-check && grep '^sha256  ' MANIFEST | sed 's/^sha256  //' | sha256sum --check)
grep -E '^(release|serial|date|expires)=' tnd-check/MANIFEST
```

`gpgv` must print the status lines above, a `GOODSIG` and its `VALIDSIG` for a shipped key (`95A38484E1CBD31D773F6AF928FD56AD2F9FAE47` or `32F886ADE9C3A88218E4B67CA0A69159FC76DBFD` today), and every file must print `OK`.
The last line shows which release it is, its release date and its expiry date.
The scripts take a script release on the same status rules as a node release, and need good signatures by at least one release key (`TN_SIG_THRESHOLD`).
On a host without an installed copy, make the keyring from the keys the installer carries, its trust root, and check their fingerprints against the ones above:

```bash
curl --proto '=https' --tlsv1.2 -fsSL https://install.telcoin.network \
  | sed -n "/<<'TN_RELEASE_KEYS'/,/^TN_RELEASE_KEYS\$/p" | sed '1d;$d' > installer-keys.asc
gpg --show-keys --with-fingerprint installer-keys.asc
gpg --dearmor < installer-keys.asc > release-keys.gpg
```

### 4.11 The committee quorum check

Stopping a committee node while too many other members are already down halts consensus.
Before a script stops or restarts the node, it counts the committee members that are down: n is the committee size, f is (n - 1) / 3 rounded down, and consensus halts once f + 1 members are down.
A member counts as down when it authored no header in the most recent consensus commit, so a slow member counts as down too.
The node itself adds one when it stops, also when its own mode cannot be read, unless `tn_info` on the node itself returns an authority id that authored nothing in that commit (then it is already among the down).
`tn_info` is asked only of the node, never of the public RPC.
The check reads the committee and the most recent commit from the node, else from the network's public RPC.

- A node that is readable and not voting (`tn_nodeMode` other than `CvvActive`) passes: stopping it does not change the quorum.
- When stopping it would make f + 1 down, the run is refused with `committee of <n>: <d> member(s) down; stopping this node makes <d+1> of the <f+1> that halt consensus. Refused: ...` and nothing is changed.
- When the count cannot be made (no committee, no commit, a commit older than 120 seconds or from another epoch), testnet and devnet warn and go ahead. A mainnet node goes ahead only when the registry reports its `VALIDATOR_ADDRESS` as not staked; a staked or voting mainnet node, a mainnet node with no `VALIDATOR_ADDRESS` in `.node-meta`, and a node of an unknown network are refused.

The check runs in `update-node.sh` (before it stops the node), `edit-config.sh` (before every restart or stop), `migrate-node-naming.sh` (before it stops the legacy node), `setup-node.sh` (when a re-run restarts a running node), `install-caddy.sh` and the observability add-on (before they restart the node), and `edit-config.sh --migrate-credential`.
For a restart the fleet coordinator has planned, override a refusal with `--allow-quorum-risk` on `update-node.sh`, `edit-config.sh`, `migrate-node-naming.sh` and `setup-node.sh`, or with `TN_ALLOW_QUORUM_RISK=1` for any of them, `install-caddy.sh` and `setup-observability.sh` included, for example `sudo TN_ALLOW_QUORUM_RISK=1 bash ~/telcoin-node-scripts/install-caddy.sh --phase=rpc-disable`.
The override turns the refusal into a warning; it does not skip the epoch wait.

### 4.12 The validator key: backup, restore, rotation, decommissioning

These files hold the validator key:

| What | Where | Notes |
|---|---|---|
| The keys | `<data dir>/node-keys/` (default `/var/lib/telcoin`, `DATA_DIR` in `.node-meta`), owned by the service user | The BLS key is wrapped by the passphrase as `node-keys/bls.kw`. `check-node.sh` fails on a cleartext `bls.key` without `bls.kw`. |
| The node record | `<data dir>/node-info.yaml` | Names the keys, the execution address and the proof of possession. |
| The passphrase | `/etc/telcoin/bls-passphrase.cred` (`PASSPHRASE_METHOD=credential`), or the root 0600 file `/etc/telcoin/bls-passphrase` (`PASSPHRASE_METHOD=stdin`, testnet and devnet below systemd 250 only) | The `.cred` is sealed to the host that wrote it (its systemd host key, plus the TPM with `CREDENTIAL_KEY=host+tpm2`), so it is not a backup. |
| Copies the scripts made | `/var/backups/telcoin` (root only) | Shredded after a passphrase move. |

`.node-meta` records the install; the key does not need it.
`bls.kw` together with the passphrase is the key in the clear.

Backup.
Setup prints `BACK UP YOUR KEYS NOW.` after key generation; section 2.5 has the commands.
Back up `node-keys/` and `node-info.yaml`, and keep the passphrase itself offline and apart from them.
A backup must not sit on the node's own disk, or in a snapshot or image of it.
No script makes the backup for you.

Snapshots count as copies.
A disk snapshot or machine image of a node holds `node-keys/`, `node-info.yaml` and the `.cred` (or the plaintext file).
With `CREDENTIAL_KEY=host` (a host without a usable TPM: testnet and devnet, or mainnet with `--allow-no-tpm`) the systemd host key that decrypts the `.cred` (`/var/lib/systemd/credential.secret`) is on the same disk, so the snapshot alone can start the validator elsewhere.
Treat every snapshot and image as a copy of the key: the restore rule below applies to it, and decommissioning deletes it.

Restore, only after the old host is gone and cannot start again.
Two hosts that run one BLS key sign conflicting votes, and no script detects a second copy.
On the new host, with the scripts installed (section 2.1) and the archive from section 2.5 copied into your home directory there (`scp telcoin-keys.tgz user@NEW_SERVER_IP:`):

1. Create the service account and the data directory, and unpack the backup into it as that account:

   ```bash
   sudo groupadd --system telcoin
   sudo useradd --system --no-create-home --shell /bin/false --gid telcoin telcoin
   sudo install -d -o telcoin -g telcoin -m 0700 /var/lib/telcoin
   sudo -u telcoin tar -C /var/lib/telcoin -xzf - < ~/telcoin-keys.tgz
   ```

2. Write the passphrase as the one-line root 0600 file (typed, not echoed):

   ```bash
   sudo install -d -m 0755 /etc/telcoin
   sudo bash -c 'umask 077; IFS= read -rs p; printf "%s\n" "$p" > /etc/telcoin/bls-passphrase'
   ```

3. Run `sudo bash ~/telcoin-node-scripts/setup-node.sh` interactively and answer No to `Overwrite existing keys?`. Setup keeps the keys and, where the host can hold an encrypted credential, moves the file into a new `.cred` sealed on this host. A `--json` setup refuses existing keys (`refusing to overwrite in non-interactive mode`).

Do not copy the old host's `.cred`: setup keeps a `.cred` it finds without decrypting it, and the old one does not open on the new host.
Setup keeps the passphrase without checking it against the key; a check there waits on `keytool verify` (telcoin-network #1730).

Rotation.
The BLS key cannot rotate: a new BLS key is a new validator (new keys, a new ConsensusNFT, a new execution address).
Before you stake, `prepare-stake.sh --rotate-address <0xNEW>` signs the proof of possession for another execution address with the same BLS key (section 6.6).
It is refused once the current address has staked (`Refused: <addr> has staked (<status>). Its BLS key is registered to it on-chain and cannot move to another address.`) or is retired, and when the new address has staked or is retired.
`edit-config.sh`, item `5) BLS passphrase`, changes only the stored passphrase; it never re-encrypts the key, so the new value must be the one the key was made with.
On node releases with `keytool verify` (telcoin-network #1730) it refuses a passphrase that does not open the key (section 4.3).

Decommissioning.
`remove-node.sh` shreds `node-keys/` when you delete the keys, the `.cred` and plaintext file, `.node-meta` and `/var/backups/telcoin`, and says that shred is best effort and is not decommissioning.
A host that held a validator key is decommissioned when its disk is destroyed or crypto-erased and every snapshot and image taken from it is deleted.
Leaving the validator set is separate and done from the execution wallet: `beginExit()` while Active, then `unstake(address,bool)` with `false` once the status is Exited and one epoch has passed (section 6.11; `check-node.sh --address` says when `unstake` is eligible).
`unstake` retires the address and burns its NFT.

Lost passphrase.
Without the passphrase `bls.kw` cannot be opened, and the key is lost.
While the host that sealed the `.cred` still decrypts it, root can read the passphrase back there, to a private terminal:

```bash
sudo systemd-creds decrypt --name=bls-passphrase /etc/telcoin/bls-passphrase.cred -
```

This is the call `edit-config.sh --reseal` makes into a pipe; it prints the passphrase, so run it only on that host and write the value down offline.
Otherwise exit with the execution wallet (`beginExit()`, then `unstake`; neither needs the BLS key) and start again as a new validator: new keys with `setup-node.sh`, and a ConsensusNFT for a new address.
Until a node release has `keytool verify`, nothing checks that a passphrase opens the key before it is stored.

### 4.13 Host baseline (auditd and AIDE)

`--host-baseline` adds two records of the node's files: kernel audit watches, and an AIDE database to check the files against later.
It is off unless you ask for it:

```bash
sudo bash ~/telcoin-node-scripts/setup-node.sh --host-baseline
```

On a host whose node is installed, the flag alone makes the baseline, or makes it again, and changes nothing else.
In a full setup it runs once the node is installed, after public RPC and the testnet add-ons; `--json --phase=finalize --host-baseline` reports `"host_baseline":true|false` in its `done` event.
A failure is a warning (`The host baseline was not made (see above); the node runs without it. Try again with: sudo ./setup-node.sh --host-baseline`), and setup goes on.
A failed or refused run leaves nothing behind: the audit rules are written and loaded only after the AIDE prerequisites pass and are removed again on a later failure, so the host then has no rules, no AIDE config and no `HOST_BASELINE` marker.

It installs `auditd` and `aide` with `apt-get install --no-install-recommends` (so no daily whole-system AIDE timer and no mail packages come with them) and writes:

| File | What |
|---|---|
| `/etc/audit/rules.d/telcoin-node.rules` (root 0640) | Watches on `<data dir>/node-keys` (reads included, key `telcoin-keys`), `/etc/telcoin` (`telcoin-config`) and the node unit (`telcoin-unit`), loaded with `augenrules --load`. |
| `/etc/aide/telcoin-node.conf` (root 0600) | The node's own AIDE config: `/opt/telcoin`, `/usr/local/libexec/telcoin`, `/etc/telcoin`, the unit, and the node binary when it lives elsewhere. It leaves out the passphrase file and credential, `alloy/ingest-token` and the scripts' temp files. It is not in `/etc/aide/aide.conf.d`, so a system-wide AIDE setup never reads it. |
| `/var/lib/aide/telcoin-node.db` (root 0600) | The baseline database. |

`.node-meta` records `HOST_BASELINE=true`.
It refuses with a warning, and records no marker, on a host without apt-get, without a node unit, or whose unit still holds the passphrase (`sudo ./edit-config.sh --migrate-credential` first), and when `/var/lib/aide` belongs to another account (aide-common makes it `_aide:root`): give it to root (`sudo chown root:root /var/lib/aide`) or purge aide-common, then run it again.

Look at the records:

```bash
sudo ausearch -k telcoin-keys
sudo aide --config=/etc/aide/telcoin-node.conf --check
```

`aide --check` exits 0 when nothing changed and 1 to 7 when it lists differences.
Nothing runs it on a schedule; run it yourself, or from your own monitoring.

The scripts' own changes do not show up as differences: these runs make the baseline again after a change that went through, and only warn when that fails:

- `update-node.sh`, after each verified apply;
- `edit-config.sh`, after a restart that came back healthy (`--set`, a menu edit, `14) Restart node`) and after a passphrase action that went through;
- `install-caddy.sh`, after public RPC is turned on or off (the dashboard writes nothing the baseline covers);
- `firewall-setup.sh`, after the recommended defaults are applied, after `Manage node ports` opens the P2P ports, and after a health-port source is added or removed;
- `setup-vpn.sh`, after an enable, a key sync that grants or revokes maintainer root, and a disable;
- `setup-observability.sh`, after each change that went through, a token rotation included.

A refused or failed run does not refresh.
The report of `setup-node.sh --audit` and `check-node.sh --audit` (section 1.2) shows the state; `make it again: sudo ./setup-node.sh --host-baseline` in a warning is the fix.
`remove-node.sh` removes the rules (and unloads them), the AIDE config, both databases and the marker with the last node unit on the host; while another node unit remains it keeps them and says so. The kept rules and AIDE config still name the removed unit and its data directory, so after removing one node of two run `sudo ./setup-node.sh --host-baseline` again to make a baseline of what is left.
The packages stay (`sudo apt-get purge auditd aide` removes them).

### 4.14 Private alerts

`setup-alerts.sh` puts a heartbeat on the node host.
A systemd timer runs a small checker every 60 seconds, and each run pushes the node's status, up or down with a reason, to a monitor you own: an Uptime Kuma push monitor, a healthchecks.io check or a JSON webhook.
The monitor alerts you when a heartbeat says down, and also when the heartbeats stop, so a host that crashed or lost its network shows up too.

Private alerts work on every network, mainnet included.
They are not one of the testnet add-ons of section 4.6: the Telcoin Association is not involved and receives nothing.
No inbound port opens; the heartbeat leaves the host over HTTPS to the monitor you name (section 1.3).

What each run checks.
The runner checks the node from the host, in this order, and the first check that finds the node down gives the reason:

| Check | Down when | Reason the monitor gets | Default threshold |
|---|---|---|---|
| Service | The node unit does not exist | `service telcoin not found` | At once |
| Service | The unit restarted after a failure since the last run | `service telcoin restarted after a failure (NRestarts N)` | One run; the next run is up again when all else is fine |
| Service | The unit is stopped or failed, or systemd is waiting to restart it | `service telcoin inactive (dead)` (or `failed`, `auto-restart`) | At once |
| Service | The unit is still starting or stopping | `service telcoin activating for Ns` (or `deactivating`) | 120 seconds in that state |
| Local RPC | `eth_chainId` on the node's own RPC gets no answer, or no chain ID | `rpc 127.0.0.1:8545 not answering (refused)` (or `timeout`, `dns`, `http NNN`, `malformed`, `curl N`) | 120 seconds after the unit started; at once on a node that has been up longer |
| Chain | The RPC reports another chain than the node's network | `wrong chain: rpc reports N, expected M` | At once |
| Consensus | The latest consensus header has not moved, or none has been read | `consensus stalled at header N for Ns` (or `consensus header unreadable for Ns` when no header was ever read) | 180 seconds, or three intervals when that is longer (`--stall-after`) |
| Committee | The node holds a committee seat but does not vote (`CvvInactive`) | `CvvInactive for Ns: committee member not voting` | 900 seconds, or the stall threshold when that is longer (`--inactive-after`) |
| Health | The node's health endpoint answers 503 | `health 503: node reports the network unreachable` | At once |

`telcoin` in these reasons is the node's service name, and `127.0.0.1:8545` the address of its RPC.
When the RPC does not answer, the checks below it are skipped.
The consensus check is skipped on a node release without `tn_latestConsensusHeader`, and the health check on a node that serves no health endpoint (section 4.6); a health answer other than 200 or 503 only adds `(health <code>)` to an up reason, and one that times out `(health timeout)`.
A node that is up reports its mode, block and epoch, such as `CvvActive block 1234567 epoch 42` (a part the node does not report is left out, and `rpc answering` stands in when none is known).
In the first 120 seconds after the unit starts, a run reports up with `service telcoin restarting (activating, 30s)` or `starting: rpc not answering yet`.

What leaves the host.
A heartbeat carries the status, the reason (which names the node mode, block and epoch), and, in a webhook, this host's label (`--label`, by default the host name), the network, the time of the run and whether the status changed.
A Kuma push also carries the local RPC's response time in milliseconds.
Nothing else is sent: no key, no execution address, no log line.
The monitor also sees the request itself: the host's IP address and the user agent `tn-heartbeat/<version>`.

A monitor URL holds the token that lets anyone push to that monitor, so the scripts treat it as a secret.
The URLs stay in `/etc/telcoin/alerts/targets` (root 0600), reach the runner as a systemd credential, and never go on a command line the scripts run (only your own `--target` puts one there, and it warns) or into the journal, the state file, `.node-meta` or a JSON event.
Wherever the scripts name a target, they show its provider and host only, as `kuma@kuma.example.org`.

Targets.
You can give up to five; each run pushes to every one, in the order given.

| Provider | URL to give | What each run sends |
|---|---|---|
| `kuma` (Uptime Kuma) | In Uptime Kuma, add a monitor of type Push and paste the push URL from the monitor's page, such as `https://kuma.example.org/api/push/AbC123xyz?status=up&msg=OK&ping=`. The part from `?` on is dropped, so the stored URL is `https://kuma.example.org/api/push/AbC123xyz`. | A GET with `status=up` or `status=down`, `msg=<reason>` and, when the RPC answered, `ping=<milliseconds>`. |
| `healthchecks` (healthchecks.io) | The check's ping URL, such as `https://hc-ping.com/<uuid>`. A trailing `/fail`, `/start` or `/log` is dropped; a query string or a fragment (`?` or `#`) is refused. | A POST to the URL when up and to `<url>/fail` when down, with the body `up: <reason>` or `down: <reason>`. |
| `webhook` | Any HTTPS URL that takes a JSON POST, such as `https://hooks.example.net/telcoin/node-1`. It is used as given. | A POST with the JSON body below. |

The webhook body has exactly these keys, in this order:

```json
{"status":"up","reason":"CvvActive block 1234567 epoch 42","node":"node-1","network":"testnet","mode":"CvvActive","block":1234567,"epoch":42,"ts":1762257600,"changed":false}
```

`node` is the label and `ts` the time of the run in seconds since 1970 (UTC).
`changed` is `true` when the status differs from the previous run's, and on the first run.
`block` and `epoch` are `null`, and `mode` is `unknown`, when the node does not report them.

A URL must start with `https://`.
`http://` is taken for `127.0.0.1`, `[::1]` and `localhost`, and elsewhere only with `--allow-http`, because the token then travels in clear text.
A URL holds no quote, backslash or space, and is at most 512 characters.
Redirects are not followed, so give the final URL.
A push counts as accepted on a 2xx answer; from Kuma, the answer must not say `"ok":false` either.

Enable.
Open the menu:

```bash
sudo bash ~/telcoin-node-scripts/setup-alerts.sh
```

```
1) Status
2) Enable private alerts
3) Change targets
4) Send a test heartbeat now
5) Refresh after a script update
6) Disable private alerts
7) Exit
```

`2) Enable private alerts` asks for one target at a time: `Where should the heartbeat go?` with `1) Uptime Kuma push URL`, `2) healthchecks.io ping URL` and `3) JSON webhook`, then `Provider [1-3]:` and `URL (input hidden):`.
It checks the URL, says why when it refuses one and asks again, shows the target back as `kind@host` only, and asks `Add another? [y/N]`, up to five.
An empty URL stops the questions.
Then it asks `Interval in seconds [60]:`.

From a script, pipe the targets in, one `<provider> <url>` per line:

```bash
printf 'kuma https://kuma.example.org/api/push/AbC123xyz\n' | sudo bash ~/telcoin-node-scripts/setup-alerts.sh --json --enable --targets-stdin
```

`TN_ALERT_TARGETS`, with the same lines, works too, and so does `--target kuma=<url>` (repeat it per target), which warns: `--target puts the URL on the command line, where other local users can read it while this runs; pipe it in with --targets-stdin instead.`
Give the targets from one source only.

Before it writes anything, an enable checks that it runs as root, that the node is installed (`.node-meta` and the node unit), that systemd is 247 or later (for `LoadCredential=`), and that the node command has `--http`, without which it says `The node command has no --http, so the runner cannot read the local RPC; add it with edit-config.sh and run this again. Nothing was changed.`
Then it writes the files below and sends a test heartbeat.
Only when at least one target accepts it does it start the timer and record `ENABLE_ALERTS=true` in `.node-meta`.
Otherwise it removes what it wrote, leaves `.node-meta` as it was and says `No target accepted the test heartbeat; private alerts were not enabled. Check the URLs and run this again.`

The menu asks only the interval, 30 to 3600 seconds, and sets the stall threshold to three intervals (at least 180 seconds) and the inactive threshold to 900 seconds (at least the stall threshold).
A run with `--enable` (with or without `--json`) takes `--interval N` (default 60, 30 to 3600), `--stall-after N` (default the larger of 180 and three intervals; at least the interval plus 30, at most 86400) and `--inactive-after N` (default the larger of 900 and the stall threshold; at least the stall threshold, at most 86400), and `--label X` (letters, digits, `.`, `_` and `-`, starting with a letter or digit, up to 64 characters).
A value out of range is refused, and nothing changes.

During setup.
`setup-node.sh` asks `Set up private alerts once the node is running?` on every network (section 2.2), and a yes records `ENABLE_ALERTS=pending`.
When the node is running at the end of setup, setup runs `setup-alerts.sh --enable`, which asks for the targets.
When it is not, the alerts stay pending, and setup says `The node is not running yet, so private alerts stay pending. Once it runs: sudo bash setup-alerts.sh`.
An enable that does not finish leaves them pending too, and setup names the same command.
A `--json` setup and `TN_ASSUME_YES=true` do not ask; enable the alerts afterwards with the stdin form above.

Set up the monitor.
After an enable, or a run that changes the interval, the script says `Set the monitor's heartbeat interval to about <2 x interval> s with 1-2 retries: a node update or a restart you run yourself shows as a short down.`
With the 60-second default, that is a heartbeat interval of about 120 seconds on the monitor, with one or two retries.

Updates and restarts you run yourself.
A node update (section 4.2), a configuration change that restarts the node (section 4.3), an add-on that restarts it and `systemctl restart telcoin` all stop the node for a moment.
A heartbeat that lands in that moment says down, such as `service telcoin inactive (dead)`; in the first 120 seconds after the start it says up, `service telcoin restarting (activating, ...)` or `starting: rpc not answering yet`.
With the monitor set as above, a planned restart shows as a short down at most.
For longer work, pause the monitor first; no script pauses it for you.

Test.
`4) Send a test heartbeat now` runs the heartbeat once, now, and prints each target's result, such as `Target 1 kuma@kuma.example.org: accepted (200)` or `Target 2 webhook@hooks.example.net: failed (000 timeout)`, and what the node read as.
The same without the menu:

```bash
sudo bash ~/telcoin-node-scripts/setup-alerts.sh --test
```

Add `--json` for a JSON `done` line (section 7.3).
The test exits 0 when a target accepted the heartbeat and 1 otherwise.
When no fresh result appears, it points at `journalctl -u telcoin-heartbeat -n 20`.

Change the targets.
`3) Change targets`, or the stdin form of the enable on a node whose alerts are on, replaces the whole list, so give every target you want to keep.
It sends a test heartbeat, and when no target accepts it, the old list goes back: `No target accepted the test heartbeat; the previous targets were put back.`
An enable without targets on a node whose alerts are on does a refresh.

Refresh after a script update.
When a script update changes the runner or its library on a host with the alerts installed, `update-scripts.sh` prints `The heartbeat runner or its library changed. Reinstall them on the host:` and the command (section 4.1):

```bash
sudo bash ~/telcoin-node-scripts/setup-alerts.sh --refresh
```

A refresh (`5) Refresh after a script update`) reinstalls the runner, writes `alerts.env` and both units again with the interval, thresholds and label already set, and restarts the timer.
Run it too after you change the node's RPC address or port, or its service name; the status reports the difference.
With the alerts off it says `Private alerts are off; nothing to refresh.`

Change the interval, the thresholds or the label.
On a node whose alerts are on, `--interval`, `--stall-after`, `--inactive-after` and `--label` replace the values already set, given with `--refresh` or with `--enable` (with or without targets); there is no need to disable first:

```bash
sudo bash ~/telcoin-node-scripts/setup-alerts.sh --refresh --interval 120
```

A value you leave out keeps the one already set, except that with `--interval` each threshold you leave out follows the new interval as in an enable (360 and 900 seconds for an interval of 120), even one you set before; give it again to keep it.
A threshold you give must fit the ones kept: a `--stall-after` above the inactive threshold already set is refused (`Refused: --inactive-after must be a whole number of seconds from <stall> (the stall time) to 86400. Nothing was changed.`); give `--inactive-after` with it.
The run writes `alerts.env` and both units again and restarts the timer; with `--json`, its `done` line lists `alerts:refreshed` and the new `interval` (section 7.3).
When the same run gives targets, the new values apply only once a target has accepted the test heartbeat, and `alerts:targets-changed` comes first in `applied`.
If the targets changed but the values could not be applied, it exits 3 with `The new targets are in place, but the new settings were not fully applied; run setup-alerts.sh --refresh with the same options again.`
Then set the monitor's heartbeat interval to about twice the new interval.

Disable.
Pause or delete the node's monitor first: a push monitor alerts on silence, so heartbeats that stop look like a dead node.
Then choose `6) Disable private alerts`, or:

```bash
sudo bash ~/telcoin-node-scripts/setup-alerts.sh --disable
```

It stops and removes the timer, the service, the runner and its state, shreds the targets file, removes `alerts.env` and `/etc/telcoin/alerts`, records `ENABLE_ALERTS=false`, and ends with `Pause or delete this node's monitor: a push monitor alerts on silence.`
A disable that cannot remove the targets file exits 3.
`remove-node.sh` removes the alerts the same way, before it stops the node (section 4.7).

The files:

| File | Owner, mode | What |
|---|---|---|
| `/usr/local/libexec/telcoin/tn-heartbeat` | root 0755 | The runner, a copy of `lib/tn-heartbeat.sh`. |
| `/etc/systemd/system/telcoin-heartbeat.service` | root 0644 | Runs the runner once; the timer starts it. |
| `/etc/systemd/system/telcoin-heartbeat.timer` | root 0644 | Starts the service every interval, the first time 120 seconds after boot. |
| `/etc/telcoin/alerts/` | root 0755 | The two files below. |
| `/etc/telcoin/alerts/targets` | root 0600 | One `<provider> <url>` per line, at most five. The only secret. |
| `/etc/telcoin/alerts/alerts.env` | root 0644 | The node's service name and local RPC URL, the network and its chain ID, the label, the health port, the interval and the thresholds. No URL of a monitor. |
| `/var/lib/private/telcoin-heartbeat/state` | the runner's account (on disk `nobody` (65534) with systemd 257 or later), directory 0700 | What the runner remembers between runs: the last status and reason, the consensus header it last saw, and each target's last result. Never a URL. |
| `/run/telcoin/heartbeat-service` | root 0644 | The node service's state (`systemctl show` of `telcoin.service`). The service rewrites it as root before each run, and the runner reads it. Gone after a reboot until the next run. |
| `ENABLE_ALERTS` in `.node-meta` | | `true`, `pending` (asked for during setup, not enabled yet) or `false`. Absent means off. |

The runner runs as an account systemd makes for each run (`DynamicUser=yes`).
It reads the targets through `LoadCredential=`, cannot read the data directory or the passphrase files, holds no capabilities and writes only its state directory.
That directory is the one path the alerts add that root does not own.
Such an account cannot ask systemd for the node's service state, so before each run the service writes that state, as root, to `/run/telcoin/heartbeat-service`; that one step does nothing else.

Enable, change, refresh and disable take the update lock, so each refuses while another script holds it; the test takes it too, and the status takes none and needs no root.
On a host with the host baseline (section 4.13), a change that went through makes the baseline again.
None of them stops or restarts the node, so they run neither the quorum check (section 4.11) nor the epoch wait (section 4.2).

What check-node reports.
`check-node.sh` shows the same status as `1) Status`: `Private alerts: on`, `pending` or `off`, the timer, and, run with `sudo`, the last run (`last run Ns ago: up, CvvActive block ... epoch ...`) and each target as `kind@host` with its last result; without `sudo` it says `last run not checked (run with sudo)` and `alerts.env not compared with the node (run with sudo)`.
Without `sudo` it cannot read `.node-meta` (root 0600) either, so on a host with the timer installed it says `Private alerts: unknown (run with sudo)` and tells whether the alerts are on from `systemctl is-enabled telcoin-heartbeat.timer`.
On a host without private alerts it prints one line, `Private alerts: off (enable them with setup-alerts.sh)`, and counts nothing.
Each of these counts as an issue: the alerts are on but the timer is inactive or not installed; no run is recorded, or the last run is older than three intervals plus 30 seconds; the last run recorded no target, or no target accepted it; the targets file is missing, is not a regular file or is not `0600 root:root`; `ENABLE_ALERTS` is set twice in `.node-meta`; the runner is missing or its version differs from the scripts' copy; `alerts.env` is missing or names another service or RPC address than the node's.
Each warning names its fix, most often `sudo bash setup-alerts.sh --refresh`.
Its ownership check covers the runner and the files in `/etc/telcoin/alerts`.

Troubleshooting.

```bash
systemctl status telcoin-heartbeat.timer
journalctl -u telcoin-heartbeat -n 20
sudo cat /var/lib/private/telcoin-heartbeat/state
```

Each run logs one line, `up: <reason> | <pushes>` or `down: <reason> | <pushes>`, such as `up: CvvActive block 1234567 epoch 42 | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net fail 000 timeout`.
When the status changed, a line `status up -> down: <reason>` comes before it (`status none -> up: <reason>` on the first run), and `every target failed` follows it when no target accepted the heartbeat.
A failed push says why: `timeout`, `refused`, `dns`, `tls`, `too-large`, `body` (Kuma answered `"ok":false`), `http` (the code says which) or `curl-N`; code `000` means no answer came.
A run in which every target failed leaves the service failed, and the timer keeps starting it.
A `config:` line means the runner refused its settings or its targets and sent nothing: run `setup-alerts.sh --refresh`, or give the targets again with `3) Change targets`.
When the heartbeat stays up while the node is stopped, check that `cat /run/telcoin/heartbeat-service` shows `ActiveState=` after a run: without that file the runner cannot see the service and only the RPC checks decide, so run `sudo bash setup-alerts.sh --refresh` to install the current unit.
The state file holds `key=value` lines: the last run, status, reason, mode, block and epoch, and `push_1` to `push_5` (`<provider> ok|fail <code> [why] <host>`).

### 4.15 Worker gateway

`setup-gateway.sh` runs telcoin-network's worker gateway, a public JSON-RPC front for transaction submissions.
The gateway takes JSON-RPC as HTTP `POST`.
A transaction submission (`eth_sendRawTransaction`, `eth_sendRawTransactionSync`, or a batch made only of those) goes to the worker of the node it fronts.
Every other call, reads and `tn_*` calls included, goes to a query endpoint you name with `--redirect-queries`, such as a public RPC node: the gateway proxies the call there itself and never sends the client a redirect.
Two kinds of read stay with the worker: `eth_getTransactionCount` for `"pending"`, and a transaction or receipt lookup for a hash this gateway submitted a short while ago.
A batch that mixes submissions with other calls goes whole to the query endpoint.

What it is not.
It has no TLS, no WebSocket and no authentication of its own.
It limits each client IP address to 100 requests a second and 32 open connections.
It never stops, starts or restarts the node, and `setup-gateway.sh` never edits the node's launch file, `.node-meta` or a firewall rule.
It works on every network, but testnet and mainnet refuse it until a scripts release pins an image (see Images below), so today it runs on devnets only.

Pick a layout with `--mode`:

| Mode | Where the gateway runs | Use it when |
|---|---|---|
| `same-host` | On the node's host, reaching the node on `127.0.0.1`. | A testnet or devnet node whose host can also serve the gateway's public name. Refused on mainnet: `on mainnet the gateway runs on its own host (use --mode standalone there)`. The node needs `--healthcheck`. |
| `standalone` | On a host of its own with no node, reaching a validator on the validator's private IPv4 (`--upstream`). | The validator stays off the public internet and only the gateway host faces it. The only layout on mainnet. The validator must admit the gateway host first. |

And a front with `--front`:

- `caddy` (the default): the gateway listens on `127.0.0.1:8655`, and this host's Caddy serves `https://<domain>/` in front of it. Needs `--domain` (a DNS name: an IP address is refused, because Caddy needs a name for the certificate), a DNS record and ports 80 and 443.
- `none`: the gateway itself listens on `0.0.0.0:8655` over plain HTTP, for a load balancer or private network that brings its own TLS. No script opens that port: the firewall is yours.

The gateway has two more listeners, on `127.0.0.1` only: the probe listener on 8656 (`/health`, `/ready`, `/ready/any`) and the metrics listener on 9655.
`--listen-port`, `--probe-port` and `--metrics-port` change the three; they must differ from each other and, on a node host, from the node's RPC and health ports.
`--redirect-queries` takes `http(s)://host[:port][/path]` with a hostname or an IPv4 address, and is refused when it points at the worker's RPC or readiness port, or at one of the gateway's own ports on this host, because the gateway refuses to start with such a URL.

Images.
The gateway runs from a Docker image given by digest, `<repository>@sha256:<64 lowercase hex>`; a tag is refused.
On testnet and mainnet only the image this scripts release pins in `lib/gateway.sh` is taken, and `--image` may be left out.
Each pin is the image a signed telcoin-network release names in its `IMAGE_DIGEST-worker-gateway`, an image in `ghcr.io/telcoin-association/tn-worker-gateway`, and `lib/gateway.sh` records that release beside it.
CI checks each pin against that release's signed `SHA256SUMS-edge`, and the installer of a scripts release is published only when the check passes.
This release pins none, so `--enable` there refuses with `this scripts release pins no worker-gateway image for <network> yet`, and names `update-scripts.sh`, which brings a later scripts release that pins one.
No signed telcoin-network release with a worker-gateway image exists yet.
A pin that is not such an image, or that has no release of the network's own tag form beside it, is refused as a defect of the scripts release: `this scripts release's <network> worker-gateway pin cannot be used: ...`.
On devnet the repository must be one of `ghcr.io/telcoin-association/tn-dev` (telcoin-network's unsigned builds, tagged `dev-worker-gateway-<tag>`), `ghcr.io/telcoin-association/tn-worker-gateway` (the release images) or `us-docker.pkg.dev/telcoin-network/tn-public/worker-gateway`.
Before it writes anything, the enable pulls the digest when Docker does not hold it, then runs the image's `--help` and refuses an image that lacks a flag the unit passes.
The unit itself never pulls (`--pull=never`).
Docker must be installed and running; `setup-gateway.sh` does not install it.

To build an image for a devnet, run this from the root of a telcoin-network checkout (the gateway has its own Dockerfile there):

```bash
docker build -f bin/worker-gateway/Dockerfile -t us-docker.pkg.dev/telcoin-network/tn-public/worker-gateway:<tag> .
docker push us-docker.pkg.dev/telcoin-network/tn-public/worker-gateway:<tag>
docker inspect --format '{{index .RepoDigests 0}}' us-docker.pkg.dev/telcoin-network/tn-public/worker-gateway:<tag>
```

The last command prints the `<repository>@sha256:<digest>` reference to pass as `--image`.
The push needs write access to that repository, one of the three devnet takes.

Same host, behind Caddy.

1. The node needs `--healthcheck`: the gateway reads the worker's readiness from `http://127.0.0.1:<health port>/health/workers`. On testnet the health monitor add-on adds `--healthcheck 43174` (section 4.6). Elsewhere add `--healthcheck 43174` to the node command in its launch file by hand and restart the node; no `edit-config.sh` field sets it. Without the flag the enable refuses: `the node runs without --healthcheck, and the gateway reads the node's readiness from it; give the node a health port (--healthcheck 43174) and run this again. Nothing was changed.`
2. Create an A record for the gateway's name pointing at this server's inbound public IP, and check it. The check changes nothing and exits 0 only when the name reaches this server:

   ```bash
   sudo bash ~/telcoin-node-scripts/install-caddy.sh --phase=gateway-check-dns --gateway-domain gw.example.org
   ```

3. Caddy needs ports 80 and 443 free on this host and reachable from the internet to get and renew the certificate. The enable adds `ufw` rules for both; open them in your cloud provider's firewall yourself. `firewall-setup.sh --enable` and `--reset` keep 80 and 443 open while the gateway site exists. A public RPC site (section 5) on the same host stops the enable: the public RPC site and the worker gateway are not served from one host, so run `install-caddy.sh --phase=rpc-disable` first.
4. Enable it:

   ```bash
   sudo bash ~/telcoin-node-scripts/setup-gateway.sh --enable --mode same-host --domain gw.example.org \
     --image us-docker.pkg.dev/telcoin-network/tn-public/worker-gateway@sha256:<digest> \
     --redirect-queries https://rpc.example.org/
   ```

   It checks everything first, then says what it will expose and asks once:

   ```
   The worker gateway answers JSON-RPC from anyone on the internet at https://gw.example.org/, through this host's Caddy.
   Transaction submissions go to the node's worker at http://127.0.0.1:8545; every other call is proxied to https://rpc.example.org/.
   There is no auth: each client IP gets at most 100 requests a second and 32 connections. The node is not stopped or restarted.
     Enable the worker gateway? [y/N]:
   ```

   `--yes` skips the question and `--json` never asks; without a terminal and without either it stops with `Enabling the worker gateway needs your consent to the above: run again with --yes (or from a terminal). Nothing was changed.`
   Then it writes `/etc/telcoin/gateway/gateway.meta` and `telcoin-gateway.service`, starts the unit, waits up to 20 seconds for the gateway's `/health`, and runs `install-caddy.sh --phase gateway-enable`, which writes the `tn-gateway` site, opens 80 and 443 and reloads Caddy. It ends with `worker gateway enabled`.
   It does not wait for `/ready`, because the node may be down.
   When the Caddyfile already holds the same site but Caddy is not running, `gateway-enable` writes the site again and starts Caddy.
5. Check it:

   ```bash
   sudo bash ~/telcoin-node-scripts/setup-gateway.sh --status
   curl -s https://gw.example.org/ready
   curl -s -X POST -H 'Content-Type: application/json' \
     --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' https://gw.example.org/
   ```

   The query endpoint answers the `eth_chainId` call.
6. Advertise the gateway in the node's record (below) only now: `rpc-advertise` refuses until `https://gw.example.org/health` answers 200 from this host.

The node's RPC port defaults to the node's `--http.port`, else `RPC_PORT` in `.node-meta`, else 8545, and the health port to the node's own; `--rpc-port` and `--health-port` override them.
`--network` defaults to the node's network and must match it when given.
If a step fails after the first write, the enable puts the previous unit and `gateway.meta` back (or removes them when there were none) and exits 1; exit 3 means the put-back failed too, and the message says what is left.
An enable with the same inputs as the installed gateway changes nothing and restarts nothing: `the worker gateway was already as asked; nothing had to change`.
With different inputs it rewrites the unit and restarts the gateway, never the node.

The Caddy site passes `POST` to the gateway with request bodies capped at 2 MB, passes `GET` and `HEAD` on `/health`, `/ready` and `/ready/any` to the probe listener, answers a CORS preflight as the public RPC site does, and answers a WebSocket upgrade and any other method with `405` and `Allow: POST, OPTIONS`.

Standalone, on its own host.
Two hosts: the validator, at private IPv4 `10.0.0.12`, and the gateway host, at private IPv4 `10.0.0.20` with the public name `gw.example.org`.
They need a private network that routes between them.
`--upstream` must be a private IPv4 address (10/8, 172.16/12, 192.168/16, 100.64/10 or 169.254/16).
Do the steps in this order: the validator refuses to listen until its firewall admits the gateway host.

On the validator:

1. Admit the gateway host:

   ```bash
   sudo bash ~/telcoin-node-scripts/firewall-setup.sh --enable --gateway-from 10.0.0.20
   ```

   This adds two `ufw` rules per source on every network, `allow from 10.0.0.20 to any port <RPC port> proto tcp` and the same for the health port 43174 (the RPC port is `RPC_PORT` in `.node-meta`, else 8545).
   The list is stored as `GATEWAY_ALLOW_FROM` in `.node-meta`, and every later `--enable` and `--reset` applies it again.
   Sources are compared the way `ufw` stores them: `10.0.0.20/32` and `10.0.0.20` are one source, and a CIDR is its network address (`10.0.0.5/24` is `10.0.0.0/24`).
   `sudo bash ~/telcoin-node-scripts/firewall-setup.sh --json --status` shows it as `"gateway_from":["10.0.0.20"]`.
2. Bind the RPC and the health check to every interface:

   ```bash
   sudo bash ~/telcoin-node-scripts/edit-config.sh --set gateway_upstream=10.0.0.20
   ```

   It sets `--http.addr 0.0.0.0` and `--healthcheck 0.0.0.0:43174` on the node command and records `GATEWAY_UPSTREAM` and, the first time, the previous `--healthcheck` value as `GATEWAY_PREV_HEALTHCHECK` in `.node-meta`.
   It adds none of the public RPC limits and no `--http.api`, and leaves the WebSocket bind alone.
   It is refused on every network, mainnet included, unless `ufw` is active and holds both rules for every address listed, for example: `ufw has no rule letting 10.0.0.20 in to port 8545, so the gateways cannot reach the RPC and health check; open them first: sudo bash ~/telcoin-node-scripts/firewall-setup.sh --enable --gateway-from 10.0.0.20`.
   It is also refused when the firewall lets more than the gateways in: a default policy for incoming traffic other than deny or reject, or a rule that lets any address in to the RPC or health port, such as `ufw has a rule letting any address (Anywhere) in to port 8545; delete it first`.
   And it is refused when the node's RPC already listens on every interface: that RPC is public, and `gateway_upstream` is for a node whose RPC is private.
   List each gateway host by its IPv4 address, as `--gateway-from` names it (`10.0.0.20` or `10.0.0.20/32`); a CIDR in `--gateway-from` that contains the address does not count.
   A running node is restarted after the committee quorum check (section 4.11) and the epoch wait (section 4.2), as for any other edit; a node that was stopped (inactive or failed) stays stopped, with the files edited and nothing started.
   A node that is starting, stopping or waiting for its automatic restart is refused: `the node is starting or restarting (or stopping), neither active nor stopped; wait until it is active, or stop it`.

On the gateway host, which runs no node:

3. Get the scripts (section 2.1) and install Docker, then enable the gateway. `--network` is required here, because there is no node to take it from:

   ```bash
   sudo bash ~/telcoin-node-scripts/setup-gateway.sh --enable --mode standalone --network devnet \
     --upstream 10.0.0.12 --domain gw.example.org \
     --image us-docker.pkg.dev/telcoin-network/tn-public/worker-gateway@sha256:<digest> \
     --redirect-queries https://rpc.example.org/
   ```

   The enable asks the validator for its chain id (`eth_chainId`) and refuses when the chain belongs to another network than `--network`, such as `the upstream http://10.0.0.12:8545 is on chain <id> (testnet), and the network given is devnet: give the network that node runs`.
   Mainnet and testnet each have one chain id, and a devnet is any other.
   When the validator does not answer within 3 seconds, it warns `The network could not be confirmed` and goes on with the network given; `--status` checks it again once the validator answers.
   The DNS record and the ports 80 and 443 of the same-host steps apply to this host.
   The gateway reaches the validator at `http://10.0.0.12:8545` and reads its readiness from `http://10.0.0.12:43174/health/workers`; give `--rpc-port` or `--health-port` when the validator uses other ports.
   With `--front none` there is no Caddy and no DNS step; leave out `--domain`.
4. Turn on this host's firewall:

   ```bash
   sudo bash ~/telcoin-node-scripts/firewall-setup.sh --enable --ssh-from 198.51.100.7/32
   ```

   On a host with a gateway and no node, `firewall-setup.sh` takes the network from `gateway.meta` and applies the SSH rules and, when Caddy serves the gateway site, 80 and 443; it adds no P2P rule and no health rule.
   With `--front none` it opens nothing for the gateway's port, so add your own rule, such as `sudo ufw allow from 203.0.113.0/24 to any port 8655 proto tcp` for a load balancer's range.
   It keeps the SSH source list as `SSH_ALLOW_FROM` in `gateway.meta`, so `--ssh-from` is given once: a plain `--enable` applies the stored list again, and removing the gateway removes the list with `gateway.meta`.
   On mainnet, as on a node host, `--enable` is refused until it has an SSH source list, given or stored, or `--ssh-anywhere`.
5. On the validator, advertise the gateway in its record (below) only now, with the gateway, its DNS record and its certificate in place: `rpc-advertise` refuses until `https://gw.example.org/health` answers 200 from the validator.

To undo it, go in the reverse order:

```bash
# on the gateway host
sudo bash ~/telcoin-node-scripts/setup-gateway.sh --remove
# on the validator
sudo bash ~/telcoin-node-scripts/install-caddy.sh --phase=rpc-unadvertise    # only if you advertised the gateway
sudo bash ~/telcoin-node-scripts/edit-config.sh --set gateway_upstream=off
sudo bash ~/telcoin-node-scripts/firewall-setup.sh --enable --gateway-from none
```

`gateway_upstream=off` puts `--http.addr` back on `127.0.0.1`, whatever it was before, and `--healthcheck` back to the value recorded in `GATEWAY_PREV_HEALTHCHECK` (it removes the flag when there was none, and leaves the flag as it is with a warning when the key is missing), then unsets both keys; it restarts the node under the same guards.
`--gateway-from none` removes `GATEWAY_ALLOW_FROM` and deletes its rules.

While `GATEWAY_UPSTREAM` is set, `firewall-setup.sh` on the validator refuses `--gateway-from none`, a `--gateway-from` list that leaves out a host `GATEWAY_UPSTREAM` names, and `--reset`; a plain `--enable` still runs.
The node's RPC listens on every interface then, and the firewall is all that limits who reaches it: `--gateway-from none` or a shorter list deletes the rules made for the gateway, and a reset turns `ufw` off while it applies the rules again.
That is why the undo steps run `gateway_upstream=off` before `--gateway-from none`.
To reset the firewall of such a validator, turn the upstream off around the reset:

```bash
sudo bash ~/telcoin-node-scripts/edit-config.sh --set gateway_upstream=off
sudo bash ~/telcoin-node-scripts/firewall-setup.sh --reset
sudo bash ~/telcoin-node-scripts/firewall-setup.sh --enable --gateway-from 10.0.0.20
sudo bash ~/telcoin-node-scripts/edit-config.sh --set gateway_upstream=10.0.0.20
```

Each `gateway_upstream` change restarts a running node under the guards of step 2.

Advertise the gateway in the node's record.
Other nodes forward the transactions they receive to the RPC URL that committee members advertise in `node-info.yaml` (section 6.1).
To have them send transactions to the gateway, advertise its URL on the node host: this host in same-host mode, the validator in standalone mode.

```bash
sudo bash ~/telcoin-node-scripts/install-caddy.sh --phase=rpc-advertise --rpc-domain gw.example.org
```

It first asks for `https://gw.example.org/health` from this host and refuses unless the answer is 200 with a certificate valid for that name: `rpc-advertise was asked to advertise https://gw.example.org/, and GET https://gw.example.org/health from this host got <what> instead of 200`.
No flag skips the check: a wrong URL in a validator's record breaks transaction forwarding to it until the record is fixed and the node restarted again.
So the gateway, its DNS record and its certificate come first, and in standalone mode the validator must resolve the gateway's name and reach it over HTTPS.
It writes `https://gw.example.org/` and no WebSocket URL into `node-info.yaml`, sets `PUBLIC_RPC_DOMAIN`, `PUBLIC_RPC_URL` and `RPC_ADVERTISED_VIA=gateway` in `.node-meta`, removes `PUBLIC_WS_URL`, and touches no Caddy file.
The node signs its record at start, so this restarts the node once, after the quorum check and the epoch wait; when `node-info.yaml` already holds that URL, there is no restart.
It ends with `Worker gateway advertisement set: https://gw.example.org/ (no WebSocket URL).`
The URL is always `https`, so advertise only a gateway that serves TLS: one behind Caddy, or behind a load balancer that terminates TLS for that name.
`--phase=rpc-unadvertise` clears the RPC entry from `node-info.yaml`, unsets the four keys and restarts the node the same way (`Worker gateway advertisement removed.`).

While `RPC_ADVERTISED_VIA=gateway` is set, `rpc-disable` removes only a public RPC site and leaves `node-info.yaml` and the keys alone, and `rpc-enable` refuses until you run `rpc-unadvertise`.
`gateway-enable` refuses while a public RPC site is configured.
`rpc-advertise` and `rpc-unadvertise` refuse while this host serves a public RPC site, whose advertisement is `rpc-disable`'s to clear.
A public RPC site and a gateway are never served from one host.

Status and logs.

```bash
sudo bash ~/telcoin-node-scripts/setup-gateway.sh --status
```

```
installed true, enabled true, active true, network devnet
mode same-host, front caddy (gw.example.org), listen 127.0.0.1:8655, upstream http://127.0.0.1:8545
image us-docker.pkg.dev/telcoin-network/tn-public/worker-gateway@sha256:<digest> (held true)
health true, ready true, ready_any true, issues 0
```

Each issue it finds comes on its own line with its fix, such as `The unit differs from /etc/telcoin/gateway/gateway.meta: run setup-gateway.sh --refresh`.
Three issues compare the gateway with the node and with this scripts release: `gateway.meta` names another network than the node on this host; on a host with no node, the upstream answers with the chain id of another network than `gateway.meta` names; the gateway runs an image this scripts release does not allow (`The gateway runs an image this scripts release does not allow: ...; run setup-gateway.sh --refresh`).
`check-node.sh` reports the same issues.
`--status` needs no root, but `gateway.meta` is root 0600, so run it with `sudo` to see everything.
It exits 0 whenever it could read the state; with `--json` its `done` line carries `installed`, `active`, `health`, `ready`, `ready_any` and `issues`, which a script judges.

| Field | True when | What it tells you |
|---|---|---|
| `health` | The gateway answers `GET /health` with 200 on its probe listener. | The gateway process runs. |
| `ready` | `GET /ready` answers 200: the node's `/health/workers` has said `accepting_transactions: true` for worker 0 on two polls in a row. | Submissions can go through. The gateway polls every 5 seconds and turns not ready after three failed polls. While not ready, a submission gets `503` with JSON-RPC error `-32000`, and other calls still go to the query endpoint. |
| `ready_any` | `GET /ready/any` answers 200: `ready` is true, or the query endpoint answers. | At least one of the two routes works. |

`ready` false is not counted as an issue: the node may be down or restarting, and the gateway keeps running and recovers on its own when the node accepts transactions again.

`check-node.sh` checks the gateway too, in a section `Checking the worker gateway...`: the unit enabled and active, the image held by Docker, the three listeners bound where `gateway.meta` says, `/health`, the Caddy site with front `caddy`, and in same-host mode that the node's `--healthcheck` is on the port the gateway polls.
It reports `/ready` without counting it.
On a host with a gateway and no node it says `No Telcoin node on this server, only a worker gateway: the node sections are skipped.`
On a validator with `GATEWAY_ALLOW_FROM` or `GATEWAY_UPSTREAM` in `.node-meta`, a section `Checking the gateway upstream (validator side)...` checks the `ufw` rules for each listed host, that the RPC and `--healthcheck` listen on `0.0.0.0` exactly when `GATEWAY_UPSTREAM` is set, and that `node-info.yaml` advertises an `https` URL and no WebSocket URL.
When they listen on `0.0.0.0`, it also reports a firewall that lets more than the gateways reach them.

The gateway logs to the journal through its unit, and Docker keeps the container's output while it runs (the container is removed when it stops):

```bash
journalctl -u telcoin-gateway -n 100
sudo docker logs telcoin-gateway
```

The metrics listener answers on `127.0.0.1:9655` only, such as `curl -s http://127.0.0.1:9655/metrics`.
Its names begin with `tn_worker_gateway_`: `tn_worker_gateway_upstream_ready` is 1 while the worker is ready, `tn_worker_gateway_routed_requests_total` counts calls by `route` (`worker` or `query`), and `tn_worker_gateway_rejections_total` counts refusals by `reason`, such as `rate_limited` or `no_upstream_ready`.
No add-on of these scripts scrapes it.

Refresh, and what a scripts update does.

```bash
sudo bash ~/telcoin-node-scripts/setup-gateway.sh --refresh
```

A refresh renders the unit again from `gateway.meta` with the scripts on disk and, when the result differs from the installed unit, writes it and restarts the gateway only.
With `--image <repository>@sha256:<digest>` it moves the gateway to that image, under the same image rules as an enable.
On testnet and mainnet, without `--image`, it moves the gateway to the image this scripts release pins when `gateway.meta` holds another, and says so: `Moving the worker gateway from <old> to <new>, the image of telcoin-network <release> this scripts release pins for testnet`.
It checks the network first: on a node host it refuses when `gateway.meta` names another network than the node's, and on a host with no node it asks the upstream for its chain id, as the enable does.
When nothing differs it says `the worker gateway was already current; nothing had to change`.
A scripts update (section 4.1) replaces the scripts on disk and nothing else: the installed unit, `gateway.meta` and the running container stay as they were.
When the new scripts would write a different unit, `--status` and `check-node.sh` report that the unit differs; run the refresh then.
When the new release pins another image, they report the running image as one the release does not allow, and the refresh moves the gateway to the new pin.
To change a setting other than the image, run `--enable` again with every option you want.

Remove.

```bash
sudo bash ~/telcoin-node-scripts/setup-gateway.sh --remove
```

It says what goes, such as `https://gw.example.org/ stops answering: its Caddy block is removed.` and `The unit telcoin-gateway.service, its container and /etc/telcoin/gateway are removed; the image stays.`, and asks `Remove the worker gateway? [y/N]` (`--yes` or `--json` skips it).
With front `caddy` it runs `install-caddy.sh --phase gateway-disable` first, which removes the site and leaves any other Caddy site in place.
It ends with `worker gateway removed; its image stays on this host`.
A file in `/etc/telcoin/gateway` that the gateway did not write stays, and the directory with it: the removal names it (`... stays: it holds files the gateway did not write (...)`) and exits 0.
It does not touch the node's record: run `rpc-unadvertise` on the node host if you advertised the gateway.
On a standalone layout, close the validator side as the undo steps above show.

`remove-node.sh` on a host with a node and a gateway removes the gateway (its unit, container and `/etc/telcoin/gateway`) before it stops the node, as it does the private alerts (section 4.7).
It keeps the image and says how to remove it (`docker image rm <image>`), and it leaves the Caddy site in place with `The Caddyfile still holds the worker gateway's site; remove it with: sudo bash install-caddy.sh --phase gateway-disable`.
When `.node-meta` still says `RPC_ADVERTISED_VIA=gateway`, it warns `node-info.yaml still advertises https://gw.example.org/ as this node's RPC` and names `rpc-unadvertise`.
On a host with a gateway and no node, it never removes a gateway that runs on its own host (`MODE=standalone` in `gateway.meta`, or no mode it can read), and says `A worker gateway is installed here and this script leaves it in place; remove it with: sudo bash setup-gateway.sh --remove`.
The files a node left on such a host stay as well, because removing them would take the gateway's files with them: remove the gateway first, then run `remove-node.sh` again.
A same-host gateway whose node is gone is removed with the files the node left.
Update the scripts (section 4.1) before you remove a node that has a gateway: an older `remove-node.sh` does not know the gateway, leaves it running, and its scan for other installs offers the gateway's unit and container as a stray install.

Limits to know.
The rate and connection limits are per client IP address.
Behind Caddy, the gateway trusts only `127.0.0.1` (`--trusted-proxies 127.0.0.1/32`) and takes the client address from the right end of `X-Forwarded-For`.
Caddy's default proxy handling sets that header to the address the connection came from and drops a value the client sent, and the generated Caddyfile configures no trusted proxy: that default is what stops a client from spoofing its address past the limit.
With `--front none` the gateway trusts no proxy unless you give `--trusted-proxies <CIDR>[,<CIDR>]`; behind a load balancer, give its range, or every client counts as the balancer.
An upstream RPC node, wallet backend or relay that forwards many users' transactions through the gateway is one client: 100 requests a second and 32 connections for all of them.
A batch of K calls costs K requests.
After a `429` the gateway closes the connection, so the client has to reconnect.

The files:

| File | Owner, mode | What |
|---|---|---|
| `/etc/telcoin/gateway/` | root 0755 | Holds `gateway.meta`. |
| `/etc/telcoin/gateway/gateway.meta` | root 0600 | The gateway's settings, one `KEY=value` per line: the network, the mode, the front, the domain, the image, the upstream host and ports, the gateway's own ports, the query endpoint and the trusted proxies; on a host with no node also the firewall's SSH list (`SSH_ALLOW_FROM`). `--refresh` renders the unit from it. |
| `/etc/systemd/system/telcoin-gateway.service` | root 0644 | Runs `docker run --rm --name telcoin-gateway --network=host --user 1101:1101 --read-only --cap-drop ALL --security-opt no-new-privileges --pull=never --stop-timeout 60 <image> <flags>`, with `Restart=on-failure` and `TimeoutStopSec=75`. |
| The `tn-gateway` block of `/etc/caddy/Caddyfile` | | With front `caddy` only; `install-caddy.sh` writes and removes it. |
| `GATEWAY_ALLOW_FROM`, `GATEWAY_UPSTREAM`, `GATEWAY_PREV_HEALTHCHECK` in the validator's `.node-meta` | | Written by `firewall-setup.sh --gateway-from` and `edit-config.sh --set gateway_upstream` in standalone mode. |
| `RPC_ADVERTISED_VIA=gateway` in the node's `.node-meta` | | Written by `rpc-advertise`, removed by `rpc-unadvertise`. |

Enable, refresh and remove take the update lock, so each refuses while another script holds it; `--status` takes none.
On a host with the host baseline (section 4.13), a change that went through makes the baseline again.
Every refusal ends `Nothing was changed.`
Exit status: 0 done; 1 refused, or failed and put back; 2 the libraries are older than the script (update the scripts); 3 a step failed after something changed, and the message says what is left.

Troubleshooting.

| What you see | Cause | Fix |
|---|---|---|
| `/ready` answers `503` and submissions get `503` / `-32000` | The node is down or restarting. | Start the node; the gateway turns ready about two polls after the node accepts transactions. |
| The same, with the node running | The node does not report worker 0 as accepting transactions. | `curl -s http://127.0.0.1:43174/health/workers` on the node host shows the `accepting_transactions` value the gateway reads. |
| The same, and `check-node.sh` says the node's `--healthcheck` is on another port than the gateway's readiness URL | The gateway polls the wrong health port. | Run `setup-gateway.sh --enable` again (with `--health-port` in standalone mode). |
| The same, and `check-node.sh` says the node's launch line has no `--healthcheck` | The node serves no health endpoint. | Add `--healthcheck 43174` to the node command (step 1 of the same-host steps). |
| The same, standalone | The validator's health check or RPC listens on `127.0.0.1`, or `ufw` does not admit the gateway host. | On the validator: `check-node.sh`, then the `firewall-setup.sh --gateway-from` and `edit-config.sh --set gateway_upstream` steps. |
| Reads get `502` (`-32001`) or `504` (`-32002`) while submissions work | The query endpoint is down or unreachable from the gateway host. | Check the `--redirect-queries` URL from the gateway host; change it with `setup-gateway.sh --enable` and the full set of options. |
| `429` (`-32006`) | A client went over 100 requests a second, or behind a load balancer every client looks like the balancer. | Spread the load, or with `--front none` give the balancer's range with `--trusted-proxies`. |
| A `tn_*` call gets `403` (`-32011`, `method not allowed through this gateway`) | The gateway runs without a query endpoint. A gateway these scripts install always has one and sends `tn_*` calls there. | Check that `telcoin-gateway.service` is the unit these scripts wrote (`setup-gateway.sh --status`, issue lines). |
| `405` | A `GET` or a WebSocket upgrade. | Send JSON-RPC as `POST`; the gateway has no WebSocket. |
| `413` | The request body is too large. | Send smaller requests. |
| The certificate does not issue | The A record does not point at this host, or 80 and 443 are closed in a firewall in front of it. | `install-caddy.sh --phase=gateway-check-dns --gateway-domain <name>`, open 80 and 443 in the cloud firewall, then `sudo journalctl -u caddy -n 50`. |
| `edit-config.sh --set gateway_upstream=...` is refused with `ufw has no rule letting ...` or `ufw is not active` | The firewall does not admit the gateway host yet. | Run the `firewall-setup.sh --enable --gateway-from <list>` it names first. |
| `edit-config.sh --set gateway_upstream=...` is refused with `ufw has a rule letting any address (Anywhere) in to port ...` or `ufw's default policy for incoming traffic is ...` | Other addresses than the gateways would reach the RPC or health port once it listens on `0.0.0.0`. | Delete the open rule (`sudo ufw status numbered`, then `sudo ufw delete <number>`), or run `firewall-setup.sh --enable --gateway-from <list>`, which sets the default deny. |
| `edit-config.sh --set gateway_upstream=...` is refused with `the node is starting or restarting (or stopping)` | systemd reports the node neither active nor stopped, such as a crashed node waiting for its automatic restart. | Wait until the node is active, or stop it (`sudo systemctl stop <service>`, as the message says), then run it again. |
| `firewall-setup.sh --gateway-from none`, or a list without a gateway host, is refused with `GATEWAY_UPSTREAM in .node-meta names ...` | The node is bound for that gateway, and the run would delete the gateway's rules. | `edit-config.sh --set gateway_upstream=off` (or a new list) first, then the firewall run. |
| `firewall-setup.sh --reset` is refused with `--reset is refused while GATEWAY_UPSTREAM is set` | A reset turns `ufw` off while it applies the rules again, and the node's RPC listens on every interface. | The four commands the message names, in order (the reset steps after the undo steps above). A plain `--enable` is allowed. |
| `setup-gateway.sh --enable` or `--refresh` is refused with `the upstream http://... is on chain ..., and the network given is ...` | `--network`, or `NETWORK` in `gateway.meta`, is another network than the validator runs. | Run `--enable` again with the validator's network as `--network`. |
| `setup-gateway.sh --refresh` says `Moving the worker gateway from ...` | On testnet and mainnet a refresh moves the gateway to the image this scripts release pins. | Nothing: that is the only image the release allows there. `--status` shows the new image. |
| `install-caddy.sh --phase=rpc-advertise` is refused with `GET https://<name>/health from this host got ... instead of 200` | The gateway, its DNS record or its certificate is not in place, or this host cannot reach the name. | Enable the gateway first, then run `curl -sS https://<name>/health` from this host; run `rpc-advertise` again when it answers. |
| `firewall-setup.sh --gateway-from ...` runs without error, but `--json --status` has no `gateway_from` | Scripts older than this release ignore flags they do not know. | Update the scripts (section 4.1), then run it again. |
| `setup-gateway.sh` exits 2 | The libraries are older than the script. | Update the scripts (section 4.1). |

## 5. Public RPC (https + wss)

Public RPC serves your node's JSON-RPC at `https://<domain>/` and its WebSocket at `wss://<domain>/`, and advertises both URLs in `node-info.yaml` so wallets and gateways can discover the node.
reth itself stays on `127.0.0.1`.
Caddy holds the TLS certificate on port 443 and proxies to reth on loopback.

It is a deliberate choice.
The Caddy site has no authentication and no rate limiting, so anyone can send requests to it.
It suits observers that are meant to serve the public.
The upstream validator guidance is to keep a validator's RPC off the public internet; read the appendix before you turn this on for a validator.

A host serves either this site or a worker gateway's site (section 4.15), not both.
The README section [Public RPC endpoint](README.md#public-rpc-endpoint-https--wss) covers the internals; the steps are below.

### 5.1 DNS first

Create an A record for the node's public name pointing at the server's inbound public IP, and wait until it resolves, before you enable anything.
Caddy requests a Let's Encrypt certificate as soon as the site loads; if the name does not point at the server yet, issuance fails and repeated attempts get rate-limited.

- Allow inbound TCP 443 (required) and TCP 80 (recommended) in every firewall layer, and forward both on the router if the server is behind NAT.
- Behind NAT, or on a server with several addresses, pass the inbound IP with `--public-ip <ip>`. The address the scripts detect is the outbound one, which can differ.
- The RPC name and the dashboard name must be different, for example `node7.example.com` for RPC and `dashboard.node7.example.com` for the dashboard.
- Both must be DNS names. `install-caddy.sh` lowercases a name and drops a trailing dot, and refuses an IP address: `<name> is an IP address; Caddy needs a DNS name (an A record pointing at this server) to get a certificate`.
- Caddy 2.8.0 or newer. `install-caddy.sh` installs Caddy from its apt repository when it is missing, and refuses an older one before it writes anything, with the install instructions.

### 5.2 New install

```bash
DOMAIN=node7.example.com   # your node's public name
sudo bash ~/telcoin-node-scripts/setup-node.sh --rpc-domain "$DOMAIN"
```

Behind NAT, run this instead, with the inbound public IP:

```bash
sudo bash ~/telcoin-node-scripts/setup-node.sh --rpc-domain "$DOMAIN" --public-ip 203.0.113.10
```

Or answer `2) Public` at the RPC access prompt.
With a domain, key generation writes `https://<domain>/` and `wss://<domain>/` into `node-info.yaml` when the release's keytool supports advertising RPC (`--rpc-http`, present since `v0.12.0-adiri`).
After the node starts, setup checks DNS and runs `install-caddy.sh --phase=rpc-enable`, which does not restart the node when `node-info.yaml` already holds those URLs.
If DNS is not ready, setup finishes anyway and prints the command to run later.

`--no-public-rpc` keeps RPC private without asking.
It cannot be combined with `--rpc-domain` or `--rpc-public`; setup stops with an error (an `error` event in `--json` mode).
`--rpc-public` without `--rpc-domain` leaves RPC private and prints a warning with the command to enable it later.

### 5.3 Existing node

Check DNS first, then enable:

```bash
DOMAIN=node7.example.com   # your node's public name
sudo bash ~/telcoin-node-scripts/install-caddy.sh --phase=rpc-check-dns --rpc-domain "$DOMAIN"
sudo bash ~/telcoin-node-scripts/install-caddy.sh --phase=rpc-enable --rpc-domain "$DOMAIN"
```

`rpc-check-dns` changes nothing and exits 0 only when the name reaches this server.
`rpc-enable` first shows what the endpoint exposes and asks you to agree; from a script, pass `--yes` (without a terminal and without `--yes` it stops: `public RPC needs your consent to the exposure above: run again with --yes (or from a terminal). Nothing was changed.`).
On mainnet, Caddy is not offered to validators: the dashboard and public RPC are refused on a staked validator, on a node whose stake status cannot be read, and on a node with no `VALIDATOR_ADDRESS` in `.node-meta`. The stake is read from the local node, and from `https://rpc.telcoin.network` only when that endpoint answers with chain 731. A node whose network cannot be told (no `NETWORK` in `.node-meta`, and a genesis that cannot be read or is on neither 731 nor 2017, such as a chain-487 genesis) is refused too, with what was found: `The network of this node cannot be told (no NETWORK in .node-meta, and the chain id of /var/lib/telcoin/genesis/genesis.yaml (487) is neither 731 nor 2017), so this run cannot confirm it is not a staked mainnet validator. ...`. Serve public RPC from a separate RPC node and the dashboard over the SSH tunnel.
`rpc-enable` writes the Caddy site and reloads Caddy, adds `ufw` rules for 80 and 443 (also while `ufw` is off, so they are in place when you turn it on), makes sure reth serves WebSocket, and sets the advertised URLs in `node-info.yaml` (the first worker's entry) with the node's own `keytool set-rpc`.
It restarts the node once, and only if `node-info.yaml` or the launch command changed; it first runs the committee quorum check (section 4.11; `TN_ALLOW_QUORUM_RISK=1` overrides a refusal), and on a committee node it waits for the epoch boundary (section 4.2), which `TN_SKIP_EPOCH_WAIT=1` skips.
If the check refuses, or the run is stopped before the restart, `node-info.yaml` and the launch command are put back.
Before it edits the node it takes the update lock, so while `update-node.sh` or `edit-config.sh` holds it, the run stops with `an update is in progress (PID N); try again when it has finished.` and says what it already did; run it again once the update has finished.
It records `PUBLIC_RPC_DOMAIN`, `PUBLIC_RPC_URL` and `PUBLIC_WS_URL` in `.node-meta`.
When the endpoint serves but something was left undone, such as a node that is still starting or `wss://` not answering yet, the run still succeeds, prints a warning for each item, and ends with `Open items: ... (see the warnings above).`
Add `--public-ip <ip>` behind NAT.
If the dashboard already uses this name, create the A record for `dashboard.<domain>` and add `--move-dashboard-to dashboard.<domain>` to move it in the same run.
For a guided run, start `sudo bash ~/telcoin-node-scripts/install-caddy.sh` and choose `[2] Public RPC endpoint`.

The site Caddy serves, block v2 in `/etc/caddy/Caddyfile`, proxies JSON-RPC requests to reth's HTTP port and WebSocket upgrades to its WebSocket port.
The upgrade match ignores case, so a proxy that sends `Connection: upgrade` gets through.
A browser that opens the URL gets HTTP 405 and a short page naming the endpoint, with a `curl` example.
Request bodies above 2 MB (Caddy counts that as 2,000,000 bytes) get HTTP 413, and Caddy cuts the connection once the cap is passed, so reth never receives a whole oversized request; the largest legitimate JSON-RPC request is about 256 KiB.
Every change backs up the Caddyfile to `/etc/caddy/Caddyfile.bak.<time>`, and the newest five backups are kept.

### 5.4 Verify

```bash
curl -s https://$DOMAIN/ -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}'
```

On testnet the answer is `"result":"0x7e1"` (chain ID 2017).
The first request after enabling can take a few seconds while the certificate is issued.

For WebSocket, connect with `websocat wss://$DOMAIN/` or `wscat -c wss://$DOMAIN/` and send the same JSON request.
Opening `https://$DOMAIN/` in a browser shows the 405 page, which confirms that Caddy serves the name.

```bash
sudo bash ~/telcoin-node-scripts/check-node.sh
sudo bash ~/telcoin-node-scripts/install-caddy.sh --phase=rpc-status
```

The health check has a public RPC block that probes https and wss through Caddy, shows what `node-info.yaml` advertises, and ends with `public RPC: OK` or `public RPC: WARN -- <reasons>` plus the command that fixes it.
Run it with `sudo`; without root it can only report `public RPC: unknown (.node-meta not readable — run with sudo)`.
`--phase=rpc-status` shows whether the site is enabled, what is advertised, and whether reth's WebSocket port is listening.

A site enabled by an `install-caddy.sh` older than 1.4.0 has the old block: `rpc-status` reports it as stale (`"block_stale": true` with `--json`) and prints the refresh command, and `check-node.sh` warns `public RPC: the Caddy tn-rpc block predates block v2 (...)`.
Refresh it by running `rpc-enable` again with the same hostname.
That is a Caddy reload; the node restarts only if `node-info.yaml` or its WebSocket flags need a change.

`check-node.sh` also warns when `--http.api` or `--ws.api` on the node command names `debug`, `trace` or `admin`, because Caddy serves those methods to anyone who reaches the name.
Remove them from the launch file and restart the node.
`all` is not warned about: it enables `eth`, `net`, `web3` and `rpc` only, and the node reads a list that starts with `all` as plain `all`.

### 5.5 Turn it off

```bash
sudo bash ~/telcoin-node-scripts/install-caddy.sh --phase=rpc-disable
```

This takes the Caddy site down first, with a reload and no wait, and drops the `PUBLIC_RPC_*` lines from `.node-meta`.
Then, if `node-info.yaml` still advertises the endpoint, it takes the update lock, waits for the epoch boundary on a committee node (section 4.2), clears the advertised URLs and restarts the node.
When an update holds the lock, the site is already gone and the message says that `node-info.yaml` still advertises it; run `rpc-disable` again once the update has finished.
It removes the `ufw` rules for 80 and 443 once no Caddy site remains.

## 6. Validators: stake and activate

The stake and activation calls go to the ConsensusRegistry contract at `0x07E17e17E17e17E17e17E17E17E17e17e17E17e1`, the same address on testnet and devnet.
The BLS keys never leave the node.
On the node, `prepare-stake.sh` checks everything the stake depends on and prints the exact `cast send` commands; you run those commands on the machine that holds your wallet.
The script never reads, asks for or prints a private key, and it sends nothing.
The telcoin-network "how to stake" page shows outdated `stake` and `unstake` signatures; use the commands in this section (see the [appendix](#appendix-where-this-repo-and-the-telcoin-network-docs-disagree)).

The `cast` commands from section 6.7 on use these variables, set on the wallet machine:

```bash
REG=0x07E17e17E17e17E17e17E17E17E17e17e17E17e1
RPC=https://rpc.adiri.tel   # testnet; section 1.5 lists the networks
ADDR=0xYOUR_EXECUTION_ADDRESS
```

### 6.1 Prerequisites

- Association approval. Only GSMA-approved mobile network operators can validate; start with support@telcoin.org.
- Hardware at the validator tier of the network's table (section 1.1).
- The node's P2P ports reachable from the internet (section 1.3).
- A synced node (section 3).
- A publicly routable RPC URL advertised in `node-info.yaml` (section 5). Other nodes forward user transactions to the committee's advertised URLs and skip private addresses. Only a private network, such as a devnet, can lift that with `allow_private_forward_targets: true` in `parameters.yaml` (section 4.3); testnet and mainnet refuse `true`.
- The execution address funded with the stake plus gas. The stake is 1,000,000 TEL on testnet today; `prepare-stake.sh` reads the current amount.
- Foundry's `cast` on the wallet machine, and the wallet holding your execution address.

### 6.2 Check the node with prepare-stake.sh

On the node:

```bash
sudo bash ~/telcoin-node-scripts/prepare-stake.sh
```

It prints each check as it runs it:

1. Network RPC. The RPC must serve this node's chain: testnet (2017) unless `NETWORK` in `.node-meta` names another network. The default is that network's public RPC (section 1.5); `--network-rpc <URL>` picks another.
2. Validator address. The `execution_address` in `node-info.yaml`, shown with its EIP-55 checksum. It warns when `.node-meta` records a different `VALIDATOR_ADDRESS`.
3. Whitelist. Whether the address holds a ConsensusNFT. Without one the run stops: send the address to the Association for governance approval, and run the script again once the NFT is minted.
4. Validator status. An address that has not staked goes on. A staked one (status 1) skips to the `activate()` step. Any later status is reported, and the run ends with "Nothing to do".
5. Stake amount. What the registry asks for now, from `stakeConfig(getCurrentStakeVersion())`, in TEL and wei.
6. Balance. The address's TEL against the stake plus a gas allowance (the gas price times a million gas). If it is short, the script says how much to send and still prints the commands.
7. Stake calldata. Exported by the node's own keytool. No passphrase is needed.
8. Simulation. `stake()` is simulated from the address with `eth_estimateGas`. A predicted revert is named with what to do (section 6.5), and no commands are printed.
9. Local node sync. A warning when the node trails the network by more than 50 blocks.

Then it prints the commands for sections 6.3 and 6.4 and the epoch arithmetic from section 6.8.
With `--json` the human output goes to stderr and one JSON object with every value the run read goes to stdout at the end.

The run ends with one line and an exit code:

| Exit | Last line | Next step |
|---|---|---|
| 0 | `Ready to stake: run the commands above.` | Send the stake (6.3). |
| 0 | `Staked: activate() is next.` | Activate once the node has caught up (6.4). |
| 0 | `Nothing to do: ...`, because activation is under way, the validator is active, exiting or exited, or the address is retired | Watch the status (6.7). |
| 1 | A usage or setup problem, such as `Run this as root: sudo bash prepare-stake.sh <args>` | Do what the message says. |
| 2 | The network RPC cannot be reached, serves another chain, or the on-chain state cannot be read | Check the server's internet access, or pass `--network-rpc <URL>` with an RPC for the node's chain. |
| 3 | `Not ready: ...`, `Refused: ...` or `Cancelled: nothing changed.` | Fix what the lines above it name, then run it again. |
| 4 | `... node-info.yaml is back as it was (from <backup>).` | A rotation failed and was undone (6.6). |
| 130, 143, 129 | `Interrupted by SIG<X> ...` after Ctrl-C (SIGINT), SIGTERM or SIGHUP | Outside a rotation nothing changed; run it again. For a rotation, see 6.6. |

A mainnet node that uses the default RPC stops with exit 2 today: `https://rpc.telcoin.network serves chain 2017 (testnet), not chain 731 (mainnet)`, because mainnet has not launched and its hostname still serves the testnet (section 1.5).

### 6.3 Send the stake

The script prints the stake command with your values filled in:

```bash
cast send --rpc-url https://rpc.adiri.tel 0x07E17e17E17e17E17e17E17E17E17e17e17E17e1 \
  0x2fb0d025... \
  --value 1000000000000000000000000 --from 0xYOUR_EXECUTION_ADDRESS --ledger
```

Copy it to the wallet machine and run it there.
The calldata holds only public data: the node's BLS public key and its proof of possession.

`--ledger` signs on a Ledger; use `--trezor` for a Trezor.
For a key held in software, use `--account <name>`, an encrypted keystore you create once with `cast wallet import <name> --interactive`, or `--interactive` to paste the key when `cast` asks for it.
Do not use `--private-key`: the key would be on `cast`'s command line, where any user of that machine can read it with `ps`, and in your shell history.

Wait for the transaction to be mined.
Running `prepare-stake.sh` again then ends with `Staked: activate() is next.` and prints only the activation command.

### 6.4 Activate

Once the stake has landed (status 1, Staked) and the node has caught up, run the second command the script printed:

```bash
cast send --rpc-url https://rpc.adiri.tel 0x07E17e17E17e17E17e17E17E17E17e17e17E17e1 \
  'activate()' --from 0xYOUR_EXECUTION_ADDRESS --ledger
```

Status moves to `2` (PendingActivation) and then to `3` (Active) at the next epoch boundary.
Section 6.8 says when the first committee seat can come.

### 6.5 If prepare-stake.sh predicts a revert

The simulation names the error the registry would return, and the run stops with exit 3 and `Not ready: stake() would revert with <Error>. Fix that before you send the stake.`
A `cast send` that reverts returns the same names.

| Error | What it means | What to do |
|---|---|---|
| `InvalidProofOfPossession` | The proof of possession in `node-info.yaml` was signed for a different address than the one you stake from. The keys are fine. | Re-sign it for the staking address with `prepare-stake.sh --rotate-address` (6.6). |
| `InvalidTokenId` | The address holds no ConsensusNFT, so it is not whitelisted. | Ask the Association for approval, then run the script again. |
| `RequiresConsensusNFT` | The ConsensusNFT for the address is not held by that address. | Email support@telcoin.org. |
| `InvalidStakeAmount` | The stake configuration changed after the script read it. | Run the script again for the current amount. |
| `InvalidStatus` | The registry already holds a validator record for the address (the status number is shown), so it cannot stake again. | Check it with `sudo bash ~/telcoin-node-scripts/check-node.sh`. |
| `DuplicateBLSPubkey` | This BLS key is already registered. A BLS key can be staked only once. | If you staked it from another address, that address is this node's validator: check it with `check-node.sh --address <that address>`. Do not generate new keys. |
| `InvalidBLSPubkey` | The BLS public key in `node-info.yaml` is not a valid key, so the file was edited or damaged. | Restore `node-info.yaml` from your backup (2.5). |
| `EnforcedPause` | The registry is paused, so staking is closed for now. | Try again later. |
| `LowLevelCallFailure` | The registry could not run its BLS signature check. | Try again later. If it keeps failing, email support@telcoin.org. |
| `Error` with a message | The registry rejected the call with that message. | Act on the message. |
| `Panic`, or an error the script does not know | An internal error in the registry, or error data the script cannot name. | Email support@telcoin.org with the data the script prints. |

### 6.6 Change the execution address before you stake

The execution address is signed into the proof of possession in `node-info.yaml`.
To stake from a different address than the one you entered at key generation, re-sign the proof of possession for it with the same keys:

```bash
sudo bash ~/telcoin-node-scripts/prepare-stake.sh --rotate-address 0xNEW_ADDRESS
```

Rotation works only while the current address has not staked and is not retired.
The new address must not have staked or be retired either; a whitelisted address that has not staked, or one that is not whitelisted yet, is fine.
Once an address has staked, the registry holds the BLS key for it and the script refuses with `Refused: 0x... has staked (...)`.

The script:

- Shows what will change and asks first. `--yes` skips the question, and a `--json` run needs it.
- Takes the update lock, so it refuses while another script holds it, such as `update-node.sh` applying an update: `Refused: an update is in progress (PID N); try again when it has finished.`
- Copies `node-info.yaml` to `node-info.yaml.bak.<UTC time>` beside it, as the service user.
- Runs `keytool generate pop` from the node's own release, which changes only `execution_address` and `proof_of_possession`, then checks that the BLS key and the node name are unchanged.
- Records the new address as `VALIDATOR_ADDRESS` in `.node-meta`.
- Restarts the node so it loads the new file. `--no-restart` leaves the restart to you.

If keytool fails or its result is wrong, the script puts `node-info.yaml` back and exits 4; a wrong passphrase is the usual cause.

A rotation stopped by Ctrl-C, SIGTERM or SIGHUP ends with exit 130, 143 or 129 (with `--json`, `"ok":false` and the state `interrupted`).
Stopped while the proof of possession is being signed, the script lets keytool finish, puts `node-info.yaml` back from the backup and only then releases the update lock: `Interrupted by SIGINT while the proof of possession was being signed; node-info.yaml is back as it was (from <backup>).`
Stopped after the re-signed file passed its checks, `node-info.yaml` keeps the new address and the message ends `To finish, run: sudo bash prepare-stake.sh --rotate-address 0xNEW_ADDRESS --yes`; that run records the address and restarts the node.

The passphrase comes from `TN_BLS_PASSPHRASE` first, then from `/etc/telcoin/bls-passphrase` when that is a regular file with mode 600 or stricter (only a testnet or devnet host below systemd 250 has one), then from a prompt on a terminal.
The keytool gets it on standard input, never on a command line.
An install that keeps the passphrase as an encrypted credential has no plain file, so there type the passphrase at the prompt, or pass the variable through `sudo`, which otherwise drops it:

```bash
read -rs TN_BLS_PASSPHRASE && export TN_BLS_PASSPHRASE
sudo --preserve-env=TN_BLS_PASSPHRASE bash ~/telcoin-node-scripts/prepare-stake.sh --rotate-address 0xNEW_ADDRESS
```

After a rotation, run `sudo bash ~/telcoin-node-scripts/prepare-stake.sh` again; it exports the calldata for the new address.

### 6.7 Watch your status

```bash
cast call $REG "getValidator(address)(address,uint32,uint32,uint8,bool,uint8,uint8)" $ADDR --rpc-url $RPC
```

The seven lines are the validator address, activation epoch, exit epoch, status, `isRetired`, stake version and region.
The fourth line is the status (section 6.9).
The same information, with the next step spelled out, comes from:

```bash
sudo bash ~/telcoin-node-scripts/check-node.sh
```

`check-node.sh` finds the address itself, from `.node-meta` or the node; add `--address <0x...>` to check another one.
Its "Checking epoch and committee..." section shows the current epoch and when it ends, whether the address is in the committee for this epoch and the next two, and a staked validator's activation epoch and earliest committee seat.

Other signals:

- The Node Manager UI shows the validator view as soon as the network reports status 1 to 4 for the node's address, even while the node is still syncing. On a synced node its Current Epoch tile counts down to the boundary and shows the activation epoch and the earliest seat.
- `tn_nodeMode` (section 3) changes from `Observer` to `CvvActive` while the node holds a committee seat. A seated node that falls behind, for example during a long restart, reports `CvvInactive` until it has caught up, then logs `attempting to rejoin consensus` and votes again.
- The current epoch and its committee:

```bash
cast call $REG "getCurrentEpoch()(uint32)" --rpc-url $RPC
cast call $REG "getCurrentEpochInfo()((address[],uint256,uint64,uint32,uint32,uint8))" --rpc-url $RPC
```

The second call's output starts with the list of committee addresses.

### 6.8 When you get a committee seat

`activate()` mined in epoch E makes the validator active at epoch E+1.
The committee for each epoch is fixed two epochs in advance, so the earliest seat is epoch E+3, the activation epoch plus 2.
On testnet's six-hour epochs that is 12 to 18 hours after `activate()`, depending on how much of epoch E was left.
`prepare-stake.sh` prints the live numbers, for example:

```text
  The network is in epoch 581, which ends in about 2h 10m.
  activate() mined now: active at epoch 582, earliest seat at epoch 584.
```

Selection is random only when there are more eligible validators than seats.
Between seats an Active validator reports `Observer`, which is normal.

### 6.9 Status values

| Status | Name | What it means | Your next step |
|---|---|---|---|
| (call reverts) | No record | No ConsensusNFT for this address. | Finish Association approval. |
| 0 | Undefined | NFT minted, not staked. | Run `prepare-stake.sh`, then stake (6.2, 6.3). |
| 1 | Staked | Stake received. | `activate()` once synced (6.4). |
| 2 | PendingActivation | Activation queued. | Wait for the next epoch boundary. |
| 3 | Active | Eligible for committee seats. | Keep the node healthy. |
| 4 | PendingExit | `beginExit()` called. | Wait until the protocol exits you. |
| 5 | Exited | Out of the validator set. | `unstake` from the epoch after the exit epoch; `check-node.sh` says when (6.11). |
| 6 | Any | A reserved sentinel. On its own you should never see it. | Email support@telcoin.org. |
| 6 with `isRetired` true | Retired | `unstake` ran: NFT burned, stake returned. | None. This identity cannot stake again. |

`check-node.sh` prints `Status: Retired` for the last row and appends ` (Retired)` to any other status that has `isRetired` set.
The scripts treat statuses 1 to 4 as staked and everything else as not staked.

### 6.10 Stake by hand

`prepare-stake.sh` runs these steps for you.
Use them to cross-check its output, or when you cannot run it.

Confirm the ConsensusNFT on the wallet machine; `1` means the Association has minted it, `0` means approval is not complete:

```bash
cast call $REG "balanceOf(address)(uint256)" $ADDR --rpc-url $RPC
```

<a name="64-export-the-stake-calldata-on-the-node"></a>
Export the stake calldata on the node.
The keytool reads only `node-info.yaml`, but it still wants a passphrase source, so pass `--bls-passphrase-source no-passphrase`; `-q` keeps its log line out of the output, so you get the calldata alone.
Source and release installs (an `existing` install uses its own binary path):

```bash
sudo /opt/telcoin/telcoin-network -q --bls-passphrase-source no-passphrase \
  keytool export-staking-args --node-info /var/lib/telcoin/node-info.yaml --calldata
```

Docker installs:

```bash
IMAGE=$(sudo sed -n 's/^DOCKER_IMAGE=//p' /etc/telcoin/.node-meta)
sudo docker run --rm -v /var/lib/telcoin:/home/nonroot/data:ro "$IMAGE" \
  telcoin -q --bls-passphrase-source no-passphrase \
  keytool export-staking-args --node-info /home/nonroot/data/node-info.yaml --calldata
```

Copy the `0x...` output to the wallet machine and check that it is calldata for `stake`:

```bash
CALLDATA=0x...   # paste the output here
[ "${CALLDATA:0:10}" = "$(cast sig 'stake(bytes,(bytes))')" ] && echo "calldata OK"
```

Read the stake amount for the current stake version:

```bash
VERSION=$(cast call $REG "getCurrentStakeVersion()(uint8)" --rpc-url $RPC)
cast call $REG "stakeConfig(uint8)(uint256,uint256,uint256,uint32)" $VERSION --rpc-url $RPC
STAKE=$(cast call $REG "stakeConfig(uint8)(uint256,uint256,uint256,uint32)" $VERSION --rpc-url $RPC | awk 'NR==1 {print $1}')
```

The four values are the stake amount in wei, the minimum reward withdrawal, the issuance per epoch, and the epoch length in seconds.
`stake()` takes exactly the first value of the current epoch's stake version, so send that amount or the call reverts with `InvalidStakeAmount`.
Do not read the amount from `getCurrentStakeConfig()`: it returns the newest configuration, which takes effect only at the next epoch.
Read the amount just before you stake.
Once you have staked, the amount that applies to your validator is fixed by the stake version recorded on it (the sixth field of `getValidator`).

Then stake, and once the stake has landed and the node is synced, activate (section 6.3 covers the signing options):

```bash
cast send $REG $CALLDATA --value $STAKE --from $ADDR --ledger --rpc-url $RPC
cast send $REG "activate()" --from $ADDR --ledger --rpc-url $RPC
```

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
When the status reads Exited (5), wait until the epoch after the exit epoch (`check-node.sh` says when `unstake()` becomes eligible), then reclaim the stake:

```bash
cast send $REG "unstake(address,bool)" $ADDR false --from $ADDR --ledger --rpc-url $RPC
```

`unstake` permanently retires the validator and burns its ConsensusNFT.
Neither the address nor the BLS key can stake again, and validating again needs new keys and a new NFT.
The second argument, `acceptRewardShortfall`, stays `false`; `true` forfeits any rewards the Issuance contract cannot cover.
`unstake` also works while the status is still Staked (1), before activation.

### 6.12 What not to do

- Never regenerate keys for a staked identity, and never pass `--force` to the keytool for one. The registered BLS key would no longer match the node, and the registry never releases a registered key, not even after `unstake`.
- Do not generate new keys to change the execution address. Before you stake, re-sign with `prepare-stake.sh --rotate-address` (6.6); after you stake, the address cannot change.
- New validator keys are a new validator identity. Generate them in a new data directory, and only after talking to the Association.
- Never run the same keys on two servers at once.
- When you re-run `setup-node.sh` on a staked node, answer No to `Overwrite existing keys?`.

## 7. Automation

### 7.1 Setup without prompts

`setup-node.sh --json` runs in two phases so you can back up the keys in between.
Pass the same flags to both phases.
Keygen records the install method, the Docker image or binary path and the node flags in `.node-meta`, and finalize reads them back for any of those you leave out. `vX.Y.Z-adiri` stands for the release you install (the newest final on the releases page, or a release candidate only when you mean one):

```bash
ARGS=(--network testnet --install-method docker --release-tag vX.Y.Z-adiri
  --address 0xYOUR_EXECUTION_ADDRESS
  --external-primary /ip4/203.0.113.10/udp/49590/quic-v1
  --external-worker  /ip4/203.0.113.10/udp/49594/quic-v1
  --listener-primary /ip4/10.0.0.5/udp/49590/quic-v1
  --listener-worker  /ip4/10.0.0.5/udp/49594/quic-v1)
read -rs PASS
printf '%s\n' "$PASS" | sudo bash ~/telcoin-node-scripts/setup-node.sh --json --phase=keygen --passphrase-stdin "${ARGS[@]}"
unset PASS
# back up node-keys/ and node-info.yaml now (section 2.5)
sudo bash ~/telcoin-node-scripts/setup-node.sh --json --phase=finalize "${ARGS[@]}"
```

- `keygen` runs preflight, installs dependencies, creates the service user and generates the keys. It writes no unit and starts nothing, and it refuses to run if `node-keys/` already exists or a node unit is installed.
- `finalize` writes the configuration, creates and starts the service, and enables public RPC when you pass `--rpc-domain`. It refuses when a node unit already exists, and when a flag differs from what keygen recorded (install method, data directory, binary path); a different Docker image replaces the recorded one (below).
- On a Docker install, `finalize` first holds the image keygen recorded to the same pull rule and build-feature check as keygen's preflight, before it writes the configuration or the unit or starts the container. It does not pull the recorded image: an image removed since keygen stops it (`Could not run <image> ...`).
- To replace the recorded image, pass `--release-tag <tag>` or `--docker-image <repository>@sha256:<digest>` to `finalize` (not both; on mainnet `--release-tag` only, since a digest alone is not taken there). Finalize first runs every other input check (listeners, node flags), then takes the new image through keygen's steps: the pull rule, a release tag resolved to the digest its signed release names (on mainnet, the digest rule), the release a digest belongs to (`The registry names <image> as the image of release <tag>.`), the oldest supported release, the pull by digest and its digest check, and the build-feature check. Only then does it write `.node-meta`, in order: the old `RELEASE_TAG` removed, `DOCKER_IMAGE` and `DOCKER_IMAGE_DIGEST` written, the new `RELEASE_TAG` last when a release names the image. Any refusal on the way ends `... No container was started and .node-meta was not changed.` (or `the image was not used and .node-meta was not changed` after a digest mismatch). The install method, the data directory and the binary path cannot be replaced at finalize: a different value is refused with `... or run keygen again. Nothing was changed.`
- The passphrase comes from standard input with `--passphrase-stdin` (`printf` is a shell builtin, so the value never reaches a command line), or from `TN_BLS_PASSPHRASE` passed with `sudo --preserve-env=TN_BLS_PASSPHRASE`; giving both is an error.
- Each phase prints one JSON object per line on stdout, with `event` set to `step`, `log`, `error` or `done`. Every run ends with exactly one `{"event":"done","ok":true|false,...}`, and a failed run's `done` carries the reason in `msg`. Human-readable output goes to stderr.
- Finalize's `done` adds `operator_guide` (the URL of this runbook) and `public_rpc` (`enabled`, `domain`, `http`, `ws`).
- The inputs are checked before anything runs as root. A flag with no value, an unknown phase, network or install method, a malformed URL, an image that is not the network's repository by digest, a ref that is not a release tag of the network, and a relative `--binary-path` each stop the run with an `error` event.
- `--data-dir`, the four multiaddr flags, `--address`, `--passphrase-method`, `--service-user` and `--service-group` are checked before root too, and a `--json` keygen without `--address`, or with the zero address, stops with an error that names it.
- `--network` takes `testnet` (or `adiri`), `mainnet` or `devnet`. A mainnet install stops until the mainnet values in section 1.5 are set; only the mainnet keygen of section 2.12 runs before that.
- `--install-method` takes `source` or `release` (each with `--release-tag <tag>`; `--build-ref` is the older name), `docker` or `existing`. A Docker keygen takes `--release-tag <tag>` or `--docker-image <repository>@sha256:<digest>`; with neither it picks the newest release image (section 2.3; never a release candidate), by digest, and records it. For `existing`, `--binary-path <path>` (absolute) names the binary and, in `--json` mode, implies `existing`; without it keygen searches PATH, `/usr/local/bin`, `/opt` and `/home`, and stops when it finds none. A finalize whose keygen ran under `setup-node.sh` 1.2.1 or older has no recorded binary, so pass `--binary-path` to it.
- Node flags: `--bootstrap-peers <file>`, `--enable-state-export` and `--state-export-keep <n>` (section 2.7), and `--admission open|grace|closed` with `--trusted-nodes <file>` (section 2.9).
  Finalize reads the admission choices back from what keygen recorded, as it does the node flags.
- Other flags: `--data-dir`, `--passphrase-method credential|stdin`, `--allow-no-tpm`, `--bind-pcrs <list>`, `--log-target journal|file`, `--allow-quorum-risk` (section 2.8), `--public-ip`, `--advertised-name`, `--service-user`, `--service-group`, `--genesis-dir`, `--enable-healthcheck-monitor`, and the public RPC flags from section 5.

### 7.2 Advertised RPC URL flags

`--rpc-domain <d>` fills in all four of these, so most installs never pass them:

| Flag | Written to | Derived from `--rpc-domain <d>` |
|---|---|---|
| `--rpc-http <url>` | `node-info.yaml`, published to the network | `https://<d>/` |
| `--rpc-ws <url>` | `node-info.yaml`; needs `--rpc-http` or `--rpc-domain`, otherwise it is ignored with a warning | `wss://<d>/` |
| `--public-rpc-url <url>` | `.node-meta` `PUBLIC_RPC_URL`, for the UI and tooling only | `https://<d>` |
| `--public-ws-url <url>` | `.node-meta` `PUBLIC_WS_URL` | `wss://<d>` |

An explicit flag wins and is used as given.
`--rpc-http` and `--public-rpc-url` take an `http://` or `https://` URL, `--rpc-ws` and `--public-ws-url` a `ws://` or `wss://` one.
Setup stops on a malformed URL, and warns when a URL or `--rpc-domain` points at a private address or name (loopback, RFC 1918, `.local`, `.internal`) that wallets on the internet cannot reach.
An invalid `--public-ip` is ignored with a warning.
Derived URLs reach key generation only when the keytool supports `--rpc-http`; otherwise they are written when `rpc-enable` runs.
If an explicit URL differs from the domain, setup warns that `rpc-enable` will replace it.

### 7.3 Other scripts

| Script | Non-interactive forms |
|---|---|
| `install-caddy.sh` | `--phase=rpc-status`, `rpc-check-dns`, `rpc-enable`, `rpc-disable` and the dashboard phases `status`, `check-dns`, `enable`, `disable`, with or without `--json`. `rpc-enable` needs `--yes` (or `-y`) outside a terminal; in `--json` mode the exposure summary is a `warn` event and the run itself is the consent. The dashboard password, at least 16 bytes, comes on standard input with `--password-stdin`, or from `TN_CADDY_PASSWORD`, not both. A value flag given last is a usage error (exit 2). A successful `done` message may end with a parenthesised list of what was left undone, such as `(wss:// not answering yet)`. The worker gateway phases `gateway-status`, `gateway-check-dns`, `gateway-enable`, `gateway-disable`, `rpc-advertise` and `rpc-unadvertise` (section 4.15) take the same forms. |
| `update-node.sh` | `--json --check`, `--json --prepare --ref <release tag>`, `--json --apply --yes [--no-epoch-wait] [--allow-quorum-risk]`, `--json --discard`. `--ref` takes a release tag only. A failed apply rolls back; its `done` line carries `"ok":false` and a boolean `rolled_back` (`true` when the rollback succeeded), and `"voting":false` when a node that voted before does not vote again. A refused downgrade's `done` carries `"downgrade":true` and `storage_downgrade`. `--json --check` adds `tag_moved` and `tag_unknown` (a Docker digest whose release tag is not known; Docker compares digests). A one-way apply (section 4.2) never rolls back: its failed `done` carries `"rolled_back":false` and `"storage_migration":true`, and `--json --check` adds the same boolean, `true` when updating to `latest_ref` is one-way. A `--json --discard` after such an apply had started the new release keeps the launch files; it sends a `warn` event with the steps to go back, and its `done` carries `"storage_migration":true`. |
| `firewall-setup.sh` | `--reset`, `--json --status`, `--json --enable [--ssh-from <list\|file>] [--p2p-from <list\|file>] [--ssh-anywhere] [--p2p-anywhere] [--gateway-from <list\|file\|none>]`, `--json --port <49590/udp\|49594/udp\|43174/tcp> <on\|off>`. `--json --enable` on mainnet needs `--ssh-from` or `--ssh-anywhere`. Its `done` carries `rc` (0 done, 1 refused with nothing changed, 2 a step failed and the old rules are back, 3 the restore failed too) and `active`. `--json --status` adds `p2p_ports`, one object per P2P port with `port`, `proto`, `label` and `allowed` (`null` while `ufw` is off), `p2p_new_flow_limit` (`reason` `committee` while committee mode is on) and, last, `p2p_committee`: `enabled`, `persistent`, `timer` and `reason`, then with committee mode on the tool's `loaded`, `epoch`, `allowed_v4`, `allowed_v6`, `static`, `floor`, `keys`, `dns_skipped`, `last_good`, `age_secs`, `stale`, `stale_since`, `stale_reason` and `counters`; otherwise `reason` is `off`, `unreadable`, `tool-missing` or `tool-error` (README, [P2P committee allowlist](README.md#p2p-committee-allowlist)). `--p2p-committee on\|off\|sync\|status` (section 2.10) has no `--json` form and goes alone; `on` exits 0 on, 1 refused, 2 failed and turned off again, 3 that undo did not finish; `sync` 0 fresh, 1 refused, 2 failed, 3 stale or busy; `off` 0, 1 refused, 3 partly done. |
| `edit-config.sh` | `--set <field>=<value>`, with or without `--json`, for the fields in section 4.3; `--migrate-credential`, `--reseal` (with `--allow-no-tpm`, `--bind-pcrs <list>\|none`); `--no-epoch-wait`, `--allow-quorum-risk`, `--allow-public-metrics` (not with `--json`). |
| `prepare-stake.sh` | `--json`, `--network-rpc <URL>`, and `--rotate-address <0xNEW> --yes [--no-restart]`. With `--json` it prints one JSON object at the end; the exit codes are in section 6.2. |
| `remove-node.sh` | `--json --remove observer\|validator --scope service\|data\|keys --yes [--remove-ui]`. The `--remove` value is a UI slot name, not a role; either one removes the node. |
| `migrate-node-naming.sh` | `--yes`, `--allow-quorum-risk`. |
| `setup-observability.sh` | `--json`, with the ingest token on standard input (`--token-stdin`); `--token <value>` still works but warns. |
| `setup-alerts.sh` | `--json` with exactly one of `--status`, `--enable`, `--test`, `--refresh`, `--disable` (two or none are refused); without `--json` each action prints plain text, and with no action the menu opens. `--enable` takes its targets from one of `--targets-stdin` (one `<provider> <url>` per line), `TN_ALERT_TARGETS` (the same lines) or `--target <provider>=<url>` (repeatable; warns), plus `--interval`, `--stall-after`, `--inactive-after`, `--label` and `--allow-http`; `--refresh` takes `--interval`, `--stall-after`, `--inactive-after` and `--label` too, and on a node whose alerts are on either action replaces the values it is given (section 4.14). Every `done` with `ok:true` carries `applied` and `network`. `applied` holds `alerts:enabled`, `alerts:targets-changed`, `alerts:refreshed`, `alerts:tested` or `alerts:disabled`; `alerts:targets-changed` then `alerts:refreshed` when one run changed the targets and the settings; and nothing for a status or for a refresh with the alerts off, which adds no `interval` either. An enable or a test adds `node_status`, `node_reason` and `targets` (one object per target with `n`, `provider`, `host`, `result` and `code`, plus `why` for a failed push), and an enable or a refresh adds `interval`. `--status` takes no lock and needs no root; it carries `enabled` (`true`, `pending` or `false`, or `null` when it cannot read `.node-meta`, as without root), `timer` (`active`, `inactive` or `absent`), `last_run`, `last_status` and `last_reason` (`null` without root), `runner_version`, `issues` and `targets`. Exit status: 0 done; 1 nothing changed, `.node-meta` included: a refusal, an enable whose test heartbeat no target accepted, or a test that no target accepted or that recorded no run; 2 a library gap; 3 a step failed after something changed, such as a disable that left the targets file. An unknown argument is refused. |
| `setup-gateway.sh` | `--enable`, `--status`, `--refresh` or `--remove`, exactly one, with or without `--json` (events on standard output and one `done` line). `--enable` and `--remove` need `--yes` outside a terminal; `--json` never asks. Exit 0 done, 1 refused or put back, 2 libraries older than the script, 3 a step failed after something changed (section 4.15). |
| `check-node.sh` | `--audit` (section 1.2). |

The status and DNS-check phases and `update-node.sh --json --check` print a single JSON object instead of an event stream.
`TN_ASSUME_YES=true` answers yes to the scripts' yes/no prompts, destructive ones included, such as `remove-node.sh`'s `Remove chain data?`; deleting the keys still needs the typed `DELETE`.
A `.node-meta` with Windows (CRLF) line endings reads correctly, and a script that changes a key writes the file back with LF endings.
`check-node.sh` has no JSON mode and always exits 0 (except `--audit`), so parse its verdict line.

`update-node.sh`, `edit-config.sh`, `install-caddy.sh` (`rpc-enable`, `rpc-disable`), `setup-observability.sh`, `migrate-node-naming.sh` and `prepare-stake.sh --rotate-address` hold the restart of a node that votes in the current committee while the epoch boundary is close (section 4.2).
In `--json` runs the wait reports as `step`, `log` and `warn` events.
These environment variables tune it; pass them through `sudo`, as in `sudo TN_SKIP_EPOCH_WAIT=1 bash ...`:

| Variable | Default | Meaning |
|---|---|---|
| `TN_SKIP_EPOCH_WAIT` | unset | `1` skips the wait. |
| `TN_EPOCH_MARGIN` | epoch length / 72, held to 300-900 (300 on mainnet and testnet) | Seconds before the boundary inside which a restart waits. A whole number you set is used as given. In the blind wait (below the table) it is derived from the epoch length this release knows for the network: 300 on mainnet and testnet, and 300 where none is known. |
| `TN_EPOCH_SETTLE` | epoch length / 240, held to 90-300 (90 on mainnet and testnet) | Seconds to wait after the epoch changes. A whole number you set is used as given. In the blind wait it is derived the same way: 90. |
| `TN_EPOCH_JITTER_MAX` | 30 | Then a random pause of up to this many seconds, so nodes that waited for the same boundary do not restart together. `0` turns it off. The committee check runs again after the wait. |
| `TN_EPOCH_WAIT_MAX` | 1800 | Cap on the whole wait, settling included. `0` turns the wait off. A cap you set is kept as set: when it is shorter than margin + settle + two polls (420 seconds on mainnet and testnet), the script warns that the restart may land before the epoch has settled and suggests a larger cap or `TN_SKIP_EPOCH_WAIT=1`. |
| `TN_EPOCH_POLL` | 15 | Seconds between progress lines, held between 5 and 20. |

The epoch length comes with the boundary, from the node or from the network's public RPC.
When neither answers for a staked node whose mode cannot be read, the restart waits blind: `TN_EPOCH_MARGIN` + `TN_EPOCH_SETTLE` seconds, at most `TN_EPOCH_WAIT_MAX`.
Unless you set them, both derive from the epoch length this release knows for the network (6 hours on mainnet and testnet, so 300 + 90), and are 300 + 90 on a network without one (devnet).
The warning ends with where each value came from, for example `Margin 300s and settle 90s (network default: epoch 21600 s).`
A node that votes in the committee but whose epoch answer cannot be read restarts without a wait.

## 8. Legacy installs

Older versions of these scripts installed role-named units, `telcoin-observer` or `telcoin-validator`, with per-role directories such as `/etc/telcoin/observer` and `/var/lib/telcoin/observer`.
Every script still finds and manages those installs.
To move one to the unified `telcoin` layout:

```bash
sudo bash ~/telcoin-node-scripts/migrate-node-naming.sh
```

It takes the update lock after you confirm, runs the committee quorum check (section 4.11) and waits for the epoch boundary on a committee node, then stops the node, moves the directories, writes the `telcoin` unit and the start script `/usr/local/libexec/telcoin/tn-start` (`tn-start-docker` on Docker), removes the old `NODE_TYPE` line from `.node-meta`, opens UDP 49590 and 49594 in `ufw`, and restarts the node.
`--allow-quorum-risk` (or `TN_ALLOW_QUORUM_RISK=1`) overrides a refusal of the quorum check.
The keys stay as they are, and a custom data mount stays in place.
It strips `--observer` and `--instance` from the launch command, so RPC moves to the default ports 8545 and 8546 (an observer that ran with `--instance` was on other ports, such as 8541 and 8554).
If that node serves public RPC, run `install-caddy.sh --phase=rpc-enable --rpc-domain <domain>` again afterwards so Caddy points at the new ports; until then the public endpoint returns 502.
If any step fails before the new unit runs and answers on RPC, the script restores the old install and restarts it without waiting; the old unit and wrapper are removed only after that check.
Ctrl-C, SIGTERM or SIGHUP behave the same way: before the verified start the run rolls back, after it the new layout stays.
A legacy unit that holds the passphrase is handled in the same run: the passphrase moves to the encrypted credential (or, below systemd 250 on testnet, the root-only file) and every copy of it is shredded afterwards.
If the legacy unit starts the node itself, with no start wrapper, run `sudo bash ~/telcoin-node-scripts/edit-config.sh --migrate-credential` first (section 4.8), which gives it the current start script, and migrate after that.
A passphrase sealed with the old TPM method is refused with the same pointer.
`--yes` skips the confirmation prompt.
Its backups are root-only copies in `/var/backups/telcoin`.

If you keep a legacy layout, still get rid of `--observer` before you move to `v0.16.0-adiri`, which refuses to start with it: `update-node.sh` removes it when it updates to `v0.15.0-adiri` or later, and `check-node.sh` warns while the launch file still carries it.
`setup-observer.sh` and `setup-validator.sh` are deprecated shims that forward to `setup-node.sh`.

## 9. Troubleshooting

Start with `sudo bash ~/telcoin-node-scripts/check-node.sh` and `journalctl -u telcoin -n 200`.

| Symptom | Cause | Fix |
|---|---|---|
| The node will not start after an update; the log shows `unexpected argument '--observer'` | The launch file still passes `--observer`, which `v0.16.0-adiri` and later reject. | `bash ~/telcoin-node-scripts/update-scripts.sh`, then `sudo bash ~/telcoin-node-scripts/update-node.sh`. Or delete the `--observer` token from the launch file the `check-node.sh` warning names: `/usr/local/libexec/telcoin/tn-start` (`tn-start-docker` on Docker), or on a legacy install `/opt/telcoin/start-telcoin-observer.sh` or `start-telcoin-validator.sh`. A node that starts from its unit moves with `edit-config.sh --migrate-credential`, which drops the flag (section 4.8). Then run `sudo systemctl daemon-reload` and restart the unit: `telcoin`, or `telcoin-observer` or `telcoin-validator` on a legacy install. |
| `check-node.sh` warns `Launch file ... still passes --observer` | Same flag, caught before an update. | Same fix, before you update. |
| `check-node.sh` prints `note: --observer is ignored; the role is decided on-chain each epoch` | Role flags are retired; `update-node.sh` and `edit-config.sh` ignore them too. | Drop `--observer` and `--validator` from your commands. |
| `update-node.sh` ends `... Not rolled back: the previous release cannot open the migrated data dir.` | A one-way update to `v0.16.0-adiri` or later did not pass its health check, often because the first start is still migrating the consensus store. | Watch `journalctl -u telcoin -f`. A node that is still migrating comes up without help; a node that stopped says why in the journal. To go back, restore the pre-update snapshot as section 4.2 describes. |
| Older release fails with `invalid version` (`invalid version (should be 0)` in the log) after a downgrade | `v0.16.0-adiri` or later has migrated the data dir, and older releases cannot read it. | Restore the data dir from the snapshot taken before the update (section 4.2), or run `v0.16.0-adiri` or later again. |
| `tn_nodeMode` returns `Observer` while `getValidator` shows Active | Not seated yet, or between seats. | Normal. See section 6.8. |
| `tn_nodeMode` stays at `CvvInactive` | A committee member that has not caught up. It votes again once it is within 20 rounds of the network's newest commit in the same open epoch, while the network is still committing; the log then shows `attempting to rejoin consensus`. | Treat it like a lagging node (next row). |
| `CATCHING UP` and the lag does not shrink between runs | Peers cannot reach the node, the disk is full or slow, or the node keeps restarting. | Check the node's P2P ports (section 1.3) in every firewall layer, check that the external multiaddrs in `node-info.yaml` carry the current public IP, check disk space, and look for restarts in the journal. |
| `eth_syncing` returns `false` while the node is behind | Expected on Telcoin Network. | Compare `eth_blockNumber` instead (section 3). |
| `check-node.sh` warns `In the committee for epoch <E>, but the node reports Observer: it is not taking part in consensus` | The node holds a seat in this epoch's committee but is not voting, usually because it is behind or cut off from its peers. | If the report adds `The node is at epoch <N>: let it catch up, and it joins once it reaches epoch <E>.`, wait. Otherwise look in the node log (`journalctl -u telcoin -n 200`) for why it does not join, and treat it like a lagging node (the `CATCHING UP` row). |
| `check-node.sh` reports `In the committee for epoch <E> but NOT in recent headers -- node may be running but silent` | A committee member whose headers the network does not see. | Check that the node runs, that its P2P ports are open in every firewall layer, that its external multiaddrs carry the current public IP, and that time sync is on (section 1.1). |
| `check-node.sh` reports `Workers: the network requires <N> per node (...) but node-info.yaml lists <M>` | The node has fewer workers than `WorkerConfigs.numWorkers()` requires. Workers are fixed when the keys are generated. | No script adds a worker. Email support@telcoin.org with the `check-node.sh` output before the node is due for a committee seat. |
| `eth_sendRawTransaction` (or `eth_sendRawTransactionSync`) returns error `-32000` `worker is inactive` or `worker is no longer active in this epoch; submit to an active worker` (from the next release) | The network's worker count per node went down while this node was running. The node keeps the dropped worker's RPC port open for reads but refuses transactions there. | Send transactions to the first worker's RPC, port 8545 on a default install (section 1.3). |
| `eth_sendRawTransaction` (or `eth_sendRawTransactionSync`) returns error `-32603` `validator is inactive; retry another endpoint` (from the next release) | The node is a committee member that is catching up (`tn_nodeMode` reports `CvvInactive`). It refuses new transactions until it votes again, and the health endpoint's `/health/workers` reports it as not accepting them. | Send transactions to another node until `tn_nodeMode` reports `CvvActive`; the node takes them again as soon as it rejoins, without a restart. If it stays `CvvInactive`, see the `CvvInactive` row. |
| `check-node.sh` warns `<rpc> serves chain <X> (...), not chain <Y> (...) -- skipping the network comparison` | The comparison RPC serves another chain than the node's. Today `https://rpc.telcoin.network` serves the testnet (mainnet has not launched). | Not a node problem. Pass `--network-rpc <URL>` with an RPC for the node's chain (section 1.5). |
| `check-node.sh` warns `VALIDATOR_ADDRESS in .node-meta (...) is not the node's execution address (...); the on-chain status report is for the .node-meta address` | `.node-meta` and the running node name different addresses: a rotation with `--no-restart` that the node has not picked up yet, or a hand edit. | Follow the line under the warning: if you rotated with `--no-restart` (or `node-info.yaml` already has the `.node-meta` address), restart the node; otherwise set `VALIDATOR_ADDRESS` in `/etc/telcoin/.node-meta` to the address it names. |
| Preflight prints `[WARN] <role>: below minimum` | The server is under that role's minimum for the network you chose (section 1.1). | A warning only. The check counts physical cores, so a cloud instance with hyperthreads has half as many as its vCPUs: an 8 vCPU instance meets the testnet validator minimum, 3 cores (6 vCPU), but not the mainnet one, 8 cores (16 vCPU). |
| `systemd <version> is too old: the node needs 247 or later ...`, or `systemd <version> is below the mainnet floor (255, Ubuntu 24.04 or later; ...) ...` | The OS is too old for the network. | Testnet and devnet: move to Ubuntu 22.04+, Debian 12+ or RHEL 9+. Mainnet: install fresh on Ubuntu 26.04 (or 24.04). |
| `CVE-2026-31431 (Copy Fail) -- setup cannot continue` | The `algif_aead` module is not blocked, or is still loaded. | Apply the mitigation from https://copy.fail, unload the module or reboot, re-run setup. |
| `Port <port>/<proto> (...) is already in use.` | Another process holds the port. | Find it with `sudo ss -lunp` (UDP) or `sudo ss -ltnp` (TCP); stop it or choose another port. |
| `lib/common.sh <version> is older than this <script>: run update-scripts.sh and try again.` | The shared library is older than the script that needs it. | `bash ~/telcoin-node-scripts/update-scripts.sh`, then run the script again. |
| `--bootstrap-peers needs telcoin-network v0.15.0-adiri or later, and ... does not have it.` (setup), or `the installed release has no --bootstrap-peers; update the node first` (edit-config) | The node release lacks the flag. The same messages name `--enable-state-export` (`v0.13.0-adiri`) and `--state-export-keep` (`v0.15.0-adiri`). | Pick a newer release, update the node (section 4.2), or leave the flag out. |
| `<file> is mode 600: other users cannot read it. ... Run chmod 644 <file> first.` | Setup and `edit-config.sh` take only a peers file that other users can read, because the installed copy is world-readable. | `chmod 644 <file>`, then run it again. |
| `the node rejects <file> as a --bootstrap-peers map (...)` | A key is not a BLS public key, or a value is not the `primary` and `workers` entries of that node's `node-info.yaml`. | Fix the map (section 2.7). |
| `line <n>: the network_address of <key>... is a DNS name (...): the node does not resolve names, so it would never dial it.` (setup, after `--trusted-nodes:` or `--bootstrap-peers:`; `edit-config.sh`), or `... is not an address the node can dial` | A trusted nodes or bootstrap peers map names a host, or another transport, where the node needs an IP address and QUIC: the node would start, keep the entry and never dial it. Nothing was written. | Put the IP address in, `/ip4/<address>/udp/<port>/quic-v1/p2p/<peer id>` as in that node's `node-info.yaml` (sections 2.7, 2.9), and run the command again. |
| `[WARN] /etc/telcoin/bootstrap-peers.yaml lacks <n> of the <m> validators of the genesis committee in .../genesis/committee.yaml (...), so it is not written to network-config as committee_peers: ...` | With an admission mode, the bootstrap peers map does not list every genesis validator (a map of hubs only, or of the other validators without this node). The node would not start during epoch 0 with it as `committee_peers`, so it was left out; the node still dials the map. | Nothing stops. To have it written, add the validators the warning names, this node included, and run `edit-config.sh --set bootstrap_peers=FILE` (section 2.9). |
| `Error: committee_peers: missing validator <key>` in `journalctl -u telcoin`, the node stopping within a second of each start | `network-config` holds a `committee_peers` map without that genesis validator, written by hand or by scripts older than this check, and the node's chain is at epoch 0. | Run `edit-config.sh --set bootstrap_peers=FILE` again (it leaves an incomplete map out), or add the validator to the map (section 2.9). |
| `bootstrap_peers needs a start wrapper: ...`, or `... move it to the current unit and start script first: sudo ./edit-config.sh --migrate-credential (nothing was changed)` | A node that starts straight from its systemd unit, holds the passphrase in the unit, or uses the old TPM method. | `sudo bash ~/telcoin-node-scripts/edit-config.sh --migrate-credential` (section 4.8). |
| `committee of <n>: <d> member(s) down; stopping this node makes ... Refused: ...`, or `could not count the committee members that are down (...)` | The committee quorum check refused the stop or restart (section 4.11). | Wait until the other members are back. For a restart the fleet coordinator has planned, run again with `--allow-quorum-risk` or `TN_ALLOW_QUORUM_RISK=1`. On mainnet, record `VALIDATOR_ADDRESS` in `.node-meta` so an unstaked node can go ahead when the committee cannot be read. |
| `... still has the old file ownership layout and must be installed fresh; it is not migrated in place.` | A mainnet host set up by older scripts. | Install it fresh on Ubuntu 26.04 or 24.04 (section 4.9). |
| `Refusing <path> ...`, or the layout move stops with a list of paths | A symlink, special file, hard-linked file or unexpected owner in the install, config or log tree. | Fix or remove the listed paths, then run the script again. Nothing beyond the directories themselves was changed. |
| `Release <tag> did not verify (see above); nothing was installed.`, or `No release signing key in .../lib/release-keys (*.asc)` | The release signature or a hash did not check, or the scripts carry no key for the release (a key added or renewed after this script release, or a lib/release-keys/ emptied by hand). | Run `update-scripts.sh` for the current keys (and `install-ui.sh --update` when you use the Node Manager UI), then try again; check the release by hand (section 4.10). Never install a release that fails. |
| `<tag> is not a testnet release tag ...`, `image refused: ...`, or `Refusing the image ...` | A branch, commit, `latest` or another repository's image. | Give a release tag (`vX.Y.Z-adiri`, or a release candidate `vX.Y.Z-adiri-rcN`, on testnet) or the network's image by digest. |
| `vX.Y.Z-rcN is not a mainnet release tag ...` | A release candidate on mainnet, which takes final releases only. | Give the final tag, `vX.Y.Z`. |
| `... is older than the running ...: downgrades are refused.` | The target release is older than the one the node runs. A release candidate counts as older than its final. | Pick a newer release. On testnet, an interactive run with `--allow-downgrade` goes ahead. |
| `No testnet release is published on GitHub yet.`, then `Taking us-docker.pkg.dev/telcoin-network/tn-public/adiri:<tag>, the newest image of the legacy repository, ...` | The testnet channel has no release on GitHub yet: `v0.16.0-adiri` has none, and the first signed release is planned as `v0.17.0-adiri`. | Nothing to fix. Until then the default image is the newest final tag of the legacy repository, by the digest the registry serves, which no signed release confirms. This fallback ends once testnet has a signed release. |
| `Cannot read the telcoin-network releases from GitHub (https://api.github.com/repos/Telcoin-Association/telcoin-network/releases), so the newest <network> release is unknown.` | The GitHub Releases API did not answer: no route to `api.github.com`, a proxy, or GitHub's limit on anonymous calls. | Check that the host reaches `https://api.github.com`, or name the release tag yourself. On testnet the default image falls back as in the row above, with a warning; mainnet never falls back. |
| `Could not read the newest image from us-docker.pkg.dev/telcoin-network/tn-public/adiri; offering v0.16.0-adiri (...)` | Testnet with no release on GitHub (or GitHub unreadable), and the legacy repository's tag list could not be read either. | Take the offered `v0.16.0-adiri` by its pinned digest, or name a release tag. |
| `The registry gave no digest for <tag> in ghcr.io/telcoin-association/tn-testnet or ...` (testnet only), or `Could not reach registry (or no parseable tags returned).` (update-node's Docker tag menu) | The image registry could not be read, or does not have the tag. ghcr.io asks for an anonymous pull token even for a public package; the scripts fetch one, and a 401, 403 or 404 there (a package that is not public, or a tag that does not exist) counts as an unreadable registry. | Check that the host reaches `https://ghcr.io` (and `https://us-docker.pkg.dev` on testnet) and that the tag is published. If ghcr.io keeps refusing a published release, report it to support@telcoin.org. |
| `Image refused: <image> was built with the features <list>, and a <network> image has <rule>, so it is not a <network> image. ...`, or `Image refused: <image> prints <n> "Build Features:" lines with --version, not one, ...` | The image's node binary was not built for the network: a testnet image on mainnet, a mainnet image on testnet, or an image that is not a release build. | Nothing was changed. Give the network's release tag, or its image by digest from the network's package. If a release names that image, report it to the node team (support@telcoin.org). |
| `Could not run <image> to read its build features (docker run exited <rc>), so it is not used and nothing was changed.` | Docker could not start a throwaway container from the pulled image, or (at `--phase=finalize`, which never pulls) the image keygen pulled is no longer there. | Check that Docker is running and holds the image (`docker image ls`), then run the step again. For finalize, pull the recorded image by its digest (the `DOCKER_IMAGE` line of `.node-meta`) with `sudo docker pull <image>`, then run finalize again; it checks the image once more. |
| `Refusing the image <image>: ... No container was started; to replace it, run finalize again with ...` (`setup-node.sh --json --phase=finalize`) | The image keygen recorded in `.node-meta` is not one a new pull for the network takes, or its build features are not the network's. Keygen checks the same rules, so `.node-meta` was changed after it, or keygen ran with older scripts. | Run finalize again with the same flags plus the way out the message names: `--release-tag <tag>` on mainnet; `--docker-image <repository>@sha256:<digest>` or `--release-tag <tag>` on testnet; `--docker-image` on devnet. Finalize checks and pulls the new image, and records it in `.node-meta` only when every check passes. |
| `Refusing the image <image> given with --docker-image (see above). ...`, `Refusing the image of release <tag> given with --release-tag (see above). No container was started and .node-meta was not changed.`, `Failed to pull Docker image: <image>. ...` or `Docker does not hold <image> under that digest after the pull (digest mismatch); ...` (finalize with `--docker-image` or `--release-tag`) | The replacement is not the network's image by digest or release (on mainnet a digest alone is not taken), is older than the oldest supported release, or could not be pulled by its digest. | Nothing was recorded. Give a release tag of the network, or its image by digest from its package, check that the host reaches the registry, and run finalize again. |
| `Image refused: <image> did not finish --version within 60 seconds (docker run exited <rc> under timeout), ...; docker rm -f <name> was run to remove its container.` | The image's `--version` hung or Docker was too slow; the check removed the container it left. | Check that Docker is running (`docker ps`), then run the step again. If a release names the image, report it to support@telcoin.org. |
| `The input ended at the Docker image prompt, so no usable image was given and the Docker install stops. Nothing was pulled and no container was started.` | Setup read the end of its input at the Docker image prompt with nothing typed (standard input closed or piped), so no image was chosen; only Enter takes the default, and a last line typed without a newline still counts. | Run setup in a terminal and answer the prompt, or pass `--release-tag` or `--docker-image`. |
| `Image refused: <image>. No release was ever published to ghcr.io/telcoin-association/telcoin-network, so no image is pulled from it; ...` | The image names the old single package, which never held a release. | Give the release tag, or an image by digest from the network's package (`tn-mainnet`, `tn-testnet`; on devnet the legacy repository or `tn-dev`). |
| `Release <tag>: IMAGE_DIGEST names <image>, but a <network> release image is <repository>@sha256:<digest> from ... The release is refused and nothing was pulled; report it to the node team.` | The signed release names an image outside the network's package. | Nothing was pulled. Report it to support@telcoin.org; do not take the image by hand. |
| `No mainnet release can be verified yet: these scripts pin no mainnet chain configs, so Docker installs and image changes are refused on mainnet.` | Mainnet has not launched, and these scripts carry no mainnet chain-config pins (section 1.5). | Nothing on the host was changed. Run `update-scripts.sh` once the launch script release is announced. |
| `No usable TPM2 on this host: on mainnet pass --allow-no-tpm ...` | A mainnet host without a TPM2 that systemd-creds can use. | Add a TPM (a vTPM on cloud VMs), or accept the host key alone with `--allow-no-tpm`. |
| `<launch file> has 2 node commands with --http, so it is not clear which one starts the node. ...` | A hand edit left a second node command in the launch file. | Remove or comment out the extra one, then run `edit-config.sh` again. |
| `an update is in progress (PID <N>); try again when it has finished` (`edit-config.sh`, `install-caddy.sh`), `Another update is already running (PID <N>).` (`update-node.sh`), or `Refused: an update is in progress ...` (`prepare-stake.sh --rotate-address`) | Another script, usually `update-node.sh`, holds the update lock `/run/telcoin/update.lock`. | Wait for it to finish, then run it again. `install-caddy.sh` says what it had already done; after `rpc-disable` the site is gone and `node-info.yaml` still advertises it until the re-run. |
| `Cannot tell which network this node runs: .node-meta has no NETWORK. Chain configs unchanged.` | The install predates the `NETWORK` line. | Add `NETWORK=testnet` to `/etc/telcoin/.node-meta`, then refresh again. |
| `The testnet chain configs are not the pinned ones (see above); nothing was copied.` (setup in scripts-v2.1.0) | Setup in scripts-v2.1.0 takes the chain configs from telcoin-network's default branch, and on `main` `committee.yaml` no longer matches the testnet pins. Setup stopped at step 4 of 8, before any key was made. | Once `scripts-v2.2.0` is out, run `bash ~/telcoin-node-scripts/update-scripts.sh`, then run setup again: those scripts read the files at the pinned tag. Until then, or on a host that stays on scripts-v2.1.0, run setup with `--genesis-dir <dir>`, a directory that holds `genesis.yaml`, `committee.yaml` and `parameters.yaml` as they are at `v0.16.0-adiri` (`https://raw.githubusercontent.com/Telcoin-Association/telcoin-network/v0.16.0-adiri/chain-configs/testnet/<file>`). |
| `The testnet chain configs were refused (see above); nothing was copied.` or `Could not get the testnet chain configs (see above).` (setup, step 4 of 8) | Setup could not put the pinned chain configs in `/etc/telcoin/chain-configs/testnet/`. The warning above the line names the cause; the rows below cover the common ones. No key was made. | Fix the cause the warning names, then run setup again. |
| `Could not fetch v0.16.0-adiri from origin (<git's reason>); reading the testnet chain configs from the local copy of v0.16.0-adiri.` | The checkout could not fetch the tag from GitHub, for the reason in brackets, so the files are read from the copy of the tag it already holds (an earlier fetch, or its own tag). They are checked against the pins before they are installed. | Nothing to fix for this run. If it shows on every run, check that the host reaches `https://github.com`. |
| `Could not fetch tag v0.16.0-adiri from origin (<git's reason>), and the checkout does not have it.` | The fetch failed, and the checkout holds no copy of the tag. | Let the host reach `https://github.com` and run again, or run setup with `--genesis-dir <dir>`, a directory that holds the three files of the tag. |
| `/opt/telcoin-source must be a directory owned by root (not a symlink); nothing was fetched.` | The checkout belongs to another account, or `/opt/telcoin-source` is a symlink. The scripts run git as root only in a checkout that root owns. | Move it aside (`sudo mv /opt/telcoin-source /opt/telcoin-source.old`) and run again; you are then offered a clone at the tag. |
| `/opt/telcoin-source exists but is not a git checkout; move it aside first.` | Something other than a checkout or an empty directory is at that path, so the scripts do not clone into it. | `sudo mv /opt/telcoin-source /opt/telcoin-source.old`, then run again. |
| `<dir> must be a directory, not a symlink or a file; nothing was installed. Remove it and run again.` (`<dir>` is `/etc/telcoin/chain-configs` or `/etc/telcoin/chain-configs/<network>`) | That path is a symlink or a file, so nothing is installed or read through it. | Remove it, then run again: the install makes both directories root-owned. |
| `/etc/telcoin/chain-configs/<network>/<file> is a symlink or not a regular file; nothing was installed. Remove it and run again.` | An entry in the way: `genesis.yaml`, `committee.yaml` or `parameters.yaml` there is a symlink, a directory or another entry that no install can replace. | Remove that entry, then run again. |
| `Reinstalled the <network> chain configs in /etc/telcoin/chain-configs/<network> root-owned, directories 0755 and files 0644: their owner or modes were not the ones the install sets.` | The directory held the pinned files with another owner or other modes, for example copied in by hand or under a restrictive umask. They were checked and installed again from where they were, with no git and no network. | Nothing to fix. |
| `Invalid ref "<ref>": a ref cannot start with "-".` | `update-node.sh` refuses a ref that git or docker would read as an option. | Use a release tag. |
| `<domain> already serves the Node Manager dashboard -- the dashboard and the public RPC endpoint need DIFFERENT hostnames` | RPC and dashboard on one name. | Create `dashboard.<domain>` in DNS, then add `--move-dashboard-to dashboard.<domain>` to `rpc-enable`. |
| `rpc-check-dns` fails, or setup says `Public RPC not enabled yet` | The A record is missing, not propagated, or points at the outbound IP of a NAT host. | Fix the record, pass `--public-ip <inbound-ip>` behind NAT, then re-run `rpc-enable`. |
| The certificate is not issued, or Let's Encrypt reports a rate limit | DNS or ports 80/443 were wrong when Caddy asked. | Fix DNS and the ports first, then wait out the rate limit; repeated attempts extend it. |
| `port 80 is in use by 'apache2'` (or 443, or nginx) | Another web server holds the ports Caddy needs. | `sudo systemctl disable --now apache2` (or nginx), or run `sudo bash ~/telcoin-node-scripts/install-caddy.sh` and let it guide you. |
| `Caddy <version> is installed, and this script needs 2.8.0 or newer` | The installed Caddy is too old for the site `install-caddy.sh` writes. | Install the current release from Caddy's apt repository, as the message says, then run it again. |
| `public RPC: the Caddy tn-rpc block predates block v2 (...)`, or a WebSocket client behind a proxy gets HTTP 405 | The site was written by an `install-caddy.sh` older than 1.4.0. | Run `rpc-enable` again with the same hostname (section 5.4). |
| `public RPC: --http.api on the node command names <modules>; ...` (or `--ws.api`) | The node serves `debug`, `trace` or `admin` methods, and Caddy passes them to anyone. | Remove them from the launch file and restart the node. |
| `public RPC: unknown (.node-meta not readable — run with sudo)` | `check-node.sh` ran without root. | Run it with `sudo`. |
| `wss://<domain>/` returns 502 | Nothing listens on the WebSocket port 8546 yet. | Wait if the node is still starting. Otherwise check `install-caddy.sh --phase=rpc-status`; after `migrate-node-naming.sh`, re-run `rpc-enable`. |
| `firewall-setup.sh` stops right after `Firewall is active` in `1) View current firewall status` | A bug in `firewall-setup.sh` before 1.6.0. | `bash ~/telcoin-node-scripts/update-scripts.sh`. |
| `P2P committee mode was not turned on: <reason>. Nothing was changed.` | The node's snapshot is not authoritative yet (often right after a restart), its release lacks `tn_admissionSnapshot`, or the snapshot lists no address beyond the floor; the reason says which. A tool that cannot be installed says `tn-p2p-allow-sync <tag> is not installed` instead. | Section 2.10, "What `on` refuses, and why". |
| A committee peer cannot connect after `--p2p-committee on`, and `tn_drop_p2p_unlisted` rises in `--p2p-committee status` | The peer sends from an address its record does not carry (NAT, multi-homing, IPv6 temporary addresses), or the allowlist is stale. | Run `check-node.sh`; add the peer's source to `P2P_ALLOW_FROM` with `--enable --p2p-from` (section 2.10); `--p2p-committee off` is the kill switch, which opens the P2P ports to every source. |
| `check-node.sh` warns or fails on a `P2P committee` line | The allowlist is missing, stale, behind the committee or out of step with the node's config. | The table in section 2.10, "What `check-node.sh` reports". |
| The node cannot decrypt its BLS key at start | The stored passphrase is not the one the keys were generated with. | Store the correct one with `edit-config.sh` option 5, `1) Change the stored passphrase`; it never re-encrypts the keys. |
| The node does not start after a firmware, Secure Boot or TPM change; systemd cannot decrypt `bls-passphrase.cred` | The credential is bound to the TPM (and to PCRs with `--bind-pcrs`), and the state changed or the TPM was reset. | `sudo bash ~/telcoin-node-scripts/edit-config.sh --reseal` after a PCR change. After a TPM reset or a move to another host, store the passphrase you kept offline again with option 5. |
| `prepare-stake.sh` ends `Not ready: 0x... is not whitelisted.` | The address holds no ConsensusNFT yet. | Send the address to the Association (support@telcoin.org) and run the script again once governance has minted the NFT. |
| `prepare-stake.sh` ends `Not ready: 0x... is short of TEL.` | The balance is below the stake plus gas. | Send at least the amount the line above it names, then run it again. |
| `prepare-stake.sh` stops with `<rpc> serves chain <X> (...), not chain <Y> (...)` | The network RPC serves another chain than the node's. | Pass `--network-rpc <URL>` with an RPC for the node's chain (section 1.5). |
| `stake` reverts, or `prepare-stake.sh` ends `Not ready: stake() would revert with <Error>` | The registry would refuse the stake. | Look the error up in section 6.5. |
| `No BLS key passphrase. Set TN_BLS_PASSPHRASE ...` | `--rotate-address` found no passphrase source. | Use one of the sources in section 6.6. |
| `Refused: 0x... has staked (...)` | The address has staked, so its BLS key stays registered to it. | Stake from that address; it cannot change now. |
| `prepare-stake.sh --rotate-address` exits 4 with `keytool generate pop failed (exit <N>): ... node-info.yaml is back as it was (from <backup>).` | Usually a wrong passphrase. | Run it again with the passphrase the keys were generated with. |
| `prepare-stake.sh --rotate-address` ends `... To finish, run: sudo bash prepare-stake.sh --rotate-address 0x... --yes` | The rotation was interrupted after the re-signed `node-info.yaml` passed its checks, before `.node-meta` and the restart caught up. | Run that command. |
| `beginExit` reverts | The validator is not Active yet, or too few validators would remain. | Wait, then retry. |
| `unstake` reverts with `IneligibleUnstake` | The validator is neither Staked nor one epoch past Exited. | Wait for Exited plus one epoch. |
| The node will not start; the log shows `another telcoin process (pid <N>) holds the lock on this data directory` | `v0.16.0-adiri` and later lock `<data dir>/telcoin.pid`, and another node process, such as one started by hand, runs on the same data dir. | Stop the other process, then start the service. Do not delete `telcoin.pid`: the lock is released when its holder exits. |
| The node stops at every start; the journal shows `Cannot check database (epoch): epoch table <table> holds <n> row(s) this binary cannot decode, the first at key <key> with header epoch <N> ...` (from the next release), or on `v0.16.0-adiri` a panic `Invalid bytes!` | From the next release each start checks the epoch database, which holds only the epoch in progress. On that release's first start the check runs on the MDBX database it is about to copy, `consensus-db/epoch`, and the line reads `Cannot migrate the consensus DB from MDBX: Cannot check database (epoch) ...`; on a node already on tndb the line starts `Cannot check database (epoch)` and names `consensus-db/tndb/epoch`. The database holds a row this release cannot read and every retry finds the same row, so systemd restarts the node every 10 seconds and it can end in `start-limit-hit`. `v0.16.0-adiri` has no such check: a damaged row stops the node with the panic while the database opens, with the same restarts. | On the next release's first start (the line follows `Cannot migrate the consensus DB from MDBX:` and names `consensus-db/epoch`), stop the node (`sudo systemctl stop telcoin`) and move `/var/lib/telcoin/consensus-db/epoch` out of the data dir, for example `sudo mv /var/lib/telcoin/consensus-db/epoch /var/lib/telcoin.epoch-<N>`; keep `consensus-db/epochs` (the epoch packs) and `db` in place. That directory also held the node's guards against voting or proposing twice in epoch `<N>`, so start the node again only once the network has closed that epoch (compare `<N>` with the network's current epoch, section 3). On a node already on tndb (the line names `consensus-db/tndb/epoch`, and `consensus-db/tndb/mdbx-migrated` exists), do not remove `consensus-db/tndb/epoch`, although the message says to: the next start refuses to open an empty environment beside the migration marker (`Cannot open database (tndb): ... refusing to open it empty`). Email support@telcoin.org with the journal lines instead. On `v0.16.0-adiri`, email support@telcoin.org with the journal lines, the panic included. A node with state export on can instead be restored into a fresh data dir with `db load-state`. |
| `systemctl status telcoin` shows `start-limit-hit` | Five failed starts within 60 seconds. | Fix the cause from the journal (for `Cannot check database (epoch)` or `Invalid bytes!`, see the row above), then `sudo systemctl reset-failed telcoin && sudo systemctl start telcoin`. |
| After a restart near an epoch boundary the log shows `previous epoch record missing on restart (killed at its boundary); re-deriving it locally`, `epoch record present but the consensus db tables still hold rows of an older epoch (killed between the record write and the tables clear); clearing them` or `ignoring parent certificates from another epoch` | The node was stopped while the epoch changed and repairs its epoch records as it starts. | Normal; no action. For planned restarts, keep to the epoch wait (section 4.2). |
| An `ERROR` line in the journal ending `; ending the epoch (the node stops if its stores cannot write): <error>`, or on `v0.16.0-adiri` a vote line ending `; initiating node shutdown: <error>` | The node could not write a vote or certificate durably to its epoch database (`consensus-db/tndb/epoch`; `consensus-db/epoch` on `v0.16.0-adiri`) and refused to send it rather than risk signing twice. That store refuses every later write until a restart, so the node stops itself: it logs `... can no longer make writes durable; stopping the node` and exits with status 1, and systemd starts it again after 10 seconds, which reopens the stores. A disk that still fails makes it fail again, and the unit can end in `start-limit-hit`. On `v0.16.0-adiri` a failed vote write stops only the consensus tasks: the node keeps running but cannot vote again until it is restarted. | Check the data drive: free space (`df -h /var/lib/telcoin`) and I/O errors (`sudo dmesg`), and fix the cause. If systemd has given up (`start-limit-hit`), run `sudo systemctl reset-failed telcoin && sudo systemctl start telcoin`. On `v0.16.0-adiri`, restart the node yourself once the cause is fixed (`sudo systemctl restart telcoin`). If the line comes back, email support@telcoin.org with it. |

## 10. Getting help

Email support@telcoin.org for everything, validator onboarding, approval and hardware included.

Include:

- The full output of `sudo bash ~/telcoin-node-scripts/check-node.sh`.
- For staking questions, the output of `sudo bash ~/telcoin-node-scripts/prepare-stake.sh`.
- The last 200 log lines: `journalctl -u telcoin -n 200 --no-pager`.
- The node version (the release tag, and the image digest on Docker) and the script release that `update-scripts.sh` reports.
- The network (testnet or devnet) and your install method.

Never send the contents of `node-keys/`, `bls-passphrase.cred` or your BLS passphrase.

## Appendix: where this repo and the telcoin-network docs disagree

A fix for the published docs is prepared locally as the telcoin-network branch `docs/operator-docs-backlog` (13 commits) and will be opened as a pull request after `make attest`.
It brings them in line on the staking signatures, the `--force` advice, the worker port 49594, the `workers:` shape of `node-info.yaml`, the RPC-advertising guidance, the canonical endpoints, the support contact and the chain-config note.
Until it merges, the published pages still say what the third column shows.
The operating systems row is not part of that branch.

| Topic | This repo | Published telcoin-network docs | Trust |
|---|---|---|---|
| Worker P2P port | UDP 49594 by convention | UDP 49595 | This repo. Whatever you choose, the open port must match the worker multiaddr in `node-info.yaml`. |
| `stake` / `unstake` | `stake(bytes,(bytes))` with the amount from `stakeConfig(getCurrentStakeVersion())`, and `unstake(address,bool)` | `stake(bytes,(bytes,bytes))` with the amount from `getCurrentStakeConfig()`, and `unstake(address)` | The deployed contracts, which match this runbook (section 6.10). |
| Staking errors | `InvalidTokenId` means no ConsensusNFT; `InvalidProofOfPossession` means re-sign the proof of possession (section 6.6); `DuplicateBLSPubkey` means the key is already staked from another address (section 6.5) | `RequiresConsensusNFT` for a missing NFT, and new keys for the other two (with `--force` for `DuplicateBLSPubkey`) | This repo. The registry never releases a registered BLS key, so new keys are a new validator identity. |
| `node-info.yaml` workers | `p2p_info.workers:`, a list, which `v0.15.0-adiri` and later write; the scripts also read the older single `worker:` map | `p2p_info.worker:`, one map, in the CLI README | Your node's own file. These scripts handle both shapes. |
| RPC exposure | Any node can serve public RPC through Caddy and advertise it, and the committee's advertised URLs are where other nodes forward transactions. | Keep validator RPC off the public internet; serve the public from observers. | Both hold: a validator must advertise a reachable URL to receive forwarded transactions, so choose deliberately and protect it. Section 5 keeps reth on loopback behind a TLS proxy. |
| Chain configs | The files in telcoin-network's `chain-configs/testnet/` at the pinned tag, `v0.16.0-adiri`, are the live Adiri genesis, and setup installs them from that tag. On `main`, `committee.yaml` no longer matches the testnet pins. | The `chain-configs` README calls them placeholders, not the actual network configs. | This repo for testnet. Do not edit those files; the mainnet ones are placeholders until launch. |
| Operating systems | Ubuntu 26.04 recommended. Mainnet: Ubuntu 24.04 or later (systemd 255+). Testnet and devnet: systemd 247+, so Ubuntu 22.04+, Debian 12+, RHEL 9+ | Debian 11+, Ubuntu 20.04+, RHEL 8 | This repo for `setup-node.sh`; older systems fail its systemd check. |
| Contact | support@telcoin.org for everything | Two addresses, used for different things on different pages | Section 10. |
