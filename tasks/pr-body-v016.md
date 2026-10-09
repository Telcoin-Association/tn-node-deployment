## Summary

Operator-side changes for the adiri move to **v0.16.0-adiri** (telcoin-network `d72cc2bc`, image `us-docker.pkg.dev/telcoin-network/tn-public/adiri:v0.16.0-adiri`, linux/amd64, index digest `sha256:b905b0982e87d5ca608e2f29192d0c5582793ae0043630074cddb9be1162ffea`; git tag pushed, peels to d72cc2bc).

v0.16's first start migrates `consensus-db/epochs` one way (pack v1 → v2) and v0.15 cannot reopen it, so the public updater must stop auto-rolling the binary back across that line.

- **update-node 1.2.1**: an apply from < 0.16.0 (or an unreadable running release) to ≥ 0.16.0 (or a branch/commit) is one-way. It warns before the stop, checks free space against twice the largest `epoch-N`, asks for a snapshot in interactive mode, waits 600 s for the first start unless `TN_UPDATE_VERIFY_TIMEOUT` is numeric (leading zero no longer read as octal), and never rolls back on failure: node left as it is, pending state cleared, version marker kept, restore steps printed. `--json`: the failed `done` is `{"ok":false,"phase":"apply","rolled_back":false,"storage_migration":true,…}` (also when the apply is cut short after the new release started); `--check` gains `"storage_migration"`; both prepare paths emit the one-way `warn`. Non-migrating updates keep the 45 s window and the rollback.
- **common 1.6.1 / ui 1.9.1 / update-scripts 1.1.72**: default and fallback image pins → v0.16.0-adiri; sidecars refreshed (exactly five changed).
- **Docs**: README changelog + baseline entry, OPERATOR.md (snapshot guidance, `storage_migration`, three troubleshooting rows), partner guide 1.2 (+PDF), CHANGELOG, AGENTS.md (one-way contract), followup.md.
- **tasks/**: spec, designs, checkpoints, observer notice draft.

## Verification

- Implementer harness: 174/174 (bash 5.3.9 and bash 3.2.57 in a container).
- Independent verifier (own harness, written before reading the implementer's): 334/334 on bash 5, 342/342 on bash 3.2, each case also run against `lib/common.sh` from df82deb (COMMON 1.6.0) for skew. Verdict "ship after LOW fixes"; the four fixes (octal timeout, `du` field split on paths with spaces, exit-trap `done` fields, "not running" wording) are applied, with the exit-trap field gated on the new release having started.
- `bash -n`, `tools/check-bash32.sh`, `bash:3.2 bash -n`, shellcheck (findings identical to df82deb), `ui/test_*.py` 135 OK (python:3.10-slim), `ui/tests/helper_test.sh` 205/205 under bash 5 and 3.2, `gen-checksums.sh` idempotent.
- PDF rebuilt with pandoc 3.8.3 + WeasyPrint 70.0 (container; the reference toolchain is pandoc 3.11 on the Mac, so a Mac rebuild may differ byte for byte). 46 pages; lint clean.

## Interface contract with the fleet driver (adiri-genesis)

`--check` → `"storage_migration":<bool>`; failed one-way apply → `error` then exactly one `done` with `rolled_back:false, storage_migration:true`, node left running; `TN_UPDATE_VERIFY_TIMEOUT` numeric = explicit. Phase 0 of the fleet roll requires `SCRIPT_VERSION ≥ 1.2.1` on followers, which they pull from `main`: **the fleet roll waits for this merge** (+ ~5 min raw CDN).

## Follow-ups recorded (followup.md)

Interactive "Prepare only" gives no one-way warning; the UI status card does not show `storage_migration`; a one-way apply killed after its restart makes a second apply back up the new binary; `--http.api` lists without `tn` break the health check; `db migrate` could move the migration out of the health window.
