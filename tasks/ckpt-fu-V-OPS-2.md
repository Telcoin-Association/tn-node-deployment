status: done

# V-OPS-2 checkpoint

Harness dir: /private/tmp/claude-501/-Users-grant-coding-telcoin-tn-node-deployment/eddb430f-f0dc-43fe-9180-65cd421b1e88/scratchpad/vops2-tests/

## Plan
Fan-out (forks, each with its own checkpoint and harness subdir):
- V-OPS-2-cn  item 1 check-node  -> tasks/ckpt-fu-V-OPS-2-cn.md,  vops2-tests/cn/
- V-OPS-2-fw  item 2 firewall    -> tasks/ckpt-fu-V-OPS-2-fw.md,  vops2-tests/fw/
- V-OPS-2-obs item 3 observability -> tasks/ckpt-fu-V-OPS-2-obs.md, vops2-tests/obs/
- V-OPS-2-ps  item 4 prepare-stake -> tasks/ckpt-fu-V-OPS-2-ps.md, vops2-tests/ps/
Each fork also does item 6 (implementers' tests) and item 7 (prose) for its own script.
Me: item 5 static/boundary on all five; merge; re-check every `error` finding.

Baselines (pinned): pre-L1 lib fb5f6cd (common 1.4.0, fallback 1.0.2); L1 lib 1e2d2f1 (1.5.0);
L2 lib d1593ae (1.6.0); HEAD lib ea86e22 (1.6.0). firewall baseline d1593ae (1.5.2);
observability baseline 8185d00 = 5eb98b4^ (setup-observability 1.2.0, lib/observability 1.0.1);
check-node baseline c7a9690^ (1.1.55).

## Completed sections
- [x] read shared/ops/core specs + lessons
- [x] spawn forks (cn, fw, obs, ps launched 2026-10-02)
- [x] item 5 static (me)
- [x] collect fork reports (cn [x], fw [x], obs [x], ps [x])

## ps fork report (done; harness vops2-tests/ps/)
- No errors. F0 warn: SIGTERM to the script during `generate pop` -> done `{"ok":true,"exit":0,"state":"error"}`
  (code=$? in EXIT trap), keytool child keeps running and rewrites node-info after the lock is released;
  .node-meta keeps old address; no restart. I re-ran t_sig.sh under bash 5: SIGTERM json ok:true exit 0,
  node-info=CHANGED, meta_has_new=0; SIGINT (group) ok:false exit 130 in my run (fork saw ok:true on 5.3 once).
- F1 warn: CRLF .node-meta -> `NETWORK=testnet\r … is not testnet, mainnet or devnet`, exit 1 (meta_get keeps CR).
- F2 warn = my M1 (--private-key "$VALIDATOR_KEY" guidance).
- Notes: N1 balance short exits 3 not-ready (documented); N2 spec says python3 for 256-bit, code uses pure bash
  limbs + bash Keccak (verified vs python/cast on 273 vectors) -> fix spec; N3 rotation re-suggests the running
  command; N4 keytool stderr cut mid-word at 300 chars + stray space.
- Value flags with no value: I checked -> exit 1, "[ERROR] --network-rpc needs a value", JSON done ok:false.
- Held lock -> 3 (mkdir and flock), stale lock taken, foreign lock untouched: fork PASS.
- Counts: t_ps 108/110 per bash (2 = F1); implementer t_d 260/260, t_rot 215/215, t_units 13/13 per bash.

## cn fork report (done; harness vops2-tests/cn/, `bash t_cn.sh <bash> [regex]`)
- F1 warn (pre-existing 1.1.55, now reachable): fetch_consensus_header python reads sub_dag.reputation_score;
  live key is reputation_scores (I re-checked live: sub_dag keys commit_timestamp, headers, randomness,
  reputation_scores{final_of_schedule,scores_per_authority}). Reputation line never prints. Implementer shim
  uses the singular key.
- F2 (I re-ran: reproduced under /bin/bash): .node-meta VALIDATOR_ADDRESS vs node-info mismatch WARN sits in
  report_epoch_committee after early returns -> missing offline/--no-network and when network
  tn_getCurrentEpochInfo fails; on that path stake_status_for_rule uses VALIDATOR_ADDRESS (.node-meta) ->
  "[ERROR] NOT in recent headers, and committee membership is unknown (...); the registry has this node as
  Active" for a node whose own address has no record. My rating: error (narrow; two faults). Fix: mismatch
  check right after resolve_identity; rule uses EXEC_ADDR's status.
- Notes: F3 wrong-chain path says "network RPC unreachable"; F4 `all` in --http.api only enables
  eth,net,web3,rpc on v0.15.0 (all,<x> ignores the rest); F5 "committee N" = distinct authors of the latest
  commit (4 vs 5 live); F6 pre-L1 says "no tn_info answer" when never asked; F7 workers ERROR / Observer WARN /
  mismatch WARN lack the "what to do".
- Live: epoch 581, 0x0033… member E..E+2, numWorkers 1, status 3, activation 0 — matches cast.
- Counts: t_cn.sh 423/428 per bash (5 = F1/F2 repros); ws 6/6; sig 3/3; implementer t_b.sh 493/493 and
  t_ws.sh 7/7 per bash.

## obs fork report (done; harness vops2-tests/obs/)
- No errors. W1 (pre-existing 8185d00): obs_status `sent=$(… | grep -E '^loki_write_sent_bytes_total' | awk …)`
  dies under set -e/pipefail when Alloy /metrics is empty -> show_status exits rc 1 after "[OK] alloy active";
  same for samples. Fix single awk. (check-node calls obs_status || true.)
- W2 (pre-existing): `--json --enable-logs --token` (value flag last; also --region/--push-url/--metrics-push-url)
  -> shift 2 fails before run_json_mode's trap -> rc 1, empty stdout, no done.
- Notes: rc1 branch contradictory lines when flag in trailing comment; json_fail_flags/json_need_node prose
  ("needs the change in the error event"; "Nothing was changed" false after earlier --disable); rc3 message
  says "FLAGS are not single shell words" and echoes METRICS_PORT=9101;id (validate port); interactive
  enable_health with no node still writes meta (deliberate per ckpt-fu-C; comment says otherwise); obs_enable
  rewrites Alloy before the flag check; --enable-logs --enable-metrics = 2 obs_enable calls/2 node restarts;
  soft-guard warnings only on stderr in --json; health warn says plain `systemctl restart telcoin`.
- Docker log dir: unified install w/o DATA_DIR now /var/lib/telcoin/logs (8185d00 used …/validator/logs).
- Counts: t_v.sh 153/153 per bash; implementer t_obs.sh 144/144 per bash.

## fw fork report (done; harness vops2-tests/fw/, baseline sha 3c7c152a…5119)
- No errors. F1 warn (pre-existing d1593ae): `--json --enable` with a failing `ufw allow` (22/tcp, 49594/udp,
  49595/udp, 80/tcp) exits rc 1, empty stdout, no error/done event (set -e inside the loop, &>/dev/null);
  interactive exits silently. Stops before enable (holds). Fix: EXIT trap emitting done ok:false; error line.
- F2 note (pre-existing): json_fw_status `default_in=` pipeline dies when `ufw status verbose` fails -> empty
  stdout rc 1; view prints empty default policy. Fix `|| true` + "unknown".
- F3 note prose: "Kept TCP 80/443 open" printed on plain enable where just added -> "Allowed".
- F4 note: --json --status single object no done (pre-existing, UI contract); p2p_ports lists defaults with
  allowed:false when no node.
- Library note: ufw_active = `ufw status | grep -q` under pipefail can SIGPIPE with chunked writers.
- Counts: t_p2p 116/116, adversarial 40/40, legacy 2/2, t_enable 60/68 (8 = F1), t_json 244/244, t_view 54/54,
  t_prel1 74/74; implementer t_fw.sh 124/124 under both bashes.
- [x] re-check error/borderline findings (cn F1 live, cn F2 rerun, ps F0 rerun under bash 5, ps value flags)
- [x] final report (handed back)

## Item 5 results (me)
- bash -n under /bin/bash 3.2.57 and bash 5.3: rc 0 for all five.
- shellcheck -x --severity=error: rc 0. At warning level only pre-existing SC2206 (firewall, also in d1593ae)
  and SC2034 (setup-observability OBS_PUSH_URL/OBS_METRICS_PUSH_URL, lib/observability OBSERVABILITY_VERSION).
- /bin/bash tools/check-bash32.sh (working tree) on the five + lib/common.sh + lib/fallback.sh: clean, rc 0.
- Boundary: only firewall-setup.sh comment naming common/config-caddy.sh, marked maintainer-only (allowed).
- --observer/--validator: check-node accepts them as ignored CLI flags with a note; warns about a leftover
  --observer in the launch file. Nothing emitted to the binary.
- prepare-stake private key: only in printed guidance (ps_print_key_note).

## Findings so far
- M1 (warn, prepare-stake ps_print_key_note): suggests `--private-key "$VALIDATOR_KEY"` and says "Never write
  the key itself on the command line"; the expanded key is still in cast's argv (visible to `ps` on that
  machine). cast 1.5.1 has no env var for --private-key. Suggest recommending --account (cast wallet import,
  encrypted keystore) / --interactive / --ledger, and dropping --private-key or stating the argv exposure.
