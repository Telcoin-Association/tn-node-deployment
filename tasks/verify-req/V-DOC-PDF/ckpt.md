status: done (tip d7c16b1; REPORT.md Write refused by the harness: full text returned in the hand-back for the orchestrator to save)

# V-DOC-PDF checkpoint

Worktree /home/drtnarg/coding/telcoin/tnd-req-v-doc-pdf at 2d91fa8 (base 01664cc).
Scratch: /var/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/46275ae3-5cf9-4f35-b799-c09950443243/scratchpad/v-doc-pdf/
  base/   the four PDFs at 01664cc (git show)
  txt1/   pdftotext -layout and plain of the three 2d91fa8 PDFs and the three 01664cc PDFs
          (poppler 22.12 in tn-pdf-tools). Stale once the PDFs are rebuilt.

Order: P2, P3, P4, then P1, P6, P5.

## Sections

- [x] P2 text assertions: DONE at d7c16b1. Harness extract_text.sh + check_text.py (layout for
      tables, -raw for prose: plain pdftotext drops line-end hyphens, "singlethreaded").
      80 PASS / 0 FAIL (scratch p2-run1.txt). Negative control on the 01664cc PDFs: fails as
      expected (old rows, hyperthread, 487, no 1.3/1.13 line). No finding.
- [x] P3 DONE at d7c16b1 (build_in_clone.sh; scratch clones p3-clone-a at /w, p3-second/deeper/dir/tnd-b
      mounted at /srv/another/checkout/path). Six builds (3 docs x tn-pdf-tools:pandoc-3.14 and
      tn-pdf-tools/3.8.3) all print "PDF unchanged" and are byte-identical to the committed PDFs;
      second path (3.14, all three docs): byte-identical too. Clones show no tracked change.
      sha256: testnet c2145ff1baf78bab6a0873dff09f308e1ca7a8921d24e5f520c4108d49fd3506,
      mainnet b7a7d8d04279b794fef3f98202404fc390bf68b5c30128fce0eae95004a0d458,
      guide 4a1881d30b0f00a9fa37c7fb87b79eff4e5053b0e52e386d7a26fbd338bf888f.
      01664cc sources (p3-clone-base; out p5-base-3.14, p5-base-383): both images give the same
      bytes as each other (testnet 1ca98017..., mainnet 8f343733..., guide 323202f2...), all
      three differ from the committed 1.2/1.12 PDFs ("toolchain drift"); compare in P5.
- [x] P4 DONE (check_blobs.sh): four PDFs regular, mode 100644, working blob = HEAD blob
      (guide 780f833b, testnet 2012447a, mainnet bcc9ad42, spec 1ed24b30); spec no change
      01664cc..HEAD, same blob. Also *.md, metadata.yaml and the five site assets = HEAD, no symlink.
- [x] P1 DONE (pdf_props.sh, scratch p1-props): guide 81 pages (base 79), one-pagers 1 page each,
      all A4 595.276x841.89, PDF 1.7. Info dict identical to 01664cc except Pages/File size:
      Title (the # heading), Subject (metadata description), Author Telcoin Association, Producer
      WeasyPrint 70.0, no dates, no XMP stream. Font sets identical to base (guide 6 Geist faces,
      one-pagers 5), all embedded subsets. No path/user name in info, XMP or uncompressed bytes;
      second-path build byte-identical proves no build path is embedded at all. No finding.
- [x] P6 DONE. theme.css / template.html cmp-identical across the two one-pagers and unchanged
      01664cc..HEAD (also assets/, build script). Markdown diff = exactly: rows to spec 3.1, the
      hyperthread bullet replaced by F2, QLC bullet dropped on both, testnet "Every node" gains
      "no QLC drives", mainnet "Every node" -> "swap off, time sync on, ext4 or xfs; none checked.",
      mainnet chain ID 487 (0x1e7) -> 731 (0x2db), version 1.2 -> 1.3. Round-trip bullets and the
      OS lines unchanged. PDF text delta (p6_sentences.py, -raw, 1.2 vs 1.3) shows the same and
      nothing else. Cut necessity (PARTNER_MD variants in p3-clone-a/p6var, 3.14 image):
      testnet with the 1.2 bullets -> 2 pages; mainnet with only the QLC cut -> 2 pages; mainnet
      with ranked cut 2 instead (one-line round-trip bullet) -> 2 pages (columns rebalance, the
      round-trip bullet moves left). So cut 3 was needed; skipping cut 2 is not a defect.
      Possible Info: mainnet "ext4 or xfs; none checked." drops "data directory on" and who checks.
- [x] P5 the look: DONE.
      Done: 01664cc sources built with both images = same bytes (p5-base-pandoc-3.14, p5-base-383).
      One-pagers from 1.2 sources: layout text identical and 110-dpi renders pixel-identical (ppm cmp)
      to the committed 1.2 PDFs. Guide from 1.12 sources: 79 pages, every page has the same
      characters (raw, whitespace removed) as committed 1.12; layout lines differ on 6 pages
      (15,18,26,28,60,67): 36 lines (69 removed+added, the coordinator's count). Commit-message
      claims confirmed. page_audit.py: 1.13 and 1.12 both: 72 contents entries all on the right
      page, footers Page N of M right, running headers right, no blank page; the same 6 headings
      stranded with 0 lines under them, each alone on its page (1 body line), next page starts
      with the section's table: 1.13 pp 18 (3.6), 63 (8.3), 67 (9.1), 70 (9.2), 73 (9.3), 77 (9.5);
      1.12 pp 17, 61, 65, 68, 71, 75. Pre-existing, not new. Rule: table break-inside: avoid
      (theme.css :208) with h2 break-after: avoid (:152) / table break-before: avoid (:209).
      Renders DONE. One-pagers 110 dpi vs 1.2: nothing clipped, rows one line, bullets balanced
      (testnet 3|4 lines, mainnet 3|3), callout, header, badge right. Bottom clearance above the
      footer strip: testnet 4.2 mm both; mainnet 5.1 mm (1.2) -> 2.5 mm (1.3) (Info).
      Guide 70 dpi (14 sheets) + zooms at 110 dpi: no lost column, no overflow, no clipped code or
      callout, contents right. Premature line breaks from the container (also in the 01664cc
      rebuild, absent from committed 1.12): p16 "command," alone, p27 "-o" split "pass -"/"o
      ProxyCommand", p30 "catches" alone, p69 "with an RPC"/"for the node's chain". Container:
      pango 1.50.12, harfbuzz 6.0.0 (Debian 12). Pandoc version: no effect.
- [x] REPORT: written; the Write of REPORT.md was refused, so its full text is in the hand-back.
      Findings: VP-1 Low (container premature line breaks guide pp 16, 27 '-o' split, 30, 69, 71),
      VP-2 Low pre-existing (6 headings alone on a page; table break-inside: avoid; experiment with
      break-inside: auto -> 69 pages, 0 stranded), VP-3 Info (mainnet bottom clearance 5.1 -> 2.5 mm),
      VP-4 Info (mainnet 'Every node' wording). Gates on own files pass.

Findings so far: none.
