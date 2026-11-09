status: done

- [x] S1 Constants and helpers (4b04b6e)
- [x] S2 Storage floor by network (8abb2b4)
- [x] S3 Image feature check (fbe71f4)
- [x] S4 UI twins (e1ae4cd)
- [x] S5 Fixtures (7757b8b; amended once to add the update_guard_test stub)

Follow-up round (coordinator decision on open issues 1, 2, 6):
- [x] F1 (15a7bb3) devnet pulls from ghcr.io/telcoin-association/tn-dev (TN_DEV_IMAGE_REPO), lib + UI twin + remove-node scan + fixtures
- [x] F2 (72aed4c) UI helper setup-keygen validates with the pull rule

Approach: each section's commit carries the fixture updates its change needs, so
the bash suite stays green commit by commit; S5 adds the remaining cross-cutting
cases. Exception: the UI agreement test (ui/test_csrf.py
test_image_repositories_match_the_library) is red from S1 until S4 lands, by
design (it pins lib and server together).

## Operator-visible changes

- S1: testnet images come from ghcr.io/telcoin-association/tn-testnet, mainnet
  from ghcr.io/telcoin-association/tn-mainnet. Messages and examples name the
  network's package (tn_docker_repo_for). The old package
  ghcr.io/telcoin-association/telcoin-network is refused for every new pull
  (setup --docker-image, a typed image, update-node and edit-config refs, a
  signed IMAGE_DIGEST) on every network, devnet included; it is still recognised
  for a running container (remove-node scan, UI docker-detect, pending state,
  start-script render). Devnet new pulls take the devnet repository
  (us-docker.pkg.dev/.../adiri) only.

- S2: a mainnet (or devnet) update is never treated as a one-way storage
  migration (no snapshot prompt, normal 45 s health window, rollback on a failed
  check), and a mainnet downgrade is refused as a downgrade only, never with the
  "is below v0.16.0 and cannot open the data dir" sentence; the --json done event
  carries "storage_downgrade":false there. Testnet unchanged.

- S3: after the pull and digest check, setup-node, update-node (prepare, both
  modes) and edit-config (set and menu) run the image's /usr/local/bin/telcoin
  --version once (no network, no capabilities, read-only, 60 s) and refuse an
  image whose Build Features line does not fit the network: mainnet none,
  testnet adiri (faucet allowed), exactly one line. Devnet: info line, no check.
  Refusal: "Image refused: <image> was built with the features <list>, and a
  <net> image has <rule>, so it is not a <net> image. It is not used and nothing
  was changed; if a <net> release names this image, report it to the node team."
- S4: the wizard's Docker image field names the network's package
  (…tn-mainnet@sha256:… / …tn-testnet@sha256:…); the old package is refused in
  the field and never offered as the newest image.

## Docs notes

Facts for DOCS-2:

- Packages (lib/common.sh): `TN_MAINNET_IMAGE_REPO="ghcr.io/telcoin-association/tn-mainnet"`
  (tags `vX.Y.Z`; rc tags `vX.Y.Z-rcN` are never offered or accepted on mainnet),
  `TN_TESTNET_IMAGE_REPO="ghcr.io/telcoin-association/tn-testnet"` (tags
  `vX.Y.Z-adiri[-rcN]`). The channel is a function of the tag (`-adiri` = testnet),
  and every stage derives the package from the network again (`tn_docker_repo_for`).
  `TN_GHCR_IMAGE_REPO` is gone.
- Old package: `TN_GHCR_LEGACY_IMAGE_REPO="ghcr.io/telcoin-association/telcoin-network"`.
  No release was ever published there. It is in `TN_TESTNET_IMAGE_REPOS` and
  `TN_DEVNET_IMAGE_REPOS` only so a running container is recognised (remove-node
  scan, UI docker-detect, pending NEW_IMAGE, start-script render); every new pull
  refuses it on every network (`tn_docker_pull_repo_ok`, `tn_docker_pull_repos_for`;
  UI twins `docker_pull_repo_ok`, `pull_image_allowed`). Mainnet never accepts it.
  Message: `Image refused: <arg>. No release was ever published to
  ghcr.io/telcoin-association/telcoin-network, so no image is pulled from it;
  <net> images come from <package>. Give the <net> release tag instead.` (devnet:
  `...; give the devnet image by digest, us-docker.pkg.dev/telcoin-network/tn-public/adiri@sha256:<digest>.`)
- Lists: `TN_TESTNET_IMAGE_REPOS` = GAR legacy (`us-docker.pkg.dev/telcoin-network/tn-public/adiri`),
  old package, tn-testnet. `TN_DEVNET_IMAGE_REPOS` = GAR legacy, old package (so a
  devnet new pull takes GAR only). Mainnet: tn-mainnet alone.
- IMAGE_DIGEST: a signed release's line must be `<repo>@sha256:<64 hex>` from a
  repository a new pull for the network takes: mainnet exactly tn-mainnet; testnet
  tn-testnet or the GAR legacy repository (never the old package). Refusal:
  `Release <tag>: IMAGE_DIGEST names <image>, but a <net> release image is
  <repository>@sha256:<digest> from <package(s)>. The release is refused and nothing
  was pulled; report it to the node team.`
- Mainnet digest-alone rule unchanged (taken only when .node-meta records it for a
  mainnet release tag), now explained as defence in depth: only the signed release
  says which digest of tn-mainnet is a release image. The "testnet and mainnet
  share the ghcr repository" reason is gone everywhere.
- Storage floor (update-node.sh): `STORAGE_MIGRATION_FLOOR_TESTNET="0.16.0"`,
  `STORAGE_MIGRATION_FLOOR_MAINNET=""`, `STORAGE_MIGRATION_FLOOR_DEVNET=""`, read by
  `storage_migration_floor [NETWORK]` (default: the node's network; unknown network
  = the testnet floor). Empty = never a one-way update, never the storage downgrade
  sentence, `"storage_downgrade":false`. `STORAGE_MIGRATION_FLOOR` is gone.
- Feature check: `tn_docker_image_network_ok NETWORK IMAGE [fn]` runs
  `docker run --rm --pull=never --network none --cap-drop ALL --security-opt no-new-privileges --read-only --entrypoint /usr/local/bin/telcoin IMAGE --version`
  (60 s via `timeout` where present) after the pull and digest check, before any
  container start, start-script/pending write or .node-meta write, in setup-node
  (interactive and --json), update-node prepare (interactive and --json) and
  edit-config (set_docker_image and the menu). Exactly one `Build Features:` line;
  mainnet none; testnet `adiri` (+ `faucet` allowed, nothing else); devnet skipped
  with an info line. Refusals: `Image refused: <img> was built with the features
  <list|none>, and a <net> image has <none|adiri, and faucet at most>, so it is not
  a <net> image. It is not used and nothing was changed; if a <net> release names
  this image, report it to the node team.`; `Image refused: <img> prints <n>
  "Build Features:" lines with --version, not one, ...`; `Could not run <img> to
  read its build features (docker run exited <rc>), so it is not used and nothing
  was changed. Check that Docker is running and holds the image, then try again.`
  Callers add: setup `Refusing the image <img>: it is not a <net> image (see above).
  No container was started and .node-meta was not written.`; update-node `The image
  <img> is not a <net> image (see above); nothing was prepared and the node was not
  touched.` then the existing error event, then done (exit trap); edit-config
  `refusing <img>: it is not a <net> image (see above); the image is not changed`.
- UI: wizard Docker image field label names the package
  (`ghcr.io/telcoin-association/tn-mainnet@sha256:…` / `…tn-testnet@sha256:…`);
  server error hint names it too.

Follow-up (F1, F2) docs facts:

- Devnet pulls from `ghcr.io/telcoin-association/tn-dev` (`TN_DEV_IMAGE_REPO`, the
  package the node team's dev images go to), by digest only, as every devnet
  image is. `TN_DEVNET_IMAGE_REPOS` = the legacy Artifact Registry repository, the
  old single package (recognition only) and tn-dev; a devnet new pull takes the
  legacy repository or tn-dev (`tn_docker_pull_repos_for devnet`). Testnet and
  mainnet refuse tn-dev like any other repository. `TN_DEVNET_IMAGE_REPO` (the
  repository devnet examples name) is still the legacy repository.
- Devnet refusals now list both: "... from one of these repositories:
  us-docker.pkg.dev/telcoin-network/tn-public/adiri ghcr.io/telcoin-association/tn-dev."
  (resolve_ref, the old-package refusal on devnet, setup-node --docker-image).
- remove-node's scan of custom containers also lists tn-dev containers (devnet nodes).
- README 1463 suggested wording becomes "Devnet pulls images by digest only, from the
  legacy repository or `ghcr.io/telcoin-association/tn-dev`".
- UI helper: setup-keygen's TN_SETUP_DOCKER_IMAGE check is the pull rule
  (tn_docker_image_allowed + tn_docker_pull_repo_ok), so the old package is refused
  there with "invalid docker image for <net> (its repository by digest; a release
  goes in TN_SETUP_BUILD_REF): <image>", matching setup-node.

Stale lines (replacement wording suggested):

- AGENTS.md 80-85: "Testnet and mainnet images share one repository (...), so on mainnet
  an image is named by its release tag ..." -> "Each network has its own image
  package: mainnet `ghcr.io/telcoin-association/tn-mainnet`, testnet
  `ghcr.io/telcoin-association/tn-testnet` (`TN_MAINNET_IMAGE_REPO`,
  `TN_TESTNET_IMAGE_REPO`; the channel follows the tag). The old single package
  `ghcr.io/telcoin-association/telcoin-network` (`TN_GHCR_LEGACY_IMAGE_REPO`) never held a
  release: it is recognised for running containers only, and every new pull refuses it
  (`tn_docker_pull_repo_ok`). On mainnet an image is still named by its release tag and
  the digest comes from the signed release; `tn_docker_resolve_ref` refuses a bare
  digest unless ... (rest unchanged). A pulled image's Build Features are checked
  against the network (`tn_docker_image_network_ok`) before anything uses it."
- AGENTS.md 222-226: "(`STORAGE_MIGRATION_FLOOR`)" -> "(`STORAGE_MIGRATION_FLOOR_TESTNET`,
  read through `storage_migration_floor`; mainnet and devnet have no floor)".
- README 787: drop "Testnet and mainnet images share `ghcr.io/telcoin-association/telcoin-network`,
  so a digest alone could name a testnet image:" -> "Only the signed release says which
  digest of `ghcr.io/telcoin-association/tn-mainnet` is a release image, so".
- README 992: "...testnet repositories or of `ghcr.io/telcoin-association/telcoin-network`..."
  -> "...the testnet repositories, `ghcr.io/telcoin-association/tn-testnet`,
  `ghcr.io/telcoin-association/tn-mainnet` or the old `ghcr.io/telcoin-association/telcoin-network`...".
- README 1089: "one line naming `ghcr.io/telcoin-association/telcoin-network@sha256:<digest>`"
  -> "one line naming the network's package by digest
  (`ghcr.io/telcoin-association/tn-mainnet@sha256:<digest>` on mainnet,
  `ghcr.io/telcoin-association/tn-testnet@sha256:<digest>` on testnet); ... and that
  its binary's Build Features fit the network".
- README 1463: "The image repository is set for both networks: `ghcr.io/telcoin-association/telcoin-network`
  ... Devnet runs images by digest only, from the legacy repository or ghcr.io
  (`TN_DEVNET_IMAGE_REPOS`)" -> "The image packages are set: testnet
  `ghcr.io/telcoin-association/tn-testnet`, mainnet `ghcr.io/telcoin-association/tn-mainnet`;
  testnet also takes the legacy `us-docker.pkg.dev/...`. Devnet pulls images by digest
  only, from the legacy repository."
- README 1705-1707 (the v2.1.0 notes): "since testnet and mainnet share the ghcr repository (#46)"
  -> "since only the signed release names a mainnet release image (#46)"; add bullets
  for the packages, the old package, the floor by network and the feature check.
- README 1862 (v2.0.1 notes), 1963 and 2108 (v2.0.0 notes): historical; they describe
  releases that named the old package. DOCS-2 to decide whether to leave them or add
  "(replaced in 2.1.0 by tn-mainnet/tn-testnet)".
- OPERATOR 199-200: -> "The mainnet image package is set:
  `ghcr.io/telcoin-association/tn-mainnet`, where the release pipeline publishes the
  mainnet images (testnet's are in `ghcr.io/telcoin-association/tn-testnet`). A mainnet
  node names its image by its release tag, and the digest comes from the signed
  release; a digest given alone is taken only when ... (section 4.3)."
- OPERATOR 270 (`3) Docker` row): "Images come from `ghcr.io/telcoin-association/telcoin-network`
  ... on testnet and mainnet" -> "Images come from the network's package,
  `ghcr.io/telcoin-association/tn-mainnet` or `ghcr.io/telcoin-association/tn-testnet`;
  testnet also takes the legacy Artifact Registry repository ...; after the pull the
  image's Build Features are checked against the network."
- OPERATOR 725 (`docker_image` row): "of the network's repository, `ghcr.io/telcoin-association/telcoin-network`"
  -> "of the network's package (`...tn-mainnet` or `...tn-testnet`)"; add "and its
  Build Features are checked after the pull".
- OPERATOR 967: "in the repository the release pipeline publishes to,
  `ghcr.io/telcoin-association/telcoin-network@sha256:<digest>`" -> "in the network's
  package, `ghcr.io/telcoin-association/tn-mainnet@sha256:<digest>` (mainnet) or
  `ghcr.io/telcoin-association/tn-testnet@sha256:<digest>` (testnet)".
- OPERATOR 1705 (troubleshooting): "`The registry gave no digest for <tag> in
  ghcr.io/telcoin-association/telcoin-network or ...`" -> "`... in
  ghcr.io/telcoin-association/tn-testnet or us-docker.pkg.dev/...`" (that fallback
  runs on testnet only). Add rows for the feature-check and IMAGE_DIGEST refusals.
- Partner guide 214: -> "The mainnet image package is set:
  `ghcr.io/telcoin-association/tn-mainnet`; testnet's is `ghcr.io/telcoin-association/tn-testnet`."
- Partner guide 266: still true (tag grammar unchanged); optionally add "the tag also
  picks the image package".
- Partner guide 307 (`3) Docker` row): "Pulls the image by digest from
  `ghcr.io/telcoin-association/telcoin-network`" -> "from the network's package,
  `ghcr.io/telcoin-association/tn-mainnet` or `ghcr.io/telcoin-association/tn-testnet`
  (on testnet also the older `us-docker.pkg.dev/...`), checks the pulled digest and
  that the image's build features fit the network".
- Partner guide 716-721, OPERATOR 601-608, README 960-963: the one-way update text
  names `v0.16.0-adiri`; add "testnet only: mainnet and devnet have no storage floor".
- lib/release-keys/README lines 36-38 (owned by SIG): "(on testnet the Artifact
  Registry adiri repository or ghcr.io/telcoin-association/telcoin-network)" -> "(on
  mainnet ghcr.io/telcoin-association/tn-mainnet, on testnet
  ghcr.io/telcoin-association/tn-testnet or the Artifact Registry adiri repository)".
- followup.md 68-73 ("Mainnet images come from the repository testnet uses ...") is
  stale: mainnet has its own package now; the remaining item is the node team's
  confirmation that tn-mainnet receives `vX.Y.Z` releases (UPS).
- CHANGELOG/scripts-v2.1.0.md 54 and 65 name the shared package; 65's example
  `ghcr.io/telcoin-association/telcoin-network@sha256:<digest>` becomes
  `ghcr.io/telcoin-association/tn-mainnet@sha256:<digest>`.

## Tests run

Final, at the branch tip 7757b8b:

- Fixtures, `bash tools/tests/run.sh` (all 61 files):
  - bash 5.3 (host, real docker trapped on PATH): 60 passed, host_baseline_test
    flaky (see Open issues 5); host_baseline_test then passed 3 of 3 alone.
  - `bash:3.2` container (worktree mounted): 61 files, 0 failed.
  - `ubuntu:24.04` container (bash 5.2, worktree mounted): 61 files, 0 failed.
- UI: `python -m pytest -q -p no:cacheprovider ui` in python:3.10-slim and
  python:3.12-slim (requirements with --require-hashes, worktree mounted
  read-only): 283 passed, 1236 subtests passed on both. UI shell tests (bash 5.3):
  helper 548 checks, open_ui 9, install_ui 1, 0 failed.
- Lints on every touched *.sh: shellcheck 0.11 and koalaman/shellcheck:v0.9.0
  `-x --severity=error` clean; `tools/check-bash32.sh` clean; `bash -n` under 5.3
  and `bash:3.2` clean; `tools/check-network-hits.sh` clean (147 annotated hits);
  `tools/check-perl-interp.sh` clean (145 files); `git diff --check` clean.
- Per section along the way: S1 full bash 5 suite 61/0; S1, S3 key fixtures under
  bash:3.2 0 failed; S2 floor fixtures 0 failed.
- Note: one earlier pair of bash:3.2/ubuntu runs mistakenly mounted the main
  checkout (a backgrounded subshell lost the cd); its results were discarded and
  the runs repeated against the worktree. Those runs only read the main checkout:
  no file there is root-owned or was created by them (checked).

Follow-up round (F1 15a7bb3, F2 72aed4c):

- bash 5.3: docker_image 331 checks, network_detect 156, setup_release 109,
  remove 368, update_guard 73, all 0 failures on a clean run; ui/tests/helper_test.sh
  556 checks, 0 failed. Under host load (load average about 20 from other agents)
  docker_image_test failed one check once and remove_test once; neither repeated
  in 4 further runs each, and the failing check was not captured (load flakes,
  like host_baseline_test).
- bash:3.2: docker_image, network_detect, setup_release, remove, update_guard 0
  failed; helper_test 556 checks, 0 failed; bash -n on every touched file clean.
- pytest in python:3.10-slim and python:3.12-slim: 283 passed, 1268 subtests passed.
- shellcheck 0.9 and 0.11 --severity=error, check-bash32, bash -n 5.3,
  check-network-hits (147), check-perl-interp, git diff --check: clean.

## Open issues

1. RESOLVED by F1 (coordinator: devnet pulls from tn-dev). Was: Devnet new pulls: with the old single package refused for every new pull,
   a devnet node can change its image only to a digest of the devnet repository
   (`us-docker.pkg.dev/telcoin-network/tn-public/adiri`). Upstream's
   `make docker-devnet` pushes dev images to the old package today and, after UPS,
   to `ghcr.io/telcoin-association/tn-dev`, which no network here pulls from. If the
   devnet fleet needs ghcr images, the one-line follow-up is adding tn-dev to
   `TN_DEVNET_IMAGE_REPOS` (and server.py `DOCKER_REPO["devnet"]`). Decision for the
   orchestrator; the spec said "never for a new pull", so IMG follows it.
2. RESOLVED by F1 (the scan lists tn-dev). Was: remove-node's custom-container scan does not list containers of
   `ghcr.io/telcoin-association/tn-dev` (dev deployments after UPS). Before UPS they
   ran from the old package and were listed. Add `tn-dev` to the scan's grep if dev
   deployments should stay visible (read-only scan; each removal asks).
3. `lib/release-keys/README` lines 36-38 (SIG owns the file) still say testnet
   IMAGE_DIGEST may name `ghcr.io/telcoin-association/telcoin-network`. Exact text:
   "IMAGE_DIGEST must name an image repository the scripts accept for the network
   (on mainnet ghcr.io/telcoin-association/tn-mainnet; on testnet
   ghcr.io/telcoin-association/tn-testnet or the Artifact Registry adiri repository).
   The old ghcr.io/telcoin-association/telcoin-network package holds no release and
   is refused." Updater-tracked: its .sha256 sidecar needs regenerating.
4. Commit-by-commit greenness: S1 (4b04b6e) to S3 (fbe71f4) leave
   `ui/test_csrf.py::test_image_repositories_match_the_library` red until S4
   (e1ae4cd), by design of the agreement test; S3 leaves `update_guard_test.sh` red
   until S5 (7757b8b), which stubs the feature check there (its json_prepare_docker
   reaches the real check, which execs the docker binary under `timeout`, so a shell
   function stub of docker cannot catch it). The branch tip is green.
5. `tools/tests/host_baseline_test.sh` is flaky under host load (the
   "--json <scope> ... done ok" checks; seen while other suites ran in parallel on
   this host): it failed 4 of 6 runs once and then passed 12 of 12 on HEAD and 6 of
   6 on the base tree. IMG does not touch json_remove or the baseline code.
6. RESOLVED by F2. Was: `ui/telcoin-ui-helper.sh` setup-keygen validates `TN_SETUP_DOCKER_IMAGE` with the
   recognition rule (tn_docker_image_allowed), so a digest of the old package passes
   the helper and is refused by setup-node's new-pull check. Harmless (setup-node is
   the gate); tighten the helper to tn_docker_pull_repo_ok if wanted.
7. The feature check does not compare the image's `Version:` with the release tag
   (the spec asked for Build Features only); `tn_release_version_ok` could do both
   by passing the tag where it is known.
8. `ui/dev/serve.py` still fakes a `latest_docker_image` from the Artifact Registry
   (followup.md already lists it); not touched.
9. The UI helper's docker-detect (`_docker_tn_names`) recognises containers of the
   testnet and mainnet lists only, so a devnet node's tn-dev container is not
   listed there (the UI does not manage devnet nodes; setup-keygen refuses devnet).
10. server.py `docker_image_choice` accepts a devnet tag such as
    `<repo>:v0.2.0-devnet` on devnet (pre-existing; the library refuses devnet tags
    because devnet has no signed releases). The wizard never offers devnet, so it
    is unreachable today; align it if the wizard ever takes devnet.
