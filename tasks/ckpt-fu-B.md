status: done

# Package B — check-node.sh 1.2.0 (C.2)

Owner file: check-node.sh only (`SCRIPT_VERSION` 1.2.0). No other repo file edited. Tests live
in the scratchpad under `b-tests/` (`t_b.sh`, `t_ws.sh`, `wsstub.py`, `shims/`, `fx/`,
`hook.sh`, `oldlib/`, `live/`, `live-cmp/`).

## Sections
- [x] 1. Network: .node-meta NETWORK -> expected chain id + comparison RPC; --network-rpc wins; unknown accepts any known id; wrong-chain endpoint -> WARN and skip (resolve_network, check_network_chain)
- [x] 2. Authority id from tn_info, fallback --authority-id; say where it came from (resolve_identity)
- [x] 3. Committee logic: on-chain membership main test; ERROR / info / unknown rules (report_participation)
- [x] 4. Epoch section: id, next boundary (UTC, macOS + Linux date), activation + earliest seat, E/E+1/E+2, Observer-in-committee WARN; print_validator_onchain_status with current epoch; rc-2 reason (report_epoch_committee)
- [x] 5. Worker count: numWorkers() vs local; per-worker probes only when >1 local worker (report_worker_count, probe_worker_rpcs)
- [x] 6. macOS: df -Pk parser (df_line), /proc/meminfo optional (TN_PROC_MEMINFO), tn_physical_cores CPU line
- [x] 7. wss probe: background curl -D tmp + poll + kill (ws_upgrade_status)
- [x] 8. Public node warnings: stale RPC block (rpc_block_check), unsafe api namespaces (risky_api_modules); runner, bootstrap/state-export flags, advertised RPC, P2P ports (report_node_config)
- [x] 9. Soft guards (have_fns + one header warning via version_gte 1.6.0); explicit exit 0; no --observer/--validator emitted
- [x] 10. Tests (C.5) under /bin/bash and bash; bash -n, shellcheck, check-bash32
      - [x] 10a. shim suite b-tests/t_b.sh: 424/424 under /bin/bash 3.2 and bash 5
      - [x] 10b. wss probe timing (b-tests/t_ws.sh, real curl, wsstub.py): 7/7 both bashes
      - [x] 10c. fully real run under /bin/bash (no shims, live rpc.adiri.tel) reaches the summary, rc 0, 2 s
      - [x] 10d. live comparison with cast: all values match
- [x] 11. Closing headings

## Notes

Design decisions:
- The local RPC probe moved before the report header (silent; §2 renders it), because when
  .node-meta does not name the network, the local chain id picks the network RPC.
- resolve_network: NODE_NETWORK from .node-meta NETWORK; when missing, unreadable or not
  testnet/mainnet/devnet, a Telcoin local chain id stands in ("from the local chain id");
  with neither, any Telcoin chain id is accepted. NETWORK_RPC = --network-rpc, else the
  network's RPC constant, else TESTNET_RPC_URL. DEFAULT_NETWORK_RPC is gone.
- check_network_chain (§3): eth_chainId of the network RPC; a different chain id than
  expected is a WARN, sets NETWORK_WRONG_CHAIN and skips §3's consensus probe and §5's
  network EVM read (and its "could not read" warning); not a health issue; the summary
  banner names it.
- resolve_identity: tn_info on the local RPC gives AUTH_ID (else --authority-id) and
  EXEC_ADDR (else node-info.yaml execution_address, else VALIDATOR_ADDRESS). The node's own
  id wins over the flag; a differing flag gets an info line. VALIDATOR_ADDRESS falls back to
  EXEC_ADDR when neither --address nor .node-meta gave one. detect_authority_id (read
  primary_network_key, the libp2p key) is gone.
- §5.5 (new, between §5 and §6): reads through the network RPC when NETWORK_OK, else the
  local node (labelled "local node"). IN_COMMITTEE is yes/no only from the network RPC.
  Worker count lives here too.
- §6 headers: the network's latest commit, else the local node's (network down, wrong chain
  or --no-network); the summary banner lists §6 as skipped only when it did not run.
  Unknown membership: status (network read, else a lazy read through the local node) 3 or 4
  and mode not Observer -> ERROR; 3/4 with Observer -> WARN; status unknown -> WARN; a
  known status that cannot hold a seat (none, 0, 1, 2, 5, 6) -> info "expected". The last
  rule is a deliberate refinement of the spec's "otherwise WARN": a node the registry rules
  out cannot be in the committee, so a warning would be noise.
- Extra (small): a WARN in §5.5 when .node-meta VALIDATOR_ADDRESS differs from the node's own
  execution address (the stake status and the committee check would otherwise be about two
  different addresses); silent for --address. BSD `wc -w` padding trimmed in the §3
  "committee N" line (macOS showed "committee        5").
- Old library: one header WARN when COMMON_VERSION < 1.6.0; each new check tests its helpers
  with have_fns; the epoch section prints "Skipped: this check needs lib/common.sh 1.6.0";
  smaller additions (node config lines, CPU line, unsafe-API warning) are left out silently.
- Test hook: the harness copies check-node.sh and inserts
  `[[ -n "${TN_TEST_HOOK:-}" ]] && source "$TN_TEST_HOOK"` after the lib source (test copy
  only) to point tn_node_launch_target at fixture launch files.

## Operator-visible changes

- The report header has a new `Network:` line (testnet/devnet/mainnet, its chain id and
  where that came from). The network RPC defaults to the public RPC of that network
  (testnet `https://rpc.adiri.tel`, devnet `https://rpc.devnet.telcoin.network`, mainnet
  `https://rpc.telcoin.network`); it was always `https://rpc.telcoin.network`.
  `--network-rpc` still wins.
- The local chain id is checked against the network in .node-meta, so a devnet node
  (32285) is no longer reported as "Chain ID mismatch ... expected 2017". Without a recorded
  network, any Telcoin chain id (2017, 487, 32285) passes with an info line; any other
  chain id is an error.
- When the network RPC itself serves another chain (today `https://rpc.telcoin.network`
  answers for 2017), the report warns "<rpc> serves chain X, not chain Y -- skipping the
  network comparison" instead of blaming the node; no health issue.
- The committee header check runs again: the authority id comes from the node's `tn_info`
  (it used to read `primary_network_key`, which never matched a header author), with
  `--authority-id` as the fallback. The report says where the id came from.
- What absence from the latest commit's headers means now depends on on-chain committee
  membership of the current epoch: an error for a member, info for a non-member. When
  membership cannot be read, it is an error only for an Active or Pending Exit validator
  whose node does not report Observer. With the network RPC down, the check uses the
  latest commit the local node has seen.
- New "Checking epoch and committee..." section: epoch id, time to the next boundary and its
  UTC time, membership for the current and next two epochs, a staked validator's activation
  epoch and earliest committee seat (activation + 2; activate() now gives current + 3), a
  warning when a committee member reports Observer, and the worker count against
  `WorkerConfigs.numWorkers()` (fewer configured than required is a health issue). Extra
  workers' RPC and WebSocket ports are probed when the node runs more than one.
- An Exited validator's on-chain status says whether unstake() is eligible now; an
  unreadable stake status shows the reason (for example `http 429`).
- §1 lists what the node runs (docker image or binary), bootstrap peers and state export
  when set, the P2P ports and the advertised RPC.
- Public nodes: a warning (with the refresh command) when the Caddy RPC block predates
  block v2, and when `--http.api` / `--ws.api` enables debug, trace or admin (not `all`,
  which the node reads as eth, net, web3 and rpc). The wss probe returns as soon as the
  101 arrives (about 0.15 s) instead of waiting up to 8 s.
- A WARN in §1 when VALIDATOR_ADDRESS in .node-meta is not the node's own execution
  address (tn_info, else node-info.yaml), with the fix: restart the node after a
  `--no-restart` rotation, or correct .node-meta.
- The reputation line shows again: nodes report `sub_dag.reputation_scores`, which the
  parser now reads (the singular key it used is kept as a fallback).
- The §3 count is labelled "N authors in the latest commit"; §5.5 prints the on-chain
  committee size.
- macOS: disk usage from `df -Pk`; memory says "not checked -- the memory check needs
  /proc/meminfo" instead of failing; a CPU line ("N physical cores"). A macOS run reaches the
  summary.
- With an older lib/common.sh the report warns once in the header and skips the checks that
  need the new helpers.
- A value flag with no value (`--rpc` as the last argument, or followed by another flag)
  prints `error: --rpc needs a value (see ... --help)` on stderr and exits 0, instead of
  dying with "unbound variable".
- The local RPC probe no longer shares `/tmp/check-node.rpc.tmp` between runs: each run
  uses its own temp directory, removed on exit, so two runs at once cannot read each
  other's answer.

## Changelog text

### check-node v1.2.0 — network from .node-meta, committee membership, epoch and worker checks
check-node compares the node with the network recorded in .node-meta: the chain id check
expects that network's id (so a devnet node is no longer a "Chain ID mismatch"), and the
network RPC defaults to that network's public RPC (testnet `https://rpc.adiri.tel`) instead
of `https://rpc.telcoin.network`. When .node-meta has no network, any Telcoin chain id
passes. If the network RPC answers for a different chain, as `https://rpc.telcoin.network`
does today, the report warns and skips the comparison rather than blaming the node.
The authority id now comes from the node's own `tn_info` (`--authority-id` is the fallback).
The old lookup read `primary_network_key`, which is not the id headers carry, so the
author check never ran. Whether missing from the latest commit's headers is an error now
depends on on-chain committee membership for the current epoch; when membership cannot be
read, it is an error only for an Active or Pending Exit validator whose node does not
report Observer. A new epoch section shows the epoch, the time of the next boundary in UTC,
committee membership for this epoch and the next two, a staked validator's activation epoch
and earliest seat, and the worker count against `WorkerConfigs.numWorkers()`; too few workers
is a health issue. The service section lists the image or binary, bootstrap peers, state
export, P2P ports and the advertised RPC, and warns when VALIDATOR_ADDRESS in .node-meta is
not the node's own execution address. The reputation score shows again: nodes report it
under `reputation_scores`, which the parser now reads. Public nodes get warnings for a
Caddy RPC block older than block v2 and for debug, trace or admin in `--http.api` /
`--ws.api`, and the wss probe stops as soon as the upgrade answers. On macOS, disk usage comes from `df -Pk` and
the memory check is skipped with a note, so the report runs to the end. Exited validators
are told whether unstake() is eligible now. With an older lib/common.sh, the checks that
need its new helpers are skipped with a warning. A flag given without its value now
prints a usage error instead of crashing, and each run keeps its probe files in its own
temp directory, removed on exit, instead of a shared `/tmp/check-node.rpc.tmp`.

## Tests run

All in `<scratchpad>/b-tests/`.

- `/bin/bash -n check-node.sh`, `bash -n check-node.sh`: clean.
  `shellcheck -x --severity=error check-node.sh`: clean; `shellcheck -x -S style`: clean
  (HEAD had 2 SC2034 warnings). `/bin/bash tools/check-bash32.sh check-node.sh`: clean.
- `t_b.sh` (shim suite; check-node.sh runs as a whole under the same bash as the harness;
  python3 curl shim answering per JSON-RPC method, per eth_call selector and argument, per
  epoch, plus WebSocket upgrades; systemctl/ss/docker/ufw/caddy shims; TN_ROOT_PREFIX
  fixture root; fixture launch files via the test hook):
  `/bin/bash t_b.sh` (3.2.57): 424 passed, 0 failed. `bash t_b.sh` (5.3.15): 424 passed,
  0 failed. Every case also asserts exit 0 and no "unbound variable", "command not found"
  or "syntax error". Cases: testnet/devnet/mainnet/missing/unknown-chain/unreadable
  .node-meta; `--network-rpc` wins; testnet node on 32285 is a mismatch; mainnet node with
  `rpc.telcoin.network` serving 2017 -> WARN, no ERROR, no consensus or eth_blockNumber call
  to that endpoint, banner names it; authority id from tn_info, differing flag ignored with
  a note, flag fallback, none (member -> WARN, non-member -> info); member absent -> ERROR +
  1 issue; non-member absent -> info, no issue; unknown membership (tn_getCurrentEpochInfo
  -32601) with status 3 + CvvActive -> ERROR, + Observer -> WARN, status none -> info;
  network down -> local headers, local stake read, ERROR, banner keeps §6; both RPCs down;
  `--no-network` (no network request at all); epoch values (5h 43m, UTC time equal to
  `date -u -r` of block ts + 21600 within 2 s), membership line 580/581/582, genesis,
  pending activation 590 -> seat 592 "in 12 epochs", 579 -> "next epoch", 500 -> "reached",
  status 1 -> 581/583, Observer in committee with local epoch 578, Exited at 570 -> "That is
  now: the network is at epoch 580", getValidator HTTP 429 -> "(http 429)", boundary passed
  6m 40s, E+2 read failing -> "unknown"; numWorkers 2 vs 1 local -> ERROR + issue, 1 vs 1
  info, two local workers with both probes answering, worker 1 down (transport connect),
  numWorkers read failing -> nothing, legacy `worker:` map; macOS real df/meminfo/CPU,
  meminfo fixtures 38% and 97% (CRITICAL + issue); Caddyfile without the v2 stamp (no
  install-caddy) -> stale WARN + refresh command, with stamp -> none, stub install-caddy
  JSON block_stale true / false / spaced / missing key (old tool -> update-scripts first),
  the real install-caddy.sh 1.3.0 (enabled:false here, falls back to the stamp);
  `--http.api eth,net,web3,debug` and `--ws.api "eth,TRACE"` on a docker wrapper,
  `--http.api all` on a binary wrapper, a private node with debug (no warning); wss 405 ->
  FAIL; node config lines (image, `$(cat /etc/telcoin/bootstrap-peers.yaml)`, keeps 3
  epochs, ports, advertised RPC); `.node-meta` address differing from tn_info -> WARN,
  `--address` -> no WARN; pre-L1 library (7fb7c8d, COMMON_VERSION 1.4.0): header WARN,
  epoch section skipped with its line, report reaches the summary, §6 and §7 still run,
  `--authority-id` still matches; `--observer --validator` ignored with a note; the docker
  shim was never called in any case; `--help`.
  The getValidator and numWorkers fixtures are byte-identical to the live payloads captured
  from rpc.adiri.tel (`live/`).
- `t_ws.sh` (ws_upgrade_status extracted from check-node.sh, real curl, `wsstub.py` raw
  socket server): 7/7 under /bin/bash and bash. 101 answered in about 0.16 s, 405 in about
  0.15 s, closed port in about 0.15 s, a server that never answers gives up at about 1.77 s,
  no temp files or curl processes left, no "Terminated" noise on stderr.
- Fully real run, `/bin/bash check-node.sh --address 0x0033a370616805b1fd275b7ffab83fc41d665ccb`
  on this Mac (no shims, live https://rpc.adiri.tel): rc 0 in 2 s, reaches the summary.
- Live read-only comparison (`live-cmp/`, real curl, fixture .node-meta with NETWORK=testnet
  and a member node-info) against `cast`: epoch 581 = `tn_getCurrentEpochInfo.epochId`;
  committee membership 581/582/583 = `tn_getEpochInfo` lists; `numWorkers()` 1 = "1 required
  on-chain"; getValidator(0x0033a3…) = `(…, 0, 0, 3, false, false, 0)` = "Activation epoch:
  0 (genesis validator)" + "Status: Active"; boundary 2026-10-02 08:32:00 UTC = block
  `blockHeight-1` timestamp + 21600 via `cast block`. With `--rpc https://rpc.adiri.tel` the
  authority id from the real tn_info (G6A8BRn31vofiVH8KZzETW2kcPsbomNTQYMgvZg52jTg) is found in
  the real headers ("participating"), and the mismatch WARN fires for the fixture's
  different .node-meta address.
- All of the above re-run after another package changed lib/common.sh in the working tree
  (still 1.6.0): same results.

## Open issues

1. Release bookkeeping (orchestrator): `check-node.sh.sha256` must be regenerated after this
   change (the working tree already shows that sidecar modified by someone else; it does not
   match this file until `tools/gen-checksums.sh` runs again); README changelog entry above;
   `update-scripts.sh` bump in the release commit.
2. Docs (orchestrator/docs package): OPERATOR.md, README and the partner guide do not
   document `--network-rpc` or `--authority-id`, and the verdict lines they tell operators
   to parse ("All checks passed", "N issue(s) found", "CATCHING UP") are unchanged, so
   nothing there is wrong. The troubleshooting tables could gain rows for the new
   messages: "<rpc> serves chain X, not chain Y", "the Caddy tn-rpc block predates block
   v2", "--http.api on the node command names debug", "Workers: the network requires N",
   "In the committee for epoch E, but the node reports Observer" and the .node-meta
   VALIDATOR_ADDRESS mismatch.
3. Depends on package A: the stale-block fallback looks for the literal text
   `tn-rpc block v2` inside the `# >>> tn-rpc >>>` fence, and the JSON path reads
   `"block_stale":true|false` next to `"enabled":true` from `install-caddy.sh --json
   --phase=rpc-status`. If A words the stamp differently, the fallback must follow.
   The refresh command printed is `sudo bash <dir>/install-caddy.sh --phase=rpc-enable
   --rpc-domain <domain>` (the non-interactive human phase from install-caddy's usage).
4. Resolved in the follow-up below: a value flag given last no longer dies on `set -u`.
5. The silent-server cap of the wss probe is 15 polls of `sleep 0.1`, which measures about
   1.7 s with fork overhead (spec: "up to ~1.5 s"); `read -t 0.1` would be tighter but needs
   bash 4.
6. Resolved in the follow-up below: the fixed `/tmp/check-node.rpc.tmp` is gone.

## Follow-up (coordinator request; version stays 1.2.0)

1. Value flags without a value. `--rpc`, `--network-rpc`, `--authority-id`, `--address` and
   `--service`, given as the last argument or followed by another `--flag`, now print
   `error: <flag> needs a value (see <script> --help)` on stderr and exit 0, before the
   header. Exit 0 follows the existing convention: the only exit in the usage path was
   `--help` (exit 0), unknown arguments only warn and go on, and OPERATOR.md documents that
   check-node always exits 0 and is judged by its verdict line (absent here). The check is
   a separate `case` ahead of the existing one, so the flag lines themselves are unchanged.
2. Temp files. The fixed `/tmp/check-node.rpc.tmp` is replaced by a private per-run
   directory, `CN_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/check-node.XXXXXX")"` (falls back to
   `/tmp` when TMPDIR is missing or read-only), created once just before the first probe
   and removed by an EXIT trap (`check_node_cleanup`). The probe's body file
   `$CN_TMP_DIR/rpc-body` is emptied before each call, so a failed call never reads an old
   body. Existing trap behaviour is kept: an EXIT trap already set at that point is read
   with `trap -p EXIT` and run after the cleanup (sourcing lib/common.sh sets none; the only
   library traps are inside `tn_acquire_update_lock`, which check-node never calls).
   A directory rather than a single mktemp file because of what the tests found: under
   bash 5, a SIGTERM to the script while the probe's command substitution was still
   waiting ran the EXIT trap at once, and the still-running curl then recreated the
   removed file (mode 644, holding the late body). With a directory, the late write
   fails because the directory is gone. The wss probe's per-call temp file now also goes
   in `CN_TMP_DIR`, so an interrupted probe leaves nothing behind (it still uses its own
   mktemp under TMPDIR when called outside a run, as `t_ws.sh` does).
   Not changed: `${TMPDIR:-/tmp}/check-node.state` is the cross-run state file that
   measures block advancement between runs, so its fixed name is the point. Concurrent
   runs only race on which reading is kept (last writer wins); it is not a temp file.
   Command substitutions do not run the EXIT trap, and SIGINT and SIGTERM do run it, under
   both bashes (checked).
3. Tests after the follow-up:
   - `/bin/bash -n check-node.sh` and `bash -n check-node.sh`: clean.
     `shellcheck -x --severity=error check-node.sh`: clean; `-S style`: clean (one
     `# shellcheck disable=SC2329` on the trap handler, which only the trap calls).
     `/bin/bash tools/check-bash32.sh check-node.sh`: clean.
   - `t_b.sh`: 493 passed, 0 failed under `/bin/bash` 3.2.57; 493 passed, 0 failed under bash
     5.3.15. New cases: each of the five flags given last (error on stderr, no report,
     exit 0), `--rpc --no-network`, a missing value after valid flags, no temp left after a
     normal run and no `/tmp/check-node.rpc.tmp`, a pre-existing EXIT trap still runs and
     the temp is still removed, a missing TMPDIR falls back to /tmp and leaves nothing
     there, two concurrent runs sharing one TMPDIR (probe delayed 1 s in both) each read
     their own chain id (0x7e1 testnet, 0x7e1d devnet) and leave nothing, SIGTERM mid-probe
     leaves nothing.
   - `t_ws.sh`: 7 passed, 0 failed under both bashes.
   - `t_sig.sh` (SIGTERM and SIGINT to the script mid-probe, 5 runs each): 5/5 clean for both
     signals under both bashes.
   - Real run under `/bin/bash` (no shims, live rpc.adiri.tel): exit 0, reaches the summary,
     TMPDIR empty afterwards.

## Fix pass (V-OPS-2)

Edited the committed c7a9690 file in place; `SCRIPT_VERSION` stays 1.2.0. Findings from
`tasks/ckpt-fu-V-OPS-2-cn.md` (F1 to F7).

1. (error, F2) The `.node-meta` VALIDATOR_ADDRESS check moved out of
   `report_epoch_committee` into `report_address_mismatch`, called in §1 right after
   `resolve_identity`, which also moved to §1 (it needs only the pre-header local probe).
   It now fires before any early return: with `--no-network`, with the local RPC down
   (address from node-info.yaml on disk), and when the network epoch read fails.
   `resolve_identity` always reads node-info.yaml (`DISK_EXEC_ADDR`). The unknown-membership
   rule (`stake_status_for_rule`) now uses the stake status of the node's own address
   (`EXEC_ADDR` from tn_info or node-info.yaml only; never `.node-meta` or `--address`): it
   reuses §3's read when that was for the same address, else reads it once through the
   network RPC (or the local node when the network RPC is not in use). With the verifier's
   two-fault fixture the result is the mismatch WARN and "expected: ... no validator
   record", not the ERROR.
2. (warn, F1) `fetch_consensus_header` reads `sub_dag.reputation_scores`
   (`scores_per_authority`, `final_of_schedule`), confirmed on a live
   `tn_latestConsensusHeader` from rpc.adiri.tel (sub_dag keys: commit_timestamp, headers,
   randomness, reputation_scores; scores_per_authority is an object keyed by authority id),
   with the singular `reputation_score` as a fallback. The shim now serves the live shape.
   While in that function: its Python output is `eval`ed and took header authors,
   reputation keys and number fields straight from the RPC answer, so an answer holding
   `$(...)` would have run under sudo (pre-existing since 1.1.x). Only base58 ids and plain
   non-negative integers get through now; tested with a hostile header (nothing runs).
3. (notes)
   - F3: the §7 skip line names the reason through `network_gap_reason` ("the network RPC
     serves another chain", "--no-network", "the network RPC is unavailable").
   - F4: `risky_api_modules` warns on debug, trace and admin only, and on nothing when the
     list starts with `all`. Confirmed with
     `<scratchpad>/tn5-target/debug/telcoin-network node --help`: "`all` enables eth, net,
     web3, rpc; name debug and trace explicitly ... A list whose first entry is `all` parses
     as plain `all` and the rest is ignored".
   - F5: §3 says "N authors in the latest commit"; §5.5 adds "Committee of epoch E: N
     members (on-chain)".
   - F6: `AUTH_WHY` says why the authority id is unknown: "tn_info not asked: lib/common.sh
     1.4.0 is too old", "tn_info not asked: the local RPC is DOWN", "no tn_info answer:
     <kind detail>", "tn_info has no authority_id".
   - F7: each finding ends with what to do. Workers: "Workers are fixed when the node keys
     are generated and no script here adds one, so email support@telcoin.org before this
     node is due for a committee seat." (keytool `generate validator --workers` exists but
     says "Currently workers MUST be 1"). Observer in committee: "let it catch up" when the
     local epoch is behind, else "Look in the node log (journalctl -u <svc> -n 200) for why
     it does not join the committee." Mismatch: "node-info.yaml already has the .node-meta
     address, so restart the node ... as after prepare-stake.sh --rotate-address
     --no-restart" when the running node (tn_info) lags node-info.yaml on disk, else "If you
     rotated the address with --no-restart, restart the node; otherwise set
     VALIDATOR_ADDRESS in .node-meta to <address>."

Tests after the fix pass:
- `/bin/bash -n` and `bash -n`: clean. `shellcheck -x --severity=error`: clean; `-S style`:
  clean. `/bin/bash tools/check-bash32.sh check-node.sh`: clean.
- `t_b.sh`: 614 passed, 0 failed under `/bin/bash` 3.2.57; 614 passed, 0 failed under bash
  5.3.15. New rows: the two-fault fixture (mismatch WARN, no ERROR, own address read,
  0 issues) and its control (own address Active -> ERROR, 1 issue); the mismatch with the
  local RPC down (WARN printed before §2), offline with `--no-network`, `--no-network` with
  the local RPC up, the network epoch read failing, the restart advice, a case-only
  difference (no WARN); reputation with the live key, the singular key, and a real live
  header; a hostile header (no command runs, the real author still matches); `--http.api
  all,debug` (no warning) with `--ws.api eth,admin` (admin warned); `--http.api all`
  (no warning); the labels (4 authors vs 5 members); the pre-L1 library wording; the three
  skip reasons; the workers and Observer next steps. Updated rows: the changed wording.
- `t_ws.sh`: 7/7 under both bashes. `t_sig.sh`: SIGTERM and SIGINT 5/5 clean under both.
- Live read-only (`--rpc https://rpc.adiri.tel`, fixture .node-meta with 0x0033… and
  node-info with 0x0033…, tn_info from the balancer answering 0x3518…): exit 0; the
  mismatch WARN in §1 with the restart advice; "5 authors in the latest commit" and
  "Committee of epoch 581: 5 members (on-chain)" (cast: epochId 581, committee length 5);
  "Your reputation score: 43 (committee avg: 44)"; participating; temp directory removed.
  One earlier attempt saw the balancer answer the local probe slowly (DOWN under the 3 s /
  6 s limits); the probe answered HEALTHY in three direct tries and both repeat runs.
