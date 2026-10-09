status: done
agent: V-DOC-C (read-only docs sub-verifier)

Doc mtimes when first seen (02:4x on 2026-10-02): CHANGELOG.md 02:44:33, AGENTS.md 02:44:54,
followup.md 02:44:41, README.md 02:44:39.

## Sections
- [x] 0. Read preamble, spec-fu-shared.md, fu-docs-notes.md
- [x] 1. README.md `## Changelog` to end
- [x] 2. CHANGELOG.md Unreleased section
- [x] 3. AGENTS.md
- [x] 4. followup.md (>= 15 sampled items + docs-notes additions)
- [x] 5. Re-check mtimes of CHANGELOG.md / AGENTS.md / followup.md (unchanged: 02:44:33, 02:44:54, 02:44:41; README 02:44:39)

## Section 1 result
New entries (README 1413-1851) all name versions matching on-disk constants: update-scripts 1.1.70
(expected; disk 1.1.69), telcoin-ui 1.9.0, install-ui 1.4.0, prepare-stake 1.0.0, setup-node 1.3.0,
edit-config 1.3.0, update-node 1.2.0, install-caddy 1.4.0, check-node 1.2.0, firewall-setup 1.6.0,
setup-observability 1.2.1, remove-node 1.2.9, migrate-node-naming 1.2.1, lib/common 1.6.0,
lib/fallback 1.0.3, lib/observability 1.0.2. No off-by-one. Every tracked file changed in
7fb7c8d..HEAD has an entry (setup-vpn unchanged). Sampled ~60 claims against code; all held
(fail-closed message text, pair install, chmod only *.sh, v1.1.69 declare -g, install.sh,
helper order/rpc-enable/dashboard refusal, 2 endpoints x 3 s, node-role.json, role_source values,
status-6 retired rule, InvalidTokenId 0xed15e6cf, epoch fields, prepare-stake exit codes
0-4/130/143/129, either-address refusal, single JSON object, signing note, SYNC_LAG 50,
setup-node region tr/cut 32, 64 KiB, lib<1.6.0 message, edit-config menu 5/8-13, world-readable
peers file, private-forward refusal, refresh chain-id check, ambiguous launch file, update-node
9>&- on cargo/docker/git/systemctl, epoch defaults 300/90/1800/15 clamp 5-20, stalled-epoch warn,
install-caddy stamp/Allow/2MB/block_stale/PUBLIC_* keys/keep 5/lock message/exit 2,
check-node strings, firewall p2p_ports keys, observability fallbacks, CI jobs, lint marker).
install-caddy 1.3.0 "never pruned" kept as history with a correction paragraph (deliberate).
v1.5.0 "never released" holds: 1e2d2f1 is not on origin/main.

Findings (section 1):
- N1 note README.md install-caddy v1.3.0 correction line is one 160-char unwrapped line, unlike
  the wrapped prose around it.
- N2 note README.md update-scripts v1.1.70 entry omits "clear cannot end the run" (3c78a6d);
  harmless.
- N3 note (code, out of scope) lib/fallback.sh deprecation comment still says firewall-setup
  "still does" call tn_resolve_node_type "until firewall-setup 1.6.0 lands"; 1.6.0 has landed
  and no caller remains. README's lib/fallback entry is right.

## Section 2 result (CHANGELOG.md, read at mtime 02:44:33)
Areas and versions match disk. Guide version 1.1 matches metadata.yaml. --no-epoch-wait exists only
in update-node and edit-config, as stated. Old wss probe was --max-time 8, as stated.
devnet-genesis e732765 exists (config.sh comment). Superseded note in the older "Dynamic node
role" entry is correct.
Security bullet -> commit: (1) launch-file metachars -> 2c423dc (+d1593ae unit $ % `);
(2) validated answers/flags, `9101;id` -> babb69d (+9df76cb); (3) peers map never echoed,
world-readable file -> 8185d00, 8c69378, 59d10a0; (4) helper role arg / sudoers last ->
2025ea3, 8feb576; (5) check-node eval -> 823e149 (eval since a04fd4a check-node 1.1.31, so
"since 1.1.x" holds); (6) updater fail-closed -> 3c78a6d; (7) prepare-stake passphrase/key ->
f918d4f, 77e043b; (8) update lock on SIGTERM -> ea86e22, f9c47df. No bullet lacks a commit.
Security-relevant commits with no Security bullet:
- W1 warn: e28e8e5 + f9c47df refuse refs starting with "-" (option injection into root-run git
  and docker; 7fb7c8d had no guard). Mentioned under "Updates and restarts" only.
- N4 note: 1540751 validates the observability token, URLs and METRICS_PORT and rehearses the
  launch-file edit before Alloy is rewritten (input validation for root-written config).
- N5 note: 7acc653 adds the 2 MB request-body cap on the public RPC (DoS hardening); listed
  under Public RPC only.
- N6 note: intro says "Operators receive every script below through update-scripts.sh v1.1.70",
  but the same section lists install.sh (not tracked) and maintainer tooling (not shipped);
  each says so in place, so harmless.
- N7 note: "Updates and restarts" list of epoch-waiting scripts omits prepare-stake
  --rotate-address, which also restarts after the epoch wait (prepare-stake.sh ps restart).
Known remaining: checked in section 4.

## Section 3 result (AGENTS.md, read at mtime 02:44:54)
All named operator scripts, lib/, ui/, docs/testnet-addons.md (Sync note heading present),
docs/partner/* and tools/* exist. Updater arrays (35 entries) == committed *.sha256 set exactly;
no sidecar for AGENTS.md, OPERATOR.md, followup.md, CHANGELOG.md, README.md, docs/, tools/,
ui/tests/, ui/dev/, ui/test_*.py, and none of them is in an array. Boundary grep: no runtime
common/ or devnet-genesis use; provenance comments are marked maintainer-only; setup-vpn's
`./common/wgvpn/add-node.sh` is printed "For the Association admin". NODE_TYPE is read only by
the deprecated tn_resolve_node_type (no callers). Epoch defaults/clamp, TN_EXIT_TRAP_OWNED,
fail-closed updater, CI (checksum job via git status --porcelain; lint on macOS /bin/bash and
Ubuntu bash; helper tests on both), lint rule list and `# bash32-ok` all true.
Findings:
- W2 warn: boundary list omits `open-ui.sh`, an operator-facing script (runs on the operator's
  laptop; clean today). Add it next to install.sh.
- N8 note: "Restarts and the epoch boundary" names update-node, edit-config, install-caddy and
  the observability add-on; prepare-stake --rotate-address also calls tn_wait_restart_window
  (prepare-stake.sh, after tn_acquire_update_lock). Add it.
- N9 note: the CI sentence lists sidecars, /bin/bash parse and the lint; CI also fails on the
  Linux bash -n, shellcheck errors and the UI test job. Not wrong, incomplete.
- (for followup) setup-observability/lib/observability restart the node without taking the
  update lock (grep: 0 tn_acquire_update_lock); check whether followup.md lists it.

## Section 4 result (followup.md, read at mtime 02:44:41)
Sampled ~45 items against code; all still open as described except the shellcheck item.
Checked open: create_directories chown -R; UI peers pattern accepts ..; remove-node no-unit exit
leaves UI; helper ref regex allows leading -, server/update-node/setup-node parser refuse;
check-node.state fixed /tmp path; listeners not recorded at keygen (finalize writes empty);
no --bootstrap-peers none / --no-state-export; edit-config leaves BOOTSTRAP_PEERS_FILE/STATE_EXPORT;
refresh git pull + NETWORK refusal; edit written before epoch wait; edit_bls_passphrase return 1
under errexit (lib/common set -euo); image pull before ambiguity check; GNU sed -i;
--binary-path warning before step_welcome clear; update-node prepare message with set +e;
config_dir_for_unit ignores unit; migrate opens 49590/49594; migrate rerun "Nothing to do";
check_ports ss|grep -q; validate_port octal; tn_rpc_call no data; no-record hint lacks
prepare-stake; tn_sync_submodules no 9>&-; Allow-Methods lists GET; no public-ip record;
check-node peers info-only; wss 15 x sleep 0.1; _obs_has_metrics presence only; insufficient
funds string; stream reap grace 2; Config tab lacks new inputs; metrics regex rejects off;
operator_guide unused; no TN_SETUP_BINARY_PATH; install-ui tty-only prompts; no chain 487 in
NETWORKS/NETWORK_PUBLIC_RPC; two status-page hosts; addons/status needs node_type; duplicate
error tail; install.sh wget vs updater curl; FILES_TO_UPDATE expansion under set -u; pdftotext;
--help gaps (captured help); OPERATOR.md hidden anchor; upstream branch 13 commits (ckpt-fu-UP);
keytool --workers help "MUST be 1".
Docs-notes additions all present (listeners, peers file check, ownership SECURITY, tn_rpc_call
data, TPM rotation, worker-0 set-rpc, fixed firewall toggles, metrics addr, streams abort 2 s,
stale-block refresh inbound IP, StakeConfig L2 blocks, CLI README drift, compose 49595, --help
gaps, migrate fixed ports, stale NODE_TYPE). Correctly absent: tn_node_parse_check first-line
item (fixed 8185d00), helper/server config-set fields (fixed 0c8aacf), fwExtraPorts p.allowed
(fixed, index.html fwExtraPorts reads p.allowed).
CHANGELOG "Known remaining" names nothing fixed in the tree.
Findings:
- W3 warn: followup "Maintainer tooling and CI": "Advisory shellcheck warnings remain: SC2206 in
  firewall-setup's kuma_restricted_desc, and SC2034 ... in setup-observability and
  lib/observability.sh". `shellcheck -x --severity=warning $(git ls-files '*.sh')` reports 29
  warnings in 12 files: lib/common.sh 12x SC2034 + 1x SC2206, update-scripts.sh 2x SC2206,
  remove-node.sh 3x SC2034 + 2x SC2115 (rm -rf "/home/${user}", guarded by `id`), update-node.sh
  2x SC1090, and SC2034 in install-ui, setup-node, setup-observer, setup-validator, fallback.
  Reword as "29 advisory warnings remain across 12 files (list)" or scope it to V-OPS-2's files.
- N10 note AGENTS.md: "each before it stops the node or edits the files the restart depends on"
  reads as wait-before-edit; edit-config and the observability add-on write the launch file
  before the wait (followup.md records the edit-config case). Say "before it stops the node
  (install-caddy also before it edits node-info.yaml)".
- N3 (section 1) is already tracked by followup "Library" item 1; drop it.

## Final report
No `error` findings. 3 warns (W1 CHANGELOG Security lacks the dash-ref hardening; W2 AGENTS
boundary list omits open-ui.sh; W3 followup shellcheck item understated), notes N1, N2, N4-N10
(N3 dropped: tracked in followup). Mtimes unchanged at hand-back. Report returned via
SubagentHandback.
