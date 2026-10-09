status: done

# DOC-2 checkpoint: OPERATOR.md update

Owner file: OPERATOR.md only (diff vs HEAD: +466 / -107 lines, 1214 lines now).

## Sections
1. [x] Staking chapter rewritten around prepare-stake.sh
2. [x] New flags and behaviour in install and operate chapters
3. [x] Endpoints and networks
4. [x] Appendix "where this repo and the telcoin-network docs disagree"
5. [x] Consistency pass
6. [x] Closing headings (sections changed, grep output, open issues)

## Notes (facts gathered)
- Inputs read: spec-fu-shared, fu-docs-notes, AGENTS.md, ckpt P4a P4b P5 P6 A B C D UI-1 UI-2a UI-2b
  UI-3a UI-3b L1 L2 UP (and V-OPS-2-* findings at the end), every script's --help (saved under
  <scratchpad>/doc2-help/).
- Live (read-only, 2026-10-02): rpc.adiri.tel and rpc.telcoin.network both chain 2017;
  getCurrentStakeVersion 0; stakeConfig(0) = 1e24, 1e21, 2.58e22, 21600; epoch 581; the
  getCurrentEpochInfo and getValidator cast tuples decode; tn-contracts 10cc12b confirms
  getCurrentStakeConfig = latest authored, getCurrentStakeVersion = current epoch's, IneligibleUnstake.
- Upstream: tn-5 branch docs/operator-docs-backlog = 13 commits over origin/main f47a2603, not on
  origin (git ls-remote empty). Published docs (origin/main) checked with git grep for each row.

## Sections changed
- 1.1 hardware check counts physical cores (`Detected:` line); 1.3 port conventions, the node's real
  ports shown by check-node / firewall-setup; 1.4 address change via --rotate-address; NEW 1.5
  networks and endpoints (chain ids 2017/487/32285 with hex, rpc.adiri.tel, telscan.io /
  www.telscan.xyz, rpc.telcoin.network not launched and serving 2017, eth_chainId check, 405 on
  WebSocket upgrade, NETWORK in .node-meta).
- 2.2 mainnet menu shows 487; v0.13.0-adiri floor for source refs and typed images; node-flag release
  check in step 4 of 8; staking steps point to prepare-stake.sh; summary ports + runbook link;
  `--help` exists, unknown args reported. 2.4 state_exports and bootstrap-peers.yaml rows, .node-meta
  keys, NODE_TYPE stale-line note. 2.6 P2P ports follow the node, 80/443 kept for Caddy, per-port
  labels. NEW 2.7 optional node flags (--bootstrap-peers: map shape, 64 KiB, world-readable rule,
  parser check, $(cat) at every start; --enable-state-export; --state-export-keep; release check;
  .node-meta keys).
- 3 network RPC from .node-meta, Network: line, service section contents, macOS, wrong-chain WARN
  (rpc.telcoin.network today), NEW "The epoch section" (membership line, "not a member" meaning,
  activation/earliest seat, worker count error); hand check uses rpc.adiri.tel.
- 4.1 updater fails closed, lib pair together, new scripts arrive. 4.2 dash refs refused; epoch
  wait (CvvActive, 300 s margin, 90 s settle, 30 min cap, 15 s lines, exact message, --no-epoch-wait,
  TN_SKIP_EPOCH_WAIT=1, rollback never waits). 4.3 rewritten: 13-item menu table (BLS passphrase
  still 5), backups, restart prompt, --set without --json, field table (metrics=off,
  bootstrap_peers, state_export, allow_private_forward_targets devnet-only), release check, update
  lock refusal, epoch wait, refresh needs NETWORK / git pull failure. 4.5 strict hostnames,
  installer order (visudo first, whitelist last), helper API 2 banner, wizard Public RPC, role from
  chain + banners, Config tab gap, 30-minute wait and keep the tab open. 4.6 add-on restarts wait,
  failed flag add fails the enable. NEW 4.8 unit-started Docker node -> start wrapper procedure.
- 5.1 Caddy >= 2.8.0; 5.2 one sentence per line; 5.3 set-rpc first worker, ufw rules staged while
  off, restart only on change, epoch wait, PUBLIC_RPC_* keys, block v2 (case-insensitive upgrade,
  405 page, 2 MB = 2,000,000 B -> 413, backups kept to five); 5.4 browser 405 check, block_stale
  refresh (rpc-enable same hostname, reload only), --http.api/--ws.api warning; 5.5 wait and keys.
- 6 rewritten: intro (prepare-stake on node, cast on wallet machine, variables with rpc.adiri.tel),
  6.1 prereqs, 6.2 prepare-stake steps + exit table + mainnet exit-2 example, 6.3 stake command and
  key sources (--ledger, --trezor, --interactive, --private-key "$VALIDATOR_KEY", --account; never a
  literal key), 6.4 activate, 6.5 decoded revert table, 6.6 --rotate-address (when allowed, lock,
  backup, generate pop, VALIDATOR_ADDRESS, restart, exit 4, passphrase sources, TPM note), 6.7
  watch status (check-node epoch section, UI view from chain), 6.8 epoch arithmetic E -> E+1 -> E+3
  with live example, 6.9 status table, 6.10 stake by hand (-q --bls-passphrase-source
  no-passphrase, stakeConfig(getCurrentStakeVersion()), seconds; anchor kept for README), 6.11, 6.12
  never regenerate keys.
- 7.1 finalize reads keygen's choices, done fields, input checks before root, install methods incl.
  --binary-path and auto image, node flags; 7.2 URL validation; 7.3 table (update-node
  --no-epoch-wait and dash refs, firewall p2p_ports, edit-config fields, prepare-stake row) + epoch
  wait variable table.
- 8 NODE_TYPE removed by migrate; migrate needs the old wrapper (refers to 4.8).
- 9 table: corrected staking rows (InvalidTokenId vs RequiresConsensusNFT, rotate instead of new
  keys; now one row pointing at 6.5) and new rows from B (Observer-in-committee, silent member,
  workers, wrong chain, VALIDATOR_ADDRESS mismatch), P4a/P4b/P5 (lib older, release lacks flag, mode
  600, rejected map, start wrapper, two node commands, update lock, no NETWORK), P6 (dash ref), A
  (Caddy < 2.8.0, stale block, http.api), C (status view crash before 1.6.0), D (not whitelisted,
  short of TEL, wrong chain, no passphrase, has staked, exit 4).
- 10 prepare-stake output for staking questions. Appendix rewritten: branch sentence; rows worker
  port, stake/unstake + amount, staking errors, node-info workers shape, RPC exposure, chain configs,
  OS, contact. Dropped: Public RPC URL (now agrees) and CPU counts (scripts count physical cores).

## Grep output
- Flags: every script flag OPERATOR.md names is in its script's parser (65 flag/script pairs
  checked). In `--help` as well: setup-node public RPC + node flags, --help, --json, --phase;
  update-node --discard, --no-epoch-wait; edit-config --set, --json, --no-epoch-wait; check-node
  --address, --network-rpc; prepare-stake all five; migrate --yes. Not in --help (parser only):
  see open issue 2. Other flags are cast / docker / systemctl / curl / keytool / node flags.
- URLs (all): http://127.0.0.1:8545 http://localhost:8080 https://$DOMAIN/ https://copy.fail
  https://github.com/Telcoin-Association/tn-node-deployment(.git) https://install.telcoin.network
  https://raw.githubusercontent.com/.../main/install.sh https://rpc.adiri.tel
  https://rpc.devnet.telcoin.network https://rpc.telcoin.network (6x, each as mainnet / not
  launched / serving 2017) https://telscan.io https://www.telscan.xyz wss://$DOMAIN/.
- Emails: support@telcoin.org only (11x). `common/` / devnet-genesis: 0. scan.telcoin: 0.
  Line-number references: 0. tasks/ references: 0. `--observer` / `--validator`: 8 lines, all
  removal or legacy context, no instruction to pass them.
- Layout: every table has a consistent column count; one sentence per line in paragraphs (one
  pre-existing two-sentence line in 5.2 split); em dashes only inside quoted script output.
- Cross-references: every "section N.N" / "(N.N)" points at the right heading after the
  renumbering.

## Open issues
1. README.md links `OPERATOR.md#64-export-the-stake-calldata-on-the-node`; 6.4 is now "Activate".
   A hidden `<a name="64-export-the-stake-calldata-on-the-node"></a>` sits before the export step in
   6.10 so the link still lands there. DOC-1 can point it at `#610-stake-by-hand` and the anchor can
   then go.
2. --help gaps (scripts, not docs): setup-node --help lists no --json-mode flags (--phase is only
   mentioned, --network, --install-method, --binary-path, --build-ref, --docker-image, --address,
   --external-*, --listener-*, --data-dir, --passphrase-method, --advertised-name, --service-user,
   --service-group, --genesis-dir, --enable-healthcheck-monitor); update-node --help lists no
   --json, --check, --prepare, --ref, --apply, --yes. install-caddy, firewall-setup,
   setup-observability and remove-node answer --help with "must be run as root" (usage only in the
   header comments).
3. The appendix names the upstream branch `docs/operator-docs-backlog`, which is not on origin yet
   (git ls-remote empty). Push it before this ships, or reword that sentence.
4. install-caddy fix pass V-OPS-1 is in progress in the working tree (F2 site removed first, F3
   strict hostname, F4 update lock for rpc-enable/rpc-disable). 5.5 is worded to fit either order.
   When F4 lands, add "refused while update-node.sh or edit-config.sh holds the update lock" to
   5.3/5.5 and name install-caddy in the troubleshooting lock row.
5. UI gaps documented as they are: no Config tab inputs for bootstrap_peers, state_export,
   allow_private_forward_targets; no "keep this page open" notice during the epoch wait (UI-3a open
   issue 1: leaving the tab mid-apply cuts the apply off).
6. prepare-stake's printed key note recommends `--private-key "$VALIDATOR_KEY"`, which puts the key
   in cast's argv (V-OPS-2-ps F2). OPERATOR.md warns about the process list and adds `--account`;
   the script's note could do the same.
7. migrate-node-naming still opens the fixed 49590/49594 rather than the node's ports (documented
   as is in section 8).
8. Not independently verified: "the largest legitimate JSON-RPC request is about 256 KiB" (from
   fu-docs-notes, package A).
9. README (DOC-1) and the partner guide + PDF (DOC-3) need the matching changes per AGENTS.md.

## Follow-up (coordinator, after the V-OPS fix passes)

status: done

- [x] F0. Read fix-pass sections: ckpt-fu-A (V-OPS-1), ckpt-fu-B (V-OPS-2), ckpt-fu-D (V-OPS-2), ckpt-fu-L2 (fix pass 4); exact strings taken from the scripts
- [x] F1. install-caddy: 5.1 hostnames lowercased, trailing dot dropped, IP refused (exact reason); 5.3 update lock before any node edit (refusal text, says what it already did), "Open items: ... (see the warnings above)"; 5.5 rpc-disable order (site first, reload, no wait; .node-meta keys; then lock + wait + clear + restart only if still advertised; held lock -> site gone, re-run); 7.3 row: value flag last = usage error exit 2, done may end with a parenthesised list; section 9 lock row names install-caddy
- [x] F2. check-node: 5.4 and the section 9 row warn on debug/trace/admin only, `all` explained; section 3 epoch subsection: "Committee of epoch E: N members (on-chain)" vs "N authors in the latest commit", workers advice (email support before the seat); section 9 rows: Observer-in-committee advice (let it catch up / journal), workers advice, mismatch WARN new text + advice (restart after --no-restart, else set VALIDATOR_ADDRESS)
- [x] F3. prepare-stake: 6.3 key paragraph follows the script's note (--ledger, --trezor, --account via `cast wallet import <name> --interactive`, --interactive; no --private-key, env-var suggestion dropped); 6.2 exit table row 130/143/129; 6.6 interrupted rotation (restore while signing, or "To finish, run ... --rotate-address <new> --yes"); section 9 row for the "To finish" message; lock sentences in 4.3/6.6 say "another script holds it"
- [x] F4. 7.3: CRLF .node-meta reads correctly, rewritten with LF on a key change (one line)
- [x] F5. appendix: branch prepared locally, PR after `make attest`
- [x] F6. grep check re-run: script flags unchanged (all in parsers); URLs canonical (rpc.telcoin.network 6 lines, all mainnet/not launched/serving 2017); support@telcoin.org only (12x); 0 common/, devnet-genesis, scan.telcoin, line refs, tasks/; `--observer`/`--validator` only in removal/legacy lines; `--private-key` only in the "Do not use" sentence; tables consistent; one sentence per paragraph line; em dashes only in quoted output

Sections touched in this follow-up: 3 (epoch subsection), 4.3, 5.1, 5.3, 5.4, 5.5, 6.2, 6.3, 6.6, 7.3, 9, appendix.

### Follow-up 2 (setup-node fix pass 2, DOC-3 note)

status: done

- [x] Read ckpt-fu-P4b.md "Fix pass 2" (committed as babb69d).
- [x] 2.2 intro (two sentences): prompts for a port, a directory, the Docker image, the binary path,
      the execution address or a multiaddr (external or listener) ask again until valid;
      directories must be absolute, letters, digits and `. _ / -`, no `..`.
- [x] 2.2 step 4: the region label keeps only letters, digits, `_` and `-`, up to 32 characters,
      with a warning. Put at the step that describes the prompt (it is an interactive add-on
      prompt; setup-node has no region flag), not in section 7.
- [x] 7.1 new bullet: `--data-dir`, the four multiaddr flags, `--address`, `--passphrase-method`,
      `--service-user`, `--service-group` checked before root; a `--json` keygen without
      `--address` stops with an error naming it.
- [x] DOC-3 note: the troubleshooting quote already reads `The node is at epoch <N>: let it catch
      up, and it joins once it reaches epoch <E>.` (fixed in the first follow-up), identical to
      check-node.sh apart from the placeholders. DOC-3's other note (6.3 offering --private-key)
      was also fixed in the first follow-up.
- [x] Grep check re-run: clean (same results as Follow-up 1; the five flags named in the new bullet
      are all in setup-node's parser).

### Follow-up 3 (independent docs review: V-DOC, V-DOC-O)

status: done

- [x] R0. Read ckpt-fu-V-DOC.md (errors 1 and 3, warns 4-6 and 10-13, notes 29-33), ckpt-fu-V-DOC-O.md,
      P5 "Fix pass 3 (V-DOC)" (status done: edit-config rolls back an edit stopped before the
      restart; in the working tree, not yet committed) and P6 "Fix pass 3 (V-DOC)" (committed 12e58f4)
- [x] R1. 2.6: two blanket SSH rules (IPv4 + `(v6)` twin), `2) Remove a whitelist entry` deletes one
      per run, list again with `3) Show all firewall rules` before the second delete, one left = SSH open over IPv6
- [x] R2. 2.2 step 6: menu for source and existing installs only, never Docker
- [x] R3. 4.5: README wording ("checks everything before it changes anything that is running", the four
      pre-checks); a later failure leaves the new helper with the old whitelist: run the installer again
- [x] R4. 5.2: the NAT variant is its own block ("Behind NAT, run this instead")
- [x] R5. P5 fix pass 3 is done, so: 4.3 says the edit is written before the wait and a run stopped
      before the restart (Ctrl-C, SIGTERM, SIGHUP, closed UI tab) puts every file back, with the
      script's message; after the restart is issued the edit stays. 4.5 UI bullet points there.
- [x] R6. 4.8 rewritten for Docker and source/existing-binary nodes, aligned with README's procedure
      (passphrase moved to a LoadCredential file; wrapper 750 Docker / 755 binary; bash -n; unit
      backup; systemctl edit --full); section 8 sentence generalised
- [x] R7. 9 `--observer` row: legacy `start-telcoin-<role>.sh` and `telcoin-<role>`, "the file the
      check-node warning names"
- [x] R8. 4.3 table and 6.1: `true` refused on testnet and mainnet; `false` accepted everywhere
- [x] R9. 4.3: refresh copies genesis.yaml/committee.yaml into genesis/ and parameters.yaml over the
      node's; set allow_private_forward_targets again; a refresh stopped during its wait keeps the new files
- [x] R10. 1.5 (refresh takes only the network; check-node and prepare-stake also the RPC); 4.7
      (service and container go right after "Proceed with node removal?"); 3, 6.2, 9 "(mainnet has
      not launched)"; 7.3 TN_ASSUME_YES also answers destructive prompts, keys still need DELETE
- [x] R11. 2.3 table row (replace the binary the node runs, section 4.2); 4.2 quotes update-node's
      existing-install message (binary from the launch file / BINARY_PATH, stop-install-start,
      edit-config item 12 for committee nodes)
- [x] R12. 2.5: move node-keys/ and node-info.yaml aside before re-running setup; Yes to
      `Overwrite existing keys?` currently ends `Key generation failed.`
- [x] R13. Grep check: clean (flags unchanged except `--name` gone with the old 4.8; URLs canonical;
      rpc.telcoin.network always with not-launched context; support@telcoin.org only, 12x; 0
      common/ devnet-genesis scan.telcoin line refs tasks/; role flags only removal/legacy;
      `--private-key` only in "Do not use"; tables consistent; one sentence per paragraph line; no
      stray em dashes; every new quote found in its script)

Sections touched: 1.5, 2.2 (step 6), 2.3, 2.5, 2.6, 3, 4.2, 4.3, 4.5, 4.7, 4.8, 5.2, 6.1, 6.2, 7.3, 8, 9.
Note: if the P5 fix pass 3 change to edit-config.sh is not committed with this docs pass, 4.3 and the
4.5 bullet overstate the rollback (the committed edit-config leaves the edit on disk unapplied).
