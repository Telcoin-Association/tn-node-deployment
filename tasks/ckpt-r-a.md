status: done (final report handed back)
completed sections: read-through; req1-8 all checked; shellcheck/bash3.2 parse; python editor exercised on scratch fixtures (legacy byte-identical vs v1.2.0; workers list set/reset/clear/get/CRLF/comments)
findings:
- BLOCKER: none
- SHOULD-FIX: 947-952 guard recovery restart w/o `systemctl reset-failed` (start-limit-hit blocks manual start) -> node left down; now reachable via --ws injection (quoted "--ws" not matched at 1039 -> duplicate flag)
- SHOULD-FIX: install-caddy.sh.sha256 stale
- NOTE: 1314/1004 rpc-disable dies on unparseable node-info before removing vhost
- NOTE: 550-556 reload ok but inactive -> restore + false "keeps serving" msg
- NOTE: foreign `admin off` config -> reload always fails
- NOTE: 1059 WS listening check accepts any process
- NOTE: 575-578 teardown early-return w/o caddy leaves RPC block + ufw 80/443
- NOTE: teardown lacks foreign guard (pre-existing, now recoverable)
- NOTE: guard 60s window vs RestartSec; header line 41 overstates rollback
requirements: 1 met, 2 met, 3 met, 4 met, 5 met (guard caveat), 6 met, 7 met, 8 met
