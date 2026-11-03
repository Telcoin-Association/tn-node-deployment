status: done

## Sections
- [x] 1. tools/check-network-hits.sh (lint), commit 77dff25 (amended from b3f289f to tighten the line-above rule)
- [x] 2. tools/tests/network_hits_test.sh (fixture tree, 51 checks), commit 7ae4845
- [x] 2b. help printers of setup-node/edit-config/update-node skip marker lines (their header block is --help and holds 9 hits), commit 98be26f; --help output byte-identical
- [x] 3. annotation sweep: 140 markers applied, lint clean (148 hits incl. 7 marker lines naming adiri), commit 4e77031
- [x] 3b. network_hits_test.sh also runs the lint over the repository (53 checks), commit b2babdf
- [x] 4. gates: all green (see Tests run)

## Operator-visible changes
None. The help printers of setup-node.sh, edit-config.sh and update-node.sh skip `# network-gated:` lines, so --help prints exactly what it printed before (checked byte for byte). The embedded Alloy fallback (lib/observability.sh _obs_alloy_fallback, written only when observability/config.alloy is missing) gains one `//` comment line in its header.

## Docs notes
- Lint: `tools/check-network-hits.sh [--list] [ROOT]` (ROOT default: the repository the tool lives in; no git needed). Exit 0 clean (stderr "check-network-hits: clean, N annotated hit(s) in M file(s) scanned"), 1 unannotated hits (stdout `FILE:LINE: <trimmed line>` each, plus a summary on stderr), 2 usage error / missing or unreadable scanned file / lib/testnet-addons.env value missing or not literal. `--list` prints every hit as `FILE:LINE: <reason> -- <line>` (reason "unannotated" when none) and the patterns on stderr. `--help`.
- Hits: `adiri` in any case anywhere on the line, and the hosts read at run time (as text, never sourced) from lib/testnet-addons.env: host of OBS_PUSH_URL_TESTNET and OBS_METRICS_PUSH_URL_TESTNET (obs.adiri.telcoin.network), address of TN_WG_HUB_ENDPOINT without the port (34.20.198.253), address of TN_KUMA_SRC without the prefix (104.155.184.201). Addresses match as text (a longer address containing one counts).
- Scope: lib/*.sh (not lib/wgvpn/), root *.sh, ui/server.py, ui/telcoin-ui-helper.sh, ui/static/index.html, observability/config.alloy. Not: common/, tools/, tests, CHANGELOG*, tasks/, followup.md, docs/, *.md, lib/testnet-addons.env, *.sha256 (and ui/install-ui.sh, lib/release-keys/README, which the spec leaves out).
- Marker: `network-gated:` right after a comment opener (`#`, `//`, `<!--`, `/*`), then a reason with a letter or digit; `-->`/`*/` are not part of the reason. A hit passes when its own line carries the marker, or the line right above is a marker line (nothing but the marker comment). A trailing marker covers its own line only. Forms: shell/Python `# network-gated: <reason>`, JavaScript/Alloy `// network-gated: <reason>`, HTML `<!-- network-gated: <reason> -->`. Inside a script's --help header (setup-node, edit-config, update-node) a marker line is left out of --help. Inside a Python docstring a marker cannot go: put the name on the docstring's first line and the marker comment between def and docstring.
- CI: GOV wires `bash tools/check-network-hits.sh` into "hardening lints"; tools/tests/network_hits_test.sh runs in the fixture-test jobs.
- Annotated lines per file (markers added by NET-2: 140; plus 1 by UI-S): lib/common.sh 53, setup-node.sh 17, ui/server.py 18 (+1 UI-S STATUS_PAGE_LINKS = 19), ui/static/index.html 12, lib/observability.sh 11, edit-config.sh 6, install-caddy.sh 6, update-node.sh 5, ui/telcoin-ui-helper.sh 5, check-node.sh 3, observability/config.alloy 2, remove-node.sh 1, setup-vpn.sh 1. Lint total 148 = 141 annotated hit lines + 7 marker lines that name adiri.

## Tests run
- lint on the pre-sweep tree: 141 hits, 140 unannotated, rc 1, same output under bash 5.3 (gawk), gawk --posix, bash:3.2 (busybox), ubuntu:24.04 (mawk)
- lint on the swept tree: rc 0, "clean, 148 annotated hit(s) in 23 file(s) scanned" under bash 5.3, bash:3.2, ubuntu:24.04
- network_hits_test.sh: 51 checks, 0 failures under bash 5.3, bash:3.2, ubuntu:24.04, gawk --posix
- bash -n (5.3 and 3.2), check-bash32 (12 files clean), shellcheck 0.11 and v0.9.0 --severity=error clean on the lint, the test and every annotated .sh
- python3 -m py_compile ui/server.py ok; pytest python:3.10-slim 277 passed (1125 subtests)
- bash ui/tests/helper_test.sh (5.3): 548 checks, 0 failed
- check-perl-interp over git ls-files *.sh: clean, 103 files
- no-behaviour-change proofs: `bash --pretty-print` of every scanned .sh identical before/after apart from blank lines, the Alloy fallback heredoc line and the help-printer filter; Python AST identical apart from the latest_source_tag docstring; index.html and config.alloy identical once the markers are stripped; node --check (node:22-slim) of the page script ok before and after; --help of setup-node, edit-config, update-node byte-identical
- full suite bash tools/tests/run.sh (5.3): 61 test files, 0 failed (60 baseline + network_hits_test.sh)
- network_hits_test.sh with the tree check: 53 checks, 0 failures under bash 5.3, bash:3.2, ubuntu:24.04

## Open issues
Real gaps (not annotated as safe; no code changed):
1. edit-config.sh edit_docker_image: `print_info "Enter a ${net} release tag (such as ${DEFAULT_DOCKER_TAG}) ..."` runs for every non-devnet network, so on mainnet it would suggest the testnet tag v0.16.0-adiri. Unreachable on mainnet today (tn_docker_network_ok refuses mainnet until the chain-config pins exist), reachable once mainnet ships. The lint cannot see it (a variable, not a literal). Fix: a per-network example as setup-node's _setup_tag_example does (mainnet v1.0.0).
2. remove-node.sh custom-container scan: `grep -E 'telcoin-network/tn-public|/tn-public/|-adiri'` misses containers that run the ghcr repository by digest or with a mainnet tag (ghcr.io/telcoin-association/telcoin-network@sha256:..., :v1.0.0), so a hand-made mainnet container (or a digest-pinned testnet one) is not offered for removal. The line itself is safe on mainnet (annotated as finding leftover testnet-image containers); the gap is the missing ghcr pattern.
Wording follow-ups (annotated truthfully as "shown on every network"): testnet tag forms and adiri hostnames as examples that a mainnet operator also sees: edit-config.sh bootstrap-peers "Needs v0.15.0-adiri or later." and the state-export menu labels; setup-node.sh require_node_flag refusal labels (v0.13.0-adiri, v0.15.0-adiri) and node7.adiri.telcoin.network in the public-RPC prompt and the --rpc-domain/--rpc-url errors; update-node.sh existing_update_refusal "TAG is the release, such as vX.Y.Z-adiri"; check-node.sh --observer warning; install-caddy.sh same-domain messages and both domain prompts; ui/static/index.html DEFAULT_RPC_HOST placeholder. A network-neutral host (node1.example.com) and per-network tag examples would drop those markers.
Deviations to review:
- 98be26f changes code in setup-node.sh, edit-config.sh, update-node.sh (the --help printers skip `#[ \t]*network-gated:` lines). Their header block is their --help and holds 9 hits (setup-node 5, edit-config 3, update-node 1); without the filter the markers would print in --help. Output byte-identical. Dropping it means dropping those 9 markers, and the lint then fails there.
- Pass rule tightened vs the spec wording: the line above counts only when it is a marker line; a code line's trailing marker covers its own line only (the fixture showed the literal rule letting a CSS line's marker vouch for the next line).
- lib/observability.sh _obs_alloy_fallback heredoc gained one `//` marker line (emitted only when observability/config.alloy is missing; River statements unchanged, obs_test passes).
- ui/server.py latest_source_tag docstring reordered so the tag forms sit on its first line (a marker cannot go inside a docstring).
- Scope per spec leaves out shipped files with hits: ui/install-ui.sh (UI_BUNDLE, one comment line, the release tag form) and lib/release-keys/README (prose). Consider adding ui/install-ui.sh to the scope later.
Spec vs code: "server STATUS_PAGE_BASE" is STATUS_PAGE_LINKS (already marked by UI-S); the shared facts say deploy-networks-common is the Alloy upstream now, but docs/testnet-addons.md "Sync note" and the config.alloy header still name adiri-genesis (not changed here; the markers say "names the upstream ... not an endpoint").
