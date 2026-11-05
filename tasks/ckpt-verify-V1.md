# ckpt-verify-V1
status: done

## Sections
- [x] 1. read specs, diff, AGENTS.md, lessons
- [x] 2. harness written (tasks/verify-fup/V1/v1_test.sh, run.sh)
- [x] 2b. harness run (final): host, bash:3.2, ubuntu:24.04 each 315 checks, 0 failures, 0 skips, 4 FINDING (C8 x2, C9 x2)
- [x] 2c. mutation run (final harness): 28/28 caught (mutate.log 27/28 + M17 rerun after a ~ separator clash, mutate-M17.log)
- [x] 3. compared (notes above); harness +5 checks from docs notes (315 on host)
- [x] 4. gates: run.sh 60/0 (5.3, 4050 checks) 60/0 (3.2, 3975); helper 505/0 both; shellcheck 0.11+0.9, check-bash32, bash -n clean
- [x] 5. committed 9b16075 on verify/V1 (tasks/verify-fup/V1 only; .base/ left untracked)

## Notes
- design: v1_test.sh runs each case in a fresh bash (drv.sh) sourcing a variant copy
  ($T/v/{ship,on,floor,launch,nomain,base}); FINDING checks counted apart (obs), so the
  tip exits 0 and a mutation exits 1.
- candidate findings so far: setup-node --docker-image digest on mainnet bypasses the
  digest rule after launch (json_check_install_flags / _preflight_docker use
  validate_docker_image + tn_docker_release_tag_for, never tn_docker_resolve_ref);
  edit_docker_image interactive mainnet refusal still suggests a digest; blind wait keeps
  a short cap (spec item 2 literal); ac9a605 subject says update-node/edit-config required
  helpers changed (only setup-node's list did).
- mutation run started (mutate.sh, 28 mutants) -> records/mutate.log; do NOT edit v1_test.sh
  while it runs. Pending harness additions after it: D17 43200 -> 600/180, D19 "should have
  ended" + timing sentence, F6 check-node --help "none when the network is unknown".
- section 3 notes: LIB-A docs note "none recorded: not checked, tn_docker_resolve_ref warns"
  is wrong on mainnet (refuses); "before the install flags" wrong (init_install_flags,
  --log-target, public-RPC flags validated first: repro setup-node --json --network mainnet
  --release-tag v0.16.0-adiri --build-ref v0.17.0-adiri gives the flag error, not the mainnet
  one). LIB-B docs note "<n>s by default when the answer carried no epoch length" wrong:
  missing epochDuration = no wait (malformed); "by default" only for epochDuration 0.
  #33 strings all present in update-node.sh. adiri example URL in --public-rpc-url error on
  mainnet (pre-existing, NOTE).

## Findings draft
- ERROR setup-node.sh json_check_install_flags + _preflight_docker: at launch (flag 1, floor,
  mainnet pin) --docker-image <ghcr digest> on mainnet is accepted (rc 0) and pulled after a
  "not a release tag" warning; tn_docker_resolve_ref refuses the same (C9 x2).
- WARN edit-config.sh edit_docker_image: on mainnet the prompt says "such as v0.16.0-adiri"
  (DEFAULT_DOCKER_TAG) and the refusal says "Give a mainnet release tag, or <repo>@sha256:<digest>."
  (C8 x2); the --json path got a mainnet message in ac9a605, the menu did not.
- NOTE blind wait keeps a cap below margin+settle (spec item 2 literal vs keytool pin) D11.
- NOTE docs-note corrections (see section 3 notes).
- NOTE ac9a605 subject: only setup-node's required list changed.
- NOTE --public-rpc-url error example names node7.adiri.telcoin.network on mainnet (pre-existing).
- lint gates: shellcheck 0.11 + 0.9 clean, check-bash32 clean, bash -n 5.3 + 3.2 clean (6 files).
