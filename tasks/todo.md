# Release TN node scripts via `curl -fsSL https://install.telcoin.network | bash`

Approved plan. `main` stays the single source of truth; the vanity URL is only the
human-facing front door. Work is additive.

## Work items

- [x] 1. Publish workflow → GitHub Pages (`.github/workflows/publish-installer.yml`)
- [x] 2. Point docs/usage at the vanity URL (`install.sh` header, `README.md` Quick Start)
- [x] 3. Shell CI (`.github/workflows/ci.yml`): `bash -n` (Linux + macOS 3.2), shellcheck, checksum gate
- [x] 4. Activate `.sha256` integrity:
    - [x] `tools/gen-checksums.sh` (derives list from SCRIPTS + UI_BUNDLE + TESTNET_ADDONS_BUNDLE)
    - [x] portable `_sha256()` in `update-scripts.sh`; bump 1.1.58 → 1.1.59
    - [x] generate all 33 `*.sha256` sidecars (LAST, after all content edits)
- [x] 5. git-less macOS tarball fallback in `install.sh` (git optional; curl/wget + tar)
- [x] 6. Dual licence: `LICENSE-MIT` (Telcoin Association, 2026) + `LICENSE-APACHE`; README License section
- [x] 7. (surfaced by the new shellcheck gate) fix pre-existing SC2259 bug in `update-node.sh`

## Key findings from exploration

- All 19 tracked `*.sh` already pass `/bin/bash -n` under bash 3.2.57 → macOS CI leg safe to make blocking on the full set.
- All 33 updater-referenced files (17 SCRIPTS + 6 UI_BUNDLE + 10 TESTNET_ADDONS_BUNDLE) flow through the same checksum-checked download loop → all need sidecars.
- Stock macOS has `shasum` not `sha256sum` → portable helper required for the activated sidecars.
- `install.sh` is NOT in the updater arrays → editing it does not touch any sidecar. Only `update-scripts.sh` edits affect a sidecar (it's in SCRIPTS), so generate sidecars last.
- Checksum gate: use `git status --porcelain` empty (not `git diff --exit-code`) so NEW untracked sidecars are also caught.

## Ordering invariant

Make ALL content edits first (install.sh, update-scripts.sh incl. version bump), THEN run
`tools/gen-checksums.sh`, THEN the tree must be clean. Commit sidecars with the change.

## Review

**Done & verified locally (all four CI jobs green):**
- `parse-linux` (bash 5.x `-n`) and `parse-macos` (`/bin/bash` 3.2 `-n`) pass on all 20 `*.sh`.
- `shellcheck --severity=error` (blocking) passes; advisory `--severity=warning` shows only
  37 pre-existing nits (SC2034/2206/2115/1090) — my new code is clean at both levels.
- Checksum gate: 33 sidecars; regeneration is byte-identical → `git status` clean once committed.
- Both workflow YAMLs validate; `update-node.sh` Docker-tag parser proven to emit tags again.

**Scope note (item 7):** the shellcheck gate flagged a genuine pre-existing bug
(`fetch_docker_tags` heredoc-vs-pipe stdin clash, SC2259) that made Docker tag suggestion
always return empty. Per no-laziness, fixed it (payload via env var, not stdin) rather than
suppress; bumped `update-node.sh` 1.1.53 → 1.1.54 so the fix reaches operators; regenerated
its sidecar. Risk bounded by the function's existing `except: pass` fallback.

**Cannot be done from here (manual / requires deploy) — see plan's "One-time manual setup":**
1. DNS CNAME: `install` → `telcoin-association.github.io`.
2. Repo Settings → Pages: Source = GitHub Actions; custom domain `install.telcoin.network`; Enforce HTTPS.
3. (Recommended) verify `telcoin.network` at org level to prevent subdomain takeover.
4. End-to-end checks that need the live domain / clean VMs (curl 200, clean Linux clone,
   clean-Mac tarball path) — run after DNS + Pages are live.

**Not committed** — left in the working tree for review (no commit was requested).
The `.sha256` sidecars + all changes must be committed together (the gate enforces freshness).
