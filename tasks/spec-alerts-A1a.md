# Package A1a: the heartbeat runner `lib/tn-heartbeat.sh` and `tools/tests/heartbeat_test.sh`

Read `tasks/spec-alerts-shared.md` first (sections 1, 3, 4, 5 and 10 are yours). Checkpoint:
`tasks/ckpt-alerts-A1a.md`. Scratch: the shared scratchpad path `/A1a/`.

## Files you own

- `lib/tn-heartbeat.sh` (new)
- `tools/tests/heartbeat_test.sh` (new)

Nothing else. `lib/alerts.sh` (A1b) will `source` your file for `hb_target_normalize`,
`hb_url_host`, `hb_header_number` and `hb_state_get`, so their contracts are fixed by the shared
spec; keep every other function `hb_*` too and keep the file free of side effects when sourced
(`hb_main "$@"` only when `[[ "${BASH_SOURCE[0]}" == "$0" ]]`; no `set -e` at top level, set it
inside `hb_main` if you want it; no `readonly` arrays at top level).

## Sections

- S0 read the shared spec; read `lib/common.sh` `tn_rpc_call` (:4065) and `_tn_curl_reason` for
  the curl-rc mapping style, `tn_json_field` (:4142) for the regex style, `update-node.sh`
  `_uc_header_number` (:1128) for what the header answer looks like; write the header comment
  of the file (what it is, how systemd runs it, the env it reads, the exit codes, the test hooks).
- S1 helpers: `hb_log PRIO MSG`, `hb_clean TEXT` (filter + cut 200), `hb_target_normalize`,
  `hb_url_host`, `hb_header_number` (string-aware awk depth walk), `hb_hex2dec`, `hb_json_str`
  (the escaping for `reason`/`node`), `hb_curl_why RC`.
- S2 state: `hb_state_get FILE KEY`, `hb_state_load` (whitelist + regex per key, symlink refused,
  invalid -> defaults + `<4>` line), `hb_state_save` (tmp + `mv -f`), reboot detection.
- S3 checks 1-5 exactly as section 5 of the shared spec, the up message, first-down-wins.
- S4 pushes per kind (section 5), the `-K` process substitution, kuma body check, the log line,
  `<5>status …` on change, exit codes 0/1/2.
- S5 `tools/tests/heartbeat_test.sh`: every scenario of section 10; stubs call nothing real
  (`systemctl` and `curl` stubs are scripts in `$T/bin` first on PATH, each reading its
  behaviour from files/env under `$T`); the curl stub must parse `-K FILE` and read `url = "…"`
  from it, parse `-G`/`--data-urlencode`/`--data-raw`/`--data-binary`/`-H`/`-w`/`--url`/`-X`
  enough to record a push and to answer an RPC from `$T/rpc/<method>` (the method is in the
  `--data` JSON). The stub never calls the real curl.
- S6 gates: `bash -n` (bash 5 and `bash:3.2`), `tools/check-bash32.sh`, `shellcheck -x
  --severity=error`, `bash tools/tests/run.sh tools/tests/heartbeat_test.sh` in all three
  environments (section 11), `bash tools/check-network-hits.sh`, `bash
  tools/tests/passphrase_print_test.sh`. Record commands and results in the checkpoint.

## Notes

- `/proc/uptime` is absent on macOS; `TN_HB_MONO` must cover it, and when both are missing use
  `date +%s` (the test always sets `TN_HB_MONO`).
- Under `ProtectProc=invisible` the runner still reads `/proc/uptime` and `/dev/fd/N` of its
  own process substitution.
- `--max-filesize` with `-sS` and a 2xx: curl exits 63 when the body is too large; treat as
  `too-large`.
- Keep awk POSIX: no `gensub`, no `length(array)`, no `--re-interval`; test under mawk (Ubuntu),
  busybox awk (`bash:3.2` image) and expect BSD awk on CI.
