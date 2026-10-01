# Telcoin Network Node Setup Scripts

Automated setup scripts for running a node on the Telcoin Network. Built for MNO operators — interactive, guided, and validated at every step.

There is one node identity. Every node installs validator-capable and follows consensus from day one; staking and on-chain activation are what let it validate. The protocol decides a node's role from on-chain committee membership each epoch, not from a setup flag.

> **Maintainers / AI agents:** see [`AGENTS.md`](AGENTS.md) for the operator-vs-maintainer repo boundary — what ships to operators vs. the maintainer-only `common/` tooling that operators never have.

---

## What's Included

| File | Purpose |
|---|---|
| `install.sh` | One-command installer for fresh machines |
| `setup-node.sh` | Full guided setup for a node (canonical installer) |
| `check-node.sh` | Health check for any running node |
| `edit-config.sh` | Edit the configuration of a running node |
| `firewall-setup.sh` | Interactive firewall management and hardening |
| `remove-node.sh` | Safely remove a node installation |
| `update-node.sh` | Update a running node to a newer version (source build or Docker image), with a prepare/apply two-phase workflow and one-keystroke rollback |
| `update-scripts.sh` | Check for and download script updates from GitHub |
| `setup-observability.sh` | Opt-in centralized logging + health monitoring (testnet add-on) |
| `setup-vpn.sh` | Opt-in WireGuard admin SSH for the Telcoin Association (testnet add-on) |
| `lib/common.sh` | Shared functions used by the above scripts (not run directly) |

> `setup-observer.sh` and `setup-validator.sh` still exist as thin deprecated shims that forward to `setup-node.sh`.

---

## Run a node

Anyone can run a full node — no approval required. Install the scripts, run `setup-node.sh`, and the node syncs the full chain state, serves JSON-RPC, and follows Narwhal/Bullshark consensus.

Every node is provisioned validator-capable from day one. "Just following consensus" and "validating" are not two install options — the difference is on-chain state (stake plus committee membership) that the protocol reads each epoch. Until you stake and activate, the node behaves like any full node.

The ports are the same on every node:

- RPC: **8545** (HTTP) / **8546** (WS) — the reth defaults
- P2P: **49590** (primary) and **49594** (worker) — UDP/QUIC
- Metrics: **9101** (loopback only)

### Become a validator (optional)

To validate you additionally need, in order:

1. **Approval** — Telcoin Association onboarding. Validators must be GSMA-approved MNOs; email grant@telcoin.org before purchasing hardware.
2. **Stake** — submit the stake transaction with your BLS public key and proof of possession.
3. **Activation** — call `activate()` on-chain and go active at the next epoch boundary.

The node software does not change. Once `tn_isValidator(blsPubkey)` returns true on-chain, the web UI automatically shows that node on the validator tab and renders the validator dashboard — there is no node-type toggle to flip. The step-by-step (with `cast` commands) is in [Validator Onboarding Flow](#validator-onboarding-flow) below.

### One node per VM

Each machine runs exactly **one** node, installed under a single, consistent identity:

- systemd unit: **`telcoin`** (`telcoin.service`)
- Docker container name (Docker installs): **`telcoin`**
- config directory: **`/etc/telcoin`**
- data directory: **`/var/lib/telcoin`**

`/etc/telcoin/.node-meta` records a `NODE_TYPE=` key, but it is only a non-authoritative
default-view hint (new installs write `NODE_TYPE=observer`) — the on-chain `tn_isValidator`
status is authoritative. Because there is only ever one node on the box, the binary is
launched with no node-instance flag and serves RPC on the reth default ports (`8545`/`8546`).

> **Upgrading from an older install?** Earlier versions used a separate unit name and
> per-role config/data directories for each node type. Those legacy per-role installs keep
> working untouched — a compatibility shim (`lib/fallback.sh`) detects the old layout and
> resolves the correct unit, container, and directories automatically. Nothing is renamed or
> migrated on its own; to move an existing install onto the unified layout, run
> `migrate-node-naming.sh`. Fresh installs always use the unified `telcoin` identity above.

---

## Requirements

### Hardware

The baseline below runs a full node. The heavier "to validate" column is what you want **if** you intend to stake and validate — treat it as guidance, not a requirement to run a node. The hardware preflight checks against the baseline and prints the validate spec for reference.

| Component | Run a node (baseline) | To validate |
|---|---|---|
| CPU | 8 cores / 16 threads, x86-64/ARM64 | 16+ cores / 32 threads, x86-64, 4000+ PassMark single-thread |
| RAM | 16GB DDR4 ECC | 128GB DDR4/DDR5 ECC RDIMM |
| Storage | 500GB TLC NVMe SSD | 4TB TLC NVMe SSD |
| Network | 24Mbps+ stable | 1Gbps sustained, 1GbE+ |

> Storage note: TLC NVMe drives are specifically required over QLC. TLC supports 1,000-3,000 P/E cycles vs 100-1,000 for QLC, making TLC significantly more durable for continuous blockchain write operations.

### Supported Operating Systems

- Ubuntu 22.04+ LTS (minimum -- required for systemd 247+)
- Debian 12+
- Red Hat Enterprise Linux (RHEL) 8+
- Kernel version 3.10+ minimum
- macOS Sequoia 15+ (full node only)

### Software
The scripts will install or check for everything needed. You do not need to install anything manually beforehand.

### To validate
- GSMA MNO status — only GSMA-approved MNOs may validate
- Hardware approval from the Telcoin Association — email grant@telcoin.org before purchasing equipment
- Prior governance approval from the Telcoin Association
- A registered Ethereum address for receiving TEL rewards

---

## Quick Start

All scripts are interactive and guide you through each step. Work through these in order on a fresh Linux machine:

**1. Install the scripts**

One-liner with `curl`:
```bash
curl -fsSL https://install.telcoin.network | bash
```

Or with `wget`:
```bash
wget -qO- https://install.telcoin.network | bash
```

If the `install.telcoin.network` domain is ever unreachable, the raw GitHub URL is a drop-in fallback:
```bash
curl -fsSL https://raw.githubusercontent.com/Telcoin-Association/tn-node-deployment/main/install.sh | bash
```

Or clone the repo directly:
```bash
git clone https://github.com/Telcoin-Association/tn-node-deployment.git ~/telcoin-node-scripts
chmod +x ~/telcoin-node-scripts/*.sh
```

**2. Run the guided setup**
```bash
sudo bash ~/telcoin-node-scripts/setup-node.sh
```
This provisions a validator-capable node. Staking and on-chain activation (see [Become a validator](#become-a-validator-optional)) are what let it validate later; until then it follows consensus as a full node.

**3. Harden the firewall (recommended)**
```bash
sudo bash ~/telcoin-node-scripts/firewall-setup.sh
```
Opens the ports every node needs: SSH, Uptime Kuma, and the P2P consensus ports UDP 49590/49594.

**4. Check node health any time**
```bash
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
- Asks whether RPC is private (default) or public; public asks for a DNS name for the node (see [Public RPC endpoint](#public-rpc-endpoint-https--wss))

**Step 4: System Infrastructure**
- Creates a dedicated system user and group (default: telcoin/telcoin, customisable). The user has no login shell for security.
- Creates all required directories under /opt/telcoin, /var/lib/telcoin, /etc/telcoin, /var/log/telcoin
- Creates the reth internal log cache directory
- Verifies the binary is valid and executable

**Step 5: Key Generation**
- Asks for your Ethereum address and P2P multiaddrs
- Asks you to set a BLS key passphrase (entered twice to confirm, never shown on screen)
- Runs the telcoin-network keytool to create the node's cryptographic keys (BLS + P2P)
- Stores keys in /var/lib/telcoin/node-keys/ with strict permissions
- Stores passphrase in /etc/telcoin/bls-passphrase (mode 600)
- If TPM selected: seals passphrase to TPM chip, shows it once, prompts operator to store offline

**Step 6: Configuration**
- Copies the official chain-config files (genesis.yaml, committee.yaml, parameters.yaml) from the cloned repository

**Step 7/8: Systemd Service**
- Writes a wrapper script to /opt/telcoin/start-telcoin.sh that reads the passphrase securely at runtime
- Writes a systemd service file to /etc/systemd/system/telcoin.service using LoadCredential
- Configures the correct network listener addresses for P2P connectivity
- Optionally starts the node immediately
- Optionally enables auto-start on server reboot
- With a public RPC domain and a started node: checks DNS, then enables the endpoint through Caddy

---

## System Layout

After setup, files are organised as follows. There is one layout for every node — the
default-view hint is recorded in `/etc/telcoin/.node-meta` (`NODE_TYPE=`) rather than in the paths.

```
/opt/telcoin/
  telcoin-network                   -- the node binary
  start-telcoin.sh                  -- wrapper script (reads passphrase, starts node)

/var/lib/telcoin/
  node-keys/                        -- P2P + BLS keys (keep backed up!)
  node-info.yaml                    -- public node identity (BLS pubkey + proof of possession)
  genesis/
    genesis.yaml                    -- chain genesis config
    committee.yaml                  -- validator committee config
  parameters.yaml                   -- consensus parameters
  db/                               -- chain database (grows over time)

/etc/telcoin/
  bls-passphrase                    -- BLS key passphrase (mode 600, root only)
  .node-meta                        -- internal metadata used by remove/edit scripts

/var/log/telcoin/
  telcoin.log                       -- node output log
  telcoin-error.log                 -- node error log

/etc/systemd/system/
  telcoin.service                   -- systemd unit definition

/home/telcoin/
  .cache/reth/logs/                 -- reth internal log cache

/opt/telcoin-source/                -- cloned GitHub repository
  chain-configs/                    -- official chain config files
  target/release/                   -- compiled binary location (source builds only)
```

One machine runs one node, so there is a single `telcoin.service` and a single set of
directories regardless of node type. Installs created by older versions of these scripts used
per-role unit names and per-role subdirectories under `/etc/telcoin` and `/var/lib/telcoin`;
those keep working as-is and the helper scripts locate them automatically via the
compatibility shim in `lib/fallback.sh`.

---

## Security Design

The scripts follow Linux security best practices:

- **Dedicated service user** — the node runs as a dedicated system user (default: `telcoin`) with no login shell and no sudo access. The user and group name can be customised during setup. If the process is compromised it cannot access your other files or accounts.
- **Strict file permissions** — key files are mode 600 (readable only by owner). The node-keys directory is mode 700.
- **Passphrase never embedded in the service file** — for **all** install methods the BLS passphrase is loaded via systemd `LoadCredential` into a secure temporary directory and never appears in the service file or `systemctl show`/`cat` output. Binary/source installs read it from `$CREDENTIALS_DIRECTORY` directly; Docker installs do the same in a small wrapper and pass it to the container with `-e TN_BLS_PASSPHRASE` (name only — the value is not on the command line). Note that, inherent to Docker, the value is still present in the container's environment (`docker inspect`); keeping it out of the persisted unit is the protection this provides.
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

All install methods use systemd `LoadCredential` by default (requires Ubuntu 22.04+ / systemd 247+). The passphrase is stored in a mode 600 file and loaded securely at runtime -- it never appears in the service file or `systemctl show`/`cat` output. Docker installs load it the same way via a small root-owned wrapper and pass it to the container with `-e TN_BLS_PASSPHRASE` (name only); the value is still visible in the container's own environment (`docker inspect`), inherent to Docker, but no longer in the persisted unit. For operators requiring even higher security, the following options are available.

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
# /opt/telcoin/start-telcoin.sh
export TN_BLS_PASSPHRASE=$(vault kv get -field=passphrase secret/telcoin/node)
exec /opt/telcoin/telcoin-network node --datadir /var/lib/telcoin \
    --metrics 127.0.0.1:9101 \
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

### P2P consensus ports
Open the P2P consensus ports — UDP/QUIC **49590** (primary) and **49594** (worker) — on **every** node, not just ones that validate today. A node that later stakes and joins the committee behind a closed firewall is unreachable to its peers and silently misses consensus, so the ports are opened up front while the node is still just following consensus.

**Linux firewall (ufw):**
```bash
sudo ufw allow 49590/udp
sudo ufw allow 49594/udp
```

**Router port forward (home/bare metal only):**
Forward UDP ports 49590 and 49594 from WAN to your server's local IP address. Cloud servers handle this via their network configuration.

The RPC port (8545) should **not** be opened to the internet, even for a public endpoint. reth stays on `127.0.0.1` and Caddy serves it on 443 (see [Public RPC endpoint](#public-rpc-endpoint-https--wss)).

### Health Monitoring (Uptime Kuma)
**Required for all nodes.** The Telcoin Association runs Uptime Kuma health monitoring against every deployed node — TCP port 43174 must be reachable **by the Association monitor, plus any optional operator-chosen IPs**. Restrict it to those source IPs rather than opening it to the whole internet (the endpoint binds on all interfaces, so a firewall rule is its only protection):

```bash
sudo ufw allow from 104.155.184.201/32 to any port 43174 proto tcp
```

`firewall-setup.sh` does this automatically — source-restricted to the monitor — when you run option 2 ("Enable firewall with recommended defaults"). To also expose it to **your own monitoring host(s)**, run `firewall-setup.sh` → "Manage node ports" → choice 2 ("Association monitor + your IPs"); your additions are persisted and survive a firewall reset. **Avoid `sudo ufw allow 43174/tcp`**, which exposes the health endpoint to the entire internet.

---

## Validator Onboarding Flow

Setting up a validator involves both off-chain (node setup) and on-chain (contract interaction) steps. The setup script handles the off-chain steps and guides you through what is needed on-chain.

Full staking guide: https://docs.telcoin.network/telcoin-network/staking/how-to-stake

### Full Process

**Step 1 — Generate keys and set up node (script handles this)**
Run `setup-node.sh`. The script installs the binary, generates your BLS keys, copies chain configs, and starts the node service.

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
# Health check for the local node
bash ~/telcoin-node-scripts/check-node.sh

# Force the validator or full-node view (overrides the .node-meta hint)
bash ~/telcoin-node-scripts/check-node.sh --validator
bash ~/telcoin-node-scripts/check-node.sh --observer

# Include validator on-chain status (queries the ConsensusRegistry contract)
bash ~/telcoin-node-scripts/check-node.sh --address 0xYOUR_VALIDATOR_ADDRESS

# Skip the network RPC query (fully local / air-gapped diagnostics)
bash ~/telcoin-node-scripts/check-node.sh --no-network

# Custom local RPC endpoint or service name
bash ~/telcoin-node-scripts/check-node.sh --rpc http://127.0.0.1:8545 --service telcoin
```

The health check verifies:
- **Systemd service status** — running, with restart-loop detection (warns if the unit has restarted more than 5 times)
- **Local RPC mode** — classified as `HEALTHY`, `SLOW` (responding but >6s), `DISABLED` (HTTP 200 but `-32601 method not found`), or `DOWN` (connection refused). Previously all four looked the same.
- **Network consensus state** — queries `https://rpc.telcoin.network` for ground truth: current block, epoch, committee size, and how fresh the latest commit is.
- **Local consensus state** — calls `tn_latestConsensusHeader` on the local node and applies the freshness contract: `block == 0` → ERROR (fully stalled), commit-timestamp age > 60s → WARN (stale), else OK. Also reports lag vs network in blocks.
- **Author presence (validator-only)** — checks whether your authority ID appears in the network's recent consensus headers. Catches the failure mode where a validator is running (systemd green, RPC up) but silent (not authoring headers). Auto-detects your authority ID from `<data-dir>/node-info.yaml` (field `primary_network_key`) or accepts an explicit `--authority-id <BASE58>` override.
- **Reputation score (validator-only)** — your own score from `sub_dag.reputation_score.scores_per_authority` alongside the committee average. Flags scores below half-average.
- **Validator on-chain status** — when `--address` is provided, calls the ConsensusRegistry contract and reports your validator state (Undefined / Staked / PendingActivation / Active / etc.).
- **Disk space** — uses the actual data directory from `/etc/telcoin/.node-meta` (falls back to `/var/lib/telcoin`), so the check reports usage on whichever mount actually holds chain data — not just the default.
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

**Manage node ports** — opens the P2P consensus ports (UDP 49590/49594) inbound on every node and manages the health port. It doesn't toggle TCP 80/443: `install-caddy.sh` opens them when it enables the public RPC endpoint or the dashboard (both served by Caddy), and closes them when the last site is disabled.

**Manage trusted IP whitelist** — add or remove specific IP addresses or CIDR ranges that are allowed SSH access. Shows your current session IP so you don't accidentally lock yourself out.

### Important warnings

- **Test SSH in a new terminal** before closing your current session after making any changes
- **Whitelist your IP first** before enabling default deny or restricting SSH
- **Every node** opens inbound UDP 49590/49594 — a node that later stakes behind a closed firewall would otherwise miss consensus
- Never open the RPC port (8545) directly to the internet — serve it through Caddy on port 443 instead (see [Public RPC endpoint](#public-rpc-endpoint-https--wss))
- A reset to a clean slate wipes every ufw rule, but keeps 80/443 while Caddy serves a Node Manager site (public RPC or dashboard). To close them, disable the site with `install-caddy.sh`

### When to run it

Run `firewall-setup.sh` after completing node setup and before going live. For production validator nodes this is strongly recommended. For home/testing setups it is optional but good practice.

---

```bash
# Start / stop / restart
sudo systemctl start telcoin
sudo systemctl stop telcoin
sudo systemctl restart telcoin

# View live logs
sudo tail -f /var/log/telcoin/telcoin.log

# View logs via journalctl
journalctl -u telcoin -f

# Enable auto-start on boot
sudo systemctl enable telcoin

# Reset after too many failed restarts
sudo systemctl reset-failed telcoin
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

**IPv4** — for home or bare metal servers. The script will auto-detect your server's internal IP address (e.g. `10.x.x.x` on cloud, `192.168.x.x` on home networks) and ask you to confirm it. On home or bare-metal networks, forward UDP ports 49590 and 49594 on your router to this server so the node stays reachable to its peers (and to the committee if it later stakes).

**Important distinction for cloud/data centre operators:**
- **Internal IP** (e.g. `10.70.70.2`) — what the node binds its listener to. Auto-detected by the script via `hostname -I`.
- **External/Public IP** — what peers use to reach your node. Fetched automatically via `api.ipify.org` and used for the node's key registration in `node-info.yaml`.

These are two different addresses on cloud servers and the script handles both correctly.

---

## Removing a Node

Use the dedicated removal script to safely remove a node installation:

```bash
sudo bash ~/telcoin-node-scripts/remove-node.sh
```

The script automatically detects what is installed (including legacy per-role layouts) and the install method (binary/source or Docker). It guides you through removal step by step with individual confirmations for each component.

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

Your node keys are stored in `/var/lib/telcoin/node-keys/`. Back these up immediately after setup.

If you lose your keys you lose your node identity. A node that has already staked must re-register its replacement keys with the Telcoin Association; a node that has not can simply regenerate keys and restart.

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
  setup-node.sh              1.1.2      1.1.3      UPDATE AVAILABLE
  check-node.sh              1.1.2      1.1.2      Up to date
  edit-config.sh             1.1.2      1.1.3      UPDATE AVAILABLE
  lib/common.sh              1.1.2      1.1.3      UPDATE AVAILABLE
```

If updates are available it will ask for confirmation before downloading. `lib/common.sh` is always included in any update since all scripts depend on it.

The updater also tracks the optional web UI (versioned independently, starting at `1.0.0`). When a newer UI is published it fetches the bundle into `ui/` and, if the UI is already installed, redeploys it via `ui/install-ui.sh --update` (refreshing the helper, sudoers, and restarting the service so the new code loads).

---

## Web UI (optional)

A small, self-contained web UI for managing a node from your browser: health at a glance, live logs, configuration, and OpenTelemetry traces. It is **optional** — nodes run fine without it.

### Install

```bash
sudo bash ~/telcoin-node-scripts/ui/install-ui.sh
```

The installer creates an unprivileged `telcoin-ui` system user, installs the app under `/opt/telcoin-ui`, and runs it as a systemd service. No further manual `sudo` setup is required.

### Access

The UI binds to `127.0.0.1:8080` only — it is **never** exposed to the network. Reach it over an SSH tunnel.

From your local machine, the helper script opens the tunnel and your browser:

```bash
./open-ui.sh user@SERVER_IP
```

Or do it manually:

```bash
ssh -L 8080:localhost:8080 user@SERVER_IP
# then open http://localhost:8080 in your browser
```

### External dashboard access (optional, via Caddy)

By default the UI is localhost-only (SSH tunnel). If you'd rather reach it at your own domain over HTTPS, `install-caddy` puts [Caddy](https://caddyserver.com) in front of it as a reverse proxy with automatic Let's Encrypt TLS and a login.

Public access is **read-only** — Caddy stamps an unforgeable header that the UI server enforces, so every management action (start/stop, config edit, update, setup, remove) is refused over the public path. Full management stays on the **SSH tunnel** (localhost).

Enable it from the UI under **Settings → External Dashboard Access**, or on the server:

```bash
sudo bash ~/telcoin-node-scripts/install-caddy.sh
```

Choose **Dashboard** from the menu, then pick the domain, a login username (not forced to `admin`), and a password.

- **Set the DNS A record first.** Point your domain at the server's public IP (the router's public IP if it's behind NAT) **before** enabling — Caddy requests the certificate on first start, so the record must already resolve or issuance fails and Let's Encrypt rate-limits retries. The wizard checks propagation before continuing.
- **Give it its own hostname.** The dashboard can't share a name with the [public RPC endpoint](#public-rpc-endpoint-https--wss). If your node has a public name like `node7.adiri.telcoin.network`, keep that for RPC and put the dashboard on `dashboard.node7.adiri.telcoin.network`.
- **Ports:** forward **443/tcp (required)** to the node; **80/tcp is recommended** (it adds the http→https redirect and a fallback for certificate issuance/renewal) but not required — Caddy obtains the certificate over 443. The script opens 80/443 in `ufw` for you. (Inbound forwarding is off by default on most routers, so this is something you set up explicitly.)
- **Conflicts:** Apache/Nginx and Caddy can't share ports 80/443. The interactive installer detects a conflicting web server and offers to stop, disable, or remove it (or quit), and it won't overwrite a Caddy config it didn't create.
- **Treat the login as a read-only credential, and rotate it.** The username/password gate only the public **read-only** view (it's stored as a bcrypt hash in the Caddyfile); it grants no management access — that stays on the SSH tunnel. If the credential leaks, the blast radius is read-only, but rotate it anyway by re-running `install-caddy.sh` (re-prompts and rewrites the hash). Don't reuse a password you use elsewhere.

Disable any time from the same **Settings** panel.

### Traces & Settings

The **Settings** tab can start/stop a local Jaeger instance and toggle OpenTelemetry tracing on the node; the **Traces** tab browses the collected spans. Jaeger's own UI (`:16686`) and the OTLP endpoint (`:4317`) are likewise localhost-only and reached through the same tunnel.

### Security model

- Binds `127.0.0.1` only; never `0.0.0.0`. Reached via an SSH tunnel — no new firewall ports — unless you opt into public access via Caddy (above), which is **read-only** and enforced server-side.
- The UI runs as the unprivileged `telcoin-ui` user. Every privileged action goes through **one** root-owned, argument-validated helper at `/usr/local/sbin/telcoin-ui-helper`.
- That user's `sudo` rights are pinned by an explicit, **no-wildcard** sudoers drop-in (`/etc/sudoers.d/telcoin-ui`): the six `systemctl start|stop|restart` lines for the two node services, plus the exact helper sub-commands. Nothing else.

### Service management

```bash
systemctl status telcoin-ui
journalctl -u telcoin-ui -f
```

---

## Public RPC endpoint (https + wss)

Optional. Serves your node's JSON-RPC at `https://<domain>/` and its WebSocket at `wss://<domain>/`, and advertises both on-network so gateways and wallets can find the node. Without it (the default), RPC stays on `127.0.0.1`.

reth never listens publicly. [Caddy](https://caddyserver.com) holds the TLS certificate (automatic Let's Encrypt) on port 443 and proxies to reth on loopback: JSON-RPC to `RPC_PORT` (8545), WebSocket upgrades to `WS_PORT` (8546). CORS preflight is answered at the edge. `install-caddy.sh` keeps this in the same Caddyfile as the optional [dashboard](#external-dashboard-access-optional-via-caddy); changing one site never touches the other.

### DNS first

The RPC endpoint and the dashboard need different hostnames:

| Hostname | Serves |
|---|---|
| `nodeN.<suffix>`, e.g. `node7.adiri.telcoin.network` | public RPC (https + wss) |
| `dashboard.nodeN.<suffix>`, e.g. `dashboard.node7.adiri.telcoin.network` | Node Manager dashboard (optional) |

One name can't carry both. `install-caddy.sh` refuses the clash before it writes anything.

Create each A record **before** you enable the site, pointing at the server's inbound public IP. Caddy asks Let's Encrypt for a certificate as soon as the site loads. If the name doesn't resolve to this server yet, issuance fails and retries get rate-limited. Allow inbound TCP 443 (required) and 80 (recommended), and forward both if the server sits behind a router. Behind NAT, or on a server with several addresses, the inbound IP isn't the one the scripts detect; pass it with `--public-ip <ip>`.

### New install

In step 3, `setup-node.sh` asks about RPC access. Choose `2) Public`, enter the domain, and give the inbound IP if you're behind NAT (Enter auto-detects). Flags skip the prompt:

```bash
sudo bash ~/telcoin-node-scripts/setup-node.sh --rpc-domain node7.adiri.telcoin.network
sudo bash ~/telcoin-node-scripts/setup-node.sh --rpc-domain node7.adiri.telcoin.network --public-ip 203.0.113.10
sudo bash ~/telcoin-node-scripts/setup-node.sh --no-public-rpc    # private, no prompt
```

`--rpc-public` on its own no longer makes RPC public. Without `--rpc-domain` it prints a warning and the node stays private.

The domain is saved to `.node-meta` as `PUBLIC_RPC_DOMAIN`. After the node starts, setup checks DNS (`install-caddy.sh --phase=rpc-check-dns`) and then enables the endpoint (`--phase=rpc-enable`). If DNS doesn't point at the server yet, or you chose not to start the node, setup still completes and prints the exact `rpc-enable` command to run later.

### Existing node

Set up DNS, then:

```bash
sudo bash ~/telcoin-node-scripts/install-caddy.sh --phase=rpc-enable --rpc-domain node7.adiri.telcoin.network
```

Add `--public-ip <ip>` behind NAT. For a guided run, start `sudo bash ~/telcoin-node-scripts/install-caddy.sh` and pick `[2] Public RPC endpoint`; it checks DNS before it changes anything.

**If the dashboard already sits on `nodeN`**, move it and enable RPC in one step. Create the A record for `dashboard.nodeN.<suffix>` first (Caddy needs a certificate for that name too), then:

```bash
sudo bash ~/telcoin-node-scripts/install-caddy.sh --phase=rpc-enable \
  --rpc-domain node7.adiri.telcoin.network \
  --move-dashboard-to dashboard.node7.adiri.telcoin.network
```

Only the dashboard's hostname changes; its login stays the same. The interactive menu offers the same move when it sees the clash.

### What `rpc-enable` does

1. Writes the `tn-rpc` site into `/etc/caddy/Caddyfile`, leaves any dashboard site as it was, reloads Caddy (or starts it), and opens 80/443 in ufw when ufw is active.
2. Checks that reth serves WebSocket. If nothing listens on `WS_PORT` and the node was started without `--ws`, it adds `--ws --ws.addr 127.0.0.1 --ws.port <WS_PORT>` to the node's launch file. If it can't, it advertises https only and prints why.
3. Sets `rpc` on every worker entry in `node-info.yaml`: `https://<domain>/`, plus `wss://<domain>/` when step 2 passed. The node publishes this in its signed kad record, which is where gateways and wallets look for it.
4. Restarts the node once so the record and any new `--ws` flag take effect. If the node fails to start, the `node-info.yaml` and launch-file edits are rolled back, the node is restarted on its old config, and the script tells you whether it came back. A node that is still replaying its database is left to finish; the change applies once it's up.

Every Caddyfile change runs through `caddy validate` first, with the output shown and password hashes redacted. A failed check leaves the live file alone. A running Caddy is reloaded, not restarted, and a rejected reload puts the previous file back. (One exception: if the Caddyfile being replaced turned off Caddy's admin API, which `reload` needs, Caddy is restarted once and the script says so.) Running `rpc-enable` again with the same domain is safe: the node isn't restarted when `node-info.yaml` and the launch file are already right.

### Check it

```bash
sudo bash ~/telcoin-node-scripts/check-node.sh
sudo bash ~/telcoin-node-scripts/install-caddy.sh --phase=rpc-status
```

`check-node.sh` has a public RPC block: the domain, Caddy's state, an https and a wss probe (sent through Caddy on loopback, so the real certificate is checked), the WS port, and the URLs `node-info.yaml` advertises. It ends with `public RPC: OK`, or with `public RPC: WARN -- <reasons>` and the command that fixes it. Run it with `sudo`: `.node-meta` is root-only, and without it the block reports `unknown`. A private node shows `public RPC: not configured (private node)`.

`--phase=rpc-status` shows whether the site is enabled, what `node-info.yaml` advertises, and whether reth's WebSocket port is listening.

### Backups

Before every Caddyfile write, the live file is copied to `/etc/caddy/Caddyfile.bak.<YYYYmmdd_HHMMSS>` with its owner and mode. Nothing deletes these; remove old ones by hand.

### Turn it off

```bash
sudo bash ~/telcoin-node-scripts/install-caddy.sh --phase=rpc-disable
```

This clears `rpc` in `node-info.yaml`, restarts the node, and removes the `tn-rpc` site. The dashboard keeps running if it's enabled. Once no site remains, 80/443 are closed in ufw. The `--ws` flag stays in the launch file; reth's WebSocket only listens on `127.0.0.1`.

While a Node Manager site is enabled, `firewall-setup.sh --reset` (and the clean-slate reset offered by "Enable firewall with recommended defaults") keeps 80/443 open. Close them by disabling the site in `install-caddy.sh`.

---

## Quick Reference — Common Commands

The systemd unit is `telcoin` for fresh installs. (Nodes installed under an older version may
use a previous per-role unit name — see [One node per VM](#one-node-per-vm); the helper scripts
detect it automatically, but with raw `systemctl` substitute that name below.)

### Service management

```bash
# Start / stop / restart
sudo systemctl start telcoin
sudo systemctl stop telcoin
sudo systemctl restart telcoin

# Enable / disable auto-start on boot
sudo systemctl enable telcoin
sudo systemctl disable telcoin

# Reset after too many failed restarts
sudo systemctl reset-failed telcoin
```

### Logs

```bash
# Tail the node's stdout/stderr log file
sudo tail -f /var/log/telcoin/telcoin.log

# Or via journalctl
journalctl -u telcoin -f
```

### Health and configuration

```bash
# Health check for the local node
bash ~/telcoin-node-scripts/check-node.sh

# Health check including on-chain validator state
bash ~/telcoin-node-scripts/check-node.sh --address 0xYOUR_ADDRESS

# Interactive config editor (backs up the unit file before any change)
sudo bash ~/telcoin-node-scripts/edit-config.sh
```

### RPC queries

The default RPC port is `8545` (the reth default).

```bash
# eth_chainId
curl -s -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
  http://127.0.0.1:8545

# eth_blockNumber
curl -s -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://127.0.0.1:8545

# eth_syncing
curl -s -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' \
  http://127.0.0.1:8545

# tn_latestConsensusHeader -- the authoritative consensus state (use this
# rather than log-grepping for "got new consensus" entries)
curl -s -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"tn_latestConsensusHeader","params":[],"id":1}' \
  http://127.0.0.1:8545
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

## Testnet Add-ons

Three optional, **testnet-only**, reversible capabilities that let the Telcoin
Association help run the testnet. All are **off by default** and additive — a node that
opts out is unaffected. Full details and trust model: **[docs/testnet-addons.md](docs/testnet-addons.md)**.

- **Health monitoring** — exposes a health endpoint (port `43174`) probed by the
  Association's uptime monitor (plus any IPs you choose to add), so they can alert you
  when your node drops.
- **Centralized logging** — ships your node's logs to the Association's Loki (a Grafana
  Alloy sidecar) to help debug issues. Needs a per-operator ingest token.
- **VPN admin SSH** — lets the Association SSH into your node over a private WireGuard
  overlay (a sudo `tnadmin` user reachable only over the VPN) to help recover it.

You're offered each one during `setup-node.sh` (right after
network selection), or enable them later:

```bash
# Logging + health monitoring
sudo bash ~/telcoin-node-scripts/setup-observability.sh

# VPN admin SSH (or --disable to remove)
sudo bash ~/telcoin-node-scripts/setup-vpn.sh
```

Enabling the VPN requires explicit consent (you type `I CONSENT`); it never touches your
own SSH config, runs its host firewall dormant, and is undone by `setup-vpn.sh --disable`.

---

## WireGuard admin SSH (testnet)

`setup-vpn.sh` opts your node into the Telcoin Association's private WireGuard overlay and
grants the core team SSH over that overlay only (a sudo `tnadmin` user), so they can help
recover a stuck node. It is opt-in, testnet-only, additive, and reversible — your own SSH
config is untouched and `setup-vpn.sh --disable` removes everything.

```bash
sudo bash setup-vpn.sh                  # enrol (interactive, consent-gated)
sudo bash setup-vpn.sh --status         # diagnose tunnel + keys + firewall (read-only)
sudo bash setup-vpn.sh --sync-keys      # re-apply the maintainer SSH keys after a git pull
sudo bash setup-vpn.sh --apply-firewall # (re)add the overlay->SSH ufw rule if you run ufw
sudo bash setup-vpn.sh --disable        # tear everything down
```

- **[WGVPN.md](WGVPN.md)** — full operator + maintainer guide (enrol, verify, re-key, rename,
  the firewall model).
- **[DEBUG.md](DEBUG.md)** — connectivity runbook: if `tn_ssh` times out, work both ends with
  a symptom → cause → fix table.

Run `--status` first whenever a maintainer can't reach the node — it pinpoints which of the
five things (tunnel, reboot persistence, keys, sshd drop-in, firewall) needs attention and
prints the exact fix command.

---

## Changelog

> **Versioning note (from v1.1.48 onwards):** each script bumps `SCRIPT_VERSION`
> independently, so entries are titled `<script> vX.Y.Z`. Earlier entries used
> a flat "all scripts bumped to vX.Y.Z" convention.

### update-scripts v1.1.67 — re-cut for the observer-flag removal and public RPC consolidation
`update-scripts.sh v1.1.67` re-cut with refreshed `.sha256` sidecars. It carries lib/common
v1.4.0, setup-node v1.2.0, update-node v1.1.62, check-node v1.1.55, edit-config v1.2.6,
remove-node v1.2.8 and telcoin-ui v1.8.8 (entries below). On a node with the UI installed,
`ui/install-ui.sh --update` refreshes the engine copies in `/opt/telcoin-ui-update/`.

### update-node v1.1.62 — drops the retired --observer flag during updates
The node binary no longer has an `--observer` flag. v0.15.0-adiri still accepts it as a
hidden no-op, but the next release rejects it (`unexpected argument '--observer'`), so a
legacy start wrapper or docker unit that still passes it would leave the node down after an
update. When the update target is v0.15.0 or newer (or a branch, SHA or digest with no
version in it), the apply step now removes the flag from the launch file before restarting
the node. Docker installs reuse the launch-file backup the image swap already takes;
source installs back up the start wrapper first. Either way a failed health check rolls
the file back with the old image or binary. If the strip itself fails, the update warns
and carries on.

`--observer` and `--validator` are still accepted, because older copies of the UI helper
pass one on every `--json` call, but they do nothing. The node's role is decided on-chain.
An interactive run prints one line on stderr saying the flag was ignored; `--json` output
is unchanged. The "Detected node type" line is gone, and the validator downtime prompt now
reads the on-chain stake status directly (`node_is_staked_validator`, lib/common v1.4.0)
instead of parsing the human status report. It still errs toward prompting when the
status can't be read. `--help` now prints only the header block.

### telcoin-ui v1.8.8 — validator view follows the on-chain stake
The dashboard now picks the validator view from the node's stake in the ConsensusRegistry.
Once the node is synced, the UI calls `getValidator` for its execution address. A status of
Staked, PendingActivation, Active or PendingExit shows the validator dashboard; an unstaked
or exited address, or one the registry never whitelisted (the call reverts), shows the full
node view. `tn_isValidator` is no longer consulted, because it only says a BLS key is
recorded and not retired. While the RPC is down or the node is still syncing, the view
stays where it was.

The setup wizard's preflight no longer blocks on disk usage: 90% or more used is now a
warning. It also checks the host against three hardware tiers (full node, public RPC node,
validator minimum), names any shortfall, and shows the recommended validator spec. These
rows are warnings only. "Observer" now reads "Full node", the validator details read
"Staked validator", the fallback Docker image is `v0.15.0-adiri`, and the bump redeploys
the update engine copies in `/opt/telcoin-ui-update/`.

### check-node v1.1.55 — stake status decides validator checks; consensus role; --observer warning
check-node no longer has a validator or observer mode. The role is decided on-chain each
epoch, so the script reads the node's stake status from the ConsensusRegistry once per run
and uses that one answer twice: statuses Staked, Pending Activation, Active and Pending Exit
turn on the validator checks (missing from the committee headers is then an error), and the
same result is printed in the on-chain status section. v1.1.54 got the same answer by
grepping its own rendered report. When the status can't be read, the script says so and
treats the node as a full node for that run. `--validator` and `--observer` are accepted
but ignored with a one-line note on stderr; the `Node type:` header line is gone, and the
block-advancement state file is now a single `check-node.state` instead of one per role.

When the local RPC answers, the consensus section adds a `Consensus role:` line from the
node's `tn_nodeMode` method: `CvvActive` (voting in the current committee), `CvvInactive`
(in the committee, catching up) or `Observer` (following consensus, not in the committee).
Binaries without the method print nothing, and the line never changes the verdict.

The service section now warns when the node's launch file (the start wrapper, or the unit
of a legacy docker install) still passes `--observer`. v0.15.0-adiri ignores the flag, but
later releases reject it, so the node would not start after an update. The warning names
the file and the fix: run `update-scripts.sh` then `update-node.sh`, which strips the flag,
or delete the token and restart the service. It is not counted as a health issue, and it
stays quiet when the launch file can't be read (for example without sudo).

### edit-config v1.2.6 / remove-node v1.2.8 — role flags no longer required
The node binary no longer has an `--observer` flag: its role is decided on-chain each
epoch. `edit-config.sh` stops tracking a node type. The interactive display, its header
and the "Refresh chain configs" prompt now name the resolved service (`telcoin`, or the
legacy unit name on older installs). Node Manager UI helpers that haven't been updated
still pass `--observer` or `--validator` on every `--json --set` call. The flag is
accepted and ignored, and stdout stays pure JSON.

`remove-node.sh --json --remove <observer|validator>` now treats the token as the UI's
slot name, not a role. v1.2.7 compared it with `NODE_TYPE` in `.node-meta` and refused
with "node not installed" when they differed. Every new install records
`NODE_TYPE=observer` as a view hint, so removing from the UI's validator view always
failed. The check is gone, and either token removes the single installed node. The
interactive menu no longer labels the node by role, and the key-deletion warning is the
same for every node, since nothing on the server says whether its keys are staked.

### setup-node v1.2.0 — one domain, one advertisement; hardware gaps in the setup log
`--rpc-domain <hostname>` now fills in the RPC URLs that were separate flags. With a domain
and nothing else, keygen writes `https://<domain>/` and `wss://<domain>/` into
`node-info.yaml`, and `.node-meta` records `PUBLIC_RPC_URL=https://<domain>` and
`PUBLIC_WS_URL=wss://<domain>`. Explicit `--rpc-http`, `--rpc-ws`, `--public-rpc-url` and
`--public-ws-url` still win and are used as given, so the devnet fleet's keygen command
line is byte-for-byte the same as before. All four flags are now documented in the script
header.

When the URLs come from the domain, setup first asks the keytool whether it knows
`--rpc-http`. An older release that doesn't gets a plain keygen and a warning; the
advertisement then lands when `install-caddy.sh --phase=rpc-enable` runs after the node
starts. When keygen already wrote the same URLs, `rpc-enable` finds them in place and does
not restart the node. Setup warns when `--rpc-ws` comes without `--rpc-http` (it is
ignored) and when an explicit URL differs from the domain (`rpc-enable` will replace it).
If public RPC is left pending while `node-info.yaml` already advertises the URL, setup
says so and prints the `--phase=rpc-disable` command to withdraw it.

In `--json` mode the setup log now carries the hardware check: a `hardware:` line with the
summary and, when the box is below the minimum for a role, a `WARNING:` line naming it.
Setup still continues. Keygen no longer aborts on bash 3.2 when no advertised-RPC flags
are passed (an empty argument array under `set -u`).

### lib/common v1.4.0 — stake-status probe, --observer safety net, role-aware hardware check
`node_stake_status` is now the one `getValidator` probe. It prints a single
machine-readable line (`<status> <activation_epoch> <is_retired>`, `none` when the call
reverts because the address holds no ConsensusNFT, or `unknown`), and
`node_is_staked_validator` turns that into a yes / no / unknown exit code.
`check_validator_onchain_status` prints the same report as before through
`print_validator_onchain_status`, with two fixes: a rate limit or other non-revert RPC
error no longer reads as "No validator record found", and status 6 is shown as the `Any`
sentinel it is. A retired validator (the contract parks it at `Any` with `isRetired` set)
still prints `Status: Retired`; any other status with `isRetired` set gets `(Retired)`.

The staking steps printed after key generation now match the live `stake(bytes,(bytes))`
signature: export the calldata on the node with `keytool export-staking-args --calldata`,
send it with `cast send` from the machine that holds the validator wallet, then call
`activate()`.

Releases after v0.15.0-adiri reject `--observer`. `tn_node_strip_observer_flag` removes it
from a start wrapper or legacy docker unit and leaves comments, `--instance` and every
`--http` line alone. It writes the file back only after the edited copy passes those
checks. `tn_target_drops_observer` says whether a target tag, image or version is new
enough for the strip.

`check_hardware` now reports against the per-role tiers from the telcoin-network hardware
page (full node 2 cores / 8 GB, public RPC 4 / 16 GB, validator 8 / 32 GB, all on 2 TB)
instead of one flat baseline. It measures total disk size rather than free space, allows
5 % slack so a 16 GB box or a formatted 2 TB disk passes, warns at 90 % disk use, copes
with a missing `nproc` or GNU-only `df` options, and never stops setup. The fallback
docker image is now v0.15.0-adiri.

### lib/common v1.3.9 — devnet RPC load balancer URL
`DEVNET_RPC_URL` now defaults to `https://rpc.devnet.telcoin.network`, the global load
balancer in front of the devnet nodes, the same way testnet has a canonical URL. It is
still overridable from the environment. `setup-node.sh` no longer prints a blank RPC line
for devnet.

### telcoin-ui v1.8.7 — devnet load balancer, public WebSocket endpoints
The devnet load balancer is tried first for the network block and consensus lag cards,
with the individual node endpoints kept as fallbacks. A matching list of public `wss://`
endpoints sits alongside it. The bump also redeploys the update engine copies in
`/opt/telcoin-ui-update/`, so the UI's dashboard and RPC toggles run install-caddy v1.3.0.

### install-caddy v1.3.0 — safe Caddyfile swaps, one hostname per site, WebSocket preflight
Every Caddyfile write now takes one path: render to a temp file in `/etc/caddy`, run
`caddy validate` with its output shown (bcrypt hashes redacted), copy the live file to
`/etc/caddy/Caddyfile.bak.<YYYYmmdd_HHMMSS>` (never pruned), then rename the new file
into place keeping owner and mode. v1.2.0 validated in `/tmp` with the output hidden,
kept no backup of a managed file, and fell back from `reload` to `restart`, so one bad
config could take every site down. A serving Caddy is now reloaded, not restarted (the
one exception, announced, is replacing a file that set `admin off`, since reload needs
the admin API). A rejected reload restores the backup and exits non-zero, and
`rpc-enable` stops there: nothing is advertised and the node isn't restarted.

The dashboard and the public RPC endpoint need different hostnames. Caddy rejects two
sites on one name, and v1.2.0 surfaced that as a bare validation failure. The node's
public name (e.g. `node7.adiri.telcoin.network`) carries JSON-RPC + WebSocket; the
dashboard goes on `dashboard.<node-domain>`. A clash now dies before anything is written
and prints the fix. `--phase=rpc-enable --move-dashboard-to <hostname>` moves a dashboard
that sits on the RPC name, password hash kept, in the same swap; the interactive menu
offers the same move.

Before advertising `wss://`, `rpc-enable` checks that reth will serve WebSocket. When
nothing listens on `WS_PORT` and the launch lacks `--ws`, it adds `--ws --ws.addr
127.0.0.1 --ws.port <WS_PORT>` to the launch file (rolled back with `node-info.yaml` if
the node then fails to start). When it can't, only `https://` is advertised, with a
warning. Before this, a node started without `--ws` advertised a `wss://` URL that
returned 502.

The `node-info.yaml` editor handles both shapes: the legacy `p2p_info.worker:` map and
the current `p2p_info.workers:` list, where every entry gets the rpc. After a failed node
restart the brick guard runs `systemctl reset-failed` and reports the node's real state.
Hostnames are held to the RFC length limits (63 characters per label, 253 in all).
`--phase=<x>` now works without `--json`: one phase, no prompts, human-readable output
(what `setup-node.sh` uses). `--json --phase=rpc-status` adds `advertised_http`,
`advertised_ws` and `ws_listening`. See
[Public RPC endpoint](#public-rpc-endpoint-https--wss).

### setup-node v1.1.0 — public RPC at install time
Choice 2 ("Public") in the RPC access menu said "coming soon" and fell back to private.
It now asks for the public RPC domain, plus an optional inbound IP for NAT hosts. Flags
do the same without the prompt: `--rpc-domain <hostname>`, `--public-ip <ip>` (passed
through to `install-caddy.sh`), and `--no-public-rpc` to stay private. `--rpc-public`
now needs a domain; without one it warns and RPC stays private. The domain is persisted
in `.node-meta` as `PUBLIC_RPC_DOMAIN`.

Once the service is running, setup runs `install-caddy.sh --phase=rpc-check-dns` and then
`--phase=rpc-enable`: Caddy site, https + wss, the `worker.rpc` advertisement, and one
brick-guarded node restart. If DNS doesn't point at the server yet (or the enable fails),
setup still succeeds and prints the exact `rpc-enable` command to run later. Flags that
take a value now error when the value is missing.

`--rpc-http <url>` and `--rpc-ws <url>` are passed to `keytool generate validator`, so
the RPC endpoints are advertised in `node-info.yaml` from key generation (`--rpc-ws` is
only sent together with `--rpc-http`). `--public-rpc-url` and `--public-ws-url` are
recorded in `.node-meta` as `PUBLIC_RPC_URL` and `PUBLIC_WS_URL`. In `--phase=finalize`
the on-chain validator status check is informational and can no longer abort the phase,
which used to leave a running node that was never enabled for boot.

### check-node v1.1.54 — public RPC block
New section for the public RPC endpoint: the domain (from `.node-meta`, or from the
Caddyfile when that's unset), Caddy's state, https and wss probes sent through Caddy on
loopback with the real certificate, whether reth's WS port is listening, and the URLs
advertised in `node-info.yaml` (both the `worker:` and `workers:` shapes). It ends with an
OK/WARN verdict and, on WARN, the `install-caddy.sh --phase=rpc-enable` command that
fixes it. A private node prints `not configured (private node)`. Without sudo
`.node-meta` isn't readable, so the block says `unknown (.node-meta not readable — run
with sudo)` instead of guessing. Warn-only: it never changes the health verdict or the
exit code.

### firewall-setup v1.5.2 — reset keeps the Caddy edge open
`--reset` (and the clean-slate choice in the menu) wiped every ufw rule and never put
80/443 back, which took a public RPC endpoint or dashboard offline. It now re-adds them
before re-enabling ufw when Caddy is installed and the Caddyfile is managed by the Node
Manager (the marker on its first line, or a `tn-rpc` / `tn-dashboard` fence). To close
80/443, disable the sites in `install-caddy.sh`; it closes them once no site remains.

### lib/fallback v1.0.2 — custom data directories
`tn_resolve_data_dir` now honours `DATA_DIR` from `.node-meta`, so the scripts that find
`node-info.yaml` through it (`install-caddy.sh`, and `setup-node.sh`'s check of the
advertisement) work on nodes installed with a custom data directory instead of looking
under `/var/lib/telcoin`.

`update-scripts.sh v1.1.66` re-cut with refreshed `.sha256` sidecars. `ui/server.py
v1.8.7` refreshes the root-owned copy in `/opt/telcoin-ui-update/`, so the UI's
dashboard and RPC toggles run install-caddy v1.3.0 (see telcoin-ui v1.8.7 above).

### install-caddy v1.2.0 — public RPC site (missed entry)
Shipped 2026-06-30 without a changelog line. The managed Caddyfile gained a second site,
fenced so either can be toggled without touching the other: `https://<rpc-domain>/`
proxies JSON-RPC to reth on loopback (CORS and `OPTIONS` preflight answered at the edge),
and WebSocket upgrades on the same name go to the WS port, so it serves `wss://` too.
Enabling writes `worker.rpc` into `node-info.yaml` so the endpoint is advertised
on-network, then restarts the node under a brick guard that rolls the edit back if the
node fails to start. Adds the interactive menu (dashboard / public RPC / status) and the
`rpc-status`, `rpc-check-dns`, `rpc-enable` and `rpc-disable` JSON phases.

### update-node v1.1.61 — force-fetch tags so a re-cut release tag can't resurrect an old build
Release tags are occasionally re-cut at the same name (a bad `v0.13.0-adiri` build was
retagged to a corrected commit). Both prepare flows checked the requested ref out
local-first, so a node that already held the OLD tag silently rebuilt the retired
commit — and the `git describe` version marker still read like the right release.
Prepare (interactive and `--json`) now runs `git fetch origin --tags --force` before
checkout, and the newest-tag probe (`latest_source_ref`) fetches with `--force` too,
matching the thorough refresh `setup-node.sh` already does on reused clones. Offline
prepares keep working: a failed fetch is tolerated and checkout proceeds against
local refs.

### update-node v1.1.60 — update lock, artifact-identity verify, apply-path hardening
Three operational fixes to the update engine (`lib/common.sh v1.3.8`):

- **One update at a time.** A UI-triggered update and a CLI run could previously run
  concurrently — double service stop, racing writes to `.pending-update`, interleaved
  binary/image swaps. Every mutating mode now takes `/var/lock/telcoin-update.lock`
  (`flock`, kernel-released on any exit, holder PID reported on contention); read-only
  `--check` polls never block a real update.
- **Verify means the new version is live.** Post-apply verification used to pass on
  "service active + RPC responds", which a no-op update also satisfies. Source applies
  now require the installed binary to hash-match the prepared build; docker prepares
  record the pulled image ID and applies require the running container to be on it.
  Mismatch triggers the existing rollback. Pending states written by older versions
  still apply (the identity check skips with a warning).
- **No more mid-apply aborts.** Sourcing `lib/common.sh` had silently re-enabled
  `set -e`, so an unguarded failure after "service stopped" aborted the script with the
  node down and the designed verify→rollback flow never ran. Errexit is now off (as the
  script's own header always intended), every state-changing step is explicitly
  handled, pending-state write failures can no longer report "saved", and a failed
  rollback restore stops loudly with manual recovery steps instead of restarting the
  new artifact and misreporting "rolled back".

### edit-config v1.2.5 — edits now hit the file the service actually reads
Config detection grepped the unit's `ExecStart` for `docker run`, but current installs
launch through the start wrapper (`/opt/telcoin/start-<svc>.sh`) — docker installs were
misdetected as "binary", every field showed unknown, edits silently rewrote unit lines
the service never reads, and the docker-image editor refused to run. Detection and all
edits (listeners, p2p ports, metrics, verbosity, image — menu and `--json set`) now
resolve the launch file the same way `update-node.sh` does and write there; listener
edits on binary installs update the unit `Environment=` line and the wrapper `export`
together. Also fixes a latent verbosity-edit bug where the first ` -v ` on a docker
launch line — the volume flag — could be replaced instead of the verbosity flag. RPC
editing on wrapper installs is refused with manual instructions for now.

### setup-node v1.0.1 — keygen secrets hygiene
The docker keygen passed the BLS passphrase as `-e TN_BLS_PASSPHRASE="<value>"` — visible
in `ps`/`/proc/*/cmdline` for the life of the keygen. It now uses name-only env
pass-through, the same convention as the runtime wrapper. The passphrase file is also
created `0600` from the first byte (umask subshell) instead of write-then-chmod.

`update-scripts.sh v1.1.65` re-cut with refreshed `.sha256` sidecars. `ui/server.py
v1.8.6` carries no UI change — the bump redeploys the root-owned update engine in
`/opt/telcoin-ui-update/` so UI-driven updates and config edits pick these up.

### update-node v1.1.57 — sync submodules before source builds
The v0.12.0-adiri release moved the `tn-contracts` submodule pointer, and the new
code `include_str!`s files that only exist in the new submodule commit. Both source
prepare paths in `update-node.sh` did `git checkout` + `git pull` but never
`git submodule update`, so every source-build node hit a cargo error about a missing
`deployments-*.json` mid-update. (Fresh installs were unaffected — `setup-node.sh`
already syncs.)

`lib/common.sh v1.3.7` adds `tn_sync_submodules`, which runs `git submodule sync`
then `git submodule update --init --recursive --force` to pin submodules to the
checked-out ref. Both `update-node.sh` prepare paths (interactive and UI/`--json`)
now call it and hard-fail with a clear message before any build starts; the
chain-config refresh paths (`ensure_chain_configs_available`, `edit-config.sh
v1.2.4`) sync too but only warn on failure, since chain configs live in the
superproject.

**If your source update already failed on this:** just re-run the update — prepare
now heals the submodule before building. Or fix it manually first:

```bash
sudo git -C /opt/telcoin-source submodule update --init --recursive --force
```

`update-scripts.sh v1.1.64` re-cut with refreshed `.sha256` sidecars. `ui/server.py
v1.8.5` carries no UI change — the bump redeploys the root-owned update engine in
`/opt/telcoin-ui-update/` so UI-driven updates pick up the fix.

### testnet baseline → v0.12.0-adiri
adiri testnet moved to `v0.12.0-adiri`, and this release points every default at it.
`lib/common.sh v1.3.6` bumps `DEFAULT_DOCKER_IMAGE` (the fallback used only when the
registry is unreachable) and raises `MIN_SOURCE_VERSION_TESTNET` from `0.9.1` to
`0.12.0`; `ui/server.py v1.8.4` and the setup wizard's docker-image placeholder follow.

**This upgrade is wire-protocol-breaking — a v0.11 node cannot peer with a v0.12
node at all.** Every libp2p protocol string is now namespaced by chain id, including
the gossipsub protocol id itself (`/meshsub/1.1.0` → `/tn-meshsub-{chain_id}/1.1.0`),
all four gossip topics are renamed, and request-response moved to `/0.0.2`. Multistream
negotiation fails before a subscribe frame is exchanged, so a node left on `v0.11.0-adiri`
is not "behind" — it is partitioned, with no peers and no path back to consensus. Update.

No data-dir wipe and no resync: genesis is unchanged, and v0.12 reads existing v0
consensus packs in place. Note the reverse is NOT true — v0.11 cannot read the packs
v0.12 writes, so a downgrade stops being clean once a new epoch's pack is created
(adiri epochs are 6h).

Source installs rebuild from the tag: `git checkout v0.12.0-adiri` and
`cargo build --release --features adiri`, which `update-node.sh --prepare` does for you
and which takes 20-40 minutes on typical operator hardware. It runs before any downtime.

`update-scripts.sh v1.1.63` re-cut with refreshed `.sha256` sidecars.

### update-node v1.1.56
Docker updates now edit the file that actually launches the container. Current docker
installs run `docker run` from the start wrapper (`/opt/telcoin/start-<svc>.sh`) rather
than the unit's ExecStart, but the update path still read and rewrote the systemd unit —
so `--check` reported no current image and prepare/apply failed on every wrapper-based
install. Image detection and both apply paths now resolve the wrapper-vs-legacy-unit
target via `tn_node_launch_target` and patch whichever file carries the image reference.
Two more fixes ride along: `TN_UPDATE_VERIFY_TIMEOUT=<secs>` overrides the 45s
post-restart health window (a fleet-wide simultaneous restart for a wire-protocol-breaking
upgrade re-forms quorum slower than one node restarting, and the default window triggered
a spurious auto-rollback), and the interactive docker apply no longer corrupts its restore
path — `backup_unit_file` printed its info line to stdout inside the caller's `$(...)`
capture, so a rollback would have copied from a garbage path. `update-scripts.sh v1.1.62`
re-cut with refreshed `.sha256` sidecars.

### VPN admin SSH — fix tnadmin key-login lockout + confirm-and-reuse on re-run
`setup-vpn.sh v1.4.0` fixes opted-in nodes going unreachable to maintainers. `tnadmin` was
created with no password and then `passwd -l`'d, leaving the shadow field `!`-locked; Ubuntu
sshd (`UsePAM yes`) runs PAM **account** management *after* the maintainer key matches, and a
`!`-locked / aging-flagged account is refused there — so the correct key was denied login. It
is now set password-less but login-enabled (shadow `*`, not `!`; aging/expiry cleared),
re-asserted on `--selfheal`, and reported by a new `--status` check (3b). A re-run now also
detects an existing install and offers to **reuse** the overlay IP already in `.node-meta` /
`wg0.conf` instead of re-walking the full assignment prompt. `update-scripts.sh v1.1.61`
re-cut with refreshed `.sha256` sidecars (`setup-vpn.sh`, `update-scripts.sh`).

### Branded install URL + portable checksums
The installer now has a branded front door: `curl -fsSL https://install.telcoin.network | bash`
(the raw GitHub URL still works as a fallback). `main` stays the single source of truth — a
GitHub Pages deploy republishes `install.sh` on every push to `main`, and `update-scripts.sh`
keeps pulling each file from `raw.githubusercontent.com/.../main` as before. `install.sh` also
gains a git-less tarball install path so the one-liner works on a fresh macOS with no `git`.
`update-scripts.sh v1.1.60` routes SHA-256 verification through a portable `_sha256` helper
(`sha256sum` on Linux, `shasum -a 256` on macOS), and every updater-tracked file now ships a
committed `.sha256` sidecar (generated by `tools/gen-checksums.sh`, enforced fresh by CI), so
downloads are verified on macOS observers instead of erroring.

### update-node v1.1.55
Fixes Docker tag auto-suggestion, which silently returned nothing. `fetch_docker_tags`
piped the registry JSON into `python3` while the inline script arrived on the same stdin
via a heredoc, so the parser read its own source instead of the tag list (surfaced by the
new `shellcheck` CI gate, SC2259). The payload is now passed through the environment, so
the "Update available / pick a version" menu is populated again.

### VPN admin SSH — operator self-service verbs
`setup-vpn.sh v1.1.0` adds three verbs so operators can verify and repair overlay SSH
without an admin: `--status` (PASS/FAIL triage across tunnel, reboot persistence, the
maintainer key set, the scoped sshd drop-in, and the active firewall, each with the exact
fix command), `--sync-keys` (re-apply the vendored maintainer keys after a `git pull`;
local-only, so it works before connectivity is fixed), and `--apply-firewall` (idempotently
re-add the overlay→:22 ufw rule for operators who enable/tighten ufw after enrolling).
Completes the vendored maintainer key set (`lib/wgvpn/peers/ssh/grant2.pub`), and
`update-scripts.sh v1.1.55` now ships every maintainer key in `TESTNET_ADDONS_BUNDLE` (it
previously delivered only two of them). New docs: [WGVPN.md](WGVPN.md) and [DEBUG.md](DEBUG.md).

### Health endpoint — operator-chosen source IPs
`firewall-setup.sh v1.4.0` lets operators expose the health port (`43174/tcp`) to the
Association monitor **plus** their own monitoring host(s), not TA-only. Use "Manage node
ports" → choice 2 ("Association monitor + your IPs") to add/remove single IPv4, IPv6, or
CIDR sources. The set is persisted in `.node-meta` (`KUMA_EXTRA_SRC`) and reapplied
wherever the TA rule is applied (`lib/common.sh v1.3.0` `apply_kuma_rule`), so it survives
the `ufw --force reset` that "Enable recommended defaults" performs. `setup-observability.sh
v1.1.0` restores the extras when health monitoring is re-enabled and removes their ufw
rules (keeping the persisted set) when it is disabled. See
[docs/testnet-addons.md](docs/testnet-addons.md).

### Testnet add-ons — VPN admin SSH, centralized logging, health monitoring
New opt-in, testnet-only, reversible add-ons for external operators (`lib/common.sh
v1.2.0`; new `setup-vpn.sh`, `setup-observability.sh`, `lib/observability.sh`,
`lib/testnet-addons.env`, `observability/config.alloy`, vendored `lib/wgvpn/`).
Operators are offered each during node setup, or run the standalone scripts later.
`firewall-setup.sh v1.3.0` source-restricts the health port to the Association monitor
(`104.155.184.201/32`), adds a testnet add-on rules menu, and keeps the WireGuard
overlay from being locked out by an SSH whitelist. `setup-validator.sh v1.2.16` /
`setup-observer.sh v1.2.17` bake the healthcheck + JSON-log flags on the first pass and
persist new `.node-meta` keys. `remove-node.sh v1.2.6` / `check-node.sh v1.1.51` tear
down and report the add-ons. See [docs/testnet-addons.md](docs/testnet-addons.md).

### telcoin-ui v1.0.3
Fixes the dashboard "Recent Traces / No traces yet" panel when spans are already
visible in the Jaeger UI: the node registers its OTLP service name as a
`telcoin`-prefixed name plus a node-identity suffix (e.g. `telcoin-QCZPqMY2zfp`),
so the backend's exact-name Jaeger query never matched. Traces, trace stats, and
the Jaeger `service_registered` flag now resolve the real service name by
`telcoin` prefix.

### telcoin-ui v1.0.2
Tracing toggle now restarts the node with `systemctl restart --no-block`, so the
API returns once the restart is queued instead of blocking on the node's stop
window (fixes the "tracing change failed - timeout"). `install-ui.sh` gains a
port-8080 preflight: if the service fails to come up because another process
(e.g. a hand-run `python3 server.py`) is shadowing it, the installer names the
holder and the remedy instead of leaving a silent crash-loop.

### telcoin-ui v1.0.0
First release of the optional web UI: node health, live logs, configuration, and
OpenTelemetry traces over an SSH tunnel. Binds `127.0.0.1` only; all privileged
actions go through one root-owned, arg-validated helper pinned by a no-wildcard
sudoers drop-in. Installed via `ui/install-ui.sh`.

### update-scripts v1.1.49
Tracks the web UI (gated on `ui/server.py`'s `UI_VERSION`): fetches the UI bundle
when a newer version is published and redeploys it via `install-ui.sh --update`.
Loosens the version grep to read Python constants alongside bash `readonly`.

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

## Contributing

These scripts are installed and updated **live from `main`** — operators fetch each file
directly from `raw.githubusercontent.com/.../main`, so a broken merge reaches them
immediately. Two CI gates (`.github/workflows/ci.yml`) protect that supply chain on every
pull request and push to `main`:

- **Shell parse + lint** — `bash -n` on every script under both modern bash and macOS's
  bash 3.2 (observers run on macOS), plus `shellcheck`. A parse error on `main` would brick
  `curl … | bash`, so these are blocking.
- **Checksum integrity** — every updater-tracked file has a committed `<file>.sha256` sidecar
  that `update-scripts.sh` verifies after download. **After editing any tracked script you
  must regenerate and commit its sidecar**, or CI fails:

  ```bash
  bash tools/gen-checksums.sh
  git add '*.sha256'      # quoted: git matches sidecars at any depth
  git commit -m "chore: refresh checksums"
  ```

  `tools/gen-checksums.sh` derives its file list from the `SCRIPTS`, `UI_BUNDLE`, and
  `TESTNET_ADDONS_BUNDLE` arrays in `update-scripts.sh`, so it always matches exactly what the
  updater fetches.

---

## License

Licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE) or
  <http://www.apache.org/licenses/LICENSE-2.0>)
- MIT license ([LICENSE-MIT](LICENSE-MIT) or <http://opensource.org/licenses/MIT>)

at your option.

### Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion
in the work by you, as defined in the Apache-2.0 license, shall be dual licensed as above,
without any additional terms or conditions.

---

## Support

For issues with the Telcoin Network protocol or chain configuration, contact the Telcoin Association development team.

For issues with these setup scripts, raise them via the appropriate Telcoin Association channels.
