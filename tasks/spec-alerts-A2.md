# Package A2: `setup-alerts.sh`, `tools/tests/setup_alerts_test.sh`, a row in `addon_oldlib_test.sh`

Read `tasks/spec-alerts-shared.md` first (sections 1, 7, 8, 10). Checkpoint:
`tasks/ckpt-alerts-A2.md`. Scratch: the shared scratchpad path `/A2/`. You run in W2, after
A1a and A1b are done: `lib/alerts.sh` and `lib/tn-heartbeat.sh` exist; read them before you
write a call.

## Files you own

- `setup-alerts.sh` (new; `chmod 0755`)
- `tools/tests/setup_alerts_test.sh` (new)
- `tools/tests/addon_oldlib_test.sh`: one more `old_run` row for `setup-alerts.sh --json
  --status` (and the copy of `setup-alerts.sh` into `$T/old`), plus the header comment.

## Sections

- S0 read the shared spec, `setup-observability.sh` whole (914 lines; it is the model),
  `setup-vpn.sh` `usage()` (:1498), `lib/alerts.sh` and the `hb_*` helpers; write the header.
- S1 skeleton: header, `source lib/common.sh`, `SCRIPT_VERSION`, `alerts_require_lib`,
  `addons_say`, `sa_baseline_refresh` (declare -F guard), json helpers, EXIT/signal traps,
  `load_node_context` (no `require_testnet`), `arg_fail`, `usage`.
- S2 argument parsing (section 8): exactly one action; one target source; `TN_ALERT_TARGETS`
  copied and `unset` first thing in `main`; `--target` warns; `--interval`/`--stall-after`/
  `--inactive-after`/`--label`/`--allow-http`; unknown argument refused; `-h`/`--help`.
- S3 `run_json_mode`: lock per action (`addon_meta_write_begin` for enable/refresh/disable,
  `addon_meta_lock` for test, none for status), the `done` shapes, exit codes 0/1/2/3,
  `sa_baseline_refresh` after a change.
- S4 the menu (7 items), target collection with hidden input, interval prompt, the post-enable
  advice, `--enable` without `--json` (asks when stdin is a terminal; refuses otherwise with the
  stdin hint).
- S5 tests (section 10): drive the script with a stub `lib/alerts.sh`-level override (source the
  real libraries, then redefine `alerts_*` functions in a wrapper script that `source`s
  setup-alerts.sh? No: setup-alerts.sh runs `main "$@"` at the bottom. Instead copy the script
  into `$T`, put a `lib/` beside it whose `common.sh` sources the real one and then overrides the
  `alerts_*` functions to record calls and return canned results, as other fixture tests do for
  setup-observability). Cases per section 10. `addon_oldlib_test.sh` row.
- S6 gates: `bash -n` (bash 5, `bash:3.2`), `check-bash32.sh`, `shellcheck -x
  --severity=error`, `run.sh tools/tests/setup_alerts_test.sh tools/tests/addon_oldlib_test.sh`
  in the three environments, `passphrase_print_test.sh`, `root_write_pipe_test.sh`,
  `check-network-hits.sh`.
