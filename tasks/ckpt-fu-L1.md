status: done

# Checkpoint: package L1 (lib/common.sh 1.5.0, lib/fallback.sh 1.0.3)

Owned files: `lib/common.sh`, `lib/fallback.sh`. Tests live in the scratchpad under
`l1-tests/` (`t_l1.sh` plus the `shims/curl` fake). No other repo file was edited.

## Sections

- [x] 1. Constants and `confirm()` (`tr`), `TN_OPERATOR_GUIDE_URL`, `MIN_SOURCE_VERSION_TESTNET` 0.13.0, `MAINNET_CHAIN_ID` 487, endpoint and explorer constants (header comment no longer lists tn_resolve_node_type)
- [x] 2. `meta_set` hardening and new `meta_unset` (refusal and no-meta warnings on stderr; a new file is created under umask 077)
- [x] 3. `validate_rpc_url`, `rpc_url_is_private`, `tn_ref_min_check`, `tn_genesis_chain_id`, `tn_is_public_chain_id` (new section after validate_docker_image; internal helpers `_tn_ipv4_strict`, `_tn_ipv6_strict`, `_tn_url_split`, `_tn_host_ok`, `_tn_ipv4_is_private`, `_tn_ipv6_is_private`)
- [x] 4. JSON-RPC family: `tn_rpc_call`, `tn_json_field`, `tn_local_rpc_url`, `tn_node_mode`, `tn_epoch_info`, `tn_epoch_secs_left`, `tn_wait_restart_window` (new section before the stake section; helpers `_tn_uint`, `_tn_now`, `_tn_curl_reason`, `_tn_json_uint`, `_tn_env_uint`, `_tn_fmt_secs`, `_tn_due_text`, `_tn_wait_say`; public `tn_hex_to_dec`, `tn_wei_to_tel`)
- [x] 5. Stake status: `node_stake_status`, `print_validator_onchain_status`, `check_validator_onchain_status`, `display_node_info` (plus `_tn_word_fits`, public `tn_stake_amount_wei [url] [max_time]`, constants `GET_CURRENT_STAKE_VERSION_SELECTOR`, `STAKE_CONFIG_SELECTOR`; caller audit done)
- [x] 6. `tn_acquire_update_lock` mkdir fallback honours `TN_EXIT_TRAP_OWNED` (adds `TN_UPDATE_LOCK_DIR` and `tn_release_update_lock`; flock path unchanged)
- [x] 7. `lib/fallback.sh` comment refresh, `tn_resolve_node_type` deprecation, `FALLBACK_VERSION` 1.0.3
- [x] 8. Tests (B.5 L1 bullet): 440/440 under /bin/bash 3.2 and bash 5, live included
- [x] 9. Final checkpoint with closing headings

## Operator-visible changes

- The testnet RPC used by the scripts is now `https://rpc.adiri.tel` and the explorer
  `https://telscan.io` (mainnet explorer too); `scan.telcoin.network` is gone. The mainnet
  menu entry shows chain id 487.
- The source-build picker and the new `tn_ref_min_check` treat v0.13.0-adiri as the oldest
  testnet release (was 0.12.0). Callers that adopt `tn_ref_min_check` refuse older tags with
  a message that says why.
- `confirm` prompts work under macOS `/bin/bash` 3.2 (they used to die on `${response,,}`).
- After key generation, Step 3 of the staking steps shows the live stake amount
  ("Required stake: 1,000,000 TEL (... wei, stake version 0)"), Step 5 fills in `--value`,
  and the steps end with a pointer to `sudo bash prepare-stake.sh`. If the amount cannot be
  read, the cast commands for `getCurrentStakeVersion()` and `stakeConfig(uint8)` are shown
  instead of the old `getCurrentStakeConfig()` one.
- The on-chain status report says why a read failed, with one hint each for no answer, HTTP
  429 rate limiting and an undecodable answer (it used to say "Empty response from contract"
  for all of them). An Exited validator now reads "exited at epoch E; unstake() becomes
  eligible at epoch E+1" plus whether that is now.
- New (not yet wired by callers): the epoch-boundary wait before restarting a committee
  node, with `TN_SKIP_EPOCH_WAIT`, `TN_EPOCH_MARGIN`, `TN_EPOCH_SETTLE`,
  `TN_EPOCH_WAIT_MAX` and `TN_EPOCH_POLL`.

## Changelog text

### lib/common.sh v1.5.0 — RPC helpers, epoch-boundary wait, strict stake decode

The testnet RPC constant is now `https://rpc.adiri.tel`, the explorers are
`https://telscan.io`, `MAINNET_CHAIN_ID` is 487, and `TN_OPERATOR_GUIDE_URL` points at the
operator runbook. The oldest supported testnet release is v0.13.0-adiri, the first with
`keytool set-rpc`, proof-of-possession signing and state export. `confirm` lowercases with
`tr`, so it runs under macOS `/bin/bash` 3.2. `meta_set` refuses a malformed key or a value
with a line break, and the new `meta_unset` removes a key. New helpers: `validate_rpc_url`
and `rpc_url_is_private` for operator-supplied URLs; `tn_ref_min_check` for release refs and
image tags; `tn_genesis_chain_id` and `tn_is_public_chain_id`; a JSON-RPC family
(`tn_rpc_call`, `tn_json_field`, `tn_local_rpc_url`, `tn_node_mode`, `tn_epoch_info`,
`tn_epoch_secs_left`) whose failures say what went wrong (transport, http, rpc-error,
malformed); `tn_wait_restart_window`, which holds a committee node's restart until the
current epoch has closed and settled, never longer than `TN_EPOCH_WAIT_MAX`; and
`tn_hex_to_dec`, `tn_wei_to_tel` and `tn_stake_amount_wei` for 256-bit amounts without
python3. `node_stake_status` decodes `getValidator` strictly and adds the exit epoch as a
fourth field; failures now carry their reason. The status report gives a hint per failure
kind and tells an exited validator when `unstake()` becomes eligible. The staking steps
after key generation show the live stake amount and point to `prepare-stake.sh`. A caller
that owns its EXIT trap can set `TN_EXIT_TRAP_OWNED` before `tn_acquire_update_lock` and
release the lock with `tn_release_update_lock`.

### lib/fallback.sh v1.0.3 — role comments, tn_resolve_node_type deprecated

Comments now say the validator view comes from the on-chain stake status (`getValidator`,
via `node_stake_status`), not from `tn_isValidator` or `NODE_TYPE`.
`tn_resolve_node_type` is deprecated: nothing in `lib/` calls it, and it stays for one more
release so a box with this library and older scripts keeps working.

## Tests run

Harness: `<scratchpad>/l1-tests/t_l1.sh` sources `lib/common.sh` at top level (TN_ROOT_PREFIX
temp tree), turns errexit off and keeps nounset and pipefail. JSON-RPC answers come from the
`shims/curl` PATH shim (per-method body, HTTP code or curl exit); the wait tests replace
`_tn_now`, `sleep`, `tn_node_mode`, `tn_epoch_secs_left` and `tn_epoch_info` in subshells.

- `/bin/bash t_l1.sh` (3.2.57): 440 passed, 0 failed. `bash t_l1.sh` (5.3.15): 440 passed, 0 failed.
  Coverage: constants; `confirm` with y, Y, yes, YES, Yes, " y" (read trims it), n, N, no,
  empty, x, ny, EOF, a pipe, TN_ASSUME_YES, inside `if` under `set -e`; `meta_set`/`meta_unset`
  round trips, upsert, nine refused keys, LF and CR refusals with the file byte-identical,
  stderr-only warnings, mode 600 kept and restored from 644, duplicate-line removal, prefix
  key kept, absent key/file rc 0, default path via node_meta_path, `set -e` safety;
  `tn_local_rpc_url` (meta port, RPC_PORT, default); 43 `validate_rpc_url` rows plus tab and
  newline; 32 `rpc_url_is_private` rows; a 20-row `tn_ref_min_check` matrix (v0.11/v0.12
  refused, v0.13/v0.15 allowed, main and a SHA rc 2, image `…/adiri:v0.12.0-adiri` refused,
  `…:v0.15.0-adiri` allowed, registry-port and digest refs rc 2, no floor on devnet and
  mainnet) with message checks; chain id from YAML, JSON hex, snake case, the real testnet
  and mainnet genesis files, and the public-id set; `tn_hex_to_dec` against python3 and max
  uint256, `tn_wei_to_tel` formats; `tn_rpc_call` transport (connect, timeout, dns, tls),
  HTTP 500, HTTP 429 ahead of an error body, error object, revert, missing result, empty
  body, non-JSON, multi-line success folded to one line, `"error":null`, null result, bad
  method, max-time pass-through and fallback, params, `set -e` capture; `tn_json_field`
  cases; `tn_node_mode`, `tn_epoch_info` (case folding, empty committee, hex height,
  decimal epoch param, bad epoch, out-of-range revert, missing fields),
  `tn_epoch_secs_left` (block blockHeight-1 requested, positive and negative secs, null
  block, HTTP error); `node_stake_status` with the real 7-word committee payload
  (`3 0 0 0`), exited, pending exit, retired, high bits in words 0, 1, 3 and 6, retired=2,
  status 7, six and eight words, empty and non-hex result, the 0xed15e6cf revert (`none`),
  revert by message, HTTP 429 (rc 2 `unknown http 429`), other RPC error, transport, bad
  address; `node_is_staked_validator` rc 0/1/2; old-reader compatibility; stake amount and
  calldata; unstake wording at the exit epoch (not yet), one after and well after (now),
  without a current epoch, three-field line; check_validator hints for transport, 429,
  malformed, other, the exited path reading the current epoch, one call when active;
  display_node_info with the live amount, the fallback text and no RPC_URL; update lock
  with TN_EXIT_TRAP_OWNED (caller trap kept, release works), default trap, stale takeover,
  live holder refused; fallback deprecation; `tn_wait_restart_window` with a fake clock:
  skip, RPC down (scripted and through the real `tn_node_mode` + curl shim), Observer,
  CvvInactive, far boundary, unreadable secs, near boundary then rollover (t=210 = 120 wait
  + 90 settle, 8 heartbeats, one step, max gap 15 s), boundary already passed, cap 200
  (exact), default cap 1800, settle trimmed by the cap, rollover at the cap, two failed
  reads, one failure then recovery, poll clamps 30 and 5, margin env, settle 0, a frozen
  clock (ends after 4 naps), bare call under `set -e`, a failing progress fn under
  `set -e`, an undefined progress fn, default printer on stderr. rc 0 every time; every
  heartbeat gap at most 30 s.
- Live read-only against `https://rpc.adiri.tel` (inside the same runs): `tn_node_mode` →
  CvvActive; `tn_epoch_info` → epoch 580, duration 21600, five-member CSV; epoch 579 by
  number; `tn_epoch_secs_left` → about 5300 s (0 < s ≤ 21600); `node_stake_status
  0x0033a370616805b1fd275b7ffab83fc41d665ccb` → `3 0 0 0`; the dead address → `none`; the
  live getValidator payload equals the test fixture; `tn_stake_amount_wei` → `1e24 0`.
- `/bin/bash -n` and `bash -n` on both files: clean.
- `shellcheck -x --severity=error lib/common.sh lib/fallback.sh`: clean. At warning level
  14 findings, down from 16 on HEAD; the one new finding is SC2034 for the exported
  constant `TN_OPERATOR_GUIDE_URL`.
- Grep for bash-4 constructs in both files: none, comments included.
- Name-collision grep for every new function and variable across `*.sh`, `*.py`, `*.env`:
  none outside `lib/common.sh`. `/bin/bash check-node.sh --help` still sources and runs.

## Open issues

1. Sidecars and release bookkeeping (orchestrator): `lib/common.sh.sha256` and
   `lib/fallback.sh.sha256` are stale until `tools/gen-checksums.sh` runs; README changelog
   entries above; `update-scripts.sh` bump in the release commit.
2. `tn_resolve_node_type` callers still in scripts (owned by other packages):
   `firewall-setup.sh` (two calls: the status header line and the JSON `nodetype` field;
   package C.3) and `migrate-node-naming.sh` (one call, the `nt=` line in the report;
   package P3). `ui/server.py` mentions it only in a docstring (UI package).
3. Callers that should adopt new library behaviour (no caller breaks without these):
   - check-node.sh (package B): pass the current epoch so an Exited validator gets the
     "is that now" answer: `print_validator_onchain_status "$VALIDATOR_ADDRESS"
     "$ONCHAIN_STAKE_LINE" "" "$CURRENT_EPOCH"` (the third argument stays "" so the line's
     retired flag is used). Its rc-2 branch can show `${ONCHAIN_STAKE_LINE#unknown }` as the
     reason. `${line%% *}` already works with the four-field line.
   - update-node.sh (P6): if it sets its own EXIT trap before `tn_acquire_update_lock`, it
     must set `TN_EXIT_TRAP_OWNED=1` first and call `tn_release_update_lock` from that trap.
     Without the call the next run still recovers through the stale-PID takeover.
   - Any JSON-mode caller of `tn_wait_restart_window` should pass a progress function; the
     default printer writes to stderr, so stdout stays clean either way.
4. Interface notes for later packages: RPC helpers return rc 1 for every failure kind (the
   kind is on stdout); `node_stake_status` keeps rc 1 for a bad address and rc 2 for
   unreadable. `tn_stake_amount_wei` prints `<wei> <version>`; format with `tn_wei_to_tel`.
   prepare-stake (C.4) can use these instead of python3. A bad argument to an RPC helper
   reports kind `malformed` (`malformed bad-epoch`, `malformed bad-method`), since the spec
   allows only four kinds.
5. Design choice to review: `tn_wait_restart_window` follows the spec policy exactly, so a
   committee node whose epoch never closes (stuck or far behind) waits the full
   `TN_EPOCH_WAIT_MAX` (30 min default) before the restart goes ahead. A possible
   refinement is to stop waiting when the boundary passed more than the margin ago; not
   implemented because the spec does not ask for it.
6. `node_stake_status` now rejects a status above 6 as malformed (rc 2) instead of
   reporting "Unknown (status code: N)". update-node treats rc 2 as "unknown, warn", which
   is the safe side.
