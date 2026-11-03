status: done

# Checkpoint Q3 (render review of docs/partner/technical-specification/technical-specification.pdf, 38 pages)

Render dir: /private/tmp/claude-501/-Users-grant-coding-telcoin-tn-node-deployment/474df373-eb73-43be-adbe-ffcbd2a2657a/scratchpad/render-review
(p-01.png .. p-38.png at 72 dpi; orig/oNN.png = original pages at 72 dpi; cmp01/cmp02/cmp06/cmp13-15/cmp04/cmp10-11.png = original left, ours right; cmp-headfoot.png = header and footer at 200 dpi; glyphs.png = special glyphs at 200 dpi; spec.txt = pdftotext -layout)

## Completed sections
- render (38 pages; fonts embedded: Inter Regular/Medium/Bold and Geist Mono Regular/SemiBold only, no fallback font)
- pages 1-10 reviewed
- pages 11-20 reviewed
- pages 21-30 reviewed
- pages 31-38 reviewed
- side-by-side comparison: cover (p01 vs o01), contents (p02 vs o02), table page (p06 vs o06), chapter opening (p15 vs o13), intro/bullets (p04 vs o04), header/footer at 200 dpi
- pdftotext pass (layout text, word diff against the Markdown, special glyphs, link annotations)

## Verified OK (no action)
- cover: no header or footer, no white edge (artwork reaches all four edges), title, subtitle and meta block inside the card, meta readable, nothing clipped; mailto:devs@telcoin.org link annotation present on page 1
- header and footer on pages 2-38 only (37 header titles, 37 confidentiality lines, 37 page counters); counter reads "Page | 2 / 38" on p2 and "Page | 38 / 38" on p38
- confidentiality line reads exactly "Telcoin Association Confidential and Proprietary Information. 15 October 2026." on all 37 pages
- header band, header title (9pt at x72 y23), logo tab, hairline, footer pill and both logos within ~2pt of the original
- contents: 59 entries = 59 Markdown headings (## / ### / ####), three levels, only chapters numbered ("N." bold), every page number matches the page the heading is on, no wrapped entries, chapter blocks kept whole
- every chapter starts a new page (p4, 5, 7, 10, 15, 19, 23, 26, 31, 35); no heading at a page bottom; no empty page
- chapter h1 20pt, h2 14pt, h3 12pt, body 11pt/15.3pt: sizes and the gaps below headings match the original to <0.3pt
- tables: lavender header row, pale cells and white gutters on every table (p6, 11, 12 x3, 18, 20, 24-25, 27, 30, 33 x2, 36); split tables repeat the header and leave at least 2 rows each side (p11/12: 2 rows carried; p24/25: 4/3)
- nothing inked outside the 72-523pt text column on pages 2-38 (pixel scan); longest code-block line is 39 chars
- glyphs render correctly: ƒ (p5, p7), curly quotes (p10), × in Geist Mono (p13), · (cover), ^ in 10^8 (code, p13); no ligature characters, no soft hyphens, no automatic hyphenation (every line-end hyphen is a real one), no running header text leaking into the body
- numbered lists aligned (p13, p14, p20-21, p35)

## Issues

### p01 (cover)
- p01: should-fix: cover title is 30pt; the original "Telcoin Network" is 41pt bold (bbox 49.6pt high), top at 301pt (106.3mm) vs ours 285pt (.cover-title { font: 700 41pt/1.21 }; .cover-head { top: 106.3mm }; drop the stale "30pt / 126mm" comment: at 41pt the title is ~115mm and fits the card)
- p01: should-fix: cover subtitle is 14pt, original 16pt, and 27.5pt below the title (ours 15.7pt) (.cover .cover-subtitle { margin-top: 9.7mm; font: 500 16pt/1.21 })
- p01: nit: the original stretches the artwork to ~613pt wide (card right edge 475pt); ours keeps proportions (card edge 462pt), so the card is ~4.6mm narrower (only for an exact match: background-size: 216.2mm 297mm; background-position: 0 0)
- p01: nit (accepted by the plan, do not fix): the cover counts as page 1, so the contents page reads "Page | 2 / 38"; the original numbered the contents page as 1

### p02-p38 (running elements)
- p02+: nit: confidentiality line is 8pt; the original measures ~7.4pt (.run-conf { font-size: 7.5pt })
- p02+: nit: the original sets "Page | N / M" in Arial 10pt (thin bar); ours is Inter 10pt (taller "|") and its centre sits ~5pt lower in the pill (788pt vs 783pt) (optional: .run-page { padding-bottom: 3mm })
- p26, p27, p28: nit: body text reaches 719pt; the original never goes below ~713pt, so the last line nearly touches the confidentiality line (pdftotext even merges them on p27) (@page { margin-bottom: 44mm }, re-check pagination after)

### Lists
- p04, p07, p08, p09, p28, p29, p37: should-fix: the bullet "●" in Inter 11pt is 8.2pt across; the original's is 4.8pt (main ul > li::before { font-size: 6.5pt; line-height: 1; top: 4.6pt }, left stays -18pt; tune top so the dot centres on the x-height, ~281pt on p4)

### Tables
- p06: nit: the original sets the comparison table's first column (Unit, Linking, Content...) bold; ours is regular (**Unit** etc. in Markdown lines 54-59; the original's other tables were not bold, so leave the CSS alone)
- p11, p12, p20, p24, p27, p30, p33: nit: code-span labels in cells are Geist Mono 9.5pt inside 10.5pt Inter, so they read light and small next to the original's bold-italic Inter field names (accept as the plan's code styling, or td code { font-size: 10pt })
- p20: nit: every status in the first column is a code span except "Retired", which is plain Inter (Markdown line 365: `Retired`, if it is meant to read as a status name)
- p25: nit: page holds only the last 3 rows of the Capabilities table (header repeated) before chapter 8; the split rules hold, acceptable
- p27: nit: topic names break inside the code in the narrow first column ("tn-consensus-" / "output-" / "{chain_id}"); the original broke them too (optional: nowrap on that column)
- p30: nit: the Score column wraps "above / -20" and "-20 or / below" (wider column via nowrap on short cells, or shorter wording); negatives use hyphen-minus rather than U+2212 throughout chapter 8

### Pagination
- p10: nit: ~110pt blank at the page bottom because the "Repurposed Fields" h3 and its table move to p11 together (acceptable keep-with-next)
- p17: should-fix: ~190pt blank at the page bottom mid-chapter (text ends 533pt, content box ends 723pt): table { break-before: avoid } drags the last 3 lines of the long "Fork gates" paragraph (widows: 3) plus the header and first two rows (166pt) to p18 (add a one-line lead-in before the fork table in the Markdown, e.g. "The forks and their activation epochs on Adiri:", so only that line travels with the table)
- p22: should-fix: runt page: only the last 3 lines of "Delegation" and ~600pt of blank before chapter 7 (cut 3+ lines from chapter 6, e.g. one sentence in Lifecycle steps or Delegation; or main li { margin: 0 0 2.5mm } plus a trimmed sentence; re-check contents page numbers)
- p29: nit: ~150pt blank at the bottom because the 3-row reputation table and its lead-in cannot split; acceptable
- p38: should-fix: the document ends on a runt page holding only the last 3 lines of "Recovery after restart" (cut 3+ lines from chapter 10, or tighten list spacing on p35/p37 as for p22)

### Text and justification
- p31: should-fix: two badly stretched justified lines: "hashed to the curve with the domain separation tag" (the DST string BLS_SIG_BLS12381G1_XMD:SHA-256_SSWU_RO_NUL_ cannot break) and "Contracts can verify BLS signatures through a native precompile at" (the 42-char address follows) (reword so each long code token starts its sentence or sits in a code block; CSS overflow-wrap does not help because the token fits on the next line)
- p13, p15: nit: "applySlashes, and concludeEpoch on the ConsensusRegistry, then" justifies with very wide gaps (same cause; the original had the same effect with italics; reword or accept)
- p13: nit: the penalty formula code span `((10^8 - r)^2 × u) / 10^16` splits across lines after "^2" (accept, or move the formula into a code block)
- p28: nit: code spans break at "/" and inside "tn-" / "primary" in the protocol-name paragraph (accept)
- p05-p37: nit: inline code at 9.5pt Geist Mono has a ~17% smaller x-height than 11pt Inter, so identifiers look shrunken mid-sentence (code { font-size: 10pt } for inline code outside tables; keep pre at 9.5pt)
- p16, p24: nit: two curly apostrophes ("worker’s", "epoch’s", Markdown lines 294 and 433) in a document that otherwise prints straight ' (make them straight)

## Summary
- must-fix: 0
- should-fix: 7 (p01 title size, p01 subtitle size/gap, bullet size on all bulleted lists, p17 blank before the fork table, p22 runt page, p31 stretched lines, p38 runt last page)
- nit: 18 (one of them, cover counting as page 1, is accepted by the plan and not to be fixed)
- pages with must-fix items: none
