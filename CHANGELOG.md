# Telcoin Node Scripts -- Older Changelog

Historical changelog entries from v1.1.39 and earlier.
For recent entries (v1.1.40 onwards), see the Changelog section of README.md.

---

## Unreleased

### v0.16.0-adiri round, October 2026 -- update-scripts v1.1.72
This round moves the adiri testnet to `v0.16.0-adiri` (telcoin-network `d72cc2bc`). Operators
receive the scripts below through `update-scripts.sh` v1.1.72; the Changelog section of
README.md has one entry per script and a "testnet baseline" entry for the release itself.

#### One-way updates
The first start of `v0.16.0-adiri` migrates the consensus store in the data dir, and older
releases cannot open it afterwards. update-node v1.2.1 treats an apply across that line as
one-way: it warns before it stops the node, warns again when the disk has less than twice the
largest `epoch-N` free, asks an interactive operator about a snapshot, and gives the first start
600 seconds unless `TN_UPDATE_VERIFY_TIMEOUT` is a number. A failed check no longer rolls back;
the node is not stopped, and the error says how to restore the pre-update snapshot. In `--json`
mode the failed `done` carries `"rolled_back":false` and `"storage_migration":true`, `--check`
reports `storage_migration`, and prepare sends the warning so the Node Manager UI shows it
before Apply. A source install's running release comes from the version marker, not the
checkout, and a running release that cannot be read counts as older.

#### Defaults
lib/common v1.6.1 and telcoin-ui v1.9.1 name `v0.16.0-adiri` as the fallback image and in the
UI's placeholders. The UI bump also redeploys the UI's copy of update-node.

#### Docs
README.md, OPERATOR.md and the partner guide (version 1.2) describe one-way updates, how to
snapshot the data dir before one and how to go back, and the release's other visible changes:
`--observer` is now an argument error (exit status 2), the `telcoin.pid` lock, the refusal of
wildcard and port-0 advertised addresses, `/health/network`, and an explicit `--http.api` list
that no longer serves `tn_*` methods unless it names `tn`. No new fork is armed
(`subsecond_timestamp_fork_epoch=4294967295`).

### Backlog round, October 2026 -- update-scripts v1.1.70
This round worked through the `followup.md` backlog left by the public-RPC and observer-flag
work. Operators receive every script below through `update-scripts.sh` v1.1.70. The Changelog
section of README.md has one entry per script; this summary goes by area.

#### Library
`lib/common.sh` v1.6.0 (v1.5.0 was folded into it) holds the helpers the scripts below share:
JSON-RPC calls that report why they failed, epoch and stake-amount reads, a keytool runner that
uses the node's own release, `node-info.yaml` readers for both worker layouts, launch-file edits
that touch only the live node command, and the epoch-boundary wait, which a signal interrupts
at once instead of after the next poll. Its constants name
`https://rpc.adiri.tel` as the testnet RPC, `https://telscan.io` as the explorer and 487 as the
mainnet chain ID, and the oldest testnet release it accepts is v0.13.0-adiri. The hardware check
counts physical cores, so an 8-vCPU VM with 4 physical cores reads as below the validator
minimum, and `getValidator` replies are decoded strictly. `lib/fallback.sh` v1.0.3 deprecates
`tn_resolve_node_type`, which nothing calls any more.

#### Setup and configuration
`setup-node.sh` v1.3.0 checks every input before it asks for root, refuses testnet releases older
than v0.13.0-adiri, and carries the install method and the image or binary chosen at keygen
through to finalize, so a UI install whose image was picked automatically no longer fails while
it writes the start wrapper. It adds `--bootstrap-peers FILE`, `--enable-state-export`,
`--state-export-keep N` and `--help`; each node flag is checked against the installed release
before any key is made. `.node-meta` is updated one key at a time and no longer carries
`NODE_TYPE`. A `--json` keygen refuses up front, before root and before any build, when
`--address`, one of the four multiaddrs or `TN_BLS_PASSPHRASE` is missing. `edit-config.sh`
v1.3.0 adds bootstrap peers, state export and `allow_private_forward_targets` (devnet only) to
its menu and to `--set`. It takes the update lock, refuses a chain-config refresh that would
change the chain ID, and does not restart the node for an edit that changes nothing. An edit
interrupted before its restart is rolled back. Both scripts need lib/common v1.6.0 and say so.

#### Updates and restarts
update-node v1.2.0, edit-config v1.3.0, install-caddy v1.4.0, setup-observability v1.2.1 and
`prepare-stake.sh --rotate-address` (v1.0.0) hold the restart of a node that votes in the
current committee when the epoch boundary is at most five minutes away, and restart once the
epoch has closed and settled, waiting 30 minutes at most. `--no-epoch-wait` (update-node,
edit-config) or `TN_SKIP_EPOCH_WAIT=1` skips the wait, a rollback never waits, and a node outside
the committee is never held. update-node's `--json` runs end with exactly one `done` event, a ref
that starts with `-` is refused, and a killed update no longer leaves the update lock held.
remove-node v1.2.9 and migrate-node-naming v1.2.1 run under macOS `/bin/bash` 3.2, and a
migration removes the old `NODE_TYPE` hint instead of writing it.

#### Public RPC
`install-caddy.sh` v1.4.0 writes RPC block v2. Its WebSocket match ignores case, so an upgrade
that comes through Google's load balancer or nginx gets 101 instead of 405; a browser gets a 405
page that says the hostname is a JSON-RPC endpoint; a request body over 2 MB gets 413.
`rpc-status` reports a block written by an older version as stale, with the command that
refreshes it (a Caddy reload, no node restart). The advertised RPC in `node-info.yaml` is written
with the node's own `keytool set-rpc`, and the node is not restarted when the value already
matches. rpc-enable and rpc-disable keep the public RPC keys in `.node-meta` current, and
rpc-disable takes the Caddy site down before it withdraws the advertisement. Edits that restart
the node take the update lock, hostnames follow a strict rule, Caddyfile backups are pruned to
the newest five, and Caddy older than 2.8.0 is refused.

#### Health check
`check-node.sh` v1.2.0 compares the node with the network recorded in `.node-meta`, so a devnet
node is no longer reported as a chain ID mismatch, and its testnet comparison endpoint is
`https://rpc.adiri.tel`. When the comparison endpoint serves another chain, as
`https://rpc.telcoin.network` does until mainnet launches, it warns and skips the comparison.
Whether a node missing from the latest headers is an error now follows on-chain committee
membership, the authority ID comes from the node's own `tn_info`, and reputation is read from the
key the live RPC returns. A new epoch section shows the next boundary, committee membership for
this epoch and the next two, a staked validator's activation epoch and earliest seat, and the
worker count against `WorkerConfigs.numWorkers()`. The report runs to the end on macOS, and the
wss probe returns as soon as the upgrade answers instead of waiting eight seconds.

#### Firewall and add-ons
`firewall-setup.sh` v1.6.0 opens the node's own P2P ports, read from its launch line and then
`node-info.yaml` (every worker), instead of the fixed 49590 and 49594. Enabling the firewall
allows 80 and 443 whenever Caddy serves a site on the box, so turning ufw on no longer takes the
public RPC or the dashboard offline, and "View current firewall status" works again with ufw
active (it had stopped early since v1.1.1). `setup-observability.sh` v1.2.1 with
`lib/observability.sh` v1.0.2 ignores commented-out flags, says why a flag could not be added,
records nothing and skips the restart when a flag is still missing, and waits for the epoch
boundary before it restarts a committee node.

#### Staking helper
`prepare-stake.sh` v1.0.0 is new. It checks a node before it stakes: that the network RPC serves
the node's chain, that the address holds the whitelist NFT, its stake status, the stake amount
the registry asks for now, the TEL balance, and the calldata from the node's own keytool. It
simulates `stake()`, names any revert with what to do, and prints the `cast send` commands for
`stake()` and `activate()` with the epoch arithmetic. It sends nothing and never reads a private
key. `--rotate-address 0xNEW` re-signs the proof of possession for another execution address and
is refused once either address has staked; it asks for the BLS passphrase before it takes the
update lock, so an unanswered prompt never holds up another script. `install.sh` installs the
script and the updater tracks it.

#### Node Manager UI
telcoin-ui v1.9.0 needs install-ui v1.4.0 (helper API 2); a UI updated without re-running the
installer shows a "helper outdated" banner. The setup wizard offers public RPC with a hostname and
a DNS check. The System tab's RPC card shows what the node advertises, offers to refresh a stale
Caddy block, and can move the dashboard off the RPC hostname in the same step. The validator view
is decided from the network first (the node's `getValidator` record on the public RPC), so a
newly staked validator opens in the validator view while it syncs, and `NODE_TYPE` no longer
picks the view. On a synced node that view counts down to the epoch boundary and shows the
activation epoch and the earliest committee seat. Every action stream ends with one `done`, and
updates and config saves no longer use EventSource, whose reconnect could run an action twice.
Hostnames follow one strict rule in the page, the server and the helper. The role check never
waits on a public RPC endpoint inside a request: a background thread refreshes the network's
answer, each endpoint's chain ID is remembered for an hour, and a failing endpoint is backed off.

#### Updater and integrity
`update-scripts.sh` v1.1.70 fails closed: a file whose `.sha256` sidecar is missing, empty or
unreadable is not installed, the updater checks its own replacement against its sidecar before it
relaunches, `lib/common.sh` and `lib/fallback.sh` are installed together or not at all, and the
run exits 1 when any file failed. It now runs under macOS `/bin/bash` 3.2 (v1.1.69 stopped at
`declare -g`) and fetches `prepare-stake.sh`. `--help` prints the usage without contacting
GitHub, and an unknown argument is refused instead of ignored. An interrupted run removes the
files it downloaded but did not install, and a checksum the updater cannot download for its own
replacement is reported as a network error. `install.sh`, which is not
updater-tracked, installs `prepare-stake.sh`, ends with a link to the operator runbook, and no
longer stops when a script is missing from the download.

#### Maintainer tooling and CI
`tools/check-bash32.sh` flags bash 4+ syntax that macOS `/bin/bash` 3.2 parses but cannot run,
such as `declare -A`, `${v,,}`, `mapfile`, `&>>` and negative subscripts, including inside
one-line `case` arms. CI runs it on every `*.sh` under `/bin/bash` on macOS and under bash on
Ubuntu, and runs the UI tests: `ui/test_*.py`, and `ui/tests/helper_test.sh` under bash 3.2 and 5.
`ui/dev/serve.py` serves the page against canned scenarios for walk-throughs. None of this ships
to operators.

#### Docs
README.md and OPERATOR.md describe every new flag, the epoch wait, `prepare-stake.sh`, bootstrap
peers and the canonical endpoints: `https://rpc.adiri.tel` for testnet, and
`https://rpc.telcoin.network`, which serves the testnet chain until mainnet launches. The partner
guide is at version 1.1. The upstream fixes from the old "Docs upstream" list (the staking ABI,
worker port 49594, the `p2p_info.workers` shape, endpoints and explorers, the support address,
advertising an RPC endpoint) sit on a telcoin-network docs branch prepared locally, to be opened
as a PR; a devnet-genesis commit corrects the `config.sh` comment.

#### Security
Hardening in this round:

- Launch-file edits refuse a value with an unquoted shell metacharacter, and a systemd unit
  refuses `$`, `%` and backticks, so an edited flag value cannot become a second command in the
  start wrapper (lib/common v1.6.0).
- Every interactive answer and `--json` flag that reaches the root-run start wrapper, the unit or
  `.node-meta` is validated: ports, directories, the Docker image, the binary path, the execution
  address and the listener addresses. A pasted value such as `9101;id` can no longer be written
  there, and a prompt asks again until its answer is valid (setup-node v1.3.0).
- An interrupted UI config save can no longer leave an unapplied edit on disk for the next
  restart to pick up: edit-config rolls the edit back when the run ends before its restart
  (edit-config v1.3.0).
- A bootstrap-peers map is never echoed back: a rejected map is reported with the parser's reason
  and the value replaced. setup-node and edit-config accept only a peers file that other users can
  already read, because the installed copy is world-readable and the parse check puts the map on
  a command line, so the UI cannot be used to read a line of a root-only file (setup-node v1.3.0,
  edit-config v1.3.0, lib/common v1.6.0).
- The UI helper no longer takes a role argument, which shrinks its sudoers whitelist. install-ui
  v1.4.0 checks the new whitelist with `visudo -c` under a name sudo ignores and installs it last,
  so a rejected whitelist never replaces the live one.
- check-node no longer `eval`s strings taken from the consensus header the RPC returns. An answer
  holding `$(...)` would have run under sudo (present since 1.1.x); only base58 IDs and plain
  integers get through now (check-node v1.2.0).
- The updater installs nothing whose sidecar is missing and verifies its own replacement before it
  relaunches (update-scripts v1.1.70).
- update-node refuses a ref that starts with `-`, in `--json` runs and at the interactive prompt
  alike, so a ref can no longer pass an option to git or docker running as root (update-node
  v1.2.0).
- The observability add-on checks its input before it touches Alloy: `METRICS_PORT` must be a
  port number, and the launch-file edits are rehearsed first (setup-observability v1.2.1,
  lib/observability v1.0.2).
- A public RPC block caps request bodies at 2 MB; a larger JSON-RPC request gets 413 and never
  reaches reth in full (install-caddy v1.4.0).
- prepare-stake never puts the BLS passphrase or a key on a command line. The passphrase reaches
  only the keytool call that re-signs, through its environment; no private key is read or asked
  for, and the printed signing note warns against `cast --private-key`, which `ps` shows to every
  user of the machine (prepare-stake v1.0.0).
- The update lock is released on SIGTERM even while an orphaned child still holds its descriptor,
  and update-node's long-running children no longer inherit it, so a killed update does not block
  the next one (lib/common v1.6.0, update-node v1.2.0).

#### Known remaining
`followup.md` lists what this round left open, each item with its reason: provisioning more than
one worker, the fleet Caddy changes in the maintainer repo, the upstream docs PR, the ownership of
`/opt/telcoin`, `/etc/telcoin` and `.node-meta` (a security item with a recommended fix), and
smaller script and UI gaps.

### Partner guide for mobile network operators -- docs/partner/
`docs/partner/mno-node-guide.md` is the runbook rewritten for a partner reader, with no
legacy-install material and support@telcoin.org as the only contact. `tools/build-partner-pdf.sh`
renders it through pandoc and WeasyPrint into the branded `docs/partner/mno-node-guide.pdf`
(Telcoin colours, Geist fonts, cover, contents and running headers), which is committed next
to its sources. AGENTS.md has the sync rule.

### One contact address -- support@telcoin.org
The `setup-node.sh` welcome banner, `OPERATOR.md` and the README now give support@telcoin.org
for everything, validator onboarding, approval and hardware included. Ships in setup-node
v1.2.1 and update-scripts v1.1.69.

### Operator runbook -- `OPERATOR.md`
A standalone runbook (deploy, sync, public RPC, stake, activate, day-2 operations) now lives
at the repo root; README stays the reference and links to it. `followup.md` holds the
operator-facing backlog.

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
Superseded in part: hardware tiers now follow the per-role numbers in telcoin-network's
hardware-requirements page (validator minimum 8 physical cores / 32 GB ECC / 2 TB NVMe) and
the validator view follows the on-chain stake status (`getValidator`) rather than
`tn_isValidator`; see the README changelog. setup-node v1.3.0 and migrate-node-naming v1.2.1
remove `NODE_TYPE` from `.node-meta`, and the UI asks the network first.

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
