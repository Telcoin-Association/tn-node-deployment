# Telcoin Node Scripts -- Older Changelog

Historical changelog entries from v1.1.39 and earlier.
For recent entries (v1.1.40 onwards), see the Changelog section of README.md.

---

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

