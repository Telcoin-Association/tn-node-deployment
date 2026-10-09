status: done
owner: B5
files: edit-config.sh (1.2.5 -> 1.2.6), remove-node.sh (1.2.7 -> 1.2.8)

## Completed sections
- Section 1 -- edit-config.sh: DONE. SCRIPT_VERSION 1.2.6. NODE_TYPE global and the
  tn_resolve_node_type call removed. File header comment, detect_node ("Detected node service:"),
  print_header "Current Configuration -- ${TARGET_SERVICE}", "Service name:" row (was "Node type:"),
  and the refresh prompt now name TARGET_SERVICE. Parser: `--observer|--validator) shift ;;` with
  comment. run_json_set comment updated. No usage/help text ever listed the flags.
  Gates: bash3.2 -n, bash5 -n, shellcheck --severity=error: clean.
  Harness scratchpad/B5/ec-harness.sh, both bashes: --validator --json --set x=y -> pure JSON,
  done ok:false; --observer --json --set verbosity=-vvv -> pure JSON, done ok:true, stub log shows
  systemctl daemon-reload / restart telcoin / is-active. Literal checks (json grep -v '^{', --help
  grep for role flags) print nothing.
- Section 2 -- remove-node.sh: DONE. SCRIPT_VERSION 1.2.8. json_remove: slot token validation kept
  (error now "invalid node slot: X"), installed_type mismatch refusal deleted, comments say the token
  is a UI slot name; "no node installed" when no unit resolves; done-event key "node_type" kept
  (echoes the slot) for UI compatibility. Role removed elsewhere: UNIT_TYPE map (dead after the change)
  and all tn_resolve_node_type calls removed; show_detected "Node detected (unit)"; remove_keys shows
  one role-independent strong warning; wipe/removal messages name the unit; remove_chain_data and
  remove_keys take no arg (detect_data_dir ignored it). Two bash-4 `${x^}` uses disappeared with it.
  Gates clean. Harness scratchpad/B5/rn-harness.sh (bash 5): .node-meta NODE_TYPE=observer +
  --remove validator --scope service -> stub log `systemctl stop telcoin`, done ok:true, pure JSON;
  HEAD baseline same args -> {"event":"error","msg":"node not installed: validator"}. Also data scope,
  bogus slot (rejected), legacy telcoin-observer unit with --remove validator --scope keys, and
  missing --yes all pure JSON. Under /bin/bash 3.2 the script dies at the pre-existing
  `declare -A UNIT_DOCKER` (identical at HEAD).
- Drafts: DONE (below).

## README changelog draft

### edit-config v1.2.6 / remove-node v1.2.8 — role flags no longer required
The node binary no longer has an `--observer` flag: its role is decided on-chain each
epoch. `edit-config.sh` stops tracking a node type. The interactive display, its header
and the "Refresh chain configs" prompt now name the resolved service (`telcoin`, or the
legacy unit name on older installs). Node Manager UI helpers that haven't been updated
still pass `--observer` or `--validator` on every `--json --set` call. The flag is
accepted and ignored, and stdout stays pure JSON.

`remove-node.sh --json --remove <observer|validator>` now treats the token as the UI's
slot name, not a role. v1.2.7 compared it with `NODE_TYPE` in `.node-meta` and refused
with "node not installed" when they differed. Every new install records
`NODE_TYPE=observer` as a view hint, so removing from the UI's validator view always
failed. The check is gone, and either token removes the single installed node. The
interactive menu no longer labels the node by role, and the key-deletion warning is the
same for every node, since nothing on the server says whether its keys are staked.

## Commit message draft

fix(edit-config,remove-node): role flags are ignored; the role is decided on-chain

edit-config.sh 1.2.6 drops the NODE_TYPE global and names the resolved
service in its display and prompts. --observer/--validator are still
accepted (old UI helpers send them) and ignored; --json stdout stays JSON.
remove-node.sh 1.2.8 no longer refuses --json --remove when the UI slot
differs from the .node-meta NODE_TYPE hint, and its key warning no longer
depends on a locally recorded role.

## Open issues
- remove-node.sh still has 3 pre-existing `declare -A` (UNIT_DOCKER/USER/GROUP); I deleted the
  4th (UNIT_TYPE) only because it became dead code. Script cannot run under bash 3.2 (same at HEAD).
- Changed JSON error strings: "invalid node type: X" -> "invalid node slot: X"; "node not installed: X"
  -> "no node installed". grep shows no UI code matching on either string.
- Pre-existing, untouched: edit-config `--set` as the last arg does `shift 2` with one positional left.
