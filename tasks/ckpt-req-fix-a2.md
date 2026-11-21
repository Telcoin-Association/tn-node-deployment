status: done

# FIX-A2 checkpoint (setup-node.sh side of the pinned chain configs)

Worktree: /home/drtnarg/coding/telcoin/tnd-req-fix-a2 (branch req/fix-a2, base 0b5f97b)

## Sections
- [x] require list (setup-node.sh ~211-212: three helpers added on a new continuation line)
- [x] ensure call (step_create_infrastructure ~2142: cc_rc capture, case 0/1/*)
- [x] step_write_config (pinned dir second, only when the network has a tag; hint tree/${tag:-main})
- [x] tests (genesis_hash_test.sh: 25 new checks after the cwd case; swc = step_write_config with checkout entries under TN_ROOT_PREFIX; host 135/0/1skip, ubuntu:26.04 137/0, bash:3.2 137/0; 3 mutations caught)
- [x] other mentions (help :60-64 release chain-config hashes true; :72 allow-dirty true; :696-703 source checkout true; :816-821 release stage true; :3296-3298 TN_GENESIS_DIR comment true but only names step_write_config; :3332-3334 run_streamed "git clone" stale-ish; no tree/main left; no TN_SOURCE_DIR/chain-configs except the search entry)
- [x] phases and skew (scratch runs: keygen ensure in one env -i process, finalize step_write_config in another finds pinned dir; new sn + 01664cc lib refused both modes; old sn + new lib: fresh OK via tag clone, diverged checkout refused fail-safe)
- [x] gates (all green on d3fdb5e tree: suite host 81 files 0 failed, ubuntu:26.04 81 files 0 failed; genesis_hash host 135/0/1skip, u26.04 137/0, bash3.2 137/0; lints clean)

## Notes
- Decision: pinned dir only when tn_chain_configs_tag is non-empty (devnet and untagged mainnet keep todays order, which is what ensure checked). Report as a deviation.

## Commit
- d3fdb5e FIX-A2: setup reads the pinned chain-config directory (setup-node.sh, tools/tests/genesis_hash_test.sh)
