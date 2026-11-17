# Plan: node requirements one-pagers, testnet and mainnet (2026-11-17)

Branch `docs/node-requirements-one-pagers` off `origin/main` at b89ada4 (`scripts-v2.1.0`; the
approved plan named 628a74d, one commit earlier, and that commit touches neither the build
script nor the guide). Two one-page partner PDFs under `docs/partner/`, built by
`tools/build-partner-pdf.sh`. Checkpoints `tasks/ckpt-onepager-<unit>.md`. Agents do not
commit; the orchestrator reviews each unit's diff and the rendered pages, then commits.

## Decisions (user, 2026-11-17)

- Both pages are committed partner documents, not one-off files.
- Commit as the work goes; no Claude trailer or footer; open the PR at the end.
- Mainnet has not launched: the mainnet page states what the scripts already enforce and marks
  the rest "set at launch". No invented figure.
- Left out because they move with each release: the node version, the scripts version, which
  release starts signed node releases.

## W0 Setup (orchestrator)

- [x] `git fetch`; branch from `origin/main`; baseline `--all` in `tn-pdf-tools` prints
      "PDF unchanged" for the guide (77 pages) and the specification (37 pages)
- [x] `.claude/project-context.md` regenerated (untracked, as before)
- [x] this plan block
- [x] upstream check: the guide's disk figures (10,000 write IOPS, 300 MB/s) match the upstream
      hardware page at `v0.17.0-adiri`; upstream `main` raised them in #1834 (storage v2,
      unreleased: 20,000 write IOPS, 800 MiB/s). The pages follow the guide; the change is a
      follow-up for the guide and both pages together

## W1 Script (unit S, opus)

- [x] `DOCS` and `case "$DOC"` know `testnet-node-requirements` and `mainnet-node-requirements`
      (`LINT_LEGACY=1`, `CONTACT_IN_MD=1`, `NEED_CONFIDENTIALITY=0`)
- [x] page bounds per document in the `case` block: 15 to 150 for the long documents, exactly 1
      for the one-pagers
- [x] `toc-depth: 0` accepted; `--number-sections --toc --toc-depth` only for 1 to 3
- [x] header comment, `usage()`, page-count wording ("expected exactly 1")
- [x] `bash -n` (5.x and 3.2), `check-bash32.sh`, shellcheck 0.11 and 0.9, `check-network-hits.sh`
- [x] guide and specification still "PDF unchanged"; scratch one-pager cases pass
- [x] the "legacy" lint message says "this document" (orchestrator, after S's hand-back)
- [x] commit 1 `build-partner-pdf: per-document page bounds, toc-depth 0`

## W2 Testnet page (unit T, opus)

- [x] `docs/partner/testnet-node-requirements/`: `template.html`, `theme.css`, `metadata.yaml`,
      the Markdown, the PDF; A4, one page, two columns, the guide's brand tokens, vendored
      assets only
- [x] orchestrator reads the rendered page (nothing clipped, columns balance, logos, legible)
- [x] orchestrator edits after the review: the installer command breaks at a backslash instead of
      inside its URL; ports 443 and 80 are for public RPC or the dashboard (guide line 173);
      "Signed node releases are checked against the same keys", because `v0.17.0-adiri` is
      unsigned and passes by a one-tag exception (`lib/common.sh`, `TN_UNSIGNED_RELEASE_TAG`)
- [x] commit 2 `docs/partner: testnet node requirements one-pager`

## W3 Mainnet page (unit M, opus)

- [x] `docs/partner/mainnet-node-requirements/` on T's template and theme (byte-identical copies)
- [x] latency rule without a committee size ("to a quorum of the committee"); the mainnet
      verifier settles it against the upstream page
- [x] orchestrator reads the rendered page
- [x] orchestrator edits after the review: three planned facts the writer had cut for space are
      back (testnet add-ons refused, journal logs, SSH sources for the firewall); the explorer
      cell uses the guide's "Not launched yet"; the validating sentence no longer says the
      advertised RPC URL is served by another node, which the guide does not say
- [x] commit 3 `docs/partner: mainnet node requirements one-pager`

## W4 Verification and docs (units V and D, opus, parallel)

- [x] V (read-only), one verifier per page (`tasks/ckpt-onepager-V-testnet.md`,
      `tasks/ckpt-onepager-V-mainnet.md`): every statement against the guide at this branch
      and, for numbers, the code or upstream line; sources read before the writers' text;
      live checks of the endpoints the page prints
- [x] D: `AGENTS.md`, `README.md`, `docs/partner/assets/README.md`, `CHANGELOG.md` (reviewed, held for commit 4)
- [x] fixes from V applied (five on the testnet page, four on the mainnet page); both reports
      are closed with nothing open
- [x] `AGENTS.md`: a bullet on the three Markdown hooks and how to fit text (orchestrator)
- [x] commit 4 `docs: list the node requirements one-pagers`

## W5 Gates, PR, records (orchestrator)

- [x] `--all` twice in the container, from a fresh worktree at another path: "PDF unchanged"
      for all four on both runs
- [x] negative checks with `PARTNER_MD` on both pages (over-long copy reports 2 pages; a
      forbidden string and the word "legacy" fail the lint)
- [x] `pdftotext` shows `devs@telcoin.org` and no forbidden string; `cmp` of the two templates
      and the two themes
- [x] commit 5 `tasks: plan, checkpoints and review of the one-pagers round`, made after CI so
      the review is written last
- [x] push over SSH; `gh pr create` against `main`: PR #67, opened on the first four commits
- [x] CI green at f0cfb70 (12 of 12 checks); review section in `tasks/todo.md`

# Plan: private alerts, a heartbeat pushed from the node host (setup-alerts.sh), issue #60 (2026-11-04)

Branch `private-alerts` off `hardening-followups` (4a2cf6e); PR base `hardening-followups`;
folded into the unreleased `scripts-v2.1.0` note. Shared spec `tasks/spec-alerts-shared.md`,
package specs `tasks/spec-alerts-<PKG>.md`, checkpoints `tasks/ckpt-alerts-<PKG>.md`.

## W0 Setup (orchestrator)
- [x] `.claude/project-context.md` regenerated; branch created; issue #60 opened
- [x] shared spec, eight package specs, checkpoint stubs, this plan block

## W1 Implementation (opus, parallel, one checkout, no commits)
- [x] A1a `lib/tn-heartbeat.sh` + `tools/tests/heartbeat_test.sh`
- [x] A1b `lib/alerts.sh` + the common.sh source block + `tools/tests/alerts_test.sh` + `tools/tests/vm.d/P0-alerts.sh`
- [x] A3a setup-node.sh + check-node.sh + host_baseline_test, check_node_hardening_test, setup_node_alerts_test
- [x] A3b remove-node.sh + update-scripts.sh + AGENTS.md + remove_test, remove_addons_test, updater_manifest_test, addon_gates_test
- [x] A4a OPERATOR.md §4.14 and the short additions; README section, rows, changelog
- [x] A4b CHANGELOG/scripts-v2.1.0.md, docs/testnet-addons.md, followup.md, partner guide 1.7 Markdown + metadata

## W2 Script (opus)
- [x] A2 `setup-alerts.sh` + `tools/tests/setup_alerts_test.sh` + addon_oldlib_test row

## W3 Verification (opus)
- [x] V1 (code) and V1d (docs) gates in all three environments, lints, systemd-analyze, AGENTS-rule sweep, runner mutants, docs vs code

## W4 Fixes
- [x] fixers F-A (library, setup-alerts), F-B (runner), F-C (OPERATOR, README), F-D (release note, guide, add-ons doc, follow-ups, AGENTS.md); V2 re-checks

## W5 Release prep and PR (orchestrator)
- [x] `tools/gen-checksums.sh`; guide PDF built twice in the container ("PDF unchanged")
- [x] `git diff --check`; nine commits in the planned order, no trailers
- [x] push; PR #61 against `hardening-followups` ("Closes #60"); comment on #59 about the cut order
- [x] CI round: the VM job's dbus finding (root pre-step), two BSD test fixes, three rebases (guide 1.8); force-push
- [x] `tasks/todo.md` review section (the checkout stays on `private-alerts`: another worktree holds `hardening-followups`)

---

# Plan: round 2 on PR #59 (2026-11-04)

GPG-signed script releases, per-network image packages, three code owners, a mainnet epoch
constant, the Alloy vendoring refresh, the #41 manifest proposal and the signing walkthrough.
Replaces the follow-ups plan of 2026-11-02 (finished at 4a2cf6e). Specs: `tasks/spec-r2-*.md`.

## Decisions (user, 2026-11-04)

- Script releases are signed with the same YubiKey GPG key as node releases
  (`lib/release-keys/grantkee.asc`), under the gpgv status policy already used for node
  releases. `MANIFEST.asc` replaces `MANIFEST.sig`; `lib/allowed_signers` goes away.
  `scripts-v2.1.0` is the first signed release (serial 1); `scripts-v2.0.0` is never tagged.
- Images: `ghcr.io/telcoin-association/tn-mainnet` (tags `vX.Y.Z`) and
  `ghcr.io/telcoin-association/tn-testnet` (tags `vX.Y.Z-adiri`); dev images go to `tn-dev`;
  the old single package is abandoned. The channel is a pure function of the tag at every stage.
- CODEOWNERS: `@grantkee @sstanfield @MavenRain`. Mainnet epoch 21600 s; margin and settle stay
  derived (300/90). The P2P new-flow limit stays 20/min, burst 40, on every network.
- #41: propose the signed address-manifest format as an issue comment (done 2026-11-04).

## Waves

- [x] Wave 0 (orchestrator): Alloy header -> deploy-networks-common main 18f8485 (a2162b6);
      CODEOWNERS three owners + ci_pins two-owner check (8db70e0); #41 comment + followup pointer
      (9fd615a); specs (2966e54). Pushed.
- [ ] Wave 1 (opus implementers in worktrees `tnd-r2-<pkg>`, branches `r2/<pkg>`):
  - [ ] SIG: GPG signatures in release-scripts / update-scripts / install.sh, `MANIFEST.asc`,
        threshold hook, `tools/cut-release.sh`, tests, CI grep, VM assertion.
  - [ ] IMG: per-network packages, network-keyed storage floor, image feature check, UI twins.
  - [ ] EPOCH: `MAINNET_EPOCH_DURATION`/`TESTNET_EPOCH_DURATION`, blind wait derives from them.
  - [ ] UPS (telcoin-network `release-packages-per-network`): `etc/release.sh` package from the
        channel, package checks at every stage, Makefile dev image, workflow and docs.
- [ ] Wave 1 integration: cherry-pick EPOCH -> IMG -> SIG; quick gates per package; push.
- [ ] Wave 1v: V7 (SIG + IMG, mutants on the status policy, threshold, dearmor, bootstrap,
      cross-network refusals, the feature check, cut-release step order); V8 (UPS dry-run
      matrix, sign refusal, actionlint). Fix rounds back to the owning implementer.
- [ ] Wave 2: DOCS-2 (README, OPERATOR, AGENTS, lib/release-keys/README, CHANGELOGs,
      followup.md, docs/testnet-addons.md, partner guide 1.7 + PDF); #46 comment; upstream
      draft PR for UPS.
- [ ] Wave 3: sidecars, full gates, push, CI green, `/code-review high` over 4a2cf6e..HEAD,
      PR #59 body update, todo review, lessons, memory.
- [ ] Wave 4 (interactive): signing environment on the maintainer box through a forwarded
      gpg-agent, ending in a verified test signature. The ceremony itself runs after PR #59
      merges: `tools/cut-release.sh prep scripts-v2.1.0 --serial 1`, merge the release PR,
      `tools/cut-release.sh tag scripts-v2.1.0`.

## Outward actions this round

Plain pushes of `hardening-followups`; one comment each on #41 (done) and #46; one draft PR in
telcoin-network on `release-packages-per-network`; the PR #59 body edit. No tag, no release
files, no image push, no package creation.

## Left to the user

Rulesets (#30) with `require_code_owner_review` true; the package access lists after the first
pushes; review and merge of the upstream draft PR; the signing-environment steps that need the
client or sudo; after PR #59 merges, the release ceremony above; PR #1716 in their own session.
