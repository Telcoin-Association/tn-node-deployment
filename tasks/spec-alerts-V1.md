# Package V1: independent verification of the private-alerts round

Read `tasks/spec-alerts-shared.md` first. Checkpoint: `tasks/ckpt-alerts-V1.md`. Scratch: the
shared scratchpad path `/V1/`. You edit nothing in the repo except your checkpoint; findings go
there with file:line citations, severity (E error / W warning / N note) and the exact fix text
where it is short.

Re-derive from the code and the spec BEFORE reading any implementer checkpoint (read them last,
to find what they claim and did not do).

## Sections

- V0 `git status`, `git diff --stat hardening-followups`, list every new and changed file;
  confirm no commit was made by an agent and no `*.sha256` was touched yet.
- V1 gates, all of them, recorded with their output summary: `bash tools/tests/run.sh` (bash 5);
  the `bash:3.2` and `ubuntu:24.04` containers; `bash -n` under both bashes on every changed
  `*.sh`; `tools/check-bash32.sh` on each; `shellcheck -x --severity=error` on each (and the
  warning run, advisory); `tools/check-perl-interp.sh` on every tracked `*.sh`;
  `tools/tests/passphrase_print_test.sh`; `tools/tests/root_write_pipe_test.sh`;
  `tools/check-network-hits.sh`; `tools/tests/ci_pins_test.sh`; `bash tools/gen-checksums.sh`
  then `git diff --stat -- '*.sha256'` (expect the three new sidecars and changed ones for
  common.sh, setup-node, check-node, remove-node, update-scripts; then `git checkout --
  '*.sha256'` and `git clean -n` to leave the tree as it was, removing the three new sidecars
  you generated so the orchestrator makes them in W5).
- V2 systemd: in `ubuntu:24.04` (`apt-get install -y systemd`), render both units with
  `alerts_unit_text`/`alerts_timer_text` and run `systemd-analyze verify` and `systemd-analyze
  security` on the service (expect no error; record the exposure score).
- V3 AGENTS-rule sweep: `grep -n 'require_testnet\|is_testnet' setup-alerts.sh lib/alerts.sh
  lib/tn-heartbeat.sh` empty; `git diff hardening-followups -- lib/common.sh` is the source
  block only; no URL on argv in the runner (every curl gets `-K`); no `echo`/`printf` of a URL
  or token; no root write outside the primitives (`grep -n '> *"\?/etc\|cp \|sed -i\|mv '` in
  the new files, judged); no `systemctl stop|restart <node>` anywhere in the three new files;
  `tn_testnet_addons_present` unchanged; the versions and the first-match rule for
  `_file_version` on the three new files (`bash -c 'source update-scripts.sh …'` is not needed:
  reproduce the grep).
- V4 runner mutants: about 20 one-line mutations of `lib/tn-heartbeat.sh` (swap a `>=` for `>`,
  drop the depth check, drop the kuma body check, drop the reboot reset, let a `$(…)` state value
  through, drop `-K`, etc.), each run against `tools/tests/heartbeat_test.sh`; a mutant the test
  does not catch is a finding (W) with the missing assertion.
- V5 docs vs code: every flag, path, message, field, reason string and exit code in OPERATOR.md
  §4.14, README, the release note, docs/testnet-addons.md, AGENTS.md and the guide against the
  code; the guide with `--html-only` in the `tn-pdf-tools` container.
- V6 read the implementer checkpoints; list claims you could not confirm.
- V7 the findings list, ordered by severity, with the package that owns each file.

## Items the implementers raised (check each; decide E/W/N or "fine as is")

- A1b: `alerts_enable` on an already-enabled node without targets keeps the stored interval
  (`--interval`, `--stall-after`, `--inactive-after` are ignored there); the operator must
  disable and enable again to change them. Decide whether the docs say so, or whether a fixer
  should make an explicit flag refresh the env with the new values (preferred if small: a
  request variable like `ALERTS_LABEL_REQ`).
- A1b additions beyond section 7: refresh also `systemctl enable`s the timer; status counts
  alerts.env drift as an issue; `ENABLE_ALERTS=true` with no timer unit is treated as a fresh
  install; `alerts_test` starts the service a second time if a timer-started run answered the
  first start. Check each is correct and documented.
- A1b: `alerts_set_targets` returns 2 when the old file could not be put back; setup-alerts
  must map that to exit 3.
- A1b: `P0-alerts.sh` never passed end to end locally (Docker cannot provide a
  `LoadCredential=` directory). Read it closely for assumptions about setup-alerts.sh's output;
  it is proven only by the CI VM job after the push.
- A1a: the seven departures in `tasks/ckpt-alerts-A1a.md` (restart age from
  `StateChangeTimestampMonotonic`, `auto-restart*`, grace ends the checks, 0 stamp unknown,
  the extra normalisation rules, hex chain id, `--url` for health). Section 13 of the shared
  spec accepted them; confirm the docs match.
- A3a: the read-back uses `setup_meta_read` and stops setup on a duplicated `ENABLE_ALERTS`
  key; `check_alerts` prints the quiet one-liner on hosts without alerts (confirm A1b's quiet
  form reached the library and the check-node test).
- A3b: `release_scripts_test.sh` fails until the three new files are committed (expected; the
  orchestrator commits after your pass); the updater's setup-alerts version check un-skips once
  setup-alerts.sh exists: run `tools/tests/updater_manifest_test.sh` again.
- A4a/A4b: every string from setup-alerts.sh, lib/alerts.sh and lib/tn-heartbeat.sh in the docs
  was written from the spec before the code existed. Their unconfirmed lists are in
  `tasks/ckpt-alerts-A4a.md` and `tasks/ckpt-alerts-A4b.md`; the guide example `consensus
  stalled at header 812 for 240s` assumes the `Ns` form; `TN_ALERT_TARGETS` has a row in the
  release note's environment table; the `--allow-http` wording (refusal vs warning) must match
  setup-alerts.sh.
- Shared-spec section 13 is binding where it differs from sections 1-12.
- A2: when `--stall-after` or `--inactive-after` is omitted the default derives from the
  interval (max(180, 3 x interval); max(900, stall)), matching the menu; the docs must state
  the derived defaults (the spec's fixed 180 would refuse any `--interval` above 150).
- A2: `TN_ALERT_TARGETS` is copied and unset before `lib/common.sh` is sourced (fine).
- A2/A1b: a failed fresh enable on a host with no `ENABLE_ALERTS` line leaves
  `ENABLE_ALERTS=false` in `.node-meta` (the rollback writes the value it read, and "absent"
  reads as `false`), and setup-alerts exits 1 without a baseline refresh, so on a
  `HOST_BASELINE=true` host AIDE reports `.node-meta` changed. Decide: the rollback should
  `meta_unset ENABLE_ALERTS` when the key was absent (cleanest), or the script refreshes the
  baseline on that path. Mark E or W with the fix.
- A2: a failure `done` carries only `ok` and `msg`; per-target results of a failed test are in
  the warn events. Fine unless the docs promise otherwise.

## Split (orchestrator, after A2)

Two verifiers run in parallel from this spec. **V1** does V0-V4, V6 and V7 for the code and
tests (checkpoint `tasks/ckpt-alerts-V1.md`). **V1d** does V5, the docs-versus-code pass, for
OPERATOR.md, README.md, CHANGELOG/scripts-v2.1.0.md, docs/testnet-addons.md, followup.md,
AGENTS.md and the partner guide (checkpoint `tasks/ckpt-alerts-V1d.md`), including the
`--html-only` guide build in the `tn-pdf-tools` container and the items above that concern
docs. Neither edits any repo file but its own checkpoint.
