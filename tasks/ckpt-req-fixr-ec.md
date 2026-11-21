status: done
agent: FIXR-EC (menu 13 fixes V-FIX-E-1,2,3,4,7,8)
worktree: /home/drtnarg/coding/telcoin/tnd-req-fixr-ec (branch req/fixr-ec, base 1a3404b)

## Sections
- [x] read: spec, report, harness, code (refresh_chain_configs 3730-3933, apply_changes 2226-2279, lib clone 3327)
- [x] fix1 V-FIX-E-1 clone offered from the menu
- [x] fix2 V-FIX-E-2 restart hint after Nothing to refresh
- [~] fix3 V-FIX-E-3 one baseline refresh (blocked in range: success path stays 2; patch for apply_changes next)
- [x] fix4 V-FIX-E-4 lock released before Press Enter
- [x] fix5 V-FIX-E-7 mainnet refuses up front
- [x] fix6 V-FIX-E-8 data-dir hashes via tn_as_service_user
- [x] tests
- [x] verifier harness second opinion (host 65/7F/1S, ubuntu root 68/7F/0S; 7 flips all expected: E2f, E3a, E3b, E3c, E4d, E4a, E5 failed copy; E1 count 2 unchanged)
- [x] gates (whole suite host 84/0 failed, ubuntu:26.04 84/0 failed; six files green host/ubuntu/bash3.2; lints clean)
- [x] commit 6f31bd4 (fix 3 not in it; patch in scratch)

## Decisions
- fix1: the no-checkout test runs BEFORE menu_lock (same test as ensure_chain_configs_available:
  no .git and the pinned dir fails tn_chain_configs_check). Clone question asked with no lock held;
  on yes menu_lock is taken, then _tn_chain_configs_clone (skipped if .git appeared meanwhile), and the
  lock stays held into the helper. Decline / failed clone -> unlock, manual lines, Enter.
  Helper rc 2 with no .git after that is race-only: error + "Run this again" hint.
- fix3: BLOCKED in range. apply_changes (outside my range) refreshes the baseline only on a
  successful restart and exposes nothing about its branch (always rc 0). Count 1 on success AND 1 on
  restart-later needs apply_changes to learn the caller already made it. Keep the immediate refresh
  after install (1 on every non-success path); success stays 2. Deliver a verified patch in scratch.
- fix4: edit_unlock before every Press Enter after the lock; main_menu's edit_unlock is a no-op
  (EDIT_LOCK_HELD=false).
- test: read() wrapper logs "enter" into EV for "Press Enter" prompts -> order proven from EV.

## Progress
- code in edit-config.sh done (tn_require_fns + refresh_chain_configs), shellcheck warning-clean
- test rewritten: host 140/0/0; against HEAD edit-config.sh 39 FAIL (all in new areas)
- six files: host/ubuntu/bash3.2 all green (chain_configs_refresh 140/0/0 each)
- lints: bash32 clean 214, network-hits clean 153, perl clean 214, shellcheck err+warn clean both files
- whole suite host+ubuntu running in background
- fix3 patch (apply_changes [baseline-current] + menu 13 call + test): /var/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/46275ae3-5cf9-4f35-b799-c09950443243/scratchpad/fixr-ec/fix3-apply_changes.patch
  verified in scratch tree fix3tree: chain_configs_refresh 142/0/0, edit_backup/resync/admission/passphrase green; git apply --check OK on the worktree
- commit message draft: scratchpad/fixr-ec/commit-msg.txt (subject drops "one baseline refresh": fix 3 not in it)
