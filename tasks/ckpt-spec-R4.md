status: done (all sections reviewed; findings complete)

# Checkpoint R4

Scope: transcription.md lines 288-326 (Node modes) and 448-493 (Trustless synchronization).
WT = tn-v0.16.0-adiri worktree (facts file). All cites are WT-relative at tag v0.16.0-adiri.

Completed sections:
- Node modes: intro, CvvActive, CvvInactive, Observer, Mode detection, Capabilities
- Trustless synchronization: intro, Step 1, Step 2 (+ sources table), Step 3, Security properties, Recovery after restart

Pending sections: none

# Findings

## Node modes

### F1 Node modes (intro)
- claim: "Every node in the Telcoin Network operates in exactly one of three modes at any given time. The mode determines which protocol responsibilities the node performs and how it receives consensus output."
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/primary/node_mode.rs:13-24, crates/consensus/executor/src/subscriber.rs:76-133
- note: one enum with three variants; the subscriber starts a different task per mode (direct sequence, catch-up-and-rejoin, follow).

### F2 CvvActive
- claim: "A node operates in CvvActive (Committee-Voting Validator, Active) mode when it holds a staked authority identity that is a member of the current committee and is fully synchronized with the current consensus round."
- verdict: confirmed
- replacement: n/a
- cite: crates/consensus/primary/src/consensus_bus.rs:252-258, crates/consensus/worker/src/worker.rs:145 ("committee voting validator"), crates/node/src/manager/node/start_epoch.rs:1041-1049
- note: "fully synchronized" is assumed, not tested on entry: the code enters CvvActive optimistically and demotes the node if it later finds itself behind (start_epoch.rs:1047-1048, 1078-1081).

### F3 CvvActive
- claim: "This is the default mode for all committee members at the start of an epoch."
- verdict: stale
- replacement: "A committee member enters this mode at the start of each epoch, unless it is still catching up from the previous epoch, in which case it stays CvvInactive, or the newest epoch record it holds already leaves its key out of the committee, in which case it runs as an observer."
- cite: crates/node/src/manager/node/start_epoch.rs:1050-1097, crates/node/src/manager/node.rs:1815-1840
- note: identify_node_mode returns CvvInactive first if already set (sticky), then applies the epoch-record veto (node_mode_from_epoch_record) to a would-be CvvActive.

### F4 CvvActive
- claim: "A CvvActive node participates directly in consensus by producing batches, voting on proposals, generating certificates, and advancing consensus rounds. It executes each block as the consensus protocol commits it."
- verdict: confirmed
- replacement: n/a
- cite: crates/node/src/manager/node/run_epoch.rs:368-381, crates/node/src/manager/node/run_epoch.rs:980-1000, crates/consensus/executor/src/subscriber.rs:91-104
- note: the primary (proposer, certifier, consensus) starts only when starts_proposer(mode) is true, i.e. CvvActive; batch builders for committee workers follow the same gate; the CvvActive subscriber executes the locally committed sequence.

### F5 CvvActive
- claim: "Because it is a direct participant in consensus, it does not consume consensus output streams from peers."
- verdict: confirmed
- replacement: n/a
- cite: crates/state-sync/src/lib.rs:97-109
- note: spawn_state_sync does nothing for CvvActive. It still reads the committee's consensus-result gossip, but only to detect that it has fallen behind (crates/consensus/primary/src/network/handler.rs:162-171, 480-485).

### F6 CvvInactive
- claim: "A node operates in CvvInactive (Committee-Voting Validator, Inactive) mode when it holds a staked committee identity but has fallen behind the current consensus state. This occurs when a committee member restarts after a failure mid-epoch or when a running node falls too far behind to continue voting."
- verdict: stale
- replacement: "A node operates in CvvInactive (Committee-Voting Validator, Inactive) mode when it holds a staked committee identity but has fallen behind the current consensus state: more rounds behind than the consensus garbage-collection window allows, or an epoch behind. This most often follows a restart mid-epoch."
- cite: crates/consensus/primary/src/network/handler.rs:162-252, crates/node/src/manager/node.rs:969-972, crates/consensus/primary/src/consensus/state.rs:584-596
- note: a restarted member starts as CvvActive and is demoted only when behind_consensus finds it outside the GC window or an epoch behind; a restart alone does not set CvvInactive. (Two internal consistency failures also demote it, state.rs:584-596 and 641-655.)

### F7 CvvInactive
- claim: "A CvvInactive node cannot produce certificates, propose batches, or vote in consensus rounds."
- verdict: confirmed
- replacement: n/a
- cite: crates/node/src/manager/node/run_epoch.rs:368-381, crates/node/src/manager/node/run_epoch.rs:980-1000, crates/node/src/manager/node/run_epoch.rs:2266-2273
- note: no primary and no batch builder for a non-active member; its accepted transactions stay pooled (run_epoch.rs:415-428). The vote request handler has no explicit mode check, but it rejects headers more than the GC window ahead of the node's committed round (handler.rs:848-859), so a node behind cannot vote.

### F8 CvvInactive
- claim: "It follows consensus output by streaming ConsensusHeaders from peers, executes committed blocks as they arrive, and synchronizes its state forward."
- verdict: confirmed
- replacement: n/a
- cite: crates/consensus/executor/src/subscriber.rs:105-118, crates/consensus/executor/src/subscriber.rs:211-245, crates/state-sync/src/lib.rs:97-140
- note: it fetches whole consensus outputs (header plus batches) or epoch packs over the sync-stream protocol, then executes them forward.

### F9 CvvInactive
- claim: "Once it has caught up with the current round, it transitions to CvvActive and resumes full consensus participation."
- verdict: confirmed
- replacement: n/a
- cite: crates/consensus/executor/src/subscriber.rs:221-243, crates/types/src/primary/node_mode.rs:17-21, docs/src/rpc-methods/tn/tn_nodemode.md:14
- note: switches when the output just executed is the newest known one and its commit is under 5 s old, then restarts the epoch tasks; see F16 for what happens if the node has left the committee by then.

### F10 Observer
- claim: "A node operates in Observer mode when it is not a member of the current committee. An observer is characterized by not being a committee member for the current epoch, regardless of whether they hold a stake."
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/primary/node_mode.rs:22-24, crates/consensus/primary/src/consensus_bus.rs:263-265
- note: wording matches the enum docs ("may or may not be staked").

### F11 Observer
- claim: "This includes nodes explicitly configured as observers and staked validators not selected for the committee in the current epoch."
- verdict: stale
- replacement: "This includes staked validators not selected for the committee in the current epoch and any node whose key is not in it. No node is configured into this mode: each node derives its role from committee membership every epoch."
- cite: crates/node/src/manager/node.rs:969-972, crates/node/src/manager/node/start_epoch.rs:1060-1081, SYNC.md:180-182
- note: #1385 (2a2891dbf) derives the role from membership; #1417 (9c3fcbc10) removed the CLI role flag.

### F12 Observer
- claim: "An observer follows consensus output by streaming ConsensusHeaders from peers and executes committed blocks as they arrive. It synchronizes the epoch chain but does not participate in consensus rounds, certificate production, or batch proposal."
- verdict: confirmed
- replacement: n/a
- cite: crates/consensus/executor/src/subscriber.rs:119-131, crates/state-sync/src/lib.rs:97-140, crates/node/src/manager/node.rs:1157-1182, crates/node/src/manager/node/run_epoch.rs:368-381
- note: follow_consensus path; epoch-record sync and the background record collector run app-wide for every mode.

### F13 Observer
- claim: (none; fact absent)
- verdict: missing
- replacement: "An observer does not put transactions into batches. Its workers forward the transactions they accept to committee validators over RPC, and it does not subscribe to the committee's batch gossip, because it receives batch contents inside the consensus output it downloads."
- cite: crates/node/src/manager/node/start_epoch.rs:722-735, crates/node/src/manager/node/start_epoch.rs:942-951, crates/node/src/manager/node/start_epoch.rs:1197-1213, crates/node/src/manager/node/run_epoch.rs:988-1000
- note: one sentence here is enough; the forwarding mechanism itself belongs under Networking (#804/#820), per the facts file.

### F14 Mode detection
- claim: "At each epoch boundary, a node determines its mode for the new epoch by reading the current committee from the execution state."
- verdict: confirmed
- replacement: n/a
- cite: crates/node/src/manager/node/start_epoch.rs:1050-1081, crates/node/src/manager/node/start_epoch.rs:176-200
- note: the committee comes from on-chain state pinned to the previous epoch's closing block; at process start the same check runs in node.rs:969-981.

### F15 Mode detection
- claim: "If the node holds an authority identity present in the new committee, it enters CvvActive. If the node is not in the committee or is configured as an observer, it enters Observer mode."
- verdict: stale
- replacement: "If the node's key is in the new committee, it enters CvvActive, unless the newest epoch record it holds names a next committee without that key, in which case it runs as an observer. If the key is not in the committee, the node enters Observer mode."
- cite: crates/node/src/manager/node/start_epoch.rs:1076-1093, crates/node/src/manager/node.rs:1815-1840
- note: no configured observer exists (F11); the record veto keeps stale local execution state from restoring a validator that has rotated out; records never promote an observer.

### F16 Mode detection
- claim: "A node that was CvvInactive at the epoch boundary remains CvvInactive until it completes synchronization as long as it remains in the active voting committee of validators for that epoch."
- verdict: stale
- replacement: "A node that is CvvInactive at the epoch boundary stays CvvInactive until it has caught up. It then checks the committee again: it becomes CvvActive if its key is in the current committee and an observer if not."
- cite: crates/node/src/manager/node/start_epoch.rs:1043-1058, crates/consensus/executor/src/subscriber.rs:236-240, crates/node/src/manager/node/run_epoch.rs:994-997
- note: CvvInactive is sticky regardless of membership ("a non-member whose CvvInactive carried over"); membership is re-read only at the re-entry after catch-up.

### F17 Mode detection
- claim: "All non-voting nodes enter observer mode for epochs in which they are not part of the epoch's committee."
- verdict: confirmed
- replacement: n/a
- cite: crates/node/src/manager/node/start_epoch.rs:1076-1078
- note: the one exception is the CvvInactive carry-over in F16, which ends at catch-up.

### F18 Mode detection
- claim: "Mode transitions may also occur within an epoch. A CvvActive node that falls behind transitions to CvvInactive. A CvvInactive node that finishes catching up transitions to CvvActive."
- verdict: confirmed
- replacement: n/a
- cite: crates/consensus/primary/src/network/handler.rs:216-252, crates/consensus/executor/src/subscriber.rs:236-240
- note: each switch notifies the epoch shutdown so the epoch's tasks restart in the new mode.

### F19 Mode detection
- claim: (none; fact absent)
- verdict: missing
- replacement: "A node reports its current mode through the tn_nodeMode RPC method, which reads it when the request arrives, so a caller can see the transient CvvInactive mode while a validator catches up. While CvvInactive, the node also reports itself as syncing to eth_syncing."
- cite: crates/execution/tn-rpc/src/rpc_ext.rs:135-140, crates/execution/tn-rpc/src/rpc_ext.rs:490-491, docs/src/rpc-methods/tn/tn_nodemode.md:3-15, crates/node/src/manager/node/start_epoch.rs:1181-1195
- note: tn_info is static and does not carry the mode (docs/src/rpc-methods/tn/tn_info.md:3); eth_syncing behaviour from #1231/#1232 (1e4fc55f8).

### F20 Capabilities (row: Consensus voting)
- claim: "Consensus voting | Yes | No | No"
- verdict: confirmed
- replacement: n/a
- cite: crates/node/src/manager/node/run_epoch.rs:368-381, crates/consensus/primary/src/network/handler.rs:848-859
- note: see F7 for why a CvvInactive member cannot vote although the vote handler is not mode-gated.

### F21 Capabilities (row: Certificate production)
- claim: "Certificate production | Yes | No | No"
- verdict: confirmed
- replacement: n/a
- cite: crates/node/src/manager/node/run_epoch.rs:368-381
- note: certificates come from the primary, started only for CvvActive.

### F22 Capabilities (row: Batch production)
- claim: "Batch production | Yes | No | No"
- verdict: confirmed
- replacement: n/a
- cite: crates/node/src/manager/node/run_epoch.rs:980-1000, crates/node/src/manager/node/run_epoch.rs:2266-2283
- note: an observer's worker runs a builder only to forward transactions to the committee (no quorum seal); a CvvInactive member runs none.

### F23 Capabilities (row: Block execution)
- claim: "Block execution | Yes | Yes | Yes"
- verdict: confirmed
- replacement: n/a
- cite: crates/consensus/executor/src/subscriber.rs:203, crates/consensus/executor/src/subscriber.rs:348, crates/consensus/executor/src/subscriber.rs:705
- note: all three subscriber paths send consensus output to the execution engine.

### F24 Capabilities (row: Consensus output streaming)
- claim: "Consensus output streaming | No (direct participant) | Yes | Yes"
- verdict: confirmed
- replacement: n/a
- cite: crates/state-sync/src/lib.rs:97-140
- note: state-sync streaming tasks start only for CvvInactive and Observer.

### F25 Capabilities (row: Epoch chain sync)
- claim: "Epoch chain sync | Yes | Yes | Yes"
- verdict: confirmed
- replacement: n/a
- cite: crates/node/src/manager/node.rs:1157-1182
- note: sync_epoch_records_to_tip and spawn_epoch_record_collector run at process level, independent of mode.

### F26 Capabilities (rows absent)
- claim: (none; rows absent)
- verdict: missing
- replacement: candidate rows, pick any: "Transaction intake | Seals into batches | Holds in its pool until active | Forwards to committee validators"; "Epoch record signing | Yes, for an epoch whose committee included it, in every mode"; "Reported as syncing (eth_syncing) | No | Yes | No".
- cite: crates/node/src/manager/node/run_epoch.rs:415-428, crates/node/src/manager/node/run_epoch.rs:988-1000, crates/node/src/manager/epoch_votes.rs:446-480, crates/node/src/manager/node/start_epoch.rs:1181-1195
- note: epoch-record votes are gated on membership in that record's committee, deliberately not on current mode (an observer that rotated out still signs the epoch it served in).

## Trustless synchronization

### F27 Trustless synchronization (intro)
- claim: "A node must verify the entire chain history independently, without relying on any peer, whether it is joining the network initially or rejoining after a period of downtime."
- verdict: confirmed
- replacement: n/a
- cite: SYNC.md:3, SYNC.md:27-36, crates/storage/src/epoch_records.rs:1218-1236
- note: every downloaded record is validated against locally trusted state only, never against the record's own committee (epoch_records.rs:278-281). See F29 for the snapshot alternative.

### F28 Trustless synchronization (intro)
- claim: "The well-known genesis block is the sole trust anchor for syncing historic data. From this starting point, any node derives and verifies every subsequent committee, every consensus decision, and every state transition."
- verdict: confirmed
- replacement: n/a
- cite: crates/storage/src/epoch_records.rs:1225-1227, crates/node/src/manager/node.rs:1143-1154, SYNC.md:3
- note: concretely the anchor is the genesis committee (epoch 0 record validated against get_committee_keys(0) with a default parent digest).

### F29 Trustless synchronization (intro)
- claim: (none; fact absent)
- verdict: missing
- replacement: "A node may instead start from an exported state snapshot of a recent epoch. The snapshot does not widen the trust anchor: the node re-verifies the snapshot's chain of certified epoch records from the genesis committee, checks the epoch's consensus pack against the certified final_consensus, and accepts the execution state only if its recomputed state root matches the block that the certified final_state names. It then syncs forward from that epoch, and holds no historical state below the snapshot block."
- cite: SYNC.md:77-97, SYNC.md:159-168, SYNC.md:190-193, crates/telcoin-network-cli/src/db.rs:1033-1043
- note: describe the mechanism only; leave the export/import commands and flags out of the partner text.

### F30 Trustless synchronization (intro)
- claim: "Synchronization proceeds in three steps."
- verdict: confirmed
- replacement: n/a
- cite: SYNC.md:67-75, crates/node/src/manager/node.rs:1157-1182, crates/node/src/manager/node.rs:1265-1298
- note: records, then consensus (packs and outputs), then forward execution; at the tag steps 2 and 3 interleave per epoch.

### F31 Step 1: Sync the epoch chain
- claim: "The node downloads epoch records sequentially starting from epoch 0."
- verdict: confirmed
- replacement: n/a
- cite: crates/state-sync/src/epoch.rs:133-178, crates/state-sync/src/epoch.rs:41-49
- note: one record and its certificate per request, in epoch order; startup collection is capped at 30 s, then a background collector continues (node.rs:1175-1182).

### F32 Step 1: Sync the epoch chain
- claim: "For each record, it verifies three properties:"
- verdict: stale
- replacement: "For each record, it verifies four properties:" with a new first item: "Position: the record is for the epoch that was requested, so a peer cannot answer one slot with a self-consistent record for another"
- cite: crates/storage/src/epoch_records.rs:345-362, crates/storage/src/epoch_records.rs:1205-1217
- note: validate_record_against_anchor checks epoch_matches, parents_match, committee_valid, cert_valid.

### F33 Step 1: Sync the epoch chain (item 1)
- claim: "Chain integrity: the record's `parent_hash` matches the previous record's cryptographic digest"
- verdict: confirmed
- replacement: n/a
- cite: crates/storage/src/epoch_records.rs:356, crates/storage/src/epoch_records.rs:1225-1231
- note: epoch 0 chains from the default (zero) digest.

### F34 Step 1: Sync the epoch chain (item 2)
- claim: "Committee continuity: the record's `committee` matches the previous record's `next_committee`"
- verdict: stale
- replacement: "Committee continuity: the record's `committee` equals the previous record's `next_committee`, or, when governance ejected a validator during the epoch, is a subset of it that keeps at least four members and at least two-thirds of the promised committee"
- cite: crates/types/src/primary/epoch.rs:113-165, crates/storage/src/epoch_records.rs:316-327
- note: #922 (123addfa7); a committee can never grow mid-epoch and duplicate keys are rejected.

### F35 Step 1: Sync the epoch chain (item 3)
- claim: "Authenticity: the record's certificate contains a valid super-quorum BLS aggregate signature from the expected committee"
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/primary/epoch.rs:59-111
- note: verify_with_cert checks the certificate names this record's digest and carries an aggregate signature from at least floor(2n/3)+1 members of the record's own committee, which item 2 ties to the expected committee.

### F36 Step 1: Sync the epoch chain
- claim: "The epoch 0 record is verified against the genesis committee. Each subsequent epoch's expected committee is learned from the previous record's `next_committee` field."
- verdict: confirmed
- replacement: n/a
- cite: crates/storage/src/epoch_records.rs:1225-1231
- note: anchor is get_committee_keys(0) for epoch 0, else record_by_epoch(epoch - 1).next_committee.

### F37 Step 1: Sync the epoch chain
- claim: "After processing all available records, the node has committee membership for every epoch and two checkpoint hashes per epoch: `final_consensus` (the last verified consensus header digest) and `final_state` (the corresponding execution state)."
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/primary/epoch.rs:22-39, SYNC.md:36-37
- note: each checkpoint is a number-and-hash pair: final_consensus is the epoch's last ConsensusHeader, final_state its last execution block; the current epoch's committee comes from the latest record's next_committee.

### F38 Step 1: Sync the epoch chain
- claim: (none; fact absent)
- verdict: missing
- replacement: "The newest record is certified only after the following epoch has begun: its outgoing committee signs it then, and the network does not wait for the certificate before it starts the new epoch. A syncing node accepts a record only with its certificate, so the newest checkpoint becomes available once that certificate has been gathered."
- cite: SYNC.md:18-25, crates/state-sync/src/epoch.rs:146-165, crates/node/src/manager/node/run_epoch.rs:1003-1013
- note: #1196 (2ea18beca): a running node opens the next epoch from its own deterministic record without a certificate; the sync path still requires one (request_epoch_cert, then validate_downloaded_record).

### F39 Step 1: Sync the epoch chain
- claim: "Because the network produces one epoch record approximately once per eight hours, this step completes quickly even after years of operation."
- verdict: stale
- replacement: "Because the network produces one epoch record per epoch, and an epoch lasts several hours (six on the current test network; the length is a consensus-registry parameter), this step completes quickly even after years of operation."
- cite: chain-configs/testnet/genesis.yaml:103, crates/telcoin-network-cli/src/genesis/mod.rs:90-94, crates/tn-reth/src/system_calls.rs:256-257
- note: testnet genesis stores epochDuration 0x5460 = 21,600 s; 8 h is only the CLI default for new genesis files; governance can change it, so the live value is not settled by code (check epochDuration via tn_getCurrentEpochInfo on adiri). docs/src/getting-started/hardware-requirements.md:319 also says 6-hour epochs.

### F40 Step 2: Sync consensus headers
- claim: "Using the verified checkpoint hashes from epoch records as trust anchors, the node retrieves consensus headers backwards."
- verdict: stale
- replacement: "For each completed epoch, the node downloads that epoch's consensus pack, its consensus headers together with their batches, from a peer. It checks each header's parent link forward from the previous record's `final_consensus` and keeps the pack only if its last header matches the epoch record's `final_consensus`. For the epoch in progress, it walks backwards from the latest verified hash, and when it is more than a few outputs behind it first downloads a verified prefix of that epoch's pack."
- cite: crates/state-sync/src/consensus.rs:286-300, crates/state-sync/src/consensus.rs:473-478, crates/storage/src/consensus.rs:668-728, crates/storage/src/consensus_pack.rs:3236-3240, crates/state-sync/src/consensus.rs:27, crates/state-sync/src/consensus.rs:347-360
- note: packs move over the primary sync-stream protocol (EpochPack / EpochPackPartial requests, docs/src/network/sync-streams.md:80-88); PARTIAL_PACK_CATCHUP_THRESHOLD = 5.

### F41 Step 2: Sync consensus headers
- claim: "Syncing nodes request the header for a verified hash, confirm the header's digest matches, then request the header's parent via `parent_hash`. This process repeats until all consensus headers are downloaded."
- verdict: confirmed
- replacement: n/a
- cite: crates/state-sync/src/consensus.rs:215-289, crates/consensus/primary/src/network/mod.rs:597-611
- note: true for the in-progress epoch (F40); each request returns the whole output and its header digest is checked before any batch is read; a peer serving a wrong hash is penalized.

### F42 Step 2: Sync consensus headers
- claim: "Each header's certificate is verified against the known committee for the header's epoch."
- verdict: stale
- replacement: "A header is trusted because its digest chains to a certified epoch record or to a committee-attested consensus hash. The node also checks that every certificate author in the header belongs to that epoch's committee."
- cite: crates/storage/src/consensus_pack.rs:3165-3166, crates/storage/src/consensus_pack.rs:3416-3430, crates/storage/src/consensus.rs:713-728
- note: no certificate signature check exists on the sync decode or import path (grep verify_cert / verify_secure in crates/storage, crates/state-sync: none); authentication is the hash chain.

### F43 Step 2: Sync consensus headers
- claim: "This step may proceed in parallel with epoch record sync for epochs that were already verified."
- verdict: confirmed
- replacement: n/a
- cite: crates/state-sync/src/consensus.rs:286-300, crates/node/src/manager/node.rs:1265-1298
- note: pack requests are queued per verified record and served by three fetch workers while record collection continues.

### F44 Step 2: Sync consensus headers
- claim: "Verified hashes that seed the backward walk come from three sources, in order of availability:"
- verdict: stale
- replacement: "Verified hashes that seed the download come from two sources, in order of availability:"
- cite: crates/consensus/primary/src/network/handler.rs:497, crates/state-sync/src/epoch.rs:155, crates/state-sync/src/epoch.rs:252
- note: these are the only callers of publish_consensus_num_hash_if_newer, the watch that drives fetching (consensus.rs:448-470). See F47.

### F45 Step 2 sources table (row 1)
- claim: "Epoch records (`final_consensus`) | After epoch record sync | One historical checkpoint per epoch"
- verdict: confirmed
- replacement: n/a
- cite: crates/state-sync/src/epoch.rs:146-160, crates/state-sync/src/epoch.rs:244-257
- note: the highest record's final_consensus is published once per collection pass.

### F46 Step 2 sources table (row 2)
- claim: "Live committee gossip | Once current committee is known | Latest consensus hash in real time"
- verdict: missing
- replacement: Notes cell: "Latest consensus hash in real time, accepted once one-third plus one of the committee have each signed the same result"
- cite: crates/consensus/primary/src/network/handler.rs:373-415, crates/consensus/primary/src/network/handler.rs:480-497, crates/node/src/manager/node/start_epoch.rs:752-758
- note: the row itself is correct; the threshold (n/3 + 1, at least one honest signer) is the missing fact. Each ConsensusResult signature is checked individually; publishers are limited to the previous, current and next committees (#912).

### F47 Step 2 sources table (row 3)
- claim: "Execution blocks (`parent_beacon_block_root`) | After execution sync | Each block stores the producing ConsensusHeader digest"
- verdict: stale
- replacement: drop the row and add after the table: "Each execution block also records, in `parent_beacon_block_root`, the digest of the consensus header that produced it. A restarted node uses it to find where execution stopped, and it exposes a fork, but it does not seed downloads."
- cite: crates/consensus/primary/src/consensus_bus.rs:967-997, crates/node/src/manager/node.rs:1669-1698, SYNC.md:57
- note: the stored digest is real; it is read only on restart (last_executed_consensus_block, try_restore_state), never published as a fetch target.

### F48 Step 3: Re-execute batches
- claim: "Once consensus headers span a contiguous range, the node orders them forward."
- verdict: confirmed
- replacement: n/a
- cite: crates/state-sync/src/lib.rs:421-445, crates/state-sync/src/lib.rs:518-533
- note: the forward drain re-derives each digest from the previous one and stops on a mismatch.

### F49 Step 3: Re-execute batches
- claim: "The protocol extracts the batches from each header's committed sub-DAG and executes one EVM block per batch in sequence."
- verdict: confirmed
- replacement: n/a
- cite: crates/engine/src/payload_builder.rs:19-24, crates/engine/src/payload_builder.rs:50, crates/engine/src/payload_builder.rs:98
- note: see F50 for the empty-output case.

### F50 Step 3: Re-execute batches
- claim: (none; fact absent)
- verdict: missing
- replacement: "A consensus output with no batches produces no block, unless it closes the epoch, in which case it produces one."
- cite: crates/engine/src/payload_builder.rs:19-24, crates/engine/src/payload_builder.rs:98, crates/engine/src/payload_builder.rs:114-118
- note: optional; matters to a reader counting blocks per round.

### F51 Step 3: Re-execute batches
- claim: "At each epoch boundary, the resulting state is compared against the epoch record's final_state checkpoint."
- verdict: stale
- replacement: "As it executes, the node checks each consensus output against its own chain: the output's leader names the execution block it was built on, and the node halts if that block is not in its executed chain. The epoch record's `final_state` fixes the execution state from which each epoch's consensus pack is executed."
- cite: crates/state-sync/src/lib.rs:542-575, crates/consensus/primary/src/consensus_bus.rs:916-945, crates/types/src/primary/header.rs:37-41, crates/storage/src/consensus_pack.rs:4155-4162, crates/node/src/manager/node/close_epoch.rs:416-422
- note: no runtime comparison of executed state to a stored record's final_state exists (grep .final_state: only pack meta check, snapshot import and tests); at epoch close a node holding a downloaded record reuses it rather than recomputing.

### F52 Step 3: Re-execute batches
- claim: "This step transforms a cryptographically verified transaction ordering into actual account state, balances, and contract storage."
- verdict: confirmed
- replacement: n/a
- cite: crates/engine/src/payload_builder.rs:19-24
- note: descriptive; execution is the normal EVM payload path.

### F53 Security properties
- claim: "Four mechanisms secure the synchronization process:"
- verdict: confirmed
- replacement: n/a
- cite: (framing; see F54-F58)
- note: still four after the F54 rewrite.

### F54 Security properties
- claim: "BLS aggregate signature verification: applied at every step (epoch records, consensus headers, and the certificates embedded in each)"
- verdict: stale
- replacement: "BLS signature verification: every epoch record carries an aggregate BLS certificate from a super-quorum of its committee, and the live consensus hash is accepted only once one-third plus one of the committee have each signed it. Consensus headers, and the certificates inside them, are then trusted through hash chaining to one of these signed checkpoints."
- cite: crates/types/src/primary/epoch.rs:59-91, crates/consensus/primary/src/network/handler.rs:381-415, crates/storage/src/consensus_pack.rs:3165-3166
- note: headers carry no signature of their own and sync does not re-verify embedded certificates (F42).

### F55 Security properties
- claim: "Parent hash chaining: prevents reordering or omission of records in all three chains"
- verdict: confirmed
- replacement: n/a
- cite: crates/storage/src/epoch_records.rs:356, crates/storage/src/consensus_pack.rs:4283-4285, crates/state-sync/src/lib.rs:518-533, crates/state-sync/src/lib.rs:542-575
- note: epoch chain by parent_hash, consensus chain by parent_hash and strict numbering (consensus_pack.rs:3394-3405), execution chain checked through each leader's latest_execution_block.

### F56 Security properties
- claim: "Committee continuity validation: each transition is checked against the previous record's `next_committee`, tolerating validator dropout so long as at least two-thirds overlap persists and committee size never falls below four members"
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/primary/epoch.rs:113-165
- note: #922. Precisely: a shrunken committee must be a subset of the promised one with n >= 4 and 3n >= 2e; "dropout" here means a governance ejection.

### F57 Security properties
- claim: (none; fact absent)
- verdict: missing
- replacement: "The two-thirds bound applies to each record against the one before it, so ejections in consecutive epochs compound."
- cite: crates/types/src/primary/epoch.rs:132-144
- note: optional; the code documents this as a deliberate liveness trade-off with follow-up work tracked. Orchestrator to decide whether it belongs in a partner document.

### F58 Security properties
- claim: "Super-quorum threshold (2/3 + 1): up to one-third of validators may be Byzantine without compromising safety"
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/primary/epoch.rs:92-111
- note: super_quorum = floor(2n/3) + 1 over the record's committee. The live gossip hash uses n/3 + 1 instead (F46, F54).

### F59 Recovery after restart
- claim: "A node that restarts mid-epoch does not repeat full synchronization."
- verdict: confirmed
- replacement: n/a
- cite: crates/state-sync/src/lib.rs:186-246, crates/state-sync/src/epoch.rs:146-160
- note: it resumes from its executed tip and consensus store; records already held with certificates are skipped.

### F60 Recovery after restart
- claim: "It walks its locally stored executed blocks for the current epoch to restore accumulated gas accounting and leader scheduling state,"
- verdict: stale
- replacement: "It walks its locally stored executed blocks for the current epoch to rebuild per-worker gas totals, restores leader reward counts and the leader schedule from its consensus store, and reads the epoch's base fees from the previous epoch's closing block,"
- cite: crates/node/src/manager/node.rs:306-330, crates/node/src/manager/node.rs:356-430, crates/node/src/primary.rs:80-85, crates/consensus/primary/src/consensus/leader_schedule.rs:258-279, crates/node/src/manager/node.rs:955-967
- note: gas totals come from executed blocks; leader counts from the consensus DB in reverse; the leader swap table from the latest commit with final reputation scores; base fees are never restored from blocks (crates/types/src/gas_accumulator.rs:18-47).

### F61 Recovery after restart
- claim: "replays any consensus output that was committed but not yet executed,"
- verdict: confirmed
- replacement: n/a
- cite: crates/node/src/manager/node/start_epoch.rs:98-150, crates/node/src/manager/node/run_epoch.rs:229-240, crates/state-sync/src/lib.rs:207-246
- note: replay stops at an epoch-closing output and closes the epoch first.

### F62 Recovery after restart
- claim: "and then resumes live consensus participation."
- verdict: stale
- replacement: "and then resumes in the mode its committee membership gives it: a committee member resumes as CvvActive and drops to CvvInactive if it finds itself behind, and a node outside the committee resumes as an observer."
- cite: crates/node/src/manager/node.rs:969-981, crates/node/src/manager/node.rs:1165-1172, crates/consensus/primary/src/network/handler.rs:216-252
- note: only a committee member that is still within the GC window resumes live participation directly.

### F63 Recovery after restart
- claim: (none; fact absent)
- verdict: missing
- replacement: "A node stopped exactly at an epoch boundary, after executing the closing block but before storing that epoch's record, re-derives the record locally from its executed closing block when it restarts."
- cite: crates/node/src/manager/node/close_epoch.rs:515-585, crates/node/src/manager/node/run_epoch.rs:222-227
- note: optional; the record is deterministic, so no peer fetch or certificate is needed.

## Not raised
- v0.16.0 storage migration (consensus store consensus-db/epochs, epoch packs v1 to v2; crates/storage/src/consensus_pack.rs:60, crates/config/src/traits.rs:155-156): these two chapters do not describe on-disk layout, so no finding. If the editor wants a pointer, F40's "consensus pack" is where it would attach.

## Summary
- total findings: 63
- confirmed: 38 (F1, F2, F4, F5, F7, F8, F9, F10, F12, F14, F17, F18, F20-F25, F27, F28, F30, F31, F33, F35, F36, F37, F41, F43, F45, F48, F49, F52, F53, F55, F56, F58, F59, F61)
- stale: 16 (F3, F6, F11, F15, F16, F32, F34, F39, F40, F42, F44, F47, F51, F54, F60, F62)
- missing: 9 (F13, F19, F26, F29, F38, F46, F50, F57, F63; F46 adds a missing threshold to an otherwise correct table row; F26, F50, F57, F63 are optional)
- unverifiable: 0 (only open value: the live adiri epoch length behind F39, settled by reading epochDuration from tn_getCurrentEpochInfo; the F39 replacement does not depend on it)
