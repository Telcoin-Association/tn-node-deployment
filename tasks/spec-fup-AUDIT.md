# AUDIT: host baseline with auditd and AIDE (issue #43)

Read `tasks/spec-fup-shared.md` first. Worktree `~/coding/telcoin/tnd-fup-AUDIT`, branch
`fup/AUDIT`, checkpoint `tasks/ckpt-fup-AUDIT.md`.

## Goal

An operator can opt into a host integrity baseline at setup (`--host-baseline`): auditd
watches the key material and the node's configuration, AIDE keeps a baseline of the node's
installed files that the update paths refresh after a successful apply and that
`tn_host_audit` reports; remove-node tears it down.

## Owned files

`setup-node.sh` (the new flag, its JSON key and the step that calls the library; nothing
else), `lib/common.sh` (new functions `tn_host_baseline_install`, `tn_host_baseline_refresh`,
`tn_host_baseline_remove`, `tn_host_baseline_status`, placed right after `tn_host_audit`; and
the lines inside `tn_host_audit` that report them), `update-node.sh` and `edit-config.sh` (one
call each after a successful apply), `remove-node.sh` (one teardown call), new fixture
`tools/tests/host_baseline_test.sh`. LIB-A/LIB-B edit other functions of lib/common.sh and
setup-node.sh, KEYS edits edit-config's credential actions, OBS and KEYS touch remove-node:
add, do not reflow.

## Facts (main 1187ddb)

- `tn_host_audit` lib/common.sh:5967: read-only "ok|warn|info  text" lines (`_tn_audit_say`),
  rc 1 when anything warned; `LimitCORE` check :6032.
- `.node-meta` is written through `meta_set KEY VALUE` and read with `meta_get`; AGENTS.md
  "Ownership" says root-owned files go through `tn_write_root_file`.
- Node unit text carries `LimitCORE=0` (:3380, :3416). `DATA_DIR` holds `node-keys/`;
  `/etc/telcoin` holds `.node-meta`, `node.env`, the credential, `alloy/`; the scripts live
  under `/opt/telcoin` and the UI engine under `/opt/telcoin-ui-update`; the helper is in
  `/usr/local/libexec/telcoin`; the unit is `/etc/systemd/system/<SERVICE_NAME>.service`.
  Verify every path with grep (`create_directories`, `INSTALL_DIR`, `OPT_DIR`).
- `install_package` wraps apt; tests stub `apt-get` on PATH. Ubuntu 24.04 packages:
  `auditd` (rules in `/etc/audit/rules.d/*.rules`, loaded by `augenrules --load`) and `aide`
  (`/etc/aide/aide.conf.d/`, `aideinit` or `aide --init` → `/var/lib/aide/aide.db.new`, then
  `aide --update` and the rename to `aide.db`). The Ubuntu `aide` package reads
  `/etc/aide/aide.conf` and includes `/etc/aide/aide.conf.d/*`; its default config scans the
  whole system, which takes minutes: ship a drop-in that restricts the scan to the node paths
  (check how the Debian config selects directories; a `database_in`/`database_out` override
  may be needed, so test the real `aide` in `ubuntu:24.04` once, as root, to pin the exact
  invocation, then stub it in the fixture).
- `update-node.sh` and `edit-config.sh` have one "apply succeeded" point each (grep the
  post-update check / `done` event); `remove-node.sh` removes units and dirs through
  `_rm_shred_tree` and friends.

## Required behaviour

1. `setup-node.sh --host-baseline` (and JSON key `host_baseline: true`; the interactive run
   does not ask, default off): after the node is installed and running, calls
   `tn_host_baseline_install`. On a missing package manager or a failed install the step
   warns and setup continues (the node is already up); `.node-meta` gets `HOST_BASELINE=true`
   only when both tools are installed and the baseline exists.
2. `tn_host_baseline_install`: installs `auditd` and `aide`; writes
   `/etc/audit/rules.d/telcoin-node.rules` (root 0640, through `tn_write_root_file`): `-w
   <DATA_DIR>/node-keys -p rwxa -k telcoin-keys`, `-w /etc/telcoin -p wa -k telcoin-config`,
   `-w <unit path> -p wa -k telcoin-unit`; `augenrules --load`; writes the AIDE drop-in
   `/etc/aide/aide.conf.d/99_telcoin` covering `/opt/telcoin`, `/usr/local/libexec/telcoin`,
   `/etc/telcoin` (minus the credential and `alloy/ingest-token`, which rotate) and the unit;
   initialises the database; `meta_set HOST_BASELINE true`. Idempotent: a second run rewrites
   the same files and refreshes the baseline.
3. `tn_host_baseline_refresh`: when `HOST_BASELINE` is `true` and `aide` is present, run
   `aide --update` and move `aide.db.new` over `aide.db`; a failure is a warning, never a
   failed update. update-node (after the post-update check reports the apply as done, on
   every apply path including `--json`) and edit-config (after a successful restart) call it.
4. `tn_host_baseline_remove`: removes the rules file, reloads audit rules, removes the AIDE
   drop-in and the database files it created, clears the meta key; remove-node calls it
   before the directories go. Packages stay installed (say so in the message).
5. `tn_host_audit` gains lines: audit rules present/loaded (`auditctl -l` contains
   `telcoin-keys`), AIDE baseline present and its age, `HOST_BASELINE` marker; `info` when the
   marker is absent, `warn` when the marker is set and a piece is missing.

## Tests

`tools/tests/host_baseline_test.sh` with PATH stubs for `apt-get`, `augenrules`, `auditctl`,
`aide`, `aideinit`, `systemctl` that record argv and create the files the real tools would:
install writes the rules and drop-in with the right modes and paths and sets the marker;
refresh runs `aide --update` and renames; refresh without the marker does nothing; remove
clears everything; `tn_host_audit` reports each state; setup-node `--host-baseline` and JSON
`host_baseline` call install (stub the library function and assert the call); update-node's
and edit-config's hooks run only on success (drive the existing fixtures' apply stubs:
`update_guard_test.sh` and `edit_backup_test.sh` show how). Under bash 5.3, `bash:3.2`
(SKIP what needs GNU) and `ubuntu:24.04` as root (once with the real `aide` and `auditd`
packages installed in the container to prove the invocations: record the output in the
checkpoint, then keep the stubbed run as the fixture).

## Docs notes to hand over

The flag, JSON key, files written and their modes, the refresh points, the teardown, what
`tn_host_audit` reports, and the disk-encryption and `LimitCORE` statements already true
(OPERATOR/README "host audit" sections).
