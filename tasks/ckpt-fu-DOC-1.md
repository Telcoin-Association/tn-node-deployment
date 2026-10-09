status: done
package: DOC-1 (README.md only)

## Sections
- [x] 1. Reference sections brought up to date
- [x] 2. Public node tuning subsection
- [x] 3. Changelog entries
- [x] 4. Consistency pass (grep check)
- [x] 5. Closing headings (what changed, grep output, open issues)

## Notes
- Sources read: spec-fu-shared, fu-docs-notes, AGENTS.md, all 16 implementer checkpoints
  (operator-visible + changelog + fix passes), README in full, every script's --help (captured
  in <scratchpad>/doc1/help-*.txt), the v0.15.0 binary's node/keytool help
  (<scratchpad>/doc1/binary-help.txt), and the script sources where the help was silent.
- install-caddy, firewall-setup, setup-observability and remove-node need root even for --help;
  their flags come from the header comments and case arms.
- 2 MB cap facts: client gets 413; reth gets headers + first 2,000,000 bytes, never a complete
  request (V-OPS-1, A open issue 2); cap on the JSON-RPC handler only.
- Legacy docker units (before 8def9c2) inline `docker run ... -e "TN_BLS_PASSPHRASE=<v>"`;
  migrate-node-naming refuses a bare ExecStart unit; no script converts one.

## What changed (README.md, +839 / -67, nothing else edited)

Reference sections:
- What's Included: rows for prepare-stake.sh, install-caddy.sh, migrate-node-naming.sh.
- Run a node: ports "by convention" (real ones shown by check-node/firewall-setup); validator
  view read by prepare-stake too, UI asks the network first (shows the validator view during sync).
- One node per VM: the NODE_TYPE sentence replaced (removed by setup-node 1.3.0 / migrate 1.2.1;
  a stale line from migrate 1.2.0 is harmless, nothing reads it).
- Hardware: physical cores (lscpu, /proc/cpuinfo, sysctl), "N logical CPUs" fallback.
- Quick Start: firewall line (node's P2P ports, 80/443 with a Caddy site); prepare-stake in
  day-to-day.
- What the Setup Script Does: testnet floor v0.13.0-adiri; runner recorded in .node-meta at
  step 4; node-flag release check + peers map install; wrapper passes the peers file; summary
  lists every advertised P2P port and links OPERATOR.md.
- System Layout: bootstrap-peers.yaml, consensus-db/state_exports; table of .node-meta keys the
  scripts read back (NETWORK, INSTALL_METHOD/DOCKER_IMAGE/BINARY_PATH, BOOTSTRAP_PEERS_FILE,
  STATE_EXPORT, PUBLIC_RPC_*, VALIDATOR_ADDRESS); key-by-key updates.
- Firewall / Router: P2P ports follow the node (launch file, node-info.yaml, defaults).
- Validator Onboarding Flow: prepare-stake pointer; endpoint note (rpc.adiri.tel is testnet,
  rpc.telcoin.network = mainnet, not launched, answers 2017 today); keytool export with
  `-q --bls-passphrase-source no-passphrase`; stake amount via getCurrentStakeVersion() +
  stakeConfig(uint8) (getCurrentStakeConfig() removed); all cast commands on rpc.adiri.tel;
  E+1 / E+3 arithmetic; unstake eligibility from check-node; status table + staked-validator
  sentence (check-node judges by committee membership).
- NEW "## Prepare to stake": usage, the nine checks in order, printed commands, --json, exit
  codes 0-4, lib 1.6.0 need; "### Staking from another address" (--rotate-address, --yes,
  --no-restart, refusals incl. update lock message, passphrase order and the 600 rule, TPM note,
  never on a command line, never sends a transaction).
- Health Check: --network-rpc default; Network line and chain-id rules incl. the
  rpc.telcoin.network-serves-2017 warning; service section contents; author presence (tn_info
  authority id, --authority-id fallback, committee rule, membership-unreadable rule, local
  fallback); epoch & committee section (boundary in UTC, seats for 3 epochs, activation +2,
  Observer-in-committee warning, worker count vs numWorkers, extra worker probes); Exited
  validator unstake eligibility, failure reason; public RPC warnings (stale block, --http.api /
  --ws.api with debug/trace/admin/all); macOS df -Pk / memory skipped / CPU line; older lib
  warning; value flag usage error; "Why RPC" paragraph fixed (local RPC closed -> --authority-id).
- Firewall Setup: status labels + fixed status crash note; enable allows 80/443 with a Caddy site;
  Manage node ports follows the node; warning bullet; NEW "### JSON mode (Node Manager UI)"
  (p2p_ports objects, allowed null while ufw off, --port allowlist unchanged, older lib).
- Binary Installation Options: --binary-path and search paths; testnet floor paragraph.
- NEW "## Restarts and the epoch boundary": which scripts wait, the policy, env-var table
  (TN_SKIP_EPOCH_WAIT, TN_EPOCH_MARGIN 300, TN_EPOCH_SETTLE 90, TN_EPOCH_WAIT_MAX 1800 / 0 off,
  TN_EPOCH_POLL 15, 5-20), --no-epoch-wait, sudo VAR=..., hand restarts never wait.
- NEW "## Editing the configuration": examples, menu 1-13 table + renumbering note, --set field
  table (metrics off, digest images, bootstrap_peers, state_export, allow_private_forward_targets
  refused on 2017/487), how an edit runs (release check, rollback incl. parameters.yaml and peers
  file, no-op edits, update lock message, epoch wait, two-command refusal, refresh chain configs,
  lib 1.6.0); "### Bootstrap peers" (shape from a fixture the v0.15.0 parser accepted, 64 KiB,
  world-readable rule and why, parser reason without quoting, install path/mode, read at every
  start, missing/empty file stops the node, none, unit-started refusal); "### Converting a
  unit-started node to a start wrapper" (6-step manual procedure mirroring setup-node's Docker
  wrapper and unit).
- NEW "## Updating the node": phases, flags, epoch wait (4 paths, lib < 1.5.0), --observer strip,
  ref rules (no floor, "-" refused at prompt and --ref, --ref without value), JSON contract.
- Key Backup: --rotate-address pointer.
- Keeping Scripts Up to Date: fallback.sh pair; integrity paragraph (download, bash -n, sha256,
  fail closed with the exact FAILED text, separate counts, exit 1, self-check, bash 3.2).
- Web UI: install order and failure behaviour, redeploy + outdated banner; dashboard ufw rules even
  while ufw is off; Jaeger service name; NEW Setup wizard, System tab, Validator view,
  Long-running actions subsections; Security model rewritten for the visudo/last-swap rule,
  engine copies, helper API 2, config-set fields (and that the page lacks inputs for three).
- Public RPC endpoint: Caddy 2.8.0 floor; block v2 bullets (case-insensitive upgrade, OPTIONS,
  405 page, 2 MB = 2,000,000 bytes with the 413 + cut-connection fact, ~256 KiB largest request,
  WebSocket not capped, no timeouts/per-IP); rpc-enable steps 1-7 (ufw while off, no-op path,
  epoch wait, --ws placement/refusal, keytool set-rpc worker 0 + python fallback, restart,
  .node-meta); older lib behaviour; JSON refusals; stale block + refresh; backups pruned to 5
  (tn-orig and current backup kept); rpc-disable details incl. multi-worker caveat.
- Quick Reference: NEW "### Networks and endpoints" table (testnet/devnet/mainnet, chain ids,
  RPCs, telscan.io + www.telscan.xyz) + rpc.telcoin.network note; comparison endpoint;
  prepare-stake in Scripts; setup-node flags table (URL schemes, --public-ip validation,
  --bootstrap-peers, --enable-state-export, --state-export-keep, -h/--help, finalize read-back,
  --install-method, --build-ref, --docker-image floor, --binary-path) + URL warning paragraph +
  JSON contract paragraph (checks before root, one done, operator_guide, public_rpc, 1.2.1
  keygen needs --binary-path, lib 1.6.0).
- Testnet Add-ons: observability flags paragraph (comments ignored, epoch wait, Alloy never waits,
  reasons, not recorded / no restart / ok:false).
- Contributing (maintainer heading): bash 3.2 lint (what it flags, CI on both runners, how to run,
  # bash32-ok) and UI tests.
- Support: support@telcoin.org only.

Section 2: "### Public node tuning" at the end of the Public RPC section (request-limit and
rpc-cache tables with v0.15.0 defaults and labelled unmeasured starting points; how to add by
editing the start wrapper; no per-IP limits (carrier NAT, no stock rate limiter); no timeouts
(WebSocket, long eth_getLogs); --http.api/--ws.api must not include debug, trace, admin, all).

Section 3, Changelog (newest first, after the versioning note): update-scripts v1.1.70,
telcoin-ui v1.9.0, install-ui v1.4.0, prepare-stake v1.0.0, setup-node v1.3.0, edit-config
v1.3.0, update-node v1.2.0, install-caddy v1.4.0, check-node v1.2.0, firewall-setup v1.6.0,
setup-observability v1.2.1, remove-node v1.2.9, migrate-node-naming v1.2.1, lib/common v1.6.0
(1.5.0 folded in, stated), lib/fallback v1.0.3, lib/observability v1.0.2, and an unversioned
"Maintainer tools" entry. One-line correction under install-caddy v1.3.0 ("never pruned").

## Grep check output

Script: <scratchpad>/doc1/doc1-check.sh; full output: <scratchpad>/doc1/check-out.txt. rc 0, PASS.
- Flags: 93 distinct long flags; 29 in a script --help, 27 in the v0.15.0 binary help
  (node/keytool), 36 only in a script parser or source, 1 external, 0 unknown. Parser-only
  includes setup-node's --json flags (--binary-path, --build-ref, --docker-image,
  --install-method, --network, --data-dir), update-node's --check/--prepare/--ref, the root-only
  scripts' flags (--move-dashboard-to, --status, --enable, --reset, --port, --remove), setup-vpn's
  (--apply-firewall, --sync-keys, --disable), install-ui --update, and cast/curl/git flags quoted
  in lib text.
- Script-attributed flags: 3 hits, all line-wrap false positives (`--set` on an edit-config
  changelog line that also names update-node.sh; `--no-public-rpc`/`--rpc-public` on a setup-node
  v1.1.0 changelog line that names install-caddy.sh).
- edit-config --set fields: all 8 present in edit-config --help.
- URLs: all canonical (rpc.adiri.tel 17, rpc.telcoin.network 7, rpc.devnet.telcoin.network 3,
  telscan.io 3, www.telscan.xyz 1, docs/github/install/copy.fail/caddyserver/licences);
  remaining "CHECK" lines are bare schemes ("an `http://` or `https://` URL") and one historical
  changelog mention of the github.com homepage probe. No scan.telcoin.network.
- Line-number references: none (a quoted clap message "at line 1 column 1" was shortened).
- --observer/--validator: 17 lines, all describing removal, stripping or the ignored legacy
  flag; none tells an operator to pass one.
- common/: one mention, the AGENTS.md pointer that calls it maintainer-only tooling operators
  never have.
- Email: support@telcoin.org only (5 occurrences).
- In-README anchors: all 14 resolve; inbound anchors from OPERATOR.md (10) all resolve.
- Tables: column counts consistent in every table.

## Open issues
1. setup-node --help prints only the public RPC and node flags; the --json flags (--phase,
   --network, --install-method, --build-ref, --docker-image, --binary-path, --address, --data-dir
   and the listener/service flags) exist only in the parser. The README documents them from the
   parser. Followup candidate: a JSON section in setup-node's header.
2. update-node --help omits its UI flags (--json, --check, --prepare, --apply, --ref, --yes); the
   README names --ref and --check from the parser.
3. install-caddy.sh, firewall-setup.sh, setup-observability.sh and remove-node.sh refuse --help
   without root. Followup candidate.
4. ui/static/index.html has no inputs for bootstrap_peers, state_export or
   allow_private_forward_targets, and its metrics check rejects "off"; the README says to use
   edit-config.sh on the server for those. Followup candidate for the UI.
5. The unit-to-wrapper procedure mirrors setup-node 1.3.0's Docker wrapper/unit and the legacy unit
   format from commit 8def9c2; it has not been run on a real legacy box (no Docker this session).
6. Public node tuning values are labelled unmeasured; the cache rationale ("wallets and indexers
   send receipt and log queries often") is general knowledge, not a measurement.
7. README links into OPERATOR.md anchors #6-validators-stake-and-activate,
   #64-export-the-stake-calldata-on-the-node and #7-automation (all valid today). If DOC-2
   renumbers OPERATOR.md, these three links need the new anchors.
8. update-scripts.sh still says SCRIPT_VERSION 1.1.69 on disk; the README entry is written for
   v1.1.70, so the release commit must bump it (orchestrator).
9. The human-writing skill's post-step (format-output agent) was not run: it reflows every
   paragraph of the whole README to one sentence per line, which conflicts with this package's
   "keep the existing structure" rule and would touch all historical text. Orchestrator's call.
10. The Validator Onboarding Flow keeps the caveat that the upstream staking guide's signatures are
   out of date; drop it once the tn-5 docs branch (package UP) is merged and deployed.

## Follow-up (coordinator, after the last fix passes)
status: done
- [x] F0. Read fix passes: A (V-OPS-1), B (V-OPS-2), C (V-OPS-2), D (V-OPS-2), L2 (fix pass 4); P4b has no "Fix pass 2" yet (re-check before closing). OPERATOR.md: #6-validators-stake-and-activate and #7-automation exist; #64 is now #610-stake-by-hand (6.10 holds the binary and Docker export commands).
- [x] F1. install-caddy: update lock before node edits, rpc-disable order, hostname normalisation + IPs refused, value flag last = exit 2, done may list open items
- [x] F2. check-node: --http.api warning covers debug/trace/admin (not all); author vs committee counts; mismatch WARN advice; header parser changelog line
- [x] F3. prepare-stake: key sources (--ledger, --trezor, --account, --interactive; never --private-key); interrupted rotation
- [x] F4. firewall/observability: ufw allow failure in --json; default_incoming unknown; one restart for logs+metrics; METRICS_PORT; rehearsal before Alloy
- [x] F5. library: CRLF .node-meta read and rewritten with LF
- [x] F6. OPERATOR.md anchors (#64 -> #610-stake-by-hand; check the other two)
- [x] F7. P4b "Fix pass 2 (free-text inputs)" exists but is in progress (FY1-FY4 unchecked; setup-node.sh has uncommitted +156/-27 work): not documented, open issue recorded.
- [x] F8. Changelog clauses (install-caddy, check-node, prepare-stake, firewall, observability, lib/common)
- [x] F9. Re-run doc1-check.sh: PASS (rc 0); output in <scratchpad>/doc1/check-out-2.txt

### Follow-up: sections touched (README.md now +889 / -71 against HEAD)
- DNS first: hostname normalisation (trim, lowercase, one trailing dot) and IP addresses refused.
- What `rpc-enable` does: steps reordered to plan first (dry-run --ws, node-info check), take the
  update lock when a node change follows (refusal text, nothing changed), then site, wait, --ws,
  set-rpc, restart (rollback message names journalctl), .node-meta + lock release; new paragraph
  on open items in a successful run; older-lib paragraph adds the lock warning (< 1.5.0) and the
  value-flag-last usage error (exit 2).
- Turn it off: site first (reload, no lock, no wait), .node-meta keys, then lock + wait + clear +
  restart only when worker 0 still advertises; refusal leaves the site removed.
- Health Check: new "Execution address" bullet (mismatch WARN, offline too, the two pieces of
  advice); "N authors in the latest commit"; author bullet says why the authority id is unknown
  and that the unreadable-membership rule uses the node's own address; epoch bullet adds
  "Committee of epoch E: N members (on-chain)", the Observer and workers advice
  (support@telcoin.org); reputation key `sub_dag.reputation_scores` (singular fallback); public
  RPC warning covers debug/trace/admin, not a list starting with `all`.
- Public node tuning: rule now debug/trace/admin; explains `all` and `all,debug` in v0.15.0-adiri
  (dropped the unverified "other reth builds" sentence).
- Prepare to stake: signing note (--ledger, --trezor, --account via cast wallet import,
  --interactive; never --private-key, visible with ps); exit codes 130/143/129; interrupted
  rotation paragraph (keytool finishes, node-info restored, lock released; or "To finish, run").
- Validator Onboarding Step 3: signing line aligned (--account keystore, --interactive caution,
  never --private-key).
- System Layout: VALIDATOR_ADDRESS row notes check-node's comparison; CRLF line under the table.
- Firewall Setup: status with a failing `ufw status verbose` (unknown policy); enable stops at a
  failing rule step before ufw is enabled; JSON mode: no-node p2p_ports null, default_incoming
  unknown, error + done ok:false on a failed rule step.
- Testnet Add-ons: one restart for logs+metrics; inputs validated (METRICS_PORT 1-65535) and the
  launch-file edit rehearsed before Alloy, so a failure changes nothing; value flag without value
  is an error; restart hint via edit-config item 12.
- OPERATOR.md link: #64-export-the-stake-calldata-on-the-node -> #610-stake-by-hand
  (#6-validators-stake-and-activate and #7-automation still exist).
- Changelog clauses added to the unreleased entries: install-caddy v1.4.0 (lock, disable order,
  hostnames/IPs, exit 2, open items), check-node v1.2.0 (authors vs committee, mismatch WARN and
  advice, next steps, reputation key, header parser no longer evaluates RPC strings, warning list
  without `all`), prepare-stake v1.0.0 (signals, rotation interruption, signing note),
  firewall-setup v1.6.0 (failing rule step, unknown default policy), setup-observability v1.2.1
  (one restart, value flags, restart hint), lib/observability v1.0.2 (input validation,
  rehearsal before Alloy, obs_status on empty /metrics), lib/common v1.6.0 (CRLF meta, ufw reads
  under pipefail), lib/fallback v1.0.3 (CRLF in _tn_meta_get).

### Follow-up: check result
doc1-check.sh rc 0, PASS. 97 long flags, 0 unknown (29 in a script --help, 27 in the binary
help, 40 parser/source only, 1 external; new: --account, documented in prepare-stake's note).
Script-attributed hits: 4, all line-wrap false positives (the earlier 3, plus check-node's
--no-network on the Execution address line that names prepare-stake.sh). URLs canonical; no
line-number references; --observer/--validator lines descriptive only; common/ only in the
maintainer pointer; email support@telcoin.org only; 14 in-README anchors and the 3 OPERATOR.md
anchors resolve; all tables consistent.

### Follow-up: open issues
- P4b "Fix pass 2 (free-text inputs)" is in progress (FY1-FY4 unchecked; setup-node.sh carries
  uncommitted +156/-27 work). Not documented. Once it lands, add one line to "What the Setup
  Script Does" (prompts and flags for ports, IPs, multiaddrs, directories, image, binary path and
  address are validated and re-asked before they reach the wrapper, unit or .node-meta) and one
  clause to the setup-node v1.3.0 changelog entry.
- README's unit-to-wrapper section could link OPERATOR.md 4.8 ("Give a unit-started Docker node a
  start wrapper"); not added (not asked; DOC-2 owns that section's wording).

### Follow-up 2 (setup-node "Fix pass 2", committed as babb69d)
status: done
- [x] Read tasks/ckpt-fu-P4b.md "Fix pass 2 (free-text inputs)" (status done; setup-node.sh clean
      against HEAD babb69d; validate_setup_path is ^/[A-Za-z0-9._/-]+$ without "..").
- [x] "What the Setup Script Does": new paragraph after the Step 7/8 bullets (README line 249):
      every answer and flag reaching the wrapper, unit or .node-meta is validated; prompts ask
      again (ports 1-65535, data/config/log/install directories with the path rule, Docker image,
      binary path, execution address 0x + 40 hex, P2P listener and external addresses); a bad
      flag stops before root with the flag named; a --json keygen needs --address; the region
      label is reduced to letters, digits, _ and -, at most 32, with a warning.
- [x] setup-node flags table: --binary-path row adds the charset (line 1323); --address row adds
      the format and "Required for a --json keygen" (line 1324); --data-dir row adds the path
      rule (line 1325).
- [x] JSON contract paragraph (line 1329): the refusal list adds address, directory, multiaddr,
      passphrase method, service user/group and a keygen without --address; done msg names the
      flag; finalize checks the read-back install method, image and binary path.
- [x] setup-node v1.3.0 changelog, first paragraph (from line 1558): "Every answer and flag that
      reaches the start wrapper or .node-meta is validated: ..." sentence.
- [x] doc1-check.sh: rc 0, PASS (<scratchpad>/doc1/check-out-3.txt); 97 flags, 0 unknown; the same
      four line-wrap false positives; all tables consistent. README now +897 / -73 against HEAD.
- The "P4b Fix pass 2 not documented" open issue above is resolved by this pass.

### Follow-up 3 (independent docs review: ckpt-fu-V-DOC.md, ckpt-fu-V-DOC-R1.md)
status: done
- [x] R0. Read V-DOC, V-DOC-R1, P5 "Fix pass 3 (V-DOC)", P4b "Fix pass 3 (V-DOC)", P6 "Fix pass 3 (V-DOC)", commit 13f6309, updater clear fix
- [x] R1. (error 1) Web UI Long-running actions: config save interrupted during the wait (P5 fix pass 3 decides wording)
- [x] R2. (warn 7) Restarts section: name the scripts that wait; migrate-node-naming and UI Start/Stop/Restart, trace toggles, node-name change restart at once; only CvvActive waits
- [x] R3. (warn 8) setup-node flags: keygen without --address (P4b fix pass 3 decides)
- [x] R4. (warn 9) rpc-enable older-lib paragraph: <1.6.0 no --ws, python editor; <1.5.0 also no wait, no lock
- [x] R5. (warn 10) Refresh chain configs copies parameters.yaml: set allow_private_forward_targets again (text + menu table)
- [x] R6. (warn 11) unit-to-wrapper: binary/source variant or re-run setup-node.sh
- [x] R7. (warn 14) Full staking guide link 404: replace with https://docs.telcoin.network/ or drop
- [x] R8. notes 20-28 (refresh on a tag, peers refused before the binary, exit table rows, To finish line, Step 2 header, validator view epochs, --binary-path interactive, floor sentence, security model steps 11/12, wrap correction line, updater clear + --help/unknown args, update-node existing installs)
- [x] R9. Re-run doc1-check.sh: PASS (rc 0), <scratchpad>/doc1/check-out-5.txt

#### Follow-up 3: sections touched (README.md now +920 / -77 against HEAD)
- Web UI "Long-running actions" (R1): update wait changes nothing; a config save stopped before its
  restart is rolled back (`rolled_back: true`), the edit stays once the restart is issued. P5
  "Fix pass 3 (V-DOC)" is marked done (edit-config.sh change is in the working tree, not yet
  committed; latest commit 59d10a0). Matching bullet added under "Editing the configuration"
  (signals 130/143/129, the exact message, Refresh chain configs exception) and one clause in the
  edit-config v1.3.0 changelog entry.
- "Restarts and the epoch boundary" (R2, note 19): "These scripts check before they restart"
  (update-node, edit-config, install-caddy rpc-enable/disable, setup-observability, prepare-stake
  --rotate-address); migrate-node-naming and the UI Start/Stop/Restart buttons, trace toggles and
  node-name change restart at once; only CvvActive waits (Observer and CvvInactive not delayed).
- setup-node (R3, P4b "Fix pass 3" done): "What the Setup Script Does" paragraph, the JSON
  contract paragraph and the setup-node v1.3.0 changelog say a --json keygen without --address,
  the four multiaddr flags or TN_BLS_PASSPHRASE stops before root (no build first); flags intro
  adds --binary-path as interactive-capable (note 26).
- "What rpc-enable does" older-lib paragraph and install-caddy v1.4.0 changelog (R4): < 1.6.0 no
  automatic --ws + python3 editor; < 1.5.0 also no epoch wait and no update lock.
- "Editing the configuration" (R5, note 20): menu row 11 and the refresh bullet say it replaces
  genesis/committee/parameters.yaml, so set allow_private_forward_targets (item 10) again; tag
  build: git's error + "git pull failed in <dir>. Chain configs unchanged."
- Bootstrap peers (note 21): "before the map reaches the node binary".
- Unit-to-wrapper (R6): intro names both kinds (old Docker; binary/source before setup v1.1.22
  with Environment="TN_BLS_PASSPHRASE=..." + ExecStart=<binary> node ...); new paragraph with the
  binary/source variant (exec line, chown <user>:<group> + 0750, delete the passphrase
  Environment= line, keep the listener ones).
- Validator Onboarding (R7): the 404 how-to-stake link replaced by https://docs.telcoin.network/
  (checked: root 200, old path 404); the check's URL allowlist no longer accepts the dead path.
- Prepare to stake (notes 22-23): exit rows 0 ("Rotated: node-info.yaml now names 0x..."), 2
  (keytool export failure), 3 ("Cancelled: nothing changed."); the To-finish line quoted whole,
  and that it re-signs (needs the passphrase).
- What the Setup Script Does (notes 24, 27): Step 2 block removed, network chosen in Step 1 (with
  the add-on prompts; headers jump 1 -> 3); floor sentence "the first release that has all three
  ... (set-rpc and pop arrived in v0.12.0-adiri, state export in v0.13.0-adiri)"; lib/common
  v1.6.0 changelog sentence likewise.
- Web UI (notes 25, 28): validator tile "this epoch or the next two"; Install paragraph and
  Security model: visudo at step 5, rename at step 11, step 12 starts/restarts the UI; a failure
  after the helper step leaves new helper + old whitelist, run the installer again.
- Changelog (note 38): install-caddy v1.3.0 correction line wrapped; update-scripts v1.1.70 adds the
  `clear` fix and the new --help / unknown-argument behaviour (13f6309); "Keeping Scripts Up to
  Date" adds --help, exit statuses 0/1/2 and the stdin answer (`printf 'y\n' | ...`).
- "Updating the node" + update-node v1.2.0 changelog (P6 "Fix pass 3", 12e58f4): an existing
  install is told which binary the node runs (launch file, else .node-meta BINARY_PATH) and the
  stop / install -m 0755 / start steps, with the epoch-aware alternative via edit-config item 12.

#### Follow-up 3: check result
doc1-check.sh rc 0, PASS (<scratchpad>/doc1/check-out-5.txt): 101 long flags, 0 unknown; the same
four line-wrap false positives; URLs canonical (allowlist now excludes the 404 path); no
line-number references; role flags descriptive only; support@telcoin.org only; anchors resolve;
all tables consistent. The update-scripts --help capture was refreshed (it now prints usage).

#### Follow-up 3: open issues
- The README's interrupted-config-save wording assumes P5 "Fix pass 3 (V-DOC)" ships: the
  edit-config.sh change is uncommitted (HEAD 59d10a0). Commit them together, or revert that
  sentence to "the edit stays on disk, unapplied, until the next restart".
- lib/common.sh still prints "Full staking guide: https://docs.telcoin.network/telcoin-network/
  staking/how-to-stake" (404) after key generation, and tn_ref_min_check's floor message still
  reads "the first with keytool set-rpc ..." (P4b FZ2). Both are library text (not README).
- V-DOC note 33 (Overwrite existing keys always fails) is an OPERATOR/script matter; README's Key
  Backup advice ("answer N") is unaffected.
