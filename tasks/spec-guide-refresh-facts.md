# Verified facts for the MNO guide 1.4 refresh (checked 2026-10-15)

Shared preamble for the U1 (guide writer), U2 (OPERATOR/README writer) and U3 (verifier)
agents. Every fact below was read by the orchestrator from telcoin-network `main` at commit
98849a221 (2026-10-15, three merges past tag `v0.16.0-adiri` d72cc2bcf: 6a9310b8a #1622,
361f4b0c3 #1647, 98849a221 #1572). Read a cited line with

    git -C /Users/grant/coding/telcoin/telcoin-network show 98849a221:<path> | sed -n '<a>,<b>p'

Never check out, reset or otherwise touch that repository; `git show` only. No new tag exists
and the Docker default image stays `v0.16.0-adiri`. The code is the primary source; the mdbook
under `docs/src/` is secondary.

## What did not change (so the documents keep it)

- No CLI flag, `db` or `keytool` subcommand, `tn_*` RPC method, `/health` response or data-dir
  layout changed. `SUBSECOND_TIMESTAMP_FORK_EPOCH` is still `u32::MAX` (unarmed on adiri).
- No deployment script needs a code change: no version bumps, no `.sha256` sidecars.
- Hardware table numbers, the `v0.16.0-adiri` pins (still the newest tag), the restart-replay
  sentence (guide line 442), the status values and the Introduction stay as they are.

## Facts, with citations at 98849a221

### Clock drift (correction C, item 2)
- `docs/src/getting-started/hardware-requirements.md:405`: a validator waits out a header
  timestamped up to `max_header_time_drift_tolerance` ahead of its own clock before voting:
  250 ms by default, rounded up to whole seconds in epochs before the sub-second timestamp fork
  (so 1 s on adiri today). A header further ahead gets no vote yet and costs its proposer
  nothing; only a header more than the tolerance plus `vote_timeout` ahead is rejected, without
  a score penalty.
- `crates/config/src/node.rs:230-253`: `vote_timeout` doc comment, default 5 s (line 252-253).
- `crates/consensus/primary/src/error/network.rs:215-221`: `TooNew`, `TooOld`,
  `InvalidTimestamp`, `InvalidSeedSignature` carry no penalty (`=> None`).
- Figures for the documents on adiri today: hold up to 1 s; reject more than about 6 s
  (1 s + 5 s). The upstream page's "5.25 s" is the 250 ms default, not adiri's rounded value.
- The old sentence "A node rejects headers timestamped more than a second ahead of its own
  clock." is therefore wrong on two counts (it waits, and the limit is about six seconds).

### Epoch restart recovery (#1572; items 5, 6, 10a, 10c)
- `crates/node/src/manager/node/close_epoch.rs:607-612` WARN
  `previous epoch record missing on restart (killed at its boundary); re-deriving it locally`
  (this one existed at the tag).
- `close_epoch.rs:634-639` INFO
  `re-derived epoch record written - clearing the previous epoch's consensus db tables`.
- `close_epoch.rs:669-676` WARN `epoch record present but the consensus db tables still hold
  rows of an older epoch (killed between the record write and the tables clear); clearing them`
  (one log line; the source wraps it with a `\` continuation).
- `crates/consensus/primary/src/proposer.rs:585` benign WARN
  `ignoring parent certificates from another epoch`.
- `crates/storage/src/lib.rs:187-191`: the epoch database is `<data dir>/consensus-db/epoch`
  (singular, `store_path.join("epoch")`); its start-up check panics with the prefix
  `Cannot check database (epoch)` (line 191, `.expect(...)`), so the journal shows
  `Cannot check database (epoch): epoch table ...`.
- `crates/storage/src/epoch_db_recovery.rs:179-196`: the message after the prefix is
  `epoch table {table} holds {n} row(s) this binary cannot decode, the first at key {key} with
  header epoch {epoch} ({error}); ...`. Its own remedy text: "Retrying the start finds the same
  rows. Remove the epoch database directory `consensus-db/epoch` under the datadir, which holds
  only the epoch in progress (keep `consensus-db/epochs` and `db`), and start again once the
  network has closed that epoch, since the directory also held this node's guards against
  voting or proposing twice in it; or restore the node into a fresh datadir from a state export
  bundle with `db load-state`". Any undecodable row in `LastProposed`, `Certificates` or
  `ProposedCertificates` triggers it. The late-upgrader discard path is dormant on adiri
  (fork unarmed): do not document it.
- `crates/config/src/traits.rs:155-156` `epochs_db_path` = `consensus-db/epochs` (the epoch
  packs, migrated one-way by v0.16.0); `traits.rs:192-193` `reth_db_path` = `<data dir>/db`.
  Keep `consensus-db/epoch` (epoch in progress) and `consensus-db/epochs` (packs) distinct in
  every sentence.
- systemd restart policy written by setup-node.sh: `StartLimitIntervalSec=60`,
  `StartLimitBurst=5` (`setup-node.sh:1897-1898` Docker, `1990-1991` binary/source),
  `Restart=on-failure`, `RestartSec=10` (`setup-node.sh:1913-1914`, `2007-2008`). So a node
  that stops at every start restarts every 10 s and ends in `start-limit-hit` (5 in 60 s).
- `update-node.sh:476` (this repo): the one-way failure message says "Not rolled back: the
  previous release cannot open the migrated data dir" and points at the journal; it does not
  mention `Cannot check database (epoch)` (triage item, not for this round).

### Certifier fail-stop (#1552; item 10d)
- `crates/consensus/primary/src/certifier.rs:532`, `:559`, `:603`: three ERROR lines ending
  `; initiating node shutdown: {e}` (durable barrier failed for an already-certified
  certificate / error accepting own certificate / durable barrier failed for own certificate).
  Each calls `self.config.shutdown().notify()` and returns a `TaskError`.
- `crates/node/src/manager/node/run_epoch.rs:506-532`: the epoch task manager's exit handling
  (`until_task_ends(consensus_shutdown_clone)`); an `Err(e)` branch logs `failed to reach epoch
  boundary` and returns the error. Whether the whole process then exits, or only the epoch's
  tasks restart, is NOT established. The verifier settles it by reading the caller of
  `run_epoch` (the epoch manager loop in `crates/node/src/manager/node.rs` or beside it) and
  `crates/node/src/main.rs` / the `node` subcommand. Until then the documents say the node
  "stopped consensus rather than risk signing twice"; the verifier adjusts the wording if the
  process exits.
- Note `config.shutdown()` on the consensus config is the same notifier the subscriber uses to
  restart the epoch tasks on rejoin (`subscriber.rs:320`), which is why the question is open.

### Rejoin (#1513/#1550; items 1, 7, 8)
- `crates/consensus/executor/src/subscriber.rs:38` `REJOIN_HEAD_MAX_AGE` = 5 s;
  `:44-55` only an output from the still-open epoch can establish rejoin readiness (never into
  a closed epoch); `:71-81` `rejoin_ready`: newest header younger than 5 s, same epoch, and the
  handled output trails the newest known header by at most `rejoin_window` rounds.
- `crates/types/src/primary/mod.rs:72-74` `gc_activity_window(gc_depth) = gc_depth - 10`;
  `:84-86` `rejoin_round_window = gc_activity_window / 2`; the doc comment at `:80-81` says
  "With a `gc_depth` of 50 this is 20 rounds". The default `gc_depth` is at
  `crates/config/src/node.rs:338-340` (verifier: confirm it is 50).
- `subscriber.rs:317` INFO `attempting to rejoin consensus`, then `node_mode` becomes
  `CvvActive` (`:319`).

### Worker RPC admission (#1543; item 9)
- `crates/tn-reth/src/worker.rs:63-68` `deactivate`: a removed worker keeps its listeners
  bound; read-only RPC stays available while transaction submissions are rejected.
- `crates/tn-reth/src/worker.rs:141-145` `ensure_active`: JSON-RPC error code `-32000`,
  message `worker is inactive` (used by `eth_sendRawTransaction` and
  `eth_sendRawTransactionSync`).
- Worker RPC ports: `crates/tn-reth/src/env/rpc.rs:142` "`http_port` shifted down by
  `200 * worker_id`"; `rpc.rs:1284-1285` worker one = base - 200, worker two = base - 400.
  Worker 0 is on the base HTTP port, 8545 on a default install (the guide's Ports table,
  guide line 155). So "send transactions to the first worker's RPC, port 8545 on a default
  install" is right.
- The guide's existing Workers row (line 1218) is about too FEW workers; the new row is about
  a node configured with MORE workers than the network requires.

### Peer penalties (#1493/#1647)
- `crates/consensus/primary/src/error/network.rs:215-221`: `TooNew`, `TooOld`,
  `InvalidTimestamp`, `InvalidSeedSignature` score nothing ("a restart, clock skew, or
  divergent local anchor must not isolate peers needed for recovery"). The guide carries no
  penalty detail; this only backs the clock-drift correction.

### `network-config` and the opt-in keys (items 3, 4)
- `crates/config/src/traits.rs:76-83`: the node writes `network-config` only when the file is
  missing (`NotFound` => write `T::default()`); YAML; unknown top-level keys are ignored.
- The scripts DO write one line of it: `lib/common.sh:1272-1286` `write_advertised_name`
  writes `hostname: "<name>"` into `<data dir>/network-config` (creates the file when absent);
  `setup-node.sh:1606` calls it. Never write "the scripts never touch it".
- Field names at `crates/config/src/network.rs`: `process_budget` (line 37,
  `Option<NetworkProcessBudget>`), `source_admission` (42, `Option<SourceAdmissionConfig>`),
  `hostname` (48), `bootstrap_peers` (55), `trusted_nodes` (60), `committee_peers` (68),
  `endpoints` (70). The four opt-in keys the documents name: `process_budget`,
  `source_admission`, `trusted_nodes`, `committee_peers`. All absent/empty by default; no
  script sets any of them.
- `crates/config/src/network/trusted.rs:14-18` `TrustedNode` (primary + workers endpoints).
- `crates/config/src/network.rs:61-67` `committee_peers` doc: operator-owned launch inventory;
  at genesis must cover every committee member; later a gap is logged and discovery covers it.
- `crates/config/src/network_budget.rs:16-27` `NetworkProcessBudget` fields.
- `crates/config/src/source_admission.rs:12-27` `SourceAdmissionConfig` fields.
- `crates/node/src/manager/node.rs:1543-1548`: startup WARN when `source_admission` is set,
  starting `source admission is enabled` and continuing `: committee peers share its ceilings
  and are refused while it is full; do not enable it on a validator until protected capacity
  exists`.
- `docs/src/network/peers.md:54`: "Bootstrap entries supply discovery hints. They do not
  acquire operator retention or load privileges automatically." (At the tag, `peers.md:65`
  called them important.) So: the node treats bootstrap peers as discovery hints only; it does
  not keep them connected ahead of other peers or exempt them from load penalties.

## Rules in force

- Build lint (`tools/build-partner-pdf.sh`, run `bash tools/build-partner-pdf.sh
  mno-node-guide --html-only`): fails on `grant@`, `--observer`, `migrate-node-naming`,
  `setup-observer.sh`, `setup-validator.sh`, repo-relative links, the word "legacy" anywhere
  in the guide, a missing `devs@telcoin.org`, a second `# ` heading, a `(#slug)` link with no
  heading, `metadata.yaml` without `version`/`date`/`contact`; warns on code lines over 90
  chars and on Markdown changed without a metadata bump. Never quote the upstream line
  `migrated legacy pack to v2 on open` into the guide (OPERATOR.md line 484 may keep it).
- Contact in the guide is only `devs@telcoin.org`. OPERATOR.md and README.md keep
  `support@telcoin.org` (out of scope; do not change it).
- Links to repository files are absolute GitHub URLs under
  `https://github.com/Telcoin-Association/tn-node-deployment/blob/main/`. Cross-references
  inside the guide are `[text](#heading-slug)`. OPERATOR.md uses "section N.N"; README.md uses
  its own heading links. No manual heading numbers in the guide.
- Describe main as current behaviour, with no release qualifier. The words "next release"
  must not appear anywhere. No "legacy" in the guide.
- AGENTS.md "Restarts and the epoch boundary": the scripts' wait is unchanged (margin 300 s,
  settle 90 s, max 1800 s, only `CvvActive` waits). The documents must not weaken that advice:
  the recovery note says "keep to the wait".
- Style: one sentence per line in the guide and OPERATOR.md (README.md uses paragraphs);
  British spelling; no em dashes in prose; "data directory" in the guide, "data dir" in
  OPERATOR.md and README.md.
- Net growth of the guide: 40 lines or fewer (about 15 expected). "Missing" means a fact
  without which a corrected sentence is untrue; everything else goes to triage.
- Apply edits bottom-up so the line numbers above stay valid. Copy old strings exactly from
  the file. One agent per file; no concurrent edits to one file.

## Decisions (user, 2026-10-15)

1. Describe main as current behaviour. The CHANGELOG records that guide 1.4 describes
   telcoin-network main 98849a221.
2. Opt-in keys: a short note only (three or four lines under Optional node flags).
3. Guide plus a small sync of the same sentences and rows in OPERATOR.md and README.md.
4. One commit on `docs/technical-specification`, no attribution trailer, no push.

## Edit list: `docs/partner/mno-node-guide/mno-node-guide.md` (U1)

Line numbers at the current file (1297 lines). C = correction, A = addition. Apply bottom-up
(item 11 first is fine, then 10, 9, ... 1). Headings to link: `### Service and keys` (line
1260), `### Restarts and the epoch boundary` (524), `### The epoch section` (402),
`### Ports` (148), `### Hardware per role` (96).

1. L91 Vocabulary `CvvInactive` row: "catching up before it can vote. This should be brief."
   -> "catching up before it can vote, for example after a restart. This should be brief."
2. L120: replace "A node rejects headers timestamped more than a second ahead of its own
   clock." with two lines: a validator holds its vote on a header timestamped ahead of its own
   clock until that lead has passed, on testnet today up to one second; it rejects a header
   more than about six seconds ahead (the one-second tolerance plus the five-second vote
   timeout). Keep L121 "The deployment scripts check neither, so set both up yourself." No
   penalty detail.
3. After L350 ("...your own list of peers to dial at start."): one line: the node treats these
   peers as discovery hints only; it does not keep them connected ahead of other peers or
   exempt them from load penalties.
4. After L369 (the `.node-meta` records line, end of Optional node flags): a blank line and a
   new paragraph of four lines: the node also reads `network-config`, a YAML file in the data
   directory, of which the scripts write only the `hostname` line (the advertised node name);
   it accepts four optional keys, `process_budget`, `source_admission`, `trusted_nodes` and
   `committee_peers`, all absent by default and none set by the scripts; leave them absent
   unless devs@telcoin.org asks you to set one; `source_admission` can refuse committee peers
   once its limits fill, and a node that has it set logs a warning starting
   `source admission is enabled`.
5. After L535 (ends "`12) Restart node`, which waits."): a blank line and a two-line
   paragraph: a committee node stopped inside that window anyway repairs its epoch records
   when it starts again and logs warnings that need no action (see
   [Service and keys](#service-and-keys)); it still misses the epoch votes while it is down,
   so keep to the wait.
6. After L520 ("...read the journal before you decide to go back."): two lines: a node whose
   epoch database fails its start-up check stops with `Cannot check database (epoch)`; see
   [Service and keys](#service-and-keys) for the fix. That fix touches `consensus-db/epoch`,
   the epoch in progress, never `consensus-db/epochs`, the epoch packs this update migrates.
7. L989 (the `tn_nodeMode` bullet under Watch your status): append to the same bullet: a
   seated node that restarts or falls behind reports `CvvInactive` until it has caught up,
   then logs `attempting to rejoin consensus` and votes again.
8. L1213 Sync and node mode `CvvInactive` row, cause column: "A committee member that has not
   caught up. It votes again once it is within 20 rounds of the network's newest commit in the
   same open epoch, while the network is still committing; the log then shows
   `attempting to rejoin consensus`." Fix column unchanged.
9. After L1218 (the Workers row): a new row. Symptom: `eth_sendRawTransaction` returns
   `-32000` `worker is inactive`. Cause: a node configured with more workers than the network
   requires keeps the extra workers' RPC ports open for reads but refuses transactions there.
   Fix: send transactions to the first worker's RPC, port 8545 on a default install (see
   [Ports](#ports)).
10. L1266 Service and keys: replace the `start-limit-hit` row with four rows, in this order:
    (a) Symptom: the node stops at every start; the journal shows
    `Cannot check database (epoch): epoch table <table> holds <n> row(s) this binary cannot
    decode, the first at key <key> with header epoch <N> ...`. Cause: each start checks the
    epoch database, `consensus-db/epoch`, which holds only the epoch in progress; it holds a
    row this release cannot read, every retry finds the same row, so systemd restarts the node
    every 10 seconds and it can end in `start-limit-hit`. Fix: stop the node and move
    `/var/lib/telcoin/consensus-db/epoch` out of the data directory, keeping
    `consensus-db/epochs` and `db`; that directory also held the node's guards against voting
    twice in epoch `<N>`, so start the node again only once the network has closed that epoch
    (compare `<N>` with the network's current epoch, see
    [The epoch section](#the-epoch-section)); a node with state export on can instead be
    restored into a fresh data directory with `db load-state`; email devs@telcoin.org first.
    (b) The `start-limit-hit` row as it is, with "(for `Cannot check database (epoch)`, see
    the row above)" added to its fix.
    (c) Symptom: after a restart near an epoch boundary the log shows `previous epoch record
    missing on restart (killed at its boundary); re-deriving it locally`, `epoch record
    present but the consensus db tables still hold rows of an older epoch (...); clearing
    them` or `ignoring parent certificates from another epoch`. Cause: the node was stopped
    while the epoch changed and repairs its epoch records as it starts. Fix: normal, no
    action; keep to the epoch wait for planned restarts (see
    [Restarts and the epoch boundary](#restarts-and-the-epoch-boundary)).
    (d) Symptom: an `ERROR` line ending `; initiating node shutdown: <error>`. Cause: the node
    could not write a vote or certificate durably to its epoch database
    (`consensus-db/epoch`) and stopped consensus rather than risk signing twice. Fix: check
    the data drive, free space (`df -h /var/lib/telcoin`) and I/O errors (`sudo dmesg`), fix
    the cause, restart the node; if it comes back, email devs@telcoin.org with the line.
11. `docs/partner/mno-node-guide/metadata.yaml`: `version: "1.4"`; keep
    `date: 15 October 2026`.

## Edit list: `OPERATOR.md` and `README.md` (U2)

Each file keeps its own style ("data dir", "section N.N" cross-references, `support@`
contact). Line numbers at the current files (OPERATOR.md 1288 lines, README.md 2581 lines).
Apply bottom-up within each file.

OPERATOR.md:
- L97: the item 2 correction (same two lines, "data dir" style is irrelevant here).
- L69 (section 0 `tn_nodeMode` table, `CvvInactive` row): item 1.
- Section 2.7 (323-346): item 3 after L328 ("...peers to dial at start."); item 4 after L346
  (the `.node-meta` records line), cross-reference "section 9" instead of a heading link and
  `support@telcoin.org` instead of `devs@`.
- Section 4.2: after L484 ("...read the journal before you decide to go back.") the item 6
  pointer, pointing at section 9; after the paragraph ending at L500 (the line starting
  "`edit-config.sh`, `install-caddy.sh` and the testnet add-ons wait the same way") the item 5
  recovery lines, pointing at section 9.
- Section 6.7 (L963, the `tn_nodeMode (section 3)` bullet): item 7.
- Section 9 (one table): L1213 item 8; item 9 row after the Workers row (L1218), fix "section
  1.3" instead of the Ports link; items 10a-10d replacing L1256 (the `start-limit-hit` row,
  beside the `telcoin.pid` row at L1255), with "section 3" for The epoch section, "section 4.2"
  for Restarts and the epoch boundary (that section's wait paragraph lives in 4.2), and
  `support@telcoin.org`.

README.md:
- Restarts and the epoch boundary (751-753): the item 5 recovery sentence as a new paragraph
  after L753 (the paragraph starting "Only a node that reports `CvvActive`"), in README prose
  style, pointing at OPERATOR.md section 9 with a relative link
  (`[OPERATOR.md](OPERATOR.md#9-troubleshooting)` is the README's existing style; check an
  existing OPERATOR link in README.md and copy its form).
- Bootstrap peers (822-845): the item 3 sentence appended to the first paragraph (L824) after
  "the node dials them at start."
- README has no hardware time-sync line and no troubleshooting table, so nothing else.

U2 checks `git diff --stat` touches only OPERATOR.md and README.md before reporting.

## Triage (not for the documents this round; the orchestrator writes it to followup.md)

Kademlia record retention; the new `tn_network_*` metric series and the `class`/`outcome`
labels on `peer_penalties_total`; the WARN `inbound connections keep being refused by
connection limits`; `kad_replication_interval` now a no-op; the `process_budget` startup
errors; the late-upgrader discard path; a "Where things land" row for `consensus-db/epoch`;
`update-node.sh`'s one-way failure message (line 476) not pointing at the journal's
`Cannot check database (epoch)` advice (a script change); the UI showing a crash-looping node
as down without the panic reason; re-check guide 1.4 against the next tag and refresh the
specification's `protocol:` then.

## Corrections from the verifier (U3, 2026-10-15), confirmed by the orchestrator

- Clock drift: the reject check adds `vote_timeout` to the RAW tolerance, not the rounded one
  (`crates/consensus/primary/src/network/handler.rs:775-788`: hold compares against
  `ceil_secs(tolerance)` while the sub-second fork is dormant; reject compares against
  `tolerance.saturating_add(vote_timeout)`). Default tolerance 250 ms
  (`crates/config/src/network.rs:717`), so a node whose `network-config` was written by the
  current release rejects beyond 5.25 s; a data dir whose `network-config` still holds the bare
  integer `1` an older release wrote keeps 1 s (`network.rs:969-1002`) and rejects beyond 6 s.
  The hold is up to 1 s on adiri either way. The documents say "five to six seconds" (guide)
  and give both figures (OPERATOR.md). The "1 s + 5 s = 6 s" line above was wrong.
- `worker is inactive`: a worker configured above the committee's on-chain worker count is never
  initialised (no RPC server) until an epoch activates its id
  (`crates/node/src/manager/node/start_epoch.rs:535-541, 631-636`); only a worker that was
  active and then dropped by a lower on-chain count is deactivated with its listeners kept
  (`start_epoch.rs:566` `deactivate_workers_above`, `crates/tn-reth/src/worker.rs:63-68`).
  The row's cause is therefore "the network's worker count per node went down while this node
  was running", not "configured with more workers than the network requires".
- `; initiating node shutdown`: the six sites (certifier.rs:532, 559, 603 and
  `crates/consensus/primary/src/network/handler.rs:620, 1121, 1159`, the vote barriers) fire the
  per-epoch consensus notifier; the task error is non-critical and skipped
  (`crates/types/src/task_manager.rs:472-473`), the task manager exits through its shutdown
  branch with Ok, `run_epoch` returns Ok and `run_epochs` loops. The process does not exit and
  systemd does not restart it. The epoch database's commit-failure latch is sticky for the
  process (`crates/storage/src/layered_db.rs:233-238`), so every later vote or certificate
  barrier fails the same way until the node is restarted. The row says so, and tells the
  operator to restart at once: the epoch wait protects nothing while the node cannot vote.
- `network-config` defaults: when the node creates the file itself it writes the full default,
  so the four keys appear as `null` or `{}` (`crates/config/src/traits.rs:76-83`,
  `network.rs:25-70`); "unset by default", not "absent". Every key is optional
  (`#[serde(default)]`, `network.rs:26`), so "four of the keys it accepts are opt-in". The Node
  Manager UI writes `hostname` too (`ui/telcoin-ui-helper.sh` `cmd_set_hostname`,
  `ui/server.py`).
