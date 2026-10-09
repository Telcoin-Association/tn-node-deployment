status: DONE (2026-09-30) -- handed back
sandbox: /private/tmp/claude-501/-Users-grant-coding-telcoin-tn-cli-dev/493f29bf-7e45-4838-af9b-04e2d651efeb/scratchpad/v-sn/
harness: .../v-sn/harness.sh  (run: /opt/homebrew/bin/bash harness.sh [G1 G2 G3 G5 G6 G7]); last output .../v-sn/last-run.txt
TALLY: PASS=165 FAIL=1 (141 sandboxed subject runs)
completed groups:
- G0 recon -- DONE
- G1 differential -- DONE, all PASS (bash5 + 3.2)
- G2 flags -- DONE, 1 FAIL: install-caddy gets --public-ip=IP (equals form, setup-node.sh:1408) vs criterion/follow-up space form
- G3 prompt / G4 persistence / G5 step_public_rpc / G6 summary / G7 syntax+shellcheck -- DONE, all PASS
notes: --rpc-public false --rpc-domain d => PUBLIC; UI --rpc-public true now errors (v1.0.1 ignored); setup-node.sh.sha256 stale; bash 3.2 confirm ${response,,} pre-existing
