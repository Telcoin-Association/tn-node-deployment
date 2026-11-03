# ckpt-verify-V3
status: done

## Sections
- [x] S1 read specs, AGENTS.md, lessons, OBS diff
- [x] S2 harness written (tasks/verify-fup/V3/: v3_obs_lib_test.sh, v3_obs_e2e_test.sh, v3_obs_skew_test.sh, run.sh)
- [x] S3 harness run: bash 5.3 / bash:3.2 / ubuntu:24.04 (run.sh; lib 211/210/210, skew 13+, e2e 79; FAILs = findings)
- [x] S4 systemd-analyze verify on rendered units (records/systemd-analyze.txt: native rc 0 with /usr/bin/true, docker rc 0; native as rendered only lacks /usr/bin/alloy on this host)
- [x] S5 real-image proof (records/real-image.txt: fmt rc0 x3; R0 473+group-add cannot read config root:root 0640; R1 473 no group-add: token permission denied, Alloy keeps running; R2/R3 Bearer token over TLSv1.3 with server_name obs.test; R4 TLS1.2 hub: protocol version not supported; 0 token lines in logs/inspect)
- [x] S6 mutation run (records/mutations.txt, consistent baseline 19:13Z: 37 of 38 killed; M20 equivalent)
- [x] S7 compare implementer checkpoint + docs notes (claims match: sha 4c1527db..., 30a2813, counts 350/345/345, image uid 0, --mount missing source, hub TLS1.3; docs-note correction: "--group-add also covers an image that runs as 473" false end to end (config root:root 0640); docs omit push-URL loss)
- [x] S8 gate cross-check (records/gate-*.log, gate-lints.txt): obs 350/345/345, remove 313x3, pipe 2, passphrase 4, all rc 0; bash -n 5.3+3.2, check-bash32, shellcheck 0.11+0.9 error, perl lint clean
- [x] S9 commit fixtures/records (0a4a497 on verify/V3, tasks/verify-fup/V3 only, no trailers)

## Notes
- S1 leads to test: push-URL override not persisted -> rotate/partial disable rewrite env file from current env (OBS_PUSH_URL lost);
  CLI rotate path has no EXIT trap calling tn_remove_inflight_tmp (only lock release); snapshot strips trailing newlines;
  rotate refusal (no token, non-tty) happens after so_write_begin; settle check cannot detect a bad token.
- S2/S3 first results (lib 211 checks bash5.3, 4 FAIL = findings): push URL override lost on rotate (devnet -> empty URL) and on partial disable (testnet override -> adiri);
  snapshot/restore drops/adds trailing newline. e2e: CLI SIGTERM during token temp write leaves .tn.* with the new token (json path cleans);
  ro dir: obs_disable says "shredded" but token remains (json ok:true); ro rotate prints "Could not put X back" for unchanged files.
  json_on_exit says rc=0 after SIGTERM (pre-existing).
- S5 run 1 harness bugs (config 0640 owned by me; shared data dir) fixed; R1 (473 no group-add): token refused, container keeps running; R2 with group-add: readable.
  R0: 473 + group-add cannot read config.alloy root:root 0640 (comment overstates --group-add).
- Alloy 1.5.1 with OBS_METRICS_PUSH_URL empty stays running (records/real-image-empty-url.txt): devnet rotate without --push-url "succeeds" shipping nowhere.
- Mutation M20 (said every time) survives: equivalent mutant (after the first rewrite the env holds no token, so a second call never sees legacy).
- New finding: status after a full disable says "run --rotate-token", which refuses with both pipelines off (records/status-after-disable.txt).
- Harness edited while mutate.sh ran (e2e E14 check, lib status check): rerun mutate.sh at the end for a consistent baseline.

## Findings (draft, each reproduced)
ERROR
- F1 _obs_write_env_file via obs_render_alloy (rotate, partial disables): push URL override not persisted -> devnet rotate writes OBS_PUSH_URL= (Alloy stays active, ships nowhere); testnet override reverts to adiri hub (token to another hub). lib checks "devnet override: rotate keeps OBS_PUSH_URL", "testnet override: partial disable keeps OBS_PUSH_URL".
WARN
- F2 setup-observability CLI/menu: no EXIT trap with tn_remove_inflight_tmp; SIGTERM during token temp write leaves .tn.* 0600 holding the new token (E13 cli). json path clean.
- F3 obs_disable says "shredded" when the token file stays (ro dir), --json ok:true (E14).
- F4 _obs_restore after a failed first write rewrites unchanged files; ro dir prints "Could not put X back" x3, OBS_ROTATE_MSG says a file could not be put back (E14).
- F5 _obs_token_status after a full disable advises --rotate-token, which refuses (status-after-disable.txt).
NOTE
- N1 docs/comment: --group-add covers a 473 image -> false end to end, docker config.alloy root:root 0640 unreadable (R0).
- N2 _obs_snapshot $(cat) drops trailing newlines; restore adds one (rollback fidelity).
- N3 settle check blind to unreadable/wrong token (R1: Alloy running, "unable to read authorization credentials"); success message could say so.
- N4 interrupted rotate (E12) leaves new token + renders, no rollback/report (consistent).
- N5 pre-existing: json_on_exit "rc=0" after SIGTERM; gate prints 2 blank lines on --json stdout.
- N6 remove-node.sh:1664 comment "mode-600 ingest token" stale.
- Final run.sh (V3_CLAIMED_SHA set): lib 213/5F/0S bash5.3, 212/5F/1S bash3.2 + ubuntu; skew 15/2F x3; e2e ubuntu 80/3F; every FAIL = a finding. Mutation rerun in progress.
