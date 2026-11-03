status: complete (all 9 sections done, summary written)

# Checkpoint R1

Scope: transcription.md lines 14-111 (Architecture overview; Consensus layer).
Sections: 1 Architecture intro, 2 Consensus chain, 3 Execution chain, 4 Epoch chain,
5 Comparison table, 6 Consensus layer intro + Certificate DAG, 7 Total ordering,
8 Equal voting weight + Reputation scheduling, 9 Worker horizontal scaling.

## Completed sections
- 1 Architecture intro
- 2 Consensus chain
- 3 Execution chain
- 4 Epoch chain
- 5 Comparison table
- 6 Consensus layer intro + Certificate DAG
- 7 Total ordering
- 8 Equal voting weight + Reputation scheduling
- 9 Worker horizontal scaling
- Summary

## Findings

## Architecture overview (intro)

### F1 Architecture overview
- claim: "The protocol separates responsibilities across three chains: the Consensus Chain orders transactions, the Execution Chain executes state changes, and the Epoch Chain records committee transitions."
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/primary/block.rs:43-57 (ConsensusHeader), crates/engine/src/payload_builder.rs:114-200 (EVM blocks from output), crates/types/src/primary/epoch.rs (EpochRecord, see F12)
- note: three hash-linked structures exist at the tag with these roles.

### F2 Architecture overview
- claim: "The consensus layer operates on raw bytes with no knowledge of gas, account state, or virtual machine rules."
- verdict: stale
- replacement: "The ordering layer works over batch digests and has no knowledge of gas, account state or virtual machine rules. Workers check each batch against a small set of execution rules before acknowledging it (the transactions decode, every transaction type is on the executable allowlist, the batch fits the gas limit and carries the epoch's base fee), but they never execute it."
- cite: crates/batch-validator/src/validator.rs:46-99, crates/types/src/worker/sealed_batch.rs:67-75
- note: Batch.transactions is still Vec<Vec<u8>>, but validate_batch decodes txs, checks type allowlist, gas and base fee; the sentence as written overstates the separation.

### F3 Architecture overview
- claim: "This modular design allows the execution environment to evolve independently."
- verdict: confirmed
- replacement: n/a
- cite: crates/engine/README.md:3-13, crates/engine/src/payload_builder.rs:114-130
- note: design statement; the engine consumes committed output only, no consensus code depends on EVM state. Soft claim, acceptable.

## Consensus chain

### F4 Consensus chain
- claim: "The Consensus Chain is a hash-linked sequence of blocks that record BFT ordering decisions."
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/primary/block.rs:43-57
- note: ConsensusHeader.parent_hash links to previous header digest.

### F5 Consensus chain
- claim: "Each header contains three fields: a `parent_hash` linking to the previous header, a `sub_dag` capturing the committed sub-DAG of ordered certificates, and a `number` denoting the header's height."
- verdict: stale
- replacement: "Each header carries a `parent_hash` linking to the previous header, a `sub_dag` holding the committed sub-DAG (the ordered headers of the committed certificates, the leader last), and a `number` denoting the header's height. A fourth field, `extra`, is reserved and currently always zero."
- cite: crates/types/src/primary/block.rs:43-57, crates/types/src/primary/output.rs:385-389,417-419
- note: struct has four fields (extra: B256, "currently unused"); CommittedSubDag stores Headers, not Certificates ("stores Headers without certificates").

### F6 Consensus chain
- claim: "The consensus block's digest is computed as the concatenated hash of the block's parent hash, the sub-DAG digest, and the block's strictly monotonically increasing number."
- verdict: stale
- replacement: "The header's digest is a BLAKE3 hash over the parent hash, the sub-DAG digest, the block number (little-endian) and a 32-byte zero placeholder for the reserved field. Numbers increase by one from zero at genesis."
- cite: crates/types/src/primary/block.rs:60-80, crates/types/src/crypto/mod.rs:267
- note: digest_from_parts hashes the three values plus B256::default(); DefaultHashFunction = blake3::Hasher. Minor precision fix; "number of ancestor blocks" per block.rs:50-52.

### F7 Consensus chain
- claim: "This chain advances whenever the BFT protocol commits a new sub-DAG and is the authoritative record of transaction ordering for all nodes on the network."
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/primary/output.rs:111-130, crates/engine/README.md:3-13
- note: one ConsensusOutput (header) per committed sub-DAG; execution consumes outputs in order.

## Execution chain

### F8 Execution chain
- claim: "The Execution Chain is a standard Ethereum-compatible chain of blocks."
- verdict: confirmed
- replacement: n/a
- cite: crates/tn-reth/src/payload.rs:29-105
- note: blocks are reth SealedHeaders built per batch.

### F9 Execution chain
- claim: "The protocol produces exactly one EVM block per committed batch."
- verdict: confirmed
- replacement: n/a
- cite: crates/engine/src/payload_builder.rs:193-200, crates/engine/README.md:7-8
- note: loop builds one block per flattened batch. Adiri epochs at or below 160 (ADIRI_DUP_BATCH_EPOCH) replay a historical duplicate-batch case where a duplicated batch digest yields no second block; testnet-history detail, not needed in a partner spec.

### F10 Execution chain
- claim: "Blocks are only produced when batches contain transactions or when an epoch boundary requires closing."
- verdict: confirmed
- replacement: n/a (optional sharpening: "A committed sub-DAG with no batches produces no block, unless it closes the epoch, in which case a single empty block runs the epoch-closing system calls.")
- cite: crates/engine/src/payload_builder.rs:114-131, crates/batch-builder/src/lib.rs:239-246, crates/batch-validator/src/validator.rs:149
- note: workers never seal empty batches (peers reject EmptyBatch); empty non-closing output is skipped.

### F11 Execution chain
- claim: "Block headers carry consensus metadata in repurposed Ethereum header fields described in detail below. This binding makes every execution block traceable to the consensus decision that ordered its contents."
- verdict: confirmed
- replacement: n/a
- cite: crates/tn-reth/src/payload.rs:37-47,68-74,89-100
- note: parent_beacon_block_root = ConsensusHeader digest, ommers_hash = batch digest, nonce = epoch<<32|round, difficulty packs batch index and worker id, mix_hash = PREVRANDAO, extra_data = shuffle seed on the closing block. Field details belong to the execution-layer reviewer.

## Epoch chain

### F12 Epoch chain
- claim: "The Epoch Chain is a hash-linked sequence of EpochRecords."
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/primary/epoch.rs:22-39, crates/node/src/manager/node/close_epoch.rs:920-940
- note: parent_hash = previous record's digest (BLAKE3 over the encoded record, epoch.rs:43-47); epoch 0 uses a zero parent.

### F13 Epoch chain
- claim: "Each epoch generates exactly one record signed by a quorum of committee nodes (2ƒ+1)."
- verdict: confirmed
- replacement: n/a (see M1 for the timing nuance)
- cite: crates/types/src/primary/epoch.rs:59-95, crates/types/src/committee.rs:1189-1194
- note: record is accepted with floor(2n/3)+1 committee signatures; equals 2f+1 for n = 3f+1, same formula as the certificate quorum (committee.rs:474-479).

### F14 Epoch chain
- claim: "Each record contains the epoch number, the current committee's BLS public keys, the next committee's BLS public keys, a parent hash linking to the previous epoch record, a record of the final execution state (the block number and hash of the last execution block in the epoch), and a record of the final consensus state (the block number and hash of the last ConsensusHeader in the epoch)."
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/primary/epoch.rs:22-39
- note: fields epoch, committee, next_committee, parent_hash, final_state (BlockNumHash), final_consensus (ConsensusNumHash) match one-for-one.

### F15 Epoch chain
- claim: "The outgoing committee signs each EpochRecord with a super-quorum BLS aggregate signature requiring at least two-thirds-plus-one of committee members."
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/primary/epoch.rs:84-102 (super_quorum = 2n/3 + 1), :196-221 (EpochCertificate: aggregate signature + signer bitmap), crates/node/src/manager/epoch_votes.rs:87-98,165-173
- note: votes come only from the record's own committee (the outgoing committee), gathered at the start of the next epoch.

### F16 Epoch chain
- claim: "This chain anchors committee transitions and provides a compact proof of finality across epoch boundaries."
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/primary/epoch.rs:1-7,32-38, crates/state-sync/src/epoch.rs:164-200
- note: syncing nodes walk records from genesis, check each committee against the previous record's next_committee, and use final_consensus as a trusted anchor.

### M1 Epoch chain (missing, #1196)
- claim: n/a (the paragraph implies the record must be certified before the next epoch can proceed)
- verdict: missing
- replacement: "Every node derives the record deterministically from the epoch's closing block, so the next epoch starts without waiting for it. The outgoing committee's signatures are gathered in the background during the first moments of the next epoch, and nodes that join later fetch the record and its certificate from peers."
- cite: crates/node/src/manager/node/close_epoch.rs:898-940 (build_epoch_record), crates/node/src/manager/epoch_votes.rs:20-40,165-173; commit 2ea18beca (#1196)
- note: #1196 removed the certification requirement at epoch start; SYNC.md:18-23 says the same.

### M2 Epoch chain (missing, #922)
- claim: n/a
- verdict: missing
- replacement: "A record's committee normally equals the previous record's next committee. If governance ejects a validator during the epoch, the record carries the smaller committee, which is accepted only if every member was in the expected committee, at least four remain, and at least two-thirds of the expected committee remain."
- cite: crates/types/src/primary/epoch.rs:104-160 (committee_compatible), crates/node/src/manager/node/close_epoch.rs:942-958; commit 123addfa7 (#922)
- note: optional; one sentence fits the paragraph. Check the governance-ejection wording against the validator-lifecycle reviewer's text.

## How the three chains complement each other (table)

### F17 Table / Unit
- claim: "ConsensusHeader | EVM block | EpochRecord"
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/primary/block.rs:43, crates/tn-reth/src/payload.rs:29-31, crates/types/src/primary/epoch.rs:22
- note: type names match.

### F18 Table / Linking
- claim: "Parent hash of previous header | Parent hash of previous block | Parent hash of previous epoch record"
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/primary/block.rs:44-45, crates/tn-reth/src/payload.rs:32-33, crates/types/src/primary/epoch.rs:30-31
- note: all three carry a parent hash.

### F19 Table / Content (Consensus Chain)
- claim: "Committed sub-DAG of ordered certificates"
- verdict: stale
- replacement: "Committed sub-DAG: the ordered headers of the committed certificates, with the leader last"
- cite: crates/types/src/primary/output.rs:385-389,417-421,686
- note: CommittedSubDag keeps Headers; certificates are converted with into_header() at commit time, signatures are dropped.

### F20 Table / Content (Execution, Epoch)
- claim: "Transactions, receipts, state root | Committee keys, finality anchors"
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/primary/epoch.rs:24-38
- note: standard EVM block content; epoch record fields as F14.

### F21 Table / Verification (Consensus Chain)
- claim: "BLS certificate signatures + hash digest"
- verdict: stale
- replacement: "Hash chain back to a trusted header hash (an epoch record's final consensus hash, or a result signed by committee members); certificate signatures are checked when certificates enter the DAG, not stored with the header"
- cite: crates/types/src/primary/output.rs:417-421, crates/state-sync/src/lib.rs:504-526, crates/state-sync/src/consensus.rs:404-411, crates/types/src/primary/block.rs:124-147 (ConsensusResult)
- note: SYNC.md:51 still says "headers include certificates"; the code at the tag stores headers without certificates, so the code wins. ConsensusResult is accepted with committee/3 + 1 signatures (consensus/primary/src/network/handler.rs:415); that number is for the networking/sync reviewer.

### F22 Table / Verification (Execution, Epoch)
- claim: "Standard Ethereum block validation | Super-quorum BLS aggregate signature"
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/primary/epoch.rs:59-89
- note: epoch side confirmed. Execution side: blocks are re-executed from committed output rather than validated as foreign blocks, but the cell is acceptable at this level.

### F23 Table / Advancement
- claim: "Each BFT sub-DAG commit | Each committed batch and/or epoch boundary | Each epoch boundary"
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/primary/output.rs:111-130, crates/engine/src/payload_builder.rs:114-131,193-200
- note: matches F7, F9, F10.

### F24 Table / Purpose
- claim: "Canonical transaction ordering | State transition and EVM compatibility | Committee rotation and cross-epoch finality"
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/primary/epoch.rs:1-7
- note: descriptive; consistent with code roles.

## Consensus layer (intro)

### F25 Consensus layer
- claim: "Telcoin Network uses a DAG-based Byzantine Fault Tolerant consensus protocol composed of two logical sub-protocols: a data availability layer (Narwhal) that constructs a certificate DAG, and a total ordering layer (Bullshark) that derives a deterministic commit sequence from that DAG."
- verdict: confirmed
- replacement: n/a (optional: "Telcoin Network runs Bullshark's partially synchronous variant: safety never depends on timing, liveness needs periods of synchrony.")
- cite: crates/consensus/primary/src/consensus/bullshark.rs:22-38, docs/src/architecture/consensus-layer.md:3,23
- note: Bullshark over a Narwhal DAG at the tag; the mdbook states the partially synchronous variant explicitly.

## Certificate DAG

### F26 Certificate DAG
- claim: "Validators produce signed proposals referencing transaction batches."
- verdict: stale
- replacement: "Each round, every committee member proposes a header that references the digests of batches its workers have had acknowledged and the certificates it holds from the previous round."
- cite: crates/types/src/primary/header.rs:21-37,41-53, crates/types/src/primary/vote.rs:14-27
- note: a header carries no author signature over itself (only the author's BLS seed signature over a per-round seed message, from SEED_SIGNATURE_FORK_EPOCH); the signatures are the voters'. Minor; "signed" is loose rather than wrong.

### F27 Certificate DAG
- claim: "Once a proposal collects a quorum of BLS signatures, it becomes a certificate."
- verdict: confirmed
- replacement: n/a (optional precision: "a quorum (2f+1) of BLS vote signatures over the header digest")
- cite: crates/consensus/primary/src/aggregators/votes.rs:65, crates/types/src/primary/vote.rs:25-26, crates/types/src/committee.rs:474-479
- note: vote aggregator certifies at weight >= quorum_threshold = floor(2N/3)+1.

### F28 Certificate DAG
- claim: "Each certificate references a set of prior certificates from the previous round, forming a directed acyclic graph (DAG)."
- verdict: confirmed
- replacement: n/a (optional precision: "at least a quorum of certificates from the previous round")
- cite: crates/consensus/primary/src/network/handler.rs:966-1018, crates/types/src/primary/header.rs:35-36
- note: parents must be from round-1, same epoch, distinct authors, and reach quorum_threshold.

### F29 Certificate DAG
- claim: "This structure provides two guarantees: data availability (every referenced batch is retrievable by honest validators) and causal ordering (each certificate encodes a partial history of the proposals that preceded it)."
- verdict: confirmed
- replacement: n/a
- cite: crates/consensus/worker/src/quorum_waiter.rs:162-190, docs/src/architecture/transaction-lifecycle.md:11
- note: a batch digest reaches the primary only after a quorum of peer workers acknowledged (stored) the batch, so any certified digest is held by at least f+1 honest workers.

## Total ordering

### F30 Total ordering
- claim: "The ordering layer processes the certificate DAG to create a definitive, final order for all transaction data."
- verdict: confirmed
- replacement: n/a
- cite: crates/consensus/primary/src/consensus/bullshark.rs:116-180
- note: committed sub-DAGs are final; no reorgs (docs/src/architecture/transaction-lifecycle.md:14).

### F31 Total ordering
- claim: "The protocol operates in rounds, with a predetermined schedule selecting a specific leader for each round."
- verdict: stale
- replacement: "The protocol operates in rounds. Every even round has a leader, chosen by a deterministic rotation through the committee that the reputation schedule can adjust (see Reputation scheduling)."
- cite: crates/consensus/primary/src/consensus/leader_schedule.rs:293-306 (leader(): asserts even round, index (round/2 - 1) mod committee size at :301, then swap table), crates/consensus/primary/src/consensus/bullshark.rs:138-141
- note: leaders exist only on even rounds; odd rounds carry the votes.

### F32 Total ordering
- claim: "If a leader's certificate is referenced and acknowledged by a supermajority (quorum) of certificates in the next round, that leader is successfully committed."
- verdict: stale
- replacement: "A leader is committed once at least f+1 certificates of the following round reference it, enough to guarantee that at least one honest validator saw it."
- cite: crates/consensus/primary/src/consensus/bullshark.rs:201-215, crates/types/src/committee.rs:480-485 (validity_threshold = ceil(N/3) = f+1)
- note: the code checks voting_power < validity_threshold, not quorum_threshold. Most consequential correctness fix in this chapter.

### F33 Total ordering
- claim: "When this happens, the protocol automatically commits the leader's certificate and every previous uncommitted certificate linked to it."
- verdict: confirmed
- replacement: n/a (optional sharpening: "...first committing, oldest first, any earlier uncommitted leader it links to, then every uncommitted certificate in each leader's history back to the garbage-collection horizon of 50 rounds.")
- cite: crates/consensus/primary/src/consensus/bullshark.rs:216-232,300-339, crates/consensus/primary/src/consensus/utils.rs:30-62, chain-configs/mainnet/parameters.yaml (gc_depth: 50; testnet the same)
- note: order_leaders walks back over linked earlier leaders; order_dag stops at gc_round+1.

### M3 Total ordering (missing, #1260)
- claim: n/a
- verdict: missing
- replacement: "Within a committed sub-DAG, certificates are ordered by round, and the leader comes last. Certificates of the same round are ordered by a hash of the epoch's seed chain value and the certificate digest, a value no proposer can predict when it builds its header, so no validator can choose where its batches land in the execution order."
- cite: crates/consensus/primary/src/consensus/utils.rs:63-110 (order_dag sort, intra_round_key), crates/types/src/forks.rs:580-618 (LEADER_SEEDED_ORDERING_FORK_EPOCH = 567 on adiri, active from genesis on other builds)
- note: the fork epoch belongs in the fork-gates subsection under Epoch boundaries, not here.

### F34 Total ordering / sub-DAG contents
- claim: "Certificates: signed proposals referencing transaction batches" / "Leader certificate: the anchor from which the sub-DAG is derived"
- verdict: stale
- replacement: "Headers: the headers of the committed certificates, ordered by round, each referencing transaction batches (signatures are checked before commit and not kept)" / "Leader: the last header, the anchor from which the sub-DAG is derived"
- cite: crates/types/src/primary/output.rs:385-389,417-421,686
- note: CommittedSubDagInner.headers: Vec<Header>; "the last element MUST be the leader".

### F35 Total ordering / sub-DAG contents
- claim: "Reputation scores: per-validator performance metrics for the round"
- verdict: stale
- replacement: "Reputation scores: each validator's running score for the current scheduling window"
- cite: crates/types/src/primary/output.rs:390-391, crates/consensus/primary/src/consensus/bullshark.rs:61-112
- note: scores carry over from the previous commit and reset every 60 committed leaders (crates/node/src/primary.rs:33); not per round.

### F36 Total ordering / sub-DAG contents
- claim: "Commit timestamp: the canonical time assigned to the commit"
- verdict: confirmed
- replacement: n/a (optional: "...the leader's timestamp, never earlier than the previous commit's")
- cite: crates/types/src/primary/output.rs:392-397,641-651
- note: whole seconds; the sub-second variant is behind SUBSECOND_TIMESTAMP_FORK_EPOCH = u32::MAX (not armed), so do not document milliseconds.

### M4 Total ordering / sub-DAG contents (missing)
- claim: n/a
- verdict: missing
- replacement: list item "Seed value: the epoch's seed chain value after this commit, derived from the leader's BLS seed signature; it feeds the block's PREVRANDAO and, at the epoch's last commit, the draw of the next committee"
- cite: crates/types/src/primary/output.rs:398-407,653-684, crates/tn-reth/src/payload.rs:89-100
- note: the `randomness` field is the fourth wire field of the sub-DAG; the execution reviewer owns PREVRANDAO detail, so keep this to one line.

### F37 Total ordering
- claim: "The protocol decouples data dissemination from transaction ordering, allowing both to advance at network speed."
- verdict: confirmed
- replacement: n/a
- cite: crates/consensus/primary/src/proposer.rs:966-978, chain-configs/mainnet/parameters.yaml (min_header_delay 1s, max_header_delay 1s)
- note: workers disseminate batches independently; a header goes out as soon as parents reach quorum and enough batch digests are pending, otherwise on the min/max header delay timers.

## Equal voting weight

### F38 Equal voting weight
- claim: "All staked validators carry equal voting weight in consensus regardless of individual stake amount."
- verdict: stale
- replacement: "Every member of the epoch's committee carries one equal vote in consensus. Staked validators outside the committee for that epoch do not vote."
- cite: crates/types/src/committee.rs:26,307-309,978-984,487-489,473-478, crates/tn-reth/src/evm/block.rs:1540-1555 (committee drawn from active validators)
- note: EQUAL_VOTING_POWER = 1 for every authority; quorum math counts members. "All staked validators" overstates who votes; the committee is a per-epoch draw.

### F39 Equal voting weight
- claim: "This prevents large stakeholders from dominating block production or commit decisions."
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/committee.rs:1189-1194
- note: design rationale; also every validator stakes the same fixed amount per stake version (tn-contracts/src/consensus/StakeManager.sol:288-292), so stake size cannot differ within a version anyway.

### F40 Equal voting weight
- claim: "Economic incentives still favor larger stakes through stake-weighted reward distribution, but consensus power remains uniformly distributed across the validator set."
- verdict: stale
- replacement: "Each validator stakes the fixed amount its stake version requires. Epoch rewards are shared in proportion to effective stake (that amount, reduced if slashed) multiplied by the number of committed leader turns the validator held in the epoch, while consensus power stays uniform across the committee."
- cite: tn-contracts/src/consensus/ConsensusRegistry.sol:133-187 (weight = min(balance, version stakeAmount) * consensusHeaderCount), tn-contracts/src/consensus/StakeManager.sol:288-292, crates/engine/src/payload_builder.rs:44
- note: "larger stakes" is misleading: stake amounts are fixed per version; the variable part is leader turns.

## Reputation scheduling

### F41 Reputation scheduling
- claim: "The protocol maintains per-validator reputation scores that track participation and reliability each round."
- verdict: stale
- replacement: "The protocol keeps a reputation score for each committee member over a window of 60 committed leaders. The window resets at its end and at every epoch."
- cite: crates/consensus/primary/src/consensus/bullshark.rs:61-112, crates/node/src/primary.rs:33, crates/consensus/primary/src/consensus/reputation.md:92-160,208-220
- note: scores update per commit, not per round; reset at window and epoch start.

### F42 Reputation scheduling
- claim: "Validators that consistently produce certificates and acknowledge peers' proposals accumulate higher scores."
- verdict: stale
- replacement: "A validator gains a point each time its certificate in the round after a committed leader references that leader."
- cite: crates/consensus/primary/src/consensus/bullshark.rs:81-89
- note: the only scoring event; there is no negative scoring or decay (reputation.md:46-60).

### F43 Reputation scheduling
- claim: "These scores influence the leader scheduling algorithm."
- verdict: confirmed
- replacement: n/a
- cite: crates/consensus/primary/src/consensus/bullshark.rs:361-378, crates/consensus/primary/src/consensus/leader_schedule.rs:62-200
- note: final scores of each window build the LeaderSwapTable.

### F44 Reputation scheduling
- claim: "Reliable validators receive priority in leader selection, while underperforming validators are deprioritized."
- verdict: stale
- replacement: "Leadership rotates evenly through the committee. At the end of each window, validators whose scores fall far below the best (roughly two standard deviations, and never more than a third of the committee) lose their leader turns for the next window; each lost turn goes to a validator drawn deterministically from the top scorers."
- cite: crates/consensus/primary/src/consensus/leader_schedule.rs:63-200 (good/bad lists, std-dev gate, 33% cap), :210-230 (swap seeded by round, ChaCha12 at :221), crates/types/src/primary/mod.rs:39 (DEFAULT_BAD_NODES_STAKE_THRESHOLD = 33)
- note: in normal operation both lists are empty and no swap happens; "priority" overstates it.

### F45 Reputation scheduling
- claim: "This mechanism encourages liveness and penalizes absent or slow validators without requiring explicit slashing at the consensus layer."
- verdict: confirmed
- replacement: n/a (optional link: "Because rewards follow committed leader turns, a validator that loses its turns also earns less.")
- cite: crates/consensus/primary/src/consensus/reputation.md:167-175, tn-contracts/src/consensus/ConsensusRegistry.sol:161
- note: the only effect is losing leader turns; no voting-power change, no slashing.

### F46 Reputation scheduling
- claim: "The protocol distributes block rewards to every leader at the end of each epoch."
- verdict: confirmed
- replacement: n/a (optional: "...in proportion to stake and the number of committed leader turns, see Equal voting weight")
- cite: crates/engine/src/payload_builder.rs:44, crates/types/src/gas_accumulator.rs:138-155, crates/tn-reth/src/evm/block.rs:527, tn-contracts/src/consensus/ConsensusRegistry.sol:133-187
- note: leader count increments for every committed output, including empty ones; applyIncentives runs at the epoch-closing block; retired validators are skipped.

## Worker horizontal scaling

### F47 Worker horizontal scaling
- claim: "Each validator operates one or more workers that independently construct transaction batches."
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/committee.rs:1072-1080, crates/node/src/engine/inner.rs:145-190; commit 4ff09cd99 (#1390, all committee workers start each epoch)
- note: the text gives no worker count. Genesis configs set one (chain-configs/mainnet/committee.yaml:53; testnet omits the key, default one). The live adiri count is the on-chain WorkerConfigs.numWorkers, not visible in code.

### F48 Worker horizontal scaling
- claim: "Workers are parallel lanes for data ingestion and must be uniform across all validator nodes."
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/committee.rs:1072-1080 ("all nodes have to agree on this and be running the required number of workers"), crates/types/src/worker/sealed_batch.rs:94-97 (worker N talks to other worker Ns)
- note: worker count is a committee-level value.

### F49 Worker horizontal scaling
- claim: "Each worker lane maintains its own base fee and processes transactions concurrently with other workers on the same validator."
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/worker/sealed_batch.rs:76-86, crates/node/src/engine/inner.rs:145-190
- note: base fee keyed by worker_id, fixed for the epoch; each worker has its own transaction pool and RPC server.

### M5 Worker horizontal scaling (missing)
- claim: n/a
- verdict: missing
- replacement: "Each worker has its own transaction pool and its own RPC endpoint, so a transaction joins the lane of the endpoint it was submitted to."
- cite: crates/node/src/engine/inner.rs:155,169-181 (per-worker pool and RPC server), crates/tn-reth/src/env/rpc.rs:346-352 (#1287, distinct ports per worker)
- note: one sentence after F49. Check it does not clash with the networking reviewer's text on transaction forwarding (#820).

### F50 Worker horizontal scaling / batch metadata
- claim: "Beneficiary: the validator's address, used for priority fee distribution"
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/worker/sealed_batch.rs:74-76, crates/engine/README.md:39 (beneficiary is covered by the batch digest, #1222)
- note: the producing validator's execution address receives the batch's priority fees.

### F51 Worker horizontal scaling / batch metadata
- claim: "Base fee: the per-worker fee at the time of batch construction"
- verdict: stale
- replacement: "Base fee: the worker's base fee for the epoch. Every validator's worker of the same ID carries the same value, which changes only at an epoch boundary"
- cite: crates/types/src/worker/sealed_batch.rs:76-86, crates/batch-validator/src/validator.rs:86-87
- note: "at the time of batch construction" implies a per-batch value; peers reject any batch whose fee differs from the epoch's value (InvalidBaseFee).

### F52 Worker horizontal scaling / batch metadata
- claim: "Worker ID: identifies the originating worker lane" / "Transactions: the ordered set of transactions in the batch"
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/worker/sealed_batch.rs:63-71,94-97
- note: transactions are encoded bytes in proposer order.

### M6 Worker horizontal scaling / batch metadata (missing)
- claim: n/a
- verdict: missing
- replacement: list item "Epoch: the epoch the batch was built for; peers reject a batch from any other epoch"
- cite: crates/types/src/worker/sealed_batch.rs:72-73, crates/batch-validator/src/validator.rs:62-67
- note: the list omits a field that the batch carries and that validation checks.

### F53 Worker horizontal scaling
- claim: "Scaling the number of workers is configurable through on-chain governance at each epoch boundary."
- verdict: confirmed
- replacement: n/a
- cite: tn-contracts/src/consensus/WorkerConfigs.sol:122-134 (setNumWorkers, onlyOwner), crates/types/src/committee.rs:1072-1080 (read at the previous epoch's closing block)
- note: on adiri the count had to stay at one until MULTI_WORKERS_FORK_EPOCH = 570 (crates/types/src/forks.rs:474); that belongs in the fork-gates subsection.

### F54 Worker horizontal scaling
- claim: "The DAG and ordering layers are agnostic to the number of workers per validator and operate solely over certificates that reference batches regardless of origin."
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/primary/header.rs:33-34,189-194, crates/consensus/primary/src/consensus/utils.rs:30-110
- note: ordering ignores worker ids. Header validation still rejects a worker id at or above the committee's worker count, which is acceptable at this level of detail.

### F55 Worker horizontal scaling
- claim: "This enables the protocol to support multiple execution environments if ever desirable."
- verdict: unverifiable
- replacement: n/a (suggest softening to "The design leaves room for workers dedicated to other execution environments, though every worker today carries EVM transactions." or dropping)
- cite: crates/batch-validator/src/validator.rs:75-84 (every worker decodes and gas-checks EVM transactions), crates/engine/src/payload_builder.rs:193-200 (every batch becomes an EVM block)
- note: forward-looking design claim. No code path at the tag supports a non-EVM lane. A maintainer statement of intent would settle whether to keep it.

## Not checked (no numbers in scope)
The chapters in scope state no round timing, batch size or GC depth numbers, so none were verified as claims. For reference, at the tag the genesis parameters are gc_depth 50, min_header_delay 1s, max_header_delay 1s mainnet / 3s testnet, max_batch_delay 1s, header_num_of_batches_threshold 5, max_header_num_of_batches 10 (chain-configs/{mainnet,testnet}/parameters.yaml), and the batch gas limit is 30,000,000 (crates/types/src/worker/sealed_batch.rs:197-199).

## Summary
- Findings: 55 F-blocks + 6 M-blocks = 61.
- confirmed: 38 (F1, F3, F4, F7-F18, F20, F22-F25, F27-F30, F33, F36, F37, F39, F43, F45-F50, F52-F54)
- stale: 16 (F2, F5, F6, F19, F21, F26, F31, F32, F34, F35, F38, F40, F41, F42, F44, F51; F6 and F26 are precision fixes only)
- unverifiable: 1 (F55)
- missing: 6 (M1 #1196 record certified in background; M2 #922 mid-epoch ejection; M3 #1260 seeded intra-round order; M4 sub-DAG seed value; M5 per-worker pool/RPC; M6 batch epoch field)
- Most consequential stale: F32 (leader commit needs f+1 support, not a quorum); F21/F19/F34/F5 (committed sub-DAGs hold headers, not certificates, so consensus-chain verification is a hash chain to a certified epoch record, not BLS signatures); F44/F41/F42 (reputation only swaps far-below-average validators out of an even rotation, 60-commit window, single scoring event); F38/F40 (only committee members vote; stake is fixed per version and rewards weight stake x leader turns).
