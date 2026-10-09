status: done

# DOC-A checkpoint: WP-A.6 docs for v0.16.0-adiri (tn-node-deployment, branch v0.16.0-adiri)

Edits docs only. Never commits. Code under verification; behaviour checked against the working tree.

## Sections
- [x] 1. README.md: changelog entries above update-scripts v1.1.70 (update-scripts v1.1.72, update-node v1.2.1, lib/common v1.6.1, telcoin-ui v1.9.1 [file's naming, not `common`/`ui`], testnet baseline → v0.16.0-adiri); body: check-node `--observer` bullet (:630), Docker fallback image (:723), Updating-the-node intro + new one-way bullet after the strip bullet (:883), request-limit defaults (:1165, verified identical via `docker run ... node --help` of the v0.16 image), `--http.api` paragraph (:1199, v0.16 default set adds `tn`; explicit list without `tn` drops tn_*; verified in telcoin-network d72cc2bc crates/tn-reth/src/cli.rs), Long-running actions (one-way warning at prepare, 10-minute health check). Floors left: :807, :824, :882, :1318, :1320; historical: :1609, :1618 and the 1845-2033 block
- [x] 2. OPERATOR.md: §0 roles (:53, v0.16 refuses `--observer`, exit 2); §2.3 fallback image (:243); §4.2 window bullet (600 on one-way, explicit number wins), rollback bullet ("except after a one-way update"), new one-way bullet, new snapshot paragraph with stop/cp -a/start + restore steps; §4.5 UI one-way bullet (warning at prepare, no snapshot question at Apply, 10 min); §7.1 IMAGE example (:1108); §7.3 update-node row (`storage_migration`); §8 legacy line (:1198); §9 `--observer` row (:1207) + new rows: one-way "Not rolled back", "Older release fails with `invalid version`", `telcoin.pid` lock; appendix workers row (:1284). Floors left: :329, :338, :469, :557, :558, :1226 (literal setup message)
- [x] 3. Partner guide: Install methods fallback image (:267); Update the node bullets (600 s window, explicit number wins, rollback except one-way, new one-way bullet); new `### One-way updates` section after Update the node (snapshot with node stopped, cp -a / disk snapshot, apply, watch journal, restore steps, `invalid version (should be 0)`; no `####` headings, no "legacy" log line quoted); scope list mentions one-way updates; UI bullet; Setup-without-prompts IMAGE example; Other scripts update-node row (`storage_migration`); troubleshooting rows (Not rolled back, `invalid version`, `telcoin.pid` lock). metadata.yaml version 1.1 -> 1.2, date 9 October 2026. Floors left: :351, :360, :569-570 area, literal message row in Setup and preflight
- [x] 4. PDF rebuilt in tn-pdf-tools: lint passed; "Wrote docs/partner/mno-node-guide.pdf (46 pages)" (was 44), "Done: pandoc 3.8.3, WeasyPrint 70.0"; second run "PDF unchanged". pdftotext: 6 lines with v0.16.0-adiri, cover "Version 1.2 · 9 October 2026", TOC has "One-way updates" (p. 19). Note: built with pandoc 3.8.3, not the reference 3.11
- [x] 5. CHANGELOG.md: `### v0.16.0-adiri round, October 2026 -- update-scripts v1.1.72` at the top of `## Unreleased` (#### One-way updates, Defaults, Docs), file's `--` heading style
- [x] 6. AGENTS.md: node-role paragraph (v0.16.0-adiri rejects `--observer` at parse time, exit 2; strip-floor line kept); new `## One-way storage migration (v0.16.0-adiri)` section before Staking helper (floor, running-release source, no OLD_REF, failure path, `storage_migration`, fleet driver depends on the names, do not re-add auto rollback). followup.md: updated keytool (:71), getValidator layout (:176), bootstrap-peers (:207) items with v0.16 facts (keytool `is_key_dir_empty` and the peers parser unchanged at d72cc2bc); none closed. New items: zero-padded TN_UPDATE_VERIFY_TIMEOUT read as octal (tested: 0600 -> 384 s, 0900 -> immediate failure); interactive prepare does not warn; `telcoin-network db migrate` offline option; UI status card lacks `storage_migration` / no snapshot question / 10-min tab risk; check-node does not warn about an explicit `--http.api` without `tn`
- [x] 7. Final pass. Docs diff: AGENTS.md +19/-?, CHANGELOG.md +29, OPERATOR.md 40, README.md 103, metadata.yaml 4, mno-node-guide.md 37, PDF 311786 -> 321249 bytes, followup.md 46. No code, sidecar, fixture or lib/wgvpn file touched by DOC-A. Post-review wording fix (from V-A ckpt §1 "left running even when the unit never started"): every doc now says a failed one-way check "does not stop the node" instead of "the node is left running", and the troubleshooting fix covers a node that stopped. Target wording aligned to "branch, commit or digest". PDF rebuilt after these edits.

## PDF build output
- `docker run ... tn-pdf-tools bash tools/build-partner-pdf.sh`: lint passed; "Wrote docs/partner/mno-node-guide.pdf (46 pages)"; "Done: pandoc 3.8.3, WeasyPrint 70.0"; second run "PDF unchanged: docs/partner/mno-node-guide.pdf (46 pages)". Previous committed PDF: 44 pages.
- pdftotext: 6 lines contain v0.16.0-adiri; 0 hits for "legacy"; cover reads "Version 1.2 · 9 October 2026"; TOC lists "One-way updates" (page 19).
- Toolchain caveat: built with pandoc 3.8.3 (container), not the reference pandoc 3.11 from Homebrew. A Mac rebuild may differ byte-wise; the script keeps the committed PDF on toolchain-only drift.

## Remaining v0.15.0-adiri mentions (docs, tasks/ excluded)
- AGENTS.md:49 intentional (v0.15 accepts --observer as no-op, v0.16 rejects)
- AGENTS.md:56 floor (strip threshold 0.15.0)
- OPERATOR.md:53 intentional (same contrast as AGENTS:49)
- OPERATOR.md:329 floor (--bootstrap-peers)
- OPERATOR.md:338 floor (--state-export-keep)
- OPERATOR.md:469 floor (strip threshold)
- OPERATOR.md:557 floor (bootstrap_peers edit)
- OPERATOR.md:558 floor (state_export N)
- OPERATOR.md:1198 floor (update-node strips when updating to v0.15.0-adiri or later)
- OPERATOR.md:1226 floor (literal setup error message)
- OPERATOR.md:1284 floor ("v0.15.0-adiri and later write" workers list)
- README.md:630 floor (strip threshold, second sentence)
- README.md:807 floor (state_export N)
- README.md:824 floor (bootstrap peers)
- README.md:882 floor (strip threshold)
- README.md:1165 intentional (defaults identical in both releases)
- README.md:1319 floor (--bootstrap-peers)
- README.md:1321 floor (--state-export-keep)
- README.md:1465 intentional (lib/common v1.6.1 entry: same tn-contracts pin)
- README.md:1479 intentional (baseline entry: contracts unchanged)
- README.md:1484 intentional (baseline entry: v0.15 cannot open migrated data dir)
- README.md:1496 floor (baseline entry: strip threshold)
- README.md:1700 historical (setup-node v1.3.0 entry)
- README.md:1709 historical (edit-config v1.3.0 entry)
- README.md:2001 historical (update-node v1.1.62 entry)
- README.md:2032 historical (telcoin-ui v1.8.8 entry)
- README.md:2052 historical (check-node v1.1.55 entry)
- README.md:2113 historical (lib/common v1.4.0 entry)
- README.md:2124 historical (lib/common v1.4.0 entry)
- docs/partner/mno-node-guide.md:351 floor (--bootstrap-peers)
- docs/partner/mno-node-guide.md:360 floor (--state-export-keep)
- docs/partner/mno-node-guide.md:590 floor (bootstrap_peers edit)
- docs/partner/mno-node-guide.md:591 floor (state_export N)
- docs/partner/mno-node-guide.md:1229 floor (literal setup error message)
- followup.md:71 intentional (keytool behaviour, both releases)
- followup.md:192 intentional (tn-contracts pin, both releases)
- followup.md:224 intentional (peers parser, both releases)
