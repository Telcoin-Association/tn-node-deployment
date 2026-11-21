status: done

# ONEPAGERS checkpoint (node requirements one-pagers 1.3)

Worktree /home/drtnarg/coding/telcoin/tnd-req-onepagers, branch req/onepagers, tip 7a686dc.
Scratch: /var/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/46275ae3-5cf9-4f35-b799-c09950443243/scratchpad/onepagers/
(build.sh there: builds one page in the container, writes build/cand.txt and build/cand-1.png)

Sections:
- [x] 1. step 0 baseline
- [x] 2. testnet page
- [x] 3. mainnet page
- [x] 4. cuts applied, in order, with build result after each
- [x] 5. builds and gates
- [x] 6. pages looked at
- [x] 7. commit

## 1. Step 0 baseline (pandoc 3.8.3 + WeasyPrint 70.0 in tn-pdf-tools, unchanged sources)

- Committed PDFs (pandoc 3.14) copied to scratch/committed/; container builds of the
  unchanged sources to scratch/baseline/.
- Both build "Wrote ... (1 pages)" (the script's git lookup gives no base inside the
  container, so it writes instead of warning "toolchain drift").
- pdfinfo: 1 page, A4, WeasyPrint 70.0, all four.
- PDF bytes differ (testnet 48004 vs 48049, mainnet 48375 vs 48408).
- pdftotext -layout identical; pdftoppm -r 110 PNGs byte-identical, both pages.
- Finding: pandoc 3.8.3 alone changes only PDF bytes, nothing visible or textual.
- Both PDFs restored with git checkout.

## 2. Testnet page (FINAL: fold version)

- Rows: the five testnet rows of spec 3.1, cell for cell. Hyperthread bullet -> F2 verbatim.
  metadata version 1.3. No chain-config/default-branch/pull statement on the page: none added.
- First build: 2 pages. F2 wraps to 3 lines in the half-width list column ("cores." alone),
  list 4 -> 5 lines; the left column's last 2 lines spill. F2 does not fit in two lines.
- Coordinator (option B): keep QLC on testnet; order (2) RTT, (3) Every node, (4) drop QLC.
  - (2) RTT "A validator also needs a p95 round-trip time well below 1 second to at least 7
    of the 10 committee members." -> "A validator also needs p95 round trips well below 1 s
    to at least 7 of the 10 committee members.": 2 pages (still 2 lines).
  - (3) Every node "... data directory on ext4 or xfs; ..." -> "Every node: swap off, time
    sync on, ext4 or xfs; the scripts check none of these.": 2 pages (still 2 lines).
  - (4) QLC bullet dropped: 1 page.
  - (2),(3) reverted, only QLC dropped: 1 page, same layout (they bought nothing).
  - Coordinator's last try, committed if it fits: QLC bullet dropped and folded into Every
    node: "Every node: swap off, time sync on, data directory on ext4 or xfs, no QLC drives;
    the scripts check none of these." RTT original. RESULT: 1 page, bullet 2 lines, list 4
    lines, everything below the list at the baseline positions (bbox identical: IMPORTANT
    313.57, Network 337.88, last left line 785.42) and pdftotext below the list identical
    to baseline. -> this version is the one to commit.

## 3. Mainnet page (FINAL: cuts 1 and 3)

- Rows: the six mainnet rows of spec 3.1. F2 verbatim. Chain ID row 731 (`0x2db`).
  metadata version 1.3; badge "Mainnet · not launched" names no chain id.
- No cell wraps (recommended "16 cores (32 vCPU), 64 GB ECC RAM" is one line): theme.css
  column widths stay. CPU format N cores (2N vCPU) everywhere; no fallback.

## 4. Cuts (mainnet), in order

- No cut: 2 pages (left column's last paragraph, 3 lines, spills).
- Cut 1, QLC bullet dropped ("Avoid QLC drives: they wear out under continuous chain
  writes."): 2 pages.
- Cut 2, RTT bullet "A validator also needs a p95 round-trip time well below 1 second to a
  quorum of the committee." -> "A validator needs a p95 RTT well below 1 s to a committee
  quorum." (wrapped, 2 pages) -> "Validators: p95 RTT well below 1 s to a committee quorum."
  (one line; 2 pages: WeasyPrint balanced F2+RTT | Every node, 4 lines tall).
- Cut 3, Every node "Every node: swap off, time sync on, data directory on ext4 or xfs; the
  scripts check none of these." -> "Every node: swap off, time sync on, ext4 or xfs; none
  checked." -> 1 PAGE. Cuts 4 and 5 not applied. (The line is full: "checked." ends at
  x 554.6 of 555.6.)
- Then tested cut 2 reverted (cuts 1+3 only): 1 page, list 3 lines (F2 | RTT 2 + Every 1).
  Coordinator: commit cuts 1 and 3 only; cut 2 tried, saved nothing once cut 3 was in,
  reverted. Final positions: IMPORTANT 371.43, Network 395.73, last left line 790.08
  (baseline 783.29); content bottom 807.87.

## 5. Builds and gates

- Second build of each: "PDF unchanged ... (1 pages)"; sha256 testnet c2145ff1...,
  mainnet b7a7d8d0... unchanged; build gates passed (one page, no forbidden word/legacy).
- scratch/check.py on pdftotext output: every spec 3.1 cell of each table, exactly those rows
  in order; Version 1.3 · November 2026; Ubuntu 26.04 LTS (recommended); grep -c 26.04 = 1
  per .md; no hyperthread wording; every vCPU figure is N cores (2N vCPU) with 2N = 2 x N
  (6 of 6 per page); mainnet 731 (0x2db), no 487 / 0x1e7 / "Storage, every role"; testnet
  2017 (0x7e1), no "2 TB". F2 verbatim checked from the -layout text (plain pdftotext
  dehyphenates "single-|threaded" to "singlethreaded"; the PDF keeps the hyphen).
- theme.css and template.html: cmp identical (unchanged). build/ is gitignored.

## 6. Pages looked at

- Both final renders at 110 dpi, plus the mainnet bottom at 200 dpi: nothing clipped, every
  table row one line, columns balanced. Testnet: everything below the list at the baseline
  positions. Mainnet: content below the table 6.8 pt lower than baseline (one row added, one
  list line saved); last left line clears the footer strip. F2 ends with "cores." alone on
  its third line on both pages (verbatim sentence; unavoidable at this width).

## 7. Commit

- 33ad64b "ONEPAGERS: node requirements one-pagers 1.3" (6 files: both .md, metadata.yaml,
  .pdf). No attribution lines. Checkpoint not committed.

