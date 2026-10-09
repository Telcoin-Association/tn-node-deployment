# ckpt-B3 — update-node.sh 1.1.62 (strip retired --observer; role flags ignored)
status: done

## Completed sections
- [x] 1. Read
- [x] 2. Role removal: NODE_TYPE, NODE_TYPE_EXPLICITLY_SET, set_node_type deleted; detect_node_type -> detect_node (SERVICE_NAME via tn_resolve_service, exit 1 with "Re-run setup-node.sh"; RPC_URL from meta RPC_PORT else DEFAULT_RPC_PORT when empty); both callers updated (run_json_mode, main). Arg loop `--validator|--observer) LEGACY_ROLE_FLAG="$1"`; human mode prints one stderr line "Ignoring <flag>: the node's role is decided on-chain, not by a flag."; JSON mode prints nothing. node_is_onchain_validator_or_unknown -> node_is_staked_validator, returns 1 only on rc 1 (fail-open). "Re-run setup-${NODE_TYPE}.sh" -> setup-node.sh. USAGE lines for the flags removed.
- [x] 3. Docker strip: new helper observer_strip_needed <file> <target...> (tn_target_drops_observer && tn_node_has_observer_flag). apply_docker_update + json_apply_docker strip after the hash/grep checks, before start_service; daemon-reload after a strip; human print_info / JSON `json_event step "stripped retired --observer flag from <file>"`; strip failure warns and continues. Existing pre-perl backup (backup_unit_file / inline cp -p) is of the same launch file (docker_launch_file = tn_node_launch_target 3rd field) and predates the strip, so every rollback already restores it. Target text = ${new_image##*/} (name:tag, so a registry host:port is never read as a version).
- [x] 4. Source strip: apply_source_update + json_apply_source, after the binary swap: wrapper = tn_node_launch_target 3rd field; if observer_strip_needed "$wrapper" "$new_ref $new_version": backup_unit_file -> wrapper_backup (backup failure = no strip, warn), strip, log. Verify-failure rollbacks restore the wrapper after the binary restore; the binary-restore-failure manual hint / JSON msg names the wrapper backup too. The cp-failure early-abort runs before the strip (nothing to restore).
- [x] 5. SCRIPT_VERSION 1.1.62. Header paragraph on the strip (help-visible, no literal role flags). Compat comment just below the header rule names --observer/--validator as accepted and ignored. --help now prints exactly the header block (awk to the closing rule) instead of `grep '^# ' | head -30`, which spilled internal comments and would have shown the compat note.
- [x] 6. Harness (scratchpad/B3/h.sh 89 checks + h2.sh 22 edge checks) — all PASS under /bin/bash 3.2.57 and /opt/homebrew/bin/bash 5.3.15. Gates: /bin/bash -n, brew bash -n, shellcheck -x --severity=error all clean (warning count unchanged: 5 before, 5 after).

## README changelog draft

### update-node v1.1.62 — drops the retired --observer flag during updates
The node binary no longer has an `--observer` flag. v0.15.0-adiri still accepts it as a
hidden no-op, but the next release rejects it (`unexpected argument '--observer'`), so a
legacy start wrapper or docker unit that still passes it would leave the node down after an
update. When the update target is v0.15.0 or newer (or a branch, SHA or digest with no
version in it), the apply step now removes the flag from the launch file before restarting
the node. Docker installs reuse the launch-file backup the image swap already takes;
source installs back up the start wrapper first. Either way a failed health check rolls
the file back with the old image or binary. If the strip itself fails, the update warns
and carries on.

`--observer` and `--validator` are still accepted, because older copies of the UI helper
pass one on every `--json` call, but they do nothing. The node's role is decided on-chain.
An interactive run prints one line on stderr saying the flag was ignored; `--json` output
is unchanged. The "Detected node type" line is gone, and the validator downtime prompt now
reads the on-chain stake status directly (`node_is_staked_validator`, lib/common v1.4.0)
instead of parsing the human status report. It still errs toward prompting when the
status can't be read. `--help` now prints only the header block.

## Commit message draft

feat(update-node): strip the retired --observer flag on update; role flags ignored

Before restarting on a v0.15.0+ target, the docker and source apply paths
(human and --json) strip --observer from the launch file. Docker reuses the
pre-swap launch-file backup; source backs up the start wrapper and restores
it on rollback. --observer/--validator are parsed and ignored (one stderr
notice in human mode). NODE_TYPE plumbing is gone; detect_node resolves the
service and RPC URL. The validator guard uses node_is_staked_validator and
fails open. --help prints the header block only. SCRIPT_VERSION 1.1.62.
