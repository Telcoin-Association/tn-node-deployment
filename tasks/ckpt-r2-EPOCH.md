status: done

# Checkpoint: package EPOCH (round 2, PR #59)

- [x] S1 Constants (MAINNET/TESTNET/DEVNET_EPOCH_DURATION, tn_network_epoch_duration) -- 493860b
- [x] S2 Blind wait derives from the constant -- 6981526
- [x] S3 Tests (restart_window_test.sh cases, mutation note) -- df4f58d
- [x] S4 Docs you own (AGENTS.md, CHANGELOG/scripts-v2.1.0.md, followup.md) -- 95f99ff

Commits on r2/EPOCH (base 2966e54):
- 493860b lib/common: each network has an epoch length constant
- 6981526 lib/common: the blind restart wait follows the network's epoch constant
- df4f58d tests: the blind restart wait follows the network's epoch constant
- 95f99ff docs: mainnet's epoch is 6 hours and the blind wait follows the constant

## Operator-visible changes

- No value changes: every blind wait is still 300 + 90 = 390 s unless set, capped by
  TN_EPOCH_WAIT_MAX. The live wait (epoch length read from the node or public RPC) is untouched.
- The blind wait (node mode unreadable, node must wait, no RPC gives the epoch timing) now derives
  margin and settle from the network's epoch constant through `_tn_epoch_timing`, the same
  derivation as the live path: mainnet and testnet 21600 s -> 300 + 90. TN_EPOCH_MARGIN and
  TN_EPOCH_SETTLE still win. Devnet and a network tn_detect_network cannot tell keep the fixed
  300 + 90. A future change of a constant moves the blind wait with it.
- The blind-wait warning keeps its old text word for word and gains one closing sentence naming
  each value's source (see Docs notes).

## Docs notes

Facts:
- Constants at the top of lib/common.sh, after the devnet block: `MAINNET_EPOCH_DURATION="21600"`,
  `TESTNET_EPOCH_DURATION="21600"`, `DEVNET_EPOCH_DURATION=""` (unknown: no devnet genesis is
  tracked in this repository; the only genesis fixtures are the testnet ones under
  tools/tests/genesis.d/). Mainnet's equals telcoin-network `MAINNET_EPOCH_DURATION_SECS`.
- Resolver: `tn_network_epoch_duration NETWORK` prints the constant or nothing, always rc 0.
- The network for the blind wait is what `tn_detect_network` reports (NETWORK in .node-meta, else
  the genesis chain id). It only ever reports mainnet or testnet, so a devnet node lands on the
  fixed default.
- Blind-wait warning, full form on mainnet or testnet with nothing set:
  `This node is in the committee, but the time to the next epoch boundary could not be read
  (<why>). Waiting 390s (TN_EPOCH_MARGIN + TN_EPOCH_SETTLE, at most TN_EPOCH_WAIT_MAX) so the
  restart does not land on it; set TN_SKIP_EPOCH_WAIT=1 to skip. Margin 300s and settle 90s
  (network default: epoch 21600 s).`
  Other endings: `Margin 300s and settle 90s (default).` (devnet, network unknown);
  `Margin 120s and settle 30s (TN_EPOCH_MARGIN, TN_EPOCH_SETTLE).` (both set);
  mixed sources name each value: `Margin 120s (TN_EPOCH_MARGIN) and settle 90s (network default:
  epoch 21600 s).`, `Margin 300s (default) and settle 30s (TN_EPOCH_SETTLE).`
- No new flag, no new environment variable, no new file.

Done in this package: AGENTS.md "Restarts and the epoch boundary" (constants, #49 confirmed,
derived blind wait), CHANGELOG/scripts-v2.1.0.md "Restarts wait by the epoch length (#49)" (6 h
epoch of mainnet and testnet; the blind-wait bullet; the interim bullet replaced) and the Left
open #49 line, followup.md (the #49 item removed).

Stale lines for DOCS-2, with replacement sentences:
- OPERATOR.md, section on update waits ("Testnet's 6-hour epoch gives 300 and 90 seconds, a 7-day
  epoch 900 and 300." and "These shares are interim: the node team's mainnet epoch length and
  restart margins replace them (#49)."). Replace both with:
  "Mainnet and testnet both run 6-hour epochs (21600 seconds), which give 300 and 90 seconds; a
  7-day epoch would give 900 and 300. Mainnet's epoch length is confirmed (#49), so these shares
  stand."
- OPERATOR.md epoch-wait table: `TN_EPOCH_MARGIN` default "(300 on testnet)" -> "(300 on mainnet
  and testnet)", and "Before the epoch length is known (the blind wait, below the table), 300." ->
  "In the blind wait (below the table) it is derived from the network's known epoch length: 300 on
  mainnet and testnet, and 300 where none is known."; `TN_EPOCH_SETTLE` "(90 on testnet)" -> "(90
  on mainnet and testnet)", "Before the epoch length is known, 90." -> "In the blind wait, derived
  the same way: 90."; `TN_EPOCH_WAIT_MAX` "(420 seconds on testnet)" -> "(420 seconds on mainnet
  and testnet)".
- OPERATOR.md below that table ("the restart waits blind: `TN_EPOCH_MARGIN` + `TN_EPOCH_SETTLE`
  seconds (300 + 90 unless set), at most `TN_EPOCH_WAIT_MAX`."). Replace with:
  "the restart waits blind: `TN_EPOCH_MARGIN` + `TN_EPOCH_SETTLE` seconds, at most
  `TN_EPOCH_WAIT_MAX`. Unless set, both derive from the epoch length this release knows for the
  network (6 hours on mainnet and testnet, so 300 + 90), and are 300 + 90 on a network without one
  (devnet). The warning ends with where each value came from, for example `Margin 300s and settle
  90s (network default: epoch 21600 s).`"
- README.md, the paragraph after the epoch-wait table ("The epoch length is `epochDuration` ...
  replace them (#49)."). Replace with:
  "The epoch length is `epochDuration` from `tn_getCurrentEpochInfo`, read with the boundary. The
  6-hour epoch of mainnet and testnet (21600 s) gives 300 and 90; a 12-hour epoch gives 600 and
  180, a 7-day epoch 900 and 300. In the blind wait above, margin and settle derive the same way
  from the epoch length the release knows for the network (21600 s on mainnet and testnet, so 300
  and 90), and are 300 and 90 on a network without one (devnet). The messages end with one
  sentence naming the values and their source, such as `Margin 300s and settle 90s, derived from a
  21600 s epoch.`, `Margin 120s from TN_EPOCH_MARGIN; settle 300s derived from a 604800 s epoch.`
  or, in the blind wait, `Margin 300s and settle 90s (network default: epoch 21600 s).` Mainnet's
  epoch length is confirmed at 6 hours (#49), so the shares and clamps stand."
- README.md, the scripts-v2.1.0 change list ("`tn_wait_restart_window` derives the margin ... from
  the epoch length; adiri keeps 300 and 90."): "adiri keeps 300 and 90" -> "mainnet and testnet
  (6-hour epochs) keep 300 and 90, and so does the blind wait, which derives them from the
  network's epoch constant".
- Partner guide (docs/partner/mno-node-guide/mno-node-guide.md), restart wait ("On testnet's
  six-hour epochs (21600 seconds) that gives five minutes and 90 seconds; a seven-day epoch gives
  900 and 300 seconds."). Replace with:
  "On the six-hour epochs of mainnet and testnet (21600 seconds) that gives five minutes and 90
  seconds; a seven-day epoch would give 900 and 300 seconds. When the boundary cannot be read at
  all, the wait is the margin plus the settle time for the network's six-hour epoch, and the
  warning ends with `Margin 300s and settle 90s (network default: epoch 21600 s).`"
  Its table: "(300 on testnet)" -> "(300 on mainnet and testnet)", "(90 on testnet)" -> "(90 on
  mainnet and testnet)", "(420 seconds on testnet with the defaults)" -> "(420 seconds on mainnet
  and testnet with the defaults)".

## Tests run

- Baseline at 2966e54 (host bash 5.3.9): restart_window_test 43 checks 0 failures; keytool_test
  45 checks 0 failures.
- After S1 and S2 (host): both green with unchanged counts; check-bash32, bash -n (5.3 and
  bash:3.2), shellcheck 0.9 and 0.11 --severity=error -x, check-network-hits (146 annotated),
  check-perl-interp clean.
- After S3: `bash tools/tests/run.sh tools/tests/restart_window_test.sh tools/tests/keytool_test.sh`
  host bash 5.3.9: restart_window 62/0 (43 + 19 new), keytool 45/0 (file unchanged). Same in
  `bash:3.2` (3.2.57): 62/0 and 45/0. shellcheck 0.9 (docker) and 0.11 (host) `--severity=error
  -x` on lib/common.sh and tools/tests/restart_window_test.sh clean; bash -n 5.3 and 3.2 clean;
  check-bash32 clean on both files.
- Mutation (S3): a copy of the tree in the scratchpad with `readonly
  MAINNET_EPOCH_DURATION="36000"` (margin 36000/72 = 500, settle 150): restart_window 62 checks,
  5 failures: "mainnet epoch constant: 6 h", "mainnet blind wait derives from the 6 h constant:
  300 + 90" (650 waited, 390 expected), "mainnet blind wait: the warning names the network
  default", "env margin wins over the constant: 120 + 90" (270 waited, 210 expected), "env
  margin: each value names its source". The copy was removed afterwards.
- Final at 95f99ff, host bash 5.3.9 and bash:3.2 (3.2.57), same results in both: restart_window
  62/0, keytool 45/0, edit_backup 13/0 (6 root-only skips), update_guard 67/0, prepare_stake
  43/0, consensus_participation 41/0, migrate_naming 0/0 (1 root-only skip), quorum_guard 85/0,
  network_hits 59/0. check-network-hits clean after S4.

## Open issues

- update-node.sh and edit-config.sh header comments (not this package's files) say the margin
  is "five minutes on testnet; derived from the epoch length elsewhere, up to 15 minutes", which
  reads as if mainnet differed. Suggested text: "(five minutes for the 6-hour epochs of mainnet
  and testnet; derived from the epoch length, up to 15 minutes)". Changing them moves their
  .sha256 sidecars (orchestrator regenerates).
- CHANGELOG/scripts-v2.1.0.md: the #49 entry stays in "Left open" worded as "nothing is left on
  it in this repository". If the user closes #49 with this release, the intro sentence "It closes
  #47." (not in this package's lines) could become "It closes #47 and #49." and the Left open
  entry go. Closing the GitHub issue is a user step.
- keytool_test.sh still pins 390 for its mainnet and testnet blind waits (kept unchanged as
  required). A future change of a constant has to update those expectations together with
  restart_window_test.sh.
