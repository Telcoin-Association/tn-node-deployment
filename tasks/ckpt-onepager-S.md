status: done

# Unit S checkpoint: tools/build-partner-pdf.sh one-pager support

Completed sections:
- S1 script edit (git diff --numstat: 55 added, 21 deleted, tools/build-partner-pdf.sh only)
- S2 lints a-d
- S3 existing documents unchanged e-f
- S4 scratch cases g

Sections: S1 script edit, S2 lints a-d, S3 existing documents unchanged e-f, S4 scratch cases g

## S1 script edit
- Header: two new names, one-pager sentence (toc-depth: 0), metadata.yaml and
  template.html lines cover the one-pager, assets "shared by every document",
  legacy lint "(guide and one-pagers)", USAGE takes <document|--all> plus a list.
- usage(): two new document lines and a note (single page, no cover, no contents).
- DOCS: appends testnet-node-requirements mainnet-node-requirements.
- case "$DOC": MIN_PAGES/MAX_PAGES per arm (15/150, 15/150, 1/1); new arm
  testnet-node-requirements|mainnet-node-requirements (LINT_LEGACY=1,
  CONTACT_IN_MD=1, NEED_CONFIDENTIALITY=0); globals removed; readonly line extended.
- toc-depth lint accepts 0-3; messages name 0 to 3.
- pandoc: TOC_ARGS array (--number-sections --toc --toc-depth=N) only for 1-3,
  expanded with ${TOC_ARGS[@]+"${TOC_ARGS[@]}"}; option order unchanged.
- Page-count messages: "expected exactly N" when MIN_PAGES == MAX_PAGES; the
  15-to-150 messages are unchanged.

## S2 lints a-d
- a. `bash -n tools/build-partner-pdf.sh` (bash 5.3.9): rc=0.
  `docker run --rm -v <repo>:/w -w /w bash:3.2 bash -n tools/build-partner-pdf.sh`: rc=0.
- b. `git ls-files -z '*.sh' | xargs -0 bash tools/check-bash32.sh`:
  "check-bash32: clean, 197 file(s) scanned", rc=0.
- c. `shellcheck -x --severity=error` local 0.11.0: rc=0, no output.
  koalaman/shellcheck:v0.9.0 same flags: rc=0, no output.
  `shellcheck -x -f gcc` with no severity filter on `git show HEAD:` copy and on
  the new file (scratch unit-S/sc/): both 0 findings; normalised diff empty.
- d. `bash tools/check-network-hits.sh`:
  "check-network-hits: clean, 152 annotated hit(s) in 27 file(s) scanned", rc=0.

## S3 existing documents unchanged e-f
- e. container (`tn-pdf-tools`, pandoc 3.8.3, WeasyPrint 70.0), repo mounted at /w:
  mno-node-guide: "PDF unchanged: docs/partner/mno-node-guide/mno-node-guide.pdf (77 pages)", rc=0.
  technical-specification: "PDF unchanged: docs/partner/technical-specification/technical-specification.pdf (37 pages)", rc=0.
  `git status --short` afterwards: ` M tools/build-partner-pdf.sh`, `?? tasks/ckpt-onepager-S.md`,
  plus ` M tasks/plan.md` and `?? .claude/`, both present before this unit started (not mine).
  Later `?? tasks/spec-onepager-shared.md` appeared, written by another unit (not mine).
- f. `--help`: rc=0, Documents lists the four names plus --all.
  `no-such-doc`: rc=2, "error: unknown document: no-such-doc (known: mno-node-guide
  technical-specification testnet-node-requirements mainnet-node-requirements)".
  `--all` in the container: guide and spec "PDF unchanged" (77, 37 pages); then
  "error: docs/partner/testnet-node-requirements/testnet-node-requirements.md not found (repo root: /w)",
  same for mainnet; "error: --all: failed: testnet-node-requirements mainnet-node-requirements"; rc=1.
  git status unchanged (no build/ dir created for the absent documents).

## S4 scratch cases g
Scratch tree: /var/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/c2fde98a-9da7-45ca-a634-ce28b0feca98/scratchpad/unit-S/t
(script copy, assets copy, testnet-node-requirements/ with minimal md, metadata.yaml
toc-depth 0, template.html with mailto and $if(toc)$, A4 theme.css), mounted at /w.
- (i) short md: "Wrote docs/partner/testnet-node-requirements/testnet-node-requirements.pdf (1 pages)", rc=0;
  build HTML: 0 `<nav`, 0 `header-section-number`, 0 `id="TOC"`.
- (ii) long md: "error: .../build/testnet-node-requirements.pdf has 4 pages; expected exactly 1", rc=1.
- (iii) long md via PARTNER_MD: "warn: .../build/long.pdf has 4 pages (expected exactly 1; ignored for PARTNER_MD)", rc=0.
- (iv) toc-depth 4: "error: lint: .../metadata.yaml sets toc-depth '4'; it must be 0 (no contents), 1, 2 or 3", rc=1.
  no toc-depth: "error: lint: .../metadata.yaml has no 'toc-depth:' line (contents depth, 0 to 3; 0 for no contents)", rc=1.
- (v) toc-depth 2, short: "Wrote ... (1 pages)", HTML has 1 `<nav`, 2 header-section-number spans,
  toc-section-number 1 Hardware / 2 Network. Long md with toc-depth 2: "has 4 pages; expected exactly 1", rc=1.
- (vi) "Legacy" line: "error: lint: ... mentions 'legacy' (drop legacy material from the partner guide):", rc=1.
- (vii) no devs@telcoin.org: "error: lint: ... never mentions devs@telcoin.org", rc=1.
- Extra: HEAD script vs new script on a scratch mno-node-guide (unit-S/t2-head, t2-new)
  with a one-page md: error and PARTNER_MD warn output byte-identical
  ("has 1 pages; expected 15 to 150", "(outside 15 to 150; ignored for PARTNER_MD)").

## Open
- The legacy lint message still says "(drop legacy material from the partner guide)"
  for a one-pager too; left unchanged per the brief.
