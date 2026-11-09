Title: lib/common 2.0.1: devnet Docker installs by digest

Base: mainnet-hardening (stacked on #11)
PR: https://github.com/Telcoin-Association/tn-node-deployment/pull/52 (opened 2026-10-30, head 090d9e1; R4 follow-ups f5abe22, d9446f7)

---

Stacked on #11. Review it against `mainnet-hardening`, not `main`.

In 2.0.0 `TN_DEVNET_IMAGE_REPO` is empty, so every Docker path refuses devnet and the devnet fleet cannot run the 2.0 scripts as a Docker install. This branch names the devnet image repositories, gives devnet a tag grammar, and lets the update and edit paths find a devnet host. Testnet and mainnet behave as before, except that `tn_docker_repo_ok` now refuses a repository string containing whitespace and refusal messages mention the devnet grammar.

## What changed

- **Image repositories** (`lib/common.sh`). `TN_DEVNET_IMAGE_REPO` is the public legacy Artifact Registry repository, `us-docker.pkg.dev/telcoin-network/tn-public/adiri`. `TN_DEVNET_IMAGE_REPOS` also allows `ghcr.io/telcoin-association/telcoin-network`, the same pair `TN_TESTNET_IMAGE_REPOS` holds for testnet. `tn_docker_repo_ok` now reads the per-network list on testnet and devnet; mainnet still takes only its own constant. The devnet fleet always pins `<repo>@sha256:<64 hex>`.
- **Devnet tags** (`lib/common.sh`, `ui/server.py`). On devnet `tn_release_tag_ok` takes `^[A-Za-z0-9][A-Za-z0-9._-]*-devnet$`, such as `v0.2.0-devnet`, and the UI server has the same rule. The grammar is there for named tags and to keep the UI in step. `tn_release_tag_final` is false on devnet, so no newest-release pick turns on there. An image named by tag is still refused unless `TN_DOCKER_REQUIRE_DIGEST=0`.
- **`setup-node.sh` on devnet** refuses `--release-tag`, source and release installs, and a Docker install without `--docker-image`, before anything on the host changes: devnet has no signed release to verify or to take the newest image from. `--docker-image <repo>@sha256:<digest>` and `--install-method existing` work.
- **Network guard** (`update-node.sh`, `edit-config.sh`, `lib/common.sh`). `_tn_guard_network` reads `NETWORK=devnet` from `.node-meta` when `tn_detect_network` names no network. update-node gets `image_network`, a wrapper around it, and its Docker image paths use that: `prepare_docker_update` and `json_prepare_docker` (`--ref <repo>@sha256:...`, which update-node honours with `--json` only) instead of `detect_network`, and the image comparison in `--check` instead of `tn_detect_network`. `verify_consensus_participation` takes its network from `_tn_guard_network` too, so a devnet apply checks the chain id against `DEVNET_CHAIN_ID` (32285) instead of warning that it is not checked; testnet and mainnet are unchanged. A devnet image change is made with `update-node.sh --json --prepare --ref <repo>@sha256:<digest>` and then `update-node.sh --json --apply --yes`, or with `edit-config.sh --set docker_image=<repo>@sha256:<digest>`. The interactive update picker offers no digest, and `--check` does not find a newer image on devnet: `latest_docker_ref` goes through `detect_network` and devnet has no release feed, so the image comparison is never reached there. edit-config's `set_docker_image` and `edit_docker_image` call `_tn_guard_network` instead of `tn_detect_network`. `tn_docker_image_allowed` (and so `validate_docker_image`) falls back to `_tn_guard_network` instead of `tn_detect_network` when neither its argument nor `NETWORK` names a network, which is what lets edit-config's start-script swap and update-node's pending `NEW_IMAGE` check accept a devnet digest. `tn_detect_network` and `detect_network` are unchanged and still return 1 on devnet, so the source and release paths still refuse devnet.
- `fetch_docker_tags` and `tn_docker_release_tag_for` never ask the registry on devnet; `tn_docker_image_for_tag` refuses a devnet tag before anything is downloaded. `_tn_release_fetch` (and so `tn_fetch_verified_release` and `tn_fetch_release_image`) and `tn_source_checkout_tag` refuse devnet with rc 3 and one line before any download, git or staging directory, as they did at the base, so the new devnet tag grammar does not open a release download or a source checkout on devnet.
- Versions: `COMMON_VERSION` 2.0.1; setup-node, update-node and edit-config `SCRIPT_VERSION` 2.0.1; `UI_VERSION` 2.0.1 (the UI change only keeps its copies of the rules in step, and the UI still refuses devnet). The sidecars of the five changed files are refreshed.
- Docs: a 2.0.1 entry in `CHANGELOG.md` and 2.0.1 entries in the README Changelog section; the devnet sentences in `README.md` (the Docker install notes and the networks section, which both said devnet had no image repository) and in the install-methods table of `OPERATOR.md`; the devnet image repository item in `followup.md` is closed.

## Caveat

`tn-public/adiri` also holds the testnet images. The repository allow-list therefore cannot stop an adiri image from being pinned on a devnet node. The real guard is the digest pin together with the `telcoin --version` probe in the devnet fleet tooling. Only a repository that holds devnet images alone would let the allow-list catch it, and there is none.

## Tests

New vectors, all on devnet unless noted:

- the tag grammar: `v0.2.0-devnet` and `x-devnet` pass; `-devnet`, `.x-devnet`, `_x-devnet`, `v0.2.0-devnet-rc1`, `v0.2.0-DEVNET`, `é-devnet` (under `C`, `C.UTF-8` and `en_US.UTF-8`) and `v0.16.0-adiri` fail; a devnet tag fails on testnet and mainnet; `tn_release_tag_final` is 1 on devnet; devnet tags have no release order and drop out of a sorted list
- `tn_docker_repo_for devnet` names the legacy repository; `tn_docker_repos_for` per network; `tn_docker_repo_ok` on devnet, and a repository with whitespace in it refused on every network
- a devnet digest from `us-docker.pkg.dev/telcoin-network/tn-public/adiri` or `ghcr.io/telcoin-association/telcoin-network` is accepted; a devnet tag is refused by default and accepted only with `TN_DOCKER_REQUIRE_DIGEST=0`; `main-<sha>` and `v0.16.0-adiri` are refused
- with no network given, `tn_docker_image_allowed` takes devnet from `.node-meta` and refuses when the network cannot be told
- `tn_docker_image_for_tag devnet v0.2.0-devnet` is rc 1 with nothing fetched; `v0.16.0-adiri` and `main-<sha>` are rc 3
- `_tn_release_fetch x-devnet devnet "" image` is rc 3 with one line on stderr, nothing on stdout, an empty staging directory and the fetcher never called (stubbed to fail loudly); `tn_source_checkout_tag DIR devnet x-devnet` is rc 3 and runs no git, and so is `--allow-dirty` on devnet
- `tn_docker_resolve_ref devnet` takes a GAR or ghcr digest and refuses busybox, a devnet tag and a testnet tag
- `tn_docker_release_tag_for devnet`, `latest_docker_image devnet` and `fetch_docker_tags devnet` make no registry call (the lookups are stubbed to fail loudly)
- `setup-node.sh` on devnet: a digest is accepted; finalize without `--docker-image` is accepted; `--release-tag x-devnet` is refused; source and release installs at keygen are refused; docker without `--docker-image` at keygen is refused; `_preflight_docker` stops before Docker's apt repository for a devnet tag
- update-node on devnet: `image_network`, the pending `NEW_IMAGE` check and `json_prepare_docker`; after an apply, chain 32285 passes with the chain id checked and chain 2017 is refused (`runs chain id 2017, not 32285 (devnet)`)
- edit-config on devnet: `set_docker_image`, `swap_docker_image` and the image menu
- the UI: the repositories and the tag rule match the library on devnet; `latest_source_tag("devnet")` and `latest_docker_image("devnet")` run nothing; a devnet update-prepare is refused

The vectors the change flips (a devnet digest accepted, the devnet repository named) are flipped, and the devnet rows that still pass for a new reason are relabelled. The testnet and mainnet vectors are unchanged and pass as they are, and the `tn_detect_network` devnet rc 1 pins stay.

Test files touched: `tools/tests/docker_image_test.sh`, `tools/tests/setup_release_test.sh`, `tools/tests/network_detect_test.sh`, `tools/tests/primitives_test.sh`, `tools/tests/source_ref_test.sh`, `tools/tests/release_fetch_test.sh`, `tools/tests/consensus_participation_test.sh`, `tools/tests/unit_render_test.sh` (two labels), `ui/test_csrf.py`, `ui/test_server_contract.py`.

## Verification

Gates run on the head of this branch:

- the fixture suite, `bash tools/tests/run.sh` (bash 5.3): 59 files, 0 failed (3697 checks, 0 failures, 49 skipped)
- the same suite's ten devnet-relevant files under `bash:3.2` (the eight above, `pending_state_test.sh`, `update_guard_test.sh`): 0 failed
- the UI tests, `python -m pytest -q ui` in `python:3.10-slim` with the hash-pinned requirements, as CI installs them: 258 passed
- the helper tests, `ui/tests/helper_test.sh`: 494 checks, 0 failed (1 skipped, needs root)
- the bash 3.2 lint, `tools/check-bash32.sh`: clean, 100 files
- the perl interpolation lint, `tools/check-perl-interp.sh`: clean, 100 files
- `shellcheck -x --severity=error` on every tracked `.sh`: clean; `--severity=warning` on the twelve changed `.sh` files: 36 findings against the base's 37 (one unused variable in `release_fetch_test.sh` is now used), none new
- `tools/gen-checksums.sh`: only the five changed files' sidecars change (the R4 follow-ups refresh `lib/common.sh.sha256` and `update-node.sh.sha256` again; no version moves past 2.0.1)
- `verify_consensus_participation` side by side against 090d9e1 on testnet, mainnet, devnet, unknown and bogus hosts with four chain ids: only the devnet host's lines differ

## Not in this PR

- The devnet fleet tooling that pins the digest and runs the `telcoin --version` probe. It lives in devnet-genesis and pins this branch's head commit.
- A devnet repository separate from `tn-public/adiri`, and signed devnet releases.
