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
