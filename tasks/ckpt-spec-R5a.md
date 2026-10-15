# R5a checkpoint: Networking intro, Transport, Identity and discovery, Gossipsub topics, Transaction forwarding

status: complete
completed sections: Networking intro, Transport, Identity and discovery, Gossipsub topics, Transaction forwarding (missing), Summary
remaining: none

Source text: transcription.md lines 327-362. All cites are WT-relative at tag v0.16.0-adiri
(d72cc2bcf). WT = scratchpad/tn-v0.16.0-adiri.

## Networking (chapter intro)

### F1 Networking intro
- claim: "Telcoin Network nodes communicate over a structured peer-to-peer overlay that combines publish-subscribe gossip, direct request-response messaging, and DHT-based discovery."
- verdict: confirmed
- replacement: n/a (optional, more complete: "...that combines publish-subscribe gossip, direct request-response messaging, bulk-sync streams and DHT-based discovery.")
- cite: crates/network-libp2p/src/consensus.rs:280-310 (TNBehavior: gossipsub, req_res, peer_exchange, record_exchange, kademlia, stream sync), crates/network-libp2p/src/consensus.rs:687-695
- note: read the behaviour struct and the swarm constructor; the three named mechanisms are all present, plus a stream behaviour for bulk sync.

### F2 Networking intro
- claim: "All communication uses QUIC v1 over UDP as the sole transport."
- verdict: confirmed
- replacement: n/a
- cite: crates/network-libp2p/src/consensus.rs:726-744 (SwarmBuilder ... with_quic_config, no other transport), crates/network-libp2p/Cargo.toml:12-18 (libp2p features: request-response, gossipsub, tokio, quic, macros, kad; no tcp)
- note: no TCP, noise or yamux feature is compiled in; docs/src/network/transport.md:22-28 agrees.

## Transport

### F3 Transport
- claim: "Every peer-to-peer connection requires a static IPv4 or IPv6 address."
- verdict: confirmed
- replacement: n/a
- cite: crates/node-record/src/addresses.rs:7-11, crates/node-record/src/addresses.rs:44-63
- note: an advertised endpoint must be an IPv4 or IPv6 literal (not unspecified/multicast), a nonzero UDP port and QUIC v1; DNS names, relays and wildcards are rejected, so a resolvable fixed IP is required.

### F4 Transport
- claim: "Node addresses follow the multiaddr convention: /ip4/{HOST}/udp/{PORT}/quic-v1"
- verdict: confirmed
- replacement: n/a (optional addition after the code block: "An IPv6 endpoint takes the form `/ip6/{HOST}/udp/{PORT}/quic-v1`, and a node record may advertise up to four endpoints.")
- cite: crates/node-record/src/addresses.rs:58-63, crates/node-record/src/addresses.rs:11 (MAX_ADVERTISED_MULTIADDRS = 4), crates/network-libp2p/src/consensus.rs:799-819 (with_advertised_addresses)
- note: validator accepts Ip4|Ip6 / Udp(nonzero) / QuicV1 with an optional /p2p suffix bound to the network key; docs/src/network/transport.md:90 shows the same ip4 form.

### F5 Transport
- claim: "Connections maintain periodic keep-alive probes to prevent NAT and firewall timeouts."
- verdict: confirmed
- replacement: n/a
- cite: crates/config/src/network/quic.rs:15-20, crates/config/src/network/quic.rs:42 (keep_alive_interval 5 s), crates/config/src/network.rs:261-265
- note: QUIC (quinn) transport keep-alive after 5 s of inactivity; the code comment says TN relies on QUIC keep-alive instead of a separate swarm behaviour. The NAT/firewall rationale is interpretive but consistent.

### F6 Transport
- claim: "The maximum idle connection timeout is 65 seconds by default, and is aligned with the QUIC handshake timeout so stale connections are reclaimed promptly."
- verdict: stale
- replacement: "A quiet connection sends a QUIC keep-alive after 5 seconds of inactivity, and the transport closes a connection after 30 seconds without traffic. The handshake ceiling is the smaller of the 65-second handshake timeout and that 30-second idle timeout, so a handshake has 30 seconds to complete. The swarm keeps an idle connection open for up to 65 seconds, which leaves the QUIC idle timeout as the limit that reclaims stale connections."
- cite: crates/config/src/network/quic.rs:10-14, crates/config/src/network/quic.rs:40-42 (handshake 65 s, max_idle_timeout 30 000 ms, keep-alive 5 s), crates/config/src/network.rs:377 (swarm max_idle_connection_timeout 65 s, "same as quic handshake"), crates/network-libp2p/src/consensus.rs:739-743
- note: the 65 s figure is the swarm-level idle timeout only; the QUIC transport idle timeout (30 s) is the binding one, so "reclaimed promptly" is attributed to the wrong value. docs/src/network/transport.md:43-56 states the same.

## Identity and discovery

### F7 Identity and discovery
- claim: "Each node derives its network identity from an Ed25519 keypair. The peer ID is the node's unique identifier across all protocol interactions."
- verdict: stale
- replacement: "Each node holds a BLS12-381 keypair, and its network identity is an Ed25519 keypair derived deterministically from that BLS key. The primary and each worker run their own swarm with their own derived network key, so a node has one peer ID per swarm; the BLS public key is the identifier that ties them together."
- cite: crates/config/src/keys.rs:240-244, crates/config/src/keys.rs:547-554 (generate_network_keypair: hash of a BLS signature over a seed, ed25519_from_bytes), crates/config/src/keys.rs:504-523 (per-worker keys), crates/network-libp2p/src/consensus.rs:280-310 (separate swarms per role)
- note: the Ed25519 key is not independent; it is derived from the BLS key, and the primary and every worker have distinct peer IDs, so "the peer ID is the node's unique identifier" no longer holds per node. docs/src/network/transport.md:68-82 agrees.

### F8 Identity and discovery
- claim: "Validators additionally hold BLS12-381 keypairs used for consensus signing."
- verdict: stale
- replacement: (folded into F7) "The BLS key signs headers, votes and certificates when the node sits on the committee, and it is the key registered on-chain."
- cite: crates/config/src/keys.rs:355-385 (every KeyConfig load reads the BLS keyfile and derives the network key from it), docs/src/network/transport.md:77-79
- note: every node, validator or not, loads a BLS keypair because its network keys derive from it; "additionally" and "validators" are wrong.

### F9 Identity and discovery
- claim: "To enable discovery, validators publish signed peer records to a Kademlia DHT."
- verdict: stale
- replacement: "To enable discovery, every node publishes a node record to the Kademlia DHT of each of its swarms, signed with its BLS key, and republishes it every 12 hours."
- cite: crates/network-libp2p/src/consensus.rs:951-955 (run: Mode::Server, provide_our_data unconditionally), crates/network-libp2p/src/consensus.rs:904-922, crates/config/src/network.rs:382 (kad_publication_interval 12 h), crates/node-record/src/lib.rs:4-7
- note: publication is unconditional in ConsensusNetwork::run, so observers publish too; only the resolution cache is committee-filtered (docs/src/network/discovery.md:57-59).

### F10 Identity and discovery
- claim: "Each record contains the validator's BLS public key, Ed25519 peer ID, and current network addresses, allowing any node to resolve a validator's connection details from its BLS public key alone."
- verdict: stale
- replacement: "Each record is keyed by the node's primary BLS public key and carries the swarm's Ed25519 network public key (from which the peer ID follows), its advertised addresses, a publication timestamp and, on worker records of validators that opt in, a public RPC endpoint. The BLS signature covers the chain id and the role (primary or worker id), so a record verifies only on the network it was signed for. Any node can therefore resolve a validator's connection details from its BLS public key alone."
- cite: crates/node-record/src/record.rs:10-23, crates/node-record/src/record.rs:246-262 (NetworkInfo: pubkey, multiaddrs, timestamp, rpc), crates/node-record/src/record.rs:60-125 (label line 66, RecordDomain, signing_bytes line 122), crates/network-libp2p/src/kad.rs:230-232 (record key = primary BLS public key)
- note: the BLS key is the DHT record key, not a field of the record; the record carries the network public key, not the peer ID; timestamp, optional RPC info and domain separation (GHSA-cc64-wfq5-56ph) are new since April.

### F11 Identity and discovery
- claim: "The DHT uses standard Kademlia routing with a K-bucket size of 20."
- verdict: confirmed
- replacement: n/a
- cite: crates/config/src/network.rs:380 (k_bucket_size: K_VALUE), crates/network-libp2p/src/consensus.rs:628; libp2p-kad 0.49.0 src/lib.rs:91 (K_VALUE = 20, version from Cargo.lock:5540-5541)
- note: K_VALUE is the libp2p-kad constant 20.

### F12 Identity and discovery
- claim: "Bucket inserts are performed manually with record filtering to prevent pollution."
- verdict: confirmed
- replacement: n/a
- cite: crates/network-libp2p/src/consensus.rs:624-636 (BucketInserts::Manual, StoreInserts::FilterBoth)
- note: both settings present; inbound records must pass BLS verification, the address checks and a publisher-equals-record-key check before storage (consensus.rs:857-901).

### F13 Identity and discovery
- claim: "Nodes target 30 connected peers (150% of K-bucket size) to maintain routing table coverage."
- verdict: confirmed
- replacement: n/a (optional addition: "Peers are found through the bootstrap peers, which default to the genesis committee, Kademlia record lookups and random closest-peer walks, a direct record exchange with each newly connected peer, and a peer-exchange list that a node over its target sends before it disconnects.")
- cite: crates/config/src/network.rs:552-557 (target_num_peers = K_VALUE/2 + K_VALUE = 30), crates/config/src/network.rs:127-139 (bootstrap: CLI, then config, then genesis), crates/config/src/network.rs:266-280 (peer-exchange on graceful disconnect), crates/network-libp2p/src/record_exchange.rs:1-6, crates/node-record/src/protocol.rs:62-80
- note: arithmetic holds (10 + 20 = 30); connection ceiling is 30 x 1.3 = 39 (network.rs:574-577). Optional sentence covers the discovery paths the section does not name.

## Gossipsub topics

### F14 Gossipsub topics
- claim: "Message dissemination uses the gossipsub publish-subscribe protocol across five dedicated topics:"
- verdict: stale
- replacement: "Message dissemination uses the gossipsub publish-subscribe protocol, negotiated as `/tn-meshsub-{chain_id}`, across four topics. Every topic name carries the genesis chain id (2017 on adiri), and the worker topic also carries the worker id, so nodes on different chains never share a mesh. Each topic accepts messages only from an allowlist of BLS keys that the node refreshes at the start of every epoch:"
- cite: crates/config/src/network.rs:349-370 (exactly four topic constructors), crates/node-record/src/protocol.rs:99-101 (gossip_protocol_id_prefix), crates/network-libp2p/src/consensus.rs:570-585, crates/node/src/manager/node/start_epoch.rs:814-842
- note: no transaction topic exists anywhere in crates/ or docs/src/ (grep for tn-txn, txn_topic: no hits); #1064 (a0162b9a1) dropped the dead topic constants. The builder appends /1.1.0 and /1.0.0 to the protocol prefix.

### F15 Gossipsub topics (table header)
- claim: "| Topic | Purpose |"
- verdict: stale
- replacement: "| Topic | Authorised publishers | Purpose |" (adds the #912 publisher column; rows below give the full replacement table)
- cite: docs/src/network/gossip.md:19-24, crates/node/src/manager/node/start_epoch.rs:787-842
- note: since #912 the publisher set is part of each topic's definition and is enforced before relay.

### F16 Gossipsub topics (row 1)
- claim: "| `tn-primary` | Primary certificate propagation between validators |"
- verdict: stale
- replacement: "| `tn-primary-{chain_id}` | Current committee | Certificate propagation between committee members |"
- cite: crates/config/src/network.rs:349-352, crates/node/src/manager/node/start_epoch.rs:824-829 (allowlist = committee_keys), crates/consensus/primary/src/network/mod.rs:411-416 (publish_certificate)
- note: purpose unchanged; the name now carries the chain id and publishers are the current committee.

### F17 Gossipsub topics (row 2)
- claim: "| `tn-consensus-output` | Committed consensus output for observers and syncing nodes |"
- verdict: stale
- replacement: "| `tn-consensus-output-{chain_id}` | Previous, current and next committee | Signed announcements of each committed consensus header (epoch, round, number and hash); a header signed by more than one third of the committee is trusted by observers and syncing nodes |"
- cite: crates/config/src/network.rs:354-357, crates/consensus/primary/src/network/mod.rs:418-441 (ConsensusResult: epoch, round, number, hash, validator, signature), crates/consensus/primary/src/network/handler.rs:362-410 (committee member check, signature verify, threshold committee.len()/3 + 1), crates/node/src/manager/node/start_epoch.rs:801-806 and 837-842 (boundary_publishers), crates/consensus/executor/src/subscriber.rs:336
- note: the topic carries a signed header digest, not the output itself; the window spans three committees so boundary messages from a rotating committee are still relayed (#912).

### F18 Gossipsub topics (row 3)
- claim: "| `tn-epoch-vote` | Epoch boundary vote signatures |"
- verdict: stale
- replacement: "| `tn-epoch-vote-{chain_id}` | Previous, current and next committee | Epoch boundary vote signatures |"
- cite: crates/config/src/network.rs:359-362, crates/consensus/primary/src/network/mod.rs:443-448 (publish_epoch_vote), crates/node/src/manager/node/start_epoch.rs:830-836
- note: purpose confirmed; name and publisher window updated.

### F19 Gossipsub topics (row 4)
- claim: "| `tn-worker` | Worker batch digest propagation |"
- verdict: stale
- replacement: "| `tn-worker-{chain_id}-{worker_id}` | Current committee | Batch digest announcements for one worker; only committee members subscribe |"
- cite: crates/config/src/network.rs:364-370 (one mesh per worker id), crates/consensus/worker/src/network/handle.rs:139-149 (payload (epoch, batch digest)), crates/node/src/manager/node/start_epoch.rs:1003-1026 and 1209-1214 (should_subscribe_batch_topic: CvvActive/CvvInactive subscribe, Observer unsubscribes)
- note: purpose confirmed; per-worker naming and the committee-only subscription are new.

### F20 Gossipsub topics (row 5)
- claim: "| `tn-txn` | Transaction propagation to workers |"
- verdict: stale
- replacement: delete the row. Transactions are not gossiped; see the new "Transaction forwarding" subsection (M1).
- cite: crates/config/src/network.rs:349-370 (no transaction topic), crates/tn-reth/src/forward.rs (see M1), docs/src/network/gossip.md:3
- note: #820 replaced transaction gossip with RPC forwarding to the committee; #1064 removed the dead constants. grep for tn-txn / txn_topic finds nothing at the tag.

### F21 Gossipsub topics
- claim: "Each topic enforces message validation rules specific to its payload type."
- verdict: stale
- replacement: "Validation runs in two stages. Before relaying anything, the network layer rejects a message larger than 12,000 bytes or one whose author does not resolve to a BLS key on the topic's allowlist, so an unauthorised message is never forwarded. The receiving component then checks that the payload type belongs on the topic it arrived on and validates the payload itself."
- cite: crates/network-libp2p/src/consensus.rs:2077-2102 (verify_gossip: size, allowlist), crates/config/src/network.rs:253 (MAX_GOSSIP_MESSAGE_SIZE = 12_000), crates/network-libp2p/src/consensus.rs:570-576 (Strict validation, manual validate_messages), crates/consensus/primary/src/network/handler.rs:362-368 and 512-517 (topic re-check)
- note: the per-payload part is still true; the publisher allowlist and size bound (#912) are the new first stage.

### F22 Gossipsub topics
- claim: "Messages that fail validation result in peer score penalties that may result in a node temporarily banning a peer."
- verdict: confirmed
- replacement: n/a (optional refinement: "...penalties, charged to the message's author or, for an oversized message, to the peer that relayed it; a fatal penalty bans the peer.")
- cite: crates/network-libp2p/src/consensus.rs:2816-2822 (RejectReason::penalty: TooLarge -> FatalRelayer, UnauthorizedAuthor -> FatalAuthor, Skip when unresolved), crates/consensus/primary/src/error/network.rs:191-195, crates/config/src/network.rs:653 (banned_before_decay_secs = 30 min before score decay)
- note: bans are temporary (score decays after banned_before_decay_secs); details belong to the "Peer scoring" section owned by another unit.

## Transaction forwarding (new subsection, after "Gossipsub topics")

### M1 Transaction forwarding
- claim: (none; the April text has no such subsection and listed a `tn-txn` gossip topic instead)
- verdict: missing
- replacement:

```markdown
### Transaction forwarding

Transactions are not gossiped. A node outside the current committee accepts a transaction into its own pool and forwards it with `eth_sendRawTransaction` to a committee validator, at the JSON-RPC endpoint that validator advertises in its BLS-signed worker node record. The node takes the committee for the epoch from chain state and sends each transaction first to the validator whose committee slot owns the sender's address, so every transaction from one account reaches the same validator and nonce order is preserved. If that validator advertises no endpoint, cannot be reached or refuses the transaction for a reason local to its own node, the node tries the other committee validators in a rotating order, and a rejection of the transaction itself stands only once a second validator confirms it. When no committee endpoint is usable, the transactions stay in the node's pool for a later attempt, and a forwarded transaction that is missing from the next three consensus outputs is sent to a different validator until it is included or its retention period ends.
```

- cite, sentence by sentence:
  - S1 "Transactions are not gossiped.": crates/config/src/network.rs:349-370 (four topics, none for transactions); crates/consensus/worker/src/worker.rs:272-276 ("Replaces the previous gossip broadcast"); commit 9ace6219a "push non-validator txns to committee via RPC instead of gossip (#820)".
  - S2 accept, then `eth_sendRawTransaction` to the advertised endpoint: crates/consensus/worker/src/worker.rs:335-339 (a worker without a quorum waiter, i.e. not in the committee, calls disburse_txns), crates/consensus/worker/src/worker.rs:281-322; crates/tn-reth/src/forward.rs:1-12, :86-88, :1070 (provider.send_raw_transaction); crates/node-record/src/record.rs:256-261 (rpc field on worker records of validators that opt in); crates/network-libp2p/src/peers/manager.rs:1290-1299 (current_committee_rpcs reads endpoints from verified records of current committee members).
  - S3 committee and sender-slot routing: crates/consensus/worker/src/worker.rs:101-110 (committee_slots from consensus_config.committee() in slot order); crates/tn-reth/src/forward.rs:991-1004 (owning_validator: first 8 bytes of the sender address modulo committee size); crates/batch-validator/src/validator.rs:101-121 (same rule on the validator side, submit_txn_if_mine).
  - S4 fallback and confirmed rejection: crates/tn-reth/src/forward.rs:8-12 (skip validators without an endpoint; fallback order rotates per node and per forward, #1173), :21-30 (endpoint-local failures fall through; first rejection held until a second validator confirms, #1167), :1006-1027 (walk_fallback_chain; first acceptance ends the walk), :183 (UNREACHABLE_COOLDOWN 30 s demotion).
  - S5 failure handling and retry: crates/consensus/worker/src/worker.rs:272-280 and :316-322 (no admissible endpoint returns NotValidator so the batch builder keeps the transactions pending for a later build); crates/tn-reth/src/forward.rs:30-35 (retain and watch inclusion; retry to a different validator after three newer consensus outputs omit it, #1366), crates/tn-reth/src/forward_pending.rs:16 (DEFAULT_RETRY_OUTPUTS = 3), crates/tn-reth/src/forward.rs:110-114 (FORWARD_PENDING_LIFETIME = 2 x 120 s).
- note: verified in code. docs/src/architecture/transaction-lifecycle.md:3-11 describes only a validator receiving a transaction directly and says nothing about forwarding, so it supports none of these sentences and is itself out of date. Optional detail left out for brevity: by default the forwarder refuses to dial non-public hosts (forward.rs:37-42, #1092), and forwarding sends the signed bytes over whatever scheme (http or https) the validator advertised (forward.rs:16-20). The doc line at forward.rs:1006 ("until two accept it") contradicts its own body at :1026 ("A first acceptance ends the walk"); the body matches the code path and the module header (:30).

## Secondary-source drift noticed (not spec findings)

- docs/src/network/discovery.md:49-50 says a record advertises at most one multiaddr; the code allows four (crates/node-record/src/addresses.rs:11, MAX_ADVERTISED_MULTIADDRS = 4).
- docs/src/network/transport.md:36 lists seven swarm behaviours without the record-exchange behaviour (crates/network-libp2p/src/consensus.rs:307).

## Summary

- confirmed: 9 (F1, F2, F3, F4, F5, F11, F12, F13, F22)
- stale: 13 (F6, F7, F8, F9, F10, F14, F15, F16, F17, F18, F19, F20, F21)
- unverifiable: 0
- missing: 1 (M1 Transaction forwarding)
