# V-DOC-REF report: the documents against the frozen code (tip 2d91fa8)

Scope: `git diff 7a686dc..HEAD -- '*.md' '*.yaml'` (16 files) on `req/v-doc-ref`, checked against the code at this tip (frozen at 7a686dc), against `scripts-v2.1.0` where a document describes the old scripts, against `tasks/spec-req-shared.md` sections 1, 3.1, 4, 5, 6.3 and 7, and against the V-CHAIN, V-AWS, V-FIX-S, V-FIX-E and V-HW-UI reports. Read-only: no tracked file was edited. The writers' checkpoints were read only after sections R1 to R8 were done; they changed nothing below.

Harness: `tasks/verify-req/V-DOC-REF/hw_examples.sh` runs the real `check_hardware` on stub `lscpu`/`df` and meminfo fixtures for the hosts the documents quote. It passes `shellcheck --severity=error` and `tools/check-bash32.sh`. One-off checks (an anchor resolver, a table column counter, a `git pull` on a detached checkout) ran from the session scratch directory and are described where they are used.

No High finding. One Medium, seven Low, four Info.

## Findings

| Id | Severity | File:line | One line |
|---|---|---|---|
| VD-1 | Medium | `README.md:2197`, `CHANGELOG/scripts-v2.2.0.md:216-218` | Old menu 13's `git pull` is said to have moved a source install's build tree; a source checkout is detached, so that pull failed and moved nothing |
| VD-2 | Low | `OPERATOR.md:275` | Step 10's search order puts `/etc/telcoin/chain-configs/<network>/` before the checkout on every network; only on testnet |
| VD-3 | Low | `OPERATOR.md:327` | The `/opt/telcoin-source/` row says setup and menu 13 never pull it; on devnet both still do |
| VD-4 | Low | `OPERATOR.md:2726` | "the rows below cover each one": several causes the library prints have no row |
| VD-5 | Low | `OPERATOR.md:273` | Step 8 describes the chain configs before the node-flag check; the code runs the node-flag check first |
| VD-6 | Low | `README.md:1629` | "the mainnet tiers once mainnet is picked": the preflight shows them only after going back to step 1 |
| VD-7 | Low | `CHANGELOG.md:60`, `CHANGELOG/scripts-v2.2.0.md:18-19`, `README.md:2204` | The failing installs are "Docker and signed-release"; existing-binary installs failed the same way |
| VD-8 | Low | `CHANGELOG.md:31` (vs `:42`, `:58`) | The Unreleased headings mix landing versions and tip versions, and two names for the UI |
| VD-9 | Info | `README.md:255-257`, `mno-node-guide.md:664-666` (vs `OPERATOR.md:786-788`) | AWS behaviour V-AWS calls inferred is stated as fact in README and the guide, as expectation in OPERATOR.md |
| VD-10 | Info | `lib/common.sh:9240` | `Could not reach origin` is still printed (source-build tag check); spec 7.1 says it is gone everywhere. No document is wrong |
| VD-11 | Info | `OPERATOR.md:2725` | The scripts-v2.1.0 fix says "run update-scripts.sh, then setup again", which helps only once scripts-v2.2.0 is published |
| VD-12 | Info | `README.md:143` | The example `(have 350 GB disk)`: a 350 GiB disk reads 369 GB in that line |

### VD-1 (Medium): old menu 13 did not move a source install's build tree

**Written:**
- `README.md:2197` (edit-config v2.2.1 entry): "Menu 13 ran `git pull` in the telcoin-network checkout and copied the default branch's files: on testnet the pull moved a source install's build tree, and the copy was then refused because those files no longer match the pins."
- `CHANGELOG/scripts-v2.2.0.md:216-218` (edit-config 2.2.2): "Menu 13, "Refresh chain configs", ran `git pull` in the repository checkout and copied `chain-configs/<network>` from its default branch. On testnet the pull moved a source install's build tree, and the copy was then refused because the default branch no longer matches the pins."

**Code:**
- Old menu 13 runs `if ! git -C "$source_dir" pull; then print_error "git pull failed in ${source_dir}. Chain configs unchanged."` (`git show scripts-v2.1.0:edit-config.sh`, line 3600; the same at 01664cc:3771). No checkout or switch runs before it.
- A source install's checkout is detached at the release tag: `lib/common.sh:9283` runs `git -C "$dir" -c advice.detachedHead=false checkout --quiet --detach "refs/tags/${tag}^{commit}"`. The same holds in scripts-v2.1.0 (`tn_source_checkout_tag`).
- `git pull` on a detached HEAD exits 1 and moves nothing. I ran it with git 2.53.0 in scratch `gitexp1/`: a clone checked out `--detach` at a tag, then `git -C src pull`, prints "You are not currently on a branch." with rc 1, and HEAD is unchanged. A `clone --branch <tag>` behaves the same.
- So on a source install the old menu stopped with `git pull failed in /opt/telcoin-source. Chain configs unchanged.`. That is what README, OPERATOR.md and the guide said before this round.
- The pull did move a checkout that is on a branch: the default-branch clone that scripts-v2.1.0 setup made for a Docker, signed-release or existing-binary install.
- V-FIX-E-9's "HEAD moved from the tag commit to `main`" used such a branch checkout (`menu13_test.sh:523`, `checkout -q -B main "$TAGC"`).

**Proposed** (`README.md:2197`): "Menu 13 ran `git pull` in the telcoin-network checkout and copied its files. On a source install, whose checkout is detached at a release tag, the pull failed (`git pull failed in /opt/telcoin-source. Chain configs unchanged.`); on the default-branch clone setup made for other installs, it moved the checkout to the branch's tip, and the copy was then refused because those files no longer match the pins."

**Proposed** (`CHANGELOG/scripts-v2.2.0.md:216-218`): "Menu 13, "Refresh chain configs", ran `git pull` in the repository checkout and copied `chain-configs/<network>` from it. On a source install, whose checkout is detached at a release tag, the pull failed and the menu stopped; on the default-branch clone setup makes for other installs, the pull moved the checkout to the branch's tip, and the copy was then refused because that branch no longer matches the pins."

`AGENTS.md:129` ("so a source install's build tree stays where it is") states the new rule and is correct as written.

### VD-2 (Low): step 10's search order holds on testnet only

**Written** (`OPERATOR.md:275`): "It looks for them in the `--genesis-dir` directory when you gave one, then in `/etc/telcoin/chain-configs/<network>/`, then in the checkout."

**Code** (`setup-node.sh:2369-2379`):
- The pinned directory is added second only when `tn_chain_configs_tag` prints a tag, which is testnet today.
- On devnet, and on mainnet without a tag, the order is `--genesis-dir`, `${TN_SOURCE_DIR}/chain-configs/<net>`, `/opt/telcoin-source/chain-configs/<net>`, `${CONFIG_DIR}/chain-configs/<net>`. The checkout comes first.
- README (`:850`, "then on testnet `/etc/telcoin/chain-configs/testnet/`") has it right.

**Proposed:** "It looks for them in the `--genesis-dir` directory when you gave one, then, on testnet, in `/etc/telcoin/chain-configs/testnet/`, then in the checkout, and last in `/etc/telcoin/chain-configs/<network>/` on a network without a pinned tag."

### VD-3 (Low): the checkout row leaves out devnet

**Written** (`OPERATOR.md:327`, `/opt/telcoin-source/`): "...or the clone setup made at the pinned tag for the chain configs. ... Setup and `13) Refresh chain configs` fetch the pinned tag into `refs/tn-remote-tags/<tag>` and read the files from there: they never pull it or check anything out."

**Code:**
- On devnet, setup pulls (`lib/common.sh:3422`, `git -C "$source_dir" pull --ff-only`) or clones the default branch with submodules (`:3353`).
- Menu 13 pulls on devnet (`edit-config.sh:3945`).
- README's row (`README.md:867`) says "(at the pinned chain-config tag; on devnet, the default branch)".

**Proposed:** "...or the clone setup made for the chain configs (at the pinned tag; on devnet, the default branch). ... On testnet, setup and `13) Refresh chain configs` fetch the pinned tag into `refs/tn-remote-tags/<tag>` and read the files from there: they never pull it or check anything out. On devnet both still pull its default branch."

### VD-4 (Low): not every cause has a troubleshooting row

**Written** (`OPERATOR.md:2726`): "The warning above the line names the cause, and the rows below cover each one."

**Code:** these causes have no row in section 9:
- `Git cannot read the repository in <dir> (<reason>); nothing was installed.` (`lib/common.sh:7452`, rc 1)
- `The testnet chain configs at v0.16.0-adiri do not match the pins; nothing was installed.` (`:7489`, rc 1)
- `v0.16.0-adiri has no chain-configs/testnet/<file>.` (`:7476`)
- `Could not read chain-configs/testnet/<file> at v0.16.0-adiri (...); nothing was installed.` (`:7474`)
- `Could not make a staging directory for the testnet chain configs.` (`:7464`)
- `Could not install the testnet chain configs from v0.16.0-adiri into <dest> (see above).` (`:7492`)
- `Clone failed. Check your internet connection.` (`:3361`)

**Proposed:** "The warning above the line names the cause; the rows below cover the common ones."

### VD-5 (Low): step 8 runs the node-flag check before the chain configs

**Written** (`OPERATOR.md:273`): "...creates the `telcoin-log` group for log readers. Next it puts the chain configs in `/etc/telcoin/chain-configs/<network>/` ... If you passed node flags (section 2.7), setup asks the installed release here whether it has them, and stops before any key is made if it does not."

**Code** (`setup-node.sh:2141-2151`): `verify_binary`, then `prepare_node_extra_flags`, then `ensure_chain_configs_available`. A refused flag stops setup before the chain configs. The guide (`mno-node-guide.md`, step 8) has the code's order.

**Proposed:** move the sentence "If you passed node flags (section 2.7), setup asks the installed release here whether it has them, and stops before any key is made if it does not." in front of "Next it puts the chain configs ...", and start the chain-config part with "Then it puts".

### VD-6 (Low): the wizard shows the mainnet tiers only after going back

**Written** (`README.md:1629`): "The setup wizard's preflight judges the hardware tiers of the wizard's network, the tables in [Hardware](#hardware): the mainnet tiers once mainnet is picked, the testnet tiers otherwise, and going back to the preflight step after picking a network fetches them again."

**Code:**
- The preflight is wizard step 1 and the network is step 2.
- `stepPreflight` sends the network only when step 1 is rendered (`ui/static/index.html`, spec 3.5; V-HW-UI F9; `followup.md:124-127` records it).
- An operator who picks mainnet and goes forward never sees the mainnet tiers. OPERATOR.md 4.5 says this correctly.

**Proposed:** "The setup wizard's preflight judges the hardware tiers of the wizard's network, the tables in [Hardware](#hardware). It comes before the Network step, so it shows the testnet tiers until you pick another network and go back to it, which fetches that network's tiers."

### VD-7 (Low): existing-binary installs failed too

**Written:**
- `CHANGELOG.md:60`: "Fresh testnet Docker and signed-release installs have failed at keygen since 2026-11-14."
- The same pair of install methods appears at `CHANGELOG/scripts-v2.2.0.md:18-19` and `README.md:2204` (lib/common v2.2.2).

**Code** (`git show scripts-v2.1.0:lib/common.sh`, `ensure_chain_configs_available`, lines 3277-3310; called for every install method at `setup-node.sh:2141` of that tag):
- Any host without `/opt/telcoin-source/.git` gets the consent prompt and `git clone --recurse-submodules` of the default branch, whose `committee.yaml` fails the pins.
- An "I already have it" install has no checkout, so it failed the same way.
- A source install did not fail: its checkout is detached at the build tag, the `pull --ff-only` fails quietly, and the tag's files match.
- OPERATOR.md's troubleshooting row (`:2725`) places the stop "at step 4 of 8, before any key was made". "Failed at keygen" can be misread against that; in the UI, the step-4 failure falls in the keygen phase.

**Proposed:** "Fresh testnet Docker, signed-release and existing-binary installs have failed since 2026-11-14, at step 4 of 8, before any key is made." Use the same install list in the other two places.

### VD-8 (Low): the Unreleased headings mix version conventions

**Written:**
- `CHANGELOG.md:31`: "### Mainnet chain id 731, November 2026 -- lib/common 2.2.4, check-node 2.2.1, update-node 2.1.1, telcoin-ui 2.1.2, install-caddy 2.2.1".
- `:42` and `:58` name the tip versions (lib/common 2.2.5, setup-node 2.1.4, Node Manager UI 2.1.3, edit-config 2.2.2), although the hardware change itself landed in lib/common 2.2.3, setup-node 2.1.3 and telcoin-ui 2.1.1.

**Code:**
- The constants are `COMMON_VERSION` 2.2.5 (`lib/common.sh:82`), update-node 2.1.2 (`update-node.sh:115`) and `UI_VERSION` 2.1.3 (`ui/server.py:78`).
- So one heading reads as stale next to the other two.
- The UI is "telcoin-ui" in one heading and "Node Manager UI" in the next.

**Proposed** (`:31`): "### Mainnet chain id 731, November 2026 -- lib/common 2.2.5, check-node 2.2.1, update-node 2.1.2, Node Manager UI 2.1.3, install-caddy 2.2.1". Keep the body's "(lib/common 2.2.4)" and "(telcoin-ui 2.1.2)" as the versions the change came in.

### VD-9 (Info): AWS inferences worded two ways

- `OPERATOR.md:786-788` writes the update behaviour as expectation: "expect an update to try to replace the instance", "Expect that change to land before the failure", "expect a `Validator` stack's update to stop and start".
- `README.md:255-257` and `mno-node-guide.md:664-666` state the same as fact, in F10's wording.
- V-AWS (`REPORT.md`, "Not proved"): "The update order (DataVolume before NodeInstance) and the stop/start for c7i.8xlarge → c7i.2xlarge are inferred from the dependency and the documented rules, not observed."
- Nothing documented contradicts them, so R8 passes; only the two styles differ.

**Proposed** (optional):
- README `:255`: "Once a newer image is out, expect the update to try to replace the instance, fail because the old instance holds the network interface, and roll back."
- `:256`: "Expect the volume's IOPS change to be made before that failure, so that the rollback waits ..."
- `:257`: "If the image has not changed, expect a `Validator` stack's update to stop and start the instance ..."
- The guide's `:664-666` likewise.

### VD-10 (Info): "Could not reach origin" is still in the code

- `lib/common.sh:9240` (`tn_source_checkout_tag`, the source build's tag check) still runs `_tn_c4_say warn "Could not reach origin; using the local tag ${tag} (not compared with origin's)." "$fn"`.
- Spec 7.1 says "`Could not reach origin` is no longer printed anywhere". That is true of the chain-config helpers only.
- No document claims more: `README.md:2141` scopes the replacement to those helpers, and no document quotes the source-build line.
- Recorded so that a later sweep does not "fix" a true quote, or the code, on the strength of that sentence.

### VD-11 (Info): the scripts-v2.1.0 row depends on the release

**Written** (`OPERATOR.md:2725`, fix column): "Run `bash ~/telcoin-node-scripts/update-scripts.sh`, then run setup again: these scripts read the files at the pinned tag."

**Why it matters:**
- Until `scripts-v2.2.0` is published, `update-scripts.sh` installs `scripts-v2.1.0` again, and the next setup fails the same way.
- The row's `--genesis-dir` alternative works today. Checked against `scripts-v2.1.0`: `ensure_chain_configs_available` checks `TN_GENESIS_DIR` instead of the checkout, and `step_write_config` searches it first.

**Proposed:** "Once `scripts-v2.2.0` is out, run `bash ~/telcoin-node-scripts/update-scripts.sh`, then run setup again: those scripts read the files at the pinned tag. Until then, or on a host that stays on scripts-v2.1.0, run setup with `--genesis-dir <dir>` ..."

### VD-12 (Info): the "have" figure of the disk example

- `README.md:143` gives the example "such as `needs ≥ 2 TB disk (have 350 GB disk)`".
- The "have" value is the filesystem's `df` total in decimal GB (`lib/common.sh:2330`). On the reference host, a 350 GiB pd-ssd, it reads `(have 369 GB disk)`: `hw_examples.sh`, case "c3-highcpu-8, mainnet"; V-AWS A4 gives 350 GiB ext4 → 368.8 GB.
- The format is right, the sentence says "such as", and spec 7.1 uses the same example.
- No change is needed; `(have 369 GB disk)` would match the testnet machine exactly.

## What was checked and found sound

### R1. Quoted messages, names and flags (about 55 quotes, about 30 names)

Each was found in the code at this tip, printed under the condition the document gives.

**Library chain-config messages** (`lib/common.sh:7409-7510`, `:3305-3449`):
- `Could not fetch <tag> from origin (<git's reason>); reading the <network> chain configs from the local copy of <tag>.`
- `Could not fetch tag <tag> from origin (...), and the checkout does not have it.`
- `<dir> must be a directory owned by root (not a symlink); nothing was fetched.` (`$(id -un)` is root on a host)
- `<dir> exists but is not a git checkout; move it aside first.`
- `<dir> must be a directory, not a symlink or a file; ...`
- `<dir>/<file> is a symlink or not a regular file; ...`
- `Reinstalled the <network> chain configs in <dir> root-owned, directories 0755 and files 0644: ...`
- `Clone the repository now to get the chain-config files?`
- The parenthesised git reason is absent when git printed nothing (`${why:+ (${why})}`); the documents' placeholder form is fine.

**setup** (`setup-node.sh:2151-2156`, `:2397-2400`):
- `The <network> chain configs were refused (see above); nothing was copied.` (rc 1) and `Could not get the <network> chain configs (see above).` (rc 2).
- The four-line hint with `tree/<tag>/chain-configs/<net>/`, the copy target and `--genesis-dir`, and the `--json` stop.
- The scripts-v2.1.0 message `... are not the pinned ones ...` appears only where a document says it is the old scripts' (OPERATOR.md:2725) or in history (README.md:2149). `git show scripts-v2.1.0:setup-node.sh:2141` confirms it, and that it is step 4, before keygen.

**Menu 13** (`edit-config.sh:3746-4033`):
- `Nothing to refresh: ... (<tag>), so <service> was not restarted.` and the `14) Restart node` line.
- `This script release pins no <network> chain configs yet, so there is nothing to install. Chain configs unchanged.`
- `The pinned <network> chain configs (<tag>) were not installed / could not be installed (see above). Chain configs unchanged.`
- `Clone the repository at <tag> into <dir> now?`
- `sudo git clone --branch <tag> <TN_REPO> <dir>`, with TN_REPO `https://github.com/Telcoin-Association/telcoin-network.git` (`lib/common.sh:117`), and the three raw URLs.
- `git pull failed in <dir>. Chain configs unchanged.` (devnet only).
- `The chain configs in <dir> do not match the <network> pins (see above). Chain configs unchanged.`
- The menu label `13) Refresh chain configs   (pinned genesis/committee/parameters)` (`:4104`).
- The update lock is free at every "Press Enter", including in `apply_changes` (`:2228-2272`).

**Hardware check** (run with `hw_examples.sh`):
- `[OK] Validator (minimum): meets minimum (3 cores (6 vCPU) / 16 GB / 350 GB)` on testnet.
- `[WARN] Validator (minimum): below minimum — needs ≥ 8 cores (16 vCPU) (have 4 physical cores)` for a 4-core, 32 GiB, 2 TB host on mainnet (OPERATOR.md 1.1).
- `needs ≥ 2 TB disk (have ... GB disk)`.
- `Detected: 4 physical cores ...` and `8 logical CPUs`, the logical-CPU note, `Comparing with the testnet hardware tiers.`, and F2.

**UI** (`ui/static/index.html:3619-3674`, `ui/server.py:5190-5330`):
- `Detected 8 logical CPUs / ...`.
- `Physical cores could not be counted, so the tiers are compared with logical CPUs; ...`: the page's own wording, without the shell's "below", as README.md:1632 quotes it.
- `Compared with the <network> hardware tiers.`
- `cpu_kind`, `ecc` and `network` in the reply, the exact core compare, and the decimal-GB disk floor.

**install-caddy** (`install-caddy.sh:2486-2522`, `lib/common.sh:3267`):
- `The network of this node cannot be told (no NETWORK in .node-meta, and the chain id of <datadir>/genesis/genesis.yaml (487) is neither 731 nor 2017), so this run cannot confirm ...`
- `; https://rpc.telcoin.network does not answer with chain 731, so the stake was not read there`.
- The old `no readable genesis chain id` (01664cc:2489).
- `_tn_rpc_chain_is` in its required functions (`:3894`).

**Other scripts and the page:**
- check-node (`:1392`) and prepare-stake (`:864`): `serves chain 2017 (testnet), not chain 731 (mainnet)`.
- `select_network`: `2) Mainnet (Chain ID: 731)`.
- The heartbeat: `wrong chain: rpc reports <n>, expected <n>` (`lib/tn-heartbeat.sh:618`).
- The UI tooltip: `· chain id <n>` (`index.html:4213`).

**Upstream strings** in followup.md (`node build: faucet=<bool> ...`, `--allow-faucet-on-chain`, `TN_ALLOW_FAUCET_ON_CHAIN`) match V-CHAIN C1.

**Names, all found:**
- Constants: `MAINNET_CHAIN_CONFIGS_TAG`, `TESTNET_CHAIN_CONFIGS_TAG`, the six `*_SHA256` pins, `HW_TIERS`, `HW_VALIDATOR_RECOMMENDED`, `NETWORKS`, `NETWORK_PUBLIC_RPC`, `MAINNET_RPC_URL`, `ALERTS_CHAIN_ID`.
- Library functions: `tn_chain_config_pin`, `tn_chain_configs_{tag,dir,from_tag,check}`, `_tn_chain_configs_{dest_ok,clone_target,clone,in_place}`, `tn_genesis_chain_id`, `tn_detect_network`, `alerts_write_env`, `_gw_chain_fits`.
- Script functions: both `tn_require_fns` lists, `refresh_chain_configs`, `apply_changes`, `verify_consensus_participation`, `run_streamed`, and the page's `setSetupNetwork`.
- Tests: the three test files AGENTS.md names, and `ui/test_hw_mirror.py`.

### R2. Behaviour claims

Apart from VD-1 to VD-7, these claims are true of the code:
- **When the hardware check runs:** after `select_network` and `check_internet` (`setup-node.sh:446-452`).
- **Which table it uses:** devnet gets the testnet table; an empty or unknown network gets the mainnet table.
- **"In place":** root, 0755/0644 (`_tn_chain_configs_in_place`). Right files with another owner or modes are reinstalled without git.
- **The clone prompt:** only with no checkout and no pinned files, and only after `_tn_chain_configs_dest_ok` and `_tn_chain_configs_clone_target`. Declined, it returns rc 0 and setup shows the step-6 hint.
- **`--genesis-dir`:** no git, no prompt, pins checked. The workaround also works with scripts-v2.1.0.
- **Offline:** the fallback order is an earlier `refs/tn-remote-tags` fetch, then `refs/tags`.
- **Mainnet:** no git, refused while the pins are empty; menu 13 refuses it before its prompt.
- **Devnet:** pull or clone of the default branch, files unchecked.
- **Menu 13:** "Nothing to refresh" comes before any prompt, lock or restart; otherwise it copies the files and `apply_changes` asks about the restart.
- **The Caddy gate's order:** `.node-meta`, then the genesis, then the local stake, then the public RPC only on chain 731.
- **The UI preflight:** `network_rule(...) or "testnet"`.
- **remove-node:** removes `/etc/telcoin` with `chain-configs` on the unified layout (`_rm_config_dir`) and leaves it on a role layout (`followup.md:636`).

### R3. Figures

- **The eight hardware tables** (testnet and mainnet in README.md, OPERATOR.md and the guide; each one-pager's own) are identical to spec 3.1, cell for cell and row for row: 44 data rows, by `diff` against the spec's lines.
- **Fixed strings:** F2 is verbatim in all five documents that carry it (and in `lib/common.sh:2493` and the UI). F5 is verbatim three times, and F6 three times (lines joined).
- **CPU format:** `git grep -n -E '[0-9]+ vCPU \([0-9]+ cores?\)'` over `*.md`/`*.yaml` outside `tasks/` finds no hit. Every CPU figure in the added lines is `N cores (2N vCPU)`, or the vCPU count of a machine (F6, the "8 vCPU instance" sentences).
- **Constants:** `HW_TESTNET_*`/`HW_MAINNET_*` (`lib/common.sh:96-103`) and `HW_TIERS` match the tables and the release note's tier table.
- **AWS:** `aws/node.yaml` presets, `DataVolumeSize` (default 500, allowed 350/500/2000/4000), `Iops: 15000` and `Throughput: 300` match F9 and every document.
- **AWS limits:** 12,000 IOPS / 312.5 MB/s / 30 minutes at least once every 24 hours; gp3 3,000 IOPS / 125 MiB/s; four modifications in 24 hours. These match spec section 1 and V-AWS-3.
- **Chain ids and dates:** 731 = `0x2db`, 2017 = `0x7e1`, 32285 = `0x7e1d`; #1716 on 2026-11-12; 2026-11-14.
- **Benchmark figures:** as in spec section 1.
- About 70 figures outside the tables in all.

### R4. Changelog and versions

- **Constants at the tip:** lib/common 2.2.5, setup-node 2.1.4, edit-config 2.2.2, check-node 2.2.1, update-node 2.1.2, install-caddy 2.2.1, telcoin-ui 2.1.3. Untouched: update-scripts 2.2.0, setup-gateway 2.2.0, firewall-setup 2.2.0, remove-node 2.2.0, prepare-stake 2.0.0, install-ui 2.1.0 and the rest.
- **README:** 17 new entries (lines 2120-2214), newest first by commit (adf7ee0 ... f355768), each script's versions descending, and each script's newest entry equal to its constant. `git diff 01664cc..HEAD -- README.md` at and below the old `## Changelog` line (2044) is one insertion hunk with no removed line.
- **`CHANGELOG/scripts-v2.2.0.md`:** one `###` heading per script at its final version (install-caddy 2.2.1, edit-config 2.2.2, check-node 2.2.1, update-node 2.1.2, setup-node 2.1.4, lib/common 2.2.5, Node Manager UI 2.1.3, AWS one-click stack). Its version table matches the constants.
- **Released notes:** `CHANGELOG/scripts-v2.0.0.md`, `scripts-v2.1.0.md` and `v0.16.0-adiri.md` have no diff from 01664cc. `CHANGELOG.md` has one insertion hunk and no removed line. Every pre-existing README entry is unchanged.
- **Entries against their commits** (`git show --stat` of the twelve commits): sound apart from VD-1, VD-7 and VD-8.
- **Partner versions:** guide 1.13 and one-pagers 1.3, November 2026, in the three `metadata.yaml` files and in `CHANGELOG.md`. The technical specification stays 1.3. AGENTS.md states no version.

### R5. Surviving old text

**The first sweep's hits outside code and tests are all allowed:**
- `CHANGELOG.md:53`, `CHANGELOG/scripts-v2.2.0.md:397` and `:400`, `README.md:2141`, `:2149` and `:2175`: new entries saying what it was.
- `OPERATOR.md:2725`: the old scripts' message, quoted on purpose.
- `README.md:1244`: devnet's `git pull failed`, which `edit-config.sh:3946` still prints.
- Code and test hits are not documents (`lib/common.sh:9240` is VD-10).

**The `487|0x1e7|1e7` sweep: 25 hits, all allowed:**
- "Moved from 487" in the new entries: CHANGELOG.md, the release note, README 2121-2172, followup.md:139.
- Released history: CHANGELOG.md:442, README.md:3559.
- Devnet or unknown-chain examples: OPERATOR.md:2182, followup.md:349-350, :468-469, :722.

**V-CHAIN C5, row by row:**
- **RM:** RM-1 to RM-4 done as specified (the optional RM-4 was taken); RM-5 kept; RM-6 added (four entries).
- **OP:** OP-1 to OP-5 done; OP-6 and OP-7 kept.
- **GD:** GD-1 to GD-3 done; GD-4 kept; GD-5 is 1.13.
- **MP:** MP-1 done; MP-2 is 1.3.
- **TP-1 and TS-1:** kept.
- **FU:** FU-1 verbatim; FU-2 merged into FU-3, and FU-3 verbatim; FU-4 and FU-5 done; FU-6 kept.
- **CL:**
  - CL-1 kept.
  - CL-2 added. It also names install-caddy 2.2.1, which is right: adf7ee0 is the chain-731 gate.
  - CL-3 added under lib/common, check-node, update-node and the UI.
  - CL-4 unchanged.
- **OT-1:** unchanged.
- Not done: none.

### R6. Ubuntu 26.04

- **Counts:** lines naming 26.04, base → tip: README 9 → 9, OPERATOR 8 → 8, guide 5 → 5, testnet one-pager 1 → 1, mainnet one-pager 1 → 1, `aws/node.yaml` 4 → 4, `lib/common.sh` 4 → 4, `setup-node.sh` 1 → 1.
- **Removed lines that name Ubuntu:**
  - The old AWS parameter and stack lines, each replaced by a line that keeps its 26.04.
  - The two "rolls back unchanged" sentences.
- None of them states or weakens the recommendation.

### R7. Consistency and structure

- **Headings:** per file, the only added or renamed headings are:
  - the new README changelog entries;
  - the four new CHANGELOG.md entries;
  - AGENTS.md's `## Chain configs`;
  - the release note's per-script headings at their new versions, plus `update-node 2.1.2`, `Node Manager UI 2.1.3` and `AWS one-click stack`.
- OPERATOR.md, the guide and the one-pagers keep every heading.
- **Links:** the 32 links on added lines resolve to a heading slug. They include README's and OPERATOR.md's, the release note's links into OPERATOR.md and to its own `#libcommon-225`/`#aws-one-click-stack`, and the guide's cross-references. No link points at a renamed release-note heading.
- **Tables:** every row of every table in the ten changed Markdown files has its header's column count (96 tables, 0 bad rows).
- **"legacy":** none in the guide, the one-pagers or their metadata.
- **Private repositories:** the added lines name only `telcoin-network`, `tn-node-deployment` (implicitly), `tn-partner-site` and the image packages. There is no `/home` path and no private repository; spec 7.2's last item was rightly left out of followup.md.
- **Same fact in several documents:** README, OPERATOR.md and the guide agree in substance on:
  - menu 13;
  - the hardware check (F7);
  - the walkthrough order (F11);
  - the troubleshooting row (F8);
  - the chain-config flow;
  - the AWS advice (F9, F10).
- The exceptions are VD-2, VD-3, VD-5, VD-6 and the wording difference of VD-9.

### R8. followup.md and the "do not" statements

**Every item of spec 7.2 is present, in a fitting section, and matches its source:**
- the upstream hardware page;
- V-HW-UI F9 and F10;
- V-FIX-E-3, and V-FIX-E-8: the chain-id guard reads as root, the "Nothing to refresh" test through the service user (`edit-config.sh:3800`, `:4004`);
- V-FIX-S-06 with V-FIX-E-9;
- V-FIX-S-13;
- FIX-T F2;
- V-FIX-S-12 (`setup-node.sh:3348-3352`);
- V-AWS-7 and V-AWS-4;
- V-CHAIN VC-5, VC-6 and VC-7.

**Other followup.md checks:**
- The U-3/U-5 item no longer says "open" or `_487`.
- The devnet `refresh_chain_configs` item now says testnet reads the tag.
- No closed item is listed as open; for example, `tn_sync_submodules` still lacks `9>&-` (`lib/common.sh:3296`).

**"Does not" statements, all true of the code:**
- `check_hardware` measures only cores, MemTotal and the filesystem size: no ECC, NVMe, IOPS or throughput.
- No pull, checkout, reset or submodule command runs on the testnet path. `_tn_chain_configs_git` runs only fetch, rev-parse, cat-file, ls-tree and clone.
- No snapshot in `aws/` (`:280`).
- Nothing grows a filesystem: no `resize2fs`, `growpart` or `xfs_growfs` outside documents.
- The scripts check neither swap, time sync, the filesystem type nor QLC.

**AWS:** nothing documented contradicts the statements V-AWS calls inferred (VD-9 covers the wording).

## Not reached

- The PDFs, which belong to another verifier.
- Behaviour on a real host or a real AWS stack. The AWS statements were checked against V-AWS, not by launching a stack. The chain-config and menu-13 behaviour was read from the code and the fixtures' expected output, not re-run in containers. The hardware check was run.
