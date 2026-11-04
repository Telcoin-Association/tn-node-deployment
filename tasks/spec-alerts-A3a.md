# Package A3a: setup-node.sh and check-node.sh integrations and their tests

Read `tasks/spec-alerts-shared.md` first (sections 1, 9 "setup-node.sh" and "check-node.sh", 10).
Checkpoint: `tasks/ckpt-alerts-A3a.md`. Scratch: the shared scratchpad path `/A3a/`.

## Files you own

- `setup-node.sh` (`SCRIPT_VERSION` stays 2.1.0)
- `check-node.sh` (`SCRIPT_VERSION` stays 2.1.0)
- `tools/tests/host_baseline_test.sh` (the driver list :596-600 and the order string :616)
- `tools/tests/check_node_hardening_test.sh` (new cases for `check_alerts` and the
  `check_ownership_layout` rows)
- a new `tools/tests/setup_node_alerts_test.sh` for `prompt_alerts`, the read-back, the
  `.node-meta` key, `step_alerts` (driver style as host_baseline_test.sh: stub the other steps,
  stub `systemctl is-active`, stub `setup-alerts.sh` with a script in `$T` that records argv and
  exits per env), and the final summary lines.

`lib/alerts.sh` is written by A1b in parallel; check-node's `check_alerts` only needs the name
`alerts_status` and its contract (rc = issue count, prints its own lines); stub it in the test.
Do not add helpers to `tn_require_fns` in setup-node (lib_skew_test.sh stays untouched) nor to
the check-node helper list lib_skew_test.sh:176 checks.

## Sections

- S0 read the shared spec, setup-node.sh :270-285, :418-440, :1875-1895, :2570-2590,
  :2823-2900, :3319-3482, lib/common.sh `prompt_testnet_addons`/`step_testnet_addons`
  (:10296-10415) and `confirm` (:159); check-node.sh :291-300, :1767-1790, :1878-1960,
  :2125-2150, :2205-2225; host_baseline_test.sh :560-625; check_node_hardening_test.sh whole.
- S1 setup-node: default, read-back, `prompt_alerts`, `write_node_meta` key, `step_alerts`,
  `step_final_summary` lines, header comment mention, `--help` text if the script has one for
  add-ons.
- S2 check-node: `check_alerts`, the loop entry, the `_cn_own` rows, the header comment.
- S3 tests: host_baseline_test.sh update; check_node_hardening_test.sh cases; the new
  setup_node_alerts_test.sh.
- S4 gates: `bash -n` (bash 5, `bash:3.2`), `check-bash32.sh`, `shellcheck -x
  --severity=error` on both scripts, `run.sh` on the three test files plus
  `tools/tests/lib_skew_test.sh` in the three environments, `passphrase_print_test.sh`,
  `root_write_pipe_test.sh`, `check-network-hits.sh`.
