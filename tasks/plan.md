# Plan: scripts-v2.2.0 for testnet with the v0.18.0-adiri packages (2026-11-24)

`scripts-v2.1.0` (serial 1) is the signed release. Main (`1e71337`) holds everything meant for
`scripts-v2.2.0`. telcoin-network `v0.18.0-adiri` was published on 2026-11-24, signed by
grantkee's ed25519 key: the first signed release on the testnet channel. Three things on main do
not match that yet, so the release is a pull request first and the signing ceremony second.

Branch: `chore/2.2.0-gateway-pin-third-key` from `origin/main` at `1e71337`, in the main checkout.
Partner guide branch: `docs/mno-guide-1.14`, worktree `~/coding/telcoin/tnd-v220-guide`.
Shared facts: `tasks/spec-v220-shared.md`. Checkpoints: `tasks/ckpt-v220-<id>.md`.

## Decisions (user, 2026-11-24)

- Pin the testnet worker gateway to the image `v0.18.0-adiri` signs. The node image needs no pin;
  the `v0.16.0-adiri` offline fallback stays.
- Ship the third release key, `sstanfield.asc`: `vendor/tn-release-signing` moves from `813fcf4`
  to `172be74`.
- Hosts on 2.1.0 cannot be made to accept 2.2.0: their updater verifies against the RSA key
  alone, and that key no longer signs. The release tells them the remedy everywhere they can
  land: the installer one-liner.
- 2.2.0's updater names the installer when no installed key signed a release, or the signing key
  has expired. (The plan also listed a revoked key; the review round took it out, see
  `tasks/todo.md`.)
- No Claude attribution on any commit or on the pull request.
- No version constant moves: `update-scripts.sh` and `lib/gateway.sh` stay 2.2.0, as in the
  earlier edits of this unreleased cycle.

## Phase 1: PR A (release-critical)

- [x] Gate: the pinned image runs `--help` offline and unprivileged and lists every flag of
      `GW_REQUIRED_FLAGS` (2026-11-24, `linux/amd64`, the probe's own regex).
- [x] Commit 1 `feat(release-keys)`: the submodule pointer, `lib/release-keys/sstanfield.asc`,
      its `SCRIPTS` row, the `TN_RELEASE_KEYS` block of `install.sh`, the key README. (agent A)
- [x] Commit 2 `chore(gateway)`: the testnet pin and the tree-pin check in
      `tools/tests/gateway_setup_test.sh`. (agent B)
- [x] Commit 3 `feat(update-scripts)`: the installer hint in `verify_manifest` and its test
      cases. (agent C, after A: both edit `update-scripts.sh`)
- [x] Commit 4 `docs`: OPERATOR.md and README.md (D1), the two changelogs (D2), AGENTS.md and
      followup.md (D3).
- [x] `chore(release)`: `bash tools/gen-checksums.sh`, once after commit 4 and once after the
      review round.
- [x] Cold review of the diff by two fresh agents (code and tests; docs against code).
- [x] Review round: `fix(update-scripts)` (no hint for a revoked key or on the key bootstrap),
      `docs` corrections, `test(bootstrap-servers)` (a test that failed as root on main too).
- [x] Verification on the tip after the review round: the fixture tests in four environments,
      the UI tests, the lints, `check-release-keys.sh`, `check-gateway-pin.sh` online, a clean
      `gen-checksums.sh`.
- [x] `tasks`: this plan, the review in `tasks/todo.md`, the lessons, the operator note, the
      checkpoints.
- [ ] Push and open the pull request; report CI.

## Phase 1b: PR B, partner guide 1.14 (not release-critical)

- [x] `mno-node-guide.md`: signed releases started with `v0.18.0-adiri` (lines 330 and 847), and
      the troubleshooting row for the unsigned-manifest refusal gives the installer (line 1852).
- [x] `metadata.yaml` 1.14; PDF rebuilt on the Ubuntu 26.04 toolchain; rendered pages read.
- [x] Pushed and opened as pull request #80. It merges before the release PR or after the tag,
      never between the release merge and the tag. After it merges: Publish on tn-partner-site.

## Phase 2: prepare and sign (user)

- [ ] Main checkout on the merged main, submodule at the new pointer, `git status --short` empty.
- [ ] `bash tools/cut-release.sh prep scripts-v2.2.0 --serial 2` (user, YubiKey).
- [ ] Rehearsal against `release/scripts-v2.2.0` (`tasks/verify-v220/rehearse-updater.sh`):
      `cut-release.sh status`; the real 2.1.0 tree refuses with the documented `[ERROR]` line
      and changes nothing; a tree with the three keys installs 2.2.0.

## Phase 3: merge and tag (user)

- [ ] Merge the release PR with a merge commit.
- [ ] `bash tools/cut-release.sh tag scripts-v2.2.0`.

## Phase 4: after the tag

- [ ] `cut-release.sh status` and the three tag workflows.
- [ ] Fresh install from the published one-liner in `ubuntu:26.04`; `update-scripts.sh --check`
      exits 0 on `scripts-v2.2.0`, serial 2, three key files.
- [ ] The 2.1.0 path for real: install 2.1.0, its updater refuses, the one-liner brings 2.2.0.
- [ ] User: post `tasks/operator-note-scripts-v2.2.0.md`; wire the AWS template publish.

## Not in this release

PR #76 (mainnet genesis readiness) and `TN_MAINNET_ENABLED`; Dependabot PR #77; the
`v0.16.0-adiri` fallback image and the chain-config tag; the release-tool guard on key-set
overlap (a follow-up PR).
