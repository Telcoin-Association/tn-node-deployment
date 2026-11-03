status: complete (sections 1-5 done)
completed sections: 1, 2, 3, 4, 5

# V1a checkpoint: verification of technical-specification.md 1.1 -> 1.2

Worktree (read-only): /tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/64bde3c7-bb69-4b5a-b090-75740954e028/scratchpad/tn-main at 7167e7800 (on origin/main; newest tag v0.16.0-adiri).
Statements S1-S37 enumerated from `git diff 58665ac` (37 added/changed sentences).

## Section 1: Introduction and Networking (derived from code before reading writer notes)

- S1 edition line (v0.16.0-adiri + main to 7167e7800, Nov 2026): tag exists; HEAD date 2026-11-02, contained in origin/main. CONFIRMED.
- S11 dial: 10 s per address = quic handshake_timeout `crates/config/src/network/quic.rs:67` (min with idle 30 s, quic.rs:11); at most four = `MAX_ADVERTISED_MULTIADDRS` `crates/node-record/src/addresses.rs:11`; in order, one at a time = `crates/network-libp2p/src/peers/behavior.rs:281-282`; 45 s DERIVED = `DIAL_TIMEOUT_SLACK` 5 (`crates/network-libp2p/src/consensus.rs:186`) + 4 x 10, `consensus.rs:675-677`, applied as swarm `with_connection_timeout` `consensus.rs:881` (peer-manager backstop = max(15, 45+5) = 50 s, consensus.rs:678-683, network.rs:874). CONFIRMED.
- S12 idle timeout about half a minute: `quic.rs:68` 30_000 ms. CONFIRMED.
- S13 128 per swarm / 8 per peer: `consensus.rs:216`, `consensus.rs:227`, per swarm `consensus.rs:340-341`, applied `consensus.rs:347-361`. CONFIRMED as defaults; IMPRECISE: an operator `process_budget` in `<datadir>/network-config` replaces both (`consensus.rs:224-226` "An operator `process_budget` replaces it", `consensus.rs:352-359`, `crates/config/src/network.rs:37,288`, `crates/config/src/network_budget.rs:7-24`). -> D1 (imprecise).
- S14 no committee exemption: `consensus.rs:223-225`; pending budget refuses committee peers too `consensus.rs:238-239`. CONFIRMED.
- S15 1,024 pending inbound per swarm, held <= 10 s: `consensus.rs:247`, `consensus.rs:337-341`. CONFIRMED.
- S16 DHT ~2 records/s shared budget, exempt = prev/current/next committees + operator/bootstrap peers, shed without penalty: `crates/network-libp2p/src/peers/manager.rs:135` (2/s), `manager.rs:145` (burst 120), `manager.rs:1881-1890`, `crates/network-libp2p/src/peers/policy.rs:59-68,93-114`, shed path `consensus.rs:3040-3043`. CONFIRMED (burst of 120 at an instant is covered by "about").
- S17 12,000-byte payload, every topic: `crates/config/src/network.rs:542`, check `consensus.rs:2540-2542`. CONFIRMED.
- S18 frame gate: 24,579 DERIVED = max(12,000 + 512, 16,384 + 3) + 8,192 = 16,387 + 8,192 (`crates/network-libp2p/src/gossip_config.rs:26,34,41,46,54-57,63`); 8 entries `gossip_config.rs:71`; 16 KiB control `gossip_config.rs:34`; strict `>` checks on raw buffer before decode, stream closed: libp2p-gossipsub 0.50.0 (Cargo.lock) `src/protocol.rs:295-347`; order doc `gossip_config.rs:129-147`. CONFIRMED (the 24,579 limit is on the read buffer, so "a frame larger than" is a sufficient condition, accurate).
- S19 topics carry only chain id: `crates/config/src/network.rs:643-661`, `crates/node/src/manager/node/start_epoch.rs:1638`. CONFIRMED.
- S20/S21 replay drops unauthorized author without penalty; historical = entering with certified record; size penalty in every epoch to relayer: `consensus.rs:3443-3463`, `crates/network-libp2p/src/types.rs:1189-1196`, `start_epoch.rs:401-428`. CONFIRMED.
- S22 two tiers current+next, 2 streams per peer: `crates/consensus/primary/src/network/mod.rs:1960-1963,1981`, `mod.rs:134`; worker `crates/consensus/worker/src/network/mod.rs:715,730,79`. CONFIRMED.
- S23 5 s / 1 s opening read: primary `mod.rs:181,190,552-557`; worker `mod.rs:117,127,273-278`. CONFIRMED.
- S24 5 public + 4 reserved per class; 3 primary classes; worker batches; at-capacity Deny at once: primary `mod.rs:66,75,392-396`, Deny `mod.rs:625-637`; worker `mod.rs:45,51,726`; `crates/network-libp2p/src/sync/admission.rs:1-24`. CONFIRMED.
- S25 200 s public epoch-pack serve cut: primary `mod.rs:200,470-476`. CONFIRMED.
- S26 worker serves own epoch and previous, denies before storage read: worker `mod.rs:618-625,634-640,515-524`. CONFIRMED.
- S27 batch fetch: 5/5/210/480 s: `crates/consensus/worker/src/network/handle.rs:61,52,46,81`; whole-call timeout `handle.rs:237-249`; committee first `handle.rs:220-224`, `consensus.rs:1503` (preferred header author tried before that, `handle.rs:290-296`). CONFIRMED.
- S28/S29 penalty Mild = 1 point, charges: `crates/network-libp2p/src/peers/score.rs:73`, `peers/penalty.rs:59`; primary `mod.rs:563-572,611-660,670-685`; worker `mod.rs:293-299,338-406,425-431`. CONFIRMED.
- S30 committee members count against ceilings: `consensus.rs:223-225`. CONFIRMED; the word "fixed" inherits D1 (an operator budget changes the ceilings).
- S31 committee peer record never pruned: `crates/network-libp2p/src/peers/all_peers.rs:59-61,1058-1062,1083`. CONFIRMED.

## Section 2: Worker scaling, Epoch boundaries, Node modes (derived from code)

- S2 removed lane closes admission at the boundary and hands its pool to worker 0 under normal validation/capacity; refused ones discarded: `crates/node/src/engine/mod.rs:316-334` (destination = `workers.first()`), call at close `crates/node/src/manager/node/run_epoch.rs:488-490` and entry `run_epoch.rs:218-220`, `start_epoch.rs:594`; relay `crates/tn-reth/src/worker.rs:60-88`; discard + reasons `crates/tn-reth/src/metrics.rs:327-331,341-357`. CONFIRMED.
- S3 removed lane keeps listeners for reads, reopens over an empty pool: `crates/tn-reth/src/worker.rs:62-65,70-71,92-101`; submission refusal `worker.rs:177` ("worker is inactive"), `crates/tn-reth/src/rpc_fee_cap.rs:9-11,180-188`. CONFIRMED.
- S4 mainnet genesis six-hour epochs: `chain-configs/mainnet/genesis.yaml:98` (0x5460 = 21,600 s = 6 h) and `:81` (stake-config word, 0x5460); regenerated by #1559 in 5ccb88e8; gate test `crates/telcoin-network-cli/src/genesis/mod.rs:598,620`. Placeholder validator addresses in the file make "planned" right. CONFIRMED.
- S5 member enters CvvActive at each epoch start and at startup without a caught-up check: `crates/node/src/manager/node/start_epoch.rs:1210-1218`, startup `crates/node/src/manager/node.rs:984-997,1288-1295`. CONFIRMED.
- S6/S7/S36 later-epoch record -> CvvInactive; rotated out -> Observer: `crates/node/src/manager/node.rs:1960-1982`. CONFIRMED with one precedence gap: the CvvInactive branch applies only when the record is eligible (its `next_committee` holds the key, or it is older than local epoch - 1); a later record that drops the key gives Observer (`node.rs:1969-1976`). S6 states the CvvInactive exception unconditionally. -> D2 (imprecise, minor).
- S8/S9 intake by mode: CvvActive seals; observer forwards; a member vetoed to Observer has no builder and keeps the pool: `crates/node/src/manager/node/run_epoch.rs:1080-1090,409-425`; forwarding keyed on seat `start_epoch.rs:797-815`, `crates/consensus/worker/src/worker.rs:254-257,336-339`; CvvInactive refuses `crates/tn-reth/src/rpc_fee_cap.rs:56-61`. CONFIRMED. (Edge: a non-member whose CvvInactive carried over still forwards what its pool holds, run_epoch.rs:1086-1087; it still refuses new submissions, so the sentence holds.)
- S10 error text, both methods, before pool, mode read per request: `crates/tn-reth/src/rpc_fee_cap.rs:65-77` (code `INTERNAL_ERROR_CODE`), `rpc_fee_cap.rs:204-224`, `rpc_fee_cap.rs:160-162` (mode closure read per call); `crates/node/src/engine/inner.rs:145-146`. CONFIRMED.

## Section 3: Trustless synchronization and Recovery after restart (derived from code)

- S32 record without certificate answered unavailable at once; requester asks again (random peer, up to three per call): `crates/consensus/primary/src/network/handler.rs:1293-1325`; `crates/consensus/primary/src/network/mod.rs` `request_epoch_cert` (loop of three `send_request_any`). CONFIRMED.
- S33 strict next consensus number, repeat refused: `crates/storage/src/consensus_pack.rs:4682-4708` (`InvalidConsensusNumber`). CONFIRMED.
- S34 final digest checked on the header before its batches; each batch = next declared digest and within `max_batch_size`: `consensus_pack.rs:4633-4646,4648-4672`, loop `consensus_pack.rs:4575-4590`. CONFIRMED.
- S35 output not held -> `Deny(Unavailable)` at once; requester tries the next peer: `handler.rs:1510-1540`; requester arm "try next peer" in primary `mod.rs` (Deny -> `RPCRetryable`). CONFIRMED.
- S36 restart resumes CvvActive unless synced records rotate it out (Observer) or are past its epoch (CvvInactive): `crates/node/src/manager/node.rs:984-997,1288-1295,1960-1982`. CONFIRMED; same precedence gap as D2 (here the order "rotate out ... or past its epoch" reads correctly, so no separate defect).
- S37 latched durability failure stops the node; restart reopens the stores: `crates/node/src/manager/node/run_epoch.rs:1150-1163` ("stopping the node (a restart reopens it)"), `run_epoch.rs:1192-1211`, `run_epoch.rs:598`, `close_epoch.rs:761`; latch semantics `crates/storage/src/tndb/README.md:197-204`, `crates/storage/src/tndb/commit.rs:15-17`. CONFIRMED (from #1558, 8aedf72e, on main).

## Section 4: comparison with the writer's log, cross-document agreement, off-main check

Writer's log (`tasks/ckpt-spec-refresh-2-log.md`) and facts F1-F3 read only after sections 1-3. Every citation in the log points at the line I derived or a neighbouring one (spot-checked: `genesis/mod.rs:575` `MAINNET_EPOCH_DURATION_SECS = 21_600`; `txn_pool.rs:818-838` `admitted_transactions` / `migrate_transactions_to`; `handler.rs:1257-1262` consensus output answered from data on hand; `all_peers.rs:1243-1248` `is_committee_record`; `run_epoch.rs:1214-1235` certificate-pack seal failure). No citation contradicts the code. Two facts the writer dropped knowingly: F2's "an operator `process_budget` replaces both" (D1), and F3's qualifier "a committee member whose key the newest epoch record does not exclude" (D2).

Cross-document agreement (`git diff 58665ac` of the guide, OPERATOR.md, README.md):
- `validator is inactive; retry another endpoint`, both submit methods: guide and OPERATOR troubleshooting rows print the same message, add `-32603` (matches the code) and say "from the next release" (decision 2; the spec's edition line covers that). AGREE.
- Worker-count lowering: guide and OPERATOR `worker is inactive` rows ("keeps the dropped worker's RPC port open for reads but refuses transactions there"; send to the first worker) agree with S2/S3. AGREE.
- Storage fail-stop: OPERATOR and guide rows (`... can no longer make writes durable; stopping the node`, exit 1, systemd restart reopens the stores; on `v0.16.0-adiri` only consensus tasks stop) agree with S37. AGREE.
- `CvvInactive` vocabulary: OPERATOR adds "From the next release it refuses new transactions meanwhile"; the guide's vocabulary row does not, but its troubleshooting row does. No conflict with the spec.
- Six-hour epochs: guide and OPERATOR state testnet epochs only; no mainnet claim anywhere else. No conflict.
- Networking figures (45 s, 128, 8, 1,024, 12,000, 24,579, sync tiers, DHT budget, 5/5/210/480 s): no twin in the guide, OPERATOR or README. Nothing to compare.

Off-main: every changed sentence is backed by code in the 7167e7800 tree (on `origin/main`). The changed text names no staging 10-27 PR, no worker gateway, no `--forward-txs`, no tag other than `v0.16.0-adiri`. (The code comment at `rpc_fee_cap.rs:54` mentions a worker gateway; the spec does not.) PASS.

Conventions: one `# ` title; no contact in the body; "legacy" only at line 7 (EVM legacy transactions); identifiers in code spans except the commit hash (D3); both new heading links resolve (`#step-2-sync-consensus-headers` from `### Step 2: Sync consensus headers`, `#transport`); no heading added, renamed or removed. The `Step 1/2/3` headings carry ordinals, but they predate this refresh (present at 58665ac). `metadata.yaml` bumped to 1.2, November 2026.

## Section 5: report

## Verdict

- Statements checked: 37 (every added or changed sentence, the table cell and the new bullet included).
- Confirmed against the code: 37 (no sentence is wrong or unsupported).
- Defects: 3 (two imprecise, one convention), touching 5 statements (S1, S6, S7, S13, S30). Confirmed with no reservation: 32.

## Defects

- D1 imprecise (low, optional) — "Each of a node's swarms, one for the primary and one for each worker, accepts at most 128 established connections in total, ... and at most eight from any one peer." and "They still count against each swarm's fixed connection ceilings (see [Transport](#transport))." — 128 and 8 are the values when the operator sets no `process_budget`; an operator `process_budget` in `<datadir>/network-config` replaces both (F2 said so, the writer left it out as opt-in) — `crates/network-libp2p/src/consensus.rs:218-227` ("An operator `process_budget` replaces it"), `consensus.rs:352-359`, `crates/config/src/network.rs:37,288` — Fix: write "accepts by default at most 128 ..." (or keep it and drop "fixed" from the Peer scoring sentence: "each swarm's connection ceilings").
- D2 imprecise (minor) — "The exception is a member whose newest epoch record is for a later epoch than the one it is entering: that record proves it is behind, so it starts as `CvvInactive` and catches up before it votes." and in Mode detection "... and if the record is for a later epoch than the one it is entering, the node enters `CvvInactive` and catches up before it votes." — the `CvvInactive` branch is taken only when the record does not exclude the key; a later record whose `next_committee` lacks the key gives `Observer` (the observer check comes first) — `crates/node/src/manager/node.rs:1969-1976` — Fix: say "a member whose newest epoch record still names it in the next committee but is for a later epoch ..." in CvvActive, and "if the record keeps the key but is for a later epoch ..." in Mode detection.
- D3 convention (nit) — "This edition describes the protocol as of release `v0.16.0-adiri` and the changes merged to telcoin-network `main` up to commit 7167e7800 (November 2026)." — the commit hash is an identifier but is the one not in a code span (`main` and the tag are) — n/a (style) — Fix: write `7167e7800`.

## Confirmed

- S1 edition line: tag `v0.16.0-adiri` exists; 7167e7800 on `origin/main`, 2026-11-02.
- S2 lane handoff to worker 0: `crates/node/src/engine/mod.rs:316-334`; `run_epoch.rs:488-490`; `crates/tn-reth/src/worker.rs:60-88`; `crates/tn-reth/src/metrics.rs:327-331`.
- S3 reads stay open, empty pool on regrow: `crates/tn-reth/src/worker.rs:62-71,92-101`.
- S4 mainnet six-hour epochs: `chain-configs/mainnet/genesis.yaml:98` (0x5460 = 21,600 s); `crates/telcoin-network-cli/src/genesis/mod.rs:575,620`.
- S5 CvvActive at epoch start and startup: `crates/node/src/manager/node/start_epoch.rs:1210-1227`; `crates/node/src/manager/node.rs:984-997,1288-1295`.
- S6/S7 later-epoch record -> CvvInactive (see D2): `crates/node/src/manager/node.rs:1960-1982`.
- S8 table cell "Refuses new submissions": `crates/tn-reth/src/rpc_fee_cap.rs:57-61`.
- S9 intake by mode, seated observer keeps its pool: `crates/node/src/manager/node/run_epoch.rs:1080-1090`; `start_epoch.rs:812-815`; `rpc_fee_cap.rs:57-61`.
- S10 message, both methods, before the pool, mode per request: `rpc_fee_cap.rs:68-77,204-224`; `crates/node/src/engine/inner.rs:145-146`.
- S11 10 s per address, four addresses in order, 45 s: `crates/config/src/network/quic.rs:67`; `crates/node-record/src/addresses.rs:11`; `crates/network-libp2p/src/peers/behavior.rs:281-282`; `consensus.rs:186,675-677,881`.
- S12 idle timeout about 30 s: `quic.rs:68`.
- S13 128 / 8 per swarm (see D1): `consensus.rs:216,227,340-341`.
- S14 no committee exemption: `consensus.rs:223-225,238-239`.
- S15 1,024 pending, 10 s hold: `consensus.rs:247,337-339`.
- S16 about two DHT records per second, exempt sets, shed without penalty: `crates/network-libp2p/src/peers/manager.rs:135,145,1881-1890`; `peers/policy.rs:59-68,93-114`.
- S17 12,000-byte payload: `crates/config/src/network.rs:542`; `consensus.rs:2540-2542`.
- S18 frame gate 24,579 / 8 / 16 KiB: `crates/network-libp2p/src/gossip_config.rs:26,34,41,46,54-57,63,71`; libp2p-gossipsub 0.50.0 `src/protocol.rs:295-347`.
- S19 topics carry only the chain id: `crates/config/src/network.rs:643-661`.
- S20 replay drops unauthorized authors without penalty: `consensus.rs:3443-3463`.
- S21 closed = entering with certified record; size charged to relayer always: `start_epoch.rs:420-428`; `consensus.rs:3456-3463`; `crates/network-libp2p/src/types.rs:1189-1196`.
- S22 two tiers, two streams per peer: `crates/consensus/primary/src/network/mod.rs:134,1960-1963,1981`; worker `mod.rs:79,715,730`.
- S23 5 s / 1 s opening read: primary `mod.rs:181,190,552-557`; worker `mod.rs:117,127,273-278`.
- S24 5 + 4 per class, at-capacity Deny at once: primary `mod.rs:66,75,392-396,625-637`; worker `mod.rs:45,51,726`.
- S25 200 s public pack-serve cut: primary `mod.rs:200,470-476`.
- S26 worker serves own and previous epoch only, before storage: worker `mod.rs:618-625,634-640`.
- S27 batch fetch 5/5/210/480 s, committee first: `crates/consensus/worker/src/network/handle.rs:46,52,61,81,220-249`; `consensus.rs:1503`.
- S28 new penalty bullet (public tier only): primary `mod.rs:670-685`; worker `mod.rs:425-431`.
- S29 Mild = 1 point and the charge list: `crates/network-libp2p/src/peers/score.rs:73`; `peers/penalty.rs:59`; primary `mod.rs:563-572,611-660`.
- S30 committee members count against the ceilings (see D1): `consensus.rs:223-225`.
- S31 committee peer records never pruned: `crates/network-libp2p/src/peers/all_peers.rs:59-61,1058-1062,1083`.
- S32 uncertified record answered unavailable at once: `crates/consensus/primary/src/network/handler.rs:1293-1325`; `request_epoch_cert` loop in primary `mod.rs`.
- S33 strict next consensus number: `crates/storage/src/consensus_pack.rs:4682-4708`.
- S34 final digest before batches, next declared batch, size cap: `consensus_pack.rs:4633-4672`.
- S35 output not held answered at once, next peer: `handler.rs:1257-1262,1510-1540`.
- S36 restart: rotated out -> observer, past its epoch -> CvvInactive: `node.rs:984-997,1288-1295,1960-1982`.
- S37 fail-stop on own storage, restart reopens: `crates/node/src/manager/node/run_epoch.rs:1150-1163,1192-1211`; `crates/storage/src/tndb/README.md:197-204`.

## Open points

(a) The refusal is `ensure_can_submit` in `crates/tn-reth/src/rpc_fee_cap.rs:68-77`: `ErrorObjectOwned::owned(jsonrpsee::types::error::INTERNAL_ERROR_CODE, "validator is inactive; retry another endpoint", None)`. `node_mode_accepts_submissions` (`rpc_fee_cap.rs:57-61`) is false only for `CvvInactive`. Both `send_raw_transaction` and `send_raw_transaction_sync` call it (`rpc_fee_cap.rs:210`, `:222`), after `admission.ensure_active()` (`-32000` `worker is inactive`, `crates/tn-reth/src/worker.rs:177`) and `ensure_active_worker()` (`-32000` `worker is no longer active in this epoch; submit to an active worker`, `rpc_fee_cap.rs:180-188`), and before the fee cap and any decoding or pool access. Cargo.lock has a single `jsonrpsee-types` at 0.26.0 (workspace `Cargo.toml:183-184` pins `jsonrpsee` and `jsonrpsee-types` 0.26.0); `jsonrpsee-types-0.26.0/src/error.rs:129` has `INTERNAL_ERROR_CODE: i32 = -32603`. So the code is `-32603`. The spec prints only the message; the guide and OPERATOR print `-32603` and agree.

(b) A node demoted to `CvvInactive` keeps the transactions already in its pool. Nothing clears a pool on a mode change: the only removals in `crates/tn-reth/src/txn_pool.rs` are the queued-lifetime eviction (`:417-431`, queued and basefee subpools only), blob and unsupported-type removal (`:993-1000`) and canonical-state updates; nothing in `crates/node`, `crates/consensus/worker` or `crates/batch-builder` calls a clear keyed on `NodeMode`. The worker components and pools are reused across modes (`start_epoch.rs:1416-1426`, `inactive_cvv_epoch_starts_all_workers_and_reuses_components`). A `CvvInactive` member gets no batch builder, because its proposer does not run (`run_epoch.rs:409-425`, `produces_batches` at `:1080-1090`), so those transactions wait in the pool and are sealed once the node re-enters the epoch as `CvvActive`. The refusal is admission-only, "before their pools can retain submissions" (`crates/node/src/engine/inner.rs:145-146`). "Refuses new submissions" is therefore exactly right: not too weak (every new submission on both methods is refused) and not too strong (held transactions are kept, not dropped). If the orchestrator wants it, a safe addition is "and keeps the transactions it already holds until it can seal them again". Edge case: a non-member whose `CvvInactive` carried over from the previous epoch still runs a builder and forwards what its pool holds (`run_epoch.rs:1086-1087`), while still refusing new submissions.

(c) Figures and their computing lines:
- Dial: 10 s per address = `handshake_timeout: Duration::from_secs(10)` `crates/config/src/network/quic.rs:67` (effective min(10, idle 30), `quic.rs:11`). At most four addresses = `MAX_ADVERTISED_MULTIADDRS = 4` `crates/node-record/src/addresses.rs:11`. 45 s DERIVED: `DIAL_TIMEOUT_SLACK` 5 s (`consensus.rs:186`) + 4 x 10 s, folded at `consensus.rs:675-677` and applied by `with_connection_timeout` at `consensus.rs:881`. (The peer manager's dial timeout is max(15 s, 45 + 5) = 50 s, `consensus.rs:678-683`, `network.rs:874`; the spec does not print it.)
- 128 established per swarm = `MAX_ESTABLISHED_CONNECTIONS` `consensus.rs:227` (constant; its doc derives it as 2 x (39 + 25) = 128, `consensus.rs:223-224`). 8 per peer = `MAX_ESTABLISHED_CONNECTIONS_PER_PEER` `consensus.rs:216`. 1,024 pending = `MAX_PENDING_INCOMING_CONNECTIONS` `consensus.rs:247`. All three per swarm (`consensus.rs:340-341`); 128 and 8 apply when no `process_budget` is set (D1).
- Gossip: 12,000-byte payload = `MAX_GOSSIP_MESSAGE_SIZE` `crates/config/src/network.rs:542`. 24,579 DERIVED: `GOSSIP_FRAME_BOUND` = max(12,000 + 512, 16,384 + 3) = 16,387 (`gossip_config.rs:26,34,46,54-57`), plus `GOSSIP_READ_CHUNK` 8,192 (`:41`) = 24,579 (`GOSSIP_MAX_TRANSMIT_SIZE`, `:63`). 8 messages = `GOSSIP_MAX_PUBLISH_PER_FRAME` `:71`. 16 KiB control = `GOSSIP_CONTROL_SIZE = 16 * 1024` `:34`. All three are strict `>` checks on the raw buffer (gossipsub 0.50.0 `protocol.rs:302,324,335`).
- Sync-stream admission: 2 streams per peer = `MAX_PENDING_REQUESTS_PER_PEER` primary `mod.rs:134`, worker `mod.rs:79`, used as `PeerSlots::new(...)` (primary `:1981`, worker `:730`). 5 s / 1 s = `SYNC_REQUEST_READ_TIMEOUT` / `PUBLIC_SYNC_REQUEST_READ_TIMEOUT` primary `:181,190`, worker `:117,127`. Pools 5 + 4: primary `MAX_CONCURRENT_EPOCH_STREAMS = 5` `:66`, `COMMITTEE_RESERVED_SYNC_STREAMS = 4` `:75`, three classes `:392-396`; worker `MAX_CONCURRENT_BATCH_STREAMS = 5` `:45`, `COMMITTEE_RESERVED_BATCH_STREAMS = 4` `:51`. 200 s = `PUBLIC_EPOCH_PACK_SERVE_TIMEOUT` primary `:200`, public epoch-pack only (`:470-476`).
- DHT: about two records per second = `PUT_RECORD_BUDGET_REFILL_PER_SEC = 2` `crates/network-libp2p/src/peers/manager.rs:135` (burst `PUT_RECORD_BUDGET_BURST = 120`, `:145`, which "about" covers).
- Batch requester: 5 s write = `SYNC_REQUEST_WRITE_TIMEOUT` `crates/consensus/worker/src/network/handle.rs:61`; 5 s acknowledgement = `SYNC_ACK_TIMEOUT` `:52`; 210 s data = `BATCH_STREAM_TOTAL_TIMEOUT` `:46`; 480 s whole fetch = `BATCH_REQUEST_TOTAL_TIMEOUT` `:81` (a constant, documented as two worst honest exchanges of 15 + 5 + 5 + 210 = 235 s plus headroom, `:75-80`).
- Mainnet six-hour epochs: `chain-configs/mainnet/genesis.yaml:98`, ConsensusRegistry storage word `0x...5460` = 21,600 s = 6 x 3,600 (also packed in the stake-config words at `:81`); pinned by `MAINNET_EPOCH_DURATION_SECS: u32 = 21_600` and the test `mainnet_genesis_encodes_the_six_hour_epoch_target` (`crates/telcoin-network-cli/src/genesis/mod.rs:575,620-636`). `parameters.yaml` carries no epoch length.
