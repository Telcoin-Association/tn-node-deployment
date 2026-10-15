status: complete (all sections done, summary written)

# Checkpoint R3 findings

Completed sections: Smart contracts, Validator lifecycle intro, ConsensusNFT, Validator statuses, Lifecycle steps, Delegation, Summary
Remaining: none

Worktree WT = tn-v0.16.0-adiri (tn-contracts 10cc12b7). All cites are WT-relative.

## Smart contracts (transcription 180-193)

### F1 Smart contracts
- claim: "The protocol relies on four core smart contracts deployed at genesis:"
- verdict: stale
- replacement: "The protocol relies on three system contracts placed at fixed addresses in the genesis state. The ConsensusRegistry is built on StakeManager, a staking module it inherits, so the two share one address:"
- cite: crates/tn-reth/src/env/genesis.rs:22-34, tn-contracts/src/consensus/StakeManager.sol:18-21, tn-contracts/src/consensus/ConsensusRegistry.sol:28, tn-contracts/deployments/deployments-mainnet.json:4,6,13,17
- note: genesis writes exactly the registry, Issuance and WorkerConfigs accounts (plus the BLS precompile stub); StakeManager is `abstract` and deployments-mainnet.json maps StakeManager and ConsensusRegistry to the same 0x07E1... address.

### F2 Smart contracts
- claim: "ConsensusRegistry: Manages the validator lifecycle including registration, committee membership transitions, epoch metadata storage, and reward distribution."
- verdict: confirmed
- replacement: n/a
- cite: tn-contracts/src/consensus/ConsensusRegistry.sol:101-130 (concludeEpoch), :133-187 (applyIncentives), :40-41 (epochInfo / futureEpochInfo ring buffers), :584-605 (stake), tn-contracts/src/interfaces/IConsensusRegistry.sol:33-48
- note: read the system-call mutators and storage; the registry holds four recent and two future epochs (IConsensusRegistry.sol:283) and credits rewards to balances that Issuance pays out.

### F3 Smart contracts
- claim: "StakeManager: Governs TEL staking operations and mints a non-transferable ConsensusNFT (ERC-721) to represent each validator's staking position."
- verdict: stale
- replacement: "StakeManager: The staking module inside the ConsensusRegistry. It holds the stake versions, validator balances and delegations, and the ConsensusNFT (ERC-721) ledger: a non-transferable token that governance mints to each approved validator address and that the address must hold before it can stake."
- cite: tn-contracts/src/consensus/StakeManager.sol:21-25, :110-121, :123-162, tn-contracts/src/consensus/ConsensusRegistry.sol:596-599, :941-954
- note: the NFT is a governance whitelist minted before any stake (`stake()` checks `_checkConsensusNFTOwner`), not a receipt for a staking position; it is not a separate deployment.

### F4 Smart contracts
- claim: "Supports delegation."
- verdict: confirmed
- replacement: n/a
- cite: tn-contracts/src/consensus/StakeManager.sol:24, :51-60, tn-contracts/src/consensus/ConsensusRegistry.sol:608-649
- note: `delegateStake` and the `delegations` mapping exist at the tag; see the Delegation findings for the model.

### F5 Smart contracts
- claim: "WorkerConfigs: Stores worker configuration parameters on-chain, allowing the protocol to read and enforce operational settings from contract state."
- verdict: stale
- replacement: "WorkerConfigs: Stores each worker's base-fee policy on-chain: a fee strategy (EIP-1559 or a static fee), its parameter (target gas or flat fee) and a data field. The protocol reads every worker's configuration at each epoch boundary to set the next epoch's base fees, and the epoch-closing block writes each EIP-1559 worker's next-epoch base fee back to the contract."
- cite: tn-contracts/src/consensus/WorkerConfigs.sol:9-32, :79-90, crates/tn-reth/src/system_calls.rs:22-25, crates/tn-reth/src/evm/block.rs:490-501
- note: the contract is a "per-worker fee config store" only; "operational settings" overstates it. Base-fee write-back is #1101.

### F6 Smart contracts
- claim: "Governance can configure worker lane parameters without forking."
- verdict: confirmed
- replacement: n/a (optionally: "Governance can change worker fee parameters and the number of workers without forking.")
- cite: tn-contracts/src/consensus/WorkerConfigs.sol:107, :122, :137, :145 (owner-only setters), crates/tn-reth/src/env/genesis.rs:289
- note: `setWorkerConfig`, `setWorkerConfigsBatch`, `setNumWorkers`, `setMaxStrategy` are `onlyOwner` (Ownable2Step); the owner is the genesis owner address.

### F7 Smart contracts
- claim: "Issuance: Accepts TEL designated for validator rewards and uses the native ledger for accounting, providing verifiable reward distribution."
- verdict: confirmed
- replacement: n/a (optional addition: "It receives TEL only through the ConsensusRegistry and pays out only when the registry settles a reward claim or an unstake.")
- cite: tn-contracts/src/consensus/Issuance.sol:9-52, tn-contracts/src/consensus/design.md:57, tn-contracts/src/consensus/StakeManager.sol:28
- note: Issuance holds native TEL (no token ledger); `receive`, `distributeStakeReward` and `withdraw` are all `onlyStakeManager` (the registry address).

### F8 Smart contracts
- claim: "These contracts anchor the consensus protocol's economic and governance logic within the execution layer."
- verdict: confirmed
- replacement: n/a
- cite: crates/tn-reth/src/evm/block.rs:490-560, tn-contracts/src/consensus/ConsensusRegistry.sol:941-988 (owner-only governance functions)
- note: committee rotation, rewards and worker fees all run as EVM system calls against these contracts; governance acts as their owner.

### F9 Smart contracts
- claim: "The data provides verifiable committee transitions, staking state, and reward calculations without requiring trust."
- verdict: confirmed
- replacement: n/a
- cite: tn-contracts/src/consensus/ConsensusRegistry.sol:405-483 (public epoch, committee and validator views), :532-547 (getRewards / getBalanceBreakdown)
- note: all of it is public contract state readable through eth_call and the tn_* RPC wrappers (tn_getCommitteeValidators, tn_getValidator, tn_getRewards).

### F10 Smart contracts
- claim: (missing) who owns the system contracts and what governance can do to them
- verdict: missing
- replacement: "Telcoin governance owns the ConsensusRegistry and WorkerConfigs through a multisignature Safe account. As owner it approves validators, sets the stake versions and committee size, funds the Issuance contract, adjusts worker fee settings, and can pause validator and stake management in an emergency; the epoch-boundary system calls are not pausable."
- cite: crates/telcoin-network-cli/src/genesis/mod.rs:24-38, crates/config/src/genesis.rs:38-39, tn-contracts/src/consensus/ConsensusRegistry.sol:356-373, :941-988, :1549-1557, :1662-1683
- note: genesis default owner is GOVERNANCE_SAFE_ADDRESS (0x...07a0); pause comment at :1550 excludes system-callable and NFT functions. Optional; the #1410 SafeL2 migration is internal and not partner material.

## Validator lifecycle intro (transcription 253-255)

### F11 Validator lifecycle (intro)
- claim: "Validators must stake the appropriate amount of TEL on the governance staking contract in order to participate in consensus."
- verdict: stale
- replacement: "Validators must hold a ConsensusNFT issued by governance and stake the exact amount of TEL set by the current stake version in the ConsensusRegistry contract in order to participate in consensus."
- cite: tn-contracts/src/consensus/ConsensusRegistry.sol:584-605, tn-contracts/src/consensus/StakeManager.sol:288-292
- note: "governance staking contract" is not a contract name; the amount must match exactly (`InvalidStakeAmount` otherwise).

### F12 Validator lifecycle (intro)
- claim: "The stake requirement is based on the stake configuration when the node joins."
- verdict: confirmed
- replacement: n/a
- cite: tn-contracts/src/consensus/ConsensusRegistry.sol:597-598, :1145-1158, docs/src/staking/how-staking-works.md:14
- note: `stake()` reads `getCurrentEpochInfo().stakeVersion` and records it as the validator's `stakeVersion`.

### F13 Validator lifecycle (intro)
- claim: "The governing body may, at a later date, vote to modify this setup, potentially increasing or decreasing the required TEL stake for nodes."
- verdict: confirmed
- replacement: n/a (optional tightening: "Governance may later publish a new stake version that raises or lowers the required stake; a new version applies from the next epoch.")
- cite: tn-contracts/src/consensus/ConsensusRegistry.sol:1662-1683, :1411-1419, docs/src/rpc-methods/tn/tn_getcurrentstakeversion.md:3
- note: on-chain half confirmed (`upgradeStakeVersion` is owner-only; `concludeEpoch` stamps the version into the next epoch). The word "vote" describes an off-chain governance process; see F49.

### F14 Validator lifecycle (intro)
- claim: "Validators are not obligated to adjust their stake if the configuration changes."
- verdict: stale
- replacement: "Validators are not obligated to adjust their stake if the configuration changes. A validator, or its delegator, may opt in to a newer stake version; the change is one-way, and for a validator in service it settles at an epoch boundary, with any extra stake paid up front and any surplus refunded."
- cite: tn-contracts/src/consensus/ConsensusRegistry.sol:735-805, :235-308, docs/src/staking/how-staking-works.md:16
- note: first sentence still true; the opt-in path (`requestStakeVersionChange`, forward-only, queued for PendingActivation/Active) did not exist in the April text.

### F15 Validator lifecycle (intro)
- claim: "Nevertheless, if validators hold different stake amounts within the committee, the distribution of rewards will be weighted according to the amount staked."
- verdict: stale
- replacement: "Each epoch's issuance is shared in proportion to a weight equal to the validator's stake amount multiplied by the number of committed consensus rounds it led in that epoch. Validators on the same stake version therefore earn by performance alone, and where stake amounts differ, rewards are also weighted by the amount staked."
- cite: tn-contracts/src/consensus/ConsensusRegistry.sol:151-186, crates/tn-reth/src/evm/block.rs:523-534, crates/types/src/gas_accumulator.rs:148-190, crates/storage/src/consensus_pack.rs:3971, docs/src/staking/how-staking-works.md:20-36
- note: the client counts the leader of each committed sub-DAG per committee member and passes the counts to `applyIncentives`; the stake term is the version amount capped at the outstanding balance. Unspent dust rolls into the next epoch.

### F16 Validator lifecycle (intro)
- claim: (missing) the membership model
- verdict: missing
- replacement: "Telcoin Network uses a membership model rather than stake-weighted consensus. Each validator stakes exactly the amount of its stake version, no more; every committee member has equal voting power, and committees are drawn uniformly at random from the eligible validators. An operator cannot add capital to one node to increase its influence, so it grows its share by running more governance-approved validators, each with its own ConsensusNFT, keys and stake."
- cite: docs/src/staking/why-membership-model.md:9-11, :69-71, tn-contracts/src/consensus/StakeManager.sol:288-292, crates/types/src/committee.rs:307-309, :487-489, crates/tn-reth/src/evm/block.rs:2186-2220
- note: `EQUAL_VOTING_POWER` per authority; the draw is a seeded Fisher-Yates shuffle with no stake input (region-blind at the tag; do not mention regions).

### F17 Validator lifecycle (intro)
- claim: (unverifiable, implied by "distribution of rewards") that rewards are paid on the live network today
- verdict: unverifiable
- replacement: n/a
- cite: tn-contracts/src/interfaces/IConsensusRegistry.sol:242-243, crates/tn-reth/src/evm/block.rs:523-534, tn-contracts/src/consensus/design.md:105
- note: the contract comment says issuance distribution "is not yet enabled during the pilot; the protocol passes an empty array", but the client at the tag passes leader counts. Whether TEL actually flows depends on the live stake version's `epochIssuance` and the Issuance balance. Settled by reading `tn_getCurrentEpochInfo` (epochIssuance) and the Issuance contract balance on adiri, or by asking the Association. Avoid claiming rewards are live.

## ConsensusNFT (transcription 257-259)

### F18 ConsensusNFT
- claim: "Governance mints a non-transferable ConsensusNFT (ERC-721) to a validator's execution address."
- verdict: confirmed
- replacement: n/a
- cite: tn-contracts/src/consensus/ConsensusRegistry.sol:941-954, :1580, tn-contracts/src/consensus/StakeManager.sol:21, :123-162
- note: ERC721Enumerable named "ConsensusNFT"/"CNFT"; `transferFrom`, `approve` and `setApprovalForAll` all revert `NotTransferable`.

### F19 ConsensusNFT
- claim: "Only the contract owner, managed by Telcoin governance, may mint these NFTs."
- verdict: confirmed
- replacement: n/a
- cite: tn-contracts/src/consensus/ConsensusRegistry.sol:941, tn-contracts/src/consensus/StakeManager.sol:114, crates/telcoin-network-cli/src/genesis/mod.rs:24-38
- note: `mint` is `onlyOwner`; the genesis owner defaults to the governance Safe address. Genesis validators are minted by the constructor (ConsensusRegistry.sol:1652), which the text need not mention.

### F20 ConsensusNFT
- claim: "The token ID is the validator's unique identifier."
- verdict: confirmed
- replacement: n/a (optional precision: "The token ID is the validator's execution address read as a number, so each address can hold at most one.")
- cite: tn-contracts/src/consensus/StakeManager.sol:113, :325-327, tn-contracts/src/consensus/ConsensusRegistry.sol:943-945
- note: `tokenId == uint160(validatorAddress)`; `mint` reverts `AlreadyDefined` if the address already holds one or is retired.

### F21 ConsensusNFT
- claim: "ConsensusNFTs are non-transferable and are burned upon unstaking."
- verdict: confirmed
- replacement: n/a (see F22 for the other burn paths)
- cite: tn-contracts/src/consensus/ConsensusRegistry.sol:917-932, tn-contracts/src/consensus/StakeManager.sol:215-231
- note: `unstake` retires the validator and `_unstake` burns the token via `_burnConsensusNFT`.

### F22 ConsensusNFT
- claim: (missing) governance ejection and slashing
- verdict: missing
- replacement: "Governance can also burn a validator's ConsensusNFT at any time to eject it. The validator is removed from the current committee and the two committees already drawn after it, its staked TEL is moved to the Issuance contract for future rewards, and its address is retired. The registry also supports slashing at epoch boundaries, with a validator slashed to zero ejected the same way, but the protocol does not apply slashes yet."
- cite: tn-contracts/src/consensus/ConsensusRegistry.sol:957-970, :1323-1350, :1368-1396, :190-225, crates/tn-reth/src/system_calls.rs:31-32, crates/tn-reth/src/evm/block.rs:494-499
- note: `burn` on a staked validator runs `_consensusBurn` (eject from current, next and subsequent committees; confiscate the stake to Issuance; exit, retire, burn). A never-staked holder is just retired and burned. Production builds always pass an empty slashes array.

## Validator statuses (transcription 261-272)

### F23 Validator statuses
- claim: "Each validator occupies exactly one status at any given time:"
- verdict: confirmed
- replacement: n/a
- cite: tn-contracts/src/interfaces/IConsensusRegistry.sol:16-31, tn-contracts/src/consensus/ConsensusRegistry.sol:1269-1287
- note: one `currentStatus` field per `ValidatorInfo`; `_setStatus` is the single mutation point.

### F24 Validator statuses
- claim: "Undefined | No validator record exists for this address"
- verdict: stale
- replacement: "Undefined | The address has not staked. It may already hold a ConsensusNFT."
- cite: tn-contracts/src/consensus/ConsensusRegistry.sol:947-950, docs/src/rpc-methods/tn/tn_getvalidator.md:5, docs/src/staking/how-to-stake.md:213
- note: `mint` stamps the address onto a record that stays `Undefined` until `stake()`/`delegateStake()`; tn_getValidator returns that record.

### F25 Validator statuses
- claim: "Staked | Validator has staked TEL but has not yet activated"
- verdict: confirmed
- replacement: n/a
- cite: tn-contracts/src/interfaces/IConsensusRegistry.sol:204, tn-contracts/src/consensus/ConsensusRegistry.sol:1145-1165
- note: `_recordStaked` moves Undefined to Staked; a Staked validator may also unstake at any time (ConsensusRegistry.sol:1517).

### F26 Validator statuses
- claim: "PendingActivation | Validator is queued for activation; transitions to Active at the next epoch boundary"
- verdict: confirmed
- replacement: n/a (optional addition: "; already eligible for committee selection")
- cite: tn-contracts/src/interfaces/IConsensusRegistry.sol:205-206, tn-contracts/src/consensus/ConsensusRegistry.sol:1294-1301, :1509-1512
- note: every PendingActivation validator is activated in `concludeEpoch`; the status is in the committee-eligible pool (see F37).

### F27 Validator statuses
- claim: "Active | Validator is eligible for committee selection indefinitely"
- verdict: confirmed
- replacement: n/a
- cite: tn-contracts/src/interfaces/IConsensusRegistry.sol:207, crates/tn-reth/src/evm/block.rs:1580-1597
- note: Active is first in the client's eligible pool; no expiry.

### F28 Validator statuses
- claim: "PendingExit | Validator has initiated exit but remains eligible for committee selection"
- verdict: stale
- replacement: "PendingExit | Validator has initiated exit. It keeps the committee seats already assigned to it and is drawn into new committees only when Active and PendingActivation validators cannot fill them."
- cite: crates/tn-reth/src/evm/block.rs:2186-2204, tn-contracts/src/interfaces/IConsensusRegistry.sol:208-209
- note: `assemble_new_committee` partitions PendingExit out and samples from it only for missing seats.

### F29 Validator statuses
- claim: "Exited | Validator is removed from committees and awaiting the cooldown period to unstake"
- verdict: confirmed
- replacement: n/a (optional: "...awaiting a one-epoch cooldown before it can unstake")
- cite: tn-contracts/src/consensus/ConsensusRegistry.sol:1195-1200, :1515-1525
- note: exit only fires when the validator sits in none of the next three committees; unstake needs `currentEpoch >= exitEpoch + 1`.

### F30 Validator statuses
- claim: (missing) the retired state
- verdict: missing
- replacement: add a table row: "Retired | The validator has unstaked or been ejected. Its ConsensusNFT is burned and the address can never rejoin (the registry reports status `Any` with `isRetired` set)."
- cite: tn-contracts/src/interfaces/IConsensusRegistry.sol:211-220, :322-324, tn-contracts/src/consensus/ConsensusRegistry.sol:1205-1216, docs/src/rpc-methods/tn/tn_getvalidator.md:5,18, docs/src/rpc-methods/tn/tn_isretired.md:3
- note: the enum's seventh value `Any` is the retired sentinel; tn_getValidator returns "Any" and tn_isRetired returns true for such an address.

## Lifecycle steps (transcription 274-282)

### F31 Lifecycle steps
- claim: "NFT mint. Telcoin governance mints a ConsensusNFT to the validator's execution address, granting that address the right to participate in the protocol."
- verdict: confirmed
- replacement: n/a
- cite: tn-contracts/src/consensus/ConsensusRegistry.sol:941-954, :599, :706, :897
- note: `stake`, `activate` and `beginExit` each require `_checkConsensusNFTOwner`.

### F32 Lifecycle steps
- claim: "Key generation. The validator generates a BLS12-381 keypair for consensus signing and Ed25519 network keys for peer identity and transport."
- verdict: confirmed
- replacement: n/a (optional precision: "...and Ed25519 network keys, derived from the BLS key, for peer identity and transport. It also signs a proof of possession that binds the BLS key to its execution address.")
- cite: crates/types/src/crypto/bls_keypair.rs:4, crates/config/src/keys.rs:535-554
- note: blst min_sig (96-byte G2 public keys); network keypairs are `ed25519_from_bytes` of a hash of a BLS signature over a seed.

### F33 Lifecycle steps
- claim: "Stake. The validator calls `stake()` on the `ConsensusRegistry`, sending the exact required TEL amount."
- verdict: stale
- replacement: "Stake. The validator calls `stake()` on the `ConsensusRegistry` with its BLS public key and proof of possession, sending exactly the stake amount of the current epoch's stake version. The registry verifies the proof through the BLS precompile and accepts each BLS key only once."
- cite: tn-contracts/src/consensus/ConsensusRegistry.sol:584-605, :1005-1079, tn-contracts/src/consensus/StakeManager.sol:288-292
- note: `stake(bytes blsPubkey, ProofOfPossession)`; PoP message is intent prefix || compressed key || address; `_spendBLSPubkey` reverts `DuplicateBLSPubkey` on reuse.

### F34 Lifecycle steps
- claim: "The validator transitions from Undefined to Staked."
- verdict: confirmed
- replacement: n/a
- cite: tn-contracts/src/consensus/ConsensusRegistry.sol:600-604, :1153-1160
- note: `_checkValidatorStatus(..., Undefined)` then `_setStatus(..., Staked)`; `delegateStake` takes the same path (:628-648).

### F35 Lifecycle steps
- claim: "Stake amounts are configurable to support iterative adjustment during early protocol phases."
- verdict: confirmed
- replacement: n/a
- cite: tn-contracts/src/consensus/design.md:45, tn-contracts/src/consensus/ConsensusRegistry.sol:1662-1683
- note: via owner-only `upgradeStakeVersion`; see F14 for the validator-side opt-in.

### F36 Lifecycle steps
- claim: "Activate. The validator calls `activate()` to enter the PendingActivation queue. The designated activation epoch is the next epoch."
- verdict: confirmed
- replacement: n/a
- cite: tn-contracts/src/consensus/ConsensusRegistry.sol:704-714, :1168-1173
- note: requires Staked; sets `activationEpoch = currentEpoch + 1`.

### F37 Lifecycle steps
- claim: "Committee entry. At the next epoch boundary, the `concludeEpoch()` system call transitions the validator from PendingActivation to Active. The validator is now eligible for committee selection."
- verdict: stale
- replacement: "Committee entry. At the next epoch boundary, the `concludeEpoch()` system call moves the validator from PendingActivation to Active. The validator is already eligible for the committee drawn at that boundary. Committees are drawn three epochs ahead, so the earliest committee the validator can join serves from the third epoch after that boundary."
- cite: tn-contracts/src/consensus/ConsensusRegistry.sol:101-130, :1294-1301, :1424-1425, tn-contracts/src/interfaces/IConsensusRegistry.sol:233, crates/tn-reth/src/evm/block.rs:1580-1597
- note: the client reads the eligible pool (Active, PendingActivation, PendingExit) before `concludeEpoch`; `newCommittee` is "the future validator committee for currentEpoch + 3".

### F38 Lifecycle steps
- claim: "Exit. The validator calls `beginExit()` and enters PendingExit status."
- verdict: confirmed
- replacement: n/a
- cite: tn-contracts/src/consensus/ConsensusRegistry.sol:895-914, :1185-1190
- note: requires Active and `currentEpoch >= activationEpoch`; reverts if the eligible pool would be too small for the committee.

### F39 Lifecycle steps
- claim: "While in PendingExit, the validator remains eligible for committee selection."
- verdict: stale
- replacement: "While in PendingExit, the validator keeps the committee seats already assigned to it and is drawn into new committees only if there are not enough Active and PendingActivation validators to fill them."
- cite: crates/tn-reth/src/evm/block.rs:2186-2204
- note: same evidence as F28.

### F40 Lifecycle steps
- claim: "The validator is fully exited only after being excluded from voter committees for two consecutive epochs, at which point the status transitions to Exited."
- verdict: stale
- replacement: "The protocol moves the validator to Exited at the first epoch boundary at which it holds no seat in the committee of the starting epoch or in either of the two committees already drawn after it. With enough active validators this happens within three epoch boundaries of `beginExit()`."
- cite: tn-contracts/src/consensus/ConsensusRegistry.sol:1303-1318, :1404-1425, docs/src/staking/how-to-stake.md:272
- note: `_updateValidatorQueue` marks the new current, next and newly drawn committees and exits each PendingExit validator found in none of them; "two consecutive epochs" is carried over from the stale tn-contracts README (:59).

### F41 Lifecycle steps
- claim: "Unstake. After one full epoch in the Exited state, the validator calls `unstake()` to reclaim the original stake plus any accrued rewards."
- verdict: stale
- replacement: "Unstake. After one full epoch in the Exited state, the validator or its delegator calls `unstake()`. The registry returns the stake and any accrued rewards to the stake originator: the delegator when there is one, otherwise the validator."
- cite: tn-contracts/src/consensus/ConsensusRegistry.sol:917-932, :1515-1525, :719-723, tn-contracts/src/consensus/StakeManager.sol:222-268, :306-314
- note: `unstake(address validatorAddress, bool acceptRewardShortfall)`; payout goes to `_getRecipient`. Slashed balances return only what remains; not stated since slashing is not live.

### F42 Lifecycle steps
- claim: "The ConsensusNFT is burned. The validator's address enters permanent retirement and can never rejoin the protocol."
- verdict: confirmed
- replacement: n/a
- cite: tn-contracts/src/consensus/ConsensusRegistry.sol:925-926, :1205-1216, :943-945
- note: `_retire` sets `isRetired`; `mint` refuses a retired address.

### F43 Lifecycle steps
- claim: "To participate again, the operator must obtain a new ConsensusNFT and use a new address."
- verdict: stale
- replacement: "To participate again, the operator must obtain a new ConsensusNFT for a new address and generate a new BLS key, because a registered BLS key can never be registered again."
- cite: tn-contracts/src/consensus/ConsensusRegistry.sol:1073-1079, :1203-1204
- note: `blsPubkeyHashToValidator` is never cleared on retirement (only rewritten by the one-time migration at :331-332).

### F44 Lifecycle steps
- claim: (missing) exits from the lifecycle that the steps omit
- verdict: missing
- replacement: append to the steps: "A validator that has staked but not yet activated can unstake at any time. An active validator can claim accrued rewards without exiting, and rewards always go to the stake originator."
- cite: tn-contracts/src/consensus/ConsensusRegistry.sol:1515-1517, :726-732, tn-contracts/src/consensus/StakeManager.sol:277-286
- note: claims respect the stake version's `minWithdrawAmount`. Governance ejection is covered by F22; stake version changes by F14.

## Delegation (transcription 284-286)

### F45 Delegation
- claim: "The protocol supports delegated proof-of-stake, though delegation is expected to be used sparingly given the small, governance-vetted validator set."
- verdict: stale
- replacement: "The protocol supports delegated staking, though it is expected to be used sparingly given the small, governance-vetted validator set. A delegator funds one validator's entire stake on its behalf; there is no pooling of stake from several delegators and no added consensus weight."
- cite: tn-contracts/src/consensus/design.md:58, tn-contracts/src/consensus/ConsensusRegistry.sol:608-649, tn-contracts/src/consensus/StakeManager.sol:24
- note: "delegated proof-of-stake" suggests pooled, stake-weighted DPoS; the code keeps one `Delegation` record per validator and `delegateStake` must send exactly the version's stake amount.

### F46 Delegation
- claim: "Upon unstaking, delegators receive all stake rewards and the full staked balance."
- verdict: confirmed
- replacement: n/a (optional: "Delegators receive all stake rewards, whether claimed during service or on unstaking, and the staked balance when the validator unstakes.")
- cite: tn-contracts/src/consensus/StakeManager.sol:306-314, :222-268, tn-contracts/src/consensus/ConsensusRegistry.sol:726-732, :917-932, docs/src/rpc-methods/tn/tn_isdelegated.md:3
- note: `_getRecipient` returns the delegator for every claim and unstake.

### F47 Delegation
- claim: "Any reward splitting between a validator and its delegator is agreed upon offchain and falls outside protocol enforcement."
- verdict: confirmed
- replacement: n/a
- cite: tn-contracts/src/consensus/design.md:59
- note: no split logic exists in the registry.

### F48 Delegation
- claim: (missing) how a delegation is formed and authorized
- verdict: missing
- replacement: "A delegation is formed when the delegator calls `delegateStake()` before the validator has staked, supplying the validator's BLS public key and proof of possession and the stake amount of the current stake version. The validator authorizes it by signing an EIP-712 digest, available from `delegationDigest()` or the `tn_delegationDigest` RPC method, that binds its BLS key, its address, the delegator, the current stake version, the validator's delegation nonce and a deadline. The validator can revoke an unused signature by advancing its nonce, and governance can record a delegation without the signature. Once formed, the delegator cannot be changed, and either the validator or the delegator can claim rewards or unstake."
- cite: tn-contracts/src/consensus/ConsensusRegistry.sol:550-575, :608-656, :719-723, tn-contracts/src/consensus/StakeManager.sol:30-33, docs/src/rpc-methods/tn/tn_delegationdigest.md:3-5
- note: `delegateStake` requires status Undefined; the owner path skips the signature (`msg.sender != owner()` branch); `increaseNonce()` revokes. Contract validator accounts authorize through ERC-1271 (:1099-1125), which the spec need not mention.

## Governance process

### F49 Validator lifecycle (intro), governance wording
- claim: "The governing body may, at a later date, vote to modify this setup" (the "vote")
- verdict: unverifiable
- replacement: n/a
- cite: tn-contracts/src/consensus/ConsensusRegistry.sol:1662-1683, crates/telcoin-network-cli/src/genesis/mod.rs:24-38
- note: the code shows only that the registry owner (a governance Safe multisig by default) authors stake versions. How governance decides (a vote, signer thresholds) is off-chain; settled by the Telcoin Association's governance documentation.

## Summary

Counts by verdict (49 findings): confirmed 26, stale 15, missing 6, unverifiable 2.

- Smart contracts (F1-F10): 6 confirmed, 3 stale (F1 contract count, F3 StakeManager/NFT role, F5 WorkerConfigs scope), 1 missing (F10 owner and pause).
- Validator lifecycle intro (F11-F17): 2 confirmed, 3 stale (F11, F14, F15), 1 missing (F16 membership model), 1 unverifiable (F17 rewards live).
- ConsensusNFT (F18-F22): 4 confirmed, 1 missing (F22 governance ejection, slashing not applied).
- Validator statuses (F23-F30): 5 confirmed, 2 stale (F24 Undefined, F28 PendingExit), 1 missing (F30 Retired row).
- Lifecycle steps (F31-F44): 7 confirmed, 6 stale (F33, F37, F39, F40, F41, F43), 1 missing (F44).
- Delegation (F45-F48): 2 confirmed, 1 stale (F45), 1 missing (F48 formation and authorization).
- Governance process (F49): 1 unverifiable.

Most consequential stale findings:
1. F40: exit timing. A PendingExit validator exits at the first boundary where it holds no seat in the starting committee or the two drawn after it (three committees), not "two consecutive epochs".
2. F15/F16: rewards are weighted by stake amount times committed leader rounds, under a fixed-stake membership model with equal voting power; the text says only "weighted by amount staked".
3. F3/F1: StakeManager is the abstract base of the ConsensusRegistry (same address), there are three genesis system contracts, and the ConsensusNFT is a governance whitelist minted before staking, not a staking-position token.

Unverifiable: F17 (whether rewards are paid on the live network: the contract comment says issuance is disabled for the pilot while the client passes leader counts; settle with the live epochIssuance and Issuance balance), F49 (the governance "vote" process is off-chain).

Out-of-scope observation for the orchestrator: transcription line 177 says "Three additional system calls execute at epoch boundaries". At the tag the closing block makes four: applyIncentives, applySlashes, concludeEpoch, then WorkerConfigs.setWorkerConfigsData (crates/tn-reth/src/evm/block.rs:490-492). Whoever owns that section should check it.
