status: done

Package A1a (issue #60, branch private-alerts). Spec: tasks/spec-alerts-A1a.md; shared: tasks/spec-alerts-shared.md.

## Sections
- [x] S0 read specs and anchors; header comment of lib/tn-heartbeat.sh
- [x] S1 helpers (hb_log, hb_clean, hb_target_normalize, hb_url_host, hb_header_number, hb_hex2dec, hb_json_str, hb_curl_why)
- [x] S2 state (hb_state_get, hb_state_load, hb_state_save, reboot detection)
- [x] S3 checks 1-5, up message, first-down-wins
- [x] S4 pushes per kind, -K process substitution, kuma body check, log line, <5>status, exit codes
- [x] S5 tools/tests/heartbeat_test.sh (167 checks)
- [x] S6 gates (bash 5, bash:3.2, ubuntu:24.04, check-bash32, shellcheck, network-hits, passphrase-print)

## Files
- lib/tn-heartbeat.sh (new, untracked): `HEARTBEAT_VERSION="2.1.0"` on line 61, the first match of
  the updater's grep. `#!/bin/bash` (the installed copy is run directly by systemd). Sourcing
  defines functions, `HEARTBEAT_VERSION` and the plain array `HB_STATE_KEYS`; nothing runs, no
  `set -e`, no readonly. `hb_main "$@"` only when `BASH_SOURCE[0] == $0`. Sources nothing.
- tools/tests/heartbeat_test.sh (new, untracked).

## Operator-visible changes
- New runner, installed by A1b as /usr/local/libexec/telcoin/tn-heartbeat.
- Journal lines (stdout, journald prefixes), one per run plus extras:
  - `<6>up: <reason> | 1 kuma@host ok 200, 2 webhook@host fail 000 timeout`
  - `<4>down: <reason> | ...` (a down run is logged at warning, so `journalctl -p warning` shows it)
  - `<5>status up -> down: <reason>` / `down -> up`; the first run prints `<5>status none -> up: ...`
  - `<4>every target failed`
  - `<4>state file invalid; starting fresh`; `<4>state not saved: ...` (write failure)
  - `<3>config: ALERTS_X invalid`, `<3>config: no targets credential`,
    `<3>config: targets credential is empty`, `<3>config: targets credential holds more than 5 lines`,
    `<3>config: targets line N invalid: <reason>`, `<3>config: STATE_DIRECTORY invalid`
- Exit 0 at least one target accepted; 1 every target failed (state still written); 2 config error
  (nothing pushed, no state written).

## Docs notes
Down reasons (first found wins, in this order), exactly as pushed:
- `service telcoin not found`
- `service telcoin restarted after a failure (NRestarts N)`
- `service telcoin inactive (dead|failed|auto-restart|auto-restart-queued)`
- `service telcoin activating for Ns` / `service telcoin deactivating for Ns` (at or past the 120 s grace)
- `rpc 127.0.0.1:8545 not answering (refused|timeout|dns|http NNN|malformed|curl N)`
- `wrong chain: rpc reports N, expected M`
- `consensus stalled at header N for Ns` / `consensus header unreadable for Ns`
- `CvvInactive for Ns: committee member not voting`
- `health 503: node reports the network unreachable`
Up reasons: `CvvActive block 1234567 epoch 42` (unknown parts dropped; `rpc answering` when all
are unknown), with ` (health 500)` / ` (health timeout)` appended when the health endpoint
answers something other than 200 (not listening: nothing appended); `service telcoin restarting
(activating, 30s)` inside the restart grace; `starting: rpc not answering yet` when the unit
became active less than 120 s ago and the RPC does not answer yet.
Every reason is filtered to `[A-Za-z0-9 ._:/()=,+-]` and cut to 200 characters, so a service
name with `@` loses the `@` and an IPv6 RPC host loses its brackets in the message.
Pushes:
- kuma: GET `<url>?status=up|down&msg=<reason>&ping=<ms>` (ping only when the RPC answered;
  milliseconds of the eth_chainId call). Accepted on 2xx without `"ok":false` in the body.
- healthchecks: POST to `<url>` (up) or `<url>/fail` (down), body `up: <reason>` / `down: <reason>`.
- webhook: POST, `Content-Type: application/json`, body exactly
  `{"status":"up","reason":"...","node":"<label>","network":"testnet","mode":"CvvActive","block":1234567,"epoch":42,"ts":1762257600,"changed":false}`
  (`block`/`epoch` null and `mode` "unknown" when not read; `changed` true on the first run and on a change).
- User-Agent `tn-heartbeat/2.1.0`; no redirects followed; 5 s connect, 10 s total, 64 KiB body cap.
- Failed push reasons: `timeout`, `refused`, `dns`, `tls`, `too-large`, `body` (kuma ok:false),
  `http` (non-2xx; the code says which), `curl-N`; code `000` when no response.

## Tests run
All on 2026-11-04, in /home/drtnarg/coding/telcoin/tn-node-deployment:
- `bash tools/tests/run.sh tools/tests/heartbeat_test.sh` (bash 5.3.9): 167 checks, 0 failures, 0 skipped.
- `docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/run.sh tools/tests/heartbeat_test.sh`
  (bash 3.2.57, busybox awk/sed/tr/mv): 167 checks, 0 failures, 0 skipped.
- `docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/run.sh tools/tests/heartbeat_test.sh`
  (bash 5.2.21, root, GNU tools, mawk): 167 checks, 0 failures, 0 skipped.
- `bash -n` both files under bash 5 and `bash:3.2`: ok.
- `bash tools/check-bash32.sh lib/tn-heartbeat.sh tools/tests/heartbeat_test.sh`: clean.
- `shellcheck -x --severity=error` both files: clean; `--severity=warning`: clean too.
- `bash tools/check-network-hits.sh`: clean (146 annotated hits in 26 files; none in the new file).
- `bash tools/tests/passphrase_print_test.sh`: 4 checks, 0 failures.
- `bash tools/tests/root_write_pipe_test.sh`: 2 checks, 0 failures.
- `bash tools/check-perl-interp.sh` both files: clean.
- Mutation check (scratch copy): ten deliberate runner bugs (stall `-gt`, no kuma body check, no
  reason filter, URL on argv instead of -K, no healthchecks /fail, no reboot reset, grace `-le`,
  symlink followed, status line always, header depth ignored) each fail the test (1 to 70 failures).
- Real-tool smoke (scratch, not committed): real curl 8.18 against a local listener and real
  `systemctl show` on a missing unit: kuma GET with the query, healthchecks POST to /fail, webhook
  POST JSON, User-Agent, `not found` reason, `tls` and `refused` push failures, exit 1 when all fail.

## Open issues
Deviations from the shared spec, made on purpose (orchestrator please confirm or reverse):
1. Restart age. The spec measures activating/deactivating age as `mono - svc_since`, but
   ActiveEnterTimestampMonotonic still names the PREVIOUS activation while a restart is under way
   (systemd sets it only on entering active), so a plain `systemctl restart` or the docker
   `ExecStartPre=docker stop -t 80` window would read as "activating for 36000s" and push a false
   down. The runner also asks `-p StateChangeTimestampMonotonic` and uses it for that age (time in
   the current state); it falls back to the spec's formula when the property is missing or 0.
   The RPC "starting" grace still uses svc_since (time since the unit became active), as specified.
2. `SubState` `auto-restart*` (systemd 254+ also reports `auto-restart-queued`) counts as the
   auto-restart down.
3. A step-1 up variant (restart inside the grace) ends the checks: the RPC is not consulted, since
   step 2's grace applies only to an `active` unit and would otherwise turn every restart into a
   down. A step-1 down still runs steps 2-5 so mode/block/epoch and the trackers stay current (the
   reason stays the step-1 one). `malformed` gets the same RPC grace as a transport failure.
4. `ActiveEnterTimestampMonotonic=0` (never active) counts as unknown (empty `svc_since`).
5. hb_target_normalize: an extra rule after the scheme check, `HB_ERR="url has no host"`; the
   unknown-kind message quotes the kind only when it is a plain word (`[A-Za-z0-9_-]{1,32}`), else
   `unknown provider (kuma, healthchecks or webhook)`, so a URL pasted in the kind slot is never
   echoed. hb_url_host keeps only `[][A-Za-z0-9.:_-]` (max 253) so a push record always matches the
   state regex.
6. Wrong chain with an id above the signed 64-bit range names it as hex (`rpc reports 0x...`).
7. Health query uses `--url "http://127.0.0.1:<port>/health/network"` (the spec showed it
   positional); same request.

For A1b (lib/alerts.sh), contract notes:
- `hb_target_normalize` sets `HB_URL` as well as printing it. `HB_ERR` is lost when the call runs
  inside `$( )`, so call it directly (`hb_target_normalize "$k" "$u" "$allow" >/dev/null`) and read
  `HB_URL` / `HB_ERR`. It may also return `url has no host` (item 5).
- `hb_state_get FILE KEY` re-reads and validates the whole file on every call and leaves `HB_S_<key>`
  globals set in the caller (harmless, namespaced). rc 1 for absent key, missing/invalid/symlinked
  file; an empty value (e.g. `last_block=`) prints an empty line with rc 0.
- `hb_header_number JSON` counts `[` as a level too, so a result that is an array is rc 1.
- The state may also lack keys (a value that failed validation on save is left out); treat a
  missing key as unknown.
- vm.d/P0-alerts.sh: `systemctl show -p StateChangeTimestampMonotonic` under DynamicUser is the same
  `Properties.GetAll` call, so the existing assertion covers it.

None of these needs a change in another package's file.

## Verifier fixes (F-B)
status: done
- [x] FB1 N3: lib/tn-heartbeat.sh:176-177 refuses a healthchecks URL holding `?` or `#`
  (`HB_ERR="healthchecks: a query string or fragment is not allowed"`), comment :104-106. Kuma's
  `#` cut unchanged. Table: heartbeat_test.sh:79 (kuma `#frag` cut), :89 (query, new message),
  :91 and :93 (`#x` and `/fail#x` refused).
- [x] FB2 W3: heartbeat_test.sh:481-489 RPC starting grace 119 s up / 120 s down; :538-548 restart
  restarts the stall window (header_since = the run's mono, still up 60 s later at 230 s on one
  header); :574-587 unreadable tn_nodeMode keeps inactive_since, down at 900 s from the first
  CvvInactive; :589-603 Observer (up `Observer block 1234567 epoch 42`, webhook mode Observer)
  clears the window, a later CvvInactive starts fresh.
- [x] FB3 N2: :66-67 `"number":12.5` unreadable (M39); :122-123 hb_url_host drops `%`/`!` (M65);
  :155-157 and :172-174 the stand-ins log an inherited TN_BLS_PASSPHRASE to $T/env-leak, :772-783
  positive control plus a run with it exported (M60). Not covered (equivalent or harmless per
  V1): M25/M25b, M37, M44, M66, M69.
- [x] FB4 mutants (scratch F-B/mut, expressions from V1's lists applied to a copy of the current
  runner; test copy with RUNNER from HB_RUNNER): unmutated 187/0; M04 1 fail, M21 2, M23 2,
  M63 3, M39 1, M60 1, M65 1, N3 (back to `*\?*`) 2. All killed.
- [x] FB5 gates: heartbeat_test 187 checks 0 failures 0 skipped under bash 5.3.9, bash:3.2
  (3.2.57) and ubuntu:24.04 (5.2.21, root); bash -n both bashes; check-bash32 clean;
  shellcheck error and warning clean; check-network-hits clean (146 hits, 27 files);
  passphrase_print_test 4/4, and its lint function run directly on both files: no hits;
  check-perl-interp clean. alerts_test (other fixer already on the new message) 268/0/3.
