status: DONE (all 6 sections; handed back)
owner: B2 (setup-node.sh only, SCRIPT_VERSION 1.1.0 -> 1.2.0)

## Completed sections
1. Read first -- DONE
   - Interactive main: parser -> init_public_rpc_flags -> step_welcome (`clear`!) -> step_preflight
     -> step_config (prompt_public_rpc only when no --no-public-rpc / domain / RPC_PRIVATE_NOTE)
     -> step_create_infrastructure -> step_generate_keys -> step_write_config
     -> step_create_service (.node-meta heredoc, then start, sets NODE_STARTED) -> step_public_rpc
     -> step_testnet_addons -> step_final_summary.
   - JSON: parser -> run_json_mode: json_setup_fds -> trap json_on_exit -> init_public_rpc_flags
     -> check_root -> json_set_network -> keygen: step_preflight, step_config, step_create_infrastructure,
     step_generate_keys | finalize: step_write_config, step_create_service (.node-meta), step_public_rpc (if domain).
   - Domain var: PUBLIC_RPC_DOMAIN, normalised in the parser by normalize_rpc_domain (strip ws, lowercase,
     drop one trailing dot); validated in init_public_rpc_flags via validate_rpc_domain (error -> exit 1,
     json error event). RPC_DOMAIN_GIVEN tracks an empty --rpc-domain.
   - JSON detection: json_mode() (JSON_MODE=true set before run_json_mode). print_* go to stderr in JSON mode.
   - Design decision: interactive warnings printed in init would be wiped by step_welcome `clear`, so
     warnings live in a separate public_rpc_url_warnings (JSON: end of init; interactive: step_config
     after the RPC-access decision) -- same pattern as public_rpc_no_domain_notice.
   - Extra stale line refs found: guard comment cites lib/common.sh:1073-1076; parser comment says
     "line-43 default". Fix both (no line numbers rule).
2. derive_public_rpc_urls -- DONE
   - New global RPC_ADVERTISE_DERIVED=false (next to ADVERTISE_RPC_*).
   - derive_public_rpc_urls (after init_public_rpc_flags): fills only empty ADVERTISE_RPC_HTTP=https://d/
     (sets DERIVED=true), ADVERTISE_RPC_WS=wss://d/, PUBLIC_RPC_URL=https://d, PUBLIC_WS_URL=wss://d.
     Called at end of init_public_rpc_flags and end of prompt_public_rpc.
   - setup_warn (print_warn + json `log` "WARNING: ..." in JSON mode); public_rpc_url_warnings: ws-without-http
     (no domain) ignored; explicit http/ws differing from domain URLs replaced by rpc-enable.
     Called: end of init_public_rpc_flags (JSON only), step_config interactive after RPC-access decision.
3. step_generate_keys -- DONE
   - New keytool_supports_rpc_args (before step_generate_keys): captures `docker run --rm IMG telcoin keytool
     generate validator --help` (docker) or `$BINARY_PATH keytool generate validator --help`; match *--rpc-http*.
     Captured (not piped) so pipefail/SIGPIPE cannot false-negative; failure reads as unsupported.
   - Before print_step "Generating validator keys...": if DERIVED && probe fails -> setup_warn, clear both
     ADVERTISE_*, DERIVED=false. `local rpc_args=()` built once; both calls expand ${rpc_args[@]+"${rpc_args[@]}"}.
     Duplicate per-branch blocks + leaked global removed.
4. Header + comments -- DONE
   - Header: new "RPC URLS" block documenting --rpc-http/--rpc-ws/--public-rpc-url/--public-ws-url + precedence.
   - NODE_TYPE comment: validator view follows on-chain stake status (ConsensusRegistry getValidator), not tn_isValidator.
   - Guard comment: dropped lib/common.sh:1073-1076, check-node.sh:119, update-node.sh:894 refs.
   - Parser comment: "line-43 default" -> "ENABLE_HEALTHCHECK_MONITOR default".
   - public_rpc_pending: info line (+ JSON log) when node-info already advertises https://d/; withdraw with
     install-caddy.sh --phase=rpc-disable. New helper public_rpc_node_info (shared with step_public_rpc).
5. step_preflight + version -- DONE
   - After check_hardware, JSON mode: json_event log "hardware: ${TN_HW_SUMMARY:-unknown}"; if ${TN_HW_GAPS:-}
     non-empty: json_event log "WARNING: hardware below the minimum for: ${TN_HW_GAPS} (setup continues)".
   - SCRIPT_VERSION 1.2.0. Gates so far: /bin/bash -n OK, brew bash -n OK, shellcheck -x --severity=error OK,
     no new shellcheck warnings vs b5d912b.
6. Harness -- DONE (dir scratchpad/B2: new.sh, base.sh, prelude.sh, cases.sh, interactive.sh, stubs/)
   - cases.sh (a)-(e) PASS on /bin/bash 3.2 + brew bash 5 (fleet keygen/finalize unchanged, no warnings;
     domain normalised+derived; explicit http wins + WARNING log; ws-only warning; trailing --rpc-http exit 1,
     JSON error event + done ok:false).
   - interactive.sh PASS both bashes: no warnings at init; step_config warns after decision; prompt path derives.
   - Found pre-existing bash-4-only `${response,,}` in lib/common.sh confirm() (at b5d912b too) -> open issue (not my file).
   - kg-cases.sh (keygen.sh drives main --json --phase=keygen -> real step_generate_keys, docker/tnbin stubs log argv):
     fleet keygen docker argv AND binary argv byte-identical new vs b5d912b on bash 3.2 + 5 (and bash3 == bash5);
     no keytool probe on fleet path. No rpc flags: new OK on 3.2; b5d912b aborts on 3.2 with
     "rpc_args[@]: unbound variable" (done ok:false) -- the fixed bug. Derived + --help has --rpc-http -> args
     present, 0 warnings; --help lacks it -> args cleared + one WARNING log event (docker and binary).
     All JSON stdout pure (grep -v '^{' empty).
   - preflight.sh: JSON step_preflight emits "hardware: <summary>" + "WARNING: hardware below the minimum for:
     validator (setup continues)"; no gaps -> only summary; lib without TN_HW_* -> "hardware: unknown"; stdout pure.
   - pending.sh: public_rpc_pending adds the live-advertisement info line (+ JSON log) only when node-info.yaml
     already has https://d/.
   - Final gates: /bin/bash -n OK, /opt/homebrew/bin/bash -n OK, shellcheck -x --severity=error OK,
     no new shellcheck warnings vs b5d912b.

## Draft (a): README changelog entry

### setup-node v1.2.0 — one domain, one advertisement; hardware gaps in the setup log
`--rpc-domain <hostname>` now fills in the RPC URLs that were separate flags. With a domain
and nothing else, keygen writes `https://<domain>/` and `wss://<domain>/` into
`node-info.yaml`, and `.node-meta` records `PUBLIC_RPC_URL=https://<domain>` and
`PUBLIC_WS_URL=wss://<domain>`. Explicit `--rpc-http`, `--rpc-ws`, `--public-rpc-url` and
`--public-ws-url` still win and are used as given, so the devnet fleet's keygen command
line is byte-for-byte the same as before. All four flags are now documented in the script
header.

When the URLs come from the domain, setup first asks the keytool whether it knows
`--rpc-http`. An older release that doesn't gets a plain keygen and a warning; the
advertisement then lands when `install-caddy.sh --phase=rpc-enable` runs after the node
starts. When keygen already wrote the same URLs, `rpc-enable` finds them in place and does
not restart the node. Setup warns when `--rpc-ws` comes without `--rpc-http` (it is
ignored) and when an explicit URL differs from the domain (`rpc-enable` will replace it).
If public RPC is left pending while `node-info.yaml` already advertises the URL, setup
says so and prints the `--phase=rpc-disable` command to withdraw it.

In `--json` mode the setup log now carries the hardware check: a `hardware:` line with the
summary and, when the box is below the minimum for a role, a `WARNING:` line naming it.
Setup still continues. Keygen no longer aborts on bash 3.2 when no advertised-RPC flags
are passed (an empty argument array under `set -u`).

## Draft (b): commit message

feat(setup-node): derive advertised RPC URLs from --rpc-domain; hardware gaps in the setup log

--rpc-domain <d> now fills any of --rpc-http/--rpc-ws (https://<d>/, wss://<d>/) and
--public-rpc-url/--public-ws-url (https://<d>, wss://<d>) left empty; explicit flags win,
so the fleet keytool argv is unchanged. Derived URLs reach keygen only when the keytool's
--help lists --rpc-http; otherwise rpc-enable advertises them after start. Build rpc_args
once and expand it safely, fixing the bash < 4.4 empty-array abort under set -u. Warn on
--rpc-ws without --rpc-http and on explicit URLs that differ from the domain. --json
preflight logs the hardware summary and below-minimum roles. SCRIPT_VERSION 1.2.0.
