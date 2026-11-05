# Checkpoint F-E: service state from a root ExecStartPre

status: done (all sections complete; nothing committed, sidecars not regenerated)

## Sections

- [x] 1 lib/alerts.sh unit text + disable
- [x] 2 lib/tn-heartbeat.sh _hb_check_service reads the state file
- [x] 3 remove-node.sh remove_alerts
- [x] 4 tests
- [x] 5 docs
- [x] 6 container proof
- [x] 7 gates

## Proof

Container tnsd (systemd 255.4-1ubuntu8.18). Installed lib/tn-heartbeat.sh as
/usr/local/libexec/telcoin/tn-heartbeat (root 0755) and the unit alerts_unit_text renders
(identical to the one found there). Test scaffolding only, not shipped: a drop-in
`Environment=CREDENTIALS_DIRECTORY=/etc/telcoin/alerts-cred` with a root 0644 copy of the
targets file (Docker does not populate LoadCredential=), a full alerts.env with
ALERTS_RPC_URL=http://127.0.0.1:8545, and python3 -I stand-ins (rpc.py and listener.py from
P0-alerts.sh) run outside telcoin.service, so only step 1 can see the node stop. The control
run drops ExecStartPre= with a drop-in and shows the old bug (up with the node stopped). All
scaffolding removed afterwards; alerts.env restored to `ALERTS_SERVICE=telcoin`.

```
== run 1: telcoin.service started
active
heartbeat rc=0
-- /run/telcoin:
root:root 755 directory /run/telcoin
root:root 644 regular file /run/telcoin/heartbeat-service
-- /run/telcoin/heartbeat-service:
NRestarts=0
LoadState=loaded
ActiveState=active
SubState=running
StateChangeTimestampMonotonic=2319991474596
ActiveEnterTimestampMonotonic=2319991474596
-- state:
version=2.1.0
last_run=1793840528
mono=2319991
last_status=up
status_since=2319991
last_reason=CvvActive block 1234567 epoch 42
last_mode=CvvActive
last_block=1234567
last_epoch=42
last_header=1234
header_since=2319991
inactive_since=
started=2319991
svc_since=2319991
svc_restarts=0
push_total=1
push_ok=1
push_1=kuma ok 200 127.0.0.1:18080
-- state owner:
62873:62873 600
-- journal:
Starting telcoin-heartbeat.service - Telcoin node heartbeat (private alerts)...
status none -> up: CvvActive block 1234567 epoch 42
up: CvvActive block 1234567 epoch 42 | 1 kuma@127.0.0.1:18080 ok 200
telcoin-heartbeat.service: Deactivated successfully.
Finished telcoin-heartbeat.service - Telcoin node heartbeat (private alerts).
-- pushes:
GET /api/push/<token>?status=up&msg=CvvActive+block+1234567+epoch+42&ping=0

== run 2: telcoin.service stopped
inactive
heartbeat rc=0
-- /run/telcoin/heartbeat-service:
NRestarts=0
LoadState=loaded
ActiveState=inactive
SubState=dead
StateChangeTimestampMonotonic=0
ActiveEnterTimestampMonotonic=0
-- state:
version=2.1.0
last_run=1793840530
mono=2319993
last_status=down
status_since=2319993
last_reason=service telcoin inactive (dead)
last_mode=CvvActive
last_block=1234567
last_epoch=42
last_header=1234
header_since=2319993
inactive_since=
started=2319993
svc_since=
svc_restarts=0
push_total=2
push_ok=2
push_1=kuma ok 200 127.0.0.1:18080
-- last_reason: service telcoin inactive (dead)
-- journal:
Starting telcoin-heartbeat.service - Telcoin node heartbeat (private alerts)...
status up -> down: service telcoin inactive (dead)
down: service telcoin inactive (dead) | 1 kuma@127.0.0.1:18080 ok 200
telcoin-heartbeat.service: Deactivated successfully.
Finished telcoin-heartbeat.service - Telcoin node heartbeat (private alerts).
-- journal with priorities:
<5>status up -> down: service telcoin inactive (dead)
<4>down: service telcoin inactive (dead) | 1 kuma@127.0.0.1:18080 ok 200
-- pushes:
GET /api/push/<token>?status=down&msg=service+telcoin+inactive+%28dead%29&ping=0
→ Overall exposure level for telcoin-heartbeat.service: 1.5 OK :-)
verify-rc=0
ExecStartPre={ path=/bin/sh ; argv[]=/bin/sh -c umask 022; install -d -o root -g root -m 0755 /run/telcoin && rm -f /run/telcoin/heartbeat-service /run/telcoin/heartbeat-service.tmp && systemctl show 
== control: no pre-step, telcoin.service inactive
heartbeat rc=0
-- state file present: no
-- last_reason: CvvActive block 1234567 epoch 42
status down -> up: CvvActive block 1234567 epoch 42
up: CvvActive block 1234567 epoch 42 | 1 kuma@127.0.0.1:18080 ok 200
```

## Tests run

- bash 5.3.9: heartbeat 202/0 fail/0 skip, alerts 288/0/3, remove 502/0/0, setup_alerts 209/0/0
- bash:3.2 (3.2.57, busybox): heartbeat 202/0/0, alerts 280/0/2, remove 502/0/0, setup_alerts 204/0/5
- ubuntu:24.04 root (5.2.21): heartbeat 202/0/0, alerts 280/0/2, remove 502/0/0, setup_alerts 204/0/5
  (skips are environmental: no systemd-analyze, root reads every file, no python3)
- New heartbeat cases fail against the HEAD runner (7 of the 16 new checks), pass now.
- bash -n under 5 and 3.2, check-bash32 (7 files clean), shellcheck -x --severity=error (rc 0;
  advisory warning counts unchanged from HEAD), passphrase_print 4/0, root_write_pipe 2/0,
  ci_pins 55/0, check-network-hits clean (147 annotated hits), git diff --check clean.
- systemd-analyze verify of the rendered unit: host systemd 259 (alerts_test) and tnsd 255.

## Open issues

- The .sha256 sidecars of lib/alerts.sh, lib/tn-heartbeat.sh and remove-node.sh are stale until
  the orchestrator runs tools/gen-checksums.sh (the checksums CI job fails until then).
- tools/tests/vm.d/P0-alerts.sh was only parsed and linted here; its new assertions run on the CI
  VM (tnsd cannot run it: Docker does not populate LoadCredential=).
- The partner guide does not list the alerts files, so it and its PDF are unchanged.
