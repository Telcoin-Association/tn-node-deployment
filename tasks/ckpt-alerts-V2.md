status: done

Re-check verifier V2 (issue #60, branch private-alerts, uncommitted tree). Confirms the F-A/F-B/F-C/F-D fixes against
tasks/spec-alerts-shared.md section 13, tasks/ckpt-alerts-V1.md and tasks/ckpt-alerts-V1d.md.

## Sections
- [x] R1 Gates
- [x] R2 Code fixes
- [x] R3 Docs vs final code (findings drafted below in R5 form)
- [x] R4 vm.d/P0-alerts.sh
- [x] R5 Findings

## R2 notes (code fixes)

- V1 W1 / V1d W-X1 CONFIRMED. lib/alerts.sh:708-727 `_alerts_enable_undo` runs `alerts_disable "" no-hint keep-meta`, then meta_set PREV only when the value differs, or meta_unset when the key was absent (alerts_enable reads it with meta_get, lib/alerts.sh:780-795). End-to-end as root (ubuntu:24.04, real setup-alerts.sh + real library, stub systemctl/runner "allfail", .node-meta with no ENABLE_ALERTS line), --json and plain: exit 1, done ok:false "No target accepted the test heartbeat; ...", .node-meta byte-identical, same inode, same mtime, no ENABLE_ALERTS line, no alerts file left. Script: scratchpad V2/e2e/w1.sh. Library test alerts_test.sh:686-737 asserts the same (cmp + zero .node-meta writes for absent, pending, false).
- V1 W2 CONFIRMED. lib/alerts.sh:1133-1162 (`-e && ! -r` at :1134) -> en=unreadable, ALERTS_ST_ENABLED="", line "Private alerts: unknown (run with sudo)", on from `systemctl is-enabled --quiet`; alerts.env line "alerts.env not compared with the node (run with sudo)". setup-alerts.sh:635 prints `sa_jstr` -> `"enabled":null`. End-to-end non-root (mode-000 .node-meta, ENABLE_ALERTS=true): enabled+active -> 0 on-only issues; enabled+inactive -> "not running" issue counted; not enabled -> no on-only issue; no timer unit -> the quiet line `Private alerts: off (enable them with setup-alerts.sh)` with `"enabled":null`. Script: V2/e2e/w2.sh. Side note: `"network":""` in every non-root done (NETWORK unreadable), not null.
- V1 W3 CONFIRMED. heartbeat_test.sh 187/0; M04 (586 -le) 1 fail, M21 (486 dropped) 2, M23 (647 else) 2, M63 (Observer dropped) 3: all killed (re-applied here, scratch V2/mut).
- V1 N3 CONFIRMED. lib/tn-heartbeat.sh:176-177 `*[?#]*` -> "healthchecks: a query string or fragment is not allowed"; mutant back to `*\?*` 2 fails.
- alerts_refresh / alerts_enable vs section 13 CONFIRMED (code + e2e V2/e2e/r2.sh as root): explicit values replace the stored ones, omitted keep them (`--refresh --stall-after 400` -> 120/400/900); derived only with --interval: `--refresh --interval 120` -> 120/360/900, `--enable --interval 120 --stall-after 400` -> inactive 900 (drops a stored 1200), `--refresh --interval 90 --inactive-after 2000` -> stall 270 (drops a stored 400). So with --interval every threshold NOT given is derived (stall from the interval, inactive from the stall in effect), never kept from alerts.env; without --interval a threshold not given keeps the stored one, so `--refresh --stall-after 1000` over a stored inactive 900 is refused: `Refused: --inactive-after must be a whole number of seconds from 1000 (the stall time) to 86400. Nothing was changed.` (exit 1). Two-item applied with msg "private alerts targets changed and refreshed" (targets + --label); targets alone -> ["alerts:targets-changed"], "private alerts targets changed". rc 2 -> exit 3: targets ok + restart fails -> both errors, done "The new targets are in place, but the new settings were not fully applied; run setup-alerts.sh --refresh with the same options again."; refresh restart fails -> exit 3 with the library's "The heartbeat timer did not restart ...". Advice line after an explicit --interval on --refresh and on an enabled --enable. `--refresh --interval 120` on an off node: exit 0, applied [], msg "private alerts are off; nothing to refresh" (the value is ignored silently). `--test --interval 60`: exit 1 "--interval goes with --enable or --refresh (the menu asks for the interval). Nothing was changed."
- alerts_require_lib CONFIRMED complete: every lib function setup-alerts.sh calls (outside the check) is listed except print_*/confirm (core) and tn_host_baseline_refresh (declare -F guarded); every common.sh helper lib/alerts.sh calls is listed too (incl. new meta_get, meta_unset).
- --help (setup-alerts.sh:16-50, usage() prints the header) CONFIRMED: describes the derived defaults, `--refresh` taking the four values, "with --interval a threshold not given follows the new interval as above", exit codes 0/1/2/3.

## R4 notes (tools/tests/vm.d/P0-alerts.sh vs final setup-alerts.sh)

Every assumption holds: `bash setup-alerts.sh --json --enable --targets-stdin --interval 30` from a pipe, as root, on a fresh
host goes through sa_timing (30/180/900, in range), the done event reaches stdout through fd 3 with "ok":true (now also
"interval":30) and exit 0; `kuma http://127.0.0.1:18080/api/push/vmtest1` passes (loopback http, 7-char token); the state's
`push_N=<kind> ok 200 <host>` and `last_status`/`last_reason` keys match the runner; the journal run line carries
`kuma@127.0.0.1:18080 ok 200` and no URL; the node-stopped run gives `service telcoin inactive (dead)`; `--json --disable`
exits 0, removes units, runner, /etc/telcoin/alerts and the state, and records ENABLE_ALERTS=false (keep-meta is only the
enable undo's). Nothing F-A changed touches these paths. Still unproven until the CI VM job runs it (as V1 said).

## Findings

No E. W 1, N 9. Owners: docs = OPERATOR/README (F-C files) or release note/guide (F-D files); code = F-A; repo hygiene = orchestrator.

### W

- W-D1 OPERATOR.md:1293 and README.md:488 (last clause of the "On a node whose alerts are on" sentence) vs setup-alerts.sh:463-479
  (`sa_timing_req`: with --interval it calls `sa_timing`, :434-457). "an `--interval` given alone sets both thresholds from it"
  implies that `--interval` plus one threshold keeps the other stored one; the code derives every threshold not given whenever
  --interval is given, and drops a stored custom one (e2e: stored stall 400, `--refresh --interval 90 --inactive-after 2000` ->
  stall 270; stored inactive 1200, `--enable --interval 120 --stall-after 400` -> inactive 900). Fix OPERATOR:1293: "A value you
  leave out keeps the one already set, except that with `--interval` each threshold you leave out follows the new interval as in
  an enable (360 and 900 seconds for an interval of 120), even one you set before; give it again to keep it." Fix README:488:
  replace "except that an `--interval` given alone sets both thresholds from it" with "except that with `--interval` a threshold
  left out is derived from the new interval as above, even a custom one".

### N

- N-D1 CHANGELOG/scripts-v2.1.0.md:362-364 and the guide mno-node-guide.md:1086 (and its :1680 row): "replace the stored values"
  / "the timer restarts with the new values" say nothing of the derivation in W-D1. Release note: after "with no disable in
  between" add "; with `--interval`, each threshold not given follows the new interval, as at an enable". Guide :1086: add "A
  threshold you do not give follows the new interval, as at the enable." (README.md:1799 changelog bullet: same clause, optional.)
- N-D2 refusal an operator can meet, undocumented: without --interval, a threshold not given keeps the stored one, so
  `--refresh --stall-after 1000` over a stored inactive 900 exits 1 with `Refused: --inactive-after must be a whole number of
  seconds from 1000 (the stall time) to 86400. Nothing was changed.` (lib/alerts.sh:952-976 + :271-289). Add to OPERATOR.md
  after :1293: "A threshold you give must fit the ones kept: a `--stall-after` above the inactive threshold already set is
  refused (`Refused: --inactive-after must be ... (the stall time) ...`); give `--inactive-after` with it." Release note
  Refusals table row: "| `Refused: --inactive-after must be a whole number of seconds from <N> (the stall time) to 86400` (or
  `--stall-after ... (the interval plus 30)`, `the interval must be ... from 30 to 3600`) | Give a value in range; with a new
  `--stall-after`, give `--inactive-after` too. Nothing was changed. |"
- N-D3 the exit-3 message of a targets change whose values did not apply (lib/alerts.sh:825, e2e confirmed) is in no doc:
  `The new targets are in place, but the new settings were not fully applied; run setup-alerts.sh --refresh with the same options
  again.` Add to OPERATOR.md:1295 (after "... `alerts:targets-changed` comes first in `applied`."): "If the targets changed but
  the values could not be applied, it exits 3 with `The new targets are in place, but the new settings were not fully applied;
  run setup-alerts.sh --refresh with the same options again.`" Release note Refusals row: "| `The new targets are in place, but
  the new settings were not fully applied` (exit 3) | Run `setup-alerts.sh --refresh` again with the same `--interval`,
  `--stall-after`, `--inactive-after` and `--label`. |"
- N-D4 status without root on a host with no timer unit prints the one quiet line `Private alerts: off (enable them with
  setup-alerts.sh)` (lib/alerts.sh:1133-1144; JSON still `"enabled":null`), not `unknown (run with sudo)`. OPERATOR.md:1333 says
  so ("on a host with the timer installed"); README.md:500 ("when it cannot read `.node-meta`, as without root, it says ..."),
  CHANGELOG/scripts-v2.1.0.md:369-372 and the guide :1680 ("without it, the setting shows as `unknown (run with sudo)`") do not.
  Fix: insert "on a host with the timer unit" in each (README: "when it cannot read `.node-meta`, as without root, on a host
  with the timer unit, it says ..."; guide: "without it, on a host with the timer installed, the setting shows as ..."). Side
  effect worth knowing (code, F-A, optional): ENABLE_ALERTS=pending with no timer reads "pending / Finish the setup" as root but
  the quiet "off" line without root.
- N-D5 OPERATOR.md:1332-1333: without sudo the status also prints `alerts.env not compared with the node (run with sudo)` and
  counts no alerts.env issue (lib/alerts.sh:1273-1274). Add after "... `last run not checked (run with sudo)`": "and `alerts.env
  not compared with the node (run with sudo)`".
- N-D6 OPERATOR.md:1296 / :1249: the script itself prints the monitor-advice line after an explicit --interval on an enabled node
  (setup-alerts.sh:697 for an enable, :749 for a refresh). Optional: :1249 "After an enable, or a run that changes the interval, the script says ...",
  and :1296 "The run prints the same `Set the monitor's heartbeat interval ...` line for the new interval."
- N-D7 CHANGELOG/scripts-v2.1.0.md:355 "(an `ENABLE_ALERTS` line the enable added is removed again)": no failed enable adds the
  line (ENABLE_ALERTS=true is written last, lib/alerts.sh:870), and the undo leaves the file unwritten (e2e: same inode and mtime). Fix:
  "(it is not even rewritten)".
- N-C1 setup-alerts.sh:227 (`sa_finish`, :221): a non-root `--json --status` prints `"network":""` (NETWORK unreadable), beside
  `"enabled":null`. Either `"network":$(sa_jstr "${NETWORK:-}")` (null when unknown; owner F-A, then setup_alerts_test.sh's
  non-root status case) or say in OPERATOR 7.3 that `network` is empty without root. Low impact.
- N-H1 repo hygiene (orchestrator): untracked empty files `no` and `nothing` at the repo root (mtime 17:09, during the fix round,
  not recreated by the test runs) and `docs/partner/build/` (Oct 30, outside the gitignored `docs/partner/<name>/build/`); delete
  before the commit. The guide PDF is not rebuilt yet (mno-node-guide.pdf Nov 3, .md Nov 4 17:02; plan.md:29 already lists it).
- N-T1 tools/tests/host_baseline_test.sh:882 and :893 (`rj | grep -q` with pipefail) failed 3 checks once under load (bash 5, three
  suites at once); three re-runs alone pass 223/0/3. Pre-existing lines, same class as followup.md:627; add them to that item.

## Gates

| Gate | Result |
|---|---|
| `bash tools/tests/run.sh` (host bash 5.3.9, run concurrently with the two containers) | 65 files, 2 failed: release_scripts_test.sh (92 checks, 41 failures, cascade of "not committed to git: lib/alerts.sh", expected) and host_baseline_test.sh (3 failures, lines 882/893 `rj \| grep -q` "done ok"); host_baseline re-run alone 3x: 223/0/3 each, a load flake (SIGPIPE under pipefail, same class as followup.md:627) |
| `bash:3.2` run.sh | 65 files, 0 failed |
| `ubuntu:24.04` run.sh (root) | 65 files, 0 failed |
| per file bash5 / 3.2 / ubuntu | alerts 279(3 skip)/271(2)/271(2); heartbeat 187/187/187; setup_alerts 209/204(5 skip)/204(5); setup_node_alerts 48 x3; remove 474 x3; remove_addons 34 x3; updater_manifest 192/188/188; addon_gates 67 x3; addon_oldlib 53 x3; host_baseline 223/232/232; check_node_hardening 30/45/50; all 0 failures (bar the two above) |
| `bash -n` bash 5 and bash 3.2 (15 files: 3 scripts + 12 new/changed tests) | clean |
| `tools/check-bash32.sh` same 15 | clean |
| `shellcheck -x --severity=error` (0.11.0) same 15 | clean; warning level on the 8 new files: only 9 x SC2034 in lib/alerts.sh (cross-file globals, as V1) |
| passphrase_print_test.sh | 4/4; its lint function run directly on setup-alerts.sh, lib/alerts.sh, lib/tn-heartbeat.sh: no hits (positive control flagged) |
| root_write_pipe_test.sh | 2/2 |
| check-network-hits.sh | clean, 146 hits, 27 files |
| check-perl-interp.sh on the 3 scripts | clean |
| ci_pins_test.sh | 53/53 |
