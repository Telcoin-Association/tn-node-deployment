status: done

Package A3b (issue #60, branch private-alerts). Spec: tasks/spec-alerts-A3b.md; shared: tasks/spec-alerts-shared.md.

## Sections
- [x] S0 read the shared spec, the anchors in remove-node.sh / update-scripts.sh, AGENTS.md, the four tests
- [x] S1 remove-node: remove_alerts, its three call sites, rm_leftovers_present and the shown list, header comment
- [x] S2 update-scripts: the three rows after the observability row, the --refresh hint after install_pass
- [x] S3 AGENTS.md (section 9 edits + ## Private alerts)
- [x] S4 tests: remove_test.sh, remove_addons_test.sh, updater_manifest_test.sh, addon_gates_test.sh
- [x] S5 gates

## Operator-visible changes

remove-node.sh (SCRIPT_VERSION stays 2.1.0):
- New `rm_alerts_present` (reads only) and `remove_alerts` (inline, fixed paths under TN_RM_ROOT,
  no lib/alerts.sh or hb_* call). remove_alerts does nothing and prints nothing when none of
  these exists: /etc/systemd/system/telcoin-heartbeat.timer, .../telcoin-heartbeat.service,
  /usr/local/libexec/telcoin/tn-heartbeat, /etc/telcoin/alerts, /var/lib/private/telcoin-heartbeat,
  /var/lib/telcoin-heartbeat. Otherwise, in this order: `systemctl disable --now telcoin-heartbeat.timer`,
  `systemctl stop telcoin-heartbeat.service`, `systemctl clean --what=state telcoin-heartbeat.service`,
  removes the state dir and its link when they are still there, shreds /etc/telcoin/alerts/targets
  (and any `.tn.*` writer temp copy in that dir), removes alerts.env, rmdir the dir (a symlinked
  dir: only the link goes), removes both units and the runner, `systemctl daemon-reload`,
  `systemctl reset-failed telcoin-heartbeat.service`, then best-effort
  `meta_set ENABLE_ALERTS false <config dir>/.node-meta` while that file exists. Always rc 0.
- Called before the node stops: remove_node_unit (right before stop_and_disable_service),
  json_remove at every scope (after rm_take_lock, before the "Stopping and disabling" step),
  remove_leftovers (right after rm_take_lock). Not in the chain-data-only wipe.
- Messages (printed through rm_baseline_say, so --json gets events):
  - interactive: `>>> Removing private alerts (telcoin-heartbeat)` then
    `  -> Pause or delete this node's monitor: a push monitor alerts on silence.`
  - --json: `{"event":"step","msg":"Removing private alerts (telcoin-heartbeat)"}` and
    `{"event":"log","msg":"Pause or delete this node's monitor: a push monitor alerts on silence."}`
- rm_leftovers_present counts /etc/systemd/system/telcoin-heartbeat.timer; the leftover list
  shows `  /etc/systemd/system/telcoin-heartbeat.timer (private alerts)`.
- Comments updated: rm_baseline_say, rm_leftovers_present, remove_leftovers, remove_node_unit and
  the JSON-mode header (scope "service" now starts with the alerts removal).

update-scripts.sh (SCRIPT_VERSION stays 2.1.0):
- SCRIPTS rows after setup-observability.sh: `setup-alerts.sh:setup-alerts.sh:SCRIPT_VERSION`,
  `lib/alerts.sh:lib/alerts.sh:ALERTS_VERSION`, `lib/tn-heartbeat.sh:lib/tn-heartbeat.sh:HEARTBEAT_VERSION`.
- After install_pass and the UI hint, when UPD_PATHS holds lib/tn-heartbeat.sh or lib/alerts.sh
  and `${TN_ROOT_PREFIX:-}/etc/systemd/system/telcoin-heartbeat.timer` exists (-e):
  `  -> The heartbeat runner or its library changed. Reinstall them on the host:`
  `  ->   sudo bash <scripts dir>/setup-alerts.sh --refresh` (then a blank line). Never runs sudo.

AGENTS.md: setup-alerts.sh in the boundary list; setup-alerts among the addon_meta_write_begin
users; "the five add-ons" for the baseline refresh; "setup-alerts runs neither, because it never
stops or restarts the node" in the restart paragraph; `alerts_require_lib` in the *_require_lib
list; the ownership intro names the runner's state dir (/var/lib/private/telcoin-heartbeat, 0700,
DynamicUser StateDirectory) as the one other tree not owned by root; CI says integration.yml runs
only `tools/tests/vm.d/P0-*.sh` (a new file needs the P0- prefix), and the fixture-tests vm.d
bullet says the same; new `## Private alerts` section (between "Staking helper" and "Partner
documents") with the rules: every network / not a testnet add-on / three SCRIPTS rows and the
first-match version rule; the runner sources nothing; URLs only via the targets credential and
`-K`, shown as kind@host; DynamicUser and the state file; no node restart, locks, baseline
refresh; removal before the node stops (not the chain-data wipe) with the hint, no library call;
the updater only prints --refresh; the pushed field set is an operator-visible contract.

## Docs notes

- remove-node.sh removes private alerts at every removal (menu, Node Manager UI --json scopes
  service/data/keys, and the leftover clean-up), before it stops the node, and keeps them on
  "Wipe chain data only". Exact hint: "Pause or delete this node's monitor: a push monitor
  alerts on silence." Step text: "Removing private alerts (telcoin-heartbeat)".
- Leftover list entry: "/etc/systemd/system/telcoin-heartbeat.timer (private alerts)".
- Removed paths: /etc/systemd/system/telcoin-heartbeat.timer, /etc/systemd/system/telcoin-heartbeat.service,
  /usr/local/libexec/telcoin/tn-heartbeat, /etc/telcoin/alerts/targets (shredded),
  /etc/telcoin/alerts/alerts.env, /etc/telcoin/alerts, /var/lib/private/telcoin-heartbeat and
  the /var/lib/telcoin-heartbeat link; .node-meta gets ENABLE_ALERTS=false when it is kept.
- update-scripts.sh hint, exact lines: "The heartbeat runner or its library changed. Reinstall
  them on the host:" and "  sudo bash <scripts dir>/setup-alerts.sh --refresh"; shown only when
  lib/tn-heartbeat.sh or lib/alerts.sh changed and the timer unit exists.
- README changelog / CHANGELOG/ release note: remove-node.sh and update-scripts.sh changed at
  2.1.0 (no version bump, the release is unreleased).

## Tests run

All on the four tests (remove_test.sh, remove_addons_test.sh, updater_manifest_test.sh,
addon_gates_test.sh), run with lib/alerts.sh and lib/tn-heartbeat.sh present in the tree
(written by A1a/A1b) and setup-alerts.sh absent:
- `bash tools/tests/run.sh <4 files>` (bash 5.3.9): 474 / 34 / 191 (1 skip: setup-alerts.sh version,
  file absent) / 67 checks, 0 failures.
- `docker run ... bash:3.2 bash tools/tests/run.sh <4 files>` (bash 3.2.57): 474 / 34 / 187 (3 skips:
  ssh-keygen absent, git absent, setup-alerts.sh absent) / 67, 0 failures.
- `docker run ... ubuntu:24.04 bash tools/tests/run.sh <4 files>` (bash 5.2.21, root): same counts
  as bash:3.2, 0 failures.
- `bash -n` (bash 5 and bash:3.2) on remove-node.sh, update-scripts.sh and the four tests: clean.
- `bash tools/check-bash32.sh` on those six files: clean.
- `shellcheck -x --severity=error` remove-node.sh update-scripts.sh and the four tests: clean;
  warning-level counts identical to HEAD (6 SC2034, 3 SC2115, 3 SC2206, all pre-existing).
- `tools/tests/ci_pins_test.sh`: 53 checks, 0 failures. `tools/check-network-hits.sh`: clean.
  `tools/tests/root_write_pipe_test.sh`: 2/0. `tools/tests/passphrase_print_test.sh`: 4/0.
  `tools/check-perl-interp.sh remove-node.sh update-scripts.sh`: clean.
- `tools/tests/lib_skew_test.sh`: 146 checks, 0 failures.
- `tools/tests/release_scripts_test.sh`: FAILS (expected) with "release-scripts.sh: not committed
  to git: lib/alerts.sh": the new SCRIPTS rows name files that are not committed yet.

New test cases:
- remove_test.sh: remove_alerts alone (remaining tree = snapshot minus the alerts paths,
  /var/lib/private kept, the exact systemctl sequence, targets shredded, meta_set logged, hint
  once, token never printed); the real alerts_disable (when the library defines it) leaves the
  same tree; no alerts files: no output, no call, no meta write; symlinked config dir; --json
  service/data/keys (alerts gone, timer disabled before `systemctl stop telcoin`, step and log
  events, the step before "Stopping and disabling telcoin", token absent from JSON and stderr);
  menu remove_node_unit; leftover path (listed, removed before the units stop); only the timer
  left is a leftover and is removed; chain-data-only wipe keeps every alerts file; a duplicated
  .node-meta key refuses before touching the alerts; a static check that remove-node.sh calls
  no alerts_*/hb_* function; --json keys with every alerts_*/hb_* function unset.
- remove_addons_test.sh: the alerts files join KEEP (remove_testnet_addons leaves them, never
  says "Testnet add-ons found", never calls anything heartbeat); remove_alerts in a fresh bash
  sourcing a copy of remove-node.sh beside a lib/ without alerts.sh and tn-heartbeat.sh (rc 0,
  no alerts_/hb_ function loaded, every alerts file, the dir, the state dir and link removed, the
  other files kept, the timer disabled, the hint printed).
- updater_manifest_test.sh: version_var_for gives SCRIPT_VERSION / ALERTS_VERSION /
  HEARTBEAT_VERSION and the three rows follow setup-observability.sh in SCRIPTS; for each file
  present in the tree, _file_version equals the file's own `^(readonly )?VAR="` assignment
  (SKIP when absent); the hint printed once (both lines) when lib/tn-heartbeat.sh changed and
  the timer exists under TN_ROOT_PREFIX, likewise for lib/alerts.sh, names this tree, sudo never
  run; not printed when neither changed (timer present) nor when the timer is absent.
- addon_gates_test.sh: the five alerts files alone: tn_testnet_addons_present rc 1, no output
  (and they stay for the later cases, whose lists are unchanged).

## Open issues

- release_scripts_test.sh and CI's checksum job stay red until setup-alerts.sh, lib/alerts.sh and
  lib/tn-heartbeat.sh are committed with their sidecars (orchestrator, W5).
- updater_manifest_test.sh reports SKIP for "alerts rows: setup-alerts.sh version" until A2's
  setup-alerts.sh lands; then it checks that the first `SCRIPT_VERSION` match is the real
  `readonly SCRIPT_VERSION="2.1.0"`.
- For A1b (lib/alerts.sh, alerts_disable), a parity suggestion: remove_alerts also shreds a
  writer's `.tn.*` temp copy left in /etc/telcoin/alerts by an interrupted write (it holds the
  push URLs, and it would keep the rmdir from removing the dir). alerts_disable could do the
  same before its rmdir: `_tn_shred "$(alerts_etc_dir)"/.tn.*` (_tn_shred skips a word that
  is neither a file nor a link, so an unmatched glob is harmless). Not needed for the tests.
- Docs (A4): OPERATOR.md / README / partner guide should say that removal takes the private alerts
  first and prints the monitor hint, and describe the updater's --refresh hint (strings above).
