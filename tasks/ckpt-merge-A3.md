status: complete
completed sections: (1) conflict regions, (2) survival check, (3) contact sweep, (4) HTML build and heading-link check

# Checkpoint merge-A3

Rewritten after each section. See the brief in the agent prompt.

Judgment calls:
- R1 (Have these ready): kept main's new SSH-ranges bullet, then the validators bullet with the branch's devs@telcoin.org.
- R2 (Optional node flags / Logs): both sides added at the same spot; kept the branch's network-config paragraph at the end of "Optional node flags", then main's new "### Logs" subsection after it.
- R3 (One-way updates): kept the branch's two `Cannot check database (epoch)` lines, then main's reworded "To go back" sentence (start script, binary, unit, node.env), which supersedes the base wording the branch still carried.
- Survival: all 20 branch hunks' added lines present verbatim, each in the same section as on the branch; no branch-removed line remains. All 306 main-added non-blank lines present verbatim; no main-removed line remains; heading lists identical to main's. Line count 1514 = base 1297 + branch 16 + main 201.
- Clock-drift lines (Hardware per role) still read true next to main's text: "The deployment scripts check neither" holds, main adds no time-sync check.
- Contact sweep: only 2 support@telcoin.org left after the merge (the branch sweep had already covered the base lines; both were in main-added troubleshooting rows on release signing); replaced with devs@telcoin.org. No mailto: links. Count now 0; devs@telcoin.org appears 16 times.
- Build: `tools/build-partner-pdf.sh mno-node-guide --html-only` in tn-pdf-tools, rc 0, pandoc 3.8.3; lint and internal-link check passed (120 links, 41 targets, all resolve); no metadata warning printed. HTML has 17 mailto:devs@telcoin.org, no support@.
- Structure: one `# ` title, no prose before the first `##`, no --observer / migrate-node-naming / setup-observer.sh / setup-validator.sh / legacy, no conflict markers.
- Not checked (out of scope): the README.md#... anchors the guide links to depend on the README merge.
