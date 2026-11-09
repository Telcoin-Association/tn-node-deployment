# Shared spec for the hardening follow-ups round (read first)

Round of 2026-11-03: the follow-up PR `scripts-v2.1.0` (branch `hardening-followups`, draft PR
on GitHub) that advances the hardening issues left open after PR #11 merged (8cb1b0b,
2026-11-02). Every implementation and verification agent reads this file, then its own
package spec `tasks/spec-fup-<pkg>.md`. The orchestrator is the only committer on the
integration branch; implementers commit on their own `fup/<pkg>` branch in their worktree.

## Ground rules

- Commits (implementers, on `fup/<pkg>` in `~/coding/telcoin/tnd-fup-<pkg>`): one commit per
  section, conventional prefix (`lib/common: …`, `firewall-setup: …`, `tests: …`), plain prose
  that says what the behaviour is now, no `Co-Authored-By`, no "Generated with", no trailer of
  any kind. Explicit paths only: never `git add -A`, never `tasks/`, `.claude/`, `*.sha256`.
- No version bumps, no `tools/gen-checksums.sh`, no edits to the `SCRIPTS`/`UI_BUNDLE`/
  `TESTNET_ADDONS_BUNDLE` arrays of `update-scripts.sh`, no `README.md`/`OPERATOR.md`/
  `AGENTS.md`/`CHANGELOG/`/`docs/` edits unless your package owns them (DOCS does). The
  orchestrator bumps versions and sidecars at release prep.
- The maintainer private ops checkout (outside this repository) is never read into a public file,
  commit, comment or test. Do not reference it anywhere.
- bash 3.2 safe (CI runs every fixture under macOS `/bin/bash` 3.2 and `bash:3.2`): no
  `declare -A`, `declare -g`, `local -n`, `${var,,}`, `${var^^}`, `mapfile`, `readarray`,
  `&>>`, `|&`, `[[ -v`, `wait -n`, negative subscripts, `${v@X}`, `%(…)T`, `;;&`. Empty arrays
  expand as `${a[@]+"${a[@]}"}` under `set -u`. No apostrophe inside a `${var:-default}`
  word. Declare locals on the `local` line, assign on their own lines. `readonly arr=(…)`
  sourced inside a function is invisible under 3.2: source at top level. Inside `$( )` never
  write a `case` with bare `pat)` patterns (3.2 counts parentheses): move it into a function
  or write `(pat)`. `source missing || true` still exits under 3.2 with `set -e`: guard with
  `[ -r f ] && source f`. `tools/check-bash32.sh FILE` must stay clean on every touched file.
- Boundary rule (AGENTS.md): nothing operator-facing may call, source or point at `common/`
  or `devnet-genesis/`. Never emit or reintroduce `--observer` / `--validator`.
- Root owns the install (AGENTS.md "Ownership"): root-owned files are written with
  `tn_write_root_file` and never through a pipe (`tools/tests/root_write_pipe_test.sh`);
  the passphrase variables are never echoed (`tools/tests/passphrase_print_test.sh`);
  no perl program expands a shell variable (`tools/check-perl-interp.sh`).
- Restarts (AGENTS.md "Restarts and the epoch boundary"): any new code that stops or
  restarts the node runs `tn_committee_down_guard`, then `tn_wait_restart_window`, right
  before the stop, under the update lock.
- `--json` runs print only JSON events on stdout and always end with a `done` event.
- Agents edit, test and commit on their own branch only. Never `git checkout`/`switch`
  another branch, never `git stash`, `git reset`, `git rebase`, `git push`. Read-only git is
  fine. If a change seems to need a file another package owns, write it under "Open issues"
  in your checkpoint with the exact text and hand back.
- Prose in comments, help text and messages: plain, specific, no filler, no line-number
  references, no em-dashes. Messages tell the operator what happened and what to do.
- Temporary files go in your worktree's `tasks/verify-fup/<name>/` (verifiers, committed as
  records) or `/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/5d4c8cd2-b758-4c78-9efb-36793aa8b1d5/scratchpad/<pkg>/`
  (implementers), never elsewhere in the repo.

## Checkpoint protocol

- Checkpoint file: `tasks/ckpt-fup-<pkg>.md` in your worktree (do not commit it; the
  orchestrator collects it). First line `status: <in-progress|blocked|done>`. Then the
  sections with `[x]`/`[ ]`, rewritten after EACH section, not once at the end.
- On start, read your own checkpoint and continue from the first unfinished section.
- The checkpoint ends with four headings: **Operator-visible changes**, **Docs notes** (the
  exact facts DOCS must write: flags, env names, file paths, messages, defaults), **Tests
  run** (commands and results, bash 5 and bash 3.2), **Open issues**.
- Budget well under 250k tokens. If you are ballooning, checkpoint and hand back; the
  orchestrator respawns for the remainder.
- If Write is refused, do not work around it: return the complete text in the final answer.
- Return a summary (not file dumps) in the final answer: commits on your branch (sha +
  subject), tests run with counts, docs notes, open issues.

## Versions on main 1187ddb (2026-11-03; agents do not bump)

lib/common 2.0.1, lib/fallback 1.1.0, lib/observability (`OBSERVABILITY_VERSION`) see file,
lib/testnet-addons.env 1.1.0, setup-node 2.0.1, edit-config 2.0.1, update-node 2.0.1,
check-node 2.0.0, firewall-setup 2.0.0, remove-node 2.0.0, prepare-stake 2.0.0,
migrate-node-naming 2.0.0, install-caddy 2.0.0, setup-vpn 2.0.0, setup-observability 2.0.0,
update-scripts 2.0.0, ui/server.py `UI_VERSION` 2.0.1, ui/install-ui 2.0.0. Release prep
sets every touched tracked script, `COMMON_VERSION` and `UI_VERSION` to 2.1.0 (orchestrator).

## Verified facts (checked on main 1187ddb, 2026-11-03)

Repository state:
- PR #11 (`mainnet-hardening`) merged 2026-11-02 as 8cb1b0b; PR #52 (lib/common 2.0.1) came in
  with it; PR #58 (partner guide 1.5, technical specification 1.2, new `docs/partner/<name>/`
  layout) merged 2026-11-03; Dependabot #53-#57 merged 2026-11-03 (checkout 7.0.1,
  setup-python 7.1.0, upload-pages-artifact 5.0.0, deploy-pages 5.0.1, pytest 9.2.0).
- No `RELEASE`, `MANIFEST`, `MANIFEST.sig` on main; `lib/allowed_signers` has comment lines only;
  no `scripts-v*` tag. The user cuts `scripts-v2.0.0` from main (serial 1) before this PR
  merges; this PR becomes `scripts-v2.1.0` (serial 2). `MANIFEST` keys today: `format=1`,
  `release=`, `serial=`, `min_updater=` (update-scripts.sh `parse_manifest` at ~366 counts
  each once and refuses a duplicate; unknown keys are ignored, so a new `expires=` key is
  backward compatible with 2.0.0 updaters).
- Updater-tracked files are the three arrays at update-scripts.sh:73-130 (`SCRIPTS`,
  `UI_BUNDLE`, `TESTNET_ADDONS_BUNDLE`); every file there has a `.sha256` sidecar that the
  orchestrator regenerates at release prep. `tools/`, `tasks/`, `AGENTS.md`, tests are not
  tracked.
- CI jobs (`.github/workflows/ci.yml`, display names): "bash -n (Linux)", "bash -n and
  bash-3.2 lint (macOS bash 3.2)", "shellcheck", "fixture tests (Linux bash 5)", "fixture
  tests (macOS bash 3.2)", "hardening lints", "release manifest", "Node Manager UI tests",
  "checksum freshness"; `integration.yml`: "Ubuntu 24.04 VM assertions".
  `tools/tests/ci_pins_test.sh` checks pins, permissions and `persist-credentials: false`.

Library anchors (lib/common.sh, line numbers approximate, verify with grep before editing):
- Constants: `MAINNET_CHAIN_ID="487"` :26, `MAINNET_CHAIN_NAME="telcoin"`, `MAINNET_RPC_URL=
  "https://rpc.telcoin.network"` :28, `MAINNET_EXPLORER="https://telscan.io"`,
  `TESTNET_RPC_URL="https://rpc.adiri.tel"` :21, `DEVNET_RPC_URL` :36,
  `MIN_SOURCE_VERSION_TESTNET="0.13.0"` :82, `MIN_SOURCE_VERSION_MAINNET=""` :83,
  `DEFAULT_DOCKER_IMAGE` :1510 (GAR adiri image by digest), `TN_MAINNET_IMAGE_REPO=
  "$TN_GHCR_IMAGE_REPO"` :6286 (testnet and mainnet share the ghcr repository),
  `TN_DEVNET_IMAGE_REPO` :6287. There is NO `TN_MAINNET_ENABLED` in the library today; it
  exists only in `ui/server.py:2856` (`TN_MAINNET_ENABLED = False`) and `ui/static/index.html`.
- `tn_ref_min_check REF NETWORK` :1973 (rc 0 allowed, 1 refused, 2 warning; empty floor =
  no floor). Only caller today: setup-node.sh:1689. update-node's prepare paths
  (`prepare_docker_update` :1581, `prepare_source_build` :1971, `prepare_release_update`
  :1995, `json_prepare_source` :2897, `json_prepare_release` :2909, `json_prepare_docker`
  :2926) and edit-config's `edit_docker_image` :2329 (and the `--json` path at :1385) do not
  call it.
- `check_internet` :2341 curls `$TESTNET_RPC_URL` then `https://1.1.1.1` on every network.
- `select_network` :2630: option 2 prints "Mainnet has not launched yet." and loops.
- setup-node.sh `json_set_network` :2932 accepts `mainnet` and sets the mainnet constants;
  `_setup_image_example` :577 prints `DEFAULT_DOCKER_IMAGE` (an adiri image) unless devnet.
- `tn_wait_restart_window` :4456: `margin=$(_tn_env_uint TN_EPOCH_MARGIN 300)`, `settle … 90`,
  `cap … TN_EPOCH_WAIT_MAX 1800`, `poll … 15` clamped 5-20 (:4465-4470). `epochDuration` is
  read at :4217 (`_tn_json_uint "$out" epochDuration`) for the boundary. Contract comment
  :4355-4390. The blind wait (`_tn_wait_blind`) is margin + settle capped. A `CvvActive`
  node whose epoch info is unreadable continues without a wait (`keytool_test.sh:171` pins
  it: "wait: mode read, epoch unreadable: continues without a blind wait" expects 0). Fixture:
  `tools/tests/restart_window_test.sh`.
- `tn_committee_down_guard` :3853. `tn_host_audit` :5967 (read-only report; `LimitCORE` check
  at :6032). The node unit text carries `LimitCORE=0` (:3380, :3416). `tn_keytool_has SPEC WORD
  [SUBCMD…]` :9013 (rc 0 listed, 1 not, 4 probe failed).
- `tn_docker_repo_for` :6323, `tn_docker_resolve_ref NETWORK ARG [fn]` :7305: a
  `<repo>@sha256:<digest>` of an allowed repository is "taken as given" with the tag from
  `.node-meta` (`tn_docker_recorded_tag`) else empty with a warning. On mainnet this lets a
  digest of a testnet image through (same ghcr repository).
- `is_testnet_like` :7768.
- adiri `tn_getCurrentEpochInfo` (live 2026-11-02): `epochDuration` 21600 s, committee of 5.

Scripts:
- check-node.sh: `network_rpc_url` :318, `resolve_network` :340; :369-370 fall back to
  `$TESTNET_RPC_URL` when the network is unknown; `--network-rpc` :183 overrides.
- edit-config.sh: `edit_migrate_credential` :2074, `edit_reseal` :2107; the passphrase edits
  (`edit_bls_passphrase`, `edit_change_passphrase`: grep) and `--migrate-credential`. No
  `tn_keytool_has` call today (0 hits). Credential path `/etc/telcoin/bls-passphrase.cred`
  (never `/etc/credstore.encrypted`).
- remove-node.sh: `_rm_shred_note` :341, `_rm_shred` :375, `_rm_shred_tree` :391; it shreds
  the `.cred` and backups.
- firewall-setup.sh: `fw_p2p_ports` :299, `fw_p2p_allow` :381 (ufw per-source rules when
  `FW_P2P_SRCS` is set, else `ufw allow PORT/udp`), `fw_src_list` :401, `fw_load_p2p_srcs`
  :510, `apply_recommended_firewall [--reset]` :866. `--p2p-from` is a comma list or a file;
  `.node-meta` keeps `P2P_ALLOW_FROM`. Fixtures: `firewall_reset_test.sh`,
  `firewall_signal_test.sh`, stub `tools/tests/fwstub.sh`.
- lib/observability.sh: `obs_write_config_alloy` :231, `_obs_alloy_fallback` :327 (embedded
  copy; `bearer_token = sys.env("OBS_INGEST_TOKEN")` at :379 and :431), `_obs_write_env_file`
  :443 (writes `OBS_INGEST_TOKEN=${token}` into `${OBS_ETC_DIR}/telcoin-alloy.env`, umask 077),
  `obs_write_alloy_native_unit` :689 (`obs_alloy_unit_text BIN ENVF GRP DD`), `obs_run_alloy_docker`
  :716 (`docker run … --env-file ${envf} -v config:ro -v logs:ro -v data`), `obs_existing_token`
  :1322 (reads the env line), `/etc/credstore.encrypted` named at :640 in the
  `InaccessiblePaths` list (stale: the credential lives at `/etc/telcoin/bls-passphrase.cred`).
  `observability/config.alloy` is vendored from
  `adiri-genesis/common/observability/node-agent/config.alloy` (header says so; the
  deploy-networks-common repository is the upstream now: see docs/testnet-addons.md "Sync
  note"); `endpoint { url = sys.env("OBS_PUSH_URL"); bearer_token = sys.env("OBS_INGEST_TOKEN") }`
  at :75-77 (logs) and :138-140 (metrics). Hub host from `lib/testnet-addons.env`:
  `OBS_PUSH_URL_TESTNET="https://obs.adiri.telcoin.network/loki/api/v1/push"`,
  `OBS_METRICS_PUSH_URL_TESTNET="https://obs.adiri.telcoin.network/api/v1/write"`;
  `TN_ALLOY_IMAGE="grafana/alloy:v1.5.1"`, `TN_ALLOY_NATIVE_VERSION="1.5.1"`.
- setup-observability.sh: `--token-stdin`, `--token`, `TN_OBS_TOKEN` (:582-609), `main_menu`
  :638, `--json` mode :380+.
- update-scripts.sh: `verify_manifest` :342, `parse_manifest` :366 (`M_SERIAL`,
  `M_MIN_UPDATER`), `refuse_min_updater` :441, `usage` :736. install.sh: manifest parse at
  :177-215 (`format=*|release=*|serial=*|min_updater=*`), `TN_SCRIPTS_TAG=""` :27 (written by
  release-scripts). tools/release-scripts.sh: `[--serial N] [--min-updater X.Y.Z] [--date
  YYYY-MM-DD] TAG` and `--check [--tag TAG] [--require-sig]`. Fixtures:
  `updater_manifest_test.sh`, `release_scripts_test.sh`, `install_test.sh`, `tools/tests/signing.sh`.
- ui/server.py: `TN_MAINNET_ENABLED = False` :2856, used at :2872; `UI_VERSION` :78.
  ui/static/index.html: :1603 hard-coded `https://status.adiri.telcoin.network/` link, :3136
  firewall card, :3191 `p2p_ports`. ui/telcoin-ui-helper.sh: `node_network` :504, `cmd_setup`
  :1480 (`net_rule=mainnet` :1520), firewall verb near :1353. `ui/telcoin-ui.service`: no
  `LimitCORE`, `NoNewPrivileges` intentionally absent (sudo). Tests: `ui/test_*.py` (258 pass),
  `ui/tests/helper_test.sh`, `install_ui_test.sh`, `open_ui_test.sh`.
- CI dead fallbacks: ci.yml :128-134 (`if [ -f tools/check-perl-interp.sh ]` else notice) and
  :197-207 (`if [ -f ui/tests/requirements-dev.txt ]` and the `import pytest` else-unittest
  branch). publish-installer.yml:49 `touch _site/.nojekyll` (dotfiles are dropped by
  upload-pages-artifact v4+, harmless on artifact deploys). `ui/requirements.txt:12` says the
  dev file is generated from "pytest>=8,<9" (now 9.2.0); `ui/tests/requirements-dev.txt:29`
  carries the same `# via pytest>=8,<9` annotation. `.github/CODEOWNERS`: single owner
  `@grantkee` on every line; line 1 says "requires a review from a code owner" (no ruleset
  exists yet).
- Docs: partner guide is `docs/partner/mno-node-guide/mno-node-guide.md` + `metadata.yaml`
  (version "1.5", date November 2026) + `mno-node-guide.pdf`; build with
  `tools/build-partner-pdf.sh` in `tn-pdf-tools` (AGENTS.md "Partner documents"). The
  technical specification (1.2) is not touched by this round. `followup.md` :50-53 says
  `tn_docker_repo_for mainnet` returns nothing (stale: it returns ghcr since ebb34ae); :10-11
  says the U-numbered issues "are drafted but not posted yet" (stale: #1725-#1735 exist).
  `docs/testnet-addons.md:208` names `/etc/credstore.encrypted`. `ui/server.py:4940` docstring
  (see DOCS spec). `OPERATOR.md` "4.10 Verifying a release by hand" :867 is the manual
  signature+hash procedure the README and partner guide lag.

## Gate invocations (this Linux box; images pulled 2026-11-03)

```
bash -n FILE; docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash -n FILE
bash tools/check-bash32.sh FILE...
shellcheck -x --severity=error FILE...                      # 0.11 on the host
docker run --rm -v "$PWD:/w" -w /w koalaman/shellcheck:v0.9.0 -x --severity=error FILE...
bash tools/tests/run.sh [name_test.sh ...]                                   # bash 5.3
docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/run.sh [names]  # 3.2, busybox
docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/run.sh [names]   # root, GNU
bash ui/tests/helper_test.sh; docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash ui/tests/helper_test.sh
docker run --rm -v "$PWD:/w" -w /w python:3.10-slim sh -c 'pip install -q --require-hashes -r ui/requirements.txt -r ui/tests/requirements-dev.txt && python -m pytest -q ui'
git ls-files -z '*.sh' | xargs -0 bash tools/check-perl-interp.sh
bash tools/tests/run.sh root_write_pipe_test.sh passphrase_print_test.sh
systemd-analyze verify <rendered unit>        # on units the package renders (host has systemd)
docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD:/w" -w /w tn-pdf-tools:latest bash tools/build-partner-pdf.sh mno-node-guide
```
Fixture tests source `tools/tests/lib.sh`, load the library with `eval "$(tn_test_source_common)"`
at top level, and use `check`, `check_has`, `check_lacks`, `check_rc`, `skip`, `finish`
(AGENTS.md "Fixture tests"). Stubs on PATH call the real tool by absolute path resolved
before the stub dir is prepended. Never call `check` inside `( … )`, `$( )` or a `| while`.

## Decisions of this round (user 2026-11-02; orchestrator where marked)

1. Release order: `scripts-v2.0.0` from main first (user signs); this PR is `scripts-v2.1.0`.
2. Dependabot merged (done). GOV fixes the two notes (requirements recipe, `.nojekyll`).
3. #39 (UI oneshots) is deferred to its own PR: nothing in this round touches sudoers or the
   UI unit beyond `LimitCORE=0`.
4. Closing policy: only #34 closes now; #47 closes with this PR; the other 15 stay open.
5. (orch.) #33 "late" semantics stay: a header or vote timeout after an apply keeps the new
   release and ends `ok:true` with `"voting":false`. Docs describe it; no code change.
6. (orch.) #41: nftables table `inet tn_p2p` meters NEW UDP flows per source on the P2P ports
   (`ct state new`, per-saddr meter, default 20/minute burst 40, drop above), only when no
   `--p2p-from` list is set; `TN_P2P_NEW_FLOW_RATE` / `TN_P2P_NEW_FLOW_BURST` override;
   established flows untouched. See FW.
7. (orch.) #49: margin = clamp(epochDuration/72, 300, 900), settle = clamp(epochDuration/240,
   90, 300); explicit env wins; `TN_EPOCH_WAIT_MAX` < margin + settle + 2*poll is raised with
   a warning. Unreadable epoch info on a `CvvActive` node keeps today's no-wait. See LIB-B.
8. (orch.) #43: `--host-baseline` (setup-node), auditd + AIDE, `.node-meta` `HOST_BASELINE=true`,
   refresh after update-node/edit-config apply, teardown in remove-node. See AUDIT.
9. (orch.) #35: token file `/etc/telcoin/alloy/ingest-token` (root:telcoin-alloy 0640),
   `LoadCredential=ingest-token:…` + `bearer_token_file = sys.env("CREDENTIALS_DIRECTORY") +
   "/ingest-token"`, Docker bind mount + `--group-add`, explicit `tls_config`, `--rotate-token`,
   env-file migration, shred on remove. See OBS.
10. (orch.) #40: `expires=YYYY-MM-DD` in MANIFEST (default 90 days), warnings, `update-scripts.sh
    --check` (rc 1 when expired), check-node reports the installed release. 2-of-N deferred.
11. (orch.) #47: `# network-gated: <reason>` annotations + `tools/check-network-hits.sh` in
    "hardening lints". See NET-2 and GOV.
12. (orch.) #46: `tn_docker_resolve_ref` on mainnet refuses a raw ghcr digest no signed mainnet
    release names. See LIB-A.
13. (orch.) #43 flag is `--host-baseline` (`--audit` is taken by the read-only report).

## Packages and owners

| pkg | wave | owns (everything else read-only) |
|---|---|---|
| LIB-A | 1A | lib/common.sh (mainnet flag, select_network, json refusal, floor call sites, digest refusal), setup-node.sh, update-node.sh + edit-config.sh (floor call sites only), ui/telcoin-ui-helper.sh `cmd_setup` only, tests: network_detect_test.sh, source_ref_test.sh, docker_image_test.sh, ui/tests/helper_test.sh (setup cases) |
| LIB-B | 1A | lib/common.sh (`tn_wait_restart_window` derivation, `check_internet`), check-node.sh (network resolution), setup-node.sh (`_setup_image_example`), tests: restart_window_test.sh, keytool_test.sh, check_node_*_test.sh, network_detect_test.sh |
| KEYS | 1A | edit-config.sh (keytool verify hooks), remove-node.sh (`_rm_shred_note` text), tests: edit_passphrase_test.sh, credential_test.sh, remove_test.sh |
| AUDIT | 1A | setup-node.sh (`--host-baseline`), lib/common.sh (`tn_host_baseline_*`, `tn_host_audit` lines), update-node.sh + edit-config.sh (refresh hook), remove-node.sh (teardown), tests: host_baseline_test.sh (new) |
| OBS | 1B | lib/observability.sh, setup-observability.sh, observability/config.alloy (+ upstream checkout), remove-node.sh (token shred), tests: obs_test.sh, remove_test.sh |
| REL | 1B | tools/release-scripts.sh, update-scripts.sh, install.sh, check-node.sh (release report), tests: updater_manifest_test.sh, release_scripts_test.sh, install_test.sh, check_node_*_test.sh |
| FW | 1B | firewall-setup.sh, tests: firewall_reset_test.sh, firewall_signal_test.sh, fwstub.sh |
| UI-S | 1B | ui/server.py, ui/telcoin-ui-helper.sh (firewall verb only), ui/static/index.html, ui/telcoin-ui.service, ui/test_*.py, ui/tests/helper_test.sh (firewall cases) |
| NET-2 | 2 | tools/check-network-hits.sh (new), tools/tests/network_hits_test.sh (new), `# network-gated:` comment lines anywhere the lint reports |
| GOV | 2 | .github/workflows/ci.yml, .github/workflows/publish-installer.yml, .github/CODEOWNERS, tools/tests/ci_pins_test.sh, ui/requirements.txt (comment), ui/tests/requirements-dev.txt (comment) |
| DOCS | 2 | README.md, OPERATOR.md, AGENTS.md, WGVPN.md, docs/testnet-addons.md, followup.md, docs/partner/mno-node-guide/* (+ PDF), CHANGELOG/scripts-v2.1.0.md |

Two wave-1A packages (LIB-A, LIB-B, AUDIT) and two wave-1B packages touch `lib/common.sh`;
each edits only its own functions, adds new functions at the end of the nearest related
section, and never reflows unrelated lines, so the orchestrator's cherry-picks apply cleanly.
Same for setup-node.sh (LIB-A, LIB-B, AUDIT), edit-config.sh (LIB-A, KEYS, AUDIT),
update-node.sh (LIB-A, AUDIT), remove-node.sh (KEYS, AUDIT, OBS), check-node.sh (LIB-B, REL).
