status: done

Package OBS (issues #35, #43 token part). Worktree ~/coding/telcoin/tnd-fup-OBS, branch fup/OBS, base 6cbf52e.

## Sections
- [x] S0 read specs, verify anchors, Alloy syntax reference check
- [x] S1 upstream commit on alloy-token-file-tls in adiri-genesis/common (not pushed)
- [x] S2 observability/config.alloy vendored (sync-note diff empty, header) + _obs_alloy_fallback
- [x] S3 lib/observability: token file, env file hosts, native unit, docker sidecar, migration, obs_existing_token, obs_disable shred, obs_status line
- [x] S4 setup-observability: --rotate-token (interactive, menu, --json, restart check, rollback)
- [x] S5 remove-node: token shred in observability teardown
- [x] S6 tests: obs_test.sh + remove_test.sh
- [x] S7 gates (all environments) + docker image readability proof
Follow-up round (V3 findings, 2026-11-03):
- [x] F1 E1: push URLs read back from the env file; refuse an empty URL for an enabled pipeline
- [x] F2 W1: EXIT trap for non-JSON --rotate-token and the menu (tn_remove_inflight_tmp + lock release)
- [x] F3 W2: obs_disable checks the token file is gone, warns + rc 1 if not
- [x] F4 W3/N2: restore only changed files; byte-exact snapshot
- [x] F5 W4: missing token with both pipelines off reported as info
- [x] F6 N1/N6/N3/N4: docker config.alloy root:telcoin-alloy; remove-node comment; rotate success hint; docs note
- [x] F7 tests + gates
Round 3 (review: push-URL precedence records intent):
- [x] R1 lib: OBS_*_PUSH_URL_SOURCE=override marker; stored URL wins only with it; `default` word clears; log line on change
- [x] R2 tests: default change reaches the host, override kept, 2.0.x env = default, marker never carries the token, clear with `default`
- [x] R3 gates + checkpoint + hand-back

## Progress notes
- S0 Alloy 1.5 reference (archive.grafana.com/docs/alloy/v1.5/reference/components/loki/loki.write/ and .../prometheus/prometheus.remote_write/): endpoint takes `bearer_token_file` (string) and `bearer_token` (secret); at most one of bearer_token, bearer_token_file, authorization, basic_auth, oauth2 (+sigv4, azuread for remote_write). Nested `endpoint > tls_config` with `server_name` (string) and `min_version` (string; one of "TLS10","TLS11","TLS12","TLS13"; default Go's TLS 1.2). Syntax page (.../get-started/configuration-syntax/expressions/operators/): `+` under String operators = "Concatenate two strings".
- S0 hub probe: openssl s_client -tls1_3 to obs.adiri.telcoin.network:443 negotiates TLSv1.3, cert CN=obs.adiri.telcoin.network, verify 0.
- S0 real image grafana/alloy:v1.5.1 (digest sha256:01a63f4e...1eb3): Config.User is EMPTY, so the process runs as uid 0 (root) in the container; 473:473 is only the owner of /var/lib/alloy. With --cap-drop=ALL: uid 0 reads a 0640 0:4999 bind-mounted file (owner bits) with or without --group-add; --user 473:473 --group-add 4999 reads it; --user 473:473 without --group-add gets Permission denied. `alloy fmt` on the new upstream file: identical output. `alloy run` (network none, env file, token mounted): config loads, both pipelines start, push fails only at DNS; with the file unreadable (--user 473 no group-add) it logs "unable to read authorization credentials" for loki.write and prometheus.remote_write. So the mount + --group-add design works for today's image (root) and for an image that switches to user 473.
- S1 upstream: ~/coding/telcoin/adiri-genesis/common branch alloy-token-file-tls from origin/main dc57dfe, commit 30a2813a7af82aea77833f28f1d7fc07147b35c0 "observability/node-agent: read the ingest token from a file and pin TLS 1.3" (NOT pushed). sha256(upstream config.alloy) = a486542488aff9b2c6e61320a81f31e248b6dd93992e8abe3af191aa257734c6.

- S2 commit db0d15c observability/config.alloy (sync-note diff empty, alloy fmt identical). sha256(observability/config.alloy) = 4c1527db28863dc85f2e5a8f06119ebf8eac731d879038e455e17efbac5453a3
- S6 commit 1178da3 tests (obs_test 348 checks on bash 5.3, 344+3 skip on bash:3.2 and ubuntu:24.04; remove_test 313).
- S3 commit 5fb0bf1 lib/observability; S4 commit 817e76d setup-observability; S5 commit a89b459 remove-node.
- Real-image proof of the sidecar ExecStart (network none, --ulimit core=0, --cap-drop=ALL, --group-add, --mount readonly): config loads, 0 credential errors, only DNS dial errors; docker inspect Env has no token; ulimit -c = 0 in the container. --mount with a missing source: "bind source path does not exist" (no directory created), unlike -v.
- systemd-analyze verify (host systemd 259) on rendered native and docker units: rc 0 (only unrelated xfs_scrub CPUAccounting notices).

## Follow-up round (V3) results
Commits on fup/OBS after 6d08cef (oldest first):
- 676faaa F1 push URLs read back / refusal
- 3e04cf3 F3 obs_disable checks the token file is gone
- f02b75d F4 restore only what changed, byte-exact snapshot
- 5d32f5f F5 status info when both pipelines are off
- 3096ab7 N1 docker config.alloy root:telcoin-alloy 0640
- 6c15251 N3 rotate success line says how to check shipping
- 085edf9 setup-observability: the menu and --rotate-token remove an interrupted token write on exit
- 89b3656 remove-node: the full-removal comment names the 0640 ingest token file
- 951090f tests: kept push URLs, the rotate exit trap, a token file that stays, exact rollbacks
- 748d154 setup-observability: TERM, INT and HUP end the run through exit, so the EXIT trap runs
- ed35f48 tests: the menu traps TERM, and the SIGTERM case holds under bash 3.2
MESSAGE DEFECT (mine; ready amend files: /tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/5d4c8cd2-b758-4c78-9efb-36793aa8b1d5/scratchpad/OBS/msg/amend-<sha>.txt): the six lib commits 676faaa..6c15251 lost their subject line (a `<<'MSG' && \` chain made the first heredoc line part of the command line) and 6c15251 has no blank line after the subject. Content is correct. I did not rewrite history (reset/rebase not allowed). Intended messages, to apply with `git commit --amend -F` after each cherry-pick:
- 676faaa: "lib/observability: keep the push URLs an enable wrote, and refuse a render without one" + its current body.
- 3e04cf3: "lib/observability: obs_disable says when the token file could not be deleted" + body.
- f02b75d: "lib/observability: a --rotate-token rollback puts back only what changed, byte for byte" + body.
- 5d32f5f: "lib/observability: no token file with both pipelines off is information, not a warning" + body.
- 3096ab7: "lib/observability: the docker config.alloy is root:telcoin-alloy 0640, like the token file" + body.
- 6c15251: "lib/observability: the rotate success line says how to check that Alloy ships" + blank line + the rest of the current first paragraph as body.
Cherry-pick check: `git merge-tree --write-tree --merge-base=6d08cef hardening-followups ed35f48` is clean (tree 7e5c29b...); on that merged tree check-network-hits.sh is clean (148 annotated hits) and obs_test 403/0/0, remove_test 338/0/0, network_hits_test 53/0/0.
Mutation check of the new fixtures (scratch copies): read-back removed 5 FAIL, EXIT trap removed 2, disable check removed 7, restore-always 2, no sentinel 3, off-info removed 2, URL check in obs_render_alloy removed 1. All killed.
Real image N1: config.alloy 0640 0:4999 + token 0640 0:4999, --cap-drop=ALL --group-add 4999: as uid 0 and as --user 473:473 both run, 0 config/permission errors, 0 credential errors (only DNS). The docker storage dir /var/lib/telcoin-alloy (root:root 0750) would still stop an image that switched to user 473; this unit does not run one.
F2 finding: bash 3.2 skips a shell's EXIT trap when SIGTERM kills it by default and its parent shell has an EXIT trap (reproduced in a 10-line probe). Fixed by trapping TERM/INT/HUP with exit 143/130/129 in both the --json and the menu/--rotate-token paths.

## Round 3 results (push-URL intent)
Commits on fup/OBS after ed35f48:
- 75d6fc3 lib/observability: record a push URL override as intent, so a changed default reaches the host
- 4d37f61 tests: a changed release default reaches the host, an override stays, 2.0.x counts as default
Design: telcoin-alloy.env carries OBS_PUSH_URL_SOURCE=override / OBS_METRICS_PUSH_URL_SOURCE=override only when the URL came from an override (on that run, or carried from a recorded one). obs_effective_*: override on this run (any value but "default") > a stored URL whose marker says override > the current release default (devnet/testnet). "default" clears. No marker (release default, 2.0.x env file, or this round's earlier unreleased files) = default. A URL change at render is said once per render and pipeline. The empty-URL refusal (_obs_urls_ok) is unchanged. A partial disable drops the disabled pipeline's lines, so its override is forgotten: pass the flag again when re-enabling it.
Mutation check: marker ignored 9 FAIL, marker not written 11, "default" not handled 3, change line removed 5. All killed.
Cherry-pick check: merge-tree onto hardening-followups (base ed35f48) clean (tree 0803fcc); merged tree: check-network-hits.sh clean (146 annotated hits, rc 0), obs_test 434/0/0, remove_test 352/0/0, network_hits_test 59/0/0.
Gates at 4d37f61 (TN_UPSTREAM_ALLOY_CONFIG set): bash 5.3 obs 434/0/0, remove 313/0/0, root_write_pipe 2/0, passphrase_print 4/0; bash:3.2 obs 427/0/4 skipped, 313, 2, 4; ubuntu:24.04 obs 427/0/4 skipped, 313, 2, 4. bash -n both, check-bash32, shellcheck 0.11 + v0.9.0, perl lint: clean. systemd-analyze verify: ok. Sync-note diff empty, sha256 unchanged 4c1527db...53a3. Full suite bash 5.3: 59 files, 0 failed.

## Operator-visible changes
- The hub ingest token is in /etc/telcoin/alloy/ingest-token (root:telcoin-alloy 0640, one line), never in telcoin-alloy.env, the unit text, argv, Alloy's environment or `docker inspect`.
- Both push endpoints read the token with bearer_token_file and pin TLS 1.3 with the push URL's host as server name.
- Native unit: LoadCredential=ingest-token:/etc/telcoin/alloy/ingest-token, LimitCORE=0, InaccessiblePaths names /etc/telcoin/bls-passphrase.cred (the stale /etc/credstore.encrypted is gone).
- Docker sidecar: the token file is bind-mounted read-only (--mount ...,readonly) at /run/credentials/telcoin-alloy/ingest-token, --group-add <gid of telcoin-alloy>, --ulimit core=0, unit LimitCORE=0; the unit is now written with tn_write_root_file. The telcoin-alloy system account is created on docker installs too (its group owns the token file).
- A host still on the env-file token is migrated the next time Alloy's files are rendered (enable, a partial disable, --rotate-token), with one message. Until then it keeps working on the old files; obs_status warns.
- New: setup-observability.sh --rotate-token (stdin, --token, TN_OBS_TOKEN, a hidden prompt on a terminal; menu entry 8; --json). Restarts Alloy only, checks it stays active, rolls back on failure (rc 1).
- obs_disable (menu "Disable" of the last pipeline, --disable-* when the other is off) shreds the token file: enabling again asks for the token. remove-node shreds the token file and telcoin-alloy.env.
- obs_status (setup-observability "Show status", check-node.sh) has a token line.
- The partial disables now also rewrite telcoin-alloy.env and the unit (same render as enable).

## Docs notes
Paths and modes:
- /etc/telcoin/alloy/ingest-token: root:telcoin-alloy 0640, one line, the token. NEW.
- /etc/telcoin/alloy/telcoin-alloy.env: root 0600 (unchanged mode), no token any more.
- /etc/telcoin/alloy/config.alloy: unchanged owner/mode (native root:telcoin-alloy 0640, docker root:root 0640).
- Native: Alloy reads the token at $CREDENTIALS_DIRECTORY/ingest-token (systemd: /run/credentials/telcoin-alloy.service/ingest-token) via `LoadCredential=ingest-token:/etc/telcoin/alloy/ingest-token`; unit has `LimitCORE=0`; `InaccessiblePaths=-/var/lib/telcoin -/etc/telcoin/bls-passphrase.cred -/etc/telcoin/bls-passphrase [-<data dir>]`.
- Docker: `--mount type=bind,source=/etc/telcoin/alloy/ingest-token,target=/run/credentials/telcoin-alloy/ingest-token,readonly`, `--group-add <gid of telcoin-alloy>`, `--ulimit core=0`, unit `LimitCORE=0`; env file sets `CREDENTIALS_DIRECTORY=/run/credentials/telcoin-alloy`. (The image grafana/alloy:v1.5.1 runs as uid 0 with every capability dropped and reads the root-owned file as owner; --group-add also covers an image that runs as its alloy user 473.)
Env file variables:
- Before: TN_NODE TN_REGION TN_VALIDATOR_ADDRESS TN_CHAIN TN_IMAGE_VERSION OBS_PUSH_URL OBS_INGEST_TOKEN [+ TN_METRICS_ADDR OBS_METRICS_PUSH_URL with metrics].
- After: TN_NODE TN_REGION TN_VALIDATOR_ADDRESS TN_CHAIN TN_IMAGE_VERSION OBS_PUSH_URL OBS_PUSH_HOST [+ TN_METRICS_ADDR OBS_METRICS_PUSH_URL OBS_METRICS_PUSH_HOST with metrics] [+ CREDENTIALS_DIRECTORY=/run/credentials/telcoin-alloy on docker only]. OBS_PUSH_HOST / OBS_METRICS_PUSH_HOST = host of the effective push URL (scheme, user, port, path dropped).
Migration message (once per run, when the old env file still had OBS_INGEST_TOKEN=):
- "/etc/telcoin/alloy/telcoin-alloy.env no longer holds the ingest token: it is in /etc/telcoin/alloy/ingest-token (root:telcoin-alloy 0640), which Alloy reads as a file, not from its environment."
- Triggered by an enable, a partial disable (logs or metrics alone) or --rotate-token. After update-scripts, an existing host stays on the env-file token until one of those runs; obs_status says "The ingest token is still in /etc/telcoin/alloy/telcoin-alloy.env; run setup-observability.sh --rotate-token (the same token is fine) to move it into /etc/telcoin/alloy/ingest-token."
--rotate-token usage:
- `printf '%s\n' "$NEW_TOKEN" | sudo bash setup-observability.sh --rotate-token --token-stdin` (stdin form, preferred)
- `sudo bash setup-observability.sh --rotate-token` asks for the token hidden when stdin is a terminal; refuses ("--rotate-token needs the new token: pipe it in with --token-stdin, or run this from a terminal to type it. Nothing was changed.") otherwise. `--token VALUE` (warns it is on the command line) and `TN_OBS_TOKEN` also work; the stored token is never reused.
- `... --json --rotate-token --token-stdin`: done `{"event":"done","ok":true,"applied":["token:rotated"],...}`; failure: error event "the ingest token was not rotated: <reason>" then done ok:false. Reasons include "telcoin-alloy.service did not stay running on the new token; the previous token was put back and Alloy runs on it again".
- Menu: "8) Rotate the ingest token (Alloy restarts, the node does not)"; Exit is now 9 ("Enter choice [1-9]").
- Cannot be combined with --enable-*/--disable-* ("--rotate-token runs on its own; run the enable or disable separately."). --token-stdin now goes with --json or --rotate-token.
- Behaviour: writes the token file, re-renders config.alloy, env file and unit (migrates an env-file token), restarts Alloy only (no committee guard or epoch wait: the node is not restarted), checks it stays active for OBS_ALLOY_SETTLE_SECS (5) reads; on failure puts back the token file, env file, config.alloy and unit as they were, restarts Alloy, exit 1. Refuses (nothing changed) when both pipelines are off or the unit is not installed. A wrong token keeps Alloy running (the hub answers 401): check the shipping counters in "Show status".
Status line (obs_status, so also check-node.sh):
- OK: "Ingest token file present (0640 root:telcoin-alloy): /etc/telcoin/alloy/ingest-token"
- WARN: "Ingest token file <f> is <mode> <owner>:<group>, not 0640 root:telcoin-alloy; run setup-observability.sh --rotate-token to write it again."; the env-file line above; "No ingest token file at <f>, so Alloy cannot authenticate to the hub; run setup-observability.sh --rotate-token."
- INFO without sudo: "Ingest token file not checked: /etc/telcoin/alloy is closed to this account (run this with sudo)."
Disable/remove:
- Full disable shreds the token file (and an env file that still holds the token): "The ingest token file was shredded; enabling logs or metrics again asks for the token."
- remove-node shreds /etc/telcoin/alloy/ingest-token and /etc/telcoin/alloy/telcoin-alloy.env before removing /etc/telcoin/alloy.
TLS pin: both endpoints `tls_config { server_name = sys.env("OBS_PUSH_HOST") | sys.env("OBS_METRICS_PUSH_HOST"), min_version = "TLS13" }`; obs.adiri.telcoin.network negotiates TLSv1.3 (checked 2026-11-03).
Sync note:
- `sha256(observability/config.alloy) = 4c1527db28863dc85f2e5a8f06119ebf8eac731d879038e455e17efbac5453a3` (was 3ed01c5d...426b4).
- Upstream: deploy-networks-common branch `alloy-token-file-tls` commit 30a2813a7af82aea77833f28f1d7fc07147b35c0 (from origin/main dc57dfe), NOT pushed; vendored header says "Vendored from upstream branch alloy-token-file-tls 30a2813, pending merge." Update the header line and the sha line once it merges.
- obs_test.sh runs the sync-note diff when TN_UPSTREAM_ALLOY_CONFIG names the upstream file.
- docs/testnet-addons.md:208 still names /etc/credstore.encrypted (DOCS).
Follow-up docs notes (V3):
- Push URLs: with no --push-url / --metrics-push-url (OBS_PUSH_URL / OBS_METRICS_PUSH_URL) on the run, the URL already in telcoin-alloy.env is kept (an operator's own hub, a devnet hub); to go back to the default hub, pass --push-url / --metrics-push-url with the default URL. A render that would leave an enabled pipeline with no URL is refused before anything is written: "There is no logs push URL for network '<net>', so Alloy would ship the logs nowhere. Pass --push-url to setup-observability.sh (or set OBS_PUSH_URL); nothing was written." (metrics: "--metrics-push-url", "OBS_METRICS_PUSH_URL"). --rotate-token refuses it with nothing changed.
- Full disable when the token file cannot be deleted: "Could not delete <file>, which still holds the ingest token; remove it by hand (sudo shred -u <file>)." rc 1; a --json disable ends done ok:false ("disabling log shipping did not finish (see server logs)").
- Status with both pipelines off and no token file (INFO): "No ingest token file: log and metrics shipping are off, and enabling either asks for the token." With both off and the token still in the env file (WARN): "... although log and metrics shipping are off; delete it (sudo shred -u <env file>), or enable logs or metrics again, which moves it into <token file>."
- Docker config.alloy is now root:telcoin-alloy 0640 (was root:root 0640), like native and like the token file.
- After "Ingest token rotated": "Check that it ships: a wrong token keeps Alloy running while the hub refuses every push. In a minute, journalctl -u telcoin-alloy.service -n 20 shows no 401, and these counters grow:" then "logs: curl -s 127.0.0.1:12345/metrics | grep loki_write_sent_bytes_total" and/or "metrics: ... | grep prometheus_remote_storage_samples_total".
- A --rotate-token interrupted after the token write and before the restart leaves the new token and the re-rendered files in place with no rollback (Alloy keeps running on the old ones until it restarts): re-run --rotate-token (with the new or the old token). An interruption during the token write itself leaves nothing behind (the EXIT trap removes the temp copy).
- The menu, --rotate-token and --json runs end on TERM/INT/HUP with 143/130/129 after removing an interrupted write and releasing the update lock.

Round-3 docs notes (push URL override):
- Set an override: `--push-url URL` / `--metrics-push-url URL` (or OBS_PUSH_URL / OBS_METRICS_PUSH_URL) on an enable or a --rotate-token run. It is recorded in /etc/telcoin/alloy/telcoin-alloy.env as `OBS_PUSH_URL_SOURCE=override` / `OBS_METRICS_PUSH_URL_SOURCE=override` (the marker holds only the word "override") and kept by every later render (rotate, partial disable, the other pipeline's enable) until changed.
- Clear it: `--push-url default` / `--metrics-push-url default` (I chose the word; re-enabling without the flag keeps the override). The URL then follows the release default.
- Without an override the URL follows the release default (OBS_PUSH_URL_TESTNET / OBS_METRICS_PUSH_URL_TESTNET from lib/testnet-addons.env, devnet: OBS_*_PUSH_URL_DEVNET): a default that a script release changes reaches the host at the next render (enable, partial disable, --rotate-token), with "The logs push URL follows the release default: <new> (was <old>). Pass --push-url to setup-observability.sh to ship somewhere else." (metrics: --metrics-push-url). A new override says "The logs push URL is now <new> (set with --push-url; was <old>)."
- Migration: an env file from 2.0.x has no marker, so its URL counts as the default: a 2.0.x install that had its own hub moves to the release default at the next render, with the line above; run with --push-url again to keep the own hub. On devnet (no default) the render is refused with the "There is no logs push URL ..." message instead.
- Disabling a pipeline drops its URL lines, so its override is forgotten; pass the flag again when re-enabling it.

Remainder of #35: one shared ingest token for every operator; per-node tokens (and revoking one operator) need the hub's Caddy to check a per-node token list instead of the single OBS_INGEST_TOKEN for /loki/api/v1/push and /api/v1/write. Not done here.

## Tests run
Commits on fup/OBS (base 6cbf52e): db0d15c config.alloy, 5fb0bf1 lib, 817e76d setup-observability, a89b459 remove-node, 1178da3 tests, faedcb8 lib (status when the dir is closed), 6d08cef tests.
- obs_test.sh + remove_test.sh, final tree, TN_UPSTREAM_ALLOY_CONFIG set (upstream file mounted read-only in the containers):
  - bash 5.3.9 host: obs 350 checks 0 failures 0 skipped; remove 313/0/0.
  - bash:3.2 (3.2.57, busybox, root): obs 345/0/3 skipped (2 systemd-analyze verify: no systemd-analyze; closed-dir status: root); remove 313/0/0.
  - ubuntu:24.04 (bash 5.2.21, root): obs 345/0/3 skipped (same three); remove 313/0/0.
  - Without TN_UPSTREAM_ALLOY_CONFIG the sync-note check SKIPs (one more skip).
- bash -n under host bash 5.3 and bash:3.2 on lib/observability.sh setup-observability.sh remove-node.sh tools/tests/obs_test.sh tools/tests/remove_test.sh: clean.
- tools/check-bash32.sh on the same 5 files: clean.
- shellcheck -x --severity=error: host 0.11.0 clean; koalaman/shellcheck:v0.9.0 clean.
- tools/check-perl-interp.sh on every tracked *.sh: clean (100 files).
- bash tools/tests/run.sh tools/tests/root_write_pipe_test.sh tools/tests/passphrase_print_test.sh: 2 files, 0 failed.
- systemd-analyze verify (systemd 259) on the rendered native unit and docker sidecar unit: rc 0, no line about telcoin-alloy.service (in obs_test.sh on the host, plus by hand); negative control: a misspelt key is reported against telcoin-alloy.service.
- Sync-note diff `diff <(sed -n '/^local\.file_match/,$p' ~/coding/telcoin/adiri-genesis/common/observability/node-agent/config.alloy) <(sed -n '/^local\.file_match/,$p' observability/config.alloy)`: empty.
- `alloy fmt` (grafana/alloy:v1.5.1) on the upstream and the vendored file: output identical to input.
- Real image grafana/alloy:v1.5.1: token readability matrix and `alloy run` results under S0/S2 progress notes above.
- Full suite bash 5.3: first run 59 files, 1 failed (obs_test.sh "status without access to the Alloy dir"): a race, I edited lib + test while it ran; re-run on the final tree (no edits during the run): FULL-SUITE 59 test file(s), 0 failed (bash 5.3.9).

Follow-up gates (tip ed35f48):
- obs_test.sh / remove_test.sh / root_write_pipe_test.sh / passphrase_print_test.sh with TN_UPSTREAM_ALLOY_CONFIG: bash 5.3 host 403/0/0, 313/0/0, 2/0/0, 4/0/0; bash:3.2 396/0/4 skipped, 313, 2, 4; ubuntu:24.04 396/0/4 skipped, 313, 2, 4. Skips in containers: the two systemd-analyze verify checks (no systemd-analyze), the closed-dir status and the read-only-dir disable cases (root).
- bash -n under bash 5.3 and bash:3.2 on the 5 touched .sh: clean. check-bash32: clean. shellcheck --severity=error 0.11 and v0.9.0: clean. perl lint: clean (100 files). systemd-analyze verify native + docker units: ok (inside obs_test on the host). Sync-note diff: empty; sha256(observability/config.alloy) unchanged 4c1527db...53a3.
- Full suite bash 5.3: 59 test file(s), 0 failed.

## Open issues
0. (follow-up) The six lib commits 676faaa..6c15251 need their messages amended at cherry-pick (amend files listed above). Lesson for tasks/lessons.md (orchestrator): never chain `git commit -F - <<'MSG' && \` (the continuation makes the heredoc's first line part of the command line); write the message to a file and `git commit -F file`, and always leave a blank line after the subject.
1. Upstream consumers of node-agent/config.alloy not updated (spec scoped the upstream commit to config.alloy): common/observability/node-agent/docker-compose.yml still passes OBS_INGEST_TOKEN in `environment:` with no token mount, CREDENTIALS_DIRECTORY or OBS_*_PUSH_HOST, so a compose self-host on the new config fails every push ("unable to read authorization credentials"). Suggested addition to the upstream PR: drop `OBS_INGEST_TOKEN: ${OBS_INGEST_TOKEN}`; add `OBS_PUSH_HOST: ${OBS_PUSH_HOST}`, `OBS_METRICS_PUSH_HOST: ${OBS_METRICS_PUSH_HOST}`, `CREDENTIALS_DIRECTORY: /run/credentials/alloy`, volume `- ${OBS_TOKEN_FILE:-./ingest-token}:/run/credentials/alloy/ingest-token:ro`; update its .env example header. The file's header also says start-validator-node.sh embeds a byte-identical heredoc: adiri-genesis start-validator-node.sh / start-observer-node.sh (outside the submodule) still use bearer_token = sys.env("OBS_INGEST_TOKEN") and `-e OBS_INGEST_TOKEN`; they keep working on their own copy but are no longer byte-identical.
2. ~/coding/telcoin/adiri-genesis/common is now checked out on alloy-token-file-tls (30a2813, ahead of origin/main by 1, not pushed); the parent adiri-genesis shows ` M common`. The earlier branch wgvpn-sudoers-guard (9b2c8f2) is untouched. Switching the submodule back is the orchestrator's/user's call.
3. Release prep (orchestrator): config.alloy changed, so the sync note asks for an OBSERVABILITY_VERSION bump with it; not done here (no version bumps).
4. DOCS: docs/testnet-addons.md sync-note sha line and the /etc/credstore.encrypted mention (:208); the header line "Vendored from upstream branch alloy-token-file-tls 30a2813, pending merge." in observability/config.alloy needs the merged sha once upstream merges (an observability/config.alloy header edit then, not a functional change).
5. Behaviour changes to call out: a full disable now shreds the token (re-enable asks for it again; spec-required); the partial disables now also rewrite telcoin-alloy.env and the unit (needed so a partial disable on a host still on the env-file token does not render a token-file config beside an env-file unit, which would ship nothing while Alloy stays active); menu Exit moved from 8 to 9.
6. A host updated with update-scripts keeps the token in telcoin-alloy.env until an enable, a partial disable or --rotate-token runs (nothing re-renders Alloy on update). obs_status warns. DOCS should tell operators to run `--rotate-token` with the same token after updating.
7. Not in scope, noted: the UI has no rotate action; per-node hub tokens (#35 remainder) need hub-side Caddy changes.

## Spec vs code (found wrong or incomplete)
- "image user 473:473": grafana/alloy:v1.5.1 has no USER (Config.User empty), so it runs as uid 0; 473:473 only owns /var/lib/alloy. With --cap-drop=ALL uid 0 reads the root-owned 0640 file as its owner. --group-add is kept so an image that switches to user 473 still reads it (proved: --user 473:473 needs --group-add; without it, Permission denied). No --user fallback was needed.
- `-v <file>:...:ro` creates a directory at the host path when the token file is missing (then tn_write_root_file refuses it); used `--mount type=bind,...,readonly`, which fails the start instead (proved).
- LimitCORE=0 on the sidecar unit only limits the docker client; added `--ulimit core=0` for the container (proved `ulimit -c` = 0).
- obs_run_alloy_docker wrote its unit with `cat > /etc/systemd/system/...` (not tn_write_root_file, not under TN_ROOT_PREFIX) and obs_enable ignored its rc; _obs_write_env_file wrote with `>` in a umask subshell. Both now go through tn_write_root_file with checked rc.
- obs_alloy_account ran on native installs only, so a docker host had no telcoin-alloy group for root:telcoin-alloy; it now runs on both (also in obs_render_alloy and obs_rotate_token).
- `_rm_shred` exists only in remove-node.sh; obs_disable uses `_tn_shred` from lib/common.sh.
- remove_test.sh stubs remove_testnet_addons (remove_addons_test.sh owns it); the OBS block evals the real function from the sourced copy.
- The upstream file has other consumers (docker-compose.yml, start-*-node.sh heredocs): see Open issue 1.
- Line anchors were approximate but all found (obs_write_config_alloy, _obs_alloy_fallback, _obs_write_env_file, obs_alloy_unit_text InaccessiblePaths, obs_run_alloy_docker, obs_existing_token; setup-observability token parsing and main_menu; config.alloy endpoint blocks; remove-node _rm_shred and the alloy teardown).
