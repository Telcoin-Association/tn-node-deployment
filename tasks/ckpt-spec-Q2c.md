status: done

# Checkpoint Q2c

Completed sections:
- 0. Read facts, refresh log part B (Networking + Crypto), spec lines 454-666
- 1a. Networking: intro, Transport, Identity, Gossipsub, Transaction forwarding, Request-response
- 1b. Networking: Peer scoring
- 2. Cryptographic primitives
- 3. Sweep (unchanged sentences, cross-chapter consistency)
- 4. Scope flags
- 5. Summary

Findings (WT = telcoin-network at v0.16.0-adiri; md = docs/partner/technical-specification/technical-specification.md):
- 456: holds: bulk sync streams are a separate protocol (crates/network-libp2p/src/sync/request.rs:1-83).
- 457: inconsistent: true for the libp2p swarms (with_quic_config only, no TCP: crates/network-libp2p/src/consensus.rs:726-743), but the new Transaction forwarding subsection (md 511) sends transactions over HTTP(S) JSON-RPC through alloy's reqwest transport (crates/tn-reth/src/forward.rs:16-20,:65,:1265-1276), i.e. TCP. Corrected: "All peer-to-peer communication uses QUIC v1 over UDP as the sole transport; transaction forwarding uses the validators' JSON-RPC endpoints instead."
- 468: holds: IPv6 accepted, MAX_ADVERTISED_MULTIADDRS = 4, multi-endpoint records live via with_advertised_addresses (crates/node-record/src/addresses.rs:11,:58-63; consensus.rs:804-820).
- 471: imprecise: 5 s keep-alive / 30 s idle are QuicConfig defaults in node configuration, not fixed (crates/config/src/network/quic.rs:37-42). Add "by default".
- 472: wrong: the libp2p SwarmBuilder wraps the transport in TransportTimeout with a 10 s default (libp2p-0.57.0 builder/phase/swarm.rs:5, build.rs:28; TN does not call with_connection_timeout), so a connection attempt including its handshake is cut at ~10 s, not 30 s; TN's own comment says so (crates/network-libp2p/src/consensus.rs:246-248). Corrected: "A connection attempt, handshake included, must complete within 10 seconds; the QUIC handshake timeout (65 s) and idle timeout (30 s) are longer and do not bind first." Or drop the sentence.
- 473: imprecise: QUIC idle timeout reclaims connections whose peer stopped answering; the libp2p 65 s idle timeout closes a live connection no protocol handler is using (keep-alives keep QUIC up). Corrected: "At the libp2p layer a connection that no protocol is using is closed after 65 seconds; a connection whose peer stops answering is closed by the 30-second QUIC idle timeout first." (crates/config/src/network.rs:261-265,:377; consensus.rs:739-742)
- 477-478: holds: network keys = Ed25519 from BLAKE3(BLS signature over a seed string); worker 0 seed, worker k seed + " k" (crates/config/src/keys.rs:504-523,:547-554). Note the seed strings may come from files in the keys dir (keys.rs:367-372), still deterministic.
- 480: holds.
- 481: holds: provide_our_data at run start, refresh every kad_publication_interval default 12 h (consensus.rs:951-967; crates/config/src/network.rs:382). "12 hours" is a configurable default.
- 482-484: holds: NetworkInfo {pubkey, multiaddrs, timestamp, rpc}; rpc only on worker records of opting-in validators; key = primary BLS key for both primary and worker records; signature covers label "telcoin-network/node-record/v1", chain_id, role, worker_id (crates/node-record/src/record.rs:60-125,:236-255; consensus.rs:846-859).
- 486-488 (unchanged): holds: BucketInserts::Manual, StoreInserts::FilterBoth, target_num_peers = K/2 + K = 30 (consensus.rs:626-632; crates/config/src/network.rs:553-554).
- 492: imprecise: `/tn-meshsub-{chain_id}` is the protocol-id prefix; gossipsub appends versions and negotiates `/tn-meshsub-{chain_id}/1.1.0` or `/1.0.0` (crates/node-record/src/protocol.rs:83-101; libp2p-gossipsub-0.50.0 config.rs:584-605). Corrected: "negotiated under the chain-specific protocol ids `/tn-meshsub-{chain_id}/1.1.0` and `/tn-meshsub-{chain_id}/1.0.0`".
- 493-494: holds (crates/config/src/network.rs:349-370; crates/node/src/manager/node/start_epoch.rs:787-842).
- 498: holds (publisher = current committee, start_epoch.rs:823-829). Minor: every node subscribes, observers receive certificates too (primary/src/network/handler.rs:311-350); "between committee members" describes the publishers only.
- 499: holds: ConsensusResult {epoch, round, number, hash, validator, signature}; enough_sigs = committee.len()/3 + 1 (crates/consensus/primary/src/network/handler.rs:362-410).
- 500: holds (start_epoch.rs:830-836).
- 501: holds: only CvvActive/CvvInactive subscribe, observers unsubscribe (start_epoch.rs:1011-1026,:1209-1214).
- 503-505: holds: size check then allowlist check in verify_gossip before relay; topic/payload match in handler (consensus.rs:2077-2102; handler.rs:313-318).
- 510-512: holds: forward via JSON-RPC to the endpoint in the BLS-signed worker record, owner slot = first 8 bytes of sender LE mod committee size, committee from consensus_config (crates/consensus/worker/src/worker.rs:269-322,:100-110; crates/tn-reth/src/forward.rs:1-12,:991-1005).
- 513: imprecise: a first rejection is advisory until a second validator confirms it, BUT "A rejection that reaches the end of the chain unconfirmed stands" when no other validator can be consulted (crates/tn-reth/src/forward.rs:1007-1022). Corrected: "... and a rejection of the transaction itself stands only once a second validator confirms it, or when no other validator can be reached to consult."
- 514: holds: NotValidator keeps txs pending; retry after three executed consensus outputs (default, set_retry_outputs) to a validator that has not accepted it; retention FORWARD_PENDING_LIFETIME (240 s) (worker.rs:316-322; forward.rs:27-34,:110-114,:474-480).
- 518-525: holds (crates/node-record/src/protocol.rs:34-39).
- 526: holds: UnsupportedProtocols not penalized inbound and outbound (crates/network-libp2p/src/consensus.rs:1667-1676,:1709-1716).
- 527-528: holds (protocol.rs:41-80). Minor: the peer-exchange goodbye falls back to the PeerExchange variant inside the 0.0.2 request-response enums when a peer lacks the dedicated protocol (crates/network-libp2p/src/types.rs:70-76).
- 532-534: holds: PrimaryRequest {Vote, PeerExchange, EpochRecord}, PrimaryResponse {Vote, MissingParents, EpochRecord{record, certificate}}; WorkerRequest {ReportBatch, PeerExchange}, WorkerResponse {ReportBatch, Error, RecoverableError} (crates/consensus/primary/src/network/message.rs:49-77,:213-229; crates/consensus/worker/src/network/message.rs:31-87).
- 536-537: holds: PrimarySyncRequest {EpochPack, MissingCertificates, EpochPackPartial, ConsensusOutput}, WorkerSyncRequest {Batches} (crates/network-libp2p/src/sync/request.rs:15-83).
- 539: imprecise: the 1 MiB default (max_rpc_message_size) bounds request-response and peer-exchange messages only (consensus.rs:593,:605); gossip is capped at 12,000 bytes (network.rs:253), Kademlia packets at 16 KiB (consensus.rs:134), sync streams bound each frame separately (crates/consensus/worker/src/network/handle.rs:390; primary sync_codec.rs:970). Corrected: "Each request-response message is capped at 1 MiB by default, and the other protocols carry their own limits, to bound resource consumption."
- 540: holds: codec rejects from the 4-byte length prefix (crates/network-libp2p/src/codec.rs:46-54); the resulting InvalidData IO error takes a Medium penalty (consensus.rs:1641-1660,:1689-1705).
- 544-546: holds: default_score 0, range [-100,100], halflife 300 s default (crates/network-libp2p/src/peers/score.rs:1-4,:36-44,:105-114; crates/config/src/network.rs:640-648). Trusted peers start at the maximum (peer.rs:136-146), minor.
- 554: holds: Mild -1, Medium -5, Severe -10, Fatal = min_score (score.rs:69-77).
- 555: holds: DialFailure, ConnectionClosed, reset/abort/EOF IO kinds and UnsupportedProtocols unpenalized (consensus.rs:1636-1676,:1689-1720).
- 556: wrong: only transport-level stream failures are classified without being enforced, and at this site they are only logged at debug, not metered (consensus.rs:2280-2295). Content faults on the sync streams DO change scores: a peer that streams a well-formed but wrong-hash consensus output takes a Severe penalty (crates/consensus/primary/src/network/mod.rs:600-617), and a peer-caused epoch-pack import failure is penalized (mod.rs:1194-1212). Corrected: "Transport-level failures on the bulk sync streams carry no penalty, but a peer whose streamed data fails verification is penalized like any other."
- 558-564: holds: reputation_for: <= -50 Banned, <= -20 Disconnected, else Trusted (score.rs:151-157); Disconnect -> temporarily_ban with excess_peers_reconnection_timeout 600 s default (manager.rs:526-538; network.rs:564); Ban -> gossipsub blacklist + kad remove_peer, inbound refused while peer_banned (consensus.rs:2214-2219; behavior.rs:133-136; manager.rs:596-603); pruning lowest score first, non-validators only (all_peers.rs:973-990; manager.rs:795-815).
- 566-567: holds (score.rs:133-136; config min_score_before_ban -50).
- 568: imprecise: freeze = banned_before_decay_secs 30 min default (score.rs:126-130; network.rs:653), but "always lasts at least that long" contradicts 572: a banned peer that joins a tracked committee is unbanned and reset at once (all_peers.rs:1229-1246). Corrected: "... so a ban lasts at least that long unless the peer joins a tracked committee."
- 569: holds: heartbeat Unbanned when reputation leaves Banned (peer.rs:483-500).
- 571: wrong: only committee members are exempt in a running node. The exemption reads peer.is_operator_allowlisted(), set only by Peer::new_trusted via add_trusted_peer_and_dial (peer.rs:136-146; all_peers.rs:859-885; manager.rs:300-308), which nothing outside the network crate's tests calls; the node configures bootstrap peers only, through add_bootstrap_peer, which pins the record but does not exempt it (crates/node/src/manager/node.rs:1047,:1078; manager.rs:1045-1051; consensus.rs:1132-1151). Corrected: "Members of the previous, current and next committees are exempt from scoring: penalties and bans do not apply to them, and they may connect beyond the normal peer limits." (behavior.rs:316)
- 572: holds (all_peers.rs:1229-1246; manager.rs:926-943).
- 575: holds: BANNED_PEERS_PER_IP_THRESHOLD = 1, ip_banned when count > 1; checked in handle_pending_inbound_connection (banned.rs:18-20,:126-128; behavior.rs:111-118,:270-276).
- 576: holds: peer_manager is the first sub-behaviour and rejects self and banned peers in handle_established_inbound_connection (behavior.rs:120-139; consensus.rs:262-288). Live; no TLS-stage refusal (docs/src/network/early-identity-refusal.md:3-17).
- 578: holds with condition: QUIC Retry is the default (retry_unvalidated_incoming true, an operator rollback switch) (crates/config/src/network/quic.rs:29-34,:49); 1024 pending per swarm (consensus.rs:176-194,:256-261).
- 579: holds (consensus.rs:174).
- 583-584: holds: DefaultHashFunction = blake3, secp256k1 execution keys (crates/types/src/crypto/mod.rs:262-268).
- 589-590: imprecise: list holds for validators (vote.rs:36-39; epoch.rs:50-56,:276-290; handler.rs:395-399), but every node, not only validators, BLS-signs its node records (consensus.rs:823-833, :840-844), as md 481 says. Corrected tail: "...; and every node, validator or not, signs the node records it publishes for peer discovery." Seed signature on Adiri only from epoch 383, mainnet from genesis (crates/types/src/forks.rs:186-218); covered by the Fork gates table (md 321).
- 591: holds (certificate.rs:274-286; epoch.rs:82-88).
- 592-593: holds: blst::min_sig, DST_G1 = "BLS_SIG_BLS12381G1_XMD:SHA-256_SSWU_RO_NUL_" (crates/types/src/crypto/bls_keypair.rs:4,:27).
- 595-597: holds: 3 + 96 + 20 = 119 bytes, prefix Intent::telcoin(ProofOfPossession) = 0x000000 (crates/types/src/crypto/bls_signature.rs:198-214).
- 598: holds: proofOfPossessionMessage rebuilt on chain, staticcall to BLS_G1_ADDRESS, _spendBLSPubkey reverts DuplicateBLSPubkey (keyed on the x-coordinate, so the negated key is refused too) (tn-contracts/src/consensus/ConsensusRegistry.sol:998-1072).
- 599: holds (crates/execution/tn-rpc/src/rpc_ext.rs:267).
- 601: holds (crates/tn-reth/src/evm/bls_precompile/mod.rs:51-62; IBlsG1.sol:9).
- 602: imprecise (minor): the message is capped at 4,096 bytes (MAX_BLS_VERIFY_MESSAGE_LEN, crates/tn-reth/src/evm/bls_precompile/mod.rs:113,:250). Corrected: "...so any contract can check any BLS-signed message of up to 4,096 bytes".
- 603: holds: 150,000 base + 12 gas per 32-byte word of the ABI-encoded arguments (selector unpriced); nonzero value rejected before dispatch; not fork-gated (bls_precompile/mod.rs:80,:101,:123-128,:177-182).
- 607-611: holds: per-swarm derived keys; MessageAuthenticity::Signed + ValidationMode::Strict; records BLS-signed (keys.rs:504-554; consensus.rs:570-589; record.rs:114-125).
- 615: inconsistent/imprecise: a ConsensusHeader digest is BLAKE3 over parent hash, sub-DAG digest, number (LE) and a 32-byte zero reserved field (crates/types/src/primary/block.rs:61-80), as Architecture overview md 26 says, not a hash of "the encoded structure"; a certificate's digest IS its header's digest (crates/types/src/primary/certificate.rs:486-488). Batch, header and EpochRecord are hashes of the encoding (sealed_batch.rs:134-139; header.rs:621-628; epoch.rs:43-47). Corrected: "The consensus layer hashes with BLAKE3: batch, header, ConsensusHeader and EpochRecord digests are 32-byte BLAKE3 hashes, and a certificate is identified by its header's digest."
- 616: holds.
- 618-621: holds: EpochSeedMessage {epoch, round, prior_epoch_record} under EpochCloseSeed; root keccak256(ROOT_DOMAIN || epoch LE); fold keccak256(FOLD_DOMAIN || value || leader_round LE || signature) (crates/types/src/primary/seed_chain.rs:81-84,:115-124; epoch.rs:260-296). Adiri condition as for 590.
- 625-629: holds: every consensus signature is over an IntentMessage (mod.rs:290-294; epoch.rs:53,:281); Intent serialises as scope, version, app_id (intent.rs:84-92); PoP raw bytes with prefix (bls_signature.rs:209-213); record label "telcoin-network/node-record/v1" + chain id + role (record.rs:60-125).
- 635-639: holds: discriminants 0-4 exactly (crates/types/src/crypto/intent.rs:59-67); SystemMessage has no user outside intent.rs (grep); ConsensusDigest used for votes, certificates and ConsensusResult (vote.rs:36-39; certificate.rs:281-283; handler.rs:395-399).
- 641, 647-648, 650: holds (intent.rs:17-21,:39-43).
- 655: holds (minor: the certificate's own epoch committee, certificate.rs:255-266).
- 656-658: imprecise: only leaves and certificates at rounds that are multiples of certificate_verification_round_interval (default 50, configurable) are verified directly; a parent can be accepted through a child that is itself only indirectly verified, the chain ending at a directly verified certificate (crates/consensus/primary/src/state_sync/cert_validator.rs:271-312; crates/config/src/network.rs:490). Corrected 657: "... is accepted through that reference, because the child's header digest commits to its parents' digests, and every chain of such references ends at a certificate whose signatures are checked directly." Also 658 "every 50th round" = "at every round that is a multiple of 50".
- 660-661: holds: quorum_threshold = 2n/3 + 1 (integer division) for certificates, super_quorum identical for epoch certificates (crates/types/src/committee.rs:473-478,:1191-1193; crates/types/src/primary/epoch.rs:84-110).
- 662 (unchanged): holds (understated: a 2f+1 quorum holds at least f+1 honest signers).
- 664-665: holds: method names getBlsPubkey / getCommitteeBlsPubkeys (rpc_ext.rs:229-233); window current-3 .. current+2 (ConsensusRegistry.sol:410-414); registry order (ConsensusRegistry.sol:472-480; docs/src/rpc-methods/tn/tn_getcommitteeblspubkeys.md:3-5). Note the facts file spells tn_getBlsPubKey; the md follows the code, correctly.

## Sweep (unchanged or cross-chapter)

- 457: inconsistent: see above (HTTP JSON-RPC forwarding vs "sole transport").
- 703 (Trustless synchronization) vs 537: inconsistent (low): the node requests a consensus output by its consensus number over the sync stream and checks the decoded header digest against the verified hash; a peer serving a wrong-hash output takes a Severe penalty (crates/consensus/primary/src/network/mod.rs:600-617,:752; crates/state-sync/src/consensus.rs:229-262). Suggested 703: "Syncing nodes request the consensus output at the next number down, confirm its header digest matches the verified hash, then continue with the header's `parent_hash`."
- 280 (Committee shuffle) vs 619: inconsistent (low): 280 says the seed signature is "over its epoch and round"; the signed EpochSeedMessage also binds the previous epoch record's digest (crates/types/src/primary/epoch.rs:260-275), as 619 states. Suggested 280: "...its deterministic BLS seed signature over its epoch, its round and the previous epoch record's digest".
- 615 vs 26: inconsistent: listed above (ConsensusHeader digest).
- 568 vs 572: listed above ("always" vs committee unban).
- 590 vs 481: listed above (who signs node records).
- No other stale unchanged sentence found in 454-666: 461, 470, 486-488, 506, 530, 548-552, 595-596, 641, 650, 654-655, 662 hold at the tag (cites in part 1/2).

## Scope (partner-document fitness)

- 471-473: QUIC keep-alive, idle and handshake timers and the libp2p idle timeout are node-configuration defaults (crates/config/src/network/quic.rs:37-52; crates/config/src/network.rs:377); internal and likely to change. Suggest keeping only the qualitative sentence at 470, or say "by default".
- 481 (12 hours), 488 (30 peers), 539 (1 MiB), 546 (five minutes), 563 (ten minutes), 568 (30 minutes), 658 (every 50th round), 514 (three consensus outputs): configurable defaults, not protocol constants (network.rs:376-383,:490,:553-565,:640-656; forward.rs:474-480). At minimum mark each "by default".
- 544-579 as a whole: the code marks the scoring model "an experimental approach and is subject to change" (crates/network-libp2p/src/peers/score.rs:4); the thresholds table, penalty sizes, IP-ban rule, 1024 pending slots and eight connections per peer are internal tuning. Consider a short qualitative section.
- 571: "in a node's configuration" points at node configuration (and the trusted-peer exemption is not reachable from it at the tag: wrong above).
- 578: QUIC Retry is a default with an operator rollback switch (retry_unvalidated_incoming, quic.rs:29-34); "1024 per network" is an internal memory bound (consensus.rs:176-194).
- 504: the 12,000-byte gossip cap is a fixed protocol constant (network.rs:240-253): acceptable.
- 493, 525: chain id 2017 for Adiri is a stable genesis value: acceptable.
- 599, 665, 511: RPC method names (`tn_proofOfPossessionMessage`, `tn_getCommitteeBlsPubkeys`, `tn_getBlsPubkey`, `eth_sendRawTransaction`) are public API, not operator instructions: acceptable.
- No `--observer`, script, tool, flag or file path appears in 454-666.

## Summary

Verdict counts over the part-B entries and confirmed sentences checked in 454-666:
- holds: 50
- wrong: 3 (472 handshake ceiling; 556 sync-stream penalties; 571 trusted/bootstrap exemption)
- imprecise: 9 (471, 473, 492, 513, 539, 568, 589-590, 602, 656-658)
- inconsistent: 4 (457 vs 511; 615 vs 26; 703 vs 537; 280 vs 619)
- stale (unchanged and wrong at the tag): 0 beyond the inconsistencies above
- scope flags: 6 groups (timers; configurable defaults; experimental scoring model; 571 config reference; 578 rollback switch and internal bound; none for operator material)

Could not settle: nothing material. The 472 point was settled: libp2p-core 0.44.0 TransportTimeout::new bounds both dial and listener upgrades (transport/timeout.rs:52-62,:120-129) and the 0.57.0 builder wraps the QUIC transport with it at 10 s (builder/phase/swarm.rs:5, build.rs:28). Not checked: the live Adiri network's current values (only the code at the tag).
