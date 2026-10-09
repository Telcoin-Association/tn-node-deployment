status: done

# UI-2a checkpoint (ui/server.py contract side, ui/test_server_contract.py)

Owns: `ui/server.py`, `ui/test_server_contract.py` (new). `UI_VERSION` is not bumped (UI-4).

## Sections

- [x] 1 role token out of helper argv; `helper_status()`; `/api/nodes` `helper`, `role_source`, `role_checked_at` (operator path only)
- [x] 2 hostnames: `_HOST_RE`, `norm_host`, `valid_hostname`, `same_host` replacing `_CADDY_DOMAIN_RE`
- [x] 3 setup: `_setup_env` `TN_SETUP_RPC_DOMAIN`, 400s, keygen/finalize without token
- [x] 4 `api_rpc_enable` with `move_dashboard_to`
- [x] 5 `_parse_json_tail`; `/api/rpc/status` `meta_domain` and pass-through fields
- [x] 6 SSE streams: stderr capture, stray lines as `log`, one `done`, `closed`, GeneratorExit
- [x] 7 `physical_cores()`; `/api/system`, `/api/setup/preflight` counts
- [x] 8 constants: `NETWORK_PUBLIC_WS` removed, testnet RPC, telscan, Jaeger `resolve_service`
- [x] 9 tests: `ui/test_server_contract.py`, py_compile, dev runner smoke
- [x] 10 closing headings

## Notes

- S1: all 14 node subcommands token-free (setup-keygen/finalize included). `read_meta(t=None)` now
  one cache entry ("meta"); `t` only checked. `helper_status()` + `HELPER_API_REQUIRED = 2`,
  `_helper_cache` (60 s when ok, not cached on failure). `_isval_cache` entries are
  `(expires, result, checked_at)`; `onchain_checked_at(t)`. `detect_nodes` stamps
  `role_source`/`role_checked_at` on every installed slot ("local" when `onchain_is_validator`
  answered True/False, else None). `api_nodes` adds `helper` always and the two role fields
  only when not public; the role fields are left out when the detector's slot lacks
  `role_source` (the dev runner's fake `detect_nodes`), so its fixtures still flow.
- S2: hostname helpers live after `bad_type()` (shared by setup, caddy, rpc): `_HOST_LABEL`,
  `_HOST_RE`, `_IPV4_LIKE_RE`, `norm_host`, `valid_hostname`, `same_host`, `host_error(what,
  value)` (400 text: "missing <what>: ..." / "invalid <what> '<v>': use a DNS name such as
  node7.example.com (...)"). Caddy dns-check/enable, rpc dns-check/enable use them;
  `_CADDY_DOMAIN_RE` deleted.
- S3: `_setup_env`: `instance` no longer read or validated; `rpc_domain` normalised; an explicit
  `rpc_public` false (present and falsy) drops the domain; invalid domain → `host_error`;
  `rpc_public` truthy without domain → 400. Env sets `TN_SETUP_RPC_DOMAIN` always ("" when
  none); no `TN_SETUP_RPC_PUBLIC`, no `TN_SETUP_INSTANCE`.
- S4: `api_rpc_enable` builds the four argv shapes per A.5; `move_dashboard_to` invalid →
  `host_error("dashboard hostname", …)`; `same_host` → 400 suggesting `dashboard.<host>`.
- S5: `_parse_json_tail` after `run()`; used by update status (still only when rc 0), caddy
  status, rpc status, both dns-checks. Firewall and addons readers left as they were. rpc
  status adds `meta_domain` = `read_meta()["PUBLIC_RPC_DOMAIN"]` ("" when absent), on every
  path; the script's object still passes through whole (so the four optional keys appear only
  when present).
- S6: one SSE generator exists for actions (`_update_stream`; used by config-set, setup
  keygen/finalize, caddy enable/disable, rpc enable/disable, update prepare/apply). New
  helpers `_ANSI_RE`, `_sse`, `_stream_frame`, `_stderr_tail` (deque of 12, " | ", 900 chars),
  `_reap(proc, grace)`, `_made_up_done(rc)`. `capture_stderr` parameter removed (always on);
  `on_close` now via `resp.call_on_close` (runs even if the generator never started). Child's
  `done` held until exit; second done dropped; child `closed` dropped; error (stderr tail)
  before done when rc≠0; Popen OSError → error + made-up done (127 for FileNotFoundError).
  Popen gets `text=True, encoding="utf-8", errors="replace"` (stray bytes no longer raise).
  The live log tail (`/api/logs/<t>/stream`) is untouched: raw log lines read by EventSource.
  Route comments on config-set / update-prepare no longer claim the page uses EventSource.
- S7: `CPUINFO_PATH`, `_positive_int`, `logical_cpus()` (`nproc` via `run`, else
  `os.cpu_count()`), `physical_cores()` (lscpu via `run` → /proc/cpuinfo blocks → sysctl via
  `run` → logical). `system_info`: `cpu_cores` = physical as a string ("" unknown, type kept),
  `cpu_threads` int. `hardware_profile()["cpu"]` = physical; preflight adds top-level
  `cpu_physical` (= hardware cpu) and `cpu_threads`. All probes go through `run`, so the dev
  runner's lscpu/nproc/sysctl fixtures flow (8 physical, 16 threads).
- S8: `NETWORK_PUBLIC_RPC[2017] = ["https://rpc.adiri.tel"]` (comment says why not
  rpc.telcoin.network); `NETWORK_PUBLIC_WS` deleted, comment explains there is no wss list.
  No `scan.telcoin.network` existed in server.py (nothing to change; `STATUS_PAGE_BASE` is
  status.telscan.xyz and was left). `resolve_service(services=None)`: "telcoin", then
  sorted `telcoin-*` with current-form names before `telcoin-observer…`/`telcoin-validator…`;
  callers updated; `/api/jaeger/status` ignores `?node_type=`. The UI_VERSION history comment
  still names NETWORK_PUBLIC_WS under 1.8.7 (history, left for UI-4's 1.9.0 entry).

## Operator-visible changes

None reach operators until UI-4 bumps `UI_VERSION` to 1.9.0; then, from the server:

- Node actions (updates, config saves, hostname, tracing, log clear, setup, add-on status,
  restart count, metadata) call the helper without `observer|validator`; they need the
  install-ui 1.4.0 whitelist, which the same bundle installs.
- `/api/nodes` (SSH tunnel only) reports whether the helper speaks API 2. An older helper or
  whitelist (a UI updated without re-running install-ui.sh) shows the "helper outdated" banner
  instead of failing silently. It also reports how the validator view was decided (`local` when
  the synced node answered the stake check, otherwise null, which the page shows as "role
  unknown") and when. Nothing of this is sent on the public read-only path.
- Dashboard and public RPC hostnames are checked with the strict rule (two or more labels,
  letters, digits and hyphens, not an IP address, at most 253 characters) after trimming,
  lowercasing and dropping one trailing dot. A bad name gets a 400 that says what is wrong,
  before anything runs.
- Setup takes the public RPC hostname (`rpc_domain`) and passes it to setup-node.sh as
  `--rpc-domain`. Asking for public RPC without a hostname is a 400. Choosing private RPC
  (`rpc_public: false`) ignores a hostname left in the form.
- Enabling public RPC can move the dashboard off the RPC hostname in the same step
  (`move_dashboard_to`); the same hostname for both is a 400.
- Every progress stream ends with one result line. Stray script output shows as log lines
  with terminal colour codes removed. When a step fails, the last lines of its stderr appear
  before the result for every action (updates and config saves included, which used to drop
  stderr). A script that exits without a result gets one from the server ("The script failed
  with exit code N before it reported a result."). Invalid UTF-8 in script output no longer
  breaks a stream.
- CPU counts are physical cores: System shows "8 (16 threads)" and the setup preflight
  judges the hardware tiers on physical cores (an 8-vCPU cloud box with 4 physical cores no
  longer meets the 8-core validator minimum by counting hyperthreads; it gets the warning).
- The Network Block / Consensus Lag comparison on testnet reads `https://rpc.adiri.tel`.
- Traces: the dashboard finds the node's Jaeger service under `telcoin` (what the API 2
  helper registers), falling back to an older `telcoin-observer…` or `telcoin-validator…` name.
- The public RPC card gets `meta_domain` (the hostname saved at setup) for its suggestion.

## Changelog text

### telcoin-ui v1.9.0 — helper API 2, strict hostnames, one stream contract (server part)
The server calls the privileged helper without the old `observer|validator` argument and asks
it for its API version (`helper-version`, cached for a minute when it answers 2). `/api/nodes`
reports that check as `helper` and how the validator view was decided as `role_source` and
`role_checked_at`, on the SSH-tunnel path only. Dashboard, public RPC and move-to hostnames
follow the strict rule shared with the helper and the page, and a bad one is refused with a
400 before anything runs. Setup sends the public RPC hostname as `TN_SETUP_RPC_DOMAIN` and no
longer sets `TN_SETUP_RPC_PUBLIC` or `TN_SETUP_INSTANCE`; public RPC without a hostname is
refused. `/api/rpc/enable` takes `move_dashboard_to`, and `/api/rpc/status` adds `meta_domain`
and passes the advertised and WebSocket fields through when install-caddy.sh reports them.
Status and DNS-check replies are read from the last JSON line, so a warning printed before it
no longer hides the result. Every action stream captures stderr, turns stray output into log
lines, sends exactly one `done` (made up from the exit code when the script sends none,
after an `error` line with the stderr tail when it failed) and then `closed`, and stops
cleanly when the browser goes away. CPU counts are physical cores, with `cpu_threads` beside
them. The testnet comparison endpoint is `https://rpc.adiri.tel`, the unused wss:// list is
gone, and trace lookups follow the helper's `telcoin` service name. Tests:
`ui/test_server_contract.py`.

## Tests run

All on 2026-10-01, macOS, from the repo root.

1. `<scratchpad>/ui-venv/bin/python -m unittest discover -s ui -p 'test_*.py'` (Python 3.14.8,
   Flask 3.1.3, Werkzeug 3.1.9) → 70 tests OK (63 new in `test_server_contract.py`, the 7 in
   `test_public_readonly.py` unchanged and passing).
2. Same suite under `/usr/local/bin/python3.11` with the venv's site-packages on PYTHONPATH →
   70 OK. No 3.10 interpreter on this host; `ast.parse(..., feature_version=(3, 10))` on
   `ui/server.py` and `ui/test_server_contract.py` → OK; no 3.11+ stdlib used
   (no `enterContext`, `datetime.UTC`, `tomllib`, exception groups).
3. `python -m py_compile ui/server.py ui/test_server_contract.py` (3.14 and 3.11) → OK.
4. Mutation check (`<scratchpad>/ui2a-mut/mutate.py`, scratch copies of ui/, tests unchanged):
   23 deliberate breaks, all caught — role token back on tracing-enable / config-set /
   meta-cat, yield after GeneratorExit, child done not held, second done passed, child
   `closed` passed, on_close only inside the generator, TN_SETUP_RPC_PUBLIC back, `match`
   instead of `fullmatch`, "-" always sent, sysctl before /proc/cpuinfo, helper on the public
   path, failed helper check cached, no stderr tail, `rpc_public: false` ignored, same host
   allowed for the move, no ANSI strip, strict text decoding, first JSON line instead of last,
   meta_domain missing, old testnet RPC, legacy Jaeger name first.
5. Dev runner smoke (`<scratchpad>/ui2a-mut/smoke.py`, which starts `ui/dev/serve.py --port
   <random high> --scenario …`): scenarios public, legacy, unserved, private. `/`,
   `/api/nodes`, `/api/rpc/status`, `/api/system`, `/api/setup/preflight`,
   `/api/caddy/status`, `/api/firewall`, `/api/update/status/observer`,
   `/api/addons/status?node_type=observer`, `/api/jaeger/status` all 200; fixtures flow
   (role_source network/cached from the runner's overlay, helper api 2 from the server via the
   runner's fake `run`, meta_domain from the `meta-cat` fixture, cpu 8 physical / 16 threads
   from the lscpu/nproc fixtures, p2p_ports passed through). Streams: update prepare/apply,
   rpc enable (with move), config set → step/log events, the runner's stray line as a `log`
   event, one `done`, `closed`; unserved apply → `error` (stderr tail) then synthesized done
   (rc 1) then `closed`. `POST /api/rpc/enable {"domain":"localhost"}` → 400 with the hostname
   message; finalize with `rpc_public: true` and no domain → 400. No tracebacks in the runner
   output.

## Open issues

1. For UI-2b (same file): `detect_nodes` stamps `role_source` / `role_checked_at` on every
   installed slot after the remap; `api_nodes` copies them from the presented slot and leaves
   both out when that slot has no `role_source` key (the dev runner's fake detector), sending
   null only when no node is installed. `onchain_role()` should set its source
   (network/local/cached/default/None) and check time in the same place. `_isval_cache`
   entries are now `(expires, result, checked_at)` with the accessor `onchain_checked_at(t)`;
   replace both with `onchain_role()`'s cache. `api_status` still calls
   `onchain_is_validator(t, det)` for the validator tab. `read_meta(t=None)` keeps one cache
   entry. `NETWORK_PUBLIC_RPC[2017]` is `https://rpc.adiri.tel` for `network_stake_status`.
   `test_server_contract.py` requires every helper subcommand named in server.py to be
   driven by `CrossFileContractTest.exercise_every_helper_call`; add a line there if UI-2b
   adds a helper call. `/api/validator` epoch fields are UI-2b's (not started here).
2. For UI-3b (owns `ui/dev/serve.py`): the overlay adds `helper` / `role_source` /
   `role_checked_at` on the public path too (it ignores `X-TN-Dashboard-Public`), so the runner
   shows notices there that the server never sends. In `legacy`, the overlay strips
   `cpu_physical` / `cpu_threads` only inside `hardware`, but the server now sends them at the
   top level of `/api/setup/preflight`, and `cpu_cores` is the physical count ("8", not "16").
   In `unserved`, the server's own `helper` wins over the fixture: `api` is null with the error
   "unknown subcommand: helper-version", so the banner shows the error text, not "answers API 1".
3. For UI-3b's payload: `rpc_domain` alone requests public RPC; an explicit `rpc_public: false`
   drops a leftover `rpc_domain` (not validated, not sent); `rpc_public: true` without a domain
   is 400 with "public RPC needs a hostname: …".
4. CI (`.github/workflows/ci.yml`) runs no Python tests at all. Suggest a job on Python 3.10
   with `pip install flask` running `python -m unittest discover -s ui -p 'test_*.py'`. Not in
   this package.
5. Client disconnect mid-stream (UI-3a open issue 1) is unchanged in effect: the child gets 2 s,
   then `terminate()`; the server also closes the stdout pipe, so the script's next write fails.
   If an update apply should finish after the browser goes away, the generator would have to
   hand the child to a background reaper that keeps draining stdout and releases `on_close`
   when it exits. Decision for the orchestrator.
6. The live log tail (`/api/logs/<t>/stream`) is not an action stream: raw log lines read by
   EventSource, no `done` / `closed`. Left as it was; A.4's "every SSE stream" is read as every
   action stream.
7. `/api/addons/status` still requires `?node_type=` (validated, no longer sent to the helper);
   `/api/jaeger/status` accepts and ignores it; its `tracing` object keeps both keys.
8. `scan.telcoin.network` did not occur in `ui/server.py`; nothing changed for it.
   `STATUS_PAGE_BASE` (status.telscan.xyz) was left alone. The `UI_VERSION` history comment
   still mentions `NETWORK_PUBLIC_WS` under 1.8.7 (history; UI-4 adds the 1.9.0 line).
