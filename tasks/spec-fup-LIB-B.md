# LIB-B: epoch timing derivation and network-keyed endpoints (issues #49, #47, #33)

Read `tasks/spec-fup-shared.md` first. Worktree `~/coding/telcoin/tnd-fup-LIB-B`, branch
`fup/LIB-B`, checkpoint `tasks/ckpt-fup-LIB-B.md`.

## Goal

The restart window's defaults follow the network's epoch length instead of testnet's 6 h,
the cap can never be shorter than the wait it bounds, and the three remaining adiri
endpoint hits on mainnet paths are keyed by network and fail closed.

## Owned files

`lib/common.sh` (only `tn_wait_restart_window` and the helpers it calls for the derivation,
`check_internet`), `check-node.sh` (`resolve_network` / `network_rpc_url` only),
`setup-node.sh` (`_setup_image_example` only), tests `tools/tests/restart_window_test.sh`,
`tools/tests/keytool_test.sh`, `tools/tests/check_node_unit_test.sh`,
`tools/tests/check_node_hardening_test.sh`, `tools/tests/network_detect_test.sh` (its own
cases only; LIB-A adds cases to the same file: append under a `# LIB-B` comment block at the
end so the cherry-picks do not collide). LIB-A edits `select_network` and the digest arm of
`tn_docker_resolve_ref`; AUDIT adds `tn_host_baseline_*`; REL adds a release report to
check-node. Touch nothing near those.

## Facts (main 1187ddb)

- `tn_wait_restart_window URL FN` lib/common.sh:4456. Defaults at :4465-4470:
  `margin=$(_tn_env_uint TN_EPOCH_MARGIN 300)`, `settle … TN_EPOCH_SETTLE 90`,
  `cap … TN_EPOCH_WAIT_MAX 1800`, `poll … TN_EPOCH_POLL 15` clamped 5-20. The epoch info is
  read later (`epochDuration` via `_tn_json_uint` :4217, boundary at :4236+); the blind wait
  is margin + settle capped. Contract comment :4355-4390 (update it). AGENTS.md "Restarts
  and the epoch boundary" and README/OPERATOR describe the 300/90/1800 defaults (DOCS
  updates them from your notes).
- `keytool_test.sh:171` pins: a `CvvActive` node whose epoch info cannot be read continues
  without a wait ("wait: mode read, epoch unreadable: continues without a blind wait" = 0).
  That stays (decision 7).
- adiri `epochDuration` = 21600 s. Derivation (decision 7): margin = clamp(epochDuration/72,
  300, 900), settle = clamp(epochDuration/240, 90, 300). 21600/72 = 300, 21600/240 = 90, so
  testnet behaviour is unchanged; a 7-day epoch (604800 s) gives 900 and 300. The node team's
  final mainnet values replace the shares later (DOCS records that).
- `check_internet` :2341 curls `$TESTNET_RPC_URL` then `https://1.1.1.1` on every network.
- check-node.sh `network_rpc_url` :318, `resolve_network` :340; :369-370
  `NETWORK_RPC="${NETWORK_RPC:-$TESTNET_RPC_URL}"` falls back to adiri when the network is
  unknown; `--network-rpc` :183 overrides; `check_network_chain` :1256 compares chain ids and
  already warns when the comparison endpoint serves another chain.
- setup-node.sh `_setup_image_example` :577 prints `DEFAULT_DOCKER_IMAGE` (an adiri image by
  digest) on every network but devnet; callers :921, :974, :3025 use it in messages.
  `tn_docker_repo_for mainnet` prints the ghcr repository.
- #33: the post-update check ends "late" (`ok:true`, `"voting":false`) on a header or vote
  timeout after an apply, with no rollback; `TN_UPDATE_VOTE_ROLLBACK=1` exists (grep
  update-node.sh). No code change: your checkpoint hands DOCS the exact names, defaults and
  the late-case wording for the partner guide (one paragraph), verified against the code.

## Required behaviour

1. Derivation: when `TN_EPOCH_MARGIN` is unset or empty, margin is derived from the epoch
   length once it is known (the first successful `tn_getCurrentEpochInfo` read, local or
   public RPC); same for settle. An explicit environment value wins and is never clamped.
   Before the epoch length is known (the blind-wait path), the fixed 300/90 apply as today.
   Say in the log line which values are in effect and where they came from ("derived from a
   21600 s epoch" / "TN_EPOCH_MARGIN").
2. Cap check: after margin, settle and poll are final, if `cap` is not 0 and
   `cap < margin + settle + 2*poll`, raise it to that sum and warn through `$fn` ("TN_EPOCH_WAIT_MAX
   N is shorter than the wait it bounds (margin M + settle S + two polls); using X"). The
   default cap 1800 already covers the derived maximum 900 + 300 + 40.
3. `check_internet`: probe the node's own network RPC by `case "$NETWORK"` (testnet
   `$TESTNET_RPC_URL`, mainnet `$MAINNET_RPC_URL`, devnet `$DEVNET_RPC_URL`), then
   `https://1.1.1.1`; an empty or unknown `NETWORK` fails closed with a message that names the
   variable (callers set NETWORK before preflight; verify with grep and say so in the
   checkpoint if one does not).
4. check-node: `NETWORK_RPC` is the network's own RPC; when the network is unknown and no
   `--network-rpc` was given, the chain comparison is skipped with a note ("network unknown;
   give --network-rpc URL to compare") instead of comparing against adiri. The report line
   that prints the comparison endpoint says which network it belongs to.
5. `_setup_image_example`: mainnet arm prints `$(tn_docker_repo_for mainnet)@sha256:<digest>`
   (no testnet image appears in a mainnet message); testnet and devnet unchanged.

## Tests

- `restart_window_test.sh`: stub RPC returning `epochDuration` 604800 with the boundary far
  away → no wait, log says margin 900 / settle 300 derived; boundary inside 900 s → waits;
  `TN_EPOCH_MARGIN=120` wins over the derivation; `TN_EPOCH_WAIT_MAX=100` with the derived
  values is raised with the warning text; 21600 gives 300/90 (unchanged); `TN_EPOCH_WAIT_MAX=0`
  still turns the wait off without a warning.
- `keytool_test.sh`: existing cases pass unchanged (including :171).
- `network_detect_test.sh` (LIB-B block): `check_internet` with a recording `curl` stub probes
  the mainnet URL first when `NETWORK=mainnet`, the devnet URL on devnet, and fails closed with
  `NETWORK` empty (rc 1, message) without calling curl.
- `check_node_unit_test.sh` or `check_node_hardening_test.sh` (whichever already drives
  `resolve_network`): unknown network → `NETWORK_RPC` empty and the skip note; mainnet →
  `https://rpc.telcoin.network`; `--network-rpc` wins.
- `_setup_image_example` on mainnet contains `ghcr.io` and not `adiri` (a case in
  `network_detect_test.sh` or the setup fixture that already sources setup-node, your choice).

Run every touched fixture under bash 5.3 and `bash:3.2`; `bash -n` both; `check-bash32`;
shellcheck 0.9 + 0.11 `--severity=error`.

## Docs notes to hand over

The derivation formula and the clamps, the cap rule and its warning, the unchanged testnet
numbers, "the node team's mainnet values replace the shares"; the check_internet and
check-node changes; the #33 late-case paragraph with `TN_UPDATE_VOTE_ROLLBACK` semantics.
