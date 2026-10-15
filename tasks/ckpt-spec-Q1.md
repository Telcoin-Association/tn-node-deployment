status: complete

# Checkpoint Q1

Completed sections: A, B, C, D

Files: ORIG = spec.txt / pages pNN.png (S=.../480c37c9.../scratchpad/spec); TR = .../474df373.../scratchpad/spec-md/transcription.md; FINAL = docs/partner/technical-specification/technical-specification.md; LOG = tasks/ckpt-spec-refresh-log.md

## A. Transcription fidelity (ORIG vs TR)

Method: word-level difflib of de-headered spec.txt against TR with Markdown stripped (q1/norm.py, q1/diffA.txt in the scratchpad), then every page render p04-p27 read against TR.

- A0 prose: no missing sentence and no drifted word. The only word-diff hunks are chapter/list numbers, the extraction artefacts `ConsensusHead`/`er` (p06) and `tn-consensus-outp`/`ut` (p20), the repeated table header on p10, the extraction's space in `"consensus output" .` (render p09 has none; TR 117 is right), and the two inserted ```text fences (TR 335, 367; render shows green monospace lines, so fences are right).
- A0 tables: all 11 tables match the renders cell for cell (p06 chains, p09-10 Repurposed Fields, p10 Fixed/Unused, p11 system-call properties, p15 statuses, p18 capabilities incl. "No (direct participant)", p20 topics, p22 levels, p24 IntentScope and AppId, p26 sync sources). SYSTEM_ADDRESS has 40 hex digits in both.
- A0 headings: every heading text and level matches the TOC (p02-p03). Only level difference: TOC puts Step 1-3 at level 4 under "Synchronization proceeds in three steps."; TR 454/466/478 make them ### because that line was kept a paragraph (accepted decision, consequence only).
- A0 italics: every identifier italic in the renders is a code span in TR (23, 138-152, 161, 196-235, 278-282, 355-359, 458-476, 488) and no TR code span is plain in the render. Listed, not judged: `final_state` is plain in the render at p26 Step 3 and plain at TR 480 (consistent with the render, but the same identifier is a code span at TR 462).
- A1 format: TR 255-493 (chapters 6-10) put a whole paragraph on one line (e.g. TR 255, 259, 286, 290, 294, 312, 339, 406, 450, 462, 468, 480) and lifecycle items 278, 281, 282 carry several sentences; chapters 1-5 are one sentence per line. Breaks the stated "one sentence per line" convention (no wording effect).
- A2 format: table delimiter rows are `|---|` in TR 46, 137, 150, 160 and `| --- |` in TR 266, 319, 354, 392, 425, 436, 473 (cosmetic, two transcription hands).
- A3 render-faithful choices worth knowing: Lifecycle steps bold lead-ins (accepted); Intro URL is a link because the render underlines it (TR 12); Capabilities and IntentScope/AppId value columns centred as in the renders (TR 319, 425, 436).

## B. Refresh accountability (TR vs FINAL)

Method: per-chapter sentence-level difflib of TR against FINAL (q1/diffB.py, q1/hunks_sub.txt: 92 hunks), plus a pass for units that differ only in code spans (q1/fmtonly.py: 21 units). Each hunk was matched to a log line (log line numbers below refer to tasks/ckpt-spec-refresh-log.md).

- B0 coverage: every one of the 92 hunks has a log entry (A: log 19-75; B: log 104-223); all 21 code-span-only units fall under the whole-half entries (log 18, 99); the TR paragraph-per-line of ch 6-10 is undone by log 98. Log entries with no hunk are only the deliberate "kept / not applied" ones (log 86-87, 108, 110, 113, 115, 127, 149, 158, 169, 220), which describe no change. Log is complete.
- B1 wrong fact behind a logged entry: FINAL 290 "the committee drawn when epoch N closes serves epoch N+2" (log 71, R2b F27). Code: ConsensusRegistry.sol `_updateEpochInfo` does newEpoch = ++currentEpoch and stores futureCommittee at newEpoch + 2, so the draw in epoch N's closing block serves N+3; start_epoch.rs:283-285 reads "the concludeEpoch that seats epoch N writes epoch N+2's committee". FINAL 289 ("epoch after next"), 350 and 374 ("two committees already drawn after it") and 373 ("drawn three epochs ahead ... third epoch after that boundary") agree with the code, so 290 contradicts its own chapter neighbour and chapter 6.
- B2 description incomplete: FINAL 77 adds "enough to guarantee that at least one honest validator saw it" and drops "acknowledged ... successfully committed"; log 29 describes only the threshold change.
- B3 description incomplete: FINAL 518 adds the clause "so a primary only negotiates with primaries, each worker only with workers of the same index, and nodes on different chains never negotiate at all"; log 160 mentions only the new ids.
- B4 undescribed reorder: FINAL 532-534 list order is Header votes, Batch reports, Epoch records; TR 373 had epoch records first; log 163/166 do not mention the move.
- B5 trivial undescribed edits: FINAL 625 "binds the signature" -> "binds it" (log 197); FINAL 373 "transitions" -> "moves" (inside log 119's range, acceptable).
- B6 dropped without replacement, part A: none (log 12 is right).
- B7 dropped, part B, explained: `tn-txn` row (TR 359; log 156, replaced by Transaction forwarding 508-514); RPC items "Consensus header retrieval" and "Batch downloads" (TR 374-375; log 164-165, their content moved to the sync-stream paragraph FINAL 534-535); "Average" level row (TR 394; log 176, three levels at the tag); "Execution blocks" source row (TR 476; log 216, replaced by FINAL 716-717); "configured as observers" clauses (TR 306, 312; log 133, 135, flag removed upstream).
- B8 dropped, part B, not explained: the rationale "preventing peers from evading penalties through rapid reconnection" (TR 398) is dropped by log 180 with no reason; the 30-minute freeze at FINAL 569 still serves exactly that purpose, so the clause could have stayed.
- B9 flow nit (not a log gap): FINAL 703-704 keep the April sentences "Syncing nodes request the header for a verified hash ... This process repeats until all consensus headers are downloaded." after the new pack-download sentences 700-702, so they now read as if the whole step were a per-header backward walk; only the epoch in progress (702) works that way.

## C. Scope (additions that are neither a stale-sentence correction nor one of the three planned subsections)

Judgement key: PN partner-needed, NH nice-to-have, OOS out-of-scope (op = operator material, int = internal detail, nl = not live at the tag). "rider" = new fact attached to a correction. Line numbers are FINAL.

- C1 27 header numbers start at zero and rise by one (rider on digest correction) -- NH
- C2 43-44 epoch record may carry a smaller committee after a mid-epoch ejection (subset, >=4, >=2/3) -- NH; repeated at 685
- C3 46-47 record derived from the closing block; signatures gathered in the background; late joiners fetch it -- NH; repeated at 693-694
- C4 77 "enough to guarantee that at least one honest validator saw it" (rider) -- NH
- C5 80-81 intra-round order keyed on seed chain + certificate digest; no validator picks its batch position -- NH (fairness/MEV property)
- C6 89 "Seed value" item in the committed sub-DAG list -- OOS int
- C7 118 each worker has its own pool and RPC endpoint; a transaction joins that lane -- NH
- C8 123 "Epoch" batch-metadata item; other-epoch batches rejected -- NH
- C9 148-149 TEL precompile 0x...07e1 and BLS verifier 0x...b151, value rejected -- NH (contract developers); duplicates 601-603
- C10 169 `beneficiary` header row -- NH
- C11 170 `timestamp` row incl. `tn_getBlockTimestampMillis` -- NH; on Adiri the ms gate is unarmed (326), so the RPC returns seconds x 1000 there
- C12 178 `blob_gas_used` row -- NH (trivial)
- C13 179 `gas_limit` 30,000,000 per batch row -- NH
- C14 194 system-call events absent from receipts and `eth_getLogs` (rider) -- PN for indexers
- C15 207 `setWorkerConfigsData` skipped when no lane uses EIP-1559 -- OOS int
- C16 237-238 governance Safe owns registry and `WorkerConfigs`; owner powers; pause scope -- PN (trust model)
- C17 250 a scheduled one-time contract upgrade runs first in the closing block -- OOS int (Fork gates covers it)
- C18 262 "so explorers can see the reward inputs without tracing system calls" (rider) -- NH
- C19 270 reduce-or-eject rule for a non-empty slash list -- OOS nl (dormant: the slash list is always empty); also 351
- C20 282-284 grinding analysis (no re-cut grinding; closing leader's withhold bias accepted) (rider) -- NH
- C21 290 "so every node knows the next two committees in advance" (rider) -- carries the N+2 error (B1)
- C22 297 entering/restarting nodes read fees from the contract; batches must carry exactly that fee -- NH
- C23 300 genesis EIP-1559 target effectively unlimited, so fees sit at the floor (rider) -- PN (fee expectation)
- C24 323 Fork gates table row "Governance Safe" (SafeL2 v1.4.1 migration, epoch 554) -- OOS int (R3 F10's author said not partner material; log 81 kept it)
- C25 325-326 mainnet "in force from genesis" statements -- OOS nl (mainnet not launched at the tag; a claim about a future genesis)
- C26 334 one-way stake-version opt-in, top-up/refund -- NH
- C27 338-340 membership-model paragraph (fixed stake, equal votes, random draw; grow by running more validators) -- PN (answers the MNO's investment question)
- C28 349-351 governance can burn the NFT to eject; stake moved to `Issuance`; address retired; slashing supported but unused -- PN (governance power over partner stake); slash half repeats 269-270
- C29 365 `Retired` status row -- NH
- C30 370 step 2: Ed25519 keys derived from BLS; PoP signing (optional precision) -- NH; repeats 477, 608
- C31 371 step 3: registry verifies PoP via the precompile; each BLS key accepted once (rider) -- NH
- C32 377-378 unstake before activation; claim rewards without exiting -- NH
- C33 385-387 how a delegation is formed (`delegateStake()`, EIP-712 digest, `delegationDigest()` / `tn_delegationDigest`, nonce, deadline) -- OOS op/int (procedure and API detail); a one-line "validator authorizes by signature" would do
- C34 423-424 observer does not batch; workers forward over RPC; no batch-gossip subscription -- NH
- C35 439-440 `tn_nodeMode` and `eth_syncing` mode reporting -- OOS op (monitoring)
- C36 449 "Transaction intake" capability row -- NH
- C37 456 "bulk sync streams" in the Networking overview -- NH
- C38 468 IPv6 multiaddr form; at most four advertised endpoints -- NH (operator-leaning)
- C39 471-473 5 s keep-alive, 30 s idle, handshake ceiling (rider on the 65 s correction) -- OOS int (numbers beyond what a partner needs)
- C40 480, 482, 484 12-hour republish; record timestamp and optional public RPC endpoint; signature binds chain id and role (riders) -- NH/int
- C41 493 chain id 2017 in topic names on Adiri -- NH
- C42 503-505 two-stage gossip validation, 12,000-byte cap -- OOS int
- C43 514 forwarding retention/retry ("missing from the next three consensus outputs") inside the planned subsection -- OOS int
- C44 525-526 decimal chain-id example; version skew costs no reputation -- NH/int
- C45 527-528 full protocol-id family (kad, sync, peer-exchange, record-exchange) -- OOS int
- C46 539 "1 MiB by default" -- NH
- C47 545-546 new peer starts at 0; five-minute half-life -- NH
- C48 554-555 penalty sizes; no-penalty faults -- NH/int
- C49 556 sync-stream failures recorded only in metrics -- OOS int
- C50 568 penalty counts to reach a ban -- NH
- C51 571-572 scoring exemptions (adjacent committees, trusted/bootstrap peers from node config); ban lifted on committee join -- NH; the config half is operator-leaning
- C52 574-577 layered refusal (address ban after >1 banned peer; post-handshake identity refusal) -- OOS int
- C53 578-579 admission control (QUIC Retry, 1024 pending handshakes, 8 connections per peer) -- OOS int
- C54 584 transactions use secp256k1 -- NH
- C55 592-593 min-sig variant, point sizes, hash-to-curve DST -- NH (BLS integrators)
- C56 597-599 119-byte PoP message layout; on-chain rebuild; `tn_proofOfPossessionMessage` -- NH; 599 is operator/integration how-to
- C57 601-603 BLS precompile ABI and gas cost -- NH; duplicates 148-149
- C58 617-621 seed-chain paragraph in Hashing -- repeats 279-284 (rider on the ch 9 randomness correction); trim to one sentence plus link
- C59 628-629 PoP intent prefix; node-record signing label -- OOS int
- C60 656-658 indirect verification details (leaves and every 50th round verified directly) (rider) -- NH/int
- C61 661 epoch certificates use the same threshold -- NH
- C62 664-665 committee keys from the registry; `tn_getCommitteeBlsPubkeys` / `tn_getBlsPubkey` -- NH (integration)
- C63 673-675 bootstrap from an exported state snapshot -- NH (live at the tag per WT/SYNC.md export/import)
- C64 682 "Position" check in Step 1 -- NH
- C65 693-694 newest record certified only after the next epoch begins -- NH; repeats 46-47
- C66 723 empty consensus output produces no block unless it closes the epoch -- redundant with 125-127
- C67 740 per-worker gas totals, leader counts from the consensus store, base fees from the previous closing block (rider) -- OOS int
- C68 742 restart exactly at a boundary re-derives the record -- OOS int
Totals: 68 items -- PN 5 (C14, C16, C23, C27, C28), OOS 18 (C6, C15, C17, C19, C24, C25, C33, C35, C39, C42, C43, C45, C49, C52, C53, C59, C67, C68), C21 carries the B1 error, the rest NH; 7 duplicate pairs (C2/685, C3/C65, C9/C57, C19/C28, C30/477/608, C58/279-284, C66/125-127).

## D. Mechanics (FINAL)

Passed:
- D0 exactly one `#` (1); ten `##` chapters in the original order (3, 14, 61, 131, 240, 328, 391, 454, 581, 667); every original `###`/`####` present except the logged rename at 613 (Hashing); the three added `###` at 210, 309, 508.
- D0 links: all four heading links resolve (76, 81, 208, 424); the only other link is the absolute GitHub URL at 12; no repo-relative link.
- D0 absent: `--observer`, `tn-txn`, `/telcoin-network/0.0.1`, any email or personal address, HTML tags, trailing whitespace, tabs, "Section N" cross-references.
- D0 one sentence per line in all prose; no type name (ConsensusHeader, EpochRecord, Batch, ConsensusNFT, IntentMessage, IntentScope, IntentVersion, AppId) inside a code span; no contract, function, field, status, mode, enum-variant, topic, protocol-id, RPC, constant or hex value left plain (scripted check q1/spans.py; the only plain hits are ordinary words "stake", "Any", "Staked validators").

Violations / inconsistencies (all cosmetic):
- D1 table delimiter style differs by half: `|---|` at 53, 160, 175, 187, 320; `| --- |` at 358, 445, 497, 561, 634, 646, 712.
- D2 multi-sentence list items: ch 4 wraps them onto 3-space continuation lines (226-227, 229-231); ch 6 keeps several sentences on one line (370-375). Inherited from TR.
- D3 apostrophes/quotes: curly at 136 (quotes), 294 ("worker’s") and 433 ("epoch’s"), straight everywhere else (e.g. 296 "worker's").
- D4 `Retired` (365) is the only status name left plain in the statuses table (deliberate per log 116, because the registry reports `Any` + `isRetired`).
- D5 function-call parentheses mixed: `concludeEpoch` / `applyIncentives` (206, 249, 274, 288) vs `concludeEpoch()` (373), `stake()`, `delegateStake()`; inherited from the original's own mix.
