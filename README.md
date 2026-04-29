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
| `lib/common.sh` | Shared functions used by the above scripts (not run directly) |

---

## Node Types

### Observer Node
An observer node syncs the full chain state and serves JSON-RPC queries but does **not** participate in block consensus. It requires no approval from the Telcoin Association.

Best for: developers, exchanges, wallets, dApps, block explorers, or anyone needing a private RPC endpoint.

- RPC port: **8541** (instance 5)
- P2P port: **30303**
- Metrics port: **9000**

### Validator Node
A validator node participates in Narwhal/Bullshark consensus, proposes and signs blocks, and earns TEL rewards. Validators on Telcoin Network must be GSMA-approved MNOs with prior approval from the Telcoin Association.

- RPC port: **8545** (instance 1)
- P2P port: **30303**
- Metrics port: **9000**

---

## Requirements

### Hardware (minimum)
- CPU: 4 cores
- RAM: 8GB
- Disk: 100GB free
- OS: Linux (Ubuntu 22.04 or 24.04 recommended)
- Static IP address
- Internet connection with port 30303 open inbound (TCP/UDP)

### Software
The scripts will install or check for everything needed. You do not need to install anything manually beforehand.

### For Validators Only
- Prior approval from the Telcoin Association
- A registered Ethereum address that holds a ConsensusNFT

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
```

**3. Run the setup**
```bash
# For an observer node
sudo bash ~/telcoin-node-scripts/setup-observer.sh

# For a validator node
sudo bash ~/telcoin-node-scripts/setup-validator.sh
```

**4. Edit configuration after setup (optional)**
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
- Creates a dedicated `telcoin` system user (no login shell, for security)
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

---

## Security Design

The scripts follow Linux security best practices:

- **Dedicated service user** — the node runs as a `telcoin` system user with no login shell and no sudo access. If the process is compromised it cannot access your other files or accounts.
- **Strict file permissions** — key files are mode 600 (readable only by owner). The node-keys directory is mode 700.
- **Passphrase never logged** — the BLS passphrase is passed via environment variable, never on the command line where it would appear in process lists.
- **Systemd hardening** — the service uses `NoNewPrivileges`, `PrivateTmp`, and `ProtectSystem=strict` to limit what the process can do.
- **RPC localhost only** — the RPC port defaults to 127.0.0.1 (localhost only). It is never exposed to the internet by default.

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

The node needs port **30303** open for inbound P2P connections.

**Linux firewall (ufw):**
```bash
sudo ufw allow 30303/tcp
sudo ufw allow 30303/udp
```

**Router port forward:**
Forward TCP/UDP port 30303 from WAN to your server's local IP address.

The RPC port (8541/8545) should **not** be opened to the internet unless you are specifically running a public RPC endpoint with a reverse proxy in front of it.

---

## Validator Onboarding Flow

Setting up a validator involves both off-chain (node setup) and on-chain (contract interaction) steps. The setup script handles the off-chain steps and guides you through what is needed on-chain.

### Full Process

**Step 1 — Node setup (script handles this)**
Run `setup-validator.sh`. The script installs the binary, generates your BLS keys, copies chain configs, and starts the node service.

**Step 2 — Share your node-info.yaml (operator action)**
After key generation the script displays your `node-info.yaml` and its file path. Send this file to the Telcoin Association. It contains your BLS public key, proof of possession, and network addresses — nothing secret.

**Step 3 — Receive your ConsensusNFT (Telcoin Association action)**
The Association calls `mint(yourAddress)` on the ConsensusRegistry contract. You cannot do this yourself — it is the whitelist/approval step.

**Step 4 — Stake your TEL (operator action)**
Once your NFT is minted, call `stake()` on the ConsensusRegistry contract:
- Contract address: `0x07e17e17e17e17e17e17e17e17e17e17e17e17e1`
- Parameters: your BLS public key and proof of possession (both in node-info.yaml), plus the required TEL stake as msg.value
- Use MetaMask, a hardware wallet, or any EVM-compatible tool

**Step 5 — Activate (operator action)**
Call `activate()` on the same contract. This enters you into the activation queue.

**Step 6 — Go active (automatic)**
At the next epoch boundary the protocol activates your validator automatically. You will start participating in consensus and earning TEL rewards.

### Checking Your Status

The setup script checks your on-chain status automatically after the node starts. You can also check it at any time using the health check script:

```bash
bash ~/telcoin-node-scripts/check-node.sh --address 0xYOUR_VALIDATOR_ADDRESS
```

The script will show one of these statuses:

| Status | Meaning | Next Action |
|---|---|---|
| No NFT found | Not yet whitelisted | Contact Telcoin Association |
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

# Custom service or RPC endpoint
bash ~/telcoin-node-scripts/check-node.sh --service telcoin-observer --rpc http://127.0.0.1:8541
```

The health check verifies:
- Systemd service is running
- RPC endpoint is responding
- Sync status
- Latest block number
- Peer count
- Disk space
- Memory usage

---

## Common Commands

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
| Docker | Pulls the official Docker Hub image | **Coming soon** — `docker pull telcoin/telcoin-network:latest` |
| Existing binary | Use a binary already on this machine | Useful if you have already compiled it |

---

## Network Binding

During setup you will be asked how the node should listen for incoming P2P connections:

**IPv6** — recommended for cloud and data centre servers. Binds to all IPv6 interfaces (`::`) and is NAT-free, meaning no router port forward is required.

**IPv4** — for home or bare metal servers. The script will auto-detect your server's internal IP address (e.g. `10.x.x.x` on cloud, `192.168.x.x` on home networks) and ask you to confirm it. You will also need to forward TCP/UDP port 30303 on your router to this server.

**Important distinction for cloud/data centre operators:**
- **Internal IP** (e.g. `10.70.70.2`) — what the node binds its listener to. Auto-detected by the script via `hostname -I`.
- **External/Public IP** — what peers use to reach your node. Fetched automatically via `api.ipify.org` and used for validator key registration in `node-info.yaml`.

These are two different addresses on cloud servers and the script handles both correctly.

---

## Wiping and Starting Fresh

To completely remove a node and start over:

```bash
sudo systemctl stop telcoin-observer
sudo systemctl disable telcoin-observer
sudo rm -f /etc/systemd/system/telcoin-observer.service
sudo systemctl daemon-reload
sudo rm -rf /var/lib/telcoin
sudo rm -rf /etc/telcoin
sudo rm -rf /var/log/telcoin
sudo rm -rf /opt/telcoin
sudo rm -rf /opt/telcoin-source
sudo userdel telcoin 2>/dev/null
```

To wipe chain data only (keeps keys and config, forces resync):
```bash
sudo systemctl stop telcoin-observer
sudo rm -rf /var/lib/telcoin/observer/db
sudo systemctl start telcoin-observer
```

---

## Key Backup

Your node keys are stored in `/var/lib/telcoin/observer/node-keys/`. Back these up immediately after setup.

If you lose your keys you will lose your node identity and will need to re-register with the Telcoin Association (validators) or regenerate keys and restart (observers).

Store your BLS passphrase separately from the key files — in a password manager or secure offline location. If you lose the passphrase the encrypted key files are unreadable.

---

## Changelog

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
