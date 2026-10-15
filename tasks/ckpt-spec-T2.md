status: done (sections 1-6 of 6)

# Checkpoint T2

Output: /private/tmp/claude-501/-Users-grant-coding-telcoin-tn-node-deployment/474df373-eb73-43be-adbe-ffcbd2a2657a/scratchpad/spec-md/part-b.md
Helper (italic/bold detection): pdftohtml -xml per page in /private/tmp/claude-501/-Users-grant-coding-telcoin-tn-node-deployment/474df373-eb73-43be-adbe-ffcbd2a2657a/scratchpad/t2xml/pNN.xml
(pdftohtml drops ':' '{' '}' glyphs; spec.txt and the renders keep them, so text comes from spec.txt.)

## Completed sections

1. Inputs read.
   - Tables (7): p15 validator statuses (Status|Meaning); p18 capabilities (Capability|CvvActive|CvvInactive|Observer);
     p20 gossipsub topics (Topic|Purpose); p22 reputation levels (Level|Behavior) [not in the brief's list];
     p24 IntentScope (Scope|Value|Purpose) and AppId (Application|Value|Purpose); p26 sync sources (Source|When available|Notes).
   - Code-like lines (green 14pt, Google Docs code style): p19 `/ip4/{HOST}/udp/{PORT}/quic-v1`; p20 `/telcoin-network/0.0.1`.
   - Italic identifiers (Inter-Italic runs): p16 stake, ConsensusRegistry, activate, concludeEpoch, beginExit, unstake ("()" upright);
     p20 the five topic names in the table; p25 parent_hash x2, committee (list item 2), next_committee x2, final_consensus, final_state;
     p26 final_consensus and parent_beacon_block_root (table), next_committee (security bullet).
     NOT italic in the original (left plain): ConsensusNFT, ERC-721, status names, CvvActive/CvvInactive/Observer, ConsensusHeader(s),
     EpochRecord, IntentMessage, IntentScope, IntentVersion, V0, AppId, scope/app names in tables, final_state in Step 3 (p26).
   - Bold: lifecycle step lead-ins "1. NFT mint." etc. (manual numbers inside bold text), table header rows.
   - Lists: p16 lifecycle 1-7 (manual bold numbers -> ordered list with bold lead-in); p20 3 bullets; p21 3 bullets; p25 numbered 1-3; p26 4 bullets.
   - Headings: "Synchronization proceeds in three steps." is Arial 21 #434343 (GDocs Heading 3 style), an ordinary sentence -> plain paragraph.
     Step 1/2/3 are Inter 17 #666666 (GDocs Heading 4 style) -> `###` (siblings of Security properties; avoids a skipped level).
   - `--observer`: no occurrence in pages 15-27 (only "configured as an observer/observers" prose). "legacy": none.
   - Non-ASCII: one curly apostrophe in "epoch’s" (Mode detection), kept verbatim.
2. Chapter 6 written (Validator lifecycle: intro, ConsensusNFT, Validator statuses + table, Lifecycle steps as ordered list 1-7 with bold lead-ins, Delegation).
3. Chapter 7 written (Node modes: intro, CvvActive, CvvInactive, Observer, Mode detection, Capabilities + table; Yes/No columns centred as in the original). No `--observer` in this chapter.
4. Chapter 8 written (Networking: intro, Transport + ```text multiaddr, Identity and discovery, Gossipsub topics + table with code-span topic names (tn-consensus-output rejoined), Request-response RPC + ```text protocol id + 3 bullets, Peer scoring + 3 bullets + reputation levels table).
5. Chapter 9 written (Cryptographic primitives: intro, BLS12-381 signatures, Ed25519 signatures, Keccak-256 hashing, Intent-scoped signing + IntentScope table + AppId table (Value columns centred), Signature verification). No italics in this chapter, so no code spans.
6. Chapter 10 written (Trustless synchronization: intro, "Synchronization proceeds in three steps." as a plain paragraph, Step 1 + numbered list 1-3, Step 2 + sources table, Step 3, Security properties + 4 bullets, Recovery after restart). Steps are `###` (original styles them one level below the "three steps" sentence; demoting that sentence makes them sections).
   "already verified." / "Verified hashes that seed..." (p26) sit on consecutive lines with no gap in the original; transcribed as two paragraphs.
   Self-check: `grep -c '^## '` = 5; pipe tables = 7 (matches section 1 list); pandoc gfm parse: 5 h2, 24 h3, 7 tables, 2 ol, 3 ul, 2 pre, no stray <em>, no warnings;
   `--observer` occurrences: none; forbidden-text lint (grant@, migrate-node-naming, setup-observer/validator, repo links, "legacy"): clean; no trailing whitespace, no HTML.
   Full word-level diff vs spec.txt 431-789 (headers/footers/bullet glyphs/chapter numbers stripped): 2403 vs 2402 words, sole difference = the split cell "tn-consensus-outp ut" rejoined as `tn-consensus-output`.
   10 grep -F sentence spot-checks: 10/10 found.
