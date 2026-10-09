status: complete (all groups G1-G8 run; final TALLY PASS=271 FAIL=1)
task: independent offline verification of install-caddy.sh v1.3.0
harness: /private/tmp/claude-501/-Users-grant-coding-telcoin-tn-cli-dev/493f29bf-7e45-4838-af9b-04e2d651efeb/scratchpad/v-ic/harness.sh
rerun: /opt/homebrew/bin/bash <harness> [g1..g8]   (log: v-ic/harness.log)
completed groups:
- S seams: PASS 3/3 (incl. no temp file escaped into host temp dir)
- G1 safe swap: PASS
- G2 reload rule: PASS
- G3 same-domain: PASS (NOTE: enable-direction msg names dashboard.<d>, no --move-dashboard-to cmd -- nothing to move)
- G4 move-dashboard: PASS
- G5 ws preflight: FAIL 1 (G5.24): comment line containing "--http" before the launch line -> --ws appended to the comment (tn_node_inject_flags, comment-blind, called at install-caddy.sh L1089; caddy_launch_http_line_continued L1044-1046 also comment-blind); script says "Enabled the reth WebSocket" and advertises wss:// though reth never gets --ws; only the post-restart verify warns.
- G6 human phases + JSON byte-compat: PASS
- G7 node-info editor: PASS (NOTE G7.16b: 2138-char --rpc-domain passes caddy_validate_domain L321 (no 253/63 limits) -> vhost swapped+reloaded (L1297) before node-info URL check L997 refuses; same order as v1.2.0)
- G8 regression/differential/brick guard/bash -n/shellcheck: PASS
harness lessons: background launch ignores SIGINT (perl resets SIG_DFL); macOS mktemp ignores TMPDIR (mktemp stub emulates GNU); 16 v1.2.0 leftover temp files in the Darwin user temp dir from early harness runs were identified by content and removed.
cosmetic: json SIGTERM -> "exited early (rc=0)" (json_on_exit L151 reads $? = 0 under a signal)
