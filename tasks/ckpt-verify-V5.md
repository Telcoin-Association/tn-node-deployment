status: done
# V5 verifier checkpoint (FW + UI-S)

## Sections
- [x] S1 read specs, AGENTS.md, lessons, diffs
- [x] S2 harness: FW bash (fw_test.sh)
- [x] S3 harness: remove-node + status/json
- [x] S4 harness: UI python (test_v5_ui.py) + helper bash
- [x] S5 real nft proof (ubuntu:24.04 NET_ADMIN)
- [x] S6 run harness all envs
- [x] S7 mutation run
- [x] S8 compare implementer checkpoints + docs notes
- [x] S9 gate cross-check
- [x] S10 commit + final report

## Notes
- fw_v5_test.sh 143 checks bash5.3: 4 adversarial FAILs = findings: H5 doubled P2P_ALLOW_FROM -> expected rows 'anywhere';
  I6 menu path bad rate says 'nothing was changed' after ufw opened; J4 SIGTERM after nft write -> persistent:true w/ stale boot copy;
  K1 concurrent enables (no lock w/o list) -> table 30 vs boot 10.
- rm_v5_test.sh 23 checks: R3b json keys w/ another node unit removes /etc/telcoin/p2p-limit.nft (config dir rm -rf), unit+table stay; R7 info only unit+table left -> remove_leftovers rc3 (unit left).
- helper_v5_test.sh 14 checks all ok.
- test_v5_ui.py 22 passed (50 subtests) py3.10; render_v5.js 26/26 node22. Doubled P2P_ALLOW_FROM -> UI shows last ['192.0.2.0/24'] while engine refuses.
- realnft: 30 checks ok (nft 1.0.9 kernel 7.0): loads twice, /64 shared 30+10=40, v4 burst 40 of 60, live parse ok; FINDING: ct state new meters every packet of an unanswered UDP flow (40 of 60 on ONE flow), so 'new flows' = packets before first reply. Needs --sysctl ipv6 + command ip (override clash).
- S6 run.sh: fw 143/144 (5 adversarial FAIL each env: H5,H7,I6,J4,K1), rm 23 (R3b), helper 14 ok x3, realnft 30 ok, pytest 22 ok, node 26 ok, units: p2p-limit verify rc0; ui unit only ExecStart not-found. S7 mutate.py running (bg).
- S8 docs-note checks done (FW: R3b 'all of it stays' false for json keys; desired 'anywhere only without list' false for doubled key; menu refusal 'nothing changed' false; Operator-visible bullet stale 'from one address'; UI-S: 'index.html names no adiri host' false (node7.adiri placeholder); null also for empty .node-meta; p2p_from falsy non-string accepted). S9 gates: fw/signal/remove 283|281,185,334 x3 envs ok; helper 548 x2 ok; shellcheck/bash32/bash-n ok; py_compile ok w/ prefix. pytest ui gate pending.
- S7 mutation: 31 hunks all KILLED (records/mutation.txt; run2 fixed SUBFAILED parse). S9 pytest ui 277 passed/1125 subtests. fwjson 12 checks ok.
- S10: commit next; findings W1 menu bad-env msg, W2 SIGTERM persistent, W3 concurrency no lock, W4 doubled key 'anywhere', W5 json keys w/ other node removes boot file; NOTES N1-N7.
- committed 92406ef on verify/V5 (41 files, tasks/verify-fup/V5 only)
