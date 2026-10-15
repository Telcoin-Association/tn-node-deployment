status: done

# Checkpoint Q3r

Render dir: /private/tmp/claude-501/-Users-grant-coding-telcoin-tn-node-deployment/474df373-eb73-43be-adbe-ffcbd2a2657a/scratchpad/render-q3r/ (p-01.png..p-35.png, 72 dpi)
Tools: /private/tmp/claude-501/-Users-grant-coding-telcoin-tn-node-deployment/474df373-eb73-43be-adbe-ffcbd2a2657a/scratchpad/tools-q3r/extents.py (body ink extents y 62-728)
PDF: 35 pages, A4, WeasyPrint 70.0, CreationDate 15 Oct 2026.

## Completed sections
- render (35 pages)
- ink-extent scan: all body ink inside x 72-522 except p28 (71, check); short pages p04 (intro, ends 317), p09 (ends 370, ~13 lines before ch4), p18 (ends 269), p24 (ends 223), p35 (ends 115: likely runt last page)
- pages 1-10 read: cover OK at a glance; contents p2-p3 (two pages, every entry has a number); p4 intro; p5-6 arch + comparison table OK; p7-8 consensus; p9 13 lines before ch4 (fine); p10 precompile addresses now in a text block, fits the margin

- pages 11-21 read: p11/p12 Repurposed Fields table split 8/2 rows, header repeated; p12 Fixed/Unused + System calls tables fit; p13 pre-exec/epoch-boundary calls + gas penalty; p14 smart contracts (ends 601, before ch5); p15-16 ch5; p17 fork gates lead-in line present, page filled to 707, table split 2/3 rows with header repeated; p18 last 3 fork rows then ch6 on p19; p20 statuses table ("Retired" now code), lifecycle steps; p21 ch6 ends full page (former p22 runt gone)
- pages 22-35 read: p22-23 ch7, Capabilities table split 5/2 rows (p23/p24); p24 = 2 rows + 3-line paragraph then ch8 (nit, as old p25); p25-28 ch8 (p26 last line ink at 717pt, close to the confidentiality line, pre-existing nit); p28 single anti-aliased pixel at x71 is the "A" of a paragraph, not overflow; p29 DST in its own text block, precompile address/function in a text block: both read cleanly and fit (ink max x 522); p30 "Hashing" present; IntentScope table split 3/2 (p30/p31); p32-34 ch10; p35 = RUNT LAST PAGE (3 lines of "Recovery after restart")
- runt-page arithmetic p33-35: @page bottom margin 42mm -> content bottom 722.8pt; p33 table ends 661.5pt, the next 3-line paragraph ("Each execution block also records...") needs 15.3 + 3x15.3 = 61.2pt -> 722.7, misses by a hair and goes to p34; p34 ends 710pt; the 3 runt lines need ~46pt
- (e) running elements: header title and confidentiality line "...Information. 15 October 2026." on p2-p35 (34 each), none on p1; counter "Page | 2 / 35" ... "Page | 35 / 35" on every page 2-35
- fonts: Inter Regular/Medium/Bold, Geist Mono Regular/SemiBold, all embedded, no fallback; non-ASCII glyphs only ● (20 bullets), ƒ (2), × (2), · (cover): all render; curly apostrophes gone; no glyph boxes
- (d) no heading stranded at a page bottom (every h2/h3 has its text or table after it on the same page); table splits p11/12 8/2, p17/18 2/3, p23/24 5/2, p30/31 3/2, header repeated each time, no lone row; no empty page; no ink past 72-522pt
- (f) contents: 59 entries = 59 Markdown headings, every entry has a page number and all 59 match the page their heading is on (scripted check plus visual spot-checks of 10: Introduction 4, Repurposed Fields 11, Gas over-reservation penalty 13 [added], Fork gates 17 [added], Validator statuses 20, CvvActive 22, Transaction forwarding 26 [added], Peer scoring 28, Hashing 30 [renamed from "Keccak-256 hashing"], Recovery after restart 34)
- (c) cover (pdftotext -bbox, ours vs original p01.pdf): title 41pt, top 301.31pt (orig 301.32), height 49.61 (49.61), right edge 399.38 (399.32); subtitle 16pt, top 378.43 (378.38), height 19.36 (19.36); meta block (Version 1.1 · 15 October 2026 / Protocol v0.16.0-adiri / devs@telcoin.org) 10pt at 608-653pt, readable, inside the card (card bottom ~703pt); nothing clipped; logo colour identical (20,200,255) on cover and header at 200 dpi
- (b) p29: "Messages are hashed to the curve with this domain separation tag:" + DST in its own text block; "Contracts can verify BLS signatures by calling a native precompile:" + address/function text block; both lines justify normally, blocks end inside 522pt; p10 two-address block also fits
- (a) re-judged: fork-gates gap FIXED (p17 filled to 707pt, only the lead-in line travels with the table); runt page before a chapter FIXED (old p22 gone; shortest pre-chapter tails now p18 = 3 fork rows, p24 = 2 rows + 3 lines, p9 = 13 lines); runt last page STILL PRESENT (p35)
- step 3 side-by-side: cmp01.png (o p01 / our p1), cmp02.png (o p02 / our p2), cmp06.png (o p06 / our p6), cmp13.png (o p13 / our p15, ch5 opening), cmp-logos.png (200 dpi logos) in the render dir. Header title, header logo, footer pill, counter cap height, h1/h2 sizes and body measure match; differences: ours adds the cover meta block (by design), cover card ~4.6mm narrower (art kept in proportion, accepted in F2), comparison table first column regular where the original is bold, inline code instead of italics (plan styling), counter reads 2/35 on the contents page (accepted)

## Issues
- p13, p15: nit: "applyIncentives(), applySlashes(), and concludeEpoch() on the ConsensusRegistry, then" still justifies with very wide gaps; p15 also "After distributing rewards, the protocol invokes applySlashes() on the" (reword or accept; pre-existing)
- p35: should-fix: the document still ends on a runt page holding only the last 3 lines of "Recovery after restart" (cut at least one line from p33 above the "Verified hashes" table, e.g. in the "Because the network produces one epoch record per epoch" paragraph or the long Step 2 paragraph, so the 3-line "Each execution block also records..." paragraph fits back on p33 (it misses by ~0.1pt now) and p34 gains ~61pt; or cut 3+ lines on p34 (Step 3 / Security properties); a cut on p32 alone does not help unless it frees 35pt+ more there; re-check contents page numbers)
- p24: nit: page holds only the last 2 Capabilities rows (header repeated) and a 3-line paragraph before ch8 (acceptable; pulling it back needs ~5 lines cut from ch7, and a 1-line cut would leave a 3-line runt instead)
- p26: nit: last body line ink at 717pt, close to the confidentiality line (pre-existing; @page margin-bottom 44mm would fix but repaginates)
- p26: nit: code spans /tn-meshsub-{chain_id}/1.0.0 and topic names in the narrow first column break inside the token (pre-existing, accept)
- p13: nit: penalty formula code span splits after "^2" across lines (accept or move into a text block; pre-existing)
- p28: nit: Score column wraps "above / -20", "-20 or / below", "-50 or / below"; negatives use hyphen-minus (pre-existing)
- p06: nit: original sets the comparison table's first column bold; ours regular (pre-existing; **Unit** etc. in the Markdown if wanted)
- p18: nit: last 3 fork-gate rows alone on the page before ch6 (acceptable; table rules hold)
- p01: nit: cover card ~4.6mm narrower than the original because the art keeps its proportions (accepted in F2, do not fix)
- p02+: nit (accepted by the plan): cover counts as page 1, so the contents page reads "Page | 2 / 35"

## Summary
- must-fix: 0
- should-fix: 1 (p35 runt last page: 3 lines of "Recovery after restart")
- nit: 10 (p13/p15 wide justified gaps; p13 formula split; p24 short page before ch8; p26 last line close to the confidentiality line; p26 code tokens break inside; p28 Score column wraps; p06 first column not bold; p18 3 rows before ch6; p01 card width; contents page counted as page 2), all pre-existing or accepted
- fixed since Q3: cover title/subtitle size and position (match to 0.05pt), bullets, fork-gates gap (p17), runt page before ch7, stretched DST and precompile lines (now text blocks), "Retired" code span, curly apostrophes
- verdict: no must-fix; ready to commit once the p35 runt page is removed (cut 1+ line on p33 above the "Verified hashes" table, or 3+ lines on p34, then rebuild and re-check contents page numbers); commit as-is only if a 3-line last page is accepted
