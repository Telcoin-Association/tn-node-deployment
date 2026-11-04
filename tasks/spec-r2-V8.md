# Verifier V8: UPS (light, round 2)

Read `tasks/spec-r2-shared.md` and `tasks/spec-r2-UPS.md` first. Verify the telcoin-network
branch `release-packages-per-network` in `~/coding/telcoin/tn-r2-packages` READ-ONLY (never
commit there, never push). Harness and records in `~/coding/telcoin/tnd-r2-V8/tasks/verify-r2/V8/`
(an integration-tree worktree; every `*.sh` with a shebang, shellcheck 0.9 and 0.11
`--severity=error` clean); checkpoint `tasks/ckpt-r2-V8.md`; report
`tasks/verify-r2/V8/REPORT.md` (ERROR / WARN / NOTE with command, expected, actual, file).

1. Dry-run matrix with `./etc/release.sh parse TAG` (no network): `v0.1.0`, `v0.1.0-rc1`,
   `v0.17.0-adiri`, `v0.17.0-adiri-rc2` → channel, PACKAGE, IMAGE, alias, prerelease as the
   spec says; `v0.1.0-mainnet`, `v0.1.0-adiri-adiri`, `V0.1.0`, `v01.0.0` refused.
2. Source `etc/release.sh` in a bash script and call the sign-time and verify-time package
   checks with an `IMAGE_DIGEST` naming the wrong package, a malformed digest, two lines, and
   the right package; each refusal names the channel and both packages.
3. `RELEASE_IMAGE` honoured only with `RELEASE_DRY_RUN=1`; `RELEASE_REPO` changes the GitHub
   slug and not the image package.
4. The alias (`latest`/`adiri`) is created inside the channel's package only (read the publish
   path; show the line).
5. `Makefile`: dev targets push to `tn-dev`; no target pushes to `tn-mainnet`/`tn-testnet`
   except through `etc/release.sh`.
6. `actionlint .github/workflows/release.yaml` and `shellcheck -x -S style etc/release.sh`
   clean; `bash -n`.
7. Docs: every mention of `ghcr.io/telcoin-association/telcoin-network` in the branch's docs,
   README, SECURITY.md, `.github/ACTIONS.md`, `etc/README.md` is gone or describes the old
   package as retired; the verification block in `installing-a-release.md` accepts the
   channel's package only.
8. `git log --format=%B origin/main..release-packages-per-network` has no trailer and no
   attribution line; no file outside `etc/release.sh`, `.github/workflows/release.yaml`,
   `Makefile`, the docs listed in the spec is touched (`git diff --stat origin/main`).

Hand back: the report path, the matrix table with actual outputs, findings by severity.
