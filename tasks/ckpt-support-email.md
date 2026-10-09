status: done
task: A — contact address -> support@telcoin.org (plan.md Part 1)

completed sections:
- 1 OPERATOR.md: lines 94, 152, 549 substituted; §10 two bullets -> "Email support@telcoin.org for everything, validator onboarding, approval and hardware included."; appendix Contact row -> "| Contact | support@telcoin.org for everything | Two addresses, used for different things on different pages | Section 10. |"
- 2 README.md: lines 51, 112 substituted; changelog entries update-scripts v1.1.69 and setup-node v1.2.1 added above v1.1.68 (em-dash headings, matching existing style)
- 3 setup-node.sh: banner line 162 substituted, SCRIPT_VERSION 1.2.1; update-scripts.sh SCRIPT_VERSION 1.1.69; parse checks bash 3.2.57 OK, bash 5.3.15 OK
- 4 CHANGELOG.md: "### One contact address -- support@telcoin.org" added at top of Unreleased
- 5 gen-checksums: 34 sidecars generated; only setup-node.sh.sha256 and update-scripts.sh.sha256 changed

note: AGENTS.md shows modified in git diff (44 lines) — not touched by this task; another agent's edit.

- 6 final verification: grep grant@telcoin (excl .git, tasks) empty; git status lists only expected files plus AGENTS.md and docs/partner/ (other agents); nothing staged

remaining: none
