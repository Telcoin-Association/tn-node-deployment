# Progress: roll v0.16.0-adiri (started 2026-10-09)

Spec: `tasks/spec-v016.md`. Designs: `tasks/design-v016-A.md`, `tasks/design-v016-C.md`.
The approved plan is in the session transcript; this file tracks execution only.

## Wave 0 (orchestrator)
- [x] spec written (`tasks/spec-v016.md`, copied to adiri-genesis/tasks)
- [x] telcoin-network detached at d72cc2bc, submodule 10cc12b7, patches present
- [x] `gcloud auth configure-docker us-docker.pkg.dev`; gcloud project set to telcoin-network
- [x] image build started in background (amd64 only, `--push`), log in the scratchpad
- [x] adiri-genesis `common` submodule at dee644f (staged), branch `v0.16.0-adiri`
- [x] tn-node-deployment branch `v0.16.0-adiri`
- [x] overlay verified: tn_ssh OK to validator-1..10-adiri from xerxes (2026-10-09 14:58)
- [x] memory saved: xerxes-maintainer-box

## Wave 1 (opus agents)
- [x] IMPL-A done; V-A: ship after LOW fixes F1-F4 (applied + refined F3), harnesses 174/174 and 334/342 green on bash 5 and 3.2; committed
- [x] IMPL-C1 done (helpers verified live read-only)
- [ ] IMPL-C2 (driver + restore helper + matrix) — running

## Wave 2
- [x] V-A verifier (verdict: ship after fixes; applied)
- [ ] V-C reviewer
- [x] DOC-A done (PDF rebuilt in container, 46 pages, metadata 1.2)

## Wave 3 (orchestrator)
- [x] WP-B.4 image verified 2026-10-09T20:0xZ: index sha256:b905b098…, amd64 sha256:85024097…, --version d72cc2bc, --observer rc 2, --help OK
- [x] WP-B.5 tag v0.16.0-adiri pushed on d72cc2bc (over SSH)
- [ ] config.sh digest pinned
- [ ] gen-checksums, commits, push both branches
- [ ] tn-node-deployment PR opened — STOP for operator review
- [ ] merged on approval; run record started

## Wave 4 (live)
- [ ] WP-D.0 host checks (done early: overlay OK)
- [ ] WP-D.1 REARM (tag sha, forks.rs, digest)
- [ ] WP-D.2 `--check` 10/10 READY
- [x] WP-D.3 prewarm snapshots started 20:03Z (warm-…-20261009-2003 ×5); a second prewarm right before the roll if >12 h old
- [ ] WP-D.4 prepare pass (rc 1 at CONFIRM), second `--check`
- [ ] WP-D.5 hand-off: human runs the driver and types CONFIRM

## Wave 5
- [ ] WP-E watch through the first epoch close on v0.16
- [ ] run record; lessons in both repos
