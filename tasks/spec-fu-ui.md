# Appendix A: UI contract and specs

Read `tasks/spec-fu-shared.md` first.

## A.1 Helper (`HELPER_API=2`)

† marks the 14 legacy subcommands. On these a leading `observer|validator` is dropped only when the
argument count exceeds the token-free arity (`update-prepare` 1, `config-set` 2, `set-hostname` 1,
the other eleven 0). Never strip on other subcommands (`docker-status observer` and
`set-hostname validator` are legal).

| Subcommand | Args | Runs |
|---|---|---|
| `helper-version` (new) | none | prints `2` |
| `tracing-enable`† `tracing-disable`† | none | wrapper edit with `--node-name telcoin`, then restart |
| `update-check`† `update-apply`† `update-discard`† | none | `update-node.sh --json …` with no role flag |
| `update-prepare`† | `<ref>` | `--json --prepare --ref` |
| `restart-count`† `log-clear`† `addons-status`† `meta-cat`† | none | resolved unit, log or meta |
| `config-set`† | `<field> <value>` | `edit-config.sh --json --set f=v` |
| `set-hostname`† | `<name>` | resolved data dir and meta |
| `setup-keygen`† `setup-finalize`† | none | `setup-node.sh --json --phase=…` directly (no shim); adds `--rpc-domain` only when `TN_SETUP_RPC_DOMAIN` is set; never sends `--rpc-public` |
| `caddy-dns-check`, `rpc-dns-check` | `<host> [<ip>]` | strict hostname check |
| `caddy-enable` | `<host> <user> [<ip>]` | strict hostname check |
| `rpc-enable` | `<host> [<ip>\|-] [<dash-host>]` | adds `--move-dashboard-to`; dash host strict and different from `<host>` |

Node resolution without a token (mirrors `lib/fallback.sh`): unit `telcoin`, then
`telcoin-validator`, then `telcoin-observer`; meta `/etc/telcoin/.node-meta`, then the legacy role
dirs; data dir from the meta's `DATA_DIR`. Path variables are plain (overridable after sourcing)
and `main` runs only when the file is executed, so tests can source it.

Strict hostname rule, identical in helper, server and browser: at most 253 characters, two or more
labels matching `[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?`, and not `^[0-9.]+$`. Server and
browser normalise first (trim, lowercase, drop one trailing dot). Python uses `fullmatch`.

## A.2 Sudoers (final state)

- The nine `/bin/systemctl` lines are unchanged.
- Exact helper lines (no arguments): `jaeger-start`, `jaeger-stop`, `jaeger-status`,
  `helper-version`, `tracing-enable`, `tracing-disable`, `update-check`, `update-apply`,
  `update-discard`, `restart-count`, `log-clear`, `clear-rotated`, `caddy-status`, `caddy-disable`,
  `rpc-status`, `rpc-disable`, `firewall-status`, `addons-status`, `meta-cat`, `setup-keygen`,
  `setup-finalize`, `docker-detect`, `internal-ip`.
- Wildcard lines: `update-prepare`, `config-set`, `set-hostname`, `set-logrotate`,
  `caddy-dns-check`, `caddy-enable`, `rpc-dns-check`, `rpc-enable`, the six `docker-*` with arguments.
- `firewall-port`: the six enumerated lines stay.
- `env_keep`: today's list plus `TN_SETUP_RPC_DOMAIN`, minus `TN_SETUP_RPC_PUBLIC` and `TN_SETUP_INSTANCE`.
- Overlap: the UI-1 commit keeps the 28 token lines beside the new ones, marked TRANSITIONAL;
  UI-4 (orchestrator) removes them. `UI_VERSION` is bumped only in UI-4 so operators receive one
  consistent bundle. `install-ui.sh` `SCRIPT_VERSION` goes to 1.4.0 in UI-1.

## A.3 `install-ui.sh` order (sudoers last)

1. Root check, `WAS_ACTIVE`. 2. python3, pip, Flask: on failure exit with nothing touched.
3. Create the user. 4. Sources exist; `bash -n` on the helper source.
5. Build the sudoers candidate at `/etc/sudoers.d/.telcoin-ui.XXXXXX` (sudo skips dotted names),
   `chmod 440`, `visudo -cf`; on failure exit and leave the live file alone.
6. Install the helper (`install … .new` then `mv -f`). 7. Engine copies (drop the two shim scripts
   and remove stale copies). 8. `server.py`, requirements, static files, `chown`. 9. Logrotate seed.
10. Unit file, `daemon-reload`. 11. `mv -f` the candidate over the live sudoers. 12. Restart.

Reason: a new helper accepts both call forms, so an abort after step 6 leaves a working UI; a
sudoers swap before an abort would not. Also replace `${var,,}` at the two prompt lines and
refresh the stale header and section comments.

Mixed states and why each is acceptable: abort in steps 2 to 5 changes nothing live; abort after
the helper leaves old server, old sudoers and a tolerant helper; a later restart in that state
gives a new server with old sudoers, where `helper-version` fails and the banner says to re-run
the installer; between the sudoers swap and the restart the old server is refused for under a
second; stale browser tabs keep working because routes and payloads stay compatible; a box with
only one legacy unit resolves to it; a box with both legacy units targets `telcoin-validator`,
as `lib/fallback.sh` does.

## A.4 HTTP (no new routes; `test_public_readonly.py` passes unchanged)

| Route | Change |
|---|---|
| `GET /api/nodes` | adds `role_source` (`network`\|`local`\|`cached`\|`default`\|null), `role_checked_at`, `helper` `{ok, api, required: 2, error}` |
| `POST /api/setup/<t>/{keygen,finalize}` | body adds `rpc_domain`; `rpc_public: true` without a domain is 400; invalid host is 400 |
| `GET /api/rpc/status` | adds `meta_domain`; passes `advertised_http`, `advertised_ws`, `ws_listening`, `block_stale` through only when present |
| `POST /api/rpc/enable` | optional `move_dashboard_to`; 400 when invalid or equal to the RPC host |
| `GET /api/validator/<t>` | adds `epoch_started_at`, `epoch_duration`, `epoch_ends_at`, `now`, `earliest_seat_epoch`, `seat_epoch` |
| `GET /api/system`, `/api/setup/preflight` | CPU counts become physical; add `cpu_threads` (and `cpu_physical` on preflight) |
| every SSE stream | exactly one `done`, then `closed`; a missing `done` is synthesised as `{"event":"done","ok":rc==0,"synthesized":true,"rc":N,"msg":…}`, preceded by an `error` event with the stderr tail when rc≠0; non-JSON stdout lines arrive as `log` events |

`<node_type>` URL segments keep their meaning (presentation slot); only the helper argv drops the token.

Shapes fixed by the orchestrator after UI-3a (the page already reads them this way):
- `role_checked_at`: Unix seconds as a JSON number (server clock), or null.
- `/api/setup/preflight`: `cpu_physical` and `cpu_threads` at the TOP level of the response (not
  inside a nested `hardware` object); `/api/system` likewise top level.
- `/api/firewall/status` passes `p2p_ports` through from firewall-setup unchanged: a list of
  `{"port": <int>, "proto": "udp", "label": "primary"|"worker-N", "allowed": true|false|null}`.
- The public read-only path (the unauthenticated mode `test_public_readonly.py` covers) never
  includes `helper`, `role_source` or `role_checked_at` in `/api/nodes`; those are for the operator.
- Validator epoch fields (UI-2b): `epoch_started_at`, `epoch_ends_at` and `now` are Unix seconds
  as JSON numbers; `epoch_duration` seconds; `earliest_seat_epoch = activation_epoch + 2` is sent
  only for status 2, 3 or 4 (omitted otherwise); `seat_epoch` is the first epoch in C … C+2 whose
  committee contains the address, `null` when none of the three does, and OMITTED when the lookup
  failed (the page shows null as "not in the next three committees"). Setup 400 messages are read
  by operators verbatim: write them as sentences ("Public RPC needs a hostname. Enter one or choose
  Private.").
- SSE endpoints keep their current GET or POST method and `text/event-stream` framing; the page
  reads every ACTION stream (setup, update, config save, caddy, rpc) with one fetch-based reader
  (no EventSource), so the server must not rely on EventSource reconnects and must end every
  action stream with `done` then `closed`. The read-only log tail (`/api/logs/<t>/stream`) stays
  an EventSource with raw lines and no `done`.

## A.5 `ui/server.py`

UI-2a (contract): remove the role token from every helper argv; `helper_status()` (cached)
feeding `/api/nodes`; `_HOST_RE`, `norm_host`, `valid_hostname`, `same_host` replacing
`_CADDY_DOMAIN_RE`; `_setup_env` sets `TN_SETUP_RPC_DOMAIN` and drops `TN_SETUP_RPC_PUBLIC` /
`TN_SETUP_INSTANCE`; `api_rpc_enable` argv `[…,"rpc-enable",d] + ([ip or "-"] if ip or move) +
([move] if move)`; `_parse_json_tail` (last line that parses as a JSON object) for update status,
caddy and rpc status and both dns-checks; `_update_stream` always captures stderr to a temp file,
wraps stray stdout as `log`, synthesises `done`, and returns without yielding after
`GeneratorExit`; `physical_cores()` (same order as the library: `lscpu`, `/proc/cpuinfo`,
`sysctl hw.physicalcpu`, logical) used by `hardware_profile` and `system_info`; delete
`NETWORK_PUBLIC_WS` and leave a comment saying why there is no `wss://` list (the balanced
hostnames answer 405 to a WebSocket upgrade; only per-node hostnames serve wss);
`NETWORK_PUBLIC_RPC[2017]` becomes `["https://rpc.adiri.tel"]`; Jaeger `resolve_service` prefers
`telcoin`, then any `telcoin-*`.

UI-2b (chain): `decode_validator_info` (strict: 7 words, high bits zero, retired ≤ 1) shared by
`registry_stake_status` and `api_validator`; `network_stake_status` asks at most two public RPC
endpoints at 3 s each; `onchain_role()` replaces `onchain_is_validator` (network first, then the
synced local node, then the saved answer when the address matches, else none), cached 30 s, saved
to `/opt/telcoin-ui/node-role.json` (atomic replace; already owned by the UI user and removed by
remove-node); `detect_nodes` always uses the `observer` slot first and remaps from the chain,
external containers included; delete `resolve_node_type` and `_docker_node_type`; `_legacy_role`
for legacy path fallbacks; epoch fields from one `tn_getCurrentEpochInfo` call per poll with the
boundary block timestamp cached per epoch, `earliest_seat_epoch = activation_epoch + 2`,
`seat_epoch` from `tn_getEpochInfo` for C … C+2 cached per epoch.

## A.6 `ui/static/index.html`

UI-3a: `HOST_RE`, `normHost`, `validHost`, `sameHost`; one `streamPost()` replacing three stream
readers; warn style for "public RPC not enabled" log lines; a `#noticeBanner` for an outdated
helper and for a cached or unknown role. System: `renderAccessCards()` fetches caddy and rpc
status together; RPC card gets the advertised badge (missing keys mean unknown), a WebSocket
warning, an "advertised but not served" state with a withdraw button, a refresh hint when
`block_stale` is true, a suggested hostname placeholder (rpc-status domain or advertised host,
then `meta_domain`, then the dashboard host minus `dashboard.`, else `node7.adiri.telcoin.network`),
and the move-dashboard box when the input equals the dashboard host; dashboard card warns on a
clash and suggests `dashboard.<rpc host>`; firewall card shows extra reported ports read-only.
CPU shown as "8 (16 threads)". The testnet public RPC entry in the page follows the endpoint
decision (`https://rpc.adiri.tel`). `ui/dev/serve.py` (patches `server.run` and `Popen` with
fixtures) is the maintainer dev runner.

UI-3b: wizard with both RPC cards selectable, hostname input with a DNS check that warns but never
blocks, review row, payload `rpc_domain`, completion card showing the real `/api/rpc/status`.
Validator view: activation epoch, earliest seat, seated epoch, and "ends in" on the epoch card
(only when synced, corrected with `now`).

## A.7 UI tests (no network, no sudo, temp dirs only)

- `ui/tests/helper_test.sh` under bash 3.2 and 5: sourcing does not run `main`; token and
  token-free forms give identical engine argv for all 14; `set-hostname validator` keeps its
  argument; unit resolution matrix (unified, observer only, validator only, both, mixed);
  `TN_SETUP_RPC_DOMAIN` gives `--rpc-domain` and `--rpc-public` never appears; bad hostnames
  rejected; four `rpc-enable` argv shapes; `helper-version` prints 2.
- `ui/test_server_contract.py`: `_setup_env` rules; `api_rpc_enable` argv and 400s; stream
  behaviour with a fake `Popen` (own done, missing done rc 1, rc 0 no done, stray line, ANSI
  stripped, `close()` mid-stream, `closed` last); `_parse_json_tail`; `physical_cores` fixtures;
  a cross-file check that every helper call in `server.py` matches a sudoers line, every sudoers
  subcommand exists in the helper, `env_keep` covers every `TN_SETUP_*` the server sets, and the
  installer steps are in the order above.
- `ui/test_server_chain.py`: role source matrix (network, local, cached, default, address
  mismatch); `NODE_TYPE=validator` in the meta has no effect; external container remap; strict
  decode rejections; epoch field arithmetic; one epoch-info call per poll.
- `ui/dev/serve.py` plus `node --check` on the extracted script, then the walk-through.

Run the Python tests with `<scratchpad>/ui-venv/bin/python -m unittest discover -s ui -p 'test_*.py'`.
