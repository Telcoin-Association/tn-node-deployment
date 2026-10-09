status: done
agent: V-DOC-P (read-only docs sub-verifier: docs/partner/mno-node-guide.md + docs/partner/metadata.yaml)

## Sections
- [x] S0 context: spec-fu-shared.md verified facts/endpoints, fu-docs-notes.md
- [x] S1 ## Introduction (L3-93) -- clean
- [x] S2 ## Before you start (L94-205) -- clean (HW tiers lib/common.sh:50-53 + _tn_hw_role text; systemd msg setup-node.sh:304; CVE check lib/common.sh:313-352; 43174 + 104.155.184.201/32 lib/common.sh:3074; firewall menu 1 firewall-setup.sh:1257; check-node resolve_network; prepare-stake exit 2 on chain mismatch :830; endpoints lib/common.sh:18-36)
- [x] S3 ## Install (L206-368) -- F1, F4
- [x] S4 ## Confirm the node is syncing, then synced (L369-442) -- clean
- [x] S5 ## Day-2 operations (L443-657) -- F2, N4 (L454)
- [x] S6 ## Public RPC (L658-777) -- F3 (L766)
- [x] S7 ## Validators: stake and activate (L778-1087) -- N1, N2, N3, N5
- [x] S8 ## Automation (L1088-1161) -- clean (JSON event types, run_json_mode order, rolled_back, firewall p2p_ports, remove-node slots, confirm/TN_ASSUME_YES)
- [x] S9 ## Troubleshooting (L1162-1239) -- every quoted message found in source; F3 (L1213)
- [x] S10 ## Getting help (L1240-1253) -- clean
- [x] S11 metadata.yaml -- version "1.0"->"1.1", date "1 October 2026"->"2 October 2026" (today 2026-10-02), no title: key. Clean.
- [x] S12 dry runs -- all three pass (see below)

## Dry runs (v0.15.0 debug build, throwaway datadir + HOME under scratchpad/vdoc/V-DOC-P)
1. keytool generate validator (TN_BLS_PASSPHRASE set), then the guide's line `telcoin-network -q --bls-passphrase-source no-passphrase keytool export-staking-args --node-info <dd>/node-info.yaml --calldata` with no passphrase env and no --datadir: rc 0, one stdout line, empty stderr, prefix 0x2fb0d025; the guide's `[ "${CALLDATA:0:10}" = "$(cast sig 'stake(bytes,(bytes))')" ] && echo "calldata OK"` prints calldata OK.
2. Stake-by-hand VERSION/STAKE snippet against https://rpc.adiri.tel: VERSION=0; stakeConfig prints 1e24 / 1e21 / 2.58e22 / 21600; STAKE=1000000000000000000000000, identical to the guide's `--value` example.
3. `cast call $REG "getCurrentEpochInfo()((address[],uint256,uint64,uint32,uint32,uint8))"`: decodes (5 committee addresses, issuance, block 497144, epoch 581, 21600, 0); matches EpochInfo in tn-contracts at v0.15.0.

## Findings
F1 warn guide L248 "BLS passphrase protection (not asked for Docker). This menu comes after the source build (20 to 40 minutes) or the Docker install and image pull." Self-contradictory: setup-node.sh step_preflight calls _select_passphrase_method only when INSTALL_METHOD != docker. Fix: "...comes after the source build (20 to 40 minutes), or after setup has found the binary for an existing install." (pre-existing line)
F2 warn guide L598-599 "checks the sudo whitelist ... with visudo before it changes anything ... If a step fails, the running UI, its helper and its whitelist stay as they were." ui/install-ui.sh step 6 renames the new helper over the live one before steps 7-10 (its step-11 comment: "Stopped after step 6: old sudoers, new helper"); steps 2-3 install Python/Flask and the user before the visudo check. README.md:961 scopes it correctly. Fix: "If Flask cannot be installed, a UI source file is missing, the helper does not parse or visudo rejects the whitelist, it stops before anything running changes. The whitelist goes in last; if a later step fails, run the installer again." Same text in OPERATOR.md:574-575.
F3 error guide L766 "names debug, trace, admin or all" and L1213 "The node serves debug, trace, admin or all methods". check-node.sh risky_api_modules returns 1 for a list starting with `all` and matches only debug/trace/admin (comment: v0.15.0 reads `all` as eth, net, web3, rpc). OPERATOR.md:723/1186 and README.md:633/1690 say debug, trace or admin. Fix: drop "or all"/", all" in both places.
F4 warn guide L694-697 "New install" block lists `setup-node.sh --rpc-domain "$DOMAIN"` and then `setup-node.sh --rpc-domain "$DOMAIN" --public-ip 203.0.113.10   # behind NAT` as consecutive lines of one copyable block; pasted whole it runs setup twice. Fix: two blocks, or prefix the second with "# or, behind NAT:". Same in OPERATOR.md:657-659. (pre-existing)
N1 note L829-837 exit table lacks the rotation success row (exit 0, `Rotated: node-info.yaml now names 0x....`, prepare-stake.sh ps_rotate).
N2 note exit-2 row: ps_export_calldata also exits 2 when keytool cannot export ("keytool could not export the stake() calldata from ... (exit N)"); "check the server's internet access" does not fit. Add "or keytool cannot export the calldata".
N3 note L875 "A cast send that reverts returns the same names." cast shows the selector, and the name only when it can decode it. Soften.
N4 note repo internals with no action for a partner: L454 "`lib/common.sh` and `lib/fallback.sh` are installed together or not at all." and L386 "(the script's `EVM_SYNC_THRESHOLD`)". Drop or say "the shared library files".
N5 note L800 "testnet and mainnet refuse it" (allow_private_forward_targets): it is edit-config.sh that refuses true on chains 2017/487 (set_private_forward_targets); the node reads the key on any release. Say "edit-config.sh refuses it on testnet and mainnet".

## Verdict
The partner guide is accurate against the scripts and the contracts. Every quoted message in the troubleshooting tables and the prose was found in source, the epoch arithmetic (E+1 active, E+3 earliest seat, 12-18 h), stake amount, ports, endpoints, chain IDs, menu numbers, version floors and exit codes match the code, and the three dry runs passed. One wrong fact (F3, `all` listed as a risky namespace in two places, which disagrees with check-node.sh, OPERATOR.md and README.md), two overclaims or contradictions (F1, F2), one copy-paste hazard (F4), and five notes. No maintainer-only paths, no `--worker-id`, no unreleased feature presented as available. metadata.yaml is correctly bumped (1.1, 2 October 2026, no title key).
