status: done

# Checkpoint T1

Completed sections:
1. Inputs read.
   - Tables: p06 (three-chains comparison, 6 rows); p09-p10 (Repurposed Fields, one table split across the page break, header repeated on p10; 8 rows); p10 (Fixed / Unused Fields, 2 rows); p11 (system-call Property/Value, 4 rows). Total pipe tables: 4.
   - Italics: p05 parent_hash, sub_dag, number. p09-p10 tables: field names bold-italic (snake_case as printed); packed expressions; Batch, B256::ZERO, ConsensusHeader, keccak256(BLS aggregate signature), EMPTY_REQUESTS_HASH, 0. p11 SYSTEM_ADDRESS (0x..fe). p13 epochDuration, ConsensusRegistry, close_epoch, applyIncentives, applySlashes, concludeEpoch, withdrawals. p14 Active, PendingExit, nextCommitteeSize. p04, p07, p08, p12: none (contract names in the p11-p12 list are plain).
   - Cover p01: "Telcoin Network" / "Technical Specification", no subtitle.
   - p04 github.com/telcoin-association/telcoin-network is a real hyperlink (URI annotation https://github.com/telcoin-association/telcoin-network).
2. Chapters 1-2 written (one sentence per line, matching the guide's house style; github link kept as an absolute URL because the original PDF carries a URI annotation).
3. Chapter 3 written.
4. Chapter 4 written (Repurposed Fields as one 8-row table, the p10 repeated header dropped; Fixed / Unused Fields; system-call properties; pre-execution and smart-contract numbered lists).
5. Chapter 5 written.
6. metadata.yaml written (cover has no separate subtitle, so the given subtitle is used). Self-check: 1 `#`, 5 `##`, 18 `###`, 4 `####`; 4 pipe tables (matches section 1); forbidden-text grep empty; no trailing whitespace; pandoc gfm build with the metadata, --number-sections, --toc-depth=3 and --fail-if-warnings passes; word-level diff vs spec.txt lines 72-428 (ratio 0.996) differs only in the added H1, the "ConsensusHead er" join, the `”.` join, table pipes and the dropped repeated header row on p10; 11/11 spot-checked sentences found with grep -F.
