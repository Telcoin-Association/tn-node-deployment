# Telcoin Network Node Setup Scripts

Automated setup scripts for running a node on the Telcoin Network. Built for MNO operators — interactive, guided, and validated at every step.

There is one node identity. Every node installs validator-capable and follows consensus from day one; staking and on-chain activation are what let it validate. The protocol decides a node's role from on-chain committee membership each epoch, not from a setup flag.

> **New to running a node?** Follow [`OPERATOR.md`](OPERATOR.md), the step-by-step runbook: install, sync, public RPC, staking, activation and day-2 operations. This README is the reference behind it.
>
> **Mobile network operator evaluating a node?** The partner guide, [`docs/partner/mno-node-guide.pdf`](docs/partner/mno-node-guide.pdf), is the runbook rewritten for partners and branded for hand-off. Its source is [`docs/partner/mno-node-guide.md`](docs/partner/mno-node-guide.md).

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
| `prepare-stake.sh` | Check that the node can stake and print the `cast` commands for `stake()` and `activate()`; re-sign the proof of possession for another address |
| `install-caddy.sh` | Serve the public RPC endpoint (https + wss) and the optional dashboard through Caddy |
| `migrate-node-naming.sh` | Move a legacy per-role install onto the unified `telcoin` layout |
| `setup-observability.sh` | Opt-in centralized logging + health monitoring (testnet add-on) |
| `setup-vpn.sh` | Opt-in WireGuard admin SSH for the Telcoin Association (testnet add-on) |
| `lib/common.sh` | Shared functions used by the above scripts (not run directly) |

> `setup-observer.sh` and `setup-validator.sh` still exist as thin deprecated shims that forward to `setup-node.sh`.

---

## Run a node

Anyone can run a full node — no approval required. Install the scripts, run `setup-node.sh`, and the node syncs the full chain state, serves JSON-RPC, and follows Narwhal/Bullshark consensus.

Every node is provisioned validator-capable from day one. "Just following consensus" and "validating" are not two install options — the difference is on-chain state (stake plus committee membership) that the protocol reads each epoch. Until you stake and activate, the node behaves like any full node.

Any node that is not in the current committee is an **observer**, including a staked validator between committee seats. The protocol works this out each epoch, and the node reports it through the `tn_nodeMode` JSON-RPC method: `CvvActive` (voting in the committee), `CvvInactive` (in the committee, catching up) or `Observer`.

Setup uses the same ports on every node:

- RPC: **8545** (HTTP) / **8546** (WS) — the reth defaults
- P2P: **49590** (primary) and **49594** (worker), UDP/QUIC, by convention. A node set up on other ports keeps them; `check-node.sh` and the firewall status in `firewall-setup.sh` show the ones it uses.
- Metrics: **9101** (loopback only)

### Become a validator (optional)

To validate you additionally need, in order:

1. **Approval** — Telcoin Association onboarding. Validators must be GSMA-approved MNOs; email support@telcoin.org before purchasing hardware.
2. **Stake** — submit the stake transaction with your BLS public key and proof of possession.
3. **Activation** — call `activate()` on-chain and go active at the next epoch boundary.

The node software does not change. The validator view follows your execution address's stake status in the ConsensusRegistry contract (`getValidator`): Staked, PendingActivation, Active or PendingExit (statuses 1 to 4) count as a staked validator; everything else does not. `check-node.sh`, `update-node.sh`, `prepare-stake.sh` and the web UI all read that status. The UI asks the network's public RPC first, so it shows the validator dashboard as soon as the stake is on-chain, even while the node is still syncing; there is no node-type toggle to flip. Staking makes the node eligible for a committee seat, and it votes only in epochs where it holds one. The step-by-step (with `cast` commands) is in [Validator Onboarding Flow](#validator-onboarding-flow) below.

### One node per VM

Each machine runs exactly **one** node, installed under a single, consistent identity:

- systemd unit: **`telcoin`** (`telcoin.service`)
- Docker container name (Docker installs): **`telcoin`**
- config directory: **`/etc/telcoin`**
- data directory: **`/var/lib/telcoin`**

`/etc/telcoin/.node-meta` records no role. `setup-node.sh` (1.3.0 and later) and
`migrate-node-naming.sh` (1.2.1 and later) remove the old `NODE_TYPE` hint, because the
on-chain stake status decides the validator view. A node migrated by an older
`migrate-node-naming.sh` may still carry `NODE_TYPE=observer`; nothing reads it any more, so
the line is harmless. Because there is only ever one
node on the box, the binary is launched with no node-instance flag and serves RPC on the reth default ports (`8545`/`8546`).

> **Upgrading from an older install?** Earlier versions used a separate unit name and
> per-role config/data directories for each node type. Those legacy per-role installs keep
> working untouched — a compatibility shim (`lib/fallback.sh`) detects the old layout and
> resolves the correct unit, container, and directories automatically. Nothing is renamed or
> migrated on its own; to move an existing install onto the unified layout, run
> `migrate-node-naming.sh`. Fresh installs always use the unified `telcoin` identity above.

---

## Requirements

### Hardware

Size the machine for the role you plan to run. The figures come from the telcoin-network hardware requirements and count physical cores: cloud vCPUs are usually hyperthreads, so an 8 vCPU instance has about 4 physical cores. The validator row only matters if you intend to stake and validate.

| Role | Minimum | Recommended |
|---|---|---|
| Observer, follower (RPC on localhost) | 2 cores, 8 GB RAM | 4 cores, 16 GB RAM |
| Observer, public RPC | 4 cores, 16 GB RAM | 8 cores, 32 GB RAM |
| Validator | 8 cores, 32 GB ECC RAM | 16 cores, 64 GB ECC RAM |
| Storage, every role | 2 TB TLC NVMe SSD | 4 TB TLC NVMe SSD |

Validators also need 200 Mbps symmetric bandwidth at minimum, 1 Gbps recommended.

The hardware preflight in `setup-node.sh` prints one line per role and only warns; it never blocks setup. It compares the tiers with physical cores, counted from `lscpu`, `/proc/cpuinfo` or `sysctl hw.physicalcpu`, and the report says what it measured ("4 physical cores"). When only the logical count can be read it says so ("8 logical CPUs"); halve a cloud instance's vCPU count yourself in that case. It does not check for ECC memory or NVMe.

> Storage note: TLC NVMe drives are specifically required over QLC. TLC supports 1,000-3,000 P/E cycles vs 100-1,000 for QLC, making TLC significantly more durable for continuous blockchain write operations.

### Supported Operating Systems

- Ubuntu 22.04+ LTS
- Debian 12+
- Red Hat Enterprise Linux (RHEL) 9+ and compatible distributions

`setup-node.sh` needs systemd 247 or newer for `LoadCredential` and stops on anything older, so RHEL 8 (systemd 239) is not supported. macOS is not supported for running a node.

### Software
The scripts will install or check for everything needed. You do not need to install anything manually beforehand.

### To validate
- GSMA MNO status — only GSMA-approved MNOs may validate
- Hardware approval from the Telcoin Association — email support@telcoin.org before purchasing equipment
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
Opens the ports every node needs: SSH, Uptime Kuma, and the node's P2P consensus ports (UDP 49590/49594 unless the node was set up with others). When Caddy serves the public RPC endpoint or the dashboard on the box, it allows TCP 80 and 443 too.

**4. Check node health any time**
```bash
sudo bash ~/telcoin-node-scripts/check-node.sh

# Include on-chain validator status
sudo bash ~/telcoin-node-scripts/check-node.sh --address 0xYOUR_ADDRESS
```

### Day-to-day operations

```bash
# Edit a running node's configuration (multiaddrs, ports, RPC mode, bootstrap peers, state export, etc.)
sudo bash ~/telcoin-node-scripts/edit-config.sh

# Update the node to a new version (rebuild from source OR pull a new Docker image)
sudo bash ~/telcoin-node-scripts/update-node.sh

# Validators: check that the node can stake and print the stake and activate commands
sudo bash ~/telcoin-node-scripts/prepare-stake.sh

# Update these scripts themselves to the latest version from GitHub
bash ~/telcoin-node-scripts/update-scripts.sh

# Remove a node installation (interactive, with explicit confirmations)
sudo bash ~/telcoin-node-scripts/remove-node.sh
```

> `update-node.sh` vs `update-scripts.sh`: the first updates *the node binary or Docker image* to a new release; the second updates *these helper scripts* themselves from GitHub. Different things.

---

## What the Setup Script Does

Each script walks through numbered steps:

**Step 1: Pre-flight Checks, Network and Install Method**
- Checks you are running as root
- Detects your Linux distribution and package manager
- Reports the hardware against each role's minimum (warns only, never blocks)
- Checks internet connectivity and required ports
- Checks systemd version (247+ required: Ubuntu 22.04+, Debian 12+, RHEL 9+)
- Asks which network to connect to (Adiri testnet or mainnet), then offers the testnet add-ons. The network is chosen here, so the script's own step headers go from Step 1 to Step 3
- Installs any missing tools (curl, git)
- Asks how to obtain the binary (build from source, Docker, or existing)
- On testnet, refuses a source release or Docker image older than `v0.13.0-adiri`, the first release that has all three of `keytool set-rpc`, proof-of-possession signing and state export (set-rpc and proof-of-possession signing arrived in v0.12.0-adiri, state export in v0.13.0-adiri). `main`, a commit or an image digest is allowed with a warning
- Installs all dependencies upfront before configuration begins (Rust, build tools, Docker image pull, etc.)
- For binary/source installs, asks which passphrase protection method to use (LoadCredential or TPM/vTPM)

**Step 3: Node Configuration**
- Asks for port and directory configuration
- Asks for external and listener IP addresses for P2P
- Asks whether RPC is private (default) or public; public asks for a DNS name for the node (`--rpc-domain` answers this up front; see [Public RPC endpoint](#public-rpc-endpoint-https--wss))

**Step 4: System Infrastructure**
- Creates a dedicated system user and group (default: telcoin/telcoin, customisable). The user has no login shell for security.
- Creates all required directories under /opt/telcoin, /var/lib/telcoin, /etc/telcoin, /var/log/telcoin
- Creates the reth internal log cache directory
- Verifies the binary is valid and executable
- Records the install method and the Docker image or binary path in `.node-meta`, so a later `--json --phase=finalize` can read them back
- With `--bootstrap-peers`, `--enable-state-export` or `--state-export-keep`, asks the release whether it has each flag and stops, before any key is made, when it does not. A bootstrap peers map is checked with the release's own parser and installed as `/etc/telcoin/bootstrap-peers.yaml` (see [Bootstrap peers](#bootstrap-peers))

**Step 5: Key Generation**
- Asks for your Ethereum address and P2P multiaddrs
- Asks you to set a BLS key passphrase (entered twice to confirm, never shown on screen)
- Runs the telcoin-network keytool to create the node's cryptographic keys (BLS + P2P)
- With a public RPC domain, has the keytool advertise `https://<domain>/` and `wss://<domain>/` in `node-info.yaml`
- Stores keys in /var/lib/telcoin/node-keys/ with strict permissions
- Stores passphrase in /etc/telcoin/bls-passphrase (mode 600)
- If TPM selected: seals passphrase to TPM chip, shows it once, prompts operator to store offline

**Step 6: Configuration**
- Copies the official chain-config files (genesis.yaml, committee.yaml, parameters.yaml) from the cloned repository

**Step 7/8: Systemd Service**
- Writes a wrapper script to /opt/telcoin/start-telcoin.sh that reads the passphrase securely at runtime
- Writes a systemd service file to /etc/systemd/system/telcoin.service using LoadCredential
- Configures the correct network listener addresses for P2P connectivity
- With a bootstrap peers map, the wrapper passes `--bootstrap-peers "$(cat /etc/telcoin/bootstrap-peers.yaml)"`, so the file is read at every start
- Optionally starts the node immediately
- Optionally enables auto-start on server reboot
- With a public RPC domain and a started node: checks DNS, then enables the endpoint through Caddy (no extra node restart when `node-info.yaml` already advertises the URLs)
- Ends with a summary that lists the P2P ports `node-info.yaml` advertises (every worker), uses them in the firewall reminder, and links the [operator runbook](OPERATOR.md)

Every answer and flag that reaches the start wrapper, the unit or `.node-meta` is validated. Interactive prompts ask again until the answer is valid: ports (1 to 65535), the data, config, log and install directories (absolute paths of letters, digits and `. _ / -`, no `..`), the Docker image, the binary path, the execution address (`0x` and 40 hex digits) and the P2P listener and external addresses. A bad flag stops setup before it needs root, with the flag named, and so does a `--json` keygen without `--address`, any of the four multiaddr flags or `TN_BLS_PASSPHRASE`, before any build or install work starts. The region label for the testnet add-ons is reduced to letters, digits, `_` and `-`, at most 32 characters, with a warning.

---

## System Layout

After setup, files are organised as follows. There is one layout for every node; nothing in
the paths depends on whether the node validates.

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
  consensus-db/state_exports/       -- per-epoch state exports, epoch-N/ (only with state export on)

/etc/telcoin/
  bls-passphrase                    -- BLS key passphrase (mode 600, root only)
  bootstrap-peers.yaml              -- bootstrap peers map (only with --bootstrap-peers; root, mode 644)
  .node-meta                        -- install metadata read by the helper scripts and UI (mode 600)

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
directories whatever the node's role. Installs created by older versions of these scripts used
per-role unit names and per-role subdirectories under `/etc/telcoin` and `/var/lib/telcoin`;
those keep working as-is and the helper scripts locate them automatically via the
compatibility shim in `lib/fallback.sh`.

`.node-meta` is updated one key at a time, so keys that other scripts keep there survive a
re-run of setup. The keys the scripts read back:

| Key | Written by | Holds |
|---|---|---|
| `NETWORK` | setup-node | `testnet`, `mainnet` or `devnet`. check-node, edit-config and prepare-stake take the expected chain from it |
| `INSTALL_METHOD`, `DOCKER_IMAGE`, `BINARY_PATH` | setup-node, at step 4 | What runs the node. `BINARY_PATH` is removed on a Docker install |
| `BOOTSTRAP_PEERS_FILE` | setup-node | The installed peers map, or empty |
| `STATE_EXPORT` | setup-node | `off`, `unlimited`, or the number of exports kept |
| `PUBLIC_RPC_DOMAIN`, `PUBLIC_RPC_URL`, `PUBLIC_WS_URL` | setup-node, `install-caddy.sh --phase=rpc-enable` | The public RPC hostname and URLs. rpc-disable removes them |
| `VALIDATOR_ADDRESS` | setup-node, `prepare-stake.sh --rotate-address` | The execution address that stakes. check-node warns when it differs from the node's own address |

A `.node-meta` saved with CRLF line endings (edited on Windows, say) is read correctly, and the next script that writes a key rewrites the file with LF endings.

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
Open the P2P consensus ports — UDP/QUIC **49590** (primary) and **49594** (worker) by convention — on **every** node, not just ones that validate today. A node that later stakes and joins the committee behind a closed firewall is unreachable to its peers and silently misses consensus, so the ports are opened up front while the node is still just following consensus.

A node set up on other ports, or running more than one worker, needs its own ports open. `firewall-setup.sh` reads them from the node: the primary and worker 0 ports from the listener addresses the node starts with (the start wrapper, else the unit), then from `node-info.yaml`, then the defaults; workers 1 and up from `node-info.yaml`. `check-node.sh` lists them too.

**Linux firewall (ufw), default ports:**
```bash
sudo ufw allow 49590/udp
sudo ufw allow 49594/udp
```

**Router port forward (home/bare metal only):**
Forward the node's P2P ports (UDP 49590 and 49594 by default) from WAN to your server's local IP address. Cloud servers handle this via their network configuration.

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

The Telcoin Network documentation at https://docs.telcoin.network/ also covers staking, but its `stake` and `unstake` signatures are out of date; use the commands below. The runbook walks through the same steps with shell variables and a calldata check: [OPERATOR.md, Validators: stake and activate](OPERATOR.md#6-validators-stake-and-activate). Once the node has keys, `prepare-stake.sh` does the checks of Steps 2 and 3 on the node (whitelist, stake amount, balance, calldata), simulates the stake, and prints the exact `cast send` commands for Steps 3 and 5; see [Prepare to stake](#prepare-to-stake).

The commands below use the testnet RPC, `https://rpc.adiri.tel`. `https://rpc.telcoin.network` is the mainnet endpoint; mainnet has not launched, and until it does that hostname answers for testnet (chain 2017) as well.

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
Once whitelisted, export the stake calldata on the node. The keytool reads only `node-info.yaml`; it needs neither the passphrase nor the private keys, and the BLS keys never leave the node. It still insists on a passphrase source, so pass `--bls-passphrase-source no-passphrase` (without it, and without `TN_BLS_PASSPHRASE`, it exits 1). `-q` keeps its log line off stdout, so the output is the calldata alone. Both global flags go before `keytool`:

```bash
sudo /opt/telcoin/telcoin-network -q --bls-passphrase-source no-passphrase \
  keytool export-staking-args \
  --node-info /var/lib/telcoin/node-info.yaml --calldata
```

Docker installs run the same keytool from the node's image ([command in the runbook](OPERATOR.md#610-stake-by-hand)). Copy the `0x...` output to the machine that holds your wallet, read the stake amount, and send the calldata with exactly that value:

```bash
# Stake amount in wei: read the current stake version, then the first value stakeConfig returns
cast call 0x07E17e17E17e17E17e17E17E17E17e17e17E17e1 \
  "getCurrentStakeVersion()(uint8)" --rpc-url https://rpc.adiri.tel
cast call 0x07E17e17E17e17E17e17E17E17E17e17e17E17e1 \
  "stakeConfig(uint8)(uint256,uint256,uint256,uint32)" <VERSION> \
  --rpc-url https://rpc.adiri.tel

# Submit stake: the calldata encodes stake(bytes,(bytes))
cast send 0x07E17e17E17e17E17e17E17E17E17e17e17E17e1 <CALLDATA> \
  --value <STAKE_AMOUNT> \
  --from <VALIDATOR_ADDRESS> --ledger \
  --rpc-url https://rpc.adiri.tel
```

Use `--trezor` for a Trezor. For a key in software, `--account <name>` signs with an encrypted keystore you create once with `cast wallet import <name> --interactive`; `--interactive` asks for the raw key each time, so prefer a hardware wallet or a keystore for a funded validator address. Never use `--private-key`: the key would be on cast's command line, where any user of that machine can read it with `ps`.

**Step 4 — Sync your node**
Wait for the node to catch up with the network. `eth_syncing` always returns `false` on Telcoin Network, so don't use it. Run the health check, which compares your node's block height with the public RPC, until it reports `All checks passed -- node is healthy and caught up`:
```bash
sudo bash ~/telcoin-node-scripts/check-node.sh
```

**Step 5 — Activate (operator action)**
Once synced, call `activate()` to enter the activation queue:
```bash
cast send 0x07E17e17E17e17E17e17E17E17E17e17e17E17e1 \
  "activate()" \
  --from <VALIDATOR_ADDRESS> --ledger \
  --rpc-url https://rpc.adiri.tel
```

**Step 6 — Go active (automatic)**
At the next epoch boundary your status changes to Active, which makes the validator eligible for committee seats. The earliest seat comes two epochs after that: `activate()` mined in epoch E makes the validator active at E+1, with its earliest committee seat at E+3. `check-node.sh` shows the activation epoch, the earliest seat and whether the node is in the committee for this epoch or the next two. It votes only in epochs where it holds a seat; between seats `tn_nodeMode` reports `Observer`, which is normal.

**Leaving later (operator action)**
Call `beginExit()` while Active. The status moves to PendingExit and the protocol exits you once no current or upcoming committee needs you. When the status reads Exited, wait one more epoch (`check-node.sh --address` says when `unstake()` becomes eligible), then reclaim the stake with `unstake(address,bool)` and `false` as the second argument:
```bash
cast send 0x07E17e17E17e17E17e17E17E17E17e17e17E17e1 \
  "beginExit()" \
  --from <VALIDATOR_ADDRESS> --ledger \
  --rpc-url https://rpc.adiri.tel

# once Exited, one epoch later
cast send 0x07E17e17E17e17E17e17E17E17E17e17e17E17e1 \
  "unstake(address,bool)" <VALIDATOR_ADDRESS> false \
  --from <VALIDATOR_ADDRESS> --ledger \
  --rpc-url https://rpc.adiri.tel
```
`unstake` retires the validator permanently and burns its ConsensusNFT. The address cannot stake again; validating again needs new keys and a new NFT.

### Checking Your Status

```bash
sudo bash ~/telcoin-node-scripts/check-node.sh --address 0xYOUR_VALIDATOR_ADDRESS
```

| Status | Meaning | Next Action |
|---|---|---|
| No NFT found | Not yet whitelisted | Submit address to Telcoin Association |
| 0 Undefined | NFT minted, not staked | Run `prepare-stake.sh`, then stake (Step 3) |
| 1 Staked | Staked, not activated | Call `activate()` once synced |
| 2 PendingActivation | Activation queued | Wait for the next epoch boundary |
| 3 Active | Eligible for committee seats | No action needed; keep the node healthy |
| 4 PendingExit | `beginExit()` called | Wait for the protocol to exit you |
| 5 Exited | Out of the validator set | Wait one more epoch, then call `unstake(address,bool)` with `false` |
| Retired (6 with `isRetired` set) | `unstake` ran: stake returned, NFT burned | None; this address cannot stake again |

Statuses 1 to 4 count as a staked validator for `update-node.sh` and the web UI; everything else is treated as not staked. `check-node.sh` decides whether a node missing from the consensus headers is an error from its committee membership, not from the status alone (see [Health Check](#health-check)).

---

## Prepare to stake

`prepare-stake.sh` checks, on the node, everything the stake transaction depends on, then prints the commands to send it. It never reads, asks for or prints a private key, and it never sends a transaction: run the printed commands on the machine that holds the validator wallet.

```bash
sudo bash ~/telcoin-node-scripts/prepare-stake.sh
sudo bash ~/telcoin-node-scripts/prepare-stake.sh --network-rpc https://rpc.adiri.tel
sudo bash ~/telcoin-node-scripts/prepare-stake.sh --json
```

It checks, in this order, and prints each step:

1. The network RPC serves the node's chain. The chain comes from `NETWORK` in `.node-meta` (testnet when none is recorded), and the default RPC is that network's public RPC: testnet `https://rpc.adiri.tel`, mainnet `https://rpc.telcoin.network`, devnet `https://rpc.devnet.telcoin.network`. `--network-rpc <URL>` overrides it. An RPC that serves another chain stops the run before anything else.
2. The validator address, read from `node-info.yaml` and shown EIP-55 checksummed. It warns when `.node-meta` records a different address.
3. The governance whitelist: the address holds the ConsensusNFT (`balanceOf`).
4. The validator status (`getValidator`). A staked address gets the `activate()` step only; any later status is reported and the run ends with "nothing to do".
5. The stake amount the registry asks for now, `stakeConfig(getCurrentStakeVersion())`, in TEL and wei.
6. The address's TEL balance against the stake plus gas.
7. The `stake()` calldata, exported by the node's own keytool.
8. A simulation of `stake()` from the address (`eth_estimateGas`). A revert is named (InvalidProofOfPossession, DuplicateBLSPubkey, InvalidStakeAmount, InvalidStatus, a paused registry and more) together with what to do about it.
9. How far the local node trails the network. More than 50 blocks behind is a warning.

Then it prints the `cast send` commands for `stake()` and `activate()` with the network RPC, signing with `--ledger`, and the epoch arithmetic: `activate()` mined in epoch E makes the validator active at E+1, with its earliest committee seat at E+3. A note after the commands names the other key sources: `--trezor` for a Trezor, `--account <name>` for an encrypted keystore created once with `cast wallet import <name> --interactive`, or `--interactive` to paste the key when cast asks. It also says never to use `--private-key`, which would put the key on cast's command line, where any user of that machine can read it with `ps`.

`--json` sends the human output to stderr and prints one JSON object on stdout at the end, holding every value the run read.

| Exit code | Meaning |
|---|---|
| 0 | Ready to stake, staked and ready to activate, nothing to do, or rotated ("Rotated: node-info.yaml now names 0x...") |
| 1 | Usage or environment: a bad flag, not root, no `node-info.yaml`, no way to run keytool, no passphrase, a restart that failed |
| 2 | The network RPC could not be reached, serves another chain, or the on-chain state could not be read; or keytool ran but could not export the `stake()` calldata ("keytool could not export the stake() calldata ...", with keytool's own error) |
| 3 | Not ready or refused: not whitelisted, short of TEL, the simulation reverts, a rotation that cannot be done now, or a rotation declined at the confirmation ("Cancelled: nothing changed.") |
| 4 | The rotation failed and `node-info.yaml` was put back |
| 130, 143, 129 | Interrupted by Ctrl-C, SIGTERM or SIGHUP (`state` is `interrupted` in `--json`) |

The script needs `lib/common.sh` 1.6.0; with an older library it stops and says to run `update-scripts.sh`.

### Staking from another address

The execution address is signed into the node's proof of possession. To stake from a different address before anything has staked, keep the keys and re-sign:

```bash
sudo bash ~/telcoin-node-scripts/prepare-stake.sh --rotate-address 0xNEW_ADDRESS
```

This runs keytool `generate pop` for the new address with the same BLS key, keeps a backup of `node-info.yaml` beside it, records the address as `VALIDATOR_ADDRESS` in `.node-meta`, and restarts the node (a committee node waits for the epoch boundary first; see [Restarts and the epoch boundary](#restarts-and-the-epoch-boundary)). `--yes` skips the confirmation and is required with `--json`; `--no-restart` leaves the restart to you. If the re-sign fails, `node-info.yaml` is put back (exit 4).

An interrupted rotation (Ctrl-C, SIGTERM or SIGHUP) never leaves a half-written file. While the proof of possession is being signed, the script lets keytool finish, puts `node-info.yaml` back from the backup, releases the update lock and exits 130, 143 or 129. Once the re-signed file has passed its checks, an interruption leaves it in place and the script prints how to finish: "To finish, run: sudo bash prepare-stake.sh --rotate-address <0xNEW> --yes". That run signs the proof of possession again (so it needs the passphrase), records the address and restarts the node.

Rotation is refused (exit 3) once the current address has any stake status or is retired, because a registered BLS key cannot move to another address; when the new address has staked or is retired; and while `update-node.sh` is applying an update ("Refused: an update is in progress (PID N); try again when it has finished.").

Rotation needs the BLS key passphrase. It comes from `TN_BLS_PASSPHRASE`, else the `bls-passphrase` file in the config directory, else a prompt on the terminal. sudo drops `TN_BLS_PASSPHRASE` unless you run `sudo --preserve-env=TN_BLS_PASSPHRASE`. The file is used only when it is mode 600 or stricter; a file other users can read is skipped with a warning. On a TPM install the plaintext file is gone after sealing, so use the variable or the prompt. The passphrase reaches keytool only through its environment, never a command line.

---

## Health Check

Run at any time after setup to verify your node is healthy:

```bash
# Health check for the local node
sudo bash ~/telcoin-node-scripts/check-node.sh

# Include validator on-chain status (queries the ConsensusRegistry contract)
sudo bash ~/telcoin-node-scripts/check-node.sh --address 0xYOUR_VALIDATOR_ADDRESS

# Compare against a different network RPC (default: the public RPC of the network in
# .node-meta; testnet https://rpc.adiri.tel)
sudo bash ~/telcoin-node-scripts/check-node.sh --network-rpc https://rpc.example.org

# Skip the network RPC query (fully local / air-gapped diagnostics)
sudo bash ~/telcoin-node-scripts/check-node.sh --no-network

# Custom local RPC endpoint or service name
sudo bash ~/telcoin-node-scripts/check-node.sh --rpc http://127.0.0.1:8545 --service telcoin
```

Run it with `sudo`. `/etc/telcoin/.node-meta` is root-only (mode 600), and without root the script can't read the recorded network, execution address, data directory, RPC port or public RPC domain. There is no `--validator` or `--observer` switch any more: the script still accepts both, prints a note and ignores them. A value flag given without its value (`--rpc` as the last argument, say) prints a usage error.

The health check verifies:
- **Network** — a `Network:` header line names the network from `.node-meta` (testnet, devnet or mainnet), its chain ID and where that came from. The local chain ID must match that network's; with no network recorded, any Telcoin chain ID (2017, 487, 32285) passes with a note. When the network RPC itself serves another chain (today `https://rpc.telcoin.network` answers for testnet, 2017), the report warns that the RPC serves chain X and skips the comparison instead of blaming the node.
- **Execution address** — compares `VALIDATOR_ADDRESS` in `.node-meta` with the address the node runs with (its `tn_info` answer, else `node-info.yaml` on disk) and warns near the top of the report when they differ, also with `--no-network` or the local RPC down. The warning says what to do: restart the node when `node-info.yaml` already holds the `.node-meta` address (as after `prepare-stake.sh --rotate-address --no-restart`); otherwise restart it if you rotated with `--no-restart`, or set `VALIDATOR_ADDRESS` in `.node-meta` to the node's address.
- **Systemd service status** — running, with restart-loop detection (warns if the unit has restarted more than 5 times). The section also lists what the node runs (Docker image or binary), its bootstrap peers and state export when set, its P2P ports and the RPC URLs it advertises.
- **Local RPC mode** — classified as `HEALTHY`, `SLOW` (responding but >6s), `DISABLED` (HTTP 200 but `-32601 method not found`), or `DOWN` (connection refused). Previously all four looked the same.
- **Network consensus state** — queries the network RPC (the public RPC of the network in `.node-meta`, testnet `https://rpc.adiri.tel`, unless `--network-rpc` says otherwise) for ground truth: current block, epoch, how many authors the latest commit has ("N authors in the latest commit"), and how fresh that commit is.
- **Local consensus state** — calls `tn_latestConsensusHeader` on the local node and applies the freshness contract: `block == 0` → ERROR (fully stalled), commit-timestamp age > 60s → WARN (stale), else OK. Also reports lag vs network in blocks.
- **Author presence** — checks whether your authority ID appears in the latest commit's consensus headers. Catches the failure mode where a validator is running (systemd green, RPC up) but silent (not authoring headers). The authority ID comes from the node's own `tn_info` answer; `--authority-id <BASE58>` is the fallback when the local node does not answer, and the report says which one it used, or why it has none (for example the local RPC is DOWN, or `tn_info` has no `authority_id`). What absence means depends on on-chain committee membership for the current epoch: an error for a member, expected for anyone else. When membership cannot be read, absence is an error only for an Active or PendingExit validator whose node does not report `Observer`, judged by the stake status of the node's own address (from `tn_info` or `node-info.yaml`, never `.node-meta` or `--address`). With the network RPC down, the check uses the latest commit the local node has seen.
- **Epoch and committee** — the epoch ID, the time to the next boundary and its UTC time, the committee size from the chain ("Committee of epoch E: N members (on-chain)", which can be more than the authors in the latest commit), committee membership for this epoch and the next two, and for a staked validator the activation epoch and the earliest committee seat (activation + 2). It warns when a committee member reports `Observer`, and says to let the node catch up when its epoch is behind, or else to look in the node log (`journalctl -u <svc> -n 200`). It compares the node's worker count with the required count (`WorkerConfigs.numWorkers()`, 1 on testnet today); fewer workers than required is a health issue, and because workers are fixed when the keys are generated and no script adds one, the report says to email support@telcoin.org before the node is due for a committee seat. When the node runs more than one worker, each extra worker's RPC and WebSocket ports are probed.
- **Reputation score** — your own score from `sub_dag.reputation_scores.scores_per_authority` (the singular `reputation_score` of older releases is read as a fallback) alongside the committee average. Flags scores below half-average.
- **Validator on-chain status** — uses the address from `--address`, or the execution address recorded in `.node-meta`, to call the ConsensusRegistry contract and report your validator state (Undefined / Staked / PendingActivation / Active / etc.) with the next step. An Exited validator is told whether `unstake()` is eligible now. When the status cannot be read, the report gives the reason (for example `http 429`).
- **Consensus role** — prints `Consensus role: CvvActive`, `CvvInactive` or `Observer` from `tn_nodeMode` when the node binary supports it. Informational; it never changes the verdict.
- **Legacy `--observer` flag** — warns when the node's launch file still passes `--observer`, which `v0.16.0-adiri` and later reject at startup (exit status 2). `update-node.sh` strips it when it updates to `v0.15.0-adiri` or later.
- **Public RPC** — on a node with a public RPC domain, see [Check it](#check-it). It also warns when the Caddy site predates block v2 (with the command that refreshes it) and when `--http.api` or `--ws.api` names `debug`, `trace` or `admin`. A list that starts with `all` is not warned about: the node reads it as plain `all` and ignores the rest (see [Public node tuning](#public-node-tuning)).
- **Disk space** — uses the actual data directory from `/etc/telcoin/.node-meta` (falls back to `/var/lib/telcoin`), so the check reports usage on whichever mount actually holds chain data — not just the default. On macOS it reads `df -Pk`.
- **Memory** — total / available / percent used. On macOS, which has no `/proc/meminfo`, the memory check is skipped with a note and a CPU line shows the physical core count, so the report still runs to the end.

With a `lib/common.sh` older than 1.6.0, the report warns once in its header and skips the checks that need the newer library.

### Why RPC instead of log files?

Earlier versions of `check-node.sh` grepped the node log file for fixed string markers like `peer metrics heartbeat` and `got new consensus`. That approach was fragile (any change to the node binary's log format silently broke it) and gave misleading output — for example a "P2P peers since startup" metric whose label was wrong and whose count had no time window. As of v1.1.31 the script uses `tn_latestConsensusHeader` directly, which is stable, accurate, and works whether or not the node writes a parseable log file.

The author-presence check is the most useful signal — it answers the question *"is the network actually seeing my node participate?"* using the network's own consensus headers as the source of truth. With the local RPC closed off, the node cannot report its authority ID, so pass it with `--authority-id`; the check then runs on the network's headers alone.

---

## Firewall Setup

After setting up your node, run the firewall setup script to harden your server. This script can be run at any time — both to apply changes and to view the current state of your firewall.

```bash
sudo bash ~/telcoin-node-scripts/firewall-setup.sh
```

The script is menu-driven and interactive. It never makes changes without explicit confirmation.

### What it covers

**View current status** — run this at any time to get a full overview of your firewall state, SSH configuration, open ports, and any security warnings. No changes are made. It names the installed node service (`telcoin.service`, or the legacy unit) and reports each P2P port with its label, for example "UDP 51000 is open (primary)". Before firewall-setup 1.6.0 this view stopped right after "Firewall is active" on any box with ufw active; update the scripts if yours still does. When `ufw status verbose` itself fails, the default incoming policy reads as unknown and the view carries on.

**Enable firewall with recommended defaults** — sets default deny inbound, allow outbound, and keeps SSH accessible. When Caddy serves the public RPC endpoint or the dashboard on the box, it allows TCP 80 and 443 before it turns ufw on, so the site stays reachable; the plan shown before the confirmation lists them. Every rule step is checked: when one fails (a `ufw allow` that errors, say), the script names the step and its exit code and stops there, before ufw is turned on, keeping the rules it already added. Always do this before restricting SSH access.

**Manage SSH access** — disable password authentication (keys only), disable root login, change SSH port. Each option shows the current state and warns clearly before making any changes.

**Manage node ports** — opens the node's P2P consensus ports inbound on every node and manages the health port. The ports follow the node: the primary and worker 0 ports come from the listener addresses the node starts with (the start wrapper, else the unit), then from `node-info.yaml`, then the defaults 49590 and 49594; workers 1 and up come from `node-info.yaml`. It doesn't toggle TCP 80/443: `install-caddy.sh` adds the rules when it enables the public RPC endpoint or the dashboard (both served by Caddy), and removes them when the last site is disabled.

**Manage trusted IP whitelist** — add or remove specific IP addresses or CIDR ranges that are allowed SSH access. Shows your current session IP so you don't accidentally lock yourself out.

### Important warnings

- **Test SSH in a new terminal** before closing your current session after making any changes
- **Whitelist your IP first** before enabling default deny or restricting SSH
- **Every node** opens its P2P ports inbound (UDP 49590/49594 by convention) — a node that later stakes behind a closed firewall would otherwise miss consensus
- Never open the RPC port (8545) directly to the internet — serve it through Caddy on port 443 instead (see [Public RPC endpoint](#public-rpc-endpoint-https--wss))
- A reset to a clean slate wipes every ufw rule, but keeps 80/443 while Caddy serves a Node Manager site (public RPC or dashboard). To close them, disable the site with `install-caddy.sh`

### When to run it

Run `firewall-setup.sh` after completing node setup and before going live. For production validator nodes this is strongly recommended. For home/testing setups it is optional but good practice.

### JSON mode (Node Manager UI)

The UI drives the script with `--json --status`, `--json --enable` and `--json --port <port>/<proto> on|off`. `--json --status` keeps its `ports` keys and adds `p2p_ports`: one `{"port", "proto", "label", "allowed"}` object per P2P port, with labels `primary` and `worker-N`, and `allowed` set to null while ufw is off (and on a box with no node, where the default ports are listed). When `ufw status verbose` fails, the status object still comes back, with `"default_incoming": "unknown"`. A failed rule step during `--json --enable` ends the run with an `error` event and `done` `ok: false` whose message says the rules added before it stay and ufw was not enabled. The `--port` allowlist is unchanged: 49590/udp, 49594/udp and 43174/tcp. With a `lib/common.sh` older than 1.6.0 the script warns that it cannot read `node-info.yaml` and checks the primary and worker 0 ports only.

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
| Existing binary | Use a binary already on this machine | Useful if you have already compiled it. Setup searches `PATH`, `/usr/local/bin`, `/opt` and `/home`, or takes `--binary-path <absolute path>` |

On testnet, setup accepts `v0.13.0-adiri` or later for a source build or a Docker image, whether the release is picked from the list, typed at the prompt or passed as `--build-ref` / `--docker-image`. An older tag is refused with the reason; `main`, a commit or an image digest is allowed with a warning, since setup cannot tell its release.

### Docker Install Notes

When Docker is selected the script will:
- Install Docker if not already present
- Ask for the full image URL and tag. The default is the highest-versioned `-adiri` tag in the Google Artifact Registry (`us-docker.pkg.dev/telcoin-network/tn-public/adiri`), or `v0.16.0-adiri` when the registry can't be reached
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

## Restarts and the epoch boundary

A node voting in the committee should not be down when the epoch changes: the epoch closes at the first commit at or after the boundary, and the committee exchanges epoch votes for 60 to 75 seconds afterwards. These scripts check before they restart the node: `update-node.sh` (apply), `edit-config.sh`, `install-caddy.sh --phase=rpc-enable` and `--phase=rpc-disable`, `setup-observability.sh` (enabling health monitoring, logs or metrics) and `prepare-stake.sh --rotate-address`. Everything else restarts the node at once, like a plain `systemctl restart`: `migrate-node-naming.sh`, and in the Node Manager UI the Start, Stop and Restart buttons, the trace toggles and the node-name change.

Only a node that reports `CvvActive` from `tn_nodeMode` waits, and only when the boundary is `TN_EPOCH_MARGIN` seconds away or closer: the script waits for the epoch to close, then `TN_EPOCH_SETTLE` seconds more, with a progress line every `TN_EPOCH_POLL` seconds. It never waits longer than `TN_EPOCH_WAIT_MAX`; at that limit it warns and restarts. A node reporting `Observer` or `CvvInactive` (a committee member still catching up) is not delayed, and a restart that rolls back a failed change never waits. When the boundary passed more than `TN_EPOCH_MARGIN` seconds ago and the epoch is still open (a stalled chain, or a node far behind), the script warns once and restarts.

| Variable | Default | Effect |
|---|---|---|
| `TN_SKIP_EPOCH_WAIT=1` | unset | Skip the wait. `update-node.sh` and `edit-config.sh` also take `--no-epoch-wait` |
| `TN_EPOCH_MARGIN` | 300 | Wait only when the boundary is this many seconds away or closer |
| `TN_EPOCH_SETTLE` | 90 | Seconds to wait after the epoch closes |
| `TN_EPOCH_WAIT_MAX` | 1800 | Longest wait in seconds, settle included; 0 turns the wait off |
| `TN_EPOCH_POLL` | 15 | Seconds between progress lines, 5 to 20 |

Pass a variable through sudo on the command line, for example `sudo TN_SKIP_EPOCH_WAIT=1 bash ~/telcoin-node-scripts/install-caddy.sh --phase=rpc-disable`. A script running against an older `lib/common.sh` that lacks the wait says so and restarts without it; run `update-scripts.sh`. A restart by hand (`sudo systemctl restart telcoin`) never waits, so on a committee node check the time to the next boundary with `check-node.sh` first.

---

## Editing the configuration

`edit-config.sh` changes the configuration of the installed node without hand-editing the systemd unit or the start wrapper.

```bash
# Interactive menu
sudo bash ~/telcoin-node-scripts/edit-config.sh

# One edit, then a restart and a health check
sudo bash ~/telcoin-node-scripts/edit-config.sh --set state_export=10

# The same with JSON events (what the Node Manager UI runs)
sudo bash ~/telcoin-node-scripts/edit-config.sh --json --set metrics=off
```

| Menu item | What it changes |
|---|---|
| 1 | Listener addresses (`PRIMARY_LISTENER_MULTIADDR`, `WORKER_LISTENER_MULTIADDR`) |
| 2 | Metrics address |
| 3 | Log verbosity |
| 4 | RPC access (private, public or disabled) |
| 5 | BLS passphrase |
| 6 | P2P ports |
| 7 | Docker image (Docker installs only) |
| 8 | Bootstrap peers |
| 9 | State export (off, every epoch, or the last N epochs) |
| 10 | Private forward targets (private networks only) |
| 11 | Refresh chain configs (pull the latest genesis, committee and parameters). It replaces `parameters.yaml`, so set item 10 again afterwards |
| 12 | Restart node |
| 13 | Exit |

Items 8 to 10 are new in edit-config 1.3.0, which moved Refresh chain configs, Restart node and Exit from 8, 9 and 10 to 11, 12 and 13.

| `--set` field | Values |
|---|---|
| `primary_listener`, `worker_listener` | `/ip4/<addr>/udp/<port>/quic-v1` or `/ip6/...` |
| `metrics` | `<IPv4>:<port>` adds `--metrics` or changes it; `off` removes it |
| `verbosity` | `-v` to `-vvvvv` |
| `docker_image` | `<registry/path>:<tag>`, or pinned by digest (`<name>@sha256:...`). Docker installs only; the image is pulled first |
| `bootstrap_peers` | An absolute path to a peers map, or `none` to remove the flag and the installed file. See [Bootstrap peers](#bootstrap-peers) |
| `state_export` | `off`; `unlimited` (`--enable-state-export`, every export kept, `v0.13.0-adiri` or later); or `N` from 1 to 999999 (`--state-export-keep N` as well, only the newest N kept, `v0.15.0-adiri` or later) |
| `allow_private_forward_targets` | `true` or `false`: the `parameters.yaml` key that lets the node forward transactions to committee RPC endpoints on private addresses. `true` is refused on testnet (2017) and mainnet (487), and when the genesis chain ID cannot be read |

How an edit runs:

- `bootstrap_peers` and `state_export` ask the installed release whether it has the flag; a release without it refuses the edit and says to update the node first.
- `--set` restarts the node and checks that it stays up. If it does not, every file the edit changed (the launch file, `parameters.yaml`, the peers file) is put back and the node is restarted on its previous configuration. `--set` works without `--json` too, with readable output.
- An edit that changes nothing, because the value is already in place, writes nothing and does not restart the node.
- Every edit takes the update lock. While `update-node.sh` is applying an update, edit-config refuses with "an update is in progress (PID N); try again when it has finished".
- Before restarting a committee node it waits for the epoch boundary; `--no-epoch-wait` skips the wait. See [Restarts and the epoch boundary](#restarts-and-the-epoch-boundary).
- An edit is written before that wait, so a run stopped before its restart (Ctrl-C, SIGTERM, SIGHUP, or the Node Manager UI page closing) puts every file it changed back and exits 130, 143 or 129: "Stopped by SIGTERM before the restart, so the edit was rolled back". Once the restart has been issued, the edit stays. Refresh chain configs is the exception: a run stopped during its wait keeps the new chain files for the next restart.
- A launch file with more than one node command carrying `--http` is refused rather than half edited. Remove or comment out the extra command and try again.
- Refresh chain configs reads `NETWORK` from `.node-meta` and refuses unless the node's genesis and the new one declare the same chain ID. It copies the network's `genesis.yaml`, `committee.yaml` and `parameters.yaml` over the node's, which drops an `allow_private_forward_targets` value, so set that again afterwards. On a source build checked out at a release tag, the usual testnet install, `git pull` fails: refresh prints git's error and "git pull failed in <dir>. Chain configs unchanged."
- edit-config 1.3.0 needs `lib/common.sh` 1.6.0; with an older library it stops and says to run `update-scripts.sh`.

### Bootstrap peers

A bootstrap peers map replaces the bootstrap servers in the node's genesis with peers you choose; the node dials them at start. It needs `v0.15.0-adiri` or later. The map is YAML or JSON, keyed by each peer's BLS public key, and each value is the `p2p_info` block from that peer's `node-info.yaml` (its primary and its workers):

```yaml
<peer BLS public key>:
  primary:
    network_address: /ip4/198.51.100.20/udp/49590/quic-v1/p2p/<peer id>
    network_key: <primary network key>
    rpc: ~
  workers:
    - network_address: /ip4/198.51.100.20/udp/49594/quic-v1/p2p/<peer id>
      network_key: <worker network key>
      rpc: ~
```

Give it to a new node with `setup-node.sh --bootstrap-peers FILE`, or to a running one with `edit-config.sh --set bootstrap_peers=FILE` (menu item 8). The same rules apply to both:

- The file must be a regular file of at most 64 KiB that its group and other users can already read (`chmod 644`). The map does not stay private: the installed copy is world-readable, and the check passes the map on the node binary's command line, where other users can see it. A file with mode 600, 640 or 604, for example, is refused with the `chmod` to run, before the map reaches the node binary.
- The installed release parses the map first. A rejected map is reported with the parser's reason (for example `expected valid bls public key bytes`), and the map itself is never quoted.
- The map is installed as `/etc/telcoin/bootstrap-peers.yaml` (root, mode 644) through a temporary file and a rename, so an existing map is replaced only once the new one has passed. The start wrapper passes `--bootstrap-peers "$(cat /etc/telcoin/bootstrap-peers.yaml)"`, which reads the file at every start. A hand edit of that file takes effect at the next restart, unchecked, and if the file goes missing or empty the node will not start.
- `.node-meta` records the installed path as `BOOTSTRAP_PEERS_FILE`. `bootstrap_peers=none` removes the flag and the file.
- A node started straight from its systemd unit is refused, because systemd cannot run the `$(cat ...)`. Convert it first (next section).

### Converting a unit-started node to a start wrapper

Fresh installs start the node through a start wrapper, `/opt/telcoin/start-telcoin.sh`. Two kinds of older install start it straight from the unit's `ExecStart=` line, with the BLS passphrase written into the unit: Docker installs made before setup moved the passphrase out of the unit (`docker run ... -e "TN_BLS_PASSPHRASE=<value>"`), and binary or source installs made before setup v1.1.22 (`Environment="TN_BLS_PASSPHRASE=<value>"` and `ExecStart=<binary> node ...`). edit-config cannot give such a node a bootstrap peers map, and no script converts it (`migrate-node-naming.sh` refuses a unit without a wrapper). To convert a Docker one by hand the way setup-node writes a Docker install today, with `<unit>` the service name (`telcoin`, or the legacy name) and `<config dir>` the node's config directory (`/etc/telcoin`, or the legacy per-role directory):

1. Run `sudo systemctl cat <unit>`. Go on only if `ExecStart=` runs `docker run` itself.
2. Back up the unit: `sudo cp -p /etc/systemd/system/<unit>.service /root/<unit>.service.bak`.
3. If `<config dir>/bls-passphrase` does not exist, create it, root-owned and mode 600, holding the passphrase value from the unit: `sudo install -m 600 /dev/null <config dir>/bls-passphrase`, then paste the value in with an editor.
4. Write `/opt/telcoin/start-<unit>.sh`:

   ```bash
   #!/usr/bin/env bash
   export TN_BLS_PASSPHRASE=$(cat "${CREDENTIALS_DIRECTORY}/bls-passphrase")
   exec docker run <the arguments of the unit's docker run>
   ```

   Copy the arguments as they are, except `-e "TN_BLS_PASSPHRASE=<value>"`, which becomes `-e TN_BLS_PASSPHRASE` (the name only, so the container takes the value from the wrapper's environment). Then run `sudo chown root:root` and `sudo chmod 0750` on the file, and check it with `sudo bash -n /opt/telcoin/start-<unit>.sh`.
5. In the unit's `[Service]` section, add `LoadCredential=bls-passphrase:<config dir>/bls-passphrase` and replace the whole `ExecStart=docker run ...` entry, continuation lines included, with `ExecStart=/opt/telcoin/start-<unit>.sh`. Leave `ExecStartPre` and `ExecStop` as they are.
6. Run `sudo systemctl daemon-reload` and `sudo systemctl restart <unit>` (on a committee node, not close to an epoch boundary), then `sudo bash ~/telcoin-node-scripts/check-node.sh`.

A binary or source install takes the same steps with three differences, matching what setup-node writes for those today. The wrapper ends with `exec <the binary and arguments from the unit's ExecStart>` instead of a `docker run`. The unit runs it as the service user, so give the file to that user and group (`sudo chown <user>:<group>`, then `sudo chmod 0750`). In step 5, also delete the `Environment="TN_BLS_PASSPHRASE=<value>"` line, and keep the other `Environment=` lines, such as the listener addresses: the wrapper inherits them.

The scripts find the wrapper by that name, so from then on edit-config, install-caddy and setup-observability edit the wrapper, and the passphrase is no longer stored in the unit.

---

## Updating the node

`update-node.sh` moves the node to a newer release in two phases. Prepare builds the new binary or pulls the new image while the node keeps running; apply stops the node, swaps the binary or image, restarts it and checks it, and a failed check rolls back to the old binary or image, except after a one-way update (below). The phases can run together or apart, so apply can wait for a quiet window.

```bash
sudo bash ~/telcoin-node-scripts/update-node.sh                  # interactive
sudo bash ~/telcoin-node-scripts/update-node.sh --no-epoch-wait  # restart without the epoch wait
sudo bash ~/telcoin-node-scripts/update-node.sh --discard        # drop a prepared update
```

- Apply waits for the epoch boundary before it stops a committee node, in all four apply paths (source and Docker, interactive and `--json`), once the update lock is held and the new binary or image is ready. `--no-epoch-wait` or `TN_SKIP_EPOCH_WAIT=1` skips the wait, and with a `lib/common.sh` older than 1.5.0 apply warns and restarts without it. See [Restarts and the epoch boundary](#restarts-and-the-epoch-boundary).
- When the target is `v0.15.0-adiri` or newer (or a branch, commit or digest), apply removes the retired `--observer` flag from the launch file before it restarts the node.
- When the node runs a release older than `v0.16.0-adiri` and the target is `v0.16.0-adiri` or newer (or a branch, commit or digest), apply is one-way. The new release migrates the consensus store in the data dir on its first start, and older releases cannot open it afterwards, so snapshot the data dir while the node is stopped before you apply. Apply warns, and warns again when the free space under `consensus-db/epochs` is less than twice the largest `epoch-N` directory. An interactive run asks whether you have the snapshot. The health window is 600 seconds unless `TN_UPDATE_VERIFY_TIMEOUT` is set to a number, which always wins. A failed check never rolls back and does not stop the node, since it may still be migrating; the script prints how to restore the snapshot. A running release that cannot be read counts as older. In `--json` mode the failure ends with a `done` event carrying `"rolled_back":false` and `"storage_migration":true`, and `--check` reports `storage_migration` for the latest release.
- A ref names a release tag, branch, commit or image tag. There is no release floor here, because an older ref is a legitimate rollback. A ref that starts with `-` is refused, whether it is typed at the custom-ref prompt or passed as `--ref` (the Node Manager UI's flag), so it never reaches git or docker as an option; `--ref` without a value is an error too.
- In `--json` mode stdout carries JSON only, and every run ends with exactly one `done` event, including runs that stop because they are not root, find no node, find the lock held or are terminated. `--check` prints one status object and nothing else.
- An `existing` install (a binary that setup did not build or pull) is not updated by the script. It names the binary the node runs (the one in the launch file, else `BINARY_PATH` in `.node-meta`) and prints the steps: `sudo systemctl stop telcoin`, `sudo install -m 0755 <new binary> <that path>`, `sudo systemctl start telcoin`. On a committee node, run only the install line while the node runs, then restart with `edit-config.sh` menu item 12 (Restart node), which waits for the epoch boundary.

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

If you lose your keys you lose your node identity. A node that has already staked must contact the Telcoin Association, because its BLS key is registered on-chain; a node that has not can simply regenerate keys and restart.

Never overwrite or regenerate the keys once the identity has staked: the registered BLS key would no longer match the node. When you re-run `setup-node.sh` on a staked node, answer N to `Overwrite existing keys?`. To stake from a different execution address before anything has staked, keep the keys and re-sign with `prepare-stake.sh --rotate-address` (see [Staking from another address](#staking-from-another-address)).

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

If updates are available it will ask for confirmation before downloading. `lib/common.sh` is always included in any update since all scripts depend on it, and `lib/fallback.sh` comes with it: the two are installed together or not at all, because they only work as a matching pair.

Every file is checked before it is installed: it must download in full, pass `bash -n` where it is a script, and match the SHA-256 in its published `<file>.sha256` sidecar. The check fails closed. A file whose sidecar is missing, empty or unreadable is not installed (`FAILED (no checksum published -- not installed)`), and neither is a file that does not match. The summary counts files that failed verification apart from files that could not be downloaded, and the run exits 1 when any file failed. When a newer updater is published, the updater checks its own replacement against `update-scripts.sh.sha256` before it relaunches, and keeps the current version when the check fails. The updater runs under macOS `/bin/bash` 3.2 as well as Linux bash.

`update-scripts.sh --help` prints the usage without contacting GitHub, and any other argument is refused with exit status 2. The updater exits 0 when everything is current, updated, or the update is declined, and 1 when GitHub cannot be reached or a file could not be downloaded or verified. It reads its confirmation from standard input and has no `--yes` option; to answer from a script, run `printf 'y\n' | bash update-scripts.sh`.

The updater also tracks the optional web UI (versioned independently, starting at `1.0.0`). When a newer UI is published it fetches the bundle into `ui/` and, if the UI is already installed, redeploys it via `ui/install-ui.sh --update` (refreshing the helper, sudoers, and restarting the service so the new code loads).

---

## Web UI (optional)

A small, self-contained web UI for managing a node from your browser: health at a glance, live logs, configuration, and OpenTelemetry traces. It is **optional** — nodes run fine without it.

### Install

```bash
sudo bash ~/telcoin-node-scripts/ui/install-ui.sh
```

The installer creates an unprivileged `telcoin-ui` system user, installs the app under `/opt/telcoin-ui`, and runs it as a systemd service. No further manual `sudo` setup is required.

It checks everything before it changes anything that is running. If Flask cannot be installed, a UI source file is missing, the helper does not parse, or `visudo` rejects the new sudoers whitelist, it stops and the running UI, its helper and its sudoers file stay as they were. The whitelist is renamed into place at step 11, just before step 12 starts or restarts the UI service; a failure after the helper is installed leaves the new helper with the old whitelist, so run the installer again. `update-scripts.sh` redeploys the UI with `install-ui.sh --update` when a new bundle arrives; a UI updated without that step shows a banner saying the helper is outdated.

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
- **Ports:** forward **443/tcp (required)** to the node; **80/tcp is recommended** (it adds the http→https redirect and a fallback for certificate issuance/renewal) but not required — Caddy obtains the certificate over 443. The script adds the `ufw` rules for 80/443 for you, even while ufw is off, so a later `ufw enable` keeps the site up. (Inbound forwarding is off by default on most routers, so this is something you set up explicitly.)
- **Conflicts:** Apache/Nginx and Caddy can't share ports 80/443. The interactive installer detects a conflicting web server and offers to stop, disable, or remove it (or quit), and it won't overwrite a Caddy config it didn't create.
- **Treat the login as a read-only credential, and rotate it.** The username/password gate only the public **read-only** view (it's stored as a bcrypt hash in the Caddyfile); it grants no management access — that stays on the SSH tunnel. If the credential leaks, the blast radius is read-only, but rotate it anyway by re-running `install-caddy.sh` (re-prompts and rewrites the hash). Don't reuse a password you use elsewhere.

Disable any time from the same **Settings** panel.

### Traces & Settings

The **Settings** tab can start/stop a local Jaeger instance and toggle OpenTelemetry tracing on the node; the **Traces** tab browses the collected spans. Jaeger's own UI (`:16686`) and the OTLP endpoint (`:4317`) are likewise localhost-only and reached through the same tunnel. Tracing registers the node with Jaeger as `telcoin`; the Traces tab still finds spans from an older `telcoin-observer` or `telcoin-validator` name.

### Setup wizard

The wizard runs `setup-node.sh` in two phases: key generation, then finalize once you have backed up the keys. On the Configure step, the Public RPC card asks for the public RPC hostname. It suggests the node's own name, checks the name with the hostname rule below, warns when the name already serves the dashboard, and checks DNS against the public IP the wizard uses (when you press "Check DNS" and when the field loses focus). A DNS mismatch is only a warning, because `setup-node.sh` checks again before it enables public RPC and keeps the node private while the name does not resolve. Continue needs a valid hostname while Public is selected. The review step reads "Public at <hostname>" or "Private".

When the server refuses a setup request, the wizard shows the server's own message on the step where you clicked; at finalize the button stays available for a retry. After finalize, the completion card shows the public RPC state: enabled or private, the hostname, the HTTPS and WSS URLs `node-info.yaml` advertises, and whether the WebSocket port listens.

Dashboard and public RPC hostnames must have two or more labels of letters, digits and inner hyphens, each label at most 63 characters and the whole name at most 253, and must not be an IPv4 address. The page, the server and the helper apply the same rule, and the page sends names lowercased without a trailing dot.

### System tab

The Public RPC card shows whether `node-info.yaml` advertises the endpoint to peers over HTTPS and WebSocket and whether the node's WebSocket port is listening. It warns when only HTTPS is advertised or the port is closed, and says when the advertised name differs from the one Caddy serves. When `node-info.yaml` advertises an endpoint that Caddy no longer serves, the card offers "Withdraw advertisement", which runs rpc-disable and restarts the node. A Caddy site written by `install-caddy.sh` 1.3.0 or older gets a refresh button, which is a Caddy reload. The hostname field suggests the node's own name, and typing the dashboard's hostname opens a box that moves the dashboard to `dashboard.<name>` in the same step.

The firewall card lists node ports beyond its three toggles, read-only. CPU counts are physical cores, shown as "8 (16 threads)", and the setup preflight judges the hardware tiers on physical cores too.

### Validator view

The server decides the view from the network, so a newly staked validator opens in the validator view during its initial sync. It asks the network's public RPC for the node's `getValidator` record first (testnet `https://rpc.adiri.tel`; at most two endpoints, three seconds each, and only one whose `eth_chainId` matches the node's chain), then the node itself once it is synced, then the last answer saved in `/opt/telcoin-ui/node-role.json` for the same execution address. With none of these the node shows as a full node, and a banner says the role is not known; a banner also says when the view comes from a saved answer. `NODE_TYPE` in `.node-meta`, the legacy unit names and an external container's `node-info.yaml` no longer decide the view.

On a synced node, the Current Epoch tile counts down to the epoch boundary, corrected for a browser clock that differs from the server's, and shows the activation epoch, the earliest committee seat and the epoch the validator is seated in, if it holds a seat in this epoch or the next two.

### Long-running actions

Progress panes read one stream per action. Stray script output appears as log lines, warnings are yellow, and a dropped connection adds a line asking you to check the status before you retry; updates and config saves no longer reconnect on their own, which could run the action a second time. An update or a config save on a committee node can wait up to 30 minutes for the epoch boundary (see [Restarts and the epoch boundary](#restarts-and-the-epoch-boundary)), with a progress line every 15 seconds. Keep the page open until the action finishes: leaving the tab stops the script. A one-way update (see [Updating the node](#updating-the-node)) shows its warning in the pane when you prepare it, and after the restart its health check can take up to 10 minutes. During an update's epoch wait nothing has changed yet, so stopping there leaves the node as it was. A config save writes its change before it waits, so a save stopped before its restart is rolled back: every file it changed is put back, and the result says so (`rolled_back: true`). Once the restart has been issued, the edit stays.

### Security model

- Binds `127.0.0.1` only; never `0.0.0.0`. Reached via an SSH tunnel — no new firewall ports — unless you opt into public access via Caddy (above), which is **read-only** and enforced server-side.
- The UI runs as the unprivileged `telcoin-ui` user. Its `sudo` rights come from one sudoers drop-in, `/etc/sudoers.d/telcoin-ui` (mode 440). The installer builds a new whitelist under a dotted name that sudo ignores and checks it with `visudo -c` (step 5). It renames the candidate over the live drop-in at step 11, after the helper, the engine copies, the UI files and the unit are in place; step 12 then starts or restarts the UI. A rejected candidate is discarded and the live drop-in stays as it was. The drop-in grants nothing else:
  - `systemctl start|stop|restart` for the unified `telcoin` unit and for the legacy `telcoin-observer` and `telcoin-validator` units.
  - Named sub-commands of one root-owned helper, `/usr/local/sbin/telcoin-ui-helper`, which performs every other privileged action. Most are pinned to fixed arguments. The few that take a value (an update ref, a config field and value, a hostname, a log-rotation size, a domain, a container name) wildcard it in sudoers, and the helper validates it before use. The helper runs root-owned copies of `update-node.sh`, `edit-config.sh`, `setup-node.sh`, `install-caddy.sh` and `firewall-setup.sh` from `/opt/telcoin-ui-update`.
  - `env_keep` for the BLS passphrase, the dashboard password and the `TN_SETUP_*` setup values, so they reach the helper through the environment and never appear on a command line.
- The helper speaks API 2 (`helper-version` prints 2): node subcommands take no `observer|validator` argument, and the helper finds the node the way `lib/fallback.sh` does. The helper still accepts the old call form, but the whitelist no longer does, which is why the installer swaps the whitelist in last: an interrupted run leaves the old whitelist with the new helper, and the running UI keeps working.
- Config edits go through `config-set`, which accepts only these fields and value shapes; `edit-config.sh` then does the full checks: `primary_listener` and `worker_listener` (a QUIC multiaddr), `metrics` (`<IPv4>:<port>` or `off`), `verbosity` (`-v` to `-vvvvv`), `docker_image`, `bootstrap_peers` (`none` or an absolute path), `state_export` (`off`, `unlimited` or 1 to 999999) and `allow_private_forward_targets` (`true` or `false`). The page has no inputs for the last three yet, and its metrics field does not accept `off`; use `edit-config.sh` on the server for those.

### Service management

```bash
systemctl status telcoin-ui
journalctl -u telcoin-ui -f
```

---

## Public RPC endpoint (https + wss)

Optional. Serves your node's JSON-RPC at `https://<domain>/` and its WebSocket at `wss://<domain>/`, and advertises both on-network so gateways and wallets can find the node. Without it (the default), RPC stays on `127.0.0.1`.

reth never listens publicly. [Caddy](https://caddyserver.com) holds the TLS certificate (automatic Let's Encrypt) on port 443 and proxies to reth on loopback: JSON-RPC to `RPC_PORT` (8545), WebSocket upgrades to `WS_PORT` (8546). `install-caddy.sh` keeps this in the same Caddyfile as the optional [dashboard](#external-dashboard-access-optional-via-caddy); changing one site never touches the other. It needs Caddy 2.8.0 or newer (the dashboard's `basic_auth` and the RPC site's page depend on it) and refuses an older Caddy, with install instructions, before it writes anything.

The site `rpc-enable` writes is block v2, stamped `# tn-rpc block v2` in the Caddyfile:

- The WebSocket upgrade match ignores case, so `Connection: upgrade`, as Google's load balancer and nginx send it, gets the WebSocket just as `Connection: Upgrade` does.
- CORS preflight (`OPTIONS`) is answered at the edge.
- A browser `GET` or `HEAD` gets 405 with `Allow: POST, OPTIONS` and a short page: what the hostname is, its https and wss URLs, a `curl` example and a link to https://docs.telcoin.network/. The page lives in the Caddyfile, so rpc-disable removes it with the site.
- JSON-RPC request bodies are capped at 2 MB (Caddy's `2MB`, which is 2,000,000 bytes). A larger request gets 413; reth sees its headers and the first 2,000,000 bytes, then the connection is cut, so reth never receives a complete oversized request. The largest legitimate request, a raw transaction at the pool's 128 KiB limit, is about 256 KiB once hex-encoded. The cap covers the JSON-RPC handler only, not WebSocket messages.
- There are no server timeouts and no per-IP limits. [Public node tuning](#public-node-tuning) explains why, and what to set in reth instead.

### DNS first

The RPC endpoint and the dashboard need different hostnames:

| Hostname | Serves |
|---|---|
| `nodeN.<suffix>`, e.g. `node7.adiri.telcoin.network` | public RPC (https + wss) |
| `dashboard.nodeN.<suffix>`, e.g. `dashboard.node7.adiri.telcoin.network` | Node Manager dashboard (optional) |

One name can't carry both. `install-caddy.sh` refuses the clash before it writes anything. It trims each hostname, lowercases it and drops one trailing dot, then uses only that form; a name that is not valid, or an IP address, is refused with the reason (Caddy needs a DNS name to get a certificate).

Create each A record **before** you enable the site, pointing at the server's inbound public IP. Caddy asks Let's Encrypt for a certificate as soon as the site loads. If the name doesn't resolve to this server yet, issuance fails and retries get rate-limited. Allow inbound TCP 443 (required) and 80 (recommended), and forward both if the server sits behind a router. Behind NAT, or on a server with several addresses, the inbound IP isn't the one the scripts detect; pass it with `--public-ip <ip>`.

### New install

In step 3, `setup-node.sh` asks about RPC access. Choose `2) Public`, enter the domain, and give the inbound IP if you're behind NAT (Enter auto-detects). Flags skip the prompt:

```bash
sudo bash ~/telcoin-node-scripts/setup-node.sh --rpc-domain node7.adiri.telcoin.network
sudo bash ~/telcoin-node-scripts/setup-node.sh --rpc-domain node7.adiri.telcoin.network --public-ip 203.0.113.10
sudo bash ~/telcoin-node-scripts/setup-node.sh --no-public-rpc    # private, no prompt
```

`--rpc-public` on its own no longer makes RPC public. Without `--rpc-domain` it prints a warning and the node stays private.

With a domain, key generation already advertises `https://<domain>/` and `wss://<domain>/` in `node-info.yaml` (keytool `--rpc-http`/`--rpc-ws`, available since `v0.12.0-adiri`), and setup records `PUBLIC_RPC_DOMAIN`, `PUBLIC_RPC_URL` and `PUBLIC_WS_URL` in `.node-meta`. After the node starts, setup checks DNS (`install-caddy.sh --phase=rpc-check-dns`) and then enables the endpoint (`--phase=rpc-enable`). That run writes the Caddy site, finds `node-info.yaml` already advertising the URLs, and doesn't restart the node. If DNS doesn't point at the server yet, or you chose not to start the node, setup still completes and prints the exact `rpc-enable` command to run later.

Automation can set the URLs one by one: `--rpc-http` and `--rpc-ws` override what goes into `node-info.yaml`, and `--public-rpc-url` and `--public-ws-url` override the `.node-meta` values. Any of the four left out is derived from `--rpc-domain`. An explicit URL that differs from the domain is replaced when `rpc-enable` runs, and setup warns about that up front. See [setup-node flags](#setup-node-flags).

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

1. Works out what the node needs before it changes anything: whether reth serves WebSocket or the launch file needs `--ws` (a dry run of that edit on a copy), and whether worker 0 in `node-info.yaml` already advertises the URLs. When both are already right, the node steps below are skipped: nothing is edited, nothing waits and the node is not restarted.
2. When a node change will follow, takes the update lock before anything else. While `update-node.sh` holds it, the run is refused with nothing changed: "an update is in progress (PID N); try again when it has finished."
3. Writes the `tn-rpc` site into `/etc/caddy/Caddyfile`, leaves any dashboard site as it was, reloads Caddy (or starts it), and adds the ufw rules for 80/443 whether or not ufw is active. ufw keeps rules while it is off and applies them once it is enabled, so a later `ufw enable` does not cut the site off.
4. On a node voting in the current committee, waits for the epoch boundary before the first node edit (`TN_SKIP_EPOCH_WAIT=1` skips it; see [Restarts and the epoch boundary](#restarts-and-the-epoch-boundary)).
5. If nothing listens on `WS_PORT` and the node was started without `--ws`, adds `--ws --ws.addr 127.0.0.1 --ws.port <WS_PORT>` to the node command in the launch file, before a trailing backslash on a multi-line start wrapper. A launch line that ends in a `#` comment is refused with that reason. When the flag cannot be added, it advertises https only and prints why, and the site's page leaves out the wss:// URL.
6. Sets worker 0's `rpc` in `node-info.yaml` to `https://<domain>/`, plus `wss://<domain>/` when step 5 passed. It uses `keytool set-rpc` from the node's own release (the binary or Docker image in the launch file) and falls back to a python3 editor. Only worker 0 is edited, as `set-rpc` does; testnet nodes run one worker today. The node publishes this in its signed kad record, which is where gateways and wallets look for it.
7. Restarts the node once so the record and any new `--ws` flag take effect. If the node fails to start, the `node-info.yaml` and launch-file edits are rolled back, the node is restarted on its old config, and the script says what it rolled back, whether the node came back, and to look in `journalctl -u <svc> -n 100`. A node that is still replaying its database is left to finish; the change applies once it's up.
8. Records `PUBLIC_RPC_DOMAIN`, `PUBLIC_RPC_URL` and `PUBLIC_WS_URL` in `.node-meta`, and releases the update lock.

A run can succeed with open items: the endpoint serves, but something is left for later, such as `node-info.yaml` missing (not advertised), no node service to restart, the node still starting after 60 seconds, or wss:// not advertised or not answering yet. Each gets a warning, and the closing summary (the `done` message in `--json` mode) lists them as open items.

Every Caddyfile change runs through `caddy validate` first, with the output shown and password hashes redacted. A failed check leaves the live file alone. A running Caddy is reloaded, not restarted, and a rejected reload puts the previous file back. (One exception: if the Caddyfile being replaced turned off Caddy's admin API, which `reload` needs, Caddy is restarted once and the script says so.) Running `rpc-enable` again with the same domain is safe: the node isn't restarted when `node-info.yaml` and the launch file are already right.

With a `lib/common.sh` older than 1.6.0, rpc-enable warns and runs without adding `--ws` (so https only, unless WebSocket is already on) and with the python3 editor. Older than 1.5.0, where the wait and lock helpers are missing too, it also runs without the epoch wait and without the update lock, and says so. rpc-disable always works. In `--json` runs a refusal, such as a hostname clash with the dashboard, is an `error` event carrying the reason, then `done`, and warnings are `warn` events. A value flag given last, with nothing after it (`--rpc-domain` alone, say), is a usage error: exit 2, as an `error` event and `done` in `--json` mode or an `[ERROR]` line otherwise.

### Check it

```bash
sudo bash ~/telcoin-node-scripts/check-node.sh
sudo bash ~/telcoin-node-scripts/install-caddy.sh --phase=rpc-status
```

`check-node.sh` has a public RPC block: the domain, Caddy's state, an https and a wss probe (sent through Caddy on loopback, so the real certificate is checked), the WS port, and the URLs `node-info.yaml` advertises. It ends with `public RPC: OK`, or with `public RPC: WARN -- <reasons>` and the command that fixes it. Run it with `sudo`: `.node-meta` is root-only, and without it the block reports `unknown`. A private node shows `public RPC: not configured (private node)`.

`--phase=rpc-status` shows whether the site is enabled, what `node-info.yaml` advertises, and whether reth's WebSocket port is listening.

Both report a site written by `install-caddy.sh` 1.3.0 or older as stale (`"block_stale": true` in `--json --phase=rpc-status`) and print the command that refreshes it: `--phase=rpc-enable` again with the same hostname. That rewrites the site with a Caddy reload and does not restart the node when `node-info.yaml` and the launch file are already right. The Node Manager UI offers the same refresh as a button.

### Backups

Before every Caddyfile write, the live file is copied to `/etc/caddy/Caddyfile.bak.<YYYYmmdd_HHMMSS>` with its owner and mode. `install-caddy.sh` keeps the newest five of these and deletes older ones. It never deletes `Caddyfile.tn-orig` (the hand-made Caddyfile it found before it first took over the file) or the backup of the change it is making.

### Turn it off

```bash
sudo bash ~/telcoin-node-scripts/install-caddy.sh --phase=rpc-disable
```

The endpoint goes first. rpc-disable removes the `tn-rpc` site with its page (a Caddy reload: no lock, no wait), then removes `PUBLIC_RPC_DOMAIN`, `PUBLIC_RPC_URL` and `PUBLIC_WS_URL` from `.node-meta`. Only then, and only when worker 0 still advertises something, does it take the update lock, wait for the epoch boundary on a committee node, clear worker 0's `rpc` in `node-info.yaml` and restart the node. While `update-node.sh` holds the lock, the site is already gone and the run says that `node-info.yaml` still advertises the endpoint; run rpc-disable again when the update has finished. The dashboard keeps running if it's enabled. Once no site remains, the ufw rules for 80/443 are removed, whether or not ufw is active. The `--ws` flag stays in the launch file; reth's WebSocket only listens on `127.0.0.1`. On a node with more than one worker, workers 1 and up keep advertising the old URL, because the released `keytool set-rpc` edits worker 0 only.

While a Node Manager site is enabled, `firewall-setup.sh --reset` (and the clean-slate reset offered by "Enable firewall with recommended defaults") keeps 80/443 open. Close them by disabling the site in `install-caddy.sh`.

### Public node tuning

reth's request limits and caches are sized for a node that only its operator queries. A public endpoint answers anyone, so the limits that bound a single request matter more, and the caches decide how often a popular query reaches the database. None of the values below has been measured on Telcoin Network. They are unmeasured starting points: change one at a time, then watch the node's memory, CPU and lag behind the network (`check-node.sh` shows the lag) before you change the next.

Request limits (defaults from `telcoin-network node --help` of `v0.16.0-adiri`, the same as in `v0.15.0-adiri`):

| Flag | Default | Unmeasured starting point | Why |
|---|---|---|---|
| `--rpc.max-request-size` | 15 (MB) | 2 | Caddy caps HTTP request bodies at 2 MB, but WebSocket messages pass through it; this puts the same cap on them |
| `--rpc.max-blocks-per-filter` | 100000 | 10000 | Bounds the block range one `eth_getLogs` call or log filter scans |
| `--rpc.max-logs-per-response` | 20000 | 10000 | Bounds what one `eth_getLogs` call returns |
| `--rpc.max-subscriptions-per-connection` | 1024 | 100 | A wallet or dapp needs a handful; this bounds what one WebSocket client makes the node track on every block |
| `--rpc.max-connections` | 500 | 500 | Each WebSocket client holds a connection through Caddy. Raise it only if clients are turned away |

State cache:

| Flag | Default | Unmeasured starting point | Why |
|---|---|---|---|
| `--rpc-cache.max-blocks` | 5000 | 5000 | Recent blocks. Keep the default until memory use is known |
| `--rpc-cache.max-receipts` | 2000 | 5000 | Receipts serve `eth_getTransactionReceipt` and log queries, which wallets and indexers send often |
| `--rpc-cache.max-headers` | 1000 | 5000 | Headers are small, so a larger cache costs little memory |
| `--rpc-cache.max-concurrent-db-requests` | 512 | 512 | Database reads in flight for cache misses. Lower it only if the data disk is saturated |
| `--rpc-cache.max-cached-tx-hashes` | 30000 | 30000 | Transaction hashes kept for lookups by hash |

If memory runs short, lower `--rpc-cache.max-blocks` and `--rpc-cache.max-receipts` first.

`edit-config.sh` has no field for these flags. Edit the start wrapper, `/opt/telcoin/start-telcoin.sh`, as root and add them to the end of the node command's last line, the one that starts with `--http` (before a trailing backslash, if a hand edit added one). For example:

```
  --http --http.addr 127.0.0.1 --ws --ws.addr 127.0.0.1 --rpc.max-request-size 2 --rpc.max-blocks-per-filter 10000 --rpc.max-logs-per-response 10000
```

Check the file with `sudo bash -n /opt/telcoin/start-telcoin.sh`, restart with `sudo systemctl restart telcoin` (on a committee node, not close to an epoch boundary; see [Restarts and the epoch boundary](#restarts-and-the-epoch-boundary)), and confirm with `check-node.sh`. Re-running `setup-node.sh` rewrites the wrapper, so add the flags again afterwards.

There are no per-IP limits, on purpose. Mobile carriers put many subscribers behind one address (carrier-grade NAT), so a per-IP limit would throttle a carrier's users together; and stock Caddy has no rate limiter, which would need a custom build. The 2 MB body cap is the only limit at the edge, and reth's limits above bound what one request can cost.

There are no server timeouts either. A read, write or idle timeout would cut long-lived WebSocket sessions, which hold subscriptions open for hours, and slow but legitimate `eth_getLogs` responses over a wide range. The block-range and log limits above bound those requests instead.

Keep `--http.api` and `--ws.api` to the modules a public client needs; the scripts start the node without either flag, which gives the default set. Never include `debug`, `trace` or `admin` on a public node: `debug` and `trace` let anyone start CPU-heavy tracing, and `admin` exposes node control. `check-node.sh` warns when either flag names one of them. In `v0.16.0-adiri`, no flag and `all` both enable eth, net, web3, rpc and tn, and a list whose first entry is `all` is read as plain `all` with the rest ignored, so `all,debug` does not turn debug on; check-node does not warn about `all` for that reason. Any other list serves only the modules it names: leave out `tn` and the node stops answering the `tn_*` calls that `check-node.sh`, `update-node.sh` and the Node Manager UI make.

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
sudo bash ~/telcoin-node-scripts/check-node.sh

# Health check including on-chain validator state
sudo bash ~/telcoin-node-scripts/check-node.sh --address 0xYOUR_ADDRESS

# Interactive config editor (backs up the unit file before any change)
sudo bash ~/telcoin-node-scripts/edit-config.sh
```

`check-node.sh`, `update-node.sh` and `edit-config.sh` no longer take role flags. Older UI helpers may still pass `--observer` or `--validator`; the scripts accept and ignore them.

### Networks and endpoints

| Network | Chain ID | Public RPC | Explorer |
|---|---|---|---|
| Testnet (Adiri) | 2017 | `https://rpc.adiri.tel` | `https://telscan.io` (alternate: `https://www.telscan.xyz`) |
| Devnet | 32285 | `https://rpc.devnet.telcoin.network` | none |
| Mainnet | 487 | `https://rpc.telcoin.network` | `https://telscan.io` |

Mainnet has not launched. Until it does, `https://rpc.telcoin.network` answers for testnet (chain 2017), so check `eth_chainId` before you trust an answer from it. The scripts use the testnet RPC for testnet nodes, and `check-node.sh` warns and skips its chain comparison when the network RPC serves a different chain.

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

# tn_nodeMode -- the node's consensus role: CvvActive, CvvInactive or Observer
curl -s -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"tn_nodeMode","params":[],"id":1}' \
  http://127.0.0.1:8545

# tn_latestConsensusHeader -- the authoritative consensus state (use this
# rather than log-grepping for "got new consensus" entries)
curl -s -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"tn_latestConsensusHeader","params":[],"id":1}' \
  http://127.0.0.1:8545
```

There is no `eth_syncing` example because it always returns `false` on Telcoin Network, even while the node is catching up. Compare `eth_blockNumber` on the node with the same call against the network's public RPC instead (testnet `https://rpc.adiri.tel`).

### Scripts

```bash
# Update scripts to latest version
bash ~/telcoin-node-scripts/update-scripts.sh

# Check that the node can stake; print the stake and activate commands
sudo bash ~/telcoin-node-scripts/prepare-stake.sh

# Remove a node
sudo bash ~/telcoin-node-scripts/remove-node.sh

# Firewall management
sudo bash ~/telcoin-node-scripts/firewall-setup.sh
```

### setup-node flags

Interactive setup prompts for everything. The public RPC flags (`--rpc-domain` through `--public-ws-url`), the node flags (`--bootstrap-peers`, `--enable-state-export`, `--state-export-keep`) and `--binary-path` (for an existing install) also work there, and the public RPC flags skip the RPC prompt; the rest are for non-interactive `--json` runs. `setup-node.sh --help` prints the public RPC and node flags. The full automation walkthrough is in [OPERATOR.md, Automation](OPERATOR.md#7-automation).

| Flag | What it does |
|---|---|
| `--rpc-domain <name>` | Public RPC on this DNS name. Derives and advertises `https://<name>/` and `wss://<name>/` at key generation, then enables Caddy after the node starts |
| `--public-ip <ip>` | Inbound public IP the A record points at (NAT or multi-IP hosts). In `--json` mode it is also the P2P public IP. A value that is not an IPv4 or IPv6 address is ignored with a warning and not recorded |
| `--rpc-public` | Asks for public RPC. Needs `--rpc-domain`; without one, setup warns and RPC stays private |
| `--no-public-rpc` | Private RPC (`127.0.0.1` only) without the prompt. Can't be combined with `--rpc-domain` or `--rpc-public` |
| `--rpc-http <url>` | Overrides the HTTP RPC URL written to `node-info.yaml`. An `http://` or `https://` URL |
| `--rpc-ws <url>` | Overrides the WebSocket RPC URL written to `node-info.yaml`. A `ws://` or `wss://` URL. Needs `--rpc-http` or `--rpc-domain` |
| `--public-rpc-url <url>` | Overrides `PUBLIC_RPC_URL` in `.node-meta` (UI and tooling only, never sent to the network). An `http://` or `https://` URL |
| `--public-ws-url <url>` | Overrides `PUBLIC_WS_URL` in `.node-meta`. A `ws://` or `wss://` URL |
| `--bootstrap-peers <file>` | Peers the node dials at start, replacing the genesis bootstrap servers. `v0.15.0-adiri` or later. See [Bootstrap peers](#bootstrap-peers) |
| `--enable-state-export` | Export each epoch's final execution state under `<datadir>/consensus-db/state_exports/epoch-N/`. `v0.13.0-adiri` or later. Each export is a full copy of the state, and without `--state-export-keep` none is ever deleted, so setup warns about the disk |
| `--state-export-keep <n>` | Keep only the newest n exports, 1 to 999999; 2 or more keeps the previous export while the next one is written. Turns `--enable-state-export` on as well, and says so. `v0.15.0-adiri` or later |
| `-h`, `--help` | Print the usage and exit. With `--json` the usage goes to stderr and stdout gets one `done` event |
| `--json --phase=keygen\|finalize` | Non-interactive setup in two phases: `keygen` generates the keys (back them up before the next phase), `finalize` writes the config and starts the node. Pass the same flags to both. When finalize's flags leave them out, it reads back what keygen recorded in `.node-meta`: the install method, the Docker image or binary, the bootstrap peers and state export. The passphrase comes from `TN_BLS_PASSPHRASE` |
| `--network <name>` | `testnet` (or `adiri`) or `devnet` |
| `--install-method source\|docker\|existing` | How to get the binary. Keygen needs it; finalize can read it back |
| `--build-ref <ref>` | Release tag, branch or commit for a source keygen, which needs one. On testnet a tag older than `v0.13.0-adiri` is refused; `main` or a commit is allowed with a warning |
| `--docker-image <ref>` | Image for a Docker install, with its tag. On testnet a tag older than `v0.13.0-adiri` is refused; a digest is allowed with a warning |
| `--binary-path <path>` | Absolute path to the node binary of an `existing` install, of letters, digits and `. _ / -`; with `--json` it implies `--install-method existing`. Without it, setup searches `PATH`, `/usr/local/bin`, `/opt` and `/home`, and a `--json` run stops when nothing is found |
| `--address <0x...>` | Execution address that stakes and receives rewards: `0x` and 40 hex digits. Required for a `--json` keygen |
| `--data-dir <path>` | Data directory (default `/var/lib/telcoin`): an absolute path of letters, digits and `. _ / -`, with no `..` |

Setup stops on a malformed URL flag and warns when a URL points at a private address or name (loopback, RFC 1918, `.local`, `.internal`) that wallets on the internet cannot reach; a `.local` or `.internal` `--rpc-domain` gets the same warning.

In `--json` mode every input is checked before setup requires root. A flag with no value, an unknown phase, network or install method, a malformed URL, image, address, directory, multiaddr, passphrase method or service user or group, a keygen without `--address`, one of the four multiaddr flags (`--external-primary`, `--external-worker`, `--listener-primary`, `--listener-worker`) or `TN_BLS_PASSPHRASE`, or a release below the testnet floor stops the run with an `error` event and one `done` whose `msg` names the flag and the reason. Finalize applies the same checks to the install method, image and binary path it reads back from `.node-meta`. Every `--json` run prints only JSON on stdout and ends with exactly one `done`; failures later in setup carry their reason in the `error` and `done` events too, and unknown arguments are reported on stderr. Finalize's `done` adds `operator_guide` (the URL of `OPERATOR.md`) and `public_rpc`, an object with `enabled`, `domain`, `http` and `ws` (the URLs as `.node-meta` records them, without a trailing slash). A finalize whose keygen ran under setup-node 1.2.1 has no recorded binary for an `existing` install and needs `--binary-path`. setup-node 1.3.0 needs `lib/common.sh` 1.6.0 and says so when the library is older.

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

Health monitoring, logging and metrics need node flags (`--healthcheck`, the JSON log
flags, `--metrics`). `setup-observability.sh` adds the ones missing from the live node
command and restarts the node to pick them up, waiting for the epoch boundary on a
committee node (see [Restarts and the epoch boundary](#restarts-and-the-epoch-boundary));
Alloy restarts never wait. A commented-out flag does not count as present. Enabling logs
and metrics together (`--enable-logs --enable-metrics`) costs one node restart, not two.

Before it touches Alloy, an enable checks its inputs (the token, the push URLs and
`METRICS_PORT`, which must be a port number from 1 to 65535) and rehearses the launch-file
edit on a copy. When a flag cannot go on the node command (no live node command, a launch
line that ends in a comment, a `--log.file.format` other than json, a file that cannot be
written), the script says why, names the flags to add by hand and changes nothing: Alloy is
left alone, the add-on is not recorded in `.node-meta`, the node is not restarted, and a
`--json` run ends with `ok: false`. Run the enable again once the launch file is fixed. A
value flag such as `--token` given without a value is an error too. When the node restart is
left for later, the script suggests `edit-config.sh` menu item 12 (Restart node), which waits
for the epoch boundary; a plain `systemctl restart` does not.

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

### update-scripts v1.1.72 — ships update-node v1.2.1 for v0.16.0-adiri
`update-scripts.sh v1.1.72` carries update-node v1.2.1, lib/common v1.6.1 and telcoin-ui
v1.9.1 (entries below), with refreshed `.sha256` sidecars. Run it before you update a node to
`v0.16.0-adiri`: update-node v1.2.0 and older do not know that this update is one-way, and
they roll a slow first start back to a binary or image that can no longer open the data dir.
On a node with the Node Manager UI, the updater redeploys the UI, which also refreshes the
UI's copy of `update-node.sh` in `/opt/telcoin-ui-update/`. v1.1.71 added a maintainer SSH key
to the testnet add-ons bundle (add-ons 1.0.1) and had no entry of its own.

### update-node v1.2.1 — one-way storage migration for v0.16.0-adiri
The first start of `v0.16.0-adiri` migrates the consensus store in
`<data dir>/consensus-db/epochs` to a new format, and older releases cannot open it afterwards.
Putting the old binary or image back is therefore no rollback, and that is what v1.2.0 did when
the first start was slow. An apply from a release older than `v0.16.0-adiri` to `v0.16.0-adiri`
or newer, or to a branch, commit or digest, is now one-way:

- Before it stops the node, it warns that the update is one-way. When the free space under
  `consensus-db/epochs` is less than twice the largest `epoch-N` directory, it warns about the
  disk too; the disk check never blocks. An interactive run then asks whether you have a
  snapshot of the data dir. Answering no cancels the apply and keeps the prepared update.
- The health window is 600 seconds instead of 45, because the first start migrates before the
  node answers. A numeric `TN_UPDATE_VERIFY_TIMEOUT` still wins; unset or non-numeric gives 600
  on a one-way update and 45 otherwise.
- A failed health or identity check never rolls back, and an interactive run does not offer to.
  The node is left on the new release and is not stopped, because it may still be migrating.
  The prepared update is cleared, and the version marker keeps the old release until a verified
  apply. The error names the journal to watch and the way back: stop the node, restore the data
  dir from the pre-update snapshot, copy back the binary, start wrapper or launch file from the
  backup it names, and start the node.
- In `--json` mode that failure ends with an `error` event and then one `done` event with
  `"ok":false`, `"rolled_back":false` and `"storage_migration":true`. `--check` adds a
  `storage_migration` boolean, true when updating from the running release to `latest_ref` is
  one-way. `--json --prepare` sends the one-way warning as a `warn` event before its `done`, so
  the Node Manager UI shows it before you press Apply.
- The running release comes from the image tag on Docker installs and from
  `/opt/telcoin/telcoin-network.version` on source installs, not from the source checkout,
  which a prepare moves. A running release that cannot be read counts as older, so the update
  is treated as one-way.

An update that does not cross into `v0.16.0-adiri` (from `v0.16.0-adiri` to a later release,
for example) keeps the 45-second window and the rollback, and its `done` event has no
`storage_migration` field. `--help` describes one-way updates and `TN_UPDATE_VERIFY_TIMEOUT`.

### lib/common v1.6.1 — default image v0.16.0-adiri
`DEFAULT_DOCKER_IMAGE`, the image setup falls back to when the registry cannot be reached, is
now `us-docker.pkg.dev/telcoin-network/tn-public/adiri:v0.16.0-adiri`. Comments that named the
current release now name `v0.16.0-adiri`: it pins the same tn-contracts commit (10cc12b7) as
`v0.15.0-adiri`, and it rejects `--observer`. Nothing else changes.

### telcoin-ui v1.9.1 — fallback image v0.16.0-adiri
The fallback image (used when the registry cannot be reached) and the image placeholders in
the setup wizard and the Update tab name `v0.16.0-adiri`. The version bump makes
`update-scripts.sh` redeploy the UI, which installs update-node v1.2.1 as the UI's update
engine, so an update started from the UI gets the one-way handling. The one-way warning shows
in the progress pane when you prepare; the status card does not show `storage_migration` yet.

### testnet baseline → v0.16.0-adiri
adiri testnet moves to `v0.16.0-adiri`, built from telcoin-network commit `d72cc2bc`. The image
is `us-docker.pkg.dev/telcoin-network/tn-public/adiri:v0.16.0-adiri` (linux/amd64 only, index
digest `sha256:b905b0982e87d5ca608e2f29192d0c5582793ae0043630074cddb9be1162ffea`). lib/common
v1.6.1 and telcoin-ui v1.9.1 point the defaults at it. `MIN_SOURCE_VERSION_TESTNET` stays at
0.13.0, and the system contracts are unchanged (tn-contracts 10cc12b7, as in `v0.15.0-adiri`).

**The first start migrates the consensus store one way.** Each epoch pack the node opens is
rewritten in the v2 format, with `migrated legacy pack to v2 on open` in the log once per
epoch. Older epochs migrate later, while the node runs, each with a `pre-v2 (legacy) epoch
pack; migrating it to v2` warning. `v0.15.0-adiri` cannot open a migrated data dir; it stops
with `invalid version (should be 0)`. Snapshot the data dir while the node is stopped, before
the first start of `v0.16.0-adiri`: going back means restoring that snapshot, not swapping the
binary or image. Run `update-scripts.sh` first so update-node v1.2.1 handles the apply.

No new fork is armed. The `fork schedule (adiri)` line at startup gains
`subsecond_timestamp_fork_epoch=4294967295`, which never arrives, and the six existing fork
epochs are unchanged. `telcoin --version` still prints 0.1.0; only its `Commit SHA:` line
differs. Other changes an operator can see:

- `--observer` is now an argument error: the node exits with status 2 and
  `unexpected argument '--observer'`. update-node removes the flag when it updates to
  `v0.15.0-adiri` or later, and check-node warns while a launch file still passes it.
- The node locks `<data dir>/telcoin.pid`. A second node process on the same data dir stops
  with `another telcoin process (pid N) holds the lock on this data directory`.
- The advertised addresses in `node-info.yaml` must name a concrete IP with a nonzero UDP port
  over QUIC v1. A wildcard address such as `0.0.0.0`, a multicast address or port 0 is refused.
- The health port (`--healthcheck`, 43174 with the testnet health monitor) also answers
  `GET /health/network`: 200 once the primary and every worker have peers, 503 before that.
- With no `--http.api` or `--ws.api`, or with `all`, the node serves eth, net, web3, rpc and
  tn. An explicit list now serves only what it names, so a list without `tn` drops the `tn_*`
  methods that check-node, update-node's health check and the Node Manager UI call. The scripts
  pass neither flag.

### update-scripts v1.1.70 — integrity check fails closed; runs under macOS bash 3.2
`update-scripts.sh v1.1.70` carries the entries below, down to lib/observability v1.0.2,
and fetches the new `prepare-stake.sh`.

The SHA-256 check now fails closed. A file whose `.sha256` sidecar is missing, empty or
unreadable is not installed (`FAILED (no checksum published -- not installed)`); v1.1.69
skipped the check when no sidecar came back. When the updater replaces itself, it checks the
new copy against `update-scripts.sh.sha256` before it relaunches, and keeps running the
current version when the check fails. `lib/common.sh` and `lib/fallback.sh` are installed
together or not at all, since they only work as a matching pair. The summary counts files
that failed verification apart from files that could not be downloaded, and the run exits 1
when any file failed. A partial download of a version header no longer aborts the run, and
only scripts are made executable.

The updater now runs under macOS `/bin/bash` 3.2. `check_versions` declared its update list
with `declare -ga` and two version maps with `declare -gA`; bash 3.2 has no `declare -g`, so
v1.1.69 exited with `declare: -g: invalid option` right after the connectivity check. The
list is a top-level array now, and the two maps, which nothing read, are gone. The
`source lib/fallback.sh` at the top is guarded, so a lone copy of the updater still starts.
A failing `clear` (no usable terminal) no longer ends the run. Linux output is unchanged.

The updater used to ignore its arguments, so `update-scripts.sh --help` ran a real update
check and, on a terminal, offered to install everything with Enter meaning yes. `-h` and
`--help` now print the usage (what it compares, where it fetches from, the sidecar and pair
rules, the exit statuses) and exit 0 without contacting GitHub; any other argument is refused
with exit status 2. An interrupted run (Ctrl-C or a dropped SSH session) removes the files it
had downloaded but not installed, and a checksum that cannot be downloaded for the updater
itself is reported as a network error instead of a missing checksum.

Not updater-tracked, but part of the same release: `install.sh` installs `prepare-stake.sh`,
ends with a link to the operator runbook, and no longer stops when a script is missing from
the download.

### telcoin-ui v1.9.0 — helper API 2, public RPC in the setup wizard, validator view from the network
The server calls the privileged helper without the old `observer|validator` argument and
asks it for its API version (`helper-version`, cached for a minute). The helper (API 2) finds
the node the way `lib/fallback.sh` does: unit `telcoin`, then `telcoin-validator`, then
`telcoin-observer`; the unified `.node-meta`, then the legacy role directories; the meta's
`DATA_DIR`. Its engine calls carry no role flag, setup calls `setup-node.sh` directly with
`--rpc-domain` from `TN_SETUP_RPC_DOMAIN` and never sends `--rpc-public`, and tracing
registers the node as `telcoin`. `rpc-enable <host> [<ip>|-] [<dashboard-host>]` passes
`--move-dashboard-to` and refuses a dashboard host equal to the RPC host. The sudoers lines
for the old role-argument call form are gone, so this bundle needs the install-ui v1.4.0
whitelist, which `update-scripts.sh` installs with it; a UI updated without re-running the
installer shows a "helper outdated" banner. `config-set` accepts `metrics=off` and the new
edit-config fields `bootstrap_peers`, `state_export` and `allow_private_forward_targets`, with
identical patterns in the helper and the server.

The validator view is decided from the network. The server asks the network's public RPC for
the node's `getValidator` record first (at most two endpoints, three seconds each, and only
one whose `eth_chainId` matches the node's chain), then the node itself once it is synced,
then the last answer saved in `/opt/telcoin-ui/node-role.json` for the same execution
address; with none of these the node shows as a full node. A newly staked validator therefore
opens in the validator view during its initial sync. `/api/nodes` reports how the view was
decided as `role_source` (`network`, `local`, `cached` or `default`), `role_checked_at` and
`role_address`, and the helper check as `helper`, on the SSH-tunnel path only. `NODE_TYPE` in
`.node-meta`, the legacy unit names and an external container's `node-info.yaml` no longer
pick the view, and a legacy install shown as a validator keeps its own data and config paths.
The `getValidator` reply is decoded strictly (seven words, each within its Solidity type,
status 0 to 5 or the retired 6); only the no-ConsensusNFT revert counts as no record, and any
other error counts as no answer. For a synced node, `/api/validator` adds the epoch's start
and end with the server's clock (`epoch_started_at`, `epoch_duration`, `epoch_ends_at`,
`now`), `earliest_seat_epoch` for an activated validator, and `seat_epoch`, the first of the
current and next two epochs whose committee includes the node.

The setup wizard offers public RPC. Choosing Public asks for the hostname, suggests the
node's own name, checks it with the strict hostname rule and checks DNS against the public IP
the wizard uses; a DNS mismatch is a warning, because `setup-node.sh` checks again before it
enables public RPC. The review step shows the choice, the request carries the hostname as
`rpc_domain`, a refused request shows the server's message where the operator clicked, and
the completion card reads the public RPC status after finalize. On the System tab, the RPC
card shows what `node-info.yaml` advertises over HTTPS and WebSocket and whether the WebSocket
port listens, warns when only HTTPS is advertised or the port is closed, says when the
advertised name differs from the one Caddy serves, offers to withdraw an advertisement Caddy
no longer serves, and offers a refresh (a Caddy reload) for a block written by install-caddy
v1.3.0 or older. Its hostname field suggests the node's own name, and typing the dashboard's
hostname offers to move the dashboard to `dashboard.<name>` in the same step; the dashboard
card warns when its hostname is the RPC hostname. The firewall card lists node ports beyond its
three toggles, read-only, from firewall-setup v1.6.0's `p2p_ports`. On the validator view, the
Current Epoch tile of a synced node counts down to the epoch boundary, corrected for a browser
clock that differs from the server's, and shows the activation epoch, the earliest committee
seat and the seated epoch. Banners say when the helper is outdated or answers a newer API than
the page expects, and when the validator view comes from a cached or unknown answer.

Dashboard, public RPC and move-to hostnames follow one strict rule in the page, the server and
the helper: two or more labels of letters, digits and inner hyphens, labels up to 63
characters, at most 253 in all, not an IPv4 address. A bad name gets a 400 that says what is
wrong before anything runs. Setup sends the public RPC hostname as `TN_SETUP_RPC_DOMAIN` and no
longer sets `TN_SETUP_RPC_PUBLIC` or `TN_SETUP_INSTANCE`; public RPC without a hostname is
refused. `/api/rpc/enable` takes `move_dashboard_to`, and `/api/rpc/status` adds `meta_domain`
and passes the advertised and WebSocket fields through. Status and DNS-check replies are read
from the last JSON line, so a warning printed before it no longer hides the result. Every
action stream captures stderr, turns stray output into log lines, sends exactly one `done`
(made up from the exit code when the script sends none, after an `error` line with the stderr
tail when it failed) and then `closed`, and stops cleanly when the browser goes away. The page
reads every stream the same way, and the update and config-save streams no longer use
EventSource, whose automatic reconnect could run the action a second time. Update and
source-build refs that start with `-` are refused. CPU counts are physical cores, shown as
"8 (16 threads)". The testnet comparison endpoint is `https://rpc.adiri.tel`, the unused
`wss://` list is gone, and trace lookups follow the helper's `telcoin` service name. Copy
buttons use one delegated listener instead of inline handlers. Tests:
`ui/test_server_contract.py`, `ui/test_server_chain.py`, `ui/tests/helper_test.sh`.

The role check never waits on a public RPC endpoint inside a request. The network's answer is
kept in memory and refreshed by one background thread, each endpoint's chain ID is remembered
for an hour, and an endpoint that fails is backed off for 5 minutes, doubling to 30. A changed
stake status therefore reaches the view about half a minute later than a blocking probe would
show it, and the dashboard stays responsive when the public RPC is slow or unreachable.

### install-ui v1.4.0 — sudoers whitelist checked first and installed last
The installer builds the new sudoers whitelist under a dotted name in `/etc/sudoers.d` (sudo
ignores it), checks it with `visudo -c`, and renames it over `/etc/sudoers.d/telcoin-ui` only
after the helper, the engine copies, the UI files, the logrotate seed and the unit are
installed. If Flask cannot be installed, a source file is missing, the helper does not parse
or visudo rejects the whitelist, it stops before anything of the UI changes; a failure after
the helper step leaves the old whitelist, which the new helper still serves. Before, the
installer wrote the live drop-in first and deleted it when visudo rejected it. The whitelist adds `helper-version` and the
no-argument forms of the node subcommands, drops the `observer|validator` forms (telcoin-ui
v1.9.0 no longer sends them), keeps `TN_SETUP_RPC_DOMAIN` across sudo and drops
`TN_SETUP_RPC_PUBLIC` and `TN_SETUP_INSTANCE`. The engine copies in `/opt/telcoin-ui-update/`
no longer include the deprecated `setup-observer.sh` and `setup-validator.sh`, and copies left
by earlier versions are removed. The start and enable prompts are read only from a terminal,
default to yes and lowercase with `tr` (bash 3.2 safe), and the sudoers comment no longer runs
`telcoin.service` as a command on every install.

### prepare-stake v1.0.0 — check a node before staking, print the stake and activate commands
New script. `sudo bash prepare-stake.sh` checks that the network RPC serves this node's chain,
reads the validator address from `node-info.yaml`, and checks the governance whitelist
(ConsensusNFT), the validator status, the stake amount the registry asks for now, the
address's TEL balance against the stake plus gas, and the `stake()` calldata the node's own
keytool exports. It then simulates `stake()` from the address with `eth_estimateGas`; a revert
is named (InvalidProofOfPossession, DuplicateBLSPubkey, InvalidStakeAmount, InvalidStatus, a
paused registry and more) together with what to do. It warns when the local node trails the
network by more than 50 blocks, and prints the exact `cast send` commands for `stake()` and
`activate()` with the network RPC, plus the epoch arithmetic: `activate()` mined in epoch E
makes the validator active at E+1, with its earliest committee seat at E+3. No private key is
read, asked for or printed, and nothing is sent. `--rotate-address <0xNEW>` re-signs the proof
of possession for another address with the same BLS key, keeps a backup of `node-info.yaml`,
records the address in `.node-meta` and restarts the node; it is refused once either address
has staked or while an update is running, and a failed re-sign puts `node-info.yaml` back.
`--json` prints one JSON object with every value the run read. Exit codes: 0 ready or nothing
to do, 1 usage or environment, 2 RPC or on-chain state unreadable, 3 not ready or refused,
4 rotation rolled back, and 130, 143 or 129 when Ctrl-C, SIGTERM or SIGHUP interrupts a run. A
rotation interrupted while signing waits for keytool and puts `node-info.yaml` back; one
interrupted after the re-signed file passed its checks prints how to finish. The signing note
names `--ledger`, `--trezor`, `--account <name>` and `--interactive`, and warns against
`--private-key`. See [Prepare to stake](#prepare-to-stake).

`--rotate-address` asks for the BLS passphrase before it takes the update lock, so a prompt
nobody answers never holds up `update-node.sh`, `edit-config.sh` or `install-caddy.sh`.

### setup-node v1.3.0 — input checks before root, release floor, finalize reads keygen's choices, bootstrap peers and state export
setup-node now needs lib/common v1.6.0 and says so when the library is older ("Run
update-scripts.sh and try again"), as an error event in `--json` mode. `--json` runs check
every input before `check_root`: a flag with no value, an unknown phase, network or install
method, a malformed `--rpc-http`, `--rpc-ws`, `--public-rpc-url`, `--public-ws-url` or
`--docker-image`, and on testnet a `--build-ref` or image tag older than v0.13.0-adiri each
stop the run with an `error` event and one `done` that carries the reason. A ref that is not a
release tag (`main`, a commit, an image digest) warns and goes on. Interactive setup applies
the same floor to the ref picked or typed for a source build and to the Docker image typed at
the prompt. Failures later in setup now carry their message in the `done` event too, every
`--json` run ends with exactly one `done` (a run without root says so), and unknown arguments
are reported on stderr instead of being ignored. Every answer and flag that reaches the start
wrapper or `.node-meta` is validated: prompts for ports, directories, the image, the binary
path, the execution address and the P2P addresses ask again until the answer is valid, bad
flags fail before root with the flag named, a `--json` keygen without `--address`, the four
multiaddr flags or `TN_BLS_PASSPHRASE` stops before root (no source build first), and the
region label is reduced to letters, digits, `_` and `-`, at most 32 characters.

A URL flag on a private address or name (loopback, RFC 1918, `.local`, `.internal`) warns that
wallets on the internet cannot reach it; an invalid `--public-ip` is ignored with a warning.
`--binary-path PATH` names the binary of an `--install-method existing` install. Keygen records
the install method and the Docker image or binary in `.node-meta`, and finalize reads them back
when its flags leave them out, so a UI install whose image was picked automatically at keygen
finalizes with that image instead of failing while it writes the start wrapper. `.node-meta` is
now updated one key at a time: keys that other scripts keep there survive a re-run, and the old
`NODE_TYPE` hint is removed. Finalize's `done` event adds `operator_guide` and `public_rpc`. The
closing summary shows the P2P ports `node-info.yaml` advertises, lists every one in the
firewall reminder, and links the operator runbook.

New node flags. `--bootstrap-peers FILE` gives the node a YAML or JSON map of the peers to dial
at start, keyed by BLS public key, in place of the genesis bootstrap servers. The file must be
a regular file of at most 64 KiB that other users can read: the map does not stay private,
since the installed copy is world-readable and the check runs it through the node binary's
command line. Setup checks the file before it touches the box, checks the map with the
installed release's own parser (a rejected map is reported with the parser's reason and
without quoting the map), installs it as `/etc/telcoin/bootstrap-peers.yaml` and has the start
wrapper pass `--bootstrap-peers "$(cat /etc/telcoin/bootstrap-peers.yaml)"`, so the host reads
the file at each start. `--enable-state-export` exports each epoch's execution state, and
`--state-export-keep N` keeps only the newest N exports; on its own it turns state export on
and says so. Setup asks the installed release whether it has each flag given and stops, before
any key is made, when it does not (`--enable-state-export` arrived in v0.13.0-adiri, the other
two in v0.15.0-adiri). The choices are recorded in `.node-meta` as `BOOTSTRAP_PEERS_FILE` and
`STATE_EXPORT` (`off`, `unlimited` or a number), and a `--json` finalize reads them back when
its flags leave them out. `-h` / `--help` prints the usage.

### edit-config v1.3.0 — bootstrap peers, state export and private forward targets; epoch-aware restarts; update lock
Three new settings, in the menu (items 8 to 10; Refresh chain configs, Restart node and Exit
move to 11, 12 and 13) and in `--set`. `bootstrap_peers=<path>` installs a YAML or JSON map of
peers keyed by BLS public key as `/etc/telcoin/bootstrap-peers.yaml`, after the installed node
binary has parsed it, and the start wrapper passes it with `--bootstrap-peers "$(cat …)"` at
each start; `none` removes both. It needs v0.15.0-adiri and a start wrapper: a node started
straight from its systemd unit is refused, because systemd cannot run the `$(cat …)`. It takes
only a file its group and other users can already read, because the installed copy is
world-readable and the check shows the map on the node binary's command line.
`state_export=off|unlimited|N` sets `--enable-state-export` and, for `N`,
`--state-export-keep N`, each only when the installed release lists the flag.
`allow_private_forward_targets=true|false` edits that key in `parameters.yaml`; `true` is
refused on testnet and mainnet and when the genesis chain ID cannot be read, and `false` changes
nothing when the key is absent. `--set metrics=` now adds the flag when it is missing, and
`metrics=off` removes it.

Before any restart of a node that votes in the current committee, edit-config waits for the
epoch boundary when it is within five minutes (at most 30 minutes), like update-node;
`--no-epoch-wait` or `TN_SKIP_EPOCH_WAIT=1` skips it and a rollback restart never waits. Every
edit takes the update lock and is refused while update-node.sh is applying an update. `--set`
without `--json` runs the same edit, restart and health check with readable output, and an edit
that changes nothing no longer restarts the node. A launch file with more than one node command
is refused instead of being half edited. In `--json` mode stdout is JSON only and every run
ends with one `done`, including runs that stop on a bad argument, a missing root, or the lock;
`--set` with no value used to loop forever. The rollback after a failed restart now restores
`parameters.yaml` and the peers file too. Refresh chain configs reads the network from
`.node-meta` and refuses unless the node's genesis and the new one declare the same chain ID. A
Docker image pinned by digest is written literally. A run stopped by Ctrl-C, SIGTERM or SIGHUP
after it wrote an edit but before the restart (the UI stops it when its page closes) puts every
changed file back and exits 130, 143 or 129; the menu's older edits get the same protection.
Needs lib/common v1.6.0.

### update-node v1.2.0 — waits for the epoch boundary before restarting a committee node; --json always ends with done
Apply now holds the stop of a node that votes in the current committee (`tn_nodeMode`
`CvvActive`) when the epoch boundary is at most five minutes away. It waits for the epoch to
close and settle, at most 30 minutes, with a progress line every 15 seconds, so the restart
does not land on the epoch change. All four apply paths (source and Docker, interactive and
`--json`) wait just before the service stops, after the update lock is held and the new binary
or image is ready; a rollback restart never waits. `--no-epoch-wait` or `TN_SKIP_EPOCH_WAIT=1`
skips the wait, and with a lib/common.sh older than v1.5.0 the apply warns and restarts without
waiting.

`--ref` with no value used to loop forever; it is now an error. A ref that starts with `-` is
refused, as `--ref` and at the interactive custom-ref prompt alike, so it never reaches git or
docker as an option. In `--json` mode stdout is pure JSON from the first argument on (unknown
arguments warn on stderr), and every run ends with exactly one `done` event, including runs
that stop because they are not root, find no node, find the lock held or are terminated; the
first two send an `error` event naming the cause first. The wait reports as `step`, `log` and
`warn` events, and the flag-strip and backup warnings are `warn` events now. `--check` still
prints one status object and nothing else. The update lock is released from the script's own
exit trap, and the long-running commands it starts (`cargo build`, `docker pull`, `git fetch`,
`systemctl stop`) no longer inherit the lock, so a killed update does not leave it held. For an
`existing` install it names the binary the node really runs (the launch file's, else
`BINARY_PATH` from `.node-meta`) instead of `/opt/telcoin/telcoin-network`, and prints the stop,
install and start steps, with the epoch-aware alternative for a committee node.

### install-caddy v1.4.0 — RPC block v2, keytool set-rpc, epoch-aware restarts
rpc-enable writes block v2, stamped `# tn-rpc block v2` in its comment. The WebSocket matcher
ignores case, so `Connection: upgrade` as Google's load balancer and nginx send it gets 101
instead of 405. A browser GET or HEAD gets 405 with `Allow: POST, OPTIONS` and a short page
saying the hostname is a JSON-RPC endpoint, with a curl example and the docs link; the page
lives in the Caddyfile, so rpc-disable removes it with the block. JSON-RPC bodies above 2 MB
(Caddy's `2MB`, 2,000,000 bytes) get 413: reth sees the headers and the first 2,000,000 bytes,
then the connection is cut, so it never receives a complete oversized request. A block written
by an older version is reported as stale by `rpc-status` (`"block_stale": true`) with the
command to refresh it: rpc-enable with the same hostname, a Caddy reload.

node-info.yaml is now written with `keytool set-rpc` from the node's own release, falling back
to the python3 editor, and only worker 0 is edited, as set-rpc does. The current value is read
first: when it already matches, nothing is edited and the node is not restarted. Before the
first node edit, a node voting in the current committee waits for the epoch to close
(`TN_SKIP_EPOCH_WAIT=1` skips). `--ws` is added through the shared launch-file helper, so it
lands before a trailing backslash and a line ending in a comment is refused. rpc-enable records
`PUBLIC_RPC_DOMAIN`, `PUBLIC_RPC_URL` and `PUBLIC_WS_URL` in `.node-meta`; rpc-disable removes
them. Caddy below 2.8.0 is refused with install instructions, the ufw rules for 80/443 are added
and removed while ufw is inactive too, and Caddyfile backups are pruned to the newest five. In
`--json` runs a refusal such as a hostname clash with the dashboard is an `error` event with the
reason, then `done`, and warnings are `warn` events. With a lib/common.sh older than v1.6.0
the script warns, skips the `--ws` edit and uses the python3 editor; older than v1.5.0 it also
skips the epoch wait and the update lock. rpc-disable always works. Before any node
edit the script takes the update lock, so rpc-enable is refused with nothing changed while an
update runs ("an update is in progress (PID N); try again when it has finished."), and
rpc-disable removes the site first and only then clears the advertisement under the lock and the
epoch wait. Hostnames are lowercased with one trailing dot dropped, and IP addresses are refused.
A value flag given last is a usage error (exit 2), and a successful run names any open items in
its summary and `done` message.

### check-node v1.2.0 — network from .node-meta, committee membership, epoch and worker checks
check-node compares the node with the network recorded in `.node-meta`: the chain ID check
expects that network's ID (so a devnet node is no longer a "Chain ID mismatch"), and the network
RPC defaults to that network's public RPC (testnet `https://rpc.adiri.tel`) instead of
`https://rpc.telcoin.network`. When `.node-meta` has no network, any Telcoin chain ID passes. If
the network RPC answers for a different chain, as `https://rpc.telcoin.network` does today, the
report warns and skips the comparison rather than blaming the node.

The authority ID now comes from the node's own `tn_info` (`--authority-id` is the fallback). The
old lookup read `primary_network_key`, which is not the ID headers carry, so the author check
never ran. Whether missing from the latest commit's headers is an error now depends on on-chain
committee membership for the current epoch; when membership cannot be read, it is an error only
for an Active or Pending Exit validator whose node does not report Observer. A new epoch section
shows the epoch, the time of the next boundary in UTC, committee membership for this epoch and
the next two, a staked validator's activation epoch and earliest seat, and the worker count
against `WorkerConfigs.numWorkers()`; too few workers is a health issue.

The service section lists the image or binary, bootstrap peers, state export, P2P ports and the
advertised RPC. Public nodes get warnings for a Caddy RPC block older than block v2 and for
debug, trace or admin in `--http.api` / `--ws.api` (not for a list that starts with `all`,
which the node reads as plain `all`), and the wss probe stops as soon as the upgrade answers. On macOS, disk usage comes from `df -Pk` and the memory check is skipped with a
note, so the report runs to the end. Exited validators are told whether `unstake()` is eligible
now. With a lib/common.sh older than v1.6.0, the checks that need its new helpers are skipped
with a warning. A flag given without its value now prints a usage error instead of crashing, and
each run keeps its probe files in its own temporary directory, removed on exit, instead of a
shared `/tmp/check-node.rpc.tmp`. The report now says "N authors in the latest commit" and,
separately, "Committee of epoch E: N members (on-chain)"; it warns, even offline, when
`VALIDATOR_ADDRESS` in `.node-meta` differs from the node's own address and says whether to
restart or fix `.node-meta`; and each finding ends with what to do next. Reputation is read
from `sub_dag.reputation_scores`. The consensus-header parser no longer evaluates strings from
the RPC answer: only base58 IDs and plain integers get through.

### firewall-setup v1.6.0 — P2P rules follow the node's ports; enabling keeps a live Caddy site up
Status, enable, "Manage node ports" and the expected-configuration check now use the node's
actual P2P ports instead of the fixed 49590/49594. The primary and worker 0 ports come from the
listener addresses the node is started with (the `-e` or `export` lines of the start wrapper,
else `Environment=` in the unit), then from `node-info.yaml`, then the defaults; workers 1 and
up come from `node-info.yaml`. A node set up on other ports, or with a second worker, gets the
right rules. Enabling the firewall (menu option 2 or `--json --enable`) allows TCP 80 and 443
before ufw starts whenever Caddy serves the public RPC or dashboard on the box; before, only
`--reset` did, so a plain enable could take a live site down. "View current firewall status"
works again with ufw active: since v1.1.1 it stopped right after "Firewall is active", because
its default-policy read never matched real `ufw status verbose` output and the failure ended the
script. Status shows the node's service (`telcoin.service`) instead of a node type.
`--json --status` keeps its `ports` keys and adds `p2p_ports`, one
`{"port","proto","label","allowed"}` object per port (`allowed` is null while ufw is off); the
`--port` allowlist is unchanged. With a lib/common.sh older than v1.6.0 the script warns and
checks the primary and worker 0 ports only. Every rule step is checked: a failing `ufw allow`
stops the enable before ufw is turned on and, under `--json`, ends with an `error` event and
`done` `ok: false`; a failing `ufw status verbose` reads as `"default_incoming": "unknown"`
instead of ending the status.

### setup-observability v1.2.1 — epoch wait before the health-check restart, clearer flag messages
Enabling health monitoring waits for the epoch boundary before restarting a node that votes in
the committee (`TN_SKIP_EPOCH_WAIT=1` skips the wait), and enabling logs or metrics passes its
progress printer down, so `--json` runs report the wait as `step`, `log` and `warn` events. When
`--healthcheck` cannot be added, the message says why instead of "already has --healthcheck (or
the launch line was not found)". An enable whose node flag is still missing afterwards is not
recorded in `.node-meta` and does not restart the node; in `--json` mode it sends an `error`
event per reason and ends with `done` `ok: false`, and a run with no node service stops before
it changes anything. The "no node" message now says to run `setup-node.sh`. With a
lib/observability.sh older than v1.0.2 the script warns and behaves as v1.2.0.
`--enable-logs --enable-metrics` together render and restart Alloy once and restart the node
once (v1.2.0 restarted it twice), a value flag such as `--token` without a value is an error,
and restart hints point to `edit-config.sh` menu item 12, which waits for the epoch boundary.

### remove-node v1.2.9 — runs under macOS /bin/bash 3.2
The install method, service user and service group of each detected unit moved from three
associative arrays (`declare -A`, bash 4 only) to indexed arrays kept in step with the list of
installed units, so the script no longer stops at `declare: -A: invalid option` on macOS.
Removing a node prunes all four lists together, and the lists that can be empty (no node
installed, no custom installs found) no longer abort with "unbound variable" under bash 3.2.
At end of input the menu now exits cleanly instead of looping, `clear` failing on an unusable
terminal no longer ends the run, and a service group you chose to keep is listed as kept rather
than as possibly orphaned. Prompts, teardown order and output are otherwise unchanged.

### migrate-node-naming v1.2.1 — no nameref; NODE_TYPE removed instead of written
The directory move no longer uses a bash 4.3 nameref (`local -n`), which failed under bash 3.2
and rolled every migration back. The migration now removes the old `NODE_TYPE` hint from
`.node-meta` instead of writing `NODE_TYPE=observer`; a missing hint reads as the plain
full-node view, as before. `.node-meta` keys are written with the library's `meta_set`, so a
custom data directory whose path holds `#` or `&` no longer breaks the migration (the old
sed-based writer rolled it back on `#` and mangled `&`). The already-migrated check no longer
prints the hint, and the help text and final report say the validator view follows the on-chain
stake status (ConsensusRegistry `getValidator`) rather than `tn_isValidator`.

### lib/common v1.6.0 — RPC and epoch helpers, launch-file edits, keytool runner, physical cores
v1.5.0 was never released on its own; its changes are folded into this entry.

The testnet RPC constant is now `https://rpc.adiri.tel`, the explorers are `https://telscan.io`,
`MAINNET_CHAIN_ID` is 487, and `TN_OPERATOR_GUIDE_URL` points at the operator runbook. The oldest
supported testnet release is v0.13.0-adiri, the first release that has all three of
`keytool set-rpc`, proof-of-possession signing and state export (the first two arrived in
v0.12.0-adiri); `tn_ref_min_check` holds release refs and image tags to it. `confirm` lowercases with `tr`, so it runs under macOS `/bin/bash` 3.2. `meta_set`
refuses a malformed key or a value with a line break, and the new `meta_unset` removes a key.
`meta_get` drops a trailing CR, and `meta_set` and `meta_unset` match a key on a CRLF line and
rewrite the file with LF endings, so a `.node-meta` edited on Windows reads correctly instead of
yielding values such as `testnet\r`. `ufw_active` and `ufw_has_allow` read `ufw status` in full
before they match, so a long rule list can no longer read as inactive under `pipefail`.

New helpers: `validate_rpc_url` and `rpc_url_is_private` for operator-supplied URLs;
`tn_genesis_chain_id` and `tn_is_public_chain_id`; a JSON-RPC family (`tn_rpc_call`,
`tn_json_field`, `tn_local_rpc_url`, `tn_node_mode`, `tn_epoch_info`, `tn_epoch_secs_left`)
whose failures say what went wrong (transport, http, rpc-error, malformed); and
`tn_hex_to_dec`, `tn_wei_to_tel` and `tn_stake_amount_wei` for 256-bit amounts without
python3. `tn_wait_restart_window` holds a committee node's restart until the current epoch has
closed and settled, never longer than `TN_EPOCH_WAIT_MAX` (0 turns it off); when the boundary
passed more than `TN_EPOCH_MARGIN` seconds ago and the epoch is still open, it warns once and
lets the restart go ahead. Its sleeps run in the background, so a script stopped during the wait
handles the signal at once instead of after the next poll. A caller that owns its EXIT trap sets
`TN_EXIT_TRAP_OWNED` before
`tn_acquire_update_lock` and releases the lock with `tn_release_update_lock`, which frees the
lock even while an orphaned child process still holds its descriptor.

`node_stake_status` decodes `getValidator` strictly and adds the exit epoch as a fourth field;
failures carry their reason, and status 6 is accepted only as the retired tombstone. The
on-chain status report gives one hint per failure kind (no answer, HTTP 429 rate limiting, an
undecodable answer) and tells an exited validator when `unstake()` becomes eligible. The
staking steps printed after key generation show the live stake amount, read with
`stakeConfig(getCurrentStakeVersion())`, fill it into the `cast send` command, export the
calldata with `-q --bls-passphrase-source no-passphrase`, and point to `prepare-stake.sh`.

`check_hardware` compares the hardware tiers with physical cores. `tn_physical_cores` counts
them from `lscpu`, `/proc/cpuinfo` or `sysctl hw.physicalcpu` and falls back to the logical
count, and the report says which one it measured ("4 physical cores", "8 logical CPUs"), since a
cloud vCPU is usually a hyperthread. An 8-vCPU VM with 4 physical cores now reads as below the
validator minimum.

`tn_node_inject_flags` now edits only the live node command: it skips comment lines (`;` lines
too in a unit), puts flags before a trailing backslash instead of after it, and refuses a line
that ends in a comment. The edit is staged and written back only when the staged copy keeps the
same `--http` lines, reads back as intended and, for a start wrapper, still passes `bash -n`;
owner and mode are kept. Its return code says why nothing changed: 1 already there, 2 no node
launch line, 3 refused, 4 I/O error. `tn_launch_flag_get`, `tn_launch_flag_set` and
`tn_launch_flag_unset` read and edit one flag of the node command by the same rules, quoted
values such as `"$(cat /etc/telcoin/bootstrap-peers.yaml)"` included; a value with an unquoted
shell metacharacter is refused as not a single shell word, and `set` refuses `$`, `%` and
backticks in a systemd unit, where systemd would expand them.

`tn_launch_runner` reads the Docker image or binary path from the launch file, and `tn_keytool`
runs keytool through it: in Docker as the owner of the data directory, with the BLS passphrase
passed by environment only, and with `-q` so a `$(...)` capture gets only the result.
`tn_keytool_has`, `tn_node_has_flag` and `tn_node_parse_check` ask the installed release what it
supports instead of comparing version numbers; a rejected value is reported as one line with the
parser's reason and the value replaced by `'…'`. `tn_node_info_field`,
`tn_node_info_worker_ports` and `tn_node_info_rpc` read `node-info.yaml` in both the v0.15.0
`workers:` shape and the older `worker:` shape, without python3.

### lib/fallback v1.0.3 — role comments, tn_resolve_node_type deprecated
Comments now say the validator view comes from the on-chain stake status (`getValidator`, via
`node_stake_status`), not from `tn_isValidator` or `NODE_TYPE`. `tn_resolve_node_type` is
deprecated: nothing in `lib/` calls it and firewall-setup v1.6.0 no longer does. It stays for
one more release, so a box with this library and an older `firewall-setup.sh` keeps working.
`_tn_meta_get` drops a trailing CR, so a `.node-meta` with CRLF line endings resolves the right
data directory.

### lib/observability v1.0.2 — flag checks ignore comments; epoch-aware node restarts
`obs_ensure_reth_flags` reads the live node command with `tn_launch_flag_get`, so a commented-out
`--metrics` or `--log.file.format json` no longer counts as present, and a command that already
sets `--log.file.format` to something other than json is reported rather than given a second
one. New `obs_inject_flags` words each outcome of `tn_node_inject_flags`: already there, no live
node command, edit the launch file by hand (with the reason), or the file could not be written.
After the edit, each needed flag is checked again; when one is still missing,
`obs_ensure_reth_flags` returns 1 without restarting the node and `obs_enable` returns before it
records anything in `.node-meta`. Before it restarts the node, `obs_restart_window` waits for the
epoch boundary when the node votes in the committee; Alloy restarts never wait. `obs_enable` and
`obs_ensure_reth_flags` take an optional progress function for that wait. The Docker log
directory comes from `DATA_DIR` in `.node-meta` (else the resolved data directory) instead of a
fixed role path. On a lib/common.sh older than v1.6.0 (flag reads) or v1.5.0 (the wait) each
missing piece falls back to the v1.0.1 behaviour with one warning per run. `obs_enable` now
validates its inputs, `METRICS_PORT` included (a port number from 1 to 65535), and rehearses
the launch-file edit on a copy before it touches Alloy, so a flag that cannot be added changes
nothing; `obs_status` no longer stops on an empty `/metrics` answer.

### Maintainer tools — bash 3.2 lint and UI tests in CI
Not shipped to operators and not versioned. `tools/check-bash32.sh` flags bash 4+ syntax that
`bash -n` under macOS `/bin/bash` 3.2 accepts but 3.2 cannot run: `declare -A` and the other
`declare`/`local` options, case modification such as `${v,,}`, `mapfile`, `&>>`, `|&`, `[[ -v`,
`wait -n`, negative subscripts and substring lengths, `exec {fd}>` and more, including inside
one-line `case` arms. CI runs it on every `*.sh` on the Linux and macOS runners, and runs the
Node Manager UI tests (`ui/test_*.py` and `ui/tests/helper_test.sh` under bash 3.2 and 5). See
[Contributing](#contributing).

### update-scripts v1.1.69 — re-cut for setup-node v1.2.1
`update-scripts.sh v1.1.69` re-cut with refreshed `.sha256` sidecars; carries setup-node
v1.2.1 (entry below), so updaters fetch the new banner.

### setup-node v1.2.1 — contact address is support@telcoin.org
The welcome banner now points at support@telcoin.org for Association approval. `OPERATOR.md`
and the README use the one support address for everything, validator onboarding included.

### update-scripts v1.1.68 — re-cut for update-node v1.1.63
`update-scripts.sh v1.1.68` re-cut with refreshed `.sha256` sidecars; carries update-node
v1.1.63 (entry below).

### update-node v1.1.63 — strip decision reads the release ref, not the crate version
The `--observer` strip on a source update decided from `"<ref> <binary --version>"`. The
built binary reports its crate version (`telcoin-network-cli Version: 0.1.0`), not the
release, so an update to a branch or commit (`--ref main`) read `0.1.0`, judged it older than
v0.15.0 and left the flag in place; the node then failed its health check and rolled back.
The decision now reads the ref alone: a tag carries the release version, and a branch or SHA
counts as newest and is stripped. Docker updates were unaffected (they read the image tag).

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

(Correction: "never pruned" no longer holds. Since install-caddy v1.4.0 the timestamped
backups are pruned to the newest five; see its entry above.)

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
immediately. The CI gates in `.github/workflows/ci.yml` protect that supply chain on every
pull request and push to `main`:

- **Shell parse + lint** — `bash -n` on every script under both modern bash and macOS's
  bash 3.2 (operators run some scripts, such as `open-ui.sh`, from a Mac), plus `shellcheck`.
  A parse error on `main` would brick `curl … | bash`, so these are blocking.
- **bash 3.2 lint** — `bash -n` accepts most bash 4 constructs because they fail only when
  the line runs, so `tools/check-bash32.sh` (maintainer-only, never shipped) finds them by
  pattern: `declare -A` and the other `declare`/`local` options 3.2 lacks, `${v,,}` and the
  other case changes, `mapfile`/`readarray`, `&>>`, `|&`, `[[ -v`, `wait -n`, negative
  subscripts and substring lengths, `exec {fd}>`, `${v@Q}` and more. CI runs it on every
  `*.sh` under Linux (mawk) and macOS (`/bin/bash` 3.2, BSD awk). Run it before you push:

  ```bash
  /bin/bash tools/check-bash32.sh $(git ls-files '*.sh')
  ```

  A line marked `# bash32-ok`, with the reason after the marker, is never reported.
- **Node Manager UI tests** — `python -m unittest discover -s ui -p 'test_*.py'` for the
  server, and `ui/tests/helper_test.sh` for the privileged helper under bash 3.2 and bash 5.
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

Docs move with the code. When a change alters what an operator sees or does (a flag, a
prompt, a default, a status, a command), update [`OPERATOR.md`](OPERATOR.md) in the same pull
request as this README: the runbook is the path operators follow, and the README is the
reference it links into. Carry the same change into the partner guide,
[`docs/partner/mno-node-guide.md`](docs/partner/mno-node-guide.md), bump its version and date
in `docs/partner/metadata.yaml`, and regenerate the PDF with `bash tools/build-partner-pdf.sh`
(see "Partner guide (MNO PDF)" in [`AGENTS.md`](AGENTS.md)). Keep the README anchors that
`OPERATOR.md` links to stable. In all three files, refer to scripts, functions and flags by
name, never by line number or `file:line`; line numbers go stale with the next edit.

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

Email support@telcoin.org for questions about the Telcoin Network protocol, chain configuration, validator approval or these setup scripts.
