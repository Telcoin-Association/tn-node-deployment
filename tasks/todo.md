# Review — Technical Specification as a partner document (2026-10-15, branch docs/technical-specification)

Nothing is pushed. Branch `docs/technical-specification` off `main` (037c810), six commits:
1331145 (guide moved to `docs/partner/mno-node-guide/`, fonts to `assets/fonts/geist/`, build
script by document name, PDF carried over at R100), 9a0f5d3 (Inter v4.1, two light-background
logos, cover art, assets README), 6010ed3 (partner contact devs@telcoin.org, guide 1.3 dated
15 October 2026 and rebuilt, AGENTS.md "Partner documents", README pointer), 924fa0c (the
specification: Markdown, metadata 1.1 / 15 October 2026 / protocol v0.16.0-adiri, template,
theme, 34-page PDF), 10b666e (the build stages each theme beside the HTML with raster images
inlined, so the PDF bytes do not depend on the checkout path), and the commit carrying this
file, the CHANGELOG clause and the task files. No attribution trailers. The original Google
Docs PDF stays untracked at `docs/Telcoin Network Technical Specification.pdf` for the user to
delete after sign-off; `.claude/project-context.md` stays untracked.

## What landed

- `docs/partner/technical-specification/technical-specification.md`: 738 lines, the ten
  chapters of the April 2026 document in their order, 59 headings, 12 tables, three added
  subsections (Gas over-reservation penalty, Fork gates with the six armed Adiri epochs,
  Transaction forwarding), one renamed section ("Keccak-256 hashing" to "Hashing": consensus
  digests are BLAKE3). Every change from the faithful transcription is logged with a code
  citation at the tag in `tasks/ckpt-spec-refresh-log.md` (parts A, B and C).
- The refresh corrected, among 108 stale statements: the committee drawn at the close of epoch
  N serves epoch N+3 and the node, not the contract, does the draw from the seed chain; the
  leader commit rule is f+1; four epoch-boundary system calls, 100M gas each; `mix_hash` carries
  the seed-chain PREVRANDAO; four gossip topics with committee publishers and no transaction
  topic; role-specific request-response ids `/tn-primary-{chain_id}/0.0.2`; three reputation
  levels with a ban at -50; node modes derived from committee membership, `CvvInactive`
  carrying over; `final_state` only pins a pack's start state; the fixed-stake membership model,
  rewards weighted by leader rounds, exit over three committees; every node holds a BLS key with
  derived Ed25519 network keys. The intent-scope table gains `EpochCloseSeed`.
- The toolchain on this Mac is pandoc 3.12.1, WeasyPrint 70.0, poppler 26.10.0 (installed this
  session). The guide PDF was rebuilt once for the contact change; a word-level diff against the
  pandoc 3.12 baseline showed only the address, version and date tokens.

## Verification

- `bash tools/build-partner-pdf.sh --all` in a worktree at another path: "PDF unchanged" for
  both documents, `git status --porcelain` empty; the same in the main tree. Before 10b666e the
  specification reported "toolchain drift" from any other path, because WeasyPrint names image
  objects after the md5 of the image URL.
- Script: `/bin/bash -n`, `bash -n`, `tools/check-bash32.sh`, `shellcheck --severity=warning`
  all clean; usage errors exit 2 (no argument, `bogus`, two names, `--all` with a name or with
  `PARTNER_MD`, an unknown flag); anti-churn in a scratch clone: a perturbed PDF gives
  "toolchain drift" and exit 0, `--force` writes, a Markdown edit writes and warns to bump the
  metadata.
- Specification PDF: 34 pages, empty WeasyPrint log, cover with no header or footer, header and
  footer on pages 2 to 34, "Page | 2 / 34" and "Page | 34 / 34", the confidentiality line with
  the date on every page, `mailto:devs@telcoin.org` on the cover, three-level contents with only
  chapters numbered, all 59 entries matching their pages; text contains v0.16.0-adiri and the
  `/tn-primary-` ids and none of `/telcoin-network/0.0.1`, `--observer`, `tn-txn`, personal
  addresses or "mainnet".
- `.gitignore` `docs/partner/*/build/` and `.gitattributes` `docs/partner/*/*.pdf` verified with
  `git check-ignore` and `git check-attr`; `git log --follow` on the guide PDF reaches 7fb7c8d;
  `git diff -M --stat` shows the move commit's PDF as a pure rename; no `.sha256` changed; the
  only references to the old partner paths are historical CHANGELOG lines.
- Reviews: fidelity (Q1) found no transcription defect and a complete log, and classified 68
  additions beyond the corrections (5 partner-needed kept, 18 out of scope dropped, 7 duplicate
  pairs resolved); technical disproof (Q2a/b/c, fresh agents against the code) found 5 wrong and
  36 imprecise statements among 151 checked, all applied; render review (Q3, Q3r) found no
  must-fix item, the one remaining runt page was removed by tightening one sentence.

## Out of scope, for the user

- `support@telcoin.org` remains in README.md (6), OPERATOR.md (12), `setup-node.sh`,
  `check-node.sh` and `update-scripts.sh` (1 each; those three are updater-tracked and need
  version bumps, sidecars and a changelog entry if changed), and in three historical CHANGELOG
  lines.
- Two telcoin-network docs disagree with the code at the tag and could be fixed upstream:
  `docs/src/network/discovery.md` (a record holds up to 4 addresses, not 1) and `SYNC.md:51`
  ("headers include certificates"; the sub-DAG stores headers without signatures).
- The cover counts as page 1 (the original numbered the contents page as 1); the cover card is
  about 4.6 mm narrower than the original's; the first column of the three-chains table is
  regular weight where the original is bold.

# Review — followup.md backlog round (2026-10-01 19:20 → 2026-10-02, three repos)

Nothing is pushed. `main` is 42 commits ahead of `origin/main` (`7fb7c8d..6622d1e`; the release
commit is e5e7f4f, followed by the fixes from the whole-range review); tn-5 has the
branch `docs/operator-docs-backlog` (13 commits on `origin/main` f47a2603); devnet-genesis `main`
is one commit ahead (`e732765`). Docker was unavailable for the whole session; the real-binary
tests ran against a v0.15.0-adiri build made from `git archive` of the tag and against the
pre-v0.15.0 debug build in `tn-4`, and the Caddy floor against a downloaded 2.8.4 binary.

## What landed (tn-node-deployment)

- lib/common 1.6.0, lib/fallback 1.0.3: URL and release checks, JSON-RPC and epoch helpers,
  `tn_wait_restart_window`, strict stake decode on the real struct layout, launch-file editing
  with a shell-aware tokenizer, keytool and node-info helpers, physical cores, flock release
  that survives orphans, CRLF-tolerant `.node-meta`, `tn_node_parse_check` that never echoes
  the value (commits 1e2d2f1, d1593ae, 2c423dc, 8185d00, ea86e22, aa65fc3, 20ad47a).
- setup-node 1.3.0 (9df76cb, 16123b8, 8c69378, babb69d, 509bedb), edit-config 1.3.0 (9ff00af,
  59d10a0, 48a4c42), update-node 1.2.0 (e28e8e5, f9c47df, 12e58f4), install-caddy 1.4.0
  (7acc653, a051680), check-node 1.2.0 (c7a9690, 823e149), firewall-setup 1.6.0 +
  observability (5eb98b4, 1540751), prepare-stake 1.0.0 (f918d4f, 77e043b), remove-node 1.2.9,
  migrate 1.2.1, the lint and updater (78d9f46, eb73857, 3c78a6d, 13f6309), UI 1.9.0 (2025ea3,
  0c8aacf, 8feb576), CI (0b54c64), docs (d48270b), release update-scripts 1.1.70 (e5e7f4f).
- Security fixes found by the verifiers, not in the original backlog: unquoted shell
  metacharacters accepted into a root-run wrapper; a peers-file path that echoed a root-only
  file's first line through the UI (and the probe exposing the map in `ps`); check-node's
  header parser `eval`ing strings from the RPC answer; the updater installing files whose
  sidecar was missing and relaunching an unverified copy of itself; a passphrase inherited by
  every child of prepare-stake; the flock kept by orphaned children after SIGTERM; a config
  save interrupted during the epoch wait left on disk unapplied; prompt answers such as
  `9101;id` written into the start wrapper.

## Verification

- 9 independent Opus verifiers with their own harnesses (V-L, V-UP ×2, V-CORE-1, V-CORE-2,
  V-UI, V-OPS-1, V-OPS-2, V-DOC); every error-level finding fixed and re-tested, warns fixed
  unless recorded in followup.md.
- Final sweep against HEAD, both bashes: library 794 + 427; update-node 683 + 35; setup-node
  726; edit-config 858; install-caddy 176 + 245 JSON + 60 live Caddy (2.8.4 and 2.11);
  check-node 614 + 7; firewall 178; observability 229; prepare-stake 266 + 264 + 123; migrate
  45; lint 86 fixtures under BSD awk and mawk; UI 135 Python tests + 205 helper checks. Live
  read-only checks against rpc.adiri.tel matched `cast` throughout. (Sweep output:
  `<scratchpad>/final-sweep-2.txt`.)
- Tree gates: parse under both bashes, shellcheck error level, lint under both awks, zero sidecar
  drift, every changed tracked file bumped, zero trailers in three repos.
- Code review: see below.

## Deferred

`followup.md` (84 items, each with why and source). The largest: multi-worker provisioning,
the ownership of `/opt/telcoin` and `/etc/telcoin` by the service user (security, with the
recommended fix), the UI's fixed firewall toggles and missing inputs for the new edit-config
fields, `--help` gaps, the fleet Caddy items in the maintainer repo, the upstream PR.

## To push (user)

```
cd ~/coding/telcoin/tn-node-deployment && git push origin main
cd ~/coding/telcoin/tn-5 && git push -u origin docs/operator-docs-backlog   # then open the PR and run make attest on its head SHA
cd ~/coding/telcoin/devnet-genesis && git push origin main
```

The partner PDF's links to `blob/main/prepare-stake.sh` and the new README anchors resolve once
tn-node-deployment is pushed.

## Code review (/code-review high over origin/main..HEAD, 2026-10-02)

Eight findings, all real; seven fixed, one recorded.

| # | Finding | Outcome |
|---|---|---|
| 1 | `tn_wait_restart_window` slept in the foreground, deferring every caller's signal trap by a poll interval; the UI's kill then orphaned a root script holding the update lock | fixed, dd898c3 (sleeps run in the background with `wait`) |
| 2 | `prepare-stake --rotate-address` held the update lock at the interactive passphrase prompt | fixed, 23eb06c (passphrase first, lock after) |
| 3 | `network_stake_status` blocked the UI's request thread for 3–6 s per cache expiry when the public RPC was slow or down | fixed, 504aad4 (chain-id cache, endpoint back-off, refresh on one background thread; 135 tests) |
| 4 | the updater worded a checksum download error as "no checksum available" | fixed, 3682e5a |
| 5 | stale `lib/fallback.sh` comment naming a caller that no longer exists | fixed, dd898c3 |
| 6 | the updater left `lib/*.sh.tmp` behind on Ctrl-C | fixed, 3682e5a (EXIT trap removes only what the run created) |
| 7 | edit-config duplicated the library's lock bookkeeping and closed fd 9 twice | fixed, d752211 |
| 8 | five near-identical wait printers across scripts | recorded in followup.md (Library) as a shared `tn_wait_printer` |

The first review run died on the previous account's weekly limit before reading the diff; the
second run completed.

# Review — public-RPC consolidation, observer-flag removal, OPERATOR.md (2026-10-01)

Final HEAD = origin/main = 413ed71. 16 commits since the session started (A_HEAD b5d912b
closed Track A; add9ece is the release re-cut operators pull; 413ed71 the last docs commit).

## What landed
- Track A: public-RPC set committed (install-caddy 1.3.0, setup-node 1.1.0, check-node 1.1.54,
  firewall-setup 1.5.2, lib/fallback 1.0.2), #9 merged (arg-parser conflict resolved), lib/common
  1.3.9 + UI 1.8.7 changelog.
- lib/common 1.4.0: node_stake_status / node_is_staked_validator / print_validator_onchain_status;
  tn_node_has_observer_flag / tn_node_strip_observer_flag / tn_target_drops_observer; HW_* tiers,
  warn-only check_hardware with TN_HW_SUMMARY/TN_HW_GAPS; DEFAULT_DOCKER_IMAGE v0.15.0-adiri.
- setup-node 1.2.0: --rpc-domain derives advertised + .node-meta URLs; keytool --help probe;
  rpc_args built once, bash-3.2-safe expansion; hardware gaps as WARNING log events.
- update-node 1.1.62: role flags ignored; strips --observer on apply to >= 0.15.0 with backup/rollback.
- check-node 1.1.55: stake status decides validator checks; Consensus role from tn_nodeMode;
  legacy --observer warning; no role flags.
- edit-config 1.2.6 / remove-node 1.2.8: role flags ignored / slot-name only.
- UI 1.8.8: onchain_is_validator from getValidator; warn-only hardware preflight with tiers.
- update-scripts 1.1.67 re-cut; README changelog entries for all of the above.
- Docs: OPERATOR.md (856 lines), README technical edits, followup.md, CHANGELOG/AGENTS/testnet-addons.

## Verification
- Independent harnesses (not the implementers') under bash 3.2 and 5: V-B1 (lib/common) PASS,
  V-B(a) (setup-node, check-node, edit-config, remove-node, UI) PASS, V-B(b) (update-node) PASS;
  fleet keytool argv byte-identical to b5d912b; UI unittest 7/7.
- Docs: D2 read-through (8 findings fixed), V-C links/flags/line-numbers/headings PASS.
- D1: bash -n (3.2 + 5) on all 22 scripts, shellcheck error-level, py_compile, sidecars fresh,
  versions bumped on every changed tracked file, no co-author trailers, no line numbers.

## Left as-is (deliberate)
- tasks/lessons.md is TRACKED (plan assumed untracked); my harness-gotchas append is uncommitted.
- Pre-existing bash-4 uses not fixed: confirm() ${response,,}; remove-node declare -A (followup.md).
- check-node still flags a staked-but-unseated validator's missing committee headers (followup.md).
- .claude/project-context.md and tasks/ckpt-*.md untracked, not deleted.

# Review — one support address + MNO partner guide PDF (2026-10-01)

HEAD = 7fb7c8d (not pushed). Two commits on main: e20500c (support address, setup-node
1.2.1, update-scripts 1.1.69) and 7fb7c8d (partner guide, build script, docs).

## What landed
- Every operator-facing contact is support@telcoin.org: OPERATOR.md (5 places, §10 now one
  sentence, appendix Contact row), README (2 lines + changelog entries), setup-node.sh banner.
  Sidecars regenerated; only setup-node.sh.sha256 and update-scripts.sh.sha256 changed.
- docs/partner/mno-node-guide.md (911 lines, 10 chapters, 58 headings, 28 internal heading
  links, 14 absolute GitHub links, 5 GitHub alerts). No legacy material, no manual numbers.
- docs/partner/{metadata.yaml,template.html,theme.css}, assets/ (2 logos from
  tel3.telcoin.network, 7 Geist/Geist Mono woff2 from vercel/geist-font v1.7.2 + OFL.txt +
  LICENSE.txt, 400 KB, provenance in assets/README.md), mno-node-guide.pdf (31 pages, 220 KB).
- tools/build-partner-pdf.sh: tool checks, source lint (forbidden terms fail anywhere, H1
  count is fence-aware), pandoc, dangling-anchor check, WeasyPrint with log gate, PDF sanity
  via stdlib python (page count, mailto), anti-churn gate, PARTNER_MD override for tests.
- AGENTS.md "Partner guide (MNO PDF)" section + sync rule; README call-out and "Docs move
  with the code" paragraph; CHANGELOG Unreleased entries; .gitignore docs/partner/build/;
  .gitattributes marks the PDF binary + linguist-generated; .claude/project-context.md line.

## Toolchain (only system change: `brew install pandoc weasyprint`)
- pandoc 3.11, WeasyPrint 70.0 (Homebrew, bundled Python 3.14.8). woff2 loads natively.
- Poppler not installed; page renders for review used throwaway CoreGraphics Swift tools in
  the session scratchpad.

## Verification
- `grep -rn 'grant@telcoin' --exclude-dir=.git --exclude-dir=tasks .` → empty.
- /bin/bash 3.2 + bash 5 `-n` on setup-node.sh, update-scripts.sh, tools/build-partner-pdf.sh
  → ok; shellcheck -x --severity=warning on the build script → clean.
- gen-checksums.sh after commit → no sidecar drift; no .sha256 under docs/ or tools/;
  `grep partner update-scripts.sh` → empty.
- Build: working tree → "Wrote … (31 pages)"; second run → "PDF unchanged"; clean
  `git clone --local` of 7fb7c8d → "PDF unchanged" and `cmp` byte-identical to the committed PDF.
- Negative tests: `--observer` inside a fenced block → exit 1; grant@ in prose → exit 1;
  `--bogus` → exit 2; dangling #link, second `# `, "legacy", missing support@ → exit 1 (C).
- Forbidden-term grep on md + built HTML → empty; non-http hrefs in the HTML → only ../theme.css.
- PDF metadata: Producer WeasyPrint 70.0, CreationDate/ModDate D:20261001, Author Telcoin
  Association, Lang en-GB, 60 outline entries, 6 mailto links.
- Visual review of all 31 pages (Read tool on 80 dpi renders): full-bleed gradient cover with
  both logos and no header/footer; Contents with dotted leaders and correct page numbers;
  every chapter on a new page with running header "<title> | <chapter>" and "Page X of 31";
  internal links show "(page N)"; code wraps inside A4; callouts amber/cyan; table header rows
  repeat (Status values); troubleshooting as five 3-column tables, nothing overflows.

## Orchestrator changes on top of the agents' work
- metadata.yaml `date: 1 October 2026` (pandoc normalises to 2026-10-01 for dcterms).
- theme.css `th code { white-space: nowrap }` so `--install-method` / `--rpc-domain <d>` headers
  stop breaking mid-word.
- Build lint: forbidden terms fail inside code fences too (C had made them warn-only).

## Known cosmetic points (accepted)
- Chapter-per-page leaves short end-of-chapter pages (6, 9, 15, 25 are mostly blank).
- "Menu choice" column of the Install methods table wraps `1) Build from source` to three lines.
- Two em dashes remain, both inside code quoting check-node.sh's literal output.

# Review: MNO guide 1.4 refresh to telcoin-network main (2026-10-15)

## What changed
- `docs/partner/mno-node-guide/mno-node-guide.md` 1.3 -> 1.4 (+16 lines net, 1313 lines) and
  its PDF (48 pages, was 46), describing telcoin-network `main` 98849a221 (three merges past
  `v0.16.0-adiri`: #1622, #1647, #1572) as current behaviour, no release qualifier.
  Correction: the clock-drift sentence (a validator holds its vote up to 1 s on adiri; rejects
  beyond its drift tolerance plus the 5 s vote timeout, "five to six seconds"). Additions:
  bootstrap peers are discovery hints; the opt-in `network-config` keys (four lines);
  the boundary-window repair note; the `Cannot check database (epoch)` pointer and remedy row
  (`consensus-db/epoch` only, never `consensus-db/epochs`); the `initiating node shutdown`
  row; the rejoin wording (20 rounds, `attempting to rejoin consensus`); the
  `worker is inactive` row.
- `OPERATOR.md` and `README.md` carry the same facts in their own style (`support@`,
  "section N.N", "data dir"). `CHANGELOG.md` Unreleased clause, `followup.md` triage.
- Nothing updater-tracked changed: no version bumps, `gen-checksums.sh` reports no drift.

## Verifier catches applied (U3, all re-derived at 98849a221)
- BLOCK: the reject threshold adds `vote_timeout` to the RAW tolerance (handler.rs:787), so
  5.25 s on a current `network-config` and 6 s only where the old bare `1` remains; the facts
  file's "1 s + 5 s" was wrong. Guide says "five to six seconds"; OPERATOR gives both figures.
- `worker is inactive` happens only for a worker the network dropped while the node ran
  (`deactivate_workers_above`); a worker above the count at start is never initialised.
- `; initiating node shutdown` does not exit the process: the consensus notifier is per-epoch,
  the task error is non-critical, `run_epochs` loops; the durability latch is sticky
  (layered_db.rs:233-238), so the node cannot vote until restarted. Row says so and tells the
  operator to restart at once (the wait protects nothing while it cannot vote).
- `network-config` keys are "unset" (absent, `null` or `{}`), not "absent"; every key is
  optional; the Node Manager UI writes `hostname` too.
- A restarted seated node starts `CvvActive` (optimistic) and drops to `CvvInactive` only when
  40+ rounds or an epoch behind; "falls behind, for example during a long restart".
- OPERATOR/README recovery sentence: "stopped while the epoch changes", not "close to the
  boundary". README's discovery-hints sentence moved after "It needs v0.15.0-adiri or later".

## Verification
- `bash tools/build-partner-pdf.sh mno-node-guide --html-only`: exit 0, no FAIL/WARN.
- Full build: "Wrote ... (48 pages)", WeasyPrint log clean; second run "PDF unchanged".
- `pdftotext | tr '\n' ' '` counts: every required string >= 1 (`Cannot check database
  (epoch)`, `consensus-db/epoch`, `consensus-db/epochs`, `attempting to rejoin consensus`,
  `discovery hints`, `five to six seconds`, `initiating node shutdown`, `previous epoch record
  missing`, `source admission is enabled`, `worker is inactive`, `devs@telcoin.org`); every
  forbidden string 0 (`legacy`, `--observer`, `migrate-node-naming`, `setup-observer.sh`,
  `setup-validator.sh`, `grant@`, `support@`, `more than a second ahead`, `next release`,
  `Invalid bytes`, `about six seconds`). Cover: "Version 1.4 · 15 October 2026".
- `pdfinfo`: 48 pages, ModDate 2026-10-15, Author Telcoin Association.
- Page renders viewed (80 dpi): cover, Hardware per role (7), Optional node flags (15), One-way
  updates (19), Restarts and the epoch boundary (20), Watch your status (33), Sync and node
  mode (41), Service and keys (45-46): long rows wrap cleanly, header row repeats across the
  page break, running header and "Page X of 48" intact.
- All 38 `(#slug)` links match heading ids; README's `OPERATOR.md#9-troubleshooting` resolves.
- `git status --short`: M only for the guide .md, metadata.yaml, the PDF, OPERATOR.md,
  README.md, CHANGELOG.md, followup.md, tasks/plan.md, tasks/todo.md; new task files
  untracked until the commit; the specification PDF and the telcoin-network checkout unchanged.

## Accepted as is (verifier NOTEs)
- Row 10a: the message can print `header epoch unknown`; the row already says email first.
- Row 10c leaves out the ERROR-level sibling line at close_epoch.rs:653-662 (also no action).
- "which waits for the epoch boundary" for edit-config menu item 12 is the guide's existing
  shorthand (waits only for a `CvvActive` node inside `TN_EPOCH_MARGIN`).
