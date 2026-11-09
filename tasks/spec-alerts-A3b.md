# Package A3b: remove-node.sh, update-scripts.sh, AGENTS.md and their tests

Read `tasks/spec-alerts-shared.md` first (sections 1, 9 "remove-node.sh", "update-scripts.sh",
"AGENTS.md", 10). Checkpoint: `tasks/ckpt-alerts-A3b.md`. Scratch: the shared scratchpad path
`/A3b/`.

## Files you own

- `remove-node.sh` (`SCRIPT_VERSION` stays 2.1.0)
- `update-scripts.sh` (`SCRIPT_VERSION` stays 2.1.0; the three rows; the hint)
- `AGENTS.md`
- `tools/tests/remove_test.sh`, `tools/tests/remove_addons_test.sh`,
  `tools/tests/updater_manifest_test.sh`, `tools/tests/addon_gates_test.sh`

Do NOT run `tools/gen-checksums.sh` (the orchestrator does; CI's checksum job will be red on
the branch until then, which is expected). Do not create the alerts files themselves; your
remove code uses fixed paths and must work when `lib/alerts.sh` is absent (a host whose updater
installed remove-node.sh but not the library), so no `alerts_*` call.

## Sections

- S0 read the shared spec; remove-node.sh :39-60, :372-395, :800-900, :1150-1300, :1630-1680,
  :1715-1790, :1837-1874; update-scripts.sh :60-135, :190-210, :785-815; AGENTS.md whole;
  the four tests' heads and how they stub `systemctl`.
- S1 remove-node: `remove_alerts`, its three call sites, `rm_leftovers_present` and the shown
  list, header comment.
- S2 update-scripts: the three rows after :92, the `--refresh` hint after `install_pass`.
- S3 AGENTS.md (section 9): every listed edit plus the `## Private alerts` section; keep the
  file's voice (plain prose, rules, no marketing).
- S4 tests: remove_test.sh and remove_addons_test.sh (every scope and the leftover path remove
  the alerts files, in the systemctl log the alerts teardown comes before the node stop, removal
  with `lib/alerts.sh` absent, the hint line printed, the same remaining tree as the shared
  spec's `alerts_disable` leaves); updater_manifest_test.sh (hint printed when
  `lib/tn-heartbeat.sh` changed and the timer exists under `TN_ROOT_PREFIX`, not printed
  otherwise; the three rows are tracked: `version_var_for`); addon_gates_test.sh (alerts files
  alone: `tn_testnet_addons_present` rc 1, no output).
- S5 gates: `bash -n` (bash 5, `bash:3.2`), `check-bash32.sh`, `shellcheck -x
  --severity=error`, `run.sh` on the four tests in the three environments,
  `tools/tests/ci_pins_test.sh`, `check-network-hits.sh`, `root_write_pipe_test.sh`.
