# Telcoin Network Node Setup Scripts

Automated setup scripts for deploying **Validator** and **Observer** nodes on the Telcoin Network. Built for MNO operators — interactive, guided, and validated at every step.

---

## What's Included

| File | Purpose |
|---|---|
| `install.sh` | One-command installer for fresh machines |
| `setup-observer.sh` | Full guided setup for an observer node |
| `setup-validator.sh` | Full guided setup for a validator node |
| `check-node.sh` | Health check for any running node |
| `edit-config.sh` | Edit the configuration of a running node |
| `firewall-setup.sh` | Interactive firewall management and hardening |
| `remove-node.sh` | Safely remove a node installation |
| `update-node.sh` | Update a running node to a newer version (source build or Docker image), with a prepare/apply two-phase workflow and one-keystroke rollback |
| `update-scripts.sh` | Check for and download script updates from GitHub |
| `lib/common.sh` | Shared functions used by the above scripts (not run directly) |

---

## Node Types

### Observer Node
An observer node syncs the full chain state and serves JSON-RPC queries but does **not** participate in block consensus. It requires no approval from the Telcoin Association.

Best for: developers, exchanges, wallets, dApps, block explorers, or anyone needing a private RPC endpoint.

- RPC port: **8541** (instance 5, default)
- P2P ports: **49590** (primary) and **49594** (worker) — UDP/QUIC, outbound only
- Metrics port: **9000**
- No firewall or router port forwarding required

### Validator Node
A validator node participates in Narwhal/Bullshark consensus, proposes and signs blocks, and earns TEL rewards. Validator nodes may only be operated by GSMA-approved MNOs with prior approval from the Telcoin Association.

- RPC port: **8545** (instance 1, default)
- P2P ports: **49590** (primary) and **49594** (worker) — UDP/QUIC
- Metrics port: **9000**
- Requires inbound UDP access on ports 49590 and 49594

---

## Requirements

### Validator Node Hardware

> Validators must be GSMA-approved MNOs. Submit hardware specifications to grant@telcoin.org for approval **before** installation.

| Component | Minimum | Recommended |
|---|---|---|
| CPU | 16 cores / 32 threads, x86-64 | 32 cores, higher clock speed |
| CPU Benchmark | 4000+ PassMark Single Thread | — |
| RAM | 128GB DDR4/DDR5 ECC RDIMM | 128GB+ highest MT/s |
| Storage | 4TB TLC NVMe SSD | 7.5TB TLC NVMe SSD |
| Network | 1Gbps sustained, 1GbE interface | 10GbE interface |

### Observer Node Hardware

| Component | Minimum | Recommended |
|---|---|---|
| CPU | 8 cores / 16 threads, x86/x64/ARM64 | Higher clock speed over core count |
| RAM | 16GB DDR4 ECC | 32GB DDR4 ECC |
| Storage | 500GB TLC NVMe SSD | 2TB TLC NVMe SSD (expandable) |
| Network | 24Mbps+ stable | — |

> Storage note: TLC NVMe drives are specifically required over QLC. TLC supports 1,000-3,000 P/E cycles vs 100-1,000 for QLC, making TLC significantly more durable for continuous blockchain write operations.

### Supported Operating Systems

- Ubuntu 22.04+ LTS (minimum -- required for systemd 247+)
- Debian 12+
- Red Hat Enterprise Linux (RHEL) 8+
- Kernel version 3.10+ minimum
- macOS Sequoia 15+ (observer nodes only)

### Software
The scripts will install or check for everything needed. You do not need to install anything manually beforehand.

### For Validators Only
- GSMA MNO status — only GSMA-approved MNOs may operate validator nodes
- Hardware approval from the Telcoin Association — email grant@telcoin.org before purchasing equipment
- Prior governance approval from the Telcoin Association
- A registered Ethereum address for receiving TEL rewards

---

## Quick Start

All scripts are interactive and guide you through each step. Work through these in order on a fresh Linux machine:

**1. Install the scripts**

One-liner with `curl`:
```bash
curl -fsSL https://raw.githubusercontent.com/Telcoin-Association/tn-node-deployment/main/install.sh | bash
```

Or with `wget`:
```bash
wget -qO- https://raw.githubusercontent.com/Telcoin-Association/tn-node-deployment/main/install.sh | bash
```

Or clone the repo directly:
```bash
git clone https://github.com/Telcoin-Association/tn-node-deployment.git ~/telcoin-node-scripts
chmod +x ~/telcoin-node-scripts/*.sh
```

**2. Run the setup for your node type**
```bash
# Observer node
sudo bash ~/telcoin-node-scripts/setup-observer.sh

# Validator node (GSMA-approved MNOs only)
sudo bash ~/telcoin-node-scripts/setup-validator.sh
```

**3. Harden the firewall (recommended)**
```bash
sudo bash ~/telcoin-node-scripts/firewall-setup.sh
```
Opens the right ports for the node type detected (SSH + Uptime Kuma on all, plus UDP 49590/49594 on validators).

**4. Check node health any time**
```bash
# Auto-detects observer or validator
bash ~/telcoin-node-scripts/check-node.sh

# Include on-chain validator status
bash ~/telcoin-node-scripts/check-node.sh --address 0xYOUR_ADDRESS
```

### Day-to-day operations

```bash
# Edit a running node's configuration (multiaddrs, ports, RPC mode, etc.)
sudo bash ~/telcoin-node-scripts/edit-config.sh

# Update the node to a new version (rebuild from source OR pull a new Docker image)
sudo bash ~/telcoin-node-scripts/update-node.sh

# Update these scripts themselves to the latest version from GitHub
bash ~/telcoin-node-scripts/update-scripts.sh

# Remove a node installation (interactive, with explicit confirmations)
sudo bash ~/telcoin-node-scripts/remove-node.sh
```

> `update-node.sh` vs `update-scripts.sh`: the first updates *the node binary or Docker image* to a new release; the second updates *these helper scripts* themselves from GitHub. Different things.

---

## What the Setup Script Does

Each script walks through numbered steps:

**Step 1: Pre-flight Checks and Install Method**
- Checks you are running as root
- Detects your Linux distribution and package manager
- Verifies hardware meets minimum requirements
- Checks internet connectivity and required ports
- Checks systemd version (247+ required -- Ubuntu 22.04+)
- Installs any missing tools (curl, git)
- Asks how to obtain the binary (build from source, Docker, or existing)
- Installs all dependencies upfront before configuration begins (Rust, build tools, Docker image pull, etc.)
- For binary/source installs, asks which passphrase protection method to use (LoadCredential or TPM/vTPM)

**Step 2: Network Selection**
- Asks which network to connect to (Adiri testnet or mainnet)

**Step 3: Node Configuration**
- Asks for port and directory configuration
- Asks for external and listener IP addresses for P2P

**Step 4: System Infrastructure**
- Creates a dedicated system user and group (default: telcoin/telcoin, customisable). The user has no login shell for security.
- Creates all required directories under /opt/telcoin, /var/lib/telcoin, /etc/telcoin, /var/log/telcoin
- Creates the reth internal log cache directory
- Verifies the binary is valid and executable

**Step 5: Key Generation**
- Asks for your Ethereum address (and multiaddrs for validators)
- Asks you to set a BLS key passphrase (entered twice to confirm, never shown on screen)
- Runs telcoin-network keytool generate observer/validator to create cryptographic keys
- Stores keys in /var/lib/telcoin/[node-type]/node-keys/ with strict permissions
- Stores passphrase in /etc/telcoin/[node-type]/bls-passphrase (mode 600)
- If TPM selected: seals passphrase to TPM chip, shows it once, prompts operator to store offline

**Step 6: Configuration**
- Copies the official chain-config files (genesis.yaml, committee.yaml, parameters.yaml) from the cloned repository

**Step 7/8: Systemd Service**
- Writes a wrapper script to /opt/telcoin/start-[type].sh that reads the passphrase securely at runtime
- Writes a systemd service file to /etc/systemd/system/telcoin-[type].service using LoadCredential
- Configures the correct network listener addresses for P2P connectivity
- Optionally starts the node immediately
- Optionally enables auto-start on server reboot

---

## System Layout

After setup, files are organised as follows. Replace `<type>` with either `observer` or `validator` depending on which node you installed.

```
/opt/telcoin/
  telcoin-network                   -- the node binary
  start-telcoin-<type>.sh           -- wrapper script (reads passphrase, starts node)

/var/lib/telcoin/
  <type>/                           -- chain data for this node
    node-keys/                      -- P2P + BLS keys (keep backed up!)
    node-info.yaml                  -- public node identity (BLS pubkey for validators)
    genesis/
      genesis.yaml                  -- chain genesis config
      committee.yaml                -- validator committee config
    parameters.yaml                 -- consensus parameters
    db/                             -- chain database (grows over time)

/etc/telcoin/
  <type>/
    bls-passphrase                  -- BLS key passphrase (mode 600, root only)
    .node-meta                      -- internal metadata used by remove/edit scripts

/var/log/telcoin/
  telcoin-<type>.log                -- node output log
  telcoin-<type>-error.log          -- node error log

/etc/systemd/system/
  telcoin-<type>.service            -- systemd unit definition

/home/telcoin/
  .cache/reth/logs/                 -- reth internal log cache

/opt/telcoin-source/                -- cloned GitHub repository
  chain-configs/                    -- official chain config files
  target/release/                   -- compiled binary location (source builds only)
```

Both node types share the same layout. The only structural difference is which subdirectory and unit file exist (`observer` vs `validator`); a server running both will have both subtrees populated.

---

## Security Design

The scripts follow Linux security best practices:

- **Dedicated service user** — the node runs as a dedicated system user (default: `telcoin`) with no login shell and no sudo access. The user and group name can be customised during setup. If the process is compromised it cannot access your other files or accounts.
- **Strict file permissions** — key files are mode 600 (readable only by owner). The node-keys directory is mode 700.
- **Passphrase never logged** — for binary/source installs the BLS passphrase is loaded via systemd `LoadCredential` into a secure temporary directory, never appearing in process listings or `systemctl show` output. For Docker installs it is passed via environment variable to the container.
- **Systemd hardening** — the service uses `NoNewPrivileges`, `PrivateTmp`, and `ProtectSystem=strict` to limit what the process can do.
- **RPC localhost only** — the RPC port defaults to 127.0.0.1 (localhost only). It is never exposed to the internet by default.
- **CVE-2026-31431 check** — the setup scripts check for the Copy Fail mitigation during preflight and will not proceed until it is applied.

### CVE-2026-31431 (Copy Fail)

A HIGH severity local privilege escalation vulnerability affecting all Linux kernels since 2017. A 732-byte Python script using only standard library modules can give any unprivileged local user a root shell — no race conditions, no kernel-specific offsets, 100% reliable.

The setup scripts detect whether the `algif_aead` kernel module is loaded or unblocked. If the mitigation has not been applied, the script stops and directs the operator to apply it before proceeding.

**Details and mitigation:** https://copy.fail

To apply the mitigation manually:
```bash
# Check current state
modprobe --showconfig | grep -q "install algif_aead /bin/false" && echo "BLOCKED" || echo "NOT BLOCKED"
grep -qE '^algif_aead ' /proc/modules && echo "LOADED" || echo "NOT LOADED"
```

See https://copy.fail for the official mitigation steps.

---

## Security

Binary and source installs use systemd `LoadCredential` by default (requires Ubuntu 22.04+ / systemd 247+). The passphrase is stored in a mode 600 file and loaded securely at runtime -- it never appears in `systemctl show` output or process listings. Docker installs pass the passphrase via the `-e` flag as before. For operators requiring even higher security, the following options are available.

### Option 1 — systemd LoadCredential (default for binary/source installs)

Built into systemd (version 247+, available on Ubuntu 22.04+). Instead of embedding the passphrase directly in the service file, systemd loads it from a file and injects it into a secure temporary directory that only the service process can access. The passphrase never appears in `systemctl show` output or process listings.

The setup scripts configure this automatically for binary and source installs.
Advantages:
- Passphrase never embedded in the service file
- Systemd manages the secure credential directory automatically
- No extra software required
- Credential is cleaned up when the service stops

### Option 2 — TPM/vTPM sealing (advanced)

Available as an option during setup for binary and source installs. The passphrase is sealed to the machine's TPM chip and can only be decrypted on that exact machine, even if someone obtains root access or copies the disk. Supported on GCP Shielded VMs (vTPM), AWS Nitro, and bare metal servers with a TPM2 chip.

The setup scripts handle sealing automatically using `tpm2-tools`. During setup you will be shown the passphrase once and prompted to store it offline before the plaintext file is deleted.

Advantages:
- Passphrase cannot be read by root or copied off the machine
- Works on GCP Shielded VMs, AWS Nitro, and bare metal TPM2
- No extra infrastructure required
- Falls back to LoadCredential file if TPM is unavailable

Disadvantages:
- Recovery requires your offline backup passphrase if the machine is rebuilt
- Not available on VMs without vTPM support

### Option 3 — HashiCorp Vault (enterprise grade)

Vault is a dedicated secrets management server. The passphrase never touches disk on the node server at all — it is fetched from Vault via an authenticated API call at startup. Vault provides a full audit log of every access and supports secret rotation without touching the server.

A wrapper script would replace the direct ExecStart:

```bash
#!/usr/bin/env bash
# /opt/telcoin/start-node.sh
export TN_BLS_PASSPHRASE=$(vault kv get -field=passphrase secret/telcoin/observer)
exec /opt/telcoin/telcoin-network node --datadir /var/lib/telcoin/observer \
    --observer --instance 5 --metrics 127.0.0.1:9000 \
    --log.stdout.format log-fmt -vvv --http
```

Advantages:
- Passphrase never stored on the node server
- Full audit trail of every secret access
- Central management across multiple nodes
- Secret rotation without touching node servers
- Enterprise access control policies

Disadvantages:
- Requires running and maintaining a separate Vault server
- Significantly more infrastructure overhead
- Overkill for a single node operator

---

## Firewall / Router Configuration

### Observer Nodes
Observer nodes do **not** require port forwarding. The node makes outbound connections to peers using UDP/QUIC on ports 49590 and 49594.

### Validator Nodes
Validators need inbound UDP access on ports 49590 and 49594.

**Linux firewall (ufw):**
```bash
sudo ufw allow 49590/udp
sudo ufw allow 49594/udp
```

**Router port forward (home/bare metal only):**
Forward UDP ports 49590 and 49594 from WAN to your server's local IP address. Cloud servers handle this via their network configuration.

The RPC port (8541/8545) should **not** be opened to the internet unless you are specifically running a public RPC endpoint with a reverse proxy in front of it.

### Health Monitoring (Uptime Kuma)
**Required for all nodes (observer and validator).** The Telcoin Association runs Uptime Kuma health monitoring against every deployed node — TCP port 43174 must be open inbound or your node will show as DOWN in monitoring.

```bash
sudo ufw allow 43174/tcp
```

`firewall-setup.sh` opens this port automatically when you run option 2 ("Enable firewall with recommended defaults").

---

## Validator Onboarding Flow

Setting up a validator involves both off-chain (node setup) and on-chain (contract interaction) steps. The setup script handles the off-chain steps and guides you through what is needed on-chain.

Full staking guide: https://docs.telcoin.network/telcoin-network/staking/how-to-stake

### Full Process

**Step 1 — Generate keys and set up node (script handles this)**
Run `setup-validator.sh`. The script installs the binary, generates your BLS keys, copies chain configs, and starts the node service.

**Step 2 — Request Governance Approval (operator action)**
Submit your ECDSA validator address to the Telcoin Association for off-chain verification. You do NOT need to send your node-info.yaml — just your address. Upon approval, governance calls `mint(validatorAddress)` on the ConsensusRegistry contract.

Verify you have received your ConsensusNFT:
```bash
cast call 0x07E17e17E17e17E17e17E17E17E17e17e17E17e1 \
  "balanceOf(address)(uint256)" \
  <VALIDATOR_ADDRESS> \
  --rpc-url <RPC_URL>
```

**Step 3 — Stake your TEL (operator action)**
Once whitelisted, submit the stake transaction using your BLS public key and proof of possession from `node-info.yaml`:

```bash
# Check required stake amount first
cast call 0x07E17e17E17e17E17e17E17E17E17e17e17E17e1 \
  "getCurrentStakeConfig()" \
  --rpc-url <RPC_URL>

# Submit stake
cast send 0x07E17e17E17e17E17e17E17E17E17e17e17E17e1 \
  "stake(bytes,(bytes,bytes))" \
  <BLS_PUBKEY_COMPRESSED> \
  "(<UNCOMPRESSED_PUBKEY>,<UNCOMPRESSED_SIGNATURE>)" \
  --value <STAKE_AMOUNT> \
  --trezor \
  --rpc-url <RPC_URL>
```

**Step 4 — Sync your node**
Wait for the node to fully sync. Check sync status:
```bash
curl -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' \
  http://localhost:8545
```

**Step 5 — Activate (operator action)**
Once synced, call `activate()` to enter the activation queue:
```bash
cast send 0x07E17e17E17e17E17e17E17E17E17e17e17E17e1 \
  "activate()" \
  --trezor \
  --rpc-url <RPC_URL>
```

**Step 6 — Go active (automatic)**
At the next epoch boundary your status changes to Active and you begin participating in consensus.

### Checking Your Status

```bash
bash ~/telcoin-node-scripts/check-node.sh --address 0xYOUR_VALIDATOR_ADDRESS
```

| Status | Meaning | Next Action |
|---|---|---|
| No NFT found | Not yet whitelisted | Submit address to Telcoin Association |
| Undefined | NFT minted, not staked | Call stake() on ConsensusRegistry |
| Staked | Staked, not activated | Call activate() on ConsensusRegistry |
| PendingActivation | Activation in progress | Wait for next epoch |
| Active | Fully active in consensus | No action needed |
| PendingExit | Exiting the network | Wait for exit to complete |
| Exited | Exited | Call unstake() to reclaim TEL |

---

Run at any time after setup to verify your node is healthy:

```bash
# Auto-detects whether this server runs a validator or observer
bash ~/telcoin-node-scripts/check-node.sh

# Force a specific node type (useful if both are installed on one server)
bash ~/telcoin-node-scripts/check-node.sh --validator
bash ~/telcoin-node-scripts/check-node.sh --observer

# Include validator on-chain status (queries the ConsensusRegistry contract)
bash ~/telcoin-node-scripts/check-node.sh --address 0xYOUR_VALIDATOR_ADDRESS

# Skip the network RPC query (fully local / air-gapped diagnostics)
bash ~/telcoin-node-scripts/check-node.sh --no-network

# Custom local RPC endpoint or service name
bash ~/telcoin-node-scripts/check-node.sh --rpc http://127.0.0.1:8541 --service telcoin-observer
```

The health check verifies:
- **Systemd service status** — running, with restart-loop detection (warns if the unit has restarted more than 5 times)
- **Local RPC mode** — classified as `HEALTHY`, `SLOW` (responding but >6s), `DISABLED` (HTTP 200 but `-32601 method not found`), or `DOWN` (connection refused). Previously all four looked the same.
- **Network consensus state** — queries `https://rpc.telcoin.network` for ground truth: current block, epoch, committee size, and how fresh the latest commit is.
- **Local consensus state** — calls `tn_latestConsensusHeader` on the local node and applies the freshness contract: `block == 0` → ERROR (fully stalled), commit-timestamp age > 60s → WARN (stale), else OK. Also reports lag vs network in blocks.
- **Author presence (validator-only)** — checks whether your authority ID appears in the network's recent consensus headers. Catches the failure mode where a validator is running (systemd green, RPC up) but silent (not authoring headers). Auto-detects your authority ID from `<data-dir>/node-info.yaml` (field `primary_network_key`) or accepts an explicit `--authority-id <BASE58>` override.
- **Reputation score (validator-only)** — your own score from `sub_dag.reputation_score.scores_per_authority` alongside the committee average. Flags scores below half-average.
- **Validator on-chain status** — when `--address` is provided, calls the ConsensusRegistry contract and reports your validator state (Undefined / Staked / PendingActivation / Active / etc.).
- **Disk space** — uses the actual data directory from `/etc/telcoin/<type>/.node-meta` (falls back to `/var/lib/telcoin/<type>`), so the check reports usage on whichever mount actually holds chain data — not just the default.
- **Memory** — total / available / percent used.

### Why RPC instead of log files?

Earlier versions of `check-node.sh` grepped the node log file for fixed string markers like `peer metrics heartbeat` and `got new consensus`. That approach was fragile (any change to the node binary's log format silently broke it) and gave misleading output — for example a "P2P peers since startup" metric whose label was wrong and whose count had no time window. As of v1.1.31 the script uses `tn_latestConsensusHeader` directly, which is stable, accurate, and works whether or not the node writes a parseable log file.

The author-presence check is the most useful signal — it answers the question *"is the network actually seeing my node participate?"* using the network's own consensus headers as the source of truth. This works even when the local RPC is closed off entirely.

---

## Firewall Setup

After setting up your node, run the firewall setup script to harden your server. This script can be run at any time — both to apply changes and to view the current state of your firewall.

```bash
sudo bash ~/telcoin-node-scripts/firewall-setup.sh
```

The script is menu-driven and interactive. It never makes changes without explicit confirmation.

### What it covers

**View current status** — run this at any time to get a full overview of your firewall state, SSH configuration, open ports, and any security warnings. No changes are made.

**Enable firewall with recommended defaults** — sets default deny inbound, allow outbound, and keeps SSH accessible. Always do this before restricting SSH access.

**Manage SSH access** — disable password authentication (keys only), disable root login, change SSH port. Each option shows the current state and warns clearly before making any changes.

**Manage node ports** — automatically detects whether validator or observer is installed and applies the correct rules. Validators need UDP 49590/49594 open inbound. Observers need no inbound ports. Optionally opens port 443 for public RPC via nginx.

**Manage trusted IP whitelist** — add or remove specific IP addresses or CIDR ranges that are allowed SSH access. Shows your current session IP so you don't accidentally lock yourself out.

### Important warnings

- **Test SSH in a new terminal** before closing your current session after making any changes
- **Whitelist your IP first** before enabling default deny or restricting SSH
- **Validators only** need inbound ports 49590/49594 — observer nodes need no inbound ports at all
- Never open the RPC port (8541/8545) directly to the internet — use nginx on port 443 instead

### When to run it

Run `firewall-setup.sh` after completing node setup and before going live. For production validator nodes this is strongly recommended. For home/testing setups it is optional but good practice.

---

```bash
# Start / stop / restart
sudo systemctl start telcoin-observer
sudo systemctl stop telcoin-observer
sudo systemctl restart telcoin-observer

# View live logs
sudo tail -f /var/log/telcoin/telcoin-observer.log

# View logs via journalctl
journalctl -u telcoin-observer -f

# Enable auto-start on boot
sudo systemctl enable telcoin-observer

# Reset after too many failed restarts
sudo systemctl reset-failed telcoin-observer
```

---

## Binary Installation Options

When prompted during setup you can choose how to obtain the `telcoin-network` binary:

| Option | Description | Notes |
|---|---|---|
| Build from source | Clones the GitHub repo and compiles with `cargo build --release` | Takes 20-40 min, requires ~4GB RAM during build |
| Pre-built binary | Downloads a release binary | **Coming soon** — check [releases](https://github.com/Telcoin-Association/tn-node-deployment/releases) |
| Docker | Pulls official image from Google Artifact Registry | `us-docker.pkg.dev/telcoin-network/tn-public/adiri:VERSION` |
| Existing binary | Use a binary already on this machine | Useful if you have already compiled it |

### Docker Install Notes

When Docker is selected the script will:
- Install Docker if not already present
- Ask for the full image URL and tag (default: `us-docker.pkg.dev/telcoin-network/tn-public/adiri:v0.9.2-adiri`)
- Pull the image
- Create the host service user with UID 1101 to match the container's internal `nonroot` user
- Generate keys using the Docker image
- Create a systemd service that runs `docker run` with `--user` flag for correct volume permissions

The operator can still choose any service user name and group — UID 1101 is assigned transparently to ensure Docker volume permissions work correctly.

---

## Network Binding

During setup you will be asked how the node should listen for incoming P2P connections:

**IPv6** — recommended for cloud and data centre servers. Binds to all IPv6 interfaces (`::`) and is NAT-free, meaning no router port forward is required.

**IPv4** — for home or bare metal servers. The script will auto-detect your server's internal IP address (e.g. `10.x.x.x` on cloud, `192.168.x.x` on home networks) and ask you to confirm it. Validators will also need to forward UDP ports 49590 and 49594 on their router to this server. Observers do not need port forwarding.

**Important distinction for cloud/data centre operators:**
- **Internal IP** (e.g. `10.70.70.2`) — what the node binds its listener to. Auto-detected by the script via `hostname -I`.
- **External/Public IP** — what peers use to reach your node. Fetched automatically via `api.ipify.org` and used for validator key registration in `node-info.yaml`.

These are two different addresses on cloud servers and the script handles both correctly.

---

## Removing a Node

Use the dedicated removal script to safely remove a node installation:

```bash
sudo bash ~/telcoin-node-scripts/remove-node.sh
```

The script automatically detects what is installed (observer, validator, or both) and the install method (binary/source or Docker). It guides you through removal step by step with individual confirmations for each component.

**What it removes:**
- Systemd service (stops, disables and removes the service file)
- Docker container and optionally the image (if Docker install)
- Chain database
- Node keys and passphrase (requires typing `DELETE` to confirm -- cannot be undone)
- Binary and source code
- Log directory
- Service user and group

**Wipe chain data only** (keeps keys and config, forces resync) is also available as an option inside the removal script.

---

## Key Backup

Your node keys are stored in `/var/lib/telcoin/observer/node-keys/`. Back these up immediately after setup.

If you lose your keys you will lose your node identity and will need to re-register with the Telcoin Association (validators) or regenerate keys and restart (observers).

Store your BLS passphrase separately from the key files — in a password manager or secure offline location. If you lose the passphrase the encrypted key files are unreadable.

---

## Keeping Scripts Up to Date

Run the update script at any time to check for and download newer versions:

```bash
bash ~/telcoin-node-scripts/update-scripts.sh
```

The script checks each file individually against the latest version on GitHub and shows a status table:

```
  Script                     Local      Remote     Status
  ----------------------------------------------------------------
  setup-observer.sh          1.1.2      1.1.3      UPDATE AVAILABLE
  setup-validator.sh         1.1.2      1.1.3      UPDATE AVAILABLE
  check-node.sh              1.1.2      1.1.2      Up to date
  edit-config.sh             1.1.2      1.1.3      UPDATE AVAILABLE
  lib/common.sh              1.1.2      1.1.3      UPDATE AVAILABLE
```

If updates are available it will ask for confirmation before downloading. `lib/common.sh` is always included in any update since all scripts depend on it.

---

## Quick Reference — Common Commands

The systemd unit name is `telcoin-observer` or `telcoin-validator` depending on which you installed. Substitute `<type>` accordingly in the commands below.

### Service management

```bash
# Start / stop / restart
sudo systemctl start telcoin-<type>
sudo systemctl stop telcoin-<type>
sudo systemctl restart telcoin-<type>

# Enable / disable auto-start on boot
sudo systemctl enable telcoin-<type>
sudo systemctl disable telcoin-<type>

# Reset after too many failed restarts
sudo systemctl reset-failed telcoin-<type>
```

### Logs

```bash
# Tail the node's stdout/stderr log file
sudo tail -f /var/log/telcoin/telcoin-<type>.log

# Or via journalctl
journalctl -u telcoin-<type> -f
```

### Health and configuration

```bash
# Health check (auto-detects observer vs validator)
bash ~/telcoin-node-scripts/check-node.sh

# Health check including on-chain validator state
bash ~/telcoin-node-scripts/check-node.sh --address 0xYOUR_ADDRESS

# Interactive config editor (backs up the unit file before any change)
sudo bash ~/telcoin-node-scripts/edit-config.sh
```

### RPC queries

Replace `8541` with `8545` for a validator's default RPC port.

```bash
# eth_chainId
curl -s -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
  http://127.0.0.1:8541

# eth_blockNumber
curl -s -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://127.0.0.1:8541

# eth_syncing
curl -s -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' \
  http://127.0.0.1:8541

# tn_latestConsensusHeader -- the authoritative consensus state (use this
# rather than log-grepping for "got new consensus" entries)
curl -s -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"tn_latestConsensusHeader","params":[],"id":1}' \
  http://127.0.0.1:8541
```

### Scripts

```bash
# Update scripts to latest version
bash ~/telcoin-node-scripts/update-scripts.sh

# Remove a node
sudo bash ~/telcoin-node-scripts/remove-node.sh

# Firewall management
sudo bash ~/telcoin-node-scripts/firewall-setup.sh
```

---

## Changelog

> **Versioning note (from v1.1.48 onwards):** each script bumps `SCRIPT_VERSION`
> independently, so entries are titled `<script> vX.Y.Z`. Earlier entries used
> a flat "all scripts bumped to vX.Y.Z" convention.

### check-node v1.1.50
Demotes "Consensus tip is STALE" from WARN+HEALTH_ISSUES to info -- it's a
catching-up symptom, not a confirmed failure (completes the v1.1.49 audit).

### check-node v1.1.49
Drops the "stuck on missing epoch pack" / "Block NOT advancing -- likely STUCK"
verdicts; state-sync activity and unchanged-block windows are now info, not
errors. Consolidates §3/§5 output and trims §10 boilerplate.

### check-node v1.1.48
Adds a diagnostic that reads the node log for the "stuck on missing epoch
pack" state-sync warning and surfaces the stuck epoch + consensus height.
(Superseded by v1.1.49.)

### update-scripts v1.1.48
Replaces the `https://github.com` homepage probe with a HEAD on
`${GITHUB_RAW}/README.md` to fix false-positive "No internet connection"
errors on residential links.

### v1.1.47
check-node: network probe failure is now a hard error; adds chain-ID sanity
check; removes the unreliable eth_syncing branch; demotes §4 tip-lag warn to
info; folds data dir into the §8 disk line.

### v1.1.46
Hotfix: `ensure_chain_configs_available()` no longer reassigns the readonly
`TN_SOURCE_DIR` constant (would otherwise abort setup under `set -e`).

### v1.1.45
Hotfix: disables `set -e` in check-node.sh so helpers returning non-zero no
longer abort the report mid-run; `read_prev_block_state` always returns 0.

### v1.1.44
check-node: network execution block now comes from a direct `eth_blockNumber`
call; tracks local-block advancement between runs via a `/tmp` state file to
detect frozen execution.

### v1.1.43
check-node: EVM execution lag is now the authoritative sync signal --
consensus-tip comparison only confirms connectivity, not catch-up. Fixes
false "healthy" verdicts on nodes thousands of EVM blocks behind.

### v1.1.42
update-node.sh: Docker apply gets the hash-check parity that source got in
v1.1.41; adds 5 GB pre-flight disk check, cp exit-code check, hand-off to
check-node.sh on success.

### v1.1.41
update-node.sh: fixes silent "build complete" when nothing actually changed
-- cargo PATH under sudo, cargo exit-code check, binary hash compare before
and after `cargo build` / `cp`.

### v1.1.40
`pick_source_version` correctly identifies named feature branches (e.g.
`log_db_name`) instead of mislabelling them as "detached".

For older entries (v1.1.39 and earlier), see [CHANGELOG.md](./CHANGELOG.md).

---

## Support

For issues with the Telcoin Network protocol or chain configuration, contact the Telcoin Association development team.

For issues with these setup scripts, raise them via the appropriate Telcoin Association channels.
