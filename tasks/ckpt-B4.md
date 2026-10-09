status: done (all 7 sections complete; ready for orchestrator)

# B4 checkpoint — check-node.sh 1.1.54 -> 1.1.55

## Completed sections
- 1 Read. Top-level script (no main, no check_root). §1 service, §2 local RPC, §3 network,
  §4 local consensus (gated on LOCAL_RPC_MODE HEALTHY|SLOW), §5 EVM, probe call, §6 authority,
  §7 on-chain status, §8 disk, §9 mem, §9.5/9.6 add-ons/public RPC, §10 summary.
- 2 detect_node + flags. set_node_type/detect_node_type/NODE_TYPE/NODE_TYPE_EXPLICITLY_SET
  removed; new detect_node (RPC_URL only if empty, numeric RPC_PORT else DEFAULT_RPC_PORT;
  SERVICE_NAME via tn_resolve_service unless --service, else telcoin + warn).
  --validator|--observer -> one stderr note ("note: --observer is ignored; the role is
  decided on-chain each epoch"), continue. Help lines + "Node type:" header gone.
  State file -> ${TMPDIR:-/tmp}/check-node.state. §2 DOWN hint no longer says "observers".
- 3 Stake status. probe_onchain_validator_status calls node_stake_status once (|| rc=$?),
  caches ONCHAIN_STAKE_LINE/RC; statuses 1-4 -> IS_ONCHAIN_VALIDATOR=true. New
  report_onchain_validator_status (print_step header + Address/Contract +
  print_validator_onchain_status; rc 1 invalid-address warn; rc 2 "Could not read the
  on-chain stake status from <rpc> -- validator-only checks are skipped this run") is
  called from §7 (placement unchanged). ONCHAIN_STATUS_OUTPUT + grep removed.
- 4 Consensus role. fetch_node_mode <url>: curl tn_nodeMode (--max-time 5), regex on
  "result":"X"; prints "Consensus role: ..." for CvvActive/CvvInactive/Observer, else
  silent; always rc 0. Called at the end of the §4 RPC-up block.
- 5 Legacy --observer warning. report_legacy_observer_flag (after §1 service block):
  tn_node_launch_target -> read svc _ file; silent unless readable + tn_node_has_observer_flag;
  print_warn + 2 print_info; fix command uses ${SCRIPT_DIR}/update-scripts.sh &&
  ${SCRIPT_DIR}/update-node.sh. Never touches HEALTH_ISSUES.
- 6 Version/help. SCRIPT_VERSION=1.1.55; header comment rewritten; help has no role flags;
  --rpc help default uses ${DEFAULT_RPC_PORT}.
- 7 Harness (scratchpad/B4/harness). (a) help: no role flags, rc 0. (b) --observer
  --no-network: note on stderr, no "Node type:", rc 0 (needs a /proc/meminfo fixture on
  macOS; HEAD dies the same way without it). fn-tests.sh: 44/44 PASS under bash 3.2.57 and
  5.3.15 (detect_node, state file name, stake statuses 0-6/none/unknown rc1/rc2, one call
  per probe, set -e survival with real node_stake_status, fetch_node_mode x6, observer
  warning x4). Integration run (method-aware curl stub) under both bashes: rc 0, warning in
  §1, role line in §4, §7 "Status: Active"; status 5 + no tn_nodeMode -> no role line,
  absent author is info, "All checks passed". Gates: /bin/bash -n, brew bash -n,
  shellcheck --severity=error pass; full shellcheck output identical to HEAD.

## README changelog draft

### check-node v1.1.55 — stake status decides validator checks; consensus role; --observer warning
check-node no longer has a validator or observer mode. The role is decided on-chain each
epoch, so the script reads the node's stake status from the ConsensusRegistry once per run
and uses that one answer twice: statuses Staked, Pending Activation, Active and Pending Exit
turn on the validator checks (missing from the committee headers is then an error), and the
same result is printed in the on-chain status section. v1.1.54 got the same answer by
grepping its own rendered report. When the status can't be read, the script says so and
treats the node as a full node for that run. `--validator` and `--observer` are accepted
but ignored with a one-line note on stderr; the `Node type:` header line is gone, and the
block-advancement state file is now a single `check-node.state` instead of one per role.

When the local RPC answers, the consensus section adds a `Consensus role:` line from the
node's `tn_nodeMode` method: `CvvActive` (voting in the current committee), `CvvInactive`
(in the committee, catching up) or `Observer` (following consensus, not in the committee).
Binaries without the method print nothing, and the line never changes the verdict.

The service section now warns when the node's launch file (the start wrapper, or the unit
of a legacy docker install) still passes `--observer`. v0.15.0-adiri ignores the flag, but
later releases reject it, so the node would not start after an update. The warning names
the file and the fix: run `update-scripts.sh` then `update-node.sh`, which strips the flag,
or delete the token and restart the service. It is not counted as a health issue, and it
stays quiet when the launch file can't be read (for example without sudo).

## Commit message draft

feat(check-node): on-chain stake decides the validator checks; consensus role line; legacy --observer warning

Read the stake status once with node_stake_status: statuses 1-4 enable the validator
checks and the same line is rendered in section 7 by print_validator_onchain_status,
replacing the grep over captured report text.
Drop the validator/observer view: --validator/--observer print a stderr note and are
ignored, the Node type header line is gone, the state file is check-node.state.
Add a best-effort Consensus role line from tn_nodeMode (silent when unsupported).
Warn in section 1 when the launch file still passes --observer, which releases after
v0.15.0-adiri reject. SCRIPT_VERSION 1.1.55.

## Open issues for orchestrator
- See final report.
