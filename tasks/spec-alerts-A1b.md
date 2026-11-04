# Package A1b: `lib/alerts.sh`, the common.sh source block, `tools/tests/alerts_test.sh`, `tools/tests/vm.d/P0-alerts.sh`

Read `tasks/spec-alerts-shared.md` first (sections 1, 2, 3, 6, 7, 10 are yours). Checkpoint:
`tasks/ckpt-alerts-A1b.md`. Scratch: the shared scratchpad path `/A1b/`.

## Files you own

- `lib/alerts.sh` (new)
- `lib/common.sh`: ONLY the guarded source block for `alerts.sh` after the observability block
  (:10422-10431), same shape, before the final `: # ensure …` line. `COMMON_VERSION` stays.
- `tools/tests/alerts_test.sh` (new)
- `tools/tests/vm.d/P0-alerts.sh` (new)

A1a writes `lib/tn-heartbeat.sh` in parallel. Until it exists, test your library against a
stub runner you write under `$T` (a script that writes a state file from env), and source the
`hb_*` helpers from a small stand-in in your test only if `lib/tn-heartbeat.sh` is still absent
(`[[ -f ]]` guard). V1 runs the real pair later. `lib/alerts.sh` sources
`"${__ALERTS_DIR}/tn-heartbeat.sh"` when present (`__ALERTS_DIR="$(cd "$(dirname
"${BASH_SOURCE[0]}")" && pwd)"`), as common.sh does for observability.

## Sections

- S0 read the shared spec; read `lib/observability.sh` `obs_write_token_file` (:538),
  `_obs_snapshot`/`_obs_restore` (:1602-1666), `obs_rotate_token` (:1667), `obs_disable`
  (:1735), `obs_status` (:1874) and `lib/common.sh` `tn_write_root_file` (:582),
  `tn_install_root_binary` (:741), `_tn_root_layout_dir` (:862), `addon_meta_get` (:8450),
  `tn_node_launch_target` (:8932), `tn_launch_flag_get` (:9486); write the file header.
- S1 paths and say: `alerts_etc_dir`, `alerts_targets_file`, `alerts_env_file`,
  `alerts_runner_path`, `alerts_unit_path`, `alerts_timer_path`, `alerts_state_file` (all under
  `${TN_ROOT_PREFIX:-}`), `_alerts_say`.
- S2 `alerts_targets_validate`, `alerts_write_targets`, `alerts_rpc_url`, `alerts_write_env`,
  `alerts_install_runner`, `alerts_unit_text`, `alerts_timer_text`, `alerts_write_units`.
- S3 `alerts_test`, `alerts_enable`, `alerts_set_targets`, `alerts_refresh`, `alerts_disable`,
  `alerts_status` (the issue count is the rc, capped at 20).
- S4 the common.sh source block.
- S5 `tools/tests/alerts_test.sh` (section 10): stubs for `systemctl` (logs every call to
  `$T/calls`; `start telcoin-heartbeat.service` runs `$T/stub-runner` which writes a state file
  per `$T/scenario`), `systemd-analyze` only when the real one exists; `tn_write_root_file`
  logged through a wrapper that calls the real one; root-only cases print `SKIP` when not root
  (the ubuntu container runs them).
- S6 `tools/tests/vm.d/P0-alerts.sh` (section 10): source `vm_lib.sh`; `skip` without
  python3 or when `setup-alerts.sh` is absent (A2 writes it in W2; the file must still be valid
  and pass `bash -n` now); clean up its units, fake service and listener on EXIT. Run it
  yourself in a privileged systemd container if you can (`docker run --privileged … ubuntu:24.04`
  with systemd as PID 1 is not required: if it cannot run here, say so in the checkpoint; CI
  runs it in `integration.yml`).
- S7 gates: `bash -n` (bash 5, `bash:3.2`), `tools/check-bash32.sh`, `shellcheck -x
  --severity=error`, `run.sh tools/tests/alerts_test.sh` in the three environments,
  `root_write_pipe_test.sh`, `passphrase_print_test.sh`, `check-network-hits.sh`,
  `tools/tests/lib_skew_test.sh` and `tools/tests/addon_gates_test.sh` still pass (the source
  block must not change any existing behaviour).

## Notes

- `tn_write_root_file` refuses a destination whose directory fails `tn_root_dir_ok` (every
  directory up to `/` real, root-owned, not writable by others): in the fixture tree under
  `TN_ROOT_PREFIX` that check is as the existing tests handle it (look at how `obs_test.sh` or
  `host_baseline_test.sh` prepare `$TN_ROOT_PREFIX` and whether they run as root).
- `systemctl clean --what=state` needs systemd 236+; the fallback `rm -rf` covers the prefix
  tree and older hosts.
- The state dir real path is `/var/lib/private/telcoin-heartbeat` and `/var/lib/telcoin-heartbeat`
  is a symlink systemd makes; read through the real path, refuse a `state` that is a symlink.
