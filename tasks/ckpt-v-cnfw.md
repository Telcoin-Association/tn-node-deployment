status: done
task: offline verification of check-node.sh v1.1.54 + firewall-setup.sh v1.5.2
sandbox: /private/tmp/claude-501/-Users-grant-coding-telcoin-tn-cli-dev/493f29bf-7e45-4838-af9b-04e2d651efeb/scratchpad/v-cnfw/
harness: <sandbox>/harness.sh ; runs 3,4,5 stable: TALLY pass=249 fail=1
completed groups:
- recon, static A5/B5, A4 yaml, A1, A2, A3 differential, B4 comments, B1-B3 ufw differential, stability re-runs, write-up
single FAIL: B1 strict -- firewall-setup.sh:881 greps the marker anywhere, not only at file start (low severity; same as pre-existing caddy_managed_active)
nits (not criteria): :874 "superset" comment inexact (needs caddy on PATH; caddy_managed_active does not); :312 hint uses bare install-caddy.sh (no dir); healthy wss probe always waits --max-time 8 (check-node.sh:664)
