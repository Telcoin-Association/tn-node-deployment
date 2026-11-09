status: done
task: R4 follow-ups on PR #52 (devnet-docker-images @ 090d9e1)
scratch: /tmp/claude-1000/-home-drtnarg-coding-telcoin-devnet-genesis/9749f56d-69ba-4ad5-9af1-7f63cb688653/scratchpad/fu
completed sections:
- S1 lib devnet refusals (uncommitted): _tn_release_fetch + tn_source_checkout_tag refuse net=devnet rc3 first;
  vectors in release_fetch_test.sh (stub _tn_release_get exit 99) + source_ref_test.sh (x-devnet; --allow-dirty devnet now rc3).
  Both files pass (113/0, 145/0); new vectors FAIL on 090d9e1 lib (checked).
- S2 update-node verify_consensus_participation (uncommitted): net from _tn_guard_network, devnet -> DEVNET_CHAIN_ID;
  vector in consensus_participation_test.sh (41/0; 3 new checks FAIL on 090d9e1). Side-by-side fu/cvec.sh base(090d9e1) vs tree:
  40 lines, only the 8 devnet-host lines differ; testnet/mainnet/none/foo identical (c-base.txt / c-head.txt).
- S3a docs (uncommitted): README update-node 2.0.1 + lib/common 2.0.1 "as before" exception; CHANGELOG intro exception + Network checks
  rewrite (--json only, --check finds no devnet image, --json --prepare --ref / --json --apply --yes [--yes: validator apply needs it], edit-config);
  OPERATOR.md:257 caveat sentence. PR body (tasks/pr12-body.md + gh pr edit) pending.
- S3b PR body file edited (tasks/pr12-body.md; orig copy fu/pr12-body.orig); Verification numbers + gh pr edit pending.
- S4 sidecars: gen-checksums -> exactly lib/common.sh.sha256 + update-node.sh.sha256 changed; no version bump.
- S5 gates (tree uncommitted, all green): run.sh 59 files 0 failed (3697 checks, 0 failures, 49 skipped; bash 5.3.9);
  check-bash32 clean 100; check-perl-interp clean 100; shellcheck -x --severity=error all tracked .sh clean;
  --severity=warning on 5 changed .sh: base 27 / head 26 (one SC2034 gone), none new; bash:3.2 run of the 3 touched
  test files 0 failed (41/0/0, 49/0/1 skip, 92/0/2 skip); ui/ unchanged -> pytest not run.
- S5b extra gates at head: bash:3.2 ten devnet-relevant files 0 failed; pytest ui (python:3.10-slim, hashed reqs) 258 passed
  (ui tests read lib/common.sh, so re-run); ui/tests/helper_test.sh 494/0; shellcheck warnings 12 PR .sh vs 8175a88: 37 -> 36, none new.
- S6 commits f5abe22 (code+tests+sidecars), d9446f7 (docs); no attribution trailers; pushed 090d9e1..d9446f7;
  gh pr edit 52 body from tasks/pr12-body.md (body part after ---); headRefOid = d9446f720026fa5ce8b64fce9074e56b05b3f4eb.
