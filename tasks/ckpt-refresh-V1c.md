status: complete
completed sections: 1 (OPERATOR 0-4), 2 (OPERATOR 9 rows), 3 (README), 4 (cross-document agreement and off-main check), 5 (report)

# Verifier V1c: OPERATOR.md and README.md against 58665ac

Method: changed statements from `git diff 58665ac -- OPERATOR.md README.md`; each re-derived from
telcoin-network at 7167e7800 (worktree `scratchpad/tn-main`, "main") and at `v0.16.0-adiri`
("tag", via `git show v0.16.0-adiri:<path>`), and from this repo's working tree; then compared
with `tasks/ckpt-refresh-S3.md` and the facts parts F1-F3. Paths below without a repo prefix
are telcoin-network at main unless marked "tag"; `update-node.sh`, `lib/common.sh`, `ui/...`,
`check-node.sh`, `setup-observability.sh`, `tools/...` are this repo.

## Verdict

- Statements checked: 52 (OPERATOR 42, README 10)
- Confirmed: 43
- Defects: 7 (1 wrong, 6 imprecise), touching 9 statements

## Defects

- D1 wrong — OPERATOR 9, `Cannot check database (epoch)` row: "Each start checks the epoch database, which holds only the epoch in progress: `consensus-db/epoch` on `v0.16.0-adiri`, `consensus-db/tndb/epoch` from the next release." and "On `v0.16.0-adiri`, and on the first start of the next release (...), stop the node ... and move `/var/lib/telcoin/consensus-db/epoch` out of the data dir". `v0.16.0-adiri` has no such check and never prints `Cannot check database (epoch)`: `crates/storage/src/epoch_db_recovery.rs` was added by 98849a22 (#1572), which is not an ancestor of the tag (`git merge-base --is-ancestor 98849a22 v0.16.0-adiri` fails; `git grep "Cannot check database" v0.16.0-adiri -- crates` finds nothing). On main the check runs on the MDBX source inside the migration (lib.rs:277-278, 432) and on tndb on every open (lib.rs:436; epoch_db_recovery.rs:139, :204-225). The guide's twin row (mno-node-guide.md:1512) and the facts file's decision 2 carry the same premise; the unchanged OPERATOR 4.2 lines "A node whose epoch database fails its start-up check stops with `Cannot check database (epoch)` ... That fix touches `consensus-db/epoch`" (in the `v0.16.0-adiri` one-way context) inherit it. Fix: drop "on `v0.16.0-adiri`" from the cause and the remedy and say the check comes with the next release (move `consensus-db/epoch` aside only when the line follows `Cannot migrate the consensus DB from MDBX:`; never remove `consensus-db/tndb/epoch` on a migrated node), and fix the guide row and the 4.2 pointer the same way.
- D2 imprecise (safety-relevant) — OPERATOR 4.2 tndb bullet: "until then it treats that update as an ordinary one, ... and offers its usual rollback after a failed check. ... On a committee node, decline that rollback"; README Updating the node: "(... the usual rollback after a failed check) ... on a committee node do not take the rollback". Only a terminal run offers it (`confirm "Roll back to previous binary?"` / `"... image (...)?"`, default N: update-node.sh:2220, :1715; lib/common.sh:141-156). A `--json` apply, which the Node Manager UI runs, rolls back without asking (update-node.sh:3086-3109 binary, :3186-3198 image), and `TN_ASSUME_YES=true` makes `confirm` answer yes (lib/common.sh:146-148). OPERATOR 4.5 and README Web UI say nothing of it; the guide's "the script offers to roll a committee node back ... decline" has the same gap. Fix: add "a `--json` apply, the Node Manager UI's, rolls back without asking, so update a committee node to that release from a terminal and answer no".
- D3 imprecise — OPERATOR 9, `worker is inactive` row: "`eth_sendRawTransaction` returns error `-32000` `worker is inactive` or `worker is no longer active in this epoch; submit to an active worker`" with no release wording. Neither message is on the tag: `worker is inactive` (crates/tn-reth/src/worker.rs:177) came with 361f4b0c (#1647) and the second (crates/tn-reth/src/rpc_fee_cap.rs:181-186) with 2635e26a (#1654), both after `v0.16.0-adiri` (`git grep "is inactive\|no longer active" v0.16.0-adiri -- crates` has no RPC hit). Fix: mark the row "(from the next release)" as the `-32603` row is.
- D4 imprecise — OPERATOR 2.7: "Six of the keys it accepts are opt-in, `process_budget`, `source_admission`, `trusted_nodes`, `committee_peers`, `admission` and `serve_budget` ..." with no release wording. The tag's `NetworkConfig` has none of the six (tag crates/config/src/network.rs:17-46: libp2p_config, sync_config, quic_config, peer_config, peer_readiness_timeout, hostname, bootstrap_peers, endpoints; no `deny_unknown_fields`, so the tag ignores them); they arrive with 6a9310b8, 5ccb88e8, d2a0b525 and others, all after the tag (main network.rs:26-75). Names and defaults are right (network.rs:469-492, network_budget.rs:133-150). The guide's "Six of the keys it accepts" has the same gap. Fix: "From the next release the node accepts six opt-in keys ...; `v0.16.0-adiri` ignores them."
- D5 imprecise — OPERATOR 1.1: "The consensus database reserves about 62 GiB of address space (16 GiB for each of its three logs, 1 GiB for each of its 14 table indexes) ... Under a limit the node logs `MmapDataFile: could not reserve <n> bytes of address space ...`". Numbers right (tndb/store.rs:65, archive/btree_index/index.rs:91, lib.rs:106-130 = 14 tables, archive/data_file.rs:1058), but it is tndb, main only: the tag's consensus DB is MDBX (tag lib.rs:186-190) and the tag has no `could not reserve` message. The ext4/xfs bullet holds on both (`fallocate` is on the tag too, tag archive/data_file.rs:673-684). Guide 1.x twin ("The consensus database reserves about 62 GiB") has the same gap. Fix: start the sentence with "From the next release".
- D6 imprecise (low) — OPERATOR 2.4 row: "`epochs/` holds the consensus packs of finished epochs." The pack of the epoch in progress is written there too, as `epochs/epoch-N` (crates/config/src/traits.rs:155-156; crates/storage/src/consensus.rs:441, :796; outputs saved to the pack during the epoch, lib.rs:121-122). Guide layout row (mno-node-guide.md:344) says the same. Fix: "`epochs/` holds the consensus packs, one `epoch-N` directory per epoch, the one in progress included."
- D7 imprecise (low) — OPERATOR 4.10: "`gpgv` must print a `GOODSIG` line, with its `VALIDSIG`, for a shipped key, and no `BADSIG`, `EXPSIG`, `EXPKEYSIG` or `REVKEYSIG` line ... The scripts refuse a release when any line reports `BADSIG` (by any key), `EXPKEYSIG`, `REVKEYSIG` or `EXPSIG`, or when no shipped key signed it."; README Node releases: "Go on only on a `GOODSIG` line and no `BADSIG`, `EXPSIG`, `EXPKEYSIG` or `REVKEYSIG` line". The scripts also refuse any `ERRSIG` other than a missing key (code 9) (lib/common.sh:6611-6617); upstream's block refuses every `ERRSIG` (installing-a-release.md:81-82, :94). The hand rule is laxer than the scripts' (the writer left it out on purpose, S3 "Left out"). Fix: add "and no `ERRSIG` except one for a key that is not shipped (`NO_PUBKEY`, `ERRSIG` code 9)" to both rules and to the scripts' sentence.

## Confirmed

OPERATOR
- 0 `CvvInactive` row, refuses new transactions from the next release — rpc_fee_cap.rs:56-61, :66-78; tag has no `validator is inactive`
- 1.1 "the page recommends three more settings" — docs/src/getting-started/hardware-requirements.md:406-408
- 1.1 ext4/xfs, `fallocate`, SIGBUS, btrfs/ZFS — hardware-requirements.md:406; archive/data_file.rs:1523-1545 (tag :673-684)
- 1.1 unit has no `LimitAS=` — lib/common.sh:3360-3420 (both unit templates); Docker run has no `--ulimit as` (lib/common.sh:3283)
- 1.1 power-saving bullet — hardware-requirements.md:408
- 1.1 scripts check neither filesystem nor power — grep: only a dm-crypt check, lib/common.sh:6021-6029
- 1.3 43174 row, all interfaces on the tag, loopback from the next release — tag health.rs:181; health.rs:85-101; lib/common.sh:8254
- 2.3 Docker row "planned as `v0.17.0-adiri`" — newest tag `v0.16.0-adiri`; docs/src/maintainers/releasing.md:8, installing-a-release.md:71
- 2.4 tag MDBX `epoch/`, `kad/`, `cache/`; main `tndb/epoch|kad|cache` — tag lib.rs:186-190; tndb/mod.rs:34, tndb/split.rs:46
- 2.7 defaults: first four unset, `admission` Open, `serve_budget` unbounded — network.rs:36-46, :469-492; network_budget.rs:133-150
- 4.2 existing-install pointer to `--version` lines — OPERATOR 4.10
- 4.2 printed `gpgv` line lacks `--status-fd 1`; `Good signature from`, rc 0 on a revoked or expired key — update-node.sh:285, :300; local gpg 2.4.8 test (revoked key) and the orchestrator's (expired key)
- 4.2 tndb migration copies epoch tables, kad, both batch caches; deletes MDBX once durable — lib.rs:208-236, :272-310
- 4.2 tag starts on the migrated dir with empty epoch tables and can equivocate — lib.rs:232-236, :253-263 (upstream's own statement; pack format unchanged, consensus_pack.rs:82 = tag :60)
- 4.2 script treats the next release's update as ordinary — update-node.sh:134 (`STORAGE_MIGRATION_FLOOR="0.16.0"`), :968-984 (rc 1 for 0.16.0 -> 0.17.0), :1020-1035
- 4.2 do not use `--allow-downgrade` (testnet, interactive only; no storage warning above the floor) — update-node.sh:1789-1798, :3347-3348
- 4.2 `copied <n> rows ...` when any copied; marker `consensus-db/tndb/mdbx-migrated` — lib.rs:316-326; tndb/split.rs:50
- 4.2 `Cannot migrate the consensus DB from MDBX`: MDBX kept until durable; next start copies again — lib.rs:227-232, :296-310, :432 (edge: a failure while deleting after the durable copy leaves some envs deleted; the next start handles it, lib.rs:229-232)
- 4.2 after migration epoch DB is `tndb/epoch`; do not move it — epoch_db_recovery.rs:139; tndb/split.rs:67-95, :131
- 4.5 UI warning only across `v0.16.0-adiri`; no snapshot question in Apply — update-node.sh:1020-1035 (`warn` event, return before `confirm` in JSON mode), :2922, :2948
- 4.6 add-on writes bare `--healthcheck 43174` — setup-observability.sh:67, :70; lib/common.sh:7746, :8254
- 4.6 tag binds every interface — tag health.rs:181
- 4.6 next release loopback; host probes reach it — health.rs:85-101; check-node.sh:925, setup-observability.sh:371, ui/telcoin-ui-helper.sh:1432; Docker `--network=host` lib/common.sh:3283
- 4.6 `0.0.0.0:43174` WARN `listener bound on every interface`; `<address>:43174` — tn-metrics/src/exposure.rs:28-35, :57-68; health.rs:119-127
- 4.6 tag rejects the address form — tag crates/telcoin-network-cli/src/node.rs:124-125 (`Option<u16>`)
- 4.6 failed bind stops start-up from the next release (tag ignores it) — manager/node.rs:920-928 (`?`); tag manager/node.rs:906 (`let _ =`)
- 4.10 no release page for `v0.16.0-adiri`; first signed release planned as `v0.17.0-adiri` — installing-a-release.md:71; releasing.md:8
- 4.10 block `gpgv --status-fd 1` — lib/common.sh:6651 (what the scripts run)
- 4.10 block `git rev-parse "refs/tags/$TAG^{commit}"` — release tags are signed annotated tags, etc/release.sh:595-607, :1730; same line in release.sh:1418
- 4.10 status lines, not `Good signature from` — local test (REVKEYSIG + VALIDSIG, no GOODSIG, rc 0); installing-a-release.md:94
- 4.10 tarball holds four files — release.sh check_release_files (`check_tarball`), unchanged fact
- 4.10 `--version`: `telcoin-network-cli Version: X.Y.Z`, `Commit SHA:` = tag commit, `Build Features:` `adiri` (maybe `faucet`) / empty — crates/telcoin-network-cli/src/version.rs:33-56, cli.rs:46; release.sh:1234-1270, :1421; installing-a-release.md:144-148
- 4.10 image binary `/usr/local/bin/telcoin`, same three lines — etc/Dockerfile:83; release.sh:1228, :1239, :1452
- 9 `-32603` `validator is inactive; retry another endpoint` (from the next release), both methods, `/health/workers` false, back on rejoin without restart — rpc_fee_cap.rs:56-61, :66-78, :140-147, :202-224; jsonrpsee-types-0.26.0 src/error.rs:129; health.rs:136-143; manager/node.rs:912-918
- 9 "No testnet release ..." planned wording — as 4.10
- 9 durable row: main line `; ending the epoch (the node stops if its stores cannot write)`, store latch, `... can no longer make writes durable; stopping the node`, exit 1, restart after 10 s, `start-limit-hit`; tag `; initiating node shutdown:` and consensus-only stop — certifier.rs:533, :561, :606; network/handler.rs:621, :1122, :1161; run_epoch.rs:472-474, :1146-1162, :1205-1211; bin/telcoin-network/src/main.rs:24-27; lib/common.sh:3400, :3412-3413; tag network/handler.rs:623, :1124, :1162

README
- Layout row `consensus-db/` (epochs/, MDBX on the tag, `tndb/` from the next release) — as OPERATOR 2.4
- Health: "on `v0.16.0-adiri` the endpoint binds on all interfaces" — tag health.rs:181
- Health: next-release paragraph, address forms, WARN, tag rejects address form, on-host probes — as OPERATOR 4.6; anchor `OPERATOR.md#46-testnet-add-ons` resolves
- Docker notes "planned as `v0.17.0-adiri`" — as OPERATOR 4.10
- Updating: tndb one-way bullet apart from the rollback clause (D2) — as OPERATOR 4.2; anchor `#42-update-the-node` resolves
- Updating, `existing`: printed `gpgv` lacks `--status-fd 1` — update-node.sh:300; anchor `#node-releases` resolves
- Node releases: `gpgv --status-fd 1` — as OPERATOR 4.10
- Node releases: `--version` lines; link `#410-verifying-a-release-by-hand` resolves — as OPERATOR 4.10
- Web UI: one-way warning only across `v0.16.0-adiri` — as OPERATOR 4.5
- Docs maintenance: `--all` builds both documents — tools/build-partner-pdf.sh:5, :40, :62, :107

## Cross-document agreement and off-main check

- OPERATOR and README agree on every changed fact (health bind, tndb paths, one-way note, `--version` rule, gpgv rule, UI warning).
- Guide twins agree on the facts and release wording: 43174 row, health paragraph (mno-node-guide.md:891-897), tndb layout, one-way note, `-32603` and worker rows, durable row, epoch-DB row. They share D1, D2, D3, D4, D5 and D6. The guide carries no `--version` rule.
- Wording difference, not a factual conflict: in the durable row the guide keeps "On `v0.16.0-adiri`, restart the node at once ...; the epoch wait protects nothing while the node cannot vote", while OPERATOR has "restart the node yourself once the cause is fixed". Both say restart; pick one wording.
- The spec agrees: `validator is inactive` (technical-specification.md:475), a removed lane keeps RPC open for reads, and a node with non-durable storage stops. It names no `-32603`, no paths and no health bind.
- Off-main: nothing describes staging 10-27 (#1747, #1752, #1738, #1749, #1698, #1721, #1744; no such commit in `v0.16.0-adiri..7167e7800`) or `--forward-txs`. Every `v0.17.0-adiri` reads "planned as". The newest tag is `v0.16.0-adiri`.
- Conventions: `devs@telcoin.org` appears 0 times in OPERATOR and README. Every OPERATOR "section N.N" reference resolves. README/OPERATOR anchors from OPERATOR, README and the guide resolve (script check, 0 unresolved). "legacy" count is unchanged (OPERATOR 20/20, README 39/39). `git diff --check` is clean.

## Open points

- (a) Confirmed. `--version` prints the long version (cli.rs:46; version.rs:33-56: `Version:`, `Commit SHA:`, `Build Timestamp:`, `Build Features:`, `Build Profile:`). clap prefixes the crate name, giving `telcoin-network-cli Version: X.Y.Z` (release.sh:1241). An `-adiri` tag builds with `FEATURES=adiri` (release.sh:268-269 -> Dockerfile:23, :51; bin/telcoin-network/Cargo.toml `adiri = ["telcoin-network-cli/adiri", ...]`), so `Build Features: adiri`. A mainnet tag has `FEATURES=` empty. "possibly with `faucet`" is upstream's tolerance (release.sh:1259-1262, installing-a-release.md:147); the cli crate has no `faucet` feature, so in practice it never shows. The image binary is `/usr/local/bin/telcoin` (etc/Dockerfile:83, release.sh:1228), and the tarball binary is byte-identical to it (release.sh check_release_files).
- (b) Release tags are signed annotated tags (release.sh:595-607 refuses lightweight tags; :1730 `git tag -s`), so `^{commit}` is needed. In release artifacts `Commit SHA` is the full sha: the image is built with `--build-arg GIT_SHA=$COMMIT` (release.sh:1803; `COMMIT` = `rev-parse "refs/tags/$tag^{commit}"`, :607) -> `ENV VERGEN_GIT_SHA` (Dockerfile:28-29), and vergen 8.3.2 takes a preset `VERGEN_GIT_SHA` as is (vergen-8.3.2 src/feature/git/cmd.rs:629-631). Without it, build.rs `git_sha(true)` emits a short sha (cmd.rs:632-636), so a local source build prints a short one. release.sh accepts a prefix of 7 or more (:1248-1252). "Equal" is right for a downloaded release.
- (c) Right. `STORAGE_MIGRATION_FLOOR="0.16.0"` (update-node.sh:134), so `storage_migrating_upgrade 0.16.0 0.17.0` returns 1 (:968-984): no one-way warning, no snapshot question, no 600 s window. A failed check gets the ordinary rollback: a `[y/N]` prompt in a terminal (:1715, :2220), automatic in `--json` (:3086-3109, :3186-3198), hence D2. `--allow-downgrade` is accepted only in an interactive run on testnet (:1794; refused with `--json`, :3347-3348). It lets an older release through with a warning, and adds the "cannot open the migrated data dir" warning only across the 0.16.0 floor (:1789-1798), so it would not warn on 0.17 -> 0.16. "Decline the rollback, do not use `--allow-downgrade`" is right for a terminal run.
- (d) Right, with a correction to the premise: the UI does not read `storage_migration` (no hit in ui/server.py or ui/static/index.html). It shows update-node's `warn` event from `storage_migration_begin` (update-node.sh:1020-1035, called by the JSON prepare paths :2922, :2948), which is gated by `storage_migrating_upgrade`, so only updates across the 0.16.0 floor warn.
- (e) Tag: `Option<u16>`, so `addr:port` fails argument parsing (tag cli node.rs:124-125). It binds `0.0.0.0` (tag health.rs:181), and a failed bind is ignored (tag manager/node.rs:906 `let _ =`). Main: a bare port binds `127.0.0.1`, an address binds exactly that address (health.rs:85-101, :119-127), a bind failure stops start-up (manager/node.rs:920-928), and a wildcard logs WARN `listener bound on every interface; ...` (exposure.rs:57-68). Scripts today write the bare port (`--healthcheck ${TN_KUMA_PORT}`, 43174: lib/common.sh:7746, :8254; setup-observability.sh:67, :70) and probe `127.0.0.1` (check-node.sh:925, setup-observability.sh:371, ui/telcoin-ui-helper.sh:1432).
- (f) Matches. The local test on gpg 2.4.8 with a revoked key: plain `gpgv` printed `Good signature from` and exited 0; with `--status-fd 1` it printed `REVKEYSIG` + `VALIDSIG`, no `GOODSIG`, and exited 0. The orchestrator's expired-key run gave `EXPKEYSIG` + `VALIDSIG`. The scripts run `gpgv --status-fd 1` (lib/common.sh:6651) and `_tn_gpg_status_verdict` (:6592-6643) accepts only a `GOODSIG` followed by a `VALIDSIG` whose primary fingerprint is allowlisted. It refuses on any `BADSIG`, `EXPKEYSIG`, `REVKEYSIG` or `EXPSIG`, and on an `ERRSIG` other than code 9; `NO_PUBKEY` and `ERRSIG` 9 only warn. OPERATOR 4.10's sentence about the scripts is true but omits the other-`ERRSIG` refusal (D7). update-node's own printed hand check (:285, :300) lacks `--status-fd 1`, as OPERATOR 4.2 and README now say.
- (g) `-32603` is right: `ensure_can_submit` returns `INTERNAL_ERROR_CODE` (crates/tn-reth/src/rpc_fee_cap.rs:70-77, not rpc_ext.rs), and jsonrpsee-types 0.26.0 (Cargo.lock:5226-5227) defines it as -32603 (src/error.rs:129).
