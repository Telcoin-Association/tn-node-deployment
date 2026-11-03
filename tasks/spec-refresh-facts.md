# Verified facts for the technical-specification refresh (checked 2026-10-15)

Shared preamble for the R*, C, Q* and F1 agents. Every fact below was checked by the
orchestrator against the telcoin-network worktree at tag `v0.16.0-adiri` (commit d72cc2bcf,
2026-10-08; tn-contracts submodule 10cc12b7). `WT` is that worktree:
`/private/tmp/claude-501/-Users-grant-coding-telcoin-tn-node-deployment/474df373-eb73-43be-adbe-ffcbd2a2657a/scratchpad/tn-v0.16.0-adiri`.
The April 2026 specification text describes the protocol as of roughly `v0.8.1-adiri`
(f61a307d4, 2026-04-10); 486 commits separate the two tags. The code is the primary source;
the mdbook under `WT/docs/src/` and `WT/SYNC.md` are secondary. Cite `path:line` at the tag.

## Confirmed in `git log v0.8.1-adiri..v0.16.0-adiri`

- #970 request-response bumped to `/0.0.2`, frozen legacy variants deleted.
- #820 non-validator transactions pushed to the committee over RPC instead of gossip.
- #1064 dead topic constants dropped; stale epoch, base-fee and hash references corrected in docs.
- #912 consensus-output and epoch-vote gossip restricted to committee publishers.
- #922 mid-epoch validator ejection tolerated in epoch records.
- #1196 an epoch record no longer needs certification to start a new epoch.
- #1101 next-epoch worker base fees written to `WorkerConfigs` at epoch close.
- #1186 gas over-reservation penalty documented and surfaced.
- #1279 region-aware committee draw behind a fork gate, THEN #1328 removed validator regions
  and the region-shuffle fork gate. At the tag the draw is region-blind
  (`crates/tn-reth/src/system_calls.rs:106-109`: the `region` field is held in contract storage
  and not read by the client). Do not document a region-aware draw.
- #1385 node role derived from committee membership; #1417 `--observer` CLI flag removed.
- #1447 validated handshake-start accounting; #1450 early identity refusal (decision recorded
  in `docs/src/network/early-identity-refusal.md`).
- #1260 intra-round commit order keyed on the leader digest behind a fork gate.
- #1311 / #1319 prevrandao fork; #1286 BLS precompile rejects value-bearing calls;
  #1410 governance Safe stack migrated at a fork boundary; #1442 adiri forks armed.

## Facts read from the code at the tag

- Fork gates (`crates/types/src/forks.rs`, epoch numbers for adiri):
  `ADIRI_DUP_BATCH_EPOCH = 160` (line 71), `CONSENSUS_REGISTRY_FORK_EPOCH = 407` (180),
  `SEED_SIGNATURE_FORK_EPOCH = 383` (218), `PREVRANDAO_FORK_EPOCH = 574` (343),
  `MULTI_WORKERS_FORK_EPOCH = 570` (474), `LEADER_SEEDED_ORDERING_FORK_EPOCH = 567` (618),
  `SUBSECOND_TIMESTAMP_FORK_EPOCH = u32::MAX` (772, not armed),
  `GOVERNANCE_SAFE_FORK_EPOCH = 554` (1144). Read each gate's doc comment before citing it.
- Request-response protocol ids (`crates/node-record/src/protocol.rs:36-78`), per role:
  `/tn-primary-{chain_id}/0.0.2`, `/tn-worker-{id}-{chain_id}/0.0.2`; Kademlia
  `/tn-primary-kad-{chain_id}/0.0.1`, `/tn-worker-{id}-kad-{chain_id}/0.0.1`; sync
  `/tn-primary-sync-{chain_id}/0.0.1`, `/tn-worker-{id}-sync-{chain_id}/0.0.1`; peer exchange
  `/tn-primary-peer-exchange-{chain_id}/0.0.1` and the worker form; record exchange
  `/tn-primary-record-exchange-{chain_id}/0.0.1` and the worker form; gossipsub protocol
  `/tn-meshsub-{chain_id}` (line 100). Chain id 2017 on adiri.
- Gossip topics (`crates/config/src/network.rs:351-369`; `docs/src/network/gossip.md:19-24`):
  `tn-primary-{chain_id}` (current committee, `Certificate`), `tn-consensus-output-{chain_id}`
  (previous, current and next committee, `ConsensusResult`), `tn-epoch-vote-{chain_id}` (same
  publishers, `EpochVote`), `tn-worker-{chain_id}-{worker_id}` (current committee, batch digest
  and `(Epoch, BlockHash)`). No transaction topic exists.
- Node modes (`crates/types/src/primary/node_mode.rs:13-24`): `CvvActive`, `CvvInactive`,
  `Observer`. RPC `tn_nodeMode` (`docs/src/rpc-methods/tn/tn_nodemode.md`) returns one of
  the three strings; `CvvInactive` is transient (committee member catching up after a failure,
  returns to `CvvActive` once synced past the garbage-collection window); `Observer` may or may
  not be staked. The `tn` namespace at the tag also documents: tn_delegationDigest,
  tn_epochRecord, tn_epochRecordByHash, tn_genesis, tn_getBalanceBreakdown,
  tn_getBlockTimestampMillis, tn_getBlsPubKey, tn_getCommitteeBlsPubKeys,
  tn_getCommitteeValidators, tn_getCurrentEpoch, tn_getCurrentEpochInfo,
  tn_getCurrentStakeVersion, tn_getEpochInfo, tn_getNextCommitteeSize, tn_getRewards,
  tn_getValidator, tn_getValidators, tn_info, tn_isDelegated, tn_isRetired, tn_isValidator,
  tn_latestConsensusHeader, tn_latestHeader, tn_proofOfPossessionMessage,
  tn_undistributedIssuance (`docs/src/rpc-methods/tn/`).
- Peer penalties: `crates/network-libp2p/src/peers/` has `score.rs`, `penalty.md` (no
  `penalty.rs`), `banned.rs`, `status.rs`, `manager.rs`, `all_peers.rs`, `behavior.rs`.
- The gas over-reservation penalty is documented in `docs/src/gas-penalty.md` (sender-facing)
  and `docs/src/gas-limit-penalty.md`; implementation `crates/tn-reth/src/evm/utils.rs` and
  `crates/tn-reth/src/evm/handler.rs`.
- The TEL precompile lives under `crates/tn-reth/src/evm/tel_precompile/`; the BLS precompile
  under `crates/tn-reth/src/evm/bls_precompile/`.

## Conventions for findings

Each finding: the specification claim (quote), the verdict (`confirmed` / `stale` with
replacement text in the specification's voice / `unverifiable` with what would settle it), and
a `path:line` citation at the tag. Replacement text must be partner-safe: no operator material,
no `--observer`, no personal addresses, no "legacy" except in the EVM sense ("legacy
transactions"). Keep the chapter structure; new material goes only into short subsections where
the plan has a home for it (gas penalty under Execution layer, fork gates under Epoch
boundaries, transaction forwarding under Networking).
