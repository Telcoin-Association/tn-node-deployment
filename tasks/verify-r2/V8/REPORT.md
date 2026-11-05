# V8 report: UPS round 2, per-network image packages (telcoin-network)

This report covers three rounds. The final tip, `7ae07a950` (draft PR Telcoin-Association/telcoin-network#1784), comes first and is the current status. The re-verification at `57b8ec90a` and the first round at `0ba57016d` follow as the record of what was found then.

Target: `~/coding/telcoin/tn-r2-packages`, branch `release-packages-per-network`, tip `0ba57016d`, six
commits over origin/main `a0d6e6e26` (e595f9809, 930afd05d, a883fed98, 60d00d284, 848a47b5f,
0ba57016d). Treated as read-only: after every run `git status --porcelain` there is `?? tasks/` only.
Verified 2026-11-04 against `spec-r2-UPS.md` and `spec-r2-V8.md`. I built the harness before
reading the implementer's checkpoint and PR body.



## Final tip 7ae07a950 (2026-11-04)

The branch gained one commit, 7ae07a950 "release: stop the first-push check on anything but a clear answer", which touches `etc/release.sh` (`login_digest`, `cmd_build`) and one failure-table row in `docs/src/maintainers/releasing.md`. The branch now has ten commits and the same nine files, all on the spec's list, with no trailers. The worktree is untouched (`?? tasks/` only).

Result of `bash run_all.sh` at 7ae07a950: **484 assertions, 484 pass, exit 0.**

```text
t1_matrix: 37 passed, 0 failed
t2_package: 148 passed, 0 failed
t3_env: 35 passed, 0 failed
t4_alias: 11 passed, 0 failed
t5_make: 13 passed, 0 failed
t6_lint: 7 passed, 0 failed
t7_docs: 43 passed, 0 failed
t8_commits: 19 passed, 0 failed
tx1_build: 129 passed, 0 failed
tx2_draft: 42 passed, 0 failed
SKIP tx3_ghcr_probe (opt-in, V8_NETWORK=1)
```

The 57b8ec90a harness gave 437 pass and 17 fail on this commit, and every failure was one of the intended changes. The harness changes for 7ae07a950:
- `drive.sh`: `sleep` is stubbed in the build scenario, because `login_digest` now retries with `sleep 5`. New `LOGIN=msg:<text>` gives any inspect error, and `LOGIN_SEQ` gives one answer per attempt.
- `tx1_build.sh`: the private and login-error groups are rewritten, and the new answer-sorting cases are added (99 cases became 129).
- `t7_docs.sh`: the new private row.
- `t8_commits.sh`: the pins are now tip `7ae07a950` and 10 commits.

The harness still passes shellcheck 0.11 and 0.9 at `--severity=error`, and `bash -n`.

### N15 and N16: fixed

**N15, fixed.** When the login sees the tag in a package that refuses anonymous reads, build now exits 2 before any build or push, whatever `RELEASE_REBUILD`, `RELEASE_FIRST_PUSH` and `RELEASE_YES` say (tx1 `*-private`, `*-private-rebuild`, `*-private-rebuild-no-push`, `*-private-everything`). The refusal reads: `<IMAGE> is private, not new, and already holds <IMAGE>:<TAG> (<digest>): do the one-time setup first (make the package public and set its access list, as the maintainer guide says), then run make release-build TAG=<TAG> again, with RELEASE_REBUILD=1 if the tag must be rebuilt`. The guide's failure-table row now says the same (t7 `docs-row-private*`).

**N16, fixed.** `login_digest` sorts failed inspects.
- These answers count as "the login does not see the tag": `not found`, `manifest unknown`, `name unknown`, and `denied`, matched case-insensitively. Without `RELEASE_FIRST_PUSH` the run exits 2; with the matching value it pushes and stops at exit 2 (tx1 `*-login-*-not-seen`, `*-fp-pushes`).
- Everything else is tried 3 times, with 2 waits, and then exits 3 with `cannot ask the registry for <IMAGE>:<TAG> with the docker login after 3 attempts: <last line> (check the network, and run make docker-login if the login expired)`. That covers a DNS failure, `401 Unauthorized`, and a local `permission denied`, which is matched before `denied`. None of them pushes, even with `RELEASE_FIRST_PUSH` (tx1 `*-login-error*`, `*-login-unauthorized`, `*-login-local-permission-denied`).
- A failure followed by `not found` counts as not seen. A failure followed by the digest counts as private (tx1 `*-login-flaky-then-*`).

The PR body (`tasks/pr-body-UPS.md`) already describes both changes, and its guarantee now carries the qualifier "only after the registry answered that the tag is not found or denied".

### N19, new NOTE: the sorting depends on the registry's wording

Last round, an anonymous inspect of `ghcr.io/telcoin-association/tn-mainnet:v0.1.0` (tx3) answered `ERROR: failed to authorize: failed to fetch anonymous token: unexpected status from GET request to https://ghcr.io/token?...: 403 Forbidden`. That text contains neither `denied` nor `not found`, so the sorter treats such an answer as a retryable failure and exits 3 (tx1 `*-login-403-forbidden`).

The authenticated answer for a never-pushed package was not exercised here, because that needs the maintainer's login. ghcr probably answers a logged-in pull of a package that does not exist with `denied` or `not found`, which the sorter handles. If it answers with this 403 text instead, a network's first push cannot start. It would stop with exit 3, quoting that line, so this fails closed and is not unsafe.

Optional one-line fix: add `*"403 forbidden"*` to the not-seen patterns. That stays safe, because a 403 means the login cannot read the tag, so it can never be the "sees the tag" case, and the push still needs `RELEASE_FIRST_PUSH=<package>`. Otherwise, watch the first `release-build` of each network.

The opposite slip also exists: a local error whose text contains `not found` (for example a missing helper binary) would read as "not seen". It still needs `RELEASE_FIRST_PUSH` to continue, and the build step would then fail on the same missing tool.

### Verdict at 7ae07a950

W1, W2, W3, N3 and N4 from the earlier rounds and N15 and N16 from the second are fixed and covered by the harness: 484 of 484 pass. Nothing at ERROR or WARN remains. The open NOTEs are N14, N17, N18 and N19, plus the first-round NOTEs N1, N2 and N5-N13. They are optional hardening, and none blocks the draft PR, which is open as #1784.

---

## Re-verification at 57b8ec90a (2026-11-04)

Three commits were added on top of `0ba57016d`:
- e68eac852 release: check the whole IMAGE_DIGEST line in one place
- d93aba218 release: make the first push of a package explicit
- 57b8ec90a docs: the first push needs RELEASE_FIRST_PUSH

Together they touch `etc/release.sh`, `docs/src/maintainers/releasing.md` and `.github/ACTIONS.md`. The branch now has nine commits and nine files, all on the spec's list, with no trailers. The worktree is still read-only (`?? tasks/` only).

Result of `bash run_all.sh` at 57b8ec90a: **451 assertions, 451 pass, exit 0.**

```text
t1_matrix: 37 passed, 0 failed
t2_package: 148 passed, 0 failed
t3_env: 35 passed, 0 failed
t4_alias: 11 passed, 0 failed
t5_make: 13 passed, 0 failed
t6_lint: 7 passed, 0 failed
t7_docs: 41 passed, 0 failed
t8_commits: 18 passed, 0 failed
tx1_build: 99 passed, 0 failed
tx2_draft: 42 passed, 0 failed
SKIP tx3_ghcr_probe (run once with V8_NETWORK=1, see below)
```

Run unchanged against the new tip, the first-round harness gave 54 failures. All of them were the reworded refusal texts, the tip and commit count, or the new first-push rules; no exit code was wrong. I then extended the harness:
- `drive.sh`: `LOGIN` modes for `docker buildx imagetools inspect` (D, none, error, nodigest, d-then-warning, or a literal answer), and `IDG_RAW=1`, which writes the file without a final newline.
- `t2_package.sh`: rewritten so that every refusal is matched against the whole refusal shape. It covers 22 IMAGE_DIGEST shapes (2 accepted, 19 refused, 1 NUL case) through both check functions on both channels, plus cmd_sign and cmd_verify for three refusals.
- `tx1_build.sh`: the first-push half rewritten for `login_digest` and `RELEASE_FIRST_PUSH`.
- `tx2_draft.sh`: updated to the new refusal shape.
- `t7_docs.sh`: 9 new assertions on the new docs text.
- `t8_commits.sh`: the expected tip and commit count are parameters (`V8_TIP`, `V8_COMMITS`).
- `tx3_ghcr_probe.sh`: also runs anonymous `imagetools inspect` reads.

All harness files still pass shellcheck 0.11 and 0.9 at `--severity=error`, and `bash -n`.

### Status of the first-round findings

| finding | status | evidence at 57b8ec90a |
|---|---|---|
| W1 draft dropped a malformed digest | **fixed** | tx2 42/42. `cmd_draft` now exits 1, with `::error::` and before render or edit, on each of these: `<IMAGE>@sha256:XYZ`, a trailing CR, `<IMAGE>@`, a 0-byte file, an empty line, two lines, another package, the old package, a tag reference without `@`. A well-formed line, with or without its final newline, keeps its digest in the body. |
| W2 first-push guard | **fixed** | tx1 99/99, details below. |
| W3 PR-body overstatements | **fixed** | The rewritten `tasks/pr-body-UPS.md` now says only the package name comes from the tag and the owner from `RELEASE_REPO` or `GITHUB_REPOSITORY` (t3 still shows `ghcr.io/someone-else/tn-mainnet`). It describes `check_digest_package` accurately (one line, the repository before the first `@`, `sha256:<64 hex>`), with the registry match left to `check_image_digest_file`. It says "This rerun is a full rebuild, so the first release of each network builds twice". One guarantee needs a qualifier: N16. |
| N3 refusal shape | **fixed** | t2 148/148 and tx2. Every refusal reads `IMAGE_DIGEST <problem>, but <TAG> is on the <channel> channel, whose images are published only in <IMAGE> (expected the one line <IMAGE>@sha256:<64 hex>); <advice>`. The problem is one of `names an image in <repo>`, `names '<line>', which is not an image by digest`, `holds <N> lines`, or `names <IMAGE> with the malformed digest '<digest>'` (non-printing bytes shown as `?`). The guide quotes this refusal for one case, and t7 checks that the quote is a verbatim prefix of what the code prints for it. |
| N4 two "single line" rules | **resolved** | Only `awk 'END { print NR }'` in `check_digest_package` remains: a trailing blank line gives `holds 2 lines`, and a 0-byte file gives `holds 0 lines`. |
| N1 cheaper resume | not built | Now documented: the first release of each network builds twice (guide one-time setup step 3, PR body step 4). |
| N2, N5-N13 | unchanged | As in the first round. |

### W2 in detail (tx1, both channels)

When the anonymous read is denied, `build` asks the login with `docker buildx imagetools inspect <IMAGE>:<TAG> --format '{{println .Manifest.Digest}}'`, for the channel's package only. The public paths never call it (`*-normal`: no `imagetools inspect` among the calls).

**The login sees the tag.** build warns `<IMAGE> is private, not new: it refuses anonymous reads, but the docker login sees <IMAGE>:<TAG> at <digest>; make the package public as the maintainer guide's one-time setup says`. It then exits 1 with `... already exists (<digest>); set RELEASE_REBUILD=1 to rebuild it` before any build. That happens even with `RELEASE_YES=1 RELEASE_FIRST_PUSH=<package>`.

**The login does not see the tag.**
- With no `RELEASE_FIRST_PUSH`, with only `RELEASE_YES=1`, and with `RELEASE_YES=1 RELEASE_REBUILD=1`: exit 2 before any build, with `<IMAGE> refuses anonymous reads and the docker login does not see <IMAGE>:<TAG>: if this is the first release image of the package <package>, run again with RELEASE_FIRST_PUSH=<package>; otherwise make the package public (maintainer guide, one-time setup)`. `RELEASE_YES=1: continuing without a prompt` never appears; cmd_build has no `confirm` any more.
- With the other network's package, the full image name, the upper-case name or `1`: exit 2 `RELEASE_FIRST_PUSH is <value>, but <TAG> is on the <channel> channel, whose package is <package>`.
- Only the matching value continues. It warns, builds with the channel's `CARGO_FEATURES`, runs `--version`, pushes `<IMAGE>:<TAG>`, and stops with exit 2, `... is pushed, but the package is not public: ...`, with no IMAGE_DIGEST, upload or verify.

**The inspect answers without a valid digest** (other text, `sha256:XYZ`, or a warning after the digest): exit 1 `docker buildx imagetools inspect <IMAGE>:<TAG> answered without a digest: ...`, before any build.

`RELEASE_FIRST_PUSH` changes nothing on a public package. With the tag already present, the run still exits 1 without `RELEASE_REBUILD`.

### Re-checked at 57b8ec90a

- `check_version_output` still runs before `docker push` on the first-push path and on the normal path, for both channels (tx1 `*-fp-order`, `*-normal-order`). Wrong build features stop the run before the push on both paths, and the error is the feature refusal (`*-badfeat`, `*-is-feature-refusal`).
- The stop after the push is still exit 2 (tx1 `*-fp`, `*-post-denied`, `*-private-rebuild`).
- The check 1 matrix is unchanged (t1 37/37, table below).
- Lints, t6 7/7: `bash -n` under 5.3 and bash:3.2, host `shellcheck -x -S style etc/release.sh`, host actionlint, and `make release-lint` with the cached pinned images and `--network none`. bash:3.2 `parse` works.
- `mdbook build docs` (0.5.4) succeeds on the branch and on origin/main, 0 warnings each.
- Docs, t7 41/41:
  - the `RELEASE_FIRST_PUSH=tn-testnet make release-build` command;
  - "`RELEASE_YES=1` never stands in for it";
  - "This is a full rebuild, so the first release of each network builds twice";
  - the two new failure-table rows ("stops and asks for `RELEASE_FIRST_PUSH`" and "private, not new");
  - the old "asks whether to push" prompt is gone from releasing.md and ACTIONS.md;
  - ACTIONS.md item 3 names `RELEASE_FIRST_PUSH`;
  - the `etc/release.sh` header documents `RELEASE_FIRST_PUSH=PACKAGE`.

Anonymous reads (`V8_NETWORK=1 bash tx3_ghcr_probe.sh`, with an empty `DOCKER_CONFIG`, so no credential is used):
- The token endpoint still answers 403 for tn-mainnet, tn-testnet, tn-dev, telcoin-network and a made-up name.
- `imagetools inspect ghcr.io/orhun/git-cliff/git-cliff:2.10.1 --format '{{println .Manifest.Digest}}'` exits 0 and prints only `sha256:6ba0d1fc...` (the digest `etc/release.sh` pins), which is what `login_digest` parses.
- A missing tag gives rc 1 `ERROR: ...: not found`.
- tn-mainnet gives rc 1 `failed to authorize: ... 403 Forbidden`.
- The authenticated answer for a private or never-pushed package was not exercised: that would need the maintainer's login.

### New at 57b8ec90a: no ERROR, no WARN; NOTEs

- **N14.** `$(cat)` in bash drops a NUL byte ("ignored null byte"), so `<IMAGE>@sha256:<hex>` followed by a NUL passes `check_digest_package` (t2 `file-*-nul-byte-accepted`). Every reader sees the same well-formed reference: release.sh, and the operator block's `$(cat IMAGE_DIGEST)`. SHA256SUMS hashes the bytes and build never writes such a file, so nothing is gained by it. A strict byte check would close it; this is optional.
- **N15. A private package with `RELEASE_REBUILD=1` builds into a dead end.** When the login sees the tag, the run's last error line says `set RELEASE_REBUILD=1`. Following it rebuilds and pushes into the still-private package, and the run then stops at exit 2 (tx1 `*-private-rebuild`), whose message asks for another `RELEASE_REBUILD=1` run: two full builds. The guide's row has the right order (make the package public, then rebuild if needed). Exiting 2 before the build when the login sees the tag would save both, because that run cannot finish anyway.
- **N16.** `login_digest` reads any failed inspect as "the login does not see the tag". With a DNS failure and `RELEASE_FIRST_PUSH=<package>`, build goes on and pushes (tx1 `*-fp-login-error-pushes`); without the variable it exits 2 as it should. Reaching the push needs two things together: an operator who sets `RELEASE_FIRST_PUSH` on a package that already holds the tag, and a transient inspect failure. A login that cannot read a package cannot push to it either. So the PR guarantee "build never overwrites a tag that the registry holds without `RELEASE_REBUILD=1`, a private package included" holds whenever the inspect answers. To close it, either exit 3 on inspect failures other than not-found/denied, or qualify the guarantee.
- **N17.** An inspect that prints anything after the digest exits 1 (tx1 `*-login-d-then-warning`). That is fail-closed; the real buildx printed only the digest.
- **N18.** The refusals print the repository part, and a line without `@`, as the file holds them. Only the digest is sanitised, so a CR in the repository part reaches the log as is. Cosmetic.

### Verdict at 57b8ec90a

W1, W2, W3 and N3 are fixed and covered by the extended harness (451/451). The first-push path can no longer be answered by `RELEASE_YES`. It needs the exact package name, never bypasses the `RELEASE_REBUILD` rule when the login can see the tag, and still gates the push behind the version and feature check. It still stops with exit 2 before anything reaches the draft. Docs and the PR body match the code. **The branch is ready for the draft PR.** The remaining items are NOTEs. N15 and N16 are one-line hardening options for the implementer or the orchestrator to take or leave, and N16 may instead be answered by qualifying one PR-body guarantee.

---

## Harness (first round, at 0ba57016d; extended at 57b8ec90a as above)

Everything is in this directory. Each script has a shebang and passes `bash -n`, host shellcheck
0.11 and `koalaman/shellcheck:v0.9.0` with `-x --severity=error`. Rerun everything with
`bash run_all.sh`. Output goes to the session scratchpad (`$SCRATCH/out/<case>.txt`).

- `lib.sh`: paths and `expect NAME RC WANT [NOT] -- CMD`.
- `drive.sh SCENARIO TAG`: sources `etc/release.sh` (sourcing only defines functions) and replaces
  only the calls that reach git, gh, docker, gpg, curl or the registry. Everything else runs the
  real functions: `parse_tag`, `init_env`, `check_digest_package`, `check_sums_package`,
  `check_image_digest_file`, `check_release_files`, `confirm`, `image_binary`,
  `check_version_output`, `write_sums`, `registry_digest` (curl stubbed), `cmd_build`,
  `cmd_sign`, `cmd_verify`, `cmd_publish`, `cmd_draft` and `cmd_check_tag`.
- `t1_matrix.sh` (check 1), `t2_package.sh` (2), `t3_env.sh` (3), `t4_alias.sh` (4),
  `t5_make.sh` (5), `t6_lint.sh` (6), `t7_docs.sh` (7), `t8_commits.sh` (8),
  `tx1_build.sh` (first-push path, and `check_version_output` before the push),
  `tx2_draft.sh` (draft fail-closed), `tx3_ghcr_probe.sh` (anonymous ghcr reads, only with
  `V8_NETWORK=1`).

Result of `bash run_all.sh` in the first round, at 0ba57016d:

```text
t1_matrix: 37 passed, 0 failed
t2_package: 82 passed, 0 failed
t3_env: 35 passed, 0 failed
t4_alias: 11 passed, 0 failed
t5_make: 13 passed, 0 failed
t6_lint: 7 passed, 0 failed
t7_docs: 32 passed, 0 failed
t8_commits: 15 passed, 0 failed
tx1_build: 53 passed, 0 failed
tx2_draft: 16 passed, 6 failed      <- W1
SKIP tx3_ghcr_probe (ran once with V8_NETWORK=1, output under N9)
```

Of 301 assertions, 295 pass. All 6 failures are finding W1.

## Findings (first round, at 0ba57016d)

### ERROR

None. I found no path that pushes a mainnet image into tn-testnet (or the reverse), skips the
version and feature check, signs or verifies an IMAGE_DIGEST from another package, or moves an
alias outside the tag's package.

### WARN

**W1. `draft` still drops a malformed digest without a word when the repository is right.**
`etc/release.sh`, `cmd_draft`.
- Command: `bash tx2_draft.sh`, cases `draft-*-bad-digest-fails`, `-crlf-fails` and
  `-empty-digest-fails`. Single case: `GITHUB_ACTIONS=true GITHUB_REPOSITORY=Telcoin-Association/telcoin-network IDG='@SELF@@sha256:XYZ' bash drive.sh draft v0.1.0`.
- Expected (the claim as briefed, "draft now fails when an existing draft's IMAGE_DIGEST names
  another package or is malformed"): exit 1 before the body is rendered or edited.
- Actual: exit 0. The output is `render_notes digest=[]`, then `gh release edit v0.1.0 ... --notes-file`,
  then `draft release v0.1.0 is ready`. The same happens for a trailing CR (`...@sha256:<hex>\r`)
  and for an empty digest (`<IMAGE>@`), on both channels.
- Draft does fail closed for another network's package, the old `telcoin-network` package,
  another owner, a tag reference without `@`, an empty file and two lines (16 PASS). The cause:
  `check_digest_package` checks only the repository, and the next line,
  `if ! [[ "$digest" =~ $DIGEST_RE ]]; then digest=; fi`, still drops the digest silently.
- Impact: low. sign, verify and publish all refuse a malformed digest (through
  `check_image_digest_file`, t2 `file-*-bad-digest`, `verify-*-bad-digest`). The implementer's
  checkpoint says this was kept "as before". But the PR body calls `check_digest_package` "the one
  place that decides whether an IMAGE_DIGEST is acceptable: a single line `<IMAGE>@<digest>`",
  and a file that was not written by build is still accepted here.
- Fix: replace the silent drop with
  `die 1 "IMAGE_DIGEST holds a malformed digest: $digest; ..."`, or let `check_digest_package`
  also check `DIGEST_RE` so that every caller gets it. Alternatively, reword the PR body.

**W2. On the first-push path, a private package that already holds `:TAG` is rebuilt and pushed
over without `RELEASE_REBUILD=1`, and `RELEASE_YES=1` answers the one prompt where the guide says
to answer no.** `etc/release.sh`, `cmd_build`, `registry_digest ... first-push`.
- Command: `RELEASE_YES=1 REG_SEQ=denied,denied bash drive.sh build v0.1.0`
  (tx1 `build-*-private-existing-overwritten`), compared with `REG_SEQ=D bash drive.sh build v0.1.0`
  (tx1 `build-*-rerun-no-rebuild`).
- Expected: a tag that already exists in the package is rebuilt only with `RELEASE_REBUILD=1`.
- Actual: for an anonymous 401/403, build sets `existing=` and skips the `RELEASE_REBUILD` rule.
  It then prints `RELEASE_YES=1: continuing without a prompt`, builds, and runs
  `docker push ghcr.io/telcoin-association/tn-mainnet:v0.1.0`. Only after the push does it stop,
  with exit 2 (`... is pushed, but the package is not public ...`). The public-package case
  stops at exit 1 (`... already exists (sha256:...); set RELEASE_REBUILD=1 to rebuild it`)
  before any build.
- Why: the anonymous probe cannot tell "never pushed" from "private". tx3 measured 403 for both.
  The prompt also says "Push ... as the first image of the package", which is false for a private
  package. The guide's failure table says to answer yes only on a network's first release. That
  judgement is exactly what `RELEASE_YES=1` skips. Before this branch, build had no prompt that
  `RELEASE_YES` could answer.
- Impact is bounded, and the stop is fail-closed (tx1):
  - build refuses a published release and a draft with `SHA256SUMS.asc` before the probe.
  - It writes no IMAGE_DIGEST or SHA256SUMS and uploads nothing after the stop.
  - Older assets on the draft now disagree with the registry, so verify and sign refuse them
    (t2 `file-*-registry-differs`).
  - Rerunning before the setup is done repeats the full build and push each time.
- Fix: when the anonymous read is denied, ask the registry with the login that build already
  requires (`require_registry_login`), for example `docker buildx imagetools inspect "$IMAGE:$TAG"`.
  - If it resolves, the tag exists: apply the `RELEASE_REBUILD` rule and tell the operator the
    package is private.
  - Only otherwise, ask the first-push question.
  - Have a dedicated variable answer that question (for example `RELEASE_FIRST_PUSH=<package>`)
    instead of `RELEASE_YES`, as `check_build_sums_hash` already does for sign.

**W3. Two PR-body sentences claim more than the code does.** `tasks/pr-body-UPS.md`.
- "The package depends on the tag alone. No variable, flag or `make` setting chooses it outside a
  dry run." Actual (t3 `repo-other-owner`, `repo-ci-fork`): outside a dry run,
  `RELEASE_REPO=Someone-Else/telcoin-network` gives `IMAGE=ghcr.io/someone-else/tn-mainnet`, and
  so does `GITHUB_REPOSITORY` in a fork. That is the spec's design (S1: OWNER from REPO), and only
  the package name depends on the tag alone. The body's own earlier bullet says so; the guarantee
  should too.
- "`check_digest_package` is the one place that decides whether an IMAGE_DIGEST is acceptable: a
  single line `<IMAGE>@<digest>`." Actual: it checks the repository and that there is one line.
  `check_image_digest_file` checks the digest form and the line count separately (N4), and draft
  does not check the digest form at all (W1).
- Fix: reword both, or fix W1 so that the second becomes true.

### NOTE

- **N1. A cheaper safe rerun after the first-push stop exists.** Today the rerun is a full
  `--no-cache` rebuild with `RELEASE_REBUILD=1`. Builds are not reproducible, so it also leaves
  the first image untagged in the package. A resume can stay as safe as long as all of these
  hold:
  - the registry now serves `$IMAGE:$TAG` at digest E;
  - the local `$IMAGE:$TAG` has `RepoDigests` containing `$IMAGE@E` (docker push records it);
  - its labels `org.opencontainers.image.revision` and `.version` equal `$COMMIT` and `$TAG`.

  Under those conditions build can skip `buildx build` and `docker push` and keep everything
  after them: `image_binary`, `check_version_output`, the tarball from the image,
  the `RepoDigests` comparison, IMAGE_DIGEST, `write_sums`, the uploads and `cmd_verify 1`, which
  pulls by digest and compares the binaries. Anyone who could swap the local image could also
  tamper with a rebuild, so nothing is lost. Make it explicit (`RELEASE_RESUME=1`) rather than
  automatic.
- **N2.** `check_sums_package` in `cmd_sign` and `cmd_verify` cannot be the check that refuses
  another package in the real flow: `check_release_files` runs first, and through
  `check_image_digest_file` it already refuses one (t2 `sign-*-other` shows the default advice,
  not "do not sign it"). The new check is only reached with `check_release_files` stubbed (t2
  `*-iso-*`). It is harmless defence in depth, and the guide's "checks once more right before it
  signs" is accurate.
- **N3.** Spec V8 check 2 asks that "each refusal names the channel and both packages". Only the
  wrong-package refusal does: `IMAGE_DIGEST names an image in ghcr.io/telcoin-association/tn-testnet, but v0.1.0 is on the mainnet channel, whose images are published only in ghcr.io/telcoin-association/tn-mainnet; ...`.
  The other three name less:
  - a missing `@`: `names '...', not an image by digest; expected <IMAGE>@sha256:<hex>`, with
    no channel;
  - two lines: `IMAGE_DIGEST must be a single line`, with neither;
  - a malformed digest: `holds a malformed digest: sha256:XYZ`, with neither.

  The UPS spec asks for the channel and the packages only on the mismatch, so this is a NOTE.
  Appending "(the <channel> channel's images are in <IMAGE>)" would cover all of them.
- **N4.** There are two definitions of "single line":
  - `check_digest_package` looks for a newline after `$(cat)` has stripped trailing newlines;
  - `check_image_digest_file` uses `awk 'END { print NR }'`.

  A file with a trailing blank line passes the first and fails the second (t2
  `file-*-trailing-blank`). The second runs at every gate, so nothing slips through.
- **N5.** A dry run uses one `RELEASE_IMAGE` for both channels (t3 `dry-image-*`: both give
  `IMAGE=localhost:5000/x`), so a rehearsal cannot show the package split. This is per spec.
  Appending `/$PACKAGE` in dry runs would be a spec change and is the orchestrator's call.
- **N6.** `RELEASE_REPO` is honoured outside a dry run and sets the image owner, with a
  `warning: using repository ...` line. This is unchanged from origin/main, where the image was
  `ghcr.io/lower(REPO)`. The draft lookup uses the same repository, so the release and the
  package stay consistent. It can never change the package name: `RELEASE_REPO=Telcoin-Association/tn-testnet`
  on a mainnet tag still gives `tn-mainnet` (t3 `repo-named-like-package*`).
- **N7.** `GHCR_IMAGE` can be overridden on the make command line (t5 `make-override-possible`).
  The recipes hard-code the `:dev-<flavor>-$(TAG)` tag, so even an override cannot write
  `:vX.Y.Z`, `:latest` or `:adiri`. The package access list is the real control. The PR's
  "ad-hoc targets cannot write a release package" holds for release tags.
- **N8.** The operator image-check block, on the install page and in every release body, prints
  its refusal on stderr and exits 0. This is unchanged from origin/main, and harmless for
  copy-paste use.
- **N9.** The premise holds. Anonymous reads on 2026-11-04 (`V8_NETWORK=1 bash tx3_ghcr_probe.sh`)
  got token 403 for tn-mainnet, tn-testnet, tn-dev, telcoin-network and a made-up name. The
  public `orhun/git-cliff/git-cliff` got token 200, manifest 200 for an existing tag and 404 for
  a missing one. `registry_digest` maps a 403 from the token endpoint to `denied` (tx1
  `reg-token-403-first-push`). A curl failure (000) and a 500 stay retryable outages, exit 3,
  never `denied`.
- **N10.** The stop after the first push is the only reminder of the access-list step in the
  one-time setup. If a new package ever answered anonymously right after its first push, build
  would continue without that reminder. A `warn` naming the access-list step whenever the
  pre-push probe was denied would cost one line.
- **N11.** The draft refusal's advice ("rebuild the draft with make release-build TAG=...") is
  not enough on its own when the draft already holds `SHA256SUMS.asc`, or when `:TAG` exists:
  build then refuses. The guide's "failed `release-verify`" row has the full recipe, and the
  message could point there.
- **N12.** The implementer's checkpoint lists two paths as "not exercised end to end": the
  first-push path and publish's alias assertion. With stubbed I/O they are covered here (tx1, 53
  cases; t4, 11 cases), including `check_version_output` running before `docker push` on both
  channels (tx1 `*-order`, `*-badfeat`).
- **N13.** 848a47b5f only rewords the refusal from 930afd05d (implementer open issue 1). The
  first-push change is in 930afd05d, and that commit's message describes it.

## Matrix (check 1; same output at 0ba57016d and 57b8ec90a; `./etc/release.sh parse TAG`; IMAGE from `init_env`, default environment)

| tag | rc | CHANNEL | PACKAGE | IMAGE | ALIAS | PRERELEASE | FEATURES |
|---|---|---|---|---|---|---|---|
| `v0.1.0` | 0 | mainnet | tn-mainnet | ghcr.io/telcoin-association/tn-mainnet | latest | false | (none) |
| `v0.1.0-rc1` | 0 | mainnet | tn-mainnet | ghcr.io/telcoin-association/tn-mainnet | (none) | true | (none) |
| `v0.17.0-adiri` | 0 | adiri | tn-testnet | ghcr.io/telcoin-association/tn-testnet | adiri | true | adiri |
| `v0.17.0-adiri-rc2` | 0 | adiri | tn-testnet | ghcr.io/telcoin-association/tn-testnet | (none) | true | adiri |
| `v0.1.0-mainnet` | 2 | `error: not a release tag: 'v0.1.0-mainnet' (expected vX.Y.Z, vX.Y.Z-rcN, vX.Y.Z-adiri or vX.Y.Z-adiri-rcN)` | | | | | |
| `v0.1.0-adiri-adiri` | 2 | refused, same message | | | | | |
| `V0.1.0` | 2 | refused, same message | | | | | |
| `v01.0.0` | 2 | refused, same message | | | | | |
| extra: `v0.1.0-rc0`, `v0.1.0-rc1-adiri`, `v0.1.0-testnet`, `"v0.1.0 "`, `v0.1.0<LF>x`, `v0.1`, `""` | 2 | refused, same message | | | | | |

## Results by check (first round, at 0ba57016d)

| check | script | result | key actual output |
|---|---|---|---|
| 1 parse matrix | t1_matrix.sh | 37/37 | table above |
| 2 sign/verify-time package checks | t2_package.sh | 82/82 | wrong package (other network, old package, other owner, upper case, `:tag@digest`): exit 1 with the refusal quoted in N3; checked before `registry_digest` and `docker pull`; cmd_sign stops before `confirm` and `gpg`; a two-line file gives `single line`; a malformed digest gives `holds a malformed digest`; SHA256SUMS missing, twice or with a wrong hash gives `does not list the IMAGE_DIGEST beside it exactly once with its hash`; the right package reaches `gpg` / `verified v0.1.0 commit=...` |
| 3 RELEASE_IMAGE / RELEASE_REPO | t3_env.sh | 35/35 | dry run gives `IMAGE=localhost:5000/x`; without it (set, empty, `=0`; init_env and the real CLI for check-tag, build, sign, verify, publish): exit 2 `RELEASE_IMAGE is honoured only in a dry run (RELEASE_DRY_RUN=1)`; a ghcr RELEASE_IMAGE in a dry run is refused; RELEASE_REPO changes the owner, never the package (N6); check-tag logs `PACKAGE=` and `IMAGE=` |
| 4 alias in package | t4_alias.sh | 11/11 | release.sh line 2110 `docker buildx imagetools create --prefer-index=false --tag "$IMAGE:$ALIAS" "$IMAGE@$D"`; publish v0.1.0 moves `tn-mainnet:latest` to `tn-mainnet@sha256:aa..`; v0.17.0-adiri moves `tn-testnet:adiri`; rc tags: `alias=none`; a moved or missing `:TAG`: exit 1 before `imagetools create` |
| 5 Makefile | t5_make.sh | 13/13 | `make -n docker-adiri/devnet/push` give `ghcr.io/telcoin-association/tn-dev:dev-...`; the only push lines are 453, 458 and 462 on `$(GHCR_IMAGE)`; release-* run `./etc/release.sh <step> "TAG"`; no recipe names tn-mainnet or tn-testnet |
| 6 lints | t6_lint.sh | 7/7 | `bash -n` (5.3 and bash:3.2), host `shellcheck -x -S style etc/release.sh`, host actionlint, `make release-lint` (pinned images, `--network none`, ro mount): all clean; bash:3.2 `parse` works on the branch and on origin/main |
| 7 docs | t7_docs.sh | 32/32 | two remaining old-package mentions, both "never held a release and is no longer used" (ACTIONS.md:477, releasing.md:35); SECURITY.md and etc/README.md do not name the package; the install-page block and the release-body block accept only `tn-mainnet@sha256:` for mainnet tags and `tn-testnet@sha256:` for adiri tags (look-alike, tag reference and old package refused); the rollback `case` refuses the other package; mdbook 0.5.4 builds branch and origin/main with 0 warnings each |
| 8 commits / scope | t8_commits.sh | 15/15 | six commits, linear, prefixes release/make/ci/docs, no trailers (`git interpret-trailers --parse` empty), no attribution; 9 files changed, all on the spec's list |
| X1 first-push | tx1_build.sh | 53/53 | without a TTY or RELEASE_YES: exit 2 before any build; with RELEASE_YES=1: build with the channel's `CARGO_FEATURES`, `--version` check, then `docker push <channel package>:TAG`, then exit 2 `... is pushed, but the package is not public: do its one-time setup (maintainer guide), then run make release-build TAG=... again with RELEASE_REBUILD=1`; no IMAGE_DIGEST, upload or verify; bad features stop before the push on both paths and both channels; see W2 |
| X2 draft | tx2_draft.sh | 16/22 | another package, no `@`, empty, two lines: exit 1 before render or edit, with `::error::`; a malformed digest in the right package: exit 0, digest dropped (W1) |
| X3 premise | tx3_ghcr_probe.sh | ran once | N9 |

## Verdict (first round, at 0ba57016d)

The branch does what the UPS spec asks. The package is a pure function of the tag. Every stage
that reads or writes IMAGE_DIGEST refuses another package, and does so before any pull,
signature or alias move. The alias moves only inside the channel's package. The Makefile writes
only tn-dev. Lints, mdbook and commit hygiene are clean. The first-push path is fail-closed: it
writes no IMAGE_DIGEST and no SHA256SUMS, uploads nothing, and exits 2, after a push that is
gated by the same version and feature check as the normal path.

The branch is ready for a draft PR once two small changes are made:
- W1: make `draft` refuse a malformed digest, a one-line `die`, or else reword the claim.
- W3: correct the two PR-body sentences.

W2 deserves a fix before the PR leaves draft, or at least before the first real release of
either network: use the authenticated registry probe, and a dedicated answer instead of
`RELEASE_YES`. That path runs exactly once per network and is the one place where an operator's
judgement is meant to stop it. N1, a resume instead of a rebuild, is an optional improvement on
the same path.
