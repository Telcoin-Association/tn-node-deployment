status: done
task: PR 12 docs (devnet docker images, 2.0.1)
completed sections:
- recon: CHANGELOG.md style = "## Unreleased" > "### <round>, October 2026 -- <versions>" + #### subsections; followup.md has no closed-item convention (closed items removed) -> add dated "Closed in 2.0.1" line to U-4 item (lines 78-84); README stale "devnet has no image repository" on lines 751 + 1393; OPERATOR line 257; operator guide = OPERATOR.md
- CHANGELOG.md: 2.0.1 entry inserted under "## Unreleased", above the 2.0.0 round (heading "Devnet Docker images, October 2026 -- lib/common v2.0.1"; script versions deliberately not named: code agent's bumps unknown)
- followup.md: U-4 item, devnet image repo phrase removed from "Still open", dated "Closed in 2.0.1 (2026-10-30)" line added
- README.md: lines 751 (Docker notes) + 1393 (networks) devnet sentences replaced; OPERATOR.md: line 257 Docker row
- tasks/pr12-body.md: written (title, base, body; gate results to be filled by P0b)
pending: (none)
notes: followup.md:50-53 (no mainnet image repo) is stale vs lib/common (TN_MAINNET_IMAGE_REPO=ghcr) -> report only
