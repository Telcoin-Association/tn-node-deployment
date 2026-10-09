status: done

# Checkpoint: package P5 (edit-config.sh 1.3.0)

Owned file: `edit-config.sh` (`SCRIPT_VERSION` 1.3.0). Tests in the scratchpad under `p5-tests/`
(`t_p5.sh`, `overrides.sh`, `shims/`, `shims-flock/`, `keys/`). No other repo file was edited.

## Sections

- [x] 1. Hard guard (B.1 verbatim, 1.6.0) after `source lib/common.sh`; `main` pre-scans `--json`, swaps fds, EXIT trap `edit_on_exit` (done ok:false when none sent, releases the lock); `--set` last or followed by a flag → error + done; unknown args warn on stderr; `--no-epoch-wait`; role flags accepted and ignored; `--help` prints the header block
- [x] 2. Update lock in every apply path (`edit_lock`: `TN_EXIT_TRAP_OWNED=1; tn_acquire_update_lock`), refusal "an update is in progress (PID N); try again when it has finished", released by the trap and (menu) after each edit via `edit_unlock`
- [x] 3. `edit_epoch_wait` (update-node policy and progress mapping via `edit_wait_say`) before the restart in `apply_changes`, `edit_bls_passphrase` (before its stop), `run_set`, plus `restart_node`; never on the rollback restart
- [x] 4. Metrics via `set_metrics` (`tn_launch_flag_set`/`unset`, `off` removes); deleted `read_flag`, `has_flag`, `has_flag_in_file`, `set_flag_value`, `add_flag`, `remove_flag`, `restore_service_file`, `json_set_listener`, `json_apply_changes`; launch-flag edits gated on `tn_launch_runner` (`edit_launch_spec`) and `tn_node_has_flag` (`edit_need_flag`)
- [x] 5. New fields (menu items 8-10, `--set`, `--help`): `set_bootstrap_peers`, `set_state_export`, `set_private_forward_targets`
- [x] 6. Rollback through a per-edit backup registry (`edit_backup`, `edit_restore_backups`, `edit_any_changed`, `edit_drop_backups`) covering launch file, unit, `parameters.yaml`, peers file
- [x] 7. `refresh_chain_configs`: directory from `.node-meta` NETWORK (`chain_config_subdir`); chain-id match required; lock before the git pull; a failed pull no longer kills the script
- [x] 8. Tests: `t_p5.sh` 527/527 under `/bin/bash` 3.2.57 and bash 5.3.15; `bash -n` both; shellcheck error-level clean (all levels: same 3 SC2001 as HEAD); check-bash32 clean
- [x] 9. Closing headings

## Notes

- "Three apply paths": interactive `apply_changes` (every menu edit, refresh included),
  `edit_bls_passphrase` (its own stop/start), and `run_set` (`--set`, JSON or human). Menu item
  "Restart node" also takes the lock and waits (a restart of a committee node at the boundary is
  what the wait exists to avoid, and a restart in the middle of an update-node apply would start
  a half-swapped node).
- `--set` works without `--json` too (human output, same flow), since the setters are shared.
- Setters return 0/1; the caller detects "nothing changed" by comparing each backup with its file,
  then drops the backups and skips the restart (done ok:true "... is already ...").
- The menu releases the lock after each edit (`edit_unlock`: `tn_release_update_lock` for the
  mkdir lock, `exec 9>&-` for the flock lock) so an open menu never holds up update-node.

## Operator-visible changes

- Three new settings, in the menu (items 8 to 10) and in `--set`:
  `bootstrap_peers=<absolute path>|none`, `state_export=off|unlimited|N`,
  `allow_private_forward_targets=true|false`. The menu shows their current values in the config
  table. The menu is renumbered after item 7: Refresh chain configs 8 → 11, Restart node 9 → 12,
  Exit 10 → 13 (BLS passphrase stays item 5, which OPERATOR.md cites).
- Bootstrap peers: the file is checked by the installed node binary, installed as
  `/etc/telcoin/bootstrap-peers.yaml` (0644 root) and loaded by the start wrapper at each start
  with `--bootstrap-peers "$(cat …)"`. Refused on a release without the flag ("the installed release
  has no --bootstrap-peers; update the node first") and on a node started straight from its
  systemd unit ("... Convert the unit to a start wrapper first."). `none` removes the flag and the
  file.
- State export: `unlimited` needs v0.13.0-adiri or later, `N` v0.15.0-adiri or later; each flag is
  checked against the installed release first.
- `allow_private_forward_targets=true` is refused on testnet (2017) and mainnet (487) and when the
  genesis has no readable chain id; allowed on devnet (32285) and any other chain id.
- Metrics: `--set metrics=…` now adds `--metrics` when it is missing (it used to edit only an
  existing flag), and `metrics=off` (or "off" in the menu) removes it.
- Before a restart (menu apply, Restart node, the BLS passphrase stop, `--set`), a committee node
  waits for the epoch boundary when it is within `TN_EPOCH_MARGIN` (300 s), at most
  `TN_EPOCH_WAIT_MAX` (1800 s). `--no-epoch-wait` or `TN_SKIP_EPOCH_WAIT=1` skips it. A rollback
  restart never waits.
- Every edit takes the update lock; while update-node.sh holds it, the edit is refused with "an
  update is in progress (PID N); try again when it has finished".
- Needs `lib/common.sh` 1.6.0: with an older library it stops with "lib/common.sh X is older than
  1.6.0. Run update-scripts.sh and try again." (an error event and done in `--json` mode).
- `--set` without `--json` runs the same edit-restart-verify flow with human output.
- An edit that changes nothing (the value is already in place) no longer restarts the node.
- `--json`: stdout is JSON only from the first argument on; every run ends with exactly one
  `done`, including non-root runs, bad arguments and the lock held; `--set` with no value is an
  error (it used to loop forever); unknown arguments warn on stderr; `--json --help` sends one
  done ok:true.
- The JSON rollback now also restores `parameters.yaml` and the peers file (and removes a peers
  file the edit created). Rollback message: "restart failed; rolled back to the previous
  configuration" (was "... to previous unit").
- Refresh chain configs uses `NETWORK` from `.node-meta` (testnet, mainnet, devnet) instead of
  always testnet, and refuses unless the node's genesis and the new one declare the same chain id
  (the message names both). A failed `git pull` is reported instead of ending the script.
- `docker_image` pinned by digest (`name@sha256:…`) is now written literally (perl used to read
  `@sha256` as an array and drop it).
- New `--help`.

## Changelog text

### edit-config v1.3.0 — bootstrap peers, state export and private forward targets; epoch-aware restarts; update lock

Three new settings, in the menu (items 8 to 10; Refresh chain configs, Restart node and Exit move
to 11, 12 and 13) and in `--set`. `bootstrap_peers=<path>` installs a YAML or JSON map of peers
keyed by BLS public key as `/etc/telcoin/bootstrap-peers.yaml`, after the installed node binary has
parsed it, and the start wrapper passes it with `--bootstrap-peers "$(cat …)"` at each start;
`none` removes both. It needs v0.15.0-adiri and a start wrapper: a node started straight from its
systemd unit is refused, because systemd cannot run the `$(cat …)`. `state_export=off|unlimited|N`
sets `--enable-state-export` and, for `N`, `--state-export-keep N`, each only when the installed
release lists the flag. `allow_private_forward_targets=true|false` edits that key in
`parameters.yaml`; `true` is refused on testnet and mainnet and when the genesis chain id cannot be
read. `--set metrics=` now adds the flag when it is missing, and `metrics=off` removes it. Before
any restart of a node that votes in the current committee, edit-config waits for the epoch boundary
when it is within five minutes (at most 30 minutes), like update-node; `--no-epoch-wait` or
`TN_SKIP_EPOCH_WAIT=1` skips it and a rollback restart never waits. Every edit takes the update
lock and is refused while update-node.sh is applying an update. `--set` without `--json` runs the
same edit, restart and health check with readable output, and an edit that changes nothing no
longer restarts the node. In `--json` mode stdout is JSON only and every run ends with one `done`,
including runs that stop on a bad argument, a missing root, or the lock; `--set` with no value used
to loop forever. The rollback after a failed restart now restores `parameters.yaml` and the peers
file too. Refresh chain configs reads the network from `.node-meta` and refuses unless the node's
genesis and the new one declare the same chain id. A Docker image pinned by digest is written
literally. Needs `lib/common.sh` 1.6.0.

## Tests run

Harness `<scratchpad>/p5-tests/t_p5.sh` runs the real `edit-config.sh` (symlinked, unmodified)
end to end with the bash running the harness, under `env -i`, against a `TN_ROOT_PREFIX` fixture
tree per case. Library copies: `libs/new` (working tree, common 1.6.0) and `libs/l1` (1e2d2f1,
common 1.5.0), each with `DEFAULT_INSTALL_DIR`/`TN_SOURCE_DIR` made env-overridable and an
`overrides.sh` hook (fake root via `check_root`, recording `tn_wait_restart_window` stub that drives
the progress function with step, log and warn and can hold for a few seconds). PATH shims:
`systemctl` (records; active-state file; N bad restarts), `docker` (records; `run --rm IMAGE telcoin
…` runs the real v0.15.0 build for `…:v0.15.0-adiri` and the tn-4 build for `…:v0.14.0-adiri`),
`chown`, `sleep`, `git`, `ufw`, `id`; `shims-flock/flock` takes a real `flock(2)` on the inherited
descriptor through python3, so the Ubuntu flock path and its release work on macOS. Fixtures:
binary wrapper, docker wrapper and legacy one-line unit (setup-node shapes); genesis with chain ids
2017, 487, 32285, 31337 and none; `parameters.yaml` from tn-4 testnet (no key) and v0.15.0 mainnet
(key present, plus a quoted repeat with a comment); a peers map keyed by a BLS key generated with the
v0.15.0 build's `keytool generate validator` (body = that node-info's `p2p_info`), and a fake-key
map. Real binaries: v0.15.0 build as `binary:` and through docker; the tn-4 build as the
pre-v0.15.0 negative fixture.

- `/bin/bash t_p5.sh` (3.2.57): 527 passed, 0 failed. `bash t_p5.sh` (5.3.15): 527 passed, 0 failed.
  Coverage:
  - Hard guard with the 1.5.0 library: `--json` prints exactly the error and done lines, rc 1;
    human mode prints `[ERROR] …` on stderr with empty stdout; wrapper untouched.
  - `--set` last, `--set --json`, human `--set` last: rc 1 within 5 s, error then done (two lines),
    or `[ERROR]` on stderr. `--json` alone, unknown field (no lock taken), empty value
    (`bootstrap_peers=`): error + one done. Unknown argument: warning on stderr only; `--observer`
    silent in JSON. `--json --help`: one done ok:true, help on stderr lists the new fields,
    `--no-epoch-wait` and `TN_SKIP_EPOCH_WAIT=1`. `--help` stops at the closing rule.
  - Non-root (`check_root` real): error "edit-config.sh must run as root" and exactly one done,
    also for a bare `--json`.
  - state_export on the binary wrapper: unlimited, 5, 5 again (ok, "is already", no restart, file
    byte-identical), unlimited (keep dropped), off (back to the original line); bad values 0, -1,
    1234567, 01, abc, empty refused with no backup left and no restart; tn-4: N refused with "the
    installed release has no --state-export-keep; update the node first", unlimited allowed; docker
    v15 (probe through `docker run --rm IMAGE telcoin node --help`), docker v14 refused, unknown
    image "could not run the node binary (docker:…)"; legacy unit: flags appended to `ExecStart`,
    daemon-reload before restart, off restores the unit.
  - bootstrap_peers: binary wrapper installs the file (byte-identical, mode 644, `chown 0:0` on the
    staged copy), the line carries `--bootstrap-peers "$(cat <installed path>)"`, `bash -n` under
    both bashes; the edited wrapper run under `/bin/bash` and bash against a recording binary passes
    the map as one argument byte for byte (14 arguments); same file again and the installed path
    itself: nothing changed; `none` removes flag and file (backup kept), again: nothing changed;
    docker v15 parse check through docker; fake-key map rejected with clap's error and the shape
    hint, nothing installed, no staged copy left; relative, missing, directory, empty and 70,000-byte
    paths refused; tn-4 refused with the update hint; legacy unit refused with "Convert the unit to
    a start wrapper first." and the unit named; `none` on the unit: nothing changed.
  - allow_private_forward_targets: true at 2017 refused naming testnet (no backup), false at 2017
    appended; true at 487 refused (mainnet); true at 32285 appended with a backup equal to the
    original and every other line intact, then false (one occurrence); 31337 the same; a file with
    the key and a quoted repeat: rewritten where it stood, repeat dropped, every other line kept;
    unreadable chain id refused; bad value refused; legacy unit node: unit untouched.
  - metrics: added when missing, changed (one occurrence), off removes it, `9101` refused; legacy
    unit gets `--metrics` on `ExecStart`; a wrapper with no `--http` line refused by the runner gate.
  - Existing fields: verbosity on the docker wrapper (volume `-v` untouched), docker image by digest
    pulled and written literally, same image: no pull, nothing changed; primary listener on docker.
  - Rollback (first restart unhealthy): new peers file removed and wrapper restored; an existing
    peers file restored; `parameters.yaml` restored; legacy unit restored with daemon-reload before
    the second restart; two restarts, one wait, the wait before the first restart and none after;
    second restart also unhealthy: `rolled_back:false`, journalctl hint, files restored.
  - `--no-epoch-wait` and `TN_SKIP_EPOCH_WAIT=1`: no wait, the skip note logged, applied. The real
    `tn_wait_restart_window` with the RPC down: a log event, no wait, applied.
  - Lock: a live PID holding the mkdir lock → refused naming the PID, done repeats it, holder's lock
    left alone, no restart; dead PID → taken over, released at exit. flock path: `flock -n 9` used,
    no mkdir lock; another process holding the flock → refused with its PID. Menu, both lock kinds,
    driven through a FIFO: the lock is held during the wait and released while the menu is still
    open; menu exit rc 0.
  - Menu: state export 3/6 (wait shown as `>>>` before the restart), metrics with the restart
    declined (no wait, no restart), bootstrap peers from the menu, peers on a legacy unit (refusal
    shown, unit untouched), private forward targets at 31337 and refused at 2017, Restart node (wait
    before restart), BLS passphrase (wait before `systemctl stop`), lock held (state export and
    Restart node both refused).
  - Refresh: match (pull, copy, "Chain id 2017 matches", wait before restart); mismatch 2017 vs 487
    (both ids named, nothing copied, no restart); unreadable node id; unreadable source id; devnet
    meta uses `chain-configs/devnet`; NETWORK=mainnet picks `chain-configs/mainnet`; no NETWORK
    refused before any pull, with the fix hint naming the meta file; failed pull reported, script
    survives.
  - Human `--set`: `[OK]  applied and telcoin healthy`, rc 0; refused on tn-4 with the hint, rc 1.
  - Every `--json` run: each stdout line is exactly one JSON object (`jq -e -s`), exactly one done,
    and it is the last line.
- `/bin/bash -n edit-config.sh`, `bash -n edit-config.sh`: clean.
- `shellcheck -x --severity=error edit-config.sh`: clean. All levels: 3 SC2001, the same as HEAD.
- `/bin/bash tools/check-bash32.sh edit-config.sh`: clean.
- Greps: no apostrophe in a `${var:-…}` word, no `local x="$(…)"`, no line-number references, no
  `--observer`/`--validator` emitted (only accepted and ignored).

## Open issues

1. Release bookkeeping (orchestrator): `edit-config.sh.sha256` on disk was regenerated by another
   process (all sidecars, 22:06:13) after my last edit (22:03:14) and matches the final file
   (sha256 `367d6f9e…`); rerun `tools/gen-checksums.sh` if edit-config changes again. README
   changelog entry above; `update-scripts.sh` bump in the release commit.
2. Decision to confirm: the P5 brief says 32285 counts as private for
   `allow_private_forward_targets` (and asks that `true` at 32285 edits `parameters.yaml`), but
   `tn_is_public_chain_id` (lib 1.5.0+) returns public for 32285 (`DEVNET_CHAIN_ID`). I followed the
   brief: the gate refuses when `tn_is_public_chain_id "$id" && [[ "$id" != "$DEVNET_CHAIN_ID" ]]`,
   so a future public network added to the library is still refused. To refuse devnet instead,
   drop the `!= DEVNET_CHAIN_ID` test in `set_private_forward_targets`, change "testnet and
   mainnet" in the help block and the menu text, and flip the `pf-devnet` test.
3. UI (helper and server), for `config-set`: the helper's allowlist only knows the old five fields.
   Field names and values `edit-config.sh --json --set` now accepts:
   - `primary_listener=<multiaddr>`, `worker_listener=<multiaddr>` (unchanged)
   - `metrics=<IPv4:PORT>|off` (new: `off`), suggested regex
     `^(off|([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5})$`
   - `verbosity=-v…-vvvvv`, `docker_image=<ref>` (unchanged)
   - `bootstrap_peers=<absolute path>|none`, suggested `^(none|/[A-Za-z0-9._/-]+)$`; the file must
     already be on the node host (the helper has no upload path)
   - `state_export=off|unlimited|N`, `^(off|unlimited|[1-9][0-9]{0,5})$`
   - `allow_private_forward_targets=true|false`, `^(true|false)$`
   Also: a run that changes nothing ends `ok:true` with msg "<field> is already <value>; nothing
   changed and <svc> was not restarted"; the rollback msg is now "restart failed; rolled back to the
   previous configuration"; events now include `log` and `warn`; a run can last up to 30 minutes
   longer during the epoch wait (heartbeat every 15 s); the helper cannot pass `--no-epoch-wait`
   (fixed argv, sudo resets the environment). The UI ships its own copy of edit-config and lib/
   (install-ui.sh): edit-config 1.3.0 refuses to run with a lib/common.sh older than 1.6.0, so the
   UI bundle must carry both together or config edits from the UI fail with the guard message.
4. Library (L package): `tn_node_parse_check` keeps only the first `error:` line. For a multi-line
   map, clap quotes the value across lines and the reason ("expected valid bls public key bytes",
   "while parsing a flow sequence …") comes after `for '--bootstrap-peers <MAP>': ` on a later line,
   so it is lost. Suggest returning the text after that marker, or the error block up to the blank
   line joined into one line. edit-config adds a hint about the expected map shape meanwhile.
5. Docs (OPERATOR.md, README, partner guide, per AGENTS.md): the three new fields; the menu
   renumbering; `--set` without `--json`; `metrics=off`; the epoch wait with `--no-epoch-wait` and
   `TN_SKIP_EPOCH_WAIT`; the update-lock refusal; the OPERATOR.md table row for `edit-config.sh`
   lists only the old five fields. The bootstrap-peers refusal tells a legacy-unit node to "convert
   the unit to a start wrapper first", but no script in this repo converts a bare-`ExecStart` unit
   (migrate-node-naming.sh requires an existing wrapper); the docs need that procedure, or a later
   package a converter.
6. Refresh chain configs, pre-existing: a source-build node checked out at a release tag is on a
   detached HEAD, where `git pull` fails; refresh now stops with "git pull failed …" (before, the
   failure ended the whole script under errexit). A box whose `.node-meta` has no NETWORK can no
   longer refresh (the message says to add it); deriving the directory from the genesis chain id
   would be a safe fallback, since the chain-id check still applies.
7. Pre-existing and untouched: listener edits on binary installs use GNU `sed -i` (fine on Ubuntu,
   fails on macOS); `edit_verbosity`, `edit_rpc`, `edit_listener_addresses` and the main menu exit
   at end of input under errexit; some `edit_bls_passphrase` error paths `return 1`, which ends the
   script under errexit.
8. Behaviour to know: setting and then unsetting a flag on setup-node's one-line wrapper drops the
   trailing blank setup-node leaves after the last flag (library behaviour; harmless).

## Fix pass (V-CORE-1)

status: done (2026-10-02). Edited in place on top of 9ff00af; `SCRIPT_VERSION` stays 1.3.0.
Findings from `tasks/ckpt-fu-V-CORE-1.md`: F-f (error), F-c (warn), F-g and F-h (notes), plus
the library change 8185d00.

- [x] 1. F-f: `peers_file_ok FILE` (mirrors setup-node's: readable regular file, group and other
      read bits set via `stat -L -c %a` then BSD `stat -L -f %Lp`, non-empty, at most 64 KiB; reason
      on stdout). Runs on the source before any probe, then on the staged copy, now made with
      `cp -p` so it carries the mode of the file actually read: a path swapped to a private file
      between the check and the read is refused before the map reaches a process list. The parse
      check stays the only time a run hands the map to a node binary.
- [x] 2. F-c: an absent `allow_private_forward_targets` reads as false (`${cur:-false}`), so
      `false` is then a no-op: done ok:true, no write, no restart.
- [x] 3. F-g: `--help` reads `${BASH_SOURCE[0]}` instead of `$0`.
- [x] 4. F-h: `launch_node_commands FILE` counts live commands that run `node` with `--http`, read
      by the library's rules (continuations joined; `#` lines, and `;` lines in a unit, skipped; in a
      shell wrapper a comment line ends a continued command). `edit_launch_unambiguous` refuses
      every launch-file edit when the count is 2 or more: `edit_launch_spec` (metrics,
      bootstrap_peers path and none, state_export), `--set` listeners and verbosity,
      `set_docker_image` (before the pull), the menu's `backup_edit_targets` and its RPC edit.
- [x] 5. 8185d00: `tn_node_parse_check` now gives one redacted line with clap's reason. The relayed
      message drops the leading `error: ` and keeps the map-shape hint; there was no second-probe
      workaround in edit-config to remove. Done messages no longer read ".; nothing was changed"
      (the error's final period is trimmed first).
- [x] 6. Found by the new menu row: a refused menu edit returned 1 into the menu loop, which runs
      under errexit, and ended the script. The four `backup_edit_targets` callers now `return 0`
      (a backup failure also goes back to the menu now, instead of exiting).

### Exact new messages

- Mode: `<FILE> is mode 600: other users cannot read it. edit-config accepts only a peers file that
  others can already read, because the installed copy is world-readable (0644) and the check passes
  the map on the command line of the node binary, where other users can see it. Run chmod 644
  <FILE> first.` (done: `... Run chmod 644 <FILE> first; nothing was changed`)
- Swapped during the copy: `<FILE> changed while it was being copied. Check the file and try again.`
- Absent key + false: done ok:true `allow_private_forward_targets is already false; nothing changed
  and telcoin was not restarted`.
- Two node commands: `<launch file> has 2 node commands with --http, so it is not clear which one
  starts the node. edit-config changes a launch file only when it has exactly one; remove or comment
  out the others and try again.`
- Rejected map (lib 8185d00): `the node rejects <FILE> as a --bootstrap-peers map (invalid value '…'
  for '--bootstrap-peers <MAP>': invalid value: string "…", expected valid bls public key bytes at
  line 1 column 1). Each key must be a node's BLS public key and each value the primary and workers
  entries from that node's node-info.yaml.`

### Tests (fix pass)

- `t_p5.sh`: 702 passed, 0 failed under `/bin/bash` 3.2.57 and bash 5.3.15 (527 before). New rows:
  modes 600, 640, 604, 400 refused with zero calls to a recording node binary (`bin/rec-v15`, which
  logs and runs the v0.15.0 build) and nothing installed; 600 through docker: no `docker run`; 0644
  accepted with the map handed over exactly once (two probes: help, then the map), once again on a
  repeat, none for `none`; docker: one `docker run … --bootstrap-peers`; a `cp` shim that leaves the
  copy 600 (a swap) refused with zero map calls and no staged file left; absent key + false at 2017
  and 31337 (no restart, no wait, file byte-identical, no backup left), key already false; `--help`
  sourced from `bash -c 'source FILE --help'` prints the fields with rc 0; two live node commands
  refused for metrics, state_export, bootstrap_peers (path and none), verbosity, primary_listener
  (file, unit, no probe, no restart, no backup), docker_image (no pull), a unit with two ExecStart
  node commands (`--set` and the menu RPC edit), the menu's verbosity and metrics edits (script
  stays in the menu, rc 0); allowed: a commented second command, a command split over lines; a
  continued command cut by a comment line: no node command, untouched. Rejected map: clap's reason
  relayed, no doubled period, the map text on neither stdout nor stderr.
- `count_check.sh`: `launch_node_commands` agrees with the library's reading
  (`tn_launch_flag_get FILE --http` rc 2 = none) on all 13 L2 launch-file fixtures, both bashes.
- `bash -n` under both bashes: clean. `shellcheck -x --severity=error edit-config.sh`: clean (all
  levels: 3 SC2001, unchanged). `/bin/bash tools/check-bash32.sh edit-config.sh`: clean.

### Changelog addendum (append to the edit-config v1.3.0 paragraph)

`bootstrap_peers` takes only a file its group and other users can already read: the installed copy
is world-readable and the check shows the map on the node binary's command line. A launch file with
more than one node command is refused instead of being half edited, and
`allow_private_forward_targets=false` changes nothing when the key is absent.

### Open issues (fix pass)

1. Release bookkeeping: `edit-config.sh.sha256` on disk (`6a6e8cd7…`) was regenerated by another
   process at 01:06:29, before my last edit (01:07:39), so it records an intermediate version. The
   final file is sha256 `6c222f4f…`; rerun `tools/gen-checksums.sh` before committing.
2. The menu's docker image edit still pulls before the two-command check refuses (a wasted pull on a
   corrupted launch file only); the `--set` path checks before the pull.
3. UI helper (optional, from F-f): its `bootstrap_peers` path pattern can stay broad now that
   edit-config refuses private files, but narrowing it (no `..`, a fixed directory) is still cheap.

## Fix pass 3 (V-DOC)

status: done (2026-10-02). Edited in place on top of 59d10a0; `SCRIPT_VERSION` stays 1.3.0.
V-DOC finding 1: `run_set` wrote the edit, then waited for the epoch boundary inside `edit_restart`;
a run killed during the wait (the UI sends TERM two seconds after its page goes away) released the
lock and sent done ok:false but left the edit on disk unapplied, for the next restart or reboot to
load with no health check and no rollback.

- [x] 1. `EDIT_PENDING`: set by `edit_backup` when it records a file (so from the first file an
      edit is about to change), cleared by `edit_reset_backups`, `edit_restore_backups` (and so
      `edit_drop_backups`), just before the restart is issued (`edit_restart` for `--set`,
      `apply_changes` for the menu) and when the operator chooses to restart later in the menu.
- [x] 2. `edit_on_exit` now starts with `set +e` and `trap '' TERM INT HUP PIPE`, and when an edit
      is pending calls `edit_abort_pending`: every recorded file is put back (launch file, unit,
      `parameters.yaml`, peers file; a new peers file removed) with `edit_restore_backups`, which
      also runs `daemon-reload`, before the lock is released. Reported as an error event and in the
      done (`"rolled_back":true`, or `false` when a restore failed) or as an `[ERROR]` line. A staged
      `.new.<pid>` file (`EDIT_TMP`) is removed too.
- [x] 3. `main` sets `trap 'EDIT_SIGNAL=TERM; exit 143' TERM`, `... INT; exit 130`,
      `... HUP; exit 129` after the EXIT trap, as prepare-stake does.
- [x] 4. A restart that takes long is not rolled back: the flag is cleared before
      `systemctl restart`, so a signal during the restart (bash runs the trap when it returns)
      leaves the edit in place; the done says "stopped by SIG… after the restart was issued; the
      edit stays in place". A signal before any edit says "stopped by SIG…; nothing was changed".
- [x] 5. The menu: the older edits (listeners, verbosity, P2P ports, docker image, RPC) now record
      their backups with `edit_backup` too (`backup_edit_targets`, `edit_rpc`), so they get the same
      protection; the menu loop resets the record before each action. Stopping at the
      "Restart the node now?" prompt or during the wait rolls back; declining the restart keeps the
      saved edit, as before.

### Exact new messages

- `Stopped by SIGTERM before the restart, so the edit was rolled back: every file it changed is as
  it was before this run.` (SIGINT, SIGHUP likewise; an exit that is not a signal reads
  `Stopped (exit status N) before the restart, ...`). Done: ok:false, `"rolled_back":true`, same msg.
- Restore failure: `Stopped by SIGTERM before the restart, and putting the files back failed (see
  the errors above): copy each .bak file over its original by hand.` (`"rolled_back":false`)
- Signal after the restart was issued: done `stopped by SIGTERM after the restart was issued; the
  edit stays in place`. Signal before any edit: done `stopped by SIGTERM; nothing was changed`.

### Tests (fix pass 3)

- `t_p5.sh`: 852 passed, 0 failed under `/bin/bash` 3.2.57 and bash 5.3.15 (702 before). Signal
  cases start the script through a python launcher that resets SIGINT to its default (a background
  job of a non-interactive shell starts with it ignored, and bash cannot trap a signal ignored on
  entry); the stubbed `tn_wait_restart_window` blocks in 0.1 s naps (`P5_WAIT_SLEEP`), and the
  signal is sent once the stub has logged WAIT. Rows: TERM during the wait for a launch-file flag
  (`state_export=5`, exit 143), `parameters.yaml` (`allow_private_forward_targets=true` at 31337,
  no staged file left), a new peers file (removed, no staged file left), a replaced peers file
  (old bytes and mode 644 back), a legacy unit (unit byte-identical, daemon-reload after the
  restore); HUP (129) and INT (130); the flock lock path (lock free afterwards); human `--set`
  (`[ERROR]` line, 143). Each: files byte-identical to before the edit, never restarted, error
  event plus one done ok:false `rolled_back:true` with the message, lock released, every stdout
  line one JSON object. An exit with status 7 from inside the wait (`P5_WAIT_EXIT`): rolled back
  with "Stopped (exit status 7)". A slow restart (`P5_RESTART_SLEEP=2`) signalled during the
  restart: the edit stays, no `rolled_back` field. A normal run with a blocking wait: applied,
  restarted once. TERM during a docker pull, before any edit: "nothing was changed". Menu: TERM
  during the wait after a state-export edit and after a verbosity edit (an older menu edit): files
  byte-identical, `[ERROR]` line; INT at the "Restart the node now?" prompt (through a FIFO): rolled
  back, 130; TERM after declining the restart: the saved edit stays.
- `bash -n` under both bashes: clean. `shellcheck -x --severity=error edit-config.sh`: clean (all
  levels: 3 SC2001, unchanged). `/bin/bash tools/check-bash32.sh edit-config.sh`: clean.

### Open issues (fix pass 3)

1. Sidecar: `edit-config.sh.sha256` on disk matched the final file (`680eb086…`) when this pass
   ended (regenerated by another process after my last edit); rerun `tools/gen-checksums.sh` if
   the file changes again.
2. bash runs a trap only when the foreground command returns: a TERM during the epoch wait is
   handled at the next poll (`TN_EPOCH_POLL`, 15 s by default), and one during a docker pull or the
   parse check when that returns. The rollback still happens; it is just not instant.
3. Not covered, by design: Refresh chain configs copies new genesis, committee and parameters files
   without recording backups, so a run stopped during its wait keeps the new files for the next
   restart (the files a network restart needs). The BLS passphrase edit waits before it stops the
   node and writes; a signal in the few seconds between its stop and start leaves the node stopped
   with the new passphrase file.

## Fix pass 4 (code review)

status: done (2026-10-02). Edited in place on top of 48a4c42; `SCRIPT_VERSION` stays 1.3.0.
Finding: `edit_unlock` kept its own lock-kind flag (`EDIT_LOCK_FLOCK`) and closed fd 9 a second
time after `tn_release_update_lock` (lib/common.sh 1.6.0), which already runs `flock -u 9;
exec 9>&-` on the flock path, removes the mkdir lock dir otherwise, and tracks
`TN_UPDATE_LOCK_KIND`.

- [x] 1. `EDIT_LOCK_FLOCK` and the extra `exec 9>&-` are gone; `edit_lock` sets only
      `EDIT_LOCK_HELD`.
- [x] 2. New `edit_release_lock`: `tn_release_update_lock` when `declare -F` finds it; otherwise
      (a library without it, which the 1.6.0 hard guard already rules out) a minimal fallback that
      closes fd 9 and removes `${TMPDIR:-/tmp}/telcoin-update.lock.d` when its pid file names this
      process. `edit_unlock` (menu) and `edit_on_exit` both release through it; the trap also
      clears `EDIT_LOCK_HELD`.

### Tests (fix pass 4)

- `t_p5.sh`: 858 passed, 0 failed under `/bin/bash` 3.2.57 and bash 5.3.15 (852 before). The flock
  stand-in now honours `flock -u` (LOCK_UN on the inherited descriptor), as util-linux does. All
  lock rows pass for both kinds: refusal with the holder's PID (mkdir live PID, python flock holder),
  stale mkdir takeover, release at exit, menu release while the menu stays open (mkdir and flock;
  the flock one now also checks the release is the library's `flock -u 9`), release after a
  signalled run. New row: TERM during the wait with an orphaned child that inherited fd 9 still
  running; the lock is free as soon as the script exits (`flock -u 9`), and the edit is rolled back.
- `t_p5_release.sh` (sources a copy without `main "$@"`): 12 passed, 0 failed under both bashes.
  With the library: `edit_unlock` removes the mkdir lock and clears `EDIT_LOCK_HELD`, a second call
  is a no-op. Without `tn_release_update_lock`: the fallback removes our mkdir lock, closes fd 9,
  keeps another process's lock dir, returns 0 with nothing held; `EDIT_LOCK_FLOCK` is gone from the
  file and `exec 9>&-` appears once (the fallback).
- `bash -n` under both bashes: clean. `shellcheck -x --severity=error edit-config.sh`: clean (all
  levels: 3 SC2001, unchanged). `/bin/bash tools/check-bash32.sh edit-config.sh`: clean.

### Open issues (fix pass 4)

1. Sidecar: `edit-config.sh.sha256` still records the 48a4c42 file (`680eb086…`); the final file
   is sha256 `e58c4a00…`. Rerun `tools/gen-checksums.sh` before committing.
