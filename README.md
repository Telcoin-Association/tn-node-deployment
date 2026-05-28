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

### v1.1.43
Fixes a real accuracy bug in `check-node.sh`: it would report a node as "healthy / synced / current" while the node was thousands of execution blocks behind the network.

**Root cause**
- The consensus section compared the local node's `tn_latestConsensusHeader.number` against the network's. But that number is the latest consensus tip the node has *tracked*, not the height it has actually *processed*. A node can track a fresh tip (so the comparison shows ~0 lag) while its execution layer is far behind. This was confirmed live: the script printed `Local consensus current: block 923057 / Lag vs network: 0 blocks / All checks passed -- healthy` on a node that was simultaneously 6,042 EVM execution blocks behind.
- `eth_syncing` returns `false` on Telcoin even during consensus-layer backfill, so it reinforced the false "synced" reading rather than catching it.

**What changed**
- The **EVM execution lag** (network execution block − local execution block) is now the authoritative sync signal. If it exceeds `EVM_SYNC_THRESHOLD` (50 blocks), the node is reported as **CATCHING UP**, not healthy -- regardless of what the consensus-tip comparison or `eth_syncing` say.
- The consensus section is **relabelled** from "Local consensus current / Lag vs network" to "Consensus tip tracked / Tip vs network: matched -- tracking the network tip", with an explicit note that this confirms *connectivity* to the tip, not that execution is caught up.
- `eth_syncing: false` is now annotated: `(note: stays false during consensus backfill -- not a sync guarantee)` instead of `(synced)`.
- The final summary has a new top-priority branch: when the node is catching up, it prints `Node is CATCHING UP -- N execution blocks behind the network`, explains this is expected after a restart/update/fresh install, and tells the operator to re-run -- shrinking lag means it's recovering normally, static/growing lag means it may be stuck.
- When genuinely caught up, the summary now states the EVM lag explicitly: `node is healthy and caught up (EVM lag N)`.

**Note for future simplification**
- The cleanest long-term fix would be an RPC that returns the node's last-*processed* consensus height alongside the network target (the `last_consensus_height` / `max_consensus_height` pair currently only visible in the catch-up log lines). Worth requesting from the Telcoin team. Until then, the EVM execution lag is the best authoritative sync proxy available over RPC.

All scripts bumped to v1.1.43.

### v1.1.42
Four small `update-node.sh` follow-ups that close the remaining silent-failure gaps I identified after the v1.1.41 hotfix.

**Docker apply now has the same hash check that source got in v1.1.41**
- Hashes the unit file before the `perl -i` substitution and again after. If the hash hasn't changed, that means the old image string wasn't actually found in the unit file -- the substitution was a no-op. Surfaces a hard error, restores the backup, and aborts rather than restarting on an unchanged unit.
- Also greps for the new image string in the unit file after the edit. If it's not present (a weird perl mishap), same restore-and-abort path.

**Source: disk-space pre-flight**
- Before starting the build, checks the available space on the mount holding `/opt/telcoin-source` and refuses to start if less than 5 GB free. A clean cargo build can produce a `target/` directory several gigabytes large, and the previous behaviour was to fail mid-compile with a cryptic "no space left on device" -- now you get a clean refusal upfront with a hint to run `cargo clean`.

**Source: cp exit-code check on install**
- The `cp -p "$built" "$installed"` step now checks its exit status. A failed cp (permissions, I/O error, disk full) under `set -uo pipefail` previously left the system in an indeterminate state without a clear signal. Now the script restores the backup, attempts to start the service on the previous binary, and exits with a specific error pointing at `df -h` output for the install directory.

**Hand off to `check-node.sh` after a successful update**
- Both source and docker `apply_*_update` paths now print `Verify full health: bash ~/telcoin-node-scripts/check-node.sh` on success. The DB-map-size class of failure that one operator hit recently would have shown up immediately in `check-node.sh`'s output, and pointing them there closes the loop between "update completed" and "node is genuinely healthy."

**Note on future "installed version" upstream change**
- The Telcoin Network team is working on surfacing the installed version more directly in the binary's metadata. Once that lands, the `Build Features:` empty-field quirk and the various indirect detection paths (git describe, sha256, hash compare before/after) can be simplified to a direct version-read. Tracking but not changing anything here yet.

All scripts bumped to v1.1.42.

### v1.1.41
Hotfix for a silent-failure bug in `update-node.sh` discovered on an operator's node: the script reported "build complete" + "update applied" even though the binary on disk was unchanged. Root cause was three separate gaps that compounded.

**Fixed: cargo not found under sudo**
- `update-node.sh`'s `prepare_source_build` invoked `cargo` directly, but sudo's PATH doesn't include `~/.cargo/bin` (where rustup installs cargo). The build immediately died with `cargo: command not found`. The setup scripts (`setup-{observer,validator}.sh`) already export the right PATH and source `~/.cargo/env` -- the update script now mirrors that, looking in `${HOME}/.cargo/bin`, `/root/.cargo/bin`, and `/home/${SUDO_USER}/.cargo/bin`, and sources the matching `.cargo/env` if present. Also adds an explicit `command -v cargo` check that fails loudly with installation instructions instead of pressing on.

**Fixed: cargo exit code silently discarded**
- The build was wrapped in `(cd ...; cargo build ... | tee ...)` -- a subshell whose exit status was never checked. With `set -o pipefail` *inside* the subshell, the pipeline did fail when cargo errored, but the subshell's failure propagated nowhere because we didn't check `$?`. Rewrote using `pushd` + a direct `if ! ... | tee ...` check, which actually catches a non-zero cargo exit and prints the last 10 lines of the build log.

**Fixed: "build complete" reported when binary didn't change**
- Previous logic only checked whether the binary *file existed* after the build, not whether anything changed. Since the old build from the original install is sitting on disk, `[[ -f $built ]]` always passed -- even when cargo did nothing at all. Now hashes the binary before and after the build; if the hashes are identical, prints a clear warning, names the hashes, and asks the operator to confirm before proceeding.

**Fixed: "binary installed" reported when cp was a no-op**
- Same defect on the apply side. `apply_source_update` ran `cp -p "$built" "$installed"` and declared success, even if both files were already identical. Now hashes the installed binary before and after `cp`. If unchanged, surfaces a `[WARN]` line so the operator knows the cp was a no-op and the running version after restart will be the same as before.

**Net effect:** the same "I updated my node but nothing changed" scenario can no longer happen silently. The script will either succeed with a new binary or fail loudly with a specific reason. Operators on v1.1.40 or earlier should update before their next `update-node.sh` run.

All scripts bumped to v1.1.41.

### v1.1.40
Picker now correctly identifies feature branches instead of mislabelling them as "detached."

Previously `pick_source_version` only checked for two named states: exact tag and main tip/behind. Anything else fell through to "detached / not on main or any tag" -- even when the operator was sitting on a real, named local branch (e.g. `log_db_name`) tracking a remote branch. That made the header line factually wrong and uninformative.

**What changed**
- Added `git symbolic-ref --short HEAD` detection to distinguish "on a named branch" from "truly detached."
- When the detected branch is `main`, the existing tip/behind logic applies.
- When the detected branch is anything else (e.g. `log_db_name`), the picker now reports it as a feature branch:

  ```
  Current source ref:   branch 'log_db_name' @ cf4086bd
  Relative to main:     1 commit ahead of main
  Latest commit:        "Add names to some of the DB logs."
  ```

- Genuinely detached HEAD still gets the "detached / not on any branch or tag" label (and the wording is slightly more accurate now -- previously "not on main or any tag" implied other branches didn't exist).

All scripts bumped to v1.1.40.

### v1.1.39
Picker now distinguishes "at the tip of main" from "built from main but origin/main has moved since."

Previously `pick_source_version` had a binary `on_main` check -- either HEAD == origin/main and the `main` option got a `<-- current` marker, or it didn't and got nothing. That hid a real signal: operators who built from main weeks ago but had since fallen behind saw no marker at all and had to guess whether new commits had landed.

**New state machine** (replacing `on_main`):
- `tip` -- HEAD is exactly at origin/main. Picker shows `main  <-- current` and the header reports `origin/main: up to date`.
- `behind` -- HEAD is an ancestor of origin/main but the tip has advanced. Picker shows `main  <-- N commit(s) newer than your build` and the header reports `origin/main has moved: N commits since your build` plus a one-line summary of the latest main commit (e.g. `abc12345 2 days ago -- Add memory-pool improvements (#704)`).
- `none` -- HEAD is detached or diverged from main. Header reports as before (`detached / not on main or any tag`).

Detection uses `git merge-base --is-ancestor HEAD origin/main` (ancestry check) and `git rev-list --count HEAD..origin/main` (gap count). No substring matching.

All scripts bumped to v1.1.39.

### v1.1.38
Two corrections to `pick_source_version` based on operator feedback.

**Fixed: wrong `<-- current` marker on tag lists**
- The previous logic did a substring match between `git describe --tags --always` and each tag name. For an operator on `main` with the closest ancestor tag being `v0.6.0-adiri`, `git describe` produced `v0.6.0-adiri-84-gXXXXXXXX`, which *contained* `v0.6.0-adiri`, so the picker incorrectly marked that tag as "current" -- even though the operator's HEAD was at the tip of `main`, not on that tag at all.
- Replaced with proper detection: `git describe --tags --exact-match HEAD` returns a non-empty value only when HEAD is exactly an annotated tag, and `git rev-parse HEAD vs origin/main` confirms whether HEAD is on main. The "current" marker now lands on `main` for operators built from main, on the exact tag for operators built from a tag, or on neither for detached commits. The header line also describes the operator's state in plain language: "main @ 34911812 (v0.6.0-adiri-84-g34911812)" rather than just the describe string.

**New: hide obsolete source versions from the picker**
- Per the Telcoin team, operators shouldn't be installing builds older than v0.9.1. The picker now applies a minimum-version filter (`MIN_SOURCE_VERSION_TESTNET="0.9.1"`, configurable in `lib/common.sh`) after the network-suffix filter, so the menu shows only the currently-supported tags. main and custom-ref remain available as separate options. With the current upstream state the testnet picker now shows just `v0.9.2-adiri` and `v0.9.1-adiri` plus `main` -- not 15 historic releases.

All scripts bumped to v1.1.38.

### v1.1.37
Hotfix for v1.1.36.

- `update-node.sh` was still declaring its own `readonly TN_SOURCE_DIR="/opt/telcoin-source"` after v1.1.36 moved that declaration into `lib/common.sh`. Under `set -e` the duplicate readonly assignment killed the script immediately on start with `update-node.sh: line 35: TN_SOURCE_DIR: readonly variable`. Removed the duplicate. (The same fix was applied to `setup-observer.sh` / `setup-validator.sh` in v1.1.36, but `update-node.sh` slipped through.)

All scripts bumped to v1.1.37.

### v1.1.36
Source-build picker now follows the official Telcoin guidance for which ref to build from.

Per the Telcoin dev team: the general case for **testnet** is to build from the latest `-adiri` tag (which sits on a branch parallel to `main`). Using `main` works too but isn't the default. **Devnet** follows `main`. **Mainnet** will have its own tag set when it launches.

**Changes**
- New `pick_source_version <network>` in `lib/common.sh`. Filters tags by the network's suffix (`-adiri` for testnet, `-telcoin` for mainnet -- placeholder until mainnet exists). Lists newest first, marks the recommended (latest matching tag) and the operator's current ref. Default selection is option 1 (just press Enter).
- `setup-observer.sh` and `setup-validator.sh` use the new picker for the source-build step. The previous "main (recommended -- stable release) / custom" prompt is gone -- it was misleading because `main` is a parallel branch from the testnet release tags, not the recommended testnet build. New operators on testnet now get the latest `-adiri` tag by default.
- `update-node.sh` uses the same picker via `lib/common.sh`. The duplicate copy in `update-node.sh` was removed.
- New constants in `lib/common.sh`: `TN_SOURCE_DIR`, `NETWORK_TAG_SUFFIX_TESTNET`, `NETWORK_TAG_SUFFIX_MAINNET`. The local `TN_SOURCE_DIR="/opt/telcoin-source"` declarations in `setup-observer.sh` and `setup-validator.sh` were removed (they shadowed the new readonly in `common.sh` and caused an early exit).
- Wording cleanup: the setup scripts now explain upfront that testnet ops build from `-adiri` tags and `main` is for devnet -- so operators aren't confused about why they're being defaulted to a tag rather than `main`.

**Migration note for existing operators**
- Existing installs built from `main` will keep working -- no forced update. To switch to the latest `-adiri` tag, run `sudo update-node.sh` and pick option 1 from the new menu.

All scripts bumped to v1.1.36.

### v1.1.35
UX improvement to `update-node.sh`: show available versions upfront instead of asking the operator to commit to "prepare" before seeing what's there.

**New flow:**
1. Auto-detect node type + install method (same as v1.1.34)
2. **Probe the remote upfront** -- `git fetch` for source installs, GAR API for Docker installs -- so the operator can see what is available before picking anything.
3. **Show a numbered menu of versions** with the current one marked `<-- current` and the newest one marked `<-- latest`. For source: up to 15 recent tags plus a `main` option and a custom-ref entry. For Docker: up to 15 recent tags plus a custom-tag entry. Both menus include a `Cancel` option.
4. **Then** ask whether to prepare-only, prepare-and-apply, or cancel.

For source builds the script also reports how many commits behind `origin/main` the current ref is, so operators can see at a glance whether anything has landed since their last build. If you are already on the latest release tag, the menu says `[OK] You are on the latest release tag` so you can cancel out without committing to a build.

The `--discard` flag and the existing pending-state logic (apply / discard-and-prepare / leave-for-later) are preserved; "discard and prepare different" now flows through the same picker.

All scripts bumped to v1.1.35.

### v1.1.34
New `update-node.sh` -- a single script for safely moving a running node to a newer version. Replaces the operator's previous workflow of "stop service, rebuild manually, hope it works, restart manually."

**Two-phase workflow (same for both source and Docker installs)**
- Phase 1 (prepare): runs the slow/risky step with the service still running -- `cargo build --release` for source, `docker pull` for Docker. Zero downtime.
- Phase 2 (apply): stops the service, swaps the artefact, restarts, and verifies. ~30s downtime for Docker; instant for source (just a `cp`).
- The two phases can run back-to-back (one menu choice) or be split across days. Pending state is recorded in `/etc/telcoin/<type>/.pending-update` so re-running the script picks up where it left off.

**Auto-detection**
- Node type (validator vs observer): from installed systemd units.
- Install method (source vs docker): from `INSTALL_METHOD=` in `.node-meta`. If `existing` (an externally-supplied binary), the script exits with a clear message rather than guessing.
- Network (testnet vs mainnet): from `NETWORK=` in `.node-meta`, with fallback to inspecting the `chain_name` in `genesis.yaml` for older installs. Determines whether source builds get `--features faucet` (testnet) or not.

**Docker tag discovery**
- Queries the Google Artifact Registry's public Docker v2 API at `https://us-docker.pkg.dev/v2/telcoin-network/tn-public/adiri/tags/list`, parses tags matching `vX.Y.Z[-suffix]`, and shows the most recent 15 sorted by version. Marks the current tag. If the API call times out or returns unparseable data, falls back silently to manual tag entry.

**Safety nets**
- Source: the built binary is run through `--version` before being declared "prepare complete" -- catches the rare case where `cargo build` finishes but the resulting binary is broken. Hash recorded in pending state so apply can detect a swap.
- Docker: the unit file is backed up as `<unit>.bak.<UTC-ts>` before any `perl -i` edit (same helper edit-config.sh uses).
- Source: the current binary at `/opt/telcoin/telcoin-network` is backed up as `.bak.<UTC-ts>` before overwrite.
- Both: post-restart health verification (`tn_latestConsensusHeader` RPC ping with a 45s timeout). If unhealthy after restart, the script offers a one-keystroke rollback that restores the backup, restarts, and re-verifies.
- Validators get a hard-gate `CONFIRM` prompt before any downtime, with an explicit warning about lost block rewards.

**What is never touched by an update**
- BLS / P2P keys at `/var/lib/telcoin/<type>/node-keys/`
- `node-info.yaml` (the operator's `primary_network_key`, multiaddrs, etc.)
- BLS passphrase at `/etc/telcoin/<type>/bls-passphrase`
- Chain config files (genesis/committee/parameters)
- Listener multiaddrs and other `Environment=` lines in the unit file -- only the binary path (source) or image tag (Docker) changes; the rest of `ExecStart` is preserved by-construction.

**Setup scripts**
- `setup-observer.sh` and `setup-validator.sh` now write `NETWORK=` and `DATA_DIR=` lines into `/etc/telcoin/<type>/.node-meta`. This was previously missing -- `check-node.sh` already expected `DATA_DIR=` and `update-node.sh` needs both. Existing installs are not affected; the new script falls back to inspecting `genesis.yaml` (for `NETWORK`) and the default path `/var/lib/telcoin/<type>` (for `DATA_DIR`) when `.node-meta` doesn't have them.

All scripts bumped to v1.1.34.

### v1.1.33
- `check-node.sh` now shows EVM execution state alongside consensus state. New section reports your node's `eth_blockNumber`, the network's latest execution block (extracted from the consensus header response we were already fetching -- no extra RPC call), the lag in blocks, and `eth_syncing` status. If `eth_syncing` returns a syncing object, the script flags it with the current/highest block counts and counts it as a health issue. Catches "node is up but execution layer is stuck or catching up" -- a failure mode the consensus-only check could miss.
- README cleanup: older changelog entries (v1.1.28 and earlier) moved to a dedicated `CHANGELOG.md` file. The README itself is now ~250 lines shorter. The full history is preserved verbatim in `CHANGELOG.md`.

All scripts bumped to v1.1.33.

### v1.1.32
Small UX follow-up to v1.1.31. `check-node.sh` no longer requires `--observer`/`--validator` on the command line for the common case.

- `check-node.sh` auto-detects node type from installed systemd units. Run `bash check-node.sh` with no flag on any node and it picks the right defaults. `--observer` and `--validator` remain as explicit overrides for non-standard setups or when both unit files exist on the same server.
- README "Run at any time after setup" section updated to show the new auto-detect usage and lists the actual v1.1.31+ checks (the old list still referenced the retired log-grep peer count).
- Retired the "Peer Count Note" section in the README -- the entire log-grep approach it described was removed in v1.1.31. Replaced with a short "Why RPC instead of log files?" note explaining the current design.

All scripts bumped to v1.1.32.

### v1.1.31
`check-node.sh` has been redesigned around the consensus RPC. Old version relied on grepping log files for fragile string markers, which produced misleading or stale output (notably a "P2P peers since startup" metric whose label was wrong, "consensus stuck" warnings that fired during normal testnet quiet periods, and a "synced at block 0" message that was a permanent false positive on Adiri). New version replaces all of that with direct RPC calls and the network's own view of your node.

**New source of truth: `tn_latestConsensusHeader`**
- Reports network state (block, epoch, commit timestamp, committee) by querying `https://rpc.telcoin.network` directly.
- Reports local state by querying the local node's RPC and comparing.
- Health contract: `block == 0` → ERROR "fully stalled", `commit_timestamp age > 60s` → WARN "stale, behind by Xs", else OK.

**New: author-presence check (the killer signal)**
- Validators get a clear answer to "is my node actually participating?" by checking whether the operator's authority ID appears in `sub_dag.headers[].author` from the network's recent consensus headers. Catches the failure mode where a validator is "running" (systemd green, RPC up) but silent (not authoring headers).
- Works even when the local RPC is closed off entirely -- the network's view of your node is enough.
- Authority ID is auto-detected from `<data-dir>/node-info.yaml` (field `primary_network_key`) or passed explicitly via `--authority-id <BASE58>`.

**New: own reputation score**
- Reports the operator's reputation score from `sub_dag.reputation_score.scores_per_authority` alongside the committee average. Below half-average emits a `[WARN]`.

**New: local RPC mode classification**
- Distinguishes `HEALTHY` / `SLOW` (responding but >6s) / `DISABLED` (HTTP 200 with `-32601 method not found`) / `DOWN` (connection refused). Previously all four looked the same.

**New: `--no-network` flag**
- Skips the public-RPC query for fully air-gapped diagnostics. Local-only checks still run.

**New: disk check uses the actual data directory**
- Reads `DATA_DIR` from `/etc/telcoin/<type>/.node-meta` (falls back to `/var/lib/telcoin/<type>`) and reports the disk usage of whatever mount actually holds chain data. Previously hard-coded to `/var/lib/telcoin`, which missed operators with chain data on a separate mount.

**Removed entirely**
- Log file grepping for `peer metrics heartbeat`, `got new consensus`, `new connection established`
- The "P2P peers since startup" metric (label was wrong; counted all-time unique entries with no time filter)
- The 120s "consensus stuck" heuristic (false positives during testnet quiet periods)
- The "same block in last 10 log entries" heuristic (correlated nothing meaningful)
- Greedy regex for primary/worker peer breakdown

**Dependency notes**
- Adds `python3` as a runtime dependency for JSON parsing (already installed on every supported OS). No `jq` needed.

**Implementation note**
- All helper functions explicitly `return 0` even on miss, so the `set -e` inherited from `lib/common.sh` cannot fire silently when an optional file (like `node-info.yaml`) is absent.

- All scripts bumped to v1.1.31

### v1.1.30
Firewall script now opens every port a Telcoin node actually needs — no more silent monitoring failures or unreachable validators after running "Enable firewall with recommended defaults".

**`firewall-setup.sh` — node-aware recommended defaults**
- Option 2 ("Enable firewall with recommended defaults") now opens the ports a node actually needs based on what's installed: SSH, TCP 43174 (Uptime Kuma) on every node, plus UDP 49590/49594 on validators. Previously only SSH was opened, so operators who didn't also navigate to option 4 ended up with closed P2P ports (silent validator consensus failure) or closed Uptime Kuma (silent monitoring failure).
- New `UPTIME_KUMA_PORT` constant. Uptime Kuma is documented as required across all nodes (Telcoin Association health monitoring runs against every deployed node).
- New `ufw_has_allow <port> <proto>` helper. Status checks now match the protocol explicitly, fixing the prior `grep "49590\|49594"` patterns that conflated TCP and UDP rules.
- Option 1 ("View current firewall status") now flags `CLOSED -- validator will not reach consensus` and `CLOSED -- health monitoring will fail` as hard errors (not warnings) when required ports are shut on an installed node.
- Option 4 ("Manage node ports") wording updated to reflect that Uptime Kuma is required (not optional) and Public RPC remains optional.

**README**
- "Health Monitoring (Uptime Kuma)" section updated to mark TCP 43174 as required for all nodes rather than optional.

- All scripts bumped to v1.1.30

### v1.1.29
Audit-driven hardening pass. Focus: protecting live node state from typos, races, and bad input. No behavioural changes to the happy path; existing setups continue working unchanged.

**`edit-config.sh` — the highest-risk script in the suite**
- Every option that writes to a systemd unit file now creates a timestamped sibling backup first (`<unit>.bak.YYYYmmdd-HHMMSS`) so a bad edit can be rolled back by hand
- Custom multiaddrs are validated against `/ip[46]/<addr>/udp/<port>/quic-v1` before any write -- bad input is rejected, not silently inserted
- Instance number must be an integer 1-9 -- guards against typos that would silently change the RPC port
- Metrics address must be `IPv4:PORT` -- catches `127.0.0.1` (missing port) and similar
- P2P ports validated as 1-65535 and primary != worker
- Docker image reference validated before pulling -- catches obvious typos before the pull failure
- RPC mode change now strips orphan `--http.port`, `--http.api`, `--http.corsdomain`, `--http.vhosts` flags (previously only `--http.addr`/`--http` were removed, leaving stragglers)
- BLS passphrase change now stops the service, polls until fully stopped, rewrites the passphrase file, then restarts -- closes the race where the running node could read a half-written file
- Chain config refresh checks all three source YAMLs exist before any `cp`, so a missing source no longer silently leaves a node with stale configs

**Setup scripts (observer + validator)**
- `-e TN_BLS_PASSPHRASE=${bls_pass}` in the Docker `ExecStart` is now quoted -- a passphrase containing whitespace or shell metacharacters no longer breaks the unit file
- Public IP and listener IP prompts validate input (IPv4 or IPv6) and re-prompt on bad input
- Multiaddr prompts validate against the expected shape and re-prompt on bad input

**`firewall-setup.sh`**
- Atomic SSH port change. New sequence: back up `sshd_config`, add a second `Port` directive so sshd listens on both old and new during the transition, open the new port in ufw, require operator to type `CONFIRMED` after testing the new port from a second terminal, then remove the old port and old ufw rule. If anything goes wrong (sshd reload fails, operator does not confirm), rolls back to the original state.

**`remove-node.sh`**
- `wipe_chain_data_only` now polls until the unit is actually stopped before `rm -rf .../db` -- closes the race where deletion could run while the node process still held DB file handles
- Docker image removal checks whether the sibling node's unit references the same image and keeps it if so
- Service user/group removal checks whether the sibling node's unit uses the same user and keeps it if so

**`update-scripts.sh`**
- Now has `set -euo pipefail` (was the only script without it) -- failed curls in the middle of an update are no longer silent
- Three-stage integrity check on every download: non-empty file, opportunistic SHA-256 verification against an upstream `<file>.sha256` sidecar (skipped silently when absent), and `bash -n` syntax check on `.sh` files before `mv` -- catches truncated or corrupted downloads even when no checksum is published

**`check-node.sh`**
- Now has `set -uo pipefail` -- catches unset-variable bugs and silent pipe failures without breaking the script's intentional `|| echo ""` fallback patterns
- Fixed a pre-existing latent bug: `(( HEALTH_ISSUES++ ))` returns the pre-increment value 0 (exit code 1) the first time a health issue is detected, which under the inherited `set -e` from `lib/common.sh` caused the script to exit silently before reporting subsequent checks. Converted all post-increments across the suite (`check-node.sh`, `remove-node.sh`, `edit-config.sh`, `lib/common.sh`) to pre-increments which return the new value and avoid the trap.

**`lib/common.sh`**
- New input validation helpers used across the suite: `validate_ipv4`, `validate_ipv6`, `validate_public_ip`, `validate_port`, `validate_ip_port`, `validate_multiaddr`, `validate_docker_image`, `prompt_with_validation`

- All scripts bumped to v1.1.29

For older entries (v1.1.28 and earlier), see [CHANGELOG.md](./CHANGELOG.md).
---

## Support

For issues with the Telcoin Network protocol or chain configuration, contact the Telcoin Association development team.

For issues with these setup scripts, raise them via the appropriate Telcoin Association channels.
