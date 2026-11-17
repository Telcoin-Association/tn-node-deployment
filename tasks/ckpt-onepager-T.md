status: done (T1-T4 complete)

# Checkpoint: unit T, testnet node requirements one-pager

Directory: docs/partner/testnet-node-requirements/

## Completed sections

- T1 Layout: DONE. template.html, theme.css, metadata.yaml, placeholder .md; builds to 1 page,
  header band, full-width block, two columns and footer render.
  - Column method: CSS multi-column (column-count: 2, forced `break-before: column`), on a
    `<div class="columns">` wrapper inside main, not on main itself. Tested on main first:
    the forced column break works in WeasyPrint 70, but a `column-span: all` box (needed for the
    full-width hardware block) is laid out wider than its multi-column parent (it ran to the
    page's right edge, padding or margin on main made no difference). So the full-width block
    (`<div class="wide">`) sits outside the columns and the columns sit on the wrapper.
  - Markdown hooks (documented in theme.css header): `<div class="wide">`, `<div class="columns">`,
    `<div class="col-break"></div>` inside .columns.
  - Footer: `position: fixed; bottom: -12mm` inside `@page { margin: 0 0 12mm }`; WeasyPrint draws
    it in the bottom margin, body text cannot run under it (overflow goes to page 2, build fails).
- T2 Content: DONE. Real Markdown written, builds to 1 page. Sections and guide lines:
  - Hardware per role (full width): table 102-108, 113 (+ "avoid QLC" 109); notes 99-100, 114 (D2
    testnet wording verbatim), 119/122/124/126 (swap, time sync, ext4/xfs, scripts check none);
    IMPORTANT callout 117 (D4).
  - Network: 5, 7 (EVM L1, Narwhal and Bullshark, reth, JSON-RPC), 207 (chain ID, RPC,
    explorer), 230 (HTTPS only, no WebSocket), 997 (status page), 57 + 830 (six-hour epochs).
  - Operating system and host: 138, 146-147 (Debian 12 / Ubuntu 22.04 on testnet, 247+, below
    250 root-only file), 140 (BLS passphrase), 153 (macOS), 317 (x86_64 tarballs), 150 + 335 (TPM
    optional on testnet), 162 + 164 (CVE-2026-31431, https://copy.fail).
  - Ports: 171-179 (table), 181 + 187 (UDP on every node, every filtering layer).
  - Install: 252 + 255 (installer without sudo), 280 (setup), 310-313 (four methods), 269 (release
    tags only), 272 (tn-testnet image package), 267 (signed scripts, gpgv), 268 (same keys).
  - Roles and validating: 12-15, 79-82 (four steps), 1330 (1,000,000 TEL today, prepare-stake.sh),
    1494-1496 (E+3, 12 to 18 hours).
  - Contact: 48-49; guide PDF URL from spec section 7 (repo URL line 27 is in the footer).
  - Moved for balance: Node release tags and Docker image from Network to Install; x86_64 from
    Install to OS. No spec section 7 fact dropped.
- T3 Fit and polish: DONE. One page; columns end 4.4 mm (left) and 3.2 mm (right) above the
  footer strip (measured from pdftotext -bbox; footer top at 285 mm); widest word ends at
  196.1 mm (content edge 196 mm), nothing off the right edge. 200 dpi crops checked: tables,
  code, pre, header, footer legible; no overlap or clipping.
  - Final type sizes: body 8.5pt; hardware table 8.5pt; other tables 8pt (code in them 7.2pt);
    inline code 7.65pt; pre 7.5pt; section headings 10pt; callout label 7.5pt; footer 7.5pt;
    header title 18pt, subtitle 9pt, meta 8pt, badge 7.5pt. All above the 7.5 / 7 floors.
  - Polish: hardware table columns 26/42/32%; hardware notes as a two-column list; alert title
    runs in; table fills on rows (thead tr, even tbody tr), not cells, to avoid hairline seams.
- T4 Checks: DONE (docker tn-pdf-tools, absolute repo path).
  - a. two builds in a row: both `PDF unchanged: ... (1 pages)` (the last source edit, an unused
    italic @font-face, did not change the bytes; the previous build printed `Wrote ... (1 pages)`).
  - b. `pdftotext -layout` shows devs@telcoin.org on 3 lines (callout, contact, footer);
    `grep -ci legacy` = 0 in the PDF text and in the Markdown.
  - c. `pdffonts`: Geist-Semi-Bold, Geist-Medium, Geist, Geist-Mono, Geist-Bold; all emb/sub/uni yes.
  - d. weasyprint.log empty; the build printed no `weasyprint:` lines.
  - e. `grep -c '<nav'` = 0; `header-section-number` = 0; no dcterms; 3 mailto links.
  - f. `grep -n -i 'adiri\|testnet\|2017\|rpc\.' template.html theme.css`: only the header
    comments' directory name docs/partner/testnet-node-requirements/ (template.html:4, theme.css:4).
  - g. `git status --short`: new docs/partner/testnet-node-requirements/ and
    tasks/ckpt-onepager-T.md; the rest is other units' (AGENTS.md, CHANGELOG.md, README.md,
    docs/partner/assets/README.md, tasks/plan.md, .claude/, ckpt-onepager-D/S, spec).
  - h. final render at docs/partner/testnet-node-requirements/build/page-1.png (110 dpi).
  - pdfinfo: 1 page, A4, Title "Adiri testnet node requirements", Author "Telcoin Association".

## Notes

- Read: spec-onepager-shared.md, guide template/theme/metadata, guide line ranges (+27, 828-832
  because spec section 7 cites them), build script 1-55 + 448-510 (+ FORBIDDEN, pandoc call,
  _stage_css, anti-churn).
- Build: pandoc --from=gfm, --shift-heading-level-by=-1 ("## " sections become h1 in HTML).
- Build+render helper: scratchpad b.sh (docker build then pdftoppm -r 110).
- Type now: body 8.5pt, tables 8pt (code in tables 7.2pt), hardware table 8.5pt, pre 7.5pt,
  inline code 7.65pt, footer 7.5pt, callout label 7.5pt.
