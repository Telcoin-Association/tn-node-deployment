status: done

Package A1b (issue #60, branch private-alerts). Spec: tasks/spec-alerts-A1b.md; shared: tasks/spec-alerts-shared.md.

## Sections
- [x] S0 read the shared spec and the referenced helpers; file header
- [x] S1 paths and say
- [x] S2 validate, write targets, rpc url, env, runner, unit texts, write units
- [x] S3 test, enable, set_targets, refresh, disable, status
- [x] S4 common.sh source block
- [x] S5 tools/tests/alerts_test.sh
- [x] S6 tools/tests/vm.d/P0-alerts.sh
- [x] S7 gates

Coordinator adjustments applied (section 13 of the shared spec): the rollback of a failed fresh
enable writes back the ENABLE_ALERTS value read at the start; the quiet one-line status when off;
`.tn.*` temp copies shredded before the rmdir in alerts_disable; hb_target_normalize called
directly (HB_URL / HB_ERR), never in `$( )`.

## Operator-visible changes
- New library lib/alerts.sh (ALERTS_VERSION 2.1.0), sourced at the end of lib/common.sh by a
  guarded if/fi block after the observability block. COMMON_VERSION unchanged.
- What an enable installs: /etc/telcoin/alerts (root 0755), targets (root 0600), alerts.env
  (root 0644), /usr/local/libexec/telcoin/tn-heartbeat (root 0755), telcoin-heartbeat.service
  and .timer (root 0644); ENABLE_ALERTS=true in .node-meta. The runner's state lives in
  /var/lib/private/telcoin-heartbeat (the dynamic user's StateDirectory).
- Nothing in the library stops or restarts the node; every success message says "The node was
  not restarted."

## Docs notes
Defaults and ranges: interval 60 s (30-3600); stall 180 s (from interval + 30 to 86400);
inactive 900 s (from stall to 86400); restart grace 120 s (no flag); health port = the port of
--healthcheck on the node command, else 43174. Label: --label (1-64 of A-Z a-z 0-9 . _ -,
starting with a letter or digit), else the host name filtered to those characters, leading
punctuation dropped, cut to 64, else "node". A data dir outside /var/lib/telcoin is added to
InaccessiblePaths=; one holding characters other than letters, digits and . _ / - is left out.
The RPC URL: --http.addr (absent or 0.0.0.0 -> 127.0.0.1, :: -> [::1], other IPv6 bracketed)
and --http.port (absent -> RPC_PORT of .node-meta, else 8545).

Messages (exact):
- Enable refusals, each ends "Nothing was changed.":
  "Private alerts are set up as root (sudo). Nothing was changed."
  "There is no .node-meta on this host, so there is no node to watch. Nothing was changed."
  "No node service is installed on this host (telcoin.service). Nothing was changed."
  "The node command has no --http, so the runner cannot read the local RPC; add it with edit-config.sh and run this again. Nothing was changed."
  "The node's launch file cannot be read, or its --http.addr is not a plain address, so the runner cannot find the local RPC. Nothing was changed."
  "Private alerts need systemd 247 or later (LoadCredential=); this host runs <N>. Nothing was changed."
  "ENABLE_ALERTS is set more than once in .node-meta; remove the extra lines and run this again. Nothing was changed."
  "Refused: <reason>. Nothing was changed." (reason: a timing, label or target-line error; a target is named kind@host only, e.g. "line 2 (kuma@kuma.example.org): kuma: not an /api/push/<token> URL")
  "No targets were given: pass at least one '<kind> <url>' line. Nothing was changed."
- Enable: "Enabling private alerts" (step), "Sending a test heartbeat" (step), per target
  "Target <n> <kind>@<host>: accepted (<code>)" / "Target <n> <kind>@<host>: failed (<code> [why])",
  "The node reads as <up|down>: <reason>", then "Private alerts enabled: telcoin-heartbeat.timer
  sends a heartbeat every <N> s. The node was not restarted."
  Failure: "No target accepted the test heartbeat; private alerts were not enabled. Check the
  URLs and run this again." No recorded run: "The heartbeat runner recorded no run just now; see
  what it said with: journalctl -u telcoin-heartbeat -n 20". A failed write: "Private alerts were
  not enabled: <reason>. The files written for them were removed."
- A failed fresh enable removes every file it wrote and puts ENABLE_ALERTS back to the value it
  read at the start (pending stays pending; absent becomes false). Only an operator's disable
  records false.
- Change targets: "Changing the private alerts targets" (step); "Targets changed; the next
  heartbeats go to the new targets."; "No target accepted the test heartbeat; the previous
  targets were put back." (byte for byte); refused when not set up: "Private alerts are not set
  up on this host; enable them first. Nothing was changed."
- Refresh: "Private alerts are off; nothing to refresh." / "Refreshing private alerts (runner,
  settings, units)" (step) / "Private alerts refreshed: runner <v>, every <N> s. The node was not
  restarted." It keeps the interval, stall, inactive and label alerts.env holds (defaults when
  they are missing or out of range, with a warning) and reads the service, RPC URL and health
  port again.
- Disable: "Disabling private alerts" (step), "Private alerts disabled: the heartbeat timer, its
  service, the runner and its files are removed. The node was not restarted.", then "Pause or
  delete this node's monitor: a push monitor alerts on silence." When the targets file stays:
  "Could not delete <file>, which holds the monitor URLs; remove it by hand (sudo shred -u <file>)."
- Status, off (ENABLE_ALERTS false or absent and no timer unit): one line "Private alerts: off
  (enable them with setup-alerts.sh)". Otherwise the step "Private alerts (heartbeat to your own
  monitor)" and the lines "Private alerts: on|pending|off" (pending adds "Finish the setup with:
  sudo bash setup-alerts.sh"), "timer active, next run <NEXT of list-timers>" / "timer inactive" /
  "timer not installed", as root "last run <N>s ago: <up|down>, <reason>" and "target <n>
  <kind>@<host> <ok|fail> <code> [why]", else "last run not checked (run with sudo)", and
  "runner <version>". Issues counted (rc, at most 20): alerts on but the timer missing or not
  running; no run recorded or the last one older than 3 x interval + 30 s; the last run recorded
  no target or every push failed; the targets file missing, not a regular file, or not root:root
  0600; ENABLE_ALERTS set more than once; the runner missing or of another version than the
  scripts ("run: sudo bash setup-alerts.sh --refresh"); alerts.env naming another service or RPC
  URL than the node has now, or the node's RPC address unreadable.

Interface for setup-alerts.sh (A2):
- ALERTS_LABEL_REQ: set to the --label value before alerts_enable or alerts_refresh ("" = the
  stored label, else the host name).
- alerts_targets_validate ALLOW_HTTP: run it in the current shell with stdout to /dev/null and
  stdin from a process substitution; read ALERTS_VALID (normalised lines, a secret) and ALERTS_ERR.
- alerts_enable / alerts_set_targets read the targets on stdin: `< <(trap - ERR; printf '%s'
  "$ALERTS_VALID")`; an enable on a node already on without targets: `< /dev/null` (a terminal
  stdin counts as empty too).
- ALERTS_APPLIED after alerts_enable: enabled | targets-changed | refreshed.
- ALERTS_RESULTS lines "n kind host ok|fail code [why]"; ALERTS_NODE_STATUS, ALERTS_NODE_REASON.
- alerts_status: call directly (`n=0; alerts_status addons_say || n=$?`); it fills
  ALERTS_ST_ENABLED (true|pending|false), ALERTS_ST_TIMER (active|inactive|absent),
  ALERTS_ST_LAST_RUN, ALERTS_ST_LAST_STATUS, ALERTS_ST_LAST_REASON, ALERTS_ST_RUNNER_VERSION
  ("" means null) and ALERTS_RESULTS (empty without root).
- rc: alerts_set_targets 2 = no target accepted and the previous file could not be put back
  (exit 3); alerts_disable 1 = the targets file survived (exit 3); alerts_write_env,
  alerts_install_runner and alerts_write_units leave their reason in ALERTS_ERR.
- FN kinds used: step, log, ok, warn, error.

## Tests run
All against the real lib/tn-heartbeat.sh helpers (no stand-in used).
- `bash tools/tests/run.sh tools/tests/alerts_test.sh tools/tests/lib_skew_test.sh tools/tests/addon_gates_test.sh`
  (bash 5.3, uid 1000): alerts 241 checks / 0 failures / 3 skipped (the root owner checks);
  lib_skew 146/0/0; addon_gates 67/0/0. systemd-analyze verify (systemd 259) ran on both units: ok.
- same in `bash:3.2` (root, busybox; the real root primitives): alerts 241/0/1 (systemd-analyze
  absent); lib_skew 110/0/1; addon_gates 67/0/0.
- same in `ubuntu:24.04` (root, GNU): alerts 241/0/1 (systemd-analyze absent); lib_skew 110/0/1;
  addon_gates 67/0/0.
- `bash -n` (bash 5 and bash:3.2) on lib/alerts.sh, lib/common.sh, tools/tests/alerts_test.sh,
  tools/tests/vm.d/P0-alerts.sh: clean.
- `bash tools/check-bash32.sh` on the four files: clean.
- `shellcheck -x --severity=error` on the four files: clean (warning level: SC2034 on the
  result variables of lib/alerts.sh only, as observability.sh has).
- `bash tools/tests/root_write_pipe_test.sh`: 2/0/0. `bash tools/tests/passphrase_print_test.sh`:
  4/0/0. `bash tools/check-network-hits.sh`: clean. `bash tools/check-perl-interp.sh` on the
  three new files: clean.
- Full `bash tools/tests/run.sh` (bash 5): 64 files, 63 pass; release_scripts_test.sh fails
  with "release-scripts.sh: not committed to git: lib/alerts.sh" (update-scripts.sh already
  lists the new files; it passes once the orchestrator commits them).
- P0-alerts.sh: `bash -n` clean; vm_lib refuses outside root + TN_VM_TEST=1. Tried end to end
  in a privileged systemd 255 container (ubuntu:24.04 + systemd, a scratch stand-in for
  setup-alerts.sh in a scratch copy of the tree): the fake node, the listener, the unit load,
  the DynamicUser start, the rollback of the failed enable (no file left, ENABLE_ALERTS=false)
  and the disable (no unit, runner, dir or state; ENABLE_ALERTS=false) all worked, but Docker
  gives no LoadCredential= directory (a minimal DynamicUser + LoadCredential unit gets no
  /run/credentials/<unit> either; /run/credentials is read-only and empty), so the runner logged
  `config: no targets credential` and the up/push assertions could not pass there. They run on
  the CI VM (integration.yml) once setup-alerts.sh is in the tree. Container and image removed.

## Open issues
- release_scripts_test.sh fails until lib/alerts.sh (and the other new files) are committed.
- Changing the interval of an enabled node: alerts_enable on a node already on keeps the stored
  interval/stall/inactive (spec: no targets -> alerts_refresh, which reads them from
  alerts.env). Today the operator disables and enables again. If setup-alerts.sh should
  apply --interval on an enabled node, the library needs a request variable (for example
  ALERTS_TIMING_REQ) read by alerts_refresh; not added.
- Additions beyond the section 7 table, for review: alerts_refresh also runs
  `systemctl enable telcoin-heartbeat.timer` when ENABLE_ALERTS=true (so a timer refresh put
  back also starts at boot); alerts_status counts alerts.env drift (another service name, RPC
  URL, or an unreadable RPC address) as an issue; alerts_enable treats ENABLE_ALERTS=true
  without the timer unit as a fresh install; alerts_test starts the service a second time when
  the state's last_run predates the start (a timer run the start merged into).
- P0-alerts.sh assumes setup-alerts.sh prints the done event on stdout for `--json --enable
  --targets-stdin --interval 30` and `--json --disable`, and exits 0 on both (A2).

## Verifier fixes (F-A)

status: done (fixer F-A)

- [x] F1 W1 / W-X1: alerts_disable keep-meta; _alerts_enable_undo restores the start state (meta_unset when absent)
- [x] F2 W2: alerts_status with an unreadable .node-meta (unknown (run with sudo), on from is-enabled, JSON null)
- [x] F3 N1 / N-O1 / N-O2: alerts_refresh [FN] [INTERVAL STALL INACTIVE]; setup-alerts explicit values; applied list; --help
- [x] F4 tests for F1-F3 in alerts_test.sh and setup_alerts_test.sh
- [x] F5 gates (bash 5, bash:3.2, ubuntu:24.04; bash -n; bash32 lint; shellcheck; passphrase; root-write pipe; network hits)

Notes (F-A):
- alerts_disable [FN] [no-hint] [keep-meta]; alerts_refresh [FN] [INTERVAL STALL INACTIVE] (FN stays first,
  as every other say-taking function; empty value = keep the stored one); alerts_refresh rc 0 / 1 refused,
  nothing changed / 2 stopped after a write; alerts_enable rc 0 / 1 nothing changed / 2 partway (alerts on).
- ALERTS_APPLIED may be "targets-changed refreshed"; ALERTS_ST_ENABLED "" when .node-meta cannot be read.
- alerts_require_lib now also checks meta_get and meta_unset.
- Gates: alerts 279/0/3 (bash 5, uid 1000), 271/0/2 (bash:3.2, ubuntu:24.04 root); setup_alerts 209/0/0,
  204/0/5, 204/0/5; addon_oldlib 53; remove 474; bash -n (5 and 3.2), check-bash32, shellcheck error and
  warning (only the lib's existing SC2034 cross-file globals), passphrase (tree 4/4 plus the lint on the
  untracked files: clean), root_write_pipe 2/2, network hits clean, perl lint clean. One bash:3.2 run hit
  the known check_has pipefail flake (followup.md) on a unit-text line; four reruns clean.
- Mutants M1-M5 (undo without keep-meta, status ignoring an unreadable .node-meta, refresh ignoring values,
  no refresh after a targets change, full timing on an enabled node): each fails 4-9 checks.
