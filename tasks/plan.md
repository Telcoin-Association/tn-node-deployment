# Plan: node requirements from the benchmarks, chain configs at the pinned tag, mainnet chain id 731 (2026-11-21)

Three changes on one branch, `requirements-from-benchmarks`, as separate commits, ending in one
pull request.

1. **Bug fix.** Fresh testnet Docker and signed-release installs fail at keygen:
   `ensure_chain_configs_available` clones the node repository's default branch, and since
   2026-11-14 `main`'s testnet `committee.yaml` no longer matches the pinned hash. The scripts
   take the chain configs at the pinned tag instead.
2. **Hardware requirements per network.** Testnet figures follow the five Adiri validators;
   the mainnet validator storage figure follows the latest benchmark runs. Docs, three operator
   PDFs, the hardware check in the scripts and the UI, and the AWS template say the same thing.
3. **Mainnet chain id 731** (added by the user during wave 0, 2026-11-21: "also ensure mainnet
   chain id is listed as 731 everywhere using more subagents"). Upstream moved it from 487 to
   731 in telcoin-network #1716 (`90ed40b39`, 2026-11-12); this repository still says 487.

Base: `origin/main` at `01664cc` (fetched 2026-11-21), which contains #74 (Ubuntu 26.04
recommended), #73, #72, #71 (AWS stack), #70, #69 and #68. No open pull requests.
`scripts-v2.2.0` is not tagged. Integration branch: the main checkout. Agent worktrees:
`~/coding/telcoin/tnd-req-<id>`. Shared spec: `tasks/spec-req-shared.md`. Checkpoints:
`tasks/ckpt-req-<id>.md` in each agent's worktree.

## Decisions (user, 2026-11-21)

- CPU is written as physical cores with vCPU in parentheses.
- Testnet storage is one row for every role: 350 GB minimum, 500 GB TLC NVMe recommended.
- Testnet minimum storage mirrors the deployed disks: 15,000 IOPS, 240 MB/s.
- Mainnet: 20,000 IOPS for validators only; observers stay at 10,000.
- AWS Validator preset `c7i.2xlarge`, with a note that this size sustains 12,000 IOPS and bursts.
- The round ends with the branch pushed and one PR opened.
- No Claude attribution on any commit or on the PR.
- Mainnet chain id is 731 everywhere.

Defaults chosen by the orchestrator: testnet validator rows drop "ECC"; observer rows get the
vCPU parentheses too; AWS data volume default 500 GiB, allowed 350/500/2000/4000, 15,000 IOPS,
300 MB/s; the hardware check uses testnet tiers on devnet and mainnet tiers with no network;
the fix's docs are a separate commit; released changelog entries that record 487 as what an
older release shipped are history and stay (they are listed in the final report).

## Baseline on `main` (01664cc), 2026-11-21

- `bash tools/tests/run.sh`: 81 files, 0 failed on the host (bash 5.3.9) and as root in
  `ubuntu:26.04`.
- `shellcheck -x` 0.11.0 over 211 tracked `*.sh`: 0 errors, 307 warnings.
- `bash tools/check-network-hits.sh`: clean, 153 annotated hits in 29 files.
- Lines naming 26.04: `README.md` 9, `OPERATOR.md` 8, guide 5, each one-pager 1,
  `aws/node.yaml` 4, `lib/common.sh` 4, `setup-node.sh` 1.
- Images present: `tn-pdf-tools`, `python:3.10-slim`, `bash:3.2`, `ubuntu:26.04`.
- `gh auth status`: scopes `read:org`, `repo`; git over SSH.

## Wave 0 (orchestrator)

- [x] `git fetch`; branch `requirements-from-benchmarks` off `origin/main` (01664cc)
- [x] project-context refreshed (`.claude/project-context.md`)
- [x] Google Cloud and AWS figures rechecked on the live pages
- [x] `scripts-v2.2.0` still untagged; no open PRs
- [x] Baseline gates on `main`
- [x] Mainnet chain id: upstream checked (731 on `main` since #1716; 487 at the pinned tags)
- [x] `tasks/plan.md`, `tasks/spec-req-shared.md`

## Wave 1 (seven implementers in parallel, disjoint files or ranges)

- [x] FIX-A1: chain-config helpers in `lib/common.sh`; `genesis_hash_test.sh` ensure cases
- [x] HW-SH: per-network tiers and `check_hardware` in `lib/common.sh`; `step_preflight` order
- [x] HW-UI-SRV: `ui/server.py` hardware profile per network; contract and mirror tests
- [x] HW-UI-PAGE: `ui/static/index.html` preflight sends the network; wording; wiring test
- [x] AWS: `aws/node.yaml` presets, volume size and IOPS; guard rules and their tests
- [x] CHAIN-SH: `MAINNET_CHAIN_ID` 731 in the library, script comments, shell fixtures
- [x] CHAIN-UI: chain 731 in `ui/server.py` network tables and the UI tests

## Wave 1b (four agents, each after its prerequisite is integrated)

- [x] FIX-A2 (after FIX-A1): `setup-node.sh` search order, hint, progress fn, require list
- [x] FIX-T (after FIX-A1): `tools/tests/chain_configs_tag_test.sh`, written from the spec
- [x] FIX-B (after FIX-A1): `edit-config.sh` menu 13; `chain_configs_refresh_test.sh`
- [x] HW-T (after HW-SH): `tools/tests/hardware_check_test.sh`, written from the spec

## Integration 1 (orchestrator; version constants and sidecars are mine)

- [x] `fix(setup): take the chain configs from the pinned tag, not from main`
- [x] `fix(edit-config): refresh installs the pinned chain configs instead of pulling`
- [x] `feat(setup): check the hardware against the chosen network's tiers`
- [x] `feat(ui): the setup preflight judges the hardware tiers of the wizard's network`
- [x] `feat(aws): Validator preset c7i.2xlarge, a 500 GiB data volume at 15,000 IOPS`
- [x] `fix(network): the mainnet chain id is 731`
- [x] All gates on the tip

## Wave 2 (five independent verifiers, then the range review)

- [x] V-FIX-S: setup end to end, skew, `remove-node`, the live proof in `ubuntu:26.04`
- [x] V-FIX-E: menu 13
- [x] V-HW-UI: shell and server parity, parameter validation, page wording
- [x] V-AWS: lint and guard, EBS limits, update behaviour, presets against the hardware check
- [x] V-CHAIN: no surviving 487 as the mainnet id; behaviour on 731 and on 487; sibling repos
      (read-only report)
- [x] Findings fixed (implementer if under budget, else a fresh agent)
- [x] V-RANGE: one whole-diff review of the code range, then its fixes
- [x] Code freeze

## Wave 3 (docs, five writers in parallel, one owner per file)

- [x] DOC-O: `OPERATOR.md` (three passes: fix, hardware, chain id)
- [x] DOC-R: `README.md` (three passes; changelog entries, nothing older edited)
- [x] DOC-M: `CHANGELOG/scripts-v2.2.0.md`, `CHANGELOG.md`, `AGENTS.md`, `followup.md`
- [x] GUIDE: `mno-node-guide.md` 1.13, all topics in one pass, PDF
- [x] ONEPAGERS: both one-pagers 1.3, PDFs, the list of cuts used

## Wave 4 (verification, read-only)

- [x] V-DOC-REF: quoted messages, changelog headings, 26.04 counts, surviving old figures
- [x] V-DOC-PDF: `pdftotext` assertions, page counts, guide cells equal one-pager cells
- [x] V-SITE (orchestrator): the partner site's build gates against the committed tip

## Final (orchestrator)

- [x] Doc fixes
- [x] `git fetch` (`main` did not move); every gate again on the final tip
- [x] `bash tools/gen-checksums.sh`; `git status --porcelain` empty
- [x] `tasks/` records: this plan ticked, review in `todo.md`, lessons, harnesses linted
- [x] No Claude attribution in `main..tip`; subjects checked
- [ ] Push over SSH; one PR; CI watched (24.04, 26.04 VM assertions, macOS)

## Commits (as they landed, no attribution)

1. `fix(setup): take the chain configs from the pinned tag, not from main`
2. `fix(edit-config): refresh installs the pinned chain configs instead of pulling`
3. `feat(setup): check the hardware against the chosen network's tiers`
4. `feat(ui): the setup preflight judges the hardware tiers of the wizard's network`
5. `feat(aws): Validator preset c7i.2xlarge, a 500 GiB data volume at 15,000 IOPS`
6. `fix(network): the mainnet chain id is 731`
7. Fix commits from the verifiers' findings and the whole-diff review:
   `fix(setup): chain-config helpers after verification`,
   `fix(edit-config): menu 13 offers the clone and frees the lock before its prompts`,
   `fix(ui): the preflight treats a measured zero as unmeasured and words logical CPUs as such`,
   `fix(aws): say in the console what a c7i.2xlarge sustains to EBS`,
   `fix(caddy): the mainnet gate names the chain it found and checks the public RPC's chain`,
   `fix(edit-config): menu 13 uses the library's pre-checks`
8. `docs: chain configs come from the pinned tag`
9. `docs: hardware requirements per network`
10. `docs: the mainnet chain id is 731`
11. `docs(partner): guide 1.13, hardware per network, chain configs at the pinned tag, chain id 731`
12. `docs(partner): node requirements one-pagers 1.3`
13. `docs: corrections after verification`
14. `chore(release): refresh the checksums`
15. `tasks: plan, checkpoints and review of the requirements round`

## What changed against the plan

- The user added the mainnet chain id (731) during wave 0: two more implementers, a verifier,
  its own code commit and docs commit.
- The fix round bumped the touched scripts once more (lib/common 2.2.5, setup-node 2.1.4,
  edit-config 2.2.2, telcoin-ui 2.1.3, update-node 2.1.2, install-caddy 2.2.1), so the README
  changelog has one entry per bump.
- Two more verifier-driven packages than planned: the Caddy mainnet gate (V-CHAIN) and the seam
  between menu 13 and the library (the whole-diff review).
- The PDFs were built on Ubuntu 26.04 with pandoc 3.14 and WeasyPrint 70.0, not in the Debian 12
  `tn-pdf-tools` container: the user asked for pandoc 3.14 in a container, and the Ubuntu 26.04
  image turned out to rebuild main's PDFs byte for byte, while the Debian container breaks some
  lines earlier whatever the pandoc version.
- Two commit messages were corrected after the documents' verifier showed a claim in them was
  wrong (what the old menu 13's pull did on a source install), so the branch was rebuilt with
  the same trees; `tasks/spec-req-shared.md` section 8 maps the earlier commit ids, which the
  verifier reports and checkpoints cite, to the final ones.
- The testnet one-pager keeps the QLC advice inside its "Every node" bullet; the mainnet one
  needed cuts 1 and 3 of the ranked list, not 2.
- Not applied, recorded in `followup.md`: menu 13's second host-baseline refresh on a first
  install, and the guide headings that sit alone on a page.

## What stays with the user

- Merge the PR.
- Run the partner site's Publish workflow; then the orchestrator verifies run.telcoin.network.
- Cut and sign the scripts release that carries the fix; until then `scripts-v2.1.0` users need
  `--genesis-dir`.
- The upstream hardware page in `telcoin-network` still shows the old single table.
