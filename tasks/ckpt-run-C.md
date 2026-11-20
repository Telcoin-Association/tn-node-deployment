# ckpt-run-C

status: done

## Finished sections

- 1. The one-pagers: sentence replaced in both .md (no other line), both metadata.yaml 1.0 -> 1.1.
  New sentence: "The full operator guide is at [run.telcoin.network/guide](https://run.telcoin.network/guide)."
  "in the repository below" dropped: the footer strip (template.html) still prints the repo URL.
  Cross-doc grep: only these two sentences link a partner PDF; guide and spec have none.
  README.md line 9 links the four PDFs relatively (kept).
  Link lint: FORBIDDEN fixed strings reject repo-relative targets (`](README.md`, `](docs/`,
  `](WGVPN.md`, `](OPERATOR.md`) in Markdown and PDF text; `href="#..."` must match an id;
  no host check on absolute URLs, so run.telcoin.network is neither rejected nor special-cased.
- 2. Rebuild: baseline --all on 9da2a07 = 4x "PDF unchanged" (77, 37, 1, 1). Both one-pagers
  built "Wrote ... (1 pages)"; then --all = 4x "PDF unchanged"; git status docs/partner = only the 6 files.
  Checks (both): 1 page; p1 line "Version 1.1 · November 2026"; text has run.telcoin.network/guide;
  pdfinfo -url: one annotation https://run.telcoin.network/guide (old had 2 for the wrapped github blob URL);
  no github blob mno-node-guide.pdf; devs@telcoin.org x3; no Confidential and Proprietary.
  Text diff old/new: only version line + Contact sentence (3 lines -> 2). PNGs read: no clipping,
  footer same, link now plain underlined like devs@telcoin.org (old was code-styled).

- 7a. Commit 1 = 0e7053b (6 files); --all on it = 4x PDF unchanged (log scratch/c/commit1-all.log).
- 3. README.md: line-9 note gains one sentence (four short links as full URLs); maintainer paragraph gains
  short-link rule, Publish command, source_tree check (inserted after the AGENTS.md pointer). Not committed yet.
- 4. AGENTS.md: links bullet gains short-link sentence; two new bullets after "Commit the PDF" (serving/Publish/source_tree; site gates, build-site.sh, short links never renamed). Not committed yet.
- 5. CHANGELOG entry added (ASCII only).
- 7b. Commit 2 = 93f3969 (README.md, AGENTS.md, CHANGELOG.md); --all on it logged in scratch/c/commit2-all.log.
- 7c. Final: log 9da2a07..HEAD = 93f3969, 0e7053b; status only tasks/; --all on 93f3969 = 4x PDF unchanged (77,37,1,1);
  HEAD:docs/partner = a6d248bef3e9ab15ce1bdba978fa62da1028ffec; diff --stat 9 files, +55 -7. Not pushed.

## Notes
