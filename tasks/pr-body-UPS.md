# release: per-network image packages tn-mainnet and tn-testnet

## What changes

Release images move from the single package `ghcr.io/telcoin-association/telcoin-network` to one package per network:

- `ghcr.io/telcoin-association/tn-mainnet` for mainnet tags (`vX.Y.Z`, `vX.Y.Z-rcN`), alias `latest`;
- `ghcr.io/telcoin-association/tn-testnet` for Adiri tags (`vX.Y.Z-adiri`, `vX.Y.Z-adiri-rcN`), alias `adiri`;
- `ghcr.io/telcoin-association/tn-dev` for the ad-hoc `dev-<flavor>-<TAG>` images of `make docker-adiri`, `make docker-devnet` and `make docker-push`.

The old package never held a release and is no longer used.

`etc/release.sh`:

- `parse_tag` sets `PACKAGE` from the channel, and `parse` prints it. The image is `ghcr.io/<owner>/$PACKAGE`, where `<owner>` is the repository owner in lower case. `RELEASE_REPO` (or `GITHUB_REPOSITORY` in CI) still names the GitHub repository and now sets only the owner part of the image. `RELEASE_IMAGE` stays the dry-run-only override of the whole image name.
- `check_digest_package` checks an `IMAGE_DIGEST` file: it must hold exactly one line, the repository before the `@` must be the tag's image, and the digest must have the form `sha256:<64 hex>`. `sign`, `verify` (and through it build's self-check and `publish`) and `draft` all call it, and `check_image_digest_file` then also checks that the registry serves the tag at that digest. Every refusal has one shape, for example `IMAGE_DIGEST names an image in ghcr.io/telcoin-association/tn-testnet, but v0.1.0 is on the mainnet channel, whose images are published only in ghcr.io/telcoin-association/tn-mainnet (expected the one line ghcr.io/telcoin-association/tn-mainnet@sha256:<64 hex>); ...`; for several lines, a line without a digest or a malformed digest, only the first part changes.
- `draft` used to drop a malformed digest from the release body and exit 0. It now stops on any `IMAGE_DIGEST` that `check_digest_package` refuses.
- `sign` has a new check right before the signature: `SHA256SUMS` lists the `IMAGE_DIGEST` beside it exactly once, with its hash, and that file passes `check_digest_package`. `verify` runs the same check before it counts signatures.
- `publish` checks, before it moves the alias, that the package serves the tag at the digest it verified.
- `check-tag` prints the parse and the image name to its log first, so CI's `validate-tag` shows which package the tag's image goes to.
- The release body's image check names the channel's package in its refusal and troubleshooting lines.
- First push: ghcr answers 403 for a package that has never been pushed, the same as for a private one (checked with anonymous reads on 2026-11-04). The probe that `build` ran before its push stopped on that 403, so the first build into a new package could never run. Now, when the anonymous read is refused, `build` asks again with the Docker login it already requires (`docker buildx imagetools inspect`). If the login sees the tag, the package is private, not new, and `build` stops before the build: the one-time setup comes first, then a rerun, with `RELEASE_REBUILD=1` if the tag must be rebuilt. Only when the registry answers that the tag is not found or access is denied (403 Forbidden included, which is ghcr's answer for a package never pushed) does `build` treat it as a first push, and it pushes only when `RELEASE_FIRST_PUSH` is set to the tag's package; `RELEASE_YES` never answers it. Any other failure of that lookup (DNS, a timeout, an expired login) is retried and then stops with exit 3. After the push it still stops with `package is not public` until the one-time setup is done.

`Makefile`: `GHCR_IMAGE` is `ghcr.io/telcoin-association/tn-dev`, and its comment says that only `etc/release.sh` writes the release packages.

`.github/workflows/release.yaml`: comments only, no step changes.

Docs: `docs/src/maintainers/releasing.md` (channel table, package paragraph, one-time setup at each network's first release, steps 4 to 7, failure table, both rollback recipes), `docs/src/getting-started/installing-a-release.md` (the image check takes the package from `TAG`), `validator-operations.md`, `yubikey-setup.md`, `README.md` and `.github/ACTIONS.md`.

## Guarantees

- The package name, `tn-mainnet` or `tn-testnet`, depends on the tag alone; no variable, flag or `make` setting chooses it. The owner part of the image comes from the repository (`RELEASE_REPO`, or `GITHUB_REPOSITORY` in CI), and only a dry run's `RELEASE_IMAGE` replaces the whole name.
- An `IMAGE_DIGEST` that names an image in `tn-testnet` on a mainnet tag, in `tn-mainnet` on an Adiri tag or in any other repository, or that is not one line with a well-formed digest, is refused by build's self-check, by `sign` (once with the file checks and again right before the signature), by `verify` and `publish`, and in CI by `draft-release` and `verify-release`.
- A maintainer signature never covers a `SHA256SUMS` whose `IMAGE_DIGEST` names another package.
- `latest` moves only inside `tn-mainnet` and `adiri` only inside `tn-testnet`, and only to the digest that package serves for the tag being published. The manual alias rollback in the guide refuses a digest outside the alias's package.
- `build` never overwrites a tag that the registry holds without `RELEASE_REBUILD=1`, a private package included, and it makes a package's first push only with `RELEASE_FIRST_PUSH` set to that package and only after the registry answered that the tag is not found or denied (403 Forbidden included).
- The operator check on the install page and in every release body accepts `tn-mainnet@sha256:` only for a mainnet tag and `tn-testnet@sha256:` only for an Adiri tag.
- No workflow asks for the `packages` permission, so the Actions token cannot write any of the three packages.
- The Makefile's ad-hoc targets cannot write a release package.

## Maintainer steps after the first push

Nothing has been pushed and no package exists yet. A release package comes into existence at the first `make release-build` of its network: `tn-testnet` at the first Adiri tag, `tn-mainnet` at the first mainnet tag. That run stops and asks for `RELEASE_FIRST_PUSH`; run it again as `RELEASE_FIRST_PUSH=<package> make release-build TAG=<tag>`. It pushes and stops with `package is not public`. Then, in the package's settings at `https://github.com/orgs/Telcoin-Association/packages/container/<package>/settings`:

1. Change the visibility to public. Operators, `verify-release` and `etc/release.sh` read the package without credentials.
2. Under "Manage access", turn off the access inherited from the repository and give write access to the release maintainer account only.
3. Under "Manage Actions access", leave this repository out or give it the Read role.
4. Run `make release-build TAG=<tag>` again with `RELEASE_REBUILD=1` and without `RELEASE_FIRST_PUSH`, since the first image is now in the registry. This rerun is a full rebuild, so the first release of each network builds twice.

The build server's registry token (a classic personal access token with only `write:packages`) has to belong to that release maintainer account.

`tn-dev` comes into existence with the first `make docker-adiri` or `make docker-devnet` push. No release reads it, so its visibility and access list are the maintainers' choice.

The node deployment scripts in tn-node-deployment still name the old package and change in their own pull request.

## Testing

- `./etc/release.sh parse` for `v0.1.0` (mainnet, `tn-mainnet`, alias `latest`), `v0.1.0-rc1` (mainnet, `tn-mainnet`, prerelease, no alias), `v0.17.0-adiri` (adiri, `tn-testnet`, alias `adiri`) and `v0.17.0-adiri-rc2` (adiri, `tn-testnet`, prerelease, no alias); `v0.1.0-mainnet` and `v0.1.0-adiri-adiri` exit 2.
- With the file sourced, `check_sums_package` refuses a `tn-testnet` `IMAGE_DIGEST` on a mainnet tag and a `tn-mainnet` one on an Adiri tag (exit 1), and passes the matching package. `check_digest_package` refuses another package, `sha256:XYZ`, a trailing CR, `<IMAGE>@`, two lines and a line without `@` (exit 1), and passes a well-formed line with or without its final newline.
- `cmd_draft` on an existing draft, with gh and the release stubbed: exit 0 for a well-formed `IMAGE_DIGEST` (the body carries its digest), exit 1 for `<IMAGE>@sha256:XYZ`, a trailing CR and `<IMAGE>@`.
- `cmd_build` up to its build step, with docker, git and the release stubbed and the anonymous read refused: when the login sees the tag, exit 2 before the build, with `RELEASE_REBUILD=1` and with `RELEASE_YES=1 RELEASE_FIRST_PUSH=tn-mainnet` alike; when the registry answers not found, denied or 403 Forbidden, exit 2 with only `RELEASE_YES=1` or with `RELEASE_FIRST_PUSH=tn-testnet`, and it goes on with `RELEASE_FIRST_PUSH=tn-mainnet`; a DNS failure, an expired login (401) and a local permission error exit 3 after three attempts, even with `RELEASE_FIRST_PUSH=tn-mainnet`; an inspect without a digest exits 1.
- `RELEASE_DRY_RUN=1 RELEASE_IMAGE=localhost:5000/x` sets the image to `localhost:5000/x`; without `RELEASE_DRY_RUN` the override is refused with exit 2.
- `make release-lint` passes (pinned actionlint 1.7.12 and shellcheck 0.11 with `-S style`), `bash -n` passes under bash 5.3 and 3.2, and `mdbook build docs` succeeds.
- Not exercised end to end: the push itself, the stop after it and publish's alias check, which need a registry write.
