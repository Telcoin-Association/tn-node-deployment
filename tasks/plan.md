# Plan: refresh the MNO node guide to telcoin-network main 98849a221 and rebuild its PDF

Approved 2026-10-15. Branch `docs/technical-specification` (on top of 706a730). One commit,
no attribution trailer, no push. Facts, rules, decisions and the full edit lists are in
`tasks/spec-guide-refresh-facts.md`; checkpoints are `tasks/ckpt-guide-<unit>.md`.

## W0 Setup (orchestrator)
- [x] line numbers in the guide, OPERATOR.md and README.md match the plan
- [x] upstream citations re-read at 98849a221 (clock drift, recovery log lines, the
      `Cannot check database (epoch)` text, certifier, rejoin, worker RPC, network-config keys)
- [x] `tasks/spec-guide-refresh-facts.md`, `tasks/plan.md`, checkpoint stubs
- [x] baseline `bash tools/build-partner-pdf.sh mno-node-guide --html-only` passes on the
      untouched tree; `git status` clean apart from the known untracked files

## W1 Writers (two opus agents in parallel, disjoint files)
- [x] U1 guide-writer: items 1-11 on `mno-node-guide.md` and `metadata.yaml`, bottom-up;
      `--html-only` lint and anchor check pass; checkpoint `tasks/ckpt-guide-U1.md`
- [x] U2 ops-docs-writer: the OPERATOR.md and README.md list; `git diff --stat` touches only
      those two files; checkpoint `tasks/ckpt-guide-U2.md`

## W2 Verifier (one opus agent after W1)
- [x] U3 verifier: every changed or added sentence re-derived from telcoin-network at
      98849a221 (never from the writers' notes first); figures, log strings, key names, the
      `initiating node shutdown` outcome; no "next release"; lint; anchors; net growth <= 40
      lines; forbidden terms; the three files agree; findings in `tasks/ckpt-guide-U3.md`
- [x] orchestrator applies the fixes or sends them back to U1/U2

## W3 Close (orchestrator)
- [x] CHANGELOG.md "Unreleased": "Partner guide 1.4, October 2026" clause
- [x] followup.md: the triage list and the next-tag re-check
- [x] tasks/todo.md review section
- [x] `bash tools/build-partner-pdf.sh mno-node-guide` writes 46-48 pages, WeasyPrint log
      clean; second run prints "PDF unchanged"
- [x] pdftotext checks (required strings present, forbidden strings absent, cover shows 1.4)
- [x] page renders viewed: cover, Hardware per role, Optional node flags, Restarts and the
      epoch boundary, One-way updates, Watch your status, Sync and node mode, Service and keys
- [x] `pdfinfo`: ModDate 2026-10-15, Author Telcoin Association
- [x] `git status --short`: only the expected files; `gen-checksums.sh` reports no sidecar
      drift; the specification PDF and the telcoin-network checkout unchanged
- [x] commit `docs: guide 1.4 describes telcoin-network main: epoch restart recovery, clock
      drift, opt-in network-config keys` (no trailer)
- [x] memory `technical-specification-branch.md` updated
