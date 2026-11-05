status: done

# Checkpoint: package DOCS-2 (round 2, PR #59), worktree tnd-r2-DOCS, branch r2/DOCS, base a7f4fa8

- [x] S1 Integrity contract (SIG) -- f40547d (SIG follow-up 1 deltas folded in: CR key files, cut-release key check before branch, one-prompt commit, tag verify by status lines, status names the key)
- [x] S2 Images (IMG) -- 27dcf14
- [x] S3 Epoch (EPOCH) -- 0d20c36 (OPERATOR update-wait sentences + epoch table + blind wait paragraph; README epoch paragraph + lib/common 2.1.0 bullet; guide restart wait + table)
- [x] S4 Owners and Alloy -- no change needed: README, OPERATOR, docs/testnet-addons.md have no single-owner or pending-merge sentence (testnet-addons sync note and followup already name 18f8485, PR #8 merged 2026-11-04; config.alloy header agrees); AGENTS CODEOWNERS paragraph got the release-path lines in S1
- [x] S5 CHANGELOG/scripts-v2.1.0.md -- b51ccd3 (intro: first signed, serial 1, 2.0.0 never tagged; new sections 'Signed script releases with OpenPGP (#40)' and 'Image packages per network and the image feature check (#46)'; per-script bullets setup/update/edit-config/remove-node; update-scripts section line; CODEOWNERS bullet; Alloy 18f8485 bullet; new-files table; Before you update step 1; refusals table +6 rows; Left open #30/#31, #40, #41, #45/#46/#51)
- [x] S6 Partner guide 1.7 + PDF -- a84d5f6 (metadata.yaml version 1.7, date November 2026 kept; guide text changed in S1-S3)

## Docs written (where each fact lives)

S1 (f40547d):
- README: What's Included row (lib/release-keys/ only); Quick Start installer paragraph (gpgv, base64);
  Security Design "Verified releases"; Keeping Scripts Up to Date (MANIFEST.asc, refusal message,
  gpgv dependency + missing message, 1.1.72 bootstrap with the WARN text, new paragraph "A host that
  cloned main before scripts-v2.1.0" + installer one-liner + leftover allowed_signers);
  How updates are verified > Script releases (MANIFEST.asc bullet, threshold, keyring block shared
  with node releases, status-line rule); Node releases hand-check keyring line -> per-file loop;
  Changelog "update-scripts v2.1.0" heading + first signed release (serial 1) + 3 bullets;
  "update-scripts v2.0.0" entry gets a Retired note; Contributing paragraph (MANIFEST.asc, cut-release).
- OPERATOR: 2.1 (MANIFEST.asc, deps), 4.1 (gpgv, missing gpgv message, bootstrap, migration
  paragraph + one-liner, leftover allowed_signers, expired-key refusal -> re-run installer,
  --check line), 4.9 step 1, 4.10 (shared keyring block + status rule up top; node block uses it;
  script block for scripts-v2.1.0 with gpgv; host without installed copy: installer's embedded keys).
- AGENTS: Self-update and integrity contract rewritten (MANIFEST.asc, policy, threshold #40, the
  RELEASE SIGNATURES block, status-line invariant incl. cut-release tags, LF rule for key files,
  installer trust root, bootstrap TOFU, 2.0.0-from-main migration, rotation, key expiry 2028-10-16),
  "To cut a release" rewritten around cut-release.sh prep/tag/status (+ first ceremony),
  release metadata line, CI manifest bullet, CODEOWNERS release-path lines, signing.sh fixtures.
- lib/release-keys/README: Script releases section first sentence (same maintainer key signs both,
  from scripts-v2.1.0); expiry paragraph (script releases refuse too, re-run installer, 2028-10-16).
- followup.md Release prep: first ceremony item, 2.0.0-from-main hosts item, key expiry item,
  #40 with TN_SIG_THRESHOLD, sidecar item (bootstrap_keys).
- CHANGELOG/scripts-v2.0.0.md: top note (never tagged, scheme retired). CHANGELOG.md: note in the
  Mainnet hardening round section (also says the single image package never held a release).
- Partner guide: installer deps (gpgv), "How the scripts and releases are checked" first two
  bullets, "Keep the scripts current" (MANIFEST.asc, gpgv missing).

S2 (27dcf14):
- AGENTS "The mainnet switch": images paragraph (packages, tn-dev, legacy package recognition only,
  pull rule + UI twins, IMAGE_DIGEST package rule, digest-alone rule as defence in depth, feature
  check, test_csrf agreement). AGENTS "One-way storage migration": floor by network.
- README Docker Install Notes (packages, old package refusal message, devnet tn-dev, new bullet for
  the feature check with refusal text, registry fallback tn-testnet, mainnet paragraph reworded,
  mainnet examples tn-mainnet); Updating the node (tag menu, storage_downgrade by network, one-way
  testnet only, STORAGE_MIGRATION_FLOOR_TESTNET); Removing a Node container scan; Node releases step
  5 (IMAGE_DIGEST per network + refusal + feature check) and testnet fallback; Networks and
  endpoints paragraph; changelog: lib/common 2.1.0 (+3 bullets), setup-node 2.1.0, update-node
  2.1.0 (heading + 2 bullets), edit-config 2.1.0, remove-node 2.1.0, telcoin-ui 2.1.0; 2.0.x
  history entries marked "(retired in 2.1.0 ...)".
- OPERATOR 1.5 (mainnet package), 2.3 Docker row (packages, old package, feature check, devnet
  tn-dev), 4.2 tag menu + feature check, one-way testnet only, 4.3 docker_image row, 4.7 container
  scan, 4.10 IMAGE_DIGEST, 9 troubleshooting: registry row, + 4 rows (feature refusal, could not
  run, old package, IMAGE_DIGEST).
- Partner guide: mainnet package sentence, "How ... checked" (+ package bullet, digest-alone reason,
  feature check bullet), Docker row, docker_image row, one-way testnet only.
- lib/release-keys/README IMAGE_DIGEST sentence. followup.md: images item rewritten (PR #1784,
  #46 confirmed 2026-11-04), feature-check Version item added, storage floor item renamed.

## Grep results

Final gate (spec command over the 8 files): 34 lines, every one a sentence that describes the
retired SSH scheme or the retired image package as retired: the old updater's message
("has no MANIFEST.sig"), the leftover lib/allowed_signers, "never held a release / refused", the
README v2.0.0 history entry under its Retired note (README 1952-1977), and the 2.0.x README entries
marked "(retired in 2.1.0 ...)". CHANGELOG.md and CHANGELOG/scripts-v2.0.0.md keep history with a note.
tools/check-network-hits.sh: clean, 147 annotated hits in 24 files (it does not scan *.md).

S1 terms after f40547d: remaining hits only in retired-scheme sentences: followup.md (2.0.0-from-main
item), AGENTS (migration bullet), OPERATOR 4.1 migration paragraph and 4.9 step 1 (old message),
README Keeping Scripts paragraph on hosts that cloned main, README changelog v2.1.0 bullet
"... are retired", README v2.0.0 history entry under its Retired note.

## PDF hashes

Built in tn-pdf-tools:latest (pandoc 3.8.3, WeasyPrint 70.0), 73 pages:
`docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD:/w" -w /w tn-pdf-tools:latest bash tools/build-partner-pdf.sh mno-node-guide`
- build 1: 9ad09451665e2c986cc00d21e8034fe68e0e27d1efdf56d7db37da438bceb843
- build 2 (same command with --force; candidate cmp-identical, "PDF unchanged"):
  9ad09451665e2c986cc00d21e8034fe68e0e27d1efdf56d7db37da438bceb843
Lint passed both times; pdftotext shows "Version 1.7 · November 2026" and no SSH-scheme or old-package term.

## Open issues

- lib/release-keys/README is updater-tracked: its .sha256 sidecar is stale after f40547d (and S2);
  the orchestrator regenerates sidecars.
- lib/release-keys/README cites "the maintainer release keys table in that repository's SECURITY.md";
  telcoin-network origin/main SECURITY.md has no such table today (it is on other branches, e.g. the
  UPS worktree). Pre-existing; not changed.
- Verified by experiment (throwaway keys, gpg 2.4.8): gpgv exits 0 on EXPKEYSIG; `cat *.asc | gpg
  --dearmor` and the per-file loop give the same keyring for two keys (docs use the loop).
- update-node.sh and edit-config.sh header comments (code, not DOCS files) still say the margin is
  "five minutes on testnet; derived from the epoch length elsewhere", which reads as if mainnet
  differed (EPOCH open issue). Suggested: "(five minutes for the 6-hour epochs of mainnet and
  testnet; derived from the epoch length, up to 15 minutes)".
- SIG fix-round facts (CR refusal, gpg-reads-no-key refusal, cut-release key check before the
  branch, one-prompt commit, tag verify-tag --raw by status lines, status names the key) were
  verified in the SIG worktree (a73a2be, f7e1003), not on this tip (a7f4fa8); AGENTS and the
  2.1.0 note describe them. They hold once those commits are on the integration branch.
- "Merge the release PR with a merge commit" is the orchestrator's instruction; nothing in
  cut-release.sh enforces it (tag checks MANIFEST/MANIFEST.asc content only). Written as a step
  in AGENTS and followup.md with the reason "so the signed release commit stays on main".
- The ubuntu:24.04 image does have gpgv (apt depends on it), contrary to spec-r2-shared.md's
  test-environment note; only matters for the fixtures' REAL_GPG detection (it also needs gpg).
