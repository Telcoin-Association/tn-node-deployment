status: done

# Checkpoint R5c: findings for "Cryptographic primitives" (transcription.md lines 400-447)

WT = /private/tmp/claude-501/-Users-grant-coding-telcoin-tn-node-deployment/474df373-eb73-43be-adbe-ffcbd2a2657a/scratchpad/tn-v0.16.0-adiri
(tag v0.16.0-adiri, d72cc2bcf; tn-contracts at 10cc12b7). All cites are WT-relative at the tag.

## Completed sections
- [x] Chapter intro (F1-F2)
- [x] BLS12-381 signatures (F3-F10)
- [x] Ed25519 signatures (F11-F12)
- [x] Keccak-256 hashing (F13-F16)
- [x] Intent-scoped signing (F17-F27)
- [x] Signature verification (F28-F33)
- [x] Summary

Background checked against v0.8.1-adiri too: BLAKE3 was already the consensus hash and node records were
already BLS-signed in April, so F1, F12, F13, F14 were wrong when written, not only stale.

## Chapter intro

### F1 Chapter intro
- claim: "Telcoin Network uses three cryptographic primitives: BLS12-381 signatures for consensus, Ed25519 signatures for network identity, and Keccak-256 for hashing."
- verdict: stale
- replacement: Telcoin Network uses BLS12-381 signatures for consensus, Ed25519 signatures for peer-to-peer network identity, BLAKE3 for consensus-layer digests and Keccak-256 at the execution layer. Transactions carry Ethereum's standard secp256k1 signatures.
- cite: crates/types/src/crypto/mod.rs:262-268, crates/types/src/primary/block.rs:17-18
- note: `DefaultHashFunction = blake3::Hasher` (mod.rs:267); block.rs doc says "Consensus-layer digests are BLAKE3, not Keccak-256"; secp256k1 execution keys at mod.rs:262-264.

### F2 Chapter intro
- claim: "An intent-scoped signing scheme prevents cross-context signature replay."
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/crypto/intent.rs:52-56, crates/types/src/crypto/intent.rs:116-121
- note: read the enum docs and IntentMessage contract; scope applies to BLS signatures (see F17 for the exceptions).

## BLS12-381 signatures

### F3 BLS12-381 signatures
- claim: "All consensus-layer signing uses the BLS12-381 curve."
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/crypto/bls_keypair.rs:4, crates/types/src/crypto/bls_keypair.rs:59-63
- note: `blst::min_sig` SecretKey signs with DST_G1; every consensus signer goes through BlsSigner (mod.rs:273-288).

### F4 BLS12-381 signatures
- claim: "Validators sign certificates, epoch votes, and epoch records with their BLS private keys."
- verdict: stale
- replacement: Validators sign votes on proposed headers, which aggregate into certificates; epoch votes on each epoch record, which aggregate into epoch certificates; attestations to committed consensus output; a per-round seed signature carried in every header they propose; and the node records they publish for peer discovery.
- cite: crates/types/src/primary/vote.rs:39, crates/types/src/primary/certificate.rs:279-286, crates/types/src/primary/epoch.rs:50-56, crates/consensus/executor/src/subscriber.rs:329-333, crates/types/src/primary/epoch.rs:276-290, crates/node-record/src/record.rs:122-142
- note: grepped every IntentScope / to_intent_message / signer call site outside tests; certificates are not signed separately, their signature is the aggregate of header votes (cert digest = header digest, certificate.rs:483-488).

### F5 BLS12-381 signatures
- claim: "Multiple validator signatures aggregate into a single compact signature, so a verifier performs one aggregated signature check against the known committee public keys rather than N individual checks."
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/crypto/bls_signature.rs:94-102, crates/types/src/crypto/bls_signature.rs:269-286, crates/types/src/primary/epoch.rs:80-88
- note: certificates and epoch certificates each carry one 48-byte aggregate checked in one `aggregate_verify` call; consensus-output attestations are the exception and are checked one by one (crates/consensus/primary/src/network/handler.rs:409-415), which the chapter need not mention.

### F6 BLS12-381 signatures
- claim: "Validators must submit a proof-of-possession during key registration to prevent rogue key attacks."
- verdict: confirmed
- replacement: n/a
- cite: tn-contracts/src/consensus/ConsensusRegistry.sol:594, tn-contracts/src/consensus/ConsensusRegistry.sol:621, tn-contracts/src/consensus/ConsensusRegistry.sol:1613, crates/config/src/genesis.rs:128-143
- note: `stake`, `delegateStake` and the constructor (genesis committee) all call `_verifyProofOfPossession`; the client also checks every genesis validator's proof.

### F7 BLS12-381 signatures
- claim: "This proof demonstrates control of the private key corresponding to a registered public key before that key participates in any aggregation."
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/crypto/bls_signature.rs:171-183, tn-contracts/src/consensus/ConsensusRegistry.sol:1029-1070
- note: registration reverts unless the precompile verifies the proof, so no unproven key reaches a committee. Message layout is in F8.

### F8 BLS12-381 signatures
- claim: (none; proof-of-possession message and where it is checked)
- verdict: missing
- replacement: The proof of possession is a BLS signature over a 119-byte message: the 3-byte proof-of-possession intent prefix (0x000000), the validator's 96-byte compressed public key and its 20-byte execution address, so the proof also binds the consensus key to the staking address. The ConsensusRegistry contract rebuilds this message on chain, verifies the signature through the BLS precompile and refuses a public key that is already registered. The `tn_proofOfPossessionMessage` RPC method returns the exact bytes to sign.
- cite: crates/types/src/crypto/bls_signature.rs:198-214, tn-contracts/src/consensus/ConsensusRegistry.sol:1003-1021, tn-contracts/src/consensus/ConsensusRegistry.sol:1062-1078, docs/src/rpc-methods/tn/tn_proofofpossessionmessage.md:3
- note: contract also rejects a key with the compression flag clear or the infinity flag set (ConsensusRegistry.sol:1048-1049); duplicate rejection in `_spendBLSPubkey` (1073-1078).

### F9 BLS12-381 signatures
- claim: (none; signature variant and encodings)
- verdict: missing
- replacement: Telcoin Network uses the minimal-signature-size variant: signatures are 48-byte points on G1 and public keys are 96-byte compressed points on G2. Messages are hashed to the curve with the domain separation tag `BLS_SIG_BLS12381G1_XMD:SHA-256_SSWU_RO_NUL_`.
- cite: crates/types/src/crypto/bls_keypair.rs:4, crates/types/src/crypto/bls_keypair.rs:27, tn-contracts/src/interfaces/IBlsG1.sol:13-15
- note: integrators building signatures or verifiers need the variant and tag; the RPC also accepts the 192-byte uncompressed key (tn_proofofpossessionmessage.md:5).

### F10 BLS12-381 signatures
- claim: (none; BLS precompile for contracts)
- verdict: missing
- replacement: Contracts can verify BLS signatures through a native precompile at `0x000000000000000000000000000000000000B151`, called as `blsVerify(bytes signature, bytes pubkey, bytes message)`. It runs the same verification code the consensus layer uses and treats the message as opaque, so any contract can check any BLS-signed message; the ConsensusRegistry uses it for proofs of possession. A call costs 150,000 gas plus 12 gas per 32-byte word of arguments, and a call that carries value is rejected.
- cite: crates/tn-reth/src/evm/bls_precompile/mod.rs:1-22, crates/tn-reth/src/evm/bls_precompile/mod.rs:51, crates/tn-reth/src/evm/bls_precompile/mod.rs:80, crates/tn-reth/src/evm/bls_precompile/mod.rs:101, crates/tn-reth/src/evm/bls_precompile/mod.rs:177-183, tn-contracts/src/interfaces/IBlsG1.sol:9-33
- note: value rejection is #1286; registered unconditionally in both EVM constructors (crates/tn-reth/src/evm/factory.rs:67-68, 92-93), no fork gate.

## Ed25519 signatures

### F11 Ed25519 signatures
- claim: "Ed25519 is the signature scheme for network-layer identity."
- verdict: confirmed
- replacement: n/a
- cite: crates/config/src/keys.rs:549-555, crates/types/src/crypto/network.rs:10-16, crates/types/src/crypto/network.rs:37-41
- note: NetworkKeypair is a libp2p identity keypair built with `ed25519_from_bytes`; PeerId comes from the public key.

### F12 Ed25519 signatures
- claim: "Each peer holds an Ed25519 keypair that authenticates transport-layer connections and signs peer records published to the DHT."
- verdict: stale
- replacement: Each node holds Ed25519 keypairs, one for its primary network and one for each worker network, derived deterministically from its BLS key so they never need to be stored. The public key determines the node's libp2p peer ID. The key authenticates the node's QUIC connections and signs every gossip message, and peers reject unsigned gossip. Node records published to the DHT are signed with the node's BLS key instead, so a record can be checked against the validator's registered consensus key.
- cite: crates/config/src/keys.rs:240-244, crates/config/src/keys.rs:512-525, crates/config/src/keys.rs:549-555, crates/network-libp2p/src/consensus.rs:574, crates/network-libp2p/src/consensus.rs:586-589, crates/network-libp2p/src/consensus.rs:727-728, crates/node-record/src/record.rs:11-23, crates/node-record/src/record.rs:178-189
- note: derivation = BLAKE3 of the BLS signature over a seed string, first 32 bytes as the Ed25519 secret; gossipsub uses MessageAuthenticity::Signed with ValidationMode::Strict; NodeRecord.signature is a BlsSignature (also true at v0.8.1). The network-key handshake proof in network.rs:109-141 has no callers at the tag.

## Keccak-256 hashing

### F13 Keccak-256 hashing
- claim: "Keccak-256 is the hash function across the protocol." (and the section heading "Keccak-256 hashing")
- verdict: stale
- replacement: Retitle the section "Hashing". The consensus layer hashes with BLAKE3: batch, header, certificate, consensus header and epoch record digests are 32-byte BLAKE3 hashes of the encoded structure. The execution layer uses Keccak-256, as Ethereum does.
- cite: crates/types/src/crypto/mod.rs:266-268, crates/types/src/primary/block.rs:17-18
- note: grepped DefaultHashFunction / keccak256 across crates/types/src; Keccak appears only in execution-side code, the seed chain and PREVRANDAO.

### F14 Keccak-256 hashing
- claim: "It produces ConsensusHeader digests, EpochRecord digests, and block hashes."
- verdict: stale
- replacement: ConsensusHeader and EpochRecord digests are BLAKE3 hashes, as are batch, header and certificate digests. Execution block hashes are Keccak-256.
- cite: crates/types/src/primary/block.rs:67-80, crates/types/src/primary/epoch.rs:43-47, crates/types/src/primary/header.rs:621-628, crates/types/src/worker/sealed_batch.rs:134-139, crates/types/src/primary/certificate.rs:483-488
- note: each digest function instantiates crypto::DefaultHashFunction (BLAKE3); a certificate's digest is its header's digest.

### F15 Keccak-256 hashing
- claim: "It also derives randomness for committee shuffling: applying the hash to an aggregated BLS signature yields a deterministic seed for validator ordering."
- verdict: stale
- replacement: Keccak-256 also derives the seed for the committee shuffle. Each proposer signs a per-round seed message (the epoch, the round and the digest of the previous epoch record) under its own intent scope and carries that signature in its header. Every committed sub-DAG folds its leader's seed signature into a Keccak-256 hash chain that starts from a per-epoch root, and the chain value at the epoch's closing commit seeds the shuffle. BLS signatures are deterministic and the seed signature is covered by the header digest, so the seed cannot vary with which validators signed a certificate.
- cite: crates/types/src/primary/seed_chain.rs:81-84, crates/types/src/primary/seed_chain.rs:115-124, crates/types/src/primary/epoch.rs:260-296, crates/types/src/primary/output.rs:292-297, crates/types/src/primary/output.rs:655-671, crates/types/src/forks.rs:202-218, crates/tn-reth/src/payload.rs:129-134
- note: the April text describes the pre-fork rule (keccak256 of the leader certificate's aggregate signature, forkable by signer subset). On adiri the seed chain applies from epoch 383 (`SEED_SIGNATURE_FORK_EPOCH`, forks.rs:218); other builds use it from genesis. Put the epoch number in the fork-gate subsection under Epoch boundaries, not here. The same chain value also feeds PREVRANDAO from its own fork (output.rs:304-312, 330-332).

### F16 Keccak-256 hashing
- claim: "This maintains compatibility with Ethereum's hashing conventions."
- verdict: stale
- replacement: Keccak-256 keeps the execution layer compatible with Ethereum: block hashes, transaction hashes and account addresses follow Ethereum's conventions.
- cite: crates/types/src/helpers.rs:275-281, crates/types/src/repack_monitor.rs:173
- note: true only for the execution layer once F13 lands; addresses from keccak256 of the secp256k1 key, transaction hashes keccak256 of the raw bytes.

## Intent-scoped signing

### F17 Intent-scoped signing
- claim: "Every BLS signature commits to an IntentMessage that binds the signature to a specific protocol context."
- verdict: stale
- replacement: Every consensus BLS signature commits to an IntentMessage that binds it to a specific protocol context. The proof of possession carries the same 3-byte intent prefix ahead of raw bytes, so a contract can rebuild it. Node records published for peer discovery use their own signing label and bind the chain id and network role, so a record signed for one chain or role never verifies on another.
- cite: crates/types/src/crypto/mod.rs:290-294, crates/types/src/crypto/bls_signature.rs:198-214, crates/node-record/src/record.rs:60-66, crates/node-record/src/record.rs:122-125
- note: node-record signing bytes are BCS of ("telcoin-network/node-record/v1", chain_id, role, worker_id, info), no IntentMessage; the label could be quoted if the spec wants it.

### F18 Intent-scoped signing
- claim: "The message is signed after a 3-byte intent prefix is added. This prefix is composed of the scope, version, and application identifier."
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/crypto/intent.rs:10, crates/types/src/crypto/intent.rs:83-92, crates/types/src/crypto/intent.rs:125-131, crates/types/src/codec.rs:80-82
- note: BCS encodes the struct fields in order, so the bytes are scope, version, app id, then the encoded value.

### F19 Intent-scoped signing
- claim: "| ProofOfPossession | 0 | Proof of possession for protocol keys |"
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/crypto/intent.rs:60, crates/types/src/crypto/bls_signature.rs:210
- note: used with AppId Telcoin, giving the 0x000000 prefix.

### F20 Intent-scoped signing
- claim: "| EpochBoundary | 1 | Authority signature on epoch records |"
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/crypto/intent.rs:61, crates/types/src/primary/epoch.rs:50-56, crates/types/src/primary/epoch.rs:80-88
- note: epoch votes sign the EpochRecord digest under this scope; epoch certificates verify the aggregate under it.

### F21 Intent-scoped signing
- claim: "| ConsensusDigest | 2 | Authority signature on consensus certificates |"
- verdict: stale
- replacement: | ConsensusDigest | 2 | Votes on proposed headers (aggregated into certificates) and attestations to committed consensus output |
- cite: crates/types/src/crypto/mod.rs:290-294, crates/types/src/primary/vote.rs:39, crates/types/src/primary/certificate.rs:281-286, crates/consensus/executor/src/subscriber.rs:329-333, crates/consensus/primary/src/network/handler.rs:409-410
- note: `to_intent_message` always uses Consensus/ConsensusDigest; its callers are votes, certificate verification and consensus-result signing.

### F22 Intent-scoped signing
- claim: "| SystemMessage | 3 | Signing system messages |"
- verdict: stale
- replacement: | SystemMessage | 3 | Reserved; no protocol message is currently signed under it |
- cite: crates/types/src/crypto/intent.rs:63
- note: grep for `SystemMessage` across crates/ and bin/ finds only the enum variant (plus unrelated error names in crates/types/src/error.rs:51-54).

### F23 Intent-scoped signing
- claim: (none; table omits a variant)
- verdict: missing
- replacement: | EpochCloseSeed | 4 | Proposer's per-round seed signature, folded into the committee-shuffle seed |
- cite: crates/types/src/crypto/intent.rs:64-66, crates/types/src/primary/epoch.rs:276-290
- note: added by #1062 (#1032); the scope byte 4 versus 2 separation is pinned by the test at crates/types/src/primary/epoch.rs:514-536.

### F24 Intent-scoped signing
- claim: "IntentVersion is currently V0, a version byte reserved for future compatibility."
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/crypto/intent.rs:12-21
- note: single variant V0 = 0; both constructors set it (intent.rs:106-114).

### F25 Intent-scoped signing
- claim: "| Telcoin | 0 | General Telcoin Network operations |"
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/crypto/intent.rs:41, crates/types/src/crypto/bls_signature.rs:210
- note: value correct and the label is not wrong; in practice the only signatures under AppId Telcoin are proofs of possession, so "Proofs of possession" would be a sharper purpose if the editor wants one.

### F26 Intent-scoped signing
- claim: "| Consensus | 1 | Consensus-specific operations |"
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/crypto/intent.rs:42, crates/types/src/crypto/intent.rs:111-113
- note: votes, certificates, consensus-output attestations, epoch votes and seed signatures all use Intent::consensus.

### F27 Intent-scoped signing
- claim: "This scheme ensures that a certificate signature cannot be replayed as an epoch vote, and that identical serialized payloads produce distinct signed messages whenever the intent differs."
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/crypto/intent.rs:52-56, crates/types/src/primary/epoch.rs:514-536
- note: certificates use scope 2, epoch votes scope 1; the pinned test shows identical values under two scopes encode to different messages.

## Signature verification

### F28 Signature verification
- claim: "Certificate verification follows two paths."
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/primary/certificate.rs:442-458
- note: SignatureVerificationState has VerifiedDirectly and VerifiedIndirectly (plus Unsigned, Unverified, Genesis).

### F29 Signature verification
- claim: "Direct verification checks an aggregated signature against the current committee's BLS public keys."
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/primary/certificate.rs:225-251, crates/types/src/primary/certificate.rs:269-292
- note: the committee used is the one for the certificate's own epoch (the epochs must match, 226-233); `verify_cert` (255-266) takes an explicit committee key set for past epochs during sync. "the committee of the certificate's epoch" would be more exact.

### F30 Signature verification
- claim: "Indirect verification establishes a chain of trust from a previously verified certificate back to a known committee."
- verdict: stale
- replacement: Indirect verification applies to certificates fetched in bulk during catch-up. A fetched certificate that another certificate in the same set names as a parent is accepted through that reference, because the child's header digest commits to its parents' digests and the child's signatures are checked directly. Leaf certificates, and certificates every 50th round, are always verified directly.
- cite: crates/consensus/primary/src/state_sync/cert_validator.rs:271-322, crates/config/src/network.rs:490
- note: `requires_direct_verification` = not a parent of any cert in the set, or round % certificate_verification_round_interval (default 50) == 0; trust flows from child to parent, not "back to a known committee".

### F31 Signature verification
- claim: "In both cases, validity requires a super-quorum threshold: at least 2/3 + 1 of the committee must sign."
- verdict: stale
- replacement: A directly verified certificate needs signatures from at least ⌊2N/3⌋ + 1 of the N committee members; an indirectly verified certificate inherits that guarantee through its digest link. Epoch certificates use the same threshold.
- cite: crates/types/src/committee.rs:473-478, crates/types/src/committee.rs:1191-1193, crates/types/src/primary/certificate.rs:243-246, crates/types/src/primary/epoch.rs:84-88, crates/types/src/primary/epoch.rs:109-110
- note: the threshold formula is right; "in both cases" is not, because indirectly verified certificates get no quorum or signature check of their own (cert_validator.rs:316-322).

### F32 Signature verification
- claim: "This bound derives from standard BFT assumptions, guaranteeing that any valid quorum contains at least one honest signer."
- verdict: confirmed
- replacement: n/a
- cite: crates/types/src/committee.rs:473-478
- note: with N = 3f+1+k the quorum is N-f, so it holds at least f+1 honest signers. The property consensus relies on is stronger: any two quorums share at least one honest validator. The editor may want that wording.

### F33 Signature verification
- claim: (none; where verifiers obtain committee keys)
- verdict: missing
- replacement: The committee's BLS public keys come from the ConsensusRegistry contract. The `tn_getCommitteeBlsPubkeys` RPC method returns them for any epoch from three before the current one to two after it, in the registry's committee order, and `tn_getBlsPubKey` returns a single validator's key.
- cite: docs/src/rpc-methods/tn/tn_getcommitteeblspubkeys.md:3-5, docs/src/rpc-methods/tn/tn_getblspubkey.md:3
- note: low priority; useful for a partner who wants to check certificates or epoch certificates independently. Check that the RPC chapter does not already cover it before adding.

## Summary

Counts by verdict (33 blocks):
- confirmed: 16 (F2, F3, F5, F6, F7, F11, F18, F19, F20, F24, F25, F26, F27, F28, F29, F32)
- stale: 12 (F1, F4, F12, F13, F14, F15, F16, F17, F21, F22, F30, F31)
- missing: 5 (F8, F9, F10, F23, F33)
- unverifiable: 0

Note: in F21 and F22 the numeric values (2, 3) are right; only the purpose cells are stale.
