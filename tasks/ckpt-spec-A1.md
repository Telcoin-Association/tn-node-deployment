status: done (commit 1 = 1331145)

# Checkpoint A1

## Completed sections
- Section 1 (move): git mv of 9 font files -> docs/partner/assets/fonts/geist/ and the five guide
  files -> docs/partner/mno-node-guide/ (all staged as R). theme.css: header path comment and
  build-dir comment updated, font url()s -> ../assets/fonts/geist/<file>, README pointer ->
  ../assets/README.md. template.html: no change needed (uses $asset-dir$/logos/...).
  metadata.yaml: line-1 path comment fixed, `toc-depth: 2` appended with comment;
  contact/version/date untouched.
- Section 2 (script): tools/build-partner-pdf.sh takes <doc>|--all; DOCS array; per-doc case sets
  LINT_LEGACY, CONTACT_IN_MD, NEED_CONFIDENTIALITY (spec: metadata must set confidentiality; PDF
  text miss only warns); _meta reader; lints toc-depth 1..3 and contact == CONTACT
  (support@telcoin.org); pandoc --toc-depth from metadata, -V asset-dir=../../assets; scratch in
  docs/partner/<doc>/build/; pdftotext-missing note; install hint adds poppler.
  Deviation: --all re-runs via "$BASH" "$SCRIPT_DIR/<self>" (file is mode 100644 and the script
  has cd'd to the repo root, so a bare "$0" would fail); --all plus a name also exits 2.
  Gates: /bin/bash -n + bash -n OK; check-bash32 clean; shellcheck -x --severity=warning: 0
  findings (all severities 0). _meta tested under /usr/bin/awk (BSD): quotes, trailing comment,
  nested key ignored. Usage errors all rc=2: no arg, bogus, two names, PARTNER_MD+--all,
  --all+name, --bogus; --help rc=0. `technical-specification` (not created yet): "error:
  docs/partner/technical-specification/technical-specification.md not found", rc=1.
- Section 3 steps 1-3: `build-partner-pdf.sh mno-node-guide` rc=0, 46 pages, WROTE the PDF (no base
  commit at the new path yet). vs HEAD PDF: cmp differs; pdfinfo 46/46; pdftotext -layout diff =
  104 lines, line wraps and layout-indent shifts only. Cross-check: old script in a HEAD worktree
  on the same toolchain gives a candidate PDF byte-identical to the new layout's (so the move
  changes nothing; the diff is pandoc 3.12 drift). Committed bytes restored (cmp equal).
  `--html-only` rc=0. Remaining: step 4 path refs, 5 stage, 6 commit, 7 post-commit checks.
- Section 3 step 4: README (callout links + "Docs move with the code" paragraph, reflowed), AGENTS.md
  (line ~20 path, Partner guide section path strings + rebuild command only), followup.md
  (theme.css path), .gitattributes `docs/partner/*/*.pdf binary linguist-generated=true` (check-attr:
  binary+linguist-generated for both docs), .gitignore `docs/partner/*/build/` (check-ignore: both
  build dirs ignored, a doc .md not). Dangling-path grep: only CHANGELOG.md history lines remain.
- Section 3 steps 5-7: staged explicitly; cached name-status = 9 fonts R100, 5 guide files R
  (pdf/md/template R100, metadata R081, theme R090), M script/.gitignore/.gitattributes/README/
  AGENTS/followup; nothing else. Commit 1331145 (no trailers). Post-commit:
  `git show -M --stat HEAD` PDF `Bin` 0 changes, name-status R100; `git log --follow` reaches
  7fb7c8d; in a clean HEAD worktree `build-partner-pdf.sh mno-node-guide` printed "warn: toolchain
  drift, keeping the committed PDF, pass --force", rc=0, porcelain empty, PDF bytes untouched.
  `--all --html-only` there: guide OK, spec "not found", "--all: failed: technical-specification",
  rc=1. Caveat: in the MAIN tree, A3's uncommitted files under the shared docs/partner/assets/ count
  as a SOURCES change, so a guide build there would WRITE the guide PDF until assets are committed.
