status: done

# Checkpoint: package P4b (setup-node.sh 1.3.0, part b: node extra flags)

Owned file: `setup-node.sh` (`SCRIPT_VERSION` stays 1.3.0). No other repo file was edited. Tests
in the scratchpad under `p4b-tests/` (`mk.sh`, `runner.sh`, `t_p4b.sh`, `shims/`, `fakebin/`,
`gen/`).

## Sections

- [x] 1. Flags `--bootstrap-peers FILE`, `--enable-state-export`, `--state-export-keep N` in the parser and `--help`; `init_node_extra_flags` validation before `check_root`
      (header "NODE FLAGS" block and `[node flags]` in USAGE; new `-h|--help` prints the header
      block like update-node/edit-config, JSON: one done ok:true; for the two value flags an
      empty value or one starting with `-` is "requires a value"; `peers_file_ok` (exists,
      regular, readable, <= 65536 bytes); keep `^[1-9][0-9]{0,5}$`; keep without enable warns
      "turns state export on"; enable without keep warns about unlimited retention; warnings
      queue in NODE_FLAG_WARNINGS: printed in init for --json, by prepare (after the welcome
      screen) otherwise)
- [x] 2. `prepare_node_extra_flags`: probes, parse check, peers file install, flag text, `.node-meta`
      (NODE_EXTRA_FLAGS through P4a's node_launch_flags seam, not tn_launch_flag_set: one write,
      no double blank; called from step_create_infrastructure after create_directories and
      verify_binary (keygen and interactive stop before keys exist; after the chown -R of
      CONFIG_DIR) and from step_create_service (finalize); memo NODE_EXTRA_FLAGS_SPEC skips the
      second run for the same runner; all gates first (require_node_flag: rc 1 setup_fail
      naming flag, release and first release; rc 4 warn and add), then install_bootstrap_peers:
      mktemp next to dest, copy, size re-check on the copy, tn_node_parse_check on the copy,
      rc 1 -> bootstrap_peers_reason asks once more for clap's full message, rc 4 warn and
      install unchecked, chmod 0644, chown root:root, mv -f; CONFIG_DIR charset check (the path
      goes unquoted inside "$(cat ...)"); meta BOOTSTRAP_PEERS_FILE=<installed path or empty>,
      STATE_EXPORT=off|unlimited|N on every install; node_runner_spec / node_release_label
      helpers; keytool_supports_rpc_args now uses node_runner_spec)
- [x] 3. Wrappers: all four carry the flags through node_launch_flags (heredocs unchanged); the
      docker wrapper's "$(cat ...)" runs on the host and hands the map to docker as one argument.
      No `.service`-only path remains in setup-node (both methods write wrapper + unit), so there
      is nothing to refuse there.
- [x] 4. Finalize reads the recorded choices back from `.node-meta` (`finalize_node_extra_flags`
      right after finalize_install_inputs; per field: the peers map when --bootstrap-peers is
      absent, STATE_EXPORT when neither state flag is given; a recorded file that is gone or a
      bad STATE_EXPORT stops finalize before anything is written)
- [x] 5. Tests: p4b 419/419 under `/bin/bash` 3.2.57 and bash 5.3.15; P4a harness 700/701 both
      (the one failure is a stale HEAD case, see Tests run); static gates clean
- [x] 6. Closing headings

## Operator-visible changes

- New `--bootstrap-peers FILE`: a YAML or JSON map of the peers the node dials at start, keyed by
  BLS public key, each entry a node's primary and workers as under `p2p_info` in its
  node-info.yaml. It replaces the genesis bootstrap servers. Before `check_root` setup refuses a
  path that does not exist, is not a regular file, is not readable or holds more than 64 KiB
  (65536 bytes). Later it asks the installed release whether it has the flag, checks the map with
  the release's own parser (a rejected map stops setup with clap's reason, for example
  `invalid value: string "notablskey", expected valid bls public key bytes at line 1 column 1`),
  and installs it as `/etc/telcoin/bootstrap-peers.yaml`, root-owned 0644, through a temp file and
  a rename (an existing file changes only once the new map passed). The start wrapper carries
  `--bootstrap-peers "$(cat /etc/telcoin/bootstrap-peers.yaml)"`: the host reads the file at every
  start and the node gets the map as one argument. Editing that file takes effect at the next
  restart, unchecked.
- New `--enable-state-export` (exports under `<datadir>/consensus-db/state_exports/epoch-N/`) and
  `--state-export-keep N` (1 to 999999). `--state-export-keep` alone also adds
  `--enable-state-export` and warns that it does; `--enable-state-export` alone warns that every
  export is kept until the disk fills.
- Setup asks the release it installs (`node --help` of the binary, or `docker run --rm IMAGE
  telcoin node --help`) whether it has each flag given. A release without one stops setup with
  "--bootstrap-peers needs telcoin-network v0.15.0-adiri or later, and the image X does not have
  it. Pick a newer release or leave --bootstrap-peers out." (`--enable-state-export` needs
  v0.13.0-adiri, `--state-export-keep` v0.15.0-adiri). This runs in step 4 (infrastructure), so an
  interactive install or a `--json` keygen stops before any key is made. When the release cannot
  be asked, setup warns and adds the flag; when the map cannot be checked, it warns and installs
  the map unchecked.
- `.node-meta` gains `BOOTSTRAP_PEERS_FILE` (the installed map's path, empty when none) and
  `STATE_EXPORT` (`off`, `unlimited` or N), written on every install, so values from an earlier
  install are replaced. A `--json` finalize reads them back for the flags it is not given;
  finalize stops when the recorded map is gone ("Put the file back, or pass --bootstrap-peers
  FILE") or STATE_EXPORT is not one of those values.
- `--json`: a `log` event `node flags: <the text added to the launch line>`; the warnings are
  `log` events starting `WARNING:`.
- Interactive: the closing summary adds "Bootstrap peers" and "State export" lines when in use;
  the step 4 output shows "Node flags: ..." and "Bootstrap peers map installed: ...".
- New `-h` / `--help`: prints the header block (usage and every flag) and exits 0; with `--json`
  the help goes to stderr and stdout gets one `done` event.
- Without these flags the wrappers and units are byte for byte what 1.3.0 (P4a) writes.

## Changelog text

Append to P4a's `### setup-node v1.3.0` entry; suggested title: `### setup-node v1.3.0 — input
checks before root, release floor, finalize reads keygen's choices, bootstrap peers and state
export`. Third paragraph:

New node flags. `--bootstrap-peers FILE` gives the node a YAML or JSON map of the peers to dial at
start, keyed by BLS public key, in place of the genesis bootstrap servers. Setup checks the file
(a regular file of at most 64 KiB) before it touches the box, checks the map with the installed
release's own parser, installs it as `/etc/telcoin/bootstrap-peers.yaml` and has the start
wrapper pass `--bootstrap-peers "$(cat /etc/telcoin/bootstrap-peers.yaml)"`, so the host reads
the file at each start. `--enable-state-export` exports each epoch's execution state, and
`--state-export-keep N` keeps only the newest N exports; on its own it turns state export on and
says so. Setup asks the installed release whether it has each flag given and stops, before any
key is made, when it does not (`--enable-state-export` arrived in v0.13.0-adiri, the other two in
v0.15.0-adiri). The choices are recorded in `.node-meta` as `BOOTSTRAP_PEERS_FILE` and
`STATE_EXPORT` (`off`, `unlimited` or a number), and a `--json` finalize reads them back when its
flags leave them out. `-h` / `--help` prints the usage.

## Tests run

Harness `<scratchpad>/p4b-tests/`. `mk.sh` builds `sut/` (working tree, `main "$@"` removed),
`sutfull/` (with main, for `--help`) and `head/` (HEAD = P4a's commit), with P4a's boxing of the
hard-coded root paths; P4a's PATH shims plus a new docker shim that parses docker's own options
(so `--name telcoin` is not taken for the command), picks the release by image tag (a `v0.14.0`
tag runs the tn-4 build, anything else the v0.15.0 build), runs `keytool` and `node ... --help`
for real, and records a start wrapper's `docker run` (one file per argument, plus the passphrase
it saw in its environment) without starting anything. `fakebin/rec` is the v0.15.0 build except
that `node ...` without `--help` records its argv; `fakebin/broken` exits 126 on any `--help`.
Fixtures in `gen/`: a real BLS key from `keytool generate validator` of the v0.15.0 build;
`peers.yaml` (that key, the `p2p_info` body of its node-info.yaml, and a comment holding quotes,
`$HOME`, backticks, `$(id)` and `*`), `peers2.yaml` (other comment), `peers.json` (one line),
`bad-key.yaml`, `bad-yaml.yaml`, `peers-64k.yaml` (exactly 65536 bytes, valid) and
`peers-65k.yaml` (66560 bytes). `runner.sh` is P4a's. Each case runs in a fresh process.

- `/bin/bash t_p4b.sh` (3.2.57): 419 passed, 0 failed. `bash t_p4b.sh` (5.3.15): 419 passed, 0
  failed. The final sweep re-checks all 67 `--json` runs: every stdout line passes `jq -e .`,
  exactly one `done`, and it is the last line.
- Coverage: static (bash -n both, version 1.3.0, no `--observer`/`--validator`, header documents
  the three flags); `--help` human (usage, the flags, no `#`, stops at the closing rule) and JSON
  (one line, done ok:true, text on stderr); both value flags missing as the last word, followed by
  an option, and empty, in JSON (error + one done, before check_root) and human mode ([ERROR] on
  stderr, no JSON); `--state-export-keep -1`; keep values 0, abc, 1000000, 01, 1.5, " 3", "3 ",
  a 20-digit number refused before check_root, and 1, 2, 999999 accepted; keep alone (implies
  warning), enable alone (unlimited warning), both (no implies warning); in human mode init prints
  nothing and the warnings print once, later; peers file missing, a directory, unreadable (mode
  000), 65 KiB (refused, JSON and human), exactly 64 KiB (passes). Docker keygen with
  `--bootstrap-peers --state-export-keep 3`: keys made, map installed byte for byte, mode 0644,
  `chown root:root` on the temp file, no temp left, meta keys once, three `node --help` probes and
  the parse check through docker, all before keytool ran, `node flags:` log event, no wrapper.
  Finalize with no flags: wrapper holds `--bootstrap-peers "$(cat <box>/etc/telcoin/bootstrap-peers.yaml)"
  --enable-state-export --state-export-keep 3` on the `exec docker run` line, once, the BLS key
  nowhere in the wrapper, `bash -n` under both bashes, lib's `tn_launch_flag_get` reads
  `$(cat ...)` and `3` back and `tn_launch_runner` reads the image; the wrapper run under
  `/bin/bash` and bash against the recording docker shim makes one docker call whose argument after
  `--bootstrap-peers` is the map byte for byte (one argument), with `--enable-state-export` and
  `--state-export-keep 3`, the passphrase only in the environment, `<image> telcoin node --datadir
  /home/nonroot` intact; after the installed file is replaced, the next run passes the new map
  (read at start, never during setup). Same for the TPM docker wrapper. Finalize overrides: given
  `--enable-state-export` (unlimited recorded, no keep, peers read back) and given a JSON map
  (installed and passed through; keep read back). Recorded map deleted, STATE_EXPORT=lots: error +
  done, no wrapper, nothing started; a keygen that recorded neither key: finalize records off and
  none, no node flags. No flags: stale BOOTSTRAP_PEERS_FILE/STATE_EXPORT replaced by none/off,
  foreign key kept, no `node` probe, no peers file, wrapper without node flags; with no flags the
  docker and binary wrappers and units (loadcredential and TPM) are identical to the ones HEAD
  writes for the same keygen box. Invalid maps: a fake key via docker (error = clap's reason
  "...expected valid bls public key bytes at line 1 column 1", no keys, nothing installed, no temp
  left, keytool never ran) and a YAML syntax error via the binary (reason ends "at line N column
  M"); an existing peers file stays untouched when the new map is refused. tn-4 build as binary:
  `--bootstrap-peers` and `--state-export-keep` refused as unsupported (no keys), `--enable-state-export`
  accepted (keys made, unlimited recorded); v0.14.0 image: refused, image named; a finalize with
  the v0.14.0 image after a v0.15.0 keygen: refused, no wrapper. A binary whose `--help` cannot
  run: three warnings (two flags, the map), map installed, choice recorded. Existing install with
  the recording binary, loadcredential and TPM: wrapper `exec <binary> node`, literal present, no
  keep, `bash -n` both; run under both bashes: one call, exactly 15 arguments `node --datadir ...
  --ws.addr 127.0.0.1 --bootstrap-peers <map> --enable-state-export`, map byte for byte. An
  interactive docker install through main with piped answers and `--bootstrap-peers
  --state-export-keep 4`: the warning prints once, after the welcome screen; the release is asked
  once (3 probes, 1 parse check: the memo works); wrapper literal; summary lines "Bootstrap
  peers:" and "State export: every epoch, newest 4 kept". Direct calls: a CONFIG_DIR with a space
  refused; the size re-check on the copy refuses a 65 KiB source (no temp left, nothing
  installed); `bootstrap_peers_reason` prints only the reason, nothing for a valid map or a
  missing binary, and runs through docker once for a docker spec; `node_release_label` and
  `node_runner_spec` for source (with the recorded ref), docker and existing.
- P4a's harness after `p4a-tests/mk.sh` (sut = this tree, head = HEAD = P4a's commit):
  `/bin/bash t_p4a.sh` 700 passed, 1 failed; `bash t_p4a.sh` 700 passed, 1 failed. The failure is
  `fz-new-bin2` "binary wrapper same as HEAD but the version line" and is stale, not a P4b change:
  the same harness with HEAD's own setup-node.sh as the SUT fails the same way (700/1), because
  that case was written when HEAD was 1.2.1 and HEAD now reads BINARY_PATH from `.node-meta` while
  the new-side box has it removed. In a scratch copy with `fz-head-bin2` dropping BINARY_PATH like
  `fz-new-bin2` does, the harness passes 701/701 under both bashes against this tree.
- `/bin/bash -n setup-node.sh`, `bash -n setup-node.sh`: clean. `shellcheck -x --severity=error
  setup-node.sh`: clean; at warning level only HEAD's SC2034 on `USE_LOAD_CREDENTIAL`.
  `/bin/bash tools/check-bash32.sh setup-node.sh`: clean. Added lines grepped for bash-4
  constructs, apostrophes in `${…:-…}`, `local x="$(…)"`, line-number references and package
  names: none.

## Open issues

1. Release bookkeeping (orchestrator): regenerate `setup-node.sh.sha256` at commit time; the
   README changelog entry above extends P4a's; `update-scripts.sh` bump in the release commit.
2. P4a's harness (scratchpad, not mine): `fz-head-bin2` needs
   `grep -v '^BINARY_PATH=' "$(meta)" > "$BOX/m" && cat "$BOX/m" > "$(meta)" && rm -f "$BOX/m"`
   before its HEAD finalize, as `fz-new-bin2` has, now that HEAD is 1.3.0 (V-CORE-1 should apply it
   or read the failure as known). Lesson for `tasks/lessons.md`: a harness that diffs against
   `git show HEAD:` goes stale once the package itself is committed; give both sides the same box.
3. lib/common.sh (L2): `tn_node_parse_check` returns the first `error:` line, but clap quotes the
   whole value in it, so for a multi-line map that line is `error: invalid value '<first line of the
   map>` and the reason is lost (it follows the value: `' for '--bootstrap-peers <MAP>': <reason>`).
   Printing the text after `' for '<flag> <VALUE>': ` would let setup-node drop
   `bootstrap_peers_reason`, which re-runs the probe only when a map is rejected.
4. `.node-meta` keys for edit-config (P5), check-node and docs:
   - `BOOTSTRAP_PEERS_FILE=<path>`: `${CONFIG_DIR}/bootstrap-peers.yaml` (always that path) when the
     launch line carries the flag; `BOOTSTRAP_PEERS_FILE=` (empty) or absent means none. Setup
     writes it on every install.
   - `STATE_EXPORT=off|unlimited|N`, N matching `^[1-9][0-9]{0,5}$` (1 to 999999); absent means off.
     The vocabulary is edit-config's `state_export` field. `unlimited` = `--enable-state-export`
     alone; N = `--enable-state-export --state-export-keep N`.
   - Launch text setup writes, after the testnet add-on flags: `--bootstrap-peers "$(cat
     /etc/telcoin/bootstrap-peers.yaml)"` (path unquoted inside), then `--enable-state-export`, then
     `--state-export-keep N`. `tn_launch_flag_set "$file" --bootstrap-peers "\"\$(cat
     ${CONFIG_DIR}/bootstrap-peers.yaml)\""` therefore returns 1 (already so) on a setup-written
     wrapper. edit-config should update both keys when it changes the flags, so `.node-meta` and
     the launch line agree.
5. check-node: when the launch line has `--bootstrap-peers "$(cat F)"` and F is missing or empty, the
   node cannot start (v0.15.0: `--bootstrap-peers ""` fails with "EOF while parsing a value"); worth a
   FAIL. A `.node-meta` STATE_EXPORT that disagrees with the launch line means a hand edit.
6. Docs (README setup-node flags, OPERATOR.md; the partner guide only if it lists setup flags): add
   `--bootstrap-peers <file>` (YAML or JSON map keyed by BLS key, at most 64 KiB, installed as
   `/etc/telcoin/bootstrap-peers.yaml`, read at every start, v0.15.0-adiri+), `--enable-state-export`
   (v0.13.0-adiri+, every export kept), `--state-export-keep <n>` (1 to 999999, implies enable,
   v0.15.0-adiri+), `-h` / `--help`, the two `.node-meta` keys, and that a `--json` finalize reads the
   flags back from keygen.
7. UI: the helper sends none of these. If it does later: `--bootstrap-peers <absolute path the helper
   wrote>`, `--enable-state-export`, `--state-export-keep N` to keygen; finalize may leave them out.
   There is no way to drop keygen's recorded flags at finalize (no `--bootstrap-peers none` or
   `--no-state-export`); edit-config changes them after install.
8. Observation, pre-existing and outside this package: `create_directories` (lib/common.sh)
   `chown -R`s INSTALL_DIR and CONFIG_DIR to the service user, so that user can rename or replace
   entries in `/opt/telcoin` and `/etc/telcoin`. Root-run scripts write `.node-meta`,
   `bls-passphrase` and now `bootstrap-peers.yaml` there by path, and the docker start wrapper
   (root-owned, but in `/opt/telcoin`) runs as root (`User=root`). plan.md already lists the
   `.node-meta` part; root-owned 0755 directories (only the data and log dirs owned by the service
   user) would close it, after checking that nothing the node or UI writes lives there.

## Fix pass (V-CORE-1)

status: done. Findings from `tasks/ckpt-fu-V-CORE-1.md` (F-a, F-b, F-e, F-f, the prose note on the
config-dir error) plus the coordinator's header-comment item. setup-node.sh was committed as
16123b8; edited in place, version stays 1.3.0, lib/common.sh at 8185d00.

- [x] FX1. `bootstrap_peers_reason` deleted, so the binary is no longer run a second time; a rejected
      map stops setup with the library's one-line message from `tn_node_parse_check` (value shown as
      `'…'`, quoted strings in the reason as `"…"`) plus edit-config's guidance sentence: "The
      bootstrap peers map in SRC is not valid for <release> (MSG). Each key must be a node's BLS
      public key and each value the primary and workers entries from that node's node-info.yaml."
- [x] FX2. `peers_file_ok` refuses a file whose group or other read bit is clear (GNU `stat -L -c
      %a`, then BSD `stat -L -f %Lp`; `8#mode & 8#044`), with "FILE is mode 600: other users cannot
      read it. Setup accepts only a peers file that others can already read, because the installed
      copy is world-readable (0644) and the check passes the map on the command line of the node
      binary, where other users can see it. Run chmod 644 FILE first." Checked in init (before
      check_root), on the recorded file in a --json finalize, and on the source again in
      `install_bootstrap_peers` right before it is read (a keygen may build for 40 minutes in
      between). The temp copy is made 0644 at once, so the copy's own re-check passes. The map
      now reaches a node binary once per run: the parse check (keygen 1, finalize 1, interactive 1,
      a rejected map 1).
- [x] FX3. `json_require_root` replaces `check_root` in `run_json_mode`: `(check_root)` in a subshell
      first; exit 1 there means not root and becomes `setup_fail "setup-node.sh must run as root"`
      (error event, then done with the same msg); then the real `check_root`. Human mode unchanged.
      Only exit 1 counts as "not root" (check_root's contract), so the harness stub that exits 3 at
      the root check still reads as "reached check_root".
- [x] FX4. Firewall reminder lists every P2P port with one "and": "UDP 49590, 49594 and 49600";
      one worker unchanged ("UDP 41000 and 41004").
- [x] FX5. Config-dir error: "The custom config directory DIR cannot be used with --bootstrap-peers:
      the start wrapper reads the peers file through this path unquoted, so it may hold only
      letters, digits and . _ / + -. Choose another config directory, or leave --bootstrap-peers out."
- [x] FX6. Header `--rpc-public` row, the `public_rpc_no_domain_notice` comment and the parser comment
      now say Node Manager UI releases before 1.9.0 send `--rpc-public true|false` and never a
      domain, and 1.9.0 sends `--rpc-domain` when the operator picks Public and never
      `--rpc-public`. The header's `--bootstrap-peers` row adds "readable by other users (chmod 644)".
- [x] FX7. Tests (below).

### Operator-visible changes (fix pass)

- `--bootstrap-peers` refuses a file that its group or other users cannot read (0600, 0640, 0604,
  0400 refused; 0644, 0444, 0664, 0755 accepted), before check_root, saying why and giving the
  chmod. A recorded peers file chmod'ed to 0600 stops a --json finalize the same way.
- A rejected map's message no longer quotes any part of the map; it carries clap's reason with the
  value replaced by '…' and says what each key and value must be.
- A --json run as a non-root user ends with an `error` event "setup-node.sh must run as root" and a
  `done` carrying the same message (it used to be "setup exited early (rc=1)").
- The summary's firewall reminder reads "UDP 49590, 49594 and 49600" with several workers.
- A custom config directory with spaces or shell characters is named in the refusal, instead of
  the flag being blamed.

### Changelog text (replaces the paragraph above)

New node flags. `--bootstrap-peers FILE` gives the node a YAML or JSON map of the peers to dial at
start, keyed by BLS public key, in place of the genesis bootstrap servers. The file must be a
regular file of at most 64 KiB that other users can read: the map does not stay private, since the
installed copy is world-readable and the check runs it through the node binary's command line.
Setup checks the file before it touches the box, checks the map with the installed release's own
parser (a rejected map is reported with the parser's reason and without quoting the map), installs
it as `/etc/telcoin/bootstrap-peers.yaml` and has the start wrapper pass `--bootstrap-peers "$(cat
/etc/telcoin/bootstrap-peers.yaml)"`, so the host reads the file at each start.
`--enable-state-export` exports each epoch's execution state, and `--state-export-keep N` keeps
only the newest N exports; on its own it turns state export on and says so. Setup asks the
installed release whether it has each flag given and stops, before any key is made, when it does
not (`--enable-state-export` arrived in v0.13.0-adiri, the other two in v0.15.0-adiri). The choices
are recorded in `.node-meta` as `BOOTSTRAP_PEERS_FILE` and `STATE_EXPORT` (`off`, `unlimited` or a
number), and a `--json` finalize reads them back when its flags leave them out. `-h` / `--help`
prints the usage. A `--json` run without root now ends with an error event saying so, and the
closing firewall reminder lists every P2P port.

### Tests run (fix pass)

- `<scratchpad>/p4b-tests/`: `mk.sh` adds `gen/secret.yaml` (a rejected map full of distinctive
  strings: `SECRET0lOzzqx`, `xyzzy-marker-PEERS`, `distinctive-zq9`, `plugh-key-77`, `192.0.2.77`)
  and makes `fakebin/rec` log every call (`log.node`) so probe counts can be read for binary
  installs. `/bin/bash t_p4b.sh` (3.2.57): 523 passed, 0 failed. `bash t_p4b.sh` (5.3.15): 523
  passed, 0 failed. The sweep re-checked all 84 `--json` runs (JSON per line, one done, last).
- New rows: the secret map through docker and through the binary: rc 1, the redacted reason (`'…'`,
  `"…"`, "at line 2 column 1") in the error event and the done, none of the five strings anywhere
  in stdout or stderr (JSON and human), the map handed to a node binary exactly once, no keys, no
  install, no temp file. The map reaches a node binary once in a good keygen and once in its
  finalize (docker and binary), and once in the interactive run. Modes 600, 640, 604, 400 refused
  before check_root with the full message and no probe; 644, 444, 664, 755 pass; human mode; a
  recorded file at 0600 stops finalize (no wrapper, no probe); `install_bootstrap_peers` refuses a
  0600 source before any probe. Non-root, through the real script and library: keygen and
  finalize end with exactly `{"event":"error","msg":"setup-node.sh must run as root"}` then the
  done with that msg, rc 1, [ERROR] on stderr. Firewall reminder with one, two and three workers
  and with no node-info. Config dir with a space: the new message. The source re-check (65 KiB
  source) and, with a stubbed second check, the copy re-check (no temp left, no probe). Help: the
  UI wording, the stale claim gone from the file, the readability note. Static: no
  `bootstrap_peers_reason`, the map passed in one place only.
- P4a's harness (`p4a-tests/mk.sh` then `t_p4a.sh`): `/bin/bash` 699 passed, 2 failed; bash 699
  passed, 2 failed. Both failures are known: `fz-new-bin2` (stale HEAD baseline, as before) and
  `summary-two-workers` "firewall line", which pins the old "UDP 42000 and 42004, 42005"; the run
  prints "UDP 42000, 42004 and 42005", the F-b fix. The one-worker and no-node-info firewall rows
  pass unchanged.
- `/bin/bash -n` and `bash -n setup-node.sh`: clean. `shellcheck -x --severity=error`: clean
  (warning level: only the existing SC2034). `/bin/bash tools/check-bash32.sh setup-node.sh`:
  clean. Added lines: no bash-4 constructs, no apostrophe in `${…:-…}`, no `local x="$(…)"`, no
  line numbers or package names; no `--observer`/`--validator`.

### Open issues (fix pass)

1. P4a's harness `summary-two-workers` row should expect "Make sure inbound UDP 42000, 42004 and
   42005 are open" now (F-b), alongside the known `fz-new-bin2` fix.
2. Docs: the peers file must be readable by other users (chmod 644); a non-root `--json` run now
   reports "setup-node.sh must run as root".
3. Sidecar `setup-node.sh.sha256` to regenerate at commit; README changelog paragraph above.

## Fix pass 2 (free-text inputs)

status: done. Package C: free-text prompts and flags that land in the root-run start wrapper, the
unit or `.node-meta` were not validated (a metrics port `9101;id`). setup-node.sh was committed as
8c69378; edited in place, version stays 1.3.0.

- [x] FY1. Inventory of every `read -r` and every flag the helper builds from `TN_SETUP_*` (below)
- [x] FY2. Prompts ask again until valid: ports (`validate_port`), data/config/log/install
      directories (`validate_setup_path`: absolute, letters, digits and `. _ / -`, no `..`, the UI's
      own data-dir rule), docker image (`validate_docker_image`), binary path (`binary_path_ok`),
      execution address (`0x` + 40 hex); the region label from lib's add-on prompt is cut to the
      telemetry charset (letters, digits, `_ -`, 32), as lib/observability.sh does, with a warning
- [x] FY3. `init_node_inputs` (main, both modes, before check_root, `setup_fail`): `--data-dir`, the
      four multiaddr flags (`validate_multiaddr`), `--address`, `--passphrase-method`,
      `--service-user`/`--service-group` (`validate_service_name`); JSON keygen without `--address`
      fails by name; finalize's read-back of INSTALL_METHOD, DOCKER_IMAGE and BINARY_PATH from
      `.node-meta` gets the same checks; `check_binary_path` adds the charset rule
- [x] FY4. Tests (below)

### Inventory: what each input lands in and what it now checks

Prompts (`read -r`):

| Prompt | Lands in | Check now |
|---|---|---|
| Data directory (step 1) | wrapper `--datadir`/`-v`, unit `ReadWritePaths`, meta `DATA_DIR` | `prompt_setup_path` (new) |
| Install method menu, passphrase menu, RPC access choice | menu values only | unchanged |
| Docker image | wrapper image word, meta `DOCKER_IMAGE` | `validate_docker_image`, asked again (new); release floor as before |
| Binary path (existing) | wrapper `exec <path>`, meta `BINARY_PATH` | `binary_path_ok`: absolute, charset (new), executable; asked again (new) |
| P2P primary/worker, RPC, metrics ports | default multiaddrs, meta `RPC_PORT`/`METRICS_PORT`, wrapper `--metrics 127.0.0.1:<port>` | `prompt_port` = `validate_port`, asked again (new) |
| Config, log, install directories | wrapper (`-v`, TPM paths, peers path, its own location), unit (`ExecStart`, `StandardOutput`, `ReadWritePaths`) | `prompt_setup_path` (new) |
| Advertised node name | data dir `network-config` only | regex, invalid ignored (unchanged; lib checks again) |
| Public RPC domain, inbound public IP | validated already | unchanged (`validate_rpc_domain`, `validate_public_ip`) |
| Service user, group | unit `User=`/`Group=`, chown, meta | `validate_service_name` (unchanged) |
| Execution address | keytool argument, meta `VALIDATOR_ADDRESS` | `0x` + 40 hex, asked again (was "Proceeding anyway") |
| Public IP (when curl finds none) | multiaddr defaults, meta `PUBLIC_IP` | `prompt_with_validation validate_public_ip` (unchanged) |
| External primary/worker, listener primary/worker multiaddrs | keytool args / wrapper `-e "...=<addr>"` and `export`, unit `Environment=`, meta | `validate_multiaddr` loops (unchanged) |
| Internal IP | listener defaults | `validate_ipv4`/`validate_ipv6` (unchanged) |
| BLS passphrase, the "press Enter" prompts | passphrase file only / nothing | unchanged |
| Region label (lib `prompt_testnet_addons`) | meta `REGION` | cut to `[A-Za-z0-9_-]{1,32}` with a warning (new) |

Flags, including what the Node Manager UI helper (`cmd_setup`) builds from each `TN_SETUP_*`
(setup-node reads no `TN_SETUP_*` variable itself):

| Flag (`TN_SETUP_*`) | Check now |
|---|---|
| `--network` (NETWORK) | `json_set_network` (unchanged) |
| `--install-method` (INSTALL_METHOD) | `json_check_install_flags` (unchanged); meta read-back at finalize (new) |
| `--passphrase-method` (PASSPHRASE_METHOD) | loadcredential or tpm (new) |
| `--address` (ADDRESS) | `0x` + 40 hex when given (new); required at JSON keygen (new) |
| `--build-ref` (BUILD_REF) | release floor (unchanged); quoted git argument and build-info, not wrapper or meta |
| `--docker-image` (DOCKER_IMAGE) | `validate_docker_image` (unchanged); auto-detected and meta read-back images too (new) |
| `--external-primary`/`--external-worker` (EXT_PRIMARY/EXT_WORKER) | `validate_multiaddr` when given (new) |
| `--listener-primary`/`--listener-worker` (LIS_PRIMARY/LIS_WORKER) | `validate_multiaddr` when given (new) |
| `--public-ip` (PUBLIC_IP) | `validate_public_ip`; an invalid one is dropped with a warning (unchanged) |
| `--rpc-domain` (RPC_DOMAIN) | `validate_rpc_domain` (unchanged) |
| `--service-user`/`--service-group` (SERVICE_USER/GROUP) | `validate_service_name` (new for flags) |
| `--advertised-name` (ADVERTISED_NAME) | `write_advertised_name` skips an invalid name (unchanged) |
| `--data-dir` (DATA_DIR) | `validate_setup_path` (new) |
| `--binary-path` | absolute (unchanged) + charset (new) |
| `--rpc-http`, `--rpc-ws`, `--public-rpc-url`, `--public-ws-url`, `--bootstrap-peers`, `--state-export-keep` | unchanged (already checked) |
| `--genesis-dir` | quoted `cp` source only; unchanged |

There is no metrics-port (or other port) flag: a `--json` run uses the default ports, and the UI
sends none, so the JSON rows test the other flags.

### Tests run (fix pass 2)

- `<scratchpad>/p4b-tests/`: `/bin/bash t_p4b.sh` (3.2.57) 672 passed, 0 failed; `bash t_p4b.sh`
  (5.3.15) 672 passed, 0 failed; the sweep re-checked 108 `--json` runs.
- New rows: `prompt_port` refuses `9101;id`, 0, 70000, abc, `85 45` and keeps the default on
  Enter (read trims outer spaces, so ` 18545 ` is 18545); `prompt_setup_path` refuses `;`,
  relative, a space and `..`; the docker image prompt refuses `img;id` and an untagged name and
  pulls only the good image; the binary prompt refuses `;`, relative, a space and a missing file.
  Flags refused before check_root with the exact message: listener primary with `;id`, with a
  quote, a bad IP, port 70000; listener worker over tcp; external primary `$(id)`; external worker
  `/dns4`; data dir with `;id` and relative; address with `;id` and too short; passphrase method
  `tpm;id`; service user `telcoin;id`; service group `1telcoin`; human mode for the listener;
  good values (IPv6 `::` listener, tnsvc, /mnt/node-data, tpm) reach check_root with no error.
  JSON keygen without `--address`: named, no keys. Finalize with a bad `--address`: refused before
  `.node-meta` exists. `.node-meta` read-back: DOCKER_IMAGE `...;id`, BINARY_PATH `...;id` (source),
  INSTALL_METHOD `docker;id` refused, no wrapper. `--binary-path` with a space refused at keygen.
  Interactive end to end with metrics on: bad data dir, P2P port `9101;id`, address `0xnope` and a
  `;id` listener each asked again; region `us east;id` kept as `useastid`; no `;id` anywhere in the
  wrapper, unit or `.node-meta`; `--metrics 127.0.0.1:9101` and the good listener in the wrapper;
  `bash -n`. Good answers only, run once with HEAD's script and once with this one: wrapper, unit
  and `.node-meta` identical byte for byte (paths normalised).
- P4a's harness: `/bin/bash` 699 passed, 2 failed; bash 699 passed, 2 failed; the two failures are
  the known-stale `fz-new-bin2` and `summary-two-workers` "firewall line". Its interactive docker
  install still passes.
- `/bin/bash -n`, `bash -n`: clean. `shellcheck -x --severity=error`: clean (warning: only the
  existing SC2034). `/bin/bash tools/check-bash32.sh setup-node.sh`: clean. Added lines: no bash-4
  constructs, no apostrophe in `${…:-…}`, no `local x="$(…)"`, no line numbers or package names.

### Open issues (fix pass 2)

1. lib/common.sh `prompt_testnet_addons` reads the region label unchecked; setup-node now cuts it
   to the telemetry charset afterwards, but the prompt itself could ask again (lib's file).
2. `validate_port` accepts leading zeros (`0101` is read as octal 65 by its arithmetic test, and
   `09101` fails it); harmless for injection, but `^[1-9][0-9]{0,4}$` would be stricter (lib).
3. Docs: interactive prompts now ask again on a bad port, path, image, binary or address; a
   `--json` keygen needs `--address`; the region label is limited to letters, digits, `_` and `-`.

## Fix pass 3 (V-DOC)

status: done. setup-node.sh was committed as babb69d; edited in place, version stays 1.3.0.

- [x] FZ1. V-DOC finding 8. New `json_check_keygen_inputs`, called in `run_json_mode` after
      `json_check_install_flags` and before `json_require_root`: a `--json --phase=keygen` run
      without `--address` stops with `setup_fail "--address is missing: keygen needs the node's
      execution address (0x followed by 40 hex digits)."` before check_root, the preflight (a
      20-40 minute source build) and step 4. The same reasoning covers the other keygen inputs
      that step_generate_keys only checked late, so they moved too: each of the four multiaddr
      flags ("--listener-worker is missing: keygen needs all four multiaddrs (...)") and
      TN_BLS_PASSPHRASE ("TN_BLS_PASSPHRASE is not set: keygen takes the BLS key passphrase from
      that environment variable only."). Their form is still checked in init_node_inputs; the late
      checks in step_generate_keys stay as a safety net. Finalize needs none of them and is
      unchanged.
- [x] FZ2. V-DOC note 27: setup-node prints no floor wording of its own. The text "(v0.13.0 is the
      first with keytool set-rpc, proof-of-possession signing and state export)" is
      lib/common.sh `tn_ref_min_check`'s message, which `check_release_floor` relays as is.
      Reported, not edited. Suggested wording for lib: "(v${floor} is the first release that has
      all three: set-rpc and pop arrived in v0.12.0, state export in v0.13.0)".
- [x] FZ3. Tests (below).

### Tests run (fix pass 3)

- `<scratchpad>/p4b-tests/` (copies rebuilt with `mk.sh`): `/bin/bash t_p4b.sh` (3.2.57) 726
  passed, 0 failed; `bash t_p4b.sh` (5.3.15) 726 passed, 0 failed; the sweep re-checked 116
  `--json` runs.
- New rows, each proving with the recording check_root stub (it writes `check_root` to
  `BOX/calls`) that the run never got there, and with the shim logs that no preflight started (no
  docker, git or cargo call): a docker keygen without `--address` (error then done, both carrying
  the message, rc 1); a source keygen without `--address` (it used to build first); `--address ""`;
  a missing `--listener-worker`; a missing `--external-primary` on an existing install;
  TN_BLS_PASSPHRASE unset (`env -u`). A keygen with every input reaches check_root; a finalize
  with none of them reaches check_root with no error. The fix-pass-2 row `kg-no-address` now also
  asserts "before check_root" and "no docker call". Rows that must reach check_root pass the
  keygen inputs (`KG=(--address … four multiaddrs)` and TN_BLS_PASSPHRASE).
- Not asked, run to measure: P4a's harness now gives 675 passed, 26 failed under both bashes. 24 of
  the 26 are its seven `STOP_AT_ROOT=1 run --json` keygen call sites (rpc-domain-empty,
  privurl-json-1..7, puburl-json, privdomain-json, badip-json, binpath-docker, six floor rows),
  which prove that other checks "continue to check_root" without passing an address; they now
  stop earlier at "--address is missing" (rc 1, want 3), as intended. In a scratch copy with
  `TN_BLS_PASSPHRASE=secret … --address "$ADDR" "${MADDR[@]}"` added to those seven call sites the
  harness is back to 699 passed, 2 failed under both bashes (the two known-stale rows).
- `/bin/bash -n`, `bash -n`: clean. `shellcheck -x --severity=error`: clean (warning: only the
  existing SC2034). `/bin/bash tools/check-bash32.sh setup-node.sh`: clean. Added lines: no bash-4
  constructs, no apostrophe in `${…:-…}`, no line numbers or package names.

### Open issues (fix pass 3)

1. P4a's harness: add `TN_BLS_PASSPHRASE=secret` and `--address "$ADDR" "${MADDR[@]}"` to its seven
   `STOP_AT_ROOT=1 run --json` call sites (plus the two known-stale fixes).
2. lib/common.sh `tn_ref_min_check`: reword the floor message as in FZ2 (the library's text).
3. Docs: a `--json` keygen refuses up front when `--address`, a multiaddr or TN_BLS_PASSPHRASE is
   missing.
