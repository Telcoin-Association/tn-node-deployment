status: complete
agent: C4 (docs editor: CHANGELOG.md, AGENTS.md, docs/testnet-addons.md)

## Completed sections
- Section 3 docs/testnet-addons.md: 2 occurrences (intro paragraph opt-in sentence; 'During node setup' quickstart) -> `setup-node.sh`. No deprecated-shim sentence existed; Sync note untouched (no setup-script mention there).
- Section 2 AGENTS.md: OPERATOR.md pointer paragraph at end of 'What this repo is'; new '## Node role' section after boundary rule; untracked-docs sentence appended to final paragraph (README probe verified).
- Section 1 CHANGELOG.md: added "### Operator runbook -- `OPERATOR.md`" entry above Dynamic node role; appended "Superseded in part: ..." sentence (4 lines) to end of Dynamic node role entry.

## Notes
- README probe verified: update-scripts.sh HEAD-probes "${GITHUB_RAW}/README.md" as its connectivity check.
- At edit time OPERATOR.md, followup.md absent on disk; node_stake_status/node_is_staked_validator absent from lib/common.sh; update-node.sh has no --observer stripping (still has --observer CLI flag). Presumably concurrent agents. Flag in report.
