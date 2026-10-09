# Checkpoint: Task B, partner guide source (docs/partner/mno-node-guide.md)

status: done (all 10 chapters written, all checks pass)

## Completed chapters

- [x] 1 Introduction (90 lines): intro prose, What this guide covers, Contact, Vocabulary, Roles are decided on-chain
- [x] 2 Before you start (83)
- [x] 3 Install (130)
- [x] 4 Confirm the node is syncing, then synced (59)
- [x] 5 Day-2 operations (123): --observer strip bullet dropped
- [x] 6 Public RPC (https and wss) (102): appendix pointer replaced by inline IMPORTANT note
- [x] 7 Validators: stake and activate (191): upstream-page remark replaced
- [x] 8 Automation (65): migrate row dropped; keygen/finalize split into two blocks with a link to Back up the keys now
- [x] 9 Troubleshooting (53): legacy rows + migrate clause dropped; 22 rows grouped into 5 three-column tables
- [x] 10 Getting help (13)
- [x] Final checks

## Check results (final)

- forbidden-strings grep: empty
- `^# ` count: 1 (code-block comments moved to trailing comments so the build lint's plain grep sees 1)
- manual numbering in headings: none
- "section N": none
- code lines > 90: none
- support@telcoin.org: 5
- 28 unique `](#slug)` links, all resolve against 58 headings; no duplicate heading slugs
- 14 absolute GitHub links (README x11 fragments + root, WGVPN.md, docs/testnet-addons.md x2)
- pandoc 3.11 gfm -> html5 with --shift-heading-level-by=-1: 0 unresolved href="#", 5 alert divs, 0 math spans, 10 chapter h1
- parity: every inline-code token and code line from OPERATOR.md sections 0-7, 9, 10 is present except deliberate legacy drops and wrapped long lines
