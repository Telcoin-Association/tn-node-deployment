status: complete (all 7 sections done)

# Checkpoint R2b

Scope: transcription.md lines 194-252, chapter "Epoch boundaries".
Sections: intro, Reward distribution, Slash application, Committee shuffle, Base fee adjustment, Fork scheduling, missing (fork gates).
WT = /private/tmp/claude-501/-Users-grant-coding-telcoin-tn-node-deployment/474df373-eb73-43be-adbe-ffcbd2a2657a/scratchpad/tn-v0.16.0-adiri (tag v0.16.0-adiri, d72cc2bcf; tn-contracts 10cc12b).
Contract paths are WT-relative under `tn-contracts/src/consensus/`.

## Completed sections
- intro (F1-F6)
- Reward distribution (F7-F15)
- Slash application (F16-F17)
- Committee shuffle (F18-F27)
- Base fee adjustment (F28-F33)
- Fork scheduling (F34-F35)
- missing: fork gates (F36)

## Findings

### F1 intro
- claim: "Epochs are timestamp-based intervals whose duration is governed by the `epochDuration` parameter in the `ConsensusRegistry` contract."
- verdict: confirmed
- replacement: n/a
- cite: crates/tn-reth/src/system_calls.rs:127-131, crates/node/src/manager/node/run_epoch.rs:149, tn-contracts/src/consensus/ConsensusRegistry.sol:1411-1419
- note: `EpochInfo.epochDuration` is stamped from the current stake config when each epoch opens; the node sets its boundary to epoch start + `epochDuration`.

### F2 intro
- claim: "Under normal operation, epochs last approximately eight hours, though governance may adjust this value through a multisig transaction."
- verdict: stale
- replacement: On the Adiri testnet epochs last about six hours. Governance can change the duration from the governance Safe, a multisig, by publishing a new stake configuration; each epoch keeps the duration in force when it opened.
- cite: chain-configs/testnet/genesis.yaml:79, crates/types/src/forks.rs:304-308, tn-contracts/src/consensus/ConsensusRegistry.sol:1662-1683, crates/telcoin-network-cli/src/genesis/mod.rs:31-38, crates/types/src/forks.rs:1091
- note: adiri genesis registry slot 0x13 holds 0x5460 = 21,600 s; forks.rs records a measured live mean of 21,602 s (about 6.001 h). Eight hours is only the genesis CLI default (genesis/mod.rs:93); the mainnet config is a placeholder (24 h). `upgradeStakeVersion` is owner-only, the owner defaults to the governance Safe (config/src/genesis.rs:39), and the Safe fork (#1410) left owners and threshold untouched, so the multisig wording still holds.

### F3 intro
- claim: "An epoch boundary is detected when a committed sub-DAG's timestamp exceeds the current epoch's end time."
- verdict: stale
- replacement: An epoch boundary is reached when a committed sub-DAG's commit timestamp, in whole seconds, reaches the epoch's end time: the epoch's start plus its duration.
- cite: crates/types/src/primary/output.rs:830-839, crates/node/src/manager/node/run_epoch.rs:149
- note: the predicate is `commit_timestamp() >= boundary` (reaches, not strictly exceeds); minor wording fix.

### F4 intro
- claim: "When this happens, a `close_epoch` flag triggers a deterministic sequence of system calls."
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/primary/output.rs:270-280, crates/tn-reth/src/evm/block.rs:19-22, crates/engine/src/payload_builder.rs:98-131
- note: when the final output has no batches, one empty block is built to carry the calls.

### F5 intro
- claim: "All validators execute these calls identically, producing consistent state transitions across the network."
- verdict: confirmed
- replacement: n/a
- cite: crates/tn-reth/src/evm/block.rs:69-71, crates/tn-reth/src/evm/block.rs:403-428
- note: every node that executes the chain (not only validators) runs them; any failure halts execution rather than committing a divergent block.

### F6 intro
- claim: "Three system calls execute in strict order at every epoch boundary: `applyIncentives`, `applySlashes`, and `concludeEpoch`."
- verdict: stale
- replacement: Four system calls run in strict order in the epoch's closing block: `applyIncentives`, `applySlashes` and `concludeEpoch` on the `ConsensusRegistry`, then `setWorkerConfigsData` on the `WorkerConfigs` contract, which records each worker's base fee for the next epoch. When a one-time contract upgrade is scheduled for the boundary, it runs first.
- cite: crates/tn-reth/src/evm/block.rs:19-61, crates/tn-reth/src/evm/block.rs:489-565
- note: #1101 added the fourth call. Adiri closes before epoch 407 replay the earlier two-call sequence (`applyIncentives`, `concludeEpoch`) for history (block.rs:508-519, 713-722); not partner-relevant.

### F7 Reward distribution
- claim: "Throughout the epoch, the protocol maintains a count of consensus headers for every validator."
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/gas_accumulator.rs:131-145, crates/engine/src/payload_builder.rs:44
- note: `RewardsCounter` holds per-authority leader counts for the epoch.

### F8 Reward distribution
- claim: "This count specifically reflects how often a commit was initiated by that validator's leader certificate."
- verdict: confirmed
- replacement: n/a
- cite: crates/engine/src/payload_builder.rs:44
- note: `inc_leader_count(output.leader().author())` once per executed consensus output.

### F9 Reward distribution
- claim: "Leaders whose rounds produce empty commits still receive credit."
- verdict: confirmed
- replacement: n/a
- cite: crates/engine/src/payload_builder.rs:44, crates/engine/src/payload_builder.rs:114-131
- note: the increment happens before batches are examined, so an output with no batches still counts.

### F10 Reward distribution
- claim: "This accounting is maintained in memory during normal operation and rebuilt from committed blocks if a node restarts as part of the recovery process."
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/gas_accumulator.rs:18-35
- note: `catchup_accumulator` walks executed blocks and the consensus DB, then `replay_missed_consensus` replays committed but unexecuted output.

### F11 Reward distribution
- claim: "When an epoch concludes, the protocol initiates the `applyIncentives` function on the `ConsensusRegistry`."
- verdict: confirmed
- replacement: n/a
- cite: crates/tn-reth/src/evm/block.rs:523-538
- note: first of the boundary calls, issued from `SYSTEM_ADDRESS` (`onlySystemCall`, tn-contracts/src/consensus/SystemCallable.sol:17-20).

### F12 Reward distribution
- claim: "This function is supplied with each validator's address and their respective consensus header count."
- verdict: confirmed
- replacement: n/a
- cite: crates/tn-reth/src/evm/block.rs:507-532, crates/tn-reth/src/system_calls.rs:141
- note: `RewardInfo { validatorAddress, consensusHeaderCount }`.

### F13 Reward distribution
- claim: "The `ConsensusRegistry` contract then calculates the rewards, and these amounts are included in the block's `withdrawals` field, which utilizes a modified version of the standard Ethereum withdrawal mechanism."
- verdict: stale
- replacement: The `ConsensusRegistry` weights each validator's share of the epoch's issuance by its stake and its header count, and credits that share to the validator's reward balance. The closing block's `withdrawals` field, a repurposed Ethereum withdrawal list, records each validator's address and header count rather than a TEL amount, so explorers can see the reward inputs without tracing system calls.
- cite: tn-contracts/src/consensus/ConsensusRegistry.sol:133-187, crates/types/src/gas_accumulator.rs:194-206, crates/tn-reth/src/evm/block.rs:2109-2113
- note: `generate_withdrawals` sets `amount` to the leader count, not the reward; rounding dust rolls over in `undistributedIssuance`.

### F14 Reward distribution
- claim: "Validators claim earned rewards through a pull-only flow, so individual claim failures cannot revert the consensus-critical system call."
- verdict: confirmed
- replacement: n/a
- cite: tn-contracts/src/consensus/ConsensusRegistry.sol:176-183, tn-contracts/src/consensus/ConsensusRegistry.sol:726-732, tn-contracts/src/consensus/StakeManager.sol:192-206
- note: `applyIncentives` only credits `balances`; TEL moves later through `claimStakeRewards` and the Issuance contract.

### F15 Reward distribution
- claim: "During the subsidized growth phase, rewards are funded by the governance safe."
- verdict: confirmed
- replacement: n/a
- cite: tn-contracts/src/consensus/ConsensusRegistry.sol:973-977, tn-contracts/src/consensus/Issuance.sol:9-11, crates/telcoin-network-cli/src/genesis/mod.rs:31-38
- note: rewards are paid from the Issuance contract, which only the registry owner funds (`allocateIssuance`, `onlyOwner`); the owner defaults to the governance Safe. "Subsidized growth phase" is policy framing the code cannot confirm; optional sharper wording: "Rewards are paid from the Issuance contract, which governance funds from the governance Safe."

### F16 Slash application
- claim: "After distributing rewards, the protocol invokes `applySlashes` on the `ConsensusRegistry`."
- verdict: confirmed
- replacement: n/a
- cite: crates/tn-reth/src/evm/block.rs:540-551
- note: second boundary call; on adiri present from the registry fork (epoch 407).

### F17 Slash application
- claim: "This mechanism is preliminary and subject to refinement."
- verdict: stale
- replacement: Slashing is not yet live: the protocol passes an empty slash list, so the call changes nothing today. Because it runs before the next committee is drawn, a validator slashed to zero will be ejected before it can be seated once slashing is enabled.
- cite: crates/tn-reth/src/system_calls.rs:31-32, crates/tn-reth/src/evm/block.rs:493-500, crates/tn-reth/src/evm/block.rs:682-705, tn-contracts/src/consensus/ConsensusRegistry.sol:190-225
- note: production `epoch_boundary_slashes` returns `Vec::new()`; the contract ejects when balance <= slash amount, otherwise decrements.

### F18 Committee shuffle
- claim: "After slashes are applied, the protocol invokes `concludeEpoch` on the `ConsensusRegistry` to select the next epoch's committee."
- verdict: stale
- replacement: After slashes are applied, each node draws the new committee itself and passes it to `concludeEpoch` on the `ConsensusRegistry`, which checks that the list is sorted and has the target size, settles queued stake changes and records the committee.
- cite: crates/tn-reth/src/evm/block.rs:553-561, crates/tn-reth/src/evm/block.rs:1513-1527, tn-contracts/src/consensus/ConsensusRegistry.sol:101-130
- note: the shuffle runs in the node's execution engine (`generate_conclude_epoch_calldata`); the contract only validates and seats `newCommittee`.

### F19 Committee shuffle
- claim: "The contract queries all validators with `Active` status."
- verdict: stale
- replacement: The protocol reads the committee-eligible validators from the registry: those with `Active` or `PendingActivation` status, with `PendingExit` validators held in reserve.
- cite: crates/tn-reth/src/evm/block.rs:1559-1597, crates/tn-reth/src/evm/block.rs:2189-2190
- note: the node unions three `getValidatorsInfo` queries; `PendingActivation` counts with `Active`. The draw is region-blind: the `region` field is not read (crates/tn-reth/src/system_calls.rs:106-109, #1279 then #1328).

### F20 Committee shuffle
- claim: "If the number of active validators is insufficient to fill the target committee size, validators with `PendingExit` status fill remaining slots."
- verdict: confirmed
- replacement: n/a
- cite: crates/tn-reth/src/evm/block.rs:2192-2204
- note: the reserves are picked at random from the same seeded RNG (`choose_multiple`); optional precision: "randomly chosen `PendingExit` validators fill the remaining slots".

### F21 Committee shuffle
- claim: "Randomness is derived from the aggregate BLS signature of the epoch's last leader certificate using the keccak256 hash function to create a 32-byte seed."
- verdict: stale
- replacement: The randomness is a 32-byte epoch seed chain. Each epoch starts from a root derived from the epoch number, and every commit folds in the committing leader's round and its deterministic BLS seed signature over its epoch and round, which the leader's header carries and its certificate covers. The value as of the epoch's closing commit seeds the shuffle and is published in the closing block's `extra_data`.
- cite: crates/types/src/primary/seed_chain.rs:1-6, crates/types/src/primary/header.rs:245-252, crates/types/src/primary/output.rs:282-297, crates/tn-reth/src/evm/block.rs:88-97, crates/tn-reth/src/evm/block.rs:2108
- note: the April text describes the legacy seed (keccak256 of the leader certificate's aggregate signature), which adiri used before SEED_SIGNATURE_FORK_EPOCH 383 (crates/types/src/forks.rs:183-218); other builds use the seed chain from genesis.

### F22 Committee shuffle
- claim: "The seed is deterministic and unpredictable until the leader's certificate is created."
- verdict: stale
- replacement: The seed is deterministic, since every node folds the same signed inputs in the same order, and no one can compute it before the preceding commit is published.
- cite: crates/types/src/primary/seed_chain.rs:8-18, crates/types/src/primary/output.rs:286-291
- note: unpredictability now runs from the preceding commit, not from creation of the leader certificate.

### F23 Committee shuffle
- claim: "By then, it is too late for malicious actors to manipulate ordering to their advantage."
- verdict: stale
- replacement: No proposer can grind the seed by re-cutting a proposal. The one residual influence belongs to the closing leader, which can compute the seed before broadcasting and withhold its proposal at the cost of that commit; the design accepts this bias.
- cite: crates/types/src/primary/seed_chain.rs:20-27
- note: the code documents an accepted last-actor (propose-or-withhold) bias, so "too late to manipulate" overstates it.

### F24 Committee shuffle
- claim: "The eligible validator set is shuffled using a Fisher-Yates algorithm seeded with the BLS-derived 32-byte seed."
- verdict: confirmed
- replacement: n/a
- cite: crates/tn-reth/src/evm/block.rs:1540-1556, crates/tn-reth/src/evm/block.rs:2206-2211
- note: `StdRng::from_seed(randomness)` then an in-place Fisher-Yates; the seed chain folds BLS seed signatures, so "BLS-derived" still holds.

### F25 Committee shuffle
- claim: "The shuffled set is then sorted by address to establish deterministic indexing."
- verdict: stale
- replacement: The shuffled list is truncated to the target committee size, which governance sets through the registry's `nextCommitteeSize` parameter.
- cite: crates/tn-reth/src/evm/block.rs:2218-2220, tn-contracts/src/consensus/ConsensusRegistry.sol:357-372
- note: order is wrong in the April text: the code truncates the shuffled list first and sorts afterwards. Sorting before truncation would bias selection toward low addresses. F25 and F26 swap.

### F26 Committee shuffle
- claim: "The sorted list is truncated to the target committee size, which governance controls via the `nextCommitteeSize` parameter."
- verdict: stale
- replacement: The selected members are then sorted by address for deterministic indexing; `concludeEpoch` rejects a committee that is unsorted or the wrong size.
- cite: crates/tn-reth/src/evm/block.rs:1518-1519, tn-contracts/src/consensus/ConsensusRegistry.sol:103, tn-contracts/src/consensus/ConsensusRegistry.sol:115-117, tn-contracts/src/consensus/ConsensusRegistry.sol:1470-1476
- note: `setNextCommitteeSize` is owner-only; the registry also lowers the size on its own when eligible validators fall below it (ConsensusRegistry.sol:1344-1348).

### F27 Committee shuffle
- claim: "The resulting committee is committed on-chain and takes effect at the start of the next epoch."
- verdict: stale
- replacement: The registry records the new committee for the epoch after next. Committees are fixed two epochs ahead: the committee drawn when epoch N closes serves epoch N+2, so every node knows the next two committees in advance.
- cite: tn-contracts/src/consensus/ConsensusRegistry.sol:1410, tn-contracts/src/consensus/ConsensusRegistry.sol:1424-1425, crates/node/src/manager/node/start_epoch.rs:283-286, crates/tn-reth/src/env/epoch.rs:2123
- note: `_updateEpochInfo` seats the committee stored one boundary earlier and files `futureCommittee` at `newEpoch + 2`; genesis seeds epochs 0-2.

### F28 Base fee adjustment
- claim: "Each epoch boundary also adjusts base fees using the worker's on-chain configuration."
- verdict: confirmed
- replacement: n/a
- cite: crates/tn-reth/src/evm/block.rs:608-617, crates/node/src/manager/node/run_epoch.rs:722-753
- note: the per-worker strategy comes from the `WorkerConfigs` contract.

### F29 Base fee adjustment
- claim: "A gas accumulator tracks aggregate block count, gas used, and gas limit for each worker lane over the course of the epoch."
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/gas_accumulator.rs:258-266, crates/types/src/gas_accumulator.rs:287-292
- note: `GasTotals { blocks, gas_used, gas_limit }` per worker slot.

### F30 Base fee adjustment
- claim: "The totals are used to apply base fee adjustments based on the worker's configuration settings at the epoch boundary."
- verdict: stale
- replacement: From those totals and each worker's fee strategy, the closing block computes every worker's base fee for the next epoch and records it in the `WorkerConfigs` contract. Every node entering the epoch, including one that restarts or syncs, reads its fees from that record, and each batch must carry exactly that fee.
- cite: crates/tn-reth/src/evm/block.rs:57-61, crates/tn-reth/src/evm/block.rs:567-680, crates/types/src/gas_accumulator.rs:38-53, crates/tn-reth/src/system_calls.rs:472-478
- note: #1101; the fee is now on-chain state rather than a value each node re-derives. On adiri the write path starts with the registry fork (epoch 407).

### F31 Base fee adjustment
- claim: "The default worker configuration adjusts base fees using the EIP-1559 formula."
- verdict: stale
- replacement: Each worker follows one of two governance-set strategies: EIP-1559 adjustment toward a gas target, or a fixed fee. The genesis configuration uses EIP-1559 with an effectively unlimited gas target, so fees stay at the floor until governance sets a real target.
- cite: crates/types/src/gas_accumulator.rs:71-82, crates/node/src/manager/node/run_epoch.rs:746-748, crates/types/src/forks.rs:142
- note: true but incomplete; a partner reading it would expect fees to float today. Genesis strategy is `Eip1559 { target_gas: u64::MAX }`; live adiri worker 0 read back that way on 2026-08-18.

### F32 Base fee adjustment
- claim: "When gas usage equals the target, the base fee remains unchanged; when usage exceeds the target, the fee increases; when usage falls below the target, the fee decreases, subject to a minimum floor of 7 wei."
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/gas_accumulator.rs:516-544, Cargo.lock (alloy-eips 1.8.3: `MIN_PROTOCOL_BASE_FEE = 7`)
- note: alloy's `calc_next_block_base_fee` with Ethereum params (max change 12.5% per epoch), floored at `MIN_PROTOCOL_BASE_FEE`.

### F33 Base fee adjustment
- claim: "After adjustment, all gas accumulators are cleared for the next epoch."
- verdict: confirmed
- replacement: n/a
- cite: crates/node/src/manager/node/run_epoch.rs:719, crates/types/src/gas_accumulator.rs:363-371
- note: `clear()` zeroes each worker's totals and the leader counts.

### F34 Fork scheduling
- claim: "Protocol forks are scheduled at epoch boundaries."
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/forks.rs:183-218, crates/types/src/forks.rs:235-245, crates/tn-reth/src/evm/block.rs:24-41
- note: every gate is keyed on an epoch number; one-shot upgrades fire in the closing block of `fork epoch - 1`.

### F35 Fork scheduling
- claim: "Epoch numbers are fork activation points, so all protocol upgrades coincide with clean state transitions and freshly selected committees."
- verdict: stale
- replacement: Each fork that changes consensus or execution results activates at a fixed epoch number, so it takes effect exactly at an epoch boundary, where a new committee takes over and the closing block has settled the previous epoch.
- cite: crates/types/src/forks.rs:228-234, crates/types/src/forks.rs:635-641, crates/tn-reth/src/evm/block.rs:19-41
- note: "all protocol upgrades" overclaims: changes that do not alter consensus results (for example the request-response protocol version bump, #970) ship with releases and are not epoch-gated. "Freshly selected" is loose because the committee was drawn two boundaries earlier (F27).

### F36 Fork scheduling (new subsection)
- claim: n/a (missing material: epoch-gated forks at the tag)
- verdict: missing
- replacement: text below
- cite: per line below
- note: proposed as `### Fork gates` after "Fork scheduling" (or appended to it). Six sentences plus a two-column table.

Proposed text:

```
### Fork gates

Each protocol change that alters consensus or execution results is gated on an epoch number compiled into the node.
A gate compares its fork epoch with the epoch carried inside the data it handles, such as a header's own epoch or the committing leader's epoch, never with the node's local view, so replayed history reproduces exactly and every value from the fork epoch onward follows the new rule.
Most gates stay in force for every epoch at or after their fork epoch; one-time contract upgrades instead run once, inside the closing block of the epoch before.
Because the schedule is compiled in, every node must run a release that carries a gate before its fork epoch begins, and a node left on an older release falls out of step with the network at that boundary.
The Adiri testnet carries history from before these forks, so each gate has its own activation epoch there; mainnet builds have no dormant period, because every rule is in force from genesis and the contract upgrades are already part of its genesis state.
A further gate, for millisecond-precision consensus timestamps, is built in but not yet scheduled.

| Fork | Activation epoch (adiri) |
| ---- | ------------------------ |
| Seed signatures: every header carries its author's BLS seed signature, and the epoch seed chain replaces the leader-certificate seed for the committee shuffle | 383 |
| Registry upgrade: the `ConsensusRegistry` and `WorkerConfigs` contracts are upgraded in place, adding the `applySlashes` step and the on-chain record of next-epoch base fees | 407 |
| Governance Safe: the governance Safe moves to the canonical Safe v1.4.1 contracts on SafeL2, matching mainnet genesis; owners, threshold and balance are unchanged | 554 |
| Leader-seeded ordering: certificates committed in the same round are ordered by a key derived from the seed chain, so no proposer can steer its place in the commit order | 567 |
| Multiple workers: the committee record can describe more than one worker per validator, lifting the single-worker limit | 570 |
| PREVRANDAO: each block's `PREVRANDAO` value comes from the seed chain instead of transaction data, so a leader cannot choose it by re-cutting its payload | 574 |
```

Line citations (WT-relative, tag v0.16.0-adiri):
- S1 "gated on an epoch number compiled into the node": crates/types/src/forks.rs:180, 218, 343, 474, 618, 1144 (compile-time `const` epochs, all `#[cfg(feature = "adiri")]`).
- S2 "epoch carried inside the data": crates/types/src/forks.rs:193-196, 436-439, 574-576, 228-234, 635-641; crates/types/src/primary/header.rs:245-252.
- S3 "most gates `>=`; one-time upgrades in the closing block of the epoch before": crates/types/src/forks.rs:253-258 (`epoch >= SEED_SIGNATURE_FORK_EPOCH`), 685-690; one-shot `==`: crates/types/src/forks.rs:76-80, 1074-1077; crates/tn-reth/src/evm/block.rs:24-41.
- S4 "every node must run a gate-carrying release; stragglers diverge": crates/types/src/forks.rs:113-117, 209-214, 320-327, 1128-1134.
- S5 "Adiri has per-gate epochs; mainnet active from genesis, upgrades in genesis": crates/types/src/forks.rs:216-217, 330-331, 472-473, 616-617, 1103-1105, 82-85; chain-configs/README.md (mainnet section).
- S6 "millisecond timestamps built, not scheduled": crates/types/src/forks.rs:720, 758-759, 772 (`u32::MAX`).
- Row 383: crates/types/src/forks.rs:183-218.
- Row 407: crates/types/src/forks.rs:74-80, 180; crates/types/src/forks.rs:44-50 (pre-fork `WorkerConfigs` lacks `setWorkerConfigsData`); crates/tn-reth/src/evm/block.rs:24-31, 508-519.
- Row 554: crates/types/src/forks.rs:1072-1094, 1103-1105, 1144.
- Row 567: crates/types/src/forks.rs:557-575, 618.
- Row 570: crates/types/src/forks.rs:420-426, 474; crates/node/src/manager/node.rs:111-125 (pre-fork entry requires exactly one worker).
- Row 574: crates/types/src/forks.rs:289-302, 343.

Gate selection (decided from the doc comments):
- Omitted `ADIRI_DUP_BATCH_EPOCH = 160` (crates/types/src/forks.rs:69-71): not an upgrade but a replay shim that reproduces a duplicate-batch bug of early Adiri epochs so old history re-executes (crates/consensus/executor/src/subscriber.rs:533-539, crates/engine/src/payload_builder.rs:83-92). Purely internal.
- `SUBSECOND_TIMESTAMP_FORK_EPOCH = u32::MAX` (crates/types/src/forks.rs:772) is a placeholder that never fires; kept out of the table, mentioned once in prose (S6). Drop S6 if the Association prefers not to preview unscheduled work.
- The `*_PRE_FORK_CODE_HASH` / `*_POST_FORK_CODE_HASH` constants and the `test-utils` env overrides (`TN_*_FORK_EPOCH`) are pins and test hooks, not gates; omitted.
- Activation dates are recorded in the doc comments (for example epoch 407 projected 2026-08-19, epochs 554-574 measured 2026-09-25 to 2026-09-30); left out of the partner text because they are projections, not on-chain facts.
- Optional cross-reference for the execution-layer chapter: contracts that need unbiasable randomness must not rely on `PREVRANDAO` alone, since the committing leader keeps a propose-or-withhold choice (crates/types/src/forks.rs:337-341).

## Out-of-scope observations
- The "governing body may ... vote" sentence sits in "Validator lifecycle" (transcription.md line 254), outside this unit. For whoever owns it: governance acts through the registry owner, which defaults to the governance Safe (crates/telcoin-network-cli/src/genesis/mod.rs:31-38); the Safe fork (#1410, epoch 554) moved the Safe to SafeL2 and left owners and threshold unchanged (crates/types/src/forks.rs:1091), so the multisig wording still holds. The reward weighting by stake (stake x header count, capped at outstanding balance) is at tn-contracts/src/consensus/ConsensusRegistry.sol:150-161.
- #1196 (uncertified epoch record still starts the next epoch) and #922 (mid-epoch ejection) have no matching claim in lines 194-252; no finding raised here.

## Summary
- confirmed: 19 (F1, F4, F5, F7-F12, F14-F16, F20, F24, F28, F29, F32-F34)
- stale: 16 (F2, F3, F6, F13, F17-F19, F21-F23, F25-F27, F30, F31, F35)
- unverifiable: 0
- missing: 1 (F36, fork gates subsection)
- total blocks: 36
