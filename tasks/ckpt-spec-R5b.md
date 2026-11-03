status: complete (both sections done, summary written)

# Checkpoint R5b

Scope: transcription.md lines 363-399 (Networking: "Request-response RPC", "Peer scoring").
Source: telcoin-network worktree WT at tag v0.16.0-adiri (d72cc2bcf). All cites WT-relative.

## Completed sections
- Request-response RPC (F1-F10)
- Peer scoring (F11-F28)
- Summary

## Findings

### F1 Request-response RPC
- claim: "Point-to-point communication uses a request-response protocol identified as: `/telcoin-network/0.0.1`"
- verdict: stale
- replacement: "Point-to-point communication uses a request-response protocol whose identifier names the node's role and the chain id, so a primary only negotiates with primaries, each worker only with workers of the same index, and nodes on different chains never negotiate at all:

  ```text
  /tn-primary-{chain_id}/0.0.2
  /tn-worker-{worker_id}-{chain_id}/0.0.2
  ```

  The chain id is written in decimal, so on adiri (chain id 2017) a primary advertises `/tn-primary-2017/0.0.2` and worker 0 advertises `/tn-worker-0-2017/0.0.2`. Version `0.0.2` removed request and response types that moved to the sync streams. Removing them changes how messages are encoded, so a `0.0.2` node does not negotiate this protocol with a peer still on `0.0.1`; the two cannot misread each other's messages. A failed negotiation is treated as version skew and costs the peer no reputation."
- cite: crates/node-record/src/protocol.rs:20-39, crates/network-libp2p/src/consensus.rs:592-599, crates/network-libp2p/src/consensus.rs:1668-1677 (outbound UnsupportedProtocols not penalized), crates/network-libp2p/src/consensus.rs:1709-1718 (inbound), chain-configs/testnet/genesis.yaml:3 (chainId 2017)
- note: read `req_res_protocol_name` and its doc comment (bump rationale: deleting positional variants shifts BCS discriminants); the April id string does not occur at the tag (v0.8.1 config default was `/telcoin-network/0.0.0`, crates/config/src/network.rs:151 at v0.8.1).

### F2 Request-response RPC
- claim: (only one protocol id is given)
- verdict: missing
- replacement: add after the code block: "The other point-to-point protocols are namespaced the same way, by role, worker index and chain id, and remain at version `0.0.1`: node-record lookup over Kademlia (`/tn-primary-kad-{chain_id}/0.0.1`), bulk sync streams (`/tn-primary-sync-{chain_id}/0.0.1`), the peer-exchange message a node sends before it disconnects (`/tn-primary-peer-exchange-{chain_id}/0.0.1`) and current node-record exchange (`/tn-primary-record-exchange-{chain_id}/0.0.1`). A worker uses the same names with `tn-worker-{worker_id}` in place of `tn-primary`. Gossip negotiates `/tn-meshsub-{chain_id}/1.1.0`, so gossip is chain-scoped as well."
- cite: crates/node-record/src/protocol.rs:41-81, crates/node-record/src/protocol.rs:84-102 (gossip prefix; builder appends /1.1.0 and /1.0.0)
- note: verified each format string; gossip also advertises `/tn-meshsub-{chain_id}/1.0.0` (doc comment lines 91-93); the shorter text names only 1.1.0.

### F3 Request-response RPC
- claim: "This protocol supports direct peer messaging for operations that require targeted delivery rather than broadcast:"
- verdict: confirmed
- replacement: n/a (the list that follows needs F4-F7)
- cite: crates/network-libp2p/src/consensus.rs:595-599 (request_response::Behaviour, ProtocolSupport::Full)
- note: the behaviour is point-to-point; both sides support it fully, so any node may be requester or responder.

### F4 Request-response RPC
- claim: "Epoch record synchronization: nodes request epoch records and certificates from peers during catch-up"
- verdict: stale (partly right)
- replacement: "Epoch records: a node requests an epoch record, together with the epoch certificate that signs it, by epoch number or by digest, or asks for the latest record the peer holds."
- cite: crates/consensus/primary/src/network/message.rs:66-77 (PrimaryRequest::EpochRecord {epoch, hash}), crates/consensus/primary/src/network/message.rs:228-229 (response {record, certificate})
- note: "certificates" was ambiguous; DAG certificates for catch-up (MissingCertificates) no longer travel on request-response — they moved to the primary sync stream (crates/network-libp2p/src/sync/request.rs:46-56).

### F5 Request-response RPC
- claim: "Consensus header retrieval: nodes fetch specific consensus headers by hash reference"
- verdict: stale
- replacement: delete the item from the request-response list; carry the fact in F7's sync-stream sentence ("a single consensus output by its consensus number").
- cite: crates/consensus/primary/src/network/message.rs:49-78 (PrimaryRequest has only Vote, PeerExchange, EpochRecord), crates/network-libp2p/src/sync/request.rs:74-83 (PrimarySyncRequest::ConsensusOutput { number })
- note: v0.8.1 had PrimaryRequest::ConsensusHeader; at the tag it is gone, and the replacement fetch is by chain consensus number, not by hash.

### F6 Request-response RPC
- claim: "Batch downloads: nodes retrieve full worker batches referenced by consensus output"
- verdict: stale
- replacement: delete from the request-response list; carry it in F7 ("worker batches by digest").
- cite: crates/consensus/worker/src/network/message.rs:35-50 (WorkerRequest = ReportBatch, PeerExchange), crates/network-libp2p/src/sync/request.rs:15-28 (WorkerSyncRequest::Batches { batch_digests, epoch })
- note: batch fetch moved from request-response (`RequestBatchesStream`, deleted by the 0.0.2 bump, protocol.rs:24-33) to the worker sync stream.

### F7 Request-response RPC
- claim: (list omits header votes and batch reports, the main request-response traffic, and does not say where bulk transfers went)
- verdict: missing
- replacement: replace the three-item list with:
  "- Header votes: a primary sends its proposed header, with any parent certificates the peer may lack, and receives a vote or a list of the parent certificates the peer still needs.
  - Batch reports: a worker sends a sealed batch to its peers, which accept or reject it.
  - Epoch records: (F4 text).
  Bulk transfers do not use request-response. Missing certificates, epoch consensus data, a single consensus output by its consensus number, and worker batches by digest travel over a separate sync-stream protocol, where one request opens a stream that the responder fills and then closes."
- cite: crates/consensus/primary/src/network/message.rs:51-59 (Vote {header, parents}), :220-227 (Vote / MissingParents responses), crates/consensus/worker/src/network/message.rs:36-40, :66-68 (ReportBatch), crates/network-libp2p/src/sync/request.rs:15-83, docs/src/network/sync-streams.md:1-5
- note: PeerExchange is also a request variant but now only a fallback for the dedicated peer-exchange protocol (consensus.rs:601-610); not worth a partner bullet.

### F8 Request-response RPC
- claim: "Each protocol interaction enforces a maximum message size to bound resource consumption."
- verdict: confirmed (add the number)
- replacement: "Each request and response is limited to a maximum message size, 1 MiB by default, to bound resource consumption."
- cite: crates/config/src/network.rs:259-260, :376 (max_rpc_message_size 1 MiB), crates/network-libp2p/src/consensus.rs:592-593 (codec built with it), crates/network-libp2p/src/codec.rs:134-136 (encode side refuses oversized outbound)
- note: the same cap applies to the peer-exchange protocol (consensus.rs:605); sync streams use per-exchange frame caps instead (docs/src/network/sync-streams.md "Frame encoding").

### F9 Request-response RPC
- claim: "Requests that exceed the configured limit are rejected at the transport layer."
- verdict: stale (imprecise)
- replacement: "A message whose declared length exceeds the limit is rejected from its length prefix, before the node allocates memory for it, and the peer that sent it is penalized."
- cite: crates/network-libp2p/src/codec.rs:46-54 (prefix checked against max_message_size before allocation), crates/network-libp2p/src/codec.rs:104-106 (InvalidData), crates/network-libp2p/src/consensus.rs:1685-1707 (inbound non-transport I/O error → Penalty::Medium), :1641-1660 (outbound)
- note: rejection happens in the codec on the stream read path (application framing), not in the QUIC transport; applies to responses as well as requests.

### F10 Request-response RPC
- claim: (no request timeout stated)
- verdict: missing (optional)
- replacement: "A request that receives no response within 10 seconds fails; a peer that lets an outbound request time out takes a mild penalty, while dropped connections and other network faults carry none."
- cite: crates/network-libp2p/src/consensus.rs:598 (request_response::Config::default()), libp2p-request-response 0.30.0 src/lib.rs:318 (request_timeout 10 s; version from Cargo.lock:5624-5625), crates/network-libp2p/src/consensus.rs:1641-1666
- note: optional; include only if the chapter wants the scoring link stated in this section.

### F11 Peer scoring
- claim: "Nodes maintain a reputation score for each connected peer as a rational number in the range [-100, 100]."
- verdict: stale (minor)
- replacement: "Nodes keep a reputation score for every peer they know, connected or not, as a rational number in the range [-100, 100]. A new peer starts at 0."
- cite: crates/network-libp2p/src/peers/score.rs:1-4, :84-87 (clamp to [min,max]), crates/config/src/network.rs:640-645 (default 0, max 100, min -100)
- note: range confirmed; "connected" is wrong because banned and disconnected peers keep their score (that is how the ban lockout works, score.rs:120-131).

### F12 Peer scoring
- claim: "Reflecting the diminished relevance of older behavior, scores are designed to naturally decay toward zero over time using a configurable half-life."
- verdict: confirmed
- replacement: optional, add the value: "... using a configurable half-life, five minutes by default."
- cite: crates/network-libp2p/src/peers/score.rs:97-114 (e^(-ln2/HL·t), applies to positive and negative scores), crates/config/src/network.rs:645-648 (score_halflife 300 s), :666-670
- note: decay is applied on the peer-manager heartbeat (30 s, crates/config/src/network.rs:557).

### F13 Peer scoring
- claim: "Penalties reduce a peer's score for specific infractions:"
- verdict: confirmed
- replacement: n/a
- cite: crates/network-libp2p/src/peers/score.rs:68-81
- note: penalties are reported by the application and network layers; the heartbeat never penalizes.

### F14 Peer scoring
- claim: "Propagating invalid or malformed messages"
- verdict: confirmed
- replacement: n/a
- cite: crates/consensus/primary/src/error/network.rs:156-195 (invalid certificate signature Fatal, decode Fatal, I/O Medium), crates/network-libp2p/src/consensus.rs:1688-1707 (codec violation Medium)
- note: worker batch validation failures map to Mild..Fatal (crates/network-libp2p/src/peers/penalty.md:113-139, secondary).

### F15 Peer scoring
- claim: "Failing message validation on gossipsub topics"
- verdict: confirmed
- replacement: n/a
- cite: crates/network-libp2p/src/consensus.rs:1473-1496 (oversized payload from a resolved relayer, or unauthorized author: Fatal), :2818-2820
- note: an unattributable reject (identity not yet resolved) carries no penalty (consensus.rs:2818-2822 RejectPenalty::Skip).

### F16 Peer scoring
- claim: "Violating protocol expectations"
- verdict: confirmed
- replacement: n/a
- cite: crates/network-libp2p/src/consensus.rs:1518-1520 (peer without gossipsub: Fatal), :1662-1666 (outbound request timeout: Mild), :2510, :2531 (DHT record faults, Fatal/Severe)
- note: generic wording holds.

### F17 Peer scoring
- claim: (penalty sizes and the no-penalty cases are absent)
- verdict: missing
- replacement: "Penalties come in four sizes: mild (−1), medium (−5), severe (−10) and fatal, which sets the score straight to −100. Faults that are not the peer's doing, such as dropped connections, network resets and a protocol-version mismatch during an upgrade, carry no penalty."
- cite: crates/network-libp2p/src/peers/score.rs:72-77, crates/network-libp2p/src/consensus.rs:1641-1649, :1668-1677, :1709-1721
- note: magnitudes read from apply_penalty; no-penalty arms read in the req-res failure handlers.

### F18 Peer scoring
- claim: "Four reputation levels derive from the current score:" (and the table that follows)
- verdict: stale
- replacement: "Three reputation levels derive from the current score:

  | Level | Score | Behavior |
  | --- | --- | --- |
  | Trusted | above −20 | Full participation. When a node holds more peers than its target, it drops the lowest-scoring peers first |
  | Disconnected | −20 or below | Connection closed; reconnection refused for ten minutes |
  | Banned | −50 or below | Disconnected, blocked from gossip, removed from the discovery routing table, and refused new connections until the score recovers |"
- cite: crates/network-libp2p/src/peers/score.rs:151-157 (reputation_for), :189-201 (enum Reputation: Trusted, Disconnected, Banned), crates/config/src/network.rs:654-655 (−20, −50), crates/network-libp2p/src/peers/manager.rs:529-538 (ban and disconnect both apply a temporary ban), crates/config/src/network.rs:564 (600 s), crates/network-libp2p/src/consensus.rs:2214-2219 (gossip blacklist, Kademlia removal), crates/network-libp2p/src/peers/all_peers.rs:973-990 (pruning order: lowest score, then non-routable)
- note: thresholds are inclusive (`<=`). Gossipsub's own peer scoring is not enabled (no `with_peer_score` in crates/network-libp2p/src/*.rs).

### F19 Peer scoring
- claim: "| Good | Full participation in all protocols |"
- verdict: stale
- replacement: replaced by the "Trusted" row in F18.
- cite: crates/network-libp2p/src/peers/score.rs:189-194
- note: no "Good" level exists.

### F20 Peer scoring
- claim: "| Average | Normal operation with no restrictions |"
- verdict: stale
- replacement: delete the row (merged into "Trusted", F18).
- cite: crates/network-libp2p/src/peers/score.rs:151-157
- note: there is no level between Trusted and Disconnected.

### F21 Peer scoring
- claim: "| Bad | Deprioritized for routing and gossip forwarding |"
- verdict: stale
- replacement: replaced by the "Disconnected" row in F18.
- cite: crates/network-libp2p/src/peers/score.rs:195-197, crates/network-libp2p/src/peers/manager.rs:534-538
- note: there is no deprioritized-but-connected level. A score of −20 or below disconnects the peer; low scores otherwise matter only for which peers are pruned first when over target.

### F22 Peer scoring
- claim: "| Banned | Disconnected and blocked from reconnection |"
- verdict: confirmed
- replacement: n/a (the F18 row adds gossip blacklisting and routing-table removal)
- cite: crates/network-libp2p/src/peers/score.rs:198-201, crates/network-libp2p/src/peers/behavior.rs:121-139 (banned peers refused at the established inbound check), crates/network-libp2p/src/consensus.rs:2214-2219
- note: a ban lasts until decay lifts the score above −50, not a fixed term.

### F23 Peer scoring
- claim: "A peer reaching the minimum score of -100 is banned."
- verdict: stale
- replacement: "A peer whose score falls to −50 or below is banned. From a fresh score that takes 50 mild, 10 medium or 5 severe penalties, ignoring decay, or a single fatal one."
- cite: crates/config/src/network.rs:655 (min_score_before_ban −50), crates/network-libp2p/src/peers/score.rs:133-136 (is_banned: aggregate ≤ min_score_before_ban), :72-77
- note: −100 is the floor (min_score), reached only by a fatal penalty; it is not the ban threshold.

### F24 Peer scoring
- claim: "Banned peers must wait a minimum ban duration before score decay begins to restore their standing, preventing peers from evading penalties through rapid reconnection."
- verdict: stale (minor: mechanism right, number missing, rationale off)
- replacement: "A banned peer's score is frozen for 30 minutes before decay begins, so a ban always lasts at least that long. The peer is refused new connections throughout and is unbanned once decay lifts its score above −50."
- cite: crates/network-libp2p/src/peers/score.rs:116-131 (last_updated pushed forward by banned_before_decay on the transition to banned), :101-104, crates/config/src/network.rs:649-653 (30 minutes; the comment says protection comes from the threshold, not the lockout), crates/network-libp2p/src/peers/peer.rs:483-511 (unban on heartbeat)
- note: after a fatal penalty (−100) the peer needs one more half-life past the lockout, so it stays banned for about 35 minutes. Reconnection evasion is prevented by the established-connection ban check (F22), not by the lockout length.

### F25 Peer scoring
- claim: (the section does not say which peers are exempt from scoring)
- verdict: missing
- replacement: "Members of the previous, current and next committees, and peers the node operator has configured as trusted or bootstrap peers, are exempt from scoring: penalties and bans do not apply to them, and they may connect beyond the normal peer limits. When a validator joins a tracked committee, any ban on it is lifted and its score is reset to the maximum."
- cite: crates/network-libp2p/src/peers/peer.rs:311-338 (exempt peers bypass the score model), crates/network-libp2p/src/peers/all_peers.rs:859-885 (exemption from the three committee slots or the operator allowlist), crates/network-libp2p/src/peers/all_peers.rs:1229-1246 (committee entry: unban, reset_score_to_max, clear validator IPs), docs/src/network/peers.md:69 (connection-ceiling bypass)
- note: partner-relevant because it explains why validators cannot be partitioned from each other by scoring.

### F26 Peer scoring (early identity refusal, #1450)
- claim: (connection refusal is not described)
- verdict: missing
- replacement: "Refusal is layered. A pending inbound connection is refused if its source address is banned; an address is banned once more than one banned peer has connected from it. After the handshake proves the peer's identity, the node refuses a banned peer or its own identity before gossip, request-response or discovery keep any state for it. Refusing identities earlier, inside the handshake, was evaluated and not adopted: an identity is unproven until the handshake completes, and an earlier check would only save work for identities the node already refuses."
- cite: crates/network-libp2p/src/peers/behavior.rs:112-139 (pending inbound IP check, established inbound self and banned checks), crates/network-libp2p/src/peers/behavior.rs:269-276, crates/network-libp2p/src/peers/banned.rs:20, :126 (IP banned when count > 1), crates/network-libp2p/src/consensus.rs:280-296 (peer_manager is the first behaviour, connection_limits second), docs/src/network/early-identity-refusal.md:3-23 (decision: keep refusal at the established checks), :102-104
- note: #1450 is a no-change decision record, not a new mechanism. Do not describe an in-handshake identity check. The admission policy does not require committee membership (early-identity-refusal.md:12-17), so do not claim that only validators may connect.

### F27 Peer scoring (validated handshake-start accounting, #1447)
- claim: (handshake admission is not described)
- verdict: missing
- replacement: "Before an inbound handshake can take one of a bounded number of pending slots (1024 per network), the node checks that the source address is reachable using QUIC Retry. Each peer may hold at most eight established connections."
  Optional second sentence, only if the chapter wants to show forward work: "A per-source budget on validated handshake starts, which groups IPv4 sources by /24 and IPv6 sources by /64, is defined in the client but not enabled at v0.16.0-adiri; its rates await measurement."
- cite: crates/config/src/network/quic.rs:34, :49 (retry_unvalidated_incoming default true), crates/network-libp2p/src/consensus.rs:176-194 (MAX_PENDING_INCOMING_CONNECTIONS 1024, Retry rationale), :174 (8 per peer), :257-260, crates/network-libp2p/src/admission/mod.rs:1-9 (module "does not enable a transport policy or choose production limits"), docs/src/network/handshake-starts.md:3-8, :29-33, :82
- note: `git grep HandshakeStartBudget` finds no caller outside crates/network-libp2p/src/admission/, so #1447 adds an accounting contract with no live budget. Do not present it as active rate limiting.

### F28 Peer scoring (optional)
- claim: (scoring of bulk sync streams is not described)
- verdict: missing (optional)
- replacement: "Failures on the bulk sync streams are classified with the same penalty sizes but are only logged for now; they do not yet change a peer's score."
- cite: crates/network-libp2p/src/consensus.rs:2280-2300 (process_stream_event: "metrics-only, not enforced"), docs/src/network/sync-streams.md:159-162
- note: include only if F7's sync-stream sentence lands, so a reader does not assume stream abuse is scored.

### Consolidated replacement for "Peer scoring" (for the editor; assembles F11, F12, F17, F18, F23, F24, F25)
"Nodes keep a reputation score for every peer they know, as a rational number in the range [-100, 100]; a new peer starts at 0. Scores decay toward zero with a configurable half-life, five minutes by default, so older behaviour counts for less.
Penalties reduce a peer's score for specific infractions: propagating invalid or malformed messages, failing message validation on gossipsub topics, and violating protocol expectations. They come in four sizes: mild (−1), medium (−5), severe (−10) and fatal, which sets the score to −100. Faults that are not the peer's doing, such as dropped connections or a protocol-version mismatch during an upgrade, carry no penalty.
Three reputation levels derive from the score: (F18 table).
A banned peer's score is frozen for 30 minutes before decay begins; it is refused new connections throughout and is unbanned once its score rises above −50.
Members of the previous, current and next committees, and peers the operator has configured as trusted or bootstrap peers, are exempt from scoring and may connect beyond the normal peer limits."
Then F26 and F27 as a short closing paragraph.

## Summary

- confirmed: 8 (F3, F8, F12, F13, F14, F15, F16, F22)
- stale: 12 (F1, F4, F5, F6, F9, F11, F18, F19, F20, F21, F23, F24)
- missing: 8 (F2, F7, F10 optional, F17, F25, F26, F27, F28 optional)
- unverifiable: 0
