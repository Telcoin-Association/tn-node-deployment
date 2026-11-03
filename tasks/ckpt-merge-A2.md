status: complete
completed sections:
- OPERATOR.md (both conflict regions resolved; all 12 branch hunks verified present; file = main + exactly the branch's hunks)
- README.md (4 branch hunks verified; one misplaced paragraph moved; file = main + exactly the branch's hunks)

# Checkpoint merge-A2

Rewritten after each section. See the brief in the agent prompt.

Judgment calls:
- OPERATOR.md region 1 (~L390): kept the branch's four-line network-config paragraph at the end of 2.7 "Optional node flags", then main's new "### 2.8 Passphrase, logs and other setup flags" section unchanged after it.
- OPERATOR.md region 2 (~L573): main's rewritten "If the health check fails ..." and "To go back ..." lines kept verbatim; the branch's two `Cannot check database (epoch)` / `consensus-db/epoch` lines inserted between them (their original position in the branch).
- OPERATOR.md: section references in branch hunks (1.1, 1.3, 3, 4.2, 6.8, 9) still point at the same headings in main's numbering (main only added 2.8 and 4.9-4.11). Contact stays support@telcoin.org; no devs@ in the file.
- README.md: git auto-merge put the branch's "A committee node that is stopped while the epoch changes anyway ..." paragraph at the end of main's new "## Backups and the update lock" section. Moved it back to directly after the epoch-wait "Pass a variable through sudo ..." paragraph, before main's "### The quorum check", where the branch had it (after the wait text).
- README.md: the branch's docs-maintenance paragraph names `build-partner-pdf.sh mno-node-guide` and `technical-specification` but never `--all`; left as the branch wrote it (not an auto-merge error).
