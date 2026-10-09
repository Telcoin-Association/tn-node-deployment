status: done

# UI-3b checkpoint (setup wizard public RPC, completion card, validator epoch fields, dev runner)

Owns: `ui/static/index.html`, `ui/dev/serve.py`. Nothing else was edited. No version bump
(`UI_VERSION` 1.9.0 is the orchestrator's, in UI-4).

## Sections

- [x] 1 wizard Public card and hostname input: both cards selectable; `setupRpcPublicFields()`
  (`#cfgRpcDomain`, `#cfgRpcDomainHint`, `#cfgRpcDns`, `#cfgRpcDnsResult`), `setupRpcHost()`,
  `syncSetupRpcHost()` (bad host, dashboard-name clash warning), `loadSetupAccess()` (placeholder via
  `suggestRpcHost`), `setupRpcDnsCheck()` (cached per host in `state.setup.rpcDns`); `dnsCheck` gained
  `opts.advisory` (yellow, "You can continue…") and returns the HTML; Continue requires a valid host
  when Public and says why; `captureCfg` keeps `rpcDomain`.
- [x] 2 review row, payloads, 400 handling: review row "Public at <host>" / "Private";
  `buildSetupPayload` sends `rpc_public:false` unless `setupRpcHost()` gives a valid name, then
  `rpc_public:true` + `rpc_domain`; `streamFetch` handler `onReject(status, error)` replaces the
  toast when given (existing callers unchanged); `streamSetup(phase, pass, onReject)`;
  `showSetupReject`/`setupRejectText`; keygen refusal shows the server message in `#setupReject`
  (progress card hidden, "Nothing ran"); finalize refusal adds an error log line and a note in
  `#finalizeReject` (keys kept, retry Finalize); runKeygen refuses Public without a valid host
  instead of going private silently.
- [x] 3 completion card: `#setupRpcSummary` filled by `fillSetupRpcSummary()` from a fresh
  `/api/rpc/status`; `rpcSummaryHtml(s, wanted)` (Status enabled/private, Hostname when enabled,
  `advBadges`, `wsListenBadge`; one warning when the asked-for name is not enabled or node-info.yaml
  advertises an unserved URL; unreadable status, or the server's fallback reply with `error`, says so).
- [x] 4 validator epoch fields and countdown: `unixSeconds`, `epochClock(v, clientMs)`,
  `epochEndsIn(clock, clientMs)` ("ends in 1h 05m 09s" / "ending now" / ''), `epochSeatRows(v)`
  (Activation and Earliest seat only for status 2/3/4; Seated "epoch N" or "not in the next three
  committees"), `epochTileMeta(base, v, synced, clock, clientMs)` (today's line kept, extras appended),
  `tickEpochCountdown` on one 1 s interval updating `#epochEndsIn`; `state.epochClock` set from the
  fetch time in `renderValidatorDashboard`, null unless `/api/status` says `synced: true`.
- [x] 5 dev runner fixtures: scenarios `fresh` and `fresh-reject` (no node until finalize exits 0,
  flipped in `FakePopen.wait`); `SETUP {domain, installed}`; `rpc_status()`/`meta_domain()` follow
  the wizard's hostname after a fresh setup ("nodns" in the name: private, URL advertised);
  keygen/finalize canned lines follow setup-node.sh's wording; `setup_view()` wraps both setup
  routes (records the hostname, `fresh-reject` answers the public finalize with 400
  `NO_DOMAIN_ERROR`, A.4 rpc_domain 400s emulated only while `server` lacks `norm_host`, never for
  `legacy`); per-scenario validator data `VAL_ACTIVE`, `VAL_PENDING` (fixture server clock +900 s),
  `VAL_STAKED` (boundary passed); `legacy` still strips the six epoch fields.
- [x] 6 tests (below).
- [x] 7 closing headings.

## Notes

- New element ids: `cfgRpcDomain`, `cfgRpcDomainHint`, `cfgRpcDns`, `cfgRpcDnsResult`, `setupReject`,
  `finalizeReject`, `setupRpcSummary`, `epochEndsIn`. Every existing id and every UI-3a helper is
  kept; `dnsCheck` and `streamFetch` only gained optional parameters.
- Why the wizard's DNS check uses `#cfgPubIp` as the inbound IP: the helper passes the wizard's
  public IP as `--public-ip`, and setup-node.sh uses it as `RPC_INBOUND_IP` for its own DNS gate.
- Why a finalize refusal never sends the operator back through keygen: setup-node.sh `--json`
  refuses to overwrite existing node-keys.

## Operator-visible changes

- Setup wizard, Configure step: the Public RPC card is selectable (it was "coming soon"). Choosing
  it shows a "Public RPC hostname" field whose placeholder is the node's own name (same rule as the
  System tab), a live hostname check, a warning when the name already serves the dashboard, and a
  "Check DNS" button; the check also runs when the field loses focus. The DNS result is a yellow
  warning that says setup can continue. Continue requires a valid hostname while Public is selected
  and says why: without one, setup keeps the node private.
- Review step: "RPC access" reads "Public at <hostname>" or "Private".
- Requests: keygen and finalize send `rpc_domain` (lowercase, no trailing dot) with
  `rpc_public: true`; Private sends `rpc_public: false` and no `rpc_domain`.
- A refused setup request (for example a 400 for the hostname) shows the server's own message on
  the step: under Generate Keys for key generation, in the backup card above Finalize for finalize,
  where the button stays available for a retry.
- Completion card: a Public RPC section read from the server after finalize (status enabled or
  private, hostname, advertised HTTPS and WSS, WebSocket port), with a warning when the requested
  name is not enabled yet or node-info.yaml advertises a URL nothing serves.
- Validator view, Current Epoch tile: on a synced node whose server sends the new epoch fields, a
  live "ends in 1h 05m 09s" countdown ("ending now" once the boundary passes) and rows for the
  activation epoch, the earliest committee seat and the seated epoch ("not in the next three
  committees" when there is none). The countdown is corrected for a browser clock that differs
  from the server's. Without the fields, or while the node syncs, the tile is unchanged.

## Changelog text

### telcoin-ui v1.9.0 — public RPC in the setup wizard, epoch countdown (page part)
The setup wizard offers public RPC. Choosing Public asks for the hostname, suggests the node's own
name, checks it with the strict hostname rule, and checks DNS against the public IP the wizard
uses. A DNS mismatch is a warning, because setup-node.sh checks again before it enables public RPC
and keeps the node private when the name does not resolve yet. The review step shows the choice,
and the request carries the hostname as `rpc_domain`. When the server refuses a setup request, the
wizard shows the server's message where the operator clicked. The completion card reads the public
RPC status after finalize: enabled or private, the hostname, what node-info.yaml advertises, and
whether the WebSocket port listens. On the validator view, the Current Epoch tile of a synced node
counts down to the epoch boundary, corrected for a browser clock that differs from the server's,
and shows the activation epoch, the earliest committee seat and the epoch the validator is seated
in, if any of the next three.

## Tests run

All on 2026-10-01, macOS, node v24.10.0, venv Python with Flask, Chrome 154 headless.

1. `python3 <scratchpad>/extract-script.py ui/static/index.html <scratchpad>/page.js && node --check
   <scratchpad>/page.js` → OK after every section (final: 3,285 script lines).
2. `node <scratchpad>/page-helpers-test.mjs ui/static/index.html` → "page helper checks passed: 125
   assertions" (UI-3a's 81 plus 44 new; UI-3a's version kept as `page-helpers-test.ui3a.mjs`). New
   rows: countdown with the browser 900 s fast and 3600 s slow (both read the server's remaining
   time), counting down between polls, hours/minutes/seconds formats, partial second rounds up,
   negative and zero remaining and a boundary passed between polls → "ending now", millisecond,
   numeric-string and ISO timestamps, missing `now`/`epoch_ends_at`/unreadable value/no reply → no
   clock and empty text; seat rows for active, pending, staked-not-activated (no activation rows),
   no `seat_epoch` key, legacy reply (nothing); tile meta unchanged when not synced, sync unknown, or
   legacy reply, extended when synced, server text escaped; payload: Public + host → `rpc_public:
   true, rpc_domain: host`, messy host (`  NODE7.Adiri.Telcoin.Network. `) normalised, Private →
   `rpc_public: false` and no `rpc_domain` even with a stale name, invalid or empty host → never
   `rpc_public: true`, passphrase only when asked; completion summary for today's server, a 1.9.0
   served endpoint, DNS-not-ready, private, no reply, the server's fallback reply, escaping.
3. Dev runner smoke (`<scratchpad>/ui-venv/bin/python ui/dev/serve.py --port 18961 --scenario fresh`
   plus curl): `/api/nodes` role None and nothing installed; keygen with `rpc_public` and no domain →
   400 `NO_DOMAIN_ERROR`; `rpc_domain` 1.2.3.4 → 400 "invalid rpc_domain: 1.2.3.4"; keygen and
   finalize with node7.adiri.telcoin.network stream step/log/done/closed; afterwards `/api/nodes?fresh=1`
   role observer, installed; `/api/rpc/status` enabled on the name with https/wss advertised and
   `meta_domain`; DNS check for a "nodns" name → propagated false with a note. Validator fixture per
   scenario with `--role validator`: public status 3, activation 412, earliest 414, seat 580, 7,199 s
   left; private status 2, 581/583, seat null, 599 s left with the server clock +900 s; unserved
   status 1, activation 0, earliest 2, seat null, −46 s; legacy without the six fields.
4. Headless walk (`node <scratchpad>/walk.mjs 9333 <url> <scenario>`, extended), one runner each, no
   page exceptions in any run:
   - `fresh`: both RPC cards, Public selected, placeholder node7.adiri.telcoin.network; Continue with
     no hostname stays on step 4 with "Enter the public RPC hostname, or choose Private. Without a
     hostname, setup keeps the node private."; nodns name → yellow warning ending "You can
     continue…"; ` NODE7.adiri.telcoin.network. ` → "✓ … (matches this server)."; result survives a
     re-render; review "Public at node7.adiri.telcoin.network"; keygen and finalize bodies both
     `{"rpc_public":true,"rpc_domain":"node7.adiri.telcoin.network"}`; completion card "Status enabled,
     Hostname node7…, HTTPS advertised WSS advertised, WebSocket port listening"; Open Dashboard →
     dashboard view, Setup tab hidden.
   - `fresh-reject`: nodns name warns but Continue proceeds; keygen succeeds; finalize refused: log
     line "✗ Finalize refused by the server: …", note "The server refused to finalize: …. Nothing was
     started, and the keys from the first phase stay where they are…", Finalize button enabled,
     toast "Finalize refused: …".
   - `public`, `private`, `unserved`, `legacy` with `--role validator`: tile "ends in 1h 59m 58s" then
     "…56s" two seconds later with Activation 412 / Earliest seat 414 / Seated 580; private "ends in
     9m 58s" (skew corrected) with 581 / 583 / "not in the next three committees"; unserved "ending
     now" with only the Seated row; legacy "on-chain epoch" only. UI-3a's System and Update checks in
     the same runs unchanged (move box, bad-host hint, enable body with `move_dashboard_to`, "use
     it", withdraw, Update prepare toast).
   - `private`, `unserved`, `legacy` with the default (observer) role: no epoch tile, placeholders as
     before, no page errors.
5. `node <scratchpad>/walk-extra.mjs 9333 <fresh url>` (new): keygen with an invalid address → server
   400 shown as "The server refused the request: invalid address. Nothing ran on this server. Go back
   to Configure…", progress card hidden, button re-enabled, toast "Key generation refused: invalid
   address"; Public with an empty name → guard note and no request sent; System tab DNS checks still
   non-advisory ("Ready to enable." in green; red "✗" without "You can continue"). The walk scripts
   now clear exceptions that `Runtime.enable` replays from the previous page before navigating.
6. `ui-venv/bin/python -m py_compile ui/dev/serve.py` → OK; `ui/dev/__pycache__` removed; no runner
   or Chrome process left.

## Open issues

1. Server (UI-2a/UI-2b) details A.4 leaves open, as the page now reads them:
   - `epoch_ends_at`, `now`, `epoch_started_at`: the page expects Unix seconds as JSON numbers on the
     server clock (it also accepts milliseconds and ISO strings). Worth fixing in A.4 like
     `role_checked_at`.
   - `seat_epoch`: the page shows a Seated row only when the key is present and reads null as "not in
     the next three committees". If the committee lookup fails, the server should omit the key rather
     than send null, or the page will claim the validator is not seated.
   - `earliest_seat_epoch` is `activation_epoch + 2` even for a Staked validator (activation 0 gives
     2); the page hides Activation and Earliest seat unless status is 2, 3 or 4. The server could send
     null outside those statuses.
   - The countdown is gated on `/api/status` `synced` (sent today); no new field needed.
   - The setup 400 `error` strings are shown verbatim to operators, so UI-2a should word them for
     people (the dev runner's `NO_DOMAIN_ERROR` is a stand-in).
2. `ui/static/index.html.sha256` shows as modified in `git status`. It was clean at the start of this
   run and I did not touch it; with the page changed, it needs regenerating centrally anyway.
3. A hostname that already serves the dashboard gets a warning only: setup-node.sh has no
   `--move-dashboard-to`, so that install ends with public RPC pending, which the System tab's RPC
   card can finish (it moves the dashboard).
4. Pre-existing, not changed: the "← Back" button on step 5 stays usable after keygen, and returning
   to step 5 offers Generate Keys again, which setup-node.sh refuses because the keys exist. A finalize
   refusal therefore only offers a retry; since keygen accepted the same payload, a finalize-only
   refusal means the server changed between the two calls.
5. Pre-existing latent race: `stepPreflight` writes to `#pfList` after its await, so replacing step
   1's body before the preflight answers throws. Not reachable from the UI (Continue stays disabled
   until the answer), only from scripted navigation; left alone.
6. The dev runner's A.4 setup emulation switches itself off once `server.py` has `norm_host` (UI-2a),
   after which the server's own 400 messages show; the `fresh-reject` refusal stays a fixture.
7. The test scripts (`page-helpers-test.mjs`, `walk.mjs`, `walk-extra.mjs`, `extract-script.py`) live
   in the scratchpad, as UI-3a's did; they could move to `ui/dev/` if they should be kept.
