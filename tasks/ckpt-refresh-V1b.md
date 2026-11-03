status: done
completed sections: 1, 2, 3, 4, 5

WT = scratchpad/tn-main at 7167e7800; tag = v0.16.0-adiri (d72cc2bcf).

## Section 1 findings (derived from code before reading writer notes)

Confirmed:
- book recommends ext4/xfs, unlimited AS, power saving off: docs/src/getting-started/hardware-requirements.md:406-408
- fallocate growth, full disk fails a write; fallback ext2/ext3/NFS(<4.2)/FUSE sparse; btrfs/ZFS no guarantee: crates/storage/src/archive/data_file.rs:20-30,1523-1545 (tag: data_file.rs:19-22,678-689)
- 62 GiB = 3 logs x 16 GiB + 14 indexes x 1 GiB: crates/storage/src/tndb/store.rs:65, crates/storage/src/archive/btree_index/index.rs:91, crates/storage/src/lib.rs:114-136 (14 tables). NOT at tag (no tndb; tag MDBX max 512M/64M/1024M: tag crates/storage/src/lib.rs:177-190)
- unit sets no LimitAS, docker run no --ulimit as: lib/common.sh:3283,3355-3415
- performance governor / nvme_core.default_ps_max_latency_us=0 / cloud cannot: book hardware-requirements.md:408
- health: tag bare port binds 0.0.0.0 (tag crates/node/src/health.rs:181), tag CLI Option<u16> refuses addr form (tag crates/telcoin-network-cli/src/node.rs:124-125), tag ignores bind failure (tag crates/node/src/manager/node.rs:906 `let _ =`); main bare port -> 127.0.0.1 (crates/node/src/health.rs:86-101,121-128), bind error fails startup (crates/node/src/manager/node.rs:921-928, health.rs:251), WARN `listener bound on every interface` (crates/tn-metrics/src/exposure.rs:62-67)
- scripts write bare port: setup-observability.sh:67,70; lib/common.sh:8254; scripts probe 127.0.0.1: check-node.sh:925, setup-observability.sh:371
- network-config: six keys exist on main (crates/config/src/network.rs:27-75), defaults inert (AdmissionConfig Open: network.rs:482-494; ServeBudget 0=unbounded: network_budget.rs:133-150); no script sets them (grep)
- release page lists files, verify commands, operational notes: book docs/src/getting-started/release-notes.md:8
- gpgv prints Good signature/exits 0 on expired/revoked: book installing-a-release.md:94
- "planned to start with v0.17.0-adiri": allowed (book uses v0.17.0-adiri as first example, installing-a-release.md:71, maintainers/releasing.md:8)

Candidate defects:
- C1 wrong: "the first four also count as unset when null or {}" -- process_budget/source_admission are Option<struct> with required fields + deny_unknown_fields (network_budget.rs:14-27, source_admission.rs:10-27): `{}` fails "missing field"; trusted_nodes/committee_peers are BTreeMap (network.rs:63,71-72, deserialize_committee_peers network.rs:126-152 calls deserialize_map): serde_yaml 0.8.26 deserialize_map rejects null (de.rs:1319-1330); load fails start (crates/config/src/traits.rs:56-70, network.rs:442-444).
- C2 imprecise: "Six of the keys it accepts" has no release qualifier: none of the six exist at the tag (tag NetworkConfig: sync/quic/peer/peer_readiness/hostname/bootstrap_peers/endpoints, no deny_unknown_fields -> ignored).
- C3 imprecise: "The consensus database reserves about 62 GiB" is next-release (tndb) only.
- C4 imprecise (minor): "on a bare-metal validator" - book says "On bare metal" for every node (hardware-requirements.md:408).
- C5 imprecise: gpgv bad list omits ERRSIG; book refuses any ERRSIG (installing-a-release.md:82,94); scripts refuse ERRSIG except code 9 (lib/common.sh:6592-6620).

## Section 2 findings (Day-2: Where things land, One-way updates, Update the node)
status line above superseded: section 2 done.

Confirmed:
- epochs/epoch-N: crates/config/src/traits.rs:155-156 (tag same), crates/storage/src/certificate_pack.rs:178
- tag epoch/kad/cache MDBX dirs and their tables: tag crates/storage/src/lib.rs:186-205 (LastProposed/Votes in epoch, cleared every epoch: lib.rs:115-121 main)
- tndb dir + 3 envs + marker: crates/storage/src/tndb/mod.rs:34, tndb/split.rs:46,50; migration copy/delete/marker: crates/storage/src/lib.rs:239-327, remove_mdbx_env lib.rs:336-351; migration runs in prod (default feature reth-libmdbx: crates/storage/Cargo.toml:67)
- log `copied <n> rows of the consensus DB from MDBX to tndb`: lib.rs:324-326 (only when copied > 0)
- `Cannot migrate the consensus DB from MDBX` panic: lib.rs:432; retry copies again (tables cleared first): lib.rs:229-233, 380-405
- downgrade to MDBX build starts with empty epoch tables, can equivocate: lib.rs:233-237, tndb/README.md:634-637; pack format unchanged (consensus_pack.rs:82 PACK_VERSION 2 = tag :60; file names same) so "not refused" is plausible but no code says so
- update-node knows only the 0.16.0 floor: update-node.sh:134,963-983 -> "whether or not the script asks" right
- release notes page: book release-notes.md:8

Candidate defects:
- C6 WRONG (main defect): v0.16.0-adiri has NO start-up epoch check. epoch_db_recovery.rs was added by 98849a22 (#1572), 3 commits after the tag (`git merge-base --is-ancestor 98849a22 v0.16.0-adiri` false); `git grep 'Cannot check database' v0.16.0-adiri` finds nothing; tag open_mdbx (tag lib.rs:162-210) checks nothing; a bad row at the tag panics `Invalid bytes!` on first typed read (tag crates/types/src/codec.rs:66-67). Affects: troubleshooting row ("consensus-db/epoch on v0.16.0-adiri", "On v0.16.0-adiri, stop the node ... move"), One-way updates lines "A node whose epoch database fails its start-up check stops with `Cannot check database (epoch)`" now scoped by the new "For the update to v0.16.0-adiri" sentence, and "the v0.16.0-adiri fix ... applies". The consensus-db/epoch remedy is right only for the next release's first start (`Cannot migrate the consensus DB from MDBX: Cannot check database (epoch)`, lib.rs:283-284 wrap_err, :432; error names `consensus-db/epoch`: epoch_db_recovery.rs:207-225, test :652-655).
- C7 imprecise: epochs/ "consensus packs of finished epochs" - the epoch in progress's pack is also there, opened for append (crates/storage/src/consensus.rs:526-540; tag :474).
- nit: "the old database stays untouched until the copy is complete" - discard_seconds_only_proposal(&src) may delete one LastProposed row from MDBX first (lib.rs:280-284). Not raised as defect.

## Section 3 findings (Troubleshooting rows)

Confirmed:
- main tndb epoch check every start: crates/storage/src/lib.rs:433-436; error text (names `consensus-db/tndb/epoch`, says remove it): crates/storage/src/epoch_db_recovery.rs:139,207-225; tndb refuses missing env/manifest beside marker: crates/storage/src/tndb/split.rs:55-97 (via open_with :128-131, expect "Cannot open database (tndb)" lib.rs:409) -> guide's "do not remove tndb/epoch" is right (upstream message is self-contradictory)
- first-start variant `Cannot migrate the consensus DB from MDBX: Cannot check database (epoch)`: lib.rs:283-284,432; test epoch_db_recovery.rs:652-655 (names `consensus-db/epoch`); move consensus-db/epoch aside -> epoch not copied (lib.rs:268-273), tndb epoch starts empty, so "start once the epoch has closed" is right
- restart every 10 s / start-limit-hit: lib/common.sh:3364-3365,3378-3379,3399-3400,3412-3413 (Restart=on-failure, RestartSec=10, StartLimitBurst=5/60s)
- durability line at main ends `; ending the epoch (the node stops if its stores cannot write): {e}`: crates/consensus/primary/src/network/handler.rs:621,1122,1161; certifier.rs:533,561,606; then epoch ends, finish_epoch -> ensure_stores_durable Err (crates/node/src/manager/node/run_epoch.rs:627-630,1150-1165) -> launch_node Err (crates/node/src/lib.rs:89-99) -> main exit(1) (bin/telcoin-network/src/main.rs:13-17, cli.rs:186-213); latch "writes stop until a restart": crates/storage/src/tndb/store.rs:707
- tag vote barrier line ends `; initiating node shutdown: {e}` and notifies consensus shutdown: tag handler.rs:623,1124,1162; tag run_epoch ModeChange re-entry, keeps running: tag run_epoch.rs:476-535
- -32603 `validator is inactive; retry another endpoint` on both submit methods: crates/tn-reth/src/rpc_fee_cap.rs:57-77, method checks rpc_fee_cap.rs:~204-222; INTERNAL_ERROR_CODE=-32603 jsonrpsee-types 0.26.0 src/error.rs:129 (Cargo.lock:5226-5227); /health/workers same predicate: crates/node/src/engine/readiness.rs:44; not at tag (#1553 via 5ccb88e8)
- -32000 `worker is no longer active in this epoch; submit to an active worker`: rpc_fee_cap.rs:180-188; `worker is inactive`: crates/tn-reth/src/worker.rs:174-178

Candidate defects:
- C6 (see section 2) also covers the troubleshooting row.
- C8 imprecise: the worker-inactive row has no release label, but neither `worker is inactive` nor `worker is no longer active in this epoch` exists at the tag (`git grep 'is inactive' v0.16.0-adiri -- crates/tn-reth` empty; strings added by 2635e26a #1654 and earlier post-tag commits); the next row says "From the next release" - this one should too. Also the -32000 refusals apply to eth_sendRawTransactionSync too (rpc_fee_cap.rs ~204-222).
- C9 imprecise (minor): on v0.16.0-adiri only the vote barrier lines end `; initiating node shutdown`; the tag's certificate barrier lines end `refusing to externalize: <e>` / `unable to save the certificate: <e>` (tag certifier.rs:524,566) and return a critical task error, which at the tag ends run_epoch with Err (tag run_epoch.rs:490-493), i.e. the node stops rather than keeps running.

## Section 4 findings (writer notes compared, cross-document agreement, off-main)

Writer notes vs my derivation:
- C6 root cause: F1 s3 ("Writers: keep `consensus-db/epoch` for `v0.16.0-adiri` (every deployed node)") and orchestrator decision 2 assumed the tag has the start-up check. It does not: the check came with #1572 (98849a22 = the 98849a221 base of guide 1.4), 3 commits after the tag. Commit message of 98849a22: before it, opening the consensus DB "panics about 80 ms in with "Invalid bytes!: Eof" and the node crash-loops".
- C9 root cause: F1 cites `98849a221` certifier.rs:532,559,603 for the old `; initiating node shutdown` text; at the tag the certifier lines lack it (tag certifier.rs:524,566). Only the three vote lines (tag handler.rs:623,1124,1162) carry it.
- C3: F1's own heading is "Filesystem and address-space requirements of tndb"; the guide dropped the release scope.
- C4: F3 wrote "three more things for a validator host"; the book's Operating system list is for every node, power saving "On bare metal".
- C1: F2 kept the inherited "(absent, null or {})" (facts :735, :1237) without checking serde.
- C5: orchestrator check 8b settled exit status and the four keywords; the book also refuses ERRSIG (installing-a-release.md:82,94).
- Log/doc mismatch (not a doc defect): S2 log says the Docker row and "Signed releases ..." read "planned to start with the next release" and that the build found no `v0.17` text; the file reads "planned to start with `v0.17.0-adiri`" (allowed by the orchestrator's rule; the log is stale).
- Writer's gap noted, agree: no procedure for changing `--healthcheck` to the address form (setup-node re-run regenerates the bare form: lib/common.sh:8254, setup-node.sh:2398).

Cross-document agreement (OPERATOR.md, README.md, specification diffs vs 58665ac):
- Health listener: guide, OPERATOR 4.6 (:797-803), README :430 agree (facts, release wording).
- tndb one-way, `copied <n> rows`, `Cannot migrate`, do-not-move tndb/epoch, v0.16 not refused/empty tables: guide, OPERATOR 4.2 (:593-595), README agree.
- `Cannot check database (epoch)` row: OPERATOR :1534 carries the same C6 error ("`consensus-db/epoch` on `v0.16.0-adiri`", "On `v0.16.0-adiri`, and on the first start of the next release ... move"); OPERATOR :588 same scoping problem as the guide's One-way lines. Fix both together.
- Durability row: OPERATOR :1537 agrees with the guide, numbers same (status 1, 10 s); same C9 imprecision.
- -32603 row and worker-inactive row: OPERATOR agrees; OPERATOR labels the -32603 row "(from the next release)"; both leave the worker-inactive row unlabeled (C8 applies to both). Specification states the refusal without the code (consistent).
- network-config: OPERATOR repeats C1 ("The first four are unset by default (absent, `null` or `{}`)") and C2 (no release label).
- Host settings: OPERATOR repeats C3 (62 GiB unscoped) and C4 ("For a validator host"); numbers agree (62 GiB, 16 GiB x 3, 1 GiB x 14).
- Where things land: OPERATOR and README repeat C7 ("epochs/ holds the consensus packs of finished epochs" / "the epoch packs").
- gpgv hand check: guide, OPERATOR 4.10, README agree on the four keywords (C5 applies to all three).
- Minor: OPERATOR keeps the snapshot example `/var/lib/telcoin.pre-v0.16`; guide renamed it `/var/lib/telcoin.pre-update`. Example name only.

Off-main check: every main behaviour named is on main (8aedf72e tndb, d2a0b525 health bind/serve_budget, 5ccb88e8 validator-inactive/admission, 2635e26a worker no longer active all ancestors of 7167e7800). No staging 10-27, worker gateway or `--forward-txs` text. `v0.17.0-adiri` appears only as a plan (allowed). Tag wording uses `v0.16.0-adiri` and "the next release" only.

Partner-safety/conventions: contact only devs@telcoin.org (19 hits; build script CONTACT=devs@telcoin.org, tools/build-partner-pdf.sh:193); no legacy/--observer/migrate-node-naming/setup-observer/setup-validator; one `# ` title, no prose before first `## `; all `](#...)` links in the guide resolve to heading slugs (C-locale comm empty); all 19 GitHub links under https://github.com/Telcoin-Association/.

# Section 5: Report

## Verdict

Statements checked: 51 (each added or changed sentence or table cell in `git diff 58665ac -- docs/partner/mno-node-guide/mno-node-guide.md`, plus the four unchanged One-way lines that the new "For the update to `v0.16.0-adiri`" sentence re-scopes). Confirmed: 39. Defective statements: 12, in 9 defects (2 wrong, 7 imprecise). No disagreement between documents: OPERATOR.md and README.md carry the same text, so C1, C2, C3, C4, C5, C6, C7, C8 and C9 apply to their twins too. No convention defect.

## Defects

- D1 wrong: "The node stops at every start ... `consensus-db/epoch` on `v0.16.0-adiri`, `consensus-db/tndb/epoch` from the next release." and "On `v0.16.0-adiri`, stop the node ... `sudo mv /var/lib/telcoin/consensus-db/epoch ...`", the One-way lines now scoped "For the update to `v0.16.0-adiri`": "A node whose epoch database fails its start-up check stops with `Cannot check database (epoch)` ... That fix touches only `consensus-db/epoch`", and "When that line goes on with `Cannot check database (epoch)`, the `v0.16.0-adiri` fix ... applies". What the code says: `v0.16.0-adiri` runs no start-up epoch check and never prints `Cannot check database (epoch)`. `epoch_db_recovery.rs` came with #1572 (98849a22), three commits after the tag. `git grep 'Cannot check database' v0.16.0-adiri` is empty, the tag's `_open_mdbx` checks nothing, and at the tag a bad row panics `Invalid bytes!` in the typed decode while the DB opens (commit message of 98849a22). The `consensus-db/epoch` line exists only on the next release's first start, as `Cannot migrate the consensus DB from MDBX: Cannot check database (epoch) ...`. Where: tag crates/storage/src/lib.rs:162-210; tag crates/types/src/codec.rs:66-67; crates/storage/src/lib.rs:283-284,432,436; crates/storage/src/epoch_db_recovery.rs:139,207-225,652-655. Proposed fix: scope the row to the next release: the `Cannot migrate ...: Cannot check database (epoch)` form on its first start takes the `mv consensus-db/epoch` remedy, the plain form on a tndb node takes "do not move, email devs@telcoin.org". Drop "on `v0.16.0-adiri`" from the cause, the fix and the One-way pointer lines. OPERATOR.md :588 and :1534 need the same fix.
- D2 wrong: "(absent; the first four also count as unset when `null` or `{}`)". What the code says: `process_budget` and `source_admission` are `Option` of structs whose fields are all required, with `deny_unknown_fields`, so `{}` fails with "missing field" and the node does not start. `trusted_nodes` and `committee_peers` are maps, and serde_yaml 0.8.26 rejects `null` for a map. Where: crates/config/src/network_budget.rs:14-27; crates/config/src/source_admission.rs:10-27; crates/config/src/network.rs:63,71-72,126-152; serde_yaml-0.8.26 src/de.rs:1319-1330 (Cargo.lock:11318-11319); crates/config/src/traits.rs:56-70; crates/config/src/network.rs:442-444. Proposed fix: "They are unset by default, which means absent, and no script sets them" (OPERATOR.md has the same clause).
- D3 imprecise: "Six of the keys it accepts are opt-in: ...". What the code says: none of the six exists at the tag, whose `NetworkConfig` has no `deny_unknown_fields` and so ignores them. All six exist on main. Where: tag crates/config/src/network.rs (`NetworkConfig`: libp2p/sync/quic/peer/peer_readiness_timeout/hostname/bootstrap_peers/endpoints); crates/config/src/network.rs:27-75. Proposed fix: add "From the next release," or say that `v0.16.0-adiri` ignores these keys.
- D4 imprecise: "The consensus database reserves about 62 GiB of address space". What the code says: the figure is tndb's (3 logs x 16 GiB + 14 indexes x 1 GiB), which exists on main only. At the tag the consensus DB is MDBX with 512 MiB, 64 MiB and 1 GiB maps. Where: crates/storage/src/tndb/store.rs:65; crates/storage/src/archive/btree_index/index.rs:91; crates/storage/src/lib.rs:114-136; tag crates/storage/src/lib.rs:177-190. Proposed fix: "From the next release the consensus database reserves about 62 GiB ...".
- D5 imprecise: "The consensus packs of finished epochs, in `epoch-N` directories." What the code says: `epochs/` also holds the pack (and the certificate pack) of the epoch in progress, opened for append. Where: crates/storage/src/consensus.rs:526-540; crates/node/src/manager/node/run_epoch.rs:379; tag consensus.rs:474. Proposed fix: "The consensus packs, one `epoch-N` directory per epoch, the epoch in progress included." (The same wording is in OPERATOR.md and README.md.)
- D6 imprecise: "Go on only if `gpgv` prints a `GOODSIG` line and no `BADSIG`, `EXPSIG`, `EXPKEYSIG` or `REVKEYSIG` line". What the docs and scripts say: the upstream book's check also fails on any `ERRSIG`, and the scripts refuse every `ERRSIG` except code 9 (a key not in the keyring). Where: tn-main docs/src/getting-started/installing-a-release.md:82,94; this repo lib/common.sh:6592-6620. Proposed fix: add "and no `ERRSIG` line other than one for a key that is not in the keyring" (OPERATOR.md 4.10 and README.md too).
- D7 imprecise: the `worker is inactive` / `worker is no longer active in this epoch; submit to an active worker` row has no release label. What the code says: neither string exists at the tag (2635e26a #1654 and later). The next row says "From the next release", and this row should too. Both refusals also apply to `eth_sendRawTransactionSync`. Where: crates/tn-reth/src/worker.rs:174-178; crates/tn-reth/src/rpc_fee_cap.rs:180-188 and its submit handlers (~204-222); `git grep 'is inactive' v0.16.0-adiri -- crates/tn-reth` is empty. Proposed fix: begin the cause "From the next release," and name both submit methods.
- D8 imprecise (minor): "on `v0.16.0-adiri` the line ends `; initiating node shutdown: <error>`" with "could not write a vote or certificate durably ... On `v0.16.0-adiri` it stops only its consensus tasks and keeps running". What the code says: at the tag only the three vote lines carry that ending and keep the node running. The certificate lines end `unable to save the certificate: <e>` or `refusing to externalize: <e>` and return a critical-task error. Where: tag crates/consensus/primary/src/network/handler.rs:623,1124,1162; tag crates/consensus/primary/src/certifier.rs:524,566; tag run_epoch.rs:476-493. Proposed fix: "on `v0.16.0-adiri` a failed vote write ends `; initiating node shutdown: <error>`".
- D9 imprecise (minor): "and, on a bare-metal validator, turning off CPU and NVMe power saving". What the book says: its Operating system list applies to every node, and power saving reads "On bare metal". Where: tn-main docs/src/getting-started/hardware-requirements.md:400-408. Proposed fix: "and, on bare metal, turning off CPU and NVMe power saving" (OPERATOR.md "For a validator host" likewise).

Nits, not counted as defects: `copied <n> rows ...` is logged only when n > 0 (lib.rs:324-326). "The old database stays untouched" is not strictly true: before the copy the migration may delete one seconds-only `LastProposed` row from MDBX (lib.rs:280-284). The S2 log is stale on the `v0.17.0-adiri` plan wording (the file has the allowed form). OPERATOR.md keeps the `/var/lib/telcoin.pre-v0.16` example name.

## Confirmed

- book recommends ext4/xfs, unlimited AS, power saving: hardware-requirements.md:406-408
- fallocate growth, full disk fails a write, fallbacks, btrfs/ZFS: data_file.rs:20-30,1523-1545 (tag :19-22,:678-689)
- scripts do not check filesystem/power: setup-node.sh:319-336 lists fstype only; no governor/nvme check (grep)
- no ulimit -v / LimitAS advice: hardware-requirements.md:407; unit/docker set none: lib/common.sh:3283,3355-3415
- performance governor / nvme_core param / cloud cannot: hardware-requirements.md:408
- ports row 43174 (every interface on the tag, loopback from the next release for a bare port): tag health.rs:181; health.rs:86-101
- Docker row "planned to start with v0.17.0-adiri": allowed (installing-a-release.md:71; maintainers/releasing.md:8)
- release notes page contents: release-notes.md:8
- v0.16 -> next one-way bullet, snapshot whether or not asked, decline rollback: lib.rs:229-237; update-node.sh:134,963-983
- `gpgv --status-fd 1`: installing-a-release.md:81
- Good signature/exit 0 on expired/revoked: installing-a-release.md:94; orchestrator 8b test
- epoch/kad/cache on the tag (epoch in progress, own votes/proposals, peers, caches): tag lib.rs:186-205; lib.rs:114-136
- tndb/{epoch,kad,cache}, copy, delete, marker: tndb/mod.rs:34; split.rs:46,50; lib.rs:239-327,336-351; Cargo.toml:67
- One-way item 1 (packs under epochs migrated by v0.16): tag consensus_pack.rs:60 PACK_VERSION 2
- One-way item 2 (copy then delete; v0.16 not refused, empty epoch tables, can equivocate): lib.rs:233-237,268-320; tndb/README.md:634-637 (not refused: no tndb awareness at the tag, pack version unchanged consensus_pack.rs:82; not run)
- never run v0.16 again on a committee node without the snapshot: lib.rs:233-237
- `copied <n> rows of the consensus DB from MDBX to tndb`: lib.rs:324-326
- `Cannot migrate the consensus DB from MDBX`, retry copies again: lib.rs:229-233,380-405,432
- decline rollback, only the snapshot undoes it: lib.rs:233-237
- Testnet add-ons: bare `--healthcheck 43174`: setup-observability.sh:67,70; lib/common.sh:8254
- tag every interface + ufw rule: tag health.rs:181; lib/common.sh:8120-8139
- next release 127.0.0.1: health.rs:86-101
- scripts probe 127.0.0.1: check-node.sh:925; setup-observability.sh:371
- address form 0.0.0.0:43174 / <addr>:43174: health.rs:121-128; cli node.rs:149-150
- tag refuses the address form: tag cli node.rs:124-125 (Option<u16>)
- failed bind stops start (system error) + WARN `listener bound on every interface`: node.rs:921-928; health.rs:251; main.rs:13-17; tn-metrics exposure.rs:57-68
- worker-inactive strings and -32000: worker.rs:174-178; rpc_fee_cap.rs:180-188 (label: D7)
- -32603 `validator is inactive; retry another endpoint`, both methods, /health/workers: rpc_fee_cap.rs:50-78; engine/readiness.rs:44; jsonrpsee-types 0.26.0 error.rs:129
- downgrade row addition: lib.rs:233-237
- `Cannot migrate ...: Cannot check database (epoch)` takes the mv remedy: lib.rs:268-273,283-284,432
- do not remove tndb/epoch; refused beside the marker: split.rs:55-97; lib.rs:409; epoch_db_recovery.rs:139,207-225
- systemd every 10 s, start-limit-hit: lib/common.sh:3364-3365,3378-3379,3399-3400,3412-3413
- durability line at main and exit 1: handler.rs:621,1122,1161; certifier.rs:533,561,606; run_epoch.rs:627-630,1150-1165; lib.rs(node):89-99; main.rs:13-17; tndb/store.rs:707
- refused to send rather than sign twice: handler.rs:1155-1163; certifier.rs:600-609
- drive check, reset-failed: unit as above
- tag restart-at-once advice: tag handler.rs:1162; tag run_epoch.rs:476-535

## Open points

(a) At `v0.16.0-adiri` there is no start-up check and no `Cannot check database (epoch)` line. epoch_db_recovery.rs does not exist at the tag; it was added by 98849a22 (#1572), 3 commits later. A bad epoch row panics `Invalid bytes!` in the typed decode (tag codec.rs:66-67) and the node crash-loops. Moving `consensus-db/epoch` aside would clear it, but the guide's line-keyed remedy never matches on the tag. At 7167e7800, a tndb node prints `Cannot check database (epoch): epoch table ... Remove the epoch database directory `consensus-db/tndb/epoch` ...` (lib.rs:436; epoch_db_recovery.rs:139,207-225). The first tndb start prints `Cannot migrate the consensus DB from MDBX: Cannot check database (epoch) ...` naming `consensus-db/epoch` (lib.rs:283-284,432; test epoch_db_recovery.rs:652-655), and there the mv remedy works. Removing `consensus-db/tndb/epoch` beside `mdbx-migrated` is refused at the next start, so the claim is true: a missing directory or one without a manifest gives `Cannot open database (tndb): tndb: environment ... is missing beside ... refusing to open it empty` (tndb/split.rs:55-97,128-131; lib.rs:409).
(b) At the tag the vote lines end `; initiating node shutdown: {e}`, notify the consensus shutdown, and the epoch re-enters as ModeChange, so the process keeps running (tag handler.rs:623,1124,1162; tag run_epoch.rs:476-535). The tag's certificate lines lack that ending (tag certifier.rs:524,566). At 7167e7800 all six lines end `; ending the epoch (the node stops if its stores cannot write): {e}` (handler.rs:621,1122,1161; certifier.rs:533,561,606). The epoch then ends, `ensure_stores_durable` fails (run_epoch.rs:627-630,1150-1165) and main exits with status 1 (bin/telcoin-network/src/main.rs:13-17; cli.rs:186-213). The unit matches the guide: Restart=on-failure, RestartSec=10, StartLimitIntervalSec=60, StartLimitBurst=5 (lib/common.sh:3364-3379,3399-3413), so systemd restarts it after 10 s and `start-limit-hit` follows five failed starts in 60 s.
(c) At the tag a bare `--healthcheck <port>` binds `0.0.0.0` (tag health.rs:181). The flag is `Option<u16>`, so `addr:port` is refused at parse (tag cli node.rs:124-125), and a failed bind is ignored (`let _ =`, tag manager/node.rs:906). At 7167e7800 a bare port binds `127.0.0.1` (health.rs:86-101) and `addr:port` is accepted (health.rs:121-128). A failed bind fails start-up (manager/node.rs:921-928) and the process exits with status 1. A wildcard bind logs WARN `listener bound on every interface; every host that can reach this machine can read it. ...` (tn-metrics/src/exposure.rs:57-68).
(d) The code is -32603, `jsonrpsee::types::error::INTERNAL_ERROR_CODE` (jsonrpsee-types 0.26.0 src/error.rs:129; worktree Cargo.lock:5226-5227 pins 0.26.0). The message is `validator is inactive; retry another endpoint` (crates/tn-reth/src/rpc_fee_cap.rs:68-78), returned on both `eth_sendRawTransaction` and `eth_sendRawTransactionSync` while the mode is `CvvInactive` (rpc_fee_cap.rs:57-62). It is not at the tag.
(e) All the directories exist at their commits. At the tag: `consensus-db/epochs` (traits.rs:155-156) and `consensus-db/{epoch,kad,cache}` (tag lib.rs:186-190); `kad` and `cache` are MDBX envs. At 7167e7800: `consensus-db/tndb/{epoch,kad,cache}` (tndb/mod.rs:34; tndb/split.rs:46), `tndb/mdbx-migrated` (split.rs:50; written lib.rs:314-320) and `epochs` (traits.rs:155-156). The old MDBX dirs are deleted after the copy (lib.rs:336-351).
(f) Code: the fallocate growth and its fallback, with ext4/xfs named as "the supported filesystems" in the comment and the WARN (data_file.rs:20-30,1523-1545; at the tag too), and the 62 GiB reservation (store.rs:65, btree_index/index.rs:91, 14 tables lib.rs:114-136; main only, D4). Book recommendation only: putting the datadir on ext4/xfs, leaving the address-space limit unlimited (hardware-requirements.md:406-407) and turning power saving off on bare metal (:408; no code). The guide states all three as the book's advice ("The same page also recommends"), which is acceptable. Only D4's missing release scope and D9's "validator" narrowing need fixing.
