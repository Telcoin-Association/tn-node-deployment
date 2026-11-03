status: complete (all sections done)

# Checkpoint R2a — Execution layer (transcription lines 112-179)

Completed sections: 1 Execution layer intro, 2 EVM block production, 3 Repurposed block header metadata, 4 System calls, 5 Gas over-reservation penalty (new), 6 Summary

Source: WT = scratchpad/tn-v0.16.0-adiri at tag v0.16.0-adiri (d72cc2bcf). Citations are WT-relative `path:line`.
Path check: every start path named in the brief exists at the tag (`crates/tn-reth/src/system_calls.rs`,
`evm/block.rs`, `evm/utils.rs`, `evm/handler.rs`, `evm/tel_precompile/`, `evm/bls_precompile/`,
`crates/engine/src/payload_builder.rs`, `crates/types/src/forks.rs`, the four docs). Header fields are
assembled in `crates/tn-reth/src/evm/block.rs:2079-2149` (`TNBlockAssembler::assemble_block`) from the
ctx built in `crates/tn-reth/src/evm/config.rs:240-257` (`context_for_next_block`) and the env built in
`config.rs:164-203` (`next_evm_env`); the payload values come from `crates/tn-reth/src/payload.rs:117-150`
and `crates/engine/src/payload_builder.rs:130-257`.

## 1. Execution layer (intro, lines 114-118)

### F1 Execution layer
- claim: "The execution layer processes committed sub-DAGs and maintains the EVM state trie."
- verdict: confirmed
- replacement: n/a
- cite: crates/engine/src/payload_builder.rs:19-25, crates/engine/src/payload_builder.rs:305-322
- note: `execute_consensus_output` executes each output against reth and persists the blocks and state.

### F2 Execution layer
- claim: "Sub-DAGs technically only contain batch digests."
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/primary/output.rs:417-424, crates/types/src/primary/output.rs:47-60
- note: `CommittedSubDag` holds headers (whose payload is batch digests); the batches themselves ride separately in `ConsensusOutputInner::batches`.

### F3 Execution layer
- claim: "The sub-DAG batch digests are used to map batch data so the execution layer has full transaction bytes before execution."
- verdict: confirmed
- replacement: n/a
- cite: crates/consensus/executor/src/subscriber.rs:459-481, crates/types/src/primary/output.rs:53-60
- note: the subscriber's `fetch_batches` resolves each digest to its batch (local store, then peers) and records the ordered digests.

### F4 Execution layer
- claim: "The protocol refers to sub-DAGs with restored batch data as “consensus output”."
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/primary/output.rs:71-74
- note: `ConsensusOutput` doc: "includes all the blocks for each certificate in the sub dag".

### F5 Execution layer
- claim: "Consensus output contains all ordered batches of transactions which are executed to apply deterministic state transitions, enforcing protocol rules through a combination of user transactions and system calls."
- verdict: confirmed
- replacement: n/a
- cite: crates/tn-reth/src/evm/block.rs:1-16, crates/tn-reth/src/evm/block.rs:1858-1877
- note: block executor runs user transactions plus pre-block and epoch-close system calls.

## 2. EVM block production (lines 122-127)

### F6 EVM block production
- claim: "Each batch within a consensus output produces exactly one EVM block."
- verdict: confirmed
- replacement: n/a
- cite: crates/engine/src/payload_builder.rs:197-257
- note: one `TNPayload` and one `execute_payload` per flattened batch.

### F7 EVM block production
- claim: "Blocks are created sequentially in batch order, and each block's resulting state changes are committed to the EVM state trie."
- verdict: confirmed
- replacement: optional precision: "Blocks are created sequentially in batch order, each on top of the state left by the one before; the blocks of one consensus output are written to the database together once the whole output has executed."
- cite: crates/types/src/primary/output.rs:214-228, crates/engine/src/payload_builder.rs:96-104, crates/engine/src/payload_builder.rs:296-318
- note: `flatten_batches` fixes the order; per-block state roots layer over one output-scoped overlay and `persist_output_with_retry` commits the output atomically.

### F8 EVM block production
- claim: "When a consensus output contains no batches, block production depends on the epoch boundary."
- verdict: confirmed
- replacement: n/a
- cite: crates/engine/src/payload_builder.rs:114-130
- note: `batches.is_empty()` branches on `output.close_epoch()`.

### F9 EVM block production
- claim: "If the consensus output contains no batches and is the last committed sub-DAG for the epoch, the execution layer conducts closing epoch protocol transactions using system calls."
- verdict: confirmed
- replacement: optional precision: "If the consensus output contains no batches and is the last committed sub-DAG for the epoch, the execution layer produces a single empty block, credited to the committing leader, that carries the epoch-closing system calls."
- cite: crates/engine/src/payload_builder.rs:130-174, crates/types/src/primary/output.rs:259-268
- note: empty block uses parent base fee and gas limit, leader's execution address as beneficiary, zero batch digest; `close_epoch_for_last_batch` is true for an empty output.

### F10 EVM block production
- claim: "Otherwise, no state changes occur."
- verdict: confirmed
- replacement: optional precision: "Otherwise no block is produced and no state changes occur, though the commit still counts toward its leader's share of the epoch rewards."
- cite: crates/engine/src/payload_builder.rs:115-129, crates/engine/src/payload_builder.rs:44
- note: execution is skipped and the canonical header returned unchanged; the leader count is incremented before the branch.

### F11 EVM block production (addition)
- claim: (none; natural home for the two protocol precompiles)
- verdict: missing
- replacement: "Every EVM instance carries two protocol precompiles beside the standard Ethereum set: the TEL precompile at `0x00000000000000000000000000000000000007e1`, which manages issuance of the native token (timelocked mint and claim, burn, and total supply, gated to governance), and a BLS12-381 signature verifier at `0x000000000000000000000000000000000000b151`, which the ConsensusRegistry uses to check validators' proofs of possession. Both reject calls that carry value, except the TEL precompile's governance burn."
- cite: crates/tn-reth/src/evm/factory.rs:55-68, crates/tn-reth/src/evm/tel_precompile/mod.rs:1-21, crates/tn-reth/src/evm/tel_precompile/mod.rs:101-102, crates/tn-reth/src/evm/bls_precompile/mod.rs:1-22, crates/tn-reth/src/evm/bls_precompile/mod.rs:51, crates/tn-reth/README.md:270-284
- note: #1286 is the BLS "rejects value" change (bls_precompile/mod.rs:18-22); EVM target for the Introduction owner: Prague active from genesis, Osaka not (crates/types/src/genesis.rs:83-84; docs/src/evm-compatibility.md:13 "through Prague/Pectra").

## 3. Repurposed block header metadata (lines 131-152)

### F12 Repurposed block header metadata
- claim: "The protocol repurposes several Ethereum block header fields to carry consensus-layer metadata."
- verdict: confirmed
- replacement: n/a
- cite: crates/tn-reth/src/evm/block.rs:2102-2108, crates/tn-reth/src/evm/block.rs:2118-2144
- note: `assemble_block` fills `ommers_hash`, `nonce`, `difficulty`, `extra_data`, `parent_beacon_block_root`, `mix_hash` with TN values.

### F13 Repurposed block header metadata
- claim: "This data does not affect state changes and is included to support indexing tools, block explorers, and other services that read block headers directly."
- verdict: stale
- replacement: "Most of these values do not change execution and are included for indexing tools, block explorers and other services that read block headers directly. Two are visible to contracts: `mix_hash` is the `PREVRANDAO` value, and `parent_beacon_block_root` is written to the beacon roots contract."
- cite: crates/tn-reth/src/evm/config.rs:190-195, crates/tn-reth/src/payload.rs:152-165, crates/tn-reth/src/evm/block.rs:1731-1767
- note: `prevrandao` in the block env is the header's `mix_hash`; the EIP-4788 call writes `parent_beacon_block_root` into contract storage. (This was arguably imprecise at v0.8.1 too; the PREVRANDAO fork makes `mix_hash` a deliberate contract-facing value.)

### F14 Repurposed Fields — rows confirmed unchanged
- claim: "`nonce` | PoW mining nonce | Epoch and consensus round, packed as: `(epoch << 32) | round`"; "`difficulty` | Network difficulty | Worker ID and batch index, packed as: `(batch_index << 16) | worker_id`"; "`ommers_hash` | Uncle block hash | Digest of the consensus `Batch` executed to produce this block. `B256::ZERO` if closing the epoch with zero batches"; "`parent_beacon_block_root` | Beacon chain parent root | Digest of the `ConsensusHeader` that committed the transactions"
- verdict: confirmed
- replacement: n/a (optional precision for `nonce`: "Epoch and round of the committing leader, packed as `(epoch << 32) | round`")
- cite: crates/types/src/primary/header.rs:254-257, crates/tn-reth/src/evm/block.rs:2104; crates/tn-reth/src/evm/config.rs:251, crates/tn-reth/src/evm/block.rs:207-212; crates/tn-reth/src/evm/config.rs:249, crates/engine/src/payload_builder.rs:162-166; crates/tn-reth/src/payload.rs:71-73, crates/tn-reth/src/payload.rs:167-170, crates/engine/src/payload_builder.rs:45-46
- note: no fork gate touches these four at the tag; `nonce` is `output.nonce()` = leader header nonce; `difficulty` low 16 bits = worker id is also how `first_batch()` gates the EIP-4788 call (block.rs:207-238).

### F15 Repurposed Fields — `mix_hash`
- claim: "`mix_hash` | PoW mix digest | Consensus output digest XOR'd with batch digest. If no batches, just the output digest"
- verdict: stale
- replacement: "`mix_hash` | PoW mix digest (`PREVRANDAO` after the Merge) | The block's `PREVRANDAO`: `keccak256(\"TN_PREVRANDAO_V1\" || epoch seed chain value as of this commit || consensus block number || batch index)`, the last two as little-endian 64-bit integers. Unique per block and resistant to payload grinding, but the committing leader can compute it before broadcasting, so contracts that need unbiasable randomness must not rely on it alone. On the adiri testnet, blocks before epoch 574 carry the earlier form, the consensus output digest XOR'd with the batch digest."
- cite: crates/types/src/primary/output.rs:304-338, crates/types/src/primary/output.rs:343-354, crates/types/src/forks.rs:343, crates/types/src/forks.rs:363-365, crates/types/src/forks.rs:388-398, crates/engine/src/payload_builder.rs:236-239
- note: PREVRANDAO fork (#1311/#1319): `prevrandao_seed_active` = seed fork AND prevrandao fork; non-adiri (mainnet) builds active from genesis, adiri from epoch 574. Mirrors docs/src/evm-compatibility.md:123,130-139.

### F16 Repurposed Fields — `extra_data`
- claim: "`extra_data` | Arbitrary miner data | `keccak256(BLS aggregate signature)` at epoch boundaries, otherwise empty bytes"
- verdict: stale
- replacement: "`extra_data` | Arbitrary miner data | On the block that closes an epoch, the 32-byte committee-shuffle seed (the epoch seed chain value as of the closing commit); empty bytes otherwise. On the adiri testnet, epochs before 383 used `keccak256` of the leader certificate's aggregate BLS signature."
- cite: crates/tn-reth/src/evm/block.rs:2107-2108, crates/tn-reth/src/payload.rs:91-100, crates/types/src/primary/output.rs:282-297, crates/types/src/forks.rs:218, crates/types/src/forks.rs:253-263
- note: seed-signature fork (#1032/#1086): adiri epoch 383, mainnet from genesis; the value also seeds the committee shuffle and is read back on replay (config.rs:205-221). Mirrors evm-compatibility.md:126.

### F17 Repurposed Fields — `base_fee_per_gas`
- claim: "`base_fee_per_gas` | Adjusts per block (EIP-1559) | Fixed for the entire epoch, adjusted at epoch boundaries"
- verdict: stale
- replacement: "`base_fee_per_gas` | Adjusts per block (EIP-1559) | Fixed for the entire epoch for each worker lane and adjusted at epoch boundaries, either by the EIP-1559 rule against the lane's gas target or to a governance-set static fee"
- cite: crates/engine/src/payload_builder.rs:232-233, crates/types/src/gas_accumulator.rs:70-81, crates/types/src/gas_accumulator.rs:546-570, crates/tn-reth/src/evm/block.rs:566-608
- note: the block takes its batch's base fee; fees are per worker (`WorkerFeeConfig::Eip1559 | Static` from the WorkerConfigs contract), and the next epoch's EIP-1559 fees are written on chain at epoch close (#1101). Epoch-flat stays true (docs/src/basefees.md:11-15).

### F18 Repurposed Fields — `withdrawals`
- claim: "`withdrawals` | Beacon chain withdrawals | Validator reward records at epoch boundaries, otherwise empty"
- verdict: confirmed
- replacement: optional precision: "On the block that closes an epoch, one record per validator: its execution address and, in the amount field, the number of committed leader rounds it led that epoch (the weight used for rewards, not a TEL amount); empty otherwise"
- cite: crates/tn-reth/src/evm/block.rs:2109-2116, crates/types/src/gas_accumulator.rs:170-206
- note: `generate_withdrawals` maps address -> leader count with index and validator_index 0.

### F19 Repurposed Fields — missing rows
- claim: (none; `beneficiary` and `timestamp` also carry TN-specific meaning)
- verdict: missing
- replacement: two rows:
  "`beneficiary` | Block proposer's fee recipient | Execution address carried in the batch by the validator that produced it; it receives the batch's priority fees. The empty block that closes an epoch names the committing leader's execution address"
  "`timestamp` | Proposer-set block time | Commit time of the consensus sub-DAG in whole seconds; every block from one consensus output shares it. The millisecond commit time is available through the `tn_getBlockTimestampMillis` RPC method"
- cite: crates/engine/src/payload_builder.rs:240-247, crates/engine/src/payload_builder.rs:154-157, crates/tn-reth/src/evm/handler.rs:165-175; crates/tn-reth/src/payload.rs:48-67, crates/tn-reth/src/payload.rs:275-282, crates/types/src/primary/output.rs:178-184, docs/src/rpc-methods/tn/tn_getblocktimestampmillis.md:3
- note: beneficiary is the producer's `Batch::beneficiary`, covered by the batch digest (#1222). SUBSECOND_TIMESTAMP fork (forks.rs:772) is not armed on adiri (u32::MAX) and active from genesis on mainnet; either way the EVM `timestamp` stays in seconds, the fork only adds a non-decreasing clamp and millisecond commit times in consensus.

### F20 Fixed / Unused Fields — rows confirmed
- claim: "`requests_hash` | `EMPTY_REQUESTS_HASH` | EIP-7685 deposit requests not used"; "`excess_blob_gas` | `0` | Blob transactions not supported for initial mainnet launch"
- verdict: confirmed
- replacement: n/a (optional wording for the second note, matching docs: "Blob transactions are not supported")
- cite: crates/tn-reth/src/evm/block.rs:2143, crates/tn-reth/src/evm/block.rs:1882-1883; crates/tn-reth/src/evm/block.rs:2097-2098, crates/tn-reth/src/evm/config.rs:62-71
- note: EIP-4844 transactions never reach a block (batch builder skips, batch validator rejects, pool prices out) and blob gas price is pinned to u128::MAX.

### F21 Fixed / Unused Fields — missing rows
- claim: (none; two more header fields are fixed)
- verdict: missing
- replacement: two rows:
  "`gas_limit` | `30,000,000` | Maximum gas per batch; changes only at a protocol fork"
  "`blob_gas_used` | `0` | No blob transactions are executed"
- cite: crates/types/src/worker/sealed_batch.rs:205-209, crates/engine/src/payload_builder.rs:234, crates/engine/src/payload_builder.rs:134; crates/tn-reth/src/evm/block.rs:2099-2100
- note: the empty epoch-closing block copies its parent's gas limit, which is the same 30,000,000.

## 4. System calls (lines 156-178)

### F22 System calls
- claim: "System calls are protocol-level transactions that modify contract state without user initiation."
- verdict: confirmed
- replacement: n/a
- cite: crates/tn-reth/src/evm/mod.rs:220-234, crates/tn-reth/src/system_calls.rs:1-13
- note: `transact_system_call` runs protocol calls outside normal transaction rules.

### F23 System calls table — rows confirmed
- claim: "Caller | `SYSTEM_ADDRESS` (`0xfffffffffffffffffffffffffffffffffffffffe`)"; "Gas price | 0 (no fee charged)"; "Nonce check | Disabled"
- verdict: confirmed
- replacement: n/a (optional precision for gas price: "0, with the block base fee also set to 0 for the call, so no fee is charged and the caller needs no balance")
- cite: crates/tn-reth/src/system_calls.rs:44-45; crates/tn-reth/src/evm/mod.rs:251, crates/tn-reth/src/evm/mod.rs:265-272; crates/tn-reth/src/evm/mod.rs:244-245, crates/tn-reth/src/evm/mod.rs:267-274
- note: the custom handler also skips fee crediting and refunds for `SYSTEM_ADDRESS` (handler.rs:17-20, 101-104, 160-164).

### F24 System calls table — gas limit
- claim: "Gas limit | 30,000,000+"
- verdict: stale
- replacement: "Gas limit | 100,000,000 per call, outside the block gas limit"
- cite: crates/tn-reth/src/evm/mod.rs:67-90, crates/tn-reth/src/evm/mod.rs:246, crates/tn-reth/src/evm/mod.rs:265-272
- note: `SYSTEM_CALL_GAS_LIMIT = 100_000_000` (raised from 30M for the registry-fork migration walk); the block gas limit is swapped to the same value for the call's duration.

### F25 System calls
- claim: "System calls are invisible to users, do not appear in the transaction list, and do not consume block gas."
- verdict: stale
- replacement: "System calls do not appear in the block's transaction list, produce no receipts, and do not count toward the block's gas used. Their effects are visible as contract state; events they emit are not included in receipts or returned by `eth_getLogs`."
- cite: crates/tn-reth/src/evm/block.rs:422-427, crates/tn-reth/src/evm/block.rs:1956-1960, crates/tn-reth/src/evm/mod.rs:67-71, crates/tn-reth/src/system_calls.rs:15-19
- note: "invisible" overstates it: registry, beacon-root and history state changes are readable by any client; only the transaction, receipt, log and gas footprint is absent.

### F26 Pre-execution calls
- claim: "Every block begins with two pre-execution system calls:"
- verdict: stale
- replacement: "Two pre-execution system calls run before a block's transactions. The first runs once per consensus output, in that output's first block; the second runs in every block:"
- cite: crates/tn-reth/src/evm/block.rs:9-16, crates/tn-reth/src/evm/block.rs:1858-1877, crates/tn-reth/src/evm/block.rs:207-238
- note: `apply_pre_execution_changes` gates the EIP-4788 call on `ctx.first_batch()` (batch index 0, read from `difficulty`); both calls are also skipped for block 0.

### F27 Pre-execution calls — consensus root storage
- claim: "Consensus root storage (EIP-4788 style): Writes the ConsensusHeader digest to the beacon roots contract, making consensus-layer data accessible to smart contracts."
- verdict: confirmed
- replacement: optional precision: "Consensus root storage (EIP-4788): Writes the digest of the ConsensusHeader that committed the output to the beacon roots contract, making consensus-layer data accessible to smart contracts. The contract is keyed by block timestamp, so when several consensus outputs commit within the same second, a lookup for that second returns the digest of the last one; the earlier digests remain reachable through the hash-linked consensus chain."
- cite: crates/tn-reth/src/evm/block.rs:1714-1773, crates/tn-reth/src/payload.rs:167-170
- note: target `BEACON_ROOTS_ADDRESS`, calldata = `parent_beacon_block_root` = consensus header digest; same-second overwrite is documented as accepted behavior (block.rs:1720-1730).

### F28 Pre-execution calls — block hash history
- claim: "Block hash history (EIP-2935): Stores the parent block hash in the history contract, extending the range of historically accessible block hashes."
- verdict: confirmed
- replacement: n/a
- cite: crates/tn-reth/src/evm/block.rs:1784-1820, crates/types/src/genesis.rs:83
- note: target `HISTORY_STORAGE_ADDRESS`, calldata = parent hash; Prague is active from genesis so the gate always passes after block 0.

### F29 Epoch-boundary calls
- claim: "Three additional system calls execute at epoch boundaries."
- verdict: stale
- replacement: "Four additional system calls run in the last block of each epoch: `applyIncentives` and `applySlashes` (the slash list is currently always empty) and `concludeEpoch` on the ConsensusRegistry, then `setWorkerConfigsData` on the WorkerConfigs contract, which records each EIP-1559 worker lane's base fee for the next epoch and is skipped when no lane uses EIP-1559 pricing."
- cite: crates/tn-reth/src/evm/block.rs:490-563, crates/tn-reth/src/evm/block.rs:566-608, crates/tn-reth/src/evm/block.rs:649-652, crates/tn-reth/src/system_calls.rs:10-13, crates/tn-reth/src/system_calls.rs:22-25
- note: fourth call added by #1101. On adiri, closes before the ConsensusRegistry fork (epoch 407) replay a legacy two-call sequence (block.rs:514-521); history only, keep out of partner text. The "last block" is the final batch's block of the closing output, or the single empty block (F9).

### F30 Epoch-boundary calls — cross-reference
- claim: "See Section 5 for more details."
- verdict: confirmed
- replacement: style: "See [Epoch boundaries](#epoch-boundaries) for details." (heading link instead of a manual section number)
- cite: transcription.md:194 (chapter 5 is "## Epoch boundaries")
- note: target exists; replace the number with a heading link if the refresh follows the partner-guide convention of unnumbered cross-references.

## 5. Gas over-reservation penalty (new subsection)

### F31 Gas over-reservation penalty
- claim: (none; the April text has no penalty material)
- verdict: missing
- placement: new `###` subsection at the end of the Execution layer chapter, after "System calls" and before "Smart contracts" (it refers to system calls being exempt).
- replacement (each sentence followed by its citation in brackets; strip the brackets when inserting):

  ### Gas over-reservation penalty

  Because consensus orders transactions before they execute, a batch reserves capacity by each transaction's declared gas limit rather than by the gas it ends up using. [docs/src/gas-penalty.md:15-19; crates/tn-reth/src/evm/handler.rs:11-15]
  To keep that capacity from being claimed for free, execution charges a penalty on any transaction whose gas limit exceeds 210,000 and which spends less than 10 percent of that limit, whether it succeeds or reverts; system calls are exempt. [crates/tn-reth/src/evm/utils.rs:13-14; crates/tn-reth/src/evm/utils.rs:53-70; docs/src/gas-penalty.md:25-40; crates/tn-reth/src/evm/handler.rs:101-104]
  The penalty is computed in gas units with deterministic integer arithmetic as `((10^8 - r)^2 × u) / 10^16`, where `r` is the gas spent before EVM refunds divided by the gas limit and scaled by 10^9, and `u` is the gas limit less that gas spent, so it grows quadratically as usage falls below 10 percent and never exceeds the unused gas. [crates/tn-reth/src/evm/utils.rs:15-23; crates/tn-reth/src/evm/utils.rs:63-93; crates/tn-reth/src/evm/handler.rs:84-93; crates/tn-reth/src/evm/handler.rs:123-126; crates/tn-reth/README.md:251-257]
  A 21,000-gas transfer sent with a 420,000 gas limit forfeits 25 percent of its unused gas, and the same transfer sent with a 30,000,000 gas limit forfeits 98.6 percent. [crates/tn-reth/src/evm/utils.rs:44-52; docs/src/gas-penalty.md:71-79]
  The penalty is taken from the sender's unused-gas refund at the transaction's effective gas price, so the sender never pays more than the gas limit times that price. [crates/tn-reth/src/evm/handler.rs:128-139; docs/src/gas-limit-penalty.md:62; docs/src/gas-penalty.md:90-104]
  Like the base fee, the penalty is not burned: it is credited to the chain's base-fee address for governance processing. [crates/tn-reth/src/evm/handler.rs:141-148; crates/tn-reth/README.md:256-257; docs/src/evm-compatibility.md:94-100]
  The receipt does not show the charge, because `gasUsed` excludes it and no log marks it, so wallets and indexers recover it as the sender's balance change less the value sent and `gasUsed × effectiveGasPrice`. [docs/src/gas-penalty.md:109-128]

- cite: docs/src/gas-penalty.md:1-153, docs/src/gas-limit-penalty.md:1-94, crates/tn-reth/src/evm/utils.rs:1-94, crates/tn-reth/src/evm/handler.rs:1-148, crates/tn-reth/README.md:244-268
- note: #1186 (c98f711cd) documented and surfaced the penalty; #1184 made `unused_gas` saturating. Node-side debug lines are operator material and are left out. The example figures are the unit-test-pinned table on `calculate_gas_penalty`.

## Summary

Counts by verdict (one block per claim; grouped blocks F14, F20, F23 cover 4, 2 and 3 table rows):
- confirmed: 19 blocks (F1-F10, F12, F14, F18, F20, F22, F23, F27, F28, F30); several carry optional precision text (F7, F9, F10, F14, F18, F20, F23, F27) and F30 a style fix (heading link)
- stale: 8 (F13 header data "does not affect state", F15 `mix_hash`, F16 `extra_data`, F17 `base_fee_per_gas`, F24 system-call gas limit, F25 "invisible" system calls, F26 "every block" pre-execution calls, F29 three vs four epoch-boundary calls)
- missing: 4 (F11 protocol precompiles, F19 `beneficiary` and `timestamp` rows, F21 `gas_limit` and `blob_gas_used` fixed rows, F31 gas over-reservation penalty subsection)
- unverifiable: 0

Most consequential stale findings:
1. F15 `mix_hash`: now the seed-chain PREVRANDAO `keccak256("TN_PREVRANDAO_V1" || seed || consensus number || batch index)` (mainnet from genesis, adiri from epoch 574), not output digest XOR batch digest.
2. F16 `extra_data`: now the epoch seed chain value (committee-shuffle seed) on the closing block, not keccak256 of the BLS aggregate signature (mainnet from genesis, adiri from epoch 383).
3. F29 epoch boundary: four system calls (applyIncentives, applySlashes, concludeEpoch, setWorkerConfigsData), not three; with F24, the system-call gas budget is 100,000,000, not 30,000,000+.

For other units: EVM target is Prague (Pectra) from genesis, Osaka not activated (crates/types/src/genesis.rs:83-84; docs/src/evm-compatibility.md:13), relevant to the Introduction's pectra statement.
