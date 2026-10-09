## Summary

This PR moves adiri to v0.16.0-adiri (telcoin-network `d72cc2bc`). The first start of v0.16 migrates the consensus store one way, so update-node must stop auto-rolling back across that line.

- update-node 1.2.1: one-way guard, no rollback across the migration
- common 1.6.1, ui 1.9.1, update-scripts 1.1.72: image pins move to v0.16.0-adiri
- Docs, including partner guide 1.2 and its PDF

Verification: two independent harnesses under bash 5 and 3.2, the bash 3.2 lint, shellcheck, the UI tests, and CI on this PR.

The fleet roll waits for this merge, because followers pull update-node from `main`.

Details: CHANGELOG/v0.16.0-adiri.md
