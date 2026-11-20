status: done (VC verifier, branch docs/run-telcoin-network-links 93f3969) -- verdict PASS WITH NOTES
harness: /var/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/9e8efab4-ccd8-4e70-8b1b-387187e040a7/scratchpad/vc/harness
clone restored: docs/run-telcoin-network-links at 93f3969, worktree/index clean, ignored build/ dirs removed

## Finished checks
- 1 scope: PASS. 9 files exactly; guide blob 4846a88 and spec blob 1ed24b3 same at base/HEAD; no tools/, .github, template, css changes. (c1-scope.sh exit 0)
- 2 reproducibility: PASS. 0e7053b and 93f3969 both exit 0, 4x "PDF unchanged" (77,37,1,1), status clean. Container pandoc 3.8.3 / WeasyPrint 70.0. (c2-repro.sh exit 0)
- 3 PDFs at HEAD: PASS. 1 page each; "Version 1.1 · November 2026" on p1; guide annotation exactly https://run.telcoin.network/guide; no mno-node-guide link/text; devs@ present; other URLs (mailto, copy.fail, repo URL) all at base. (c3-pdf.sh exit 0)
- 4 nothing else changed: PASS. layout+raw diffs only version line + Contact sentence; pixel diff 90dpi only y99-107 and y~955-1003 x371-685; visual OK. (c4-render.sh, c4-pixdiff.sh)
- 5 md/yaml diffs: PASS. (c5-mddiff.sh exit 0)
- 6 site build: PASS. exit 0; 1.1/1.1/1.9/1.3; source_tree a6d248b == HEAD:docs/partner; sha256 4x OK; cmp 4x. (c6-site.sh exit 0)
- 7 site statements: PASS WITH NOTES. Mutations: M1 gate 4 exit 1, M2 gate 5 exit 1, no out. Notes: gate-3 formats + shared assets not mentioned; "partner PDF" trigger vs tree check; no git fetch; "renamed" vs "renamed or removed"; marking any case.
- 8 form: PASS. l9 prefix-preserved, 5 autolinks render (pandoc gfm 5->10 links); paragraph width <=96; AGENTS fence inside li; CHANGELOG ASCII, width 96 vs 95; no line numbers. CI: ci.yml/integration.yml on all PRs, no path filters; local network-hits + 6 tests pass.
- 9 commits: PASS. No trailers/AI names; claims match results; unsigned like prior commits.
- 10 short links: PASS locally (http.server 301 /guide -> /guide/; stub url=../mno-node-guide.pdf). GitHub Pages unproven.

## Live state on 2026-11-20
- gh: Telcoin-Association/tn-partner-site does not resolve; run.telcoin.network -> 216.150.1.65/.129 (wildcard), /guide 404.
