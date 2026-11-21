status: done

# FIX-A1 checkpoint (worktree /home/drtnarg/coding/telcoin/tnd-req-fix-a1, branch req/fix-a1)

Sections:
- [x] library helpers (MAINNET_CHAIN_CONFIGS_TAG, tn_chain_configs_tag, tn_chain_configs_dir, tn_chain_configs_from_tag)
- [x] ensure rewrite (_tn_chain_configs_clone, ensure_chain_configs_available)
- [x] tests (genesis_hash_test.sh 1-84)
- [x] git-wrapper sweep: 81 files, all exit 0; lib restored byte-identical; only genesis_hash_test.sh reaches ensure/the helpers (13 ensure, 17 from_tag, 2 clone calls, all on the stub); 0 blocked git calls; real git used only by addon_oldlib, cut_release, lib_skew, passphrase_print, perl_interp, release_keys, release_scripts, source_ref, updater_manifest, all against local paths
- [x] gates: suite host 81 files 0 failed (bash 5.3.9); ubuntu:26.04 81 files 0 failed; genesis_hash_test alone host 110/0/1skip, ubuntu:26.04 + bash:3.2 112/0/0; lints clean; tree 01664cc + diff sha256 4d89a2d0...
- [x] commit: 0b5f97b (lib/common.sh, tools/tests/genesis_hash_test.sh only)

Notes:
- read done: spec 0/1/2, project-context, AGENTS ownership + fixture tests, common.sh ranges.
- ensure: added _tn_chain_configs_consent (prompt) above _tn_chain_configs_clone; devnet clone failure now rc 2 too; mainnet without tag: no clone prompt.
- tests: genesis_hash_test.sh host 110 checks 0 fail 1 skip (non-root), 112/0/0 in ubuntu:26.04 and bash:3.2 (root); mutation run M1-M10 all caught; real-git private probe (scratchpad) 9/9.
- shellcheck: errors 0; warnings common.sh one fewer than HEAD (TESTNET_CHAIN_CONFIGS_TAG now used), test file same 5 as HEAD.
- lints on final tree: bash32 clean 211 files; network-hits clean 153 annotated; perl-interp clean 211; shellcheck errors 0. Suite host + ubuntu:26.04 running (scratchpad gates/).
