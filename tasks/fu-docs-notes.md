# Notes for the docs and closing packages (collected by the orchestrator)

Append-only during the run; DOC-1..4, CI and REL read this before starting.

## README.md (DOC-1)
- "Security model" still says the UI installer "removes it and stops if `visudo -c` rejects it".
  Since install-ui 1.4.0 a rejected sudoers candidate is discarded and the live drop-in stays in
  place; the swap is the last step. (UI-1)
- Changelog entries needed so far: lib/common 1.5.0, lib/fallback 1.0.3, install-ui 1.4.0 and the
  helper (text in `tasks/ckpt-fu-L1.md` and `tasks/ckpt-fu-UI-1.md`).

## Any doc that shows keytool commands (DOC-1, DOC-2, DOC-3)
- `keytool export-staking-args` needs a passphrase SOURCE even though it never reads the key:
  without `TN_BLS_PASSPHRASE` it exits 1 unless `--bls-passphrase-source no-passphrase` is given.
  `set-rpc` is the only keytool subcommand that needs no passphrase source. (V-UP, verified on the
  v0.15.0 build)
- keytool writes "INFO Loading configuration" to stdout, so `$(telcoin-network keytool … --calldata)`
  captures two lines; the global `-q` flag (or `--log.stdout.filter off`) makes it one line. Every
  capture example must use `telcoin-network -q --bls-passphrase-source no-passphrase keytool
  export-staking-args --node-info … --calldata`. Check OPERATOR.md, README.md and the partner guide
  for such examples; `prepare-stake.sh` (D) and `tn_keytool` (L2) handle this in code. (V-UP)

## setup-node 1.3.0 (DOC-1, DOC-2, DOC-3)
- README flag table: `existing` with `--json` no longer assumes `/opt/telcoin/telcoin-network`;
  `--binary-path PATH` names the binary (absolute; implies `existing` in JSON mode). Keygen records
  the install method and the docker image or binary path in `.node-meta` and finalize reads them
  back, so "pass `--docker-image` to both phases" is no longer required (still allowed). A finalize
  whose keygen ran under 1.2.1 has no recorded binary for `existing` and needs `--binary-path`. (P4a)
- The four public URL flags are validated; private hosts and `.local`/`.internal` names warn;
  `--build-ref`/`--docker-image` below v0.13.0-adiri are refused on testnet. (P4a)
- `done` events: finalize adds `operator_guide` and `public_rpc` `{enabled, domain, http, ws}`
  (URLs without a trailing slash); failure `done` messages carry the reason. (P4a)
- Listener addresses at finalize are neither validated nor recorded (unchanged; the UI always
  sends them) — followup candidate. (P4a)

## edit-config 1.3.0 (DOC-1, DOC-2, DOC-3)
- New `--set` fields (also menu items 8–10): `bootstrap_peers=<absolute path>|none`,
  `state_export=off|unlimited|N`, `allow_private_forward_targets=true|false` (devnet only; refused
  on testnet 2017 and mainnet 487). `metrics=<ip:port>|off` now adds or removes the flag. `--set`
  works without `--json`. Menu renumbering: refresh chain configs 11, Restart 12, Exit 13; the BLS
  passphrase item stays 5 (OPERATOR.md cites it). An edit that changes nothing does not restart.
  Edits are refused while update-node holds the lock ("an update is in progress"). `--no-epoch-wait`.
  (P5)
- `bootstrap_peers` is refused on a node started straight from its systemd unit ("convert the
  unit to a start wrapper first"); no script converts a unit, so the docs need the manual
  procedure (write the wrapper as setup-node 1.3.0 does, point ExecStart at it). (P5)
- Refresh chain configs needs `NETWORK` in `.node-meta`; a source build checked out at a release
  tag cannot `git pull` and refresh says so. (P5)
- followup.md: `tn_node_parse_check` keeps only the first `error:` line, so for a multi-line
  peers map clap's real reason (on a later line) is lost; edit-config prints a shape hint. (P5)
- UI: the helper's `config-set` allowlist and the server's validation must accept the new fields
  (patterns: metrics `^(off|([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5})$`, bootstrap_peers
  `^(none|/[A-Za-z0-9._/-]+)$`, state_export `^(off|unlimited|[1-9][0-9]{0,5})$`,
  allow_private_forward_targets `^(true|false)$`) — queued as a UI follow-up. The UI bundle must
  ship edit-config 1.3.0 together with lib 1.6.0 (the hard guard). (P5)

## setup-node node flags (DOC-1, DOC-2, DOC-3)
- `--bootstrap-peers FILE` (YAML/JSON map keyed by BLS public key, ≤ 64 KiB, installed as
  `/etc/telcoin/bootstrap-peers.yaml`, read at every start; needs v0.15.0-adiri),
  `--enable-state-export` (v0.13.0+), `--state-export-keep N` (1–999999; v0.15.0+; implies enable).
  `.node-meta`: `BOOTSTRAP_PEERS_FILE` (installed path or empty), `STATE_EXPORT=off|unlimited|N`;
  a JSON finalize reads them back. `setup-node.sh --help` exists now. (P4b)
- followup.md: check-node could warn when the peers file named on the launch line is missing or
  empty (v0.15.0 refuses `--bootstrap-peers ""` and the node cannot start). (P4b)
- followup.md, SECURITY: `create_directories` gives `/opt/telcoin` and `/etc/telcoin` to the
  service user while root writes files there and the docker wrapper under `/opt/telcoin` runs as
  root — the service user could replace a file root later trusts or runs. Recommended fix: root:root
  0755 directories, service-readable files where the node needs them (passphrase file 0640
  root:<group>); needs a migration step for existing installs, so it was not changed in this
  round. Pre-existing; found by P4b. (Also covers the `.node-meta` ownership item already listed.)

## prepare-stake.sh 1.0.0 (DOC-1, DOC-2, DOC-3)
- New operator script: `sudo bash prepare-stake.sh [--network-rpc URL] [--json]` checks the chain,
  the whitelist NFT, the stake status, the stake amount and balance, exports the calldata with the
  node's keytool, simulates the stake and prints the exact `cast send` lines (stake, then
  `activate()`) plus the epoch arithmetic; `--rotate-address 0xNEW [--yes] [--no-restart]` re-signs
  the proof of possession for a new execution address (refused once the current address holds any
  stake status or is retired). Exit codes 0 ready/nothing to do, 1 usage, 2 RPC or state
  unreadable, 3 not ready or refused, 4 rotation rolled back. Never reads or prints a private key;
  the passphrase travels only in the environment of one keytool call. Exact operator wording per
  exit code and per decoded revert is in `tasks/ckpt-fu-D.md`. (D)
- On TPM installs the plaintext passphrase file is gone after sealing, so rotation needs
  `TN_BLS_PASSPHRASE` or the prompt. (D)
- followup.md: `tn_rpc_call` drops revert `data`, so prepare-stake carries a private RPC call to
  decode registry errors; the library could return the data. (D)

## update-scripts release entry (DOC-1 changelog, DOC-4 CHANGELOG)
- The updater now fails closed: a file whose `.sha256` sidecar is missing, empty or unreadable is
  not installed ("FAILED (no checksum published -- not installed)"); the updater verifies its own
  replacement against `update-scripts.sh.sha256` before relaunching; the common.sh/fallback.sh pair
  is installed together or not at all; the run exits 1 when any file failed and the summary
  separates verification failures from network failures; a partial download of the version header
  no longer aborts the run; `FILES_TO_UPDATE` is a top-level indexed array and the `declare -g` maps
  are gone, so the updater runs under macOS bash 3.2 (the published 1.1.69 exits at `declare -g`);
  the `source lib/fallback.sh` is guarded so a lone copy works under bash 3.2. (V-CORE-2 / P3)
- The lint (`tools/check-bash32.sh`) also checks commands inside one-line `case` arms and flags
  `${v~}`, arithmetic negative subscripts, negative substring offsets and `exec {fd}>`. (V-CORE-2)

## NODE_TYPE hint is gone (DOC-1, DOC-2)
- README.md says new installs write `NODE_TYPE=observer` to `.node-meta`; setup-node 1.3.0 and
  migrate-node-naming 1.2.1 remove the key instead (the view follows the on-chain stake status).
  Nodes migrated by 1.2.0 keep the stale line; it is harmless and ignored. (P3)
- Changelog entries: remove-node 1.2.9, migrate-node-naming 1.2.1, update-scripts (in the release
  entry: top-level FILES_TO_UPDATE, the declare -g maps removed), tools/check-bash32.sh mention in
  AGENTS.md. (P3)

## Public RPC / install-caddy 1.4.0 (DOC-1, DOC-2, DOC-3)
- README's install-caddy v1.3.0 changelog says backups are "never pruned"; 1.4.0 keeps the
  newest five `Caddyfile.bak.*` (never `.tn-orig` or the backup of the current change). (A)
- The request-body cap is Caddy's `2MB` = 2,000,000 bytes; Caddy cuts the connection once the
  cap is passed, so an oversized request never completes (reth sees headers and the first bytes,
  never a full request). The largest legitimate JSON-RPC request is about 256 KiB. (A)
- Operators on the old block see `block_stale` in `rpc-status` / a check-node warning; the fix is
  re-running rpc-enable with the same hostname (a Caddy reload, no node restart). (A)
- rpc-enable may wait up to 30 min for an epoch boundary on a committee node before editing
  node-info and restarting; rpc-disable too. `TN_SKIP_EPOCH_WAIT=1` skips. (A)
- followup.md "Recorded, not fixed": on a node with several workers, set-rpc (and the python
  fallback) edit worker 0 only, so rpc-disable leaves workers 1+ advertising the old URL until
  a keytool with `--worker-id` ships (unreleased on origin/main). (A)

## firewall-setup 1.6.0, observability (DOC-1, DOC-2, DOC-3)
- The P2P ports follow the node: the listener addresses on the launch line, then node-info.yaml
  (every worker), then the 49590/49594 defaults. Docs that say "UDP 49590/49594" should say
  "the node's P2P ports (49590 primary and 49594 worker by convention; check-node and
  firewall-setup --status show the real ones)". A plain enable now allows 80/443 when Caddy serves
  a site on the box. JSON gains `p2p_ports` objects; the old `ports` keys are unchanged. (C)
- "View current firewall status" crashed under `set -e` on every box with ufw active since v1.1.1
  (a grep that never matched real `ufw status verbose` output); fixed in 1.6.0 — changelog. (C)
- Observability: commented-out `--metrics`/log flags no longer count as present; restarts wait
  for the epoch boundary; inject failures say why. (C)
- UI fix pass: the page's `fwExtraPorts` reads `p.open`/`p.ok`; it must read `p.allowed`
  (true/false/null) and the raw labels `primary`, `worker-N`. (C)
- followup.md: the UI's three fixed firewall toggles still act on 49590/49594 even when the node
  listens elsewhere; the observability `--metrics` address is not compared with `obs_metrics_addr`. (C)

## Epoch-aware restarts (DOC-1, DOC-2, DOC-3)
- update-node 1.2.0 (and later edit-config, install-caddy, observability) wait for a committee
  node's epoch boundary before stopping it: within `TN_EPOCH_MARGIN` (300 s) of the boundary they
  wait for the epoch to roll over plus `TN_EPOCH_SETTLE` (90 s), capped at `TN_EPOCH_WAIT_MAX`
  (1800 s); `--no-epoch-wait` or `TN_SKIP_EPOCH_WAIT=1` skips it; rollbacks never wait; observers
  and non-committee validators are not delayed. A UI-driven update can therefore sit in "waiting
  for the epoch boundary" for up to 30 minutes with a heartbeat every 15 s; the page must stay
  open (closing it aborts the update before the node is stopped, which is safe). (P6)

## OPERATOR.md (DOC-2)
- `https://rpc.telcoin.network` serves chain 2017 (testnet) until mainnet launches; say so where
  the mainnet endpoint is named, and keep `https://rpc.adiri.tel` as the testnet endpoint. (UP)

## Partner guide (DOC-3)
- Endpoint and explorer names follow the decision: `rpc.adiri.tel`, `telscan.io`, `www.telscan.xyz`.

## CHANGELOG / AGENTS / followup (DOC-4)
- followup.md "Recorded, not fixed": add the `tn-contracts` `StakeConfig` comment that calls
  `epochDuration` "in L2 blocks" (it is seconds) (UP); the CLI README drift outside the touched
  sections (`--workers` "1-4, must be 1"; the keytool flags table omits `--rpc-http`/`--rpc-ws`)
  (UP); `etc/compose.yaml` uses udp/49595 on its private bridge and the CLI README's Docker env
  row mirrors it on purpose (UP); the Update and Config tab streams still abort when the operator
  leaves the tab and the server kills the script after 2 s (UI-3a); the stale-block refresh sends
  no inbound IP, so on a 1:1-NAT host its DNS check may fail — rpc-status could report the
  inbound-IP override (UI-3a).
- AGENTS.md maintainer-only list gains `ui/tests/`, `ui/dev/`, `tools/check-bash32.sh`, `ui/test_*.py`.

## From DOC-2 (for DOC-1, DOC-3, DOC-4)
- README links `OPERATOR.md#64-export-the-stake-calldata-on-the-node`; OPERATOR.md 6.4 is now
  "Activate" and a hidden anchor keeps the old link working; DOC-1 should point at
  `#610-stake-by-hand` instead. (DOC-2)
- followup.md: `--help` gaps — `setup-node.sh --help` lists none of the `--json`-mode flags,
  `update-node.sh --help` lists no `--json`/`--check`/`--prepare`/`--ref`/`--apply`/`--yes`, and
  install-caddy, firewall-setup, setup-observability and remove-node answer `--help` with "must be
  run as root". (DOC-2)
- followup.md: migrate-node-naming still opens the fixed ports 49590/49594 rather than the node's
  own ports. (DOC-2)
- The appendix names the upstream branch `docs/operator-docs-backlog`; it exists locally only
  until the user pushes it — word it as "prepared locally, to be opened as a PR". (DOC-2)

## CI (orchestrator)
- Run `ui/tests/helper_test.sh` under `/bin/bash` in the macOS job and under bash in the Ubuntu
  UI job (UI-1).
