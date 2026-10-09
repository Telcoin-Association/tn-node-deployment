status: done

# Checkpoint: package C (C.3 firewall-setup 1.6.0, setup-observability 1.2.1, lib/observability 1.0.2)

Owned files: `firewall-setup.sh`, `setup-observability.sh`, `lib/observability.sh`. No other repo
file edited (the `.sha256` sidecars of these files changed in the tree, but not by this package:
see Open issues 1). Tests: `<scratchpad>/c-tests/`.

## Sections

- [x] 1. `fw_p2p_ports` (listener env on live launch lines for primary/worker-0, node-info for
      other workers, constants fallback); every status/enable/manage/desired-rule path loops over it.
      New in firewall-setup.sh: `fw_listener_port`, `fw_p2p_ports`, `fw_p2p_what`, `fw_p2p_port_text`,
      `fw_p2p_all_open`, `fw_p2p_allow`, `fw_lib_check` (soft guard, warns per screen / per --json run),
      `FW_CADDYFILE` (TN_ROOT_PREFIX-rooted, for tests). Rule labels: "Node P2P (primary)",
      "Node P2P (worker)" (one worker) or "Node P2P (worker N)".
- [x] 2. `apply_recommended_firewall`: `caddy_serves_public_edge` on every run, 80/443 before
      `ufw --force enable`; enable_firewall lists "Allow TCP 80 and 443" when a site is served
- [x] 3. JSON `p2p_ports` list appended after `ports`; `ports` keys and `json_fw_port` unchanged; status
      shows the service name ("Installed node: telcoin.service"); both `tn_resolve_node_type` calls removed
- [x] 4. Observability: `tn_launch_flag_get` pre-checks, inject messages by rc, `tn_wait_restart_window`
      before node restarts only, soft guards. lib/observability.sh new: `_obs_lib_has` (warn once per
      helper per run), `obs_lib_check`, `obs_wait_say`, `obs_restart_window [fn]`,
      `obs_inject_flags FILE MARKER FLAGS`; `obs_ensure_reth_flags [fn]` and `obs_enable TOKEN [fn]`
      take an optional trailing progress fn (old callers unaffected). setup-observability.sh new:
      `addons_say` (JSON step/log/warn events in --json, print_* otherwise), `addons_lib_check`,
      `health_flag_add`, `health_restart_window`.
      Restart sites decided:
        WAIT  setup-observability enable_health `systemctl restart $svc` (after the confirm)
        WAIT  lib/observability obs_ensure_reth_flags `systemctl restart $svc` (after the confirm; reached
              from enable_logging/enable_metrics, json --enable-logs/--enable-metrics, step_testnet_addons)
        none  obs_enable `systemctl restart telcoin-alloy.service` (Alloy shipper, not consensus)
        none  obs_disable_logs / obs_disable_metrics Alloy restarts, obs_disable `disable --now` + docker rm
              (disable paths, Alloy only)
        none  json_enable_health (leaves the restart to the operator), disable_health / json_disable_health
              (ufw only), every `systemctl daemon-reload`
        No rollback restart exists in these three files.
- [x] 5. Tests (both bashes, shims, fixtures, HEAD comparisons, pre-L1 library)
      - [x] 5a. firewall `t_fw.sh`: 124/124 under both bashes
      - [x] 5b. observability `t_obs.sh`: 82/82 under both bashes
      - [x] 5c. lint: bash -n, shellcheck error, check-bash32
- [x] 6. Closing headings

## Notes

- Listener env forms (setup-node + legacy b5f0e33/ad2d370^): docker wrapper `-e "PRIMARY_LISTENER_MULTIADDR=<ma>"`,
  binary wrapper `export PRIMARY_LISTENER_MULTIADDR="<ma>"`, unit `Environment="PRIMARY_LISTENER_MULTIADDR=<ma>"`,
  legacy docker unit `-e PRIMARY_LISTENER_MULTIADDR=<ma>` on the one ExecStart line. Same for WORKER_.
  The reader scans the unit, then the launch file; the last live assignment wins (the wrapper's export
  or -e beats the unit's Environment=, as at runtime). Not `tn_launch_flag_get`, which reads only the
  words after `node`.
- All three scripts run under lib/common.sh's `set -euo pipefail`.
- Pre-L2 `tn_node_inject_flags` returns 1 for both "already there" and "no launch line"; the new rc
  split is detected by `declare -F tn_launch_flag_get` (both arrived in 1.6.0).

## Operator-visible changes

firewall-setup.sh 1.6.0:
- The node P2P rules follow the node's real ports. Primary and worker 0 come from the listener
  addresses the node starts with (`-e`/`export` in the start wrapper, else `Environment=` in the
  unit), then node-info.yaml, then 49590/49594; workers 1 and up from node-info.yaml. Used by "View
  current firewall status", "Enable firewall", "Manage node ports", the expected-configuration
  check and `--json --enable`. Per-port lines carry the label: "UDP 51000 is open (primary)",
  "UDP 49598 (worker 1) is CLOSED -- ...". Expected rules read "Node P2P (primary)", "Node P2P
  (worker)" with one worker, "Node P2P (worker N)" with more.
- Enabling the firewall (menu option 2, `--json --enable`) allows TCP 80 and 443 before turning
  ufw on whenever Caddy serves the public RPC or dashboard on the box (was: only with `--reset`).
  The plan shown before the confirm lists it.
- "View current firewall status" works with ufw active. Before, it ended the script right after
  "Firewall is active" (rc 1): its default-policy read used a pattern that never matches real
  `ufw status verbose` output, and the failed pipeline tripped `set -e`. Bug present since v1.1.1.
- Status shows "Installed node: telcoin.service" (or the legacy unit) instead of "Installed nodes:
  observer"; "Manage node ports" shows "Detected node: ...".
- `--json --status`: same keys as before plus `"p2p_ports"`. The `ports` object and the
  `--json --port` allowlist (49590/udp, 49594/udp, 43174/tcp) are unchanged.
- With lib/common.sh older than 1.6.0: a warning ("cannot read node-info.yaml, so only the primary
  and worker 0 P2P ports are checked ...") and the launch-file / default ports.

setup-observability.sh 1.2.1, lib/observability.sh 1.0.2:
- Before restarting the node to pick up `--healthcheck`, the JSON log flags or `--metrics`, the
  scripts hold the restart while the node votes in the committee and the epoch boundary is close
  (`TN_SKIP_EPOCH_WAIT=1` skips). Alloy restarts never wait. In `--json` runs the wait shows as
  `step` / `log` / `warn` events on stdout.
- A commented-out `--metrics` or `--log.file.format json` no longer counts as present.
- When a flag is not added, the message says why: already on the node command (info), no live
  node command in the file, "Edit the launch file by hand: <reason>", or could not read or write
  the file. Each names the exact flags to add.
- A node command that already sets `--log.file.format` to a value other than json is reported
  ("... has --log.file.format terminal, and log shipping needs json. Change it to json by hand")
  instead of receiving a second `--log.file.format`.
- With lib/common.sh older than 1.6.0 or lib/observability.sh older than 1.0.2: one warning each
  on the status screen and before enables; the 1.2.0 behaviour otherwise.

## Changelog text

### firewall-setup v1.6.0 — P2P rules follow the node's ports; enabling keeps a live Caddy site up
Status, enable, "Manage node ports" and the expected-configuration check now use the node's
actual P2P ports instead of the fixed 49590/49594. The primary and worker 0 ports come from the
listener addresses the node is started with (the `-e` or `export` lines of the start wrapper,
else `Environment=` in the unit), then from `node-info.yaml`, then the defaults; workers 1 and up
come from `node-info.yaml`. A node set up on other ports, or with a second worker, gets the right
rules. Enabling the firewall (menu option 2 or `--json --enable`) allows TCP 80 and 443 before
ufw starts whenever Caddy serves the public RPC or dashboard on the box; before, only `--reset`
did, so a plain enable could take a live site down. "View current firewall status" works again
with ufw active: it used to stop right after "Firewall is active", because its default-policy
read never matched real `ufw status verbose` output and the failure ended the script. Status shows
the node's service (`telcoin.service`) instead of a node type. `--json --status` keeps its `ports`
keys and adds `p2p_ports`, one `{"port","proto","label","allowed"}` object per port (`allowed` is
null while ufw is off); the `--port` allowlist is unchanged. With a lib/common.sh older than 1.6.0
the script warns and checks the primary and worker 0 ports only.

### setup-observability v1.2.1 — epoch wait before the health-check restart, clearer flag messages
Enabling health monitoring waits for the epoch boundary before restarting a node that votes in
the committee (`TN_SKIP_EPOCH_WAIT=1` skips the wait), and enabling logs or metrics passes its
progress printer down, so `--json` runs report the wait as `step`, `log` and `warn` events. When
`--healthcheck` cannot be added, the message says why instead of "already has --healthcheck (or
the launch line was not found)". With a lib/observability.sh older than 1.0.2 the script warns
and behaves as 1.2.0.

### lib/observability v1.0.2 — flag checks ignore comments; epoch-aware node restarts
`obs_ensure_reth_flags` reads the live node command with `tn_launch_flag_get`, so a commented-out
`--metrics` or `--log.file.format json` no longer counts as present, and a command that already
sets `--log.file.format` to something other than json is reported rather than given a second one.
New `obs_inject_flags` words each outcome of `tn_node_inject_flags`: already there, no live node
command, edit the launch file by hand (with the reason), or the file could not be written. Before
it restarts the node, `obs_restart_window` waits for the epoch boundary when the node votes in the
committee; Alloy restarts never wait. `obs_enable` and `obs_ensure_reth_flags` take an optional
progress function for that wait. On a lib/common.sh older than 1.6.0 (flag reads) or 1.5.0 (the
wait) each missing piece falls back to the 1.0.1 behaviour with one warning per run.

## Tests run

Harness `<scratchpad>/c-tests/`: `mkcopies.sh` makes script copies with `main "$@"` removed in
`new/` (working tree), `head/` (HEAD scripts and HEAD lib/observability.sh, working-tree
lib/common.sh), `old/` (working-tree scripts, lib/common.sh + lib/fallback.sh + testnet-addons.env
from 7fb7c8d = COMMON_VERSION 1.4.0) and `oldobs/` (lib/observability.sh 1.0.1 beside the new
scripts). `run_fw.sh` / `run_obs.sh` source a copy at top level with `TN_ROOT_PREFIX=<fixture
root>` and stub `check_root`, `get_ssh_port`, `detect_distro`, `tn_node_launch_target` (same logic,
rooted), `obs_run_alloy_docker`, and with `STUB_WAIT=1` `tn_wait_restart_window` (records its
arguments and drives the progress fn once with step and log). PATH shims: `ufw` (logs every call,
answers `status` / `status verbose` / `status numbered` from `ufw/<state>/`, can fail one `allow`),
`systemctl` (logs, `is-active` from `SC_ACTIVE`), `docker` (logs), `ss`, `id`, `ip`, `caddy`.
Fixtures: `mkfx.sh` renders the start wrappers from setup-node.sh's own heredocs (docker and binary
credential blocks) with or without listener overrides, plus hand-written legacy units (b5f0e33-style
docker unit with `-e` on ExecStart and a `;` comment, legacy binary unit with `Environment=` and a
`#` comment); node-info `default` (real v0.15.0 file), `moved`, `two` workers, `legacy` `worker:`
map, missing. `mkofx.sh` builds the observability roots (plain, `# --metrics` comment above the live
line, `# --log.file.format json` comment, other log format, healthcheck present, no node `--http`
line, trailing `# comment`, read-only wrapper, missing wrapper).

- `t_fw.sh /bin/bash` (3.2.57): 124 passed, 0 failed. `t_fw.sh bash` (5.3.15): 124 passed, 0 failed.
  - fw_p2p_ports on 12 fixtures: default 49590/49594; docker override 51000/51004; override + two
    workers 51000/51004 + node-info 49598 as worker-1; binary wrapper override 52000/52004 beats the
    unit's 49590/49594; unit-only env 55000/55004; legacy docker unit 53000/53004 (the `;` line
    ignored); legacy binary unit 54000 + node-info worker 41004 (the `#Environment` line ignored);
    no env + moved node-info 50590/50594; no env + two workers; missing node-info and no node at all
    give 49590/49594; overrides only in a comment line and a trailing `#` word are ignored. Five of
    these repeated with mawk 1.3.4 as awk.
  - Pre-L1 library: override+two-workers gives 51000/51004 without worker-1, no-env+moved gives the
    constants; `--json --status` stdout is one valid JSON line with the warning on stderr;
    view_status shows the warning.
  - `--json --status` on the default fixture with ufw both rules / primary only / inactive / not
    installed: `.ports` equal to HEAD's, and the whole object minus `p2p_ports` equal to HEAD's
    object, one line each.
  - `p2p_ports`: true/true, true/false, null/null (inactive), null/null with installed false; moved
    ports with the matching rule table give 51000 true, 51004 true, 49598 false while `ports` keeps
    `{"49590/udp":false,"49594/udp":false,"43174/tcp":true}`; desired lists 51000/51004/49598 with
    the new labels; no node gives no P2P desired rules; the legacy unit's ports in desired.
  - Enable (`--json --enable`, ufw inactive): no Caddyfile, new and HEAD: no 80/443, P2P allowed,
    `--force enable` the last write, no reset. Caddyfile with the marker on line 1, and one with only
    a tn-rpc fence: `allow 80/tcp` and `allow 443/tcp` logged before `ufw --force enable`. HEAD with
    the same Caddyfile: no 80 (the bug). `--reset` with a site: reset first, 443 between reset and
    enable. Moved ports: 51000/51004/49598 allowed before the enable, 49590/49594 never touched. No
    node: no UDP rules. A failing `ufw allow 51004/udp` stops the run before `ufw --force enable`
    (HEAD control with 49594: same).
  - view_status: service name, "UDP 51000/51004/49598 required inbound", per-port open/CLOSED lines
    with labels, "Node P2P (worker 1) (49598/udp) -- MISSING", "(worker)" for a single worker,
    "Firewall matches the expected configuration", legacy "telcoin-validator.service"; HEAD shows
    "Installed nodes: observer" (ufw inactive); HEAD view_status exits rc 1 with ufw active, new rc 0
    and prints "Default inbound policy: deny (recommended)".
  - manage_node_ports: moved ports opened in one confirm ("UDP ports 51000, 51004 and 49598
    opened"); default with both rules: "already open", no allow.
  - enable_firewall: plan lists the three P2P ports and, with a Caddy site, "Allow TCP 80 and 443";
    result line "Node P2P UDP 51000, 51004 and 49598 allowed"; no web line without a site.
  - `--json --port` for 51000/udp on, 49590/udp off, 43174/tcp on, 22/tcp off, a bad state: output
    byte-identical to HEAD; the refusal still lists "49590/udp 49594/udp 43174/tcp".
  - `tn_resolve_node_type` stubbed to record calls: never called by the new script (status, view,
    desired rules, detect); HEAD control calls it.
  - Every JSON line from every run parses with `jq -e .`.
- `t_obs.sh /bin/bash` (3.2.57): 82 passed, 0 failed. `t_obs.sh bash` (5.3.15): 82 passed, 0 failed.
  - `# --metrics` comment above the live line: new injects `--metrics 127.0.0.1:9101` into the live
    `exec` line and restarts once; HEAD prints "Node already serves a metrics endpoint (--metrics)."
    and leaves the file alone. Same pair for `# --log.file.format json` (HEAD: "Node already writes
    JSON logs."). `--log.file.format terminal` on the live line: new reports it, file untouched, no
    restart; HEAD appends a second `--log.file.format`. Both flags at once: one wait, one restart;
    a rerun reports both present.
  - enable_health messages: rc 0 added; rc 1 "--healthcheck is already on the node command in
    <file>; nothing to add." with no restart; rc 2 "has no live node command (an uncommented line
    that runs node with --http) ..."; rc 3 "Edit the launch file by hand: the node command ends in a
    # comment, or is not one simple command that can be edited safely. ..."; rc 4 read-only and
    missing wrapper "Could not read or write <file>; nothing was changed. ..."; files untouched on
    every non-zero rc; the same three failures through obs_ensure_reth_flags name
    `--metrics 127.0.0.1:9101`; a FLAGS refusal carries the helper's stderr reason; HEAD rc 2 shows
    the old ambiguous message.
  - Wait placement: enable_health logs `WAIT url= fn=addons_say` on the line right before
    `systemctl restart telcoin`, and the progress shows as ">>> stub wait step" / "->  stub
    heartbeat"; a declined restart has no wait and no restart; enable_metrics (full obs_enable):
    `systemctl restart telcoin-alloy.service` with no wait, then exactly one wait right before
    `systemctl restart telcoin`; disable_logging (Alloy restart), disable_metrics (`disable --now`
    + docker rm) and disable_health: no wait.
  - `--json --enable-metrics --token …`: every line valid JSON, `{"event":"step","msg":"stub wait
    step"}` and `{"event":"log","msg":"stub heartbeat"}` on stdout, `done` ok last, wait right
    before the node restart; `--json --enable-health`: no wait, no restart, `applied` health;
    `--json --disable-logs --disable-health`: no wait; rc-2 health enable keeps stdout to the one
    done line.
  - Pre-L1 library: show_status rc 0 with both warnings ("lib/common.sh 1.4.0 has no
    tn_launch_flag_get, so a commented-out flag counts as present and a failed flag edit is not
    explained. ..." and the tn_wait_restart_window one) and obs_status output; enable_health
    restarts without a wait and warns once; rc-1 ambiguity worded "Did not add --healthcheck to
    <file>: it is already there, or the file has no node launch line. ..."; `# --metrics` keeps the
    1.0.1 test (fooled, as before) with the warning; injection still works; `--json
    --enable-metrics` valid JSON ending in done ok.
  - lib/observability.sh 1.0.1 beside setup-observability.sh 1.2.1: status warns "older than
    1.0.2"; enable_health adds the flag and restarts without a wait; the 1.2.0 message on a file with
    no launch line; `--json --enable-metrics` valid JSON.
- `/bin/bash -n` and `bash -n` on the three files: clean.
- `shellcheck -x --severity=error firewall-setup.sh setup-observability.sh lib/observability.sh`:
  clean. Warning level: the same findings as HEAD (firewall-setup 3, setup-observability 3,
  lib/observability 1).
- `/bin/bash tools/check-bash32.sh firewall-setup.sh setup-observability.sh lib/observability.sh`:
  "clean, 3 file(s) scanned".
- Added lines: no bash-4 construct, no apostrophe inside a `${var:-…}` word, no `local x="$(…)"`,
  no `--observer`/`--validator`, no new `common/` reference (the one hit is the existing
  maintainer-only provenance comment, reworded). Name sweep over `*.sh *.py *.env *.html` for all
  21 new names: each appears only in the files that define or call it.
- Real scripts run unsourced as non-root under both bashes: `firewall-setup.sh --json --status`
  exits 1 at check_root and `setup-observability.sh --json --enable-health` prints the early-exit
  done event, as HEAD does.

## Open issues

1. Sidecars: `firewall-setup.sh.sha256`, `setup-observability.sh.sha256` and
   `lib/observability.sh.sha256` show as modified in the tree, but this package did not touch them;
   someone ran `tools/gen-checksums.sh` while the edits were in progress. At hand-back the
   setup-observability and lib/observability sidecars match their files and the firewall-setup one
   is STALE (it predates the view_status fix and the `fw_p2p_allow` change). Regenerate centrally.
   README changelog entries (text above) and the `update-scripts.sh` bump belong to the release
   commit.
2. UI (`ui/static/index.html`, `fwExtraPorts`): it reads `p.open` / `p.ok` from each `p2p_ports`
   object, not `p.allowed`, so a moved or extra port shows "reported" instead of open/closed. It
   should take `p.allowed` (true / false / null). Labels arrive as `primary`, `worker-0`, `worker-1`;
   the page shows them raw ("primary · 51000/udp"). With moved ports the three FW_PORTS toggles still
   act on 49590/49594, which that node does not use; the page could grey them out when `p2p_ports`
   has none of those ports. The `/api/firewall` fallback object in ui/server.py has no `p2p_ports`
   (the page copes). The helper allowlist and `JSON_NODE_PORTS` are unchanged, as specified.
3. Docs: OPERATOR.md, README and the partner guide describe the P2P ports as "UDP 49590/49594";
   worth "the node's P2P ports (UDP 49590/49594 by default)" and a line that enabling the firewall
   now allows 80/443 when Caddy serves the public edge. Not this package's files.
4. `--json --enable-health` (and the log/metrics enables) still end with `done ok:true` when a flag
   could not be added; the explanation goes to stderr only, as in 1.2.0. A `warn` event would let a
   JSON consumer see it.
5. `--metrics` presence is checked, not its address: a node serving metrics on an address other than
   `obs_metrics_addr` (METRICS_PORT) is reported as "already serves a metrics endpoint" while Alloy
   scrapes the other port. `tn_launch_flag_get` returns the value, so a mismatch warning is a
   three-line follow-up.
6. setup-observability.sh `load_node_context` still tells a box with no node to "Run
   setup-validator.sh or setup-observer.sh first" (noted by R-C); left as is (outside C.3).
7. `fw_p2p_ports` finds the unit at `${TN_ROOT_PREFIX}/etc/systemd/system/<svc>.service`, while
   `tn_node_launch_target` uses the unprefixed path; identical in production (prefix empty).
   `FW_CADDYFILE` honours `TN_ROOT_PREFIX` the same way, for the tests.

## Follow-up (coordinator, 2026-10-02; versions stay 1.6.0 / 1.2.1 / 1.0.2)

status: done

- [x] F1a. lib/observability.sh: `OBS_FLAG_ERROR` + `_obs_flag_error` (warn + record), obs_inject_flags
      records every failure message there; presence helpers `_obs_log_format`, `_obs_has_metrics`
- [x] F1b. lib/observability.sh: obs_ensure_reth_flags re-checks each needed flag after the inject, returns 1
      when one is still missing (no restart then), obs_enable returns 1 before recording .node-meta.
      Also (F2 in this file): "blank for observers" wording gone; the two `${DEFAULT_DATA_DIR}/validator`
      fallbacks replaced by `_obs_data_dir` (meta DATA_DIR, else tn_resolve_data_dir, else DEFAULT_DATA_DIR)
- [x] F1c. setup-observability.sh --json: error events + done ok:false on a missing flag; health fail-fast;
      interactive enable_health records ENABLE_HEALTHCHECK_MONITOR only with the flag live. New:
      `health_flag_live`, `json_applied`, `json_fail_flags`, `json_need_node`.
- [x] F2. stale shim / role wording in the three files (setup-observability: "Run setup-node.sh first." and
      "no .node-meta under /etc/telcoin"; JSON contract comment names setup-node.sh; firewall-setup: legacy unit
      names out of the detect_installed_nodes comment; lib/observability: see F1b)
- [x] F3. tests + lint, results below

### JSON behaviour chosen (setup-observability.sh --json)

- `--enable-health`, decided before anything changes:
  - no node service: `{"event":"error","msg":"No node service found, so the node flags for health
    monitoring have no launch file to go into. Nothing was changed."}` then `done ok:false`. No ufw rule,
    no .node-meta write (1.2.0 set both and ended ok:true).
  - `--healthcheck` not on the live node command after the attempt (inject rc 2/3/4, or an older library
    that cannot tell): one `error` event per reason, carrying the rc-worded message (for example "Edit the
    launch file by hand: the node command ends in a # comment, ... Add to the node command in <file>:
    --healthcheck 43174"), then `done ok:false`. No ufw rule, no .node-meta write.
  - flag added: `warn` event "Added --healthcheck 43174 to <file>; the health port opens when telcoin
    restarts (sudo systemctl restart telcoin)." then the rule, the meta key and `done ok:true`.
  - flag already present: no extra event, `done ok:true`.
- `--enable-logs` / `--enable-metrics`:
  - no node service: error event + `done ok:false` before obs_enable runs (nothing changed).
  - a needed flag still missing after the attempt (inject rc 2/3/4, a `--log.file.format` other than json,
    or the old-library ambiguous case): error events + `done ok:false`. .node-meta keeps its previous
    ENABLE_OBSERVABILITY / ENABLE_METRICS (so the add-ons card, which reads .node-meta, does not show the
    pipeline as on) and the node is NOT restarted. Alloy has already been re-rendered and restarted with
    the requested pipeline by then; it ships nothing for it until the flag is on the node command, and
    re-running the enable after fixing the launch file converges.
  - flags present or added: as before (epoch-wait events, node restart, meta written, `done ok:true`).
- `done ok:false` carries `"applied"` with whatever this call did before the failure (disables run
  first, e.g. `["health:disabled"]`) and `"msg":"<what> not enabled: the node launch file needs the
  change in the error event; run this again once it is made"`. Other obs_enable failures (Alloy install
  or start) keep the 1.2.0 error text.
- Interactive mode follows the same .node-meta rule: enable_logging / enable_metrics print "Could not
  enable ... (see messages above)" when a flag is missing (obs_enable returns 1 before writing meta), and
  enable_health does not record ENABLE_HEALTHCHECK_MONITOR=true unless the flag is on the node command
  ("Health monitoring is not recorded as enabled: ..."). The interactive no-node-service path keeps its
  1.2.0 behaviour (rule + meta, with its warning).
- lib/observability.sh: `obs_ensure_reth_flags` re-checks each needed flag after the inject and returns 1
  with the reasons in `OBS_FLAG_ERROR` when one is still missing, without restarting the node (a partial
  edit still gets its daemon-reload); `obs_enable` resets `OBS_FLAG_ERROR` and returns 1 before writing
  .node-meta in that case.

### Wording fixed (F2)

- setup-observability.sh: "No Telcoin node detected (no .node-meta under /etc/telcoin)." / "Run
  setup-node.sh first." (was the role-dir path and "Run setup-validator.sh or setup-observer.sh first.");
  the JSON-contract comment names setup-node.sh.
- firewall-setup.sh: the detect_installed_nodes comment no longer names the legacy units (lib/fallback.sh
  is the only file that may).
- lib/observability.sh: "validator address blank for observers" rewritten; the two `${DEFAULT_DATA_DIR}/
  validator` fallbacks (docker log dir in obs_enable and obs_status) now use `_obs_data_dir`: DATA_DIR
  from .node-meta, else tn_resolve_data_dir (unified or legacy layout), else DEFAULT_DATA_DIR.
- Kept on purpose: the VALIDATOR_ADDRESS meta key, TN_VALIDATOR_ADDRESS and the `validator_address` label
  (they must match the vendored observability/config.alloy), and the adiri `start-validator-node.sh`
  provenance comment (not one of the two shims). No `--observer` / `--validator` text in the three files.

### Tests run (follow-up)

- `t_obs.sh /bin/bash` (3.2.57): 144 passed, 0 failed. `t_obs.sh bash` (5.3.15): 144 passed, 0 failed.
  New sections 7 and 8 (62 checks): --json --enable-health on no-launch-line, trailing comment,
  read-only and missing wrapper (error reason, `done ok:false applied []`, meta untouched, no ufw rule);
  added (warn event, ok:true, meta, ufw rule); already present (only the done line); no node service
  (health and metrics: error, ok:false, nothing changed); --enable-metrics on a trailing-comment line
  (reason, ok:false, ENABLE_METRICS stays false, no node restart, no wait); --enable-logs with
  `--log.file.format terminal` (reason, ok:false, meta off); `--disable-health --enable-metrics` failing
  lists `["health:disabled"]`; successful metrics enable writes meta; interactive metrics failure and
  health not recorded; partial edit (rc 1, metrics added, "Not restarting telcoin yet", no restart, one
  daemon-reload); pre-L1 library (ambiguous reason, ok:false; flag present ok:true); lib/observability
  1.0.1 (generic reason, ok:false); "Run setup-node.sh first." with no node; `_obs_data_dir` for meta
  DATA_DIR, unified without DATA_DIR and the legacy layout; the docker log dir lands under the resolved
  data dir. One earlier check changed: JSON --enable-health on a file with no launch line now prints an
  error event and `done ok:false` (two lines) instead of one `done ok:true` line.
- `t_fw.sh /bin/bash`: 124 passed, 0 failed. `t_fw.sh bash`: 124 passed, 0 failed.
- `/bin/bash -n` and `bash -n` on the three files: clean. `shellcheck -x --severity=error` on the three:
  clean (warning level unchanged from HEAD: 3 / 3 / 1). `/bin/bash tools/check-bash32.sh` on the three:
  "clean, 3 file(s) scanned". Added-line greps: no bash-4 construct, no apostrophe in a default word, no
  `local x="$(…)"`, no shim or `--observer`/`--validator` wording.
- Sidecars: all three `.sha256` files are now stale against the edited files (regenerate centrally).

## Fix pass (V-OPS-2) — 2026-10-02; versions stay 1.6.0 / 1.2.1 / 1.0.2; edits on top of 5eb98b4

status: done

Source findings: tasks/ckpt-fu-V-OPS-2.md (fw F1-F4, obs F-a..F-j), -fw.md, -obs.md.

- [x] P1 (6)  firewall: failing `ufw allow` in --json --enable -> error event + done ok:false (EXIT trap after
       the fd swap); interactive prints an error line; still stops before `ufw --force enable`. Code: fw_error,
       fw_try (every rule step checked, rc returned, so it holds in any errexit context), fw_on_exit trap,
       json_emit/json_event track done and the last error, json_fw_enable sends done ok:false itself,
       enable_firewall / --reset print "Stopped at that step ...".
- [x] P2 (10) firewall: json_fw_status survives a failing `ufw status verbose` ("default_incoming":"unknown");
       "Allowed TCP 80/443" when just added, "Kept" only when they were allowed on a running ufw before;
       p2p_ports with no node: DECISION keep the default entries with "allowed":null (code done)
- [x] P3 (7)  lib/observability: obs_status single awk with s+0 (no set -e/pipefail death on empty /metrics);
       also the two `cmd | grep -q` checks there (list-unit-files, node /metrics) read from here-strings, so
       SIGPIPE under pipefail cannot make them false negatives
- [x] P4 (11) lib/observability (code done): obs_metrics_port (validated, rc 1) / obs_metrics_addr /
       obs_metrics_reth_flags fail on a bad port, `_obs_bad_port_msg`; obs_inject_flags [SHOWN] and rc 1 checks
       the flag on the node command (one message for a trailing-comment marker); `_obs_flags_apply` shared by
       `obs_check_reth_flags` (dry run on a scratch copy) and obs_ensure_reth_flags; obs_enable validates the
       port and runs the dry run before Alloy (OBS_ALLOY_TOUCHED); obs_restart_hint (edit-config item 12);
       `_obs_lib_has`/`obs_lib_check` take a say fn. One restart for logs+metrics: in setup-observability (P5/P6).
- [x] P5 (8)  setup-observability: --json pre-scan, fd swap and EXIT trap in main before parsing; value flags
       (--region/--token/--push-url/--metrics-push-url) without a value, or followed by another option ->
       arg_fail (error event, done ok:false carrying it); json_on_exit uses the last error as the done msg
- [x] P6 (11) setup-observability: json_fail_flags done msg "<what> was not enabled: <first reason>" (+ count
       of further reasons) and "Nothing was changed." only with applied empty and Alloy untouched;
       json_need_node no longer claims it; one obs_enable for --enable-logs --enable-metrics
       (json_enable_pipes); soft-guard warnings via addons_say (warn events in --json); restart hints via
       health_restart_hint / obs_restart_hint; interactive enable_health with no node service stages the ufw
       rule only and does not write .node-meta
- [x] P7 tests (new rows per item) + lint; results below
       - [x] P7a t_fw.sh: baseline pinned to 5eb98b4^ (HEAD now holds package C); moved rows updated (reset
             order ignores the `ufw status` read; "Allowed" when ufw was off); section L added: 178/178 both bashes
       - [x] P7b t_obs.sh section 9: 229/229 both bashes
       - [x] P7c lint

### Decisions

- p2p_ports on a box with no node: the default entries stay (49590 primary, 49594 worker-0), with
  `"allowed":null` even when ufw is active. Kept rather than dropped: the spec says one object per
  fw_p2p_ports line, the list then names the ports a node will use here, and null already means "not
  known / nothing expected" to the UI. `ports` keys are unchanged (they still read the rule table).
- One restart for `--enable-logs --enable-metrics`: run_json_mode makes ONE obs_enable call
  (json_enable_pipes) with both pipelines on, so Alloy is rendered and restarted once and the node gets
  both flags in one edit, one epoch wait and one restart. applied lists both. The 1.2.0 baseline restarted
  the node twice (test row 9.11).
- A failing `ufw allow` (or any rule step) in apply_recommended_firewall: reported by fw_try as
  "<step> failed (exit N)."; --json --enable then sends `{"event":"error",...}` and
  `{"event":"done","ok":false,"action":"enable","ssh_port":...,"active":<now>,"msg":"<error> Stopped there:
  the rules added before it stay, and ufw --force enable was not run."}`, rc 1; interactive prints the
  [ERROR] line and "Stopped at that step ..." and returns to the menu; --reset exits 1. The EXIT trap
  (fw_on_exit) answers any other early end of a --json run with done ok:false carrying "error" and "msg".
- 80/443 wording: "Kept TCP 80/443 open" only when Caddy serves the box and a running ufw already allowed
  both before the run (checked before a --reset); otherwise "Allowed TCP 80/443". The follow-up hint no
  longer shows --json flags to a human.
- obs_enable order: validate (token, URLs, METRICS_PORT), then obs_check_reth_flags (the same flag edits on
  a scratch copy of the launch file; read-only copy when the real file is not writable), and only then
  Alloy. A flag that cannot go on the node command now changes nothing at all; the rare late failure (real
  write fails after the dry run passed) still leaves .node-meta alone.
- METRICS_PORT: obs_metrics_port validates digits and 1-65535; obs_metrics_addr / obs_metrics_reth_flags
  fail (print nothing) on a bad value, obs_enable stops with "METRICS_PORT is '<value>', which is not a port
  number (1-65535). ..." before touching anything, obs_status warns instead of dying. lib/common.sh's
  tn_node_launch_flags then drops --metrics (its command substitution runs without errexit) rather than
  writing the bad value.
- Restart hints (obs_restart_hint, health_restart_hint): "Restart telcoin with edit-config.sh, menu item 12
  (Restart node): sudo bash <dir>/edit-config.sh. It waits for the epoch boundary first when the node is in
  the committee. A plain systemctl restart does not wait: use one (or TN_SKIP_EPOCH_WAIT=1) only if you
  accept restarting the node at an epoch change." Used by the JSON health warn, the interactive "later" and
  "restart failed" lines, and obs_ensure_reth_flags.
- --json soft-guard warnings: addons_lib_check passes addons_say, so the lib/common and lib/observability
  age warnings are `warn` events in --json (print_warn otherwise); obs_restart_window and
  obs_ensure_reth_flags pass their progress fn too (deduped once per helper per run).

### Tests run (fix pass)

- `c-tests/t_fw.sh /bin/bash` (3.2.57): 178 passed, 0 failed; `t_fw.sh bash` (5.3.15): 178 passed, 0 failed.
  Section L (53 new checks): failing `allow 49594/udp`, `allow 22/tcp`, the health-port rule (`allow from`),
  `allow 49598/udp` (moved ports) and `allow 80/tcp` (Caddy site) in --json --enable -> valid JSON, the error
  event text, done ok:false action enable with the "Stopped there" msg, rc 1, no `ufw --force enable`;
  baseline 1.5.2 printed nothing; interactive enable [ERROR] + "Stopped at that step" + no success line;
  --reset [ERROR] + rc 1; manage_node_ports [ERROR] and no "opened"; the EXIT trap (json_fw_status forced to
  fail) -> one line done ok:false with "error"; `ufw status verbose` failing -> one valid status line with
  "default_incoming":"unknown" (baseline printed nothing), view shows "unknown" and carries on; Kept (ufw
  active with 80/443) vs Allowed (ufw off, or running without them) for --json --enable and --reset; no
  --json flags in the hint; no node -> p2p_ports allowed null, ports keys unchanged. Moved rows: reset order
  (first write is the reset), "Allowed" on the enable_firewall screen.
- `c-tests/t_obs.sh /bin/bash`: 229 passed, 0 failed; `t_obs.sh bash`: 229 passed, 0 failed.
  Section 9 (85 new checks): (7) show_status with Alloy up and an empty /metrics -> rc 0, both zero lines,
  reaches the health section (baseline 1.0.1 exits 1); counters summed (1000+234, 5.5e+03); node endpoint
  found; ours found at the top of a 3000-unit list. (11) trailing-comment marker -> one "appears ... only
  outside the node command" message, never "already on", file untouched; same for --healthcheck in --json
  (one error, ok:false); METRICS_PORT '9101;id' -> plain message, no "single shell words", launch file and
  Alloy untouched, meta off, JSON error + "Nothing was changed."; obs_metrics_reth_flags rc 1; addr refuses
  0, 65536, abc, 99999, accepts 9102; status with a bad port warns, rc 0; precheck on trailing-comment,
  missing and read-only launch files -> Alloy untouched, done "metrics shipping was not enabled: ..." with
  "Nothing was changed.", reason names the real file, old done text gone; earlier --disable-* -> no
  "Nothing was changed." claim; no-node alone -> claim; --enable-logs --enable-metrics -> 1 Alloy render,
  1 Alloy restart, 1 wait, 1 node restart, applied both, both flags and both meta keys (baseline: 2 node
  restarts); health warn and interactive hint name edit-config item 12 and the TN_SKIP_EPOCH_WAIT risk;
  pre-L1 lib and lib/observability 1.0.1 warnings arrive as warn events; interactive enable_health with no
  node service stages the rule only and writes no meta. (8) --token, --region, --push-url,
  --metrics-push-url with no value -> error "<flag> needs a value." + done ok:false with that msg, rc 1;
  `--token --enable-logs` refused; baseline printed nothing; interactive prints the error, rc 1. Moved rows:
  "then run this enable again", the no-service wording, interactive metrics stops in the precheck.
- New awk programs checked under mawk 1.3.4 (counter sums, empty input, `exit !f`).
- `/bin/bash -n` and `bash -n` on the three files: clean. `shellcheck -x --severity=error`: clean. Warning
  level: firewall-setup unchanged (3), setup-observability 2 (one SC2015 note removed with the rewritten
  restart line), lib/observability 2 (adds SC2034 for OBS_ALLOY_TOUCHED, read by setup-observability; same
  class as OBSERVABILITY_VERSION). `/bin/bash tools/check-bash32.sh` on the three: "clean, 3 file(s) scanned".
- Sidecars: at hand-back all three `.sha256` match the edited files (regenerated outside this package after
  the last edit); re-run tools/gen-checksums.sh if anything changes before the commit.

### Open issues (fix pass)

- setup-node.sh (not mine): the "Metrics port" prompt (and any METRICS_PORT it records) is not validated, so
  `9101;id` would be pasted into the start-wrapper heredoc. lib/observability now refuses such a value for
  every edit it makes, but setup-node should validate the input (validate_port) before it writes anything.
- The UI firewall card already accepts `"allowed":null`; with no node the default entries stay null.
