status: done

Package A2 (issue #60, branch private-alerts). Spec: tasks/spec-alerts-A2.md; shared: tasks/spec-alerts-shared.md.

## Sections
- [x] S0 read the shared spec, setup-observability.sh, setup-vpn.sh usage(), lib/alerts.sh, hb_* helpers
- [x] S1 skeleton: header, source, SCRIPT_VERSION, alerts_require_lib, addons_say, sa_baseline_refresh, json helpers, traps, load_node_context, arg_fail, usage
- [x] S2 argument parsing
- [x] S3 run_json_mode (sa_do_* per action, shared by --json and plain mode)
- [x] S4 the menu, target collection, interval prompt, --enable without --json
- [x] S5 tests (setup_alerts_test.sh, addon_oldlib_test.sh row)
- [x] S6 gates

Files: setup-alerts.sh (new, 0755), tools/tests/setup_alerts_test.sh (new),
tools/tests/addon_oldlib_test.sh (row, copy, header, "current lib" check).

## Operator-visible changes
- New script `setup-alerts.sh` (`readonly SCRIPT_VERSION="2.1.0"`, line 52, the first line matching
  `SCRIPT_VERSION\s*=`). Every network; never testnet-gated; never stops or restarts the node.
- Actions: `--status`, `--enable`, `--test`, `--refresh`, `--disable`, each with or without
  `--json` (without it: plain text); no action and no `--json`: the menu. Plain-mode actions exist
  because the updater hint and alerts_status say `sudo bash setup-alerts.sh --refresh` / `--test`.
- Exit status: 0 done; 1 refused, nothing changed (also: a failed fresh enable that rolled back,
  a target change put back, a failed test); 2 library gap; 3 something changed and stays (refresh
  stopped partway; disable left the targets file; a target change whose put-back failed; a
  rolled-back enable that could not delete the targets file).
- Locks: enable, refresh, disable `addon_meta_write_begin`; test `addon_meta_lock`; status none.
  `TN_EXIT_TRAP_OWNED=1` before the lock; EXIT trap (json_on_exit / sa_on_exit) runs
  `tn_remove_inflight_tmp` then `tn_release_update_lock`; TERM/INT/HUP exit 143/130/129.
- Host baseline (`tn_host_baseline_refresh addons_say`, behind `declare -F`): after a successful
  enable, target change, refresh or disable, and after an exit-3 partial; not after a refusal,
  a rolled-back enable, a test or status.

## Docs notes
Header / `--help` (usage() prints the header between the first two `# ====` lines):
```
  sudo bash setup-alerts.sh                     # menu
  sudo bash setup-alerts.sh --enable            # asks for each URL, input hidden
  printf 'kuma https://kuma.example.org/api/push/TOKEN\n' \
    | sudo bash setup-alerts.sh --json --enable --targets-stdin [--interval 60]
  bash setup-alerts.sh --json --status          # as root it shows the last run too
  sudo bash setup-alerts.sh --json --test       # send a test heartbeat now
  sudo bash setup-alerts.sh --json --refresh    # after update-scripts.sh changed the runner
  sudo bash setup-alerts.sh --json --disable    # remove the timer, runner, targets and state
  Each action also runs without --json and then prints plain text.
```
Flags and defaults:
- Targets: one `<kind> <url>` line each (kuma, healthchecks, webhook; at most 5) from exactly one
  of `--targets-stdin` (all of stdin; refused when stdin is a terminal or empty), the environment
  variable `TN_ALERT_TARGETS` (same lines; copied and `unset` at the top of the script, before
  `lib/common.sh` is sourced; ignored, but still unset, for actions other than --enable), or
  repeated `--target kind=url` (also `--target=kind=url`). Only with --enable.
- `--interval N` (30-3600, default 60); `--stall-after N` (default the larger of 180 and
  3 x interval); `--inactive-after N` (default the larger of 900 and the stall time). The library
  checks the ranges (stall >= interval + 30, <= 86400; inactive >= stall, <= 86400). Only with
  --enable. Value forms `--flag N` and `--flag=N`. NOTE: the shared spec section 2 says
  "default 180 / 900"; the defaults are derived from the interval so a larger --interval is not
  refused; at the default interval they are 180 and 900.
- `--allow-http`: http:// to hosts other than 127.0.0.1, [::1], localhost; with --enable or the menu.
- `--label NAME` (1-64 of A-Z a-z 0-9 . _ -, first a letter or digit; sets ALERTS_LABEL_REQ; the
  environment's ALERTS_LABEL_REQ is ignored): with --enable, --refresh or the menu.
- `-h`, `--help`: the header, exit 0 (also with --json).
- `--enable` on a node with alerts on (ENABLE_ALERTS=true and the timer unit): targets given ->
  target change (`alerts:targets-changed`); none -> refresh (`alerts:refreshed`), timing flags not
  applied (warned).
- `--enable` without --json and without a target source: from a terminal it asks (header "Enable
  private alerts", the four explain lines, the target questions, the interval prompt unless a
  timing flag was given); otherwise refused with the stdin hint.

Menu (`print_header "Telcoin Network -- Private Alerts  v2.1.0"`, then
`Network: <net>   Private alerts: on|pending|off|unknown (ENABLE_ALERTS is set more than once in .node-meta)`):
```
  1) Status
  2) Enable private alerts
  3) Change targets
  4) Send a test heartbeat now
  5) Refresh after a script update
  6) Disable private alerts
  7) Exit
  Enter choice [1-7]:
```
Bad choice: "Please enter 1-7." Item headers: "Private alerts status", "Enable private alerts",
"Change the private alerts targets", "Send a test heartbeat", "Refresh private alerts",
"Disable private alerts". Pause: "  Press Enter to return to menu...". Exit: "Exiting."
Menu texts:
- 2 when on: "Private alerts are on already. Pick 3 to change the targets, or 5 to refresh them after a script update."
- 3 when off: "Private alerts are off on this host; pick 2 to enable them."; then "The new targets replace the current ones once one of them accepts a test heartbeat; otherwise the current ones stay."
- 4 when not set up: "Private alerts are not set up on this host; pick 2 to enable them."
- 5: "Installs the runner of these scripts again and rewrites its settings and units; the targets stay and the node is not restarted."
- 6: "Removes the heartbeat timer, its service, the runner, the targets and the runner's state. The node keeps running." then confirm "Disable private alerts on this host?" (no: "Nothing was changed.")
- No target entered: "No target entered; nothing was changed."
Explain lines (menu 2 and interactive --enable):
- "A timer on this host pushes a heartbeat to monitors you own: an Uptime Kuma push URL, a healthchecks.io ping URL or a JSON webhook."
- "Each heartbeat says up or down with the reason (node mode, block and epoch); a webhook also gets this host's label and the network. Nothing else is sent."
- "No port opens, the Telcoin Association is not involved, and the node is not restarted."
- "Each URL holds its monitor's token: it is kept in /etc/telcoin/alerts/targets (root 0600) and shown only as kind@host."
Target questions (up to 5):
```
  Where should the heartbeat go?
    1) Uptime Kuma push URL
    2) healthchecks.io ping URL
    3) JSON webhook
  Provider [1-3]:            (bad: "Please enter 1, 2 or 3.")
  URL (input hidden):        (refused: "<HB_ERR>; enter it again, or press Enter to stop."; empty: "No URL entered.")
  [OK]  Target <n>: <kind>@<host>
  Add another? [y/N]:
  Interval in seconds [60]:  (bad: "Enter a whole number of seconds from 30 to 3600.")
```
After a fresh enable (log event in --json): "Set the monitor's heartbeat interval to about <2 x interval> s with 1-2 retries: a node update or a restart you run yourself shows as a short down."
On an enable of a node already on, no targets (log): "Private alerts are on already; refreshing them (the targets stay). To change the targets, run setup-alerts.sh and pick Change targets."
Timing flags on that path (warn): "Private alerts are on already, so --interval, --stall-after and --inactive-after are not applied; to change them, run --disable and then --enable."
--target (warn, once): "--target puts the URL on the command line, where other local users can read it while this runs; pipe it in with --targets-stdin instead."

Refusals (exit 1, each ends "Nothing was changed."):
- "Run setup-alerts.sh --enable as root (sudo). Nothing was changed." (same for --test, --refresh, --disable; menu: "Run setup-alerts.sh as root (sudo). Nothing was changed.")
- "No Telcoin node was found on this host (no .node-meta under /etc/telcoin); run setup-node.sh first. Nothing was changed." (every action, --status too)
- "NETWORK is set more than once in .node-meta; remove the extra lines and run this again. Nothing was changed."
- "ENABLE_ALERTS is set more than once in .node-meta; remove the extra lines and run this again. Nothing was changed." (enable, refresh)
- "Give one action: --status, --enable, --test, --refresh or --disable. Nothing was changed."
- "--json needs one action: --status, --enable, --test, --refresh or --disable. Nothing was changed."
- "Unknown argument: <--option> (see --help). Nothing was changed." / anything not option-shaped: "Unknown argument (not shown, in case it holds a URL); see --help. Nothing was changed."
- "<flag> needs a value. Nothing was changed." / "<timing flag> needs a whole number of seconds. Nothing was changed."
- "--target needs kind=url, with kind kuma, healthchecks or webhook. Nothing was changed."
- "--label takes 1 to 64 letters, digits, dots, underscores or dashes, starting with a letter or a digit. Nothing was changed."
- "<--targets-stdin|--target> goes with --enable (the menu asks for the targets). Nothing was changed."
- "<timing flag> goes with --enable (the menu asks for the interval). Nothing was changed."
- "--allow-http goes with --enable or the menu. Nothing was changed."
- "--label goes with --enable, --refresh or the menu. Nothing was changed."
- "Give the targets one way: --targets-stdin, --target or TN_ALERT_TARGETS. Nothing was changed."
- "--targets-stdin reads the targets from a pipe, not a terminal (the URLs would show as you type them). Nothing was changed."
- "--targets-stdin: no targets on stdin. Nothing was changed."
- "Refused: <ALERTS_ERR>. Nothing was changed." (e.g. "Refused: line 1 (kuma@kuma.example.org): kuma: not an /api/push/<token> URL. Nothing was changed.")
- --json --enable, no source, alerts off: "--enable needs the targets: --targets-stdin (one '<kind> <url>' line each), TN_ALERT_TARGETS or --target kind=url. Nothing was changed."
- plain --enable, no source, no terminal: "--enable needs the targets: pipe them in with --targets-stdin (one '<kind> <url>' line each), or run this from a terminal to type them. Nothing was changed."
- interactive --enable, nothing typed: "No target was entered. Nothing was changed."
- --test, unit absent: "Private alerts are not set up on this host; enable them first: sudo bash setup-alerts.sh --enable. Nothing was changed."
- lock held (--json): "another node operation holds the update lock; run this again when it has finished. Nothing was changed." / migration: "the update lock or the ownership migration stopped this run (see its messages on stderr); nothing was changed"
- library gap (exit 2): "<libs> is|are older than this script (it lacks <fns>): run update-scripts.sh, then this again. Nothing was changed." (all on stderr; --json also prints `{"event":"done","ok":false,"error":"<msg>","msg":"<msg>"}` on stdout)

--json: events `{"event":"step|log|warn|error","msg":"…"}` on stdout (fd 3), everything else on stderr;
library kinds step/warn/error keep their kind, ok and log become log. done events:
- enable: `{"event":"done","ok":true,"applied":["alerts:enabled"],"network":"testnet","interval":60,"node_status":"up","node_reason":"CvvActive block 1234567 epoch 42","targets":[{"n":1,"provider":"kuma","host":"kuma.example.org","result":"ok","code":200},{"n":2,"provider":"webhook","host":"hooks.example.net","result":"fail","code":0,"why":"timeout"}],"msg":"private alerts enabled"}`
  (`applied` `alerts:targets-changed` + msg "private alerts targets changed", or `alerts:refreshed`
  + msg "private alerts refreshed" with node_status/node_reason null and targets []; "interval" is
  ALERTS_INTERVAL of alerts.env, else the requested one; "why" only on a failed push; code 000 -> 0)
- test: `{"event":"done","ok":true,"applied":["alerts:tested"],"network":"…","node_status":…,"node_reason":…,"targets":[…],"msg":"test heartbeat sent"}`
- refresh: `{"event":"done","ok":true,"applied":["alerts:refreshed"],"network":"…","interval":<n>|null,"msg":"private alerts refreshed"}`; alerts off: `{"event":"done","ok":true,"applied":[],"network":"…","msg":"private alerts are off; nothing to refresh"}`
- disable: `{"event":"done","ok":true,"applied":["alerts:disabled"],"network":"…","msg":"private alerts disabled"}`
- status: `{"event":"done","ok":true,"applied":[],"network":"…","enabled":"true|pending|false","timer":"active|inactive|absent","last_run":<n>|null,"last_status":"up|down"|null,"last_reason":"…"|null,"runner_version":"2.1.0"|null,"issues":<n>,"targets":[…],"msg":"private alerts status"}` (exit 0 whatever the issue count)
- failure: `{"event":"done","ok":false,"msg":"…"}`; msg is the script's own refusal, else the library's last error event, else a fixed text:
  test all failed: "no target accepted the test heartbeat; check the URLs and this host's network";
  test no run: "the heartbeat runner recorded no run; see what it said with: journalctl -u telcoin-heartbeat -n 20";
  enable rollback left the targets file (exit 3): "private alerts were not enabled, and /etc/telcoin/alerts/targets, which holds the monitor URLs, could not be removed; delete it by hand: sudo shred -u /etc/telcoin/alerts/targets";
  disable left it (exit 3): "private alerts were removed except /etc/telcoin/alerts/targets, which holds the monitor URLs; delete it by hand: sudo shred -u /etc/telcoin/alerts/targets";
  early stop: "setup-alerts.sh stopped early (rc=N); see its messages on stderr".

## Tests run
- `bash tools/tests/run.sh tools/tests/setup_alerts_test.sh tools/tests/addon_oldlib_test.sh` (bash 5.3.9): 176 checks / 0 failures; 53 / 0 (old library 037c810).
- `docker run … bash:3.2 … run.sh` same files: 173 + 3 SKIP (no python3 for the JSON parse checks) / 0 failures; 53 / 0 (old library: renamed helpers).
- `docker run … ubuntu:24.04 … run.sh` same files (root, GNU): 173 + 3 SKIP / 0; 53 / 0.
- `bash -n` (bash 5 and bash:3.2) on the three files: clean. `tools/check-bash32.sh` on the three: clean.
- `shellcheck -x --severity=error` (and warning) on the three: clean.
- `tools/check-perl-interp.sh` on the three: clean. `tools/tests/passphrase_print_test.sh`: 4/0.
  `tools/tests/root_write_pipe_test.sh`: 2/0. `tools/check-network-hits.sh`: clean (rc 0).
- `bash tools/tests/run.sh tools/tests/updater_manifest_test.sh`: 192/0, 0 skipped; "alerts rows:
  setup-alerts.sh shows SCRIPT_VERSION 2.1.0" now runs and passes.
- Smoke against the real library (ubuntu:24.04, root, TN_ROOT_PREFIX fixture, no node unit):
  `--json --status` -> quiet line + done (enabled false, timer absent, nulls), rc 0;
  `--json --enable --targets-stdin` -> library refusal "No node service is installed on this host
  (telcoin.service). Nothing was changed." as the error event and the done msg, rc 1, .node-meta
  unchanged, no systemctl call; `--json --refresh` -> "nothing to refresh", rc 0.

## Open issues
- Orchestrator (W5): `tools/gen-checksums.sh` for `setup-alerts.sh.sha256`; the checksum job fails until then.
- Decision: TN_ALERT_TARGETS is copied and unset at the top of the file, before `source lib/common.sh`
  (earlier than "first thing in main"), so even the library's sourcing never sees it.
- Decision: the --stall-after / --inactive-after defaults are derived from the interval in every
  mode (max(180, 3 x interval), max(900, stall)), not fixed at 180/900 as the section 2 table says:
  a fixed 180 would refuse any --interval above 150. Docs should state the derived defaults.
- Library behaviour (A1b, for the docs or a follow-up): a failed fresh enable on a host where
  ENABLE_ALERTS was absent leaves an `ENABLE_ALERTS=false` line in .node-meta (alerts_disable inside
  `_alerts_enable_undo` writes it; the put-back only runs for a non-false value). setup-alerts
  reports that run as exit 1 and does not refresh the AIDE baseline, so a host with
  HOST_BASELINE=true would see .node-meta reported changed until its next baseline refresh.
- Failure done events carry only `ok` and `msg` (spec shape); a failed test's per-target results
  are in the warn events ("Target <n> <kind>@<host>: failed (<code> [why])"), not in the done.
