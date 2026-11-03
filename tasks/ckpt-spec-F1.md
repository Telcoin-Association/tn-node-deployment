status: complete (sections 1-7 done; gates pass: pandoc clean, grep empty, 10 chapters, headings intact, links resolve, PDF 35 pages, empty WeasyPrint log, md 738 lines)

# Checkpoint F1

Completed sections: 1, 2, 3, 4, 5, 6 (Part C appended, entries 29/71/160/166/180/197 amended), 7 (gates)

Q2c status when read: done (read before section 2; triage "From Q2c" section read too).
Decision notes: C6 (Seed value list item, line 89) is in the triage drop list and line 89 is also named for the N+3 fix; dropping C6 removes the misstatement, so 89 goes (report it). C33 + Q2b 386 merged into one sentence. Q2b 349-350 unsettled mid-epoch claim worded "no later than the next epoch boundary".

## Worklist (by chapter; decision in brackets)

Ch1 Introduction
- 6 [fix Q2a]: name admitted tx types (legacy, EIP-2930, EIP-1559; blob and EIP-7702 rejected)

Ch2 Architecture overview
- 24 [fix Q2a]: sub_dag also holds reputation scores and commit timestamp (seed omitted with C6)
- 41/45 [fix Q2a inconsistent]: drop "2ƒ+1"; super-quorum defined once at 45 (two-thirds rounded down, plus one)
- 46-47 [dedupe C3]: drop (693-694 keeps it)
- 56 [fix Q2a]: Content cell adds reputation scores, commit timestamp
- 57 consensus cell [fix Q2a]: "consensus result signed by one-third plus one of the committee"
- 57 execution cell [fix Q2a stale]: deterministic re-execution, anchored by epoch record final state

Ch3 Consensus layer
- 77 [fix Q2a 41 note]: define ƒ
- 89 [drop C6]: Seed value item
- 103 [fix Q2a]: 60 leader rounds (120 consensus rounds)
- 108 [fix Q2a]: "normally no more than a third"
- 111 [fix Q2a stale]: share of issuance for committed leader turns + link Reward distribution

Ch4 Execution layer
- 136 [cosmetic]: straight quotes
- 148-149 [fix Q2a + dedupe C9]: one sentence, TEL purpose corrected; value rule left to ch 9
- 154-155 [fix Q2a wrong]: corrected two sentences
- 206-207 [drop C15]: skip clause; `()` on function names
- 237-238 keep (C16)

Ch5 Epoch boundaries
- 249-250 [drop C17 + cosmetic ()]: drop one-time upgrade sentence
- 259, 268, 274, 288 [cosmetic]: `()` on function names
- 264 [fix Q2a]: "governance Safe"
- 270 [drop C19]
- 277 [fix Q2a]: Active/PendingActivation fill, PendingExit drawn at random
- 280 [fix Q2a + Q2c]: seed signature also over previous epoch record digest
- 289-290 [fix B1/Q2a wrong/C21]: N+3 sentence
- 294 [cosmetic]: straight apostrophe
- 300 [fix Q2a]: "stay at the minimum floor"
- 307 [fix Q2a]: forks that would change already-produced history
- 314 [fix Q2a]: "at, or soon after"
- 316-317 [reword C25]: network-neutral sentence; drop mainnet clauses
- 322 [fix Q2a]: registry upgrade substance
- 323 [drop C24]: Governance Safe row
- 325 [fix Q2a]: committee description in consensus data
- table delimiter ok

Ch6 Validator lifecycle
- 339 [fix Q2b]: draw from Active + PendingActivation, PendingExit only for shortfall
- 349-350 [fix Q2b]: burn forfeits rewards, no empty committee, ejection effective no later than next boundary; drop "at any time"
- 358 [cosmetic]: delimiter
- 365 [fix Q2b scope + cosmetic]: `Retired`, no `Any` sentinel
- 370-375 [cosmetic]: wrap multi-sentence items; 373 `concludeEpoch()`
- 377 [fix Q2b], 378 [fix Q2b]
- 385-386 [reword C33 + Q2b 386]: one sentence

Ch7 Node modes
- 398 [fix Q2b]: optimistic entry; 399 [consistency, Q2b nuance]: "names a next committee without its key"
- 408 [unsettled]: no frequency claim
- 412 [fix Q2b], 416 [fix Q2b], 417 [follow-on consistency], 419 [scope Q2b]
- 423-424 [fix Q2b]: vetoed member keeps pooled; split sentence
- 433 [fix Q2b + straight apostrophe], 437 [fix Q2b]
- 439-440 [drop C35]
- 445 delimiter; 449 [fix Q2b]: sentence under table: intake follows seat

Ch8 Networking
- 457 [fix Q2c]: peer-to-peer communication; forwarding uses JSON-RPC
- 468 [drop C38]
- 471-473 [reword C39 + Q2c 472/473]: one sentence (about ten seconds; idle timeout about half a minute)
- 477 [dedupe C30]: few words + link to Ed25519 signatures
- 481 [Q2c scope numbers]: "periodically"
- 488 [Q2c scope numbers]: qualitative peer target
- 492 [fix Q2c]: /1.1.0 and /1.0.0
- 497 delimiter; 503-505 [drop C42]: restore April sentence
- 513 [fix Q2c]; 514 [reword C43]
- 525-526 [drop C44]; 527-528 [drop C45]
- 539 [fix Q2c + numbers]: revert to April sentence (no 1 MiB)
- 546 [numbers]: drop "five minutes"
- 554-555 [drop C48]; 556 [drop C49 + Q2c wrong]
- 561 delimiter; 567 [drop C50]
- 568 [fix Q2c + B8]: restore evading-penalties rationale; unless joins tracked committee
- 571 [fix Q2c wrong + C51]: committees only
- 574-576 [drop C52]; 578-579 [drop C53]
- optional: one sentence that scoring values are defaults that may change

Ch9 Cryptographic primitives
- 590 [fix Q2c]: every node signs its node records
- 599 [drop C56 third sentence]
- 602 [fix Q2c]: 4,096-byte cap
- 615 [fix Q2c]: digests, certificate = header digest
- 617-621 [dedupe C58]: one sentence + link
- 628-629 [drop C59]
- 634, 646 delimiter
- 656-658 [fix Q2c + drop C60]: chaining sentence, no leaves/50th
- 664-665 [drop C62]

Ch10 Trustless synchronization
- 671 [fix Q2b]: unless snapshot
- 673-675 [fix Q2b, unsettled b]: replaces re-execution with checkpoint; no "recomputed root" claim
- 686 [dedupe C2]: clause + link to Epoch chain
- 687 [fix Q2b]
- 696 [fix Q2b + triage]: hours; Adiri six; genesis parameter
- 703-704 [fix Q2c 703 + B9]: per-output request by number for the epoch in progress
- 706 [fix Q2b]
- 712 delimiter
- 723 [drop C66]
- 725 [fix Q2b]
- 734 [fix Q2b stale + compounding], 735 [fix Q2b]
- 740 [drop C67 rider]: corrected but generic sentence
- 741 [fix Q2b]
- 742 [drop C68]

Whole document (section 5): `|---|`, wrapped list items, straight quotes, `Retired`, `()` on function names, dangling-sentence read.
Log (section 6): Part C + amend entries 29, 71, 160, 180, 163/166 (532-534 reorder).

Added by coordinator (F2 render fix-up), do in section 4 / section 2:
- ch 9 DST sentence: token starts its own line (begin sentence with it or fenced text block)
- ch 9 BLS precompile address: same
- ch 5 Fork gates: one-line lead-in sentence right before the table
- check ch 4 precompile sentence (two addresses mid-sentence) in the render
