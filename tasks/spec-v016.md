# Shared spec: roll v0.16.0-adiri to the adiri testnet (nodes 1-10)

Written 2026-10-09 by the orchestrator. Every agent working on this release reads this file
first, then its own design document, then its own checkpoint. Facts here were verified on
2026-10-09 the way the "how" column says; do not re-derive them, do correct them if source
contradicts them (and say so in your checkpoint).

Design documents (verbatim output of the two Plan agents, line anchors as noted):
- `tasks/design-v016-A.md`  update-node.sh migration guard, tn-node-deployment at HEAD df82deb
- `tasks/design-v016-C.md`  adiri-genesis driver changes, adiri-genesis at 6f3c204

Branches: `v0.16.0-adiri` in tn-node-deployment (from df82deb) and in adiri-genesis (from
6f3c204, with the `common` submodule bumped to dee644f). The orchestrator is the only committer
in each repo. Agents edit files and write checkpoints; they never commit, push, tag or run
anything against a live node or GCP.

## 1. Why this release is different (read before touching anything)

1. v0.16.0-adiri arms NO new adiri fork. The only startup-visible difference from v0.15 is the
   new token `subsecond_timestamp_fork_epoch=4294967295` in the `fork schedule (adiri)` line.
   `telcoin --version` prints 0.1.0 on both; only `Commit SHA:` differs.
2. v0.16's FIRST start migrates consensus storage ONE-WAY (epoch pack v1 -> v2, log line
   `migrated legacy pack to v2 on open`, one per epoch opened; past epochs migrate lazily with a
   `pre-v2 (legacy) epoch pack; migrating` WARN each). v0.15 cannot reopen a migrated datadir
   (it fails with `invalid version`). Rollback therefore means restoring a datadir snapshot or
   copy taken while the node was STOPPED, never just swapping the binary back.
3. v0.16 rejects `--observer` at argument parse time (exit 2, `unexpected argument '--observer'`),
   takes an flock on `<datadir>/telcoin.pid` (`another telcoin process (pid N) holds the lock`),
   refuses wildcard / port-0 advertised addresses in `node-info.yaml`, and serves a new
   `/health/network` endpoint.

## 2. Verified facts

| Fact | Value | How verified |
|---|---|---|
| release commit | `d72cc2bcfceb2e61b968915d72dc7e3761dd7e0b` (2026-10-08, "fix(state-sync): re-queue given-up epoch packs ... (#1577)") | `git rev-parse 6a9310b8^` in telcoin-network; equals `origin/main^` |
| excluded | #1622 (6a9310b8, "Staging/mavenrain 2026-10-08") deliberately NOT shipped | operator decision |
| tn-contracts submodule at d72cc2bc | `10cc12b7db43e2fbab67dc6a87fa5e159716bdc0`, same as v0.15 | `git submodule status` after checkout |
| patches present at d72cc2bc | `patches/libp2p-quic`, `patches/libp2p-connection-limits` | `ls patches/` |
| telcoin-network local checkout | DETACHED at d72cc2bc since 2026-10-09 (was `main` at c3947d2c). Never create a local branch named `v0.16.0-adiri` there: it would shadow the tag on operator nodes that `git fetch` + checkout by name | done by the orchestrator |
| fork line at d72cc2bc (node.rs:159-170, target `cli`) | `consensus_registry_fork_epoch=407 seed_signature_fork_epoch=383 multi_workers_fork_epoch=570 prevrandao_fork_epoch=574 leader_seeded_ordering_fork_epoch=567 subsecond_timestamp_fork_epoch=4294967295 governance_safe_fork_epoch=554` (7 tokens) | read in the planning session |
| v0.15.0-adiri pins (become ROLLBACK_*) | sha `5736cc30012c5ff25913898e318a74df308f13d9`; index digest `sha256:3b0a0ec2239f59418ed73e0984056119228acd5f82b2942881ccec8a0fec247d`; amd64 child `sha256:594600630fa2a63e74a539190dbcf2cdf2427ee59481b599294db30cbeecec95`; fork line = the 6-token line (no subsecond token) | adiri-genesis config.sh:205-253 and the v0.15 run record |
| v0.16 image | `us-docker.pkg.dev/telcoin-network/tn-public/adiri:v0.16.0-adiri`, linux/amd64 ONLY, pushed 2026-10-09T20:00:30Z from xerxes. Index digest (the tag, what `docker inspect .Id` reports on the containerd store): `sha256:b905b0982e87d5ca608e2f29192d0c5582793ae0043630074cddb9be1162ffea`; amd64 child manifest: `sha256:850240972ba8a78c906515cc90eb292e5eaa76b6d950abc6a33ea34120e6af89`; attestation manifest `sha256:9978bc3d…` (ignore). `telcoin --version` in it prints `Commit SHA: d72cc2bc…`, `Build Features: adiri`; `telcoin node --observer` exits 2; `node --help` parses | `gcloud artifacts docker images describe`, anonymous v2 manifest HEAD, docker run (verify-image-v016.sh) |
| git tag | `v0.16.0-adiri` pushed 2026-10-09 (tag object e8e51e37, peeled d72cc2bc, message "node record exchange and mmap pack storage; subsecond fork dormant"). Pushed over SSH: the gh https token has no push right on telcoin-network | `git ls-remote --tags origin` |
| tn-node-deployment versions at df82deb | update-node.sh `SCRIPT_VERSION="1.2.0"` (:56); lib/common.sh `COMMON_VERSION="1.6.0"` (:43); ui/server.py `UI_VERSION = "1.9.0"` (:72); update-scripts.sh `SCRIPT_VERSION="1.1.71"` (:27) | grep |
| image pins in tn-node-deployment | `lib/common.sh:458` `readonly DEFAULT_DOCKER_IMAGE="${GAR_IMAGE_BASE}:v0.15.0-adiri"`; `ui/server.py:2341`; `ui/static/index.html:2187,3222,3243` (placeholders). Comments mentioning v0.15 in lib/common.sh at :700,:2263,:4132,:4425,:4637,:4695-4696 | grep |
| update-node.sh apply paths | `apply_docker_update` :545, `apply_source_update` :887, `json_apply_source` :1585, `json_apply_docker` :1678; `verify_health_after_restart` :330-353; `observer_strip_needed` ends :326; `update_wait_say` :426; `json_check` object emitted ~:1401; `json_prepare_source` done ~:1514, `json_prepare_docker` ~:1553; rollback blocks at :650, :1018, :1655, :1748 | design-A, anchors at df82deb |
| running-version marker | `/opt/telcoin/telcoin-network.version`, written only by setup-node.sh (:536) and by verified applies (update-node.sh :1008, :1650) per lib/common.sh:1291-1307. `OLD_REF` is `git describe` at PREPARE time and lies after prepare -> discard -> prepare | design-A |
| `version_gte` | lib/common.sh:1089 | grep |
| adiri-genesis anchors | config.sh: DOCKER_IMAGE :46, EXPECTED_SHA :205, EXPECTED_IMAGE_DIGEST :215, EXPECTED_FORK_EPOCH :222, EXPECTED_REGISTRY_FORK_EPOCH :230, EXPECTED_FORK_FIELDS :237, ROLLBACK_* :250-253, FORK_CLOSE_EPOCH :266 (hard-set, env override does nothing), ROLLBACK_MIN_MARGIN_SECS :278, LEGACY_FLAG_DENY_RE :305. adiri-update-all.sh: APPLY_VERIFY_TIMEOUT=300 :137, FORK_CLOSE_EPOCH default :153. adiri-lib.sh: `tn_epoch_deadline` :1115-1193, phase-0 marker grep :303/:319, `tn_cmd_disk_free` :378, `tn_cmd_ext_rollback_sources` :885, `tn_cmd_ext_binary_snapshot` :856-875. restart-staggered.sh: window gate :395-416, `tn_epoch_deadline` call :401 | design-C, anchors at 6f3c204 |
| adiri-genesis submodule | `common` now at dee644f (deploy-networks-common main, has maintainer xerxes); staged on branch `v0.16.0-adiri`, not yet committed | done by the orchestrator |
| GCP | project `telcoin-network`; validator-1..5 boot disks 350 GB pd-ssd; READY snapshots `validator-N-adiri-presize-20260618` exist. Snapshot names: lowercase, digits, hyphens only, no dots, max 63 chars | planning session |
| validator-8 | its datadir is a mountpoint (`/mnt/data`); root fs has ~13 GB free. Follower copy = resync-only | design-C finding 6 |
| overlay | this box = maintainer `xerxes` 10.100.9.7 on `tn-wg0`; hub 10.100.0.1; validator-1..5 = 10.100.1.1-5; validator-6..10 = 10.100.20.6-10; key `~/.config/tnvpn/id_ed25519` | planning session |
| build host | docker 29.8.0, default builder amd64 only, credHelper for us-docker.pkg.dev now configured; bash 5.3; python 3.14; NO shellcheck (use `docker run --rm -v "$PWD":/mnt koalaman/shellcheck:stable`), NO pandoc/weasyprint, NO bash 3.2 (use `docker run --rm -v "$PWD":/mnt bash:3.2 bash -n /mnt/<file>` for a true 3.2 parse plus `/bin/bash tools/check-bash32.sh <file>`) | checked |
| Bash tool shell | the orchestrator's Bash tool runs under zsh: `echo =====` fails, `$var` with several names does not word-split (tasks/lessons.md) | lessons |

## 3. Interface contract between the two repos (binding)

update-node.sh 1.2.1 (tn-node-deployment) <-> adiri-update-all.sh (adiri-genesis):

1. `update-node.sh --json --check` emits one bare status object (no `event` key) that gains
   `"storage_migration":true|false` (true when the running release is < 0.16.0 or unknown AND
   the latest/target is >= 0.16.0 or versionless).
2. A one-way apply that fails its health window emits an `error` event and then EXACTLY ONE
   `done` event: `{"event":"done","ok":false,"phase":"apply","rolled_back":false,"storage_migration":true,"msg":"..."}`.
   The node is left RUNNING on the new binary, pending state cleared, version marker NOT
   rewritten. No binary rollback is performed or offered.
   The field is `storage_migration` (NOT `rollback_refused`; design-C §3 used the older name,
   the plan's contract wins). The driver treats such a `done` as "applied; judge in phase 3".
3. A non-migrating apply (running >= 0.16.0) keeps today's behaviour: 45 s window, auto
   rollback, `done` with `rolled_back:true` and NO `storage_migration` field.
4. `TN_UPDATE_VERIFY_TIMEOUT`: numeric = explicit and always wins; non-numeric or unset =
   600 s when migrating, 45 s otherwise. The driver passes `APPLY_VERIFY_TIMEOUT=900` through
   this variable.
5. JSON prepare (`json_prepare_source` / `json_prepare_docker`) emits a `warn` event with the
   one-way text when the prepared target is migrating, so UI users see it before Apply.
6. Phase-0 marker on a follower: `/opt/telcoin/update-node.sh` has
   `readonly SCRIPT_VERSION="X"` with X >= `${TN_MIN_UPDATE_NODE_VERSION:-1.2.1}` AND contains
   `TN_UPDATE_VERIFY_TIMEOUT`. `tn_cmd_refresh_marker` echoes `SCRIPT_VERSION=`.
7. update-node.sh 1.2.1 must be on tn-node-deployment `main` before the fleet's phase 0 runs
   (followers pull `main`; wait ~5 min for the raw CDN after the merge).

## 4. Work packages and owners

- IMPL-A (opus): WP-A.1-5 + .7 in tn-node-deployment. Files it may edit: `update-node.sh`,
  `lib/common.sh`, `ui/server.py`, `ui/static/index.html`, `update-scripts.sh`. Test harness
  in `ui/tests/` or the scratchpad as the design says. May run `tools/gen-checksums.sh` and
  `tools/check-bash32.sh`. Checkpoint `tasks/ckpt-v016-A.md`.
- IMPL-C1 (opus): WP-C.1-2 in adiri-genesis: `config.sh`, `adiri-lib.sh`. Checkpoint
  `adiri-genesis/tasks/ckpt-v016-C1.md`.
- IMPL-C2 (opus, after C1): WP-C.3-5: `adiri-update-all.sh`, new
  `restore-datadir-from-snapshot.sh`, new `tasks/dry-run-matrix.sh`; may touch
  `restart-staggered.sh` only where `none` mode needs it. Checkpoint
  `adiri-genesis/tasks/ckpt-v016-C2.md`.
- V-A (opus): independent verifier of WP-A from this spec + design-A. Writes its own harness
  BEFORE reading `ckpt-v016-A.md`. Checkpoint `tasks/ckpt-v016-VA.md`.
- V-C (opus): reviewer of WP-C. Checkpoint `adiri-genesis/tasks/ckpt-v016-VC.md`.
- DOC-A (opus, after A is committed): WP-A.6 docs. Checkpoint `tasks/ckpt-v016-DOC.md`.
- Orchestrator: spec, WP-B (build, verify, tag), pins, checksums, commits, PR, fleet roll,
  watch, run record.

## 5. Checkpoint rules (every agent)

- Your prompt names your checkpoint file. On start, READ IT FIRST and continue from the first
  unfinished section; do not redo finished ones.
- First line of the checkpoint: `status: in-progress|blocked|done`. Then a `## Sections` list
  with `- [ ]` / `- [x]` items, one per section of your work, each with a one-line summary of
  what landed (function names, anchors). Rewrite the file after EACH section, not once at the
  end.
- If Write/Edit is refused, do not work around it: return the complete text in your final
  answer and the orchestrator saves it.
- Return a SUMMARY (what changed, what was verified and how, what is left), never file dumps.
- Stay inside the paths your prompt lists. If you need something outside, say so in the
  checkpoint and hand back.
- Never commit, push, tag, run gcloud mutations, SSH to a node, or start/stop a node.
  `--dry-run` and `--check` of the driver are allowed ONLY with a scratch `CONFIG_FILE` and
  `TN_DRY_RUN=1`; read-only `--check` against the live fleet is the orchestrator's job.

## 6. Gates

tn-node-deployment (every touched `*.sh`):
- `bash -n <file>`; `/bin/bash tools/check-bash32.sh <file>`;
  `docker run --rm -v "$PWD":/mnt bash:3.2 bash -n /mnt/<file>`;
  `docker run --rm -v "$PWD":/mnt koalaman/shellcheck:stable -x /mnt/<file>` (errors fail;
  warnings advisory, but do not add new ones).
- `python3 -m unittest discover -s ui -p 'test_*.py' -v`; `bash ui/tests/helper_test.sh`.
- Bash 3.2 rules: indexed arrays only, no `declare -A`, `${v,,}`, `mapfile`, `&>>`, `|&`,
  `[[ -v`, negative subscripts; no apostrophes inside `${v:-default}`; no `local a; a="$(x)" b`;
  guard `source` with `[ -r f ] &&`.
- Version bumps + `bash tools/gen-checksums.sh`; `git status -- '*.sha256'` lists only the
  sidecars of the touched tracked files. Sidecars are regenerated by the orchestrator at commit
  time too, so do not fight over them.

adiri-genesis (every touched `*.sh`):
- `bash -n`; shellcheck via docker (`-x`, from the repo root so `source` resolves);
  bash 3.2 parse via the `bash:3.2` container (the Mac is the real 3.2 authority).
- `tasks/dry-run-matrix.sh` green under bash 5 with the documented exit codes.
- Invariants V-C checks: no mutating command before CONFIRM; every `--check` path read-only;
  2s failure resumes v0.15 on all five and restarts followers stopped in 2a; R0 refuses without
  five READY snapshots; `--rollback` without `--from-run` refuses; validator-8 is resync-only.
