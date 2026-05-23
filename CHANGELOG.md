# Telcoin Node Scripts -- Older Changelog

Historical changelog entries from v1.1.28 and earlier.
For recent entries (v1.1.29 onwards), see the Changelog section of README.md.

---

### v1.1.28
- **Fix**: Applied network selection fix to `setup-validator.sh` -- was missed in v1.1.27 due to differing script structure
- All scripts bumped to v1.1.28

### v1.1.27
- **Fix**: Network selection (testnet/mainnet) now happens before install method selection in preflight -- ensures `--features faucet` is correctly applied for testnet source builds (previously `NETWORK` was empty during build, so faucet feature was never included)
- All scripts bumped to v1.1.27

### v1.1.26
- **Fix**: Service user is now added to the `tss` group when TPM passphrase method is selected -- required for access to `/dev/tpmrm0` TPM device. Without this the node service would fail to start with `status=1/FAILURE` when running as a non-root service user.
- All scripts bumped to v1.1.26

### v1.1.25
- **Fix**: Corrected TPM unseal sequence in wrapper script and `lib/common.sh` -- now correctly uses `tpm2_load` to load the sealed object before `tpm2_unseal` (fixes `status=1/FAILURE` on node start when TPM passphrase method is used)
- Added TPM seal verification step during setup -- verifies the sealed object can be unsealed before deleting the plaintext file
- All scripts bumped to v1.1.25

### v1.1.24
- **Fix**: When TPM passphrase method is selected, `LoadCredential` is no longer written to the systemd service file -- previously caused `status=243/CREDENTIALS` startup failure when the plaintext passphrase file was deleted after TPM sealing
- All scripts bumped to v1.1.24

### v1.1.23
- **Security**: Added optional TPM/vTPM passphrase sealing for binary/source installs -- passphrase sealed to machine's TPM chip, unreadable on any other machine even with root access. Supported on GCP Shielded VMs, AWS Nitro, and bare metal TPM2. Falls back to LoadCredential if TPM unavailable.
- **Fix**: Pre-built binary option (option 2) now correctly blocks with a warning and re-prompts instead of silently continuing
- **Improvement**: `check-node.sh` now shows consensus information -- last consensus block number and age, current epoch, primary/worker peer breakdown, and epoch sync stuck detection
- `remove-node.sh` now cleans up TPM sealed files on node removal
- All scripts bumped to v1.1.23

### v1.1.22
- **Security**: Binary/source installs now use systemd `LoadCredential` for BLS passphrase -- passphrase never appears in `systemctl show` output or process listings
- **Security**: Added hard systemd version check (247+ required, Ubuntu 22.04+) -- setup exits with clear error if not met
- **UX**: Install method selection moved to Step 1 (preflight) -- all dependencies installed upfront before configuration begins, preventing mid-setup failures
- Updated default Docker image to `v0.9.2-adiri`
- Added `.gitignore` to prevent helper/patch scripts from being committed to the repository
- `edit-config.sh` passphrase edit updated to handle both LoadCredential (binary) and Docker installs correctly
- All scripts bumped to v1.1.22

### v1.1.21
- Removed helper scripts (`apply-v1120.sh`, `fix-toolchain-line.sh`) from repository
- Added TCP port 43174 (Uptime Kuma health monitoring) to firewall setup script
- Added partial install detection to `remove-node.sh` -- detects and offers to clean up leftover directories from interrupted installs
- Added service user/group name validation in both setup scripts -- prevents crashes when invalid names or existing regular users are entered
- All scripts bumped to v1.1.21

### v1.1.20
- Added `clang` and `libclang-dev` to source build dependency checks -- fixes `stdarg.h` not found error when building from source on fresh machines
- Fixed cargo PATH for source builds -- cargo env is sourced correctly after Rust installation, including root cargo path fallback
- Added automatic Rust toolchain installation -- reads `rust-toolchain.toml` from the repo and installs the required toolchain version before building
- All scripts bumped to v1.1.20

### v1.1.19
- Added branch/tag selection for source builds -- choose `main` (default) or enter any branch or tag name (e.g. `issue-679`) to build unreleased fixes
- Source builds on Adiri testnet now always include `--features faucet` (required for testnet operation)
- Both changes apply to observer and validator setup scripts
- All scripts bumped to v1.1.19

### v1.1.18
- Internal/external IP split for source builds -- node binds listener to internal NIC IP, advertises public IP to peers (fixes GCP/cloud deployments)
- Added source build dependency checks -- auto-detects and installs missing packages (`build-essential`, `cmake`, `libclang-16-dev`, `pkg-config`, `libssl-dev`, `libapr1-dev`)
- All scripts bumped to v1.1.18

### v1.1.17
- Fixed `edit-config.sh` refresh chain configs -- `chown` error when service group doesn't exist on the system
- All scripts bumped to v1.1.17

### v1.1.16
- Updated default Docker image to `v0.9.1-adiri`
- All scripts bumped to v1.1.16

### v1.1.15
- Updated default Docker image to `v0.9.1-adiri`
- All scripts bumped to v1.1.15

### v1.1.14
- Fixed final summary in setup-observer.sh -- `primary_multiaddr` unbound variable error at end of setup
- All scripts bumped to v1.1.14

### v1.1.13
- Fixed observer and validator setup scripts -- network binding (IPv4/IPv6) choice now happens in Step 3 so multiaddrs are set before keytool key generation. Previously keys were generated with `127.0.0.1` causing consensus failures.
- All scripts bumped to v1.1.13

### v1.1.12
- Fixed observer keytool key generation -- was missing `--external-primary-addr` and `--external-worker-addrs` flags, causing keys to be generated with `127.0.0.1` instead of `0.0.0.0`. This prevented the node from receiving consensus blocks.
- All scripts bumped to v1.1.12

### v1.1.11
- Fixed `check-node.sh` crash in P2P peer count -- removed multiline awk that caused issues on some systems, simplified to count all unique peers since startup
- All scripts bumped to v1.1.11

### v1.1.10
- Fixed `check-node.sh` crashing at peer check on machines where sudo requires a password -- log file is world-readable so sudo is not needed
- All scripts bumped to v1.1.10

### v1.1.9
- Fixed `check-node.sh` P2P peer count showing `00` instead of `0` on fresh nodes -- improved timestamp range matching using awk instead of grep pattern
- All scripts bumped to v1.1.9

### v1.1.8
- Fixed IPv4 binding to use `0.0.0.0` (all interfaces) instead of a specific IP address
  - Matches official dev documentation recommendation
  - Works correctly with home NAT, cloud VMs (GCP, AWS, etc), and dedicated servers
  - No need to detect or configure external/public IP
  - Removed unnecessary NAT detection logic added in v1.1.5
- Updated `edit-config.sh` option 1 (Listener addresses) with same fix
- Both observer and validator affected
- All scripts bumped to v1.1.8

### v1.1.7
- Fixed Docker service file -- added `ExecStartPre=-/usr/bin/docker rm -f` to remove stale containers before starting. Prevents exit code 125 error when container name already exists after crash or failed stop.
- All scripts bumped to v1.1.7

### v1.1.6
- Fixed `edit-config.sh` `apply_changes` crash -- added `set +e`, restart failure now shows error and returns to menu instead of exiting
- Also shows node log file path in error message for easier debugging
- All scripts bumped to v1.1.6

### v1.1.5
- Added NAT/public IP awareness to IPv4 binding in both setup scripts
  - Asks whether server is behind NAT or has a separate public IP
  - Auto-detects public IP and uses it for advertising to peers
  - Node binds to internal IP but advertises public IP so peers can connect
  - Applies to both observer and validator setup
- Fixed `edit-config.sh` option 1 (Listener addresses) crash -- added `set +e`, fixed Docker multiaddr reading/writing, added NAT awareness
- All scripts bumped to v1.1.5

### v1.1.4
- Fixed `check-node.sh` consensus peer messaging -- removed incorrect assumption that observer consensus peers are always 0. Consensus peers show correctly when UDP ports are open inbound. Shows helpful message if 0 suggesting to check firewall ports.
- Updated README peer count note to reflect correct behaviour
- All scripts bumped to v1.1.4

### v1.1.3
- Fixed `check-node.sh` syntax error in P2P peer count -- strip whitespace from `wc -l` output and validate as number
- Fixed `remove-node.sh` crash on Docker installs -- added `set +e` to detection functions, show `(none)` for empty service group
- Fixed `edit-config.sh` crash -- added `set +e` to `show_current_config`, fixed Docker image detection regex
- Fixed `setup-observer.sh` and `setup-validator.sh` -- write `.node-meta` file so `remove-node.sh` can find host service user on Docker installs
- Added `install.sh` -- one-command installer for fresh machines
- Added `SCRIPT_VERSION` to `check-node.sh` and `COMMON_VERSION` to `lib/common.sh` for update tracking
- Updated README quick start with both install methods (one-liner and manual)
- All scripts bumped to v1.1.3

### v1.1.2
- Added `install.sh` — one-command installer for fresh machines via `curl` or `wget`
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

