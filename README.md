# Telcoin Network Node Setup Scripts

Automated setup scripts for deploying **Validator** and **Observer** nodes on the Telcoin Network. Built for MNO operators — interactive, guided, and validated at every step.

---

## What's Included

| File | Purpose |
|---|---|
| `setup-observer.sh` | Full guided setup for an observer node |
| `setup-validator.sh` | Full guided setup for a validator node |
| `check-node.sh` | Health check for any running node |
| `edit-config.sh` | Edit the configuration of a running node |
| `firewall-setup.sh` | Interactive firewall management and hardening |
| `remove-node.sh` | Safely remove a node installation |
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

- Ubuntu 20.04+ LTS
- Debian 11+
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

**1. Copy the scripts to your server**

From Windows Command Prompt:
```
scp -r "C:\path\to\telcoin-node-scripts" user@YOUR_SERVER_IP:~/
```

From Linux/Mac terminal:
```
scp -r ./telcoin-node-scripts user@YOUR_SERVER_IP:~/
```

**2. Make the scripts executable**
```bash
chmod +x ~/telcoin-node-scripts/setup-observer.sh
chmod +x ~/telcoin-node-scripts/setup-validator.sh
chmod +x ~/telcoin-node-scripts/check-node.sh
chmod +x ~/telcoin-node-scripts/edit-config.sh
chmod +x ~/telcoin-node-scripts/firewall-setup.sh
chmod +x ~/telcoin-node-scripts/remove-node.sh
chmod +x ~/telcoin-node-scripts/update-scripts.sh
```

**3. Run the setup**
```bash
# For an observer node
sudo bash ~/telcoin-node-scripts/setup-observer.sh

# For a validator node
sudo bash ~/telcoin-node-scripts/setup-validator.sh
```

**4. Harden your firewall (recommended)**
```bash
sudo bash ~/telcoin-node-scripts/firewall-setup.sh
```

**5. Edit configuration after setup (optional)**
```bash
sudo bash ~/telcoin-node-scripts/edit-config.sh
```

The script will guide you through every step interactively.

---

## What the Setup Script Does

Each script walks through numbered steps:

**Steps 1-4: Preparation**
- Checks you are running as root
- Detects your Linux distribution and package manager
- Verifies hardware meets minimum requirements
- Checks internet connectivity
- Checks required ports are available
- Installs any missing tools (curl, git)
- Asks which network to connect to (Adiri testnet or mainnet)
- Asks for port and directory configuration
- Asks how to obtain the binary (build from source, pre-built, Docker, or existing)

**Step 5: System Infrastructure**
- Creates a dedicated system user and group for the node service (default: `telcoin`/`telcoin`, customisable during setup). The user has no login shell for security.
- Creates all required directories under `/opt/telcoin`, `/var/lib/telcoin`, `/etc/telcoin`, `/var/log/telcoin`
- Creates the reth internal log cache directory
- Clones the Telcoin Network repository if not already present (for chain-config files)
- Verifies the binary is valid and executable

**Step 6: Key Generation**
- Asks for your Ethereum address (and multiaddrs for validators)
- Asks you to set a BLS key passphrase (entered twice to confirm, never shown on screen)
- Runs `telcoin-network keytool generate observer/validator` to create cryptographic keys
- Stores keys in `/var/lib/telcoin/[node-type]/node-keys/` with strict permissions
- Stores the passphrase securely in `/etc/telcoin/[node-type]/bls-passphrase` (mode 600)

**Step 7/8: Configuration and Service**
- Copies the official chain-config files (genesis.yaml, committee.yaml, parameters.yaml) from the cloned repository
- Writes a systemd service file to `/etc/systemd/system/telcoin-[type].service`
- Configures the correct network listener addresses for P2P connectivity
- Optionally starts the node immediately
- Optionally enables auto-start on server reboot

---

## System Layout

After setup, files are organised as follows:

### Observer Node
```
/opt/telcoin/
  telcoin-network              -- the node binary

/var/lib/telcoin/
  observer/                    -- observer chain data
    node-keys/                 -- P2P identity keys (keep backed up)
    node-info.yaml             -- public node identity
    genesis/
      genesis.yaml             -- chain genesis config
      committee.yaml           -- validator committee config
    parameters.yaml            -- consensus parameters
    db/                        -- chain database (grows over time)

/etc/telcoin/
  observer/
    bls-passphrase             -- BLS key passphrase (mode 600, root only)

/var/log/telcoin/
  telcoin-observer.log         -- node output logs
  telcoin-observer-error.log   -- node error logs

/etc/systemd/system/
  telcoin-observer.service     -- systemd service definition

/home/telcoin/
  .cache/reth/logs/            -- reth internal log cache

/opt/telcoin-source/           -- cloned GitHub repository
  chain-configs/               -- official chain config files
  target/release/              -- compiled binary location (if built from source)
```

### Validator Node
```
/opt/telcoin/
  telcoin-network              -- the node binary

/var/lib/telcoin/
  validator/                   -- validator chain data
    node-keys/                 -- BLS and P2P identity keys (keep backed up)
    node-info.yaml             -- public node identity (contains BLS public key)
    genesis/
      genesis.yaml             -- chain genesis config
      committee.yaml           -- validator committee config
    parameters.yaml            -- consensus parameters
    db/                        -- chain database (grows over time)

/etc/telcoin/
  validator/
    bls-passphrase             -- BLS key passphrase (mode 600, root only)

/var/log/telcoin/
  telcoin-validator.log        -- node output logs
  telcoin-validator-error.log  -- node error logs

/etc/systemd/system/
  telcoin-validator.service    -- systemd service definition

/home/telcoin/
  .cache/reth/logs/            -- reth internal log cache

/opt/telcoin-source/           -- cloned GitHub repository
  chain-configs/               -- official chain config files
  target/release/              -- compiled binary location (if built from source)
```

---

## Security Design

The scripts follow Linux security best practices:

- **Dedicated service user** — the node runs as a dedicated system user (default: `telcoin`) with no login shell and no sudo access. The user and group name can be customised during setup. If the process is compromised it cannot access your other files or accounts.
- **Strict file permissions** — key files are mode 600 (readable only by owner). The node-keys directory is mode 700.
- **Passphrase never logged** — the BLS passphrase is passed via environment variable, never on the command line where it would appear in process lists.
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

## Security Improvements (Optional)

The default setup stores the BLS passphrase in a mode 600 file on disk and embeds it in the systemd service file. This is standard practice for unattended server services and is reasonable for most operators. However there are two options for higher security if needed.

### Option 1 — systemd LoadCredential (recommended upgrade)

Built into systemd (version 247+, available on Ubuntu 22.04+). Instead of embedding the passphrase directly in the service file, systemd loads it from a file and injects it into a secure temporary directory that only the service process can access. The passphrase never appears in `systemctl show` output or process listings.

To switch to this approach, modify the service file:

```ini
[Service]
# Remove the Environment="TN_BLS_PASSPHRASE=..." line and replace with:
LoadCredential=bls-passphrase:/etc/telcoin/observer/bls-passphrase

# Update ExecStart to read from the credential directory:
ExecStart=/bin/bash -c 'TN_BLS_PASSPHRASE=$(cat $CREDENTIALS_DIRECTORY/bls-passphrase) \
    exec /opt/telcoin/telcoin-network node --datadir /var/lib/telcoin/observer \
    --observer --instance 5 --metrics 127.0.0.1:9000 \
    --log.stdout.format log-fmt -vvv --http'
```

Advantages:
- Passphrase never embedded in the service file
- Systemd manages the secure credential directory automatically
- No extra software required
- Credential is cleaned up when the service stops

### Option 2 — HashiCorp Vault (enterprise grade)

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

### Recommendation

For most MNO operators running one or two nodes, `LoadCredential` is the right upgrade — meaningful security improvement with no new infrastructure. Vault makes sense for the Telcoin Association managing secrets centrally across many validators, or for large MNOs running multiple nodes at scale.

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
# Check observer node
bash ~/telcoin-node-scripts/check-node.sh --observer

# Check validator node
bash ~/telcoin-node-scripts/check-node.sh

# Check validator with on-chain status
bash ~/telcoin-node-scripts/check-node.sh --address 0xYOUR_VALIDATOR_ADDRESS

# Custom service or RPC endpoint
bash ~/telcoin-node-scripts/check-node.sh --service telcoin-observer --rpc http://127.0.0.1:8541
```

The health check verifies:
- Systemd service is running
- RPC endpoint is responding
- Sync status and latest block number
- Peer connectivity (see note below)
- Disk space
- Memory usage
- Validator on-chain status (when `--address` flag is provided)

### Peer Count Note

Telcoin Network uses a libp2p-based P2P architecture (Narwhal/Bullshark) that differs from standard Ethereum peer counting. The `net_peerCount` RPC method returns **consensus peers only** — the number of committee validators the node is actively participating with. For observer nodes this will always be 0, which is correct and expected.

The health check reads peer data directly from the node log file to provide more meaningful information:

- **Consensus peers** — from `peer metrics heartbeat` log entries. Always 0 for observers (expected). Should be > 0 for active validators.
- **Unique P2P peers (last 5 min)** — count of unique peer IPs seen in `new connection established` log entries in the last 5 minutes. Indicates active network connectivity. The same peer connecting multiple times is only counted once.

Once the Prometheus metrics endpoint (port 9000) is functional in a future binary release, the health check will be updated to use it for more accurate real-time peer data.

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
- Ask for the full image URL and tag (default: `us-docker.pkg.dev/telcoin-network/tn-public/adiri:v0.8.1-adiri`)
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

## Changelog

### v1.1.2
- Added `remove-node.sh` — interactive node removal script
  - Auto-detects installed nodes (observer, validator, or both) and install method (binary/source or Docker)
  - Separate confirmations for chain data, keys, binary, source, user and group
  - Key deletion requires typing `DELETE` to confirm — cannot be undone
  - Wipe chain data only option (keeps keys and config, forces resync)
  - Docker-aware — stops/removes container and optionally removes image
- Added `update-scripts.sh` — checks all scripts against latest GitHub versions and downloads updates
  - Checks each script individually showing local vs remote version
  - Always includes `lib/common.sh` in any update
  - Requires confirmation before downloading
- Added `COMMON_VERSION` to `lib/common.sh` so it can be version-tracked like other scripts
- Implemented Docker install option in both setup scripts
  - Installs Docker if not present
  - Prompts for image URL and tag
  - Creates host service user with UID 1101 to match container's `nonroot` user
  - Runs keytool via Docker image for key generation
  - Creates systemd service wrapping `docker run` with `--user` flag
- Added new options to `edit-config.sh`: P2P ports, Docker image update, chain config refresh, restart node
- Fixed `edit-config.sh` `set -e` crash in `show_current_config`
- Replaced manual wipe commands in README with reference to `remove-node.sh`
- Updated Binary Installation Options in README — Docker now documented with image URL
- All scripts bumped to v1.1.2

### v1.1.1
- Added CVE-2026-31431 (Copy Fail) security check to preflight in both setup scripts
- Setup will not proceed if `algif_aead` kernel module is loaded or not blocked
- Operators are directed to https://copy.fail to apply the mitigation before re-running
- Added CVE-2026-31431 section to README Security Design with details and manual check commands
- Added `firewall-setup.sh` — interactive menu-driven firewall management script
  - View current firewall status, SSH configuration and node ports at any time
  - Enable firewall with recommended defaults (default deny inbound)
  - Manage SSH access (disable password auth, disable root login, change port)
  - Manage node ports (auto-detects validator/observer, applies correct rules)
  - Manage trusted IP whitelist for SSH access
- Added Firewall Setup section to README with usage guide and warnings

### v1.1.0
- Added custom service user and group selection in Step 5 of both setup scripts — operators can name the service user and group (defaults: `telcoin`/`telcoin`)
- Group is created first if it doesn't exist, user is added to the group
- All directory ownership and systemd service file updated to use `SERVICE_GROUP`
- Improved peer count in health check — reads directly from node log file instead of unreliable `net_peerCount` RPC
  - Shows consensus peers from `peer metrics heartbeat` log entries
  - Shows P2P connections in last 5 minutes from `new connection established` log entries
  - Observer nodes correctly show consensus peers = 0 (expected, not an error)
  - Validator nodes warn if consensus peers = 0 when active
- Improved sync status messaging — cross-references block number, warns if synced but at block 0
- Added `--address` flag example to README health check section
- Added Peer Count Note section to README explaining the current approach and future metrics endpoint plan

### v1.0.9
- Split hardware requirements into separate validator and observer specs based on official Telcoin Association documentation
- Observer requirements updated: 8 cores, 16GB RAM, 500GB SSD (much more modest than validator)
- Validator requirements confirmed: 16 cores, 128GB RAM, 4TB NVMe SSD
- Hardware check in scripts now uses node-type specific thresholds
- Added GSMA MNO requirement back to validator node type description and welcome screen
- Added pre-installation contact requirement: operators must email grant@telcoin.org before installing validator nodes
- Broadened supported OS list: Ubuntu 20.04+, Debian 11+, RHEL 8+, macOS (observer only)
- Added TLC vs QLC storage explanation to README
- Added network requirements: 1Gbps for validators, 24Mbps for observers
- Reverted tn_syncing to eth_syncing — tn_syncing not supported on current node binary

### v1.0.8
- Observer setup final summary now displays actual P2P listener addresses so operators can see what the node is really binding to
- Clarified that 127.0.0.1 shown during observer key generation is internal only and not the real listener address
- Removed port forwarding requirement from observer next steps — observers do not need inbound port forwarding
- Fixed sync check command in observer summary to use `eth_syncing`

### v1.0.7
- Updated hardware requirements to match official docs: 16 cores, 128GB RAM, 4TB NVMe SSD
- Fixed validator onboarding instructions — operators submit their ECDSA address to governance (not node-info.yaml)
- Added cast commands to post-key-generation display for staking and activation
- Updated sync check to use `eth_syncing` RPC method (correct Telcoin Network method)
- Updated Validator Onboarding Flow section in README with official staking guide steps and cast commands
- Updated OS recommendation to Ubuntu 24.04 LTS

### v1.0.6
- Fixed `edit-config.sh` RPC editing — service file no longer gets mangled when switching between private/public/disabled
- Fixed grep compatibility issue with `--http` flags on Ubuntu systems
- RPC edit now uses clean sed approach to rebuild ExecStart correctly every time

### v1.0.5
- Added `edit-config.sh` — interactive configuration editor for running nodes
  - Auto-detects validator or observer installation
  - Displays current config at startup
  - Edit listener addresses, instance number, metrics, log verbosity, RPC access, BLS passphrase
  - Reloads systemd and optionally restarts node after each change

### v1.0.4
- IPv6/IPv4 binding descriptions updated to neutral wording — no longer implies one is better for a specific environment type
- RPC access descriptions updated with clearer guidance on when to use Public vs Private, including security warning about nginx
- Coming soon options (pre-built binary, Docker) now pause and show a clear message before returning to the menu, so operators know their selection was received and why it is unavailable

### v1.0.3
- IPv4 binding now auto-detects the server's internal IP address rather than using `0.0.0.0` — correctly handles cloud/data centre environments where internal and external IPs differ
- Removed IPv4+IPv6 combined binding option (not supported by the node)
- Pre-built binary download marked as coming soon — will use official GitHub releases
- Docker install marked as coming soon — will use official Docker Hub image

### v1.0.1
- Added validator on-chain status check via ConsensusRegistry contract
- Added `display_node_info()` to show node-info.yaml after key generation
- Added `--address` flag to check-node.sh for on-chain validator status
- Added Security Improvements section to README (systemd LoadCredential and HashiCorp Vault)
- Added Validator Onboarding Flow section to README

### v1.0.0
- Initial release
- Observer and validator node setup scripts
- Health check script
- Systemd service with BLS passphrase, listener multiaddrs
- Build from source with full submodule support

---

## Support

For issues with the Telcoin Network protocol or chain configuration, contact the Telcoin Association development team.

For issues with these setup scripts, raise them via the appropriate Telcoin Association channels.
