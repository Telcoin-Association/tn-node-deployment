status: done

# FIXR-SEAM checkpoint (worktree tnd-req-fixr-seam, base adf7ee0, commit d15a70c)

Sections (done marked [x]):
- [x] 1 VR-1 code: menu clone block uses -e, then _tn_chain_configs_dest_ok + _tn_chain_configs_clone_target (edit_wait_say) before the clone question; refusal = library warning + rc-mapped error, no lock; -e also in the clone's re-test and the mainnet/devnet branches; require list + tn_chain_config_pin, dest_ok, clone_target, in_place
- [x] 2 VR-2 code: was_in_place = content check && _tn_chain_configs_in_place before the helper; baseline unless was_in_place
- [x] 3 VR-3 code: rc 2 neutral line; hint only if ! -e .git && content check fails
- [x] 4 VR-4: _tn_rpc_chain_is in caddy_require_lib
- [x] 5 VR-5: genesis_hash_test 311 uses ${GIT_FETCH_ERR:0:200}; tag test OFFWHY (cut) at lines 514-518, used by 3 checks. Verified: HEAD fails 4 under long TMPDIR, mine passes long+short, mutated lib (no reason) fails them.
- [x] 6 genesis_hash_test.sh header
- [x] T refresh test: 171 checks 0 fail on host; same under umask 022/002/077; vs adf7ee0 edit-config: 26 FAIL (every new case fails except the in-place guard, which cannot)
- [x] G gates: reviewer harness (unedited: exit 1 after its 4th check, no summary, because apply_changes' set -e ends it at case 2's first FAIL; copy with set +e after cases 2/3: "14 checks, 7 failures, 0 skipped", cases 2,3,5 FAIL, case 4 ok); the 9 named files pass on host, ubuntu (git 2.53) and bash3.2; whole suite 84/0 on host and ubuntu; bash32, network-hits, perl-interp clean; shellcheck 0 errors, warnings same as HEAD
- [x] C commit d15a70c

Notes:
- chain_configs_tag_test.sh: OFFLINE (line 514) is the expected text of checks 518/525; I edited that definition line (flagged in the hand-back).
- Scratch: /var/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/46275ae3-5cf9-4f35-b799-c09950443243/scratchpad/fixr-seam/
