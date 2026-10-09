status: done

# V-L verifier checkpoint (lib/common.sh 1.6.0 at d1593ae, lib/fallback.sh 1.0.3)

Harness: <scratchpad>/vl-tests/ (t_l1a URL/meta/ref/genesis, t_l1b RPC/JSON/epoch, t_l1c wait
policy on a fake clock, t_l1d stake/status/lock, t_l2a launch-file family, t_l2b cores/hardware/
keytool/probes/node-info, t_sete plain calls under set -e, t_live live read-only; shims/ for curl
and docker, shims-cpu*/ for lscpu/sysctl/nproc/getconf; fx/ fixtures incl. the four wrappers
rendered from setup-node.sh's heredocs).

## Sections
- [x] 0. Read specs (shared, core B.1/B.2/B.3/B.5, lessons)
- [x] 1. Read lib/common.sh + lib/fallback.sh (all new/changed functions; diff vs 1e2d2f1^)
- [x] 2. L1 functions: t_l1a 248/248, t_l1b 105/106, t_l1c 52/52, t_l1d 148/148
- [x] 3. L2 functions: t_l2a 407/407, t_l2b 161/165 (4 = my expectation, keytool normalises URLs),
      t_sete 53/53. All parts: /bin/bash 3.2 and bash 5.3, VL_SETE 0 and 1, and again with mawk
      1.3.4 as awk: identical results. Exit checks reached in every part.
- [x] 4. Live read-only vs rpc.adiri.tel, all equal to cast (see Tests run)
- [x] 5. Static + caller audit
- [x] 6. Cross-check implementers' tests
- [x] 7. Prose review
- [x] 8. Report

## Tests run

- Static: `/bin/bash -n` and `bash -n` on both files OK; `shellcheck -x --severity=error` clean;
  `/bin/bash tools/check-bash32.sh lib/common.sh lib/fallback.sh` clean (rc 0); no shell `exit`
  in any new or changed function (only awk exits, comments, strings).
- Live: mode CvvActive; epoch 580 h497019 d21600 v0 five-member committee; epoch 579 OK; 583 ->
  `rpc-error 3 execution reverted`; secs_left 528 with boundary 1790908319 = `cast block 497018`
  timestamp + 21600; `node_stake_status 0x0033…5ccb` -> `3 0 0 0` (cast: `(…, 0, 0, 3, false, 0,
  0)`); 0x…dead -> `none` (cast: revert 0xed15e6cf…); `tn_stake_amount_wei` -> `1e24 0` ->
  `1,000,000`.
- Cross-check: `l1-tests/t_l1.as-1.6.0.sh --no-live` 427/427 under both bashes.
  `l2-tests/t_l2.sh` 485/498 under both: the 13 failures come from the test eval'ing
  caddy_launch_inject_target/verify_inject out of the working-tree install-caddy.sh, which the
  in-progress C.1 work deleted; with HEAD's install-caddy.sh it is 498/498 under both.

## Report

1. error - tn_launch_flag_set / tn_node_inject_flags (parser tok() in _tn_launch_awk). Unquoted
   shell metacharacters inside a "word" pass: `tn_launch_flag_set W --log.file.name 'x>/p/victim'`
   -> rc 0, get returns `x>/p/victim`; starting the wrapper truncated /p/victim to 0 bytes and
   docker received `--log.file.name x`. Same for `a;b`, `a|b`, `a&b`, `a<b`, `*`;
   `tn_node_inject_flags W --z '--z 1&'` -> rc 0 -> `exec … --z 1&` backgrounds the node. Expected
   rc 3 ("not a single word"). `(`/`)` are caught only by bash -n. Fix: in tok() end the word and
   set tk_bad on unquoted ; | & < > ( ), and refuse unquoted * ? [ in VALUE and FLAGS.
2. warn - tn_wait_restart_window: heartbeat gap = poll + epoch-read time; TN_EPOCH_POLL=30 with
   10 s reads -> 40 s gaps (bound 30 s); default poll 15 -> 25 s. Fix: clamp poll to 5..20 or give
   the in-loop read max-time 30-poll.
3. warn - tn_json_field '{"s":"x\"y"}' s -> `x\` (doc: escaped quotes kept, so `x\"y`). Fix:
   `"(([^"\\]|\\.)*)"` as in tn_rpc_call's msg_re.
4. warn - display_node_info Step 4 prints `<bin> keytool export-staking-args --node-info F
   --calldata` (and the docker form); both real binaries exit 1 "passphrase is required" when
   TN_BLS_PASSPHRASE is unset. Verified fix: add `--bls-passphrase-source no-passphrase` (and -q).
5. warn - fallback.sh tn_resolve_node_type: "no callers left in lib/. Delete it after the next
   release." firewall-setup.sh still calls it twice; deleting on that schedule breaks it unless C.3
   lands first. Fix: name the remaining caller; delete after it is gone.
6. note - node_stake_status comment: words 5-6 "isDelegated and stakeVersion on the deployed
   testnet registry" is unverified; the pinned source (tn-contracts 10cc12b7) is stakeVersion,
   region. Name those two.
7. note - coordinator's status-6 correction vs source: `_retire()` does `_setStatus(…, Any)` and
   `isRetired = true`; getValidator returns retired records without the NFT check. `6 … 1 …` is
   the stored retired tombstone; current code decodes it, node_is_staked_validator -> 1, report
   "Status: Retired". Keep it. Status 6 with isRetired 0 (never written) prints "Any (reserved
   status sentinel)"; optionally make that malformed. Other coordinator rows pass.
8. note - tn_rpc_call: URL is a bare curl arg; "-o/path" became a curl option. Use --url.
9. note - tn_rpc_call: error without message -> "rpc-error 3 " (trailing space).
10. note - tn_ref_min_check: v0.13.0-rc1 -> rc 0; "" -> rc 2 "(empty ref) … Make sure it is
    v0.13.0 or newer"; network ""/unknown -> rc 0 silently.
11. note - tn_keytool: --datadir in ARGS is not hoisted; ARGS `--datadir D set-rpc --clear` ->
    keytool rc 2 (subcommand conflict); `set-rpc --clear --datadir D` works.
12. note - tn_keytool with TN_BLS_PASSPHRASE set but empty: passes -e TN_BLS_PASSPHRASE and adds
    the no-passphrase source for export (works); generate/pop get the empty value.
13. note - keytool set-rpc normalises URLs (`https://h` -> `https://h/`); tn_node_info_rpc returns
    the slash form. Callers comparing must normalise (in-progress install-caddy passes `https://d/`).
14. note - tn_node_parse_check cannot check clap `requires`: --state-export-keep 3 alone -> rc 0.
15. note - misc: _tn_hw_role drops "could not check CPU" when RAM/disk is short;
    TN_EPOCH_WAIT_MAX=0 says "Waiting at most 0s" then warns; tn_genesis_chain_id rc 1 on one-line
    JSON (real genesis files are YAML); check_validator_onchain_status words http 503 as "The RPC
    refused the call. Check the URL".
16. note - callers at HEAD (other packages): no call site breaks with the new formats. Wording:
    setup-observability (2 sites) and lib/observability say "already has / launch line not found"
    for rc 2-4; install-caddy HEAD says "no --http launch line found" for rc 3/4;
    migrate-node-naming defines its own sed-based meta_set that shadows the library one.

Verdict: the library meets the B.2/B.3 contracts on almost every row; one error (finding 1, shell
metacharacters accepted as one word, which can corrupt a root-run wrapper) should be fixed before
callers pass values they do not validate; warns 2-5 are cheap fixes.
