status: complete
completed sections: AGENTS.md, CHANGELOG.md, followup.md

# Checkpoint merge-A1

Rewritten after each section. See the brief in the agent prompt.

## Decisions not spelled out in the brief

- AGENTS.md: the container sentence and the `docker run ... --all` block now close the branch's
  "Rebuild with" bullet (where main had them); the sentence points at the reference-toolchain
  bullet instead of repeating the versions there.
- AGENTS.md: the container's toolchain (locally built Debian 12 image, pandoc 3.8.3,
  WeasyPrint 70.0, no committed Dockerfile) is one sentence inside the branch's
  "Reference toolchain" bullet, after the Homebrew/poppler sentences.
- AGENTS.md: the second conflict region was the branch's copy of the "AGENTS.md itself is
  intentionally untracked" paragraph displaced by main's new lint/CI/fixture sections; took
  main's side whole and applied the "partner documents and their build inputs" wording to
  main's copy of that paragraph (in "Self-update and integrity contract"), reflowed.
- CHANGELOG.md: main's two Unreleased entries first in main's order (Devnet Docker images, then
  Mainnet hardening round), then the branch's two in the branch's order (Partner guide 1.4,
  then Partner documents). No new entry written.
- followup.md: took main's side of all three regions (the HEAD sides were base items main had
  rewritten, plus the branch's additions), then re-added the branch's items: (a) at the end of
  "### update-node" under "## Scripts", (b) at the end of "## UI", (d) as three bullets at the
  end of "## Tooling and docs" (main folded "Docs in this repo" into it).
- followup.md (a): the cited line number is now 1080, where the "Not rolled back: the previous
  release cannot open the migrated data dir" message sits in main's update-node.sh (was 476).
- followup.md (c): main already carries the theme.css `td code { overflow-wrap }` item; kept main's
  bullet and changed only its path to `docs/partner/mno-node-guide/theme.css` (the branch's change).
  Not duplicated. Note: `docs/partner/technical-specification/theme.css:304` carries the same rule;
  the item still names only the guide, as the branch did.
- followup.md: the re-added bullets keep their `(guide-1.4)` tag and `Why:` line, although main's
  rewrite uses neither on its own bullets.
- None of the branch's four items duplicated an item in main's rewrite except (c).
- Final check: `grep -nE '^(<<<<<<<|=======|>>>>>>>)' AGENTS.md CHANGELOG.md followup.md` prints
  nothing (rc 1). No git state changed.
