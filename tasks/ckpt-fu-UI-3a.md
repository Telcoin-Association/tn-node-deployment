status: done

# UI-3a checkpoint (ui/static/index.html shared helpers + System tab, ui/dev/serve.py)

Owns: `ui/static/index.html`, `ui/dev/` (new). Nothing else was edited. No version bumped
(`UI_VERSION` 1.9.0 is the orchestrator's, in UI-4).

## Sections

- [x] 1 shared helpers and `streamPost`: `HOST_RE`/`normHost`/`validHost`/`sameHost` plus `hostOfUrl`,
  `dashHost`, `suggestRpcHost`, `knownRpcHost`, `triState`, `DEFAULT_RPC_HOST`; core `streamFetch(url, init,
  handlers)` + `streamPost(url, body, handlers)` + `streamEvent`. Readers replaced: `streamSetup` (now a
  one-line wrapper over `streamPost`), `streamCaddy` and `streamRpc` (deleted). The two EventSource
  consumers of GET action streams (`startUpdateStream`, `saveConfigField`) also moved onto `streamFetch`
  (method GET); `state.updateES`/`configES` became `updateAbort`/`configAbort` (AbortController).
  `CADDY_DOMAIN_RE` and `appendUpdateLine` deleted. The live log tail keeps its EventSource (a read-only
  tail, not an action).
- [x] 2 notice banner: `#noticeBanner` under `#roBanner`; `noticeItems(n, hasNode)`, `fmtWhen`, `noticeHtml`,
  `updateNoticeBanner()` called from `loadNodes()`.
- [x] 3 RPC card: `renderAccessCards()` (caddy + rpc status in one `Promise.all`, kept in `state.access`);
  `renderRpcCard()` badges (`advBadges`, `wsListenBadge`), WebSocket warnings, advertised-vs-served mismatch
  note, "advertised but not served" state with `#rpcWithdraw` (`rpcWithdraw` → `/api/rpc/disable`),
  stale-block hint with `#rpcRefresh` (`rpcEnable(dom)`), placeholder from `suggestRpcHost`, live
  `syncRpcInput` (bad-host hint `#rpcDomainHint`, `#rpcMoveBox`/`#rpcMoveDash` prefilled with
  `dashboard.<host>`), `move_dashboard_to` in the enable body. `dnsCheck(route, inputSel, ipSel, outSel)`
  shared by both cards (the two copies were identical).
- [x] 4 dashboard card: enabled-view clash note, `syncCaddyInput` (`#caddyDomainHint`, "use it" button
  `#caddyUseSug`), placeholder `dashboard.<rpc host>`, enable refuses a hostname Caddy serves RPC on.
  Firewall: `fwExtraPorts(f)` rows under "Other node ports (read-only)". CPU: `cpuText(cores, threads)` on
  the System card, `hwInfoRow(hw, pf)` on the preflight card. Endpoint constants: the page has no testnet
  public RPC entry, no explorer link and no `scan.telcoin.network` mention, so nothing changed (the Network
  tab's status-page links were left alone).
- [x] 5 dev runner `ui/dev/serve.py`.
- [x] 6 tests (below).
- [x] 7 closing headings.

## Notes

- Every existing element id is kept (`caddyCard`, `caddyDomain`, `caddyUser`, `caddyPublicIp`, `caddyPw`,
  `caddyPw2`, `caddyDns`, `caddyEnable`, `caddyDisable`, `caddyDnsResult`, `caddyLog`, `rpcCard`,
  `rpcDomain`, `rpcPublicIp`, `rpcDns`, `rpcEnable`, `rpcDisable`, `rpcDnsResult`, `rpcLog`, `fwCard`,
  `updLog`, `cfgLog`, `setupLog`, ...). New ids: `noticeBanner`, `caddyDomainHint`, `caddyUseSug`,
  `rpcDomainHint`, `rpcMoveBox`, `rpcMoveDash`, `rpcRefresh`, `rpcWithdraw`.
- For UI-3b: validate with `validHost(normHost(x))` and send the normalised value; `suggestRpcHost(rpc,
  caddy)` gives the wizard's RPC placeholder; `streamSetup` already goes through `streamPost`; `dnsCheck`
  takes any route and selectors; the dev runner's `/api/validator` fixture carries the six epoch fields
  (stripped in `legacy`).
- `streamFetch` contract: resolves with the first `done` (a second is ignored, not rendered), stops at
  `closed`, wraps non-JSON payloads and JSON without a string `event` as `{event:'log'}`, reads both SSE
  frames and bare lines (CRLF too), toasts "<what> request failed" / "<what> rejected: <error>" itself,
  and appends an error line when the connection ends with neither `closed` nor `done`.
- Dev runner scenarios: `public`, `private`, `unserved` (advertised but not served, outdated helper,
  unknown role, apply fails without done), `legacy` (strips every A.4 addition: today's server). Patch
  seams: `server.run`, `server.subprocess` (namespace proxy with a fake Popen), `detect_nodes`,
  `resolve_service_unit`, `unified_install`, `detect_public_ip`, `latest_docker_image`,
  `latest_source_tag`, the `api_status` and `api_validator` views, `urllib.request.urlopen`; an
  after_request overlay adds A.4 fields the running server does not send yet (server-sent keys win) or
  strips them for `legacy`.

## Operator-visible changes

- System tab, Public RPC card: "Advertised to peers" (HTTPS and WSS) and "WebSocket port" rows, each
  "unknown" when the helper does not report it; a warning when HTTPS is advertised without WebSocket or the
  WebSocket port is not listening; a note when node-info.yaml advertises a different name from the one
  Caddy serves; a refresh button when the Caddy block predates install-caddy 1.4.0.
- Advertised but not served (node-info.yaml advertises an RPC URL, Caddy has no RPC site): the card says so
  and offers "Withdraw advertisement" (runs the existing rpc-disable, which clears node-info.yaml and
  restarts the node).
- The RPC hostname placeholder is the node's own name (served domain, then advertised host, then the name
  saved in .node-meta, then the dashboard host without `dashboard.`, else `node7.adiri.telcoin.network`)
  instead of `rpc.example.com`. Typing the dashboard's hostname opens a box that moves the dashboard to
  `dashboard.<name>` in the same enable (`move_dashboard_to`).
- Dashboard card: warns when the typed hostname is the node's RPC hostname and offers `dashboard.<name>`;
  the enabled view warns when the dashboard sits on the RPC hostname. Field label "Dashboard hostname".
- Both cards check hostnames with the strict rule (two or more labels, no IP addresses, at most 253
  characters) and send them lowercased without a trailing dot.
- Firewall card: node ports reported beyond the three toggles are listed read-only.
- CPU reads "8 (16 threads)" on the System card (and "8 cores (16 threads)" on the setup preflight) when
  the server sends thread counts.
- A banner under the header when the privileged helper is outdated (re-run
  `sudo bash ~/telcoin-node-scripts/ui/install-ui.sh`) or the validator view comes from a cached or unknown
  answer.
- Progress panes: stray script output shows as log lines, `warn` events and "public RPC not enabled" lines
  show in yellow, a dropped connection adds a "check the status before you retry" line, and the update and
  config-save streams are read with fetch, so a dropped connection no longer re-sends the request (which
  re-ran the update step or the config save).

## Changelog text

### telcoin-ui v1.9.0 — public RPC card, notices, one stream reader (page part)
The System tab reads Caddy and public RPC status together. The RPC card shows whether node-info.yaml
advertises the endpoint to peers over HTTPS and WebSocket and whether the node's WebSocket port is
listening, warns when only HTTPS is advertised or the port is closed, and says when the advertised name
differs from the one Caddy serves. When node-info.yaml advertises an endpoint Caddy no longer serves, the
card says so and offers to withdraw it. A Caddy block written by an older install-caddy.sh gets a refresh
button, which is a reload. The hostname field suggests the node's own name instead of `rpc.example.com`,
and typing the dashboard's hostname opens a box that moves the dashboard to `dashboard.<name>` in the same
step. The dashboard card warns when its hostname is the node's RPC hostname and offers `dashboard.<name>`.
Both cards check hostnames with the strict rule the server and helper use. The firewall card lists node
ports beyond the three toggles, read-only, and the CPU count reads "8 (16 threads)". A banner says when
the privileged helper is outdated or when the validator view comes from a cached or unknown answer. Every
progress pane uses one stream reader: stray script output appears as log lines, warnings and "public RPC
not enabled" lines are yellow, and the update and config-save streams no longer use EventSource, whose
automatic reconnect could run the action a second time.

## Tests run

All on 2026-10-01, macOS, node v24.10.0, venv Python 3.14.8 with Flask.

1. `python3 <scratchpad>/extract-script.py ui/static/index.html <scratchpad>/page.js && node --check
   <scratchpad>/page.js` → `node --check OK` (3,035 script lines). Re-run after the last edit: OK.
2. `node <scratchpad>/page-helpers-test.mjs ui/static/index.html` → "page helper checks passed: 81
   assertions (22 hostname rows)". It loads only named declarations from the page script into a vm
   context. Rows: good hosts, `localhost`, `1.2.3.4`, `1.2.3.4.5`, `1.2.3.a` (valid), `a..b`, trailing dot
   (valid after normHost, refused raw), `a.b..`, uppercase with spaces, 63- and 64-char labels, 253 and 254
   chars, leading/trailing hyphen, underscore, punycode, empty, URL, host:port; `sameHost`, `hostOfUrl`;
   the placeholder chooser in all five orders plus invalid and disabled-dashboard cases; `knownRpcHost`;
   `triState`; `noticeItems` (missing fields, helper current/failed/old, each role_source, no node);
   `fwExtraPorts` (strings, bare ports, objects); `cpuText`; `hwInfoRow` (today's payload, hardware
   fields, top-level fields); `streamLineHtml` classes ("public RPC not enabled" → warn); `streamPost`
   with a fake fetch: SSE split across chunks with a stray line, `warn`, two `done` (first wins), events
   after `closed` ignored; bare-line stream; CRLF frames; no done → null plus error line; 400 → null plus
   "Rejected: invalid domain" toast; done then EOF → no error line.
3. Dev runner smoke: `ui-venv/bin/python ui/dev/serve.py --port 18931 --scenario public`; `curl` of `/`,
   `/api/nodes`, `/api/caddy/status`, `/api/rpc/status`, `/api/firewall`, `/api/system`,
   `/api/validator/validator`, `/api/status/validator`, `/api/update/status/validator`,
   `/api/addons/status?node_type=validator`, `/api/jaeger/status`, `/api/network/status`,
   `/api/setup/preflight`, `/api/setup/defaults`, `/api/version/validator`, `/api/build-info`,
   `/api/netstat`: all 200 with the fixture values (role_source network, helper api 2, dashboard on
   dashboard.node7..., rpc enabled + advertised http/ws + block_stale, p2p_ports with 49595/udp,
   cpu_cores 8 + cpu_threads 16). Page HTML contains `id="noticeBanner"` and the new ids/functions.
   Streams through today's server: `/api/update/prepare/validator?ref=v0.15.0-adiri`, POST
   `/api/rpc/enable` with `move_dashboard_to`, `/api/config/validator/set?...` each replay step/log, the raw
   stray line, done, then `{"event":"closed"}`.
4. Headless walk-through (Chrome `--headless=new --remote-debugging-port=9333`, driven by
   `<scratchpad>/walk.mjs` over CDP), one dev runner per scenario, no page exceptions in any:
   - public: no banner; CPU "8 (16 threads)"; RPC card "HTTPS advertised WSS advertised", "listening",
     stale-block hint + Refresh button; firewall "Node P2P · 49595/udp reported"; Update → Prepare log shows
     step, log, the stray line, the warning line, one "✓ Prepared ..." and toast "Update prepare succeeded".
   - private: cached-role banner with the check time; RPC placeholder node7.adiri.telcoin.network; typing
     `NODE7.adiri.telcoin.network.` shows the move box prefilled `dashboard.node7.adiri.telcoin.network`;
     `1.2.3.4` shows the bad-host hint and hides the box; Enable sends
     `{"domain":"node7.adiri.telcoin.network","move_dashboard_to":"dashboard.node7.adiri.telcoin.network"}`.
   - unserved: helper banner ("It answers helper API 1; this dashboard needs 2") plus unknown-role banner;
     "Advertised but not served" with Withdraw (ran the disable stream); placeholders node7... and
     dashboard.node7...; typing the RPC name in the dashboard field shows the clash hint, "use it" fills
     `dashboard.node7.adiri.telcoin.network` and clears the hint; firewall "Worker 1 P2P · 49595/udp open".
   - legacy (today's server: `/api/nodes` without role_source/helper, rpc-status with only
     installed/running/enabled/domain, no cpu_threads, no p2p_ports, no epoch fields, preflight hardware
     without cpu_physical/cpu_threads; checked with curl): no banner, CPU "16", RPC card "HTTPS status unknown
     WSS status unknown" and WebSocket port "unknown" with no warnings, no extra firewall rows, Update →
     Prepare works.

## Open issues

1. Leaving the Update or Config tab mid-stream aborts the request, as closing the EventSource did, and
   `_update_stream` then terminates the script after 2 s. An apply cut off this way is risky. Kept as is
   (behaviour unchanged); worth deciding whether the server should let the script finish after a client
   disconnect, or the page should keep the stream running in the background.
2. `p2p_ports` has no fixed format in spec C.3. The page accepts "49595/udp", a bare port, or objects
   `{spec|port, proto, open|ok, label}`; plain strings show "reported" because `ports` keeps only the three
   toggle keys. If package C sends objects with `open`, the card shows open/closed.
3. Fields the page reads whose shape A.4 leaves open: `role_checked_at` (page accepts epoch seconds, ms or
   an ISO string) and where preflight puts `cpu_physical`/`cpu_threads` (page reads `hardware` first, then
   the top level). `/api/firewall` already passes the helper's JSON through, so `p2p_ports` needs no server
   change. No other server field is needed beyond A.4.
4. The stale-block refresh re-runs rpc-enable without an inbound IP; on a 1:1-NAT host first enabled with
   `--public-ip`, its DNS check may fail (the log says why). rpc-status could report the inbound-IP
   override so the refresh can resend it.
5. After a successful enable, disable or withdraw the card re-renders and the stream log disappears (as
   before), so warnings printed during the run are only visible while it runs. The new badges cover the
   WebSocket outcome.
6. If the server sends `helper` on the public read-only path, the helper banner (with the install-ui
   command) shows there too. UI-2 may want to omit `helper` for public requests.
7. The Network tab links `https://status.adiri.telcoin.network/` while the server reads
   `https://status.telscan.xyz`; outside the endpoint decision, left alone.
8. The node checks (`page-helpers-test.mjs`), the CDP walk (`walk.mjs`) and the extractor live in the
   scratchpad. They could move to `ui/dev/` if the orchestrator wants them kept (node only; the walk also
   needs Chrome).
9. The dev runner overrides the `/api/status/<t>` and `/api/validator/<t>` views with fixtures (those routes
   read files and the node's RPC, not subprocesses), so UI-2b's epoch arithmetic is not exercised by it.

## Fix pass (V-UI)

Scope (coordinator, from tasks/ckpt-fu-V-UI.md): may edit ui/static/index.html, ui/dev/serve.py,
ui/server.py, ui/install-ui.sh (and the matching rows in ui/test_server_contract.py). No version bumps,
no git writes, no sidecars.

- [x] F1 fwExtraPorts reads `allowed` (open/ok only when absent), `fwPortLabel` (primary → Primary P2P, worker-N → Worker N P2P); serve.py `P2P_PORTS` in every scenario (1.6.0 shape, allowed true/false/null)
- [x] F2 `RPC_PUBLIC_NEEDS_HOST`; `host_error(what, value, example)` sentences; labels dashboard hostname / public RPC hostname / new dashboard hostname; move clash text a sentence too; contract rows updated; serve.py NO_DOMAIN_ERROR = server constant
- [x] F3 notices: cached "The node's role is from a cached answer; the chain could not be reached (last answer <UTC>)."; default/null with `role_address` null "The node's role is not known yet (no execution address); the view defaults to observer."; otherwise "The node's role is not known; the chain could not be reached and no saved answer applies, so the view defaults to observer." /api/nodes had no address, so server.py now sends `role_address` (onchain_role returns `address`; detect_nodes copies it; operator path only)
- [x] F4 server: ok when api >= required (api reported as is), every answer cached 60 s (docstring says why); tests: cache row now expects the failure cached, then a re-probe after expiry; new `test_helper_status_newer_api`. Page: `helper-newer` notice "The helper answers API N; this dashboard was built for 2 and may miss features." (also when an older server says ok:false with api > required)
- [x] F5 four copy buttons (Node ID x2, BLS key/Authority ID via detailRowCopy, execution address) use `data-copy`/`data-copy-label` and one delegated document click listener; no other inline handler interpolates data
- [x] F6 server.py line-number comment (names CONSENSUS_REGISTRY / node_stake_status)
- [x] F7 install-ui.sh: both prompts read only when `[ -t 0 ]`, default "y", `read ... || var="y"` for EOF on a TTY; `tr` lowercase kept
- [x] F8 checks (results below)

Beyond the list: `role_address` in /api/nodes (needed for F3); the move-clash 400 is a sentence too;
`host_error` takes an `example` (dashboard routes say dashboard.node7.example.com); `setupRejectText`
adds a full stop only when the server text has none (the wizard showed "Private.."); serve.py gets
`EXEC_ADDRESS` and `role_address` fixtures.

Fix-pass tests (2026-10-02):
- `node --check` on the extracted script: OK (3,322 lines).
- `ui-venv/bin/python -m unittest discover -s ui -p 'test_*.py'`: 128 tests OK (126 + newer-API helper
  row + no-execution-address chain row; rows updated for the new texts, role_address, failure caching).
- py_compile ui/dev/serve.py and ui/server.py: OK.
- ui/install-ui.sh: `/bin/bash -n` and bash 5 `-n` OK; `shellcheck -x --severity=error` clean;
  `tools/check-bash32.sh` clean. `ui/tests/helper_test.sh`: 205/205 under 3.2.57 and 5.3.15.
- `node <scratchpad>/page-helpers-test.mjs ui/static/index.html`: 139 assertions pass (includes UI-3b's
  rows; new: 1.6.0 p2p shape, allowed over open/ok, moved primary, fwPortLabel, notice kinds and texts,
  setupRejectText).
- Headless walks (`<scratchpad>/fixpass/run-walks2.sh`, a copy of the verifier's walk with the new
  expectations): public/validator 12 pass, legacy/observer 8, fresh-reject/observer 13 (reject reads
  "The server refused to finalize: Public RPC needs a hostname. Enter one or choose Private. Nothing was
  started, ..."), unserved/observer 13 (no-address notice), private/observer 13 (cached notice); 0 fail,
  no console errors. Firewall card in every walk: "Worker 1 P2P · 49595/udp open", "Worker 2 P2P ·
  49596/udp closed", "Worker 3 P2P · 49597/udp reported". Copy buttons: no inline copy handlers, the
  delegated listener answers (headless shows "Copy failed", no clipboard permission).
- Note: the verifier's own walk (vui-tests/page/walk.mjs) still expects "unknown answer" for unserved;
  that text is gone by design (F3). The ui/static/index.html sidecar is stale after the last edit.
