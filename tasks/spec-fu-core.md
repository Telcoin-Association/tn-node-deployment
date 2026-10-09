# Appendix B: shared library and core scripts

Read `tasks/spec-fu-shared.md` first. Where `tasks/spec-fu-ops.md` assumed a different helper
signature, this file wins.

## B.1 Conventions

- Every new function is bash 3.2 compatible, clean under `set -u`, safe under `set -e` and
  `set +e` (update-node runs `set +e`), and never calls `exit`.
- RPC helpers: rc 0 puts the value on stdout. Any other rc puts one line `<kind> <detail>` on
  stdout, where kind is `transport`, `http`, `rpc-error` (`<code> <message>`) or `malformed`.
  Capture with `out="$(fn …)" || rc=$?`.
- Runner spec: `docker:<image>` or `binary:<abs-path>`, obtained from `tn_launch_runner`.
- Launch-flag family return codes: 0 changed, 1 no change needed, 2 no live node `--http` line,
  3 refused (trailing comment, invalid flag or value), 4 I/O error. The file is untouched unless
  rc is 0.
- Hard guard, for scripts that cannot work on an older library (setup-node, edit-config,
  prepare-stake), right after `source lib/common.sh` at top level:

```bash
if ! version_gte "${COMMON_VERSION:-0}" "1.6.0"; then
    _tn_old="lib/common.sh ${COMMON_VERSION:-unknown} is older than 1.6.0. Run update-scripts.sh and try again."
    case " $* " in
        *" --json "*) printf '{"event":"error","msg":"%s"}\n{"event":"done","ok":false,"msg":"%s"}\n' "$_tn_old" "$_tn_old" ;;
        *) printf '[ERROR] %s\n' "$_tn_old" >&2 ;;
    esac
    exit 1
fi
```

- Soft guard, for optional helpers (install-caddy, update-node, check-node, firewall-setup,
  observability): `declare -F <helper> >/dev/null 2>&1 || { warn "…run update-scripts.sh"; <old behaviour>; }`.

## B.2 `lib/common.sh` pass L1 → `COMMON_VERSION` 1.5.0

Constants: `TESTNET_RPC_URL="https://rpc.adiri.tel"`, `TESTNET_EXPLORER="https://telscan.io"`,
`MAINNET_CHAIN_ID="487"`, `MAINNET_EXPLORER="https://telscan.io"` (mainnet RPC unchanged),
`MIN_SOURCE_VERSION_TESTNET="0.13.0"` (comment: set-rpc and pop arrived in 0.12.0, state export in
0.13.0; 0.13.0 is the first release with all three), and readonly
`TN_OPERATOR_GUIDE_URL="https://github.com/Telcoin-Association/tn-node-deployment/blob/main/OPERATOR.md"`.
`display_node_info` reads the stake amount with `getCurrentStakeVersion()` + `stakeConfig(uint8)`
and points to `prepare-stake.sh`.

| Function | stdout on rc 0 | Notes |
|---|---|---|
| `confirm PROMPT` | unchanged | lowercases with `tr` |
| `meta_set KEY VAL [file]` | none | rc 1 and nothing written when KEY is not `^[A-Z][A-Z0-9_]*$` or VAL has CR or LF |
| `meta_unset KEY [file]` | none | removes every `KEY=` line; rc 0 when absent; keeps mode 0600 |
| `validate_rpc_url URL [http\|ws\|any]` | none | `http(s)://` or `ws(s)://`, host (DNS, IPv4, `[IPv6]`), optional port and path; no userinfo, whitespace, quotes or control characters; at most 512 characters |
| `rpc_url_is_private URL` | none | 0 for loopback, RFC 1918, link-local, 100.64/10, `localhost`, single-label, `.local`, `.internal` |
| `tn_ref_min_check REF NETWORK` | message on rc 1 or 2 | 0 allowed; 1 refused (release tag below the floor); 2 allowed with a warning (not a release tag). An image reference is checked on the part after the last `:` |
| `tn_genesis_chain_id FILE`, `tn_is_public_chain_id ID` | chain id | used by edit-config's private-network gate |
| `tn_rpc_call URL METHOD [PARAMS='[]'] [MAX_TIME=10]` | response body, one line | failure order: transport, HTTP not 2xx, error object, missing `result` |
| `tn_json_field JSON KEY` | first `"KEY":` scalar, unquoted | rc 1 when missing or not a scalar |
| `tn_local_rpc_url` | `http://127.0.0.1:<RPC_PORT or 8545>` | |
| `tn_node_mode [URL]` | `CvvActive` \| `CvvInactive` \| `Observer` | |
| `tn_epoch_info [URL] [EPOCH]` | `<epoch_id> <block_height> <epoch_duration> <stake_version> <committee_csv\|->` (lowercase) | decimal epoch; never decodes `epochIssuance` |
| `tn_epoch_secs_left [URL]` | `<secs_left> <epoch_id> <boundary_unix> <epoch_duration>` | `secs_left` may be ≤ 0 |
| `tn_wait_restart_window [URL] [PROGRESS_FN]` | none | always rc 0; `PROGRESS_FN` is called as `fn step\|log\|warn MSG` |
| `node_stake_status ADDR [URL]` | `<status> <activation> <retired> <exit_epoch>` or `none` | rc 1 `unknown bad-address`; rc 2 `unknown <kind> <detail>`; strict decode (each word zero above its type, bool 0 or 1); a revert is `none` |
| `print_validator_onchain_status ADDR LINE [RETIRED] [CUR_EPOCH]` | report | Exited: "exited at epoch E; unstake() becomes eligible at epoch E+1", plus whether that is now; three-field lines still accepted |
| `check_validator_onchain_status ADDR [URL]` | report | one hint per failure kind: transport, rate limit (HTTP 429), malformed |
| `tn_acquire_update_lock` | none | its mkdir fallback installs an EXIT trap only when `TN_EXIT_TRAP_OWNED` is empty |

`tn_wait_restart_window` policy. Environment: `TN_SKIP_EPOCH_WAIT=1` skips; `TN_EPOCH_MARGIN`
300; `TN_EPOCH_SETTLE` 90; `TN_EPOCH_WAIT_MAX` 1800 (0 disables the wait); `TN_EPOCH_POLL` 15
(clamped 5 to 20 after V-L: each in-loop read gets a max time of 30 − poll so a heartbeat gap
never exceeds 30 s). `tn_epoch_info [URL] [EPOCH] [MAX_TIME]` takes that optional third argument.
Launch-file family after V-L: in wrappers an unquoted `; | & < > ( )` ends a word and a node
line holding one is refused (rc 3); set/inject refuse a VALUE or FLAGS with those characters,
unquoted `* ? [` or a newline; `.service` lines are not shell, so only a standalone `;` is
refused there. `tn_ref_min_check`: empty ref → rc 1; a version at or above the floor with a
suffix other than `-adiri` → rc 2. Status 6 without `isRetired` is `unknown malformed`.
1. Skipped, or the mode is unreadable or not `CvvActive`: log and return.
2. Seconds left unreadable: warn and return. More than the margin: log and return.
3. Otherwise one `step` message, then poll until the epoch id rises, with a `log` heartbeat each
   poll; two failed reads in a row or the cap reached: warn and return.
4. Settle for `TN_EPOCH_SETTLE` seconds with heartbeats, still inside the cap.
Callers wait before stopping or editing anything, and never before a rollback restart.

`lib/fallback.sh` (1.0.3): refresh the stale `tn_isValidator` comments; mark
`tn_resolve_node_type` deprecated with no callers (keep the function one release so a half-updated
operator box never hits "command not found").

## B.3 `lib/common.sh` pass L2 → 1.6.0

| Function | stdout on rc 0 | Notes |
|---|---|---|
| `tn_physical_cores` | `<n> physical` or `<n> logical` | `lscpu --parse=CORE,SOCKET` unique pairs; `/proc/cpuinfo` (physical id, core id) pairs; `sysctl -n hw.physicalcpu`; then the logical count |
| `check_hardware` | none | compares the tiers with that count and says which kind it measured |
| `tn_node_inject_flags FILE MARKER_ERE FLAGS` | none | marker matched as a regex on non-comment lines; rc per the family table (1 = marker already on a live line) |
| `tn_launch_flag_get FILE FLAG` | value (outer quotes removed; empty for a boolean) | 1 absent, 4 unreadable |
| `tn_launch_flag_set FILE FLAG [VALUE]` | none | VALUE copied verbatim; refuses a `.service` file when VALUE contains `$`, `%` or a backtick |
| `tn_launch_flag_unset FILE FLAG` | none | removes every live occurrence with its value |
| `tn_launch_runner [FILE]` | `docker:<image>` or `binary:<path>` | image and path read from the launch file, not `.node-meta` |
| `tn_keytool SPEC DATA_DIR ARGS…` | keytool output | `@DATADIR@` in an argument becomes the data dir as keytool sees it; docker runs as the data-dir owner with `TN_BLS_PASSPHRASE` passed by name |
| `tn_keytool_has SPEC WORD [SUBCMD…]` | none | 0 when `keytool SUBCMD… --help` lists WORD |
| `tn_node_has_flag SPEC FLAG`, `tn_node_parse_check SPEC ARGS…` | none | probe `node --help`; `node ARGS… --help` exits 0 |
| `tn_node_info_field FILE KEY` | value | KEY: name, bls_public_key, execution_address, proof_of_possession, primary_address, primary_port |
| `tn_node_info_worker_ports FILE` | one UDP port per line, worker order | handles `workers:` lists and the legacy `worker:` map |
| `tn_node_info_rpc FILE [IDX=0]` | `<http\|none> <ws\|none>` | |

Also in L2 (from L1's hand-back): in `tn_wait_restart_window`, when the first successful read shows
`secs_left` below `-TN_EPOCH_MARGIN` (the boundary passed long ago and the epoch has not closed),
emit one `warn` ("epoch N should have ended M minutes ago and has not; not waiting") and return —
waiting cannot help a stalled epoch and would hold the operator for `TN_EPOCH_WAIT_MAX`. Keep every
other L1 behaviour. L1 also added public helpers `tn_hex_to_dec`, `tn_wei_to_tel` (pure bash,
256-bit safe), `tn_stake_amount_wei [url] [max_time]` (prints `<wei> <version>`) and
`tn_release_update_lock` (`TN_UPDATE_LOCK_DIR`); reuse them.

Target line rule for inject and set: the first non-comment line with a whole-word `--http` that
belongs to a command containing `node`. Flags go before a trailing `\`, else at the end. Edits are
staged in a temp file and written with `cat > file` only when the result is non-empty, has the
same number of `--http` lines and reads back as intended.

## B.4 Core script specs

`setup-node.sh` (1.3.0), P4a: hard guard. `setup_fail MSG` (error event in JSON mode, then
exit). `init_public_rpc_flags` validates the four URL flags and warns on private hosts; an
invalid `--public-ip` is dropped with a warning. Unknown flags warn on stderr. `tn_ref_min_check`
on `--build-ref` (JSON) and on the picked or typed ref (interactive) before `check_root`.
`--binary-path PATH` for `existing`. Keygen and finalize write `.node-meta` with `meta_set` per
key (foreign keys survive) and `meta_unset NODE_TYPE`; `readonly NODE_TYPE` goes; `DOCKER_IMAGE`
or `BINARY_PATH` is saved at keygen and read back at finalize; docker with no image, or
`existing` with no path, is `setup_fail`. `done` events keep `"node_type":"observer"`; finalize
adds `operator_guide` and `public_rpc`. The summary prints the real P2P ports and the runbook URL.

`setup-node.sh`, P4b: `--bootstrap-peers FILE`, `--enable-state-export`, `--state-export-keep N`
(implies enable, warns). `init_node_extra_flags` validates them (readable regular file at most
64 KiB; N matches `^[1-9][0-9]{0,5}$`). `prepare_node_extra_flags` gates each flag on
`tn_node_has_flag`, checks the peers file with `tn_node_parse_check`, installs it as
`${CONFIG_DIR}/bootstrap-peers.yaml` (0644 root), and builds the flag text in a variable so the
wrapper holds a literal `"$(cat …/bootstrap-peers.yaml)"` that the host expands at each start
(never inline in the heredoc, or it runs during setup). The flags are persisted in `.node-meta`.

`edit-config.sh` (1.3.0): hard guard. `main` pre-scans for `--json`, swaps fds and sets an EXIT
trap that emits `done ok:false` when none was sent; `--set` no longer loops on a missing value;
`--no-epoch-wait`. `edit_epoch_wait` before the restart in the three apply paths, never on
rollback. Metrics uses `tn_launch_flag_set` (it now adds the flag when missing); the dead
`ExecStart`-only flag helpers are deleted. New fields in the menu and `--set`:
`bootstrap_peers=<abs path>|none` (refused on `.service` launch files), `state_export=off|unlimited|N`,
`allow_private_forward_targets=true|false` (true only when the node's genesis chain id is readable
and is not a public chain id; edits `${DATA_DIR}/parameters.yaml` with a backup). JSON rollback
covers the launch file, unit, `parameters.yaml` and the peers file. `refresh_chain_configs` picks
the directory from `.node-meta` `NETWORK` and refuses unless the node's chain id and the source's
are known and equal. Update lock (from P6): every apply path takes the update lock with
`TN_EXIT_TRAP_OWNED=1; tn_acquire_update_lock` before editing anything and releases it from the
script's EXIT trap (`tn_release_update_lock`); when the lock is held by a live update-node run,
refuse with "an update is in progress; try again when it has finished" (error event + done in
JSON mode). Reason: update-node backs up the launch file before its epoch wait, so an edit-config
save made during that wait would be lost on a rollback.

`update-node.sh` (1.2.0): `main` pre-scans for `--json`, swaps fds and installs the EXIT trap
before parsing; `--ref` takes a value only when one follows; unknown arguments go to stderr;
`json_emit` records a `done`; `json_check` marks its single object as final; `--no-epoch-wait`.
`update_epoch_wait` (soft guard) just before the stop in the four apply paths, never on rollback.
No version floor on `--ref`: downgrades are legitimate rollbacks. Lock and trap (from L1): update-node
installs its own EXIT trap, so it must set `TN_EXIT_TRAP_OWNED=1` before calling
`tn_acquire_update_lock` and call `tn_release_update_lock` from that trap (which must also emit the
`done` event when none was sent). `node_is_staked_validator` is unchanged (rc only).

`remove-node.sh` (1.2.9): the three unit maps become indexed arrays parallel to
`INSTALLED_UNITS` with an index lookup; the prune rebuilds all four; safe empty-array expansions.

`migrate-node-naming.sh` (1.2.1): no `local -n`; safe empty-array expansions; `meta_unset
NODE_TYPE`; `tn_resolve_node_type` lines removed; stale `tn_isValidator` text rewritten.

`update-scripts.sh`: `FILES_TO_UPDATE=()` at top level; the unused `declare -g` maps deleted.
`install.sh`: print the runbook URL.

`tools/check-bash32.sh` (maintainer tool): one POSIX awk per file that skips comments and heredoc
bodies and flags `declare|local -A/-g/-n`, case-modification expansions, `mapfile`, `readarray`,
`coproc`, `&>>`, `|&`, `[[ -v`, `wait -n`, negative subscripts, `${v@X}`, `%(…)T`, `;;&`;
`# bash32-ok` suppresses a line. Exit 0 clean, 1 violations, 2 usage. On today's tree it reports
exactly the known hits (listed in `spec-fu-shared.md`); CI runs it under `/bin/bash` in the macOS
job once those are fixed.

## B.5 Tests

Harness for every package: source a copy with `main "$@"` removed, at top level, `lib/` symlinked
beside it, PATH shims first, under `/bin/bash` 3.2 and bash 5; JSON output re-parsed line by line.

- L1: `confirm` under 3.2; `meta_*` round trips and refusals; about 30 URL rows;
  `tn_ref_min_check` matrix; `tn_rpc_call` with a curl shim for each failure kind;
  `node_stake_status` valid, malformed, revert, HTTP 429; unstake wording at and after the exit
  epoch; `tn_wait_restart_window` with a fake clock (skip, RPC down, Observer, far boundary, near
  boundary then rollover, never rolls over), asserting heartbeat gaps of at most 30 s and rc 0;
  live read-only calls against `https://rpc.adiri.tel`.
- L2: launch-file fixtures (both docker wrappers, binary wrapper, legacy one-line unit, commented
  `--http` above the live line, line ending in `\`, trailing comment, quoted `$(cat …)` value);
  every return code; owner and mode kept; `bash -n` on the result; a wrapper run against a
  recording docker shim receives the peers map as one argument; physical-core fixtures; node-info
  fixtures; real keytool runs with the v0.15.0 image (and v0.14.0, v0.11.0 if they pull).
- P3: the lint against one fixture per construct and against the repo; remove-node and migrate
  under 3.2 with empty arrays; `update-scripts.sh check_versions` under `/bin/bash`.
- P4a/P4b: each new flag and each missing value; bad and private URLs; an old `--build-ref` fails
  before `check_root`; foreign `.node-meta` keys survive and `NODE_TYPE` goes; finalize with the
  image only in meta, with none, and with `--binary-path`; the rendered wrapper.
- P5: each new field on a wrapper and on a legacy unit; private-network gate at chain 2017 and at
  a private id; `--set` last; non-root run still ends with `done`; refresh refusals; the wait
  happens before the restart.
- P6: `--ref` last returns within 5 s with `error` then `done`; an unknown argument leaves stdout
  pure JSON; a successful `--check` is exactly one object; the wait precedes `systemctl stop` in
  all four paths and both overrides skip it; with the pre-L1 library, apply warns and proceeds.
