# Telcoin Node Scripts -- Older Changelog

Historical changelog entries from v1.1.39 and earlier.
For recent entries (v1.1.40 onwards), see the Changelog section of README.md.

---

## Unreleased

### Dynamic node role -- `setup-node.sh` replaces the observer/validator split
Telcoin Network decides a node's role from on-chain committee membership each epoch, not
from a setup-time flag: a staked validator that is out of the committee behaves exactly like
a never-staked full node, and both just follow consensus. Setup no longer splits into
observer vs validator. `setup-node.sh` is the canonical installer; `setup-observer.sh` and
`setup-validator.sh` stay as thin deprecated shims that forward to it. The `--observer`
binary flag is removed and is no longer emitted anywhere, the Vault `start-telcoin.sh`
example included. Because any node can later stake and join the committee, `firewall-setup.sh`
now opens the P2P consensus ports (UDP 49590 primary, 49594 worker) on every node; one that
staked behind a closed firewall would be unreachable and silently miss consensus. The
hardware preflight checks against the 8 cores / 16 GB / 500 GB baseline to run a node and
prints the 16 cores / 128 GB / 4 TB validator spec as informational, not a hard requirement.
The web UI selects the validator dashboard from the on-chain `tn_isValidator` RPC rather than
a manual toggle; `.node-meta` keeps `NODE_TYPE` only as a non-authoritative default-view hint
(new installs write `observer`). Existing per-role installs keep working via `lib/fallback.sh`,
and `migrate-node-naming.sh` is the safe, opt-in path onto the unified layout.

### Unified node naming -- single `telcoin` identity
Collapses the historical dual observer/validator identity into one identity for
NEW installs (operators run one node per VM). The systemd unit, docker `--name`,
and log files are all named `telcoin` (`telcoin.service`); config and data live
directly in `/etc/telcoin` and `/var/lib/telcoin` (no `/observer` or `/validator`
suffix), with the node type recorded as `NODE_TYPE=` in `/etc/telcoin/.node-meta`.
Drops the `--instance` flag, so observers now use the reth default RPC/WS ports
8545/8546. Existing per-role installs (`telcoin-validator` / `telcoin-observer`
units, `/etc/telcoin/<role>`, `/var/lib/telcoin/<role>`) keep working untouched
via the new `lib/fallback.sh` compatibility shim -- the management scripts detect
them and operate on them in place rather than renaming or migrating anything.

### Opt-in migration to unified naming -- `migrate-node-naming.sh`
New on-node script that migrates a legacy `telcoin-{observer,validator}` install to
the unified layout on demand (the fallback shim never migrates on its own). It
stops the node, relocates `/etc/telcoin/<role>` and `/var/lib/telcoin/<role>` up to
`/etc/telcoin` and `/var/lib/telcoin`, rewrites the unit + start wrapper to the
unified paths / `--name telcoin`, sets `NODE_TYPE=` in `.node-meta`, then restarts
as `telcoin.service`. For an observer it also converts to a validator -- it deletes
the single `--observer` launch line (the only runtime difference between the two)
and sets `NODE_TYPE=validator`, for an observer later staked + activated on-chain.
The node keeps its existing BLS key; RPC/WS ports are preserved (the `--instance` in
the launch flags is untouched). Idempotent, collision-guarded, and self-rolling-back
(restores the legacy unit/wrapper, moves the dirs back, restarts the legacy service
on any failure). Shipped via `update-scripts.sh`.

### Node Manager UI -- detect a staked validator on-chain
The dashboard now reads a node's TRUE role from the chain instead of only its
`NODE_TYPE`: after the node is synced it calls `tn_isValidator` with the node's BLS
key (base58 -> the 96-byte `0x` hex the contract requires) and, when true, shows the
node on the validator tab and renders the validator dashboard. So an observer that
was staked + activated is displayed correctly even before it is migrated. (UI 1.7.66.)

### v1.1.39
`pick_source_version` distinguishes "at tip of main" from "behind main";
replaces the binary `on_main` check with a tip/behind/none state machine.

### v1.1.38
`pick_source_version`: fixes wrong "<-- current" marker on tag lists via
proper exact-match detection; hides source versions older than v0.9.1.

### v1.1.37
Hotfix: removes duplicate readonly `TN_SOURCE_DIR` in update-node.sh that
slipped through v1.1.36 (would otherwise abort the script on start).

### v1.1.36
Source-build picker now follows official Telcoin testnet guidance: defaults
to the latest `-adiri` tag rather than `main`.

### v1.1.35
update-node.sh shows available versions upfront in a numbered menu (marks
current + latest) before prompting prepare/apply.

### v1.1.34
New update-node.sh: two-phase prepare/apply workflow for safe node version
upgrades (source + Docker), with auto-rollback on health-check failure.

### v1.1.33
check-node.sh adds EVM execution state (`eth_blockNumber` + `eth_syncing`);
older changelog entries (v1.1.28 and earlier) moved to this CHANGELOG.md.

### v1.1.32
check-node.sh auto-detects node type from installed systemd units;
`--observer` / `--validator` are now optional.

### v1.1.31
check-node.sh redesigned around the consensus RPC (`tn_latestConsensusHeader`):
adds author-presence and reputation checks; removes the fragile log-grep
heuristics that produced false positives.

### v1.1.30
firewall-setup.sh "recommended defaults" now opens every port a node
actually needs (SSH, Uptime Kuma, validator UDP) instead of just SSH.

### v1.1.29
Audit-driven hardening pass across all scripts: input validation, backups
before unit-file edits, atomic SSH port change, pre-increment counters to
avoid the `set -e` post-increment trap.

### v1.1.28
Hotfix: applies the v1.1.27 network-selection fix to setup-validator.sh
(missed due to differing script structure).

### v1.1.27
Network selection now happens before install method selection so testnet
source builds correctly receive `--features faucet`.

### v1.1.26
Service user is added to the `tss` group when TPM passphrase method is
selected (required for `/dev/tpmrm0` access).

### v1.1.25
Corrects the TPM unseal sequence (uses `tpm2_load` before `tpm2_unseal`);
adds a TPM seal-verification step before deleting the plaintext file.

### v1.1.24
When TPM passphrase method is used, `LoadCredential` is no longer written
to the systemd unit (fixes `status=243/CREDENTIALS` startup failure).

### v1.1.23
Adds optional TPM/vTPM passphrase sealing for binary/source installs
(GCP Shielded VMs, AWS Nitro, bare-metal TPM2); falls back to LoadCredential.

### v1.1.22
Binary/source installs use systemd `LoadCredential` for the BLS passphrase;
adds a hard systemd 247+ check; install-method selection moved to preflight.

### v1.1.21
Adds Uptime Kuma port to firewall-setup.sh; partial-install detection in
remove-node.sh; service user/group name validation.

### v1.1.20
Adds clang and libclang-dev to source-build deps; auto-installs the Rust
toolchain version declared in `rust-toolchain.toml` before building.

### v1.1.19
Adds branch/tag selection for source builds; testnet builds always include
`--features faucet`.

### v1.1.18
Source builds: internal/external IP split (binds internal, advertises
public); auto-install of missing build dependencies.

### v1.1.17
Fixes edit-config.sh refresh-chain-configs chown error when the service
group does not exist on the system.

### v1.1.16
Updates default Docker image to `v0.9.1-adiri`.

### v1.1.15
Updates default Docker image to `v0.9.1-adiri`.

### v1.1.14
Fixes setup-observer.sh final summary `primary_multiaddr` unbound-variable
error.

### v1.1.13
Setup scripts: network-binding choice now happens before keytool key
generation (previously keys were generated with `127.0.0.1`, causing
consensus failures).

### v1.1.12
Fixes observer keytool key generation -- adds the missing
`--external-primary-addr` and `--external-worker-addrs` flags.

### v1.1.11
Fixes check-node.sh P2P peer-count crash on some systems; simplifies to
count all unique peers since startup.

### v1.1.10
Fixes check-node.sh peer-check crash when sudo requires a password (the
log file is world-readable, so sudo is not needed).

### v1.1.9
Fixes check-node.sh P2P peer count showing `00` instead of `0` on fresh
nodes (timestamp range matching via awk).

### v1.1.8
IPv4 binding now uses `0.0.0.0` per official docs; removes the v1.1.5
NAT-detection logic.

### v1.1.7
Docker service file adds `ExecStartPre=-/usr/bin/docker rm -f` to remove
stale containers before starting (fixes exit 125 after crash).

### v1.1.6
Fixes edit-config.sh `apply_changes` crash; restart failure now shows an
error and returns to the menu instead of exiting.

### v1.1.5
Adds NAT / public-IP awareness to IPv4 binding (binds internal, advertises
public); same fix applied to edit-config.sh.

### v1.1.4
Fixes check-node.sh consensus-peer messaging -- observer consensus peers
no longer assumed to be 0; adds a firewall hint when 0.

### v1.1.3
Multiple small fixes: check-node.sh whitespace strip, remove-node.sh Docker
crash, edit-config.sh crash, `.node-meta` on Docker installs. Adds
install.sh and `SCRIPT_VERSION` tracking.

### v1.1.2
Adds install.sh, remove-node.sh, update-scripts.sh; implements Docker
install option in setup scripts; new edit-config.sh options (P2P ports,
Docker image, chain config refresh, restart).

### v1.1.1
Adds CVE-2026-31431 (Copy Fail) preflight check to setup; new
firewall-setup.sh interactive script with status/SSH/node-port management.

### v1.1.0
Custom service user/group selection in setup scripts; improved peer count
read directly from node log; improved sync messaging cross-references
block number.

### v1.0.9
Splits hardware requirements into separate validator and observer specs;
broadens supported OS list; adds network requirements (1 Gbps validator /
24 Mbps observer).

### v1.0.8
Observer setup: final summary now shows actual P2P listener addresses;
removes inbound port-forwarding from observer next steps.

### v1.0.7
Updates hardware requirements to 16 cores / 128 GB / 4 TB NVMe; fixes
validator onboarding (submit ECDSA to governance, not node-info.yaml);
uses `eth_syncing`.

### v1.0.6
Fixes edit-config.sh RPC editing -- service file no longer mangled when
switching between private/public/disabled RPC modes.

### v1.0.5
Adds edit-config.sh: interactive configuration editor for running nodes
(listener addresses, instance number, metrics, RPC, BLS passphrase).

### v1.0.4
IPv6/IPv4 binding descriptions use neutral wording; coming-soon options
now pause with a clear message so operators know their selection was
received.

### v1.0.3
IPv4 binding auto-detects the server's internal IP (handles cloud/datacentre
environments with split internal/external IPs); removes the unsupported
IPv4+IPv6 combined option.

### v1.0.1
Adds validator on-chain status check via ConsensusRegistry contract; adds
`--address` flag to check-node.sh.

### v1.0.0
Initial release: observer and validator setup scripts, health check,
systemd unit with BLS passphrase, build from source.
