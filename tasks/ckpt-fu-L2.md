status: in-progress (fix pass 5)

# Checkpoint: package L2 (lib/common.sh 1.6.0)

Owned file: `lib/common.sh` (`COMMON_VERSION` 1.6.0). No other repo file was edited. Tests live in
the scratchpad under `l2-tests/` (`t_l2.sh`, `mkfx.sh`, `shims/`, `ni/`, `gen/`).

## Sections

- [x] 1. `tn_physical_cores` and `check_hardware` on that count. New internal `_tn_hw_cpu_text`;
      `_tn_hw_role` takes an optional 8th argument cpu_kind (the old 7-argument call still works and
      words the count as logical). The summary reads "N physical cores" or "N logical CPUs"; a
      logical-only count adds one info line. The lscpu rule matches ui/server.py `physical_cores`
      (a line without a core id is skipped, an empty socket counts as one socket).
- [x] 2. Section "Node launch file: target line and flag edits" after `tn_node_launch_target`: one
      awk parser `_tn_launch_awk` (modes target, get, probe, runner, set, unset, inject; shell-style
      word splitting with quotes, `$(…)`, `${…}` and backticks; unit or shell reading; exit 10-13)
      and bash helpers `_tn_launch_is_unit`, `_tn_launch_flag_ok`, `_tn_launch_http_count`,
      `_tn_launch_live_lines`, `_tn_launch_same_but`, `_tn_launch_staged_ok`, `_tn_launch_write`,
      `_tn_launch_edit`. Public: `tn_node_inject_flags` (rewritten), `tn_launch_flag_get`,
      `tn_launch_flag_set`, `tn_launch_flag_unset`, and `tn_launch_runner` (here because it shares the
      parser). `tn_node_launch_flags` and `tn_node_launch_target` are unchanged.
- [x] 3. Section "Node binary: keytool and probes": `_tn_runner_probe`, `_tn_help_lists`,
      `tn_node_has_flag`, `tn_keytool_has`, `tn_node_parse_check`, `_tn_path_owner`, `tn_keytool`.
- [x] 4. Section "node-info.yaml readers": `_tn_node_info_flat`, `_tn_ni_pick`,
      `_tn_multiaddr_udp_port`, `tn_node_info_field`, `tn_node_info_worker_ports`, `tn_node_info_rpc`.
- [x] 5. `tn_wait_restart_window`: a first read with `secs_left < -TN_EPOCH_MARGIN` gives one warn
      ("Epoch N should have ended 5m 1s ago and has not; not waiting.") and returns 0. Policy
      comment updated; every other L1 behaviour kept.
- [x] 6. Tests (below).
- [x] 7. Closing headings.

## Facts found on the real binaries (2026-10-01)

- Both the v0.15.0 build and the tn-4 build write `p2p_info.workers:` (a list). The single
  `worker:` map is what v0.14.0 and older write (`crates/types/src/primary/info.rs` at the tags);
  the legacy fixture is hand-written from that struct.
- `keytool --datadir X set-rpc` is refused ("the subcommand 'set-rpc' cannot be used with
  '--datadir'"). `--datadir`, `-q` and `--bls-passphrase-source` all work as top-level flags before
  `keytool`, on both builds.
- keytool prints an INFO tracing line on stdout; top-level `-q` drops tracing only, the printed
  result and errors stay. With `-q`, `export-staking-args --calldata` is exactly one line.
- Every keytool subcommand except `set-rpc` wants a passphrase source; `export-staking-args` never
  reads the key, so `--bls-passphrase-source no-passphrase` makes it run with TN_BLS_PASSPHRASE
  unset. `generate pop` with the variable unset fails with keytool's own "passphrase is required"
  and leaves node-info.yaml byte-identical. A wrong passphrase fails pop too.
- set-rpc writes `rpc:` with `http: "<url>"` and `ws: "<url>"` or `ws: ~` under `workers[0]` only;
  `--clear` writes `rpc: ~`. `generate pop` changes `execution_address` and `proof_of_possession`
  and nothing else. Both rewrite node-info.yaml in place: same inode, mode 0640 and group kept.
- `node --bootstrap-peers` takes a map keyed by a real BLS key whose body is the
  `primary`/`workers` shape of node-info (`BootstrapServer`); a fake key is rejected at parse time.
  `--state-export-keep 0` is rejected at parse time (exit 2).
- setup-node.sh's wrapper heredocs are unquoted, so their backslash-newlines are removed: the
  rendered wrapper holds the whole node command on one `exec …` line, with a trailing blank when
  `launch_flags` is empty. Legacy docker units (setup-validator/observer, commit b5f0e33) carry the
  whole command on one `ExecStart=docker run … <image> telcoin node … --http` line.

## Operator-visible changes

- Setup's hardware check counts physical cores where the box reports them (lscpu, /proc/cpuinfo,
  sysctl) and compares the tiers with that. An 8-vCPU cloud VM with 4 physical cores now shows as
  below the validator minimum of 8 cores; it used to pass. The summary says "4 physical cores" or,
  when only the logical count can be read, "8 logical CPUs" plus a line saying so. Hardware checks
  still never block setup.
- Adding health, log, metrics or WebSocket flags after setup (setup-observability.sh,
  install-caddy.sh rpc-enable) no longer writes into a commented-out line, no longer puts flags
  after a trailing backslash, and leaves a launch line that ends in a `#` comment alone (the caller
  reports that the flags were not added). A `# --metrics` comment no longer counts as the flag
  being present.
- Before a restart, a committee node whose epoch should have ended more than `TN_EPOCH_MARGIN`
  seconds ago (stalled, or the node far behind) is no longer held for up to `TN_EPOCH_WAIT_MAX`; one
  warning, then the restart goes ahead.
- Everything else is new helpers that callers have not wired yet.

## Changelog text

### lib/common v1.6.0 — launch-file edits, keytool runner, node-info readers, physical cores
`check_hardware` compares the hardware tiers with physical cores. The new `tn_physical_cores`
counts them from `lscpu`, `/proc/cpuinfo` or `sysctl hw.physicalcpu` and falls back to the logical
count, and the report says which one it measured ("4 physical cores", "8 logical CPUs"), since a
cloud vCPU is usually a hyperthread.

`tn_node_inject_flags` now edits only the live node command: it skips comment lines (`;` lines
too in a unit), puts flags before a trailing backslash instead of after it, and refuses a line
that ends in a comment. The edit is staged and written back only when the staged copy has the
same `--http` lines, reads back as intended and, for a start wrapper, still passes `bash -n`;
owner and mode are kept. Its return code now says why nothing changed: 1 already there, 2 no node
launch line, 3 refused, 4 I/O error. `tn_launch_flag_get`, `tn_launch_flag_set` and
`tn_launch_flag_unset` read and edit one flag of the node command by the same rules, quoted values
such as `"$(cat /etc/telcoin/bootstrap-peers.yaml)"` included; `set` refuses `$`, `%` and backticks
in a systemd unit, where systemd would expand them.

`tn_launch_runner` reads the docker image or binary path from the launch file, and `tn_keytool`
runs keytool through it: in docker as the owner of the data dir, with the BLS passphrase passed by
environment only, and with `-q` so a `$(…)` capture gets only the result.
`tn_keytool_has`, `tn_node_has_flag` and `tn_node_parse_check` ask the installed release what it
supports instead of comparing version numbers. `tn_node_info_field`, `tn_node_info_worker_ports`
and `tn_node_info_rpc` read node-info.yaml in both the v0.15.0 `workers:` shape and the older
`worker:` shape, without python3.

`tn_wait_restart_window` no longer waits when the epoch boundary passed more than
`TN_EPOCH_MARGIN` seconds ago and the epoch is still open: it warns once and lets the restart go
ahead.

## Tests run

Harness `<scratchpad>/l2-tests/t_l2.sh`: sources `lib/common.sh` at top level, errexit off,
nounset and pipefail on. Launch fixtures come from `mkfx.sh`, which renders the four wrappers by
evaluating setup-node.sh's own `cat > "$wrapper" <<EOF` blocks, plus hand-written ones (legacy
one-line docker and binary units, a unit with a comment inside a continuation and the shell
equivalent, a commented `--http` command above the live one, a target line ending in `\`, one
ending in `# comment`, a multi-line docker wrapper carrying `--bootstrap-peers "$(cat …)"` and
state export, a `--http` command with no `node`). docker is a recording PATH shim (argc, one file
per argument, the TN_BLS_PASSPHRASE it saw); hardware tools are PATH shims plus
`TN_PROC_CPUINFO`/`TN_PROC_MEMINFO` fixtures.

- `/bin/bash t_l2.sh` (3.2.57): 498 passed, 0 failed. `bash t_l2.sh` (5.3.15): 498 passed, 0 failed.
- Same harness with `awk` resolved to mawk 1.3.4-20200120 (the Ubuntu 20.04/22.04 awk, built from
  source in `<scratchpad>/mawk-src`, nothing installed system-wide): 498/498 under both bashes.
- Coverage: physical cores from lscpu (hyperthreaded, two sockets, empty socket, a line without a
  core, no core ids, failing), cpuinfo (x86 HT, one core per socket, ARM fall-through), sysctl,
  nproc, getconf, nothing (rc 1), the real macOS value; check_hardware summary, gaps, wording,
  singular, unknown, plain ASCII, the old one-argument call; `_tn_hw_role` old and new arity.
  Inject on all four rendered wrappers (rc 0 then 1, only the target line changed, exactly old line
  plus flags, `bash -n` under both bashes), commented line above, marker only in a comment,
  continued line, end-anchored marker on a continued line (3), trailing comment (3), no node (2),
  shell comment inside a continuation (2), unit comment inside a continuation (0), legacy unit,
  `$`/`%`/backtick in a unit (3), empty flags or marker, newline, unbalanced quote, `#` word,
  invalid regex, flags without the marker (3), missing file (4), read-only file (4, and 1 when
  nothing is needed), failing mktemp (4), failing write check (4 with the old bytes restored), the
  file byte-identical after every non-zero rc. Owner, group and mode kept (0750, group staff,
  checked with `stat -f '%Sp %Su %Sg'`) for inject, set and unset. Current callers: install-caddy's
  own `caddy_launch_inject_target`, `caddy_launch_verify_inject` and `caddy_launch_has_flag`, run
  unchanged around the new helper on six launch files (verdict ok, verify passes, second call 1);
  obs log and metrics flags and `--healthcheck` on wrappers and the legacy unit. get: quoted
  value unquoted, plain, boolean, absent, a docker flag before `node` not read, `FLAG=VALUE`,
  single quotes, trailing-comment line readable, `;` line ignored, every rc. set: no-op cases (1,
  file untouched), replace in place, replace on its own line, boolean to value and back, add at the
  end and before a backslash, duplicates collapsed, every refusal, unit rules, read-only, owner and
  mode. unset: own line dropped, value at end, boolean, `--http` refused, last line of a continued
  command (previous backslash removed), every occurrence, trailing comment (3), unit next to a `;`
  line holding the same flag, every rc. Every family member under `set -euo pipefail`.
- Wrapper runs: both docker wrappers, after `tn_launch_flag_set … --bootstrap-peers "$(cat <file>)"`,
  run under `/bin/bash` and bash against the recording docker shim: one docker call, the peers map
  (multi-line, spaces, `$HOME`, backticks, a glob, quotes) arrives as ONE argument byte for byte,
  the passphrase reaches docker by environment and is in no argument. The binary wrapper, pointed
  at a recording binary: exact argv, 14 arguments, the map as one.
- tn_launch_runner: both docker wrappers, the multi-line one, both binary wrappers, legacy docker
  unit (`ExecStart=docker`), legacy binary unit, bare name found and not found on PATH, `node` as
  the command itself (Node.js, rc 1), docker with no image, a quoted image by digest, the default
  file through `tn_node_launch_target`, no node service (2), missing file (4).
- Real binaries: `tn_node_has_flag` `--bootstrap-peers` 0 on v0.15.0 and 1 on the tn-4 build;
  `--state-export-keep` 0/1; `--enable-state-export` 0/0; `--observer` 1 on v0.15.0, 0 on tn-4;
  missing binary, malformed and relative specs 4. `tn_keytool_has`: set-rpc, `generate validator
  --rpc-http`, `generate pop`, `set-rpc --clear`, `export-staking-args --calldata` 0; `set-rpc
  --worker-id` 1 on both builds; unknown subcommand 1. `tn_node_parse_check` on v0.15.0:
  `--bootstrap-peers '{}'` 0, `'not: [valid'` 1 with the clap `error:` line, a real peers map built
  from the generated node-info 0, a map with a fake key 1, `--state-export-keep 3` 0 and `0` 1; on
  tn-4 the flag is rejected (1, "unexpected argument"); missing binary 4. Help parsing only counts
  definition lines (a flag mentioned in prose or a wrapped description is not listed). Probes
  through the docker shim: argv `run --rm <image> telcoin node --help`, the parse-check map as one
  argument, docker failing (125) gives 4.
- `tn_keytool` with `binary:<v0.15.0>` on a generated data dir: `set-rpc --http
  https://x.example.org/ --ws wss://x.example.org/` then read back with `tn_node_info_rpc`, then
  `--clear` (none none), then http only; `export-staking-args --node-info @DATADIR@/node-info.yaml
  --calldata` with TN_BLS_PASSPHRASE unset, empty and set: one line starting `0x2fb0d025`, the same
  calldata each time; `--json` is one JSON document; `generate pop --address 0x…01` without the
  passphrase fails with keytool's message and leaves node-info.yaml byte-identical; with it, the
  execution address becomes 0x…01, the BLS key is unchanged and the proof of possession changes;
  a wrong passphrase fails. The tn-4 build: set-rpc and calldata the same way. Caller `--datadir`
  and `-q` are not doubled. Recording binary argv: `-q --datadir <dd> [--bls-passphrase-source
  no-passphrase] keytool …`, the source only for export-staking-args with the variable unset,
  never for pop, a caller's own source kept, every `@DATADIR@` in an argument replaced, `&` in the
  data dir kept literal, keytool's rc passed through. Recording docker shim: `run --rm --user
  <uid>:<gid of the data dir> -e HOME=/home/nonroot [-e TN_BLS_PASSPHRASE] -v <dd>:/home/nonroot
  <image> telcoin -q --datadir /home/nonroot [--bls-passphrase-source no-passphrase] keytool …`
  with `/home/nonroot` substituted for `@DATADIR@`; `-e TN_BLS_PASSPHRASE` only when the variable
  is set and never with a value; the shim sees the value in its environment; no
  `--bls-passphrase-source` for pop; a missing data dir is 4 and docker is not called.
- node-info: real files from both builds (all six fields, one worker port, `none none`, no worker
  1), the hand-written legacy `worker:` map (port, rpc with `ws: ~`), odd indentation (4 spaces,
  list at its key's indent), single and double quotes, trailing comments, `null`, two and three
  workers in order, a worker without a UDP port (rc 1), flow-style rpc (rc 1), tab indentation
  (rc 1), IPv6 primary, port out of range, unknown key, missing file (4), index `01` and `x`.
- tn_wait_restart_window with a fake clock: -301 s → one warn "should have ended 5m 1s ago", rc 0,
  no time; -7260 s → "2h 1m"; exactly -300 s and -40 s still wait and settle (t=120); margin 0 makes
  any passed boundary stalled; a larger margin keeps waiting; skip and non-committee paths
  unchanged; under `set -e`.
- `/bin/bash -n lib/common.sh` and `bash -n lib/common.sh`: clean.
- `shellcheck -x --severity=error lib/common.sh`: clean. At warning level 13 findings before and
  after, the same messages.
- Grep over the added lines: no bash-4 construct, no apostrophe in a `${var:-…}` word, no
  `local x="$(…)"`, no gawk-only awk, no line-number references, no `readonly` arrays.
- Name sweep over `*.sh`, `*.py`, `*.env`, `*.html`, `*.js`: every new function and environment
  name appears only in lib/common.sh, except `tn_physical_cores`, which ui/server.py names in the
  docstring of its mirror; the library and the UI give the same count on four lscpu fixtures.
- L1's harness `l1-tests/t_l1.sh --no-live`: 426 passed, 1 failed under both bashes; the failure is
  its pinned `COMMON_VERSION == 1.5.0`. A copy with only that pin changed
  (`l1-tests/t_l1.as-1.6.0.sh`) passes 427/427 under both bashes, with macOS awk and with mawk.
- `/bin/bash <script> --help` for check-node, setup-observability, install-caddy, update-node,
  edit-config and firewall-setup: same rc and same output with this library as with HEAD's.

## Open issues

1. Release bookkeeping (orchestrator): `lib/common.sh.sha256` is stale until
   `tools/gen-checksums.sh` runs; README changelog entry above; `update-scripts.sh` bump in the
   release commit. V-L should run `l1-tests/t_l1.as-1.6.0.sh` (or move L1's version pin) together
   with `l2-tests/t_l2.sh`.
2. install-caddy.sh (C.1, 1.4.0):
   - `caddy_ws_preflight`: delete `caddy_launch_inject_target` and `caddy_launch_verify_inject` and
     call, after the `cp -p "$file" "${file}.tn-bak"` backup,
     `rc=0; tn_node_inject_flags "$file" '(^|[[:space:]])--ws([[:space:]]|$)' "$flags" || rc=$?`;
     accept rc 0 only when `tn_launch_flag_get "$file" --ws` then returns 0 (the helper has already
     checked `bash -n` and the read-back); rc 1 means `--ws` is already on a live line; rc 2 "no
     node launch line"; rc 3 "the launch line ends in a comment or cannot be parsed, add the flags
     by hand"; rc 4 "could not write"; restore the backup on anything but 0. A whole-word marker
     lets the flags go before a trailing backslash, which the current `"${flags}$"` marker refuses
     (rc 3). Keep a soft guard on `declare -F tn_launch_flag_get` with today's code as the
     fallback. Note: the private rule reads a unit's `;` line as live and the shared one does not,
     so on such a unit the old verifier fails and restores; dropping the private copy ends that.
   - `caddy_node_info_write`: `spec="$(tn_launch_runner)"` then
     `tn_keytool "$spec" "$DATA_DIR" set-rpc --http "$http" [--ws "$ws"]` or `set-rpc --clear`;
     read back with `tn_node_info_rpc "${DATA_DIR}/node-info.yaml"` and compare with
     `"<http> <ws|none>"`. keytool rewrites node-info.yaml in place (same inode, mode and group,
     checked for set-rpc and pop), so the owner-and-mode restore in the spec is only a safety net.
     Python editor as the fallback when `declare -F tn_keytool` fails or the runner cannot be read.
   - `caddy_node_info_advertise`: read the current value with `tn_node_info_rpc` instead of the
     python `get` mode.
3. lib/observability.sh (1.0.2), `obs_ensure_reth_flags`: its pre-checks
   `grep -q -- '--log.file.format json' "$file"` and `grep -q -- '--metrics' "$file"` also match
   comment lines, so a `# --metrics` comment makes it report "already serves a metrics endpoint"
   and skip. Use `[[ "$(tn_launch_flag_get "$file" --log.file.format)" == json ]]` and
   `tn_launch_flag_get "$file" --metrics >/dev/null` behind `declare -F tn_launch_flag_get`, and
   word the inject failure by rc (2 no launch line, 3 line not editable: add by hand, 4 could not
   write) instead of always "Could not find the node launch line".
4. setup-observability.sh (1.2.1), both `tn_node_inject_flags "$file" "--healthcheck" …` call
   sites: the else branch says "already has --healthcheck (or the launch line was not found)"; split
   it by rc: 1 already present, 2 no node launch line in FILE, 3 the launch line cannot be edited
   automatically (add `--healthcheck PORT` by hand), 4 could not write FILE.
5. setup-node.sh (P4a/P4b, 1.3.0):
   - Hard guard on 1.6.0 as in spec B.1.
   - `keytool_supports_rpc_args` becomes `tn_keytool_has "$spec" --rpc-http generate validator`
     with `spec="docker:${DOCKER_IMAGE}"` or `"binary:${BINARY_PATH}"`.
   - `prepare_node_extra_flags`: gate each flag on `tn_node_has_flag "$spec" <flag>`; check the
     peers file with `msg="$(tn_node_parse_check "$spec" --bootstrap-peers "$(cat "$file")")" || rc=$?`
     (1: show `$msg` and fail; 4: could not check). The map must be keyed by BLS keys with the
     node-info `primary`/`workers` body; `--state-export-keep 0` is rejected by clap.
   - The wrapper heredoc joins backslash-continued lines into one `exec …` line. Rather than
     building the quoted `"$(cat …)"` text inside the heredoc, write the wrapper as today and then
     `tn_launch_flag_set "$wrapper" --bootstrap-peers "\"\$(cat ${CONFIG_DIR}/bootstrap-peers.yaml)\""`,
     `tn_launch_flag_set "$wrapper" --enable-state-export` and
     `tn_launch_flag_set "$wrapper" --state-export-keep "$n"` (rc 0 or 1 is success); the helper
     validates the value and runs the `bash -n` check.
   - Summary P2P ports: `tn_node_info_field "${DATA_DIR}/node-info.yaml" primary_port` and
     `tn_node_info_worker_ports "${DATA_DIR}/node-info.yaml"`.
   - `TN_HW_SUMMARY` now reads "N physical cores" or "N logical CPUs" (was "N CPUs"); anything that
     parses it should not rely on the old word.
   - Optional: keygen through `tn_keytool` would drop keytool's INFO lines (`-q`) and needs the data
     dir to exist first on docker.
6. firewall-setup.sh (C.3, 1.6.0), `fw_p2p_ports`: other workers from
   `tn_node_info_worker_ports "${DATA_DIR}/node-info.yaml"` (line N+1 is worker N), the primary
   fallback from `tn_node_info_field FILE primary_port`; rc 1 means node-info could not give the
   ports, so keep the constants. The two `tn_resolve_node_type` calls listed in L1's open issues
   are still there.
7. check-node.sh (B, 1.2.0): can show the runner (`tn_launch_runner`), the bootstrap peers and
   state export state (`tn_launch_flag_get "$file" --bootstrap-peers`, `--enable-state-export`,
   `--state-export-keep`), the advertised RPC (`tn_node_info_rpc`) and the P2P ports from the
   node-info readers. L1's open item about `print_validator_onchain_status … "$CURRENT_EPOCH"` stands.
8. edit-config.sh (P5, 1.3.0): metrics `tn_launch_flag_set "$file" --metrics "$addr"` (adds it when
   missing) and `tn_launch_flag_unset "$file" --metrics`; `bootstrap_peers=<path>` via
   `tn_launch_flag_set "$file" --bootstrap-peers "\"\$(cat ${CONFIG_DIR}/bootstrap-peers.yaml)\""`
   (rc 3 on a `.service` launch file, which is the refusal the spec wants), `none` via unset;
   `state_export=off` unsets `--enable-state-export` and `--state-export-keep`, `unlimited` sets the
   first and unsets the second, `N` sets both; gate each on
   `tn_node_has_flag "$(tn_launch_runner "$file")" <flag>`. rc 1 from set or unset means "already
   so", not failure.
9. Interface notes beyond the spec table: `tn_launch_flag_get` also returns 2 (no node line) and 3
   (bad flag name or a command the parser cannot read) and reads the first occurrence;
   `tn_launch_runner` returns 1 not recognised, 2 no node line or service, 3 unparsable, 4
   unreadable; the probes return 4 when the probe cannot run; `tn_keytool` returns 4 when it cannot
   start and otherwise keytool's (or docker's) own rc; the node-info readers return 4 for a missing
   file; `primary_address` is the whole primary multiaddr as written, not the IP.
10. Behaviour to know: `tn_keytool`'s `-q` also hides keytool's WARN lines (errors stay on stderr).
    `set` and `inject` append after a trailing blank on setup-node's one-line wrappers, giving
    `127.0.0.1  --metrics …` with two spaces; kept because install-caddy's verifier expects exactly
    the old line plus one space plus the flags. Heredocs inside a wrapper are not parsed as heredocs.

## Fix pass (from tasks/ckpt-fu-V-L.md; COMMON_VERSION stays 1.6.0, FALLBACK_VERSION 1.0.3)

Starting point: lib/common.sh and lib/fallback.sh as committed in d1593ae (clean tree).

- [x] F1. Tokenizer ends a word on unquoted `; | & < > ( )` and marks the line bad; set/inject
      refuse (rc 3, "not a single shell word") unquoted `; | & < > ( ) * ? [` or a newline
- [x] F2. tn_wait_restart_window: poll clamped 5-20, in-loop epoch read max time 30 - poll
- [x] F3. tn_json_field: escaped quotes inside strings, `\"` and `\\` unescaped
- [x] F4. display_node_info Step 4: `-q --bls-passphrase-source no-passphrase` before `keytool`
- [x] F5. lib/fallback.sh: tn_resolve_node_type comment names firewall-setup.sh as the caller
- [x] F6. node_stake_status comment: words 5-6 are stakeVersion and region (tn-contracts 10cc12b7)
- [x] F7. Status 6: retired tombstone kept; 6 with isRetired 0 → `unknown malformed status-6-not-retired`
- [x] F8. tn_rpc_call: `--url`, no trailing space on `rpc-error 3`, HTTP 503 wording
- [x] F9. tn_ref_min_check: pre-release of a release → rc 2; empty ref → rc 1; unknown network rc 0
- [x] F10. tn_keytool: hoist `--datadir X` from ARGS; empty TN_BLS_PASSPHRASE treated as unset
- [x] F11. _tn_hw_role keeps "could not check CPU"; TN_EPOCH_WAIT_MAX=0 disables the wait;
      tn_genesis_chain_id reads one-line JSON
- [x] F12. Harnesses: t_l2.sh (no install-caddy helpers), L1 copy, V-L parts, under both bashes;
      bash -n, shellcheck error, tools/check-bash32.sh

### Fix pass results

Changes (lib/common.sh stays 1.6.0, lib/fallback.sh 1.0.3):
- F1: the launch parser ends a word on an unquoted `; | & < > ( )` or line break and refuses
  (rc 3) to read or edit a node command holding one; operators on other lines (the TPM block)
  are fine. A new VALUE (set) or FLAGS (inject) holding one of those or an unquoted `* ? [` is
  refused with rc 3 and a stderr line saying it is not a single shell word; quoted forms such
  as `"$(cat …)"`, `"a;b"`, `'*'` stay accepted. In a `.service` file no shell reads the line,
  so those characters stay part of a word (an old unit with `TN_BLS_PASSPHRASE=a&b` inline stays
  editable) and only a `;` standing alone as a word (systemd's command separator) is refused.
- F2: TN_EPOCH_POLL clamped 5-20; the in-loop epoch read gets max time 30 - poll
  (`tn_epoch_info` takes an optional third argument, max_time).
- F3: `tn_json_field` reads escaped quotes and unescapes `\"` and `\\`; other escapes are kept.
- F4: Step 4 prints `<bin> -q --bls-passphrase-source no-passphrase keytool export-staking-args`
  (docker: `… telcoin -q --bls-passphrase-source no-passphrase keytool …`); the printed binary
  command was run on both builds with TN_BLS_PASSPHRASE unset: one calldata line.
- F5: fallback comment names firewall-setup.sh as the remaining caller until firewall-setup 1.6.0.
- F6: words 5-6 are stakeVersion and region (uint8), checked in tn-contracts 10cc12b7
  (IConsensusRegistry.ValidatorInfo) as pinned by v0.15.0-adiri.
- F7: `6 … 1 …` (`_retire` writes Any plus isRetired) still decodes and reports Retired;
  status 6 with isRetired 0 is `unknown malformed status-6-not-retired`, rc 2.
- F8: curl gets `--url "$url"`; `rpc-error <code>` has no trailing space without a message;
  HTTP 502/503/504 say "The RPC endpoint is unavailable (HTTP 503); try again in a minute."
- F9: empty ref → rc 1 "empty ref: …" on every network; X.Y.Z at or above the floor with a
  suffix other than the network's (`-adiri`) → rc 2 "not a release tag"; X.Y.Z below the floor
  stays rc 1 whatever the suffix (so `v0.12.0-rc1`, `v0.3.2-adiri-patch` stay refused); an
  unknown or empty network with a non-empty ref → rc 0.
- F10: `--datadir X` / `--datadir=X` anywhere in ARGS moves before `keytool` (`@DATADIR@`
  substituted; a bare trailing `--datadir` is rc 4); an empty TN_BLS_PASSPHRASE is treated as
  unset (no `-e`, keytool runs without the variable, export-staking-args gets no-passphrase).
- F11: `_tn_hw_role` keeps the "could not check CPU" line under a RAM or disk shortfall;
  TN_EPOCH_WAIT_MAX=0 logs "epoch wait disabled by TN_EPOCH_WAIT_MAX=0" and returns before any
  read; `tn_genesis_chain_id` finds the key anywhere on a non-comment line (one-line JSON).

Tests:
- `l2-tests/t_l2.sh`: 703/703 under /bin/bash 3.2.57 and bash 5.3.15, and again with mawk
  1.3.4-20200120 as awk. The install-caddy block now follows install-caddy 1.4.0 (whole-word
  `--ws` marker, `tn_launch_flag_get --ws` read-back, `bash -n`) instead of eval'ing the deleted
  helpers. New rows: V-L's exact metacharacter rows (`x>/p/victim`, `a;b`, `a|b`, `a&b`, `a<b`,
  `a>b`, `(a)`, `a)b`, `*`, plus `a?`, `[ab]`, CR, LF, space) refused with the message and the
  file untouched; quoted forms accepted; `--z 1&` inject refused; V-L's victim demo (the file
  survives a wrapper run); pipe, &&, trailing & and redirection node commands refused for
  get/set/unset/inject/runner; units with `& ; > ( ) |` inside a word editable, a `;` word
  refused; keytool hoisting and empty passphrase (binary and docker shims); poll clamps and the
  30 - poll read bound with a file clock where every read takes its full max time (largest
  heartbeat gap 30 s for TN_EPOCH_POLL 1, 5, 15, 20, 25, 60); TN_EPOCH_WAIT_MAX=0; JSON
  escapes; `rpc-error 3`; a `-o…` URL with real curl (transport failure, no file written); 503
  wording; status 6 both ways; the ref matrix; genesis forms and both real genesis files;
  Step 4 text and its real run; the two comments.
- `l1-tests/t_l1.as-1.6.0.sh --no-live`: 427/427 under both bashes after updating three rows for
  the changed rules (empty ref rc 2 → 1 with "empty ref"; "poll clamped to 30" → 20).
- V-L (`vl-tests/`, parts t_l1a t_l1b t_l1c t_l1d t_l2a t_l2b t_sete): 1175/1175 under both
  bashes with VL_SETE 1 and 0, EXIT-CHECK reached in every part; t_l2a and t_l2b also pass with
  mawk. t_live passes against rpc.adiri.tel (epoch 581; it hit one transport timeout first that
  plain curl showed too). Rows changed (originals kept as `*.pre-fixpass`):
  t_l1a `rrow 2 "" testnet` → 1 (F9); t_l1a `rrow 0 v0.13.0-rc1 testnet` → 2 (F9);
  t_l1b "json escaped quote" `x\"y` → `x"y` (F3); t_l1c "poll clamp 30" → 20 (F2);
  t_l1d is_staked row `6:1` → `6:2` (F7: status 6 with isRetired 0 is unknown);
  t_l2a "set value ; (one word in parser)" 0 → "set value ; refused" 3 (F1);
  t_l2b "dk caller datadir/-q kept" argv now `telcoin --datadir /elsewhere keytool -q …` (F10);
  t_l2b kt4/kt5 "rpc after set" and "rpc http only" expect the trailing slash keytool writes
  (V-L's own expectation error, its finding 13, not a rule change).
- `bash -n` on both files under both bashes; `shellcheck -x --severity=error` clean; warning
  level 14 findings before and after, identical; `tools/check-bash32.sh` clean on both files and
  on all 25 tracked scripts.

Open:
- spec-fu-core.md B.2 still says TN_EPOCH_POLL is clamped 5 to 30 and B.3 does not list
  `tn_epoch_info`'s new max_time argument (spec files are not mine).
- Sidecars: `lib/common.sh.sha256` and `lib/fallback.sh.sha256` are stale until
  `tools/gen-checksums.sh` runs.

## Fix pass 2 (tn_node_parse_check message; COMMON_VERSION stays 1.6.0)

- [x] G1. On failure print clap's message as ONE line: the quoted value after `invalid value`
      replaced by `'…'` (the value may span lines), then the reason lines (after the first,
      trimmed, up to the Usage / For more information footer) joined with `; `; rc unchanged;
      other clap error shapes pass through squashed to one line
- [x] G2. Harness rows on the v0.15.0 build (bad YAML, fake BLS key map, a non-YAML secret file,
      `{}`), t_l2.sh under both bashes, bash -n, shellcheck error, lint
- [x] G3. Read-only check of setup-node.sh and edit-config.sh: do they print the library message
      as-is for a rejected map, and can their workarounds go

### Fix pass 2 results

- New `_tn_parse_check_message` (awk over clap's output; the probe's ARGS reach awk through
  exported variables in a subshell, never an argument list). `tn_node_parse_check` prints its
  one line on rc 1; rc 0 and rc 4 unchanged. On the real binary clap's reason sits on the same
  line as the closing `' for '<arg>':`, which for a multi-line map is the map's last line, and
  serde's reason quotes the rejected input (`string "secret-line-1"`), so besides cutting the
  value (matched exactly against ARGS, the longest match winning; when it cannot be found, cut
  up to the last `' for '-`) every double-quoted string in the reason becomes `"…"` and a
  backquoted word found in ARGS becomes `` `…` ``. Other shapes pass through squashed (lines
  trimmed, joined with `; `, footer dropped); no `error:` line → `rejected (exit N)`.
- Outputs on the v0.15.0 build:
  - `'not: [valid'` → `error: invalid value '…' for '--bootstrap-peers <MAP>': while parsing a
    flow sequence, expected ',' or ']' at line 2 column 1`
  - multi-line map with a fake BLS key → `error: invalid value '…' for '--bootstrap-peers <MAP>':
    invalid value: string "…", expected valid bls public key bytes at line 1 column 1`
  - file `secret-line-1` → `error: invalid value '…' for '--bootstrap-peers <MAP>': invalid type:
    string "…", expected a map at line 1 column 1`
  - `'{}'` → rc 0, no output
- Tests: t_l2.sh 741/741 under /bin/bash 3.2.57 and bash 5.3.15, and with mawk; L1 copy
  427/427; V-L 1175/1175 (both bashes, VL_SETE 1 and 0); bash -n, shellcheck error level and
  tools/check-bash32.sh (both files, all 25 tracked scripts) clean.
- Callers (read-only, run from scratch copies with the real binary):
  - setup-node.sh does not print the library message: on rc 1 `install_bootstrap_peers` calls
    `bootstrap_peers_reason`, which runs the binary a second time (outside `_tn_runner_probe`)
    and prints its raw reason first (`${reason:-$msg}`), unredacted: "...: invalid type: string
    "secret-line-1", expected a map at line 1 column 1". It can go: use `$msg`, or `$msg` with
    the clap prefix stripped, which also drops the second probe.
  - edit-config.sh prints the library message as-is, "(error: invalid value '…' for ...)",
    then its shape hint. The hint is no longer needed to recover the reason; it still helps
    for the cryptic "data did not match any variant of untagged enum PrimaryWorkersRepr".
- Open: the probe hands the map to the node binary as an argument, which any local user can
  read from the process list while it runs; the library cannot avoid that (the binary only
  takes the map inline). edit-config (and the UI) could refuse a source file that is not
  world-readable, since it is installed 0644 anyway.

## Fix pass 3 (update lock held by orphans; COMMON_VERSION stays 1.6.0)

- [x] H1. tn_acquire_update_lock records the kind it took (flock or mkdir); tn_release_update_lock
      runs `flock -u 9` and closes fd 9 for the flock kind, keeps the mkdir removal otherwise
- [x] H2. tn_wait_restart_window's own sleeps run with `9>&-`
- [x] H3. Harness row: hold the lock, child sleeps 30 s, SIGTERM the parent, a second acquire
      succeeds at once; t_l2.sh and the L1 copy under both bashes; bash -n, shellcheck, lint

### Fix pass 3 results

- `tn_acquire_update_lock` sets `TN_UPDATE_LOCK_KIND` (flock or mkdir; "" when not held). On the
  flock path, when TN_EXIT_TRAP_OWNED is empty, it now sets `trap tn_release_update_lock EXIT`
  as the mkdir path already set its own cleanup trap (every current caller sets
  TN_EXIT_TRAP_OWNED=1, so none changes). `tn_release_update_lock` runs `flock -u 9` and
  `exec 9>&-` for the flock kind; the mkdir removal is unchanged. Both sleeps in
  `tn_wait_restart_window` run with `9>&-`. Header comments now describe the orphan case.
- Harness rows (python fcntl flock shim at `l2-tests/shims/flock/flock`, which also handles
  `-u`; a holder takes the lock with its own EXIT trap, a child sleeps, the holder is SIGTERMed,
  then a second process acquires; printed as "<holder rc> <child alive> <child has fd 9>
  <second acquire rc>"):
  - lib/common.sh at 2c423dc, plain `sleep 30` child: `143 yes 1 1` (refused: "Another update is
    already running (PID <dead holder>)")
  - this library, same: `143 yes 1 0` (the orphan still holds fd 9; the lock is free)
  - this library, holder inside tn_wait_restart_window's sleep: `143 yes 0 0`
  - one process: `0 flock fd9-open other-while-held=1 kind=[] fd9-closed other-after-release=0
    second-release-ok`; without TN_EXIT_TRAP_OWNED the trap is `trap -- 'tn_release_update_lock'
    EXIT`; mkdir path `0 mkdir dir removed kind=[]`
- Counts: t_l2.sh 747/747 under /bin/bash 3.2.57 and bash 5.3.15 (and with mawk); L1 copy
  427/427 under both; V-L 1175/1175 (both bashes, VL_SETE 1 and 0); bash -n clean; shellcheck
  error level clean; tools/check-bash32.sh clean on both files and all 26 tracked scripts.
- Optional caller cleanup (not edited): edit-config's `edit_unlock` closes fd 9 itself after
  `tn_release_update_lock`, which now does that, and could read TN_UPDATE_LOCK_KIND instead of
  inferring flock from an empty TN_UPDATE_LOCK_DIR.

## Fix pass 4 (CRLF .node-meta, ufw under pipefail; versions stay 1.6.0 / 1.0.3)

- [x] J1. meta_get (common) and _tn_meta_get (fallback) strip one trailing CR from the value;
      meta_set / meta_unset match a key on a CRLF line (replace, never duplicate)
- [x] J2. ufw_active / ufw_has_allow capture `ufw status` first, then grep the variable
- [x] J3. Harness rows (CRLF round trip; a chunked ufw shim that would die of SIGPIPE), t_l2.sh
      and the L1 copy under both bashes, bash -n, shellcheck error, check-bash32 on both files

### Fix pass 4 results

- `meta_get` (common) and `_tn_meta_get` (fallback) read the first KEY= line with `grep -m1`
  (no pipe to head) and drop one trailing CR. `meta_set` and `meta_unset` rewrite through the new
  `_tn_meta_rewrite` (awk: drops the KEY= lines, CRLF ones included, and the trailing CR of every
  other line; the key matched as a literal prefix), so a CRLF file is replaced in place, never
  duplicated, and comes out with LF endings. An unreadable file now makes meta_set return 1
  untouched (the old `grep -v … || true` would have rewritten it with only the new key).
  `ufw_active` and `ufw_has_allow` capture `ufw status` first (`|| return 1`) and grep the
  variable through a here-string.
- Rows: CRLF file → meta_get `testnet`, `x=y` kept, `_tn_meta_get` `/data/tn`, only one trailing
  CR dropped; 2c423dc's meta_get returned `testnet\r`; meta_set replaces (one NETWORK= line, value
  devnet, other keys kept, no CR left, mode 600), adds a new key without duplicates; meta_unset
  removes the CRLF line, keeps the rest, leaves no CR; an absent key leaves the file byte-identical;
  an unreadable file → rc 1 and unchanged; tn_resolve_data_dir honours a CRLF DATA_DIR (2c423dc
  fell back to /var/lib/telcoin); meta_get through node_meta_path. ufw: a chunked shim (status
  and first rules, then 4 chunks 0.1 s apart, SIGPIPE logged): the old piped checks return 141
  with SIGPIPE logged (active ufw read as inactive, 22/tcp missed); the new ones return 0 for
  active, 22/tcp and 49594/udp (last chunk), 1 for an absent port, with no SIGPIPE; inactive and a
  failing `ufw status` give 1; set -e safe.
- Counts: t_l2.sh 781/781 under /bin/bash 3.2.57 and bash 5.3.15 (and with mawk); L1 copy 427/427
  under both; V-L 1175/1175 (both bashes, VL_SETE 1 and 0); bash -n clean; shellcheck error level
  clean; tools/check-bash32.sh clean on both files and all 26 tracked scripts.
- Same hazard, not changed: `check_ports` runs `ss … | grep -qE` under pipefail, so a busy port
  can read as free when ss is cut off by SIGPIPE.

## Fix pass 5 (code review; versions stay 1.6.0 / 1.0.3)

- [ ] K1. Every sleep in tn_wait_restart_window (poll and settle) runs as `sleep N 9>&- &` + `wait`,
      so a caller's TERM/INT/HUP trap fires at once; a wait cut short by a trap kills the sleep and
      the function returns 0 instead of looping
- [ ] K2. lib/fallback.sh: tn_resolve_node_type comment says no callers remain (stub kept one
      release; delete it in the release after this one)
- [ ] K3. Harness: SIGTERM a caller with a TERM trap during the wait, trap within 1 s under both
      bashes (and a trap that returns: no stray sleep); fake-clock rows still pass; t_l2.sh and the
      L1 copy under both bashes; bash -n, shellcheck error, lint
