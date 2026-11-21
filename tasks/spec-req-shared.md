# Shared spec: requirements round (2026-11-21)

Read by every agent of the round. `tasks/plan.md` has the waves and the commit list. `AGENTS.md`
is authoritative for repository rules (tests, lints, bash 3.2, release plumbing, partner PDFs).
`.claude/project-context.md` is the map.

Base: branch `requirements-from-benchmarks` off `origin/main` at `01664cc`. Line numbers below
are that tree's.

## 0. Rules for every agent

- Work only in your own worktree (the absolute path in your brief). Never touch the main
  checkout at `/home/drtnarg/coding/telcoin/tn-node-deployment` or another agent's worktree.
- Edit only the files and ranges your brief lists as yours. If the work needs a line outside
  them, stop and say so in the hand-back; do not edit it.
- **Do not bump version constants** (`COMMON_VERSION`, `SCRIPT_VERSION`, `UI_VERSION`) and **do
  not run `tools/gen-checksums.sh`**; do not edit `*.sha256`, `MANIFEST`, `RELEASE`. The
  orchestrator does both at integration. (`tools/tests` has a sidecar test: if it fails only
  because a sidecar is stale, say so; do not refresh it.)
- Commit in your worktree when a section is done (the orchestrator cherry-picks). Commit
  messages go through a file: `git commit -F <file>`, never a heredoc chained with `&&`. Check
  `git log --format=%s -3` afterwards.
- **No Claude attribution anywhere**: no `Co-Authored-By` trailer, no "Generated with" line.
- Checkpoint: `tasks/ckpt-req-<id>.md` in your worktree, with a `status:` header
  (`in-progress` / `done` / `blocked`) and a list of sections, rewritten after EACH section.
  On start, read your own checkpoint and continue from the first unfinished section. Do not
  commit the checkpoint with your code commit (leave it untracked or commit it separately).
- If a Write is refused, do not work around it: return the complete text in your final answer.
- Budget: stay well under 250k tokens. If you trend past it, checkpoint, commit what is green,
  and hand back what remains.
- Hand back a summary (what changed, files, test counts with the tree each count was measured
  on, open questions), not file dumps.
- bash 3.2 safe: indexed arrays only, no `declare -A`, no `${var,,}`, no `mapfile`, no `&>>`.
  No apostrophes inside `${var:-default}`. `local a; a="$(cmd)"` on separate statements.
- BSD-safe in fixtures and in library lines a fixture exercises: no new `stat -c` without the
  shim in `tools/tests/lib.sh`, no multi-line `awk -v`, no `sed -i`, `date -d`, `readlink -f`.
  A test helper that feeds `grep -q` uses a here-string or a file, never a pipe (pipefail).
- Docker commands use the worktree's absolute path (`-v /home/drtnarg/coding/telcoin/tnd-req-<id>:/w`),
  never `$PWD`. Never `rm -rf` a variable path; give each run a directory name that does not
  exist yet.
- Comments and messages in tracked files must pass `bash tools/check-network-hits.sh` (a line
  that names a testnet host, "adiri", a network constant and so on needs the
  `# network-gated: <why>` annotation the lint describes; read its header before adding such a
  line).
- Ubuntu 26.04 stays the recommended OS: never delete or reword a line that names 26.04.

### Gate commands (run the ones your brief names; `<W>` is your worktree's absolute path)

```
bash tools/tests/run.sh                                   # host, bash 5
bash tools/tests/run.sh tools/tests/<file>_test.sh        # one file
docker run --rm -v <W>:/w -w /w ubuntu:26.04 bash tools/tests/run.sh [files]   # root, recommended OS
docker run --rm -v <W>:/w -w /w bash:3.2 bash tools/tests/run.sh [files]       # bash 3.2, busybox
git ls-files -z '*.sh' | xargs -0 bash tools/check-bash32.sh
shellcheck -x --severity=error <files>      # must be clean; --severity=warning: add none
bash tools/check-network-hits.sh
bash tools/check-perl-interp.sh
# UI:
docker run --rm -v <W>:/w -w /w python:3.10-slim sh -c \
  'pip install -q -r ui/requirements.txt -r ui/tests/requirements-dev.txt && python -m pytest -q ui'
# PDFs:
docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v <W>:/w -w /w tn-pdf-tools \
  bash tools/build-partner-pdf.sh <doc-name>
```

A single failing fixture under load is rerun alone before anything is changed (several agents
run suites at once). Baseline on `main`: 81 test files, 0 failed (host and `ubuntu:26.04`);
shellcheck 0 errors / 307 warnings over 211 files; network-hits clean (153 annotated hits).

## 1. Verified facts

| Fact | How it was checked |
|---|---|
| All five Adiri validators are `c3-highcpu-8` (8 vCPU, 16 GB, Intel Sapphire Rapids), each with one 350 GB `pd-ssd` | `gcloud compute instances/disks list` and `describe`, 2026-11-21 |
| A `pd-ssd` on a C3 VM with 8 vCPUs is capped at 15,000 read and write IOPS and 240 MiB/s. By size a 350 GiB disk would allow 16,500 IOPS (30 per GiB + 6,000), so the machine cap governs | Google Cloud "disks/performance" page, table "C3 Instances / pd-ssd", row `8 \| 15,000 \| 15,000 \| 240 \| 240`, read 2026-11-21 |
| `c3-highcpu-8`: 8 vCPU, 16 GB; "Each CPU uses two threads per core. A vCPU is implemented as a single hardware thread." (so 4 cores; the page does not print the core count) | Google Cloud "general-purpose-machines" page, read 2026-11-21 |
| Runs `r20261115-1653` / `-1131`: 10 validators on `c3-highcpu-8` with 20,000 IOPS / 800 MiB/s volumes, about 9,300 tx/s, write IOPS p95 about 20,000, about 286 MiB/s written, 16 GB with headroom | `tn-benchmarks/runs/*/run.json` and reports |
| Execution is strictly sequential: engine busy about 978 ms/s at about 56 % of 8 vCPUs | same runs |
| No run tested 10,000 IOPS, 6 vCPU or local NVMe; the benchmark site states no hardware recommendation | same runs |
| `c7i.2xlarge` EBS: baseline 12,000 IOPS and 312.5 MB/s, maximum 40,000 IOPS and 1,250 MB/s. Footnote: "These instances can support maximum performance for 30 minutes at least once every 24 hours, after which they revert to their baseline performance." | AWS "compute optimized" instance-types page, read 2026-11-21 |
| gp3: up to 500 IOPS per GiB, 0.25 MiB/s per provisioned IOPS; 3,000 IOPS and 125 MiB/s baseline; 80,000 IOPS and 2,000 MiB/s maximum per volume | AWS EBS "general-purpose" page, read 2026-11-21 |
| The three chain-config files at `v0.15.0-adiri`, `v0.16.0-adiri`, `v0.17.0-adiri` match the pins; `main`'s `committee.yaml` does not (`bc571cb8c`, 2026-11-14) | `git show <tag>:… \| sha256sum` in the local `telcoin-network` checkout |
| The UI runs `--phase=keygen` and `--phase=finalize` as separate processes (`setup-node.sh:3720-3723`) | reading the code |
| `check_hardware` is called only at `setup-node.sh:419`; `HW_*` constants are read only by it; nothing parses `TN_HW_GAPS` | whole-repo grep |
| Mainnet chain id upstream is **731** (`0x2db`): `crates/types/src/genesis.rs` `MAINNET_CHAIN_ID: u64 = 731`, `chain-configs/mainnet/genesis.yaml` `chainId: 731`, since `90ed40b39` (#1716, 2026-11-12). No release tag contains it: at `v0.16.0-adiri` and `v0.17.0-adiri` the placeholder mainnet genesis still says 487 | `git grep` on `origin/main` and the tags in the local `telcoin-network` checkout, 2026-11-21 |
| Upstream: "Devnet genesis files (`etc/genesis.sh`) use 487, so the chain id alone identifies mainnet." So 487 (`0x1e7`) is now a devnet chain id | `crates/types/src/genesis.rs:118` on `origin/main` |
| This repository says 487 for mainnet in: `lib/common.sh:26` (constant; comment `:24-25`, `:3183`), comments at `check-node.sh:2880`, `update-node.sh:323`, `:1204`, `ui/server.py:1408`, `:1422-1424`, nine test files, `OPERATOR.md`, `README.md`, the guide, the mainnet one-pager, `followup.md`. `DEVNET_CHAIN_ID` here is 32285 | `git grep -n -I -i -w -E '487\|0x1e7\|1e7'` at `01664cc` |

## 2. Design A: chain configs at the pinned tag (the bug fix)

Root cause: `ensure_chain_configs_available` (`lib/common.sh:3266-3321`) clones the default
branch (`:3301`) and, on an existing checkout, runs `pull --ff-only` (`:3283`).
`TESTNET_CHAIN_CONFIGS_TAG` (`:7149`) exists but nothing reads it.

Fix: read the three files from the pinned tag into a fixed root-owned directory, without moving
any checkout.

### 2.1 Library (`lib/common.sh`) — FIX-A1

New constant next to the pins (`:7149-7155`): `readonly MAINNET_CHAIN_CONFIGS_TAG=""` (empty
until the genesis ceremony; update the comment block above the pins).

New helpers, inserted after `tn_chain_configs_check` (ends `:7211`):

- `tn_chain_configs_tag NET` — prints the tag: testnet → `$TESTNET_CHAIN_CONFIGS_TAG`,
  mainnet → `$MAINNET_CHAIN_CONFIGS_TAG`; prints nothing for devnet or anything else. rc 0.
- `tn_chain_configs_dir NET` — prints `${TN_ROOT_PREFIX:-}${CONFIG_DIR:-$DEFAULT_CONFIG_DIR}/chain-configs/NET`.
  rc 0.
- `tn_chain_configs_from_tag DIR NET [progress-fn]` — DIR is the telcoin-network checkout.
  Messages go through `_tn_guard_say KIND MSG progress-fn` (KIND step, log or warn). In order:
  1. NET has no tag (`tn_chain_configs_tag` prints nothing): warn
     `"${net} has no pinned chain-config tag; nothing was read."`, rc 1. No git runs.
  2. The destination `tn_chain_configs_dir NET` already passes `tn_chain_configs_check`
     (checked quietly): log `"The pinned ${net} chain configs are already in ${dest}."`, rc 0.
     **No git runs**, DIR need not exist.
  3. DIR is not a git checkout (`${DIR}/.git` missing): warn
     `"${dir} is not a git checkout; the ${net} chain configs at ${tag} cannot be read from it."`,
     rc 2.
  4. DIR is a symlink or not owned by the account running this (same test as
     `tn_source_checkout_tag`, `:8789`): warn
     `"${dir} must be a directory owned by <user> (not a symlink); nothing was fetched."`, rc 1.
  5. step `"Fetching ${tag} from origin for the chain configs..."`; fetch exactly as
     `tn_source_checkout_tag` does (`:8794-8796`):
     `GIT_ALLOW_PROTOCOL=https git -C DIR fetch --quiet --no-tags origin "+refs/tags/TAG:refs/tn-remote-tags/TAG" 9>&-`.
     - Fetch succeeded: read from `refs/tn-remote-tags/TAG`. A local `refs/tags/TAG` is neither
       read nor moved.
     - Fetch failed: use the local copy, `refs/tn-remote-tags/TAG` from an earlier fetch if it
       exists, else `refs/tags/TAG`, with warn
       `"Could not reach origin; reading the ${net} chain configs from the local copy of ${tag}."`.
       Neither exists: warn
       `"Could not fetch tag ${tag} from origin, and the checkout does not have it."`, rc 2.
  6. Read the three blobs with `git -C DIR cat-file blob "<ref>:chain-configs/NET/<file>"`
     into a private staging directory (`mktemp -d`, removed on every path). A missing blob: warn
     `"${tag} has no chain-configs/${net}/${f}."`, rc 2.
  7. `tn_chain_configs_check STAGING NET progress-fn`. Mismatch: warn
     `"The ${net} chain configs at ${tag} do not match the pins; nothing was installed."`, rc 1,
     the destination is untouched.
  8. Install: `_tn_root_layout_dir` for `<config>/chain-configs` and `<config>/chain-configs/NET`
     (root:root 0755), each file with `tn_write_root_file DEST 0644` fed from the staged file
     (stdin from a file, not a pipe). Then check the destination again with
     `tn_chain_configs_check`. log `"Installed the ${net} chain configs from ${tag} into ${dest}."`,
     rc 0. A failed write: rc 2.
  HEAD, the index, the working tree and submodules of DIR are never touched: no checkout, no
  pull, no reset, no submodule command. `git status --porcelain` and `git rev-parse HEAD` in
  DIR are the same before and after.
  rc: 0 in place, 1 refused, 2 failed.

`ensure_chain_configs_available [NETWORK] [progress-fn]` (rewritten; a small
`_tn_chain_configs_clone` goes just above it):

- Unknown network: as today (error, rc 1).
- `TN_GENESIS_DIR` set (`--genesis-dir`): used as given. `tn_chain_configs_check` on it, the
  messages of today (`:3315-3319`), rc 0 or 1. No git, no prompt.
- devnet: unchanged from today (pull `--ff-only` on an existing checkout, the clone prompt
  when there is none, then the check, which only warns on devnet).
- A network whose tag is empty (mainnet today): no git at all; print
  `"Repository present; mainnet chain configs are used as published (no pull)."` when the
  checkout exists, then the check on `${source_dir}/chain-configs/${net}`, which refuses while
  the pins are empty (today's behaviour and rc).
- testnet (and mainnet once it has a tag):
  1. `tn_chain_configs_from_tag` step 2 applies first: the pinned directory already holds the
     files → rc 0 with no prompt and no git.
  2. Checkout present → `tn_chain_configs_from_tag "$source_dir" "$net" "$fn"`; return its rc.
  3. No checkout → the consent prompt of today (`:3292-3299`, same `confirm` question). Declined:
     the "Skipped…" warning of today, rc 0. Accepted: `_tn_chain_configs_clone` clones over
     https at the tag, without submodules:
     `GIT_ALLOW_PROTOCOL=https git clone --quiet --branch TAG -- "$TN_REPO" "$source_dir" 9>&-`.
     A failed clone prints `"Clone failed. Check your internet connection."` and the manual
     command, and **returns 2** (no `exit 1`). Then step 2.
  No `pull`, no `tn_sync_submodules` on testnet or mainnet.
- rc: 0 ready (or skipped by the operator), 1 refused, 2 failed.

Keep `print_ok "Chain configs in ${dir} match the ${net} pins"` on success, with `dir` the
directory that will be used (the pinned directory on testnet).

Tests (FIX-A1): rewrite the `ensure` cases of `tools/tests/genesis_hash_test.sh` (`:69-84`).
The assertion `ensure: testnet pulls --ff-only` (`:75`) becomes "the checkout is not moved": no
`pull`, `checkout`, `reset`, `merge`, `submodule` in the recorded git argv. The `git` stub
there records argv and exits 0, so the blob read needs a stub that can serve the fixture files
for `cat-file blob <ref>:chain-configs/testnet/<file>`, or the pinned directory pre-filled;
your choice, but keep one case that goes through the fetch-and-read path. Lines `:86-117`
(`step_write_config`) belong to FIX-A2: do not edit them, but they must stay green.

### 2.2 `setup-node.sh` — FIX-A2

- `step_write_config` (`:2334-2380`): the search list becomes `TN_GENESIS_DIR`, then
  `"$(tn_chain_configs_dir "$NETWORK")"`, then the three existing entries.
- The hint (`:2371`) names the tag: `…/telcoin-network/tree/<tag>/chain-configs/<net>/` with
  `<tag>` from `tn_chain_configs_tag`; `main` only when the network has no tag.
- The call at `:2141` passes `setup_progress` and words the failure by rc: rc 1 keeps
  `"The ${NETWORK} chain configs are not the pinned ones (see above); nothing was copied."`;
  rc 2 says `"Could not get the ${NETWORK} chain configs (see above)."`.
- `tn_chain_configs_tag`, `tn_chain_configs_dir`, `tn_chain_configs_from_tag` join
  `tn_require_fns` (`:204-211`).
- Tests: `tools/tests/genesis_hash_test.sh` `:86-117` gain "the pinned directory is used when no
  `--genesis-dir` is given" and "the pinned directory wins over the checkout's files".

### 2.3 `edit-config.sh` menu 13 — FIX-B

`refresh_chain_configs` (`:3717-3851`):

- devnet: unchanged (still pulls).
- testnet and mainnet: no `git pull`, no `tn_sync_submodules`. After the confirm and
  `menu_lock`: `tn_chain_configs_from_tag "$source_dir" "$network" edit_wait_say`; rc 1 or 2
  prints an error ending "Chain configs unchanged." and returns to the menu. The source of the
  copy is then `tn_chain_configs_dir "$network"`. The existing checks stay (files present, pins,
  chain-id guard, `refresh_copy_configs`, the restart and resync path).
- A node that already holds the pinned files (the three files in the node's data dir have the
  pinned sha256) is not restarted: print `Nothing to refresh` (the full line is yours, it must
  contain those words) and return to the menu without touching the service.
- Mainnet: no tag → nothing is fetched; the refusal of today (pins empty) stays.
- The intro text (`:3748-3750`) says what now happens (the pinned files of this script release
  are installed; new pins come with a signed scripts release).
- Menu label (`:3924`): `13) Refresh chain configs   (pinned genesis/committee/parameters)`
  (keep the column alignment of the neighbours).
- The three new helpers join `tn_require_fns` (`:160-166`).
- `refresh_copy_configs` and the restart/resync path keep their shape
  (`tools/tests/edit_backup_test.sh:323-345`, `tools/tests/edit_config_resync_test.sh:120`).
- New `tools/tests/chain_configs_refresh_test.sh` (harness from
  `tools/tests/edit_config_resync_test.sh:28-66`).

### 2.4 Independent test — FIX-T

New `tools/tests/chain_configs_tag_test.sh`, real git, modelled on
`tools/tests/source_ref_test.sh:474-492`: a bare origin with the tag (the fixture files of
`tools/tests/genesis.d/testnet` under `chain-configs/testnet/`) plus a `main` that diverged
(a changed `committee.yaml`). Written from this spec before FIX-A1's checkpoint or code is
read. Cases: clone on `main` → pinned files installed, HEAD and `git status --porcelain`
unchanged; dirty clone (modified and untracked files) → same, the changes still there; a
detached source tree at another tag; second run uses no git (a `git` wrapper that logs);
offline re-read (origin moved away) with the local copy; a pin mismatch (tag whose files
differ) → rc 1, destination untouched; a force-moved upstream tag → rc 1; a local tag of the
same name pointing elsewhere → remote copy read, local tag unmoved; a symlinked checkout →
rc 1; `TN_ROOT_PREFIX` honoured; no checkout → rc 2; mainnet (no tag) → rc 1 and no git;
`ensure_chain_configs_available` end to end with `confirm` stubbed both ways, and the clone
case against the local origin (set `TN_REPO` is readonly: see how `source_ref_test.sh` points
the library at a local origin, or use `git config url.<local>.insteadOf`). Skip with `skip`
when git is absent (the `bash:3.2` image has none).

Versions (orchestrator): `lib/common` 2.2.2, `setup-node` 2.1.2, `edit-config` 2.2.1.

## 3. Design B: hardware requirements per network

### 3.1 The tables (the text every document carries)

Testnet (Adiri):

| Role | Minimum | Recommended |
|---|---|---|
| Observer, follower | 2 cores (4 vCPU), 8 GB RAM | 4 cores (8 vCPU), 16 GB RAM |
| Observer, public RPC | 4 cores (8 vCPU), 16 GB RAM | 8 cores (16 vCPU), 32 GB RAM |
| Validator | 3 cores (6 vCPU), 16 GB RAM | 4 cores (8 vCPU), 16 GB RAM |
| Storage, every role | 350 GB SSD (15,000 IOPS, 240 MB/s) | 500 GB TLC NVMe |
| Validator bandwidth | 200 Mbps symmetric | 1 Gbps |

Mainnet:

| Role | Minimum | Recommended |
|---|---|---|
| Observer, follower | 2 cores (4 vCPU), 8 GB RAM | 4 cores (8 vCPU), 16 GB RAM |
| Observer, public RPC | 4 cores (8 vCPU), 16 GB RAM | 8 cores (16 vCPU), 32 GB RAM |
| Validator | 8 cores (16 vCPU), 32 GB ECC RAM | 16 cores (32 vCPU), 64 GB ECC RAM |
| Storage, validator | 2 TB TLC NVMe (20,000 write IOPS, 300 MB/s) | 4 TB |
| Storage, observer | 2 TB TLC NVMe (10,000 write IOPS, 300 MB/s) | 4 TB |
| Validator bandwidth | 200 Mbps symmetric | 1 Gbps |

### 3.2 Shell — HW-SH

Constants (`lib/common.sh:85-90`; lines 76-84 are not touched, line 80 is the version
constant). Exactly these names, one `readonly NAME=value` per statement (statements may share a
line with `;` as today), because the UI's mirror test parses them with
`readonly (HW_(TESTNET|MAINNET)_[A-Z_]+)=([0-9]+)`:

| Name stem | testnet | mainnet |
|---|---|---|
| `HW_<NET>_NODE_MIN_CPU` / `_RAM_GB` / `_DISK_GB` | 2 / 8 / 350 | 2 / 8 / 2000 |
| `HW_<NET>_RPC_MIN_CPU` / `_RAM_GB` / `_DISK_GB` | 4 / 16 / 350 | 4 / 16 / 2000 |
| `HW_<NET>_VAL_MIN_CPU` / `_RAM_GB` / `_DISK_GB` | 3 / 16 / 350 | 8 / 32 / 2000 |
| `HW_<NET>_VAL_REC_CPU` / `_RAM_GB` / `_DISK_GB` | 4 / 16 / 500 | 16 / 64 / 4000 |

(`HW_TESTNET_NODE_MIN_CPU`, `HW_TESTNET_NODE_MIN_RAM_GB`, `HW_TESTNET_NODE_MIN_DISK_GB`, and so
on.) The old `HW_NODE_*`, `HW_RPC_*`, `HW_VAL_*` names go. The comment names the two bases (the
deployed testnet validators; the telcoin-network hardware page plus the published benchmarks
for mainnet) and never says "adiri".

`_tn_hw_cores_label N` → `N cores (2N vCPU)` (e.g. `3 cores (6 vCPU)`). `_tn_hw_role` uses it in
the tier text and in the "needs" text: the spec string is
`<cores label> / <ram> GB / <disk label>`.

`check_hardware [unused] [data_dir] [network]` (`:2342-2447`):

- Tier set: `testnet` and `devnet` → testnet; `mainnet`, empty or anything else → mainnet (an
  old two-argument caller keeps the mainnet tiers and verdicts it has today).
- After the "Detected:" line (and the logical-CPU note when it applies), one `print_info`:
  - testnet: `Comparing with the testnet hardware tiers.`
  - devnet: `Comparing with the testnet hardware tiers (devnet uses them).`
  - mainnet: `Comparing with the mainnet hardware tiers.`
  - empty or unknown: `Comparing with the mainnet hardware tiers (no network given).`
- The three role lines, labels unchanged (`Full node (follower)`, `Public RPC node`,
  `Validator (minimum)`). For a `c3-highcpu-8` (4 physical cores, 16 GB, 350 GB disk) on
  testnet all three are `meets minimum`, the validator line reading exactly
  `Validator (minimum): meets minimum (3 cores (6 vCPU) / 16 GB / 350 GB)` after the `print_ok`
  prefix. On mainnet the same host gets
  `Validator (minimum): below minimum — needs ≥ 8 cores (16 vCPU), 32 GB RAM, 2 TB disk (have 4 physical cores, 16 GB RAM, <n> GB disk)`.
- Recommended line (`print_info`):
  - testnet: `Validator (recommended): 4 cores (8 vCPU) / 16 GB / 500 GB NVMe — NVMe is not checked here.`
  - mainnet: `Validator (recommended): 16 cores (32 vCPU) / 64 GB ECC / 4 TB NVMe — ECC and NVMe are not checked here.`
- Then `print_info` with the single-core sentence, verbatim:
  `Prioritise single-core performance: EVM execution is single-threaded, so a high clock speed matters more than extra cores.`
- Then the existing last line (`Hardware checks never block setup; …`).
- Still advisory, still returns 0. `TN_HW_SUMMARY` and `TN_HW_GAPS` keep their format. The
  5 % slack and the formulas stay: RAM floor `min_ram * 1024 * 1024 * 95 / 100` kB; disk floor
  `min_disk * 1000000000 * 95 / 100 / 1024` kB (decimal GB; 350 GB → 324,707,031 kB passes,
  324,707,030 warns). No new name joins `tn_require_fns`.
- Update the function's header comment (`:2325-2341`) for the third argument.

`setup-node.sh` `step_preflight` (`:373-470`): the `check_hardware` call and its `--json` log
block (`:419-428`) move to just after `check_internet` (`:456`), and the call becomes
`check_hardware "node" "$DATA_DIR" "$NETWORK"`. The `mkdir -p "$DATA_DIR"` line stays where it
is. Three tests parse this function and must stay green **unedited**:
`tools/tests/network_detect_test.sh:542-547`, `tools/tests/setup_node_alerts_test.sh:161-165`,
`tools/tests/host_baseline_test.sh:598-616`. Update the `print_header`-adjacent comments only
where they describe the order.

### 3.3 Shell test — HW-T

New `tools/tests/hardware_check_test.sh` (style of `tools/tests/os_floor_test.sh`), written from
this spec before HW-SH's checkpoint or code is read. Stub `lscpu`, `nproc`, `sysctl`, `df` on
`PATH`; `TN_PROC_MEMINFO` and `TN_PROC_CPUINFO` fixtures. Cases: `c3-highcpu-8` on testnet (all
three tiers pass, the exact validator line above, `TN_HW_GAPS` empty), the same host on mainnet
(all three warn, `TN_HW_GAPS` `node,rpc,validator`), devnet (testnet tiers, its info line), no
network (mainnet tiers, its info line), two arguments only (mainnet tiers), the disk boundary at
350 GB (324707031 kB passes, 324707030 warns), a 2-core host (testnet validator below minimum,
needs `3 cores (6 vCPU)`), the logical-CPU fallback (no `lscpu`, no readable cpuinfo, no
`sysctl`: `nproc` gives logical CPUs and the note is printed), the recommended lines for both
networks, the single-core sentence, rc 0 everywhere, and a static check that in
`setup-node.sh` `step_preflight` the `select_network` line precedes the `check_hardware` call
and that the call passes `"$NETWORK"`.

### 3.4 UI server — HW-UI-SRV (`ui/server.py:5177-5334`)

```python
HW_TIERS = {
    "testnet": (("node", "Full node (follower)", 2, 8, 350),
                ("rpc", "Public RPC node", 4, 16, 350),
                ("validator", "Validator (minimum)", 3, 16, 350)),
    "mainnet": (("node", "Full node (follower)", 2, 8, 2000),
                ("rpc", "Public RPC node", 4, 16, 2000),
                ("validator", "Validator (minimum)", 8, 32, 2000)),
}
HW_VALIDATOR_RECOMMENDED = {
    "testnet": {"cpu": 4, "ram_gb": 16, "disk_gb": 500, "ecc": False},
    "mainnet": {"cpu": 16, "ram_gb": 64, "disk_gb": 4000, "ecc": True},
}
```

- `hardware_profile(network="testnet")`: `mainnet` → mainnet tiers; anything else (testnet,
  devnet, unknown, None) → testnet tiers. The result gains `"network"`: the tier set applied,
  `"testnet"` or `"mainnet"`. Everything else keeps its shape:

```json
{"network": "testnet", "cpu": 4, "ram_kb": 16375000,
 "disk": {"path": "/", "total_kb": 360000000, "free_kb": 300000000, "used_pct": 17},
 "tiers": [{"role": "node", "label": "Full node (follower)", "min_cpu": 2, "min_ram_gb": 8,
            "min_disk_gb": 350, "ok": true, "gaps": []}, "... rpc, validator ..."],
 "validator_recommended": {"cpu": 4, "ram_gb": 16, "disk_gb": 500, "ecc": false}}
```

- Disk floor in decimal GB, the shell's formula:
  `gb * 1000**3 * HW_PASS_PCT // 100 // 1024` kB (350 → 324707031). RAM stays binary
  (`gb * 1024 * 1024 * HW_PASS_PCT // 100`). Two helpers, not one, so RAM is not changed.
- `api_preflight`: `net = network_rule(request.args.get("network")) or "testnet"` (the pattern
  at `:4447`; `adiri` reads as testnet; an unknown or missing value → testnet), passed to
  `hardware_profile(net)`. No error for a bad value.
- The comment above `HW_TIERS` names the shell constants it mirrors.
- Tests: `ui/test_server_contract.py` (the zero-argument stub at `:1481` must accept the
  argument; the tier shape at `:1850-1852`; a new `HardwareTiersTest`: both tier sets, the
  `network` field, the default, `?network=mainnet`, `?network=adiri`, `?network=bogus`, the
  disk floor boundary at 350 GB, `ecc`), and a new mirror test (its own file,
  `ui/test_hw_mirror.py`) that parses the `HW_(TESTNET|MAINNET)_*` constants out of
  `lib/common.sh` with the regex in 3.2 and compares them with `HW_TIERS` and
  `HW_VALIDATOR_RECOMMENDED`. HW-SH lands in parallel: the mirror test is written against the
  names in 3.2 and will be red in your worktree until integration (the library there still has
  the old names). Say so in the hand-back; do not edit `lib/`.

### 3.5 UI page — HW-UI-PAGE (`ui/static/index.html:3584-3650`)

- `stepPreflight` calls `/api/setup/preflight?network=<setupNetwork()>` (URL-encoded).
  Preflight is wizard step 1 and Network is step 2; going back to step 1 re-fetches, and the
  mainnet card is disabled today, so no other wiring is needed.
- `hwCores(n)` → `"<n> cores (<2n> vCPU)"`; `hwDiskLabel(gb)` → `"2 TB"` for whole thousands of
  GB, else `"350 GB"` (the shell's `_tn_hw_disk_label`).
- Tier row: `<label>: <verdict> (<hwCores(min_cpu)> / <min_ram_gb> GB RAM / <hwDiskLabel(min_disk_gb)> disk)`.
- Info row: the "Detected …" sentence as today; then, when `hw.network` is present,
  `Compared with the <network> hardware tiers.`; then
  `Recommended to validate: <hwCores(cpu)> / <ram_gb> GB RAM / <hwDiskLabel(disk_gb)> disk.`
  with `GB ECC RAM` in place of `GB RAM` when `validator_recommended.ecc` is true; then the
  single-core sentence of 3.2, verbatim.
- An older server sends no `network` and no `ecc`: the page renders without those parts.
- Test: `ui/test_page_wiring.py` (the request carries `network=`; the helper names and the
  single-core sentence are in the page).

### 3.6 AWS — AWS (`aws/node.yaml`, testnet only; `aws/rules/**` if a rule or its test pins a value)

- Validator preset → `c7i.2xlarge` (`:99`), descriptions `:51-53`.
- `DataVolumeSize`: default 500, allowed `[350, 500, 2000, 4000]` (`:64-72`); description:
  500 (the recommended size) or 350 (the minimum) for a testnet node; 2000 and 4000 stay
  allowed for stacks launched with them; it runs at 15000 IOPS and 300 MB/s.
- `DataVolume`: `Iops: 15000`, `Throughput: 300` (`:274-287`).
- The Ubuntu 26.04 `ImageId` default (`:84-88`) is untouched; the file keeps its 4 lines naming
  26.04.
- CPU wording wherever the template states it: `c7i.2xlarge, 4 cores (8 vCPU), 16 GiB`.
- Gates at the versions CI pins (`.github/workflows/ci.yml:271-305`): cfn-lint from
  `aws/requirements-ci.txt` with `--require-hashes` (Python 3.12 in CI), cfn-guard 3.2.2 from
  its GitHub release with the sha256 CI checks:
  `cfn-lint aws/node.yaml`; `cfn-guard validate --rules aws/rules --data aws/node.yaml --show-summary fail`;
  `cfn-guard test --dir aws/rules`. Neither tool is installed on this host: install them in a
  container or a scratch directory, not into the repository.

Versions (orchestrator): `lib/common` 2.2.3, `setup-node` 2.1.3, `telcoin-ui` 2.1.1.

## 4. Design C: mainnet chain id 731

Added by the user on 2026-11-21. The mainnet chain id is **731** (`0x2db`) everywhere it is
stated as the current value. 487 (`0x1e7`) is no longer mainnet's; upstream uses it for devnet
genesis files, and this repository's own `DEVNET_CHAIN_ID` stays 32285 ("a devnet is any other
chain id" stays true).

- CHAIN-SH: `lib/common.sh:24-26` (`readonly MAINNET_CHAIN_ID="731"`; the comment says the id
  matches `chain-configs/mainnet/genesis.yaml` on telcoin-network `main` since #1716 and
  `MAINNET_CHAIN_ID` in `crates/types/src/genesis.rs`), the comment at `:3183`; the comments at
  `check-node.sh:2880`, `update-node.sh:323` and `:1204`; every shell fixture that hard-codes
  487 or `0x1e7` as the mainnet id (`tools/tests/alerts_test.sh`,
  `consensus_participation_test.sh`, `gateway_setup_test.sh`, `network_detect_test.sh`,
  `primitives_test.sh`, `quorum_guard_test.sh`, `setup_passphrase_test.sh`, and any other the
  sweep finds, `tools/tests/vm.d` and `tasks/` excluded: `tasks/` is history). Where a fixture
  can read `$MAINNET_CHAIN_ID` instead of a literal, prefer that only if the test still proves
  the value somewhere: keep at least one assertion per file that names 731 literally. Add
  cases that pin the new behaviour: a genesis with chain id 487 is **not** detected as mainnet
  (`tn_detect_network`, `primitives_test.sh` / `network_detect_test.sh`), and 731 is.
  `network_detect_test.sh:542-547` (the `step_preflight` parse) is not yours: leave it.
- CHAIN-UI: `ui/server.py:1405-1426` (the network-name table and `NETWORK_PUBLIC_RPC`: key 731,
  comments), `ui/test_csrf.py:435-436`, `ui/test_server_chain.py:401-431`, and any other UI
  file the sweep finds (`ui/static/index.html`, `ui/dev/serve.py`). Add a test that chain 487
  no longer resolves to mainnet.
- Docs (wave 3): every current-state statement. **The worklist is section C5 of
  `tasks/verify-req/V-CHAIN/REPORT.md`** (32 rows: file:line at `1a3404b`, the current text,
  the class and the new text); it replaces the list that stood here, which missed
  `OPERATOR.md:814`, the guide's `:674` (both quote check-node's message with the id) and
  `followup.md:139`, `:166`. In short: `README.md:748`, `:1159`, `:1804` (and optionally
  `:1807`); `OPERATOR.md:187`, `:210`, `:249`, `:814`, `:2263`; the guide `:208`, `:242`,
  `:674`; the mainnet one-pager `:36` (`| Chain ID | 731 (\`0x2db\`) |`); `followup.md:118-122`,
  `:132-136`, `:139`, `:166`. Entries of released versions in `CHANGELOG.md` (`:380`) and below
  `## Changelog` in `README.md` (`:3394`) are history and stay; the new changelog entries say
  the id moved from 487 to 731.
- `followup.md` correction (V-CHAIN VC-1, checked against upstream `origin/main` on
  2026-11-21): **no** sentence stays "about devnet, 487". Upstream #1716 is merged
  (2026-11-12; no release tag carries it). The faucet opt-in is `--allow-faucet-on-chain`
  (env `TN_ALLOW_FAUCET_ON_CHAIN`); `TN_ALLOW_FAUCET_ON_CHAIN_487` and
  `--allow-cleartext-bls-key` no longer exist. On chain 731 the node refuses a cleartext BLS
  key and a faucet build and no flag lifts either. The Association's devnet answers
  `eth_chainId` with `0x7e1d` (32285), not 487. Use the FU-1 to FU-5 wording of the worklist.
- Sweep pattern: `git grep -n -I -i -w -E '487|0x1e7|1e7'` (and `0x01e7`, `1E7`) outside
  `tasks/`, `*.sha256`, `*.svg`, `vendor/`, `tools/tests/genesis.d/`.

Versions (orchestrator): `lib/common` 2.2.4, `check-node` 2.2.1, `update-node` 2.1.1,
`telcoin-ui` 2.1.2.

## 5. Exact strings for the docs (wave 3)

| Id | Text |
|---|---|
| F1 | CPU is written `N cores (2N vCPU)` on every figure, AWS rows included (`c7i.2xlarge, 4 cores (8 vCPU), 16 GiB`). |
| F2 | `Prioritise single-core performance: EVM execution is single-threaded, so a high clock speed matters more than extra cores.` |
| F3 | The testnet rows of 3.1. |
| F4 | The mainnet rows of 3.1. |
| F5 | `The testnet figures follow the five Adiri validators: Google Cloud c3-highcpu-8 machines (4 cores (8 vCPU), 16 GB, Intel Sapphire Rapids), each with a 350 GB pd-ssd disk, which Google caps at 15,000 IOPS and 240 MiB/s on that machine size.` |
| F6 | `The mainnet validator storage figure comes from Telcoin's published benchmarks at [benchmark.telcoin.network](https://benchmark.telcoin.network). In the [latest run](https://benchmark.telcoin.network/runs/r20261115-1653/), 10 validators on 8 vCPU and 16 GB with a 20,000 IOPS, 800 MiB/s volume averaged about 9,300 transactions a second, with write IOPS at about 20,000 at the 95th percentile and about 286 MiB/s written. Execution ran strictly in sequence: the engine was busy about 978 ms of every second while the machine used about 56 % of its 8 vCPUs. The other mainnet figures come from the hardware requirements page in the telcoin-network documentation.` |
| F7 | Hardware-check paragraph: runs during preflight once the network is picked; one line per role against that network's table, e.g. `[OK] Validator (minimum): meets minimum (3 cores (6 vCPU) / 16 GB / 350 GB)` on testnet; only warns; counts physical cores, so an 8 vCPU instance with 4 cores meets the testnet validator minimum but not the mainnet one; does not check ECC, NVMe, IOPS or throughput; devnet uses the testnet table. |
| F8 | Troubleshooting row for `[WARN] <role>: below minimum`: under that role's minimum for the chosen network; a warning only; an 8 vCPU instance meets the testnet validator minimum, 3 cores (6 vCPU), but not the mainnet one, 8 cores (16 vCPU). |
| F9 | (Corrected after V-AWS, 2026-11-21; the facts to carry, in the document's own sentences.) AWS presets: `FullNode` (default) `c7i.2xlarge, 4 cores (8 vCPU), 16 GiB`; `PublicRPC` `c7i.4xlarge, 8 cores (16 vCPU), 32 GiB`; `Validator` `c7i.2xlarge, 4 cores (8 vCPU), 16 GiB`, the same size as `FullNode`. `DataVolumeSize`: `500` (default) or `350` GiB; `2000` and `4000` stay allowed for stacks launched with them. The gp3 data volume is provisioned at 15,000 IOPS and 300 MiB/s. Cores, RAM and disk size follow the recommended column of the testnet table; the disk is an EBS network volume, not a local NVMe drive. A `c7i.2xlarge` sustains 12,000 IOPS and 312.5 MB/s to EBS and bursts above that for 30 minutes at least once every 24 hours, so on `FullNode` and `Validator` the volume gives 12,000 IOPS sustained and 15,000 in bursts. A `c7i.4xlarge` sustains the full 15,000. |
| F10 | (Corrected after V-AWS, 2026-11-21; the facts to carry.) Existing stacks keep running as they are; nothing in this release needs a change on them. Do not update a stack to this template. Every stack update reads Canonical's image parameter again. Once a newer image is out, the update tries to replace the instance, fails because the old instance holds the network interface, and rolls back. The volume's IOPS change is made before that failure, so the rollback waits until the volume modification completes, which can take hours, and the stack shows `UPDATE_ROLLBACK_IN_PROGRESS` meanwhile. If the image has not changed, a `Validator` stack's update stops and starts the instance to change its type, outside the epoch-boundary wait of `update-node.sh`. Make changes on the resources instead. To raise the data volume to 15,000 IOPS, use the EC2 console (`Volumes`, `Modify volume`): the node keeps running, and the volume takes no other modification until this one shows `completed` (at most four modifications in 24 hours). To move a `Validator` to `c7i.2xlarge`, change the instance type in the EC2 console at a time when the node may restart. A volume can grow but not shrink, and a stack update that picks a smaller `DataVolumeSize` fails. After you grow a volume, grow its filesystem on the host: `sudo resize2fs "$(findmnt -no SOURCE /var/lib/telcoin)"` (the volume has no partition table, and ext4 grows while mounted). Do not snapshot the volume first: a snapshot is a copy of the node keys. The sentence "the stack rolls back unchanged" (`OPERATOR.md` 2.11) is no longer true for an update that changes the volume. Source of each claim: `tasks/verify-req/V-AWS/REPORT.md` (V-AWS-3: "documented" or "inferred" per case; the update order and the stop/start are inferred, not observed). |
| F11 | Walkthrough order: step 2 ends with the port check and curl/git; step 3 (network) then checks internet, runs the hardware check against that network's table, and checks the systemd floor. |
| F12 | Mainnet chain id: `731` (`0x2db`). |

Chain-config doc strings: setup reads the three files from the tag the script release pins
(`v0.16.0-adiri` on testnet), never from `main`, into `/etc/telcoin/chain-configs/<network>/`,
and never pulls or checks out an existing `/opt/telcoin-source`; Docker, signed-release and
existing installs may be asked to clone; menu 13 installs the pinned files and prints
`Nothing to refresh` without a restart when the node already has them; the `git pull failed`
sentence (`OPERATOR.md:1108`) goes.

Doc rules: the sentence "These figures come from the hardware requirements page in the
telcoin-network documentation" is replaced by the two bases (F5, F6). Quoted script messages
are copied from the code at the frozen tip, not from this spec. The partner build bans the word
"legacy" in the guide and one-pagers (`AGENTS.md:639`). Per file, the count of lines naming
26.04 must not drop below `main`'s (`README.md` 9, `OPERATOR.md` 8, guide 5, each one-pager 1,
`aws/node.yaml` 4, `lib/common.sh` 4, `setup-node.sh` 1).

One-pager cuts if the mainnet page overflows, in order, rebuilding after each: drop the QLC
bullet (the storage rows say TLC); shorten the round-trip bullet; shorten the "Every node"
bullet; drop "The firewall asks for SSH sources." together with "Setup's `2) Mainnet` choice is
refused until launch."; shorten the IMPORTANT callout on both pages. Column widths in
`theme.css` (`:132-134`) move to 40 % / 35 % only if the recommended cell wraps. The
operating-system lines are never cut.

## 6. After wave 1 (integration 1, tip `1a3404b`)

Commits on `requirements-from-benchmarks` over `01664cc`:

| Commit | Subject | Packages |
|---|---|---|
| `f355768` | fix(setup): take the chain configs from the pinned tag, not from main | FIX-A1, FIX-A2, FIX-T |
| `35f4e33` | fix(edit-config): refresh installs the pinned chain configs instead of pulling | FIX-B |
| `adcd1c0` | feat(setup): check the hardware against the chosen network's tiers | HW-SH, HW-T |
| `9772c36` | feat(ui): the setup preflight judges the hardware tiers of the wizard's network | HW-UI-SRV, HW-UI-PAGE |
| `6aebeee` | feat(aws): Validator preset c7i.2xlarge, a 500 GiB data volume at 15,000 IOPS | AWS |
| `1a3404b` | fix(network): the mainnet chain id is 731 | CHAIN-SH, CHAIN-UI |

Versions at that tip: `lib/common` 2.2.4, `setup-node` 2.1.3, `edit-config` 2.2.1, `check-node`
2.2.1, `update-node` 2.1.1, `telcoin-ui` 2.1.2. The `.sha256` sidecars are stale on purpose
until the final `chore(release)` commit: a verifier does not report that.

### 6.1 Accepted deviations from sections 2-4 (not findings)

- Library (2.1): a fetch counts only once `refs/tn-remote-tags/TAG^{commit}` verifies; trailing
  slashes are stripped from DIR before the symlink test; two private helpers,
  `_tn_chain_configs_install` (step 8) and `_tn_chain_configs_consent` (the prompt); any step-8
  failure is rc 2 with `Could not install the ${net} chain configs from ${tag} into ${dest} (see above).`;
  `Could not make a staging directory for the ${net} chain configs.` (rc 2); on devnet a failed
  clone returns 2 and `TN_GENESIS_DIR` means no git; mainnet without a tag shows no clone prompt.
- setup-node (2.2): the pinned directory joins `step_write_config`'s search list only on a
  network with a tag, so devnet and mainnet-without-a-tag search as before.
- Menu 13 (2.3): the "Nothing to refresh" test runs before the confirm; `edit_unlock` on a
  helper error; `edit_baseline_refresh` after files were installed; `source_dir` honours
  `TN_ROOT_PREFIX`.
- Shell hardware check (3.2): an unknown network value prints "(no network given)"; the "have"
  part of a below-minimum line lists only the dimensions that fall short.
- UI server (3.4): `_hw_floor_kb` became `_hw_ram_floor_kb`, next to the new
  `_hw_disk_floor_kb`.
- UI page (3.5): `?` for a missing value; the detected disk is decimal GB; the single-core
  sentence comes after the empty-row return.
- AWS (3.6): no guard rule changed; a comment at the volume states the gp3 ratios and the
  instance's EBS baseline.
- Chain id (4): the UI does not list 487 at all (a node on 487 is named through `.node-meta`).

### 6.2 Known open items (verifiers confirm or refute each, with a severity)

- FIX-T F1: a pin-mismatch warning names files in the staging directory, which is gone by then.
- FIX-T F2: a failed second write leaves the destination with one new file (rc 2, no rollback).
- FIX-T F3: step 2 accepts a destination directory that is a symlink to a directory holding the
  pinned files; owner and mode are not checked.
- FIX-T F4: "Could not reach origin" is also printed when origin is reachable but the tag is
  gone there, or git refuses the repository.
- FIX-T F5: a `git worktree` checkout (`.git` is a file) is "not a git checkout" (rc 2).
- FIX-T F6: the staging directory is not swept when the run is killed.
- FIX-T F7: `rev-parse` and `cat-file` run without the https restriction and with fd 9 open.
- Menu 13: the no-checkout hint says "Re-run sudo ./setup-node.sh", which is doubtful advice
  for an installed node; `aide --update` runs twice on a first install with a restart; the older
  early returns after the lock leave the release to `main_menu`.
- Stale text outside the packages' ranges: `update-node.sh` ~2658 ("git fetch and pull");
  `setup-node.sh` ~3296 (the `TN_GENESIS_DIR` comment names only `step_write_config`) and the
  dead `run_streamed` with its comment (~3332).
- An older `setup-node.sh` (01664cc) with the new library on a checkout that sits on a diverged
  default branch still refuses (it searches the checkout first). It fails safe.
- AWS: the stack-update answers in `tasks/ckpt-req-aws.md` are from memory; nothing grows the
  filesystem after a volume grows; gp3 throughput is MiB/s (300 MiB/s is about 315 MB/s).
- `ui/dev/serve.py` rewrites `hardware.cpu` for an older-server mode and knows no `network`.

### 6.3 Rules for verifiers

- Your worktree is at the integrated tip. Edit no tracked file. Your harness and report go under
  `tasks/verify-req/<id>/` in your worktree (`*.sh` with a shebang, passing
  `shellcheck --severity=error`, `bash -n` under bash 5 and 3.2, and `tools/check-bash32.sh`:
  they are committed with the round's records and CI lints them).
- Write the harness from this spec BEFORE reading the implementers' checkpoints
  (`/home/drtnarg/coding/telcoin/tn-node-deployment/tasks/ckpt-req-*.md`, read-only) or their
  tests. Read the code under test as much as you like.
- Report `tasks/verify-req/<id>/REPORT.md`: a findings list, each with an id, severity
  (High / Medium / Low / Info), what you expected, what happened, the reproduction command, and
  a suggested fix. If the Write of the report is refused, return its full text in your answer.
- An item in 6.1 is not a finding unless it causes a defect you can demonstrate.

## 7. For the documentation wave (wave 3): the code is frozen

The frozen tip and its commits are named in each writer's brief. Versions at the frozen tip:
`lib/common` 2.2.5, `setup-node` 2.1.4, `edit-config` 2.2.2, `check-node` 2.2.1, `update-node`
2.1.2, `install-caddy` 2.2.1, `telcoin-ui` 2.1.3. Unchanged in this round: every other script
(`update-scripts` stays 2.2.0; `lib/gateway`, `setup-gateway`, `firewall-setup`, `remove-node`,
`prepare-stake` and the rest keep their versions).

Version history inside this round, for the changelog entries (one README entry per bump; the
pending release note `CHANGELOG/scripts-v2.2.0.md` has ONE heading per script, at its final
version, that tells the whole change):

| Script | Bumps (commit) | Topic of each |
|---|---|---|
| `lib/common` | 2.2.2 (`f355768`), 2.2.3 (`adcd1c0`), 2.2.4 (`1a3404b`), 2.2.5 (`35e0b7c`) | pinned-tag chain configs; hardware tiers per network; mainnet chain id 731; chain-config helpers after verification |
| `setup-node` | 2.1.2 (`f355768`), 2.1.3 (`adcd1c0`), 2.1.4 (`35e0b7c`) | reads the pinned directory; hardware check after the network is chosen; "were refused", directories listed once, the new manual hint |
| `edit-config` | 2.2.1 (`35f4e33`), 2.2.2 (`8311f9e` and the seam fix after it) | menu 13 installs the pinned files; menu 13 offers the clone, frees the lock before prompts, uses the library's pre-checks |
| `telcoin-ui` | 2.1.1 (`9772c36`), 2.1.2 (`1a3404b`), 2.1.3 (`d2c0889`) | preflight tiers per network; mainnet keyed by 731; a measured zero is unmeasured, exact core compare, `cpu_kind`, logical CPUs worded |
| `check-node` | 2.2.1 (`1a3404b`) | comment only: the chain ids it accepts name 731 |
| `update-node` | 2.1.1 (`1a3404b`), 2.1.2 (`35e0b7c`) | comments only: 731; no `git pull` runs there |
| `install-caddy` | 2.2.1 (`adf7ee0` and the seam fix after it) | the mainnet gate names the chain it found and checks the public RPC's chain |
| `aws/node.yaml` | no version (`6aebeee`, `d372e0c`) | presets, volume, the console note |

### 7.1 What the fix round changed that the documents must follow

Quote operator-facing messages from the code at the frozen tip, never from sections 2-5 of
this spec, which predate the fix round. In particular:

- `Could not reach origin` is no longer printed anywhere. The library says
  `Could not fetch <tag> from origin (<git's reason>); reading the <net> chain configs from the local copy of <tag>.`
  (`tn_chain_configs_from_tag` in `lib/common.sh`).
- setup's rc-1 line is `The <network> chain configs were refused (see above); nothing was copied.`
  and the rc-2 line `Could not get the <network> chain configs (see above).`
  (`step_create_infrastructure` in `setup-node.sh`). The "not found" hint is four lines and
  names the tag and `--genesis-dir` (`step_write_config`).
- "In place" means root-owned directories 0755 and files 0644; a directory with the right
  contents and other owner or modes is reinstalled (`Reinstalled the <net> chain configs …`); a
  symlinked destination or an entry in the way is refused; a git worktree checkout is read; a
  source path that exists and is not a checkout is refused with
  `… exists but is not a git checkout; move it aside first.`
- Menu 13 (`refresh_chain_configs` in `edit-config.sh`): `Nothing to refresh: …` followed by
  the `14) Restart node` hint; with no checkout and no pinned files the menu offers to clone at
  the pinned tag, and prints a manual `sudo git clone --branch <tag> …` line and three
  raw-file URLs when that is declined or fails; it never tells the operator to re-run setup; a
  network this release pins nothing for (mainnet today) is refused before any prompt with
  `This script release pins no <network> chain configs yet, …`; the update lock is free at
  every "Press Enter".
- Hardware check, shell (`check_hardware` in `lib/common.sh`): as section 3.2; the "have" part
  of a below-minimum line lists only the dimensions that fall short
  (`needs ≥ 2 TB disk (have 350 GB disk)`).
- UI: the page shows `Detected 8 logical CPUs / …` and the shell's sentence about logical CPUs
  when the server could not count physical cores; the detected disk is decimal GB.
- AWS: F9 and F10 of section 5 as corrected; the parameter descriptions are in `aws/node.yaml`
  (quote them from there).
- Caddy (`caddy_mainnet_gate` in `install-caddy.sh`): the "network cannot be told" refusal
  carries `tn_detect_network`'s reason (for a chain-487 genesis:
  `no NETWORK in .node-meta, and the chain id of <datadir>/genesis/genesis.yaml (487) is neither 731 nor 2017`);
  the stake is read from the mainnet public RPC only when it answers with chain 731.
  `docs/testnet-addons.md:54` describes that refusal: check it still reads true.

### 7.2 Follow-up items to record in `followup.md` (DOC-M)

Each is a verified observation that this round leaves open; give each one or two sentences and
what closes it. Sources are the verifier reports under `tasks/verify-req/`.

- The upstream hardware page (`docs/src/getting-started/hardware-requirements.md` in
  telcoin-network) still shows the old single table; it needs the per-network tables.
- Mainnet launch: the wizard shows the mainnet tiers at step 1 only if the operator goes back
  to it after picking mainnet (V-HW-UI F9); re-fetch the preflight when the network changes.
- The UI preflight measures the default data dir, setup the one chosen later (V-HW-UI F10,
  older than this round).
- Menu 13 on a first install that ends in a successful restart refreshes the host baseline
  twice (V-FIX-E-3): `apply_changes` would need a way to skip its refresh.
- An older `setup-node.sh` or `edit-config.sh` with the new library on a checkout that sits on
  a diverged default branch fails safe, but setup then fails at finalize, after keygen
  (V-FIX-S-06, V-FIX-E-9); `update-scripts.sh` installs the set together.
- `remove-node.sh` on an older `/etc/telcoin/<role>` layout leaves
  `/etc/telcoin/chain-configs`; the next run's leftovers menu removes it (V-FIX-S-13).
- A failed second write during the install leaves a partial pinned directory, which the next
  run completes (FIX-T F2); the pre-check covers entries in the way.
- `setup-node.sh` still carries the unused `run_streamed` (V-FIX-S-12).
- CI does not check the gp3 ratios or the preset instance types of `aws/node.yaml`; a plain
  fixture test could (V-AWS-7). Nothing grows the filesystem after an EBS volume grows; the
  runbook gives the `resize2fs` step (V-AWS-4).
- Devnet means "exactly 32285" in check-node, update-node and the heartbeat, and "any other
  chain id" in the gateway and `OPERATOR.md` (V-CHAIN VC-5, older than this round).
- The UI names a node on an unknown live chain by `.node-meta` without a mismatch note
  (V-CHAIN VC-6).
- A rehearsal host whose `alerts.env` was written with `NETWORK=mainnet` before this release
  keeps `ALERTS_CHAIN_ID=487` until `setup-alerts.sh` is run again (V-CHAIN VC-7).
- `tn_genesis_chain_id` in menu 13's chain-id guard reads the data dir's genesis as root
  (older than this round; the new "Nothing to refresh" test reads through the service user).

## 8. Commit ids: the ones this file and the reports cite, and the final ones

Two commit messages were corrected after wave 4, so every commit of the branch was rebuilt
with the same tree and a new id. Sections 6 and 7, the checkpoints and the verifier reports
cite the earlier ids. The trees are identical, commit for commit, except the two partner
commits, whose PDFs were rebuilt on Ubuntu 26.04 (their Markdown and metadata are the same).

| Cited id | Final id | Subject |
|---|---|---|
| `f355768` | `3d51804` | fix(setup): take the chain configs from the pinned tag, not from main |
| `35f4e33` | `bea3b02` | fix(edit-config): refresh installs the pinned chain configs instead of pulling |
| `adcd1c0` | `fbb2a89` | feat(setup): check the hardware against the chosen network's tiers |
| `9772c36` | `52b2edc` | feat(ui): the setup preflight judges the hardware tiers of the wizard's network |
| `6aebeee` | `0ed4128` | feat(aws): Validator preset c7i.2xlarge, a 500 GiB data volume at 15,000 IOPS |
| `1a3404b` | `38181ca` | fix(network): the mainnet chain id is 731 |
| `35e0b7c` | `03c737c` | fix(setup): chain-config helpers after verification |
| `8311f9e` | `4cd5a5a` | fix(edit-config): menu 13 offers the clone and frees the lock before its prompts |
| `d2c0889` | `cc2c41e` | fix(ui): the preflight treats a measured zero as unmeasured and words logical CPUs as such |
| `d372e0c` | `f3b884f` | fix(aws): say in the console what a c7i.2xlarge sustains to EBS |
| `adf7ee0` | `8d3368d` | fix(caddy): the mainnet gate names the chain it found and checks the public RPC's chain |
| `7a686dc` | `018cdff` | fix(edit-config): menu 13 uses the library's pre-checks |
| `f55fd84` | `897d322` | docs: chain configs come from the pinned tag |
| `57e40d8` | `57f772d` | docs: hardware requirements per network |
| `c9519f1` | `c550cd2` | docs: the mainnet chain id is 731 |
| `928c60f` | `9f24310` | docs(partner): guide 1.13, hardware per network, chain configs at the pinned tag, chain id 731 |
| `d7c16b1` | `8c07fa0` | docs(partner): node requirements one-pagers 1.3 |

Earlier names of the two partner commits: the guide was `cfcafac`, then `928c60f`; the
one-pagers were `2d91fa8`, then `d7c16b1`. After them came `45635c0` (docs: corrections
after verification), `9ec5b7c` (chore(release): refresh the checksums) and the records
commit. The code was frozen at `7a686dc`, now `018cdff`.

The PDF build command of section 0 names the Debian 12 `tn-pdf-tools` container. The
committed PDFs were built in an Ubuntu 26.04 image instead (pandoc 3.14, WeasyPrint 70.0,
Pango 1.57.0, HarfBuzz 12.3.2); `AGENTS.md`, "Partner documents", has the recipe and the
reason.
