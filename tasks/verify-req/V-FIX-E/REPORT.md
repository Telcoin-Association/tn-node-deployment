# V-FIX-E report: edit-config.sh menu 13 (refresh_chain_configs) at 1a3404b

Verifier V-FIX-E, worktree `tnd-req-v-fix-e` (branch `req/v-fix-e`, tip `1a3404b`), 2026-11-21.
I wrote the harness from spec sections 0, 1, 2 and 6 and from the code. I read the FIX-B checkpoint only after the harness was green. I have not read `tools/tests/chain_configs_refresh_test.sh`.

Harness: `tasks/verify-req/V-FIX-E/menu13_test.sh` (suites `main`, `cmp`, `oldscript`) and its driver `tasks/verify-req/V-FIX-E/run_all.sh`.
- Real git runs against a local bare origin. Tag `v0.16.0-adiri` holds the pinned fixture files; `main` changes `committee.yaml` after the tag.
- A git wrapper logs every argv, whether fd 9 is open and the value of `GIT_ALLOW_PROTOCOL`.
- systemctl, confirm, the committee guard and the host-baseline refresh are logging stubs.
- Every case gets a fresh `TN_ROOT_PREFIX`.
- In `ubuntu:26.04` the run is as root, with the real root writes and the real `tn_as_service_user` (`nobody`). On the host the run is not root, and those calls are stand-ins.

## Findings

| Id | Severity | One line |
|---|---|---|
| V-FIX-E-1 | Medium | The no-checkout hint sends an installed node to a full `setup-node.sh` re-run. Its tree URL serves HTML, not the files. |
| V-FIX-E-2 | Low | After an earlier refresh whose restart was deferred, "Nothing to refresh ... was not restarted" does not say the running node may still use the old files, or that 14 restarts it. |
| V-FIX-E-3 | Low | On a first install with a restart, the host baseline (`aide --update`) is made twice. |
| V-FIX-E-4 | Low | The older early returns after `menu_lock` keep the update lock through the "Press Enter" prompt. There is no deadlock and no double lock. |
| V-FIX-E-5 | Info | F7 confirmed: `rev-parse` and the three `cat-file` calls run with fd 9 open and without `GIT_ALLOW_PROTOCOL`. |
| V-FIX-E-6 | Info | A refresh that the chain-id guard refuses still fills `/etc/telcoin/chain-configs/<net>` and refreshes the baseline. |
| V-FIX-E-7 | Info | Mainnet prompts and warns of a restart before a refusal it cannot avoid while the pins are empty. The intro wording is odd. |
| V-FIX-E-8 | Info | The "Nothing to refresh" test opens files owned by the service user as root. |
| V-FIX-E-9 | Info | Skew: the `edit-config.sh` of 01664cc with the new library still pulls and force-updates submodules in `/opt/telcoin-source` on testnet, then refuses. |

### V-FIX-E-1 (Medium): the no-checkout hint

- **Expected:** a node with no checkout and an empty pinned directory gets instructions that do the least possible: put the three files in place, then run menu 13 again.
- **Got:** the menu prints this hint (captured by the harness, `<P>` is the case prefix):
  `Re-run sudo ./setup-node.sh, which offers to clone the repository and reads them, or put genesis.yaml, committee.yaml and parameters.yaml from https://github.com/Telcoin-Association/telcoin-network/tree/v0.16.0-adiri/chain-configs/testnet/ into <P>/etc/telcoin/chain-configs/testnet (owned by root) and run this again.`
- **What `sudo ./setup-node.sh` does on an installed node** (from reading the code; I did not run it):
  - In interactive mode nothing refuses an installed node. Only `--json` keygen and finalize do (`json_refuse_installed`, `setup-node.sh:3391`), and `--host-baseline` alone short-cuts (`:3880`).
  - `main` runs the whole wizard again (`:3895-3905`). It asks for the data directory with the default `DEFAULT_DATA_DIR`, not the node's `DATA_DIR` (`:269`, `prompt_setup_path` `:1973`, `step_preflight` `:412`).
  - It writes `.node-meta` (`:2127`) and asks the network and install method. It offers "Overwrite existing keys?" (`:2179`, default keep), or makes new keys without asking when the chosen data dir has no `node-keys`.
  - It rewrites `node.env`, the start script and the unit from this run's answers (`:2779-2812`), then restarts the running node (guarded, `:2876-2885`).
  - Setup copies the chain configs into the data dir itself, so "run this again" afterwards only prints "Nothing to refresh".
  - On a node whose data dir is not the default, pressing Enter at the first prompt sets up a second node identity and points the unit at it. For a validator that is a real hazard.
- **Verdict:** the hint works, but it is disproportionate, and dangerous on a node with a non-default data dir. Its second half is right in substance, but the URL is a GitHub tree page. Downloading that URL gives HTML. The harness shows the pins then refuse it safely (`E8 hint B with a wrong file`).
- **Reproduction:** `bash tasks/verify-req/V-FIX-E/menu13_test.sh main` prints `E5/E8 no-checkout hint: ...`. The replacement hints below are the checks `E8 hint A`, `E8 hint A shallow`, `E8 hint A cloned as another user` (root) and `E8 hint B`.
- **Suggested fix:** replace the two hint lines. Both paths are tested in the harness against the local origin, as root in ubuntu:26.04:
  ```
  Clone the repository at that tag (as root), then run this again:
    sudo git clone --branch v0.16.0-adiri https://github.com/Telcoin-Association/telcoin-network.git /opt/telcoin-source
  or put the three files of that tag into /etc/telcoin/chain-configs/testnet (root, 0644):
    https://raw.githubusercontent.com/Telcoin-Association/telcoin-network/v0.16.0-adiri/chain-configs/testnet/{genesis,committee,parameters}.yaml
  ```
  Use `${TN_REPO}`, `${tag}`, `${source_dir}` and `${chain_config_src}` in place of the literals.
  - The clone line is the library's own "Manual clone" line (`_tn_chain_configs_clone`, `lib/common.sh:3343`).
  - The clone must be owned by root. A clone owned by another account is refused with "must be a directory owned by root (not a symlink); nothing was fetched." and no git runs.
  - `--depth 1` also works.
  - The raw URL follows the standard raw.githubusercontent.com form. I did not fetch it.

  The cleaner fix is to offer the clone in the menu itself: `confirm`, then `_tn_chain_configs_clone "$source_dir" "$tag"`, then the helper. That is the same https-only clone at the tag that setup uses. Add `_tn_chain_configs_clone` to `tn_require_fns`.

### V-FIX-E-2 (Low): "Nothing to refresh" after a deferred restart

- **Expected:** an operator who chose "restart later", or whose restart the committee check refused, and who opens menu 13 again learns that the files are in place and how to apply them.
- **Got:** `[OK] Nothing to refresh: the node's data dir already holds the testnet chain configs this script release pins (v0.16.0-adiri), so telcoin was not restarted.`
  It does not hint that the running node may still use the old files. Menu 14 does restart the node and resync the allowlist (`E2f menu 14 restarts and resyncs`), so the operator is not stuck. The "restart later" text from `apply_changes` is unchanged since 01664cc and names a bare `sudo systemctl restart telcoin`, which has no committee check and no epoch wait.
- **Reproduction:** see the `E2f` checks in `menu13_test.sh main`.
- **Suggested fix:** add one `print_info` line: `If ${TARGET_SERVICE} has not been restarted since these files were copied, use 14) Restart node.` Optionally compare the files' mtime with the unit's `ActiveEnterTimestamp`.

### V-FIX-E-3 (Low): the AIDE baseline is made twice

- **Expected:** one `aide --update` per refresh.
- **Got:** on a first install that ends with a successful restart, `tn_host_baseline_refresh` is called twice (`E1: host baseline refreshed (count)` = 2). The first call is after the install (`edit-config.sh:3843`), the second in `apply_changes` (`:2258`). With `HOST_BASELINE=true`, each call runs `aide --update` over the whole AIDE tree (`lib/common.sh:7057-7080`, by reading; the harness counts the calls). The `cmp` run against 01664cc shows the same +1 on the refused-restart and "restart later" paths, where it is the only call and is justified, because `/etc` changed.
- **Reproduction:** `menu13_test.sh main` (E1). For the comparison, `run_all.sh` writes `cmp.diff`.
- **Suggested fix:** set a flag after the install instead of refreshing at once. Call `edit_baseline_refresh` on the paths that return without `apply_changes`' successful restart (the guard refusals, a failed copy, "restart later", a refused or failed restart), and leave the success path to the refresh that `apply_changes` already does.

### V-FIX-E-4 (Low): lock held during the "Press Enter" prompt

- **Expected:** the update lock is released before the menu waits on the operator.
- **Got:**
  - The new helper-error path calls `edit_unlock` before its prompt, which is right.
  - The older returns after `menu_lock` (chain-id refusal, failed copy, missing files, pin mismatch, the mainnet refusal) return with the lock held: `E4a` and `E5 failed copy` show `true held`.
  - Each of those returns comes right after a `read -p "Press Enter..."`, so the lock stays held for as long as the prompt sits there. `update-node.sh`, including one started from the UI, is refused meanwhile with "Another update is already running".
  - There is no deadlock and no double lock: a `main_menu` session `13, Enter, 13, Enter, 14, Enter, 15` under `set -euo pipefail` exits 0, takes the lock three times and is never refused.
  - The behaviour is the same at 01664cc.
- **Reproduction:** `menu13_test.sh main`: `E4a: lock still held ...`, `E5 failed copy: lock still held ...`, `E5 session ...`.
- **Suggested fix:** call `edit_unlock` before each of those `Press Enter` prompts, as the new error path does.

### V-FIX-E-5 (Info): F7 confirmed

The fetch runs with `fd9=closed` and `GIT_ALLOW_PROTOCOL=https`. The `rev-parse` call and the three `cat-file` calls run with `fd9=open` and the variable unset (`E1: fd 9 open in rev-parse and the three cat-file calls only`). They are short-lived, local, read-only commands, and `tn_release_update_lock` frees the lock with `flock -u`, so I found no effect. Suggested fix: add `9>&-` to them for consistency.

### V-FIX-E-6 (Info): side effects of a refused refresh

When `NETWORK=testnet` and the node's genesis is chain 32285 (or 731), the pinned directory is filled from the tag and the baseline is refreshed. Only then does the chain-id guard refuse (`E4a: pinned dir was filled anyway`, `E4a: baseline refreshed on a refused run` = 1). The data dir is untouched and there is no restart. The files are root-owned pinned content, so the effect is harmless. Suggested fix, if wanted: compare the node's chain id with `TESTNET_CHAIN_ID` before the helper runs.

### V-FIX-E-7 (Info): mainnet prompts before an unavoidable refusal

Mainnet prints "This copies the mainnet chain configs ..., once this script release pins them." and "The node will be restarted ...", asks the confirm and takes the lock. It then refuses: `mainnet has no pinned sha256 for genesis.yaml yet ...` and `The chain configs in <P>/opt/telcoin-source/chain-configs/mainnet do not match the mainnet pins`. No git runs in any of the four variants. The flow has the same shape as at 01664cc. Suggested fix: when `tn_chain_config_pin mainnet genesis.yaml` is empty, refuse before the prompt.

### V-FIX-E-8 (Info): root reads data-dir files

The new `Nothing to refresh` test runs `sha256sum < "${node_data_dir}/${f}"` as root after a `-f` / `! -L` test of the last path component. Elsewhere the script reads data-dir files through the service user (`edit_backup_copy`: "root never opens a path that user controls"). Only a boolean comes out. A service user that races in a FIFO, or swaps `genesis/` for a symlink, can at most hang the menu or force "Nothing to refresh". I did not demonstrate this. The existing `tn_genesis_chain_id` read at `:3905` has the same pattern. Suggested fix: `tn_as_service_user sha256sum -- FILE`.

### V-FIX-E-9 (Info): E7 skew

- **New `edit-config.sh` with the 01664cc library:** it refuses up front with `[ERROR] lib/common.sh 2.2.1 is older than this edit-config.sh: run update-scripts.sh and try again.` and rc 1. With `--json` it prints the error and a `done ok:false` event. This is correct.
- **The 01664cc `edit-config.sh` (2.2.0) with the new library:**
  - Its guard accepts the library, and menu 13 runs on testnet.
  - Git ran `pull`, then `submodule sync --recursive`, `submodule update --init --recursive --force` and `submodule status`, all with fd 9 open. HEAD moved from the tag commit to `main`.
  - It then refused: `committee.yaml: sha256 83419f…, expected 009b6d7b…`, "Chain configs unchanged", no restart.
- **On testnet today:** every 2.2.0 menu 13 moves `/opt/telcoin-source` (a source install's build tree) to the tip of `main` and force-updates its submodules, then fails safe on the pins. That is the bug this round fixes; a partial update reaches it. No action beyond the release.

## Proved

| Item | Command and result |
|---|---|
| E1 | `menu13_test.sh main`, all `E1` checks, host and root. The three files are pinned and the pinned dir holds the tag's files (root 644, dir root 755 as root). HEAD, branch, `status --porcelain --untracked-files=all` and refs are unchanged on a dirty checkout sitting on the changed `main`. No pull/checkout/reset/merge/submodule/clone ran. There was exactly one `fetch --quiet --no-tags origin +refs/tags/v0.16.0-adiri:refs/tn-remote-tags/v0.16.0-adiri` with fd 9 closed and https only. One restart, one resync. The lock is held while the helper runs and is free at the end. `set -euo pipefail` reaches the end. |
| E2 | `E2a`-`E2f`. Pinned data dir: the message, no prompt, no lock taken, no git, no systemctl, no baseline, no resync, no pinned dir created; strict mode also passes. One stale file: prompt. A symlink to a pinned file: refreshed, and the symlink is replaced by a regular file. `parameters.yaml` missing: refreshed. A data dir with a space: both ways. Deferred restart: see V-FIX-E-2. |
| E3 | `E3a`-`E3d`: no git process with or without a checkout, or with the pinned dir filled by hand; refused while the pins are empty, data dir unchanged, no restart. |
| E4 | `E4a`-`E4d`: a node on chain 32285, a missing genesis, a genesis without a chain id, `NETWORK=testnet` with genesis 731, and `NETWORK=mainnet` with genesis 2017 are all refused, with the data dir unchanged. |
| E5 | Helper rc 1 (symlinked checkout) and rc 2 (no checkout; offline checkout without the tag) release the lock. Chain-id refusal and failed copy keep it until `main_menu` (V-FIX-E-4). A cancelled confirm never takes it. Success releases it. A second process holding the lock gives `[ERROR] an update is in progress (PID n); try again when it has finished`, with no git run. The `main_menu` session 13,13,14,15 exits 0. |
| E6 | `tools/tests/edit_backup_test.sh` and `edit_config_resync_test.sh`, unedited, pass on the host (13 checks/0 failed/6 skipped as non-root, 35/0/0) and in ubuntu:26.04 (57/0/0, 35/0/0). In the `cmp` suite, the committee-refused, "restart later" and success transcripts are identical between the 01664cc tree and the tip, except `baseline=+1` (V-FIX-E-3). |
| E7 | V-FIX-E-9, from `run_all.sh` (`e7a-*.txt`, `docker-oldscript.txt`). |
| E8 | Hint A: `git clone --branch TAG`, and the same with `--depth 1`, work; a clone owned by another account is refused (root). Hint B: hand-copied files work with no git, and the baseline is refreshed only by the restart; an HTML file is refused. A pinned dir left by another release's pins is replaced from the tag. A current pinned dir with the checkout on the changed `main` means no git and the checkout is unchanged. `set -e`/`-u`: the strict runs and the menu session pass. UI: no file under `ui/` (tests aside) calls `refresh_chain_configs` or advertises a chain-config refresh; the helper drives `edit-config.sh` only through `--json --set` and `--migrate-credential`. `--set`/`--json`: no field reaches menu 13. |
| Gates | Both `*.sh` files have a shebang and pass `shellcheck --severity=error`, `bash -n` under bash 5.3 and in `bash:3.2` (3.2.57), and `bash tools/check-bash32.sh` (clean, 2 files). In `bash:3.2` the harness prints `SKIP menu 13 suites (git absent)`. |

Run: `bash tasks/verify-req/V-FIX-E/run_all.sh /var/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/46275ae3-5cf9-4f35-b799-c09950443243/scratchpad/v-fix-e/run-1`.
Results:
- host main: 65 checks, 0 failures, 1 skipped (the chown case, not root)
- ubuntu:26.04 main: 68 checks, 0 failures, 0 skipped
- `cmp` new and old: rc 0; `oldscript`: 2/0/0

All outputs are in that directory. No root-owned file is in the worktree (`find -user root` is empty).

## Not proved

- A real `aide --update`: the baseline refresh is a stub that counts calls. That each call runs `aide --update` comes from reading `lib/common.sh:7057-7080`.
- What an interactive `setup-node.sh` re-run does on an installed node (V-FIX-E-1) comes from reading the code. I did not run it.
- Network paths (github.com, raw.githubusercontent.com): only a local bare origin was used.
- The real epoch wait, committee check and systemd restart: stubs, with `NO_EPOCH_WAIT=true`.
- bash 3.2 at runtime: the `bash:3.2` image has no git, so the harness skips. Only syntax and `check-bash32` were checked. macOS/BSD was not run.
- On the host, root writes and `tn_as_service_user` were stand-ins. Their real behaviour was proved only in ubuntu:26.04 as root.
- The FIFO and symlink race of V-FIX-E-8 was not demonstrated.
- Not reported as a finding: `OPERATOR.md:1057` still says menu 13 "Pulls the current genesis ...". Docs are wave 3 (spec section 5).
