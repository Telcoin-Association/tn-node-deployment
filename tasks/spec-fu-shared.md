# Shared spec for the followup.md backlog work (read first)

Every implementation and verification agent reads this file, then its own package spec:
`tasks/spec-fu-core.md` (library, setup-node, edit-config, update-node, remove-node, migrate,
updater, lint tool), `tasks/spec-fu-ops.md` (install-caddy, check-node, firewall, observability,
prepare-stake) or `tasks/spec-fu-ui.md` (Node Manager UI). Where the appendices disagree,
`spec-fu-core.md` wins on helper signatures. The orchestrator is the only committer in this repo.

## Ground rules

- Commits (orchestrator, or the upstream agent in `../tn-5` and `../devnet-genesis`): conventional
  prefix, plain prose, no `Co-Authored-By` or "Generated with" line, explicit paths only, never
  `tasks/`, `.claude/` or `.DS_Store`.
- bash 3.2 safe: no `declare -A`, `declare -g`, `local -n`, `${var,,}`, `${var^^}`, `mapfile`,
  `readarray`, `&>>`, `|&`, `[[ -v`, `wait -n`, negative subscripts, `${v@X}`, `%(…)T`, `;;&`.
  Empty arrays expand as `${a[@]+"${a[@]}"}` under `set -u`. No apostrophes inside a
  `${var:-default}` word. Declare locals on the `local` line and assign on separate lines
  (`local a b; a="$(x)"; b="$(y)"`). `readonly arr=(…)` is invisible under 3.2 when sourced inside
  a function: source at top level. See `tasks/lessons.md` for the full list of harness gotchas.
- Boundary rule: nothing operator-facing may call, source or point at `common/` or
  `devnet-genesis/`. A provenance comment may mention them only if marked maintainer-only.
- Never emit or reintroduce `--observer` / `--validator`.
- Whoever edits an updater-tracked file bumps its version constant (target versions below).
  Sidecars (`tools/gen-checksums.sh`), README changelog entries and docs are handled centrally;
  do not touch `*.sha256`, `README.md`, `OPERATOR.md`, `CHANGELOG.md` or `docs/` unless your
  package owns them.
- `--json` runs print only JSON events on stdout and always end with a `done` event.
- Agents edit and self-test only. In this repo never run `git add`, `git commit`, `git stash`,
  `git checkout`, `git switch` or `git reset`. Read-only git (`git diff`, `git log`, `git show`)
  is fine.
- Own only the files your package lists. If a change seems to require touching another file,
  write it up under "open issues" in your checkpoint and hand back.
- Prose in comments, help text and messages follows the `human-writing` skill: plain, specific,
  no filler. No line-number references anywhere.
- Temporary files go in the session scratchpad
  (`/private/tmp/claude-501/-Users-grant-coding-telcoin-tn-node-deployment/eddb430f-f0dc-43fe-9180-65cd421b1e88/scratchpad`),
  never in the repo.

## Checkpoint protocol

- Checkpoint file: `tasks/ckpt-fu-<package>.md`. First line `status: <in-progress|blocked|done>`.
  Then a list of sections with `[x]`/`[ ]`, rewritten after EACH section, not once at the end.
- On start, read your own checkpoint and continue from the first unfinished section.
- The checkpoint ends with four headings: **Operator-visible changes**, **Changelog text** (one
  `### <file> vX.Y.Z — …` paragraph per bumped file, in README changelog style), **Tests run**
  (commands and results), **Open issues**.
- Budget well under 250k tokens. If you are ballooning, checkpoint and hand back; the
  orchestrator respawns for the remainder.
- If Write is refused, do not work around it: return the complete text in the final answer.
- Return a summary (not file dumps) in the final answer.

## Target versions

lib/common 1.5.0 (L1) then 1.6.0 (L2); lib/fallback 1.0.3; setup-node 1.3.0; edit-config 1.3.0;
update-node 1.2.0; install-caddy 1.4.0; check-node 1.2.0; firewall-setup 1.6.0; remove-node 1.2.9;
migrate-node-naming 1.2.1; setup-observability 1.2.1; lib/observability 1.0.2; prepare-stake 1.0.0;
telcoin-ui (`UI_VERSION` in ui/server.py) 1.9.0 (bumped only in the final UI commit); install-ui
1.4.0; update-scripts once, in the release commit (orchestrator).

Current versions on disk (2026-10-01): lib/common 1.4.0, lib/fallback 1.0.2, setup-node 1.2.1,
edit-config 1.2.6, update-node 1.1.63, install-caddy 1.3.0, check-node 1.1.55, firewall-setup 1.5.2,
remove-node 1.2.8, migrate-node-naming 1.2.0, setup-observability 1.2.0, lib/observability 1.0.1,
update-scripts 1.1.69, UI 1.8.8, install-ui 1.3.0.

## Verified facts (rely on these; do not re-derive)

Node binary and chain:

- Release tags `v0.11.0-adiri` … `v0.15.0-adiri`; every tag's crate version is `0.1.0`, so version
  checks use the git ref, the image tag, or a `--help` probe.
- Feature per release tag (checked with `git grep` against the tags on 2026-10-01):
  `keytool export-staking-args` exists at v0.11.0 and later; `keytool set-rpc`, `keytool generate
  --rpc-http` and `keytool generate pop` exist from **v0.12.0-adiri**; `--enable-state-export` from
  **v0.13.0-adiri**; `--state-export-keep` and `--bootstrap-peers` from **v0.15.0-adiri**. The source
  floor becomes 0.13.0 so every allowed build has set-rpc, pop and state export; word the comment
  that way (set-rpc alone would allow 0.12.0).
- `node --bootstrap-peers <MAP>`: inline YAML or JSON (not a path), keyed by BLS key; replaces the
  genesis bootstrap servers; parsed by a clap value parser, so `node --bootstrap-peers "$x" --help`
  validates the value with no side effects.
- `--enable-state-export` writes `<datadir>/consensus-db/state_exports/epoch-N/`;
  `--state-export-keep <N>` (N ≥ 1, needs the enable flag).
- `allow_private_forward_targets`: top-level boolean in `<datadir>/parameters.yaml`, default false,
  no CLI flag; read because this repo launches nodes without `--chain`. Safe to write on any release.
- keytool: `set-rpc (--http URL [--ws URL] | --clear)` edits `p2p_info.workers[0].rpc` only, no
  passphrase (a `--worker-id N` flag, default 0, exists only on unreleased `origin/main`; no
  release tag up to v0.15.0-adiri accepts it, so never pass it); `--chain` values are the
  kebab-case `adiri`, `test-net`, `main-net` (this repo launches without `--chain`); `generate pop --address` re-signs the proof of possession (passphrase via
  `TN_BLS_PASSPHRASE`); `export-staking-args --node-info <path> (--calldata|--json)`; `--datadir`
  is a global flag.
- Workers: count is on-chain, `WorkerConfigs` `0xFee0FEe0fee0fEE0FEe0fee0FEE0fEe0feE0FEe0`
  `numWorkers()` `0x57eb3b30` (1 on testnet today). Worker N RPC ports: http − 200·N, ws + 400·N.
- `tn_*` RPC is always served: `tn_nodeMode` (`CvvActive` | `CvvInactive` | `Observer`),
  `tn_getCurrentEpochInfo`, `tn_getEpochInfo(epoch)` for current−3 … current+2 (decimal epoch,
  committee is a list of addresses), `tn_info` (`authority_id`, `bls_public_key`,
  `execution_address`; header `author` values use the same base58 form as `authority_id`).
- ConsensusRegistry `0x07E17e17E17e17E17e17E17E17E17e17e17E17e1`: `getValidator(address)`
  `0x1904bb2e` (7 words; status is word 3), `balanceOf` `0x70a08231`, `getCurrentStakeVersion()`
  `0x67398331`, `stakeConfig(uint8)` `0xa71954ec` (word 0 is the stake amount; 1,000,000 TEL on
  testnet), `stake(bytes,(bytes))` `0x2fb0d025`, `activate()` `0x0f15f4c0`, `unstake(address,bool)`
  `0xf66a25a4`.
- Validator status values: 1 Staked, 2 PendingActivation, 3 Active, 4 PendingExit, 5 Exited
  (0 is no record). Lifecycle: `activate()` in epoch E gives `activationEpoch = E+1`; earliest
  committee seat is `activationEpoch + 2`. `unstake` is eligible when Staked, or Exited with
  `currentEpoch >= exitEpoch + 1`.
- Epoch boundary: `timestamp(block[blockHeight−1]) + epochDuration` seconds; closes at the first
  commit at or after it; epoch votes are exchanged for 60 to 75 s afterwards.
- Chain ids: testnet 2017, devnet 32285, mainnet 487.

Live response shapes, probed read-only against `https://rpc.adiri.tel` on 2026-10-01 19:40 CDT
(use these field names; the probes are the ones V-L repeats):

- `eth_chainId` → `"0x7e1"` (2017). `tn_nodeMode` → `"CvvActive"` (the balanced hostname lands on
  a committee node).
- `tn_info` → object with `chain_id` (2017, number), `version` (`"0.1.0 (<commit>)"`), `name`,
  `bls_public_key` (base58), `authority_id` (base58, e.g. `G6A8BRn31vofiVH8KZzETW2kcPsbomNTQYMgvZg52jTg`),
  `execution_address` (lowercase 0x), `primary_network_key`, `worker_network_key`,
  `primary_external_address` (multiaddr), and more.
- `tn_getCurrentEpochInfo` → `{"committee":[<5 lowercase 0x addresses>],"epochIssuance":"0x…",
  "blockHeight":497019,"epochId":580,"epochDuration":21600,"stakeVersion":0}`. Numbers are JSON
  numbers, not hex strings, except `epochIssuance`. `epochDuration` is seconds (6 h on testnet).
- `tn_getEpochInfo` takes `[<decimal epoch>]` and returns the same shape. Out of range (current+3)
  → JSON-RPC error `{"code":3,"message":"execution reverted","data":"0x9f5ba9a6<epoch as uint256>"}`.
- `getValidator(address)` on a committee member → 7 words. Layout per `IConsensusRegistry.sol`
  at the v0.15.0-adiri tag (tn-contracts 10cc12b7, also origin/main's pointer), corrected
  2026-10-01 23:30 after UI-2b's check: `[address validatorAddress, uint32 activationEpoch,
  uint32 exitEpoch, ValidatorStatus currentStatus, bool isRetired, uint8 stakeVersion, uint8 region]`.
  There is no `isDelegated` field. `exitEpoch` is 0 until an exit begins and `type(uint32).max`
  (4294967295) while PendingExit. `ValidatorStatus`: 0 Undefined, 1 Staked, 2 PendingActivation,
  3 Active, 4 PendingExit, 5 Exited, 6 Any (a query filter value, never stored for a validator).
  The genesis validator probed shows `activationEpoch 0, exitEpoch 0, status 3, retired 0,
  stakeVersion 0, region 0`. Decoders must accept `stakeVersion` and `region` up to 255.
  On an address with no record it reverts: error code 3, data `0xed15e6cf<address as uint256>`
  (a revert is `none`).
- `balanceOf(address)` on a committee member → 1 (the whitelist NFT).
- `getCurrentStakeVersion()` → 0; `stakeConfig(0)` → 4 words:
  `stakeAmount 0xd3c21bcecceda1000000` (= 1e24 = 1,000,000 TEL), `minWithdrawAmount
  0x3635c9adc5dea00000` (1e21), `epochIssuance 0x576f23131f3c2780000`, `epochDuration 0x5460` (21600).
- `WorkerConfigs.numWorkers()` → 1.

Endpoints (decision taken with the user): testnet RPC `https://rpc.adiri.tel`, mainnet RPC
`https://rpc.telcoin.network` (not yet launched), devnet `https://rpc.devnet.telcoin.network`,
explorers `https://telscan.io` and `https://www.telscan.xyz`. `scan.telcoin.network` is dead.
**Today `https://rpc.telcoin.network` answers `eth_chainId` `0x7e1` (2017, Adiri)**: until mainnet
launches it is a second testnet hostname. Consequences: check-node (package B) must not report a
node as mismatched because the *comparison endpoint* serves a different chain than expected — when
the network RPC's chain id differs from the expected id, WARN that the endpoint serves chain X and
skip the chain comparison; the UI (UI-2) must never treat an answer from that hostname as a
mainnet answer without checking `eth_chainId` first; prepare-stake (D) checks the network RPC's
chain id against the configured network before anything else (exit 2 on mismatch).

Probed live on 2026-10-01:

- Caddy's `header` matcher is case-sensitive: `Connection: upgrade` (as Google's balancer and
  nginx send it) gets 405, `Connection: Upgrade` gets 101. `install-caddy.sh` writes that matcher.
- The balanced hostnames (`rpc.adiri.tel`, `rpc.telcoin.network`, `rpc.devnet.telcoin.network`)
  answer 405 to a WebSocket upgrade; per-node hostnames answer 101.

Local toolchain: `/bin/bash` 3.2.57, bash 5.3 (`bash`), shellcheck, caddy 2.11, node 24, python3
(Flask lives in the scratchpad venv at `<scratchpad>/ui-venv`; use `<scratchpad>/ui-venv/bin/python`),
pandoc 3.11, WeasyPrint 70.0, mdbook 0.5.4, cast, jq. No `ufw`, `systemctl`, `lscpu` or `timeout`
on the host: use PATH shims for GNU-only behaviour. The Bash tool runs under zsh: never use a bare
`=====` word as a separator.

**Docker is unavailable for this whole session** (the Docker Desktop engine is hung and cannot be
restarted). Do not call `docker` for anything, do not wait on it, and do not try to pull images.
Substitutes, decided by the orchestrator:

- Real node binary: `/Users/grant/coding/telcoin/tn-4/target/debug/telcoin-network` (debug build,
  commit dbc67b2e, pre-v0.15.0: its `node --help` still lists `--observer`). It has `keytool generate
  validator|observer|pop`, `keytool set-rpc (--http [--ws] | --clear)` without `--worker-id`,
  `keytool export-staking-args --node-info … (--json|--calldata)`, and `node --enable-state-export`;
  it lacks `--bootstrap-peers` and `--state-export-keep`, which makes it a good negative fixture for
  `tn_node_has_flag`. Use it as `binary:/Users/grant/coding/telcoin/tn-4/target/debug/telcoin-network`
  with a temp data dir in the scratchpad. It starts slowly (debug build); give probes a few seconds.
  Never write into `/Users/grant/coding/telcoin/tn-4`.
- **Primary real binary (v0.15.0-adiri, built 2026-10-01 from a `git archive` of the tag, debug
  profile):**
  `/private/tmp/claude-501/-Users-grant-coding-telcoin-tn-node-deployment/eddb430f-f0dc-43fe-9180-65cd421b1e88/scratchpad/tn5-target/debug/telcoin-network`.
  Verified: `node --help` lists `--bootstrap-peers`, `--enable-state-export`, `--state-export-keep`
  and no `--observer`; `keytool set-rpc` has no `--worker-id`; `node --bootstrap-peers 'not: [valid'
  --help` exits 2 and `node --bootstrap-peers '{}' --help` exits 0 (so `tn_node_parse_check` works
  against it). `--version` prints `Commit SHA: VERGEN_IDEMPOTENT_OUTPUT` because the export has no
  `.git`; the tag commit is 5736cc30, the same the live testnet node reports. Use this as
  `binary:<that path>` for every real-binary test; use the tn-4 binary above only as the
  pre-v0.15.0 negative fixture. Both start slowly (debug builds): allow a few seconds per call.
- Caddy floor version: `<scratchpad>/caddy-2.8/caddy` is Caddy v2.8.4 for macOS; run `validate`,
  `adapt` and `fmt` with it as well as with the Homebrew 2.11.
- Linux-only behaviour (`ufw`, `systemctl`, `lscpu`, GNU `df --output`, `/proc/*`): PATH shims and
  fixture files under the scratchpad; no container.
- `docker` inside scripts under test: a recording PATH shim that logs its argv to a file.

## Existing library surface (names already taken; reuse, do not duplicate)

lib/common.sh: print_header print_step print_ok print_warn print_error print_info print_sep confirm
check_root tn_acquire_update_lock detect_distro check_cve_2026_31431 install_package
update_package_index command_exists validate_ipv4 validate_ipv6 validate_public_ip validate_port
validate_ip_port validate_multiaddr latest_docker_image validate_docker_image
prompt_with_validation _tn_hw_disk_label _tn_hw_role check_hardware check_ports check_internet
version_gte check_rust check_docker verify_binary check_rpc_alive check_peer_count
create_service_user create_directories write_advertised_name write_source_version_marker
select_network select_install_method tn_sync_submodules ensure_chain_configs_available
write_systemd_service detect_internal_ip select_ipv4_binding select_listener_ip node_stake_status
node_is_staked_validator print_validator_onchain_status check_validator_onchain_status
display_node_info tpm_check_available tpm_seal_passphrase tpm_remove_sealed_files print_summary
pick_source_version pick_action is_testnet is_testnet_like require_testnet node_meta_path meta_get
meta_set validate_cidr validate_overlay_ip ufw_installed ufw_active ufw_has_allow get_ssh_port
validate_health_src kuma_extra_list apply_kuma_extra_rules kuma_extra_add kuma_extra_remove
apply_kuma_rule apply_lb_hc_rule allow_overlay_ssh tn_node_launch_flags tn_node_launch_target
tn_node_inject_flags tn_node_has_observer_flag tn_node_strip_observer_flag tn_target_drops_observer
prompt_testnet_addons step_testnet_addons

lib/fallback.sh: _tn_unit_dir _tn_etc _tn_var _tn_meta_get tn_resolve_service tn_all_node_services
tn_resolve_container tn_legacy_node_meta_path tn_resolve_config_dir _tn_meta_data_dir
tn_resolve_data_dir tn_resolve_node_type (to be deprecated, no callers)

lib/observability.sh: obs_effective_push_url obs_effective_metrics_url obs_reth_log_flags
obs_metrics_addr obs_metrics_reth_flags obs_image_version obs_label_sourcing obs_write_config_alloy
_obs_slice_alloy _obs_alloy_fallback _obs_write_env_file _obs_disable_packaged_alloy
_obs_install_alloy_apt _obs_install_alloy_tarball obs_install_alloy_native
obs_write_alloy_native_unit obs_run_alloy_docker obs_ensure_reth_flags obs_enable
obs_existing_token obs_disable obs_disable_logs obs_disable_metrics obs_status

## Known bash-4 constructs on today's tree (the lint must flag exactly these until fixed)

Fixed already (L1, UI-1 committed): `lib/common.sh` `confirm()` `${response,,}`,
`ui/install-ui.sh` two `${var,,}`. Still present until P3 lands: `remove-node.sh` three
`declare -A`; `update-scripts.sh` `declare -ga FILES_TO_UPDATE` and two `declare -gA`;
`migrate-node-naming.sh` `local -n moved_ref`. The lint tool must flag exactly those on the tree
P3 starts from, and nothing once P3 is done.

## Test harness pattern

Source a copy of the script with the trailing `main "$@"` removed, at top level, with `lib/`
symlinked beside it, PATH shims first, under `/bin/bash` (3.2) and `bash` (5). Stub
side-effecting functions after sourcing. Drive `read` via piped stdin (prompts are silent when
stdin is not a TTY; assert on state). Re-parse every JSON output line with `jq -e .`.
