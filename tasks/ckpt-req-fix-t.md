# FIX-T checkpoint

status: done

Sections:
- [x] A expectations (written from spec 2.1 / 2.4 before reading the bodies)
- [x] B test file (tools/tests/chain_configs_tag_test.sh, 110 checks)
- [x] C first run and findings (no spec/code mismatch)
- [x] D attacks
- [x] gates

## A. Expectations (from spec 2.1 and 2.4 only)

Notation: FT = `tn_chain_configs_from_tag DIR NET [fn]`; EN = `ensure_chain_configs_available [NET] [fn]`;
D = `tn_chain_configs_dir testnet` = `${TN_ROOT_PREFIX}/etc/telcoin/chain-configs/testnet`; TAG = v0.16.0-adiri.
Messages through a progress fn arrive as `KIND|MSG`. "no git" = the PATH git logger records nothing.

Printers (rc 0 always):
- E1 tag testnet = TAG; mainnet = ""; devnet = ""; garbage = ""; empty = "".
- E2 dir testnet = `${PFX}/etc/telcoin/chain-configs/testnet`; with CONFIG_DIR=/etc/alt -> `${PFX}/etc/alt/chain-configs/testnet`;
  mainnet/devnet/garbage follow the same form; TN_ROOT_PREFIX empty -> `/etc/telcoin/chain-configs/testnet`.

FT:
- E3 mainnet / devnet / garbage: rc 1, `warn|<net> has no pinned chain-config tag; nothing was read.`, no git, DIR need not exist.
- E4 D already passes the check: rc 0, `log|The pinned testnet chain configs are already in <D>.`, no git, DIR may be absent.
  No warn line from the quiet check (no "is missing or not a regular file" for D on a fresh install either).
- E5 DIR without .git (absent dir, empty dir): rc 2, `warn|<dir> is not a git checkout; the testnet chain configs at TAG cannot be read from it.`, no git.
- E6 DIR a symlink to a checkout: rc 1, `warn|<dir> must be a directory owned by <id -un> (not a symlink); nothing was fetched.`, no git.
  As root, a checkout owned by uid 65534: rc 1, same message, no git.
- E7 step `step|Fetching TAG from origin for the chain configs...`; the fetch argv is
  `-C DIR fetch --quiet --no-tags origin +refs/tags/TAG:refs/tn-remote-tags/TAG`, run with GIT_ALLOW_PROTOCOL=https and fd 9 closed.
- E8 fetch ok: reads refs/tn-remote-tags/TAG; refs/tags/TAG neither read nor moved (a local tag on another commit: rc 0, pinned files, local tag unmoved).
- E9 fetch fails, refs/tn-remote-tags/TAG present: rc 0 from it, `warn|Could not reach origin; reading the testnet chain configs from the local copy of TAG.`
  Only refs/tags/TAG present: rc 0 from it, same warn. Both present: tn-remote-tags wins (good tn-remote, bad local -> rc 0; bad tn-remote, good local -> rc 1).
  Neither: rc 2, `warn|Could not fetch tag TAG from origin, and the checkout does not have it.`, D untouched.
- E10 blobs read with `cat-file blob <ref>:chain-configs/testnet/<f>` into `mktemp -d` staging (TMPDIR honoured), removed on every path.
  A missing blob: rc 2, `warn|TAG has no chain-configs/testnet/<f>.`
- E11 mismatch: rc 1, `warn|The testnet chain configs at TAG do not match the pins; nothing was installed.`; D absent stays absent; D holding files stays byte-identical (no temp files left).
- E12 install: `_tn_root_layout_dir` for <cfg>/chain-configs and <cfg>/chain-configs/testnet (root 0755), `tn_write_root_file <D>/<f> 0644` per file with stdin a file (not a pipe);
  re-check; `log|Installed the testnet chain configs from TAG into <D>.`; rc 0. A failed write: rc 2.
- E13 DIR untouched: HEAD, branch, `status --porcelain --untracked-files=all`, stash list, submodule status, diff and diff --cached the same before and after; no checkout/pull/reset/merge/submodule/stash/clean in the git argv.
  Working tree's committee.yaml stays main's on a main checkout.
- E14 force-moved upstream tag (after a good install, D emptied): the fetch force-updates refs/tn-remote-tags -> rc 1 (mismatch), local tag unmoved.
- E15 second run after an install: rc 0, no git.
- E16 nothing written outside the test's temp area (TN_ROOT_PREFIX honoured; /etc/telcoin/chain-configs and /opt/telcoin-source not created).
- E17 installed: dirs 0755, files 0644, root:root (as root with the real writers).

EN:
- E20 unknown network: rc 1, error.
- E21 TN_GENESIS_DIR set: no git, no prompt; good dir -> rc 0 and "Chain configs in <gdir> match the testnet pins"; bad dir -> rc 1 and
  "The chain configs in <gdir> do not match the testnet pins (see above); nothing was copied."
- E22 mainnet: no git; with a checkout "Repository present; mainnet chain configs are used as published (no pull)."; rc 1 (pins empty).
- E23 testnet, D already good: rc 0, no prompt, no git.
- E24 testnet, checkout present (diverged main): FT's rc (0), no pull/checkout/reset/merge/submodule, checkout unmoved, "Chain configs in <D> match the testnet pins".
- E25 testnet, no checkout, confirm no: rc 0, "Skipped. You will need to provide chain-config files manually in the next step.", nothing cloned, no git;
  the prompt is "Clone the repository now to get the chain-config files?".
- E26 testnet, no checkout, confirm yes: `clone --quiet --branch TAG -- $TN_REPO <src>` with GIT_ALLOW_PROTOCOL=https, fd 9 closed, no --recurse-submodules;
  the clone's HEAD = the tag's commit; submodules not initialised; files installed; rc 0.
- E27 failing clone: rc 2, "Clone failed. Check your internet connection." and the manual command; the function returns (no exit).
- E28 second EN: rc 0, no git.
- E29 devnet with a checkout: unchanged (pull --ff-only).

## B. Test file

tools/tests/chain_configs_tag_test.sh written; covers E1-E29 except E29 (devnet pull, not added yet).
Real writers via /root/.tn-cctag.XXXXXX (0700) when root + mv -T; recording stand-ins otherwise.

## C. First run

Host (bash 5.3, non-root, git 2.53, stand-ins): 110 checks, 0 failures, 2 skipped (modes; other-owner checkout).
No mismatch between the spec-derived expectations and the code so far.
ubuntu:26.04 (root, git 2.53 installed by apt in the run, REAL writers): 117 checks, 0 failures, 0 skipped.
bash:3.2 (root, no git): 37 checks, 0 failures, 1 skipped (real-git part).
fw-s2-bash32-git:local (bash 3.2.57 + git 2.49.1, root, REAL writers): 117/0/0 after fixing a bash-3.2
parse error of my own (`case` inside `$(...)`, now the helper in_stg). check-bash32 did not flag that form.
Findings from C: none.

## D. Attacks (done; one more case pending: --genesis-dir with a checkout present)

Added: odd networks; spaces in checkout path and CONFIG_DIR; set -euo pipefail callers (subshell NOT in
a condition, else bash disables errexit inside: my first version was wrong there, fixed); symlinked
checkout with trailing slash; destination a symlink (empty target -> rc 2, nothing through it);
destination holding a symlinked file (rc 2, link + target kept); second write fails (rc 2, partial:
only genesis.yaml left; check refuses it; next run completes); three concurrent runs; tag deleted
upstream (rc 0 local copy + "Could not reach origin" warning); devnet pull kept with fd 9 closed.
Host: 131 checks, 0 failures, 2 skipped.
Observations so far: dest symlink to a dir holding the pinned files -> rc 0 "already in" (no git);
partial install not rolled back; mismatch warnings name files in the removed staging dir.

Mutation check (scratch copies of lib/, 15 mutations of the helpers): every one killed
(read HEAD, checkout, fd 9 kept, staging kept, local tag first, exit 1 on clone, no short-circuit,
fetch without +, ensure pulls, clone recurses, no owner check, install before check, mainnet clones,
no https limit, writes through a pipe).
After the attacks: ubuntu:26.04 138/0/0 (real writers), bash3.2+git 138/0/0 (real writers),
bash:3.2 37/0/1, host 131/0/2. shellcheck error+warning clean, check-bash32 clean, network-hits clean,
perl-interp clean.

Findings (all code-side, none a spec mismatch):
F1 Low  mismatch warning names files in the removed staging dir (/tmp/tmp.X/committee.yaml: sha256 ...).
F2 Low  failed 2nd write: rc 2, dest left with only the new genesis.yaml (no rollback); next run fixes.
F3 Info step 2 accepts a symlinked destination dir (and any owner/mode) that holds the pinned files.
F4 Info fetch stderr dropped; "Could not reach origin" also for a tag deleted upstream / dubious ownership.
F5 Info a gitfile checkout (git worktree) is "not a git checkout" (-d .git), as in tn_source_checkout_tag.
F6 Info staging dir not swept if the run is killed (no trap; tn_staging_sweep does not know it).
F7 Info rev-parse / cat-file run without GIT_ALLOW_PROTOCOL and with fd 9 (lazy fetch on a partial clone).

- [x] gates: full suites host + ubuntu:26.04 running
