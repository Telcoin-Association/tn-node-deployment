# V2 verifier: the V1a, V1b and V1c fixes

status: done
fixes checked: V1a D1 (x2), D2, D3, open point b; guide V1b D1-D10; guide X2 edits (2); OPERATOR/README V1c D1-D7, V1b D2 (with V1c D4), D8, D9; X3 edits (2)

Code read at telcoin-network 7167e7800 (worktree .../scratchpad/tn-main) and at tag `v0.16.0-adiri`
(d72cc2bcf); scripts from this working tree. Citations are worktree-relative for telcoin-network,
repo-relative here. "guide" = docs/partner/mno-node-guide/mno-node-guide.md, "spec" =
docs/partner/technical-specification/technical-specification.md.

## Verdict

- Fixes checked: 29 (spec 5, guide 12, OPERATOR/README 12: 10 fixer items, counting D2 and D4 once each across both files, plus 2 orchestrator edits).
- Resolved: 29.
- Still wrong: 0.
- New problems: 0 defects. 1 cross-document disagreement on advice (the guide's "email first" lead) and 1 wording nit (OPERATOR 4.5 / README Web UI "health check"), both listed below.

## Findings

Spec (V1a):
- spec, V1a D3: resolved; spec:11 "up to commit `7167e7800` (November 2026)".
- spec, V1a D2: resolved; spec:420, :452; crates/node/src/manager/node.rs:1966-1979 (`eligible` = record.epoch + 1 < local_epoch or next_committee contains the key; then record.epoch > local_epoch gives CvvInactive; a later record without the key gives Observer).
- spec, V1a D1 (Transport): resolved; spec:495 "accepts by default at most 128 ... an operator `process_budget` in the network configuration replaces both limits"; crates/network-libp2p/src/consensus.rs:216, :218-227, :348-359 (`budget.map_or` for the per-peer and total limits); crates/config/src/network.rs:37, :286-289.
- spec, V1a D1 (Peer scoring): resolved; spec:604 "each swarm's connection ceilings (see [Transport](#transport))"; heading spec:482.
- spec, V1a open point b: resolved; spec:475 "keeps the transactions it already holds until it can seal them again"; crates/tn-reth/src/txn_pool.rs:417-431, :993-1000 (only queued-lifetime, blob and unsupported removals); crates/node/src/manager/node/start_epoch.rs:1420-1424 (pools reused); run_epoch.rs:1078-1090 (edge: a non-member whose CvvInactive carried over forwards rather than seals; this does not make the sentence wrong).

Guide (V1b, X2):
- guide, V1b D1: resolved; guide:1512, :688, :694. Main: crates/storage/src/lib.rs:276-282 (`wrap_err("Cannot check database (epoch)")` on the MDBX source inside the migration), :432 (`expect("Cannot migrate the consensus DB from MDBX")`), :436 (`expect("Cannot check database (epoch)")` on every open); epoch_db_recovery.rs:139 (`consensus-db/tndb/epoch`), :209-225 (refusal text, names the directory), mdbx/database.rs:422 (`consensus-db/epoch`); tests epoch_db_recovery.rs:652-655, :761-763; tndb/split.rs:66-96 (a missing directory or one with no manifest beside `mdbx-migrated` is refused); lib.rs:316-322 (the marker is written on every first open, so every tndb node has it). Tag: crates/types/src/codec.rs:67 `expect("Invalid bytes!")`; layered_db.rs:511-518 (a full-memory open_table decodes every row); composite_db.rs:42; `git grep 'Cannot check database' v0.16.0-adiri` is empty; 98849a22 is not an ancestor of the tag.
- guide, V1b D2: resolved; guide:478 "They are unset by default, which means absent from the file, and no script sets them."; no script, UI or lib file names the keys.
- guide, V1b D3: resolved; guide:477; tag crates/config/src/network.rs:19-46 (`#[serde(default)]`, no `deny_unknown_fields`, none of the six fields); tag traits.rs:66-69 (plain `serde_yaml::from_str`); main network.rs:24-75.
- guide, V1b D4: resolved; guide:127; tndb/store.rs:65 (16 GiB per log, three logs), archive/btree_index/index.rs:91 (1 GiB), lib.rs:114-134 (14 tables); no `LimitAS` in lib/common.sh or setup-node.sh.
- guide, V1b D5: resolved; guide:344; crates/storage/src/consensus.rs:526-540 (current epoch's pack opened for append); config traits.rs:156; tag consensus.rs:463, :474.
- guide, V1b D6: resolved; guide:652 (every `ERRSIG` refuses, the same as upstream docs/src/getting-started/installing-a-release.md:82, :94).
- guide, V1b D7: resolved; guide:1455; crates/tn-reth/src/worker.rs:174-178, rpc_fee_cap.rs:180-188, :204-224 (both submit methods); worker.rs:73-89 (listeners stay bound for reads); the tag has neither text.
- guide, V1b D8: resolved; guide:1515; tag handler.rs:623, :1124, :1162 (vote lines end `; initiating node shutdown: {e}` and notify a consensus shutdown); tag certifier.rs:524, :566 (other endings, not quoted); tag run_epoch.rs:476-535 (ModeChange re-entry, the process keeps running); tag layered_db.rs:209-233, :635-645 (sticky `commit_failed` latch, so no later vote persists until a restart); main handler.rs:621, :1122, :1161, certifier.rs:533, :561, :606.
- guide, V1b D9: resolved; guide:124; docs/src/getting-started/hardware-requirements.md:400-408.
- guide, V1b D10: resolved; guide:633, :695-696; update-node.sh:1713-1715, :2218-2220 (prompts); lib/common.sh:141-155 (`confirm`: TN_ASSUME_YES=true answers yes, default N); update-node.sh:3084-3109, :3180-3198 (`--json` rolls back without asking); ui/telcoin-ui-helper.sh:922 (`--json --apply --yes`); update-node.sh:3322 (`--yes` sets only ASSUME_YES); :134 (floor 0.16.0); source and release share apply_source_update (:3440-3442, :3481-3483).
- guide, X2 edit (Update the node rollback bullet): resolved; guide:629; update-node.sh:1706-1715, :2203-2220.
- guide, X2 edit (Node Manager UI one-way bullet): resolved; guide:870; update-node.sh:1020-1037 (the warning fires only when `storage_migrating_upgrade` holds), :2922, :2948 (JSON prepare paths); [Update the node](#update-the-node) resolves (guide:599).

OPERATOR / README (V1c, V1b, X3):
- OPERATOR, V1c D1: resolved; OPERATOR:1536, :1537, :589-590, :595-596; same code as guide D1, plus lib.rs:411 (`Cannot open database (tndb)`) for the refusal it quotes. README has no such text.
- OPERATOR + README, V1c D2: resolved; OPERATOR:566, :784; README:931, :1158; same code as guide D10.
- OPERATOR, V1c D3: resolved; OPERATOR:1483; worker.rs:174-178; rpc_fee_cap.rs:180-188, :204-224.
- OPERATOR, V1c D4 + V1b D2: resolved; OPERATOR:400-401; crates/config/src/network_budget.rs:14-27 and source_admission.rs:10-27 (`deny_unknown_fields`, every field required, so `{}` fails with a missing field); serde_yaml 0.8.26 (Cargo.lock:11318-11319) src/de.rs:1319-1330 (`null` is invalid_type for a map, including the custom `deserialize_map` of `committee_peers`, network.rs:126-152); read_config network.rs:442-444, propagated with `?` at manager/node.rs:1014; tag network.rs:19-46.
- OPERATOR, V1c D5: resolved; OPERATOR:104; store.rs:65, index.rs:91, lib.rs:114-134; archive/data_file.rs:1058 (`MmapDataFile: could not reserve`), which the tag does not have.
- OPERATOR + README, V1c D6: resolved; OPERATOR:286, README:272; consensus.rs:526-540.
- OPERATOR + README, V1c D7: resolved; OPERATOR:891, README:1054 (hand rules refuse every `ERRSIG`); OPERATOR:891 (the scripts refuse "any `ERRSIG` other than code 9"); lib/common.sh:6610-6622 (`ERRSIG` with code 9 and a well-formed key id, or `NO_PUBKEY`, only warns; any other `ERRSIG` sets `bad`). Matches "any `ERRSIG` other than code 9". Edge case: code 9 with a malformed key id also refuses.
- OPERATOR, V1b D8: resolved; OPERATOR:1539; same tag and main lines as guide D8; run_epoch.rs:1150-1162, :1210 (`... can no longer make writes durable; stopping the node`).
- OPERATOR, V1b D9: resolved; OPERATOR:101 "The page recommends three more settings for every node:"; hardware-requirements.md:400-408.
- OPERATOR, X3 edit (4.2 general rollback bullet): resolved; OPERATOR:564; update-node.sh:1713-1715, :2218-2220, :3084-3109, :3180-3198.
- README, X3 edit (How updates are verified, item 2): resolved; README:1035 "any other `ERRSIG` (an error other than a missing key) refuses"; lib/common.sh:6610-6622.

## Cross-document

- `Cannot check database (epoch)` (guide:1512, :688, :694; OPERATOR:1536, :589-590, :595-596): the facts and the release wording agree. The check comes from the next release. On the first start the line is `Cannot migrate the consensus DB from MDBX: Cannot check database (epoch)` and names `consensus-db/epoch`, and the fix is to move it aside and keep `epochs` and `db`. On tndb it names `consensus-db/tndb/epoch`, which must not be removed (refused beside `mdbx-migrated`). `v0.16.0-adiri` has no check and panics `Invalid bytes!` on a damaged row. One difference in advice: guide:1512 starts its fix cell with "Email devs@telcoin.org with the journal lines first." for every form, the move-aside case included, while OPERATOR:1536 dropped that lead (X3 notes: "the orchestrator's new decision") and emails only in the tndb and tag cases (see Remaining defects). Also guide:1513 points `start-limit-hit` at the row "for `Cannot check database (epoch)`" only, while OPERATOR:1537 adds "or `Invalid bytes!`" (optional; the row above covers both).
- Durability barrier (guide:1515; OPERATOR:1539): agree. From the next release the line ends `; ending the epoch (the node stops if its stores cannot write): <error>` and the node exits with status 1. On `v0.16.0-adiri` a vote line ends `; initiating node shutdown: <error>` and the node keeps running, cannot vote until restarted, and should be restarted by hand.
- `validator is inactive` and worker rows (guide:1455-1456; OPERATOR:1483-1484; spec:466-475): agree on `-32000` `worker is inactive` / `worker is no longer active in this epoch; submit to an active worker`, `-32603` `validator is inactive; retry another endpoint`, and both `eth_sendRawTransaction` and `eth_sendRawTransactionSync`. The guide and OPERATOR mark both rows from the next release. The spec states no per-feature release anywhere: its edition line (spec:11) covers main at `7167e7800`. That is consistent.
- One-way tndb update and terminal-only advice (guide:629, :633, :694-696, :870; OPERATOR:564, :566, :784; README:931, :1158): agree. Apply from a terminal, without `TN_ASSUME_YES`, and decline the rollback. The UI's `--json` apply rolls back without asking, and that rollback starts `v0.16.0-adiri` on empty epoch tables. Snapshot first. The guide names the prompt texts. OPERATOR and README add "do not go back with `--allow-downgrade`", which the guide covers with "only the snapshot undoes this update". Wording nit: OPERATOR:784 "rolls back without asking when the health check fails" and README:1158 "rolls back without asking after a failed health check" are narrower than the code. The code also rolls back on a failed binary or image identity check and a failed participation check (update-node.sh:3062-3070, :3165-3174). The guide's "a failed check" is exact. The advice is unaffected.
- `network-config` keys (guide:477-478; OPERATOR:400-401): agree. Six keys from the next release, `v0.16.0-adiri` ignores them, unset means absent, and no script sets them. Only OPERATOR adds the `{}` / `null` error, which is correct.
- 62 GiB and `epochs/` (guide:127, :344; OPERATOR:104, :286; README:272): agree. 62 GiB from the next release. `epochs/` holds the finished epochs' packs and the in-progress pack, open for append, as `epoch-N`.
- gpgv rule (guide:652; OPERATOR:891; README:1054, :1035): agree. The hand rules refuse every `ERRSIG`. The scripts' rule (OPERATOR:891, README:1035) refuses every `ERRSIG` except code 9 / `NO_PUBKEY`, which only warn.
- Release wording: rewritten rows say "on `v0.16.0-adiri`" / "from the next release". `v0.17.0-adiri` appears only as "planned" (guide:294, :639; OPERATOR:266, :874, :1503; README:760).
- Contacts: guide `support@telcoin.org` 0; OPERATOR `devs@telcoin.org` 0; README `devs@telcoin.org` 0. Every `](#...)` heading link resolves in the guide, the spec, OPERATOR and README, and README's `OPERATOR.md#42-update-the-node` and `#410-verifying-a-release-by-hand` resolve too.
- Aside (outside the fixes): AGENTS.md's partner-guide rule says the guide's "only contact is `support@telcoin.org`", but tools/build-partner-pdf.sh:193 enforces `CONTACT="devs@telcoin.org"`, which the guide follows. AGENTS.md is stale there.

## Remaining defects

1. Cross-document advice (low). guide:1512, fix cell: "Email devs@telcoin.org with the journal lines first. When the line begins `Cannot migrate the consensus DB from MDBX` and names `consensus-db/epoch`, stop the node ... and move that directory out of the data directory". OPERATOR:1536 gives the same move-aside remedy with no email step, and asks for an email only in the tndb case ("Email support@telcoin.org with the journal lines instead") and the `v0.16.0-adiri` case. The code supports both readings: the refusal text tells the operator to remove the directory and start again once the epoch closes (crates/storage/src/epoch_db_recovery.rs:209-225). Fix: apply the orchestrator's latest decision to both files. Either drop "Email devs@telcoin.org with the journal lines first." from guide:1512 and add "email devs@telcoin.org with the journal lines" to its tndb and `v0.16.0-adiri` sentences, or put the lead back in OPERATOR:1536.
2. Nit (optional, not counted as a defect). OPERATOR:784 "which rolls back without asking when the health check fails" and README:1158 "rolls back without asking after a failed health check": the code rolls back after any failed post-update check (update-node.sh:3062-3070, :3165-3174). Fix: write "after a failed check", as the guide does.

## Orchestrator action on the remaining items

- Guide `Cannot check database (epoch)` row: the leading "Email devs@telcoin.org with the journal lines first." is dropped, so the guide and OPERATOR 9 ask for an email only in the tndb and `v0.16.0-adiri` cases (item 1).
- OPERATOR 4.5 and README Web UI: "after a failed check" (item 2; update-node.sh:3062-3070, 3165-3174).
- AGENTS.md: no `support@telcoin.org` mention exists in the merged file (the remark came from main's copy); nothing to change.
