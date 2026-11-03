# Verified facts for the November 2026 refresh: guide 1.5 and specification 1.2 (checked 2026-11-03)

Shared preamble for the F1-F3 (facts), S1-S3 (writers) and V1 (verifier) agents. Every fact in
the parts below was read from telcoin-network `main` at commit 7167e7800b58f34d4f681e096ccda6d8fd20450e
(2026-11-02, 27 commits past tag `v0.16.0-adiri` d72cc2bcf; the newest tag is still
`v0.16.0-adiri`). The guide 1.4 / specification 1.1 texts describe main at 98849a221
(2026-10-15); this round covers 98849a221..7167e7800 (24 commits).

The code is read from a detached worktree of the maintainer's checkout, read-only:

    /tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/64bde3c7-bb69-4b5a-b090-75740954e028/scratchpad/tn-main

Read a cited line with `sed -n '<a>,<b>p' <worktree>/<path>`. Never run `git checkout`,
`git reset`, `git worktree`, `git stash` or any write in that worktree or in
`~/coding/telcoin/telcoin-network`. The code is the primary source; the mdbook under `docs/src/`
is secondary and is cited only for what the code cannot show (an operator-facing recommendation).

## Citation rule

Every fact carries `path:line` (or `path:a-b`) at 7167e7800, worktree-relative. A number cites the
line that computes it (the `const`, the default, the arithmetic), not a doc sentence that repeats
it. A "what did not change" line carries the citation that confirms it.

## Commits in scope (98849a221..7167e7800)

- 2635e26a Staging 10-13 (#1654): #1544 close removes worker admission at the boundary; #1545
  worker running state; #1546 hand off transactions from retired worker pools; #1551; #1549;
  #1555; #1556 base fees across worker regrow; #1557 fork gates through one const fn; #1648
  epoch/consensus-output serves without catch-up sleeps; #1651 recover peers from status-only
  bans; #1652 keep committee bindings through pruning.
- 5ccb88e8 Staging 10-15 (#1701): #1553 refuse transaction submissions on inactive validators;
  #1534 closed connection admission; #1559 mainnet genesis regenerated with 6-hour epochs;
  #1677 explicit gossipsub frame limits.
- 942d08cd Staging 10-16 (#1722): #1679 non-blocking gossip publish; #1690 fallback across
  silent signed endpoints (forwarding); #1693 quorum shortfalls and commit liveness
  (`docs/src/getting-started/consensus-liveness.md`); #1695 inbound rejection reasons; #1691
  QUIC Retry.
- d2a0b525 Staging 10-20 (#1745): #1694; #1697 metrics; #1692 bound warning volume; #1696 health
  listener bound privately (`docs/src/getting-started/observability-listeners.md`).
- 2d4afcd7 Staging 10-22 (#1754): #1736 IHAVE cap; #1737 worker sync serve memory and unserved
  epochs; #1739 inbound kad PutRecord bounds; #1740 batch sync request bounds; #1746.
- 7c014dc0 Public release pipeline (#694): signed tags, `SHA256SUMS` with `IMAGE_DIGEST` and the
  chain-config hashes, ghcr only; `docs/src/getting-started/installing-a-release.md`,
  `release-notes.md`, a maintainers chapter.
- 8aedf72e tndb (#1558): consensus database is tndb at `<consensus db>/tndb/{epoch,kad,cache}`;
  MDBX nodes migrate once on first start, one-way; ConsensusPack rework; redb removed;
  `db tndb-stat`. 7167e780 (#1767) fixes a durability watermark race in it.
- 8958c3c8 CLI (#1715): `--bls-passphrase-source credential` (reads
  `$CREDENTIALS_DIRECTORY/<name>`, `--bls-passphrase-credential`), zeroized passphrase,
  `--bootstrap-peers-file`.
- Seven "Merge commit from fork" security fixes (f69c25ee, 87180d74, 5f912b1d, ed092164,
  b68ce0c7, 813bb668, 2f37c7b3, with 70591aa4, ee1a4b1a, 6baf0d7b, 64c39f44 on their branches):
  sync-serve admission tiers, request-write timeout, epoch position for gossip replay, kad
  identical-record weighting, peer-exchange caps, QUIC receive credit and connection limits.
- 9a934631 CI (#1757): maintainer-only, nothing to describe.

Not on main and therefore not described: staging 10-27 (#1747, #1752, #1738, #1749, #1698,
#1721, #1744) and the worker-gateway stack (#1617 `--forward-txs`, `feat/worker-gateway-*`).
Also out of scope for the partner documents: metrics series and labels, dashboards, CI and
release-tooling internals (anything only maintainers see).

## Documents the facts apply to

- `docs/partner/technical-specification/technical-specification.md` (spec 1.1 -> 1.2)
- `docs/partner/mno-node-guide/mno-node-guide.md` (guide 1.4 -> 1.5; after the merge it also
  carries main's guide 1.3.3 hardening content)
- `OPERATOR.md` and `README.md` (the operator twins of the guide's facts; main's text is the base)

Each fact names the document and section it applies to and quotes the current sentence. Lines
are not cited in the partner documents (the merge reflows them); quote text and name the heading.

## Orchestrator decisions for the writers (S1-S3) and the verifier (V1)

1. **Source of truth.** The parts F1-F3 below are the only source for a changed statement. A
   writer who needs a fact the parts do not carry leaves the text as it is and reports the gap;
   nobody re-derives from the code except V1.
2. **Release and main.** No tag carries any commit after `v0.16.0-adiri`; every deployed node
   runs that release. The specification describes the protocol as of `v0.16.0-adiri` plus main
   up to 7167e7800 (its Introduction says so; its cover prints
   `Protocol v0.16.0-adiri, main at 7167e7800`); inside the chapters, main's behaviour is written
   as the protocol, without per-sentence caveats. The guide, OPERATOR.md and README.md describe
   main's behaviour as current, as guide 1.4 did, but name the release wherever an operator
   would act differently on the two: write "on `v0.16.0-adiri`" for today's behaviour and
   "from the next release" (never a tag name that does not exist) for main's. That applies to:
   the `Cannot check database (epoch)` remedy (on `v0.16.0-adiri` move `consensus-db/epoch`
   aside; on a node that has migrated to tndb do not remove `consensus-db/tndb/epoch`, the
   next start refuses to open an empty environment beside the migration marker; email
   devs@telcoin.org / support@telcoin.org first), the certifier and vote-barrier row (the node
   now stops with status 1 and systemd restarts it), the one-way update note (the next release
   migrates the consensus database to tndb on first start, one way; take the snapshot first),
   the health listener (`--healthcheck <port>` binds all interfaces on `v0.16.0-adiri` and
   loopback from the next release; an outside monitor then needs an address), and the
   `validator is inactive` refusal (from the next release).
3. **Nothing off main.** No statement about staging 10-27, the worker gateway, `--forward-txs`,
   or a `v0.17.0-adiri` tag as a fact. "Signed releases start with the next tag" is the plan the
   upstream book states; say it as a plan, if at all.
4. **Numbers.** Copy the numbers from the parts; do not compute new ones. Each number in a
   document must trace to a part entry whose citation is the line that computes it.
5. **Optional additions.** Apply an optional addition in the guide only where the reader acts
   on it; in the specification only where the chapter already covers the topic. Say in the log
   which optional items were left out.
6. **Contacts.** The partner documents name only `devs@telcoin.org`; OPERATOR.md and README.md
   keep `support@telcoin.org`.
7. **Logs.** Every changed statement is logged with its part entry and citation: the
   specification's log is `tasks/ckpt-spec-refresh-2-log.md`; the guide's and the operator
   docs' logs are their checkpoint files (`tasks/ckpt-refresh-S2.md`, `tasks/ckpt-refresh-S3.md`).
8. **Open points for V1.** The `-32603` code (F2 took it from jsonrpsee 0.26.0 in the cargo
   registry); the gpgv exit-status claim (F3 cites the upstream book, not code; a local
   `gpgv --status-fd 1` run on an expired test key settles it); whether a `CvvInactive` node
   keeps transactions it had already admitted (F3 found no pool clearing; the documents say
   only that new submissions are refused).

The parts follow, joined by the orchestrator from the F1, F2 and F3 part files (removed after the join).

### Correction to decision 2 (from V1b and V1c), 2026-11-03

Decision 2 assumed the `Cannot check database (epoch)` start-up check exists on `v0.16.0-adiri`.
It does not: `crates/storage/src/epoch_db_recovery.rs` arrived with #1572 (98849a22), which is
not an ancestor of the tag (`git grep 'Cannot check database' v0.16.0-adiri` finds nothing). The
documents now say: the check exists from the next release; on that release's first start the
line reads `Cannot migrate the consensus DB from MDBX: Cannot check database (epoch)` and names
`consensus-db/epoch`, and moving that directory aside once the network has closed the epoch is
the remedy; on a node already on tndb the line names `consensus-db/tndb/epoch`, which must not
be removed (the next start refuses an empty environment beside `mdbx-migrated`), so the operator
emails first; on `v0.16.0-adiri` a damaged epoch row panics with `Invalid bytes!` while the
database opens and the node crash-loops. The same verifiers found that none of the six opt-in
`network-config` keys, the two `-32000` worker messages or the 62 GiB reservation exist at the
tag, so those sentences say "from the next release" too, and that a `--json` apply (the Node
Manager UI) rolls back without asking after a failed check, so a committee node takes the tndb
update from a terminal. Reports: `tasks/ckpt-refresh-V1b.md`, `tasks/ckpt-refresh-V1c.md`.

### Orchestrator check of open point 8b (gpgv), 2026-11-03

Local test with gpg and gpgv 2.4.8: a signing key generated with a one-day expiry under
`--faked-system-time 20260101T000000!`, a detached signature made an hour later, then verified
today. Plain `gpgv --keyring ./keyring.gpg SUMS.asc SUMS` printed `Good signature from ...` and
exited 0. `gpgv --status-fd 1 ...` printed `[GNUPG:] EXPKEYSIG ...` and `[GNUPG:] VALIDSIG ...`,
no `GOODSIG`, and still exited 0. F3's correction stands: the hand check must read the status
lines, and "a `GOODSIG` line and none of `BADSIG`, `EXPSIG`, `EXPKEYSIG`, `REVKEYSIG`" is the
right rule (an expired key prints `EXPKEYSIG` in place of `GOODSIG`).


---

## F1: storage, sync, restart recovery (7167e7800)

All paths are worktree-relative at 7167e7800. "Old" lines are at 98849a221 (`git -C <worktree> show
98849a221:<path>`) or at tag `v0.16.0-adiri` d72cc2bcf. No release tag carries any of the changes
below: the newest tag is still `v0.16.0-adiri`, which runs the MDBX consensus DB
(`git show d72cc2bcf:crates/storage/src/lib.rs` lines 137-143, `DatabaseType =
CompositeDatabase<MdbxDatabase>` under the default `reth-libmdbx` feature). Every deployed node is
therefore still on MDBX; the tndb facts apply to a node binary built from main since 8aedf72e.
How the documents name that future release is an orchestrator decision (see "Could not settle").

### Section 1: tndb and the storage layout (#1558 8aedf72e, #1767 7167e780)

#### Facts

##### The consensus database is now tndb, under `consensus-db/tndb/`
- Document: guide > Where things land; OPERATOR > (its "Where things land" table); README > (the
  ownership table row for `/var/lib/telcoin/`). Kind: addition (optional; last round triaged a
  `consensus-db` row).
  Current (guide branch and main): "| `/var/lib/telcoin/consensus-db/state_exports/` | ... One
  directory per epoch when state export is on ..." (the only `consensus-db` row); README main:
  "`db/`, `consensus-db/` (with `state_exports/epoch-N/` when state export is on)".
  Fact: the consensus database (the epoch in progress, peer records, batch caches) is tndb, three
  environments at `<data dir>/consensus-db/tndb/epoch`, `.../tndb/kad` and `.../tndb/cache`, each one
  shared log with a B+tree index per table. The finished epochs' consensus packs stay at
  `<data dir>/consensus-db/epochs/` (unchanged). On MDBX (every tagged release, `v0.16.0-adiri`
  included) the same three databases were `consensus-db/epoch`, `consensus-db/kad` and
  `consensus-db/cache`, each an MDBX environment (`mdbx.dat`, `mdbx.lck`). Each tndb environment
  holds `LOCK`, `tables` (its manifest) and `gen-<N>/` (the log and its indexes).
  Cite: crates/storage/src/lib.rs:138 (`DatabaseType = tndb::SplitDatabase`),
  crates/storage/src/lib.rs:405-411 (`open_db` opens `store_path.join(tndb::TNDB_DIR)`),
  crates/storage/src/tndb/mod.rs:34 (`TNDB_DIR = "tndb"`), crates/storage/src/tndb/split.rs:46
  (`ENVIRONMENTS = ["epoch", "kad", "cache"]`), crates/storage/src/tndb/split.rs:129-150,
  crates/config/src/traits.rs:155-156 (`epochs_db_path` = `consensus-db/epochs`),
  crates/config/src/traits.rs:188-189 (`consensus_db_path` = `<data dir>/consensus-db`),
  crates/storage/src/tndb/layout.rs:38, :115 (`LOCK`, `gen-{n}`), crates/storage/src/tndb/manifest.rs:34
  (`tables`); old: crates/storage/src/lib.rs:185-206 (`open_mdbx_env`, dirs `epoch`/`kad`/`cache`),
  :333 (`MDBX_FILES = ["mdbx.lck", "mdbx.dat"]`). redb is gone from the tree
  (`git diff --stat 98849a221..HEAD -- crates/storage` deletes `crates/storage/src/redb/*`); it was
  never the default, so no deployed node used it.

##### First start on tndb migrates the MDBX consensus DB, one way
- Document: guide > One-way updates; guide > Script and node updates (the one-way bullet);
  OPERATOR > section 4.2 (the one-way bullet and the snapshot paragraph); README > Updating the
  node (the one-way bullet). Kind: addition (applies once a release carrying tndb is tagged; see
  "Could not settle").
  Current (guide branch): "An update from a release older than `v0.16.0-adiri` to `v0.16.0-adiri`
  or newer cannot be undone by putting the old binary or image back, because the new release
  migrates the consensus store on its first start."
  Fact: a node binary with tndb, on its first start over an MDBX data dir, copies the MDBX epoch
  tables (its last proposal, its votes, its proposed certificates and the rest of the epoch in
  progress), its peer records and both batch caches into tndb, makes the copy durable, deletes the
  MDBX files (`mdbx.lck`, `mdbx.dat`, then each directory if it is empty; a file MDBX did not make
  is kept, with its directory, and logged as `kept <dir> after moving to tndb: ...`), and writes the
  marker `consensus-db/tndb/mdbx-migrated` (its one line reads `copied <n> rows from MDBX`). It logs
  INFO `copied <n> rows of the consensus DB from MDBX to tndb` (only when n > 0). The
  consensus-output cache is not copied: the node re-reads or re-fetches those outputs. A failure
  before the marker stops the start with `Cannot migrate the consensus DB from MDBX`, and the next
  start copies again from MDBX, which is untouched until the copy is durable. The tables copied are
  small (MDBX capped them at 512 MiB epoch, 64 MiB kad, 1 GiB cache), so the migration needs at most
  that much extra space while both copies exist. The switch is one-way: the code calls a later
  downgrade to an MDBX build "not supported, because that build would start with empty epoch tables
  (no record of this node's votes and proposals) and could sign conflicting messages". Unlike the
  `v0.16.0-adiri` pack migration, the older release is not refused: it starts, as on a fresh data
  dir, with empty epoch tables. A committee member downgraded that way can equivocate. The code says
  "Problems after the switch are fixed forward." Back on tndb after such a downgrade, the node logs
  ERROR `<data dir>/consensus-db/<env>/mdbx.dat was written after this node moved to tndb (by an
  older binary?) and is not read; anything it holds is not in the consensus DB`. So the documents'
  snapshot rule applies again for that update: only a data dir snapshot taken before it undoes it,
  and putting `v0.16.0-adiri` back without the snapshot is unsafe for a committee member, not just
  impossible.
  Cite: crates/storage/src/lib.rs:208-236 (doc comment: what is copied, one-way, "fixed forward"),
  :239-331 (`migrate_from_mdbx`: :254-266 marker present and the downgrade ERROR, :268-273 env
  presence by `mdbx.dat`, :276-305 copies, :306-314 durable then delete, :316-328 marker and INFO),
  :339-357 (`remove_mdbx_env` and its WARN), :431-432 (`.expect("Cannot migrate the consensus DB from
  MDBX")`), crates/storage/src/tndb/split.rs:50 (`MDBX_MIGRATED = "mdbx-migrated"`),
  crates/storage/src/mdbx/database.rs:110-114 (`PROD_EPOCH_MAX` 512 MiB, `PROD_KAD_MAX` 64 MiB,
  `PROD_CACHE_MAX` 1 GiB), crates/storage/Cargo.toml:64-67 (`reth-libmdbx` stays a default feature,
  so release builds carry the migration). Behaviour of the older binary:
  `git show d72cc2bcf:crates/storage/src/lib.rs` lines 149-160 (opens `consensus-db/epoch` as MDBX
  with no marker check).

##### After the migration a missing tndb environment is refused
- Document: guide > Troubleshooting > Service and keys (the `Cannot check database (epoch)` row);
  OPERATOR > section 9 (same row). Kind: addition (the basis of the section 3 correction).
  Current (guide branch): "Then stop the node (`sudo systemctl stop telcoin`) and move the epoch
  database out of the data directory, for example `sudo mv /var/lib/telcoin/consensus-db/epoch
  /var/lib/telcoin.epoch-<N>`, and keep `consensus-db/epochs` and `db` in place."
  Fact: once `consensus-db/tndb/mdbx-migrated` exists, an open refuses a tndb environment whose
  directory is missing, or whose directory has no `tables` manifest, and creates nothing. The start
  then panics `Cannot open database (tndb): tndb: environment <data dir>/consensus-db/tndb/epoch is
  missing beside <data dir>/consensus-db/tndb/mdbx-migrated (its log is lost); refusing to open it
  empty` (or `... has no table manifest beside ... (its files are lost); refusing to open it
  empty`). `db tndb-stat` reports a missing environment as an error too. Before the marker (the
  first start) missing environments are created. See section 3 for what this means for the
  `Cannot check database (epoch)` remedy.
  Cite: crates/storage/src/tndb/split.rs:56-95 (`check_environments`), :124-131 (`open_with` calls it
  first), crates/storage/src/lib.rs:411 (`.expect("Cannot open database (tndb)")`),
  crates/storage/src/tndb/split.rs:504-545 (test: a lost environment is refused and nothing is
  created), crates/storage/src/tndb/inspect.rs:185-196.

##### New at-rest subcommand `db tndb-stat`
- Document: guide > (the `db` subcommands, if the guide lists them; main guide does not); OPERATOR /
  README > wherever `db validate` / `db repair` / `db migrate` / `db load-state` are listed. Kind:
  addition (optional).
  Current: none found in the guide or OPERATOR main for `tndb-stat`.
  Fact: `telcoin-network db tndb-stat` prints, for `<data dir>/consensus-db/tndb`, each environment's
  generation, whether its log closed cleanly, its size, live and dead bytes, and each table's rows
  and index state. It changes no file, refuses to run while the node holds the data dir (the
  `telcoin.pid` lock, as the other at-rest `db` tools), holds the data dir while it runs, notes
  whether the MDBX tables were copied in, prints `(no tndb database at <path>)` on an MDBX node, and
  exits non-zero when an environment is missing or unreadable. The other `db` subcommands (`stats`,
  `validate`, `repair`, `migrate`, `load-state`) are unchanged in name.
  Cite: crates/telcoin-network-cli/src/db.rs:57-83 (enum, `TndbStat` doc at :78-82), :114,
  :1509-1541 (`tndb_stat`); old enum: `git show 98849a221:crates/telcoin-network-cli/src/db.rs`
  (`enum DbSubcommand` has no `TndbStat`).

##### Filesystem and address-space requirements of tndb
- Document: guide > Hardware per role (or the host preparation section); OPERATOR > section 1 (host
  requirements). Kind: addition (operator-facing recommendations; mdbook text plus code).
  Current (guide branch): "Storage is the same for every role: at least 2 TB of TLC NVMe (10,000
  write IOPS, 300 MB/s), 4 TB recommended." (still right; unchanged).
  Fact: tndb maps each log and index with a large virtual reservation: 16 GiB per log, three logs,
  and 1 GiB per table index, 14 tables, about 62 GiB of address space (not RAM, not disk). Under an
  address-space limit (`ulimit -v`, systemd `LimitAS=`, Docker `--ulimit as`) the node logs
  `MmapDataFile: could not reserve <n> bytes of address space ...` and falls back to mapping each
  file at its length; under a tight limit a later write fails and the node stops. Keep the limit
  unlimited (the default). The deployment scripts set none (`setup-node.sh` has no `LimitAS` or
  `ulimit`), so nothing to change on a default install. Growth preallocates disk blocks with
  `fallocate`; on a filesystem without it (ext2/ext3, NFS before 4.2, FUSE) growth falls back to
  sparse files with a warning, and the mdbook recommends ext4 or xfs for the data dir. A tndb
  compaction gives way when free space falls below its floor (`MIN_FREE = 2 * DISK_HEADROOM`).
  Cite: crates/storage/src/tndb/store.rs:65 (`LOG_MAP_RESERVE = 16 << 30`),
  crates/storage/src/archive/btree_index/index.rs:91 (`BTX_MAP_RESERVE = 1 << 30`),
  crates/storage/src/lib.rs:413-428 (14 tables opened), crates/storage/src/archive/data_file.rs:1058,
  :1480 (the `could not reserve` warnings), :20-28, :1523-1540 (`fallocate`, sparse fallback),
  crates/storage/src/tndb/compact.rs:140, :424-431; recommendation (ext4/xfs, unlimited address
  space): docs/src/getting-started/hardware-requirements.md (the "Operating system" list, added in
  this range). Overlaps whichever unit owns hardware-requirements.md; drop here if F2/F3 cover it.

##### #1767 (durability watermark race)
- Document: none. Kind: none.
  Fact: 7167e780 makes tndb advance its durable watermark before the persist waiters are woken
  (a race in the code above); no operator-visible text, flag or path changes.
  Cite: `git -C <worktree> show --stat 7167e780` (touches only crates/storage/src/tndb).

#### What did not change (section 1)
- `consensus-db/epochs` holds the epoch packs, the `v0.16.0-adiri` one-way pack migration (v1 to
  v2) and its log line — unchanged; crates/config/src/traits.rs:155-156,
  crates/storage/src/consensus_pack.rs:82 (`PACK_VERSION: u16 = 2`, same as at d72cc2bcf line 60),
  crates/storage/src/consensus_pack.rs:3154 (INFO `migrated legacy pack to v2 on open`). So the
  documents' v0.16 one-way text ("migrates the consensus store on its first start", "free space
  under `consensus-db/epochs`", `invalid version (should be 0)` from an older release) stays right
  for that update.
- `consensus-db/state_exports/epoch-N/` (the "Where things land" row and `--enable-state-export`
  text) — not touched by #1558; `git diff 98849a221..HEAD -- crates/config/src/traits.rs` is empty
  for the path helpers (traits.rs:140-156, :188-193).
- `<data dir>/db` is the reth execution database (MDBX) — unchanged; crates/config/src/traits.rs:192-193.
- The `Cannot check database (epoch)` prefix — unchanged text; crates/storage/src/lib.rs:436
  (`.expect("Cannot check database (epoch)")`), now on every open after the tndb open and the
  migration. (Its remedy changed: section 3.)

### Section 2: sync serving bounds (#1737, #1740, #1648)

None of the four documents states a sync-serve bound today except the spec's list of what travels
over sync streams, which stays right. The facts below are optional additions for the spec; the guide,
OPERATOR and README carry nothing on serving and need nothing. The sync-stream admission tiers (8 + 4
opening reads, 5 + 4 serves per class, 1 s / 5 s opening reads, mild penalties) came from the
fork-merge security fixes, not from these PRs; they belong to the networking unit and are listed here
only so nobody misattributes them.

#### Facts

##### A worker serves batches only for its own epoch and the one before (#1737)
- Document: spec > Networking > Request-response RPC (the bulk-transfer paragraph). Kind: addition
  (optional).
  Current: "Missing certificates, epoch consensus data, a single consensus output by its consensus
  number, and worker batches by digest travel over a separate sync-stream protocol, where one
  request opens a stream that the responder fills and then closes." (still right)
  Fact: a worker answers a batch request only for its own epoch and the previous one (at epoch 0 only
  epoch 0). It refuses any other epoch with `Deny(Unavailable)` before it acknowledges the request
  and before it reads storage, so a peer cannot make it open older epoch packs. Batches of older
  epochs reach a syncing node inside that epoch's consensus pack (spec Step 2), not from this stream.
  A serve now reads one batch at a time and flushes every 200 batches, so one serve holds at most one
  batch in memory plus two reusable frame buffers.
  Cite: crates/consensus/worker/src/network/mod.rs:616-625 (`serves_sync_epoch`), :627-645 (the
  `Deny(Unavailable)` write), crates/consensus/worker/src/network/stream_codec.rs:25
  (`SYNC_SERVE_FLUSH_INTERVAL = 200`).

##### The batch requester is bounded step by step and in total (#1740)
- Document: spec > Networking > Request-response RPC. Kind: addition (optional; one sentence at
  most).
  Current: none.
  Fact: a worker fetching missing batches tries current-committee peers first, and on the vote path
  the header's author first. Each exchange is bounded: 5 s to write and flush the request, 5 s for the
  `Ack` or `Deny`, 210 s for the data. A peer that fails other than by `Deny` is not tried again in the
  same call; the call makes up to 3 passes over its peers and is bounded at 480 s in total, after
  which it returns what it fetched or a timeout. So a peer that negotiates the protocol and then
  never reads the request cannot hold the requester.
  Cite: crates/consensus/worker/src/network/handle.rs:61 (`SYNC_REQUEST_WRITE_TIMEOUT` 5 s), :52
  (`SYNC_ACK_TIMEOUT` 5 s), :46 (`BATCH_STREAM_TOTAL_TIMEOUT` 210 s), :68
  (`MAX_BATCH_REQUEST_RETRIES` 3), :81 (`BATCH_REQUEST_TOTAL_TIMEOUT` 480 s), :219-262
  (`request_batches`: committee first, preferred peer, total timeout), :276-292 (skipped peers,
  preferred partition).

##### Serves answer from data on hand, without waiting (#1648)
- Document: spec > Trustless synchronization > Step 1 (the newest-record paragraph). Kind: none
  (confirms the current text); optional clause.
  Current: "A syncing node accepts a record only with its certificate, so the newest checkpoint
  becomes available once that certificate has been gathered."
  Fact: still right. A serving node that holds an epoch record without its certificate now answers
  "unavailable" at once (it used to wait up to 1.5 s), and a node asked for a consensus output past
  its own tip answers "unknown" at once (it used to wait up to 2 s when it was fewer than 4 outputs
  behind). The requester retries at another peer with its own backoff. Optional clause for Step 2:
  "A peer that does not yet hold the requested output or certificate says so at once, and the node
  asks another peer."
  Cite: crates/consensus/primary/src/network/handler.rs:1257-1273 (consensus output: answer only
  from local data), :1295-1307 (by epoch number), :1312-1325 (by digest); old wait loops:
  `git -C <worktree> show 2635e26a -- crates/consensus/primary/src/network/handler.rs` (removed
  `sleep(100 ms)` x 20 and `sleep(300 ms)` x 5).

##### Imported packs are taken strictly in order (#1558)
- Document: spec > Trustless synchronization > Step 2 or > Security properties ("Parent hash
  chaining"). Kind: addition (optional).
  Current: "It checks each header's parent link forward from the previous record's
  `final_consensus` and keeps the pack only if its last header matches the epoch record's
  `final_consensus`." (still right)
  Fact: a downloaded pack is also taken strictly in order: each output must carry exactly the next
  consensus number, so a peer cannot stall an import with a repeated, parent-linked output. The final
  output is checked against the certified `final_consensus` as soon as its header arrives, before its
  batches are read, and every batch must be the next one the header declares and within the
  per-batch size cap.
  Cite: crates/storage/src/consensus_pack.rs:4632-4645 (parent expectation, final digest),
  :4681-4747 (`check_import_header`: :4707-4712 exact next number), :4649-4677 (batch order and
  `BatchTooLarge`). The per-batch cap, the committee-author check and the final check existed at
  98849a221 (`UnexpectedConsensusDigest`, `BatchTooLarge`, `TooManyBatches` in
  `git show 98849a221:crates/storage/src/consensus_pack.rs`); the strict next-number rule is new
  (the commit message of 8aedf72e: "The fix makes streamed imports strictly in-order").

#### What did not change (section 2)
- Spec Step 2 "when it is more than a few outputs behind it first downloads a verified prefix of that
  epoch's pack" — unchanged; crates/state-sync/src/consensus.rs:27
  (`PARTIAL_PACK_CATCHUP_THRESHOLD = 5`); `git diff 98849a221..HEAD -- crates/state-sync/src/consensus.rs`
  touches only tests.
- Spec Step 2 "For each output that carries batches, the node also checks that every certificate
  author belongs to that epoch's committee" — unchanged; crates/storage/src/consensus_pack.rs:4730-4744.
- Spec Step 2 "keeps the pack only if its last header matches the epoch record's `final_consensus`"
  — unchanged; crates/storage/src/consensus_pack.rs:4637-4645.
- Spec Request-response RPC: what travels over sync streams (missing certificates, epoch consensus
  data, a single consensus output by number, worker batches by digest) — unchanged;
  crates/consensus/primary/src/network/handler.rs:1257-1273 (output by number),
  crates/consensus/worker/src/network/mod.rs:616-645 (batches by digest).

### Section 3: restart recovery re-check (#1572 and later: close_epoch.rs, the node manager)

Commits in range touching the restart path: 8aedf72e (#1558) on close_epoch.rs, run_epoch.rs,
node.rs, epoch_votes.rs, the subscriber and the proposer; 2635e26a (staging 10-13) on run_epoch.rs,
start_epoch.rs and node.rs; 5ccb88e8, d2a0b525 and 5f912b1d on start_epoch.rs and node.rs (worker
and network wiring, no restart-recovery change)
(`git -C <worktree> log --format='%h %s' 98849a221..HEAD -- crates/node/src/manager`).

#### Facts

##### `Cannot check database (epoch)`: same prefix, new directory, and its remedy no longer works as written
- Document: guide > Troubleshooting > Service and keys (the `Cannot check database (epoch)` row,
  branch side; main's guide has no such row); guide > One-way updates (the two lines pointing at
  it); OPERATOR > section 9 and section 4.2 (the same row and pointer, if the merge carries them).
  Kind: correction (path; remedy) — applies to a tndb node only.
  Current (guide branch, row): "Each start checks the epoch database, `consensus-db/epoch`, which
  holds only the epoch in progress." and "move the epoch database out of the data directory, for
  example `sudo mv /var/lib/telcoin/consensus-db/epoch /var/lib/telcoin.epoch-<N>`, and keep
  `consensus-db/epochs` and `db` in place."; (One-way updates): "That fix touches only
  `consensus-db/epoch`, which holds the epoch in progress, and never `consensus-db/epochs`, the
  epoch packs this update migrates."
  Fact: on every start the node still checks the epoch tables (`LastProposed`, `Certificates`,
  `ProposedCertificates`) with a fallible decode and stops with the same prefix and message: the
  journal shows `Cannot check database (epoch): epoch table <table> holds <n> row(s) this binary
  cannot decode, the first at key <key> with header epoch <N> (<error>); ...`. On tndb the message's
  own remedy now names the directory `consensus-db/tndb/epoch`: "Remove the epoch database directory
  `consensus-db/tndb/epoch` under the datadir, which holds only the epoch in progress (keep
  `consensus-db/epochs` and `db`), and start again once the network has closed that epoch ...; or
  restore the node into a fresh datadir from a state export bundle with `db load-state`". On the
  first tndb start over an MDBX data dir the same check runs on the MDBX source first and the panic
  reads `Cannot migrate the consensus DB from MDBX: Cannot check database (epoch) ...` with the
  directory `consensus-db/epoch`; there the remedy still works (no marker exists yet, so the
  migration copies the kad and cache tables and creates a fresh epoch environment).
  But on a node that has finished the migration (marker `consensus-db/tndb/mdbx-migrated` present),
  the remedy as written fails: the next start refuses the missing environment with `Cannot open
  database (tndb): tndb: environment <data dir>/consensus-db/tndb/epoch is missing beside <data
  dir>/consensus-db/tndb/mdbx-migrated (its log is lost); refusing to open it empty`, and an empty
  directory put back in its place is refused as `has no table manifest`. By code reading, moving
  both `consensus-db/tndb/epoch` and `consensus-db/tndb/mdbx-migrated` aside passes the check (the
  open recreates the environment, the migration finds no MDBX files and rewrites the marker), but no
  upstream message, doc or test says so. Writers: keep `consensus-db/epoch` for `v0.16.0-adiri`
  (every deployed node); for a tndb node do not print a `mv` command; say "email devs@telcoin.org
  with the journal line before you move anything". Upstream issue for the orchestrator (see "Could
  not settle").
  Cite: crates/storage/src/lib.rs:433-436 (the check on every open, `.expect("Cannot check database
  (epoch)")`), crates/storage/src/epoch_db_recovery.rs:18-30 (module doc: the way out),
  :138-139 (`EPOCH_DIR = "consensus-db/tndb/epoch"` for tndb), :205-226 (the message),
  crates/storage/src/mdbx/database.rs:421-422 (`EPOCH_DIR = "consensus-db/epoch"` for the MDBX
  source), crates/storage/src/lib.rs:281-282 (the migration's check, `.wrap_err("Cannot check
  database (epoch)")`), :432; the refusal: crates/storage/src/tndb/split.rs:67-95, :129-131,
  crates/storage/src/lib.rs:411, crates/storage/src/tndb/split.rs:504-545 (test); the marker-less
  path: crates/storage/src/tndb/split.rs:68-74 (no marker, no check), crates/storage/src/lib.rs:268-273,
  :316-322.

##### `; initiating node shutdown` is gone: the line now says the epoch ends, and the node process stops
- Document: guide > Troubleshooting > Service and keys (the `; initiating node shutdown` row, branch
  side); OPERATOR > section 9 (same row). Kind: correction (log text, behaviour and fix) — applies to
  a binary built from main since 8aedf72e; `v0.16.0-adiri` keeps the old text and behaviour.
  Current (guide branch): "| An `ERROR` line ending `; initiating node shutdown: <error>` | The node
  could not write a vote or certificate durably to its epoch database, `consensus-db/epoch`, and
  stopped its consensus tasks rather than risk signing twice. It keeps running, but it cannot vote
  again until it is restarted. | ... Fix the cause, then restart the node at once with `sudo
  systemctl restart telcoin`; the epoch wait protects nothing while the node cannot vote. ..."
  Fact: the six durability-barrier ERROR lines (three in the certifier, three on the vote path) now
  end `; ending the epoch (the node stops if its stores cannot write): <error>`, for example
  `epoch DB durable barrier failed for vote; ending the epoch (the node stops if its stores cannot
  write): ...` or `durable barrier failed for own certificate, refusing to externalize; ending the
  epoch (the node stops if its stores cannot write): ...`. A barrier fails only after the store has
  latched a failed write or sync (the latch is never cleared in the process). The node then stops
  itself: the epoch loop returns the store error (at once, through a watcher on every consensus
  store, or at the epoch's end through a persist of one table per store), logs ERROR `epoch returned
  error` and `Error running node: a consensus store can no longer make writes durable; stopping the
  node` (or `the epoch store (votes, certificates, proposals) can no longer make writes durable;
  stopping the node (a restart reopens it)`, and the same for `the peer-record store` and `the
  batch-cache store`), and the process exits with status 1. systemd (`Restart=on-failure`,
  `RestartSec=10`) starts it again, which reopens the stores; a disk that still fails makes it fail
  again and it can end in `start-limit-hit` (5 starts in 60 s). Fix for the row: check the data drive
  (free space `df -h /var/lib/telcoin`, I/O errors `sudo dmesg`), fix the cause; if systemd gave up,
  `sudo systemctl reset-failed telcoin && sudo systemctl start telcoin`; the manual "restart at once"
  is no longer needed. The epoch directory in the cause is `consensus-db/tndb/epoch` on tndb.
  Cite: crates/consensus/primary/src/certifier.rs:533-534, :561-562, :606-607;
  crates/consensus/primary/src/network/handler.rs:610-622, :1115-1123, :1155-1163;
  crates/storage/src/tndb/database.rs:557-563 (persist fails once any write or sync failed; latch
  never cleared), :176-182 (`failure`), crates/storage/src/tndb/split.rs:325-337 (`failed` names
  the environment); crates/node/src/manager/node/run_epoch.rs:463-474 (`store_failed` arm),
  :627-630 and :1146-1163 (`ensure_stores_durable` messages), :1196-1213 (`store_failure` message),
  crates/node/src/manager/node.rs:1750-1753 (`epoch returned error`, `?` returns),
  crates/node/src/lib.rs:89-91 (`Error running node: {err}`), bin/telcoin-network/src/main.rs:19-24
  (exit 1); this repo: lib/common.sh:3364-3379, :3399-3413 (unit restart policy, working tree).
  Old: `git show 98849a221:crates/consensus/primary/src/certifier.rs` lines 532, 559, 603 (`;
  initiating node shutdown: {e}`).

##### More own-storage failures now stop the node (fail-stop)
- Document: spec > Trustless synchronization > Recovery after restart (or Security properties).
  Kind: addition (optional, one sentence).
  Current: none.
  Fact: a node whose own storage fails stops instead of running on: a consensus store that can no
  longer make writes durable, a failed persist of its consensus pack at the epoch's end or before a
  state export (it used to log a warning and skip the export), a certificate pack that fails to seal,
  and a failed save or persist of a downloaded epoch record (it used to log an error and go on). A
  peer's invalid or conflicting epoch record is still only logged and asked for again. A restart
  reopens the stores. Suggested sentence: "A node whose own storage can no longer make writes durable
  stops rather than run on, and a restart reopens its stores."
  Cite: crates/node/src/manager/node/run_epoch.rs:575-631 (`finish_epoch`), :1214-1235
  (`seal_certificate_pack`), crates/node/src/manager/node/close_epoch.rs:758-761 (the state-export persist,
  `.wrap_err("the consensus pack can no longer make writes durable; stopping the node")`; old: `warn!
  ... "could not persist consensus pack; skipping export"` in
  `git diff 98849a221..HEAD -- crates/node/src/manager/node/close_epoch.rs`),
  crates/state-sync/src/epoch.rs:136-144 (`stop_on_local_failure`), :252-257 (`.wrap_err("failed to persist downloaded
  epoch record/certs")?`); old: `error!` and continue (`git diff 98849a221..HEAD --
  crates/state-sync/src/epoch.rs`).

##### A committee member whose synced records are ahead now starts as `CvvInactive`
- Document: spec > Trustless synchronization > Recovery after restart; spec > Node modes > Mode
  detection (overlaps the node-modes unit if there is one). Kind: correction (refinement).
  Current (Recovery after restart): "a committee member resumes as `CvvActive`, unless the epoch
  records it syncs already rotate it out, and drops to `CvvInactive` if it finds itself behind";
  (Mode detection): "If the node's key is in the new committee, it enters `CvvActive`, unless the
  newest epoch record it holds names a next committee without that key, in which case it runs as an
  observer."
  Fact: when the newest epoch record a committee member holds is for a later epoch than the one it is
  starting, and that record's next committee still holds its key, it starts as `CvvInactive` and
  catches up before it votes, instead of starting as `CvvActive` and being demoted later. A record
  whose next committee lacks its key still makes it an observer, and a record older than the
  committee's own epoch cannot veto it. A node already `CvvInactive` stays so (sticky), as before.
  Suggested text: "a committee member resumes as `CvvActive`, unless the epoch records it syncs already
  rotate it out (it then runs as an observer) or are already past its epoch (it then starts as
  `CvvInactive`); it also drops to `CvvInactive` if it finds itself behind."
  Cite: crates/node/src/manager/node.rs:1954-1982 (`node_mode_from_epoch_record`: :1975-1976
  `record.epoch > local_epoch` gives `CvvInactive`), crates/node/src/manager/node/start_epoch.rs:1178-1235
  (`identify_node_mode`, sticky `CvvInactive` at :1192-1195); old:
  `git show 98849a221:crates/node/src/manager/node.rs` lines 1948-1968 (no `CvvInactive` branch);
  added by 2635e26a (`git log -S'record.epoch > local_epoch'`).

#### What did not change (section 3)
- Restart repair log lines the guide quotes (`previous epoch record missing on restart (killed at
  its boundary); re-deriving it locally`, `epoch record present but the consensus db tables still
  hold rows of an older epoch (killed between the record write and the tables clear); clearing
  them`) — unchanged text; crates/node/src/manager/node/close_epoch.rs:607-612, :669-676 (the same lines
  at 98849a221); INFO `re-derived epoch record written - clearing the previous epoch's consensus db
  tables` at :634-639.
- `ignoring parent certificates from another epoch` (benign WARN) — unchanged text;
  crates/consensus/primary/src/proposer.rs:586 (was :585).
- Spec Recovery after restart: "It rebuilds the epoch's gas accounting, leader reward counts and leader
  schedule from its locally stored blocks and consensus data. It then replays any consensus output
  that was committed but not yet executed" — unchanged; crates/node/src/manager/node.rs:360
  (`catchup_accumulator`), :435 (`count_leaders`), crates/node/src/primary.rs:80
  (`LeaderSchedule::from_store`), crates/node/src/manager/node/start_epoch.rs:126
  (`replay_missed_consensus`); all three present at 98849a221.
- "A node that restarts mid-epoch does not repeat full synchronization" — unchanged; the stores and
  packs are reopened in place (crates/storage/src/lib.rs:405-437, consensus packs under
  `consensus-db/epochs`).
- The guide's restart-window advice (keep to the epoch wait; the node repairs its epoch records
  when it starts again and logs warnings that need no action) — still right; the repair paths above
  are unchanged.
- The ERROR for a mix of older rows beside a current-epoch vote or proposal (`... keeping every table
  so the current epoch's equivocation guards survive ...`) — unchanged;
  crates/node/src/manager/node/close_epoch.rs:654-667 (present at 98849a221, same lines).

### What did not change
Consolidated; each line is a statement the documents make today, checked at 7167e7800.

- Spec > Trustless synchronization: the three steps, the seed-hash table, Step 3 and the four
  Security properties — unchanged; no commit in range touches the epoch-record verification
  (`git diff --stat 98849a221..HEAD -- crates/state-sync/src/epoch.rs` changes only error handling,
  section 3), the partial-pack threshold (crates/state-sync/src/consensus.rs:27) or the import checks
  beyond the strict next-number rule (crates/storage/src/consensus_pack.rs:4632-4747, section 2).
- Spec > Trustless synchronization > Step 1: "A syncing node accepts a record only with its
  certificate, so the newest checkpoint becomes available once that certificate has been gathered."
  — unchanged; crates/consensus/primary/src/network/handler.rs:1295-1307.
- Spec > Networking > Request-response RPC: the list of what travels over sync streams — unchanged;
  crates/consensus/primary/src/network/handler.rs:1257-1273, crates/consensus/worker/src/network/mod.rs:616-645.
- Spec > Recovery after restart: "A node that restarts mid-epoch does not repeat full
  synchronization. It rebuilds the epoch's gas accounting, leader reward counts and leader schedule
  from its locally stored blocks and consensus data. It then replays any consensus output that was
  committed but not yet executed" — unchanged; crates/node/src/manager/node.rs:360, :435,
  crates/node/src/primary.rs:80, crates/node/src/manager/node/start_epoch.rs:126. (Its mode clause
  is refined: section 3.)
- The spec names no database, redb, MDBX, `consensus-db` path or "first start" anywhere; the only
  storage nouns are "consensus pack" (Trustless synchronization) and "state snapshot", both still
  right — no sentence to correct.
- Guide / OPERATOR / README: `consensus-db/epochs` holds the epoch packs; the `v0.16.0-adiri`
  one-way update (packs v1 to v2 on the first start, the free-space check under
  `consensus-db/epochs`, `invalid version (should be 0)` from an older release, the snapshot steps)
  — unchanged; crates/config/src/traits.rs:155-156, crates/storage/src/consensus_pack.rs:82, :3154;
  update-node.sh:134 (`STORAGE_MIGRATION_FLOOR="0.16.0"`), :1080 (the `Not rolled back` message).
- Guide / OPERATOR: `consensus-db/state_exports/epoch-N/` and `<data dir>/db` (the execution
  database) — unchanged; crates/config/src/traits.rs (no diff in range), :192-193.
- Guide: the restart-repair warnings that need no action (`previous epoch record missing on
  restart ...`, `epoch record present but the consensus db tables still hold rows of an older epoch
  ...`, `ignoring parent certificates from another epoch`) — unchanged text;
  crates/node/src/manager/node/close_epoch.rs:607-612, :669-676, crates/consensus/primary/src/proposer.rs:586.
- Guide: `Cannot check database (epoch)` as the journal prefix — unchanged;
  crates/storage/src/lib.rs:436. (Directory and remedy: section 3.)
- Guide / OPERATOR: `CvvInactive` until caught up, then `attempting to rejoin consensus` —
  unchanged; crates/consensus/executor/src/subscriber.rs:38 (`REJOIN_HEAD_MAX_AGE` 5 s), :317;
  crates/types/src/primary/mod.rs:72, :84 (`gc_activity_window`, `rejoin_round_window`).
- Guide: systemd restarts a failing node every 10 s and gives up after 5 starts in 60 s
  (`start-limit-hit`) — unchanged in this repo; lib/common.sh:3364-3379, :3399-3413 (the unit
  writer moved there from setup-node.sh on this branch).
- Hardware: "Storage is the same for every role: at least 2 TB of TLC NVMe ..." — no tndb fact
  contradicts it (section 1 adds filesystem and address-space notes only).

### Seen but out of scope
- The sync-stream admission tiers (opening-read pool 8 + 4 committee, serve pools 5 + 4 per class,
  1 s / 5 s opening reads, mild penalties, the 200 s public epoch-pack hold limit;
  crates/consensus/worker/src/network/mod.rs:45-127, crates/consensus/primary/src/network/mod.rs:84-208,
  docs/src/network/sync-streams.md) — from the fork-merge security fixes; the networking unit owns them.
- tndb internals: compaction thresholds (64 MiB default, 256 MiB cache, 2 GiB epoch safety net;
  crates/storage/src/tndb/database.rs:47, crates/storage/src/tndb/split.rs:36, :42), group commit,
  the B+tree index, `tn_storage_tndb_*` metrics — maintainer-only.
- `db validate`, `db repair`, `db migrate` hardening inside #1558 (classifier output, index bucket
  scans) — operator tools the documents do not describe; names unchanged
  (crates/telcoin-network-cli/src/db.rs:57-83).
- The new per-epoch `cert_lock` file under `consensus-db/epochs/epoch-N/`
  (crates/storage/src/certificate_pack.rs:368) — internal; nobody touches it.
- `workload_bench`, `pack_bench`, `db_bench` — benchmarks.
- State-sync metrics (`headers_fetched_total` counted per delivery; crates/state-sync/src/lib.rs
  in 2635e26a) — metrics are out of scope.
- `update-node.sh` treats only the 0.16.0 floor as one-way (update-node.sh:134, :963-983). When a
  release carrying tndb is tagged, the MDBX-to-tndb switch is a second one-way floor, and a
  downgrade from that release to `v0.16.0-adiri` is not refused by the floor and is unsafe for a
  committee member (section 1). That is a script change for the triage list, not a document fact
  for this round.
- Staging 10-27 and the worker gateway — not on main.

### Could not settle
1. How the documents name the release that brings tndb. No tag carries 8aedf72e (newest tag
   `v0.16.0-adiri`, which is MDBX), and last round's rule bans "next release". Every tndb fact in
   sections 1 and 3 (paths `consensus-db/tndb/...`, the MDBX-to-tndb one-way switch, the new
   `; ending the epoch ...` text and the process exit, `db tndb-stat`) is true of main and false of
   every deployed node. Orchestrator/user decision: describe main as current behaviour (last
   round's decision 1) and keep the `v0.16.0-adiri` paths beside them, or hold the tndb facts until
   a tag exists.
2. The `Cannot check database (epoch)` remedy on a migrated tndb node. The upstream message says
   to remove `consensus-db/tndb/epoch`, but `check_environments` refuses exactly that once
   `mdbx-migrated` exists (crates/storage/src/epoch_db_recovery.rs:205-226 against
   crates/storage/src/tndb/split.rs:67-95). Removing the marker too passes the check by code reading
   (split.rs:68-74, lib.rs:268-273, :316-322), but nothing upstream tests or documents it, and on a
   host that later regained MDBX files (a downgrade) it would re-copy stale MDBX rows over tndb
   (lib.rs:371-397 clears each table first). Recommended document text: name the symptom, give
   the directory per release, and send operators to devs@telcoin.org before they move anything.
   Worth an upstream issue.
3. Whether `v0.16.0-adiri` itself starts or panics when its MDBX `consensus-db/epoch` directory has
   been deleted by the migration. The upstream comments say it starts with empty epoch tables
   (crates/storage/src/lib.rs:234-237, :255-258), and a fresh `v0.16.0-adiri` node opens the same
   path when it does not exist (`git show d72cc2bcf:crates/storage/src/lib.rs` lines 149-160), so
   "starts with empty epoch tables" is the reading used above; it was not run.

Counts: corrections 3 (the `Cannot check database (epoch)` path and remedy; the `; initiating node
shutdown` row; the `CvvInactive` start rule in Recovery after restart / Mode detection), additions 8
(tndb layout row; MDBX-to-tndb one-way migration; missing-environment refusal; `db tndb-stat`;
filesystem and address-space notes; worker serves only its own and the previous epoch; batch requester
bounds; strict in-order pack import; plus one optional fail-stop sentence and one optional #1648
clause), unchanged items 13 in the consolidated list (plus the per-section lists).

---

## F2: networking (7167e7800)

Paths are relative to the telcoin-network worktree named in the preamble. "Old" means main at
98849a221. Sections are appended in the order of the brief: (1) transport and connection
limits, (2) discovery, kad and peer exchange, (3) gossip, forwarding and request-response,
(4) the health listener and the ports table, (5) what did not change. The "What did not
change" list for every section is collected in section 5.

## Section 1: transport and connection limits

### Facts

#### Connection attempt timeout (#1690, in 942d08cd)
- Document: spec > Networking > Transport. Kind: correction.
  Current: "A connection attempt, handshake included, is abandoned after about ten seconds, and a connection whose peer stops answering is closed by the QUIC idle timeout within about half a minute."
  Fact: The first half is now wrong as a description of a dial. Each address gets a QUIC
  handshake window of 10 seconds (it was 65 s, capped in practice by the libp2p transport
  timeout of 10 s, which is where "about ten seconds" came from). A node dials a peer's signed
  addresses in order, at most four of them, and the whole dial is bounded by 45 seconds
  (5 s slack plus 10 s for each of four addresses); the peer manager's dial timeout is raised to
  match (at least 50 s). An inbound handshake still holds its slot for at most the 10-second
  handshake window. Suggested text: "Each address of a peer gets ten seconds to complete the
  QUIC handshake; a dial tries the peer's signed addresses in order, at most four, and gives up
  after 45 seconds." The second half (idle timeout about half a minute) is still right.
  Cite: crates/config/src/network/quic.rs:67 (handshake 10 s), :68 (idle 30 s);
  crates/node-record/src/addresses.rs:11 (`MAX_ADVERTISED_MULTIADDRS = 4`);
  crates/network-libp2p/src/consensus.rs:186 (`DIAL_TIMEOUT_SLACK` 5 s), :673-677 (outer
  timeout = 5 s + 4 x handshake = 45 s), :678-684 (peer-manager dial timeout = max(15 s, 45 s +
  5 s)), :881 (`with_connection_timeout(connection_timeout)`), :337-339 (inbound hold time);
  crates/config/src/network.rs:874 (requested `dial_timeout` 15 s). Old values:
  `git show 98849a221:crates/config/src/network/quic.rs` line 40 (65 s); the old comment at
  `git show 942d08cd -- crates/network-libp2p/src/consensus.rs` ("TransportTimeout with a 10
  second default").

#### QUIC receive credit (security merge 2f37c7b3, branch commits ee1a4b1a, 64c39f44)
- Document: spec > Networking > Transport. Kind: addition (optional; the spec states no QUIC
  window today).
  Current: none
  Fact: The QUIC receive credit is now small and bounded. One stream may hold 2 MiB of data
  the node has not yet read, one connection 4 MiB (two stream windows), and a connection may
  open at most 256 concurrent incoming streams. The old defaults were 50 MiB per stream,
  100 MiB per connection and 10,000 streams. With the connection ceilings below, one peer id can
  make the node buffer at most 32 MiB (8 x 4 MiB) and one swarm at most 512 MiB
  (128 x 4 MiB). The code comment gives the throughput consequence: about 40 MiB/s per
  connection at a 100 ms round trip.
  Cite: crates/config/src/network/quic.rs:45 (`DEFAULT_MAX_CONCURRENT_STREAM_LIMIT = 256`), :53
  (`DEFAULT_MAX_STREAM_DATA = 2 * 1024 * 1024`), :62 (`DEFAULT_MAX_CONNECTION_DATA =
  4 * 1024 * 1024`), :70-72 (defaults applied); crates/network-libp2p/src/consensus.rs:216
  (8 per peer), :227 (128 per swarm). Old: `git show 98849a221:crates/config/src/network/quic.rs`
  lines 43-48.

#### Established-connection ceilings (2f37c7b3)
- Document: spec > Networking > Transport (or Peer scoring). Kind: addition.
  Current: none
  Fact: Each swarm (the primary and each worker) accepts at most 128 established connections
  in total, both directions and every peer class, and at most 8 from one peer. 128 is two
  connections for each of the 39 default peer slots plus a committee of 25. The 8-per-peer
  bound and a ceiling of 1,024 pending inbound handshakes per swarm existed before; the
  128-per-swarm bound is new. Committee members have no bypass of these two ceilings, by design;
  an operator `process_budget` replaces both.
  Cite: crates/network-libp2p/src/consensus.rs:216 (`MAX_ESTABLISHED_CONNECTIONS_PER_PEER = 8`),
  :218-227 (`MAX_ESTABLISHED_CONNECTIONS = 128`, its derivation and the no-bypass sentence),
  :247 (`MAX_PENDING_INCOMING_CONNECTIONS = 1024`), :347-362 (`connection_limits_behaviour`),
  :817-818 (applied with the process budget); crates/config/src/network.rs:869
  (`target_num_peers` = 20/2 + 20 = 30), :875 (excess 0.3), :890-892 (`max_peers` =
  ceil(30 x 1.3) = 39). Old file has no `MAX_ESTABLISHED_CONNECTIONS`
  (`git show 98849a221:crates/network-libp2p/src/consensus.rs | grep -n 'const MAX_'`).
- Document: spec > Networking > Peer scoring. Kind: correction (precision).
  Current: "Members of the previous, current and next committees are exempt from scoring: penalties and bans do not apply to them, and they may connect beyond the normal peer limits."
  Fact: "beyond the normal peer limits" stays true for the peer-count target (the peer
  manager's slots), but committee members count against the per-swarm ceiling of 128
  established connections and the 8-per-peer ceiling like everyone else. Suggested addition:
  "They still count against the node's fixed connection ceilings." (Section 3 checks the
  scoring half of this sentence.)
  Cite: crates/network-libp2p/src/consensus.rs:224-226 ("Committee members have no bypass, by
  design"), :322-323 ("this behaviour must never install bypass peer IDs").

#### QUIC Retry (#1691, in 942d08cd)
- Document: spec > Networking > Transport. Kind: addition (optional).
  Current: none
  Fact: #1691 adds only observations (counters of the listener's Retry, accept, refuse and
  ignore decisions, a carried quinn-proto patch); the Retry behaviour itself was already on
  main at 98849a221 and is unchanged. What the spec could say: the QUIC listener answers each
  connection attempt from a source address it has not validated with a QUIC Retry packet
  (RFC 9000 section 8.1) before it creates any connection state, so a forged source address
  cannot occupy a handshake slot; this is on by default. Queued attempts are bounded per
  listener (720 attempts by default: 45 priority peers x 8 connections x 2 attempts).
  Cite: crates/config/src/network/quic.rs:30-35 (field doc), :73 (default `true`);
  crates/network-libp2p/src/quic_incoming.rs:6-9, :35-40 (derivation), :55-70;
  crates/network-libp2p/src/consensus.rs:229-236 (pending slot needs a validated round trip),
  :861-870 (applied to the swarm); crates/config/src/network.rs:898-901
  (`max_priority_peers` = ceil(30 x 1.5) = 45); patches/quinn-proto/PATCH.md (observer only).
  Old: `git show 98849a221:crates/config/src/network/quic.rs` line 49 (`true`).

#### Connection admission policy (#1534, in 5ccb88e8)
- Document: guide > Install > Optional node flags (the `network-config` paragraph). Kind:
  addition.
  Current: "Four of the keys it accepts are opt-in, `process_budget`, `source_admission`, `trusted_nodes` and `committee_peers`: they are unset by default (absent, `null` or `{}`), and no script sets them."
  Fact: `network-config` has a new key, `admission`, with `mode: Open` (the default), `Grace`
  or `Closed`, and `snapshot_max_age_secs` (default 300). Open keeps today's behaviour. Closed
  admits only the previous, current and next committees, the configured `trusted_nodes` and
  the configured bootstrap peers, and only once the node holds enough authenticated committee
  records; otherwise it falls back to Grace or Open by itself. No script sets it. A second new
  opt-in key, `serve_budget`, is in section 3. So the paragraph should name six opt-in keys,
  or say "several, among them ...". Leave it unset.
  Cite: crates/config/src/network.rs:42-43 (field), :467-477 (`AdmissionMode`, `#[default]
  Open`), :480-493 (`AdmissionConfig`, default `Open`, 300 s at :491), :511-514 (renewal at a
  third of the lease); crates/network-libp2p/src/peers/admission.md:3, :15-16, :38-46 (Closed conditions,
  maintainer design note); old struct has no `admission` field
  (`git diff 98849a221 HEAD -- crates/config/src/network.rs`).
- Document: spec > Networking > Identity and discovery or Peer scoring. Kind: addition
  (optional; partner readers need at most one sentence).
  Current: none
  Fact: A node can restrict which identities may connect to it: in the opt-in Closed mode it
  admits only the previous, current and next committees and the peers its operator configured,
  and it falls back to open admission whenever its committee view is incomplete or stale. The
  default is open admission. Admission grants no score or penalty exemption and lifts no
  transport limit.
  Cite: crates/config/src/network.rs:467-477; crates/network-libp2p/src/peers/admission.md:53-59
  (fallback table), :80-83.

#### Gossipsub frame limits (#1677)
- Document: spec > Networking > Gossipsub topics. Kind: addition.
  Current: "Each topic enforces message validation rules specific to its payload type."
  Fact: A gossip message carries at most 12,000 bytes of payload, on every topic (that bound
  existed before). New: the gossip codec checks each received frame on its raw bytes, before
  it decodes it or verifies any signature: a frame larger than 24,579 bytes, or with more than
  8 messages, or with more than 16 KiB of control data, closes the stream and none of its
  messages is delivered. 24,579 = max(12,000 + 512, 16,384 + 3) + 8,192.
  Cite: crates/config/src/network.rs:542 (`MAX_GOSSIP_MESSAGE_SIZE = 12_000`);
  crates/network-libp2p/src/gossip_config.rs:26 (512), :34 (16 KiB), :41 (8 KiB read chunk),
  :46 (3), :54-57 (`GOSSIP_FRAME_BOUND`), :63 (`GOSSIP_MAX_TRANSMIT_SIZE`), :71 (8 per frame),
  :129-134 (codec gate runs first, closes the stream), :164-169 (applied). Old: no frame limits
  (`git show 98849a221:crates/network-libp2p/src/consensus.rs` lines 612-627).

#### Inbound rejection reasons (#1695) and the connection-limit warning
- Document: none (no document quotes it). Kind: none; recorded so writers do not invent a change.
  Current: none
  Fact: #1695 only counts every refused inbound connection by reason (metrics, out of scope).
  The operator WARN `inbound connections keep being refused by connection limits` (fields
  `denied`, `window`) is unchanged in text and in rate: at most one per 60-second window of
  refusals. It now also fires when the new 128-connection swarm ceiling refuses.
  Cite: crates/network-libp2p/src/consensus.rs:251 (60 s), :1276-1297 (warning); old text at
  `git show 98849a221:crates/network-libp2p/src/consensus.rs` line 1171.

#### Bounded warning volume (#1692)
- Document: guide > Troubleshooting (optional), spec none. Kind: addition (optional).
  Current: none
  Fact: Network warnings and errors that a remote peer can trigger are rate-limited per log
  call site: at most four detailed lines per minute, then one WARN
  `repeated network diagnostics suppressed` (target `network::diagnostics`, fields
  `event_class`, `site`, `emitted`, `suppressed`, `window_seconds`) for the rest of the window.
  The line is informational: a peer misbehaving or a burst of refusals, not a fault of this
  node. Listener errors are limited the same way (one `error` per 60 s with a suppressed
  count).
  Cite: crates/network-libp2p/src/diagnostics.rs:1-7, :106-123 (summary WARN);
  crates/network-libp2p/src/diagnostics/window.rs:6 (`BURST = 4`), :8 (`INTERVAL = 60 s`);
  crates/network-libp2p/src/consensus.rs:278-310 (`LISTENER_ERROR_LOG_INTERVAL`, `ListenerErrorLog`).

### Seen but out of scope (section 1)
- QUIC listener observation counters and `tn_network.inbound_connections_denied_total` /
  rejection-reason labels (#1691, #1695), the `tn_network.diagnostics_suppressed_total` counter
  (#1692): metrics series and labels.
- `docs/src/network/transport.md:43-54` still lists the old QUIC defaults (65 s handshake,
  10,000 streams, 50 MiB / 100 MiB windows). The mdbook is stale; cite the code, not that page.
- The quinn-proto and libp2p-quic carried patches (`patches/`), CI QUIC interop lanes:
  maintainer tooling.

## Section 2: discovery, kad and peer exchange

### Facts

#### Node records and the DHT
- Document: spec > Networking > Identity and discovery. Kind: none (still right).
  Current: "The DHT uses standard Kademlia routing with a K-bucket size of 20. Bucket inserts are performed manually with record filtering to prevent pollution. Nodes target more connected peers than the K-bucket size to maintain routing table coverage."
  Fact: Unchanged. The record format did not change in this range (no diff under
  `crates/node-record`), so the record paragraph ("Each record is keyed by the node's primary
  BLS public key ...", "The BLS signature covers the chain id and the role ...") stays right.
  Cite: crates/config/src/network.rs:672 (`k_bucket_size: K_VALUE`, 20), :869 (target 30 peers);
  crates/network-libp2p/src/consensus.rs:745 (manual inserts), :752 (`FilterBoth`);
  `git diff --stat 98849a221 HEAD -- crates/node-record` (empty).

#### Inbound DHT record writes are bounded across sources (#1739, in 2d4afcd7)
- Document: spec > Networking > Identity and discovery. Kind: addition (optional).
  Current: none
  Fact: Every inbound DHT record costs a BLS signature check, so the node bounds them twice.
  Per source, it accepts 30 record writes a minute and sheds the rest without penalty; a source
  that sends more than 2,048 in a minute is penalised, and above 16,384 every further write is
  penalised (both per-source bounds existed before). New: all sources other than the previous,
  current and next committee, the operator's trusted peers and its bootstrap peers share one
  budget of 2 record checks per second, with a burst of 120; a record over that budget is shed
  without penalty. Partner wording: "A node checks at most about two DHT records per second from
  peers outside the committee and its configured peers; the excess is dropped, not penalised."
  Cite: crates/network-libp2p/src/peers/manager.rs:73 (60 s window), :106 (30 per source), :113
  (`KAD_MAX_STORED_RECORDS = 1024`), :121 (2,048), :127 (16,384), :135 (2 per second), :145
  (burst 120), :1836-1875 (per-source decision), :1881-1890 (shared budget, exemption);
  crates/network-libp2p/src/peers/policy.rs:49-57 (`SharedRecordBudget`), :95-114 (Bootstrap,
  Operator and Validator bases all exempt). Old: per-source constants at
  `git show 98849a221:crates/network-libp2p/src/peers/manager.rs` lines 67-121, no
  `PUT_RECORD_BUDGET_*`.

#### Identical-record weighting (security merge ed092164)
- Document: none. Kind: none (internal).
  Current: none
  Fact: A byte-identical copy of a stored DHT record is written to disk again only when the
  stored row has lapsed or the copy extends its expiry by more than half the record TTL (TTL
  48 hours by default), so one key costs at most two disk commits per TTL however many copies
  arrive; the kept expiry never shrinks. Not partner material; recorded so a writer does not
  describe it as a protocol change.
  Cite: crates/network-libp2p/src/kad.rs:1098-1119 (`identical_refresh`, fn at :1106);
  crates/config/src/network.rs:673 (48 h TTL).

#### Peer exchange caps (security merge b68ce0c7)
- Document: spec > Networking > Identity and discovery. Kind: addition (optional; the spec does
  not describe peer exchange today).
  Current: none
  Fact: When a node sheds a peer because it holds too many, it sends that peer a goodbye that
  lists other peers to try (peer exchange). A peer-exchange map now carries at most 128 peers,
  each with at most four addresses; a larger map is rejected from its length prefix before any
  entry is decoded, and the receiver never decompresses the listed BLS keys. The dedicated
  peer-exchange codec's size ceiling is derived from those caps, not from the 1 MiB RPC limit.
  Cite: crates/network-libp2p/src/peers/types.rs:138 (`MAX_PEER_EXCHANGE_ENTRIES = 128`), :144
  (per-peer address cap), :150 (256-byte address allowance), :164-165 (codec ceiling);
  crates/network-libp2p/src/peers/peer.rs:41 (`MAX_MULTIADDRS_PER_PEER` =
  `MAX_ADVERTISED_MULTIADDRS`); crates/node-record/src/addresses.rs:11 (4);
  crates/network-libp2p/src/consensus.rs:714-724 (codec built with
  `min(max_rpc_message_size, MAX_PEER_EXCHANGE_MESSAGE_SIZE)`).

#### Recovery from a disconnect-level ban (#1651, in 2635e26a)
- Document: spec > Networking > Peer scoring (table row `Disconnected`). Kind: none (still
  right; now true in every path).
  Current: "| `Disconnected` | -20 or below | Connection closed; reconnection refused for ten minutes |"
  Fact: Still right. #1651 fixes a case where a peer disconnected for a disconnect-level penalty
  (score between -50 and -20) kept a banned connection status in the peer store after the
  ten-minute reconnection timeout; the heartbeat now restores it after the same 600 seconds.
  Reputation bans (-50 or below) keep their 30-minute decay lockout.
  Cite: crates/network-libp2p/src/peers/all_peers.rs:461-464, :499-507;
  crates/network-libp2p/src/peers/manager.rs:916 (passes `excess_peers_reconnection_timeout`);
  crates/config/src/network.rs:879 (600 s), :968 (30 min), :969-970 (-20, -50).

#### Committee member records survive pruning (#1652, in 2635e26a)
- Document: spec > Networking > Peer scoring (last paragraph). Kind: addition (optional).
  Current: "When a validator joins a tracked committee, any ban on it is lifted and its score is reset to the maximum."
  Fact: The node also keeps the stored record of every member of the previous, current and next
  committees when it prunes disconnected or banned peers, because that record binds the member's
  peer id to its BLS key; without it the node would stop recognising the member as a validator.
  If the binding is lost another way, the node restores it from its cached signed record, and
  again at every committee update. Suggested one sentence: "It also never prunes a tracked
  committee member's peer record, which ties the member's peer id to its BLS key."
  Cite: crates/network-libp2p/src/peers/all_peers.rs:1065-1078 (`collect_excess_peers` skips
  `is_committee_record`), :1243-1248 (`is_committee_record`, three committee slots).

#### What a bootstrap peer is used for
- Document: guide > Install > Optional node flags; README > Bootstrap peers; spec none. Kind:
  none for the existing sentence (still right); addition (optional) for Closed admission.
  Current: "The node treats these peers as discovery hints only: it does not keep them connected ahead of other peers or exempt them from load penalties."
  Fact: Still right. A bootstrap peer gets two privileges and no others: it may connect when
  `admission` is Closed (section 1), and its DHT record writes skip the shared budget above.
  It gets no retention protection (it is pruned like any peer), no exemption from load
  penalties and no exemption from protocol scoring. The node registers the bootstrap peers and
  starts dialling them at process start, before the epoch loop; a nonempty configured map (the
  command-line map first, else `bootstrap_peers` in `network-config`) replaces the genesis set
  and is never merged with it. Committee membership and gossip permissions still come from
  chain state. (`--bootstrap-peers-file` is F3's.)
  Cite: crates/network-libp2p/src/peers/policy.rs:95-99 (Bootstrap grants admission and the
  shared-budget exemption only), :100-106 (Operator), :107-113 (Validator);
  crates/config/src/network.rs:53-59 (field doc), :366-377 (`resolve_bootstrap_peers`);
  crates/node/src/manager/node.rs:1083-1092 (registered and dialled at process start).

### Seen but out of scope (section 2)
- `tn_network` put-record rate-limit counters (`shed`, `flood`, `budget`), peer-store metrics:
  metrics series.
- The PutRecord per-source thresholds (2,048 and 16,384 per minute) and the AddProvider limit
  (5 per minute, `manager.rs` `MAX_ADD_PROVIDERS_PER_WINDOW`) are internal DoS bounds; include
  them only if the writer wants the full picture.

## Section 3: gossip, forwarding and request-response

### Facts

#### IHAVE id cap (#1736, in 2d4afcd7)
- Document: spec > Networking > Gossipsub topics. Kind: addition (optional, pairs with the
  frame-limit fact in section 1).
  Current: none
  Fact: Each heartbeat a node advertises the ids of messages it has recently seen to peers
  outside its mesh (gossipsub IHAVE). It now lists at most 198 ids in one IHAVE, so the frame
  stays under the 16 KiB control limit that peers enforce; above the cap each peer gets a
  different random subset. The library default was 5,000 ids, which could exceed the limit on
  a busy topic and make the receiver close the stream. The same cap bounds the ids the node asks
  one peer for (IWANT) in one heartbeat. Only frames the node sends change; peers on other
  versions need nothing. 198 = (16,384 - 8 - 64) / (2 + 80).
  Cite: crates/network-libp2p/src/gossip_config.rs:80 (80-byte id bound), :87 (64-byte topic
  bound), :93 (8-byte framing), :95-110 (rationale), :111-113 (`GOSSIP_MAX_IHAVE_IDS`), :172
  (`max_control_messages_sent`).

#### Non-blocking publish (#1679, in 942d08cd)
- Document: none. Kind: none (no behaviour change).
  Current: none
  Fact: #1679 states and tests an existing invariant: the swarm task never waits for a gossip
  publish or a slow peer; a publish to peers whose send queues are all full fails at once with
  `AllQueuesFull` and is not retried by the swarm. Nothing for partners. A writer may say, if
  wanted, "a stalled peer cannot delay the node's own gossip".
  Cite: crates/network-libp2p/src/consensus.rs:1193-1197, :1320-1328;
  crates/network-libp2p/src/types.rs:788-805.

#### Gossip from a later committee while replaying (security merge 5f912b1d)
- Document: spec > Networking > Gossipsub topics, or Peer scoring. Kind: addition.
  Current: "Messages that fail validation result in peer score penalties that may result in a node temporarily banning a peer."
  Fact: The sentence stays right, with one new exception. A node that is replaying an epoch the
  network has already closed holds that epoch's publisher allowlists, while the live committee
  of a later epoch publishes on the same topics (topic names carry only the chain id). Such a
  node now drops a message whose author is outside the replayed allowlists without penalising
  the author, because the author is most likely a live committee member. The node decides it is
  replaying from its own certified epoch records at each epoch entry: an epoch with a verified
  certified record is historical; any other epoch counts as live and the author penalty (Fatal)
  applies. An oversized gossip message is still charged to the relaying peer in every epoch.
  Suggested sentence: "A node replaying an epoch the network has already closed drops gossip
  from authors outside that epoch's allowlists without penalising them."
  Cite: crates/network-libp2p/src/consensus.rs:3443-3449 (rule), :3450-3466 (`penalty`,
  `FatalAuthor` only at `EpochPosition::Live`; `TooLarge` independent of position);
  crates/network-libp2p/src/types.rs:1182-1196 (`EpochPosition`, default `Live`);
  crates/node/src/manager/node/start_epoch.rs:414-428 (`epoch_position` from
  `certified_record_by_epoch`), :939, :1121 (primary and worker set it at epoch entry).

#### Committee exemption (Fatal included)
- Document: spec > Networking > Peer scoring. Kind: none (still right).
  Current: "Members of the previous, current and next committees are exempt from scoring: penalties and bans do not apply to them, and they may connect beyond the normal peer limits."
  Fact: The scoring half is unchanged: for a member of the previous, current or next committee
  the policy skips every protocol penalty, Fatal included, and logs
  `skipping protocol penalty for committee peer`. The exemption follows the node's own
  committee window, which is why the replay rule above was needed. (Section 1 adds the
  connection-ceiling precision to the second half.)
  Cite: crates/network-libp2p/src/peers/policy.rs:107-113 (`ProtocolScoring::CommitteeExempt`),
  :138-141 (`applies`); crates/network-libp2p/src/peers/peer.rs:324-336 (`apply_penalty`);
  crates/network-libp2p/src/peers/all_peers.rs:311-313 (policy per peer).

#### Transaction forwarding (#1690 is not a forwarding change)
- Document: spec > Networking > Transaction forwarding. Kind: none (still right).
  Current: "If that validator advertises no endpoint, cannot be reached or refuses the transaction for a reason local to its own node, the node tries the other committee validators in a rotating order, and a rejection of the transaction itself stands only once a second validator confirms it, or when no other validator can be reached to consult."
  Fact: The whole subsection is still right. The forwarding logic in `forward.rs` did not
  change in this range; its diff adds only committee-coverage metrics (#1694) and a test for
  #1553. #1690 ("preserve fallback across silent signed endpoints") is the P2P dial change in
  section 1 (each signed address gets its own handshake window), not JSON-RPC forwarding.
  Cite: crates/tn-reth/src/forward.rs:1-49 (module contract: owner first, rotating fallback,
  second-validator confirmation, retry after three newer outputs omit it, endpoint-local
  failures include "internal error"); `git diff 98849a221 HEAD -- crates/tn-reth/src/forward.rs`
  (metrics and tests only); `git show --stat 942d08cd` (no `forward.rs`).

#### Inactive validators refuse submissions (#1553, in 5ccb88e8)
- Document: guide > Troubleshooting > Sync and node mode (or Service and keys); OPERATOR and
  README troubleshooting; spec > Networking > Transaction forwarding (optional). Kind: addition.
  Current: none (the guide has only the `worker is inactive` row)
  Fact: While a node is in `CvvInactive` (a committee member catching up), both
  `eth_sendRawTransaction` and `eth_sendRawTransactionSync` refuse every transaction with
  JSON-RPC error `-32603` and the message `validator is inactive; retry another endpoint`; the
  mode is read on every request, so submissions work again as soon as the node rejoins
  (`CvvActive`), without a restart. A full node (Observer) and an active validator accept
  submissions. The checks run in this order: worker admission, worker membership
  (`-32000 worker is inactive`), node mode (`-32603 validator is inactive; ...`), then the fee
  cap. The node's `/health/workers` route reports `accepting_transactions: false` in the same
  modes. Another node's forwarder treats this refusal as local to that validator and tries the
  next one, so for the spec the forwarding sentence above already covers it.
  Suggested guide row: symptom `eth_sendRawTransaction` returns `-32603`
  `validator is inactive; retry another endpoint`; cause: the node is a committee member that is
  catching up (`CvvInactive`); fix: send the transaction to another RPC endpoint, or wait until
  the node votes again (`attempting to rejoin consensus`).
  Cite: crates/tn-reth/src/rpc_fee_cap.rs:9-13 (module doc), :57-62
  (`node_mode_accepts_submissions`: `CvvActive | Observer` true, `CvvInactive` false), :68-78
  (`ensure_can_submit`, `INTERNAL_ERROR_CODE`, message), :204-227 (order in both methods);
  `~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/jsonrpsee-types-0.26.0/src/error.rs:129`
  (`INTERNAL_ERROR_CODE = -32603`; workspace pins jsonrpsee 0.26.0 at Cargo.toml:183);
  crates/node/src/health.rs:9-11 (`/health/workers` follows the same modes);
  crates/tn-reth/src/forward.rs:2435-2474 (test
  `inactive_validators_do_not_stop_the_fallback_chain`, fn at :2436). Old: `git show 98849a221:crates/tn-reth/src/rpc_fee_cap.rs | grep -c ensure_can_submit`
  is 0.

#### `worker is inactive`
- Document: guide > Troubleshooting > Sync and node mode. Kind: none (still right).
  Current: "| `eth_sendRawTransaction` returns error `-32000` `worker is inactive` | The network's worker count per node went down while this node was running. The node keeps the dropped worker's RPC port open for reads but refuses transactions there. | Send transactions to the first worker's RPC, port 8545 on a default install (see [Ports](#ports)). |"
  Fact: Unchanged text and code; it moved from line 144 to line 177.
  Cite: crates/tn-reth/src/worker.rs:173-178 (`ensure_active`, `-32000`, `worker is inactive`);
  crates/tn-reth/src/rpc_fee_cap.rs:9-11.

#### Sync-stream admission tiers and penalties (security merges f69c25ee, 813bb668)
- Document: spec > Networking > Request-response RPC (the bulk-transfer paragraph). Kind:
  addition.
  Current: "Missing certificates, epoch consensus data, a single consensus output by its consensus number, and worker batches by digest travel over a separate sync-stream protocol, where one request opens a stream that the responder fills and then closes."
  Fact: A responder now admits sync streams in two tiers. Members of the current and the next
  committee are the committee tier; every other peer is the public tier. One peer holds at most
  2 sync streams at once. While the responder waits for the opening request it holds an
  opening-read slot (8 for anyone plus 4 reserved for the committee tier), for at most 1 second
  for a public peer and 5 seconds for a committee peer. Each request class (epoch pack, missing
  certificates, consensus output) then has its own serve pool of 5 slots for anyone plus 4
  reserved for the committee tier; worker batch serving has one such pool. A full pool answers
  "at capacity" at once. So peers outside the committee cannot crowd out a committee member
  that is catching up, nor one class another. A public-tier epoch-pack serve is also cut after
  200 seconds. Before, the responder had one pool of 5 per role, no reserve, and 5 seconds for
  every opening.
  Suggested sentence: "A responder serves sync streams from bounded pools, one per request
  class, with slots reserved for the current and next committee, so peers outside the committee
  cannot crowd out a committee member that is catching up."
  Cite: crates/network-libp2p/src/sync/admission.rs:1-24 (design), :35-43 (`PeerTier`);
  crates/consensus/primary/src/network/mod.rs:66 (5), :75 (4 reserved), :84 (8 opening reads),
  :90 (4 reserved), :134 (2 per peer), :181 (5 s), :190 (1 s public), :200 (200 s public pack
  serve), :1960-1963 (tier = current + next committee keys), :1976-1981 (pools);
  crates/consensus/worker/src/network/mod.rs:45 (5), :51 (4), :59 (8), :65 (4), :79 (2), :117
  (5 s), :127 (1 s), :715 (tier). Old: `git show 98849a221:crates/consensus/primary/src/network/mod.rs`
  line 58 (5), 102 (2), 146 (5 s); no reserve or public constants.
- Document: spec > Networking > Peer scoring (the penalty list). Kind: addition.
  Current: "Penalties reduce a peer's score for specific infractions:" followed by three bullets.
  Fact: New penalty source: a public-tier peer that holds a sync slot without progress is
  charged a Mild penalty (-1 score) for a silent, unreadable or unexpected opening, for a valid
  request that arrives in the second half of its 1-second opening window (admitted or refused),
  for a stalled serve (a write timeout, a missed throughput floor or deadline, a reset or closed
  stream), and for a public epoch-pack serve cut at 200 seconds. A prompt "at capacity" refusal
  is never charged, and committee-tier peers are never charged by admission. Ignoring decay,
  20 such charges disconnect a public peer and 50 ban it. Suggested bullet: "Holding a sync
  stream open without making progress (peers outside the committee only)".
  Cite: crates/consensus/primary/src/network/mod.rs:183-190 (late-opening rule), :559-571
  (charge list), :573-660 (`admit_and_serve_sync_stream`), :663-675 (`charge_public_peer`, fn at
  :670);
  crates/consensus/worker/src/network/mod.rs:417-433 (same on the worker);
  crates/network-libp2p/src/peers/score.rs:73 (Mild = -1.0);
  crates/config/src/network.rs:969-970 (-20, -50).
- Document: guide > Troubleshooting (optional). Kind: addition (optional).
  Current: none
  Fact: These WARN lines (target `primary::network`) name a remote peer that is slow or
  misbehaving on a sync stream and need no action on this node: `no sync request before
  timeout`, `unreadable sync request frame`, `unexpected opening sync frame`,
  `late sync request opening`, `sync serve stalled`.
  Cite: crates/consensus/primary/src/network/mod.rs:601, :613, :622, :633, :646, :655.

#### Outbound sync request write timeout (security merges 87180d74, 813bb668; #1740)
- Document: spec > Trustless synchronization (optional) or none. Kind: addition (optional).
  Current: none
  Fact: A syncing node now bounds the write of its own opening request on every sync path: 1
  second on the primary (matching the responder's public opening window) and 5 seconds on the
  worker; a peer that accepts the stream but never reads it costs one bounded probe, after which
  the node tries the next peer and drops that peer as its preferred sync server. A whole worker
  batch request call, across peers and retries, is bounded at 480 seconds.
  Cite: crates/consensus/primary/src/network/mod.rs:202-208 (`SYNC_REQUEST_WRITE_TIMEOUT =
  PUBLIC_SYNC_REQUEST_READ_TIMEOUT`); crates/consensus/worker/src/network/handle.rs:54-61 (5 s),
  :74-81 (480 s).

#### Request-response message size
- Document: spec > Networking > Request-response RPC. Kind: none (still right).
  Current: "A message whose declared length exceeds the limit is rejected from its length prefix, before the node allocates memory for it, and the peer that sent it is penalized."
  Fact: Unchanged; `codec.rs` has no diff in this range, and the RPC limit is still 1 MiB. The
  protocol ids are unchanged.
  Cite: crates/network-libp2p/src/codec.rs:46-64; crates/config/src/network.rs:668;
  crates/node-record/src/protocol.rs:36-37, :48-49, :57-58, :66-67.

#### New opt-in key `serve_budget` (#1697, in d2a0b525)
- Document: guide > Install > Optional node flags (the `network-config` paragraph). Kind:
  addition (with `admission` from section 1).
  Current: "Four of the keys it accepts are opt-in, `process_budget`, `source_admission`, `trusted_nodes` and `committee_peers`: they are unset by default (absent, `null` or `{}`), and no script sets them."
  Fact: `serve_budget` sets per-class limits on inbound requests the node serves at once
  (`vote`, `epoch_record`, `certificate_sync`, `batch`, `other`); every class defaults to 0,
  which means unbounded, so a node without it serves exactly what it served before. No script
  sets it. With `admission` that makes six opt-in keys.
  Cite: crates/config/src/network.rs:38-39 (field: "Omission leaves every class unbounded");
  crates/config/src/network_budget.rs:140-151 (fields), :153-177 ("Zero is unbounded");
  crates/network-libp2p/src/serve_permits.rs:14-16.

### Seen but out of scope (section 3)
- Forwarding coverage gauges (`tn_worker_submit_*`, #1694), serve-permit occupancy series
  (#1697), service-class labels: metrics.
- `crates/network-libp2p/src/peers/penalty.md:304` still says the worker sync-batch stream
  applies no penalty; the code now charges public-tier peers (`worker/src/network/mod.rs:417-433`).
  The maintainer doc is stale; cite the code.
- Epoch-pack serve throughput floor and per-MiB deadline (`docs/src/network/sync-streams.md`
  Admission section): existed before or are internal; not needed for partners.
- #1648 (epoch and consensus-output serves without catch-up sleeps): serving-path latency, not
  a wire rule; left to F1/F3 if anyone needs it.

## Section 4: the health listener bind (#1696) and the ports table

The answer in one line: on main at 7167e7800 a bare `--healthcheck <port>` (the form the
scripts write, `--healthcheck 43174`) binds `127.0.0.1:<port>`, not every interface, so the
Association's monitor at 104.155.184.201 can no longer reach it; an operator who is probed
from outside must write an address, `--healthcheck 0.0.0.0:43174` (every interface, logged as a
warning) or `--healthcheck <an address of this host>:43174`. No release tag contains this yet
(`git tag --contains d2a0b525` is empty; the newest tag, `v0.16.0-adiri`, still binds 0.0.0.0
and accepts only a port).

### Facts

#### The health listener binds loopback for a bare port (#1696, in d2a0b525)
- Document: guide > Before you start > Ports (row 43174); OPERATOR > the same ports table;
  README > Health Monitoring (Uptime Kuma, testnet only). Kind: correction.
  Current (README): "Restrict it to those source IPs rather than opening it to the whole internet (the endpoint binds on all interfaces, so a firewall rule is its only protection):"
  Current (guide and OPERATOR row): "| 43174 | TCP | 104.155.184.201/32, plus any monitoring hosts you add | Health-check endpoint, a testnet add-on. The node listens on it only when you enable the health monitor. |"
  Fact: `--healthcheck` (and the `HEALTHCHECK_TCP_PORT` environment variable, same parser) now
  takes a port or a socket address. A bare port binds IPv4 loopback, `127.0.0.1:<port>`; a
  socket address binds exactly that address (`10.0.0.5:43174`, `[::1]:43174`); listening on
  every interface needs the wildcard written out (`0.0.0.0:43174` or `[::]:43174`). Before, a
  port bound `0.0.0.0:<port>`. So on a node built from main the README's parenthesis is wrong
  for the scripts' `--healthcheck 43174`, and the guide/OPERATOR row's "Open to" column no
  longer describes what reaches the port: with the bare port nothing outside the host does,
  whatever ufw allows. The row's second sentence ("listens on it only when you enable the
  health monitor") is still right. The ufw source rule stays useful only once the bind is an
  interface or wildcard address.
  Cite: crates/node/src/health.rs:19-23 (binding contract), :79-102 (`HealthcheckBind`,
  `LEGACY_HOST = Ipv4Addr::LOCALHOST`), :105-115 (error text), :121-130 (`FromStr`: port first,
  then socket address), :225-230 (network binding doc), :251 (`TcpListener::bind`);
  crates/telcoin-network-cli/src/node.rs:138-149 (flag doc, `value_name = "PORT|ADDR"`,
  `env = "HEALTHCHECK_TCP_PORT"`, "keep the bind private"). Old:
  `git show 98849a221:crates/node/src/health.rs` lines 157 ("Binds to 0.0.0.0") and 181
  (`([0, 0, 0, 0], port)`); `git show 98849a221:crates/telcoin-network-cli/src/node.rs` line 125
  (`Option<u16>`). Tags: `git -C <worktree> tag --contains d2a0b525` prints nothing.
- Document: guide > Day-2 operations > Testnet add-ons; OPERATOR (same add-on paragraph);
  README > Health Monitoring. Kind: addition.
  Current (guide): "Turning on the health monitor, log shipping or metrics shipping adds flags to the node command (`--healthcheck`, `--log.file.format json`, `--metrics`) and restarts the node."
  Fact: What an operator monitored from outside must set, on a release that carries #1696: the
  health flag with an address, `--healthcheck 0.0.0.0:43174` to listen on every interface
  (keep the ufw rule that limits the port to the monitor's source address), or
  `--healthcheck <address>:43174` with an address the host owns (on a cloud VM whose public IP
  is mapped to a private interface address, that private address). The address must exist on
  the host: a bind failure (port in use, address not on this host) now stops the node at
  start-up with the OS error, where it was silently skipped before. A wildcard bind logs a
  WARN at start (target `tn::listener`):
  `listener bound on every interface; every host that can reach this machine can read it. Bind a loopback or private interface address unless the wide bind is intended`,
  and every bind logs INFO `operator listener bound` with `listener`, `listen_on` and
  `exposure` (`loopback`, `interface` or `all-interfaces`). The address form is not accepted by
  `v0.16.0-adiri` (its flag is a `u16`), so the form must match the release. The probes the
  scripts and the UI run themselves (`curl http://127.0.0.1:43174` in setup-observability's
  status and the UI helper) still reach a loopback bind, also on Docker installs, which run
  with `--network=host`.
  Cite: crates/node/src/manager/node.rs:911-929 (`HealthcheckServer::spawn(...).await?` at :922-928,
  "Propagate health bind errors" at :921); old `git show 98849a221:crates/node/src/manager/node.rs` line 911
  (`let _ = HealthcheckServer::spawn(`); crates/tn-metrics/src/exposure.rs:13-24 (classes),
  :28-35 (`of`), :57-69 (`report_listener_bound`, INFO and WARN text);
  crates/node/src/health.rs:253 (health calls it); this repo: origin/main
  `lib/common.sh:8253-8254` and `setup-observability.sh:67,70` (bare port written),
  `setup-observability.sh:371` and `ui/telcoin-ui-helper.sh:1432` (loopback probes),
  `lib/common.sh:3283` (`--network=host`); docs/src/getting-started/observability-listeners.md:28-38
  (upstream migration table: "Probe from another host ... refused; write `--healthcheck
  0.0.0.0:8080` or the node's private address"; secondary source).
- Document: README > Changelog-adjacent note "The health port (`--healthcheck`, 43174 with the testnet health monitor) also answers `GET /health/network`: 200 once the primary and every worker have peers, 503 before that." Kind: none (still right).
  Fact: Routes are unchanged: any path is liveness (`200 OK`, body `OK`), `/health/network`
  is `503` until every configured swarm has an established peer and `200` after, and
  `/health/workers` reports per-worker transaction acceptance (now also false while the node is
  `CvvInactive`, section 3).
  Cite: crates/node/src/health.rs:3-11, :48, :51, :73.

#### Ports table rows other than 43174
- Document: guide > Before you start > Ports; OPERATOR ports table; README firewall and router
  text. Kind: none (still right).
  Current: "| 9101 | TCP | Loopback only | Prometheus metrics. |" and the 8545, 8546, 49590 and 49594 rows.
  Fact: `--metrics` binds exactly the socket address given (unchanged; the scripts write
  `127.0.0.1:<METRICS_PORT>`, so loopback); the node now logs the same `operator listener bound`
  line for it and warns on a wildcard. The P2P listeners still come from the listener multiaddrs
  (node-info.yaml, the `*_LISTENER_MULTIADDR` overrides or `endpoints` in `network-config`);
  nothing in this range changed them. The worker RPC port offsets are unchanged (worker N's
  HTTP port is the base minus 200 x N, its WS port the base plus 400 x N), so "the first
  worker's RPC, port 8545" stays right.
  Cite: crates/tn-metrics/src/server.rs:84-100 (bind and report); origin/main
  `lib/observability.sh:137-141` (`127.0.0.1:<port>`), :153-157; crates/tn-reth/src/env/rpc.rs:144-149;
  crates/config/src/network.rs:74, :104-109 (`endpoints`, optional `listen`);
  `git diff 98849a221 HEAD -- docs/src/network/transport.md` (only the healthcheck sentence
  changed).

### Seen but out of scope (section 4)
- Scripts, not documents (for the orchestrator, not the writers): `setup-observability.sh:130`
  and `:315-318` on origin/main warn that "--healthcheck binds on every interface" and that with
  ufw inactive "health port 43174 is reachable from the INTERNET"; `docs/testnet-addons.md:68`
  and `:230-233` say the health server listens on every interface. All are true for
  `v0.16.0-adiri` and false for a release that carries #1696, where the scripts' bare
  `--healthcheck 43174` would also leave the Association monitor, the VPN overlay and the
  Google health-check ranges (`lib/wgvpn/wg-node-bootstrap.sh:201-230`) unable to reach the port.
  A scripts change has to pick the bind form by release.
- `etc/compose.yaml` and `etc/compose.observability.yaml` listener binds, the metric label
  policy in `observability-listeners.md:104-120`: maintainer and metrics material.
- The `/health/workers` gateway contract (#712, the worker gateway is not on main).

## Section 5: what did not change

### What did not change
- spec > Networking (intro): "All peer-to-peer communication uses QUIC v1 over UDP; transaction forwarding instead uses the JSON-RPC endpoints that validators advertise." — unchanged; the swarm is built with the QUIC transport only, crates/network-libp2p/src/consensus.rs:863-871 (`with_quic_config`), and forwarding is still JSON-RPC, crates/tn-reth/src/forward.rs:1-12.
- spec > Transport: "/ip4/{HOST}/udp/{PORT}/quic-v1" multiaddrs — unchanged; no diff under crates/node-record (`git diff --stat 98849a221 HEAD -- crates/node-record` is empty); crates/node-record/src/addresses.rs:11 (at most four advertised addresses).
- spec > Transport: "Connections maintain periodic keep-alive probes to prevent NAT and firewall timeouts." — unchanged; crates/config/src/network/quic.rs:69 (5 s keep-alive).
- spec > Transport: "... a connection whose peer stops answering is closed by the QUIC idle timeout within about half a minute." — unchanged; crates/config/src/network/quic.rs:68 (30 s). (The first half of that sentence changes; section 1.)
- spec > Identity and discovery: the paragraphs on the BLS key, the derived Ed25519 network key per swarm, the node record contents and its chain-and-role signing domain — unchanged; no change under crates/node-record, and the `crates/config/src/keys.rs` diff in the range touches only the passphrase source (#1715), not key derivation (`git diff 98849a221 HEAD -- crates/config/src/keys.rs | grep -i 'derive\|seed'` is empty).
- spec > Identity and discovery: "The DHT uses standard Kademlia routing with a K-bucket size of 20. Bucket inserts are performed manually with record filtering to prevent pollution. Nodes target more connected peers than the K-bucket size to maintain routing table coverage." — unchanged; crates/config/src/network.rs:672 (K_VALUE 20), :869 (target 30 = 20/2 + 20); crates/network-libp2p/src/consensus.rs:745 (manual), :752 (`FilterBoth`).
- spec > Gossipsub topics: protocol ids `/tn-meshsub-{chain_id}/1.1.0` and `/1.0.0`, the four topic names, and their publisher sets — unchanged; crates/network-libp2p/src/gossip_config.rs:161-163; crates/config/src/network.rs:642-661 (topic constructors). The allowlists are still set at each epoch entry (crates/node/src/manager/node/start_epoch.rs, primary and worker spawn paths, which now also set the epoch position, section 3).
- spec > Gossipsub topics: "Messages that fail validation result in peer score penalties that may result in a node temporarily banning a peer." — still right, with the replay exception in section 3; crates/network-libp2p/src/consensus.rs:3450-3466.
- spec > Transaction forwarding: the whole subsection ("Transactions are not gossiped." through "A transaction that does not reach the committee stays in the node's pool and is sent again.") — unchanged; crates/tn-reth/src/forward.rs:1-49; the range adds only metrics and tests there.
- spec > Request-response RPC: the protocol ids `/tn-primary-{chain_id}/0.0.2` and `/tn-worker-{worker_id}-{chain_id}/0.0.2`, the three message kinds, and the sync-stream sentence — unchanged; crates/node-record/src/protocol.rs:36-37 (req-res), :57-58 (sync).
- spec > Request-response RPC: "A message whose declared length exceeds the limit is rejected from its length prefix, before the node allocates memory for it, and the peer that sent it is penalized." — unchanged; crates/network-libp2p/src/codec.rs:46-64 (no diff in the range); crates/config/src/network.rs:668 (1 MiB).
- spec > Peer scoring: score range [-100, 100], new peer at 0, decay with a configurable half-life — unchanged; crates/config/src/network.rs:957-959, :963 (300 s).
- spec > Peer scoring: the three levels (`Trusted` above -20, `Disconnected` at -20 or below with ten minutes before reconnection, `Banned` at -50 or below), the 30-minute frozen score after a ban — unchanged; crates/config/src/network.rs:879 (600 s), :968 (30 min), :969-970 (-20, -50). #1651 makes the ten-minute recovery hold in the peer store too (section 2).
- spec > Peer scoring: "When a node holds more peers than its target, it drops the lowest-scoring peers first." — unchanged; crates/network-libp2p/src/peers/all_peers.rs:1016-1020 (`connected_peers_by_score_and_routability`, lowest score first), crates/network-libp2p/src/peers/manager.rs:1272-1275.
- spec > Peer scoring: "Members of the previous, current and next committees are exempt from scoring: penalties and bans do not apply to them" — unchanged, Fatal included; crates/network-libp2p/src/peers/policy.rs:107-113, :138-141. (The "beyond the normal peer limits" half needs the precision in section 1.)
- spec > Peer scoring: "When a validator joins a tracked committee, any ban on it is lifted and its score is reset to the maximum." — unchanged; crates/network-libp2p/src/peers/all_peers.rs:1312-1326 (`unbanning banned committee member`, `reset_score_to_max`).
- spec > Trustless synchronization: no sentence there names a request-response limit, a permit, a timeout or a penalty, so nothing on the wire side needs correcting; the new sync admission rules are additions (section 3).
- guide > Before you start > Ports: the 49590 and 49594 UDP rows, "49590 and 49594 are conventions, not something the node enforces: it uses the ports in its own multiaddrs.", and the 8545, 8546 and 9101 loopback rows — unchanged; listener addresses still come from node-info.yaml or the listener overrides (`git diff 98849a221 HEAD -- docs/src/network/transport.md` changes only the healthcheck sentence); `--metrics` binds the address given, crates/tn-metrics/src/server.rs:98-100, and the scripts give `127.0.0.1:<port>` (origin/main `lib/observability.sh:137-141`).
- guide/OPERATOR > Ports, row 43174: "The node listens on it only when you enable the health monitor." — still right; crates/telcoin-network-cli/src/node.rs:143-144 ("Unset starts no listener"). The rest of that row changes (section 4).
- guide > Install > Optional node flags: "The node treats these peers as discovery hints only: it does not keep them connected ahead of other peers or exempt them from load penalties." — still right; crates/network-libp2p/src/peers/policy.rs:95-99 (Bootstrap basis: admission and shared record budget only).
- guide > Install > Optional node flags: "The `source_admission` key can refuse committee peers once its limits fill, and a node that has it set logs a warning at start that begins `source admission is enabled`." — unchanged text; crates/node/src/manager/node.rs:1553-1558 (was line 1546).
- guide > Install > Optional node flags: the four opt-in keys `process_budget`, `source_admission`, `trusted_nodes` and `committee_peers` are still opt-in and unset by default — crates/config/src/network.rs:37, :46, :64, :72; two more exist now (`admission`, `serve_budget`; sections 1 and 3).
- guide > Troubleshooting > Sync and node mode: the `-32000` `worker is inactive` row — unchanged; crates/tn-reth/src/worker.rs:173-178.
- README: "The health port (`--healthcheck`, 43174 with the testnet health monitor) also answers `GET /health/network`: 200 once the primary and every worker have peers, 503 before that." — unchanged; crates/node/src/health.rs:3-6, :51.
- README > Router port forward: "The RPC port (8545) should **not** be opened to the internet ... reth stays on `127.0.0.1`" — not touched by this range (no RPC bind change in crates/tn-reth/src/env/rpc.rs other than worker admission); crates/tn-reth/src/env/rpc.rs:144-149 (worker port offsets unchanged).
- The connection-limit WARN `inbound connections keep being refused by connection limits` (not quoted by any document) — unchanged text and 60-second rate; crates/network-libp2p/src/consensus.rs:251, :1295.

### Seen but out of scope (section 5)
- Nothing on main is described here that is not on main at 7167e7800: the worker-gateway stack
  (`--forward-txs`, #1617) and staging 10-27 were not read.
- `docs/src/network/transport.md` (QUIC defaults table) and
  `crates/network-libp2p/src/peers/penalty.md:304` (worker sync stream "applies no penalty") are
  stale against the code; cited nowhere above.

---

## F3: consensus, epoch, execution, CLI, release docs (7167e7800)

All paths are worktree-relative at 7167e7800 unless marked otherwise. "Base" means 98849a221.
Dependency constants cite the crate version pinned in the worktree's `Cargo.lock`
(`alloy-eips` 1.8.3 at `Cargo.lock:308-309`, `jsonrpsee-types` 0.26.0 at `Cargo.lock:5226-5227`),
read from `~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/`.

### What did not change

- spec > Epoch boundaries > Fork gates: the five armed adiri gates and their epochs (383, 407, 567, 570, 574), and the unarmed millisecond-timestamp gate — unchanged; `crates/types/src/forks.rs:180`, `:218`, `:373`, `:504`, `:651`, `:808` (`SUBSECOND_TIMESTAMP_FORK_EPOCH = u32::MAX`), plus `:71` (`ADIRI_DUP_BATCH_EPOCH = 160`) and `:1170` (`GOVERNANCE_SAFE_FORK_EPOCH = 554`); #1557 only routes the `>=` comparisons through `fork_active_at` (`:220-247`).
- spec > Epoch boundaries > Fork scheduling ("one-time contract upgrades instead run once, inside the closing block of the epoch before") — unchanged; the one-shot `checked_add(1) == Some(FORK)` triggers keep their own operator (`crates/types/src/forks.rs:234-237`, doc comment), and `crates/tn-reth/src/evm` is unchanged base..HEAD.
- spec > Execution layer (EVM block production, repurposed header fields, system calls and their 100,000,000 gas limit, the four epoch-boundary calls in order, the gas over-reservation penalty, the two precompiles) — unchanged; `git -C <wt> diff --stat 98849a221 HEAD -- crates/tn-reth/src/evm crates/tn-reth/src/system_calls.rs crates/tn-reth/src/env/epoch.rs` is empty; `crates/tn-reth/src/evm/mod.rs:90` (`SYSTEM_CALL_GAS_LIMIT = 100_000_000`).
- spec > Repurposed block header metadata, `gas_limit` 30,000,000 per batch, and the 1,000,000-byte batch size — unchanged; `crates/types/src/worker/sealed_batch.rs:209-213`, `:215-226`; batch digests unchanged (test `transactions_encode_identically_as_byte_strings`).
- spec > Base fee adjustment, "subject to a minimum floor of 7 wei" — unchanged; `alloy-eips-1.8.3/src/eip1559/constants.rs:21`; #1556 only keeps a removed worker's fee handle live (`crates/types/src/gas_accumulator.rs:447-473`).
- spec > Consensus layer > Total ordering and Reputation scheduling — unchanged; `crates/consensus/primary/src/consensus/bullshark.rs` and `leader_schedule.rs` are untouched base..HEAD (`git -C <wt> diff --stat 98849a221 HEAD -- crates/consensus/primary/src/consensus/` lists only `liveness.rs`, `mod.rs`, `state.rs` and tests).
- spec > Certificate DAG and Trustless synchronization, the quorum of two-thirds rounded down plus one — unchanged; `crates/types/src/committee.rs:1191-1192`, file unchanged base..HEAD.
- spec > Validator lifecycle (ConsensusNFT, statuses, the seven steps, delegation) and guide > Validators (stake, activate, exit, status values) — unchanged; the `tn-contracts` submodule is `10cc12b7db43e2fbab67dc6a87fa5e159716bdc0` at both base and HEAD (`git -C <wt> ls-tree <rev> tn-contracts`).
- spec > Node modes: three modes `CvvActive`, `CvvInactive`, `Observer` — unchanged; `crates/types/src/primary/` is untouched base..HEAD. (Two sentences about entry and intake change; see the Facts.)
- spec > Epoch boundaries, "On the Adiri testnet, epochs last about six hours", and guide "Testnet epochs are six hours long" / "On testnet's six-hour epochs that is 12 to 18 hours after `activate()`" — unchanged; `chain-configs/testnet/genesis.yaml:103` (`0x5460` = 21,600 s), `chain-configs/testnet` unchanged base..HEAD.
- guide (branch) and OPERATOR (branch), the clock-drift sentences (hold up to 1 s on testnet, reject beyond the tolerance plus the 5 s vote timeout: 5.25 s at the default, 6 s with the legacy integer) — unchanged; `crates/consensus/primary/src/network/handler.rs:766-829`, `crates/config/src/network.rs:781`, `:1035-1070`, `crates/config/src/node.rs:333-335`, `crates/consensus/primary/src/error/network.rs:215-221`.
- guide (branch), `CvvInactive` row: "within 20 rounds of the network's newest commit ... `attempting to rejoin consensus`" — unchanged; `crates/types/src/primary/mod.rs:52`, `:64`, `:72-74`, `:84-86`; `crates/consensus/executor/src/subscriber.rs:38`, `:317`.
- guide (branch) troubleshooting row "`eth_sendRawTransaction` returns error `-32000` `worker is inactive`" and its cause — unchanged; `crates/tn-reth/src/worker.rs:173-178` (a second, rarer message exists; see the Facts).
- guide and OPERATOR, the hardware table (follower 2/8 and 4/16, public RPC 4/16 and 8/32, validator 8/32 ECC and 16/64 ECC, 2 TB TLC NVMe at 10,000 write IOPS and 300 MB/s, 4 TB recommended, 200 Mbps / 1 Gbps, round-trip to 7 of 10) — unchanged; `docs/src/getting-started/hardware-requirements.md:26-36`, `:396`, same rows at base.
- guide (main) "At each start, systemd decrypts the credential for the service, and the start script hands it to the node on standard input (`--bls-passphrase-source stdin`)", and the OPERATOR/README `PASSPHRASE_METHOD=credential` / `LoadCredentialEncrypted=` statements — unchanged; the scripts still use `stdin` (this repo `lib/common.sh:3280`, `:3283-3286`, `:3347-3348`), and the node's `stdin` source still trims trailing whitespace (`crates/telcoin-network-cli/src/passphrase.rs:261-270`; base `:83-89`).
- CLI: no flag was removed; keytool's flags are unchanged (only zeroized buffers); `--bls-passphrase-source no-passphrase` for the keytool calldata examples still works — `crates/telcoin-network-cli/src/cli.rs:20-33` (the five values, `NoPassphrase` kept), `git -C <wt> diff 98849a221 HEAD -- crates/telcoin-network-cli/src/keytool/` (type changes only).
- README restart window: `TN_EPOCH_MARGIN` 300 s, `TN_EPOCH_SETTLE` 90 s, `TN_EPOCH_WAIT_MAX` 1,800 s stay valid — script constants; the testnet epoch length and the boundary rule are unchanged (`chain-configs/testnet/genesis.yaml:103`, `crates/tn-reth/src/evm` unchanged).
- guide (main) "How the scripts and releases are checked" and OPERATOR (main) 4.10's description of `SHA256SUMS` (five names), `SHA256SUMS.asc`, `IMAGE_DIGEST` on ghcr.io and the shipped key `grantkee.asc` (`4E36D35A4AB61B589861D01AC7173F2377CA7573`, expires 2028-10-16) — unchanged and confirmed; `docs/src/getting-started/installing-a-release.md:4-11`, `:35`, `etc/release.sh:1113-1120`, `SECURITY.md:80-82`, upstream `.github/maintainer-gpg-keys/grantkee.asc` byte-identical to this repo's main `lib/release-keys/grantkee.asc`. (The `gpgv` hand check needs a fix; see the Facts.)
- The `TESTNET_GENESIS_SHA256`, `TESTNET_COMMITTEE_SHA256`, `TESTNET_PARAMETERS_SHA256` pins at `TESTNET_CHAIN_CONFIGS_TAG=v0.16.0-adiri` — unchanged and still equal to `chain-configs/testnet/*` at 7167e7800 (`sha256sum` of the three files); this repo `lib/common.sh:6063-6066`.
- Mainnet "not launched" / "coming soon" statements in the guide — unchanged; `chain-configs/mainnet` still holds placeholders (`chain-configs/README.md`, "## mainnet").
- spec > Introduction (Prague rules from genesis; legacy, EIP-2930 and EIP-1559 transactions; no blob or EIP-7702) — no change found in range: no hardfork or transaction-type change in `crates/tn-reth`, `crates/consensus/worker` or `crates/types` (`git -C <wt> diff 98849a221 HEAD -- crates/tn-reth crates/consensus/worker crates/types | grep -i -E '7702|eip4844|tx_type|hardfork'` finds only a pool comment). The edition sentence is the orchestrator's.

### Facts

#### Section 1. Epoch boundary and workers (#1544, #1545, #1546, #1556, #1557, #1552)

- Document: spec > Epoch boundaries > Fork gates (the table) and Fork scheduling. Kind: none (unchanged; listed under "What did not change").
  Current: "| Seed signatures: ... | 383 |" ... "| Seed-chain `PREVRANDAO`: ... | 574 |" and "The gate for millisecond-precision consensus timestamps has no activation epoch on Adiri, where commit times stay in whole seconds."
  Fact: #1557 is a refactor only. Every `>=` gate, test override and arming assert now calls one `const fn fork_active_at(epoch, fork)` (`epoch >= fork`), and the two `#[expect(clippy::absurd_extreme_comparisons)]` on the sub-second gate are gone. No fork epoch changed and no gate was added or removed: `ADIRI_DUP_BATCH_EPOCH = 160`, `CONSENSUS_REGISTRY_FORK_EPOCH = 407`, `SEED_SIGNATURE_FORK_EPOCH = 383`, `PREVRANDAO_FORK_EPOCH = 574`, `MULTI_WORKERS_FORK_EPOCH = 570`, `LEADER_SEEDED_ORDERING_FORK_EPOCH = 567`, `GOVERNANCE_SAFE_FORK_EPOCH = 554`, and `SUBSECOND_TIMESTAMP_FORK_EPOCH = u32::MAX` (still unarmed). The one-shot boundary triggers (registry upgrade, governance Safe) keep their `==` form, so "one-time contract upgrades instead run once, inside the closing block of the epoch before" stays right. The diff base..HEAD of `forks.rs` changes no `= <number>;` line.
  Cite: `crates/types/src/forks.rs:71`, `:180`, `:218`, `:373`, `:504`, `:651`, `:808`, `:1170`; `crates/types/src/forks.rs:220-247` (the rule and its doc comment, which lists the `concluding.checked_add(1) == Some(FORK)` one-shot triggers that keep their own operator); `git -C <wt> diff 98849a221 HEAD -- crates/types/src/forks.rs`.

- Document: spec > Consensus layer > Worker horizontal scaling. Kind: addition.
  Current: "Each worker has its own transaction pool and its own RPC endpoint, so a transaction joins the lane of the endpoint it was submitted to." and "Scaling the number of workers is configurable through on-chain governance at each epoch boundary."
  Fact: When governance lowers the number of workers, a node closes transaction admission on each removed worker as the epoch closes (the worker-count resize in the closing step), and again on entry to the next epoch, before recovery, replay or peer discovery can wait. Each removed worker then hands the transactions it holds, pending and fee-parked alike, to the first worker (worker 0) under that worker's normal validation and capacity limits, and keeps relaying any submission that was already past its admission check when it closed. A transaction the first worker refuses is discarded. The removed worker keeps its RPC endpoint open for reads, and if a later epoch raises the count again it reopens with an empty pool. Suggested sentence: "When governance lowers the worker count, each removed lane stops admitting transactions at the epoch boundary and hands the transactions it holds to the first lane."
  Cite: `crates/node/src/manager/node/run_epoch.rs:488-490` (deactivate right after `close_epoch`; comment: "Admission is already closed by the accumulator resize inside close_epoch"), `crates/node/src/manager/node/run_epoch.rs:218-220` (deactivate at epoch entry, "before recovery, replay, and peer discovery can await"), `crates/node/src/manager/node/run_epoch.rs:952` (`set_num_workers` in the base-fee apply), `crates/node/src/engine/mod.rs:317-334` (`deactivate_workers_above`: destination is worker 0), `crates/tn-reth/src/worker.rs:60-102` (`deactivate` spawns the relay, `reactivate` stops it), `crates/tn-reth/src/txn_pool.rs:818-838` (`admitted_transactions`, `migrate_transactions_to`: "Validation or capacity refusals are discarded"), `crates/types/src/gas_accumulator.rs:505-511` (`WorkerBaseFee::is_active` resolves membership on every call).

- Document: guide > Troubleshooting > Sync and node mode (the `worker is inactive` row, branch side). Kind: addition (the row stays right).
  Current: "| `eth_sendRawTransaction` returns error `-32000` `worker is inactive` | The network's worker count per node went down while this node was running. The node keeps the dropped worker's RPC port open for reads but refuses transactions there. | Send transactions to the first worker's RPC, port 8545 on a default install (see [Ports](#ports)). |"
  Fact: Still right: the admission gate answers `-32000` `worker is inactive` (`worker.rs:174-178`). A second refusal now exists for the same cause, checked after it: `-32000` `worker is no longer active in this epoch; submit to an active worker`, returned when the worker's slot has gone from the epoch's worker count but its admission gate has not closed yet (the short window between the resize at close and the deactivation that follows it). A writer may add that message to the row's first column ("returns `-32000` `worker is inactive` or `worker is no longer active in this epoch; submit to an active worker`") or leave the row as it is; both are true. The row could also say the node passes the transactions it already held on that worker to the first worker (previous fact). F2 owns the network side of this row; this is the execution side only.
  Cite: `crates/tn-reth/src/worker.rs:173-178`, `crates/tn-reth/src/rpc_fee_cap.rs:179-188` (`ensure_active_worker`, added in 2635e26a: `git -C <wt> blame -L 179,188 crates/tn-reth/src/rpc_fee_cap.rs`), `crates/tn-reth/src/rpc_fee_cap.rs:204-212` (order of the checks: `admission.ensure_active`, then `ensure_active_worker`, then `ensure_can_submit`).

- Document: spec > Node modes > Capabilities (table and the sentence under it). Kind: correction (#1553, staging 10-15; overlaps F2, which covers the forwarding side).
  Current: "| Transaction intake | Seals into batches | Holds in its pool until active | Forwards to committee validators |" and "Transaction intake follows the committee seat rather than the mode: a node outside the current committee forwards transactions, and a committee member that is not `CvvActive` holds them in its pool."
  Fact: A `CvvInactive` node now refuses every new `eth_sendRawTransaction` and `eth_sendRawTransactionSync` with JSON-RPC error `-32603` and the message `validator is inactive; retry another endpoint`, before the transaction reaches its pool. `CvvActive` and `Observer` nodes accept submissions (an observer's workers forward them). The node reads its live mode on every call, the same value `tn_nodeMode` returns, and `/health/workers` reports every worker as not accepting transactions while the node is `CvvInactive`. The table cell for `CvvInactive` becomes "Refuses new submissions"; the sentence under the table becomes, for example: "Transaction intake follows the mode: a `CvvActive` node seals transactions into batches, an observer forwards them to committee validators (one that still holds a seat in the current committee keeps them in its pool), and a `CvvInactive` node refuses new submissions until it has caught up." Whether a `CvvInactive` node keeps what it had already admitted is not changed by this code (no pool clear on demotion was found); do not claim either way beyond "refuses new submissions".
  Cite: `crates/tn-reth/src/rpc_fee_cap.rs:50-62` (`node_mode_accepts_submissions`: `CvvActive | Observer => true`, `CvvInactive => false`), `crates/tn-reth/src/rpc_fee_cap.rs:64-77` (`ensure_can_submit`: `INTERNAL_ERROR_CODE`, message), `jsonrpsee-types-0.26.0/src/error.rs:129` (`INTERNAL_ERROR_CODE: i32 = -32603`), `crates/tn-reth/src/rpc_fee_cap.rs:204-224` (both submit methods call it), `crates/node/src/engine/inner.rs:145-146` and `:182` (admission reads `tn_ext.node_mode_reader()`, "the same live node mode as `tn_nodeMode`"), `crates/node/src/engine/readiness.rs:28-53` (`snapshot`: `node_accepts && rpc_running && ...`), `crates/node/src/manager/node.rs:911-919` (each `/health/workers` probe reads the current mode).

- Document: guide > Troubleshooting > Sync and node mode (the `CvvInactive` row) and guide > Introduction > Roles are decided on-chain (the `CvvInactive` table row). Kind: addition (#1553, the validator-status side).
  Current: "| `tn_nodeMode` stays at `CvvInactive` | A committee member that has not caught up. It votes again once it is within 20 rounds of the network's newest commit in the same open epoch, while the network is still committing; the log then shows `attempting to rejoin consensus`. | Treat it like a lagging node (next row). |" (branch) and "| `CvvInactive` | A committee member that is catching up before it can vote, for example after a long restart. This should be brief. |"
  Fact: The guide does not state today when a node accepts transactions, except in the `worker is inactive` row. A new troubleshooting row is warranted: symptom "`eth_sendRawTransaction` returns error `-32603` `validator is inactive; retry another endpoint`"; cause "The node is a committee member that is catching up (`tn_nodeMode` reports `CvvInactive`). It refuses new transactions until it votes again, and `/health/workers` reports it as not accepting them."; fix "Send transactions to another node until `tn_nodeMode` reports `CvvActive`; if it stays `CvvInactive`, see the `CvvInactive` row." The `CvvInactive` vocabulary row may add "It refuses new transactions meanwhile." The same addition applies to OPERATOR.md's `CvvInactive` vocabulary row ("A committee member that is catching up before it can vote. This should be brief.") and its troubleshooting row ("| `tn_nodeMode` stays at `CvvInactive` | A committee member that has not caught up. | Treat it like a lagging node (next row). |").
  Cite: as the previous fact; `crates/tn-reth/src/rpc_fee_cap.rs:72-76` for the exact message text.

- Document: spec > Node modes > CvvActive and > Mode detection. Kind: correction (staging 10-13, 2635e26a, the commit "catch up retained validators behind the epoch-record tip").
  Current: "A committee member enters this mode at the start of each epoch without first checking that it is caught up, and drops to `CvvInactive` if it finds itself behind." and (Mode detection) "If the node's key is in the new committee, it enters `CvvActive`, unless the newest epoch record it holds names a next committee without that key, in which case it runs as an observer."
  Fact: At each epoch entry, and at startup, a committee member whose key the newest epoch record it holds does not exclude now starts as `CvvInactive`, not `CvvActive`, when that record closes an epoch later than the epoch it is entering: the record proves it is behind, so it catches up before it votes. Otherwise it still starts `CvvActive` optimistically and is demoted later if it turns out to be behind. An existing `CvvInactive` mode is still sticky, and an observer is never promoted by a record. Suggested wording for CvvActive: "A committee member enters this mode at the start of each epoch without first checking that it is caught up, unless the newest epoch record it holds is from a later epoch, in which case it starts as `CvvInactive`; it drops to `CvvInactive` if it finds itself behind." Mode detection gets the same clause after "it enters `CvvActive`".
  Cite: `crates/node/src/manager/node.rs:1953-1982` (`node_mode_from_epoch_record`: `!eligible => Observer`, `record.epoch > local_epoch => CvvInactive`, else `CvvActive`), `crates/node/src/manager/node/start_epoch.rs:1178-1234` (`identify_node_mode` applies it at every epoch entry with `consensus_config.committee().epoch()` as the local epoch), `crates/node/src/manager/node.rs:1987-1996` (`seed_node_mode_on_startup` applies it at startup), `git -C <wt> log -L '/fn node_mode_from_epoch_record/,+25:crates/node/src/manager/node.rs' 98849a221..HEAD` (only 2635e26a).

- Document: spec > Epoch boundaries > Base fee adjustment. Kind: none (unchanged; #1556 and #1545 are internal).
  Current: "Every node entering the epoch, including one that restarts or syncs, reads its fees from the contract, and each batch must carry exactly that fee."
  Fact: #1556 fixes a node-local bug, not a protocol rule: a worker removed and later re-added kept a stale fee handle in its pool. The accumulator now keeps a removed worker's fee container and reuses it on regrow, resetting it to the 7-wei minimum until the epoch entry writes the contract's fee, so the regrown pool charges the epoch's fee again. #1545 replaces a boolean with an explicit worker state (`Uninitialized`, `Stopped`, `Running`) and turns a panic on an out-of-order worker id into an error. Neither changes what the spec says; the 7 wei floor stays right.
  Cite: `crates/types/src/gas_accumulator.rs:447-473` (`set_num_workers`: retained containers, `set_base_fee(MIN_PROTOCOL_BASE_FEE)` at 469), `alloy-eips-1.8.3/src/eip1559/constants.rs:21` (`MIN_PROTOCOL_BASE_FEE: u64 = 7`), `crates/node/src/engine/inner.rs:157-161` (`ensure!` replaces the panic), `crates/node/src/engine/mod.rs:361-368` (`is_worker_running`), `crates/node/src/manager/node/run_epoch.rs:194-216` (entry reads the fees written by the closing block).

- Document: spec > Consensus layer > Worker horizontal scaling (batch metadata) and spec > Execution layer > Repurposed block header metadata (`gas_limit`). Kind: none (unchanged).
  Current: "| `gas_limit` | 30,000,000 | Maximum gas per batch; changes only at a protocol fork |"
  Fact: The batch wire encoding was rewritten for speed in #1558 (transactions serialized as byte strings), and a test pins that it encodes identically, so batch digests are unchanged. The 30,000,000 gas and 1,000,000 byte batch limits are unchanged.
  Cite: `crates/types/src/worker/sealed_batch.rs:209-213` (`max_batch_gas` = 30,000,000), `:215-226` (`max_batch_size` = 1,000,000), the test `transactions_encode_identically_as_byte_strings` in the same file.

#### Section 2. Consensus liveness, the certifier and the clock-drift rule (#1693, #1552, #1558)

- Document: guide, OPERATOR (no current sentence). Kind: none for the partner documents; follow-up for this repo.
  Current: none. Neither the guide nor OPERATOR.md describes a committee short of quorum.
  Fact: #1693 adds Prometheus series only (`tn_primary_rounds_evaluated_total`, `tn_primary_round_quorum_shortfalls_total`, `tn_primary_quorum_observation_active`, `tn_primary_liveness_started_timestamp_seconds`, `tn_primary_last_commit_timestamp_seconds`). It adds no log line: an operator sees nothing new in the journal when the committee is short of quorum. A round is judged 30 seconds after its first accepted certificate, or earlier when a certificate of a higher round arrives, and counts as a shortfall when the distinct committee authors that reached the local DAG sum below the quorum threshold (`floor(2n/3) + 1`, unchanged). The mdbook says the 30-second window "is an observation policy, not a consensus timeout or a rejection rule", and that `CvvInactive` validators and followers do not run the observer. Metrics are out of scope for the partner documents. Follow-up (not a document change): the testnet observability add-on and `check-node.sh` could read `tn_primary_last_commit_timestamp_seconds` to tell a stalled committee from a lagging node.
  Cite: `crates/consensus/primary/src/consensus/liveness.rs:20` (`QUORUM_OBSERVATION_WINDOW = 30 s`), `grep -n 'warn!\|info!\|error!' crates/consensus/primary/src/consensus/liveness.rs` (no hits), `crates/types/src/committee.rs:1191-1192` (`quorum_threshold = (2n / 3) + 1`; the file is unchanged base..HEAD), `docs/src/getting-started/consensus-liveness.md:45` (observation policy), `:62` (inactive validators and followers do not run it).

- Document: guide > Troubleshooting > Service and keys (branch side) and OPERATOR (branch side, the same row in its troubleshooting table). Kind: correction (#1558, 8aedf72e; the storage unit may also carry it, this is the consensus side).
  Current (guide): "| An `ERROR` line ending `; initiating node shutdown: <error>` | The node could not write a vote or certificate durably to its epoch database, `consensus-db/epoch`, and stopped its consensus tasks rather than risk signing twice. It keeps running, but it cannot vote again until it is restarted. | Check the data drive: free space with `df -h /var/lib/telcoin` and I/O errors with `sudo dmesg`. Fix the cause, then restart the node at once with `sudo systemctl restart telcoin`; the epoch wait protects nothing while the node cannot vote. If the line comes back, email devs@telcoin.org with it. |" (OPERATOR's row is the same with "in the journal" and support@telcoin.org.)
  Fact: All six ERROR lines (three in the certifier, three vote barriers) now end `; ending the epoch (the node stops if its stores cannot write): <error>`; none ends `; initiating node shutdown` any more. The node still refuses to send the vote or certificate, ends the epoch's consensus tasks, and then stops the whole process: a store that failed a write or a sync refuses every later write until restart, the epoch loop sees that latch at once (`a consensus store can no longer make writes durable; stopping the node`) or in its end-of-epoch check (for the epoch store: `the epoch store (votes, certificates, proposals) can no longer make writes durable; stopping the node (a restart reopens it)`), logs `epoch returned error`, and the binary exits with status 1 (`Error: ...` on stderr). With the units this repo writes (`Restart=on-failure`, `RestartSec=10`, `StartLimitIntervalSec=60`, `StartLimitBurst=5`), systemd starts it again after 10 seconds; if the disk is still failing the unit can end in `start-limit-hit`. The epoch database is now `consensus-db/tndb/epoch` (tndb), not `consensus-db/epoch`. Suggested row: symptom "An `ERROR` line ending `; ending the epoch (the node stops if its stores cannot write): <error>`, followed by the node exiting"; cause "The node could not write a vote or certificate durably to its epoch database (`consensus-db/tndb/epoch`) and refused to send it rather than risk signing twice. It then stops itself, because that store refuses every later write until a restart; systemd starts it again after 10 seconds."; fix "Check the data drive (free space, I/O errors) and fix the cause. If the unit has given up (`start-limit-hit`), run `sudo systemctl reset-failed telcoin` and `sudo systemctl start telcoin`. If the line comes back, email <contact> with it." The old advice "It keeps running, but it cannot vote again until it is restarted" and "the epoch wait protects nothing while the node cannot vote" no longer hold: the node does not keep running.
  Cite: `crates/consensus/primary/src/certifier.rs:533`, `:561`, `:606`; `crates/consensus/primary/src/network/handler.rs:621`, `:1122`, `:1161` (the six ERROR lines); `crates/node/src/manager/node/run_epoch.rs:463-474` (`store_failed => return Err(err)`), `:1203-1212` (`store_failure` message), `:626-633` (`ensure_stores_durable` at the epoch's end), `:1150-1166` (its three messages); `crates/node/src/manager/node.rs:1739-1753` (`epoch returned error`, `?` ends `run_epochs`); `bin/telcoin-network/src/main.rs:24-27` (`eprintln!("Error: {err:?}")`, `std::process::exit(1)`); `crates/storage/src/lib.rs:405-411` and `crates/storage/src/tndb/mod.rs:34`, `crates/storage/src/tndb/split.rs:46` (the `tndb/{epoch,kad,cache}` layout); this repo `lib/common.sh:3364-3365`, `:3378-3379`, `:3399-3400`, `:3412-3413` (restart policy).

- Document: guide > Before you start > Hardware per role (branch side: the clock-drift sentences) and OPERATOR (branch side, its two drift sentences). Kind: none (unchanged; the branch text stays).
  Current (guide branch): "A validator holds its vote on a header timestamped ahead of its own clock until that lead has passed, on testnet today for a lead of up to one second. It rejects a header more than five to six seconds ahead, its drift tolerance plus the five-second vote timeout; a header between the two gets no vote yet, and its proposer retries." (OPERATOR branch: "... 5.25 seconds with the default 250 ms tolerance, six seconds on a data dir whose `network-config` still holds the whole-second `max_header_time_drift_tolerance: 1` an older release wrote.")
  Fact: Unchanged at 7167e7800. The hold compares whole seconds against the tolerance rounded up while the sub-second fork is unarmed (so up to 1 s on adiri); the reject bound is the raw tolerance plus `vote_timeout` (5.25 s at the defaults, 6 s with the legacy integer `1`); the header errors still carry no penalty. Main's sentence "A node rejects headers timestamped more than a second ahead of its own clock." (guide main and OPERATOR main, both under the hardware section) is wrong and must not survive the merge; the branch text replaces it.
  Cite: `crates/consensus/primary/src/network/handler.rs:766-829` (`check_header_lead`; hold at `:777-781` with `ceil_secs(tolerance)`, reject bound at `:787-788` `tolerance.saturating_add(vote_timeout)`), `crates/config/src/network.rs:781` (default `Duration::from_millis(250)`), `crates/config/src/network.rs:1035-1070` (`secs_or_humantime`: a bare integer is read as seconds and warned about), `crates/config/src/node.rs:333-335` (`default_vote_timeout` = 5 s), `crates/types/src/forks.rs:808` (sub-second fork `u32::MAX`), `crates/consensus/primary/src/error/network.rs:215-221` (`TooNew`, `TooOld`, `InvalidTimestamp`, `InvalidSeedSignature => None`). `git -C <wt> diff 98849a221 HEAD -- crates/consensus/primary/src/network/handler.rs` touches none of these lines.

- Document: guide > Troubleshooting > Sync and node mode (the `CvvInactive` row, branch side). Kind: none (unchanged).
  Current: "It votes again once it is within 20 rounds of the network's newest commit in the same open epoch, while the network is still committing; the log then shows `attempting to rejoin consensus`."
  Fact: Unchanged: 20 rounds = (gc depth 50 - buffer 10) / 2; newest header younger than 5 s; same INFO line.
  Cite: `crates/types/src/primary/mod.rs:52` (`MAX_GC_DEPTH = 50`), `:64` (`GC_ACTIVITY_BUFFER = 10`), `:72-74`, `:84-86`; `crates/config/src/node.rs:337-339` (default gc depth is `MAX_GC_DEPTH`); `crates/consensus/executor/src/subscriber.rs:38` (`REJOIN_HEAD_MAX_AGE = 5 s`), `:317-319`.

#### Section 3. Mainnet genesis, epoch length and the hardware page (#1559, #1558 operator advice)

- Document: spec > Epoch boundaries (first paragraph) and spec > Trustless synchronization > Step 1. Kind: addition (optional; the current sentences stay right).
  Current: "On the Adiri testnet, epochs last about six hours." and "(six hours in the Adiri testnet genesis; governance can later change the epoch length)"
  Fact: Both stay right: the testnet genesis sets `epochDuration` 21,600 s (`0x5460`), and `chain-configs/testnet` is unchanged base..HEAD. #1559 regenerated the mainnet chain configs with the same 21,600 s (6-hour) epoch, replacing 86,400 s (24 hours), and pinned the epoch issuance beside it at 25,806 TEL per epoch (103,224 TEL a day at four epochs a day). The mainnet files are placeholders until the mainnet genesis ceremony: their four validators are throwaway test keys with addresses `0x1111...` to `0x4444...` and loopback bootstrap addresses. A writer may add "Mainnet's genesis is planned with the same six-hour epochs." Do not state the mainnet committee, stake or issuance as launch values.
  Cite: `chain-configs/testnet/genesis.yaml:103` (`StakeConfig.epochDuration` slot `0x13da...43e6` = `0x5460`), `chain-configs/mainnet/genesis.yaml:98` (same slot = `0x5460`; was `0x15180` = 86,400 at base: `git -C <wt> diff 98849a221 HEAD -- chain-configs/mainnet/genesis.yaml`), `chain-configs/mainnet/genesis.yaml:97` (`epochIssuance` slot `...43e5` = `0x576f23131f3c2780000`), `crates/telcoin-network-cli/src/genesis/mod.rs` test constants `MAINNET_EPOCH_DURATION_SECS = 21_600` and `MAINNET_EPOCH_ISSUANCE_TEL = 25_806` with the gate `mainnet_genesis_encodes_the_six_hour_epoch_target` (`grep -n 'MAINNET_EPOCH_DURATION_SECS\|MAINNET_EPOCH_ISSUANCE_TEL' crates/telcoin-network-cli/src/genesis/mod.rs`), `chain-configs/mainnet/committee.yaml:2-14` (placeholder authorities), `chain-configs/README.md` "## mainnet" ("holds placeholders, not the real mainnet configuration").

- Document: guide > Introduction > Vocabulary ("Epoch" row) and guide > Validators > When you get a committee seat. Kind: none (unchanged).
  Current: "| Epoch | The period between committee changes. Testnet epochs are six hours long. |" and "On testnet's six-hour epochs that is 12 to 18 hours after `activate()`, depending on how much of epoch E was left."
  Fact: Unchanged; testnet genesis epoch length is still 21,600 s, and the committee is still drawn three epochs ahead. A mainnet clause is not needed in a partner guide whose setup still lists mainnet as coming soon.
  Cite: `chain-configs/testnet/genesis.yaml:103`; `git -C <wt> diff --stat 98849a221 HEAD -- chain-configs/testnet` (empty).

- Document: OPERATOR > 1.1 Hardware per role, README (restart window). Kind: none (unchanged).
  Current: README "Only a node that reports `CvvActive` from `tn_nodeMode` waits, and only when the boundary is `TN_EPOCH_MARGIN` seconds away or closer: ..."
  Fact: `TN_EPOCH_MARGIN` (300 s), `TN_EPOCH_SETTLE` (90 s) and `TN_EPOCH_WAIT_MAX` (1,800 s) are script constants. Nothing in the range changes the epoch length on testnet or how a boundary is reached (a commit whose whole-second timestamp reaches start plus duration), so they stay right.
  Cite: `chain-configs/testnet/genesis.yaml:103`; `crates/tn-reth/src/evm` and `crates/tn-reth/src/env/epoch.rs` are unchanged base..HEAD (`git -C <wt> diff --stat 98849a221 HEAD -- crates/tn-reth/src/evm crates/tn-reth/src/env/epoch.rs crates/tn-reth/src/system_calls.rs` is empty).

- Document: guide > Before you start > Hardware per role (the table). OPERATOR > 1.1 Hardware per role (the table). Kind: none (unchanged).
  Current: "| Observer, follower | 2 cores, 8 GB RAM | 4 cores, 16 GB RAM |", "| Observer, public RPC | 4 cores, 16 GB RAM | 8 cores, 32 GB RAM |", "| Validator | 8 cores, 32 GB ECC RAM | 16 cores, 64 GB ECC RAM |", "at least 2 TB of TLC NVMe (10,000 write IOPS, 300 MB/s), 4 TB recommended", "200 Mbps symmetric bandwidth at minimum, 1 Gbps recommended", "A p95 round-trip time well below 1 second to at least 7 of the 10 committee members."
  Fact: The summary table is byte-identical at base and HEAD; every figure above still matches it, and the round-trip sentence is unchanged.
  Cite: `docs/src/getting-started/hardware-requirements.md:26-36` (summary table; same rows at base `git -C <wt> show 98849a221:docs/src/getting-started/hardware-requirements.md | sed -n '26,36p'`), `:396` (round-trip sentence).

- Document: guide > Before you start > Hardware per role (the paragraph after the table) and OPERATOR > 1.1 Hardware per role ("The upstream page also recommends ..."). Kind: addition (#1558; operator-facing recommendations the code cannot state, so the mdbook is the source; the numbers cite code).
  Current (guide): "The same documentation page recommends turning swap off and running time sync (chrony or systemd-timesyncd) on every node." (OPERATOR: "The upstream page also recommends turning swap off and running time sync (chrony or systemd-timesyncd) on every node.")
  Fact: The page now recommends three more things for a validator host. (1) Put the data directory on ext4 or xfs: the node preallocates disk blocks with `fallocate` as its storage files grow, so a full disk fails a write and the node stops cleanly; on a filesystem without `fallocate` (ext2, ext3, NFS, many FUSE filesystems) a full disk can crash it with SIGBUS, and btrfs or ZFS do not guarantee the space. (2) Leave the node's virtual address-space limit unlimited (no `ulimit -v`, no systemd `LimitAS=`): the consensus database reserves about 62 GiB of address space (16 GiB for each of three logs, 1 GiB for each of 14 table indexes), not RAM or disk. (3) On bare metal, turn off CPU and NVMe power saving (`performance` governor, `nvme_core.default_ps_max_latency_us=0`); cloud guests usually cannot. Suggested sentence: "It also recommends putting the data directory on ext4 or xfs, leaving the node's address-space limit unlimited, and, on bare metal, turning off CPU and NVMe power saving." The units this repo writes set no `LimitAS=`, so (2) holds on a default install; the scripts check neither (1) nor (3). The page's contact line says support@telcoin.org; the guide's own contact rule decides which address the guide prints.
  Cite: `docs/src/getting-started/hardware-requirements.md:405-409` (the five OS bullets), `crates/storage/src/tndb/store.rs:65` (`LOG_MAP_RESERVE = 16 << 30`), `crates/storage/src/archive/btree_index/index.rs:91` (`BTX_MAP_RESERVE = 1 << 30`), `crates/storage/src/tndb/split.rs:46` (three logs), `crates/storage/src/archive/data_file.rs:20-28` and `:1523-1534` (`fallocate` growth, sparse fallback), this repo `lib/common.sh:3415` (the unit's only `Limit*=` line is `LimitNOFILE=65536`).

#### Section 4. CLI: the `credential` passphrase source and `--bootstrap-peers-file` (#1715, 8958c3c8)

- Document: guide (main side) > Install > How setup stores the passphrase; OPERATOR (main side) > 2.4 Where things land and 2.8; README (passphrase sections). Kind: none (unchanged; the systemd statements stay).
  Current (guide main): "At each start, systemd decrypts the credential for the service, and the start script hands it to the node on standard input (`--bls-passphrase-source stdin`)." and "The passphrase is never on a command line, in the unit file or in the service's environment." (OPERATOR main 2.4: "It holds the node's launch command and flags, and feeds the BLS passphrase to the node on standard input.")
  Fact: Still right. The deployment scripts still start the node with `--bls-passphrase-source stdin` and redirect the start script's standard input from `$CREDENTIALS_DIRECTORY/bls-passphrase`, which systemd fills from `LoadCredentialEncrypted=bls-passphrase:<conf>/bls-passphrase.cred` (credential method) or `LoadCredential=bls-passphrase:<conf>/bls-passphrase` (stdin method). The node's `stdin` source is unchanged in behaviour: it reads one line and trims all trailing whitespace, as at base (now in place, in a zeroized buffer). Nothing in #1715 changes what the documents say about the systemd unit or the passphrase.
  Cite: this repo `lib/common.sh:3280` (`exec < "${CREDENTIALS_DIRECTORY:?...}/bls-passphrase"`), `lib/common.sh:3283-3286` (both forms exec `node --bls-passphrase-source stdin`), `lib/common.sh:3347-3348` (the two credential lines); `crates/telcoin-network-cli/src/passphrase.rs:261-270` (stdin: `read_line`, `trim_end`, truncate in place) against base `git -C <wt> show 98849a221:crates/telcoin-network-cli/src/passphrase.rs | sed -n '83,89p'` (`buffer.trim_end()`).

- Document: followup (this repo's follow-up list, not a partner document). Kind: follow-up.
  Current: none.
  Fact: telcoin-network main (not yet in any tag; the newest is still `v0.16.0-adiri`) adds `--bls-passphrase-source credential`. The node reads the file named by `--bls-passphrase-credential` (default `bls-passphrase`, env `TN_BLS_PASSPHRASE_CREDENTIAL`; an empty value selects the default; the name must be printable ASCII, at most 255 bytes, no `/` or `:`, not `.` or `..`) inside `$CREDENTIALS_DIRECTORY`. It removes exactly one trailing `\n` (and a `\r` before it) and keeps any other whitespace. It fails when `CREDENTIALS_DIRECTORY` is unset or empty, when the file is missing or unreadable, or when the passphrase is empty. Subcommands that do not need the passphrase do not read the credential. Once a release carries it, the scripts could: (a) drop the `exec < "$CREDENTIALS_DIRECTORY/bls-passphrase"` redirection from the binary start script and pass `--bls-passphrase-source credential` (the default credential name already matches the unit's `bls-passphrase` credential); (b) drop the `_tn_passfile_trim_safe` refusal and the "cannot ... start or end with whitespace" rule for new passphrases, because `credential` keeps trailing whitespace that `stdin` cuts (OPERATOR main 1.4 states the rule); (c) keep `stdin` for the Docker form unless the start script bind-mounts the credential directory into the container and passes `CREDENTIALS_DIRECTORY`, since the container does not see the host's credential directory. Any switch needs a node-version floor (a `require_node_flag`-style gate), because older binaries reject `credential` as an unknown value. Nothing changes in the partner guide until the scripts change.
  Cite: `crates/telcoin-network-cli/src/cli.rs:20-33` (`PassSource::Credential`), `:65-78` (`--bls-passphrase-credential`, default, env, `global = true`), `crates/telcoin-network-cli/src/passphrase.rs:24-28` (`CREDENTIALS_DIRECTORY`, `DEFAULT_BLS_PASSPHRASE_CREDENTIAL = "bls-passphrase"`), `:171-205` (`read_credential`), `:207-233` (`credential_name`), `:291-298` (only when the command needs a passphrase); this repo `lib/common.sh:3485-3489` (`_tn_passfile_trim_safe`), `lib/common.sh:3567-3579` (the stdin method refuses a whitespace-ending passphrase).

- Document: README / OPERATOR (no current sentence). Kind: none for the partner documents; follow-up for this repo.
  Current: none.
  Fact: #1715 also zeroizes the passphrase in memory: every buffer that holds it is a `Zeroizing<String>`, and on Linux the `env` source overwrites the value bytes of each `TN_BLS_PASSPHRASE=` entry in the process environment block with zeros before removing the variable (when `/proc/self/task` shows one thread; otherwise it only removes it and warns on stderr), so `/proc/<pid>/environ` keeps the name and a run of zero bytes as long as the value. The scripts never pass the passphrase through the node's environment (the units carry `UnsetEnvironment=TN_BLS_PASSPHRASE`), so this changes nothing a document says about the deployment.
  Cite: `crates/telcoin-network-cli/src/passphrase.rs:13` (`use zeroize::Zeroizing`), `:30-51` (doc comment and signature of `get_bls_passphrase_from_env`), `:88-140` (`scrub_env_values`, `zero_env_values`, `is_single_threaded`); `crates/telcoin-network-cli/Cargo.toml:62`; this repo `lib/common.sh:3372`, `:3409` (`UnsetEnvironment=TN_BLS_PASSPHRASE` in both unit forms).

- Document: followup (this repo). Kind: follow-up.
  Current (setup-node.sh comment, not a document): `--bootstrap-peers "$(cat /etc/telcoin/bootstrap-peers.yaml)"` on the launch line.
  Fact: `telcoin-network node --bootstrap-peers-file <PATH>` reads the same YAML or JSON map from a file while arguments are parsed (a missing or invalid file stops the node before startup) and conflicts with `--bootstrap-peers`. A relative path resolves from the working directory, which is `/` for a systemd unit, so a unit should give an absolute path. Once a release carries it, setup-node and edit-config could write `--bootstrap-peers-file /etc/telcoin/bootstrap-peers.yaml` instead of expanding the file into the command line, which would drop the restriction that a custom config directory hold only `[A-Za-z0-9._/+-]` (the start wrapper expands the path unquoted today). Partner documents that mention `--bootstrap-peers` describe the script's flag (a file argument), which is unchanged.
  Cite: `crates/telcoin-network-cli/src/node.rs:30-39` (`parse_bootstrap_peers_file`), `:69-79` (the flag, `conflicts_with = "bootstrap_peers"`), `:316` (`bootstrap_peers.or(bootstrap_peers_file)`), `docs/src/getting-started/bootstrap-peers.md` (the working-directory note); this repo `setup-node.sh:2221-2240`, `edit-config.sh:1131`, `:1217`.

- Document: (none in F3's scope). Kind: seen, for F2 or the observability unit.
  Fact: In the same window (#1696/#1689, staging 10-20) a bare `--healthcheck <port>` now binds `127.0.0.1`, not `0.0.0.0`, and a bind failure stops startup. `check-node.sh` reads `--healthcheck` from the launch line for the testnet health monitor. Not settled here; listed so the owning unit checks it.
  Cite: `crates/telcoin-network-cli/README.md` (Health check endpoint, "A bare port binds `127.0.0.1`"), `crates/node/src/engine/mod.rs:52-59` (`healthcheck: Option<HealthcheckBind>`), this repo `check-node.sh:2013-2028`.

#### Section 5. The public release pipeline and what a partner checks by hand (#694, 7c014dc0)

- Document: guide (main side) > Install > How the scripts and releases are checked; OPERATOR (main side) > 4.10 Verifying a release by hand; README (main side) "A telcoin-network release publishes `SHA256SUMS` ...". Kind: none (unchanged; confirmed against upstream).
  Current (guide main): "A release publishes `SHA256SUMS` and its signature `SHA256SUMS.asc`. ... `SHA256SUMS` lists the binary tarball, the Docker image digest (`IMAGE_DIGEST`) and the release's three chain-config files, and the scripts check what they use against it." (OPERATOR main 4.10: "Its `SHA256SUMS` lists five files: `IMAGE_DIGEST`, the tarball `telcoin-network-<tag>-x86_64-unknown-linux-gnu.tar.gz`, and the chain configs `chain-configs/<dir>/committee.yaml`, `genesis.yaml` and `parameters.yaml` (`<dir>` is `testnet` for `-adiri` tags and `mainnet` for mainnet tags).")
  Fact: Matches the pipeline on main: a release is a signed git tag plus four GitHub release files (the x86_64 tarball, `IMAGE_DIGEST`, `SHA256SUMS`, `SHA256SUMS.asc`); `SHA256SUMS` names exactly `IMAGE_DIGEST`, the tarball and the channel's three chain-config files by repository path (`chain-configs/testnet/` for `-adiri` tags, `chain-configs/mainnet/` otherwise), C-locale sorted; `SHA256SUMS.asc` is a detached OpenPGP signature by a maintainer key held on a YubiKey; images go to `ghcr.io/telcoin-association/telcoin-network` (`linux/amd64` only) and only the digest in `IMAGE_DIGEST` is signed, not tags such as `:adiri` or `:latest`. The release key the scripts ship, `lib/release-keys/grantkee.asc` (main side of this repo), is byte-identical to upstream's `.github/maintainer-gpg-keys/grantkee.asc`; its primary fingerprint `4E36D35A4AB61B589861D01AC7173F2377CA7573` and expiry 2028-10-16 match upstream's SECURITY.md table (status `active`, one signature required). No release has been cut with this pipeline yet: the newest telcoin-network tag is still `v0.16.0-adiri`, and the mdbook's examples use `v0.17.0-adiri`, so "Signed releases start at `v0.17.0-adiri`" is the plan, not something a tag shows yet.
  Cite: `docs/src/getting-started/installing-a-release.md:4-11` (the four files), `:35` (five lines), `:38-40` (YubiKey key, keys on `main`), `:47` (tags not signed), `:204` (`linux/amd64` only); `etc/release.sh:266-275` (`CHAIN_CONFIGS` per channel), `:1113-1120` (`sums_names`), `:1148-1155` (C-locale sort); `SECURITY.md:76-84`; `.github/maintainer-gpg-keys/grantkee.asc` (`cmp` with this repo's `git show origin/main:lib/release-keys/grantkee.asc` reports no difference; `gpg --show-keys` prints the fingerprint and `expires: 2028-10-16`); `git -C <wt> tag --sort=-creatordate | head -1` = `v0.16.0-adiri`.

- Document: guide (main side) > Day-2 operations > Update the node (the hand check for an `existing` install). Kind: correction.
  Current: "gpgv --keyring ./release-keys.gpg SHA256SUMS.asc SHA256SUMS" ... "Go on only if `gpgv` reports a good signature and `sha256sum` reports the tarball `OK`."
  Fact: The upstream install page warns that gpgv prints `Good signature from` and exits 0 even when the signing key is revoked or expired, so "a good signature" read from gpgv's normal output can pass a revoked or expired key. The hand check should read gpgv's status lines: run `gpgv --status-fd 1 --keyring ./release-keys.gpg SHA256SUMS.asc SHA256SUMS` and go on only if it prints a `GOODSIG` line (with its `VALIDSIG`) and no `BADSIG`, `EXPSIG`, `EXPKEYSIG` or `REVKEYSIG` line. (Upstream's own block also stops on any `ERRSIG`; this repo's scripts, per OPERATOR main 4.10, only warn on an `ERRSIG` for a key they do not ship. Either rule is safe for a hand check; the stricter one is simpler to state.) The `sha256sum -c --ignore-missing SHA256SUMS` line is fine for this block, which only needs the tarball: it skips the chain-config and `IMAGE_DIGEST` lines silently, so "reports the tarball `OK`" is the right test.
  Cite: `docs/src/getting-started/installing-a-release.md:81-82` (the status-fd block and its `awk` rule), `:94` ("gpgv prints `Good signature from` and exits 0 even when the signing key is revoked or expired"), `:240-242` (`REVKEYSIG`, `EXPKEYSIG`, `EXPSIG` rows). This is the mdbook's statement about gpgv, not telcoin-network code.

- Document: OPERATOR (main side) > 4.10 Verifying a release by hand. Kind: correction (the `gpgv` line) and addition (the `--version` checks).
  Current: "gpgv --keyring ./release-keys.gpg SHA256SUMS.asc SHA256SUMS" followed by "`gpgv` must report a good signature by a shipped key. The scripts refuse a release when any line reports `BADSIG` (by any key), `EXPKEYSIG`, `REVKEYSIG` or `EXPSIG`, or when no shipped key signed it." and "`--version` must name the tag's version, `X.Y.Z` (a release candidate's binary reports `X.Y.Z` too, without `-rcN`)."
  Fact: (1) Without `--status-fd 1`, gpgv prints no `BADSIG`/`EXPKEYSIG`/`REVKEYSIG` keywords for the reader to check, and it exits 0 on a revoked or expired key; give the command as `gpgv --status-fd 1 --keyring ./release-keys.gpg SHA256SUMS.asc SHA256SUMS` so the sentence after it can be followed. (2) Upstream's check of the binary has two more lines than "names the tag's version": the first line is `telcoin-network-cli Version: X.Y.Z` (the tag without `v`, `-adiri` or `-rcN`); `Commit SHA:` must equal `git -C tn-main rev-parse "refs/tags/$TAG^{commit}"`; and `Build Features:` must be `adiri` (possibly with `faucet`, which `adiri` implies) on an `-adiri` tag and empty on a mainnet tag. For the image, the binary is `/usr/local/bin/telcoin` and its `--version` must show the same lines. (3) Upstream fetches the tag by its full name, `refs/tags/<TAG>`, because `git clone --branch <TAG>` prefers a branch of the same name; OPERATOR's full clone followed by `git archive "refs/tags/$TAG"` already does that, so it stays right.
  Cite: `docs/src/getting-started/installing-a-release.md:94` (gpgv exit status), `:144-148` (the three `--version` lines), `:200` (image binary path), `:64` (fetch by full tag name); `crates/telcoin-network-cli/src/version.rs:40-51` (the `Commit SHA: ` and `Build Features: ` fields).

- Document: OPERATOR, README and guide (main side), wherever they name the chain-config pins (`TESTNET_GENESIS_SHA256`, `TESTNET_COMMITTEE_SHA256`, `TESTNET_PARAMETERS_SHA256`, pinned at `TESTNET_CHAIN_CONFIGS_TAG=v0.16.0-adiri`). Kind: none (unchanged).
  Current (guide main): "The chain configs (`genesis.yaml`, `committee.yaml` and `parameters.yaml`) are checked against SHA-256 pins that ship with the scripts before setup copies them."
  Fact: The three testnet chain-config files at 7167e7800 hash to exactly the pinned values (genesis `670c94e3...88c2`, committee `009b6d7b...15ce`, parameters `7c6a4471...a091`), the same as at `v0.16.0-adiri`; `chain-configs/testnet` is unchanged base..HEAD. A first signed `-adiri` release cut from this tree would list these hashes in `SHA256SUMS`, so the pins stay right. Mainnet has no pins, and `chain-configs/mainnet` is a placeholder (section 3), so README's "Mainnet has no pins yet, so mainnet release installs are refused until a script release publishes them" stays right.
  Cite: `sha256sum chain-configs/testnet/{genesis,committee,parameters}.yaml` in the worktree; `git -C <wt> show v0.16.0-adiri:chain-configs/testnet/<file> | sha256sum`; this repo `lib/common.sh:6063-6066` (branch and main carry the same four lines).

- Document: guide (branch side) > Install > Install methods (the `3) Docker` row) and guide (branch side) > Validators > Stake by hand (`IMAGE=us-docker.pkg.dev/telcoin-network/tn-public/adiri:v0.16.0-adiri`). Kind: removal (merge note).
  Current (branch): "| `3) Docker` | `docker` | Installs Docker if missing and pulls the image from `us-docker.pkg.dev/telcoin-network/tn-public/adiri`. The default tag is the newest `-adiri` tag in the registry, or `v0.16.0-adiri` if the registry cannot be reached. | `update-node.sh` |"
  Fact: The release pipeline publishes every channel's images to ghcr.io only; the Artifact Registry repository holds only the images of releases made before it (`v0.16.0-adiri` among them). Main's scripts and main's guide row already say this (ghcr.io first, the legacy repository on testnet only, by digest). In the merged guide, main's Docker row replaces the branch's, and an example that names an image should use main's wording (`<repository>@sha256:<digest>`, ghcr.io), not a tag on `us-docker.pkg.dev`.
  Cite: `docs/src/getting-started/installing-a-release.md:9` (`ghcr.io/telcoin-association/telcoin-network`), `docs/src/getting-started/validator-operations.md:82` ("Each release has a Linux x86_64 tarball on its GitHub release page and a `linux/amd64` image at `ghcr.io/telcoin-association/telcoin-network`"); `etc/release.sh:243-249` (build pushes to ghcr.io); this repo `git show origin/main:lib/common.sh | sed -n '1495,1510p'` (`TN_GHCR_IMAGE_REPO`, `TN_TESTNET_LEGACY_IMAGE_REPO`).

- Document: guide > Day-2 operations > Update the node, or Getting help. Kind: addition (optional).
  Current: none.
  Fact: Each telcoin-network GitHub release page lists its files, the commands to verify them, and operational notes such as a required resync or configuration change, and the release notes page carries each tag's changelog section. Activation conditions and the last safe rollback point arrive through the operator channel and the release notes; there is no automatic update. A partner should read a release's notes before applying it.
  Cite: `docs/src/getting-started/release-notes.md:8`; `docs/src/getting-started/validator-operations.md:81-94` (the "Releases are published as signed git tags" paragraph: "There is no automatic update: operators decide when to install a release", "Activation conditions and the final safe rollback point arrive through the authenticated operator channel and the release notes").

### Seen but out of scope

- #1693's Prometheus series (`tn_primary_round_quorum_shortfalls_total`, `tn_primary_last_commit_timestamp_seconds` and the rest) and the dashboards and alerts on `docs/src/getting-started/consensus-liveness.md` — metrics and dashboards are out of scope for the partner documents; the only operator-visible effect is none in the log (section 2). A follow-up for the testnet observability add-on is noted there.
- #1558 tndb as a whole (the `consensus-db/tndb/{epoch,kad,cache}` layout, the one-time MDBX copy, `db tndb-stat`, the new `tn_storage_tndb_*` series, the hardware page's storage rewrite) — the storage unit's. Two consequences touch F3's documents and are recorded above: the certifier and vote-barrier lines now stop the node (section 2), and the hardware page's three new OS recommendations (section 3). One more for the storage unit to settle: `docs/src/getting-started/validator-operations.md` says a node that has started the tndb release cannot roll back to an MDBX release, which is a second one-way floor beside this repo's `STORAGE_MIGRATION_FLOOR` (0.16.0) in `update-node.sh`; also a failed certificate-pack save is now a consensus error that stops the node (`crates/consensus/primary/src/consensus/state.rs`, `certificate_archived`).
- #1696/#1689 (staging 10-20): a bare `--healthcheck <port>` binds `127.0.0.1` instead of `0.0.0.0`, and a bind failure stops startup — F2's or the observability unit's; `check-node.sh:2013-2028` reads `--healthcheck` from the launch line.
- The handoff WARN `active worker refused retired worker transactions; discarding` (target `tn::execution`, `crates/tn-reth/src/txn_pool.rs:1235-1238`), logged when a worker removed by a lower on-chain worker count hands over transactions the first worker refuses. Rare (it needs a worker-count drop on a busy node); a troubleshooting row is optional and not proposed.
- The `etc/release.sh` internals (`MIN_SIGNATURES=1`, draft and sign steps, YubiKey serials, the git-cliff image) — release tooling, maintainer-only; partners see only the four release files and the signed tag.
- `chain-configs/mainnet/parameters.yaml` values that differ from testnet (`max_header_delay: 1s` against testnet's `3s`, `basefee_address: "0x9999999999999999999999999999999999999999"`, an explicit `vote_timeout: 5s`) — placeholders until the mainnet genesis ceremony; not for the partner documents.
- The workspace version on main is still `0.1.0` (`Cargo.toml:50`); the release process writes `X.Y.Z` at release time, so a binary built from main reports `Version: 0.1.0`. Not a partner fact.
- `bin/worker-gateway` exists on main but predates the range (2026-07, #823/#908) and is untouched by it; the worker-gateway stack the preamble excludes (`--forward-txs`, `feat/worker-gateway-*`) is not on main. Not described.
