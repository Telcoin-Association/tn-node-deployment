status: done
agent: E (partner guide 1.14)
worktree: ~/coding/telcoin/tnd-v220-guide (docs/mno-guide-1.14 at 1e71337)

completed sections:
- S1 toolchain: image tn-pdf-2604 (arm64/aarch64), Dockerfile in
  <session scratchpad>/pdf-tools/Dockerfile
  (ubuntu:26.04 + apt pango/harfbuzz/poppler/git + venv weasyprint==70.0 + pandoc/minimal:3.14 binary).
  Versions: pandoc 3.14, WeasyPrint 70.0, Python 3.14.4, Pango 1.57.0-1, HarfBuzz 12.3.2-2,
  poppler/pdftotext 26.01.0, pydyf 0.13.0, fonttools 4.68.0.
  Run: docker run --rm -u 501:20 -e HOME=/tmp -v worktree:/w -v <main repo .git>:<same path>:ro -w /w
  (the .git mount lets git resolve the worktree, so the script's drift check works).
  Unchanged build: "PDF unchanged ... (81 pages)", sha256 a300d9a0...f995f0. Reproduces byte for byte.
- S2 guide edits (mno-node-guide.md), hunks at 330, 657-664 (new), 669, 855, 1845, 1860-1861:
  - Install methods, Docker row: fallback only "when the release list cannot be read".
  - Update the node, by-hand steps: "Signed releases start with v0.18.0-adiri; v0.17.0-adiri and
    older have no signed release." Steps checked on the real v0.18.0-adiri (SHA256SUMS lists the 5
    files; gpgv GOODSIG+VALIDSIG 95A3..AE47; tarball hash OK; dir name as written). --version not run.
  - Troubleshooting, Scripts and updates: two rows (NOSIG -> installer once; other reason -> retry).
  - Troubleshooting, Setup row "No release signing key ... / did not verify": clause to Scripts and updates.
  - AWS one-click: new paragraph + command for stacks launched before scripts-v2.2.0; line
    "nothing in this scripts release needs a change on it" -> "its resources need no change".
  - Left: ~604 "Telcoin publishes the template with every scripts release"; ~1847 mainnet row
    "take the release that launches mainnet with update-scripts.sh".
  - One-pagers/spec: no repeat of a changed statement.
- S3 metadata.yaml: version "1.14", date stays November 2026.
- S4 build: "Wrote ... (81 pages)", no warnings; page 1 "Version 1.14 · November 2026"; no legacy /
  Confidential and Proprietary / --observer in PDF text; pages 16, 27, 34, 71, 74 rendered and read;
  second build "PDF unchanged" (sha256 293ac5e3...3242f5).
- S5 git status: only metadata.yaml, mno-node-guide.md, mno-node-guide.pdf, tasks/ files.
  diff --stat: 3 files, 15 insertions, 6 deletions; PDF 495042 -> 497809 bytes.
