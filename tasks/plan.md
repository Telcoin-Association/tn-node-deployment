# Plan: Telcoin Network Technical Specification as a version-controlled partner document

Approved 2026-10-15. Branch `docs/technical-specification` off `main` (037c810). No push.
The full plan text (context, decisions, agent table) is in the session transcript; this file
is the checklist the orchestrator ticks. Checkpoints: `tasks/ckpt-spec-<unit>.md`.

Abbreviations: `P` = `docs/partner`, `TS` = `docs/partner/technical-specification`,
`S` = scratchpad `spec/` (extracted text, page renders, images),
`WT` = scratchpad worktree of telcoin-network at `v0.16.0-adiri` (d72cc2bc, tn-contracts 10cc12b7).

## W0 Setup (orchestrator)
- [x] branch `docs/technical-specification`
- [x] `brew install pandoc weasyprint poppler` (pandoc 3.12.1, WeasyPrint 70.0, poppler 26.10.0)
- [x] worktree `WT` at the tag, tn-contracts submodule initialised
- [x] `.claude/project-context.md` written (untracked)
- [x] baseline: current script on pandoc 3.12.1 reports toolchain drift on the guide PDF
      (text differs only in line wraps; 46 pages); anti-churn keeps the committed PDF
- [x] `tasks/plan.md` + checkpoint stubs

## Wave 1
- [x] A1 guide `git mv` to `P/mno-node-guide/`, Geist to `P/assets/fonts/geist/`, new build
      script (document name / `--all`), `.gitignore`, `.gitattributes`; commit 1 with the PDF at R100
- [x] A3 assets: Inter v4.1 (6 faces + LICENSE), `telcoin-network-dark.svg`,
      `telcoin-association-dark.svg`, cover PNG, README rows
- [x] T1 transcription: title, chapters 1-5, spec `metadata.yaml`
- [x] T2 transcription: chapters 6-10 fragment
- [x] G1 gate: 10 `##`, 11 tables (4+7), snapshot `S/md/transcription.md`

## Wave 2
- [x] A2 README, AGENTS.md ("Partner documents"), followup.md; email -> devs@telcoin.org in the
      guide, metadata 1.3 / 15 October 2026, script `CONTACT`; rebuilt guide PDF; commit 2
- [x] V1a spec template + page chrome CSS (cover, header band, footer pill, confidentiality)
- [x] R1 ch 2-3 findings
- [x] R2a ch 4 (minus contracts) findings
- [x] R2b ch 5 findings
- [x] R3 ch 6 + ch 4 contracts findings
- [x] R4 ch 7, 10 findings
- [x] R5a ch 8 transport/discovery/topics findings
- [x] R5b ch 8 request-response/peer scoring findings
- [x] R5c ch 9 findings

## Wave 3
- [x] V1b body CSS (Inter 10.5pt, chapter numbering, lavender tables, 3-level TOC)
- [x] C1 + C2 consolidators (ch 1-5, scratch copy refresh-a.md, log -a) / C2 (ch 6-10, refresh-b.md, log -b);
      orchestrator joins, installs, bumps metadata 1.1 / 15 October 2026 / `protocol: v0.16.0-adiri`,
      concatenates `tasks/ckpt-spec-refresh-log.md`
- [x] G2 gate: spec PDF builds (38 pages, empty WeasyPrint log)

## Wave 4 review
- [x] Q1 fidelity (0 transcription defects, log complete, 68 scope additions triaged in tasks/spec-triage.md)
- [x] Q2a/b/c technical disproof + stale sweep
- [x] Q3 render review (0 must-fix, 7 should-fix, 18 nits)
- [x] triage (tasks/spec-triage.md)

## Wave 5-6
- [x] F1 content fixes (Q1/Q2a/Q2b/Q2c applied; 738 lines)
- [x] F2 render fixes (cover 41pt/16pt, bullets, footer geometry; stretched lines handed to F1)
- [x] Q3r re-check (0 must-fix; the last runt page fixed by the orchestrator; 34 pages)

## W7 Finish
- [x] CHANGELOG.md Unreleased clause (drafted; page count not stated)
- [x] commits: 1331145 move, 9a0f5d3 assets, 6010ed3 contact, 924fa0c spec, 10b666e staged stylesheet, then changelog + tasks; paths staged explicitly
- [x] end-to-end verification (see tasks/todo.md review section)
- [x] `tasks/todo.md` review section; `tasks/lessons.md` orchestration lessons
- [x] `git worktree remove` of `WT`
