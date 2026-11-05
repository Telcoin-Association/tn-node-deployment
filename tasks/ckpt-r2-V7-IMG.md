status: done

# V7-IMG checkpoint (IMG section of V7, round 2)

Worktree tnd-r2-V7 at c0716f3. Records: tasks/verify-r2/V7-IMG/. Scratch: scratchpad/V7-IMG/.

- [x] 0 Read code (common.sh image helpers, setup-node/update-node/edit-config preflights, ui)
- [x] 1 repo_for/repos_for/repo_ok + pull_repo_ok/pull_repos_for per network; resolve_ref refusals
- [x] 2 IMAGE_DIGEST naming another package refused on mainnet
- [x] 3 storage_migration_floor per network (incl. unknown network)
- [x] 4 feature check (stub docker), docker run failure/timeout, ref shapes; order in setup-node/update-node/edit-config
- [x] 5 --json paths (error event then done only)
- [x] 6 UI twins, pytest 3.10/3.12
- [x] 7 remove-node container scan vs UI docker-detect
- [x] 8 grep every pull path (docker pull, tn_docker_resolve_ref, tn_docker_image_for_tag, latest_docker_image)
- [x] 9 mutants in scratch copy
- [x] 10 fixtures in bash 5.3 / bash:3.2 / ubuntu:24.04 + helper_test + pytest
- [x] 11 harness lint
- [x] 12 compare with tasks/ckpt-r2-IMG.md
- [x] 13 REPORT.md: Write REFUSED (report-file rule); complete text returned in the hand-back for the orchestrator to save as tasks/verify-r2/V7-IMG/REPORT.md

## Findings (running)
- t_repos.sh 217/217 bash 5.3 (no finding: shapes uppercase/trailing slash/tag+digest/prefix all refused)
- t_feature.sh 44/44, t_floor.sh 29/29, t_digest.sh 33/33 (real gpg sig, mainnet pins stubbed)
- t_order.sh 73/73: setup(json+int), update(json+int), edit(json, --set, menu); order resolve>pull>inspect>--version>meta/keygen/pending/swap; json tails error,done
- t_ui.sh 155/155; pytest 3.10 283 passed, 3.12 283 passed. NOTE (pre-existing): UI docker_image_choice takes mainnet digest alone, lib refuses w/o record
- t_scan.sh 29/29; WARN UI docker-detect misses tn-dev containers (remove-node counts them); NOTE remove-node substring matches (-adiri anywhere, tn-testnet-evil)
- t_mutants.sh written (49 mutants); smoke M12-M14 caught by fixtures and harness; full run in progress -> scratch V7-IMG/mut-all.log
- t_leak.sh 18/18: no fixture reaches the host docker (sentinel first on PATH)
- NOTE finalize_install_inputs takes a recorded DOCKER_IMAGE by the recognition rule (old package passes on testnet), no pull rule, no feature check (scratch proto/finalize.sh); reachable only via a pre-IMG keygen or a hand-edited .node-meta

## Operator-visible changes
(none: verifier)
## Docs notes
## Tests run
## Open issues

## Counts so far
- fixtures 5.3: docker_image 331, network_detect 156, release_fetch 125, remove 368, setup_release 109, source_ref 220, storage_migration 96 (7 skip), update_guard 73; all exit 0
- fixtures bash:3.2: 331/156/49(1 skip)/368/94(3 skip)/167(2 skip)/96(7 skip)/73; all exit 0
- fixtures ubuntu:24.04: 331/156/49(1 skip)/368/94(3 skip)/182(1 skip)/126/73; all exit 0
- helper_test 556/556 on 5.3 and 3.2; pytest 283 passed on 3.10 and 3.12
- harness host: repos 217, feature 44, floor 29, digest 33, order 73, scan 29, ui 155 (all pass); bash:3.2 + ubuntu: same except digest SKIP (no gpg), ui 18 + python SKIP
- harness fix during run: t_ui helper checks now in a fresh bash (double-source of common.sh under 3.2 was a harness artifact)

## Compare with ckpt-r2-IMG.md (done after the harness)
- counts match: docker_image 331, network_detect 156, setup_release 109, remove 368, update_guard 73, helper 556, pytest 283 + 1268 subtests (3.10, 3.12)
- feature check, json tails, floor, packages, IMAGE_DIGEST messages: claims hold
- implementer open issue 9 = my WARN (UI docker-detect misses tn-dev); 7 (no Version compare) NOTE; 10 pre-existing
- checkpoint Docs notes inconsistency: README 1463 suggested wording given twice (S-round: legacy only; F1: legacy or tn-dev); first-round "TN_DEVNET_IMAGE_REPOS = GAR, old package" superseded by F1
- not in implementer ckpt: UI docker_image_choice mainnet digest-alone (pre-existing), finalize recognition rule, M09 timeout survivor
- fact check: v0.15/v0.16-adiri version.rs print "Build Features:"; docker-adiri builds with CARGO_FEATURES=adiri (not run: no real pull allowed)

## Mutants (t_mutants.sh, scratch V7-IMG/mut-all.log; M27 re-run in mut2 after the prompt-loop guard)
- 49 mutants, 0 not applied, M48 equivalent (an @ in the repo part never matches a pull repo exactly) -> 48 counted
- fixtures 43/48: survivors M09 (no timeout), M19 (interactive update passes no network), M21 (edit menu check removed), M30 (registry fallback adds the old package), M31 (registry fallback on mainnet)
- harness 47/48 (misses M47 substring repo_ok; docker_image_test catches it); either 48/48
- NOTE found by M27: _preflight_docker image prompt spins on stdin EOF when nothing is usable (pre-existing, 9fd615a same loop); scratch proto/eof.sh: 4705 "Not usable" lines in 4 s
- next: REPORT.md
