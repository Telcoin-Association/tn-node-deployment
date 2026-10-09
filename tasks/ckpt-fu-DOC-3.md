status: done
package: DOC-3 (MNO partner guide: docs/partner/mno-node-guide.md, metadata.yaml, PDF)

## Sections
- [x] 1. Content pass (guide rewritten in place: 911 -> 1253 lines, +453/-111 vs HEAD; git
      diff removals reviewed, all intended; `activate` InvalidStatus row restored after review)
- [x] 2. Partner rules (greps: --observer/--validator/migrate/setup-observer/setup-validator/
      relative links/legacy/common//devnet-genesis/scan.telcoin/tasks/ = 0; emails =
      support@telcoin.org x11; no "section N" or line refs; one # heading, nothing before the
      first ##; no code line > 90 chars; AI-vocabulary grep clean; em dashes only in quoted
      script output)
- [x] 3. metadata.yaml (version "1.1", date "2 October 2026" in the existing format; subtitle
      and description unchanged, still accurate)
- [x] 4. Build (and second run "PDF unchanged")
- [x] 5. Consistency checks (flags, URLs, heading links): PASS
- [x] 6. Closing headings

## Notes
- Read: AGENTS.md partner rules, spec-fu-shared, fu-docs-notes, ckpt DOC-1, DOC-2, OPERATOR.md
  (whole), README Web UI / Public RPC / Prepare to stake / Health Check / Restarts / Editing,
  guide in full, metadata.yaml, tools/build-partner-pdf.sh, script --help (saved under
  <scratchpad>/doc3/), and script source where wording mattered (prepare-stake key note and
  revert table, check-node epoch section, lib/common display_node_info and epoch wait,
  edit-config menu, UI banners and wizard cards).
- Skipped for partners on purpose (installs made by older scripts or maintainer detail):
  --observer rows, migrate-node-naming, unit-to-wrapper procedure, NODE_TYPE, NETWORK-missing
  refresh error, setup-node 1.2.1 keygen note, macOS check-node, mainnet exit-2 example,
  "largest request about 256 KiB" (unverified, DOC-2 open issue 8).
- human-writing post-step: format-output agent run on the guide; it changed nothing (paragraphs
  already one sentence per line; list items keep the guide's existing one-line style).

## Sections changed
- Introduction: pointer to Networks and endpoints; chapter list mentions networks, node flags,
  the epoch section, restarts around the epoch boundary and prepare-stake.sh. Roles list links
  Send the stake.
- Before you start: hardware check counts physical cores (`Detected:` line); ports are
  conventions, the real ones shown by check-node and firewall-setup; execution address can be
  rotated with prepare-stake.sh --rotate-address until it stakes; NEW "Networks and endpoints"
  (testnet 2017 / mainnet 487 / devnet 32285 with hex, rpc.adiri.tel, telscan.io and
  www.telscan.xyz, rpc.telcoin.network not launched and answering 2017 today, 405 on WebSocket
  upgrade, eth_chainId check, NETWORK in .node-meta).
- Install: setup steps 3 (Mainnet 487 menu line), 5 (v0.13.0-adiri floor for source and typed
  images), 8 (node-flag release check), 9 (staking steps with live amount and prepare-stake
  pointer), 14 (summary: advertised P2P ports, firewall reminder, runbook link); `--help`
  exists and unknown arguments are reported; Where things land adds state_exports,
  bootstrap-peers.yaml and the .node-meta keys; Firewall follows the node's P2P ports, keeps
  80/443 for a Caddy site, status labels; NEW "Optional node flags" (--bootstrap-peers,
  --enable-state-export, --state-export-keep, release check, .node-meta keys, README link).
- Confirm syncing: check-node compares with the network in .node-meta (rpc.adiri.tel),
  --network-rpc, Network line, what-the-node-runs section, wrong-chain skip; NEW "The epoch
  section" (membership line, "not a member" meaning, activation and earliest seat, workers);
  hand check uses rpc.adiri.tel.
- Day-2: update-scripts fails closed and installs the lib pair together; update-node epoch
  wait bullet and dash-ref refusal; NEW "Restarts and the epoch boundary" (which scripts wait,
  CvvActive, 5 min margin, 90 s settle, 30 min cap, the Waiting line, 15 s progress,
  --no-epoch-wait, TN_SKIP_EPOCH_WAIT=1, hand restarts never wait, variable table, UI note);
  Change the configuration rewritten (13-item menu, backups, restart prompt, --set with or
  without --json, field table, release check, update lock, epoch wait, refresh needs matching
  chain id and fails with git pull on a tag checkout, README link); Service commands note on
  hand restarts; Node Manager UI (installer visudo-first, hostname rule, helper API 2 notice,
  wizard Public card, review and completion cards, validator view from the chain and banners,
  Config tab gap, keep the tab open during the up-to-30-minute wait); Testnet add-ons restart,
  epoch wait and failed flag add.
- Public RPC: README public node tuning link; Caddy 2.8.0 floor; rpc-enable (reload, ufw rules
  while off, WebSocket, keytool set-rpc on the first worker, restart only on change, epoch
  wait, PUBLIC_RPC_* recorded; the old "writes no keys" line removed); block v2 (case-insensitive
  upgrade, 405 page, 2 MB = 2,000,000 bytes -> 413 with the connection cut, cap is HTTPS
  JSON-RPC only, newest five backups); Verify adds the browser 405 check, block_stale refresh
  and the --http.api/--ws.api warning; Turn it off adds the epoch wait, PUBLIC_RPC_* removal and
  ufw rule removal.
- Validators: rebuilt around prepare-stake.sh (intro, variables with rpc.adiri.tel,
  prerequisites incl. funding and private forward targets, the nine checks, exit-code table,
  Send the stake with the printed command and key sources --ledger/--trezor/--account/
  --interactive and never a key on a command line, Activate, revert table, Change the execution
  address before you stake, Watch your status, E -> E+1 -> E+3 with the printed example, status
  table, Stake by hand with `-q --bls-passphrase-source no-passphrase` and
  stakeConfig(getCurrentStakeVersion()) in seconds, Rewards and exit, What not to do with the
  never-regenerate-keys rules).
- Automation: keygen records and finalize reads back; done carries msg, operator_guide and
  public_rpc; inputs checked before root; --binary-path and the search paths; node flags; URL
  scheme and private-address checks; table rows for update-node (--no-epoch-wait, dash ref),
  firewall-setup (p2p_ports), edit-config (all fields, --no-epoch-wait) and NEW prepare-stake;
  epoch-wait JSON events.
- Troubleshooting: rows for committee member reporting Observer, silent member, workers,
  wrong-chain comparison, physical cores, node-flag release, peers file mode and parser
  rejection; NEW "Scripts and updates" table (lib older than 1.6.0, update-scripts integrity
  failure, update lock, dash ref, two node commands, firewall status bug before 1.6.0); public
  RPC rows for Caddy < 2.8.0, stale block, --http.api; staking table rebuilt (not whitelisted,
  short of TEL, wrong chain, revert lookup, activate InvalidStatus, VALIDATOR_ADDRESS
  mismatch, no passphrase, has staked, exit 4, beginExit, IneligibleUnstake).
- Getting help: prepare-stake output for staking questions; check-node needs no --address.

## Build output
- pandoc 3.11, WeasyPrint 70.0.
- Run 1: rc 0, "Wrote docs/partner/mno-node-guide.pdf (44 pages)", stderr empty (no lint
  error, no long-code-line warning, no WeasyPrint log lines, no metadata-bump warning).
- Run 2: rc 0, "PDF unchanged: docs/partner/mno-node-guide.pdf (44 pages)".
- Run 3 (after the format pass, which changed nothing): rc 0, "PDF unchanged ... (44 pages)".
- PDF sha256 9a87a5b0...5646 (HEAD had 3f07f2ff...55de, 221,852 bytes; now 309,186 bytes).
- pdftotext is not installed, so the build's PDF-text forbidden check was skipped; the rendered
  HTML text has none of the forbidden strings and shows support@telcoin.org 12 times.
- Pages 2, 9, 28 and 40 rendered to PNG (PDFKit) and looked at: TOC, networks table, exit-code
  table and a troubleshooting table lay out cleanly.

## Check results
- Script: <scratchpad>/doc3/doc3-check.py; output: <scratchpad>/doc3/check-out.txt. RESULT: PASS.
- Heading links: 64 headings (10 h2, 53 h3), 89 link uses, 36 distinct targets, all resolve to
  GFM slugs; no duplicate slugs; no numbered headings. pandoc's own ids match (spot-checked 9
  in the HTML) and the build's dangling-link check passed.
- Repo links: README.md, WGVPN.md, docs/testnet-addons.md, prepare-stake.sh all tracked; 13
  README anchors all match README headings.
- URLs: all canonical (rpc.adiri.tel x6, rpc.telcoin.network x5 always as mainnet-not-launched
  or the chain-id example, rpc.devnet.telcoin.network x1, telscan.io, www.telscan.xyz,
  install.telcoin.network, copy.fail, the GitHub repo and raw URLs, loopback and placeholders).
- Flags: 73 distinct long flags: 24 in a script --help, 9 in the v0.15.0 node binary help, 12
  external (cast, curl, docker, journalctl, systemctl), 28 only in a script parser (setup-node
  --json flags, update-node --check/--prepare/--ref/--apply, install-caddy/firewall-setup/
  remove-node flags, which those scripts' --help does not list; see DOC-1/DOC-2 open issues),
  0 unknown. 23 flags written right after a script name all exist in that script. All 8
  edit-config --set fields are in edit-config --help.

## Open issues
1. OPERATOR.md 6.3 and the README "Prepare to stake" paragraph still offer
   `--private-key "$VALIDATOR_KEY"`. The working-tree prepare-stake.sh (V-OPS-2-ps fix) now
   prints "Do not use --private-key" and recommends `--account <name>` (made with
   `cast wallet import <name> --interactive`) or `--interactive`. The partner guide follows the
   script; OPERATOR.md and the README should be aligned (DOC-1/DOC-2 or orchestrator).
2. OPERATOR.md troubleshooting quotes `The node is at epoch <N>; it joins once it reaches
   epoch <E>.`; check-node.sh prints `The node is at epoch N: let it catch up, and it joins
   once it reaches epoch E.` The guide quotes the script.
3. The links to blob/main/prepare-stake.sh and the README anchors added this round
   (#bootstrap-peers, #editing-the-configuration, #public-node-tuning) resolve only once main
   (25 commits ahead of origin/main, plus the uncommitted README) is pushed. Ship the PDF with
   or after that push.
4. Not stated anywhere, so not in the guide: a UI config save cut off during the epoch wait.
   edit-config writes the edit before the wait and has no signal trap, so (inferred from the
   code) the edited file stays and applies at the next restart. UI/doc followup.
5. Refresh chain configs fails on a source build checked out at a release tag (the default
   source install); the guide states the message, but no doc or script gives the remedy.
   Followup.
6. Cosmetic: inline code in table cells can break after a leading `--` (theme.css
   `td code { overflow-wrap: break-word; }`), e.g. `--network-rpc <URL>` in the exit-code
   table. theme.css is outside this package.
7. `brew install poppler` would let the build run its PDF-text forbidden check (pdftotext).

## Fix pass (V-DOC)

status: done (2026-10-02). Source: tasks/ckpt-fu-V-DOC.md and tasks/ckpt-fu-V-DOC-P.md, by way of
the coordinator. metadata.yaml stays 1.1 / 2 October 2026. No git writes.

- [x] error 2: `all` dropped from the risky --http.api/--ws.api modules in Public RPC > Verify and
      in the Public RPC troubleshooting row (now `debug`, `trace` or `admin`).
- [x] error 3: Install > Firewall: add your IP with `1) Add trusted IP for SSH access`, then remove
      both blanket SSH rules (source `Anywhere`: the IPv4 rule and its `(v6)` twin);
      `2) Remove a whitelist entry` deletes one rule number per run and the numbers shift, so
      read the list it prints again before the second delete.
- [x] warn 4: Run setup step 6: the passphrase menu comes after the source build, or for an
      existing binary once setup has found it (never for Docker).
- [x] warn 5: Node Manager UI: the installer validates the sudo whitelist with visudo before it
      changes anything that is running, stops on the four pre-checks with the running UI
      unchanged, installs the whitelist last; after a later failure, run the installer again.
- [x] warn 6: Public RPC > New install: the NAT variant is its own block ("Behind NAT, run this
      instead").
- [x] warn 13: edit-config field table and validator prerequisites: "`edit-config.sh` refuses
      `true` on testnet and mainnet".
- [x] Web UI config save: P5 "Fix pass 3 (V-DOC)" is done, so the UI bullet says a config save
      stopped before it restarts the node is rolled back (every file it changed put back); the
      edit-config `--set` paragraph says a run stopped before the restart puts the files back too.
- [x] note 34: revert table lead-in: `cast` prints the error selector, and the name when it can
      decode it.
- [x] note 35: dropped "lib/common.sh and lib/fallback.sh are installed together" and
      "(the script's EVM_SYNC_THRESHOLD)".
- [x] P4b fix 3: Automation input-check bullet: a keygen run also stops before root when
      --address, one of the four multiaddr flags or TN_BLS_PASSPHRASE is missing.
- [x] P6 fix 3: Update the node: for an existing install the script names the binary the node
      runs (the start wrapper's, BINARY_PATH in .node-meta) and the steps; stop / install -m 0755
      / start block; on a committee node install while running, then edit-config.sh menu item
      `12) Restart node`, which waits. Install methods table points there.
- [x] Also, same review, same file: exit table gains the `Rotated: ...` exit-0 row and the
      keytool-export case in exit 2 (V-DOC-P N1/N2, V-DOC note 22); Restarts and the epoch
      boundary no longer says "every script": lists the scripts that wait and says systemctl and
      the UI's Start/Stop/Restart buttons, tracing toggle and advertised-node-name save restart
      at once (warn 7's overclaim, verified in ui/telcoin-ui-helper.sh and ui/server.py), plus the
      edit-config item 12 option; wrong-chain troubleshooting row adds "because mainnet has not
      launched" (note 31).
- Not changed: warn 10 (refresh chain configs drops allow_private_forward_targets): `true` is
  refused on testnet, so it cannot affect a partner node.

### Build and checks (fix pass)
- Build 4: rc 0, "Wrote docs/partner/mno-node-guide.pdf (44 pages)", stderr empty.
- Build 5: rc 0, "PDF unchanged: docs/partner/mno-node-guide.pdf (44 pages)".
- PDF sha256 325213b2...9525; guide sha256 09542cdd...b219; guide 1272 lines, +479/-118 vs HEAD.
- doc3-check.py: PASS (64 headings, 90 link uses / 36 targets all resolve; repo links and 13
  README anchors ok; URLs canonical; 73 flags, 0 unknown; 23 script-attributed flags ok; 8
  edit-config fields ok). Partner greps clean (no --observer/--validator/legacy/forbidden names;
  support@telcoin.org only, x11); no code line over 90 chars; HTML text clean.
