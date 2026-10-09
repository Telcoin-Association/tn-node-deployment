# Plan: clear the followup.md backlog across three repos

Approved 2026-10-01 (evening). The previous plan (support address, MNO partner guide) is
complete; its review is in `tasks/todo.md`. Specs for agents: `tasks/spec-fu-shared.md`,
`tasks/spec-fu-core.md`, `tasks/spec-fu-ops.md`, `tasks/spec-fu-ui.md`, `tasks/spec-fu-upstream.md`.

## Context

`followup.md` holds about 45 operator-facing improvements deferred from the public-RPC and
observer-flag work. All of them are to be addressed by orchestrated subagents:

- `tn-node-deployment` (this repo): commit directly on `main`.
- `telcoin-network` (`../tn-5`): one branch off `origin/main`, commits as work lands.
- `devnet-genesis` (`../devnet-genesis`): commit directly on `main`.
- No Claude co-author trailer anywhere.
- At the end: `.sha256` sidecars, docs and `docs/partner/mno-node-guide.pdf` all current.

Outcome: every backlog item is implemented and verified, or (where it cannot be done from these
repos) recorded in a rewritten `followup.md` with the reason.

## Decisions

Taken with the user:

- Multi-worker: read-side readiness only (firewall, check-node and the UI read the worker list
  from `node-info.yaml`; check-node errors when the on-chain worker count exceeds the node's).
  No provisioning of extra workers; the upstream gaps go into `followup.md`.
- Canonical endpoints: testnet RPC `https://rpc.adiri.tel`, mainnet RPC `https://rpc.telcoin.network`,
  explorers `https://telscan.io` and `https://www.telscan.xyz`. Upstream docs are already right on
  the testnet RPC; this repo changes (`TESTNET_RPC_URL`, explorer constants, the UI's public RPC
  list, check-node's default, every doc mention).

Taken by the orchestrator:

- Nothing is pushed. All commits stay local; the final report lists the push commands. An
  upstream PR needs `make attest`, which is left to the user.
- Orchestrator is the only committer in this repo. Subagents edit and self-test only. In `../tn-5`
  and `../devnet-genesis` the single docs agent commits its own topic commits.
- New script name: `prepare-stake.sh` (stake preparation plus `--rotate-address`).
- The UI helper's role token is dropped now; the helper tolerates the old call form, the installer
  writes sudoers last, one transitional commit keeps both sudoers line sets.
- `tn_resolve_node_type` loses every caller but stays one release as a deprecated stub.
- Rate limiting uses stock tools only: a 2 MB request-body cap in the Caddy block, no custom build,
  no per-IP limits.
- `MAINNET_CHAIN_ID` becomes 487.
- `followup.md` is rewritten at the end to list only what remains.

Intentional additions beyond the backlog: case-insensitive WebSocket matcher in install-caddy;
check-node authority id from `tn_info`; edit-config chain-config refresh refuses a chain-id
mismatch; `update-scripts.sh` loses `declare -g`, `migrate-node-naming.sh` loses `local -n`;
`meta_set` refuses newlines; `tn_acquire_update_lock` keeps a caller's EXIT trap; the UI
synthesises a `done` event; UI tests, a dev runner, and a bash-3.2 lint tool for CI.

Fact corrections found in wave 0 (recorded in `spec-fu-shared.md`): `set-rpc` and `generate pop`
exist from v0.12.0-adiri (not v0.13.0); the 0.13.0 floor is justified by `--enable-state-export`.
`../tn-5` local `main` is one commit behind `origin/main` (a node fix, not docs); the branch is
cut from `origin/main` as planned.

## Waves and packages

Pacing: at most four agents at once. Opus was available again at 19:45 CDT (probe agent), so wave 1
started then; UI-1 and UI-3a (no code dependencies) were pulled forward to fill the slots. After any
429: read the checkpoint files on disk, then resume the same agent with `SendMessage`, naming the
sections that already exist. Checkpoints: `tasks/ckpt-fu-<package>.md`.

### Wave 0 — setup (orchestrator)

- [x] `tasks/spec-fu-shared.md`, `spec-fu-core.md`, `spec-fu-ops.md`, `spec-fu-ui.md`, `spec-fu-upstream.md`
- [x] `tasks/plan.md` (this file)
- [x] lesson in `tasks/lessons.md` (rate-limit pacing, verified-facts preamble)
- [x] `project-context` refresh for the three repos (sonnet; all three done 2026-10-01 ~20:10 CDT;
      tn-5 one scoped to docs/CLI; found `set-rpc --worker-id` is unreleased and `--chain` values are
      `adiri|test-net|main-net`, both recorded in spec-fu-shared)
- [x] UI test venv: `<scratchpad>/ui-venv` (Flask 3.1.3)
- [x] baseline gates: `/bin/bash -n` + `bash -n` on every `*.sh` pass; `shellcheck -x --severity=error` clean; `gen-checksums.sh` leaves no sidecar drift; `../tn-5` tags fetched; Docker Desktop running

### Wave 1

- [x] L1 — `lib/common.sh` 1.5.0, `lib/fallback.sh` 1.0.3 → committed 1e2d2f1 (gate: parse both
      bashes, shellcheck, 427/427 harness under 3.2 and 5; V-L covers both passes after L2)
- [x] UP — `../tn-5` branch `docs/operator-docs-backlog` (13 commits, 501a1d25..025bd690: nine
      planned plus four follow-ups from V-UP's findings; V-UP re-check: no open findings, ready
      as a PR branch; the user runs `make attest` on the head SHA after pushing). (The ninth
      fixes `upgradeValidatorStakeVersion` → `requestStakeVersionChange` on the membership page), devnet-genesis
      `e732765` on `main`. Found: `rpc.telcoin.network` serves chain 2017 today (recorded in the
      shared spec for B, D and UI-2). V-UP (ran the v0.15.0 build): 3 errors — keytool needs a
      passphrase source even for export-staking-args, keytool stdout carries an INFO line that
      breaks `$(…)` capture (fix: `-q --bls-passphrase-source no-passphrase`), the 405 is Caddy's
      not the balancer's — plus 3 warns and notes; UP is adding three follow-up commits (A, B, C).
      Both keytool facts also feed L2 (`tn_keytool` adds `-q`; `no-passphrase` only for
      export-staking-args) and D.

### Wave 2 (needs L1)

- [x] L2 — `lib/common.sh` 1.6.0 → committed d1593ae (gate: parse, shellcheck, lint, 498/498 L2
      harness and 427/427 L1 harness under both bashes; real-binary runs). V-L running.
- [x] P3 — lint tool, remove-node 1.2.9, migrate 1.2.1, update-scripts (no version bump yet),
      install.sh → committed 78d9f46 (lint flagged exactly the 7 known constructs before, clean
      after, under macOS awk and mawk). Queued follow-up: migrate-node-naming's private `meta_set`
      override breaks on `#` values — drop it in favour of the library's.
- [x] P6 — `update-node.sh` 1.2.0 → committed e28e8e5 (gate: parse, shellcheck, lint clean,
      523/523 harness under both bashes). Follow-ups routed: edit-config takes the update lock
      (P5 spec), `REF_RE` refuses a leading `-` (UI-2b), docs note on the 30-minute wait.

### Wave 3 (needs L2)

- [x] P4a — `setup-node.sh` 1.3.0 part a → committed 9df76cb (gate: parse, shellcheck, lint,
      701/701 harness under both bashes). Lesson recorded: bash 3.2 `set -e` exits on
      `source missing || true`; `update-scripts.sh` line 20 has the same shape → P3 follow-up.
- [x] P4b — bootstrap peers, state export on `setup-node.sh` → committed 16123b8 (419/419 under
      both bashes; wrappers hand the map over as one argument).
- [ ] V-CORE-1 done (tasks/ckpt-fu-V-CORE-1.md): 1 error (peers map on the probe's command line;
      refuse non-world-readable sources), 3 warns, 5 notes; both scripts otherwise contract-correct.
      Fix passes: setup-node → committed 8c69378; edit-config (702/702) → committed 59d10a0.
- [x] L-FIX 3 — flock released even with orphaned children (747/747) → committed ea86e22.
- [x] V-OPS-1 done (tasks/ckpt-fu-V-OPS-1.md): no errors; 4 warns (JSON warnings via print_*,
      rpc-disable keeps the endpoint up during the wait, loose domain rule, no update lock), 8
      notes. Fix pass done → committed a051680 (176/176, 245/245 JSON, 60/60 live).
- [x] V-OPS-2 done (tasks/ckpt-fu-V-OPS-2*.md): 1 narrow error (check-node unknown-membership
      rule reads the .node-meta address), 8 warns (live `reputation_scores` key; prepare-stake
      signal handling and `--private-key` note; CRLF `.node-meta` in `meta_get`; firewall JSON on
      a failed `ufw allow`; obs_status under pipefail; observability parser), notes. Fix passes:
      all four fix passes done and committed: B 823e149 (614/614; also hardened the header
      parser's eval of RPC strings), L2 aa65fc3 (781/781), D 77e043b (266/226/22/123), C 1540751
      (178/229). P4b fix 2 (every prompt and flag reaching the wrapper validated) → committed
      babb69d (672/672). All code is final: 29 commits since 7fb7c8d.
- [x] Fix passes done: P6 → committed f9c47df (635/635); P3 → committed 3c78a6d (lint 86/86 both
      bashes and awks; updater fails closed; lone-copy run now exits 1 on purpose when a fixture
      lacks a sidecar). All code packages are committed except the V-OPS fix passes to come.
- [x] DOC-1 README done (+839/−67; 17 changelog entries incl. update-scripts 1.1.70; check script
      exits 0) and DOC-2 OPERATOR.md done (+466/−107; 65 flag pairs checked) — both held
      uncommitted until the A/B/C/D fix passes land, then a small follow-up (lock refusal wording,
      "branch prepared locally") and V-DOC, then one docs commit.
- [ ] DOC-3 partner guide + PDF (running), DOC-4 CHANGELOG/AGENTS/followup (running), DOC-2
      follow-up done (OPERATOR.md final), DOC-1 follow-up (running); then V-DOC → one docs commit → REL
      (update-scripts 1.1.70 + sidecars) → final gates → /code-review → todo + lessons.
- [x] P5 — `edit-config.sh` 1.3.0 → committed 9ff00af (gate: parse, shellcheck, lint, 527/527
      under both bashes). Decision: `allow_private_forward_targets=true` allowed on devnet only.
      Queued UI follow-up: helper/server `config-set` allowlist for the new fields.
- [x] A — `install-caddy.sh` 1.4.0 → committed 7acc653 (gate: parse, shellcheck, lint; 111 unit,
      121 JSON, 60 live Caddy checks on 2.8.4 and 2.11 under both bashes). V-OPS-1 pending.
- [x] L-FIX — all 11 V-L findings fixed (tokenizer refuses unquoted metacharacters, poll clamp,
      json escapes, export command text, …); 703/703 + 427/427 + V-L's 1175/1175 under both
      bashes and mawk → committed (lib/common 1.6.0, lib/fallback 1.0.3 unchanged numbers).
- [x] B — `check-node.sh` 1.2.0 → committed c7a9690 (493/493 + wss probe 7/7 under both bashes,
      live `cast` match, signal tests). V-OPS-2 pending (with C and D).
- [x] C — firewall-setup 1.6.0, setup-observability 1.2.1, lib/observability 1.0.2 → committed
      5eb98b4 (124/124 + 144/144 under both bashes; found and fixed a `set -e` crash in firewall
      status present since v1.1.1). V-OPS-2 pending.
- [x] D — `prepare-stake.sh` 1.0.0 + updater row + guarded source + install line → committed
      f918d4f (260/260 prepare, 215/215 rotation, 13/13 units, 25/25 live under both bashes; found
      and fixed a passphrase inherited by every child process). V-OPS-2 pending.
- [x] P3 follow-up — migrate's private `meta_set` removed → committed eb73857 (45/45 both bashes);
      the updater's guarded `source lib/fallback.sh` and D's row ride in D's commit.
- [x] V-CORE-2 done (tasks/ckpt-fu-V-CORE-2.md): updater integrity gaps (missing sidecar
      installs; self_bootstrap unchecked — both pre-existing), lint blind spot in one-line case
      arms, flock held by orphaned children after SIGTERM, interactive ref reaching git; migrate
      and remove-node clean. Fix passes running: P3 (updater, lint, install.sh, remove-node), P6
      (update-node), L2 (flock release). Release precondition: bump update-scripts in REL.
- [x] UI-1 — helper API 2, installer 1.4.0, `ui/tests/helper_test.sh` (169 checks both bashes) →
      committed 2025ea3 with the TRANSITIONAL sudoers block (28 lines) for UI-4 to remove
- [x] UI-3a — `ui/static/index.html` (shared helpers, one fetch-based stream reader for all
      streams, notice banner, System tab cards, CPU text), `ui/dev/serve.py` (scenarios
      public|private|unserved|legacy). Gate: `node --check` OK. Contract gaps it raised are fixed
      in spec-fu-ui (`role_checked_at` unix seconds, preflight CPU fields top level, `p2p_ports`
      objects, no `helper` on the public read-only path).
- [x] UI-3b — wizard Public card (hostname, advisory DNS check, review row, `rpc_domain` payload,
      400 handling), completion card from live rpc-status, validator epoch tile (countdown corrected
      with `now`, activation, earliest seat, seated). Dev runner scenarios `fresh`, `fresh-reject`.
      Gate: `node --check` OK. Committed with UI-2.

### Wave 4

- [x] UI-2a — server contract (no role token, `helper_status`, strict hostnames, `rpc_domain`,
      `move_dashboard_to`, `_parse_json_tail`, stream `done` synthesis, physical cores, constants);
      `ui/test_server_contract.py` 70 tests. Gate: compile + 70/70 in the venv.
- [x] UI-2b — chain side (`decode_validator_info` on the real struct layout, `onchain_role` with
      network → local → cached → default, `detect_nodes` remap, epoch fields, `REF_RE` tightened),
      `ui/test_server_chain.py`, dev-runner fixes. Gate: 121/121 tests, compile OK. Next: one
      V-UI agent (helper/installer/server tests + stubbed walk-through), then the UI commit.
- [x] UI follow-up — helper and server `config-set` accept the edit-config 1.3.0 fields with
      identical patterns (205 helper checks, 126 Python tests). Found: clap echoes the quoted
      peers-file content in its error, which edit-config relays — a local user could read a
      root-only file's first line through the UI → fixed in the library (`tn_node_parse_check`
      strips the value, keeps the reason), fix pass 2 running on the L2 agent.
- [x] L-FIX 2 — `tn_node_parse_check` sanitised (committed 8185d00; 741/741).
- [x] V-UI done (tasks/ckpt-fu-V-UI.md): helper 215/215, installer 60/60, server 128 own checks +
      126 unit tests, page walks in every scenario, no injected string executes. 1 error (firewall
      card reads `open`/`ok` not `allowed`), 2 wording warns, notes (helper failure caching,
      API ≥ required, `onclick` string interpolation, stdin-at-EOF install).
- [x] UI fix pass done (128 tests, 205 helper checks, walks clean) → UI committed 0c8aacf
- Rate limit at 00:05 CDT killed C's follow-up, D, V-CORE-1 and V-UI; all four resumed from their
  checkpoints at 00:25 after the reset.
- [x] UI-4 — TRANSITIONAL block removed, `UI_VERSION` 1.9.0 → committed 8feb576
- [ ] V-CORE-2 — update-node, remove-node, migrate, updater, lint

### Wave 5 — closing

- [ ] DOC-1 `README.md`; DOC-2 `OPERATOR.md`; DOC-3 partner guide + metadata + PDF; DOC-4 `CHANGELOG.md`, `AGENTS.md`, `followup.md` → V-DOC → commit
- [x] CI — `.github/workflows/ci.yml` → committed 0b54c64 (lint under /bin/bash on macOS and
      bash/mawk on Ubuntu, comment corrected, helper tests under 3.2, Python 3.10 UI test job)
- [ ] REL — `update-scripts.sh` version, sidecars → `chore(release): …`
- [x] Final gates part 1 (2026-10-02 ~03:10): parse under both bashes, shellcheck, lint under BSD
      awk and mawk, 128 Python tests, 205 helper checks, zero trailers in three repos, every changed
      tracked file bumped (update-scripts in REL), zero sidecar drift; every package harness re-run
      against HEAD under both bashes — all green (`<scratchpad>/final-sweep.txt`).
- [x] V-DOC done (tasks/ckpt-fu-V-DOC.md): 3 errors (config save interrupted during the wait
      stays on disk — a code fix in edit-config; the guide still warns on `all`; the SSH whitelist
      advice forgets the (v6) twin rule), 15 warns, 22 notes; facts, versions, anchors, messages
      and dry runs otherwise correct. Code fixes running: P5 (rollback on exit before restart),
      P3 (update-scripts --help), P4b (--address pre-root), P6 (existing-install message).
- [x] Code fixes from V-DOC: P3 → 13f6309, P6 → 12e58f4, P4b → 509bedb, P5 → 48a4c42, lib
      wording → 20ad47a.
- [x] Docs fix passes (DOC-1..4) done → docs commit d48270b (README, OPERATOR.md, CHANGELOG,
      AGENTS, followup.md with 83 items, partner guide 1.1 + PDF).
- [x] REL → e5e7f4f (update-scripts 1.1.70; all sidecars fresh; tree clean but tasks/lessons.md).
- [x] `/code-review high` done (second run; the first died on the previous account's weekly
      limit): 8 findings — foreground sleep in `tn_wait_restart_window` defers caller traps;
      prepare-stake holds the update lock at the passphrase prompt; the UI blocks its request
      thread on a slow public RPC; updater sidecar wording and `.tmp` cleanup; stale fallback
      comment; duplicated lock bookkeeping in edit-config; five duplicated wait printers.
- [x] Review fixes committed: P5 d752211, L2 dd898c3, D 23eb06c, P3 3682e5a, UI 504aad4; the
      printer refactor is a followup.md item; changelog clauses in 6622d1e. (A second session
      limit killed L2, D and the UI agent mid-run; the L2 and D work was complete on disk and
      gated by the orchestrator, the UI fix was restarted.)
- [x] Closing gates on the final HEAD (6622d1e, 42 commits since 7fb7c8d): parse both bashes,
      shellcheck, lint under both awks, 135 Python tests, 205 helper checks under both bashes, zero
      sidecar drift, zero trailers; `tasks/lessons.md` left modified and uncommitted per the
      never-commit-tasks rule. Final harness sweep 2 running.
- [x] Review section in `tasks/todo.md`; lessons added to `tasks/lessons.md`.
- [ ] Review section in `tasks/todo.md`, new lessons in `tasks/lessons.md`

## Verification

Orchestrator gate before every commit: `/bin/bash -n` and bash 5 `-n` on each changed script;
`shellcheck -x --severity=error`; `/bin/bash tools/check-bash32.sh <changed files>` once it
exists; `bash tools/gen-checksums.sh`, staging only that commit's files and sidecars; the commit
message has no trailer.

End to end, before the work is called done:

1. Shell hygiene over the whole tree with the four commands above.
2. Fixture harnesses under both bashes for every script package.
3. Real binary in docker (v0.15.0 image, temp data dir): `generate validator`, `set-rpc`,
   `export-staking-args`, `generate pop`, `node --help` probes, the bootstrap-peers parse check;
   a rendered wrapper passes `bash -n` and hands `--bootstrap-peers` to a recording shim as one argument.
4. Caddy: block passes `caddy validate` and `caddy fmt` on 2.11 and in `caddy:2.8-alpine`; a local
   run proves the 405 page, POST pass-through, case-insensitive WebSocket match, 413 on 3 MB.
5. Live, read-only, against `https://rpc.adiri.tel`: epoch helpers, stake status, `numWorkers()`,
   stake amount, each compared with `cast`.
6. UI: unittest in the venv; `ui/tests/helper_test.sh` under both bashes; `node --check`;
   walk-through with `ui/dev/serve.py`.
7. Docs: partner build lint passes and a second run prints "PDF unchanged"; `mdbook build docs`
   for the upstream branch; every flag named in the docs exists in the scripts.
8. Integrity: `gen-checksums.sh` leaves a clean tree; every changed tracked file has a bumped
   version; no commit in any repo carries a trailer; `git status` shows only untracked `tasks/`
   and `.claude/`.
9. Final independent review of `origin/main..HEAD` with fixes.

## Recorded, not fixed here (goes into the rewritten followup.md)

- Multi-worker provisioning (needs a release allowing more than one worker, a listener override,
  a keytool command that adds a worker).
- Fleet Caddy (`common/config-caddy.sh`): case-sensitive WebSocket matcher, 30 s backend timeout,
  dead CSS in the 405 page, wrong health-check comment. Balanced hostnames carry no WebSocket.
- Upstream branch awaits a PR; the v0.15.0 versioned docs page stays wrong.
- `tn-contracts` comment calling `epochDuration` "L2 blocks".
- Delete the deprecated `tn_resolve_node_type` stub after the next release.
- `.node-meta` owned by the service user on fresh installs while root-run scripts trust it.
- Per-IP rate limiting deliberately not automated.
- Closing the browser tab kills a running setup or update in the UI.
- devnet-genesis still calls the deprecated `setup-observer.sh` / `setup-validator.sh` shims.
