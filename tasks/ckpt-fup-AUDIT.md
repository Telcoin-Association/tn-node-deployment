status: blocked (F4 handed back: budget)

## Sections
- [x] S0 pin the real auditd/AIDE invocations in ubuntu:24.04 (record below)
- [x] S1 lib/common: tn_host_baseline_install/_refresh/_remove/_status after tn_host_audit, plus tn_host_audit report lines (commit 56d433d)
- [x] S2 setup-node: --host-baseline flag and JSON host_baseline key, step after the node is up (4860ea9)
- [x] S3 update-node + edit-config: refresh hook after a successful apply (c069227)
- [x] S4 remove-node: teardown call before the directories go (547b246)
- [x] S5 tests: tools/tests/host_baseline_test.sh (c28ce77)
- [x] S6 gates (bash 5.3, bash 3.2, ubuntu:24.04 root, bash -n x2, check-bash32, shellcheck 0.11 + 0.9.0, lints, full suite)

## Follow-up round (coordinator message after V2)
- [x] F0 cherry-picked c4322d4 c11099b 1a7f7a0 (now c4608d5 def8593 2b1ffef)
- [x] F1 lib/common: rc 2 HOST_BASELINE (items 1), unreadable .node-meta (2), /var/lib/aide ownership (4), remove without augenrules (6) (f64a29f, 29eec08)
- [x] F2 edit-config: restart_node refresh (3) (df159b6)
- [x] F3 remove-node: JSON-aware printer for the teardown (5) (323c79b)
- [ ] F4 add-ons: refresh on success in install-caddy, firewall-setup, setup-vpn, setup-observability (7) -- NOT DONE, handed back (agent budget); notes under Open issues 8
- [x] F5 setup-node: tn_host_baseline_install in tn_require_fns (8) (096d6b2; appended to the `tn_committee_down_guard ... tn_service_user_can_run` line, which ac9a605 does not touch, so ac9a605's `tn_mainnet_enabled` on the next line merges cleanly)
- [x] F6 tests: fixture cases for 1-6, 8 (9d4f40b, 67e8266)
- [x] F7 gates + real-tool run (item 4) + docs-notes corrections (9)

## S0 record: real tools in ubuntu:24.04 (2026-11-03, root in `docker run ubuntu:24.04`)

Scripts and full output: scratchpad AUDIT/pin{1,2,3,4}.sh and .out.

Packages: auditd 1:3.1.2-2.1ubuntu0.1, aide 0.18.6-2ubuntu0.1 (+ aide-common with recommends).
- `apt-get install -s -y auditd aide` (recommends on) pulls ~70 packages INCLUDING `postfix`,
  `bsd-mailx`, `cron`, `aide-common` (aide-common enables `dailyaidecheck.timer`, a daily
  full-system check as `_aide`). `apt-get install -s -y --no-install-recommends auditd aide`
  pulls only `libauparse0t64 auditd libmhash2 aide`. => install with --no-install-recommends.
- no-recommends layout: `/usr/bin/aide` only; NO `/etc/aide`, NO `/var/lib/aide`, no `aideinit`
  (aideinit is aide-common's, `/usr/sbin/aideinit`). `/etc/audit/rules.d` root:root 0750 exists
  (auditd), `/etc/audit` root:root 0750.
- Debian `/etc/aide/aide.conf` (aide-common): `database_in=file:/var/lib/aide/aide.db`,
  `database_out=file:/var/lib/aide/aide.db.new`, `@@x_include /etc/aide/aide.conf.d ^[a-zA-Z0-9_-]+$`;
  `aide.conf.d/99_aide_root` selects `/` (the whole system). A drop-in in aide.conf.d therefore
  ADDS to a whole-system scan and cannot restrict it. => own config file outside aide.conf.d.
- Own config `/etc/aide/telcoin-node.conf` (database_in/out = /var/lib/aide/telcoin-node.db[.new],
  gzip_dbout=no, report_url=stdout, anchored rules `/opt/telcoin(/|$) G`, `=/etc/systemd/system/telcoin\.service$ G`,
  `!/etc/telcoin/bls-passphrase\.cred(\.new)?$`, `!/etc/telcoin/alloy/ingest-token$`):
  `aide --config=FILE --config-check` rc 0; `aide --config=FILE --init` rc 0, real 0m0.005s,
  11 entries, writes `telcoin-node.db.new` root 0600; unanchored `/opt/telcoin` would also match
  `/opt/telcoin-source` (the cargo tree) and `/opt/telcoin-ui*`: anchored form excludes them (verified).
- `mv -f -T db.new db`; `aide --config=FILE --check`: rc 0 clean ("AIDE found NO differences"),
  rc 4 changed, rc 5 added+changed (bits 1 added, 2 removed, 4 changed); excluded files never listed.
- `aide --config=FILE --update`: rc 0 nothing changed / rc 5 with changes, writes db.new either way
  (rc 1-7 = success with differences). Without database_in: rc 18 ("open (read-only) failed for
  file '/var/lib/aide/telcoin-node.db'") for both --check and --update, and --update LEAVES a
  197-byte partial `telcoin-node.db.new` => refresh removes db.new on failure, never renames it.
- `-c FILE` form also works; db header line `# Time of generation was 2026-11-03 17:35:24`.
- auditd: rules file `/etc/audit/rules.d/telcoin-node.rules` (root 0640 like audit.rules);
  `augenrules --check` rc 0 "Rules have changed and should be updated"; `augenrules --load` in the
  container rc 4 "You must be root to run this program." (no CAP_AUDIT_CONTROL; it still rewrote
  /etc/audit/audit.rules with the three -w lines after -D/-b/-f/--backlog_wait_time);
  `auditctl -l` rc 255 "Error sending rule list data request (Operation not permitted)";
  `auditctl -R file` rc 4. => load failure is a warning (rules load at boot), not fatal.
- `/var/lib/aide` is `_aide:root 0700` when aide-common is installed (tn_root_dir_ok refuses it);
  with no-recommends it does not exist and the library creates it root:root 0700.

## Operator-visible changes
- New `setup-node.sh --host-baseline` (off by default, never asked). After the node is installed and after
  public RPC and the testnet add-ons, setup installs `auditd` and `aide` (apt-get `--no-install-recommends`),
  writes and loads the audit rules, writes the node's own AIDE config, records `HOST_BASELINE=true` and makes the
  AIDE database. A failure warns ("The host baseline was not made (see above); the node runs without it. Try again
  with: sudo ./setup-node.sh --host-baseline") and setup goes on.
- On a host whose node is installed, `sudo ./setup-node.sh --host-baseline` alone (not --json) makes the baseline,
  or makes it again, and changes nothing else (prints: "A node is installed here, so --host-baseline makes the host
  baseline and changes nothing else. To run the whole setup again, leave --host-baseline out."). rc 0/1.
- `--json --phase=finalize --host-baseline`: the done event carries `"host_baseline":true|false` (false when not
  asked or failed); a failure also sends `{"event":"log","msg":"WARNING: The host baseline was not made ..."}`.
  keygen ignores the flag.
- update-node (every verified apply: docker/source/release, interactive and --json) and edit-config (`--set` after a
  healthy restart; menu edits after "Node restarted successfully") run `aide --update` and move the new database
  into place when HOST_BASELINE=true; warnings are events in --json mode, before the done event; never fails the apply.
- remove-node removes the baseline whenever it removes the node unit (menu, --json any scope, leftovers):
  "Host baseline removed. The auditd and aide packages stay installed; remove them with: sudo apt-get purge auditd aide".
- `setup-node.sh --audit` / `check-node.sh --audit` (tn_host_audit) print the host-baseline lines (below).

## Docs notes
- Flag: `--host-baseline` (setup-node.sh). JSON: finalize done event key `host_baseline` (boolean). .node-meta key
  `HOST_BASELINE=true` (set only when everything is in place; set before `aide --init` so the baseline holds it,
  removed again if the init fails).
- Packages: `auditd`, `aide` via `apt-get install -y -q --no-install-recommends auditd aide` (retry once after
  `apt-get update -q`). Without --no-install-recommends Ubuntu 24.04 pulls aide-common (daily whole-system
  `dailyaidecheck.timer`), bsd-mailx and postfix. apt-get only (Ubuntu/Debian); elsewhere: warning, nothing installed.
- Files and modes:
  - `/etc/audit/rules.d/telcoin-node.rules` root:root 0640 (tn_write_root_file), loaded with `augenrules --load`:
    `-w <DATA_DIR>/node-keys -p rwxa -k telcoin-keys`, `-w /etc/telcoin -p wa -k telcoin-config`,
    `-w /etc/systemd/system/<service>.service -p wa -k telcoin-unit`. Search events: `sudo ausearch -k telcoin-keys`.
    A load that fails (no kernel audit, e.g. containers; rules locked with `-e 2`) is a warning: auditd loads the file at boot.
  - `/etc/aide/telcoin-node.conf` root:root 0600: its own `database_in=file:/var/lib/aide/telcoin-node.db`,
    `database_out=file:/var/lib/aide/telcoin-node.db.new`, attributes `p+u+g+ftype+n+s+l+sha256+sha512`, anchored
    rules for `/opt/telcoin`, `/usr/local/libexec/telcoin`, `/etc/telcoin`, the unit, and the node binary when
    BINARY_PATH is outside /opt/telcoin; leaves out `bls-passphrase`, `bls-passphrase.cred` (and `.new`),
    `alloy/ingest-token`, the root writers' `.tn.*` temp files. It is NOT in /etc/aide/aide.conf.d, so a
    system-wide AIDE setup never reads it.
  - `/var/lib/aide/telcoin-node.db` root 0600 (written by aide). `/etc/aide` (0755) and `/var/lib/aide` (0700) are
    created root-owned when absent and stay on removal.
  - Check by hand: `sudo aide --config=/etc/aide/telcoin-node.conf --check` (rc 0 clean, 1-7 differences).
- Refresh points: update-node after each verified apply (before "Update complete" / the done event); edit-config after
  a `--set` restart came back healthy, after a menu edit's restart came back active, after the menu item "Restart node"
  came back active (df159b6: folds in an edit saved with "restart later"), and after a credential action
  (--migrate-credential, --reseal, menu 5 passphrase) whose edit_cred_report rc is 0 (c4322d4; not on a refused
  verify or rc 2/3). Not after: failed verify, rollback, committee refusal, the add-ons (see Open issues 8).
- Teardown: remove-node, with the node unit, before the data/config dirs: rules file removed + `augenrules --load`
  (without augenrules: each watch dropped with `auditctl -W <same fields>`, never `auditctl -D`; if that fails, a
  warning that the watches stay loaded until the next boot), AIDE config and both databases removed, every
  HOST_BASELINE line removed; packages stay. In `remove-node.sh --json` the step, log ("...packages stay installed;
  remove them with: sudo apt-get purge auditd aide") and warn lines are JSON events before the done event (323c79b).
- /var/lib/aide must be root-owned and not group/other-writable (tn_root_dir_ok) and the database files absent or
  regular root-owned files; aide-common's `_aide:root 0700` is refused before anything is written: "AIDE: /var/lib/aide
  is not a directory owned and writable by root alone (aide-common makes it _aide:root, so the _aide account could
  replace the baseline); the baseline was not made. Give it to root (sudo chown root:root /var/lib/aide) or purge
  aide-common, then run: sudo ./setup-node.sh --host-baseline". The same check runs before every refresh (warning).
- Interrupted install (O-1): a SIGTERM during `aide --init` leaves HOST_BASELINE=true, the rules file and the AIDE
  config with no database; status warns "AIDE baseline: ... is missing; make it again" and refresh warns; the next
  `sudo ./setup-node.sh --host-baseline` completes it.
- Duplicated marker: status `warn  host baseline: HOST_BASELINE is set more than once in .node-meta; keep one
  HOST_BASELINE=true line, then run: sudo ./setup-node.sh --host-baseline` (rc 1); refresh warns and does nothing.
- Unreadable .node-meta (--audit without sudo): `info  host baseline: not checked (.node-meta is readable by root only)`.
- Exclusions unchanged: bls-passphrase, bls-passphrase.cred (+ .new), alloy/ingest-token (OBS keeps the token there;
  real-tool run: a rotated ingest-token gives `aide --check` rc 0), .tn.* temp files.
- tn_host_audit lines (`tn_host_baseline_status`):
  - no marker: `info  host baseline: off (sudo ./setup-node.sh --host-baseline adds auditd watches and an AIDE baseline)`
  - `ok    host baseline: HOST_BASELINE=true in .node-meta`
  - `ok    audit rules: /etc/audit/rules.d/telcoin-node.rules` | `warn  audit rules: ... is missing; make it again: sudo ./setup-node.sh --host-baseline`
  - `ok    audit rules loaded (auditctl -l lists telcoin-keys)` | `warn  audit rules not loaded (...): sudo augenrules --load, and check that auditd runs` | non-root: `info  audit rules loaded: not checked (auditctl -l needs root)`
  - `warn  AIDE: aide is not installed; ...` / `warn  AIDE: /etc/aide/telcoin-node.conf is missing; ...`
  - `ok    AIDE baseline: /var/lib/aide/telcoin-node.db, made N day(s) ago (check: sudo aide --config=/etc/aide/telcoin-node.conf --check)` | `warn  ... is missing; ...` | non-root: `info  AIDE baseline: not checked (/var/lib/aide is readable by root only)`
  - any warn makes tn_host_audit rc 1. Already true before this round (unchanged): the dm-crypt line per data/config
    dir (ok when on dm-crypt, info otherwise: "cloud disk encryption is not visible from the host"), `<svc>: core
    dumps off (LimitCORE=0)` (the unit carries LimitCORE=0), fs.suid_dumpable, kernel.core_pattern, ptrace_scope.
- Refusals (warning, rc 1, no marker): no apt-get; no node unit; unit holds TN_BLS_PASSPHRASE ("move it first with:
  sudo ./edit-config.sh --migrate-credential"); DATA_DIR set twice; a path outside [A-Za-z0-9._/-]; no
  `<DATA_DIR>/node-keys`; failed install/write/`aide --init`; a symlink at the database path.

## Tests run
- S0 real tools (ubuntu:24.04 root): see the S0 record. Library end to end against the real auditd 3.1.2 + aide
  0.18.6 (scratchpad AUDIT/real.sh/.out): install rc 0 (load warning in the container), only aide+auditd installed
  (no aide-common, no postfix), modes rules 640 / conf 600 / db 600 / dirs 755,700 root:root, baseline 7 entries
  (credential and /opt/telcoin-source not in it), check rc 0; after a change check rc 4 lists tn-start only (rotated
  credential not listed); refresh rc 0 then check rc 0; status rc 1 (rules not loaded, container); remove rc 0, no
  telcoin files left, marker gone, status back to info.
- `bash tools/tests/run.sh tools/tests/host_baseline_test.sh`: bash 5.3 112 checks 0 fail 1 skip (not root);
  ubuntu:24.04 root 114/0/0; bash:3.2 114/0/0.
- Touched-script fixtures (host_baseline, remove, remove_addons, update_guard, pending_state, rollback_hash,
  storage_migration, edit_backup, edit_passphrase, setup_release, finalize_inputs, setup_passphrase,
  check_node_hardening, credential, lib_skew, addon_oldlib, root_write_pipe, passphrase_print): bash:3.2 18 files
  0 failed (1266 checks, 30 skip); ubuntu:24.04 18 files 0 failed (1416 checks, 6 skip).
- Full suite `bash tools/tests/run.sh` bash 5.3: 60 files, 0 failed (3809 checks, 50 skip).
- `bash -n` bash 5.3 and bash:3.2 on lib/common.sh setup-node.sh update-node.sh edit-config.sh remove-node.sh
  tools/tests/host_baseline_test.sh: clean. `tools/check-bash32.sh` on the six: clean. shellcheck 0.11 and
  koalaman/shellcheck:v0.9.0 `-x --severity=error`: clean. root_write_pipe + passphrase_print: pass.
  check-perl-interp on every tracked *.sh: rc 0.

## Tests run (follow-up round)
- host_baseline_test.sh: bash 5.3 124 checks 0 fail 3 skip (not root); ubuntu:24.04 root 133/0/1 (unreadable-meta case
  skipped as root); bash:3.2 133/0/1.
- Touched-script fixtures (host_baseline, remove, remove_addons, edit_backup, edit_passphrase, setup_release,
  finalize_inputs, setup_passphrase, lib_skew, credential, check_node_hardening, addon_oldlib, update_guard,
  root_write_pipe, passphrase_print): bash:3.2 15 files 0 failed (1091 checks, 17 skip); ubuntu:24.04 15/0 (1149, 7 skip).
- Full suite bash 5.3: 60 files 0 failed (3822 checks, 52 skip) (before 29eec08; host_baseline re-run after it on all three).
- bash -n 5.3 + 3.2, check-bash32, shellcheck 0.11 and v0.9.0 error level: clean on lib/common.sh setup-node.sh
  edit-config.sh remove-node.sh host_baseline_test.sh; root_write_pipe + passphrase_print pass.
- Real tools as root (scratchpad AUDIT/real2.sh): aide-common installed -> /var/lib/aide `_aide:root 700` -> install
  rc 1 with the message, no marker, nothing in /var/lib/aide; after chown root:root install rc 0, 9 entries (ingest-token
  not among them), rotating ingest-token leaves `--check` rc 0; chown back to _aide -> refresh warns and keeps the old database.

## Open issues
1. Spec wrong: AIDE drop-in `/etc/aide/aide.conf.d/99_telcoin`. Debian aide.conf includes aide.conf.d and
   `99_aide_root` selects `/`: a drop-in only adds to a whole-system scan; and with --no-install-recommends
   aide-common (and /etc/aide) is not installed at all. Implemented: own config /etc/aide/telcoin-node.conf + own
   database /var/lib/aide/telcoin-node.db. `aideinit` (aide-common, whole-system) is never used.
2. Spec wrong: "the scripts live under /opt/telcoin". /opt/telcoin holds the node binary and
   telcoin-network.version; the scripts are the operator's clone (~/telcoin-node-scripts, install.sh), not
   root-owned, changed by update-scripts.sh; not in the baseline. /opt/telcoin-ui-update not covered either (not in
   the required list). Follow-up if wanted.
3. "JSON key host_baseline": setup-node --json takes flags; implemented as the flag in finalize plus the done-event
   key. ui/telcoin-ui-helper.sh `cmd_setup` (LIB-A/UI-S) does not pass --host-baseline; a UI toggle is a follow-up.
4. Beyond spec, for the orchestrator to confirm: `setup-node.sh --host-baseline` alone on an installed node runs
   the baseline only (so existing nodes can opt in and the status remedies name a light command).
5. KEYS-owned credential actions (edit_migrate_credential, edit_reseal, edit_bls_passphrase) rewrite the
   unit/start script/.node-meta through _tn_cred_switch and do not refresh. Text for KEYS: after a `_tn_cred_switch`
   that returned 0, call `edit_baseline_refresh` (defined in edit-config.sh by this package).
6. Add-ons (install-caddy, firewall-setup, setup-vpn, setup-observability) write /etc/telcoin/.node-meta and
   /etc/telcoin/alloy/* outside the refresh points: AIDE reports those until the next update/edit refresh (or a
   `--host-baseline` run). Nothing runs `aide --check` on a schedule. Both follow-ups; DOCS should say so.
7. Cherry-pick touch points: setup-node finalize `json_done` line gained `"host_baseline":${hb},` before `"msg"`
   (and `local v` became `local v hb=false`); tn_host_audit gained one line before `unset -f _tn_audit_say` and two
   comment lines; update-node: 4 one-line `update_baseline_refresh` inserts + function before update_quorum_guard;
   edit-config: 2 inserts + function before edit_epoch_wait; remove-node: 4 lines at the top of
   stop_and_disable_service. No version bumps, no sidecars.
8. F4 (item 7) NOT DONE, for a fresh agent: add one guarded `tn_host_baseline_refresh <say-fn>` call
   (`if declare -F tn_host_baseline_refresh >/dev/null 2>&1; then ...; fi`) on the success path of install-caddy.sh,
   firewall-setup.sh, setup-vpn.sh and setup-observability.sh, plus driver checks in host_baseline_test.sh in the
   update-node driver style. Found so far: each takes the lock through addon_meta_write_begin / addon_meta_lock
   (lib/common.sh ~8170-8200) and has several success points: install-caddy json_done ok:true at ~2801, 2810, 2831,
   2841 (dashboard enable/disable, rpc enable/disable) and its menu; setup-observability json_done ok:true ~635 and
   menu actions ~206-340 (each after addon_meta_write_begin); setup-vpn writes at ~1136 and ~1195; firewall-setup's
   write at ~1067 (apply_recommended_firewall). A single call per script may need to sit in a common "after the
   write" helper of each script, or in the EXIT path gated on success; the library has no addon_meta_write_end today.
   Keep `alloy/ingest-token` excluded.
9. The install still writes and loads the audit rules before the AIDE step; a later AIDE failure (aide --init error,
   or a /var/lib/aide made foreign between the early check and the init) leaves the rules file (watches loaded) without
   the marker: status says "off" and remove-node removes it. The next --host-baseline run completes it.
