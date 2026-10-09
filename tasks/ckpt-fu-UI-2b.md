status: done

# UI-2b checkpoint (ui/server.py chain side, ui/test_server_chain.py, ui/dev/serve.py fixtures)

Owns: `ui/server.py`, `ui/test_server_chain.py` (new), `ui/test_server_contract.py` (extend only),
`ui/dev/serve.py` (fixture fixes). `UI_VERSION` is not bumped (UI-4).

## Sections

- [x] 1 `decode_validator_info(hex)` strict decoder, shared by `registry_stake_status` and `api_validator`
- [x] 2 `network_stake_status(address, chain_id)` with `eth_chainId` check, two endpoints, 3 s each
  (`_public_rpc`; 3 s is a per-endpoint deadline shared by its eth_chainId and eth_call; a chain
  mismatch is logged once per (url, chain) and the endpoint skipped)
- [x] 3 `onchain_role()` replaces `onchain_is_validator`; 30 s cache; `/opt/telcoin-ui/node-role.json`
  (`onchain_role(t, det)` → {validator, source, checked_at, status}; `_decide_role`, `_role_cache` keyed
  by (mode, container, rpc_port), `clear_role_cache()` also on `/api/nodes?fresh=1`; `_synced`,
  `_local_synced`, `_node_chain_id` (eth_chainId, else meta NETWORK), `NODE_ROLE_FILE`,
  `_read_saved_role`, `_save_role` (mkstemp in the same dir + os.replace, failure logged once),
  `_saved_role_applies` (address equal; chain id equal when both known). `api_status` uses it.
  remove-node.sh does `rm -rf /opt/telcoin-ui /opt/telcoin-ui-update`; install-ui chowns the dir.)
- [x] 4 `detect_nodes` observer slot first + remap; delete `resolve_node_type`/`_docker_node_type`; `_legacy_role`
  (`SYSTEMD_DIR` constant used by `resolve_service_unit`/`service_file`/`_legacy_role`; `unified_install`
  deleted (no callers left; the dev runner patches it only under `hasattr`); `config_dir`/`data_dir`
  follow lib/fallback.sh (unified meta → /etc/telcoin, /var/lib/telcoin; else `_legacy_role()` dir;
  else unified default) and ignore the slot; `_empty_slot()`; docker probed only when no unit exists
  (one node per host; the old code could add a container beside a unified unit); first container
  wins; external containers remap like scripts nodes)
- [x] 5 epoch fields on `GET /api/validator/<t>`
  (`epoch_fields(port, address, record)`, `_committee`, `_epoch_start` (block blockHeight−1, block 0 at
  genesis, single-entry cache keyed (port, epoch, blockHeight)), `_later_committee` (tn_getEpochInfo,
  cache keyed (port, current epoch)); timing four fields all-or-nothing; earliest seat for 2/3/4;
  seat_epoch null only when all three committees were read; `api_validator` gates on `_synced(eth_blockNumber,
  cons_exec)` and keeps `record` from getValidator. Contract test: `_docker_node_type` line replaced
  by `read_node_info_text(...)` on an external node, which drives `docker-node-info`; 70 OK.)
- [x] 6 dev runner fixture fixes (public path, legacy CPU fields, unserved helper)
  (`OPERATOR_ONLY` never added on a public request; scenario `helper` replaces the server's (others
  setdefault); legacy preflight drops top-level `cpu_physical`/`cpu_threads` and sets hardware.cpu to
  the thread count, legacy /api/system `cpu_cores` = thread count as a string; non-legacy preflight
  adds top-level counts only when the server lacks them (never inside `hardware`); `unified_install`
  dropped from the patch list; `unserved` role_source `default` (what the server now sends for an
  installed node nobody classified))
- [x] 6a (coordinator) `REF_RE` → `^[A-Za-z0-9._][A-Za-z0-9._/-]*$`; `_BUILD_REF_RE` given the same
  pattern (setup's build_ref reaches setup-node `--build-ref` and git the same way; flagged in the
  report). `RefValidationTest` in test_server_contract.py: `-v0.15.0`, `--help`, `-`, empty, space,
  `;` → 400 `{"error": "invalid ref"}` with no helper call; ordinary refs stream; build_ref `-v0.15.0` →
  "invalid build ref".
- [x] 6b (coordinator) long apply stream audit: no read timeout or watchdog in `_update_stream` (see
  open issues for the details).
- [x] 7 tests: `ui/test_server_chain.py`, contract test extension, py_compile, dev runner, live read-only check
- [x] 8 closing headings

## Notes

- S1 facts (checked read-only in ../tn-5): v0.15.0-adiri pins tn-contracts 10cc12b (= HEAD). Its
  `ValidatorInfo` is `[address, uint32 activationEpoch, uint32 exitEpoch, enum currentStatus, bool
  isRetired, uint8 stakeVersion, uint8 region]`; the node's Rust binding agrees. `isDelegated` left the
  struct in tn-contracts 0866c16 (2026-05-05), so the shared spec's word names are the old layout. Both
  layouts pass the widths (old word 5 is a bool, old word 6 a uint8). Retirement (`_retire`) stores
  status 6 (`Any`) with `isRetired` true, and getValidator returns it without the NFT check, so the
  decoder accepts 6 only with isRetired. `0xed15e6cf` is `InvalidTokenId(uint256)` from
  `_checkConsensusNFTOwner` (no NFT); `0x9f5ba9a6` is `InvalidEpoch(uint32)`.
- S1 code: `_norm_address`, `VALIDATOR_INFO_LAYOUT`, `NO_RECORD = "none"`, `_NO_RECORD_REVERT`,
  `decode_validator_info` (None on anything else), `_validator_reply(resp, address)` (record must name
  the asked address or zero), `registry_stake_status(port, address)` now returns record / NO_RECORD /
  None (only `0xed15e6cf` reverts are no-record; other errors None). `api_validator` fills its fields
  from the record; no record leaves them null (page: "Not Registered").

## Operator-visible changes

None reach operators until UI-4 bumps `UI_VERSION` to 1.9.0; then, from the server's chain side:

- The validator view no longer waits for the node to sync. The server asks the network's public RPC
  for the node's `getValidator` record first (testnet `https://rpc.adiri.tel`; on devnet the first two
  listed endpoints), using an endpoint only when its chain id matches the node's. Then it asks the
  synced node itself, then the last answer saved in `/opt/telcoin-ui/node-role.json` for the same
  execution address. With none of these the node shows as a full node and the page says the role is
  unknown. A newly staked validator therefore opens in the validator view during its initial sync.
- `NODE_TYPE` in `.node-meta`, the legacy unit name and an external container's node-info.yaml no
  longer pick the view. A legacy `telcoin-observer` install shown as a validator keeps reading its own
  data and config directories.
- External docker nodes are placed by their stake, like scripts nodes.
- A host with a scripts-managed unit no longer also lists an unrelated running docker container.
- A getValidator error other than the no-ConsensusNFT revert counts as "no answer", not "not staked".
- Validator view: a synced node's `/api/validator` adds the epoch start, end and server clock, the
  earliest committee seat for an activated validator, and the seated epoch (the data UI-3b's epoch
  tile shows).
- Updates refuse a ref that starts with "-" (400 "invalid ref"); setup refuses such a build ref.
- The journal gets one line when the role answer changes, instead of a remap line every detect cycle.

## Changelog text

### telcoin-ui v1.9.0 — helper API 2, strict hostnames, one stream contract, view from the network (server part)
The server calls the privileged helper without the old `observer|validator` argument and asks it for
its API version (`helper-version`, cached for a minute when it answers 2). The validator view is now
decided from the network: the server asks the network's public RPC for the node's `getValidator`
record first (at most two endpoints, three seconds each, and only one whose `eth_chainId` matches the
node's chain), then the node itself once it is synced, then the last answer saved in
`/opt/telcoin-ui/node-role.json` for the same execution address; with none of these the node shows as
a full node. `/api/nodes` reports how the view was decided as `role_source` (`network`, `local`,
`cached` or `default`) and `role_checked_at`, and the helper check as `helper`, on the SSH-tunnel path
only. `NODE_TYPE` in `.node-meta`, the legacy unit names and an external container's node-info.yaml
no longer pick the view, and a legacy install shown as a validator keeps its own data and config
paths. The getValidator reply is decoded strictly (seven words, each within its Solidity type, status
0 to 5 or the retired 6); only the no-ConsensusNFT revert counts as no record, and any other error
counts as no answer. For a synced node, `/api/validator` adds the epoch's start and end with the
server's clock (`epoch_started_at`, `epoch_duration`, `epoch_ends_at`, `now`), `earliest_seat_epoch`
for an activated validator, and `seat_epoch`, the first of the current and next two epochs whose
committee includes the node. Dashboard, public RPC and move-to hostnames follow the strict rule shared
with the helper and the page, and a bad one is refused with a 400 before anything runs. Setup sends
the public RPC hostname as `TN_SETUP_RPC_DOMAIN` and no longer sets `TN_SETUP_RPC_PUBLIC` or
`TN_SETUP_INSTANCE`; public RPC without a hostname is refused. `/api/rpc/enable` takes
`move_dashboard_to`, and `/api/rpc/status` adds `meta_domain` and passes the advertised and WebSocket
fields through when install-caddy.sh reports them. Status and DNS-check replies are read from the last
JSON line, so a warning printed before it no longer hides the result. Every action stream captures
stderr, turns stray output into log lines, sends exactly one `done` (made up from the exit code when
the script sends none, after an `error` line with the stderr tail when it failed) and then `closed`,
and stops cleanly when the browser goes away. Update and source-build refs that start with "-" are
refused. CPU counts are physical cores, with `cpu_threads` beside them. The testnet comparison
endpoint is `https://rpc.adiri.tel`, the unused wss:// list is gone, and trace lookups follow the
helper's `telcoin` service name. Tests: `ui/test_server_contract.py`, `ui/test_server_chain.py`.

## Tests run

All on 2026-10-01, macOS, from the repo root.

1. `<scratchpad>/ui-venv/bin/python -m unittest discover -s ui -p 'test_*.py'` (Python 3.14.8, Flask
   3.1.3) → 121 tests OK: 48 new in `ui/test_server_chain.py`, 66 in `ui/test_server_contract.py`
   (UI-2a's 63 plus 3 `RefValidationTest`), 7 in `ui/test_public_readonly.py` unchanged.
2. Same suite under `/usr/local/bin/python3.11` (3.11.6) with the venv's site-packages on PYTHONPATH →
   121 OK. `ast.parse(..., feature_version=(3, 10))` on `ui/server.py`, `ui/test_server_chain.py`,
   `ui/test_server_contract.py`, `ui/dev/serve.py` → OK.
3. `python -m py_compile` on the same four files → OK; `__pycache__` removed afterwards.
4. Mutation check (`<scratchpad>/ui2b/mutate.py`: scratch copies of ui/, tests unchanged): 27 of 27
   deliberate breaks caught — no eth_chainId check, retired 2, status 7, status 6 without retired, any
   revert as no record, reply address not checked, three endpoints, no per-endpoint deadline, network
   never asked, local asked while unsynced, saved answer for another address, for another chain, role
   cache off, `?fresh=1` keeping the role cache, NODE_TYPE picking the slot, external containers not
   remapped, docker asked beside a unit, `_legacy_role` ignored in `data_dir`, boundary from the first
   block instead of the one before, boundary block not cached, committees not cached, earliest seat
   for status 1 and 5, seat_epoch null on a failed lookup, epoch fields while unsynced, two
   tn_getCurrentEpochInfo calls per poll, leading "-" ref allowed, leading "-" build ref allowed.
5. Dev runner smoke (`<scratchpad>/ui2b/smoke.py`, which starts `ui/dev/serve.py --port <free>
   --scenario …`): all six scenarios with their default role and `public`, `private`, `unserved`,
   `legacy` with `--role validator`. `/`, `/api/nodes` (operator and public), `/api/validator/<slot>`,
   `/api/status/<slot>`, `/api/system`, `/api/setup/preflight` all 200; 177 checks OK; no tracebacks.
   Public `/api/nodes` carries no helper/role fields; `unserved` helper `{ok: false, api: 1}` and
   role_source `default`; `legacy` has no role/helper fields, no top-level or hardware CPU extras,
   hardware.cpu 16 and system cpu_cores "16" without cpu_threads, no epoch fields; `fresh` and
   `fresh-reject` role null with role_source null; validator epoch fields present in public, private,
   unserved with `--role validator`.
6. Live read-only check against `https://rpc.adiri.tel`, 2026-10-01 20:57 CDT, through the server's own
   `_public_rpc` / `_validator_reply` / `network_stake_status` (5 read-only requests, no transaction):
   `eth_chainId` → `0x7e1`; getValidator(`0x0033a370616805b1fd275b7ffab83fc41d665ccb`) → seven words,
   decoded `{activation 0, exit 0, status 3, retired false, stake_version 0, region 0}`;
   getValidator(`0x…dEaD`) → error code 3 with data `0xed15e6cf…dead` → no record;
   `network_stake_status(committee, 2017)` → status 3. Both payloads are the literals in the tests.

## Open issues

1. Spec drift in `tasks/spec-fu-shared.md`: it names getValidator words 5 and 6 `isDelegated,
   stakeVersion`, the layout before tn-contracts 0866c16 (2026-05-05). v0.15.0-adiri pins tn-contracts
   10cc12b, where they are `stakeVersion, region` (the node's Rust binding agrees). The decoder follows
   the pinned ABI; values from the old layout still pass its width checks. The live payload is zero in
   both words, so it cannot show which layout the deployed testnet registry has; `/api/validator`
   `stake_version` reads word 5, as the server did before. Worth confirming on a validator with a
   non-zero stake version or region.
2. Deviation from "status 0–5": status 6 (`Any`) is accepted together with `isRetired`, because
   `_retire` writes exactly that pair and getValidator returns it without the NFT check. Rejecting it
   would turn every retired validator into "no answer" and leave the page on a cached or unknown
   notice for good. Status 6 without isRetired, and 7 or more, are rejected.
3. The no-record rule is narrower than before: only the `0xed15e6cf` (`InvalidTokenId`) revert means
   no record. A revert without data, or with other data (`RequiresConsensusNFT` `0x61f51356`), is "no
   answer"; the old code read any code-3 revert as "not staked".
4. Coordinator item 1: `REF_RE` is `^[A-Za-z0-9._][A-Za-z0-9._/-]*$`. I gave `_BUILD_REF_RE` (setup's
   `build_ref`, which reaches setup-node `--build-ref` and git) the same pattern without being asked;
   revert that one line if unwanted. The helper's own checks (`cmd_update_prepare` and the setup build
   ref, both `^[A-Za-z0-9._/-]+$`) still admit a leading "-"; the server and update-node 1.2.0 refuse
   it first, but the helper should match (not my file).
5. Coordinator item 2 (apply streams up to 30 minutes): `_update_stream` has no read timeout or
   watchdog. It blocks on the child's stdout for as long as the child keeps it open and passes each
   heartbeat on as a `log` frame; `_reap(grace=10)` starts only after stdout closes. The helper
   `exec`s update-node.sh with no timeout, sudo adds none, `ui/telcoin-ui.service` has no
   `RuntimeMaxSec` or `WatchdogSec`, and the threaded Werkzeug server (`app.run(threaded=True)`) has no
   request timeout. `run()`'s 10 s default applies only to non-stream calls. The one early stop is a
   client disconnect: the child then gets 2 s and is terminated (UI-2a open issue 5). With up to 30
   minutes of epoch wait before the stop, a closed tab or a dropped SSH tunnel during the wait now
   ends the apply; the 15 s heartbeats keep an idle tunnel from timing out. Whether update-node
   cleans up when terminated during the wait is update-node's to confirm.
6. `ui/test_server_contract.py` is extended, with one line replaced: `exercise_every_helper_call`
   called the deleted `_docker_node_type`; it now drives `docker-node-info` through
   `read_node_info_text` on an external node, so the helper-call coverage is unchanged.
7. `ui/server.py.sha256` shows as modified: someone else regenerated it at 21:01; it matches
   `ui/server.py` as of my last edit (20:56). Regenerate centrally after the final UI commit anyway.
8. Docker is probed only when no unit exists (one node per host). A host with a scripts unit and an
   unrelated running container used to show both, in different slots; it now shows the scripts node.
9. A chain id missing from `NETWORK_PUBLIC_RPC` (mainnet 487 today) gets no network answer and falls
   back to local, cached or default. Add mainnet there (and to `NETWORKS`) when it launches.
10. The role answer is cached 30 s per (mode, container, rpc_port). A reinstall with new keys inside
    that window keeps the old answer until `/api/nodes?fresh=1` (the page calls it after setup) or the
    TTL. `node-role.json` is rewritten on each fresh definitive answer (about 150 bytes, at most every
    30 s while a dashboard polls); where `/opt/telcoin-ui` is missing the save fails with one journal
    line and the UI carries on. remove-node.sh deletes `/opt/telcoin-ui` (checked), so nothing is left.
11. The dev runner still replaces `/api/status/<t>` and `/api/validator/<t>` with fixtures, so the new
    epoch arithmetic is covered by `ui/test_server_chain.py`, not by the runner (UI-3a open issue 9).

## Fix pass (code review)

status: done

Finding: `network_stake_status` made up to two blocking HTTP round trips (eth_chainId + eth_call, 3 s
each) on the request thread every time the 30 s role cache expired, so `/api/nodes` and every route
that calls `detect_nodes` stalled 3 to 6 s when the public RPC was slow or unreachable. Contract kept:
network first, then local, then cached, then default. `UI_VERSION` stays 1.9.0 (unreleased).

Steps:
- [x] F1 per-URL state: eth_chainId answer kept an hour; failed or timed-out endpoint backed off 5 min,
  doubling to 30 min, reset by a usable answer; `_clock` seam for the tests
- [x] F2 background refresh: network answers kept in memory, refreshed by one lazily started daemon
  thread; requests never wait for the network
  F1/F2 code: `_endpoints` + `_endpoint`, `_endpoint_plan` (skip/call/ask), `_endpoint_failed`;
  `network_stake_status` walks the list skipping backed-off or wrong-chain endpoints, asks at most two,
  sends eth_chainId only when the hour-old answer is missing. `network_answer(address, chain_id)` reads
  `_network_answers` (refresh at 30 s, valid 300 s), starts `_refresh_network_answer` in one daemon
  thread (`_network_refresh`, `_network_tried` rate limit, not when every endpoint is skipped); the thread
  stores the answer and bumps `_network_refresh["generation"]`; `onchain_role` keeps the generation with
  its cache entry and decides again on a mismatch (expiring the cache from the thread raced with a
  request storing the older answer just after). `_decide_role` calls `network_answer`;
  `onchain_role` uses `_clock`. Cold cache: serve local / saved / default at once, thread fills in.
- [x] F3 tests in `ui/test_server_chain.py` (fake clock, fake HTTP), existing rows moved to the async flow
  (`FakeClock` patched over `server._clock`; `settle()` joins the refresh thread and runs as a cleanup
  before the patches are undone; `reset_network()`; `refreshed_nodes()`; network-answer rows now read the
  second request; EpochFieldsTest primes the network answer in `answer_with`. New: NetworkStakeTest
  `test_backed_off_endpoints_are_passed_over`; NetworkRefreshTest cold start, endpoint down inside its
  back-off (300 → 600 → 1200 → 1800 → 1800, reset on success), chain id once an hour, slow endpoint, answer
  ageing out to local then cached, no refresh without an endpoint. Chain file: 56 tests OK.)
- [x] F4 full suite, py_compile, Python 3.10 grammar; closing notes

Design chosen. Requests never wait for a public endpoint. `network_answer` serves the network's last
usable answer from memory (refreshed once it is 30 s old, counted as `network` until it is 300 s old)
and starts at most one daemon refresh thread; the thread runs the blocking `network_stake_status`
(3 s per endpoint, at most two endpoints, chain id remembered an hour, a failed endpoint backed off
5 → 10 → 20 → 30 min, reset by a usable answer) and bumps a generation counter that the role cache
checks. Cold cache: the first request answers from the synced node, then the saved answer, then the
default, and the network's answer replaces it on the next role check once the thread has it (no
synchronous first probe). Order unchanged: network, local, cached, default. When the network answer
ages out (endpoint down past 300 s), `role_source` falls to `local`, `cached` or `default`.

Fix-pass tests run (2026-10-02, macOS):
1. `<scratchpad>/ui-venv/bin/python -m unittest discover -s ui -p 'test_*.py'` → 135 OK (128 + 7 new:
   1 in NetworkStakeTest, 6 in NetworkRefreshTest), three runs; `ui/test_server_chain.py` alone 25
   runs, all OK (real threads, no flakes). Same suite under Python 3.11.6 → 135 OK.
2. `py_compile` on `ui/server.py` and `ui/test_server_chain.py` → OK;
   `python3 -c "import ast; ast.parse(open('ui/server.py').read(), feature_version=(3,10))"` → OK (and the
   same for the test file).
3. Mutations (`<scratchpad>/ui2b/mutate-fix.py`): 10 of 10 caught — chain id never remembered, no
   back-off, back-off not doubling, back-off never reset, probe on the request thread, answer never
   ageing out, overlapping refreshes, generation ignored, refresh started with every endpoint skipped,
   skips not honoured. UI-2b's original 27: 23 apply unchanged and are caught; equivalents of the 4
   whose code moved (endpoint limit, network never asked, role cache off, leading-dash ref) are caught.
4. Dev runner smoke (`<scratchpad>/ui2b/smoke.py`, ten runs over the six scenarios) → no failures.

Fix-pass open issues:
1. `ui/server.py.sha256` is stale against the edited `ui/server.py`; regenerate centrally (not touched).
2. A new stake status shows up to about 30 s (refresh) plus one detect cycle later than with the
   blocking probe; a cold start shows the node's or the saved answer for the first second or so.
3. The refresh thread is per process. Flask's threaded server shares it; if the UI ever runs with
   several worker processes, each would keep its own network state.
