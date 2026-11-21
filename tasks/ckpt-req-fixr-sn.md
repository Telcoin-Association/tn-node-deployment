status: done

# FIXR-SN checkpoint

Worktree /home/drtnarg/coding/telcoin/tnd-req-fixr-sn, branch req/fixr-sn, base 1a3404b. Commit 0d137d2.

## Sections
- [x] 0. Read: spec 0/2.2/6, V-FIX-S-02/-11/-12, setup-node.sh call sites, lib helpers
- [x] 1. V-FIX-S-02 rc-1 wording: "The ${NETWORK} chain configs were refused (see above); nothing was copied." (+2 comment lines above the call). JSON order driven: cause before error for symlink, owner (root), mismatch, --genesis-dir, mainnet, rc-2 fetch. Gap: failed clone (rc 2) cause never in JSON (library _tn_chain_configs_clone, V-FIX-S-01).
- [x] 2. V-FIX-S-11: candidates array -> search_paths deduped (first occurrence kept, continue 2), bash 3.2 safe
- [x] 3. V-FIX-S-12: TN_GENESIS_DIR comment names ensure (as given, no git, no prompt) and step_write_config
- [x] 4. update-node.sh update_lock comment: fetch of origin's tags for --check, tee, docker pull, systemctl stop; library: tag fetch+checkout, cargo build, epoch wait, submodule sync; "No git pull runs here."
- [x] 5. hint rewritten (4 info lines; names chain-configs/<net>/ at <tag>, raw files readable by SERVICE_USER, --genesis-dir <dir>)
- [x] 6. tests: genesis_hash_test host 150/0/2 skip, ubuntu 154/0/0, bash:3.2 154/0/0. Base copy (scratchpad/fixr-sn-base-1): host 13 FAIL, ubuntu 15 FAIL; rc-2 pair passes at base by design
- [x] 7. old-sentence grep: only setup-node.sh:2152 and tasks/spec-req-shared.md:191 (untracked spec). No test/UI/doc.
- [x] 8. gates: bash32 clean (214), shellcheck error clean, warnings setup 0->0 update 1->1 test 5->4, network-hits clean (153), perl-interp clean, 26.04 count 1, named fixtures host 29/0, full suite host 84/0, ubuntu 84/0
- [x] 9. commit 0d137d2
