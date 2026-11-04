status: done

Package A3a (issue #60, branch private-alerts). Spec: tasks/spec-alerts-A3a.md; shared: tasks/spec-alerts-shared.md.

## Sections
- [x] S0 read the shared spec and the anchors
- [x] S1 setup-node: default, read-back, prompt_alerts, write_node_meta key, step_alerts, step_final_summary lines, header comment, --help text
- [x] S2 check-node: check_alerts, the loop entry, the _cn_own rows, the header comment
- [x] S3 tests: host_baseline_test.sh update; check_node_hardening_test.sh cases; new setup_node_alerts_test.sh
- [x] S4 gates (re-run after the coordinator's prompt wording fix; all green)

## Operator-visible changes

setup-node.sh (SCRIPT_VERSION stays 2.1.0; tn_require_fns unchanged):
- New global `ENABLE_ALERTS="false"` (true | pending | false), after REGION.
- step_preflight, after the region block and before "Selecting install method": reads
  ENABLE_ALERTS from `${CONFIG_DIR}/.node-meta` with `setup_meta_read` (keeps true or pending;
  any other value counts as false; a key set twice stops setup), then `json_mode || prompt_alerts`.
- prompt_alerts (every network, no is_testnet): returns early under TN_ASSUME_YES=true, when
  `$SCRIPT_DIR/setup-alerts.sh` is absent, or when ENABLE_ALERTS is already true. Yes -> pending,
  no -> false (a no over a pending value read back from .node-meta clears it).
- step_create_service's write_node_meta: `"ENABLE_ALERTS=${ENABLE_ALERTS:-false}"` (after the VPN keys).
- step_alerts, in main between step_testnet_addons and step_host_baseline (interactive only; the
  --json finalize path is unchanged): no-op in --json or unless pending. Runs
  `bash "$SCRIPT_DIR/setup-alerts.sh" --enable 3>&-` (stdin stays the terminal; the update lock is
  free, setup released it before step_public_rpc). rc 0 -> ENABLE_ALERTS=true; else stays pending.
  Never stops or restarts the node; its only systemctl call is `is-active --quiet telcoin`.
- step_final_summary: the alerts line after the public RPC block, before "Useful commands".
- Header (--help) gains a PRIVATE ALERTS section.

check-node.sh (SCRIPT_VERSION stays 2.1.0; lib_skew_test.sh's helper list unchanged):
- check_alerts in the HARDENING CHECKS section after check_healthcheck_on_mainnet, registered last
  in the `for _hc in ...` loop. With `alerts_status`: its own output, its rc added to
  HEALTH_ISSUES. Without it: silent; joins CN_SKIPPED_CHECKS (so the existing skipped-checks
  warning names check_alerts) only when `${TN_ROOT_PREFIX}/etc/systemd/system/telcoin-heartbeat.timer`
  exists or .node-meta says ENABLE_ALERTS=true or pending.
- check_ownership_layout rows, each only when the path exists (a symlink is reported):
  `/usr/local/libexec/telcoin/tn-heartbeat` root:root 0755, `/etc/telcoin/alerts` root:root 0755,
  `/etc/telcoin/alerts/targets` root:root 0600, `/etc/telcoin/alerts/alerts.env` root:root 0644.
- Header comment: "Private alerts (setup-alerts.sh), when this host has them, are checked too:
  the timer, the last heartbeat and its pushes, the files' owners and modes."

## Docs notes

Prompt (prompt_alerts): header, four info lines, the question (default No):
```
Private alerts (optional)
  ->  A timer on this host pushes a heartbeat to a monitor you own, through an Uptime Kuma push URL, a healthchecks.io ping URL or a JSON webhook.
  ->  Each heartbeat says up or down with the reason (node mode, block and epoch); a webhook also gets this host's label and the network. Nothing else is sent.
  ->  No port opens on this host, and the Telcoin Association is not involved.
  ->  Setup asks for the monitor URLs once the node is running.
  ?  Set up private alerts once the node is running? [y/N]:
```
Asked on every network in interactive setup only: never in --json, never under
TN_ASSUME_YES=true, not when ENABLE_ALERTS=true already, not when setup-alerts.sh is missing
beside setup-node.sh. A re-run asks again over pending.

step_alerts (header "Private alerts"):
- node not running: `[WARN] The node is not running yet, so private alerts stay pending. Once it runs: sudo bash setup-alerts.sh`
- setup-alerts.sh missing: `[WARN] setup-alerts.sh is missing (<dir>/setup-alerts.sh), so private alerts stay pending. Restore it with update-scripts.sh, then run: sudo bash setup-alerts.sh`
- enable ok: `[OK]  Private alerts are on.`
- enable not ok: `[WARN] Private alerts were not set up (setup-alerts.sh exit <rc>, see above); they stay pending. To finish: sudo bash setup-alerts.sh`

Final summary (only when on or pending; nothing when false):
- `[OK]  Private alerts: on`
- `[WARN] Private alerts: pending. To finish: sudo bash setup-alerts.sh`

Duplicate key: `ENABLE_ALERTS is set more than once in /etc/telcoin/.node-meta; remove the extra lines and run setup again.`

.node-meta: `ENABLE_ALERTS=true|pending|false`, written at step_create_service with this run's
value (read back, then the prompt). --json setup never asks; the docs point to
`setup-alerts.sh --json --enable --targets-stdin`.

--help section:
```
PRIVATE ALERTS (optional, every network). Interactive setup asks whether this host
should push a heartbeat to a monitor you own (an Uptime Kuma push URL, a healthchecks.io
ping URL or a JSON webhook). Once the node runs, setup starts setup-alerts.sh --enable,
which asks for the URLs and sends a test heartbeat; .node-meta records ENABLE_ALERTS
(true, or pending until that is done). A --json run never asks: enable them afterwards
with setup-alerts.sh --json --enable --targets-stdin.
```

check-node.sh: check_alerts prints only what alerts_status prints (A1b's lines; today a
`>>> Private alerts (heartbeat to your own monitor)` step, then `Private alerts: off|on|pending`
and the timer line) and counts its rc as issues. Ownership drift takes the existing form under
"Ownership layout 2 is recorded, but these paths differ from it ...", e.g.
`  /etc/telcoin/alerts/targets: root:root 644, expected root:root 600` or
`  /etc/telcoin/alerts/targets: a symlink`.

## Tests run

Final pass (after the wording fix):
- bash 5: `bash tools/tests/run.sh` on setup_node_alerts_test 48/0 fail/0 skip,
  host_baseline_test 223/0/3, check_node_hardening_test 30/0/2, lib_skew_test 146/0/0.
- bash:3.2 (root, busybox): 48/0/0, 232/0/1, 45/0/4, 110/0/1 (lib_skew's 037c810 part skips
  without git).
- ubuntu:24.04 (root): 48/0/0, 232/0/1, 50/0/2, 110/0/1. The alerts _cn_own rows run as root in
  both containers (8 checks).
- bash -n (bash 5 and bash:3.2) and tools/check-bash32.sh clean on all five files;
  shellcheck -x --severity=error clean on both scripts and the new test (warning level clean too);
  passphrase_print_test 4/0; root_write_pipe_test 2/0; check-network-hits clean;
  check-perl-interp clean.
- Mutation check: exporting TN_SETUP_PASS to the child and changing the summary "on" line each
  make the new test fail.
- Full suite under bash 5 (before the wording fix): 62 files, only release_scripts_test.sh failed,
  with "release-scripts.sh: not committed to git: lib/alerts.sh" (another package's new file
  listed in update-scripts.sh but not committed yet; it passes once the orchestrator commits).
- Real lib/alerts.sh (A1b, present now) in an empty fixture: alerts_status prints the off lines,
  rc 0, so check_alerts adds nothing there.

## Open issues

- For A1b (lib/alerts.sh): `alerts_enable` on a fresh install rolls back through `alerts_disable`,
  which writes `ENABLE_ALERTS=false`. After a failed enable from setup-node's step_alerts,
  .node-meta then says false while setup-node's summary says pending. Suggest the rollback put
  back the value it found (pending stays pending) instead of writing false. setup-node does not
  rewrite the key itself, because it no longer holds the update lock at that point.
- Deviation from the shared spec's read-back line: setup-node reads `${CONFIG_DIR}/.node-meta`
  (the file its write_node_meta writes) through `setup_meta_read` instead of
  `meta_get ... "$(node_meta_path)" || true`. A duplicated key then stops setup, as every other
  setup-node meta read does, instead of reading as false and overwriting a live value.
- check_alerts calls alerts_status whenever it exists (as specified), so every check-node report
  carries alerts_status's off lines on hosts without alerts. Intended, but worth a look from the
  docs side.
