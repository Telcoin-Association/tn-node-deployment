# Package IMG: per-network image packages (tn-node-deployment)

Read `tasks/spec-r2-shared.md` first. Worktree `~/coding/telcoin/tnd-r2-IMG`, branch `r2/IMG`,
checkpoint `tasks/ckpt-r2-IMG.md`. Size M. Owner of: the image-repository constants and helpers
in `lib/common.sh`, `update-node.sh` (floor), the Docker preflights in `setup-node.sh`,
`update-node.sh`, `edit-config.sh` (where an image is resolved before a container starts),
`ui/server.py` + `ui/static/index.html` twins and their tests, the fixtures named below.
Upstream (telcoin-network) is package UPS; you only READ `~/coding/telcoin/tn-r2-packages`
(`etc/Dockerfile`, `etc/release.sh`) for facts.

## Decision

Mainnet images live in `ghcr.io/telcoin-association/tn-mainnet` (tags `vX.Y.Z`, rc tags
`vX.Y.Z-rcN` are never offered to operators), testnet images in
`ghcr.io/telcoin-association/tn-testnet` (tags `vX.Y.Z-adiri[-rcN]`). The channel is a pure
function of the tag and every stage re-derives it. The old single package
`ghcr.io/telcoin-association/telcoin-network` never held a release and is abandoned; it stays
only in the testnet/devnet ALLOWED lists so a container already running from it is recognised
by remove-node and the status screens, never for a new pull. Dev images go to
`ghcr.io/telcoin-association/tn-dev` (not a package this repository ever pulls from).

## Today (verified 2026-11-04 at 9fd615a; grep before editing)

- `TN_GHCR_IMAGE_REPO` common.sh ~1522 with a comment block ~1513-1521; `TN_TESTNET_LEGACY_IMAGE_REPO`
  ~1524; `latest_docker_image` ~1557-1595; `tn_release_tag_ok` ~1701-1715; sort key ~1740;
  `TN_MAINNET_IMAGE_REPO="$TN_GHCR_IMAGE_REPO"` ~6926; `TN_TESTNET_IMAGE_REPOS` ~6934 (GAR +
  ghcr telcoin-network); `TN_DEVNET_IMAGE_REPOS`; `tn_docker_repo_for` ~6957-6979;
  `tn_docker_repos_for`; `tn_docker_repo_ok` ~7016; `tn_fetch_release_image` ~7520-7531 (the
  release's `IMAGE_DIGEST` line); `tn_docker_resolve_ref` ~7940-7998 whose comment (~7947-7949)
  says testnet and mainnet share the ghcr repository and so a raw digest on mainnet is taken
  only when `.node-meta` records a mainnet release tag for it (keep that rule as defence in
  depth; reword the comment).
- `STORAGE_MIGRATION_FLOOR="0.16.0"` update-node.sh:137 applies to every network, so a mainnet
  `v0.1.x` image always counts as "below the floor" in `storage_migrating_upgrade` (~966-989)
  and `update_downgrade_check` (~1806-1825). Bug.
- UI: `ui/server.py` `RELEASE_TAG_RE` ~296-299 (unchanged: mainnet tags stay `vX.Y.Z`),
  `GHCR_IMAGE_REPO` ~376, `DOCKER_REPO` ~383-386; `ui/static/index.html` ~2404;
  `ui/test_server_contract.py` ~1377, ~1952-1962. The library's `tn_docker_repo_for` and
  the server's `DOCKER_REPO` must agree (a test pins that today; keep it).
- Tests: `docker_image_test.sh` ~123-140, ~542-566, ~644-653; `network_detect_test.sh` ~470;
  `source_ref_test.sh` (floor cases); `setup_release_test.sh`; `release_fetch_test.sh`;
  `remove_test.sh` ~951 (container scan names ghcr); `ui/test_server_contract.py`.
- Upstream `etc/release.sh` `check_version_output` ~1236-1271: the image's `telcoin-network
  --version` prints a `Build Features:` line; mainnet lists none, adiri lists `adiri` and may
  list `faucet`. Read `etc/Dockerfile` in `~/coding/telcoin/tn-r2-packages` for the entrypoint
  and binary path before writing the feature check.

## Sections (one commit each; checkpoint after each)

S1 **Constants and helpers.** `TN_MAINNET_IMAGE_REPO="ghcr.io/telcoin-association/tn-mainnet"`;
a testnet constant `ghcr.io/telcoin-association/tn-testnet` that `tn_docker_repo_for testnet`
prints; the old name kept as `TN_GHCR_LEGACY_IMAGE_REPO` (or similar) with a comment saying
no release was ever published there and it is allowed only for recognising existing
containers; `TN_TESTNET_IMAGE_REPOS` = GAR legacy + ghcr legacy + tn-testnet; devnet lists
unchanged apart from the renamed constant; `tn_docker_repo_ok` stays an exact match and on
mainnet accepts `tn-mainnet` only. Rewrite the comment blocks (~1513-1521, ~7947-7949). Every
message or example that printed the old ghcr name for a NEW pull now prints the network's
package (grep `telcoin-network"` and `telcoin-network:` in messages; the 13 every-network
example messages listed in followup.md stay a followup item unless trivially fixed in passing).
`tn_fetch_release_image` / the `IMAGE_DIGEST` reader: on every network the digest line must
name a repository `tn_docker_repo_ok` accepts for that network, and on mainnet exactly
`tn-mainnet` (a signed mainnet release whose IMAGE_DIGEST names another package is refused with
a message naming both).

S2 **Storage floor by network.** `STORAGE_MIGRATION_FLOOR_TESTNET="0.16.0"`, mainnet no floor
(empty = the migration logic is skipped, like `MIN_SOURCE_VERSION_MAINNET=""` does for the
source floor), devnet no floor (its version line restarted with the relaunch; confirm against
`source_ref_test.sh`/`docker_image_test.sh` devnet cases and say so in the checkpoint if they
contradict). A resolver `storage_migration_floor NETWORK` used by `storage_migrating_upgrade`
and `update_downgrade_check`; an empty floor means "never a migrating upgrade" and "never the
storage downgrade refusal". Fixtures: a mainnet `v0.1.3 → v0.2.0` update is not a migration;
testnet keeps today's cases.

S3 **Image feature check.** `tn_docker_image_network_ok NETWORK IMAGE_REF [fn]`: runs the
pulled image once with `docker run --rm --entrypoint <binary> IMAGE_REF --version` (the
entrypoint/binary from `etc/Dockerfile`; a 60 s `timeout` where available), reads the `Build
Features:` line (exactly one; `tn_docker_image_network_ok` refuses when it is missing or
doubled), and judges: mainnet requires no features (refuse `adiri`, `faucet`, anything);
testnet requires `adiri` (faucet allowed, nothing else); devnet is not checked (rc 0 with an
info line). rc 1 with a message naming the image, the features found and the network. Called
in setup-node's Docker preflight (interactive and `--json`), update-node's Docker prepare paths
(interactive and `--json`) and edit-config's image change if it starts a container, AFTER the
image is resolved and pulled by digest and BEFORE any container is started or any .node-meta
line is written; a failed check stops the action (fail closed) and on `--json` emits an error
event then `done`. Tests stub `docker` on `BIN` (fixture pattern: `fwstub.sh`/the docker stubs
already in `docker_image_test.sh`) printing a canned `--version` output per image ref:
mainnet image with `adiri` refused, with none accepted; testnet image without `adiri` refused;
missing line refused; devnet skipped.

S4 **UI twins.** `ui/server.py`: `DOCKER_REPO` mainnet `("ghcr.io/telcoin-association/tn-mainnet",)`,
testnet `(GAR legacy, ghcr legacy, tn-testnet)`, devnet unchanged apart from the rename; the
repository the wizard offers for a new pull is the network's package; `index.html` ~2404 text;
`test_server_contract.py` cases and the lib/server agreement test; `ui/test_mainnet_flag.py`
if it names the repository. `python -m pytest ui -q` green under 3.10 and 3.12
(`docker run --rm -v "$PWD:/w" -w /w python:3.10-slim sh -c 'pip install -q -r
ui/requirements-dev.txt 2>/dev/null; python -m pytest ui -q'`, or the venv the repo's AGENTS.md
names).

S5 **Fixtures.** `docker_image_test.sh` (repo_for/repos_for/repo_ok per network, resolve_ref
refusals: `tn-testnet:v0.17.0-adiri` on mainnet, `tn-mainnet:v0.1.0` on testnet, old ghcr name
for a new pull on every network, `-adiri` tag on mainnet, plain tag on testnet, raw digest
rules unchanged), `network_detect_test.sh`, `source_ref_test.sh` + `storage_migration_test.sh`
(floor by network), `setup_release_test.sh` (preflight calls the feature check, order: resolve
→ pull → feature check → start), `release_fetch_test.sh` (IMAGE_DIGEST package check),
`remove_test.sh` (container scan recognises all three testnet repositories and tn-mainnet).
All green in bash 5.3, `bash:3.2`, `ubuntu:24.04`.

## Docs notes to produce (for DOCS-2)

Package names per network and why (channel = tag), the old package's status, the floor by
network, the feature check (what runs, what it refuses, when), and the stale lines: AGENTS
~80-85, README ~787/~1451/~1463, OPERATOR ~199-200, partner guide ~214/~266/~307, plus any
line your grep finds naming `ghcr.io/telcoin-association/telcoin-network`.
