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
- [x] CI round: the VM job's dbus finding (root pre-step), two BSD test fixes, two rebases; force-push
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
