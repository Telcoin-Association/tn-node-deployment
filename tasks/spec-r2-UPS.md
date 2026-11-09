# Package UPS: per-network image packages in telcoin-network's release tooling

Read `tasks/spec-r2-shared.md` first (ground rules; the bash 3.2 rules do NOT apply here:
`etc/release.sh` is bash 4+ and lints with `shellcheck -S style`). Worktree
`~/coding/telcoin/tn-r2-packages`, branch `release-packages-per-network` from origin/main
a0d6e6e26, checkpoint `tasks/ckpt-r2-UPS.md` in THIS worktree (`tasks/` is untracked there;
never add it). Size M. Never touch the branch `mainnet-chain-guard` or PR #1716. Commit on
your branch only; the orchestrator pushes and opens the draft PR.

## Decision

Release images are published to two ghcr packages: `ghcr.io/telcoin-association/tn-mainnet`
for mainnet tags (`vX.Y.Z` and `vX.Y.Z-rcN`) and `ghcr.io/telcoin-association/tn-testnet` for
adiri tags (`vX.Y.Z-adiri[-rcN]`). The channel is a pure function of the tag; every stage
(build, sign, verify, publish, CI check-tag/verify) re-derives the package from the tag and
refuses a mismatch. Ad hoc images from `make docker-adiri`/`docker-devnet` go to
`ghcr.io/telcoin-association/tn-dev`. The old package `ghcr.io/telcoin-association/telcoin-network`
never held a release and is not used any more. Packages come into existence on the first push
(ghcr has no create call); nothing is pushed in this round.

## Today (verified 2026-11-04 at origin/main a0d6e6e26; grep before editing)

`etc/release.sh` (2222 lines): `TAG_RE` 79; `parse_tag` 256-288 (CHANNEL `adiri`, FEATURES,
ALIAS `adiri`/`latest`); `REPO`/`RELEASE_REPO` 2092-2100 (owner/repo, dry runs); `IMAGE=
ghcr.io/$(lower "$REPO")` 2107; dry-run facility `RELEASE_DRY_RUN=1`, `RELEASE_IMAGE`
(localhost registry; `is_local_image`, `require_local_image_in_dry_run` 214-230),
`RELEASE_DIR` (857-899); registry probes 500-520 (ghcr anonymous token per `$path`);
`IMAGE_DIGEST` shape and checks 1115-1193 (`$IMAGE@sha256:<hex>`, registry must serve
`$IMAGE:$TAG` at that digest); `check_version_output` 1236-1271 (Build Features vs channel);
`cmd_build` ~1800-1840 (pushes `$IMAGE:$TAG`, writes IMAGE_DIGEST); `cmd_publish` moves the
alias; help text 2064; `parse TAG` prints the parse without git or network; sourcing the file
defines functions only. `.github/workflows/release.yaml`: jobs `validate-tag` (`check-tag`,
line 165), `draft-release`, `verify-release` (`verify`, 266); read its permissions and any
package name. `Makefile:13` `GHCR_IMAGE := ghcr.io/telcoin-association/telcoin-network`,
`docker-adiri` 450, `docker-devnet` 455, `docker-push` ~460, help lines 86-95, `release-lint`
537. Docs naming the package: `README.md:14`, `docs/src/getting-started/installing-a-release.md`
9/195/203/209, `docs/src/getting-started/validator-operations.md:82`,
`docs/src/maintainers/releasing.md` 190/365-366, `docs/src/maintainers/yubikey-setup.md:278`,
`.github/ACTIONS.md:467`, `etc/README.md` (grep), `SECURITY.md` (grep; edit only if it names
the package).

## Sections (one commit each; checkpoint after each)

S1 **Package from the channel.** `parse_tag` sets `PACKAGE=tn-mainnet` or `tn-testnet`;
`IMAGE=ghcr.io/$(lower "$OWNER")/$PACKAGE` where OWNER is the repository owner (from `REPO`);
`RELEASE_REPO` keeps changing the GitHub repository slug only; `RELEASE_IMAGE` stays the
dry-run-only override of the whole image name (refused outside a dry run, as today). Header
comment and `print_parse` show PACKAGE. Help text.

S2 **The package is checked everywhere a digest is read or written.** `IMAGE_DIGEST` must be
`$IMAGE@sha256:<hex>` with `$IMAGE` the channel's package (the existing check at ~1188 now
does this by construction; make the message name the expected package and the channel);
`sign` refuses to sign a `SHA256SUMS` whose `IMAGE_DIGEST` names another package (a new check
before signing, with a message naming the tag's channel and the package found); `verify` and
`publish` repeat it; the alias (`latest`/`adiri`) is created inside `$IMAGE` only (it already
is; add the assertion that the alias target's digest is in the same package). `check-tag` in
CI (validate-tag) gains the parse output in the log (PACKAGE visible).

S3 **Dev images.** `Makefile`: `GHCR_IMAGE := ghcr.io/telcoin-association/tn-dev` for
`docker-adiri`, `docker-devnet`, `docker-push`; help lines; a comment that release packages
are `tn-mainnet`/`tn-testnet` and written only by `etc/release.sh`.

S4 **Workflows.** `.github/workflows/release.yaml`: comments and any step that names the
package; `verify-release` must fail when `IMAGE_DIGEST` names the wrong package (covered by
`verify`; say so in a comment). `make release-lint` clean (actionlint + shellcheck `-S style`;
needs docker and network for the pinned images: run it; if the pull fails, run `shellcheck -x
-S style etc/release.sh` with the host shellcheck 0.11 and `actionlint` from
`rhysd/actionlint` image if available, and record which ran).

S5 **Docs.** `docs/src/maintainers/releasing.md` (packages per channel, the mismatch refusals,
first-push note: a package exists after its first push and its access list is set then, write
access for the release maintainer account only, the Actions token has no package write),
`docs/src/getting-started/installing-a-release.md` (the `IMAGE_DIGEST` check lines name the
channel's package; the `case` in the verification block accepts `tn-mainnet@sha256:` for a
mainnet tag and `tn-testnet@sha256:` for an adiri tag), `validator-operations.md:82`,
`README.md:14`, `yubikey-setup.md:278`, `.github/ACTIONS.md:467` (the package list is now two
release packages plus `tn-dev`), `etc/README.md`, `SECURITY.md` only if it names the package.

S6 **Dry-run matrix** (record commands and outputs in the checkpoint, no network needed):
`./etc/release.sh parse v0.1.0` → mainnet, tn-mainnet, alias latest; `parse v0.1.0-rc1` →
mainnet, tn-mainnet, prerelease, no alias; `parse v0.17.0-adiri` → adiri, tn-testnet, alias
adiri; `parse v0.17.0-adiri-rc2` → adiri, tn-testnet, prerelease; `parse v0.1.0-mainnet`
refused; `parse v0.1.0-adiri-adiri` refused. Source the file in a bash test script and call
the sign-time package check with a `SHA256SUMS`/`IMAGE_DIGEST` naming `tn-testnet` for a
mainnet tag → refused with the expected message; naming `tn-mainnet` → passes that check. With
`RELEASE_DRY_RUN=1 RELEASE_IMAGE=localhost:5000/x` the override is honoured; without
`RELEASE_DRY_RUN` it is refused. `shellcheck -x -S style etc/release.sh` clean; `bash -n`.

## Hand back

Commits on `release-packages-per-network` (sha + subject), the matrix results, the lint
results, the PR body text (title "release: per-network image packages tn-mainnet and
tn-testnet"; body: what changes, the guarantees list, the user steps after the first push,
no attribution lines) saved as `tasks/pr-body-UPS.md` in your worktree, and open issues.
