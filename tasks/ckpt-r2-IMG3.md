status: done

IMG-3: review fix round (REV findings M3, L1, L2, L3, L5, N4) on r2/IMG3 (base f9e22fb).

- [x] M3 lib/common tn_docker_image_network_ok: --init, --name, timeout -k 5 60, rm -f on 124/137 + fixture (969da34; mutants noK/noInit/noRm/only124 caught: 1/2/4/4 FAIL)
- [x] L1 finalize_docker_override: release lookup for a digest alone before the floor + fixture (0902d13; mutant (no lookup) caught: setup_release 6 FAIL)
- [x] L2 finalize_docker_override: RELEASE_TAG removed first, image + digest, new RELEASE_TAG last + fixture (9eb645f; mutant (old order) caught: setup_release 2 FAIL)
- [x] L3 finalize --release-tag as the override; refusals name the way out per network + fixtures (3f3baa8; mutants (override skipped, mainnet way out) caught: 7+2, 2 FAIL)
- [x] L5 json_phase_finalize: every input check before the override + fixture (072e348; mutant (old order) caught: setup_release 13 FAIL)
- [x] N4 _preflight_docker: a last line without newline is taken + fixture (52d276e; mutant (old condition) caught: setup_release 3 FAIL)
- [x] Lints, fixtures 5.3 + 3.2, sentinel-docker full suite (see Tests run)

Second round (coordinator):
- [x] R1 update-node docker_record_meta + edit-config edit_record_image: ordered record + fixtures (0785452; mutants: old order UP 2 / EC 5 FAIL, unset-first-no-chain UP 1 / EC 1 FAIL)
- [x] R2 restart_window_test: docker stub in mig(); sentinel full suite clean (f231e96; sentinel alone on restart_window: empty)
- [x] R3 tasks/verify-r2/V7-IMG t_feature.sh + t_mutants.sh for M3 (one tasks: commit) (2ca2a76; t_feature 50 checks green 5.3 + 3.2; t_mutants M07 M08 M09 caught 3/3 by fixtures and harness)
- [x] R4 lints, fixtures 5.3 + 3.2, sentinel full suite (63 files rc 0, 5742 checks, sentinel log empty)

## Operator-visible changes

- M3: the build-feature check (setup-node, update-node, edit-config, finalize) runs
  `timeout -k 5 60 docker run --rm --init --name tn-feature-check-<pid>-<n> --pull=never
  --network none --cap-drop ALL --security-opt no-new-privileges --read-only --entrypoint
  /usr/local/bin/telcoin <img> --version` where timeout exists. A hanging --version now ends
  within about 65 s (TERM at 60 s reaches the binary through the init; KILL 5 s later), and
  the container is removed (`timeout -k 5 30 docker rm -f <name>`). New refusal:
  "Image refused: <img> did not finish --version within 60 seconds (docker run exited <rc>
  under timeout), so its build features are not known. It is not used and nothing was
  changed; docker rm -f <name> was run to remove its container. Check that Docker is
  running, then try again; if a <net> release names this image, report it to the node team."
  Without timeout (macOS without coreutils) the run has no limit.
- L5: a --json finalize checks the listener multiaddrs and the recorded node flags BEFORE
  the image inputs; a refused finalize leaves .node-meta as keygen wrote it (no pull).
- L1: finalize --docker-image <digest> on testnet looks up the digest's release (the
  registry's release tags) as keygen does: below the oldest supported release it is refused
  before the pull ("... older than v0.13.0 ..." from tn_ref_min_check); otherwise
  RELEASE_TAG records it. Info line: "The registry names <img> as the image of release <tag>."
- L2: the override's .node-meta record: RELEASE_TAG removed, DOCKER_IMAGE and
  DOCKER_IMAGE_DIGEST written, then RELEASE_TAG; an interrupted record leaves "release
  unknown", never the old release beside the new digest.
- L3: finalize --release-tag <tag> on a Docker install replaces the recorded image with the
  release's image (signed release digest; same oldest-release, pull, digest, feature-check
  and record sequence; RELEASE_TAG = the tag). Before, finalize ignored it for Docker and
  step_write_config recorded the tag beside the old digest. Both flags together stay refused
  ("Give --docker-image or --release-tag, not both.").
- N4: the interactive image prompt takes a last line without a newline
  (`printf 'v0.17.0-adiri' | setup-node.sh`) instead of stopping.

## Docs notes

- Second round: update-node (after a Docker update) and edit-config (after an image
  change) now record .node-meta in the same order as the finalize override: RELEASE_TAG
  removed, DOCKER_IMAGE and DOCKER_IMAGE_DIGEST written, the new RELEASE_TAG last, each
  only after the one before succeeded. Warnings unchanged ("Could not record the new image
  in .node-meta (DOCKER_IMAGE, DOCKER_IMAGE_DIGEST, RELEASE_TAG)." / "Could not record the
  image in .node-meta (...)"). No operator-facing text changed.

Exact texts (setup-node.sh, --json finalize, Docker install):
- Recorded image fails the pull rule: "Refusing the image <img>: setup runs only
  <repo>@sha256:<digest>. No container was started; to replace it, <WAY>."
- Recorded image fails the feature check: "Refusing the image <img>: it is not a <net>
  image (see above). No container was started; to replace it, <WAY>."
- <WAY> by network:
  - mainnet: "run finalize again with --release-tag <tag> (a mainnet release, such as v1.0.0)"
  - testnet: "run finalize again with --docker-image <repo>@sha256:<digest> or --release-tag
    <tag> (a testnet image or release)"
  - devnet: "run finalize again with --docker-image <repo>@sha256:<digest> (a devnet image)"
- Override refused at the resolve: "Refusing the image <ref> given with --docker-image (see
  above). No container was started and .node-meta was not changed." (unchanged) and, new,
  "Refusing the image of release <tag> given with --release-tag (see above). No container was
  started and .node-meta was not changed."
- Override progress step: "Replacing the recorded image <rec> with the image <ref>" /
  "... with the image of release <tag>".
- Feature-check timeout refusal: see M3 above.
- --help (setup-node.sh header, NODE BINARY): "In a --json finalize run of a Docker install,
  --release-tag <tag> (that release's image, by the digest the signed release names) or
  --docker-image <repository>@sha256:<digest> naming another image than the one keygen
  recorded replaces it: once every other finalize input has been checked, it is checked and
  pulled as keygen's would be, and recorded in .node-meta before the config, the unit and the
  container. On mainnet a new image is named by --release-tag only (a digest alone is taken
  only for a release this node recorded)."
Stale lines for DOCS-2:
- README setup steps and OPERATOR Docker table "60 seconds at most": now true where
  `timeout` exists (TERM at 60 s, KILL 5 s later, container removed); add that macOS without
  coreutils has no limit.
- README/OPERATOR row for `--json --phase=keygen|finalize` ("finalize refuses flags that
  differ from what keygen recorded"): not true for --docker-image and, on a Docker install,
  --release-tag (both replace the recorded image).
- IMG-2's F1 docs note: add --release-tag, the per-network way out (mainnet: --release-tag
  only), the order (after the listener and node-flag checks), and the record order.
- OPERATOR troubleshooting for the image prompt: a last line without a newline is taken.

## Tests run

Lints on the 6 touched files (lib/common.sh, setup-node.sh, tools/tests/{docker_image,
setup_release,finalize_inputs,setup_passphrase}_test.sh): check-bash32 clean; shellcheck
0.11 (host) and koalaman/shellcheck:v0.9.0 -x --severity=error clean; bash -n 5.3 and
bash:3.2 clean; check-network-hits clean (147 annotated hits, 24 files); check-perl-interp
clean (181 files); git diff --check f9e22fb..HEAD clean.

Fixtures (bash tools/tests/run.sh; bash:3.2 with the worktree mounted at its absolute path):
- bash 5.3: docker_image 358, setup_release 176, finalize_inputs 26, setup_passphrase 82,
  network_detect 161, launch_flags 28, keytool 45, restart_window 62: 0 failures.
- bash:3.2: docker_image 358, setup_release 161 (3 skipped: no python3/jq), finalize_inputs
  26, setup_passphrase 82, network_detect 161, launch_flags 28, keytool 45, restart_window
  62: 0 failures.
- Sentinel run (bash 5.3): every tools/tests/*_test.sh (62) and ui/tests/helper_test.sh,
  each with a sentinel docker first on PATH that logs its argv and exits 1: 63 files rc 0,
  5733 checks. Sentinel log: one line, "restart_window_test | rm -f x", the same on base
  f9e22fb (migrate-node-naming.sh stop_legacy with LEGACY_CONTAINER=x; not an IMG fixture).
  No IMG fixture reached it.
- Mutants (scratch copies, fixture runs): M3 no -k 1 FAIL, no --init 2, no rm 4, 124 only 4;
  L5 old order 13; L1 no lookup 6; L2 old record order 2; L3 override skipped 7 + 2
  (finalize_inputs), mainnet way out 2; N4 old condition 3. All caught.

Second round (bash tools/tests/run.sh):
- Lints on update-node.sh, edit-config.sh, tools/tests/{update_guard,setup_release,
  restart_window}_test.sh and tasks/verify-r2/V7-IMG/{lib,t_feature,t_mutants}.sh:
  check-bash32, shellcheck 0.11 and 0.9 (-x --severity=error), bash -n 5.3 and 3.2 clean;
  check-network-hits clean (147), check-perl-interp clean (181), git diff --check clean.
- bash 5.3: update_guard 78, setup_release 180, restart_window 62, network_detect 161,
  storage_migration 96 (7 skipped), pending_state 82 (6 skipped): 0 failures.
- bash:3.2: update_guard 78, setup_release 165 (3 skipped), restart_window 62,
  network_detect 161, storage_migration 96 (7 skipped), pending_state 99: 0 failures.
- V7-IMG t_feature.sh: 50 checks, 0 failures (bash 5.3 and bash:3.2); other V7-IMG t_*.sh
  green (t_repos 217, t_floor 29, t_digest 33, t_order 73, t_scan 29, t_leak 18).
- V7-IMG t_mutants.sh M07 M08 M09: applied 3/3, caught by the fixtures 3/3 and by the
  harness 3/3 (docker_image, t_feature).
- Sentinel run 2 (tip 2ca2a76, bash 5.3): 62 tools/tests files + ui/tests/helper_test.sh,
  63 rc 0, 5742 checks; sentinel log empty (0 bytes).
- Mutants (scratch copies): update-node old order 2 FAIL (update_guard), edit-config old
  order 5 FAIL (setup_release); unset first but no chain: 1 FAIL each.

## Open issues

1. (Resolved in 2ca2a76: lib.sh stand-in, t_feature.sh pins, t_mutants M07/M08/M09
   anchors.) Verifier harness tasks/verify-r2/V7-IMG/t_feature.sh pinned the old argv and its stand-in
   (lib.sh v7_timeout_stub: `shift; exec "$@"`) does not drop `-k 5`: 3 FAIL now
   ("under timeout, good image accepted", "the run goes through timeout 60", "docker run
   flags"). New argv: `timeout -k 5 60 docker run --rm --init --name
   tn-feature-check-<pid>-<n> --pull=never --network none --cap-drop ALL --security-opt
   no-new-privileges --read-only --entrypoint /usr/local/bin/telcoin <img> --version`; the
   stand-in needs `[ "$1" = -k ] && shift 2; shift; exec "$@"`. The rc-124 message still
   contains "docker run exited 124". V7-IMG t_mutants M09 anchor (`tmo=(timeout 60)`) no
   longer matches: new anchor `tmo=(timeout -k 5 "$limit")`.
2. (Resolved in 0785452.) Same L2 pattern outside my files: update-node.sh docker_record_meta and edit-config.sh
   edit_record_image write DOCKER_IMAGE, DOCKER_IMAGE_DIGEST, then set or unset RELEASE_TAG;
   a failed or interrupted RELEASE_TAG write leaves the new digest with the old release. Fix:
   `meta_unset RELEASE_TAG` first, then the two image keys, then `meta_set RELEASE_TAG "$2"`
   only when $2 is set.
3. Cosmetic: for a digest alone, tn_docker_resolve_ref (lib, not in my scope) warns "the
   downgrade and oldest-release checks cannot be applied to it" before the override's lookup
   finds the release; the next info line names it and the floor check then applies.
4. Design: finalize --release-tag whose image equals the recorded one still runs the whole
   override (pull, checks, record) instead of "no override" as an equal --docker-image does;
   idempotent, and it makes RELEASE_TAG match.
5. Sidecars: lib/common.sh and setup-node.sh .sha256 need regenerating at integration.
6. (Resolved in f231e96.) Pre-existing real docker call (not IMG): tools/tests/restart_window_test.sh runs
   migrate-node-naming.sh stop_legacy with LEGACY_CONTAINER=x and no docker stub, so the
   host's `docker rm -f x` runs (IMG-2 saw a similar call from obs_test.sh, which no longer
   hits). A `docker() { :; }` stub inside its mig() subshell would close it.
