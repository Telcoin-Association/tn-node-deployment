status: done

Package UPS (per-network image packages), worktree tn-r2-packages, branch
release-packages-per-network from origin/main a0d6e6e26.

- [x] S1 Package from the channel (e595f9809)
- [x] S2 The package is checked everywhere a digest is read or written (930afd05d)
- [x] S3 Dev images (Makefile) (a883fed98)
- [x] S4 Workflows (release.yaml, release-lint) (60d00d284)
- [x] S5 Docs (0ba57016d; wording fix to the S2 refusal in 848a47b5f)
- [x] S6 Dry-run matrix (records only, nothing to commit)
- [x] V8 fix round: W1 malformed digest fails closed everywhere (+N3 one refusal shape) (e68eac852)
- [x] V8 fix round: W2 first push needs RELEASE_FIRST_PUSH=<package>, login read keeps REBUILD rule (d93aba218)
- [x] V8 fix round: docs for W1/W2/N3 (57b8ec90a)
- [x] V8 fix round: W3 PR body wording; N1 not built, PR body and guide say the rerun is a full rebuild
- [x] V8 fix round: matrix + shellcheck + release-lint + mdbook re-run
- [x] V8 re-verification notes: N16 fail closed on unclear inspect failures, N15 private-with-tag stops before the build (7ae07a950)
- [x] PR body tasks/pr-body-UPS.md (title "release: per-network image packages tn-mainnet and tn-testnet")

## Changes

- S1 (e595f9809): parse_tag sets PACKAGE (tn-mainnet for vX.Y.Z[-rcN], tn-testnet for
  vX.Y.Z-adiri[-rcN]); `parse` prints PACKAGE after CHANNEL; init_env sets
  IMAGE=ghcr.io/<lower owner of REPO>/$PACKAGE (guard: dies 2 if parse_tag has not run);
  RELEASE_REPO/GITHUB_REPOSITORY set only the owner part of the image; RELEASE_IMAGE unchanged
  (dry-run-only whole-name override). Header gains an "Images" paragraph; usage text names the
  packages.
- S2 (930afd05d): new `check_digest_package LINE [ADVICE]` (single line, has "@", repository
  before the first "@" equals IMAGE; else die 1 naming repository found, tag channel, expected
  IMAGE). Used by check_image_digest_file (sign, verify, build self-check, publish) and by draft
  (an existing draft's IMAGE_DIGEST in another package now stops draft; malformed digest after a
  correct repository still renders without a digest as before). New `check_sums_package DIR
  [ADVICE]`: SHA256SUMS lists IMAGE_DIGEST exactly once, its hash equals the file, then
  check_digest_package; sign calls it right before confirm/gpg with advice "do not sign it;
  rebuild the draft with make release-build TAG=..."; verify calls it before counting
  signatures. publish asserts registry_digest TAG == D before moving the alias. cmd_check_tag
  prints the parse + IMAGE= to stderr (CI log). Release body: image check says "does not name
  an image in <IMAGE> by digest; <channel> images are published there and nowhere else".
  First push: registry_digest gains a `first-push` mode that prints `denied` on 401/403
  (ghcr answers 403 for a never-pushed package, verified read-only 2026-11-04 against
  telcoin-association/tn-mainnet, tn-testnet, tn-dev, telcoin-network and a nonexistent name;
  a public package answers 200). build: denied before push -> warn + confirm (RELEASE_YES=1
  answers it), push, denied after push -> die 2 "is pushed, but the package is not public: do
  its one-time setup (maintainer guide), then run make release-build TAG=... again with
  RELEASE_REBUILD=1". Generic 401/403 message keeps the substring "package is not public".
- S3 (a883fed98): Makefile GHCR_IMAGE := ghcr.io/telcoin-association/tn-dev (docker-adiri,
  docker-devnet, docker-push); comment says release packages are tn-mainnet/tn-testnet written
  only by etc/release.sh; help lines name tn-dev and, for release-build, the two packages.
- S4 (60d00d284): release.yaml comments only (no step changes): no job asks for `packages`, so
  the token cannot write tn-mainnet/tn-testnet; validate-tag's "Check the tag" log starts with
  the parse (PACKAGE); verify-release fails on an IMAGE_DIGEST outside the tag's package
  because `verify` takes the package from the channel. The parse in the CI log comes from
  cmd_check_tag (S2), so no new step was needed.
- 848a47b5f (extra commit, S2 scope): the refusal read "v0.17.0-adiri is a adiri tag"; now
  "IMAGE_DIGEST names an image in <repo>, but <TAG> is on the <channel> channel, whose images
  are published only in <IMAGE>; <advice>". Found while writing the docs that quote it.
- S5 (0ba57016d): releasing.md (channel table + package column and paragraph, one-time setup
  rewritten for first push per network, steps 4-7, failure table rows for `package is not
  public`, the first-push prompt and the package refusal, Before publish PACKAGE variable,
  After publish alias move with a case guard); installing-a-release.md (files table, channel
  table + package column, image check derives PACKAGE from TAG, 203/209 lines, troubleshooting
  row); validator-operations.md:82; README.md:14; yubikey-setup.md:278 (+ token must be on the
  release maintainer account); .github/ACTIONS.md item 3 (two release packages + tn-dev, old
  package unused, first-push timing). SECURITY.md and etc/README.md do not name the package:
  unchanged. `mdbook build docs` (0.5.4) OK. Operator case block and alias guard tested in sh.

- V8 W1+N3 (e68eac852): `check_digest_package FILE [ADVICE]` now takes the file and checks
  line count (exactly 1, via awk NR), repository (before the first "@") == IMAGE, and digest
  =~ DIGEST_RE (sha256:<64 hex>). One refusal shape for every case: "IMAGE_DIGEST <holds N
  lines | names '<line>', which is not an image by digest | names an image in <repo> | names
  <IMAGE> with the malformed digest '<d>'>, but <TAG> is on the <channel> channel, whose images
  are published only in <IMAGE> (expected the one line <IMAGE>@sha256:<64 hex>); <advice>"
  (non-printables in the digest shown as "?"). check_image_digest_file drops its own line-count
  and DIGEST_RE checks (now inside); check_sums_package passes the file; cmd_draft calls it on
  the fetched file and no longer blanks a malformed digest (fails closed, exit 1).
- V8 W2 (d93aba218): new `login_digest` (docker buildx imagetools inspect IMAGE:TAG --format
  '{{println .Manifest.Digest}}'; digest printed, or nothing + reason on stderr; success
  without a digest dies 1). cmd_build on anonymous `denied`: login sees TAG -> warn "private,
  not new" and the normal RELEASE_REBUILD rule; login does not see TAG -> RELEASE_FIRST_PUSH
  unset: die 2 naming RELEASE_FIRST_PUSH=<PACKAGE>; set to another value: die 2 naming the
  tag's package; equal: warn and continue. confirm() removed from this path (RELEASE_YES no
  longer reaches it). Post-push `denied` stop unchanged (die 2). Header documents
  RELEASE_FIRST_PUSH=PACKAGE and the Images paragraph says the first push needs it.
- V8 docs (57b8ec90a): releasing.md package paragraph (one well-formed line required, refusal
  quoted in the new shape), one-time setup step 1 (login re-check, RELEASE_FIRST_PUSH, never
  RELEASE_YES), step 3 (full rebuild, first release builds twice), failure table (rows for the
  RELEASE_FIRST_PUSH stop and the "private, not new" warning; package-refusal row generalised);
  ACTIONS.md first-push sentence.
- V8 W3: tasks/pr-body-UPS.md rewritten: package NAME from the tag, owner from the repository;
  check_digest_package described by what it checks (lines, repository, digest form) and
  check_image_digest_file named for the registry check; first-push text for RELEASE_FIRST_PUSH;
  maintainer step 4 says the rerun is a full rebuild (N1 not built).

- V8 N16+N15 (7ae07a950): login_digest classifies the inspect failure: "not found",
  "manifest unknown", "name unknown" or "denied" (case-insensitive, but not "permission
  denied") -> does not see TAG (info, empty); anything else -> retried 3 times (sleep 5) then
  die 3 "cannot ask the registry for IMAGE:TAG with the docker login after 3 attempts: <last
  line> (check the network, and run make docker-login if the login expired)". Private package
  that holds TAG -> die 2 before the build: "IMAGE is private, not new, and already holds
  IMAGE:TAG (D): do the one-time setup first (make the package public and set its access list,
  as the maintainer guide says), then run make release-build TAG=... again, with
  RELEASE_REBUILD=1 if the tag must be rebuilt". releasing.md failure-table row rewritten to
  match. PR body: first-push paragraph, guarantee kept and extended, testing line.

## Docs notes

All docs inside telcoin-network that named the package are updated in S5. Facts for any
downstream docs (tn-node-deployment DOCS-2 owns its own files):
- Release images: `ghcr.io/telcoin-association/tn-mainnet` (tags vX.Y.Z, vX.Y.Z-rcN; alias
  `latest`), `ghcr.io/telcoin-association/tn-testnet` (vX.Y.Z-adiri, vX.Y.Z-adiri-rcN; alias
  `adiri`). Dev images: `ghcr.io/telcoin-association/tn-dev:dev-<flavor>-<TAG>`.
  `ghcr.io/telcoin-association/telcoin-network` is no longer used.
- IMAGE_DIGEST content: one line `ghcr.io/telcoin-association/<package>@sha256:<hex>`.
- `./etc/release.sh parse TAG` prints PACKAGE= after CHANNEL=.
- Refusal text: `IMAGE_DIGEST <what it holds>, but <TAG> is on the <channel> channel, whose
  images are published only in <IMAGE> (expected the one line <IMAGE>@sha256:<64 hex>);
  <advice>`.
- New env: `RELEASE_FIRST_PUSH=<package>` (build only; first image of a package; never
  answered by RELEASE_YES).
- Release body / install page operator message: `IMAGE_DIGEST does not name an image in
  ghcr.io/telcoin-association/<package> by digest: <ref>`.
- tn-node-deployment today maps both networks to ghcr.io/telcoin-association/telcoin-network
  (common.sh TN_GHCR_IMAGE_REPO ~1522, TN_MAINNET_IMAGE_REPO ~6926, tn_docker_resolve_ref
  comment ~7940 "testnet and mainnet share the ghcr repository"; ui/server.py GHCR_IMAGE_REPO
  ~376-388; ui/static/index.html ~2404; ui/test_server_contract.py) - stale once this lands.

## Lints and matrix run

- After S4: `make release-lint` exit 0 (pulled rhysd/actionlint:1.7.12@sha256:b1934ee5... and
  koalaman/shellcheck-alpine:v0.11.0@sha256:9955be09...; actionlint on release.yaml + docs.yaml,
  shellcheck -x -S style on etc/release.sh, etc/yubikey-setup.sh,
  .github/scripts/verify_commit_hash.sh: no findings). Host shellcheck 0.11 `-x -S style
  etc/release.sh` clean and `bash -n etc/release.sh` OK after S1 and S2.
- Final tree (after 0ba57016d): host shellcheck 0.11 `-x -S style etc/release.sh` clean;
  `bash -n` OK under bash 5.3.9 and under the `bash:3.2` image (3.2.57, also `parse` and a
  sourced refusal run there); `make release-lint` exit 0 again (images cached, --network none);
  `mdbook build docs` (0.5.4) OK.
- S6 matrix: script `/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/a63179cc-f715-4653-8076-ca7024820f15/scratchpad/UPS/matrix.sh`, run from the worktree root. Actual output:

```text
== parse cases
-- parse v0.1.0: exit 0
CHANNEL=mainnet
PACKAGE=tn-mainnet
PRERELEASE=false
ALIAS=latest
-- parse v0.1.0-rc1: exit 0
CHANNEL=mainnet
PACKAGE=tn-mainnet
PRERELEASE=true
ALIAS=
-- parse v0.17.0-adiri: exit 0
CHANNEL=adiri
PACKAGE=tn-testnet
PRERELEASE=true
ALIAS=adiri
-- parse v0.17.0-adiri-rc2: exit 0
CHANNEL=adiri
PACKAGE=tn-testnet
PRERELEASE=true
ALIAS=
-- parse v0.1.0-mainnet: exit 2
error: not a release tag: 'v0.1.0-mainnet' (expected vX.Y.Z, vX.Y.Z-rcN, vX.Y.Z-adiri or vX.Y.Z-adiri-rcN)
-- parse v0.1.0-adiri-adiri: exit 2
error: not a release tag: 'v0.1.0-adiri-adiri' (expected vX.Y.Z, vX.Y.Z-rcN, vX.Y.Z-adiri or vX.Y.Z-adiri-rcN)
== sign-time check (sourced): check_sums_package
error: IMAGE_DIGEST names an image in ghcr.io/telcoin-association/tn-testnet, but v0.1.0 is on the mainnet channel, whose images are published only in ghcr.io/telcoin-association/tn-mainnet (expected the one line ghcr.io/telcoin-association/tn-mainnet@sha256:<64 hex>); do not sign it; rebuild the draft with make release-build TAG=v0.1.0
-- v0.1.0 (mainnet) with IMAGE_DIGEST in tn-testnet: exit 1
passed: IMAGE=ghcr.io/telcoin-association/tn-mainnet
-- v0.1.0 (mainnet) with IMAGE_DIGEST in tn-mainnet: exit 0
== same check for an adiri tag
error: IMAGE_DIGEST names an image in ghcr.io/telcoin-association/tn-mainnet, but v0.17.0-adiri is on the adiri channel, whose images are published only in ghcr.io/telcoin-association/tn-testnet (expected the one line ghcr.io/telcoin-association/tn-testnet@sha256:<64 hex>); rebuild the draft with make release-build TAG=v0.17.0-adiri, or report it if the release is published
-- v0.17.0-adiri with IMAGE_DIGEST in tn-mainnet: exit 1
passed: IMAGE=ghcr.io/telcoin-association/tn-testnet
-- v0.17.0-adiri with IMAGE_DIGEST in tn-testnet: exit 0
== RELEASE_IMAGE override
warning: dry run: no gh calls, no git push, images go only to RELEASE_IMAGE
IMAGE=localhost:5000/x
-- RELEASE_DRY_RUN=1 RELEASE_IMAGE=localhost:5000/x (sourced init_env): exit 0
error: RELEASE_IMAGE is honoured only in a dry run (RELEASE_DRY_RUN=1)
-- RELEASE_IMAGE=localhost:5000/x without RELEASE_DRY_RUN (check-tag): exit 2
awk: fatal: cannot open file `ghcr.io/telcoin-association/tn-mainnet@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' for reading: No such file or directory
error: cannot read ghcr.io/telcoin-association/tn-mainnet@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
-- dry run: IMAGE_DIGEST in ghcr tn-mainnet while RELEASE_IMAGE=localhost:5000/x: exit 1
== check-tag log (check_tag stubbed)
TAG=v0.17.0-adiri-rc2
VERSION=0.17.0
CHANNEL=adiri
PACKAGE=tn-testnet
RC=2
BASE=v0.17.0-adiri
FEATURES=adiri
PRERELEASE=true
ALIAS=
TARBALL=telcoin-network-v0.17.0-adiri-rc2-x86_64-unknown-linux-gnu.tar.gz
CHAIN_CONFIGS=chain-configs/testnet
IMAGE=ghcr.io/telcoin-association/tn-testnet
(check_tag always would run here)
-- cmd_check_tag v0.17.0-adiri-rc2: exit 0
== registry_digest first-push mode (anonymous read of ghcr, no write)
first-push mode prints: denied
error: ghcr.io/telcoin-association/tn-mainnet: the registry answered HTTP 403: package is not public, or has never been pushed (one-time setup after its first push: make it public, as the maintainer guide says)
-- plain mode for <scratch>: exit 2
== V8 W1/N3: check_digest_package shapes (v0.1.0)
-- well formed: exit 0
error: IMAGE_DIGEST names an image in ghcr.io/telcoin-association/tn-testnet, but v0.1.0 is on the mainnet channel, whose images are published only in
-- other package: exit 1
error: IMAGE_DIGEST names ghcr.io/telcoin-association/tn-mainnet with the malformed digest 'sha256:XYZ', but v0.1.0 is on the mainnet channel, whose i
-- sha256:XYZ: exit 1
error: IMAGE_DIGEST names ghcr.io/telcoin-association/tn-mainnet with the malformed digest 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
-- trailing CR: exit 1
error: IMAGE_DIGEST names ghcr.io/telcoin-association/tn-mainnet with the malformed digest '', but v0.1.0 is on the mainnet channel, whose images are 
-- IMAGE@: exit 1
error: IMAGE_DIGEST holds 2 lines, but v0.1.0 is on the mainnet channel, whose images are published only in ghcr.io/telcoin-association/tn-mainnet (ex
-- two lines: exit 1
error: IMAGE_DIGEST names 'ghcr.io/telcoin-association/tn-mainnet:v0.1.0', which is not an image by digest, but v0.1.0 is on the mainnet channel, whos
-- no @: exit 1
== V8 W1: cmd_draft on an existing draft (gh, git and the release stubbed)
body rendered with digest [sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa]
gh release edit v0.1.0 (stub)
draft release v0.1.0 is ready
-- draft with a well-formed IMAGE_DIGEST: exit 0
error: IMAGE_DIGEST names ghcr.io/telcoin-association/tn-mainnet with the malformed digest 'sha256:XYZ', but v0.1.0 is on the mainnet channel, whose i
-- draft with <IMAGE>@sha256:XYZ: exit 1
error: IMAGE_DIGEST names ghcr.io/telcoin-association/tn-mainnet with the malformed digest 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
-- draft with a trailing CR: exit 1
error: IMAGE_DIGEST names ghcr.io/telcoin-association/tn-mainnet with the malformed digest '', but v0.1.0 is on the mainnet channel, whose images are 
-- draft with <IMAGE>@: exit 1
== V8 W2: cmd_build up to its build step (docker, git and the release stubbed; anonymous read denied)
error: ghcr.io/telcoin-association/tn-mainnet is private, not new, and already holds ghcr.io/telcoin-association/tn-mainnet:v0.1.0 (sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
-- login sees the tag, RELEASE_YES=1 RELEASE_FIRST_PUSH=tn-mainnet: exit 2
error: ghcr.io/telcoin-association/tn-mainnet is private, not new, and already holds ghcr.io/telcoin-association/tn-mainnet:v0.1.0 (sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
-- login sees the tag, RELEASE_REBUILD=1: exit 2
with the docker login, ghcr.io/telcoin-association/tn-mainnet:v0.1.0 does not resolve: ERROR: ghcr.io/telcoin-association/tn-mainnet:v0.1.0: not found
error: ghcr.io/telcoin-association/tn-mainnet refuses anonymous reads and the docker login does not see ghcr.io/telcoin-association/tn-mainnet:v0.1.0: if this is the firs
-- registry answers not found, RELEASE_YES=1 only: exit 2
with the docker login, ghcr.io/telcoin-association/tn-mainnet:v0.1.0 does not resolve: ERROR: ghcr.io/telcoin-association/tn-mainnet:v0.1.0: not found
error: RELEASE_FIRST_PUSH is tn-testnet, but v0.1.0 is on the mainnet channel, whose package is tn-mainnet
-- registry answers not found, RELEASE_FIRST_PUSH=tn-testnet (mainnet tag): exit 2
with the docker login, ghcr.io/telcoin-association/tn-mainnet:v0.1.0 does not resolve: ERROR: ghcr.io/telcoin-association/tn-mainnet:v0.1.0: not found
warning: RELEASE_FIRST_PUSH=tn-mainnet: pushing ghcr.io/telcoin-association/tn-mainnet:v0.1.0 as the first image of the package; build stops after the push until the pack
reached the build step (git worktree add)
-- registry answers not found, RELEASE_FIRST_PUSH=tn-mainnet: exit 0
with the docker login, ghcr.io/telcoin-association/tn-mainnet:v0.1.0 does not resolve: ERROR: failed to authorize: denied: denied
warning: RELEASE_FIRST_PUSH=tn-mainnet: pushing ghcr.io/telcoin-association/tn-mainnet:v0.1.0 as the first image of the package; build stops after the push until the pack
reached the build step (git worktree add)
-- registry answers denied, RELEASE_FIRST_PUSH=tn-mainnet: exit 0
(retry after sleep 5)
(retry after sleep 5)
error: cannot ask the registry for ghcr.io/telcoin-association/tn-mainnet:v0.1.0 with the docker login after 3 attempts: ERROR: failed to do request: Head "https://ghcr.i
-- DNS failure, RELEASE_FIRST_PUSH=tn-mainnet: exit 3
(retry after sleep 5)
(retry after sleep 5)
error: cannot ask the registry for ghcr.io/telcoin-association/tn-mainnet:v0.1.0 with the docker login after 3 attempts: ERROR: failed to authorize: failed to fetch oauth
-- expired login (401), RELEASE_FIRST_PUSH=tn-mainnet: exit 3
(retry after sleep 5)
(retry after sleep 5)
error: cannot ask the registry for ghcr.io/telcoin-association/tn-mainnet:v0.1.0 with the docker login after 3 attempts: ERROR: open /root/.docker/config.json: permission
-- local config permission denied, RELEASE_FIRST_PUSH=tn-mainnet: exit 3
error: docker buildx imagetools inspect ghcr.io/telcoin-association/tn-mainnet:v0.1.0 answered without a digest: Name: x
-- login answers without a digest: exit 1
```

  The last block is an anonymous read of ghcr (token request + manifest HEAD), no write.
  The V8 sections stub gh, git, docker and the release state and run the real cmd_draft and
  cmd_build code (cmd_build up to `git worktree add`, where the git stub exits 0).
  Not run: the push itself, the post-push stop and publish's alias assertion (they need a
  registry write, which this round forbids); all were read in context.
- Re-run on the final tree (7ae07a950): same results as below, plus the matrix above (36
  cases, all as expected).
- V8 re-run on 57b8ec90a: host shellcheck 0.11 `-x -S style etc/release.sh`
  clean; `bash -n` OK under 5.3 and bash:3.2; `make release-lint` exit 0; `mdbook build docs`
  exit 0; matrix above.

## Open issues

1. Ten commits now (six from the first pass, four from the V8 rounds): 848a47b5f is a wording fix to the S2 refusal ("is a adiri tag"),
   found while writing the S5 docs that quote it. Squash into 930afd05d if one per section is
   wanted (the implementer may not rebase).
2. (V8: now RELEASE_FIRST_PUSH=<package> plus a login re-check; RELEASE_YES no longer answers
   it.) First-push path goes beyond the spec's literal sections. ghcr answers 403 for a package
   that was never pushed (anonymous reads 2026-11-04: tn-mainnet, tn-testnet, tn-dev, the old
   telcoin-network and a made-up name all 403; the public git-cliff package 200), so the old
   probe before build's push would have stopped the first build into a new package. The
   decision code is exercised with stubs; the push and the post-push stop are not (need a
   registry write). Unverified assumption: an authenticated `docker buildx imagetools
   inspect` of a never-pushed ghcr package answers "not found" or "denied". If ghcr answers
   something else there (for example a bare 401), the first push stops with exit 3 and the
   classifier in login_digest needs that answer added; it fails closed either way.
3. After the first push the rerun needs RELEASE_REBUILD=1, i.e. one full rebuild per network
   the first time. V8's optional N1 (RELEASE_RESUME) was not built; the guide and the PR body
   say the rerun is a full rebuild.
4. Behaviour change in CI draft-release: an existing draft whose IMAGE_DIGEST names another
   package, has no "@", has several lines or (since V8) a malformed digest now fails the job
   with exit 1; before, draft dropped the digest from the body silently.
5. The GitHub UI labels in the guide ("Danger Zone", "Manage access", "Manage Actions
   access") match ACTIONS.md's existing wording; confirm them on the settings page at the
   first push.
6. Cross-repo: tn-node-deployment still maps both networks to
   ghcr.io/telcoin-association/telcoin-network (common.sh TN_GHCR_IMAGE_REPO,
   TN_MAINNET_IMAGE_REPO, TN_TESTNET_IMAGE_REPOS, tn_docker_resolve_ref comment; ui/server.py
   GHCR_IMAGE_REPO/DOCKER_REPO; ui/static/index.html; ui/test_server_contract.py). It must
   switch to tn-mainnet / tn-testnet before the first release in the new packages.
7. etc/Dockerfile keeps `org.opencontainers.image.title="telcoin-network"` (a title, not the
   package name) and the source label that links each package to the repository; unchanged.
