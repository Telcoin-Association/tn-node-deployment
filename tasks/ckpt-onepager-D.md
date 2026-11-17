status: done

Unit D checkpoint: docs that list the node requirements one-pagers.

Completed sections:
- read spec 1-6, script diff, and the four target files
- D1 AGENTS.md: intro (one-pagers named, "and the one-pagers where they repeat it, then
  rebuild the PDFs"); Partner documents: two directory bullets, metadata `badge`, Geist for
  the one-pagers, "every PDF", four one-pager rule bullets (one page / toc-depth 0;
  byte-identical template+theme with cmp, badge; guide is source of truth; mainnet "set at
  launch" + nothing that moves per release), legacy lint and contact bullets cover the
  one-pagers, numbering sentence covers toc-depth 0 to 3
- D2 README.md: line 9 "Start with the short version" sentence linking both one-pager PDFs;
  maintenance paragraph "--all builds every document" + carry facts into both one-pagers,
  pointer to "Partner documents" in AGENTS.md
- D3 docs/partner/assets/README.md: intro "Every partner document" + one-pagers named; Geist
  for guide and one-pagers; covers bullet says no cover/raster for one-pagers; logo bullets
  name network-light in the header band and association-dark in the footer strip
- D4 CHANGELOG.md: new first ### under ## Unreleased, "Node requirements one-pagers 1.0,
  November 2026 -- ...", one paragraph, no node facts, follows guide 1.9

- D5 checks:
  a. git diff --stat: AGENTS.md, CHANGELOG.md, README.md, docs/partner/assets/README.md, plus
     tasks/plan.md (orchestrator's, untouched by D)
  b. links: testnet dir/.md/.pdf exist; mainnet dir/.md/.pdf not yet (unit M), all named in
     the brief; AGENTS.md, assets README and both logos exist
  c. the literal command lists 5 lines of docs/partner/assets/README.md only because the file
     path contains "partner"; all are about licence files, font families or logos. Per-file
     grep -h on content: no hits. No "either document", "both PDFs", "both documents" left.
  d. 6 fixtures name the files (p2p_reason_text, install, cut_release, release_scripts,
     updater_manifest, network_hits); all write synthetic copies in temp dirs or mention the
     file in a comment; none pins a real line, so none was run
  e. em dashes added: 0

Remaining: none
