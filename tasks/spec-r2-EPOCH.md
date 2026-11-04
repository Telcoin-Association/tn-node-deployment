# Package EPOCH: per-network epoch constant and the blind wait (tn-node-deployment)

Read `tasks/spec-r2-shared.md` first. Worktree `~/coding/telcoin/tnd-r2-EPOCH`, branch
`r2/EPOCH`, checkpoint `tasks/ckpt-r2-EPOCH.md`. Size S. Owner of: the epoch constants and
`_tn_wait_blind`/`_tn_epoch_timing` call sites in `lib/common.sh`, `restart_window_test.sh`,
`keytool_test.sh` (values unchanged), the AGENTS.md sentences named below, `followup.md` lines
78-80, `CHANGELOG/scripts-v2.1.0.md` lines ~73 and ~399 (the #49 line). README/OPERATOR/partner
guide lines are Docs notes for DOCS-2.

## Decision

Mainnet epoch length is 21600 s (6 h), equal to upstream `MAINNET_EPOCH_DURATION_SECS` and to
adiri today. Margin and settle stay derived (300 s and 90 s for 21600 s). When a node's epoch
timing cannot be read, the blind wait derives margin and settle from the network's constant
instead of the fixed 300/90, so a future change of the constant moves the blind wait too.

## Today (verified 2026-11-04 at 9fd615a)

- `_tn_epoch_timing DUR` common.sh ~4538-4563: margin DUR/72 clamped 300-900, settle DUR/240
  clamped 90-300; `TN_EPOCH_MARGIN`/`TN_EPOCH_SETTLE` win (source "env"); DUR 0 → fixed 300/90
  (source "default"). `_tn_epoch_timing_text` follows it.
- `_tn_wait_blind FN MARGIN SETTLE CAP POLL WHY` ~4511-4529: waits MARGIN+SETTLE capped at
  CAP; its message names `TN_EPOCH_MARGIN + TN_EPOCH_SETTLE, at most TN_EPOCH_WAIT_MAX`.
- `tn_wait_restart_window` ~4588-4771 reads `epochDuration` from the node's RPC; when the
  timing is unreadable it calls `_tn_wait_blind` with margin/settle it computed from the env
  or the defaults. No per-network epoch constant exists anywhere in the library.
- Tests: `restart_window_test.sh:54-131`, `keytool_test.sh:113-171` (expects the 300/90
  values; must keep passing unchanged).
- Docs sentences: AGENTS.md ~180-197 (restarts and the epoch boundary), OPERATOR ~642-644 and
  ~1628-1636, README ~818-826, partner guide ~811-835, CHANGELOG/scripts-v2.1.0.md ~68-80 and
  ~399, followup.md ~78-80 (the open "mainnet epoch length and margin/settle" item).

## Sections (one commit each; checkpoint after each)

S1 **Constants.** `readonly MAINNET_EPOCH_DURATION="21600"` and `readonly
TESTNET_EPOCH_DURATION="21600"` beside the other network constants at the top of
`lib/common.sh` (devnet: `DEVNET_EPOCH_DURATION=""`, unknown, unless the devnet genesis in the
repository states one; say which). A resolver `tn_network_epoch_duration NETWORK` prints the
constant or nothing.

S2 **Blind wait derives from the constant.** When `tn_wait_restart_window` falls back to the
blind wait, margin and settle come from `_tn_epoch_timing "$(tn_network_epoch_duration
"$NETWORK")"` (env overrides still win, as `_tn_epoch_timing` does), and the message says where
they came from: "(network default: epoch 21600 s)" / "(TN_EPOCH_MARGIN, TN_EPOCH_SETTLE)" /
"(default)" when the network has no constant. Values today are unchanged (300 + 90). Do not
change the live path (epochDuration read from RPC) except to share the timing text.

S3 **Tests.** `restart_window_test.sh`: "mainnet blind wait derives from the 6 h constant"
(21600 → 300/90, message names the network default), "devnet blind wait keeps the fixed
default", "env margin wins over the constant", plus a mutation note in the checkpoint showing
the new check fails when the constant is 36000 (margin 500). `keytool_test.sh:155-168`
unchanged values stay green. Green under bash 5.3 and `bash:3.2`.

S4 **Docs you own.** AGENTS.md ~182 and ~190-191 (name the constants and the derived blind
wait), `CHANGELOG/scripts-v2.1.0.md` ~73 and the #49 line ~399 ("mainnet epoch 6 h confirmed,
margins derived"), `followup.md` ~78-80 (close the item). List for DOCS-2: OPERATOR ~644,
README ~826, partner guide ~816 with the replacement sentence.
