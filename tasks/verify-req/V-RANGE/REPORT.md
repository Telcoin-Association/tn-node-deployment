# V-RANGE: the whole change 01664cc..adf7ee0 as one diff (code only, `tasks/` excluded)

Reviewer V-RANGE, worktree `tnd-req-v-range` (branch `req/v-range`, tip `adf7ee0`), 2026-11-21. No tracked file was edited.

**Method:**
- The `code-review` skill at effort `high` on the range. It ran as a forked reviewer, read the code only, and returned 10 findings; they are triaged below.
- My own seam review of the seven areas in the brief.
- Every finding given as reproduced was run with the harness in this directory.

**Repro harness:** `tasks/verify-req/V-RANGE/vr_menu13_worktree.sh`.
- It uses real git: a local bare origin, with a git worktree as the checkout.
- The lock, confirm, systemctl, epoch wait, host baseline and root writers are the stand-ins of `tools/tests/chain_configs_refresh_test.sh`.
- It writes only under its temp dir.
- It passes `shellcheck -x --severity=error`, `bash -n` under bash 5 and `bash:3.2`, and `tools/check-bash32.sh`.
- **Run:** `TMPDIR=<scratch> bash tasks/verify-req/V-RANGE/vr_menu13_worktree.sh`.
- **Expected at adf7ee0:** `14 checks, 1 failures`.
  - Cases 2, 3 and 5 assert the defective behaviour, so their `ok` shows VR-1 and VR-3 present.
  - Case 4 asserts the intended behaviour, so its one `FAIL` shows VR-2.
- **Output:** `/var/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/46275ae3-5cf9-4f35-b799-c09950443243/scratchpad/v-range/vr_menu13.out`

## Findings (most severe first)

There are no High or Medium findings. All three Lows are in edit-config.sh menu 13, at its seam with the library's fix round. The menu's own pre-checks were written before 35e0b7c changed what the library accepts: "in place" now requires the modes, and a worktree counts as a checkout. No one reconciled the two afterwards.

### VR-1 (Low): menu 13 does not recognise a checkout the library reads (a git worktree), and offers a clone into a directory that cannot take one

**Where:**
- `edit-config.sh:3831`, `:3843` and `:3885` test `-d "${source_dir}/.git"`.
- The library tests `-e` (`lib/common.sh:3409`, `:3420`, `:7425`), and its doc says a worktree counts because its `.git` is a file.
- Before the clone question, the menu calls neither `_tn_chain_configs_clone_target` (`lib/common.sh:3327`) nor `_tn_chain_configs_dest_ok`. `ensure_chain_configs_available` calls both (`:3410-3411`), so it never asks to clone into a path that is in the way, or for a destination it would refuse anyway.

**Scenario:** `/opt/telcoin-source` is a git worktree at the tag, the pinned directory is empty, and the data dir is stale.
- `tn_chain_configs_from_tag` reads the worktree: rc 0 (case 1).
- Menu 13 prints "There is no repository checkout at /opt/telcoin-source ..." and asks whether to clone.
- **Declined:** "Not cloned. Chain configs unchanged." The menu never calls the helper, so it can never refresh this node (case 2).
- **Accepted:** `git clone` refuses the non-empty directory. The operator sees "Clone failed. Check your internet connection.", then a manual `sudo git clone ...` line that fails the same way (case 3).
- **When the helper does run and returns rc 2** (fetch failed, no local tag): the `:3885` branch says there is no checkout and "Run this again to be offered a clone". That clone then fails as above.
- **The same path, without a worktree:** any non-empty directory without `.git`. Setup (`ensure`) refuses it with "exists but is not a git checkout; move it aside first." The menu offers the clone instead.

**Reproduced:** cases 1-3 of `vr_menu13_worktree.sh`. The code-review skill reported the same (its findings 2 and 6).

**Suggested fix:**
- Use `-e` in all three tests.
- Before the clone question, run `_tn_chain_configs_dest_ok "$pin_dir"` and `_tn_chain_configs_clone_target "$source_dir"`, and add both to `tn_require_fns`.
- Cleaner: one library function answering "does this network need a clone first", called by both `ensure` and the menu, so the two callers cannot drift again.
- Add a worktree case and a "path in the way" case to `chain_configs_refresh_test.sh`.

### VR-2 (Low): a mode-only reinstall of the pinned files skips the host-baseline refresh

**Where:**
- `edit-config.sh:3876-3879` sets `had_pinned` from `tn_chain_configs_check` alone, which checks contents only.
- `:3901` refreshes the baseline only when `had_pinned` is false.
- Since 35e0b7c, `tn_chain_configs_from_tag` reinstalls a destination whose contents are right but whose owner or modes are not the install's (`lib/common.sh:7419-7423`, `:7497-7506`). It rewrites the files under `/etc/telcoin/chain-configs/<net>` (new inode, owner and mode) and returns rc 0.

**Scenario:** `HOST_BASELINE=true`, the pinned files are 0600 in a 0700 directory (made by hand, or under umask 077), and the data dir is stale.
- The menu prints "Reinstalled the testnet chain configs ... root-owned, directories 0755 and files 0644".
- The operator answers "restart later". `edit_baseline_refresh` never runs; the baseline count is 0 (case 4).
- The same happens on every path that does not end in a successful restart: the committee check refusing, a failed restart, the chain-id guard, a failed copy.
- The next `aide --check` reports the changed files under `/etc/telcoin` as drift. Only a successful restart (`apply_changes`, `:2259`) hides it.

**Why the tests did not catch it:** the refresh test's stand-ins (`_tn_root_layout_dir() { mkdir -p; }`, `tn_write_root_file() { cat >; }`) set no modes. The suite passes the same under umask 022, 002 and 077 (I ran all three), and no case covers the reinstall.

**Reproduced:** case 4: `FAIL menu: host baseline refreshed after that reinstall (count)`, expected 1, got 0. The code-review skill reported the same (its finding 7).

**Suggested fix:**
- Set `had_pinned=true` only when `tn_chain_configs_check ... && _tn_chain_configs_in_place "$chain_config_src"`.
- Or have the library report whether it wrote anything (for example a global set in `_tn_chain_configs_install`), and refresh whenever it did.
- Add the 0600 case to the refresh test, with stand-in writers that set the modes they are given.

### VR-3 (Low): menu 13 picks its rc-2 message by whether `.git` is a directory, not by what failed, and can send the operator round a loop

**Where:** `edit-config.sh:3882-3892`.
- rc 2 with no `.git` directory always prints "There is no repository checkout at ... and <pinned dir> does not hold them", then "Run this again to be offered a clone of the repository at <tag>."
- rc 2 with one always prints "Could not read the pinned ... from /opt/telcoin-source (see above)."

**Scenario A (reproduced, case 5):** no checkout; the pinned files are right but 0600, and their reinstall fails. Here the layout writer refuses, as it does when `/etc/telcoin` fails `tn_root_dir_ok`; a failed write does the same.
- The library warns "Could not reinstall ... (see above)".
- The menu then says the directory "does not hold them", which is false, and promises a clone offer.
- A re-run asks no clone question, because the pre-lock content test passes, and ends with the same two lines. Runs 1 and 2 are identical.

**Scenario B (reasoned):** no checkout, and `committee.yaml` in the pinned directory is a directory.
- The pre-lock test fails, so the menu offers the clone and makes it.
- The helper then refuses the destination entry (rc 2).
- The menu says "Could not read ... from /opt/telcoin-source". The clone was made for nothing; `ensure` checks the destination before it asks.

**Scenario C (reasoned):** a staging-directory failure without a checkout also gets "does not hold them".

**Suggested fix:**
- On rc 2, print one neutral line: "The pinned ${network} chain configs (${tag}) could not be installed (see above). Chain configs unchanged." The library's warning above it already names the cause.
- Add the clone hint only when the pinned content check fails and `! -e .git`.
- With VR-1's shared pre-check, scenario B goes away.

### VR-4 (Info): two new library calls are not on their script's require list

- **What is missing:**
  - `install-caddy.sh:2511` now calls `_tn_rpc_chain_is`, which `caddy_require_lib` (`install-caddy.sh:3891-3894`) does not list.
  - `edit-config.sh:3772` and `:3788` now call `tn_chain_config_pin`, which `tn_require_fns` (`edit-config.sh:161-168`) does not list.
- **The rule:** AGENTS.md, "Scripts and an older library": "When a script starts calling a library helper it did not call before, add the helper to that script's list."
- **No practical gap:**
  - Each list already requires a helper newer than the missing one, so an older library is refused up front anyway.
  - `caddy_require_lib` lists `tn_gateway_installed` (2026-11-17), which is newer than `_tn_rpc_chain_is` (2026-10-15).
  - edit-config lists `tn_chain_configs_from_tag`, which is newer than `tn_chain_config_pin`.
  - Without that guard, a missing `_tn_rpc_chain_is` would still fail safe, but with the wrong reason ("does not answer with chain 731").
- **Reasoned:** from `git log -S` on each helper.
- **Fix:** add both names.
- **The rest is sound:** every name the lists carry is defined in lib 2.2.5, and setup-node lists the three helpers it uses.

### VR-5 (Info): four new test checks fail when TMPDIR is long

- **Which checks:**
  - `tools/tests/genesis_hash_test.sh:311` ("git cannot read the checkout: git's reason")
  - `tools/tests/chain_configs_tag_test.sh:518`, `:525` and `:532` (the three "offline" warnings)
- **Why:** each compares git's message, which embeds the fixture's temp path, with the library's reason. The library cuts that reason at 200 characters (`lib/common.sh:7646`). With a TMPDIR of about 110 characters or more, the expected line runs past the cut.
- **Who is affected:** with the default `/tmp` and with the macOS runner's TMPDIR, the messages stay under 200 and the checks pass. Only a deep TMPDIR (a host or CI image) is affected.
- **Reproduced:** `TMPDIR=/var/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/46275ae3-5cf9-4f35-b799-c09950443243/scratchpad/v-range/tmp bash tools/tests/run.sh tools/tests/genesis_hash_test.sh tools/tests/chain_configs_tag_test.sh` gives 1 and 3 failures. The cut reason measures exactly 200 characters.
- **Fix:** build the expected text with the same cut (`${msg:0:200}`), or keep the fixtures under a short directory.

### VR-6 (Info): aws/node.yaml, throughput on the c7i.2xlarge presets

- **The gap:** the volume is provisioned at 300 MiB/s (`aws/node.yaml:295`), about 314.6 MB/s. A c7i.2xlarge sustains 312.5 MB/s to EBS (spec F9), about 298 MiB/s.
- **What the template says:**
  - The DataVolumeSize description (`:75-80`) gives what the c7i.2xlarge sustains in IOPS (12000, and 15000 in bursts) but says nothing about throughput.
  - The comment at `:290-293` says "300 MiB/s on every allowed size", which is the volume's figure, not the instance's.
- **Size:** about 0.6 %, and no stated figure is wrong. I note it only because d372e0c reworded the description to say what the instance sustains.
- **Reasoned:** from AWS's published c7i figures, as spec F9 carries them.
- **Optional fix:** "... sustains 12000 IOPS and about 298 MiB/s to EBS ...".
- **Every other number and unit in the file is consistent:**
  - gp3 needs 30 GiB or more for 15000 IOPS (500 IOPS per GiB), and 1200 IOPS or more for 300 MiB/s (0.25 MiB/s per IOPS).
  - The preset sizes match the testnet recommended column (4 cores (8 vCPU) / 16 GiB, and 8 cores (16 vCPU) / 32 GiB).
  - 350 GiB is at least 350 GB.
  - The allowed sizes and the default match the description.
  - "15000 in bursts" is the volume's cap under the instance's burst.
  - "30 minutes at least once every 24 hours" is AWS's wording.

## Code-review skill findings: how I triaged them

| # | Its finding (severity it gave) | Verdict |
|---|---|---|
| 1 | The UI wizard judges hardware at step 1 with the testnet tiers, before the network is picked (important) | Accepted by spec 3.5. The mainnet card is `disabled`, so `setupNetwork()` is always testnet today. Same as V-HW-UI F9. Not a defect until mainnet is enabled. |
| 2 | Menu 13 tests `-d .git` (important) | Confirmed and reproduced: VR-1. |
| 3 | An AWS stack update shrinks the Validator instance and tries to shrink the volume (important) | Known. Spec F10 ("Do not update a stack to this template ... a stack update that picks a smaller DataVolumeSize fails") and V-AWS-3 cover it, and the wave-3 docs carry it. A console update keeps the previous parameter values; a CLI update without them takes the new defaults, as F10 says. Not new. |
| 4 | Docs still say 487 | Docs are wave 3, out of scope (code only). |
| 5 | `.sha256` sidecars and changelog | Stale on purpose until the release commit; excluded by the brief. |
| 6 | Menu has no `_tn_chain_configs_clone_target` (nit) | Part of VR-1. |
| 7 | `had_pinned` checks contents only (nit) | Confirmed and reproduced: VR-2. |
| 8 | Testnet setup now refuses a checkout not owned by root, or one offline without the tag (nit) | By design: spec 2.1 step 4, the same owner rule as `tn_source_checkout_tag`, whose source builds need a root-owned checkout anyway. The rc-1 line is now neutral, and the library's warning names the cause. |
| 9 | With no network or an unknown one, the shell defaults to the mainnet tiers and the UI to testnet (nit) | Per spec 3.2 and 3.4. setup-node always passes testnet, mainnet or devnet, and the page always passes testnet or mainnet, so no caller sees the split. Info. |
| 10 | `check_hardware` now runs after `check_internet`, which exits when offline (nit) | Per spec 3.2 and F11. `check_internet` exits only when there is no connectivity, and setup cannot go on then anyway. Info. |

## What I checked and found sound

**Area 1: chain-config helpers against setup-node and the fixtures**
- `ensure_chain_configs_available` agrees with `tn_chain_configs_from_tag` on every testnet path:
  - both test `-e .git`;
  - the quiet content test has its stderr silenced;
  - `dest_ok`, then `clone_target`, run before the consent prompt;
  - consent declined is rc 0, a failed clone is rc 2, anything else is from_tag's rc.
- setup-node maps rc 1 to "were refused (see above)" and rc 2 to "Could not get ... (see above)". The helpers' warnings reach `setup_progress` and the JSON log.
- `step_write_config`:
  - The search order is `TN_GENESIS_DIR`, then the pinned dir (only on a network with a tag), then the checkout, then `CONFIG_DIR`.
  - The dedupe is bash 3.2 and `set -u` safe.
  - The copies are checked after copying.
  - The hint names the tag and `--genesis-dir`.
- `CONFIG_DIR` is `/etc/telcoin` in every script. edit-config never sets it, so `tn_chain_configs_dir` gives the same directory in setup and in the menu.
- A no-submodule clone at the tag still works for a later source build: `tn_source_checkout_tag` checks out the tag, then runs `tn_sync_submodules`.

**Area 2: lock, prompts and staging**
- Every new `confirm` and `read` in menu 13 sits before `menu_lock` or after `edit_unlock`. The clone question is asked with the lock free, and the clone runs under it.
- Every new git child goes through `_tn_chain_configs_git`. That wrapper:
  - closes fd 9;
  - allows https only;
  - drops a stray `GIT_DIR` and the related variables;
  - sets `GIT_NO_LAZY_FETCH` on the read-only calls;
  - sets `GIT_CEILING_DIRECTORIES`.
- Pre-existing, not new: the devnet `git pull` and `tn_sync_submodules` in menu 13 keep fd 9 open, and `apply_changes` asks its restart question under the lock.
- Staging:
  - It is `tag.$$.XXXXXX` under `tn_staging_dir`, which `tn_staging_sweep` covers in both modes, and it is removed on every return path of from_tag.
  - Under `TN_ROOT_PREFIX` without `TN_RELEASE_STAGING_DIR`, it falls back to `mktemp -d`.
  - The tests set `TN_RELEASE_STAGING_DIR`, or exercise that fallback.
- No new test writes outside its temp dir; I grepped for writes to `/etc`, `/opt`, `/var`, `/usr`, `/root` and `/run`. The tag test's `/root` temp dir is root-only and cleaned up on exit.

**Area 3: hardware tiers.** The shell, the server and the page agree per network on:
- the 24 values;
- the RAM floor (binary) and the disk floor (decimal), with the same integer formulas;
- CPU compared exactly;
- zero or missing counted as unmeasured;
- half-up rounding of "have" and "Detected";
- the cores, vCPU and TB labels.

The server side is also sound:
- `physical_cores()` keeps its old result (counted cores, else the logical count), and `system_info` and `cpu_physical` are unchanged.
- `cpu_kind` is read only by the page.
- `ui/dev/serve.py` legacy mode strips `network`, `cpu_kind` and `ecc`.
- `ui/test_hw_mirror.py` checks all 24 constants in both directions, each defined once.

**Area 4: chain id**
- Every `MAINNET_CHAIN_ID` use is right: check-node, update-node, lib/alerts, lib/gateway, prepare-stake, setup-node, `select_network`, `tn_detect_network`, the quorum guard, the mode-unknown wait and the caddy gate.
- The caddy gate prints `tn_detect_network`'s own reason, and asks the public RPC for the stake only after `_tn_rpc_chain_is ... 731`. Its tests cover 487, 731, 2017, no genesis, a public RPC on 2017, 731 or junk, testnet and devnet.
- The UI's `NETWORKS` and `NETWORK_PUBLIC_RPC` are keyed 731, and `ChainIdTieTest` ties them to the library lines.
- The 487/0x1e7 sweep finds code hits only in comments and tests.

**Area 5: versions.** lib/common 2.2.5, setup-node 2.1.4, edit-config 2.2.2, check-node 2.2.1, update-node 2.1.2, install-caddy 2.2.1, telcoin-ui 2.1.3. Every name the require lists carry is defined.

**Area 6: ordinary correctness**
- Shell hazards:
  - No `local a; a=$(...)` masking.
  - No `set -e` traps in the new code paths.
  - `$(...) && x=1` and `|| rc=$?` are used correctly.
  - The redirect order of the `cat-file` capture is right.
  - `rm -rf` runs only on a validated `mktemp` dir.
  - Root files are written with `tn_write_root_file` fed from a file.
- Lints are clean: `tools/check-network-hits.sh`, `tools/check-bash32.sh` on all changed scripts and tests, and `shellcheck -x --severity=error` on lib/common.sh, setup-node.sh, edit-config.sh and install-caddy.sh.
- The new tests (chain_configs_refresh 140/0, genesis_hash, chain_configs_tag, hardware_check 300/0, caddy 189/0) pass, apart from the long-TMPDIR case in VR-5. The refresh and genesis tests give the same result under umask 022, 002 and 077.
- BSD and macOS: the new library lines use GNU `stat -c`, which `tools/tests/lib.sh` shims on macOS, and `mktemp` templates ending in `XXXXXX`. The new code has no `sed -i`, `readlink -f`, `date -d` or multi-line `awk -v`.

**Area 7: aws/node.yaml** is consistent; VR-6 is a wording note.

## What I did not get to
- A full line-by-line read of the four large new test files (`chain_configs_tag_test.sh`, `chain_configs_refresh_test.sh`, the new half of `genesis_hash_test.sh`, `hardware_check_test.sh`).
  - I scanned them for checks that cannot fail, network use, writes outside the temp dir and BSD hazards.
  - I read the hardware test's static checks in full.
- `ui/test_server_contract.py` (233 changed lines): not read.
- No macOS run.
- My harness was not run in `bash:3.2`, where it would skip because that image has no git, nor as root in `ubuntu:26.04`; its root writers are stand-ins.
- I did not re-run the whole suites, per the brief.
- VR-3 scenarios B and C were reasoned from the code, not reproduced.
