# Shared spec: private alerts (setup-alerts.sh, lib/alerts.sh, lib/tn-heartbeat.sh)

Round of 2026-11-04. Issue **#60** ("Private alerts: a push heartbeat from the node host to a
monitor the operator owns"). Branch `private-alerts` off `hardening-followups` (base 4a2cf6e);
the PR targets `hardening-followups` and is folded into the unreleased `scripts-v2.1.0` note.
Every agent reads this file first, then its own `tasks/spec-alerts-<PKG>.md`. Line numbers
below are as of 4a2cf6e; re-verify an anchor before you edit near it.

## Ground rules

- **One checkout, no commits.** Everyone works in `/home/drtnarg/coding/telcoin/tn-node-deployment`
  on `private-alerts`. Agents never run `git add`, `git commit`, `git checkout`, `git stash`,
  `git reset`, `git rebase` or `git push`. Read-only git is fine. The orchestrator commits.
- **Disjoint files.** Edit only the files your package spec lists. A change another package's
  file needs goes under "Open issues" in your checkpoint with the exact text.
- **Versions.** Touched scripts keep `SCRIPT_VERSION="2.1.0"`; the new files carry `2.1.0`
  (`SCRIPT_VERSION`, `ALERTS_VERSION`, `HEARTBEAT_VERSION`). `COMMON_VERSION` stays 2.1.0.
  Nobody runs `tools/gen-checksums.sh` except the orchestrator (W5).
- **Attribution.** No `Co-Authored-By`, no "Generated with", anywhere.
- **bash 3.2** everywhere (CI runs every fixture under macOS `/bin/bash` 3.2 and `bash:3.2`):
  indexed arrays only, no `declare -A/-g/-n`, no `${v,,}`/`${v^^}`, no `mapfile`/`readarray`,
  no `&>>`, `|&`, `[[ -v`, `wait -n`, negative subscripts, `${v@X}`, `%(…)T`, `;;&`. Empty
  arrays expand as `${a[@]+"${a[@]}"}` under `set -u`. Inside `$( )` never write a `case` with
  bare `pat)` patterns: move it into a function or write `(pat)`. `mv -f` without `-T` in the
  runner (busybox and BSD have no `-T`); `date +%s` only (no `-d`, no `%(…)T`); POSIX awk
  (mawk, BSD awk, busybox awk). `tools/check-bash32.sh FILE` must be clean on every file.
- **Boundary rule** (AGENTS.md): nothing operator-facing calls, sources or points at `common/`
  or `devnet-genesis/`. Never emit `--observer`/`--validator`.
- **Root owns the install** (AGENTS.md): root files only through `tn_write_root_file`,
  `tn_install_root_binary`, `_tn_root_layout_dir`, `meta_set`; never a pipe into a root writer
  (`tools/tests/root_write_pipe_test.sh`); the one secret (the targets file) is fed from a
  process substitution run in the main shell, as `obs_write_token_file` does
  (lib/observability.sh:538-546). The runner's own state lives in its `StateDirectory`, never
  under `/etc/telcoin`.
- **Never testnet-gated.** `setup-alerts.sh`, `lib/alerts.sh` and `lib/tn-heartbeat.sh` call
  neither `require_testnet` nor `is_testnet`/`is_testnet_like`, and `tn_testnet_addons_present`
  (lib/common.sh:8504) is not changed. The alerts files never join `TESTNET_ADDONS_BUNDLE`.
- **No node restart.** Enable, change, test, refresh and disable never stop or restart the node,
  so they run neither `tn_committee_down_guard` nor `tn_wait_restart_window`. They take the
  update lock (`addon_meta_write_begin` for a write; `addon_meta_lock` for `--test`; nothing for
  `--status`) and call `tn_host_baseline_refresh` through a `declare -F` guard after a change
  went through.
- **URLs are secrets.** A target URL is never on argv (except the operator's own `--target`,
  which warns), never in the environment of a child, never in a log line, a JSON event, the
  state file or `.node-meta`. Everywhere a target is named it appears as `kind@host`
  (`kuma@kuma.example.org`). curl receives the URL through `-K <(printf 'url = "%s"\n' "$url")`.
- **Network-hits lint** (`tools/check-network-hits.sh`): no shipped line names the testnet
  (`adiri`) or a hub address without a `# network-gated:` marker. Avoid naming it at all.
- **Prose** in comments, help text and messages: plain, specific, no filler, no em-dashes, no
  line-number references. Messages say what happened and what to do.
- **Temp files** go in the scratchpad
  `/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/17b49380-e403-4733-8490-cff7f4c713b3/scratchpad/<PKG>/`,
  never elsewhere in the repo.

## Checkpoint protocol

- Checkpoint `tasks/ckpt-alerts-<PKG>.md` (a stub exists). First line `status: in-progress`
  (`blocked`, `done`). Then `## Sections` with `[x]`/`[ ]`, rewritten after EACH section.
- On start, read your own checkpoint and continue from the first unfinished section.
- End with `## Operator-visible changes`, `## Docs notes` (exact flags, paths, messages,
  defaults the docs must say), `## Tests run` (commands and results), `## Open issues`.
- If Write is refused, return the complete text in your final answer.
- Budget well under 250k tokens; if ballooning, checkpoint and hand back.
- Return a summary, not file dumps.

## 1. Names and files (pinned)

| Item | Value |
|---|---|
| Operator script | `setup-alerts.sh`, `readonly SCRIPT_VERSION="2.1.0"` (the first line matching `SCRIPT_VERSION\s*=` in the file must be this assignment: `_file_version` in update-scripts.sh greps unanchored and takes the first match) |
| Library | `lib/alerts.sh`, `ALERTS_VERSION="2.1.0"` (not readonly, like `OBSERVABILITY_VERSION`; same first-match rule); sourced at the END of `lib/common.sh` by a guarded `if [[ -f "${__COMMON_DIR}/alerts.sh" ]]; then source …; fi` block right after the observability block (lib/common.sh:10422-10431), before the final `:` line |
| Runner (tracked) | `lib/tn-heartbeat.sh`, `HEARTBEAT_VERSION="2.1.0"` (same first-match rule); `hb_*` functions only; `hb_main "$@"` runs only when `[[ "${BASH_SOURCE[0]}" == "$0" ]]`; sources nothing (no common.sh); `lib/alerts.sh` sources it (`source "${__ALERTS_DIR}/tn-heartbeat.sh"`, guarded with `[[ -f ]]`) to use `hb_target_normalize`, `hb_url_host`, `hb_header_number`, `hb_state_get` |
| Runner (installed) | `/usr/local/libexec/telcoin/tn-heartbeat`, root 0755, via `tn_install_root_binary` (lib/common.sh:741) after `bash -n` |
| Units | `/etc/systemd/system/telcoin-heartbeat.service` (oneshot, no `[Install]`) and `telcoin-heartbeat.timer` (`WantedBy=timers.target`), both root 0644 via `tn_write_root_file`, then `systemctl daemon-reload` |
| Identity | `DynamicUser=yes`, `LoadCredential=targets:/etc/telcoin/alerts/targets`, `StateDirectory=telcoin-heartbeat` (real dir `/var/lib/private/telcoin-heartbeat`, 0700) |
| Config dir | `/etc/telcoin/alerts` root 0755 via `_tn_root_layout_dir "$dir" root 0755` (lib/common.sh:862) |
| Targets | `/etc/telcoin/alerts/targets` root 0600, one `<kind> <url>` per line (normalised), at most 5 lines |
| Env | `/etc/telcoin/alerts/alerts.env` root 0644 |
| State | `$STATE_DIRECTORY/state` (`/var/lib/private/telcoin-heartbeat/state`), written by the runner only |
| `.node-meta` | `ENABLE_ALERTS=true|pending|false`; absent means false |
| Updater rows | three `SCRIPTS` rows right after `"setup-observability.sh:setup-observability.sh:SCRIPT_VERSION"` (update-scripts.sh:92): `"setup-alerts.sh:setup-alerts.sh:SCRIPT_VERSION"`, `"lib/alerts.sh:lib/alerts.sh:ALERTS_VERSION"`, `"lib/tn-heartbeat.sh:lib/tn-heartbeat.sh:HEARTBEAT_VERSION"` |
| Journal | `SyslogIdentifier=tn-heartbeat`; `journalctl -u telcoin-heartbeat` |

All paths in the library and the integrations are under `${TN_ROOT_PREFIX:-}` so the fixture
tests can point them at a private tree. The runner uses `$STATE_DIRECTORY` and
`$CREDENTIALS_DIRECTORY` (systemd sets both) and needs no prefix.

## 2. `alerts.env` (written by `alerts_write_env`, read by systemd `EnvironmentFile=`)

```
# Written by setup-alerts.sh. Change it with setup-alerts.sh, not by hand.
ALERTS_SERVICE=telcoin
ALERTS_RPC_URL=http://127.0.0.1:8545
ALERTS_NETWORK=testnet
ALERTS_CHAIN_ID=2017
ALERTS_LABEL=node-1
ALERTS_HEALTH_PORT=43174
ALERTS_INTERVAL=60
ALERTS_STALL_AFTER=180
ALERTS_INACTIVE_AFTER=900
ALERTS_RESTART_GRACE=120
```

| Key | Source | Runner validation (invalid: `<3>config: ALERTS_X invalid` and exit 2) |
|---|---|---|
| `ALERTS_SERVICE` | `tn_resolve_service` (base name; the runner appends `.service`) | `^[A-Za-z0-9_.@-]{1,64}$` |
| `ALERTS_RPC_URL` | `alerts_rpc_url` (below) | `^http://[][A-Za-z0-9.:-]{1,80}$` |
| `ALERTS_NETWORK` | `NETWORK` from `.node-meta` (`addon_meta_get NETWORK ""`) | `^[a-z]{0,16}$` |
| `ALERTS_CHAIN_ID` | testnet `TESTNET_CHAIN_ID` 2017, mainnet `MAINNET_CHAIN_ID` 487, devnet `DEVNET_CHAIN_ID` 32285 (lib/common.sh:19-45); empty for any other network (then the chain check is skipped) | `^[0-9]{0,10}$` |
| `ALERTS_LABEL` | `--label X`, else `hostname` filtered to `[A-Za-z0-9._-]`, cut to 64; `node` when empty | `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$` |
| `ALERTS_HEALTH_PORT` | the port of `--healthcheck` on the node line (`tn_launch_flag_get FILE --healthcheck`; a value `addr:port` keeps the part after the last `:`), else 43174 | `^[0-9]{1,5}$` |
| `ALERTS_INTERVAL` | `--interval` (default 60), 30-3600 | `^[0-9]{1,5}$`, 30-3600 |
| `ALERTS_STALL_AFTER` | `--stall-after` (default 180), at least interval + 30, at most 86400 | `^[0-9]{1,6}$` |
| `ALERTS_INACTIVE_AFTER` | `--inactive-after` (default 900), at least stall, at most 86400 | `^[0-9]{1,6}$` |
| `ALERTS_RESTART_GRACE` | always 120 (no flag) | `^[0-9]{1,5}$`, 30-3600 |

`alerts_rpc_url`: `tn_node_launch_target` (lib/common.sh:8932) gives the launch file;
`tn_launch_flag_get FILE --http.addr` (rc 1 absent -> `127.0.0.1`; rc 2 "no live --http line" ->
`alerts_rpc_url` returns 1 and enable refuses: "The node command has no --http, so the runner
cannot read the local RPC; add it with edit-config.sh and run this again. Nothing was changed.");
`tn_launch_flag_get FILE --http.port` (absent -> the port of `tn_local_rpc_url`, lib/common.sh:4186).
Address mapping: `0.0.0.0` -> `127.0.0.1`; `::` -> `[::1]`; any other address containing `:` is
bracketed; others as given. Result `http://<addr>:<port>`.

Menu defaults: the menu asks only the interval (default 60); stall = max(180, 3 x interval),
inactive = max(900, stall). `--json` takes the three flags, validated as above; a bad value is
refused with exit 1 and nothing changed.

## 3. Targets: format, kinds and normalisation (`hb_target_normalize`)

Targets file: one `<kind> <url>` per line, `kind` in `kuma`, `healthchecks`, `webhook`, the URL
already normalised. No comments, no blank lines, at most 5 lines, trailing newline.

`hb_target_normalize KIND URL [ALLOW_HTTP]`: prints the normalised URL (rc 0), or prints nothing,
sets `HB_ERR` to a reason that never contains the URL, and returns 1. Rules, in order:

1. KIND must be one of the three (`HB_ERR="unknown provider 'X' (kuma, healthchecks or webhook)"`).
2. URL length 1-512 (`HB_ERR="url longer than 512 characters"` / `"empty url"`).
3. URL holds no `"`, `\`, whitespace or control character (`HB_ERR="url holds a quote, backslash, space or control character"`).
4. Scheme `https://`, or `http://` only when the host is `127.0.0.1`, `[::1]` or `localhost`, or
   ALLOW_HTTP is `1` (`HB_ERR="http needs --allow-http (the token travels in clear text)"`;
   any other scheme: `HB_ERR="url must start with https://"`).
5. kuma: cut at the first `?` or `#` (the Kuma UI shows `…/api/push/T?status=up&msg=OK&ping=`),
   strip trailing `/`, then the path must match `/api/push/[A-Za-z0-9_-]{4,128}$`
   (`HB_ERR="kuma: not an /api/push/<token> URL"`).
6. healthchecks: strip one trailing `/`, `/fail`, `/start` or `/log` (in that order, once each is
   fine); no query allowed (`HB_ERR="healthchecks: a query string is not allowed"`).
7. webhook: as given.

`hb_url_host URL` prints the host part with its port when given, IPv6 brackets kept
(`kuma.example.org`, `127.0.0.1:18080`, `[::1]:8080`); userinfo is dropped. `kind@host` is the
only form in which a target is ever displayed or logged.

The runner re-validates each line of the credential with `hb_target_normalize kind url 1`
(http was the operator's choice at enable time) and refuses the whole run (`<3>config: targets
line N invalid: <HB_ERR>`, exit 2) on a bad line, an empty file or more than 5 lines.

## 4. State file

`$STATE_DIRECTORY/state`: `key=value` lines, written to `$STATE_DIRECTORY/.state.tmp.$$` then
`mv -f` over the destination (the runner runs `umask 077`). Never sourced. If the path is a
symlink it is not followed (treated as absent; the next write replaces the link). A file with an
unknown key or a value failing its regex is invalid: logged once as `<4>state file invalid; starting
fresh` and replaced by first-run defaults. `hb_state_get FILE KEY` prints the validated value of
KEY or returns 1 (absent, invalid file, symlink).

| Key | Regex | Meaning |
|---|---|---|
| `version` | `^[0-9]+\.[0-9]+\.[0-9]+$` | runner version that wrote the file |
| `last_run` | `^[0-9]{1,19}$` | epoch seconds of the last run (`TN_HB_NOW` or `date +%s`) |
| `mono` | `^[0-9]{1,19}$` | integer part of `/proc/uptime` at the last run (`TN_HB_MONO` overrides) |
| `last_status` | `^(up|down)$` | |
| `status_since` | `^[0-9]{1,19}$` | `mono` when the status last changed |
| `last_reason` | `^[A-Za-z0-9 ._:/()=,+-]{0,200}$` | the message of the last run |
| `last_mode` | `^(CvvActive|CvvInactive|Observer|unknown)$` | |
| `last_block`, `last_epoch`, `last_header` | `^[0-9]{0,19}$` | empty when unknown |
| `header_since` | `^[0-9]{1,19}$` | `mono` when `last_header` last changed |
| `inactive_since` | `^[0-9]{0,19}$` | `mono` when `CvvInactive` was first seen; empty when not inactive |
| `started` | `^[0-9]{1,19}$` | `mono` when the runner first saw the current service activation |
| `svc_since` | `^[0-9]{0,19}$` | `ActiveEnterTimestampMonotonic` / 1000000 (whole seconds); empty when unknown |
| `svc_restarts` | `^[0-9]{0,10}$` | last `NRestarts` |
| `push_total`, `push_ok` | `^[0-9]{1,19}$` | counters since the state was created |
| `push_<n>` (n 1-5) | `^(kuma|healthchecks|webhook) (ok|fail) [0-9]{3}( [a-z0-9-]{1,16})? [][A-Za-z0-9.:_-]{1,253}$` | `<kind> ok|fail <code> [why] <host>` for target n of the last run |

A `mono` lower than the stored one means a reboot: every tracker (`header_since`,
`inactive_since`, `started`, `status_since`) restarts from this run's `mono`.

## 5. Runner algorithm (`hb_main`; the first `down` wins, in this order)

Setup: `umask 077`; read env (section 2); `now` = `TN_HB_NOW` or `date +%s`; `mono` =
`TN_HB_MONO` or the integer part of the first field of `/proc/uptime`; read the credential
`$CREDENTIALS_DIRECTORY/targets` (missing or unreadable: `<3>config: no targets credential` exit
2); read the state. `svc="${ALERTS_SERVICE}.service"`. Tools resolve through PATH (`curl`,
`systemctl`, `awk`) so the fixture test can stub them.

1. **Service.** `systemctl show --no-pager -p LoadState -p ActiveState -p SubState -p NRestarts -p ActiveEnterTimestampMonotonic "$svc"`
   (works under DynamicUser: `Properties.GetAll` is allowed to any caller; the vm.d assertion
   proves it). Parse `Key=Value` lines through a `case` on the key. If the command prints
   nothing (or fails), the service checks are skipped and the RPC checks decide.
   - `LoadState=not-found` -> down `service <svc> not found`.
   - `ActiveEnterTimestampMonotonic` changed from `svc_since` -> a restart: `started=mono`,
     `header_since=mono`, `inactive_since=` (empty). `svc_since` stores the new value.
   - `NRestarts` greater than the stored `svc_restarts` -> down `service <svc> restarted after a failure (NRestarts N)`; the new value is stored (so the next run is up again when all else is fine).
   - `ActiveState` `failed` or `inactive`, or `SubState=auto-restart` -> down `service <svc> inactive (<SubState>)` (`dead`, `failed`, `auto-restart`).
   - `ActiveState` `activating` or `deactivating`: age = `mono - svc_since` when `svc_since` is known, else `mono - started`; age < `ALERTS_RESTART_GRACE` -> up `service <svc> restarting (<ActiveState>, <age>s)`; otherwise down `service <svc> <ActiveState> for <age>s`.
   `<svc>` in these messages is the base name (`telcoin`), not `telcoin.service`.
2. **RPC.** `curl -q -sS --connect-timeout 2 --max-time 5 --max-filesize 8388608 -X POST -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' -w '\n%{http_code}\n%{time_total}' --url "$ALERTS_RPC_URL"`.
   Transport failure or non-2xx: age as in step 1 (grace applies only when the service checks
   ran and found the service `active`); age < grace -> up `starting: rpc not answering yet`;
   else down `rpc <host:port> not answering (<why>)` with `<why>` = `refused` (curl 7),
   `timeout` (28), `dns` (6), `http NNN` (a non-2xx), `curl N` (anything else). A result not
   matching `"result"\s*:\s*"0x[0-9a-fA-F]{1,16}"` counts as `malformed`. `ALERTS_CHAIN_ID`
   non-empty and different from the decimal of the result -> down `wrong chain: rpc reports N,
   expected M`. `time_total` x 1000, integer, is the Kuma `ping` (ms). When the RPC is down,
   steps 3-5 are skipped.
3. **Consensus header.** `tn_latestConsensusHeader` (same curl shape, `--max-time 5`). An
   `"error"` with `"code":-32601` -> the check is skipped (older node). Otherwise
   `hb_header_number` (below) gives the TOP-LEVEL `number` of the result; it changed from
   `last_header` -> `last_header=N`, `header_since=mono`; unchanged or unreadable and
   `mono - header_since >= ALERTS_STALL_AFTER` -> down `consensus stalled at header N for Ns`
   (unreadable with no known header: `consensus header unreadable for Ns`).
4. **Mode, block, epoch.** `tn_nodeMode` -> `CvvActive|CvvInactive|Observer` by the regex
   `"result"\s*:\s*"(CvvActive|CvvInactive|Observer)"`, else `unknown`. `CvvInactive`: set
   `inactive_since=mono` when empty; `mono - inactive_since >= ALERTS_INACTIVE_AFTER` -> down
   `CvvInactive for Ns: committee member not voting`. `CvvActive`/`Observer` clear
   `inactive_since`; `unknown` leaves it. `eth_blockNumber` -> block (hex -> `$((16#…))`);
   `tn_getCurrentEpochInfo` -> `"epoch"\s*:\s*([0-9]{1,10})` -> epoch. Each unknown on failure.
5. **Health.** `curl -q -sS --connect-timeout 2 --max-time 5 --max-filesize 65536 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${ALERTS_HEALTH_PORT}/health/network"`:
   curl 7 (refused) -> skipped silently; 200 -> fine; 503 -> down `health 503: node reports the
   network unreachable`; anything else -> the up message gets the suffix ` (health <code|timeout>)`.

**Up message:** `<mode> block <block> epoch <epoch>` with each unknown part dropped (`CvvActive
block 1234567 epoch 42`, `Observer block 1234567`, `unknown`); when mode, block and epoch are all
unknown: `rpc answering`. The step 1 and step 2 up variants replace it. Node-supplied text is
filtered to `[A-Za-z0-9 ._:/()=,+-]` and cut to 200 characters before use (`hb_clean`).

JSON parsing is `[[ =~ ]]`, `grep -oE` and `sed` only; no python. `hb_header_number JSON`:
walks the text once with POSIX awk, string-aware (an unescaped `"` toggles in-string; braces
inside strings do not count), tracking `{` depth; prints the digits of the first `"number"\s*:\s*N`
seen at depth 2 (the result object; the top-level object is depth 1; `sub_dag` and its
`latest_execution_block.number` are depth 3 or deeper, and the `sub_dag` is serialised before
the header's own `number`). Unbalanced braces or no depth-2 number -> rc 1 ("unreadable"),
never a wrong number. Input is the whole response on one line (`tr -d '\n\r'`).

**Pushes** (every target, in file order; the node's status never changes the exit code):

```
curl -q -sS --proto '=http,https' --connect-timeout 5 --max-time 10 --max-filesize 65536 \
     -A "tn-heartbeat/${HEARTBEAT_VERSION}" -w '\n%{http_code}' <kind options> \
     -K <(printf 'url = "%s"\n' "$url")
```

No `-L`, no `-f`. The URL goes through `-K` (a process substitution run in the main shell)
because `/proc/<pid>/cmdline` is world-readable. The body and code are split on the last
newline as `tn_rpc_call` does. Success is a 2xx code; for kuma also the body must not contain
`"ok":false`.

- `kuma`: `-G --data-urlencode "status=up|down" --data-urlencode "msg=<message>"` plus
  `--data-urlencode "ping=<ms>"` when the RPC answered.
- `healthchecks`: URL `<url>` when up, `<url>/fail` when down; `--data-raw "<status>: <message>"`.
- `webhook`: `-H 'Content-Type: application/json' --data-binary '<json>'` with exactly these
  keys in this order:
  `{"status":"up","reason":"CvvActive block 1234567 epoch 42","node":"<label>","network":"testnet","mode":"CvvActive","block":1234567,"epoch":42,"ts":1762257600,"changed":false}`
  (`block`/`epoch` `null` when unknown; `mode` the string `unknown` when unknown; `ts` the
  run's `now` as an integer; `changed` true when the status differs from `last_status` or there
  is none; `reason` and `node` JSON-escaped, but they can only hold the filtered character set).

`why` for a failed push: `timeout` (curl 28), `refused` (7), `dns` (6), `tls` (35, 51, 58, 60),
`too-large` (63), `body` (kuma `"ok":false`), `http` (a non-2xx code; the code says which), else
`curl-N`. Code is `000` when curl failed before a response.

**Logging** (stdout, journald priority prefixes, one line per run):
`<6>up: CvvActive block 1234567 epoch 42 | 1 kuma@kuma.example.org ok 200, 2 webhook@hooks.example.net fail 000 timeout`;
on a status change an extra line `<5>status up -> down: <reason>` (or `down -> up`); `<4>every
target failed` when all failed; `<3>config: …` on a config error. Never a URL, never a token.

**Exit:** 0 when at least one target accepted; 1 when every target failed (the unit shows
failed, the timer keeps firing); 2 for a missing credential, no targets or a bad environment.
The state file is written before exit in cases 0 and 1 (pushes recorded), not in case 2.

**Test hooks:** `TN_HB_NOW`, `TN_HB_MONO`, `STATE_DIRECTORY`, `CREDENTIALS_DIRECTORY`, and
`systemctl`/`curl` stubs on PATH. No other hook.

## 6. Unit texts

`alerts_unit_text RUNNER [DATA_DIR]` prints `telcoin-heartbeat.service`:

```
[Unit]
Description=Telcoin node heartbeat (private alerts)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=<RUNNER>
DynamicUser=yes
EnvironmentFile=/etc/telcoin/alerts/alerts.env
LoadCredential=targets:/etc/telcoin/alerts/targets
UnsetEnvironment=TN_BLS_PASSPHRASE
StateDirectory=telcoin-heartbeat
StateDirectoryMode=0700
UMask=0077
TimeoutStartSec=150
SyslogIdentifier=tn-heartbeat
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
NoNewPrivileges=yes
CapabilityBoundingSet=
ProtectProc=invisible
InaccessiblePaths=-/var/lib/telcoin -/etc/telcoin/bls-passphrase.cred -/etc/telcoin/bls-passphrase
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictNamespaces=yes
RestrictRealtime=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
MemoryMax=64M
CPUQuota=20%
TasksMax=32
LimitCORE=0
```

When DATA_DIR is given and is not `/var/lib/telcoin` or under it, ` -<DATA_DIR>` is appended to
`InaccessiblePaths=` (as the Alloy unit does). Dropped on purpose: `User=`/`Group=`
(DynamicUser), `ReadWritePaths=` (StateDirectory), `Restart=`/`StartLimit*` (the timer retries),
`[Install]` (the timer starts it), `IPAddressDeny`/`PrivateNetwork` (would block the push or
loopback), `ProcSubset=pid` (hides `/proc/uptime`).

`alerts_timer_text INTERVAL` prints `telcoin-heartbeat.timer`:

```
[Unit]
Description=Telcoin node heartbeat timer (private alerts)

[Timer]
OnBootSec=120
OnUnitActiveSec=<INTERVAL>
AccuracySec=5
Unit=telcoin-heartbeat.service

[Install]
WantedBy=timers.target
```

No `Persistent=` (OnCalendar only). `AccuracySec=5` because the 1-minute default drifts into a
monitor's missed-heartbeat window.

## 7. Library API (`lib/alerts.sh`)

Say convention: functions that report take an optional `FN`; `_alerts_say KIND MSG [FN]` calls
`FN KIND MSG` when FN is set (KIND one of `step log ok warn error`), else `print_step`,
`print_info`, `print_ok`, `print_warn`, `print_error`. setup-alerts's `addons_say` maps
`step|warn|error` to JSON events of that kind and the rest to `log`.

| Function | Behaviour | rc |
|---|---|---|
| `alerts_targets_validate [ALLOW_HTTP]` | stdin: `<kind> <url>` lines (a trailing CR dropped; blank lines ignored) -> stdout: normalised `<kind> <url>` lines. `ALERTS_ERR` names the failing line number and `kind@host` only (`"line 2 (kuma@kuma.example.org): kuma: not an /api/push/<token> URL"`); more than 5 targets or none is an error too | 0 / 1 |
| `alerts_write_targets` | stdin (a process substitution run in the main shell) -> `_tn_root_layout_dir` the dir, then `tn_write_root_file <targets> 0600` | the writer's rc |
| `alerts_rpc_url` | section 2 | 0; 1 no live `--http` |
| `alerts_write_env INTERVAL STALL INACTIVE [LABEL]` | here-string -> `tn_write_root_file <env> 0644`; computes every key of section 2 | 0 / 1 refused / 2 failed |
| `alerts_install_runner` | `bash -n "${__ALERTS_DIR}/tn-heartbeat.sh"` then `tn_install_root_binary` to `/usr/local/libexec/telcoin/tn-heartbeat` | 0 / 1 / 2 |
| `alerts_unit_text RUNNER [DATA_DIR]`, `alerts_timer_text INTERVAL` | print (section 6) | 0 |
| `alerts_write_units INTERVAL` | write both units 0644 (data dir from `.node-meta` `DATA_DIR`), `systemctl daemon-reload` | 0 / 1 / 2 |
| `alerts_test [FN]` | `t0=$(date +%s)`; `systemctl start telcoin-heartbeat.service` (blocks; its rc ignored); read the state through `hb_state_get`; fresh when `last_run >= t0`; fills `ALERTS_RESULTS` (lines `n kind host ok|fail code [why]`) and `ALERTS_NODE_STATUS` (`up|down`), `ALERTS_NODE_REASON`; prints one line per target as `kind@host` | 0 one ok; 1 all failed; 2 no fresh state (prints the hint `journalctl -u telcoin-heartbeat -n 20`) |
| `alerts_enable INTERVAL STALL INACTIVE [FN]` | targets come in on stdin (normalised lines from `alerts_targets_validate`; empty stdin allowed only when already enabled). Preflight, each refusal one sentence ending "Nothing was changed.": root; `.node-meta` present; `tn_resolve_service` finds the node unit; `alerts_rpc_url` works; `tn_systemd_version` >= `TN_STDIN_MIN_SYSTEMD` (247, for `LoadCredential=`); `addon_meta_get ENABLE_ALERTS false` not duplicated. Then: already `true` + targets on stdin -> `alerts_set_targets`; already `true` + no targets -> `alerts_refresh`; else write targets, env, runner, units; `alerts_test`; on rc 0 `systemctl enable --now telcoin-heartbeat.timer` and `meta_set ENABLE_ALERTS true`; on rc 1 or 2 a fresh install is torn down (`alerts_disable` without the hint) and the function returns 1 ("No target accepted the test heartbeat; private alerts were not enabled. Check the URLs and run this again."). Caller holds the lock (`addon_meta_write_begin`) | 0 / 1 |
| `alerts_set_targets [FN]` | stdin as above; snapshot the old targets file in a variable (`cat` + `x` sentinel, byte for byte), write the new one, `alerts_test`; rc 0 -> done; else put the old file back (same writer) and return 1 ("No target accepted the test heartbeat; the previous targets were put back.") | 0 / 1 |
| `alerts_refresh [FN]` | no-op (rc 0, says "Private alerts are off; nothing to refresh.") unless `ENABLE_ALERTS=true` or the timer unit exists; else reinstall the runner, rewrite env (the stored interval/stall/inactive from the current env file, defaults when missing) and units, `daemon-reload`, `systemctl restart telcoin-heartbeat.timer` | 0 / 1 |
| `alerts_disable [FN] [no-hint]` | `systemctl disable --now telcoin-heartbeat.timer`; `systemctl stop telcoin-heartbeat.service`; `systemctl clean --what=state telcoin-heartbeat.service` (fallback `rm -rf /var/lib/private/telcoin-heartbeat` and `rm -f /var/lib/telcoin-heartbeat` when the dir is still there); `_tn_shred` targets; `rm -f` env; `rmdir` the dir; `rm -f` both units and the runner; `daemon-reload`; `systemctl reset-failed telcoin-heartbeat.service`; `meta_set ENABLE_ALERTS false` (a failure is a warning); prints "Pause or delete this node's monitor: a push monitor alerts on silence." unless `no-hint` | 1 when the targets file survives |
| `alerts_status [FN]` | prints: `Private alerts: on|pending|off` (meta); `systemctl list-timers --all --no-legend telcoin-heartbeat.timer` summarised (`timer active, next run …` / `timer inactive` / `timer not installed`); as root the state summary (`last run Ns ago: up, CvvActive block … epoch …`; targets `n kind@host ok 200`), else `last run not checked (run with sudo)`; the targets file must be `0600 root:root`; installed runner version (`HEARTBEAT_VERSION=` grep of the installed file) vs the checkout's; env drift (`ALERTS_SERVICE` vs `tn_resolve_service`, `ALERTS_RPC_URL` vs `alerts_rpc_url`). **Returns the number of issues** (capped at 20): enabled but timer inactive or missing; last run older than 3 x interval + 30 s; every push failed or no targets recorded; wrong targets mode/owner; duplicate meta key; runner version differs ("run setup-alerts.sh --refresh") | issue count |

`alerts_require_lib` lives in setup-alerts.sh (exit 2, one message naming update-scripts.sh,
a `--json` run also gets it as the `done` event; model `addons_require_lib`,
setup-observability.sh:757-782). It checks, with `declare -F`: `addon_meta_get addon_meta_lock
addon_meta_write_begin meta_set node_meta_path tn_write_root_file tn_install_root_binary
tn_root_dir_ok _tn_root_layout_dir _tn_shred tn_systemd_version tn_resolve_service
tn_node_launch_target tn_launch_flag_get tn_local_rpc_url tn_remove_inflight_tmp
tn_release_update_lock` (lib/common.sh), every `alerts_*` of the table (lib/alerts.sh), and
`hb_target_normalize hb_url_host hb_header_number hb_state_get` (lib/tn-heartbeat.sh).

## 8. `setup-alerts.sh`

Header comment (printed by `usage()` as setup-vpn.sh:1498-1500 does: everything between the
first and second `# ====` lines, `#` stripped) with USAGE lines for the menu and every `--json`
form. Structure, `json_*` helpers, `addons_say`, EXIT/signal traps and lock handling copied from
setup-observability.sh (:32-46, :433-476, :645-701, :797-848): `TN_EXIT_TRAP_OWNED=1` before the
lock; the EXIT trap runs `tn_remove_inflight_tmp` then `tn_release_update_lock`; TERM/INT/HUP
exit 143/130/129.

Menu (after `check_root`, `load_node_context` without `require_testnet`, `addon_meta_lock`):

```
1) Status
2) Enable private alerts
3) Change targets
4) Send a test heartbeat now
5) Refresh after a script update
6) Disable private alerts
7) Exit
```

Target collection (menu, and `--enable` without `--json` and without a target source when
stdin is a terminal): one at a time: `Provider: 1) Uptime Kuma push URL 2) healthchecks.io ping
URL 3) JSON webhook [1-3]:`, then `read -r -s -p "  URL (input hidden): "`; validate with
`hb_target_normalize`; on refusal print `HB_ERR` and ask again; echo back only
`kind@host`; "Add another? [y/N]" up to 5. Then the interval prompt (`Interval in seconds [60]:`).
After an enable: "Set the monitor's heartbeat interval to about <2 x interval> s with 1-2
retries: a node update or a restart you run yourself shows as a short down."

`--json` with exactly one of `--status | --enable | --test | --refresh | --disable` (two or none:
refused, exit 1). Targets from exactly one of `--targets-stdin` (one `<kind> <url>` per line),
repeated `--target kind=url` (warns once: "--target puts the URL on the command line, where other
local users can read it while this runs; pipe it in with --targets-stdin instead."), or
`TN_ALERT_TARGETS` (same line format; copied into a variable and `unset` before anything else
runs); two sources: refused. `--interval N`, `--stall-after N`, `--inactive-after N`, `--label X`,
`--allow-http`. `-h`/`--help` prints `usage()`. Unknown argument: refused (exit 1), not ignored.

`done` events (stdout is fd 3, everything else stderr):

- enable: `{"event":"done","ok":true,"applied":["alerts:enabled"],"network":"testnet","interval":60,"node_status":"up","node_reason":"CvvActive block 1234567 epoch 42","targets":[{"n":1,"provider":"kuma","host":"kuma.example.org","result":"ok","code":200}],"msg":"private alerts enabled"}`
  (`applied` is `alerts:targets-changed` or `alerts:refreshed` on an already-enabled node).
- test: `applied:["alerts:tested"]`, same `node_status`, `node_reason`, `targets`.
- refresh: `applied:["alerts:refreshed"]`; disable: `applied:["alerts:disabled"]`.
- status: `{"event":"done","ok":true,"applied":[],"network":…,"enabled":"true|pending|false","timer":"active|inactive|absent","last_run":1762257600|null,"last_status":"up"|null,"last_reason":"…"|null,"runner_version":"2.1.0"|null,"issues":0,"targets":[…],"msg":"private alerts status"}` (no lock, no root needed; without root the state fields are null).
- failure: `{"event":"done","ok":false,"msg":"…"}` (json_on_exit when nothing else was sent).

Exit codes: 0 done; 1 refused with nothing changed; 2 library gap; 3 a step failed after
something changed (the message says what, e.g. "private alerts were not enabled; the files
written for the test were removed" is still 1 because the host is back as it was, whereas a
disable that leaves the targets file is 3).

## 9. Integrations

**setup-node.sh**
- Default `ENABLE_ALERTS="false"   # true | pending | false` beside `ENABLE_VPN` (:274).
- After the region block (:420-430), before "Selecting install method": read back
  `v="$(meta_get ENABLE_ALERTS "$(node_meta_path 2>/dev/null || true)" 2>/dev/null || true)"`
  and keep `true|pending` (a re-run must not reset a live value), then
  `json_mode || prompt_alerts`.
- `prompt_alerts` (every network): returns early under `TN_ASSUME_YES=true`, when
  `"$SCRIPT_DIR/setup-alerts.sh"` is absent, or when `ENABLE_ALERTS` is already `true`;
  `print_header "Private alerts (optional)"`; four `print_info` lines saying: a timer on this
  host pushes a heartbeat to a monitor you own (Uptime Kuma push URL, healthchecks.io ping or a
  JSON webhook); what is sent (up or down, the reason, node mode, block and epoch, this host's
  label) and nothing else; no port opens and the Telcoin Association is not involved; the URLs
  are asked for once the node runs. `confirm "Set up private alerts once the node is running?"`
  -> `ENABLE_ALERTS="pending"`.
- `write_node_meta` (:2575-2581): `"ENABLE_ALERTS=${ENABLE_ALERTS:-false}"` after `ENABLE_VPN`.
- `step_alerts` between `step_testnet_addons` and `step_host_baseline` (:3477-3478): no-op in
  `--json` or unless `pending`; `print_header "Private alerts"`; when
  `systemctl is-active --quiet "$SERVICE_NAME"` fails: warn "The node is not running yet, so
  private alerts stay pending. Once it runs: sudo bash setup-alerts.sh" and return; else run
  `bash "$SCRIPT_DIR/setup-alerts.sh" --enable` (a child; it takes the lock itself; setup
  released it at `setup_release_lock`); rc 0 -> `ENABLE_ALERTS=true`; else warn and keep
  pending with the command.
- `step_final_summary`: after the add-on lines, `Private alerts: on` or `pending: sudo bash
  setup-alerts.sh`.
- `--json`/finalize unchanged; docs point to `setup-alerts.sh --json --enable --targets-stdin`.
- `tn_require_fns` unchanged. host_baseline_test.sh's driver list (:596-600) and the expected
  order string (:616) gain `step_alerts` after `step_testnet_addons`.

**check-node.sh**
- `check_alerts` after `check_healthcheck_on_mainnet` (:2144) and before `# REPORT HEADER`
  (:2147); registered in the `for _hc in …` loop at :2216-2217. With `have_fns alerts_status`:
  `n=0; alerts_status || n=$?; (( HEALTH_ISSUES += n ))`. Without: joins `CN_SKIPPED_CHECKS`
  only when the timer unit exists or the meta value is `true|pending`.
- `check_ownership_layout` (:1900) gains `_cn_own` rows, each only when the path exists:
  `/usr/local/libexec/telcoin/tn-heartbeat` root root 0755; `/etc/telcoin/alerts` root root
  0755; `/etc/telcoin/alerts/targets` root root 0600; `/etc/telcoin/alerts/alerts.env` root root
  0644.
- lib_skew_test.sh's list of check-node helpers (:176) is unchanged.

**remove-node.sh**
- `remove_alerts` beside `remove_testnet_addons` (:1158), inline, fixed paths under
  `${TN_RM_ROOT}`, no library call: `systemctl disable --now telcoin-heartbeat.timer`,
  `systemctl stop telcoin-heartbeat.service`, `_rm_shred` the targets file, `rm -f` env, `rmdir`
  the dir, `rm -f` both units and the runner, `systemctl clean --what=state
  telcoin-heartbeat.service` (fallback `rm -rf …/var/lib/private/telcoin-heartbeat` and `rm -f
  …/var/lib/telcoin-heartbeat`), `daemon-reload`, `reset-failed`, best-effort `meta_set
  ENABLE_ALERTS false` when `.node-meta` still exists, then `print_info "Pause or delete this
  node's monitor: a push monitor alerts on silence."`. Guarded: does nothing (and prints nothing)
  when none of the alerts files exists.
- Runs **before the node stops** at every scope: in `remove_node_unit` right before
  `stop_and_disable_service "$unit"` (:1279); in `json_remove` after `rm_take_lock` and before
  `stop_and_disable_service "$svc"` (:1721-1729) with a `json_event step "Removing private
  alerts (telcoin-heartbeat)"`; in `remove_leftovers` after `rm_take_lock` (:890). Not in the
  chain-data-only wipe (the node stays). The timer unit joins `rm_leftovers_present` (:807) and
  the shown list (`/etc/systemd/system/telcoin-heartbeat.timer (private alerts)`).

**update-scripts.sh**
- The three rows (section 1).
- After `install_pass` (:790-810): when `UPD_PATHS` contains `lib/tn-heartbeat.sh` or
  `lib/alerts.sh` and `${TN_ROOT_PREFIX:-}/etc/systemd/system/telcoin-heartbeat.timer` exists,
  print `The heartbeat runner or its library changed. Reinstall them on the host:` and
  `  sudo bash ${SCRIPT_DIR}/setup-alerts.sh --refresh` (the updater never runs sudo itself).

**lib/common.sh**: only the guarded source block (section 1).

**AGENTS.md**: setup-alerts in the boundary list (:32-36); `addon_meta_write_begin` users
(:118-121); baseline-refresh users (:133-137, "the four add-ons" -> the five); the
`*_require_lib` list (:460-462) gains `alerts_require_lib`; at :207-213 say setup-alerts runs
neither the guard nor the wait because it never restarts the node; ownership: the dynamic
user's state dir is the one exception to root ownership; :587 says `vm.d/P0-*.sh`
(integration.yml:45 runs only that glob); a new `## Private alerts` section with the rules of
this spec (every network, never in `tn_testnet_addons_present`, the runner sources nothing, URLs
only via the targets credential and `-K`, DynamicUser, no node restart, removal before the node
stops, the updater only prints `--refresh`, the pushed field set is an operator-visible contract).

## 10. Tests

- `tools/tests/heartbeat_test.sh` (A1a): library mode (source `lib/tn-heartbeat.sh`): header
  parser (a nested `latest_execution_block.number` first, a fixture-shaped answer, missing
  number, error answer, unbalanced braces); the normalisation table (the Kuma query form,
  `/fail`, quotes, non-loopback http with and without allow, 513 chars, bad kind). Then
  `bash lib/tn-heartbeat.sh` with `STATE_DIRECTORY`, `CREDENTIALS_DIRECTORY`, `TN_HB_NOW`,
  `TN_HB_MONO` and PATH stubs (`systemctl` prints the `SVC_*` fields from env; `curl` answers
  RPC from `$T/rpc/<method>` files, records each push by reading the `-K` file and its options
  to `$T/pushes`, fails per host on request). Scenarios: all up; service inactive; activating
  inside and after grace; NRestarts; not-found; rpc refused; wrong chain; stall before, at and
  after, then recovery; CvvInactive window and reset on restart; reboot resets; health 503 vs
  refused vs 500; corrupt state (a value `$(touch sentinel)` never runs, the sentinel is
  absent); one of two targets failing (exit 0) vs all (exit 1, `<4>`); no credential (exit 2);
  the token never appears in stdout, stderr or the state; message <= 200; healthchecks `/fail`
  URL and body; the exact webhook JSON; `<5>status …` only on a change.
- `tools/tests/alerts_test.sh` (A1b): unit text lines one by one (no `User=`, no
  `IPAddressDeny`, no `Persistent`, the InaccessiblePaths data-dir case); `systemd-analyze
  verify` on both units with `ExecStart=$(type -P true)` where `systemd-analyze` exists (`skip`
  otherwise); the validation table through `alerts_targets_validate`; a 0600 write through a
  logged `tn_write_root_file`; enable refusals (systemd 246 stub, no unit, no `--http`, duplicate
  meta key); all-fail rollback leaves no file and meta false; set-targets restore byte for
  byte; disable order in the systemctl log, files gone, meta false, rc 1 when targets survive;
  status issue counts (timer inactive, stale run, all failed, wrong mode), a symlinked state
  file ignored; `alerts_rpc_url` mappings.
- `tools/tests/setup_alerts_test.sh` (A2): `--json` `done` shapes for every action against a
  stubbed library; argv warning; two target sources refused; two actions refused; unknown
  argument refused; `TN_ALERT_TARGETS` unset before the library runs; missing library exits 2
  with one message (plus a row in addon_oldlib_test.sh).
- `tools/tests/vm.d/P0-alerts.sh` (A1b; matches the `P0-*.sh` glob): skips without python3.
  A fake `telcoin.service` running a `python3 -I` JSON-RPC stub on 127.0.0.1:8545 (eth_chainId
  0x7e1, tn_latestConsensusHeader with a nested number first and the real number at depth 2,
  tn_nodeMode CvvActive, eth_blockNumber, tn_getCurrentEpochInfo) + a start script with `--http
  --http.addr 127.0.0.1 --http.port 8545` + `.node-meta` (NETWORK=testnet, OWNERSHIP_LAYOUT=2);
  a python3 push listener on 127.0.0.1:18080 logging method and path;
  `printf 'kuma http://127.0.0.1:18080/api/push/vmtest1\nwebhook http://127.0.0.1:18080/hook\n' | bash setup-alerts.sh --json --enable --targets-stdin --interval 30`;
  assert timer active, `last_status=up`, `push_1` starts `kuma ok 200`, the listener saw the GET
  and the POST, the state file's uid in 61184-65519, the URL absent from the journal; `systemctl
  stop telcoin` + `systemctl start telcoin-heartbeat.service` -> `last_reason=service telcoin
  inactive (dead)`; `--disable` leaves no unit, runner, dir or state.
- Existing tests updated by their package: host_baseline_test.sh, check_node_hardening_test.sh
  (A3a); remove_test.sh, remove_addons_test.sh, updater_manifest_test.sh, addon_gates_test.sh
  (a negative case: an alerts install alone makes `tn_testnet_addons_present` return 1) (A3b);
  addon_oldlib_test.sh (A2).

## 11. Commands

```
bash tools/tests/run.sh [files]                                           # bash 5
docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/run.sh [files]   # busybox, no perl/setpriv/mv -T
docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/run.sh [files]  # root, GNU
bash -n FILE; docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash -n FILE
bash tools/check-bash32.sh FILE
shellcheck -x --severity=error FILE
bash tools/tests/passphrase_print_test.sh; bash tools/tests/root_write_pipe_test.sh
bash tools/check-perl-interp.sh FILE; bash tools/check-network-hits.sh
docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash -c 'apt-get -qq update && apt-get -qq install -y systemd >/dev/null && systemd-analyze verify /w/path/to/unit'
```

## 12. Verified anchors (4a2cf6e)

lib/common.sh: constants :19-45; `tn_acquire_update_lock` :265, `tn_release_update_lock` :370,
`tn_root_dir_ok` :500, `tn_remove_inflight_tmp` :554, `tn_write_root_file` :582,
`tn_install_root_binary` :741, `_tn_root_layout_dir` :862, `tn_rpc_call` :4065, `tn_json_field`
:4142, `tn_local_rpc_url` :4186, `TN_STDIN_MIN_SYSTEMD` :5391, `tn_systemd_version` :5395,
`_tn_shred` :5617, `tn_host_baseline_refresh` :6512, `is_testnet` :8417, `require_testnet` :8428,
`addon_meta_get` :8450, `addon_meta_lock` :8469, `addon_meta_write_begin` :8484,
`tn_testnet_addons_present` :8504, `node_meta_path` :8532, `meta_get` :8545, `meta_set` :8577,
`tn_node_launch_target` :8932, `tn_launch_flag_get` :9486, `prompt_testnet_addons` :10296,
`step_testnet_addons` :10352, observability source block :10422-10431. lib/fallback.sh:
`tn_resolve_service` :88, `_tn_unit_dir` :53. lib/observability.sh: `obs_write_token_file` :538,
`_obs_snapshot` :1602, `obs_rotate_token` :1667, `obs_disable` :1735, `obs_status` :1874.
setup-observability.sh: header :1-20, `addons_say` :28-46, `so_baseline_refresh` :48-58,
`load_node_context` :161, `so_lock_begin` :178, `so_write_begin` :186, json helpers :433-476,
`run_json_mode` :645, `arg_fail` :745, `addons_require_lib` :757, `so_on_exit` :797,
`so_signal_traps` :805, `main` :830. setup-vpn.sh `usage()` :1498. update-scripts.sh: SCRIPTS
:75-98 (observability row :92), `_file_version` :196, post-install hints :790-810. setup-node.sh:
ENABLE_* defaults :270-277, region block :420-430, `write_node_meta` call :2575-2585,
`step_final_summary` :2823, `main` :3319, step order :3466-3480. check-node.sh: `have_fns` :291,
`cn_report_skipped` :1767, `_cn_own` :1878, `check_ownership_layout` :1900,
`check_healthcheck_on_mainnet` :2125, loop :2216. remove-node.sh: `TN_RM_ROOT` :39,
`rm_take_lock` :50, `_rm_shred` :380, `rm_leftovers_present` :807, `remove_leftovers` :835 (lock
:890), `remove_testnet_addons` :1158, `remove_node_unit` :1257 (stop :1279, add-ons :1296),
`json_remove` scopes `service|data|keys` (lock :1722, stop :1731), `main` :1852.

## 13. Decisions taken during implementation (binding; later than the sections above)

- **Restart age (A1a, accepted 2026-11-04).** `systemctl show` also asks for
  `StateChangeTimestampMonotonic`. The age of an `activating` or `deactivating` unit in step 1
  is `mono - StateChangeTimestampMonotonic/1000000`; during a restart `ActiveEnterTimestamp`
  still names the previous activation and would give a false "activating for 36000s" down. When
  the state-change stamp is missing the section 5 formula applies. The RPC starting grace in
  step 2 keeps `ActiveEnterTimestamp` (an `ActiveEnterTimestampMonotonic` of 0 counts as
  unknown).
- **Logging.** A down run logs `<4>down: <reason> | <pushes>`; an up run `<6>up: …`. The first
  run ever prints `<5>status none -> up: …` (or `none -> down`). A `SubState` starting with
  `auto-restart` is down (covers systemd 254's `auto-restart-queued`).
- **Restart inside the grace** ends the checks (steps 2-5 are not run, the push says
  `service <svc> restarting (<state>, Ns)`); a service that is down still runs steps 2-5 so the
  pushed fields stay current. A malformed RPC answer gets the same grace as a connection
  failure.
- **Normalisation extras.** `hb_target_normalize` also refuses a URL with no host ("url has no
  host"); it quotes an unknown kind only when it is a plain word; it sets `HB_URL` as well as
  printing (call it directly, not in `$( )`, to read `HB_ERR`). `hb_url_host` keeps only the
  characters the state regex accepts. `hb_state_get` re-validates the whole file on every call
  and leaves `HB_S_*` set in the caller; a missing key is "unknown".
- **ENABLE_ALERTS on a failed fresh enable (A3a finding).** The rollback in `alerts_enable`
  writes back the value it read at the start (setup-node records `pending` before it runs the
  child), never a hard `false`. Only an operator's disable writes `false`.
- **Quiet status (A3a finding).** `alerts_status` on a host with `ENABLE_ALERTS` false or absent
  and no timer unit prints one plain line, `Private alerts: off (enable them with
  setup-alerts.sh)`, and returns 0; the full block appears only when the meta value is `true`
  or `pending` or the timer unit exists.
- **Disable shreds temp copies (A3b finding).** `alerts_disable` shreds `.tn.*` temp files in
  the alerts dir before the `rmdir`, as `remove_alerts` in remove-node does.
- **Setup-node strings (A3a).** The summary prints `Private alerts: on` or `Private alerts:
  pending. To finish: sudo bash setup-alerts.sh`; the prompt's "what is sent" line is "Each
  heartbeat says up or down with the reason (node mode, block and epoch); a webhook also gets
  this host's label and the network. Nothing else is sent."
- **Remove-node strings (A3b).** `--json` events `{"event":"step","msg":"Removing private alerts
  (telcoin-heartbeat)"}` and `{"event":"log","msg":"Pause or delete this node's monitor: a push
  monitor alerts on silence."}`; the leftover list shows `/etc/systemd/system/telcoin-heartbeat.timer
  (private alerts)`. Updater hint: `The heartbeat runner or its library changed. Reinstall them
  on the host:` then `  sudo bash <dir>/setup-alerts.sh --refresh`.
- **Rollback of a failed fresh enable (V1d W-X1, decided).** `alerts_enable` reads
  `ENABLE_ALERTS` with `meta_get` and remembers whether the key was absent (rc 1). The undo of a
  failed fresh enable runs `meta_unset ENABLE_ALERTS` when it was absent, else writes back the
  value read. Exit 1 from setup-alerts then means nothing on the host changed, `.node-meta`
  included, so no baseline refresh is needed on that path.
- **Thresholds and label on an already-enabled node (V1d N-O1, decided).** `alerts_refresh`
  takes optional `INTERVAL STALL INACTIVE` (and reads `ALERTS_LABEL_REQ`): a given value replaces
  the stored one in alerts.env and the timer, an omitted one keeps the stored value; the timer
  is restarted. `alerts_enable` on an enabled node without targets passes the values the caller
  gave explicitly (setup-alerts tracks which flags were on the command line; the menu's
  interval prompt counts as explicit), so `--enable --interval 120` or `--refresh --interval
  120` change the interval without a disable. The derived defaults (max(180, 3 x interval),
  max(900, stall)) apply only when the interval is explicit and the other two are not. The
  `done` of such a run carries `applied:["alerts:refreshed"]` and the new `interval`.
- **#60 closes with this PR.** The release note's "Left open" entry for private alerts names the
  three follow-ups as `followup.md` items (the UI card, retiring the pull monitor, the
  maintenance marker), not as #60 staying open.
- **Status without root (V1 W2, decided).** When `.node-meta` exists but cannot be read,
  `alerts_status` reports the meta value as `unknown (run with sudo)` (JSON `"enabled":null`)
  and decides "on" from `systemctl is-enabled telcoin-heartbeat.timer`; the issues that count
  only when alerts are on then follow that decision.
- **healthchecks fragment (V1 N3, decided).** `hb_target_normalize` refuses a healthchecks URL
  holding `#` as it refuses `?` (`HB_ERR="healthchecks: a query string or fragment is not
  allowed"`), so a down ping can never land on `<url>#x/fail`.
- **`--label` with targets on an enabled node (V1 N1, decided).** It is applied: after the
  targets change succeeds, the explicit label and thresholds go through `alerts_refresh`, and
  `applied` lists both items, `["alerts:targets-changed","alerts:refreshed"]`.
- **Undo helper (V1 W1 fix shape).** `alerts_disable` gains a `keep-meta` mode that skips its
  `.node-meta` write; `_alerts_enable_undo` uses it and then restores the start state itself
  (`meta_set` of the value read, or `meta_unset ENABLE_ALERTS` when the key was absent).
