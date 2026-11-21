status: done

# FIX-B checkpoint (menu 13 installs the pinned chain configs)

Worktree /home/drtnarg/coding/telcoin/tnd-req-fix-b, branch req/fix-b, base 0b5f97b.
A copy of the finished edit-config.sh: scratchpad fixb/edit-config.sh.mine (identical to the worktree).

## Sections
- [x] require list and label (tn_require_fns + menu label; edit-config.sh)
- [x] refresh_chain_configs (uncommitted edit in worktree; bash -n ok)
- [x] test (tools/tests/chain_configs_refresh_test.sh): 92 checks green on host and bash:3.2; mutation vs
      HEAD edit-config.sh: 66 FAIL; unlock/baseline/label mutations caught; mode 0644 like most tests
- [x] other pulls and UI (findings below)
- [x] gates: six files host/26.04/3.2 green; whole suite host 82/0 failed, ubuntu:26.04 82/0 failed;
      check-bash32 clean (211 tracked + new file); shellcheck error clean both files, warnings 0 = 0
      (HEAD vs mine) on edit-config.sh, 0 on new file; network-hits clean (153); perl-interp clean.
      Committed e37c241 (edit-config.sh + new test only).

## Notes
- source_dir is ${TN_ROOT_PREFIX:-}${TN_SOURCE_DIR} (as ensure_chain_configs_available does);
  tag path: data-dir sha check first -> "Nothing to refresh"; then intro, confirm, menu_lock, helper;
  rc!=0 -> error ending "Chain configs unchanged.", edit_unlock; rc 0 and pinned dir was not already
  passing -> edit_baseline_refresh; source = tn_chain_configs_dir.

## Findings: UI and other pulls
- ui/: no refresh_chain_configs, no chain-configs/chain_configs, no git pull. The UI helper drives
  edit-config.sh only through --json --set FIELD=VALUE (and --migrate-credential); menu 13 is menu-only.
- lib/common.sh:3344 ensure_chain_configs_available: `git -C src pull --ff-only` devnet only (FIX-A1);
  devnet has no pins, so cannot break them; it does move a devnet source checkout.
- edit-config.sh:~3850 (mine): `git -C src pull` devnet only now; same verdict.
- lib/common.sh:9028 tn_source_checkout_tag: `checkout --detach refs/tags/TAG` (setup-node.sh:751,
  update-node.sh:1912 source builds): moves HEAD to a release tag, but testnet chain configs are now read
  from refs/tn-remote-tags/<pinned tag>, not the working tree: pins unaffected.
- lib/common.sh:3282/3284 clones: testnet at --branch TAG (no submodules), devnet default branch.
- update-node.sh:2658 comment says "git fetch and pull" but update-node runs no git pull (stale comment,
  out of range).
- edit-config.sh "pull latest" text: only in my range (intro + label), both changed. chain_config_subdir
  comment (:3662) "under the source checkout" still true for devnet/mainnet.
