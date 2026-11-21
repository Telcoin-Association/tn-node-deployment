# V-FIX-S report: chain configs at the pinned tag (Design A), verified end to end

Tree under test: `1a3404b` (worktree `tnd-req-v-fix-s`, `lib/common` 2.2.4, `setup-node` 2.1.3). Baseline for the bug: `01664cc` (`lib/common` 2.2.1, `setup-node` 2.1.1, a `git archive` of the main checkout). Every run used a disposable `ubuntu:26.04` container as root (git 2.53.0 from apt) and the real public repository `https://github.com/Telcoin-Association/telcoin-network.git`. "Offline" means a real DNS failure (`GIT_CONFIG_KEY_0=url.https://unreachable.invalid/.insteadOf`, `GIT_CONFIG_VALUE_0=https://github.com/`) or a git wrapper first on PATH that fails every network subcommand. Nothing else left the host.

Run directories (output only, outside the worktree), under `/var/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/46275ae3-5cf9-4f35-b799-c09950443243/scratchpad/v-fix-s/`:
- `s1-20261121-120335-3331599` (S1)
- `s2-run1` (S2)
- `s3-inner-20261121-121346-3401538` (S3)
- `s4-inner-20261121-121420-3412524` (S4)
- `s5-inner-20261121-121722-3595420` (S5)

Each holds `decisive.txt` plus one `.out`, `.err` and `.git` (git argv log) per case.

Harness (this directory):
- `s1-live.sh` and `s1-inner.sh`: the live proof.
- `s2-case.sh`: one setup-node.sh process in the fixture style. It sources a copy of setup-node.sh without its last line, keeps `set -euo pipefail` as the library leaves it, installs `json_on_exit` as the EXIT trap and the TERM/INT traps of `main`, and takes the update lock as `step_preflight` does.
- `s2-inner.sh`, `s3-inner.sh`, `s4-inner.sh`, `s5-inner.sh`: the cases.
- `vcommon.sh`: shared helpers.
- `vrun.sh`: the container driver.

All nine pass `shellcheck -x --severity=error`, `bash -n` under bash 5 and in the `bash:3.2` image, and `tools/check-bash32.sh`.

## Result in one paragraph

The fix works against the real repository. At `01664cc`, on a fresh testnet host, the clone lands on `main` (`33bf2a20`, with every submodule) and `ensure_chain_configs_available` refuses on `committee.yaml` (sha256 `886f016b...`, pin `009b6d7b...`). The bug reproduces. At `1a3404b`, the clone sits detached on the tag's commit `d72cc2bc` and no submodule is initialised. The three files are in `/etc/telcoin/chain-configs/testnet` with the pinned sha256; the directories are root:root 0755 and the files root:root 0644. With the checkout moved by hand to `origin/main` and the directory emptied, the files come back, and HEAD and `git status --porcelain` do not change. With the directory in place and the network cut, no git command runs at all. With the directory emptied and origin unreachable, the local copy of the tag is used (`refs/tn-remote-tags`, then `refs/tags` once that ref is deleted). Every setup-node.sh path ends with rc 0 or a clean rc 1 and no bash error: the interactive path, the UI's two-process keygen/finalize path, `--genesis-dir`, a failed clone or fetch, and a checkout owned by another account. There is no High or Medium finding. Five Low findings are about messages, and one is about a hand-made pinned directory that is never repaired.

## Findings

| id | severity | one line |
|---|---|---|
| V-FIX-S-01 | Low | In `--json` mode, a failed clone's reason never reaches the JSON stream. The UI gets only "Could not get the testnet chain configs (see above)." |
| V-FIX-S-02 | Low | A refused checkout (another account's, or a symlink) ends with "The testnet chain configs are not the pinned ones", which is the wrong cause. |
| V-FIX-S-03 | Low | F4 confirmed and wider. Fetch stderr is dropped, so three causes get a wrong reason: origin without the tag, git refusing the repository, and a stray `GIT_DIR`. |
| V-FIX-S-04 | Low | F2 confirmed. A non-file entry in the destination blocks every run and leaves a partial destination. |
| V-FIX-S-05 | Low | F3 confirmed, plus F3b. A hand-made pinned directory (0700/0600) passes step 2 and is never repaired; setup then fails at step 6 on every run. |
| V-FIX-S-06 | Low | Skew: the setup-node.sh of 01664cc with the new library on a diverged checkout fails safe, but now at finalize, after keygen. |
| V-FIX-S-07 | Info | F1 confirmed. The mismatch warning names `/tmp/tmp.X/committee.yaml`, which is gone. |
| V-FIX-S-08 | Info | F5 confirmed, and worse in `ensure`. A worktree checkout leads to the consent prompt and then "Clone failed. Check your internet connection." |
| V-FIX-S-09 | Info | F6 confirmed. SIGTERM during the read leaves `/tmp/tmp.X` with the (public) files. |
| V-FIX-S-10 | Info | F7 confirmed. `rev-parse` and `cat-file` run with fd 9 (the update lock) open and no `GIT_ALLOW_PROTOCOL`. |
| V-FIX-S-11 | Info | The "not found in" error lists two directories twice. |
| V-FIX-S-12 | Info | The stale setup-node.sh comments are confirmed: the TN_GENESIS_DIR comment and the dead `run_streamed`. |
| V-FIX-S-13 | Info | remove-node.sh on a legacy `/etc/telcoin/<role>` layout leaves `/etc/telcoin/chain-configs`. The next run's leftovers menu removes it. |
| V-FIX-S-14 | Info | A plain run whose stdin ends at the consent prompt reads it as "no", continues, and fails at step 6. Unchanged since 01664cc. |
| V-FIX-S-15 | Info | The update lock is held while the consent prompt waits (by design, unchanged). `update-node.sh --check` fetches into the same `refs/tn-remote-tags` without the lock. |

### V-FIX-S-01 (Low): a failed clone's reason is missing from the JSON stream
- **Expected:** in `--json` mode, the error the UI shows explains why the chain configs could not be got, or a `log` event before it does. A failed fetch already works this way (C6b).
- **Got** (S2 C5, `c5-json`): the JSON stream has exactly two lines, `{"event":"error","msg":"Could not get the testnet chain configs (see above)."}` and the matching `done`. The cause ("Clone failed. Check your internet connection.") and the manual clone command go to stderr only, through `print_error`/`print_info` in `_tn_chain_configs_clone` (lib/common.sh:3327-3346). The UI operator sees "(see above)" with nothing above it.
- **Reproduction:** `bash tasks/verify-req/V-FIX-S/vrun.sh s2-inner.sh`, case `c5-json`. By hand: on a fresh host, set `GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=url.https://unreachable.invalid/.insteadOf GIT_CONFIG_VALUE_0=https://github.com/` and run `s2-case.sh infra json`.
- **Suggested fix:** give `_tn_chain_configs_clone` the progress fn and send its two messages through `_tn_guard_say warn ... "$fn"`, as the fetch path already does. Or word setup's rc-2 line with the cause.

### V-FIX-S-02 (Low): a refused checkout is reported as "not the pinned ones"
- **Expected:** the final error names the actual refusal.
- **Got** (S2 C7a, C7b): a checkout owned by `nobody`, or `/opt/telcoin-source` as a symlink, first gives the correct warning: `/opt/telcoin-source must be a directory owned by root (not a symlink); nothing was fetched.` It then ends with `The testnet chain configs are not the pinned ones (see above); nothing was copied.` In `--json` mode that sentence is the `error` and `done` message the UI shows, although no file was compared. setup-node.sh:2150-2154 maps every rc 1 to it, as spec 2.2 asked, but rc 1 also covers the ownership and symlink refusals.
- **Reproduction:** `vrun.sh s2-inner.sh`, cases `c7a-plain`, `c7a-json` and `c7b-symlink`.
- **Suggested fix:** a neutral rc-1 line, for example "The ${NETWORK} chain configs were refused (see above); nothing was copied.", or a separate rc for an unusable checkout.

### V-FIX-S-03 (Low): fetch errors are hidden, so three causes get a wrong reason (F4, wider)
- **Expected:** the warning says what went wrong.
- **Got:**
  - **Origin reachable but without the tag** (S5 `f4`; insteadOf points origin at the public tn-contracts repository, where a fetch by hand says `fatal: couldn't find remote ref refs/tags/v0.16.0-adiri`): the run prints `Could not reach origin; reading the testnet chain configs from the local copy of v0.16.0-adiri.` and returns rc 0 with the pinned files. The result is right; the message is wrong.
  - **`.git` owned by another account** (S2 `c7c-dotgit-other`, git's "dubious ownership" refusal): the run prints `Could not fetch tag v0.16.0-adiri from origin, and the checkout does not have it.` and returns rc 2. The checkout does have the tag; git refuses to read it.
  - **`GIT_DIR` exported in the environment** (S5 `u4-gitdir`): the same "checkout does not have it" message, rc 2.
  The content stays safe in every case because the pins are checked. Fetch stderr goes to `/dev/null` (lib/common.sh:7384).
- **Reproduction:** `vrun.sh s5-inner.sh` (cases `f4` and `u4-gitdir`); `vrun.sh s2-inner.sh` (case `c7c-dotgit-other`).
- **Suggested fix:**
  - Keep the last line of the fetch's stderr and put it in the warning.
  - Word it "origin did not provide ${tag}".
  - Run `git -C DIR rev-parse --git-dir` before the fetch and refuse with git's reason when it fails.
  - Unset `GIT_DIR` and `GIT_WORK_TREE` for these calls.

### V-FIX-S-04 (Low): a non-file entry in the destination blocks every run (F2)
- **Expected:** a failed install either leaves the destination as it was, or the next run repairs it.
- **Got** (S5 `f2-run1`, `f2-run2`): with `committee.yaml` a directory in the destination, each run:
  1. fetches the tag,
  2. writes `genesis.yaml`,
  3. refuses `committee.yaml` (`tn_write_root_file: refusing ...: it is a symlink or a directory`),
  4. never writes `parameters.yaml`,
  5. returns rc 2.
  After both runs the directory holds `committee.yaml(d) genesis.yaml(f)`, and every later run repeats this until the entry is removed by hand. The message names the entry. Setup refuses on rc 2, so nothing wrong is used.
- **Reproduction:** `vrun.sh s5-inner.sh`, section F2.
- **Suggested fix:** refuse before the first write when any of the three names exists as a non-file, so no partial state is left, and end the message with "remove it and run again".

### V-FIX-S-05 (Low): a hand-made pinned directory is never repaired (F3, F3b)
- **Expected:** step 2 accepts only what step 8 would have made (a root-owned real directory 0755 holding root 0644 files), or setup repairs the modes.
- **Got:**
  - **F3** (S5 `f3`, `f3-write`): the destination as a symlink to a nobody-owned 0777 directory holding the pinned files is accepted with no git, and `step_write_config` copies from it. Integrity holds, because `_setup_copied_configs_ok` checks the copies against the pins again.
  - **F3b** (unlisted, S5 `f3b-*`): a directory made by hand under umask 077 (0700, files 0600) with the right contents passes step 2, and its modes are never touched. `step_write_config` then fails on every run with `cp: cannot stat ...: Permission denied` and `Could not copy the chain config files from /etc/telcoin/chain-configs/testnet as telcoin: they must be readable by that user.` The not-found hint tells the operator to copy into exactly this directory (`into /etc/telcoin/chain-configs/testnet/`). On a host with a restrictive root umask (027 or 077), following the hint leads to this state.
- **Reproduction:** `vrun.sh s5-inner.sh`, sections F3 and F3b.
- **Suggested fix:** in step 2, also require a non-symlink, root-owned destination with no group or other write. When the contents match but the modes are wrong, re-run `_tn_chain_configs_install` from the files in place, which needs no git. Alternatively, have the hint name an operator-owned directory and point at `--genesis-dir`.

### V-FIX-S-06 (Low): skew, an old setup-node.sh with the new library (spec 6.2 item confirmed)
- **Expected** (spec 6.2): it fails safe.
- **Got** (S3, run for real):
  - **New setup-node.sh with the 01664cc library:** refuses up front with rc 1. In plain mode it prints `[ERROR] lib/common.sh 2.2.1 is older than this setup-node.sh: run update-scripts.sh and try again.` on stderr. In `--json` mode it prints exactly one `error` and one `done` event with that text on stdout, and nothing on stderr. No file was written and no git ran.
  - **01664cc setup-node.sh with the new library, fresh host (B1):** it works. The consent clone lands on the tag, and the old search list reads the checkout, which matches the pins.
  - **Same pair, checkout on the diverged default branch (B2, B3):** step 4 (UI keygen) passes with rc 0. Step 6 (UI finalize) refuses with rc 1: `The chain configs in /opt/telcoin-source/chain-configs/testnet do not match the testnet pins`, because the old search list puts the checkout first. Nothing wrong is copied.
  - **Where the refusal now falls:** with 01664cc on both sides, this host refused at step 4, before any keys existed. With this skew the refusal comes after step 5 (`step_generate_keys`). The keys, node-info.yaml, .node-meta, the service account and the directories then exist, and there is no unit. Re-running finalize keeps refusing until the scripts are updated or the checkout is moved back to the tag.
  - **Control (B4):** the new setup-node.sh finalizes on the same host.
- **Reproduction:** `bash tasks/verify-req/V-FIX-S/vrun.sh s3-inner.sh`.
- **Suggested fix:** none, if update-scripts.sh always installs the set together. Otherwise the new `ensure` could warn when the checkout's `chain-configs/<net>` does not match the pins.

### V-FIX-S-07 (Info): the mismatch warning names a removed file (F1)
S5 `f1` moved the local copy of the tag to main's commit and ran offline. It prints `/tmp/tmp.v75Qo2QwTc/committee.yaml: sha256 886f016b..., expected 009b6d7b... (testnet).`, then `The testnet chain configs at v0.16.0-adiri do not match the pins; nothing was installed.` It returns rc 1 and leaves the destination untouched. The staging directory no longer exists. Fix: name the file by tag, for example "committee.yaml at v0.16.0-adiri".

### V-FIX-S-08 (Info): a worktree checkout reaches the clone prompt (F5, worse in ensure)
S5 `f5`: `/opt/telcoin-source` is a git worktree, so `.git` is a regular file. `ensure` tests `-d .git` (lib/common.sh:3382) and takes the no-checkout branch. It shows the consent prompt and runs `git clone` into the existing directory, which fails with `fatal: destination path ... already exists and is not an empty directory.` It then prints `Clone failed. Check your internet connection.` and returns rc 2. Any non-empty non-checkout `/opt/telcoin-source` takes the same path, which is unchanged since 01664cc. Fix: test `-e .git` in both places, and say "exists but is not a git checkout" instead of cloning.

### V-FIX-S-09 (Info): staging directory left after SIGTERM (F6)
S5 `f6`: a run killed with SIGTERM during `cat-file` exits with rc 143 and leaves `/tmp/tmp.2dMFTceyDs/{genesis,committee}.yaml`. `tn_staging_sweep` only knows `/var/lib/telcoin-staging/{rel,rustup,tag,bin,docker-apt}.*`. The files are public. Fix: stage under `TN_RELEASE_STAGING_DIR` with a `tag.<pid>.*` name, which the existing stale sweep then removes.

### V-FIX-S-10 (Info): rev-parse and cat-file keep fd 9 and have no protocol restriction (F7)
The S2 git wrapper logged every call:
- `clone` and `fetch` run with fd 9 closed and `GIT_ALLOW_PROTOCOL=https`.
- `rev-parse -q --verify` and the three `cat-file blob` calls run with `fd9 OPEN->/run/telcoin/update.lock` and `GIT_ALLOW_PROTOCOL=unset`.
They are short-lived and no harm was reproduced. On a partial clone, a lazy fetch would inherit the lock. Fix: the same prefix as the fetch, or `GIT_NO_LAZY_FETCH=1`.

### V-FIX-S-11 (Info): duplicated directories in the not-found error
S2 `c1-write`: `Chain config files not found in /etc/telcoin/chain-configs/testnet /opt/telcoin-source/chain-configs/testnet /opt/telcoin-source/chain-configs/testnet /etc/telcoin/chain-configs/testnet.` Fix: remove duplicates from `search_paths`.

### V-FIX-S-12 (Info): stale setup-node.sh comments (spec 6.2 item confirmed)
- setup-node.sh:3298-3300 says TN_GENESIS_DIR is "checked first by step_write_config". `ensure_chain_configs_available` also uses it as given, with no git and no prompt (S2 C4: 0 git calls).
- `run_streamed` (setup-node.sh:3333-3348) has no caller (grep finds only its definition, plus install-caddy.sh's own copy), and its comment still names "the git clone".

### V-FIX-S-13 (Info): legacy config layout leaves /etc/telcoin/chain-configs after removal
S4:
- **Unified layout:** `remove_keys` with a typed DELETE runs `shred_key_files` and `_rm_config_dir`, the same pair json_remove's keys scope runs. It removes all of `/etc/telcoin`, including `chain-configs`. `remove_leftovers` removes it as well.
- **Legacy layout** (config dir `/etc/telcoin/validator`): only that directory goes. `/etc/telcoin/chain-configs/testnet/*` stays, and `rmdir /etc/telcoin` cannot remove it. `rm_leftovers_present` then returns 0, so the next remove-node.sh run offers it as a leftover.

The files are public. Fix, if wanted: also remove `/etc/telcoin/chain-configs` when the config dir is a legacy role dir.

### V-FIX-S-14 (Info): a plain run that cannot answer the consent prompt
- **stdin ends after the two account prompts** (S5 `u5-eof`): `confirm` reads EOF as "no" and prints `Skipped...`, rc 0.
- **The following write step** (`u5-write-eof`): the "Press Enter" read is `|| true`, so it fails at once with the not-found error (rc 1). In the real flow `step_generate_keys` runs between the two.
- **stdin empty from the start** (`u5-devnull`): rc 1 with no message at the service-user `read` (set -e).

Both behaviours are the same at 01664cc. `TN_ASSUME_YES=true` and `--json` give consent.

### V-FIX-S-15 (Info): the lock during the prompt, and update-node.sh
S5 `u1`: while the consent prompt waits, `flock -n /run/telcoin/update.lock true` fails (lock HELD). The lock is taken in `step_preflight` and held across every setup prompt, as at 01664cc. Clone and fetch close fd 9. All mutating paths of update-node.sh take the same lock. `update-node.sh --check` (`latest_source_ref`, update-node.sh:2833) runs without the lock and fetches `--prune '+refs/tags/*:refs/tn-remote-tags/*'` into the same namespace. At worst, a collision fails setup's fetch, which then reads the local copy (still checked against the pins). Not run concurrently.

## Proved (commands)

1. **S1, the live proof:** `bash tasks/verify-req/V-FIX-S/s1-live.sh`.
   - **old:**
     - `ENSURE_RC=1`
     - `HEAD=33bf2a20... ref=refs/heads/main`
     - `committee.yaml: sha256 886f016b..., expected 009b6d7b...`
     - `step_write_config` would copy from the checkout, where `CHECK_RC=1`
     - `.git/modules present: yes`
   - **new:**
     - `ENSURE_RC=0` and `Installed ... into /etc/telcoin/chain-configs/testnet.`
     - `HEAD=d72cc2bc... detached describe=v0.16.0-adiri`, and `HEAD equals the tag's commit: yes`
     - submodule `-`, and no `.git/modules`
     - `root:root 755` on both directories, `root:root 644` on the three files with the pinned sha256
     - `step_write_config` would copy from the pinned directory, where `CHECK_RC=0`
   - **p2** (checkout on `origin/main`, directory emptied): rc 0, files back. HEAD and porcelain are unchanged.
   - **p3** (network cut, directory in place): rc 0, `git calls made: 0`.
   - **p4a** (wrapper offline, directory emptied): rc 0, `Could not reach origin; ... local copy`. The argv log shows only fetch, rev-parse and three cat-file calls.
   - **p4b** (real DNS failure, `refs/tn-remote-tags` deleted): rc 0, read from `refs/tags`.
   - **p4c** (neither ref): rc 2.
2. **S2, setup-node.sh in the fixture style:** `docker run --rm -v <wt>:/s:ro -v <wt>/tasks/verify-req/V-FIX-S:/h:ro -v <run>/out:/out ubuntu:26.04 bash /h/s2-inner.sh`, which is the same as `vrun.sh s2-inner.sh`. Every case is a fresh `env -i` process, and no bash error appeared in any of them.
   - **Consent refused:** `Skipped`, then the hint `tree/v0.16.0-adiri/...`, then rc 1.
   - **Consent given:** the clone runs with `--branch v0.16.0-adiri`, fd 9 closed and https only. The copies have the pinned sha256.
   - **UI keygen and finalize:** as two `env -i` processes, keygen emits only JSON log events. Finalize finds the pinned directory with 0 git calls.
   - **`--genesis-dir`:** 0 git calls and the directory is used as is. A bad directory gives rc 1, with a `WARNING:` log event and the error/done pair.
   - **Failed clone:** rc 1, and no checkout is left behind.
   - **Failed fetch:** with the local copy it ends rc 0; without one, rc 1 with a JSON warning.
   - **Foreign or symlinked checkout:** refused with 0 git calls.
3. **S3, skew:** `vrun.sh s3-inner.sh`. The results are in V-FIX-S-06.
4. **S4, removal:** `vrun.sh s4-inner.sh`. `remove_keys` gives `/etc/telcoin after: 0 entries`, and `remove_leftovers` prints `Removed: /etc/telcoin`.
5. **S5, open items and unlisted cases:** `vrun.sh s5-inner.sh`.
   - **`TN_ROOT_PREFIX=/r`:** the files are installed under `/r`. The only change outside it is the mtime of `/tmp` itself, from the staging directory that was then removed.
   - **A stale pinned directory from other pins:** online, it is replaced (rc 0). Offline without a copy, it ends rc 2 and setup refuses.
   - **`https_proxy`:** it reaches git.
   - **`/etc/telcoin` with another mode:** `create_directories` forces it to root:root 0755 before `ensure` runs.
   - **set -e and set -u:** every process ran with the library's `set -euo pipefail`, and none printed a bash error.
6. **Gates on the harness:**
   - `shellcheck -x --severity=error` on all 9 scripts: clean.
   - `bash -n` under bash 5 and in `bash:3.2`: rc 0.
   - `tools/check-bash32.sh`: clean.
   - The worktree holds only untracked files under `tasks/`, none owned by root.

## Not proved
- **A full `setup-node.sh` main run** (apt, docker, keytool) was not run. Because `step_generate_keys` never ran, the "after keygen" part of V-FIX-S-06 comes from the step order.
- **The clone destination under `TN_ROOT_PREFIX`:** the case hit step 2 instead of the clone; the path is read from lib/common.sh:3366 and 3384.
- **F7 harm** (a lazy fetch on a partial clone) was not reproduced.
- **A concurrent update-node.sh:** not run; the analysis comes from update-node.sh:2827-2846 and 3500-3504.
- **IPv6:** not tested.
- **Mainnet (empty tag) and devnet:** not run live.
- **edit-config.sh menu 13 (FIX-B):** out of scope.
- **The implementers' tests:** not read or run. Their checkpoints were read only after the harness had been written and run.
