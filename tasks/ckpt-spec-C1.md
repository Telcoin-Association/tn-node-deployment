status: complete (chapters 1-5 refreshed in refresh-a.md, gates pass, log written: 58 change entries)

# Checkpoint C1

Working copy: scratchpad/spec-md/refresh-a.md (first half only, up to `## Validator lifecycle`).
Head drafts: scratchpad/spec-md/c1-head-1.md + c1-head-2.md, spliced onto the original from line 253 (backup refresh-a.orig-c1.md).
Log: tasks/ckpt-spec-refresh-log-a.md

## Completed sections
- 1 Read inputs (facts, R1 61 blocks, R2a 31 blocks, R2b 36 blocks, R3 F1-F10, working copy lines 1-252)
- 2 Verified in WT: TEL precompile 0x..07e1 (tel_precompile/mod.rs:102) differs from registry 0x07e17e17...; BLS 0x..b151 (bls_precompile/mod.rs:51); setWorkerConfigsData writes EIP-1559 workers only, Static skipped, worker set from contract numWorkers (evm/block.rs:566-650); subsecond gate u32::MAX on adiri, active from genesis on mainnet (forks.rs:719-772)

- 3a Introduction, Architecture overview, Consensus layer drafted: scratchpad/spec-md/c1-head-1.md
- 3b Execution layer, Epoch boundaries drafted: scratchpad/spec-md/c1-head-2.md
- 4 Spliced (backup refresh-a.orig-c1.md); `## Validator lifecycle` now line 328; tail identical to transcription; 10 chapters; pandoc OK; no forbidden strings; links resolve

## Decisions
- type/struct names (ConsensusHeader, EpochRecord, Batch) and ConsensusNFT stay plain prose; contract names, fields, functions, statuses, constants, RPC methods, opcodes (PREVRANDAO), addresses get code spans
- conflicts: R2b F6/F30 vs R2a F29 -> EIP-1559 only (block.rs:566-650); R3 F5 + R1 F53 -> WorkerConfigs also holds numWorkers; R2b F36 Safe row kept despite R3 F10 note; R1 F36 note vs R2a F19/R2b F36 S6 -> mainnet ms from genesis
- adiri-history sentences of R2a F15/F16 left to the Fork gates table

- 5 Refresh log written: tasks/ckpt-spec-refresh-log-a.md (58 change entries + conflicts + not-applied)

## Remaining
- none (hand back)
