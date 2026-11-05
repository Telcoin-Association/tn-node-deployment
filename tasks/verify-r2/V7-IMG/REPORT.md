# V7-IMG: per-network image packages, round 2 on PR #59

Verifier V7, IMG section only. The SIG section is in `tasks/verify-r2/V7/`. Tree: worktree
`tnd-r2-V7`, branch `r2/V7` at c0716f3 (the integration tip with EPOCH, SIG, IMG and the IMG
follow-up). I checked against `tasks/spec-r2-shared.md`, `tasks/spec-r2-IMG.md` and the IMG
checks in `tasks/spec-r2-V7.md`. I wrote the harness before reading `tasks/ckpt-r2-IMG.md`. No
real `docker pull` ran and no real container started: every test puts a `docker` stand-in on
PATH, and `t_leak.sh` shows that no fixture reaches the host's docker. All commands below run
from the worktree root. The verifier could not write this file itself (Write refused); the
orchestrator saved its text unchanged.

## Harness (this directory)

| file | what it checks | host bash 5.3 | bash:3.2 | ubuntu:24.04 |
|---|---|---|---|---|
| `lib.sh` | shared setup: docker and timeout stand-ins, canned `--version`, log-order and JSON-tail helpers | - | - | - |
| `t_repos.sh` | check 1: repo_for, repos_for, pull_repos_for, the repo_ok/pull_repo_ok matrix, resolve_ref on all three networks, reference shapes, what image_for_tag and latest_docker_image ever name | 217/217 | 217/217 | 217/217 |
| `t_digest.sh` | check 2: a signed IMAGE_DIGEST end to end (real gpg detached signature, throwaway key, temp GNUPGHOME, mainnet pins answered for the fixture) | 33/33 | SKIP (no gpg) | SKIP (no gpg) |
| `t_floor.sh` | check 3: storage_migration_floor, storage_migrating_upgrade, update_downgrade_check `storage_downgrade` | 29/29 | 29/29 | 29/29 |
| `t_feature.sh` | check 4, the function: canned outputs, run failure, timeout rc 124, docker run flags, no docker call before the shape and network checks | 44/44 | 44/44 | 44/44 |
| `t_order.sh` | checks 4 and 5: call order and `--json` tails for setup-node (`main --json --phase=keygen`, interactive `_preflight_docker`), update-node (`main --json --prepare`, `prepare_docker_update`), edit-config (`main --json --set`, `run_set`, the menu) | 73/73 | 73/73 | 73/73 |
| `t_ui.sh` | check 6: server.py and index.html twins against the library's own answers; helper `docker_image_ok` | 155/155 | 18/18 + python SKIP | 18/18 + python SKIP |
| `t_scan.sh` | check 7: remove-node's scan against the UI's docker-detect | 29/29 | 29/29 | 29/29 |
| `t_leak.sh` | every IMG fixture and helper_test with a sentinel docker first on PATH | 18/18 | 18/18 | 18/18 |
| `t_mutants.sh` | 49 mutants, each in a scratch copy (`git archive HEAD`) | see Mutants | - | - |

Lint: all 10 files have a shebang and pass `shellcheck -x --severity=error` (0.11 on the host,
`koalaman/shellcheck:v0.9.0`), `bash -n` (5.3 and `bash:3.2`) and `tools/check-bash32.sh`.

## Fixture and suite counts per environment

`bash tools/tests/run.sh tools/tests/<name>_test.sh` for the eight IMG fixtures,
`bash ui/tests/helper_test.sh`, and pytest:

| fixture | bash 5.3.9 (host) | bash:3.2 (3.2.57) | ubuntu:24.04 (5.2.21) |
|---|---|---|---|
| docker_image | 331, 0 fail | 331, 0 fail | 331, 0 fail |
| network_detect | 156, 0 fail | 156, 0 fail | 156, 0 fail |
| setup_release | 109, 0 fail | 94, 0 fail, 3 skip | 94, 0 fail, 3 skip |
| release_fetch | 125, 0 fail | 49, 0 fail, 1 skip (no gpg) | 49, 0 fail, 1 skip (no gpg) |
| remove | 368, 0 fail | 368, 0 fail | 368, 0 fail |
| source_ref | 220, 0 fail | 167, 0 fail, 2 skip | 182, 0 fail, 1 skip |
| storage_migration | 96, 0 fail, 7 skip | 96, 0 fail, 7 skip | 126, 0 fail |
| update_guard | 73, 0 fail | 73, 0 fail | 73, 0 fail |
| ui/tests/helper_test.sh | 556, 0 fail | 556, 0 fail | 556, 0 fail |

pytest: `docker run --rm -e PYTHONDONTWRITEBYTECODE=1 -v "$PWD:/w" -w /w python:3.10-slim sh -c
'python -m pip install -q --require-hashes -r ui/requirements.txt -r ui/tests/requirements-dev.txt
>/dev/null 2>&1 && python -m pytest -q -p no:cacheprovider ui'` gives 283 passed and 1268
subtests passed on Python 3.10.22, and the same on 3.12.16. `PYTHONDONTWRITEBYTECODE` and
`-p no:cacheprovider` keep root-owned cache files out of the worktree.

## The seven checks

1. **Repository helpers and resolve_ref** (`bash tasks/verify-r2/V7-IMG/t_repos.sh`): pass.
   `tn_docker_repo_for` gives tn-testnet, tn-mainnet and GAR (devnet). `repos_for` gives testnet
   `GAR telcoin-network tn-testnet`, mainnet `tn-mainnet` and devnet `GAR telcoin-network tn-dev`.
   `pull_repos_for` is the same minus the old package. In the matrix the old package is
   recognised on testnet and devnet, is never pulled anywhere, and mainnet does not recognise it.
   tn-dev is devnet only. Uppercase, a trailing slash, a `docker.io/` prefix, a double slash, an
   attached tag, whitespace and a suffix are refused on every network. resolve_ref refuses all of
   these: `tn-testnet:v0.17.0-adiri`, `tn-testnet:v1.0.0` and any `-adiri` tag on mainnet;
   `tn-mainnet:v1.0.0`, a plain tag and the tn-mainnet digest on testnet; `latest` and
   `<repo>:latest`; the old package by tag or digest; GAR and tn-dev on mainnet; tn-dev on
   testnet; an rc tag on mainnet; a raw mainnet digest with no record, with a testnet record or
   with an rc record. The release lookup is never called for a refused shape (the call log shows
   this). tn_docker_image_for_tag's registry fallback asks tn-testnet and then GAR, never the old
   package, and only on testnet. On mainnet, no keys or rc 2 gives rc 1 with no registry call.
   latest_docker_image's fallback lists GAR only and never runs on mainnet or devnet.
2. **IMAGE_DIGEST naming another package** (`bash tasks/verify-r2/V7-IMG/t_digest.sh`): pass.
   This test goes through the real `_tn_release_fetch` and gpgv with a signed SHA256SUMS. A
   mainnet v1.0.0 whose IMAGE_DIGEST names tn-testnet is refused with `Release v1.0.0:
   IMAGE_DIGEST names ghcr.io/telcoin-association/tn-testnet@sha256:…, but a mainnet release
   image is <repository>@sha256:<digest> from ghcr.io/telcoin-association/tn-mainnet. The
   release is refused and nothing was pulled`. The old package, GAR, tn-dev, a tag and an
   uppercase repository are also refused on mainnet. tn-mainnet is taken. On testnet: tn-testnet
   and GAR are taken; tn-mainnet, the old package and tn-dev are refused. BADSIG and an
   IMAGE_DIGEST swapped after signing are refused. The staging dir is left empty every time.
   image_for_tag on mainnet does not fall back to the registry after the refusal.
3. **Storage floor** (`bash tasks/verify-r2/V7-IMG/t_floor.sh`): pass. Mainnet `v0.1.3 →
   v0.2.0` is not one way, with the network given or read from the host's `.node-meta`. Mainnet
   `v0.2.0 → v0.1.3` is refused as a downgrade with `"storage_downgrade":false`. Testnet
   `v0.15.2-adiri → v0.16.0-adiri` is one way, and `v0.16.0-adiri → v0.15.0-adiri` gives
   `"storage_downgrade":true`. Devnet has no floor. An unknown network (a name like `prod`, or a
   host whose network cannot be told) takes the testnet floor.
4. **Feature check** (`t_feature.sh`, `t_order.sh`): pass. Accepted: mainnet with no features
   (with or without the trailing space); testnet `adiri`, `adiri,faucet`, `faucet,adiri`, and
   `adiri` with a CR. Refused: mainnet `adiri`, `faucet`, `default` or anything else; testnet
   with no features, `faucet` alone or `adiri,evil`; two lines; a missing or indented line;
   empty output; `docker run` exit 1 or 125 even when the canned line is good; timeout rc 124.
   The run is exactly `timeout 60 docker run --rm --pull=never --network none --cap-drop ALL
   --security-opt no-new-privileges --read-only --entrypoint /usr/local/bin/telcoin <img>
   --version`. Devnet gets an info line and no docker call. An unknown network, and an image not
   given by digest, are refused before any docker call. Order in every path: resolve → pull →
   `image inspect` RepoDigests → `--version` run. Nothing that starts a container or writes
   `.node-meta`, pending state or the start script comes before the `--version` run. After a
   refusal, none of them happens.
5. **`--json` tails** (`t_order.sh`): pass. Stdout holds JSON lines only, and the last two are
   `error` then `done` with `"ok":false`. The full event lists for a testnet image built without
   adiri: setup `step log log error done`; update `warn step warn warn error done`; edit `step
   step warn error done`. The same tail holds for a mainnet image built with adiri, a failed
   `docker run`, a failed pull (setup), and an old-package digest refused before any docker call
   (update).
6. **UI twins** (`t_ui.sh`, pytest): pass. `IMAGE_REPO` equals `tn_docker_repo_for`.
   `DOCKER_REPO` equals `tn_docker_repos_for`, order included. `docker_pull_repo_ok`,
   `image_allowed` and `pull_image_allowed` match the library over the matrix.
   `docker_image_choice` matches resolve_ref for 23 references on testnet and mainnet; the one
   exception is N2. The page's `IMAGE_REPO` equals the server's, so the wizard names the
   network's package. The helper's `docker_image_ok` applies the pull rule. The library-server
   agreement test in `ui/test_csrf.py` passes on 3.10 and 3.12.
7. **remove-node's scan** (`t_scan.sh`): pass. It counts GAR, the old package and tn-testnet (by
   tag and by digest) and tn-mainnet (by tag, by digest, and by tag plus digest), and skips
   another owner's ghcr image and nginx. See W2 for where it differs from the UI.

## Findings

### ERROR

None. I found no fail-open path at c0716f3. Every refusal branch I broke in a scratch copy
changes what my harness measures (see Mutants). The current code behaves as the spec asks.

### WARN

**W1. Five mutants survive the fixtures** (they are fixture gaps, not code bugs: my harness
catches all five on the real code). Command: `bash tasks/verify-r2/V7-IMG/t_mutants.sh M09 M19
M21 M30 M31`. Expected: at least one IMG fixture fails for each. Actual: `fixtures=-` for all
five.

- **M31**, `lib/common.sh` `tn_docker_image_for_tag`: changing `if [[ $rc -ne 2 || "$net" !=
  "testnet" ]]` to `if [[ $rc -ne 2 ]]` lets a mainnet tag take the registry's digest when the
  signed release cannot be downloaded (rc 2). That is fail open on mainnet, and no fixture
  notices: `docker_image_test.sh` tests mainnet without keys and testnet with `FETCH_RC=2`, but
  not mainnet with `FETCH_RC=2`. Fixture: `tools/tests/docker_image_test.sh`. Add `FETCH_RC=2`
  with `tn_docker_image_for_tag mainnet v1.0.0`, expect rc 1 and no registry lookup.
- **M30**, same function: adding the old package to the registry fallback list (`for r in
  "$repo" "$TN_GHCR_LEGACY_IMAGE_REPO" …`) is not noticed. The effect is fail closed
  (resolve_ref refuses the result later), but the fallback order is unpinned. Fixture:
  `tools/tests/docker_image_test.sh`. Record which repositories the registry fallback asks
  (testnet: tn-testnet, then GAR).
- **M09**, `tn_docker_image_network_ok`: changing `tmo=(timeout 60)` to `tmo=()` is not noticed.
  Without the limit, an image whose `--version` hangs would hang setup, update or edit while they
  hold the update lock. Fixture: `tools/tests/docker_image_test.sh`. Put a timeout stand-in on
  PATH and check it gets `60 docker run …`, and that its rc 124 is refused (`t_feature.sh`
  shows how).
- **M21**, `edit-config.sh` `edit_docker_image` (the menu): removing the
  `tn_docker_image_network_ok` call is not noticed. `setup_release_test.sh` covers
  `set_docker_image` only. Fixture: `tools/tests/setup_release_test.sh`. Add a menu case where
  the stubbed check refuses (FEAT_RC=1) and expect no `swap_docker_image` and no
  `edit_record_image`.
- **M19**, `update-node.sh` `prepare_docker_update`: dropping `"$net"` from the
  `docker_pull_target` call makes every interactive Docker update refuse the image (an empty
  network has no build-feature rule). It fails closed, but the interactive path is broken and no
  fixture fails. `network_detect_test.sh` drives `json_prepare_docker` only. Fixture:
  `tools/tests/network_detect_test.sh`. Add a `prepare_docker_update` run that checks the
  stubbed check gets `check <node network> <image>`.

**W2. The UI's docker-detect does not count tn-dev containers; remove-node's scan does.**
Command: `bash tasks/verify-r2/V7-IMG/t_scan.sh`, which prints `info  scan difference:
c-dev-dig (ghcr.io/telcoin-association/tn-dev@sha256:…): remove-node yes, UI no`. Expected: the
two agree on which images count as a node, or the difference is written down. Actual:
`ui/telcoin-ui-helper.sh` `_docker_tn_names` asks `tn_docker_repo_ok` for testnet and mainnet
only. The helper says docker-detect exists "to recognise and monitor a Telcoin Network node
deployed as a dev-team docker container". After UPS, dev images (`make docker-adiri`/
`docker-devnet`) go to tn-dev, so a dev-team container started from a new dev image disappears
from the UI. Before this round those images were in the old package, which the UI recognises.
The implementer lists this as open issue 9 ("the UI does not manage devnet nodes"), but
docker-detect is about containers the UI does not manage, and dev adiri builds are not devnet
nodes. Fix: either count `TN_DEVNET_IMAGE_REPOS` too, or say in the helper comment and the docs
that dev-team containers from tn-dev are not shown.

### NOTE

- **N1. Finalize takes the recorded image by the recognition rule.** `setup-node.sh`
  `finalize_install_inputs`. Running the probe (sources a copy of setup-node; writes
  `.node-meta` with `NETWORK=testnet INSTALL_METHOD=docker PASSPHRASE_METHOD=stdin
  DOCKER_IMAGE=ghcr.io/telcoin-association/telcoin-network@sha256:<hex>`, then calls
  `finalize_install_inputs`) prints `finalize takes DOCKER_IMAGE=…telcoin-network@sha256:… (no
  pull rule, no feature check)`. Within one script version this is fine: keygen pulled and
  checked the image it recorded, and `json_check_install_flags` holds a `--docker-image` flag
  to the pull rule. It matters only when a pre-2.1.0 keygen recorded the old package, or when
  `.node-meta` was edited by hand. Hardening: `validate_docker_image … && tn_docker_pull_repo_ok`
  there, plus `tn_docker_image_network_ok` (the image is local after keygen).
- **N2. The UI wizard takes a mainnet digest alone; the library refuses it** (this predates
  IMG: at 9fd615a `docker_image_choice` already used `image_allowed`). `t_ui.sh` prints `info
  NOTE docker_image_choice mainnet takes ghcr.io/telcoin-association/tn-mainnet@sha256:…`. On a
  new install, `_preflight_docker` (`_setup_mainnet_digest_ok`) refuses it, so this fails closed
  late, with a less direct message. File: `ui/server.py` `docker_image_choice`.
- **N3. remove-node's scan matches more than the UI**, because `remove-node.sh`
  `custom_container_lines` runs `grep -E` over the whole `name<TAB>image<TAB>status` line. It
  also lists `ghcr.io/telcoin-association/tn-testnet-evil@…`, a busybox container named
  `*-adiri`, and `busybox:v1-adiri` (`t_scan.sh` info lines). The scan only reads, and each
  removal asks first, so this is harmless. The match is a substring one, not the exact one the
  comment implies.
- **N4. V7 check 1 says to refuse "the GAR name for a new pull"**, but the IMG spec keeps GAR in
  `TN_TESTNET_IMAGE_REPOS` (DEFAULT_DOCKER_IMAGE is there), so the library refuses GAR on
  mainnet and takes it on testnet. `GAR:v0.17.0-adiri` on testnet resolves through the signed
  release to `tn-testnet@sha256:…`: the repository prefix only gates acceptance. The library
  follows the IMG spec. I count this as a wording difference between the specs.
- **N5. Feature list format.** `tn_release_version_ok` strips all whitespace and splits on
  commas, so `Build Features: adiri faucet` is refused. Upstream `check_version_output` splits
  on `[, \t]+`. vergen prints commas, so there is no real mismatch, and the difference fails
  closed (`t_feature.sh` "space-separated list refused").
- **N6. DEFAULT_DOCKER_IMAGE must pass the feature check.** The pinned testnet fallback (GAR
  v0.16.0-adiri) is now checked like any image. Upstream
  `crates/telcoin-network-cli/src/version.rs` at v0.16.0-adiri prints the line, and that tag's
  `etc/Dockerfile` builds docker-adiri with `CARGO_FEATURES=adiri`. I could not run the real
  image here (no real pulls allowed). A one-time maintainer check on a host that holds it:
  `docker run --rm --pull=never --network none --entrypoint /usr/local/bin/telcoin
  <DEFAULT_DOCKER_IMAGE> --version` should print `Build Features: adiri`. If it does not, every
  testnet fallback install fails closed.
- **N7. Unknown-network floor.** `storage_migration_floor` gives the testnet floor for an empty
  or unknown network, as the spec says. This is the safe side: a one-way update never rolls back
  automatically.
- **N8. Host changes made before the check stay after a refusal.** These are the Docker engine
  install, daemon.json live-restore, the needrestart/apt conf files and the data dir. The spec
  promises only "no container, no .node-meta", and the message says exactly that ("No container
  was started and .node-meta was not written").
- **N9. The image prompt spins on stdin EOF** (this predates IMG; the same loop is at 9fd615a).
  `setup-node.sh` `_preflight_docker`'s `while true; read -r -p "  Docker image: …"` ignores
  read's status. With no usable default and stdin at EOF, the probe (stdin `/dev/null`,
  `latest_docker_image` failing) printed 4705 `Not usable` lines in 4 s. Interactive only:
  `--json` uses another branch. Mutant M27 hit this loop in the harness, which now stops after
  three prompts.
- **N10.** The feature check does not compare `Version:` with the release tag (implementer open
  issue 7; the spec asked for Build Features only).
- **N11. Fact check of the hand-back.** "Old package kept as TN_GHCR_LEGACY_IMAGE_REPO
  (recognition only, every network)": the old package is recognised on testnet and devnet only,
  refused for every new pull on every network, and mainnet never recognises it, as the IMG spec
  asks. Everything else in the hand-back holds. In `ckpt-r2-IMG.md` the first-round docs notes
  give `TN_DEVNET_IMAGE_REPOS` as "GAR legacy, old package" and suggest README 1463 wording
  "from the legacy repository". F1 superseded both (tn-dev added). DOCS-2 should use the F1
  wording.
- **N12.** No fixture reaches the host's docker. `bash tasks/verify-r2/V7-IMG/t_leak.sh` passes
  18/18 in all three environments, with a sentinel docker that exits 1 placed ahead of the real
  one.

## Mutants

`bash tasks/verify-r2/V7-IMG/t_mutants.sh` (V7IMG_JOBS=8). Each mutant ran in its own `git
archive HEAD` copy against the eight IMG fixtures, helper_test, pytest for the ui tag, and this
harness. I re-ran M27 after adding the prompt-loop guard; the result was the same.

- 49 mutants, all applied. M48 is equivalent: it drops the `[[ "${arg%:*}" != *@* ]]` guard in
  resolve_ref, but an `@` in the repository part can never match a pull repository exactly
  (probe: five such references, all rc 1). That leaves 48 that count.
- **Fixtures: 43/48.** Survivors: M09, M19, M21, M30, M31 (W1).
- **This harness: 47/48.** It misses M47 (repo_ok by substring), which `docker_image_test.sh`
  catches.
- **Fixtures or harness: 48/48.**

| id | mutant | fixtures that fail | harness that fails |
|---|---|---|---|
| M01 | feature check: one-line rule removed | docker_image | t_feature |
| M02 | docker run failure ignored | docker_image | t_feature, t_order |
| M03 | features never judged | docker_image | t_feature, t_order |
| M04 | unknown network accepted | docker_image | t_feature |
| M05 | not-by-digest accepted | docker_image | t_feature |
| M06 | testnet skipped like devnet | docker_image | t_feature, t_order |
| M07 | --pull=never dropped | docker_image | t_feature |
| M08 | --network none dropped | docker_image | t_feature |
| M09 | no timeout | **none** | t_feature |
| M10 | mainnet accepts any feature | docker_image, release_fetch, source_ref | t_feature, t_order |
| M11 | testnet without adiri accepted | docker_image, release_fetch | t_feature, t_order |
| M12 | testnet unknown feature accepted | docker_image, release_fetch | t_feature |
| M13 | setup: check call removed | setup_release | t_order |
| M14 | setup: check before the pull | setup_release | t_order |
| M15 | setup: refusal ignored | setup_release | t_order |
| M16 | update: check call removed | network_detect, update_guard | t_order |
| M17 | update: pending written before the check | network_detect, update_guard | t_order |
| M18 | update: check run as devnet | network_detect, update_guard | t_order |
| M19 | update interactive: no network passed | **none** | t_order |
| M20 | edit --set: check call removed | setup_release | t_order |
| M21 | edit menu: check call removed | **none** | t_order |
| M22 | edit --set: swap before the check | setup_release | t_order |
| M23 | pull rule takes the old package | docker_image, setup_release, release_fetch, helper, pytest | t_repos, t_digest, t_ui |
| M24 | resolve_ref: old-package case and final pull rule removed | docker_image, network_detect, setup_release | t_repos, t_order |
| M25 | tn-dev in TN_TESTNET_IMAGE_REPOS | docker_image, network_detect, setup_release, release_fetch, helper, pytest | t_repos, t_digest, t_scan, t_ui |
| M26 | mainnet repos_for adds tn-testnet | docker_image, release_fetch, helper, pytest | t_repos, t_digest, t_ui |
| M27 | repo_for testnet names the old package | docker_image, pytest | t_repos, t_order, t_ui |
| M28 | fetch_release_image: pull-rule half removed | release_fetch | t_digest |
| M29 | fetch_release_image: package check removed | release_fetch | t_digest |
| M30 | registry fallback adds the old package | **none** | t_repos |
| M31 | registry fallback on mainnet | **none** | t_repos |
| M32 | mainnet digest-alone rule removed | docker_image, setup_release | t_repos |
| M33 | mainnet takes the testnet floor | source_ref | t_floor |
| M34 | unknown network has no floor | source_ref, storage_migration | t_floor |
| M35 | storage_migrating_upgrade ignores its network | source_ref | t_floor |
| M36 | downgrade check always testnet floor | source_ref | t_floor |
| M37 | devnet floor 0.16.0 | source_ref | t_floor |
| M38 | server docker_pull_repo_ok takes the old package | pytest | t_ui |
| M39 | server DOCKER_REPO mainnet adds tn-testnet | pytest | t_ui |
| M40 | helper docker_image_ok drops the pull rule | helper | t_ui |
| M41 | remove-node scan drops tn-mainnet | remove | t_scan |
| M42 | remove-node scan drops tn-testnet | remove | t_scan |
| M43 | helper docker-detect drops mainnet | helper | t_scan |
| M44 | setup_fail sends no error event (--json) | network_detect | t_order |
| M45 | update --json: refused pull goes on to done ok:true | network_detect, update_guard | t_order |
| M46 | edit --set: feature refusal returns 0 | setup_release | t_order |
| M47 | repo_ok by substring | docker_image | - |
| M48 | resolve_ref split guard dropped (equivalent) | - | - |
| M49 | uppercase digest accepted | docker_image | t_repos |

## Compared with the implementer's checkpoint (`tasks/ckpt-r2-IMG.md`)

The counts match: docker_image 331, network_detect 156, setup_release 109, remove 368,
update_guard 73, helper 556, and pytest 283 + 1268 subtests on 3.10 and 3.12. Every claim
holds: the packages, the old package's role, tn-dev for devnet, both helper pairs, the floor per
network, the command and rules of the feature check, its call sites (setup interactive and
--json, update `docker_pull_target` with the network, edit `--set` and the menu), the refusal
messages, the JSON tails, the helper's pull rule, and the server constants and functions. The
checkpoint does not mention N1, N2, N9 or the five fixture survivors in W1. Its open issue 9 is
my W2, and its open issue 7 is my N10.

## Fixture files that need to change

- `tools/tests/docker_image_test.sh`: add mainnet `FETCH_RC=2` → rc 1 with no registry lookup
  (M31); record which repositories the registry fallback asks (M30); check the `timeout 60`
  wrapper and its rc 124 refusal (M09).
- `tools/tests/setup_release_test.sh`: add an `edit_docker_image` (menu) case whose feature
  check refuses: no swap, no record (M21).
- `tools/tests/network_detect_test.sh`: add a `prepare_docker_update` (interactive) case: the
  check gets the node's network (M19).
- Code, optional: `ui/telcoin-ui-helper.sh` `_docker_tn_names` (W2); `setup-node.sh`
  `finalize_install_inputs` (N1).

## Verdict

At c0716f3, IMG does what its spec asks:

- Mainnet and testnet each have their own package, and every stage derives the package from the
  network again.
- The old package is only recognised, never pulled, and tn-dev is devnet only.
- A signed IMAGE_DIGEST naming another package is refused end to end, under a real signature.
- The storage floor is per network, and an unknown network falls back to the testnet floor.
- The build-feature check runs after the pull and digest check and before anything starts or is
  recorded, in all six paths (setup interactive and --json, update interactive and --json, edit
  --set and the menu). It fails closed on a bad line, a failed run or a timeout, and every --json
  refusal ends with an error event and then done.

I found no ERROR. The weak spot is the fixtures. Five of 48 non-equivalent mutants survive them,
M31 among them: a mainnet registry fallback that would be fail open if someone reintroduced it.
This harness catches all five, and they need small additions to `docker_image_test.sh`,
`setup_release_test.sh` and `network_detect_test.sh`. The UI docker-detect gap for tn-dev
containers (W2) should be decided before release, either fixed or documented. The rest are
notes, mostly hardening and items that predate IMG.
