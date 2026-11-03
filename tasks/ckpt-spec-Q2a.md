status: complete

# Checkpoint Q2a

Completed sections:
- setup: read facts, log part A, spec slice lines 1-327
- section 1: Introduction + Architecture overview
- section 2: Consensus layer
- section 3: Execution layer
- section 4: Epoch boundaries
- section 5: sweep, scope, summary

Findings (`- <md line>: <verdict>: <note> (<cite>)`):

## Section 1: Introduction + Architecture overview (lines 1-59) — done
- 6: imprecise: Prague is active from genesis (chain-configs/testnet/genesis.yaml:17, chain-configs/mainnet/genesis.yaml:17), but batches admit only legacy, EIP-2930 and EIP-1559 transactions, so Pectra's EIP-7702 set-code and Cancun's blob transactions are rejected; a partner reading "Prague (Pectra) rules" will assume 7702. Suggest appending: "(blob and EIP-7702 set-code transactions are not accepted)" (crates/types/src/lib.rs:84-86, crates/batch-validator/src/validator.rs:213-232)
- 17-18: holds: batch validator checks digest, worker id, epoch, byte size, decode, type allowlist, sum of gas limits <= max batch gas, exact base fee; never executes ("small set" is non-exhaustive; size-in-bytes check unmentioned, acceptable) (crates/batch-validator/src/validator.rs:46-87,139-212)
- 24: imprecise: `sub_dag` holds more than the headers: reputation scores, the commit timestamp and the seed value (randomness) too; corrected: "a `sub_dag` holding the committed sub-DAG (the ordered headers of the committed certificates with the leader last, plus the reputation scores, commit timestamp and seed value listed under Total ordering)" (crates/types/src/primary/output.rs:385-414)
- 25-27: holds: `extra` is never set (ConsensusOutput::new leaves it Default; digest hashes B256::default() regardless of the field), BLAKE3 over parent, sub-DAG digest, LE number, 32-byte zero (crates/types/src/primary/block.rs:43-80, crates/types/src/primary/output.rs:113-131, crates/types/src/crypto/mod.rs:267)
- 41: inconsistent (unchanged sentence; also ƒ is used here and at 77 but never defined anywhere in the document): "a quorum of committee nodes (2ƒ+1)" vs line 45 "two-thirds-plus-one"; code uses floor(2n/3)+1, which equals 2ƒ+1 only for n = 3ƒ+1 (n=5 gives 4, 2ƒ+1 = 3); suggest "signed by a super quorum of the epoch's committee (two-thirds of its members plus one)" (crates/types/src/primary/epoch.rs:104-106)
- 43-44: holds: committee_compatible rules (subset, >=4, n*3 >= e*2, no duplicates) and build_epoch_record uses the fresh on-chain committee (crates/types/src/primary/epoch.rs:108-160, crates/node/src/manager/node/close_epoch.rs:912-971)
- 45: holds (super_quorum = floor(2n/3)+1, signed with IntentScope::EpochBoundary) (crates/types/src/primary/epoch.rs:58-106)
- 46-47: holds, slightly loose: outgoing committee members publish votes, but every node holding the record aggregates the votes it receives into the certificate; nodes that miss quorum (24+ timeouts) or join later request the cert from peers (crates/node/src/manager/epoch_votes.rs:70-190)
- 56: imprecise: same as line 24; the Content cell omits reputation scores, commit timestamp and seed value (crates/types/src/primary/output.rs:385-414)
- 57: imprecise: "a result signed by committee members" understates the threshold: a gossiped ConsensusResult is trusted once committee.len()/3 + 1 distinct committee members have signed the same (epoch, round, number, hash); corrected: "... or a consensus result signed by more than a third of the committee" (crates/consensus/primary/src/network/handler.rs:381-414)

## Section 2: Consensus layer (lines 61-129) — done
- 67: holds: header carries payload (batch digest -> worker id) and parents (previous-round certificate digests) (crates/types/src/primary/header.rs:21-37)
- 76: holds: leaders only on even rounds >= 2, base rotation (round/2 - 1) mod n through committee order, swap table overrides (crates/consensus/primary/src/consensus/leader_schedule.rs:293-306, bullshark.rs:138-141)
- 77: holds: commit needs validity_threshold = ceil(n/3) = ƒ+1 voting power of round L+1 certificates that list the leader as parent; optional precision: the rationale is that every later leader's causal history then reaches it, so all honest nodes commit it in the same order (bullshark.rs:199-215, crates/types/src/committee.rs:480-485)
- 80-81: holds with a missing condition: the key is blake3(domain || seed || digest) with seed = the seed chain value as of THIS commit (after folding the leader's seed signature); on Adiri only for leaders of epoch >= 567, before that the order inside a round is DFS discovery order. Text is correct at the tag; suggest "...ordered by a hash of the seed chain value as of this commit and the certificate digest" (crates/consensus/primary/src/consensus/utils.rs:20-110, crates/types/src/forks.rs:556-618)
- 85-88: holds (crates/types/src/primary/output.rs:385-414)
- 89: imprecise (minor): "the draw of the next committee" — the closing seed draws the committee for epoch N+3, not the next one (see line 290 finding); suggest "the committee draw at the epoch's close" (tn-contracts/src/consensus/ConsensusRegistry.sol:1408-1425)
- 95-97: holds: EQUAL_VOTING_POWER = 1 per authority (crates/types/src/committee.rs:26,307-309)
- 98-99: holds: weight = min(balance, version stakeAmount) x consensusHeaderCount; retired validators and zero counts skipped (tn-contracts/src/consensus/ConsensusRegistry.sol:132-187)
- 103: imprecise: the window is not 60 committed leaders. Reset and window end are keyed on the leader's nonce: reset when ((epoch<<32|round)/2) % 60 == 0, final when +1 is a multiple of 60, i.e. a window is 60 leader rounds (120 consensus rounds) whether or not each leader commits; an uncommitted leader at the boundary round skips that reset/update. Corrected: "over a window of 60 leader rounds (120 consensus rounds)" (crates/consensus/primary/src/consensus/bullshark.rs:68-98, crates/node/src/primary.rs:28-33)
- 104: holds: fresh ReputationScores at window start; at epoch start last_committed_sub_dag is from this epoch only (None) (bullshark.rs:71-77, crates/consensus/primary/src/consensus/state.rs:58-61,110-131)
- 105: holds (minor): only round L+1 certificates that are part of the NEXT committed sub-DAG are scored (bullshark.rs:81-89)
- 107: holds (leader_schedule.rs:299-306)
- 108: imprecise (edge): cap is max(1, floor(n*33/100)) and the loop that lowers the bad ceiling breaks with MORE than that when the ceiling bottoms out at zero ("can be violated only in some extreme edge cases"); also requires std-dev > 0 and lowest <= best-2σ. Suggest "(roughly two standard deviations, and normally no more than a third of the committee)" (leader_schedule.rs:63-160, crates/types/src/primary/mod.rs:32-39)
- 109: holds: good set = score >= best - σ (widened until >= threshold), ChaCha12 seeded with the leader round (leader_schedule.rs:132-157,214-235)
- 111: stale (unchanged): "distributes block rewards to every leader" — rewards are a share of the epoch's issuance weighted by effective stake x committed leader turns, credited to registry balances; retired validators get nothing. Suggest "At the end of each epoch, every validator whose leader turns were committed receives a share of the epoch's issuance (see Reward distribution)." (ConsensusRegistry.sol:132-187)
- 118: holds: one pool and one RPC server per worker on derived ports (crates/node/src/engine/inner.rs:145-181, crates/tn-reth/src/env/rpc.rs:342-352)
- 122-123: holds (crates/types/src/worker/sealed_batch.rs:76-86, crates/batch-validator/src/validator.rs:62-67,86-87,203-210)
- 127: holds; on Adiri the worker count had to stay at one until epoch 570 (forks.rs:452-457)
- 129: holds (softened, unverifiable as a design intent)

## Section 3: Execution layer (lines 131-238) — done
- 141-146: holds: empty non-closing output produces no block; closing empty output executes one empty block (crates/engine/src/payload_builder.rs:115-180)
- 148: imprecise: "(timelocked mint and claim, burn, and total supply, gated to governance)" reads as if totalSupply were governance-gated; it is callable by anyone. Suggest "(governance-only timelocked mint and claim and burn, plus a public total-supply view)"; also faucet builds replace mint with instant role-gated mint (testnet only) (docs/src/evm-compatibility.md:40-49, crates/tn-reth/src/evm/tel_precompile/mod.rs:96-102)
- 149: holds (docs/src/evm-compatibility.md:43-45,62; crates/tn-reth/src/evm/bls_precompile/mod.rs:18-22)
- 154-155: wrong / inconsistent with the refreshed table: the table now lists `beneficiary`, `timestamp` and `base_fee_per_gas`, which are read by contracts (COINBASE, TIMESTAMP, BASEFEE) and move balances (priority fees to beneficiary, base fee charged); five of ten rows affect execution, so neither "Most ... do not affect state changes" nor "Two are visible to contracts" holds. Corrected: "The consensus metadata in `nonce`, `difficulty`, `ommers_hash`, `extra_data` and `withdrawals` does not affect state changes and is included to support indexing tools, block explorers, and other services that read block headers directly. `mix_hash` supplies the `PREVRANDAO` value and `parent_beacon_block_root` is written to the beacon roots contract; `beneficiary`, `timestamp` and `base_fee_per_gas` keep their usual EVM roles." (crates/tn-reth/src/evm/block.rs:2103-2142, crates/tn-reth/src/evm/handler.rs:150-185)
- 161: holds (header.rs:254-256 nonce(); block.rs:2104)
- 162: holds (block.rs:207-249)
- 163: holds: keccak256("TN_PREVRANDAO_V1" || seed || number LE u64 || batch_index LE u64); Adiri pre-574 = output digest XOR batch digest (covered by fork table) (crates/types/src/primary/output.rs:313-353)
- 164-166: holds (payload_builder.rs:159-171, block.rs:2103-2108, crates/tn-reth/src/payload.rs:79-90,124-130)
- 167: holds (crates/types/src/gas_accumulator.rs:70-81,533-569)
- 168: holds: withdrawal entries = (execution address, leader count), index 0, not applied as balance credits (gas_accumulator.rs:194-206, block.rs:2109-2116)
- 169: holds (payload_builder.rs:130-157,232-247)
- 170: holds; note on Adiri `tn_getBlockTimestampMillis` returns whole seconds x 1000 (`subSecond: false`) because the sub-second gate is unarmed; line 317 states this (docs/src/rpc-methods/tn/tn_getblocktimestampmillis.md:21-22)
- 176-179: holds: gas_limit = max_batch_gas(epoch) = 30M for batch blocks; the empty closing block copies the parent's gas limit (same 30M) (crates/types/src/worker/sealed_batch.rs:205-209, payload_builder.rs:131-134,230-231, block.rs:2097-2100)
- 188-191: holds: SYSTEM_CALL_GAS_LIMIT = 100,000,000, block gas limit swapped for the call, gas price 0, nonce check disabled (crates/tn-reth/src/evm/mod.rs:67-90,235-283)
- 193-194: holds (block.rs:422-427, crates/tn-reth/src/system_calls.rs:15-19)
- 198-202: holds: EIP-4788 write only when batch index is 0 (first block of the output), EIP-2935 every block; note outputs committed in the same second overwrite one ring-buffer slot (block.rs:1858-1873,1725-1760)
- 206-207: holds; on Adiri closes before epoch 407 ran only applyIncentives + concludeEpoch (fork row covers) (block.rs:489-565,566-650)
- 212-216: holds; worked examples recomputed: 420,000 limit: r = 5e7, (1e8-5e7)^2 x 399,000 / 1e16 = 99,750 = 25.0% of 399,000; 30,000,000 limit: r = 7e5, (9.93e7)^2 x 29,979,000 / 1e16 = 29,560,762 = 98.60% (crates/tn-reth/src/evm/utils.rs:13-93, handler.rs:94-148)
- 217-218: holds: penalty x effective price credited to basefee_address; receipt gasUsed = spent_sub_refunded excludes it (handler.rs:128-148)
- 222-223: holds (crates/tn-reth/src/env/genesis.rs:22-34, tn-contracts/deployments/deployments-mainnet.json:4,13)
- 226-228: holds: NFT soulbound (transferFrom reverts NotTransferable) (tn-contracts/src/consensus/StakeManager.sol:123-161)
- 229-231: holds (tn-contracts/src/consensus/WorkerConfigs.sol:20-22,79-90,122-134)
- 237-238: holds; minor: the owner can also burn (eject) a validator, which "approves validators" does not cover; WorkerConfigs is not pausable and its system-call setters are onlySystemCall (ConsensusRegistry.sol:941-988,1551-1557; WorkerConfigs.sol:79-137)

## Section 4: Epoch boundaries (lines 240-326) — done
- 242: holds (crates/node/src/manager/node/run_epoch.rs:149)
- 243: holds: Adiri genesis registry slot 0x13 = 0x5460 = 21,600 s; measured live mean 21,602 s. Mainnet chain-configs are placeholders (chain-configs/README.md "mainnet"), so omitting a mainnet figure is right (chain-configs/testnet/genesis.yaml:79, crates/types/src/forks.rs:304-308)
- 244: holds: upgradeStakeVersion is onlyOwner; _updateEpochInfo stamps the latest version's duration when an epoch opens (tn-contracts/src/consensus/ConsensusRegistry.sol:1662-1683,1408-1418)
- 245: holds: commit_timestamp() >= boundary, boundary = epoch_start + epochDuration (crates/types/src/primary/output.rs:830-839, run_epoch.rs:149)
- 249-250: holds; the one-time upgrades exist only in Adiri builds (registry/WorkerConfigs swap at close of 406, Safe at close of 553) (crates/tn-reth/src/evm/block.rs:19-52,489-565)
- 256: holds: leader count incremented before the empty-output skip (crates/engine/src/payload_builder.rs:44,115-118)
- 261: holds (minor: the share is added to the validator's registry `balances` entry, which also holds its stake; rewards are what exceeds the stake amount) (ConsensusRegistry.sol:132-187)
- 262: holds (crates/types/src/gas_accumulator.rs:194-206)
- 269-270: holds: production slash list is always empty; eject when balance <= slash amount; applySlashes precedes the draw (block.rs:654-705, ConsensusRegistry.sol:190-225)
- 274: holds (ConsensusRegistry.sol:101-130)
- 276: holds (block.rs:1544-1580)
- 277: imprecise (minor): "active validators" means `Active` plus `PendingActivation`; the `PendingExit` fillers are picked at random with the same seeded RNG. Suggest "If `Active` and `PendingActivation` validators cannot fill the target size, `PendingExit` validators drawn at random fill the remaining seats." (block.rs:2186-2204)
- 280: imprecise (minor): the seed signature is over the epoch, the round AND the previous epoch record's digest (EpochSeedMessage) (crates/types/src/primary/epoch.rs:260-268)
- 281-284: holds (crates/types/src/primary/seed_chain.rs:1-27, output.rs:282-297)
- 286-288: holds: seeded StdRng Fisher-Yates, truncate to nextCommitteeSize, sort, concludeEpoch enforces sorting and size (block.rs:1513-1527,2172-2225; ConsensusRegistry.sol:103,115-117,1480-1484)
- 289-290: WRONG: in the block closing epoch N, concludeEpoch increments currentEpoch to N+1 and files the drawn committee at `newEpoch + 2` = N+3; genesis seeds epochs 0-2 and "Epoch 3 is the first shuffled committee". The R2b F27 note itself says `newEpoch + 2`; its replacement is off by one, and it contradicts line 373 ("Committees are drawn three epochs ahead"). Corrected: "The registry records the new committee three epochs ahead: the committee drawn when epoch N closes serves epoch N+3, so throughout any epoch the committees of the next two epochs are already fixed." (tn-contracts/src/consensus/ConsensusRegistry.sol:1408-1425,1430-1436; crates/tn-reth/src/env/epoch.rs:2118-2124; crates/node/src/manager/node/start_epoch.rs:283-286)
- 296-297: holds (block.rs:566-650, gas_accumulator.rs:38-53)
- 299: holds (gas_accumulator.rs:70-81)
- 300: imprecise (minor): with target u64::MAX fees START at the floor (genesis base fee and epoch-0 fee are MIN) and stay there; "fall to" implies a descent. Suggest "so fees stay at the minimum floor until governance sets a finite target" (crates/node/src/manager/node/run_epoch.rs:746-748, crates/telcoin-network-cli/src/genesis/mod.rs:136, crates/types/src/genesis.rs:90)
- 301: holds: Ethereum BaseFeeParams applied once per epoch to the lane's total gas vs target (so at most +-12.5% per epoch), floor MIN_PROTOCOL_BASE_FEE = 7 (gas_accumulator.rs:533-544)
- 307: imprecise: not every change to execution results is epoch-gated: the system-call gas budget raise to 100M ships as a lockstep upgrade without a gate, and the BLS precompile's value rejection (#1286) has none either. Suggest "Each fork that would change the result of already-produced history activates at a fixed epoch number ..." (crates/tn-reth/src/evm/mod.rs:67-90; git 0c97557fb)
- 311-313: holds (forks.rs:228-262; block.rs:23-40)
- 314: imprecise: overstated for the multiple-workers gate: a single-worker straggler keeps running past epoch 570 and fails only when it fetches or serves an epoch pack with an upgraded peer. Suggest "...falls out of step with the network at, or soon after, that gate's fork epoch" (forks.rs:458-466)
- 315-317: holds (forks.rs:254-262,770-772,1101-1103)
- 321: holds (forks.rs:182-218)
- 322: imprecise: the upgrade's substance is the registry's per-status validator sets and cached eligible count (one-time migrateValidatorSets) that the post-fork committee-pool read and concludeEpoch size check depend on; applySlashes already existed in the deployed bytecode, what the fork adds is the CALL in the close sequence. Suggest "...upgraded in place, giving the registry per-status validator sets for the committee draw; from then on the closing block also calls `applySlashes` and records next-epoch base fees" (forks.rs:73-81; block.rs:23-30,45-52; crates/tn-reth/src/evm/mod.rs:77-81)
- 323: holds (forks.rs:1072-1103,1144)
- 324: holds (forks.rs:556-618)
- 325: imprecise: "committee record" reads as the EpochRecord (BLS keys only); the gate changes the bcs layout of the Committee value stored in each epoch's consensus pack. Suggest "the committee description stored with each epoch's consensus data can list more than one worker per validator, lifting the single-worker limit" (forks.rs:419-474)
- 326: holds (forks.rs:289-343)

## Section 5: sweep (unchanged or cross-chapter)
- 57 (Execution Chain column, Verification cell "Standard Ethereum block validation"): stale (unchanged): execution blocks are never received and validated; every node builds them by executing the consensus output, and the epoch record's `final_state` anchors the result. Suggest "Deterministic re-execution of the consensus output, anchored by each epoch record's final execution state" (crates/engine/src/payload_builder.rs:96-260, crates/types/src/primary/epoch.rs:31-34)
- 111: see section 2 (stale, counted once)
- 264: inconsistent (style): "governance safe" lowercase vs "governance Safe" at 237/244 and the Fork gates table
- 89 vs 290 vs 373: cross-ref, committee lookahead (covered by the 289-290 finding)
- 41 vs 45: quorum notation (covered under section 1)
- 154-155 vs table rows 169-170: the refresh added rows that contradict the intro sentence (covered under section 3)

## Scope flags (partner suitability)
- 189: scope: the 100,000,000 per-call budget is an internal constant raised in this release range for an Adiri one-shot migration; suggest "a fixed per-call gas budget outside the block gas limit" (crates/tn-reth/src/evm/mod.rs:67-90)
- 103, 108: scope (mild): scheduling tuning constants (60-leader window, 2σ, 33% cap); fork-bound, so acceptable, but internal
- 250, 313, 315-316, 322-323: scope (mild): Adiri-only one-time migrations (in-place contract code swaps, governance Safe migration); the Governance Safe row in particular is testnet housekeeping a partner does not need (R3 F10 called the migration internal)
- 314: scope (mild): reads as an implicit upgrade deadline for node runners; acceptable as a protocol property
- 170, 218: scope (none needed): RPC method name and wallet/indexer reconciliation advice are integrator-facing, not operator instructions
- No scripts, tools, `--observer`, operator commands or test-only behaviour appear in the slice.

## Summary
- holds: 63
- imprecise: 15 (lines 6, 24, 56, 57 consensus cell, 89, 103, 108, 148, 277, 280, 300, 307, 314, 322, 325)
- wrong: 2 (154-155 header-field intro; 289-290 committee lookahead N+2 -> N+3)
- stale: 2 (111 "block rewards to every leader"; 57 Execution Chain "Standard Ethereum block validation")
- inconsistent: 2 (41 "2ƒ+1" vs 45 "two-thirds-plus-one", ƒ undefined; 264 "governance safe" casing)
- scope: 5 flags (189, 103/108, Adiri migration rows, 314, 170/218 no action)
- unsettled: none blocking; not checked: whether any value-bearing BLS-precompile call exists in Adiri history (relevant only to how strongly to word 307)
