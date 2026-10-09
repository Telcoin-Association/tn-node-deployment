status: done

# Checkpoint: package A (install-caddy.sh 1.4.0)

Owned file: `install-caddy.sh` (`SCRIPT_VERSION` 1.4.0). No other repo file was edited. Tests
live in the scratchpad under `a-tests/` (`t_a.sh`, `t_live.sh`, `t_json.sh`, `stubs.sh`,
`run-main.sh`, `mk.sh`, `stub_rpc.py`, `stub_ws.py`, `shims/`, `oldlib/` = lib at 7fb7c8d).

## Sections

- [x] 1. Soft guards via `caddy_lib_has` (warns once per group, names update-scripts.sh): epoch
      wait (`tn_wait_restart_window` + `tn_local_rpc_url` -> no wait), `--ws` injection
      (`tn_launch_flag_get` -> not added, https only), keytool (`tn_keytool` + `tn_launch_runner` +
      `tn_node_info_rpc` -> python3 editor and reader), meta (`meta_unset` -> `meta_set KEY ""`;
      `meta_set` missing -> skipped). Status phases use silent fallbacks (stdout is one JSON
      object). Pre-L1 library: rpc-enable degrades with warnings, rpc-disable works (t_json 12).
- [x] 2. `install_caddy_pkg` checks the version (`caddy_installed_version`, `caddy_check_version`):
      below 2.8.0 dies with the official apt repository instructions; an unreadable version only
      warns (`caddy validate` still guards). `caddy_open_ports` / `caddy_close_ports` no longer
      return early when ufw is inactive.
- [x] 3. `caddy_prune_backups` from `caddy_swap_in`: exact `YYYYmmdd_HHMMSS` suffixes only, `LC_ALL=C`
      sort, keeps `CADDY_KEEP_BACKUPS` (5), never deletes `CADDY_LAST_BACKUP` or `.tn-orig`.
- [x] 4. Block v2 from `write_rpc_block` (+ `caddy_rpc_page`), first comment line starts with
      `RPC_BLOCK_STAMP` (`# tn-rpc block v2`); `caddy_rpc_block_stale`; rpc-status `"block_stale"`
      (boolean, last key); human status warns with the refresh command.
- [x] 5. `caddy_edit_node_info` edits worker 0 only; new `caddy_node_info_rpc_get`,
      `caddy_node_info_can_edit`, `caddy_node_info_keep_perms`, `caddy_node_info_write` (keytool
      first; rc 0 ok, 1 failed and restored, 2 no editor); `caddy_node_info_advertise` reads first,
      `cmp -s` gone; `caddy_node_info_advertised` on the shared reader.
- [x] 6. `caddy_restart_window` (once per run, `caddy_wait_say` progress) before the first node
      edit (launch file in `caddy_ws_preflight`, node-info in `caddy_node_info_advertise`);
      `caddy_restart_node_guarded` calls it (no-op by then); the rollback restart never waits.
- [x] 7. `caddy_ws_preflight` on the shared `tn_node_inject_flags` with the regex marker;
      `caddy_launch_inject_target` / `caddy_launch_verify_inject` deleted; new
      `caddy_launch_carries` (`tn_launch_flag_get`, awk fallback) and `caddy_launch_syntax_ok`.
- [x] 8. `caddy_meta_record`: sets `PUBLIC_RPC_DOMAIN`, `PUBLIC_RPC_URL`, `PUBLIC_WS_URL` at the end
      of `do_rpc_enable` (no trailing slash, as setup-node writes them; ws empty without
      WebSocket), removes them at the end of `do_rpc_disable`. `die()` is JSON-aware once fd 3
      is open (`error` event, then `done ok:false` with the reason), which covers the hostname
      clash and every other refusal. `--move-dashboard-to` unchanged and tested.
- [x] 9. Tests (below).
- [x] 10. Closing headings.

## Operator-visible changes

- Public RPC block v2 (existing installs get it by running rpc-enable again with the same
  hostname: a Caddy reload, and no node restart when node-info.yaml and the launch file need no
  change):
  - WebSocket upgrades match case-insensitively. `Connection: upgrade` (Google's balancer,
    nginx) used to get 405; it now gets 101, as do `Upgrade`, `keep-alive, Upgrade` and
    `Upgrade: WebSocket`.
  - A browser GET or HEAD gets 405 with `Allow: POST, OPTIONS` and a short page: what the
    hostname is, the https and wss URLs, a curl `eth_chainId` example, a link to
    https://docs.telcoin.network/.
  - JSON-RPC request bodies above 2 MB (Caddy's 2MB = 2,000,000 bytes) get 413.
  - The block's first comment line reads `# tn-rpc block v2: ...`.
- `rpc-status` JSON gains `"block_stale"`; the human status warns about a stale block and prints
  the exact refresh command.
- node-info.yaml is written by `keytool set-rpc` of the node's own release (binary or docker
  image, read from the launch file), with the python3 editor as fallback. Only worker 0 is
  edited (1.3.0 edited every worker). When worker 0 already advertises the wanted URLs there is
  no edit, no wait and no restart.
- For a node voting in the current committee, rpc-enable and rpc-disable wait for the epoch to
  close before the first node edit (`TN_SKIP_EPOCH_WAIT=1` skips; `TN_EPOCH_WAIT_MAX` caps it).
- `--ws` is added before a trailing backslash on a multi-line start wrapper (1.3.0 refused such
  a line); a launch line that ends in a comment is refused with that reason.
- `.node-meta` records `PUBLIC_RPC_DOMAIN`, `PUBLIC_RPC_URL`, `PUBLIC_WS_URL` on rpc-enable and
  drops them on rpc-disable.
- Caddy older than 2.8.0 is refused before anything is written, with install instructions.
- ufw rules for 80/443 are added and removed while ufw is inactive too.
- Caddyfile backups are pruned to the newest 5 (1.3.0 never pruned).
- `--json` runs: every refusal is an `error` event plus `done ok:false` carrying the reason (was
  `done` "exited early (rc=1)"). Warnings are `warn` events (were `log` events starting with
  "WARNING:"); the epoch wait sends `step` / `log` / `warn`.
- With a lib/common.sh older than 1.6.0: rpc-enable warns and runs without the epoch wait,
  without adding `--ws` (https only unless WebSocket is already on) and with the python3 editor;
  rpc-disable works.

## Changelog text

### install-caddy v1.4.0 — RPC block v2, keytool set-rpc, epoch-aware restarts
rpc-enable writes block v2, stamped `# tn-rpc block v2` in its comment. The WebSocket matcher
ignores case, so `Connection: upgrade` as Google's balancer and nginx send it gets 101 instead of
405. A browser GET or HEAD gets 405 with `Allow: POST, OPTIONS` and a short page saying the
hostname is a JSON-RPC endpoint, with a curl example and the docs link; the page lives in the
Caddyfile, so rpc-disable removes it with the block. JSON-RPC bodies above 2 MB get 413. A block
written by an older version is reported as stale by `rpc-status` (`"block_stale": true`) with the
command to refresh it: rpc-enable with the same hostname, a Caddy reload. node-info.yaml is now
written with `keytool set-rpc` from the node's own release, falling back to the python3 editor,
and only worker 0 is edited, as set-rpc does. The current value is read first: when it already
matches, nothing is edited and the node is not restarted. Before the first node edit, a node
voting in the current committee waits for the epoch to close (`TN_SKIP_EPOCH_WAIT=1` skips).
`--ws` is added through the shared launch-file helper, so it lands before a trailing backslash
and a line ending in a comment is refused. rpc-enable records `PUBLIC_RPC_DOMAIN`,
`PUBLIC_RPC_URL` and `PUBLIC_WS_URL` in `.node-meta`; rpc-disable removes them. Caddy below 2.8.0
is refused with install instructions, ufw rules for 80/443 are kept while ufw is inactive, and
Caddyfile backups are pruned to the newest five. In `--json` runs a refusal such as a hostname
clash with the dashboard is an `error` event with the reason, then `done`. With an older
lib/common.sh the script warns and skips the epoch wait and the `--ws` edit; rpc-disable always
works.

## Tests run

Harness in `<scratchpad>/a-tests/`. `mk.sh` builds copies of install-caddy.sh with the trailing
`main "$@"` removed and `/etc/caddy` redirected to `$TN_TEST_CADDY_DIR`: `work-new` (lib -> repo
lib 1.6.0), `work-old` (lib -> 7fb7c8d lib 1.4.0), `work-head` (HEAD's 1.3.0). Copies are sourced
at top level; `stubs.sh` replaces `check_root`, `tn_resolve_service`, `tn_resolve_data_dir`,
`tn_node_launch_target` and records `tn_wait_restart_window` calls with the node-info and launch
checksums at call time. PATH shims: `systemctl`, `ufw`, `ss`, `hostname`, `sleep`, a recording
`docker`, a `curl` that answers the local RPC probe and ipify, and `chown`/`chmod --reference`
(macOS; `chown root:root` is a logged no-op since the tests do not run as root). Real tools:
Homebrew caddy 2.11.4, `<scratchpad>/caddy-2.8/caddy` 2.8.4, the v0.15.0 build for keytool, jq.

- `t_a.sh`: `/bin/bash` 3.2.57 111/111, `bash` 5.3.15 111/111. Block render (stamp first line,
  no braces in the page, no blank lines, no `<style>`, 3-tab heredoc indent, domain baked in,
  entities, docs link, case-insensitive matcher, body cap); full managed file (dashboard with
  bcrypt + RPC) `caddy validate` OK, `caddy fmt` byte-identical and `fmt --diff` empty, adapted
  405 body equals the page, on 2.11.4 and 2.8.4; stale detection (v2 not stale, HEAD's v1 stale,
  no block not stale); prune (8 backups -> newest 5 plus the protected oldest
  `CADDY_LAST_BACKUP`, `.tn-orig` and `Caddyfile.bak.1_2` untouched, idempotent); ufw allow and
  delete while inactive; version floor (2.6.2 and 2.7.6 refused, 2.8.0, 2.10.0, 2.11.4 accepted,
  "(devel)" warns and continues); node-info readers; python editor worker 0 only (worker 1 and
  primary untouched); advertise with real keytool on a two-worker node-info: changed URL waits
  first (the wait saw the unedited checksum), worker 0 set, worker 1 kept, mode 0640 kept, one
  restart, backup removed; unchanged URL: file untouched, no wait, no restart; http-only change;
  real `set-rpc --clear`; second clear is a no-op; keytool failing (fake binary, rc 2) falls back
  to python with the reason shown; no python3 and no runner: warning, untouched, no wait/restart.
  Preflight: flags land before the trailing backslash, read back with `tn_launch_flag_get`,
  `bash -n` under both bashes, mode 0750 kept, backup equals the original, wait before the edit;
  second run no edit; trailing comment (rc 3) and commented-only line (rc 2) leave the file
  byte-identical with the reason; port held by nginx; node already listening; existing
  `--ws.port 9000` kept, only `--ws --ws.addr` added. Meta set, ws empty, removal, other keys
  and mode 600 kept.
- `t_live.sh` (`bash`): 60/60. JSON-RPC stub (python, POST -> result, GET/HEAD -> 405 like
  reth) on :18545, WebSocket stub (raw socket, answers 101 with a correct
  Sec-WebSocket-Accept; python `websockets` is not installed) on :18546. The block is rendered by
  `write_rpc_block`; for the local run its site address becomes
  `http://rpc.test.example:<port>` with `admin off` / `persist_config off` globals and curl
  `--resolve` (no DNS or TLS). On both 2.11.4 and 2.8.4: GET -> 405, `Allow: POST, OPTIONS`,
  `text/html; charset=utf-8`, body equals the page, gzip applies with `--compressed`; HEAD ->
  405 with Allow; GET/HEAD never reach the stub; POST -> 200 from the stub with
  `Access-Control-Allow-Origin: *`; OPTIONS -> 200 with CORS, not proxied; `Connection: upgrade`,
  `Upgrade`, `keep-alive, Upgrade` and `Upgrade: WebSocket` -> 101, four upgrades at the WS stub,
  none at the RPC stub; 3 MB POST -> 413 and the stub never gets a complete request (see open
  issue 2); a 2,000,000-byte POST passes. HEAD's v1 block: lowercase `upgrade` -> 405 from the RPC
  stub, never at the WS stub (the recorded bug); `Upgrade` -> 101.
- `t_json.sh`: `/bin/bash` 121/121, `bash` 121/121. Subprocess runs through `run-main.sh`; every
  stdout line parses with `jq -e .`, exactly one `done`, last. rpc-enable (keytool, wait before
  the one restart, `step` event from the wait, meta keys, ufw); same hostname again (reload only,
  no wait, no restart); HEAD's v1 block: rpc-status `block_stale: true` with the key order
  ending in `block_stale`, human status warning and refresh command, refresh to v2 with no
  restart; WS off (flags injected, one wait, one restart); dashboard enable then the clash
  (`error` event with the reason, `done ok:false`, Caddyfile byte-identical);
  `--move-dashboard-to` (step event, dashboard moved with its login, RPC block written);
  rpc-disable (cleared with keytool, block removed, dashboard kept, meta keys gone, others kept,
  wait then restart); dashboard disable (teardown, ufw deletes); single objects for status,
  rpc-status, check-dns, rpc-check-dns and the unknown phase; Caddy 2.6.2 refused in JSON
  (`error` + `done ok:false`, no Caddyfile written); the library's real `tn_wait_restart_window`
  logs through `caddy_say`. Pre-L1 library 1.4.0: rpc-enable `done ok:true` with the three
  warnings (no wait, no `--ws`, python editor), launch untouched, https-only advertised, meta set
  with empty `PUBLIC_WS_URL`, one restart; rpc-status reads via python; rpc-disable
  `done ok:true`, cleared, block removed, meta keys emptied with the fallback warning; human
  rpc-disable rc 0.
- Real binary: `keytool set-rpc --http/--ws` and `--clear` with the v0.15.0 build through
  `tn_keytool` (t_a E1-E5, t_json 1-7); keytool rewrites the file and quotes values, which the
  readers handle.
- Probe (not kept as a test): `request_buffers 4MB` / `2MB` inside `reverse_proxy` does not stop
  the upstream from receiving an oversized request's headers on either version.
- Static: `/bin/bash -n` and `bash -n` clean; `shellcheck -x --severity=error` clean (and clean at
  `-S style`, as HEAD); `/bin/bash tools/check-bash32.sh install-caddy.sh` clean; no apostrophe in
  a `${var:-…}` word, no `local x="$(…)"`, no line-number references, no bash-4 constructs in the
  added lines; `caddy_launch_inject_target` / `caddy_launch_verify_inject` have no references left.

## Open issues

1. Release bookkeeping (orchestrator): `install-caddy.sh.sha256` is stale until
   `tools/gen-checksums.sh` runs; README changelog entry above; `update-scripts.sh` bump in the
   release commit. The v1.3.0 README entry says backups are "never pruned"; 1.4.0 keeps five.
2. Body cap semantics: `request_body max_size` streams, so a 3 MB POST gets 413 at the client
   while the upstream receives the headers and the first 2,000,000 bytes, then the connection is
   cut. reth never gets a complete oversized request, so nothing is executed, but the C.5 wording
   "never reaches the stub" does not hold for any spec-shaped block (`request_buffers` was tried
   on 2.11.4 and 2.8.4: no change). If the upstream must not see the request at all, a
   Content-Length matcher answering 413 before `reverse_proxy` would do it for declared lengths
   (chunked bodies would still stream); not added because it changes the block shape.
   Also note Caddy's `2MB` is 2,000,000 bytes (SI), not 2 MiB.
3. check-node (package B, stale-block wording): a tn-rpc block is current when the text between
   `# >>> tn-rpc >>>` and `# <<< tn-rpc <<<` in /etc/caddy/Caddyfile contains `# tn-rpc block v2`
   (its first comment line starts with it). Suggested WARN: "the public RPC block for <domain>
   was written by an older install-caddy.sh: WebSocket upgrades sent with a lowercase
   'Connection: upgrade' get 405, request bodies are not capped and browsers get no page.
   Refresh it: sudo bash <dir>/install-caddy.sh --phase=rpc-enable --rpc-domain <domain> (a
   Caddy reload; the node restarts only if node-info.yaml or its WebSocket flags need a change)".
   check-node's https probe is a POST and its wss probe an upgrade handshake, so v2 does not
   change their results. Advertised URLs are now worker 0 only.
4. UI: rpc-status now always has `block_stale` (boolean), which the page already reads.
   Warnings now arrive as `warn` events instead of `log` lines starting with "WARNING:";
   `streamLineHtml` renders both. A failing run sends its own `error` event with the reason,
   and the server's stderr-tail `error` event then repeats it (the `[ERROR]` line); harmless, but
   the server could skip its tail when the child already sent an `error`. rpc-enable and
   rpc-disable can now hold for the epoch wait (up to `TN_EPOCH_WAIT_MAX`, 1800 s by default) on a
   committee node; `_update_stream` has no time limit, so nothing cuts it.
5. Docs (OPERATOR.md, README, partner guide): landing page and 405 for browsers, 2 MB cap, the
   case-insensitive WebSocket match, the stale-block refresh, the epoch wait and
   `TN_SKIP_EPOCH_WAIT`, keytool set-rpc with worker 0 only, Caddy 2.8.0 floor, backups pruned to
   five, the `PUBLIC_RPC_*` keys being written and removed by install-caddy.
6. Multi-worker nodes advertised by 1.3.0 had the URL on every worker; 1.4.0 (set-rpc semantics)
   sets and clears worker 0 only, so rpc-disable on such a node leaves workers 1+ advertising the
   old URL. Testnet has one worker today; the hand-clear hint in the warnings now names the first
   entry under `p2p_info.workers`.
7. CORS `Access-Control-Allow-Methods` still lists GET (kept from v1, so nothing that reads it
   changes), although GET without an Upgrade header now always gets the 405 page.

## Fix pass (V-OPS-1)

Findings: `tasks/ckpt-fu-V-OPS-1.md`. Version stays 1.4.0; edits on the committed 7acc653 file
(`git diff --stat`: +552 / -198 against 7acc653). No other repo file touched.

- [x] F1. Messages in `caddy_restart_node_guarded`, `caddy_node_info_advertise`, `caddy_launch_rollback`
      (and the WebSocket plan/inject/verify) go through `caddy_say`; the restart itself is a `step`
      event. New `caddy_note` collects what a successful run left undone; the JSON `done` message
      and the human summary ("Open items: ...") name it. Decisions below.
- [x] F2. `do_rpc_disable`: the RPC block goes first (reload only, no lock, no wait), the
      `.node-meta` keys next, then `caddy_node_info_advertise clear` (lock + wait + edit + restart
      only when worker 0 still advertises something).
- [x] F3. `caddy_norm_host` (trim, lowercase, one trailing dot) + strict `caddy_validate_domain`
      (253 chars, two or more labels, not `^[0-9.]+$`) + `caddy_domain_problem` reasons (IPv4:
      "is an IP address; Caddy needs a DNS name ... to get a certificate") + `caddy_require_domain`.
      `main` normalises `--domain`, `--rpc-domain`, `--move-dashboard-to` once; every phase and the
      interactive prompts normalise again and use only the normalised name.
- [x] F4. `caddy_node_lock` (`TN_EXIT_TRAP_OWNED=1; tn_acquire_update_lock`) before the first node edit
      and before the wait; rpc-enable takes it before the Caddyfile swap whenever the plan says a
      node change will follow, so a held lock refuses with nothing changed; rpc-disable takes it
      after the takedown. Released at the end of each operation (`caddy_node_unlock`) and by the
      EXIT trap (`caddy_exit_cleanup`, also run by `json_on_exit`). Refusal: "an update is in
      progress (PID N); try again when it has finished." plus what was already done. Soft guard:
      without `tn_release_update_lock` (lib < 1.5.0) the run warns and goes on without the lock. The
      dashboard phases never edit the launch file or restart the node, so they take no lock.
- [x] F5. Decide first: `caddy_ws_plan` (dry run of the inject on a copy with the same file name in a
      `mktemp -d` dir) and `caddy_node_info_needs_edit`; the lock and the wait happen only in
      `caddy_ws_inject` / `caddy_node_info_advertise`, right before an edit that will happen.
- [x] F6. `do_check_dns_json` normalises and validates first; an invalid name gives the usual object
      with `propagated:false`, the reason in `note` and `error`, exit 1 (nothing reaches dig).
- [x] F7. `main` pre-scans `--json`; a value flag given last is `caddy_usage_error`: `error` +
      `done ok:false` (JSON) or `[ERROR]` on stderr (human), exit 2.
- [x] F8. `json_escape`: backslash, quote and every U+0001..U+001F as `\u00XX` (`printf -v`, `%b`; no
      subshell per character; bash strings cannot hold NUL).
- [x] F9. Page: the wss:// sentence is its own `@WS@`-tagged paragraph, printed only when the plan
      serves WebSocket (`write_rpc_block DOMAIN OUT WITH_WS`); human status shows wss:// only while
      the WS port listens; rollback `die`: "<svc> failed after the change, so <node-info.yaml
      (worker rpc) | the --ws launch flags | both> was rolled back. <running again on its previous
      configuration | still down; start it with ... (the Caddy site answers 502 until it runs)>
      Find the cause in: journalctl -u <svc> -n 100, then run this again."; version warning
      without empty parentheses; JSON step "Advertising the endpoint in node-info.yaml" (the
      restart step comes from the restart); refusals (names, clash) before any step (also for the
      dashboard enable); interactive texts say the node restarts only when something changes.
- [x] F10. Tests and static checks (below).

### Item 1 decisions (when `done` stays ok:true)

- ok:true, with a `warn` event and a closing note, when the endpoint is serving (Caddy reloaded)
  but: node-info.yaml is missing ("not advertised in node-info.yaml"); no editor can run (same
  note); no node service, so no restart ("node not restarted: no node service found"); the node
  is still starting after 60 s ("node still starting; the change applies once it is up"); wss:// is
  not advertised ("wss:// not advertised"); the WS port is not answering after the restart
  ("wss:// not answering yet").
- rpc-disable stays ok:true once the site is removed; when node-info.yaml cannot be cleared the
  `warn` event and the note "node-info.yaml still advertises the endpoint" say so. A missing
  node-info.yaml on disable is an info line (nothing to clear), no note.
- ok:false (`error` + `done`): invalid name, hostname clash, Caddy below 2.8.0, validate or reload
  failure, update lock held (rpc-enable: nothing changed; rpc-disable: the site is removed and the
  message says node-info.yaml still advertises it), node-info edit failure in set mode, and the
  brick-guard rollback.

### Fix-pass tests

- `t_a.sh` 176/176 under `/bin/bash` 3.2.57 and `bash` 5.3.15. New rows: the http-only page (no
  wss://, no tag leaks, validate + fmt byte-stable on 2.11.4 and 2.8.4); plan vs inject (plan
  changes nothing, no wait, no lock, the dry-run copy removed; inject waits with the lock held and
  the launch unedited at wait time; refused edits (trailing comment, commented line) give http
  with no wait; `.service` launch file planned with unit rules); hostnames (normalisation, valid and
  invalid tables, IPv4 and digits-and-dots refused with the reason, 253/255 chars); `json_escape`
  (all 31 control characters round-trip exactly through jq, none left raw); the lock (held by a
  live PID refused with the PID and the note, holder untouched, stale holder taken over, release,
  refusal before any wait); advertise notes (missing node-info, no service), `needs_edit`, and the
  rollback `die` text (what was rolled back, where to look, no "will 502" when the node is back).
- `t_json.sh` 245/245 under both bashes. New rows: restart step only when a restart follows; lock
  released after a run; clash refused before any step; rpc-disable order (reload, then WAIT with
  no RPC block in the Caddyfile, then restart); old library: lock warning, warnings are `warn`
  events; warn events + done notes for missing node-info and no service; IPv4 refused before any
  step; ` NODE.Test.Example. ` normalises (no rewrite, no wait, no restart, lowercase Caddyfile,
  meta and done domain); check-dns with `-f/etc/hosts` and an IPv4 (object, error key, rc 1); held
  lock (rpc-enable refused, no Caddyfile, no wait; rpc-disable removes the site then refuses);
  six value-flag-last command lines (error + done, rc 2) and human `--phase` ([ERROR], rc 2); a
  keytool runner printing colour codes and CR (every line parses, no raw control bytes); a refused
  launch edit with node-info as wanted (no wait, no restart, http-only page); human status without
  wss:// when the port is not listening.
- `t_live.sh` 60/60 (2.11.4 and 2.8.4, unchanged expectations).
- Interactive smoke (piped stdin, `/bin/bash`): an IPv4 entry refused with the reason,
  `NODE.Test.Example.` stored as `node.test.example`, lock gone afterwards.
- Static: `bash -n` (3.2, 5) clean; `shellcheck -x --severity=error` clean (also `-S style`);
  `/bin/bash tools/check-bash32.sh install-caddy.sh` clean; no apostrophe in a `${var:-…}` word, no
  `local x="$(…)"`.

### Fix-pass open issues

1. Unchanged from the first pass: the 3 MB POST note (upstream sees up to 2,000,000 bytes, never a
   complete request), workers 1+ keep a 1.3.0 advertisement, a hand-edited v2 block counts as
   current and is rewritten by a same-host rpc-enable (the backup keeps it).
2. The page is written from the plan. If the planned `--ws` edit then fails at apply time (the dry
   run passed, so only an I/O error or a file changed in between), wss:// is not advertised but the
   page still mentions it until the next rpc-enable.
3. The interactive menu releases the lock after each operation, so a menu left open does not hold
   up update-node.sh.
4. UI: `warn` events now also carry the restart guard and rollback lines; the `done` message may end
   with a parenthesised list of open items; a usage error exits 2.
