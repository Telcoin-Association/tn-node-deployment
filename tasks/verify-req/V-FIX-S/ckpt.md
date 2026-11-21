status: done
# V-FIX-S checkpoint
base=/var/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/46275ae3-5cf9-4f35-b799-c09950443243/scratchpad/v-fix-s
sections:
- [x] S1 live proof -- DONE. run dir $base/s1-20261121-120335-3331599 (bash s1-live.sh)
  old: ENSURE_RC=1, HEAD refs/heads/main 33bf2a20, committee 886f016b.. vs 009b6d7b.. (bug reproduced)
  new: ENSURE_RC=0, HEAD d72cc2bc = tag, submodule '-', dirs root:root 755, files 644 pinned;
  p2 rc0 HEAD/porcelain same; p3 0 git calls; p4a local tn-remote-tags; p4b refs/tags via DNS fail; p4c rc2.
- [x] S2 -- DONE. run dir $base/s2-run1 (docker run ... s2-inner.sh). All cases as designed, no bash errors.
  Findings: (a) JSON failed clone: only "Could not get ... (see above)" in JSON, reason only on stderr;
  (b) rc1 for ownership/symlink refusal says "chain configs are not the pinned ones"; (c) .git owned by
  another account -> "Could not fetch tag ... and the checkout does not have it" (git dubious ownership);
  (d) F7 confirmed: rev-parse/cat-file fd9 OPEN, GIT_ALLOW_PROTOCOL unset; (e) not-found list repeats dirs.
- [x] S3 -- DONE. run dir $base/s3-inner-20261121-121346-3401538 (bash vrun.sh s3-inner.sh)
  A: plain + json refuse, rc1, 0 files written, 0 git calls. B1 fresh ok (reads checkout at tag);
  B2/B3 diverged: infra/keygen ok, write/finalize rc1 checkout committee mismatch (after keygen in real flow).
  B4 control new+new ok.
- [x] S4 -- DONE. run dir $base/s4-inner-20261121-121420-3412524: remove_keys DELETE and remove_leftovers remove /etc/telcoin incl. chain-configs; legacy /etc/telcoin/validator layout leaves /etc/telcoin/chain-configs (rm_leftovers_present rc0 catches it next run)
- [x] S5 -- DONE. run dir $base/s5-inner-20261121-121722-3595420: F1-F6 confirmed (F7 in S2), F3b hand-made 0700 dir never repaired, F5 worse in ensure (clone into existing dir), U1 lock HELD at prompt, U2 no prefix leak, U3 stale pins replaced, U4 proxy/GIT_DIR reach git, U5 EOF=Skipped
- [x] REPORT.md -- Write refused by the harness (subagent report files); full text returned in the hand-back for the orchestrator to save
