status: complete (refresh-b.md assembled, all gates pass)

# Refresh log B: chapters 6-10 (Validator lifecycle to Trustless synchronization)

Working copy: SP/spec-md/refresh-b.md (SP = session scratchpad); the April transcription of this half is kept at SP/spec-md/c2/refresh-b.orig.md.
Cites are telcoin-network paths at tag v0.16.0-adiri (tn-contracts 10cc12b7), as given in the R3, R4, R5a, R5b and R5c findings.
Confirmed sentences are unchanged apart from the two whole-half formatting entries below.

## Whole half

- All chapters: reflowed to one sentence per line inside paragraphs; list items and table cells stay on one line, as in the MNO guide; no wording change (formatting convention).
- All chapters: code-span harmonisation to the convention C1 uses: backticks on contract names (`ConsensusRegistry`, `Issuance`), fields (`parent_hash`, `final_state`, `isRetired`), functions, status names (`Undefined`, `Staked`, `PendingActivation`, `Active`, `PendingExit`, `Exited`, `Any`), node modes (`CvvActive`, `CvvInactive`, `Observer`, including the Capabilities table headers and "observer mode" in Mode detection, which becomes "`Observer` mode"), enum variants (IntentScope and AppId values, `V0`, the reputation levels), topic and protocol ids, RPC methods, constants and hex values; type, struct and token names (ConsensusNFT, ConsensusHeader, EpochRecord, IntentMessage, IntentScope, IntentVersion, AppId) and proper names of algorithms and technologies (BLS12-381, Ed25519, Keccak-256, BLAKE3, QUIC, gossipsub, libp2p, Kademlia, EIP-712, ERC-721, secp256k1) stay plain (formatting convention).
- All chapters: American spelling kept ("behavior", "authorized"), ASCII minus signs in scores, testnet written "Adiri testnet" (style).

## Validator lifecycle

- Validator lifecycle > intro: first sentence replaced: hold a governance-issued ConsensusNFT and stake the exact amount of the current stake version in `ConsensusRegistry` (R3 F11; ConsensusRegistry.sol:584-605, StakeManager.sol:288-292).
- Validator lifecycle > intro: "The governing body may, at a later date, vote to modify this setup..." replaced by F13's optional wording ("Governance may later publish a new stake version ... applies from the next epoch"), which drops the unverifiable "vote"; conflict resolved in favour of softening (F49, unverifiable) over keeping the confirmed sentence verbatim (F13), with F13's code-cited wording (R3 F13, F49; ConsensusRegistry.sol:1662-1683, :1411-1419).
- Validator lifecycle > intro: added the one-way stake-version opt-in sentence after "Validators are not obligated..." (R3 F14; ConsensusRegistry.sol:735-805, :235-308).
- Validator lifecycle > intro: reward-weighting sentence replaced by two sentences: issuance weight = stake amount x committed leader rounds (R3 F15; ConsensusRegistry.sol:151-186, block.rs:523-534, gas_accumulator.rs:148-190).
- Validator lifecycle > intro: no claim that rewards are paid on the live network; the F15 text states only the distribution rule, so nothing further changed (R3 F17 unverifiable; IConsensusRegistry.sol:242-243).
- Validator lifecycle > intro: added a three-sentence paragraph on the membership model (fixed stake, equal voting power, random draw) (R3 F16; why-membership-model.md:9-11, committee.rs:307-309, block.rs:2186-2220).
- Validator lifecycle > ConsensusNFT: optional precision on the token ID not applied; confirmed sentence kept (R3 F20 optional skipped; StakeManager.sol:113).
- Validator lifecycle > ConsensusNFT: added a paragraph on governance burn and ejection and on slashing; "does not apply slashes yet" rephrased as "does not submit any slashes" (R3 F22; ConsensusRegistry.sol:957-970, :1323-1350, system_calls.rs:31-32).
- Validator lifecycle > Validator statuses: `Undefined` row meaning replaced ("The address has not staked. It may already hold a ConsensusNFT.") (R3 F24; ConsensusRegistry.sol:947-950).
- Validator lifecycle > Validator statuses: `PendingActivation` row kept; optional "already eligible" clause not applied (R3 F26 optional skipped; ConsensusRegistry.sol:1294-1301).
- Validator lifecycle > Validator statuses: `PendingExit` row meaning replaced (keeps assigned seats; drawn only when `Active` and `PendingActivation` validators cannot fill) (R3 F28; block.rs:2186-2204).
- Validator lifecycle > Validator statuses: `Exited` row kept; optional "one-epoch cooldown" wording not applied (R3 F29 optional skipped; ConsensusRegistry.sol:1515-1525).
- Validator lifecycle > Validator statuses: added row "Retired" (status name left plain because the registry reports `Any` with `isRetired`) (R3 F30; IConsensusRegistry.sol:211-220, ConsensusRegistry.sol:1205-1216).
- Validator lifecycle > Lifecycle steps: step 2 gains the optional precision: Ed25519 keys derived from the BLS key, plus a proof-of-possession sentence; applied so the step agrees with Networking and Cryptographic primitives (R3 F32 optional; keys.rs:535-554).
- Validator lifecycle > Lifecycle steps: step 3 "sending the exact required TEL amount" replaced by `stake()` with BLS key and proof of possession at the current stake version's amount, plus the registry-verification sentence (R3 F33; ConsensusRegistry.sol:584-605, :1005-1079).
- Validator lifecycle > Lifecycle steps: step 5 "transitions ... now eligible" replaced: eligible for the committee drawn at that boundary; committees drawn three epochs ahead (R3 F37; ConsensusRegistry.sol:101-130, :1294-1301, block.rs:1580-1597).
- Validator lifecycle > Lifecycle steps: step 6 "remains eligible for committee selection" replaced (keeps seats, drawn only when needed) (R3 F39; block.rs:2186-2204).
- Validator lifecycle > Lifecycle steps: step 6 "excluded ... for two consecutive epochs" replaced by the three-committee exit rule (R3 F40; ConsensusRegistry.sol:1303-1318, :1404-1425).
- Validator lifecycle > Lifecycle steps: step 7 unstake sentence replaced: validator or delegator calls `unstake()`, payout to the stake originator (R3 F41; ConsensusRegistry.sol:917-932, StakeManager.sol:306-314).
- Validator lifecycle > Lifecycle steps: step 7 last sentence replaced: a new address and a new BLS key are required (R3 F43; ConsensusRegistry.sol:1073-1079).
- Validator lifecycle > Lifecycle steps: added a two-sentence paragraph after the list (unstake before activation; claim rewards without exiting) (R3 F44; ConsensusRegistry.sol:1515-1517, :726-732).
- Validator lifecycle > Delegation: first sentence replaced ("delegated staking"; one delegator funds one validator's whole stake) (R3 F45; design.md:58, ConsensusRegistry.sol:608-649).
- Validator lifecycle > Delegation: added a three-sentence paragraph on forming a delegation (`delegateStake()`, EIP-712 digest via `delegationDigest()` / `tn_delegationDigest`, delegator fixed); trimmed to three sentences by dropping the nonce-revocation and governance-without-signature sentences; the confirmed F46 and F47 sentences follow it in that paragraph (R3 F48; ConsensusRegistry.sol:550-575, :608-656).
- Validator lifecycle > Delegation: optional rewording of the unstaking sentence not applied (R3 F46 optional skipped; StakeManager.sol:306-314).

## Node modes

- Node modes > CvvActive: "This is the default mode for all committee members at the start of an epoch." replaced (sticky `CvvInactive`, epoch-record veto) (R4 F3; start_epoch.rs:1050-1097, node.rs:1815-1840).
- Node modes > CvvInactive: definition completed (GC window or an epoch behind) and "This occurs when a committee member restarts ... or ... falls too far behind" replaced by "This most often follows a restart mid-epoch." (R4 F6; handler.rs:162-252, node.rs:969-972).
- Node modes > Observer: "This includes nodes explicitly configured as observers and ..." replaced; added "No node is configured into this mode: each node derives its role from committee membership every epoch." (R4 F11; node.rs:969-972, start_epoch.rs:1060-1081).
- Node modes > Observer: added two sentences: no batches; workers forward transactions over RPC (heading link to Transaction forwarding); no batch-gossip subscription (R4 F13; start_epoch.rs:722-735, :1197-1213, run_epoch.rs:988-1000).
- Node modes > Mode detection: second sentence replaced (key in the new committee, epoch-record veto); the "configured as an observer" clause removed (R4 F15; start_epoch.rs:1076-1093, node.rs:1815-1840).
- Node modes > Mode detection: `CvvInactive` carry-over sentence replaced by two sentences (stays until caught up, then re-checks membership) (R4 F16; start_epoch.rs:1043-1058, subscriber.rs:236-240).
- Node modes > Mode detection: added a paragraph on `tn_nodeMode` and `eth_syncing` (R4 F19; rpc_ext.rs:135-140, :490-491, start_epoch.rs:1181-1195).
- Node modes > Capabilities: added row "Transaction intake" after "Batch production"; the other two candidate rows (epoch record signing, reported as syncing) not added (R4 F26 optional, partly applied; run_epoch.rs:415-428, :988-1000).

## Networking

- Networking > intro: "bulk sync streams" added to the list of mechanisms (R5a F1 optional; consensus.rs:280-310).
- Networking > Transport: added the IPv6 multiaddr form and the four-endpoint limit after the code block (R5a F4 optional; addresses.rs:11, :58-63).
- Networking > Transport: "The maximum idle connection timeout is 65 seconds ..." replaced by three sentences (5 s keep-alive, 30 s QUIC idle timeout, 30 s effective handshake ceiling, 65 s libp2p idle timeout); "the swarm" phrased as "At the libp2p layer" because swarms are introduced later (R5a F6; quic.rs:10-14, :40-42, network.rs:377).
- Networking > Identity and discovery: first two sentences replaced (Ed25519 key derived from the BLS key; one peer ID per swarm) (R5a F7; keys.rs:240-244, :547-554, :504-523).
- Networking > Identity and discovery: "Validators additionally hold BLS12-381 keypairs used for consensus signing." replaced by "The BLS key signs the node's consensus messages when it sits on the committee, and it is the key registered on-chain."; conflict resolved: R5a F8's list "headers, votes and certificates" generalised because R5c F4 (more specific cites) shows certificates are vote aggregates, not signed separately (R5a F8, R5c F4; keys.rs:355-385, vote.rs:39, certificate.rs:279-286).
- Networking > Identity and discovery: discovery sentence replaced (every node publishes a BLS-signed node record per swarm, republished every 12 hours) (R5a F9; consensus.rs:951-955, network.rs:382).
- Networking > Identity and discovery: record-contents sentence replaced by three sentences (keyed by primary BLS key; network public key, addresses, timestamp, optional RPC endpoint; signature binds chain id and role); the "resolve from its BLS public key alone" sentence moved ahead of the signature sentence so "therefore" follows the keying (R5a F10; record.rs:10-23, :60-125, :246-262, kad.rs:230-232).
- Networking > Identity and discovery: optional discovery-paths sentence not applied (R5a F13 optional skipped; network.rs:127-139).
- Networking > Gossipsub topics: "five dedicated topics" sentence replaced by three sentences (four topics, `/tn-meshsub-{chain_id}`, chain id in topic names, per-epoch publisher allowlist) (R5a F14; network.rs:349-370, protocol.rs:99-101, start_epoch.rs:814-842).
- Networking > Gossipsub topics: table gains an "Authorized publishers" column (R5a F15; gossip.md:19-24, start_epoch.rs:787-842).
- Networking > Gossipsub topics: row `tn-primary` becomes `tn-primary-{chain_id}`, publishers current committee, purpose "between committee members" (R5a F16; network.rs:349-352, start_epoch.rs:824-829).
- Networking > Gossipsub topics: row `tn-consensus-output` becomes `tn-consensus-output-{chain_id}`, publishers previous/current/next committee, purpose signed header announcements; threshold written "one-third plus one" to match Trustless synchronization (R4 F46) instead of "more than one third" (same value) (R5a F17; network.rs:354-357, handler.rs:362-410).
- Networking > Gossipsub topics: row `tn-epoch-vote` becomes `tn-epoch-vote-{chain_id}` with publishers previous/current/next committee (R5a F18; network.rs:359-362, start_epoch.rs:830-836).
- Networking > Gossipsub topics: row `tn-worker` becomes `tn-worker-{chain_id}-{worker_id}`, publishers current committee, committee-only subscription (R5a F19; network.rs:364-370, start_epoch.rs:1003-1026).
- Networking > Gossipsub topics: row `tn-txn` removed (R5a F20; network.rs:349-370, #820, #1064).
- Networking > Gossipsub topics: "Each topic enforces message validation rules specific to its payload type." replaced by three sentences on two-stage validation (12,000-byte cap, allowlist before relay, payload checks) (R5a F21; consensus.rs:2077-2102, network.rs:253).
- Networking > Gossipsub topics: penalty sentence kept; optional author/relayer refinement not applied (R5a F22 optional skipped; consensus.rs:2816-2822).
- Networking > Transaction forwarding: new subsection after Gossipsub topics, five sentences from M1 (no gossip; `eth_sendRawTransaction` to the advertised endpoint; sender-slot routing; fallback and confirmed rejection; retention and retry); no operator material; the author's optional details (non-public hosts, URL scheme) left out (R5a M1; worker.rs:272-339, forward.rs:1-35, :991-1027, record.rs:256-261).
- Networking > Request-response RPC: "/telcoin-network/0.0.1" sentence and code block replaced by the role-specific ids `/tn-primary-{chain_id}/0.0.2` and `/tn-worker-{worker_id}-{chain_id}/0.0.2` (R5b F1; protocol.rs:20-39).
- Networking > Request-response RPC: added the decimal chain-id example and the version-skew sentence; F1's two version-history sentences (types removed in 0.0.2, encoding change versus 0.0.1) dropped for the present-tense voice (R5b F1; consensus.rs:1668-1677, :1709-1718).
- Networking > Request-response RPC: added the rest of the protocol family (kad, sync, peer-exchange, record-exchange at `0.0.1`, worker form); "remain at version" written "use version"; F2's gossip sentence dropped because Gossipsub topics already names `/tn-meshsub-{chain_id}` (R5b F2; protocol.rs:41-102).
- Networking > Request-response RPC: list item "Epoch record synchronization" replaced by "Epoch records" (record plus epoch certificate, by number or digest, or latest) (R5b F4; message.rs:66-77, :228-229).
- Networking > Request-response RPC: list item "Consensus header retrieval" removed (R5b F5; message.rs:49-78, sync/request.rs:74-83).
- Networking > Request-response RPC: list item "Batch downloads" removed (R5b F6; worker network/message.rs:35-50, sync/request.rs:15-28).
- Networking > Request-response RPC: list items "Header votes" and "Batch reports" added, plus a two-sentence paragraph on the sync-stream protocol (R5b F7; message.rs:51-59, :220-227, worker network/message.rs:36-40, sync/request.rs:15-83).
- Networking > Request-response RPC: "1 MiB by default" inserted into the confirmed message-size sentence; the rest of its wording kept (R5b F8; network.rs:259-260, :376).
- Networking > Request-response RPC: "rejected at the transport layer" sentence replaced (rejected from the length prefix before allocation; sender penalized) (R5b F9; codec.rs:46-54, consensus.rs:1685-1707).
- Networking > Request-response RPC: optional request-timeout sentence not applied (R5b F10 optional skipped; consensus.rs:1641-1666).
- Networking > Peer scoring: first sentence replaced (every known peer, connected or not) and "A new peer starts at 0." added (R5b F11; score.rs:1-4, :84-87, network.rs:640-645).
- Networking > Peer scoring: "five minutes by default" appended to the confirmed half-life sentence (R5b F12 optional; network.rs:645-648).
- Networking > Peer scoring: added penalty sizes and the no-penalty faults (two sentences) (R5b F17; score.rs:72-77, consensus.rs:1641-1649, :1668-1677).
- Networking > Peer scoring: added the sync-stream sentence, rephrased without "for now" and "not yet" (R5b F28 optional; consensus.rs:2280-2300).
- Networking > Peer scoring: "Four reputation levels" changed to "Three"; table gains a Score column (R5b F18; score.rs:151-157, :189-201, network.rs:654-655).
- Networking > Peer scoring: row "Good" replaced by `Trusted` (above -20; lowest-scoring peers pruned first) (R5b F19, F18; score.rs:189-194, all_peers.rs:973-990).
- Networking > Peer scoring: row "Average" removed (R5b F20; score.rs:151-157).
- Networking > Peer scoring: row "Bad" replaced by `Disconnected` (-20 or below; reconnection refused for ten minutes) (R5b F21, F18; manager.rs:529-538, network.rs:564).
- Networking > Peer scoring: row "Banned" extended (-50 or below; gossip blacklist, routing-table removal, refused until the score recovers) (R5b F22, F18; behavior.rs:121-139, consensus.rs:2214-2219).
- Networking > Peer scoring: "A peer reaching the minimum score of -100 is banned." replaced (-50 threshold; penalty counts to reach it) (R5b F23; network.rs:655, score.rs:133-136).
- Networking > Peer scoring: ban-duration sentence replaced (30-minute freeze, unbanned above -50); the "evading penalties through rapid reconnection" rationale dropped (R5b F24; score.rs:116-131, network.rs:649-653, peer.rs:483-511).
- Networking > Peer scoring: added the scoring-exemption paragraph; "the node operator has configured" rephrased "in a node's configuration" (R5b F25; peer.rs:311-338, all_peers.rs:859-885, :1229-1246).
- Networking > Peer scoring: added the layered-refusal paragraph; F26's fourth sentence (in-handshake refusal evaluated and not adopted) dropped as design history (R5b F26; behavior.rs:112-139, banned.rs:20, :126, early-identity-refusal.md:3-23).
- Networking > Peer scoring: added the admission paragraph (QUIC Retry, 1024 pending handshakes, eight connections per peer); optional handshake-budget sentence not applied (R5b F27, optional part skipped; quic.rs:34, :49, consensus.rs:174-194).

## Cryptographic primitives

- Cryptographic primitives > intro: "three cryptographic primitives ... Keccak-256 for hashing" replaced (BLAKE3 for consensus digests, Keccak-256 at the execution layer); added the secp256k1 transaction sentence (R5c F1; crypto/mod.rs:262-268, primary/block.rs:17-18).
- Cryptographic primitives > BLS12-381 signatures: "Validators sign certificates, epoch votes, and epoch records" replaced by the full list of BLS-signed messages (R5c F4; vote.rs:39, certificate.rs:279-286, epoch.rs:50-56, :276-290, subscriber.rs:329-333, record.rs:122-142).
- Cryptographic primitives > BLS12-381 signatures: added the min-sig variant, encodings and hash-to-curve tag (two sentences) (R5c F9; bls_keypair.rs:4, :27, IBlsG1.sol:13-15).
- Cryptographic primitives > BLS12-381 signatures: added three sentences on the proof-of-possession message, its on-chain check and `tn_proofOfPossessionMessage` (R5c F8; bls_signature.rs:198-214, ConsensusRegistry.sol:1003-1021, :1062-1078).
- Cryptographic primitives > BLS12-381 signatures: added a three-sentence paragraph on the BLS precompile; address written lower case as in the code (`0x...b151`), not "B151" as in the finding (R5c F10; bls_precompile/mod.rs:1-22, :51, :80, :101).
- Cryptographic primitives > Ed25519 signatures: "Each peer holds an Ed25519 keypair that ... signs peer records" replaced by four sentences (per-swarm keys derived from BLS, peer ID, QUIC and gossip signing, node records signed with BLS) (R5c F12; keys.rs:240-244, :512-525, consensus.rs:574, :586-589, record.rs:11-23).
- Cryptographic primitives > Hashing: heading renamed from "Keccak-256 hashing" to "Hashing" (R5c F13; crypto/mod.rs:266-268).
- Cryptographic primitives > Hashing: "Keccak-256 is the hash function across the protocol." and "It produces ConsensusHeader digests, EpochRecord digests, and block hashes." replaced by one BLAKE3 sentence covering batch, header, certificate, ConsensusHeader and EpochRecord digests (R5c F13, F14 merged; block.rs:67-80, epoch.rs:43-47, header.rs:621-628, sealed_batch.rs:134-139).
- Cryptographic primitives > Hashing: "This maintains compatibility with Ethereum's hashing conventions." replaced by one execution-layer sentence that merges F14's block-hash clause and F16's compatibility sentence (R5c F14, F16; helpers.rs:275-281).
- Cryptographic primitives > Hashing: committee-shuffle randomness sentence replaced by a four-sentence paragraph on the per-round seed signature and the Keccak-256 seed chain; the adiri activation epoch (383) left to Fork scheduling as the finding asks (R5c F15; seed_chain.rs:81-84, :115-124, epoch.rs:260-296, output.rs:292-297, forks.rs:218).
- Cryptographic primitives > Intent-scoped signing: first sentence qualified to "consensus" BLS signatures; added the proof-of-possession prefix and node-record label sentences after the confirmed prefix sentences (R5c F17; crypto/mod.rs:290-294, bls_signature.rs:198-214, record.rs:60-66, :122-125).
- Cryptographic primitives > Intent-scoped signing: `ConsensusDigest` purpose replaced (header votes and consensus-output attestations) (R5c F21; vote.rs:39, certificate.rs:281-286, subscriber.rs:329-333).
- Cryptographic primitives > Intent-scoped signing: `SystemMessage` purpose replaced with "Reserved; no protocol message is signed under it" ("currently" dropped) (R5c F22; intent.rs:63).
- Cryptographic primitives > Intent-scoped signing: added row `EpochCloseSeed` = 4 (R5c F23; intent.rs:64-66, epoch.rs:276-290).
- Cryptographic primitives > Signature verification: indirect-verification sentence replaced by three sentences (bulk catch-up, parent references, leaves and every 50th round verified directly) (R5c F30; cert_validator.rs:271-322, network.rs:490).
- Cryptographic primitives > Signature verification: "In both cases, validity requires ..." replaced (direct needs 2/3 + 1, "two-thirds rounded down, plus one", in words rather than floor brackets; indirect inherits; epoch certificates same threshold) (R5c F31; committee.rs:473-478, certificate.rs:243-246, epoch.rs:84-88).
- Cryptographic primitives > Signature verification: added a two-sentence paragraph on where committee keys come from; RPC names follow the code, `tn_getCommitteeBlsPubkeys` and `tn_getBlsPubkey` (the finding and the facts file write `tn_getBlsPubKey`) (R5c F33; rpc_ext.rs:229-232, tn_getcommitteeblspubkeys.md:3-5).

## Trustless synchronization

- Trustless synchronization > intro: added a three-sentence paragraph on starting from a state snapshot (mechanism only) (R4 F29; SYNC.md:77-97, :159-168, :190-193).
- Trustless synchronization > Step 1: "three properties" changed to "four properties" and list item "Position" added first (R4 F32; epoch_records.rs:345-362, :1205-1217).
- Trustless synchronization > Step 1: list item "Committee continuity" replaced (equals `next_committee`, or a subset after a governance ejection keeping at least four members and two-thirds) (R4 F34; primary/epoch.rs:113-165, epoch_records.rs:316-327).
- Trustless synchronization > Step 1: added a two-sentence paragraph on the newest record being certified after the next epoch begins (R4 F38; SYNC.md:18-25, state-sync/epoch.rs:146-165, run_epoch.rs:1003-1013).
- Trustless synchronization > Step 1: "approximately once per eight hours" sentence replaced (one record per epoch; several hours; six in the Adiri testnet genesis; a governance-changeable `ConsensusRegistry` parameter); "current test network" not used (R4 F39; chain-configs/testnet/genesis.yaml:103, genesis/mod.rs:90-94, system_calls.rs:256-257).
- Trustless synchronization > Step 2: "retrieves consensus headers backwards" sentence replaced by three sentences on per-epoch consensus packs and the backward walk for the epoch in progress (R4 F40; state-sync/consensus.rs:286-300, :347-360, :473-478, storage/consensus.rs:668-728).
- Trustless synchronization > Step 2: "Each header's certificate is verified against the known committee" replaced by two sentences (hash-chain trust; certificate authors checked against the committee) (R4 F42; consensus_pack.rs:3165-3166, :3416-3430).
- Trustless synchronization > Step 2: "seed the backward walk come from three sources" changed to "seed the download come from two sources" (R4 F44; handler.rs:497, state-sync/epoch.rs:155, :252).
- Trustless synchronization > Step 2: "Live committee gossip" Notes cell extended with the one-third-plus-one acceptance threshold (R4 F46; handler.rs:373-415, :480-497).
- Trustless synchronization > Step 2: row "Execution blocks (`parent_beacon_block_root`)" removed and replaced by a two-sentence paragraph after the table; "exposes a fork" written "to detect a fork" (R4 F47; consensus_bus.rs:967-997, node.rs:1669-1698).
- Trustless synchronization > Step 3: added the empty-output sentence (R4 F50 optional; payload_builder.rs:19-24, :98, :114-118).
- Trustless synchronization > Step 3: "the resulting state is compared against the epoch record's final_state checkpoint" replaced by two sentences (leader's execution-block check; `final_state` fixes the starting state) (R4 F51; state-sync/lib.rs:542-575, consensus_bus.rs:916-945, consensus_pack.rs:4155-4162).
- Trustless synchronization > Security properties: first list item replaced (epoch certificates and the live hash are BLS-verified; headers trusted by hash chaining); the finding's two sentences joined with a semicolon to keep one list line (R4 F54; primary/epoch.rs:59-91, handler.rs:381-415, consensus_pack.rs:3165-3166).
- Trustless synchronization > Security properties: optional sentence on compounding ejections not applied; the author left its fit for a partner document to the orchestrator (R4 F57 optional skipped; primary/epoch.rs:132-144).
- Trustless synchronization > Recovery after restart: the long second sentence split in two; its gas-accounting and leader-schedule clause replaced (per-worker gas totals from blocks, leader counts and schedule from the consensus store, base fees from the previous closing block); the confirmed replay clause kept, now opening "It then" (R4 F60, F61; node.rs:306-330, :356-430, leader_schedule.rs:258-279).
- Trustless synchronization > Recovery after restart: "resumes live consensus participation" replaced by resuming in the membership-derived mode (R4 F62; node.rs:969-981, :1165-1172, handler.rs:216-252).
- Trustless synchronization > Recovery after restart: added the epoch-boundary record re-derivation sentence (R4 F63 optional; close_epoch.rs:515-585, run_epoch.rs:222-227).
