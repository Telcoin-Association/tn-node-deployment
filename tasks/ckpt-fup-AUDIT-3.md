status: done

# ckpt-fup-AUDIT-3

## Sections
- [x] 0. Read specs, checkpoints, AGENTS sections, lessons, the baseline code and the fixture
- [x] 2. lib/common: atomic tn_host_baseline_install (prereqs before any write, rules written last, one teardown core shared with remove, tn_host_baseline_present) (465f0de; carries the one changed expectation of the existing fixture so the commit is green)
- [x] 1. remove-node: keep the baseline while another node unit remains (5ff3ff4)
- [x] 3. tests: host_baseline_test.sh cases for 1 and 2 (529dbcc; mutants: the old remove-node fails 16 checks, the old install body fails 16)

## Plan (section 0)
- lib: _tn_hb_rules_drop FN (the rules-file removal + augenrules --load / auditctl -W
  sequence, moved out of tn_host_baseline_remove unchanged); _tn_hb_teardown FN (rules drop,
  AIDE config + databases, every HOST_BASELINE line); tn_host_baseline_present (marker line or
  any file); remove = present || return 0, step, teardown, log.
- install order: prechecks (unchanged) -> apt + tools -> rules.d exists, /etc/aide and
  /var/lib/aide made, _tn_hb_db_dir_ok (all before any write) -> AIDE config write (a refusal
  returns with nothing of this run written) -> meta_set -> aide --init -> rules write ->
  augenrules --load (warning only) -> done. Any failure after the first write runs
  _tn_hb_teardown and one warning. A failed AIDE step therefore never touches the kernel's
  audit rules; a re-run over an earlier baseline that fails drops those rules (augenrules
  --load after removal).
- _tn_hb_aide_db: aide's last stderr line in the warning; the init warning no longer points at
  the config the unwind removes.
- remove-node stop_and_disable_service: teardown only when other_node_unit_files is empty, else
  rm_baseline_say log "Host baseline kept: another node unit remains here" when
  tn_host_baseline_present.
- [x] 4. Real-tool proof as root in ubuntu:24.04 (failed init leaves nothing; record below)
- [x] 5. Gates (all green, see Tests run)

## S4 record: real tools, root in ubuntu:24.04 (2026-11-03)

Script scratchpad AUDIT-3/real.sh, output real-ro.out and real-rerun.out. auditd 1:3.1.2-2.1ubuntu0.1,
aide 0.18.6-2ubuntu0.1, `apt-get install -y -q --no-install-recommends auditd aide` rc 0.
- ro: /var/lib/aide a read-only volume (root:root 755, passes the owner check), so the REAL
  aide --init fails: install rc 1, lines: step Installing, step Making the AIDE baseline,
  `warn AIDE: aide --init failed (rc 18): ERROR: /etc/aide/telcoin-node.conf:4: open (read/write)
  failed for file '/var/lib/aide/telcoin-node.db.new': Read-only file system (line: ...)`, then the
  undo warning. After: rules.d holds only audit.rules (no telcoin-node.rules), 0 telcoin lines in
  rules.d/*.rules + /etc/audit/audit.rules (augenrules never ran), `auditctl -l` rc 255 ("Error
  sending rule list data request (Operation not permitted)": no CAP_AUDIT_CONTROL in a container),
  /etc/aide and /var/lib/aide empty, 0 HOST_BASELINE lines, status `info  host baseline: off (...)`.
- rerun: a good install first (rc 0; rules 640, conf 600, db 600, /var/lib/aide 700, all root; 6
  telcoin lines: the rules file plus the 3 lines augenrules wrote into audit.rules; load warning,
  container), then a run with an `aide` wrapper that exits 8 on --init (the real aide otherwise):
  rc 1, `warn AIDE: aide --init failed (rc 8): ERROR: injected aide --init failure`, `warn augenrules
  --load failed: the node's audit watches stay loaded until the next boot.` (container: rc 4), the
  undo warning. After: no telcoin-node.rules, 0 telcoin lines in rules.d and audit.rules (augenrules
  regenerated audit.rules without them even though the kernel load failed), `auditctl -l` rc 255,
  /etc/aide and /var/lib/aide empty, 0 HOST_BASELINE lines, status off.

## Operator-visible changes
- remove-node: removing one node unit while another node unit stays on the host (legacy
  telcoin-validator + telcoin-observer, or any sibling unit file) no longer removes the host
  baseline; the run prints "Host baseline kept: another node unit remains here" (print_info in
  the menu, a log event in --json, every scope), only when some piece of a baseline is there. The
  baseline goes with the last node unit, as before ("Removing the host baseline ..." and "Host
  baseline removed. The auditd and aide packages stay installed; ...").
- setup-node --host-baseline: a failed install leaves nothing behind. All checks run before the
  first write; the AIDE config, HOST_BASELINE and the AIDE database come first and the audit
  rules (and augenrules --load) last, so a failed AIDE step never touches the kernel's rules.
  Any failure after the AIDE config is written takes the whole baseline away again (an earlier
  run's included) and warns: "The host baseline was not made. Its audit rules, AIDE config and
  database and the HOST_BASELINE line are removed, so no part of it is left; the auditd and aide
  packages stay installed."
- aide failure warnings now carry aide's own last stderr line: "AIDE: aide --init failed (rc N):
  <line>" (no command: the config is gone after the undo), "AIDE: aide --update failed (rc N):
  <line>; see: sudo aide --config=/etc/aide/telcoin-node.conf --update" (refresh, unchanged otherwise).

## Docs notes
- remove-node (OPERATOR/README host-baseline teardown): "The host baseline goes with the last node
  unit. While another node unit remains on the host, remove-node keeps it and prints: Host baseline
  kept: another node unit remains here" (--json: `{"event":"log","msg":"Host baseline kept: another
  node unit remains here"}`). Nothing is printed on a host without a baseline.
- "A failed --host-baseline install leaves nothing behind": no /etc/audit/rules.d/telcoin-node.rules,
  no /etc/aide/telcoin-node.conf, no /var/lib/aide/telcoin-node.db(.new), no HOST_BASELINE line; the
  auditd and aide packages and the /etc/aide (0755) and /var/lib/aide (0700) directories stay. This
  holds for a re-run too: a re-run that fails after its first write removes the earlier baseline as
  well (tn_host_audit then says "host baseline: off"). A run refused before any write (no apt-get, no
  node unit, the unit holds the passphrase, a path the files cannot name, no node keys, apt-get or a
  tool missing, no /etc/audit/rules.d, /etc/aide or /var/lib/aide not creatable, /var/lib/aide not
  root's alone, the AIDE config write refused) leaves the host as it was.
- Install order and lines: step "Installing auditd and aide (no recommended packages)", step "Making
  the AIDE baseline of the node's files", step "Writing the audit rules
  /etc/audit/rules.d/telcoin-node.rules", log "Audit rules loaded: ..." or the "did not load now ...
  auditd loads them at the next boot" warning, log "AIDE baseline made: /var/lib/aide/telcoin-node.db.
  Check the node's files against it with: sudo aide --config=/etc/aide/telcoin-node.conf --check".
- Replace the AUDIT docs note "set before aide --init so the baseline holds it, removed again if the
  init fails" with: HOST_BASELINE is set before aide --init (the baseline holds it); a failed init
  removes it with everything else.
- Replace the AUDIT note O-1 (interrupted install): a SIGTERM during aide --init now leaves
  HOST_BASELINE=true and the AIDE config, with no database and no audit rules; status warns "audit
  rules: ... is missing" and "AIDE baseline: ... is missing"; the next `sudo ./setup-node.sh
  --host-baseline` completes it.
- AUDIT checkpoint Open issue 9 (rules loaded without the marker after an AIDE failure) is closed.

## Tests run
- host_baseline_test.sh: bash 5.3 223 checks 0 fail 3 skip (not root); bash:3.2 232/0/1 and
  ubuntu:24.04 232/0/1 (root: the refusals use a directory owned by uid 65534).
- With remove_test, remove_addons_test, root_write_pipe_test, passphrase_print_test (5 files):
  bash 5.3 605 checks 0 failed 3 skip; bash:3.2 614/0/1; ubuntu:24.04 root 614/0/1.
- Mutants against the new fixture: HEAD's remove-node.sh fails 16 checks (every two-unit and --json
  kept case); HEAD's tn_host_baseline_install body on the new helpers fails 16 (order, every unwind
  case, config-refused). Each restored from a copy and compared (cmp) afterwards.
- Each commit green on its own: the fixture at 465f0de and 5ff3ff4 169/0/3 (bash 5.3).
- bash -n (5.3 and bash:3.2), tools/check-bash32.sh, shellcheck -x --severity=error 0.11 and
  koalaman/shellcheck:v0.9.0 on lib/common.sh, remove-node.sh, host_baseline_test.sh: clean.
  check-network-hits.sh rc 0; check-perl-interp on every tracked *.sh rc 0. Shellcheck at default
  severity: nothing in the changed lib region.
- Real tools: see the S4 record.
- Full suite bash 5.3: 61 files, 0 failed (5153 checks, 54 skip).

## Open issues
1. Design choice to confirm: the spec described checking the AIDE prerequisites before the rules and
   unwinding the rules after a later failure. The rules are now written and loaded last instead (after
   aide --init), so on a first install no failure path follows a load at all; the unwind
   (_tn_hb_install_undo -> _tn_hb_teardown -> _tn_hb_rules_drop, the helper tn_host_baseline_remove
   uses too) still runs for every failure after the first write, and it is what drops the rules a
   re-run over an earlier baseline finds loaded (fixture: "re-run, aide --init fails"; real tools:
   real-rerun.out). The fixture case "aide --init rc 8 after the rules were loaded" is therefore the
   re-run case; the first-install case asserts that augenrules never runs.
2. A failed re-run removes the earlier baseline too (before: HOST_BASELINE unset, rules/config/db
   left). Status said "off" in both; now the files agree with it. Restoring the earlier baseline
   instead would need copies of the rules, config and database; not done.
3. _tn_hb_rules_drop keeps the remove wording "augenrules --load failed: the node's audit watches stay
   loaded until the next boot." It also shows on a host where they never loaded (a container without
   CAP_AUDIT_CONTROL, where augenrules --load exits 4 and auditctl -l 255; it still rewrites
   /etc/audit/audit.rules without the lines). Accurate on a host whose rules are locked with -e 2.
   A refinement would warn only when auditctl -l lists telcoin-keys; left as it was (pure factoring).
4. Kept baseline on a two-unit host: the rules and the AIDE config name the unit (and DATA_DIR) the
   install resolved (tn_resolve_service: telcoin, else telcoin-validator, else telcoin-observer). When
   that is the unit removed, the kept baseline still names it: `aide --check` reports its unit file as
   removed and the telcoin-unit watch points at a missing file. `sudo ./setup-node.sh --host-baseline`
   rewrites both for the remaining node. On the legacy layout the marker sits in the first role
   .node-meta (node_meta_path); a keys-scope removal of that role removes /etc/telcoin/<role> and the
   marker with it, so status says "off" while the rules and AIDE files stay (the last-unit removal
   still takes them: tn_host_baseline_present checks the files too). DOCS may say: after removing one
   of two nodes, run `sudo ./setup-node.sh --host-baseline` again.
5. Sidecars: lib/common.sh and remove-node.sh changed after dc5a023 (scripts-v2.1.0 versions and
   checksums), so their .sha256 sidecars are stale until the orchestrator regenerates them (versions
   are already 2.1.0; not touched here).
6. Cherry-pick touch points: lib/common.sh: _tn_hb_aide_db (comment + body), the
   tn_host_baseline_install comment and its second half, new _tn_hb_install_undo after it, and the old
   tn_host_baseline_remove replaced by _tn_hb_rules_drop, _tn_hb_teardown, tn_host_baseline_present,
   tn_host_baseline_remove (after _tn_hb_unwatch). Nothing near tn_wait_restart_window (LIB-B).
   remove-node.sh: only the first block of stop_and_disable_service (FW edits remove_keys and the
   leftover path). tools/tests/host_baseline_test.sh: the aide stub, the writer stand-in, the install
   unwind block, the remove-node driver block after the --json teardown checks.
