status: done

IMG-2: V7-IMG fix round on r2/IMG2 (base 64c3d65). Harness read from
~/coding/telcoin/tnd-r2-base/tasks/verify-r2/V7-IMG (not in this tree; run with
V7IMG_REPO pointing here).

- [x] W1 M31+M30 docker_image_test: mainnet rc-2 fetch, no registry lookup; testnet fallback order (3f1f3ae)
- [x] W1 M09 docker_image_test: timeout stand-in (60 docker run ...), rc 124 refused (96d0e10)
- [x] W1 M21 setup_release_test: edit menu, check refuses -> no swap, no record, no meta (48bae0d)
- [x] W1 M19 network_detect_test: interactive prepare_docker_update passes the network (86ed5fa)
- [x] W2 ui helper docker-detect counts the devnet list (tn-dev) + helper_test fixture (d2fc0b1)
- [x] N1 setup-node finalize_install_inputs: pull rule + feature check + fixture (6546f24)
- [x] N9 setup-node _preflight_docker prompt: EOF refuses + fixture (9ce9f15)
- [x] F1 finalize --docker-image replaces the recorded image (keygen preflight path), refusals name the way out (cc72dcb)
- [x] Lints, fixtures 5.3 + 3.2, helper_test, t_mutants M09 M19 M21 M30 M31 (full host suite: see Tests run)

## Mutation results

(scratch copy of the worktree, mutant applied, fixture run; tree itself green)
- M31 (rc -ne 2 only): docker_image_test 3 FAIL (mainnet rc 2 refused / no lookup / no registry digest offered). CAUGHT.
- M30 (old package added to the fallback): docker_image_test 2 FAIL (order pins, with and without key). CAUGHT.
- M09 (tmo=()): docker_image_test 4 FAIL (timeout 60 argv, rc 124 refused, message, one call). CAUGHT.
- M21 (menu check -> if false): setup_release_test 4 FAIL (menu order, refusal order, meta untouched, message). CAUGHT.
- M19 (no network to docker_pull_target): network_detect_test 2 FAIL (testnet and devnet order). CAUGHT.
- W2 check (devnet half removed from _docker_tn_names): helper_test 2 FAIL (docker-detect list, docker-status tnd). CAUGHT. Also mainnet half removed (own variant of M43, whose harness anchor no longer matches the split line): 1 FAIL. CAUGHT.
- N1a (finalize pull rule -> if false): setup_release_test 3 FAIL. CAUGHT. N1b (finalize feature check -> if false): setup_release_test 4 FAIL, finalize_inputs_test 1 FAIL. CAUGHT.
- N9 (read status ignored again): setup_release_test 3 FAIL (rc 99 after three prompts, message, default case). CAUGHT.
- F1 override mutants (setup_release unless noted): OVa override replaced by the old
  finalize_same_as_keygen refusal: 8 FAIL, finalize_inputs 1 FAIL. OVb resolve skipped:
  7 FAIL. OVc override feature check removed: 5 FAIL. OVd record dropped: 2 FAIL
  (.node-meta at config, digest). OVe record before the pull: 4 FAIL (.node-meta changed on
  refusal). OVf pull skipped: 2 FAIL. OVg stale RELEASE_TAG kept: 1 FAIL. All CAUGHT.

- Verifier harness (V7IMG_REPO=this tree, t_mutants.sh M09 M19 M21 M30 M31): fixtures=docker_image / network_detect / setup_release / docker_image / docker_image; caught by the fixtures 5/5, every mutant applied. Also M13 M16 M20 still caught. M43 is NOT-APPLIED now (its anchor line was split by W2).

## Operator-visible changes

- UI: the Docker container list (helper docker-detect) also shows containers of the
  devnet repositories, which include ghcr.io/telcoin-association/tn-dev (dev-team
  images); docker-status/docker-logs accept them.
- setup-node --json --phase=finalize (Docker): the image keygen recorded is refused if
  it is the old single package (or any repository a new pull does not take), and its
  build features are checked again before anything is written or started. Messages
  (after F1): "Refusing the image <img>: setup runs only <repo>@sha256:<digest>. No
  container was started; to replace it, run finalize again with --docker-image
  <repo>@sha256:<digest> (a <net> image)." and "Refusing the image <img>: it is not a
  <net> image (see above). No container was started; to replace it, run finalize again
  with --docker-image <repo>@sha256:<digest> (a <net> image)."
- F1: finalize --docker-image naming another image than the recorded one replaces it
  (resolve, pull by digest, digest check, build-feature check, then .node-meta), so a
  bad recorded image is fixed without a new keygen (which refuses while node-keys exist).
- setup-node interactive, Docker image prompt: end of input (Ctrl-D, closed stdin) stops
  setup with "The input ended at the Docker image prompt, so no usable image was given
  and the Docker install stops. Nothing was pulled and no container was started.",
  with or without a default (only Enter takes the default). Before: endless "Not
  usable" loop (set +e) or a silent exit 1 (set -e).

## Docs notes

- F1: `setup-node.sh --json --phase=finalize --docker-image <repository>@sha256:<digest>`
  naming another image than keygen recorded replaces it: resolved by tn_docker_resolve_ref
  (pull rule; mainnet digest rule), held to the oldest supported release, pulled by
  digest, digest-checked, build-feature checked, then recorded in .node-meta (DOCKER_IMAGE,
  DOCKER_IMAGE_DIGEST, RELEASE_TAG or its removal) before the config, unit and container.
  Refusals: "Refusing the image <img> given with --docker-image (see above). No container
  was started and .node-meta was not changed." / "Refusing the image <img>: it is not a
  <net> image (see above). No container was started and .node-meta was not changed." /
  "Failed to pull Docker image: <img>. No container was started and .node-meta was not
  changed." The recorded-image refusals now end "No container was started; to replace
  it, run finalize again with --docker-image <repo>@sha256:<digest> (a <net> image)."

- UI docker-detect: the Node Manager's Docker view lists containers whose image comes
  from any repository the library recognises for testnet, mainnet or devnet, so a
  dev-team container from ghcr.io/telcoin-association/tn-dev is shown (as remove-node's
  custom-container scan lists it).
- Finalize check: setup-node --json --phase=finalize holds the Docker image keygen
  recorded in .node-meta to the same pull rule and build-feature check keygen's
  preflight applied, before the config, the unit and the container, and stops with
  "...No container was started; to replace it, run finalize again with --docker-image <repo>@sha256:<digest> (a <net> image)." (F1 wording; see the F1 note above)
- Interactive image prompt at end of input refuses (message above); worth one line in
  OPERATOR troubleshooting if DOCS-2 lists setup prompts.
- ckpt-r2-IMG.md open issue 9 is resolved by W2 (drop it from any docs list).

## Tests run

Lints on the 8 touched files (setup-node.sh, ui/telcoin-ui-helper.sh, ui/tests/helper_test.sh,
tools/tests/{docker_image,setup_release,network_detect,finalize_inputs,setup_passphrase}_test.sh):
check-bash32 clean; shellcheck 0.11 and koalaman/shellcheck:v0.9.0 -x --severity=error clean;
bash -n 5.3 and bash:3.2 clean; check-network-hits clean (147); check-perl-interp clean (171);
git diff --check 64c3d65..HEAD clean.

Fixtures (bash tools/tests/run.sh):
- bash 5.3: docker_image 347, setup_release 125, network_detect 161, update_guard 73,
  remove 368, finalize_inputs 23, setup_passphrase 80, launch_flags 28, host_baseline 223
  (3 skipped): 0 failures. ui/tests/helper_test.sh 557 checks, 0 failed.
- bash:3.2: docker_image 347, setup_release 110 (3 skipped: no python3/jq), network_detect
  161, update_guard 73, remove 368, finalize_inputs 23, setup_passphrase 80, launch_flags
  28, host_baseline 232 (1 skipped): 0 failures. helper_test 557, 0 failed.
- Full host suite (bash 5.3, all 62 files, tip 9ce9f15): 62 files, 0 failed.
- F1 (cc72dcb): bash 5.3 setup_release 138, finalize_inputs 24, setup_passphrase 82,
  launch_flags 28, network_detect 161, host_baseline 223 (3 skipped), docker_image 347;
  bash:3.2 setup_release 123 (3 skipped), finalize_inputs 24, setup_passphrase 82,
  launch_flags 28, network_detect 161, host_baseline 232 (1 skipped), docker_image 347;
  all 0 failures. Full host suite with a docker guard on PATH: 62 files, 0 failed.
  Lints (check-bash32, shellcheck 0.11 and 0.9, bash -n 5.3 and 3.2, check-network-hits
  147, check-perl-interp 171, git diff --check) clean.
- Verifier t_mutants.sh M09 M19 M21 M30 M31 (V7IMG_REPO=this tree): caught by the fixtures 5/5;
  harness column also lists t_scan for each (open issue 1). M13 M16 M20 still caught; M43 NOT-APPLIED (open issue 2).

## Open issues

F1 round:
A. Incident: before setup_passphrase_test.sh was fixed, its two finalize listener cases
   (--docker-image $DEFAULT_DOCKER_IMAGE, nothing recorded) reached the new override on
   the host and ran a real `docker pull` of DEFAULT_DOCKER_IMAGE (twice), which the host
   already held (image b905b0982e87). No container ran (the feature check was stubbed).
   The test now records the image as keygen does and stubs docker; a full suite run with
   a failing docker guard first on PATH shows no docker call from any IMG test.
B. That guarded run shows one pre-existing real docker call: `docker rm -f x` from
   tools/tests/obs_test.sh (not IMG; its comment says obs_disable runs a real docker rm -f).
C. On mainnet the override takes only what tn_docker_resolve_ref takes from --docker-image:
   a digest .node-meta records for a mainnet release. A mainnet override by release tag
   would need --release-tag at finalize (refused with --docker-image today). Mainnet
   Docker installs are refused anyway until chain configs are pinned.
D. finalize_same_as_keygen still says "or run keygen again" for --install-method,
   --data-dir and --binary-path; --docker-image no longer goes through it.


1. Verifier harness t_scan.sh pins the old W2 behaviour: `check "differs: tn-dev not
   counted by the UI" no ...` now fails (by design of W2); expected becomes yes (or
   the check moves to the "agree" list). That is why every mutant run shows
   harness=...,t_scan.
2. Verifier mutant M43's anchor (`if tn_docker_repo_ok testnet "$repo" || tn_docker_repo_ok
   mainnet "$repo"; then`) no longer matches: the condition is split over two lines
   with the devnet half. New anchor: `if tn_docker_repo_ok testnet "$repo" ||
   tn_docker_repo_ok mainnet "$repo" \` -> `if tn_docker_repo_ok testnet "$repo" \`
   (helper_test catches that, checked).
3. setup-node.sh and ui/telcoin-ui-helper.sh are updater-tracked: their .sha256 sidecars
   need regenerating at integration (not done here, by the rules).
4. Finalize now runs `docker run --pull=never` on the recorded image: if the image was
   removed between keygen and finalize, finalize stops ("Could not run ... Check that
   Docker is running and holds the image") instead of starting a container that would
   pull it. Fail closed, as decided; the message says what to do.
