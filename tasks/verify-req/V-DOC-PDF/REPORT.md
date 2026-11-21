# V-DOC-PDF: the three rebuilt partner PDFs

Verifier V-DOC-PDF, 2026-11-21. Tree under test: `d7c16b1` (tree `49bf7f34`, identical to `2d91fa8`'s); base `01664cc`. The guide 1.13 was written in `928c60f`, the one-pagers 1.3 in `d7c16b1`.

Toolchain: the local images `tn-pdf-tools` (pandoc 3.8.3) and `tn-pdf-tools:pandoc-3.14` (pandoc 3.14), both Debian 12 with WeasyPrint 70.0, poppler 22.12, Pango 1.50.12 and HarfBuzz 6.0.0. Nothing PDF-related ran on the host. The worktree was not modified: every build ran in a scratch clone.

Harness, in this directory: `extract_text.sh` + `check_text.py` (P2), `build_in_clone.sh` (P3), `check_blobs.sh` (P4), `pdf_props.sh` (P1), `p6_sentences.py` (P6), `compare_text.py`, `page_audit.py`, `render.sh`, `montage.py` (P5).

Scratch output: `/var/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/46275ae3-5cf9-4f35-b799-c09950443243/scratchpad/v-doc-pdf/` (written `<S>` below).

## Findings

| Id | Severity | PDF, page | One line |
|---|---|---|---|
| VP-1 | Low | guide 1.13, pp 16, 27, 30, 69, 71 | Lines broken too early by the container toolchain, absent from the published 1.12; on p27 the option `-o` is split over two lines |
| VP-2 | Low (pre-existing) | guide 1.13, pp 18, 63, 67, 70, 73, 77 (1.12: 17, 61, 65, 68, 71, 75) | Six section headings sit alone on an otherwise empty page, with their table on the next page |
| VP-3 | Info | mainnet one-pager 1.3 | The gap between the last left-column line and the footer strip shrank from 5.1 mm to 2.5 mm; nothing is clipped, but no line can be added without another cut |
| VP-4 | Info | mainnet one-pager 1.3 | The shortened bullet "Every node: swap off, time sync on, ext4 or xfs; none checked." no longer says what must be ext4 or xfs, or who does not check it |

### VP-1 (Low): lines broken too early by the build environment

- **PDF:** `docs/partner/mno-node-guide/mno-node-guide.pdf` (1.13).
- **Expected:** lines fill the measure as in the published 1.12. The guide's text changed in this round, but its theme did not.
- **Seen:** five lines break early, checked at 110 dpi:
  - p16, Install methods row 1: "Every `tn-build` process is stopped after each build" / "command," / "before root copies the output. …". The word "command," sits alone on its line.
  - p27, AWS one-click: "then pass `-`" / "`o ProxyCommand="aws ssm start-session …`". The `ssh` option `-o` is split after its hyphen. A reader who retypes the command sees `- o`.
  - p30, 4.3: "… before the node" / "catches" / "up again, so a node …". The word "catches" sits alone.
  - p69, 9.1 last row, Fix column: "… with an" / "RPC" / "for the node's chain (see …".
  - p71, 9.2 row "Mainnet is not enabled …", Fix column: "Install on testnet, and take the" / "release" / "that launches mainnet with …".
- **Cause:** the build environment, not pandoc.
  - A container build of the unchanged 1.12 sources breaks the same sentences the same way: pp 15, 26, 28 and 67 of that build, where the published 1.12 PDF has normal breaks. Both pandoc images give that build byte for byte, so the pandoc version plays no part.
  - The published 1.12 PDF also says WeasyPrint 70.0, so the difference must lie further down, most likely in Pango or HarfBuzz: the container has Debian 12's Pango 1.50.12 and HarfBuzz 6.0.0, against Homebrew's current releases. This is inferred, not proved.
  - p71 is new content; it breaks the same way.
- **Reproduce:**
  ```
  docker run --rm -v <W>:/w:ro -w /w tn-pdf-tools pdftotext -layout docs/partner/mno-node-guide/mno-node-guide.pdf - \
    | grep -n -E '^\s+command,$|before the node$|^catches$|then pass -$|^\s+RPC$|^ +release$'
  bash tasks/verify-req/V-DOC-PDF/render.sh <new dir> 110 png docs/partner/mno-node-guide/mno-node-guide.pdf   # pp 16, 27, 30, 69, 71
  ```
  To compare with 1.12: `python3 compare_text.py <committed-1.12 layout> <container-build-of-1.12 layout> --show 20`.
- **Suggested fix:** pick one.
  - Build the guide with the reference toolchain that AGENTS.md names (Homebrew pandoc, WeasyPrint 70.0, poppler on macOS), or in an image whose Pango matches it, and compare.
  - Accept the five breaks and record in AGENTS.md that the container breaks some lines early.
  - Either way, p27 is worth a look before publishing.

### VP-2 (Low, pre-existing): headings alone on a page before a long table

- **PDF:** the guide, 1.13 and 1.12 alike.
- **Expected:** a heading stays with the start of its section.
- **Seen:** these six headings each sit alone on their page, with no other body line. The section's table starts on the next page.

  | Heading | Page in 1.13 | Page in committed 1.12 |
  |---|---|---|
  | 3.6 Where things land | 18 | 17 |
  | 8.3 Other scripts | 63 | 61 |
  | 9.1 Sync and node mode | 67 | 65 |
  | 9.2 Setup and preflight | 70 | 68 |
  | 9.3 Scripts and updates | 73 | 71 |
  | 9.5 Service and keys | 77 | 75 |

  - The page before 8.3 (p62) carries 7 body lines; the chapter 9 opening (p66) carries 3.
  - The container rebuild of 1.12 shows the same six headings, so neither this round nor the toolchain introduced them. The writer's report that they predate this round is confirmed.
- **Cause:** `theme.css` `table { break-inside: avoid; }` (`:208`), together with `h1, h2, h3 { break-after: avoid; }` (`:152`) and `table, pre { break-before: avoid; }` (`:209`).
  - Experiment in a scratch clone: with `:208` changed to `table { break-inside: auto; }`, the guide builds to 69 pages with no heading alone, and the contents, footers and running headers stay correct.
  - Cost of that change: short tables may then split across pages.
- **Reproduce:**
  ```
  python3 tasks/verify-req/V-DOC-PDF/page_audit.py <guide layout text>   # STRANDED / SHORT lines
  ```
- **Suggested fix:** a follow-up outside this round, since it changes every guide page. Keep `break-inside: avoid` for short tables only (for example on a class, or a rule that lets a table taller than a page split), rebuild with `--all`, and check the specification too. It shares the rule pattern; I did not check it.

### VP-3 (Info): the mainnet one-pager is fuller at the bottom

- **Measured** at 110 dpi, from the last row with text above the footer strip (`y=1233`):

  | Page | 1.2 | 1.3 |
  |---|---|---|
  | testnet | 4.2 mm | 4.2 mm |
  | mainnet | 5.1 mm | 2.5 mm |

  - The writer's own figures agree: the last left-column line is at 790.08 pt, against 783.29 pt in 1.2.
  - Nothing is clipped or behind the footer, and the type, margins and columns are unchanged.
- **Suggested fix:** none. Record that any added line on the mainnet page needs cut 4 or 5 (spec 5, last paragraph).

### VP-4 (Info): the shortened "Every node" bullet loses its object

- **Mainnet 1.2:** "Every node: swap off, time sync on, data directory on ext4 or xfs; the scripts check none of these."
- **Mainnet 1.3:** "Every node: swap off, time sync on, ext4 or xfs; none checked."
- This is the spec's cut 3 and is allowed. The testnet page and the guide keep the full wording. My test shows the cut was needed, and that cut 2 would not have fitted (see P6).
- **Suggested fix:** none required. If a later change frees a line, restore "data directory on".

## Proved

**P2, text** (`extract_text.sh` then `check_text.py`; layout text for tables, `-raw` text for prose): 80 checks pass, 0 fail. The `-raw` text is needed because plain `pdftotext` drops a line-end hyphen ("singlethreaded"). Negative control: the 01664cc PDFs fail it as expected.
- Both one-pagers:
  - `Version 1.3 · November 2026` is on page 1, and so is "Ubuntu 26.04 LTS (recommended)".
  - Every row of their spec 3.1 table matches character for character, one row per line, in the spec's order, with no extra or wrapped row.
  - F2 is there verbatim.
  - Neither page has "hyperthread", "physical cores", a vCPU-before-cores figure, "legacy" or the confidentiality marking.
- Testnet: `2017 (0x7e1)` is there; `2 TB` is not.
- Mainnet:
  - `731 (0x2db)` and both storage rows are there.
  - `487`, `0x1e7` and `Storage, every role` are not.
- Guide:
  - `Version 1.13 · November 2026` is on page 1, and so is "Ubuntu 26.04 LTS (recommended)".
  - Both tables match spec 3.1. F2 is there verbatim.
  - `731` and `0x2db` each appear twice, as often as in the Markdown, in their three places: the networks row `Mainnet 731 (0x2db)`, the `eth_chainId` line, and the check-node message `not chain 731 (mainnet)`.
  - `/etc/telcoin/chain-configs/` and `v0.16.0-adiri` are there.
  - None of these appear: `487`, `0x1e7`, `c7i.8xlarge`, "These figures come from", "git pull failed", "rolls back unchanged", "legacy", a vCPU-before-cores figure.
- The guide's tables equal the one-pagers' tables cell for cell, compared as tuples of the extracted cells split on runs of 2 or more spaces.

**P3, the PDFs are what the sources build** (`build_in_clone.sh`, scratch clones of the worktree at `d7c16b1`):
- Six builds, three documents with each of the two images, clone at `/w`. Each printed "PDF unchanged" and is byte-identical to the committed PDF.
- Second path: the clone sits at `<S>/p3-second/deeper/dir/tnd-b` and is mounted at `/srv/another/checkout/path`, built with pandoc 3.14. All three documents are byte-identical again, so no build path reaches the PDF.
- The clones showed no tracked change after any build.

| PDF | sha256 (committed = all 9 builds) |
|---|---|
| testnet-node-requirements.pdf | `c2145ff1baf78bab6a0873dff09f308e1ca7a8921d24e5f520c4108d49fd3506` |
| mainnet-node-requirements.pdf | `b7a7d8d04279b794fef3f98202404fc390bf68b5c30128fce0eae95004a0d458` |
| mno-node-guide.pdf | `4a1881d30b0f00a9fa37c7fb87b79eff4e5053b0e52e386d7a26fbd338bf888f` |
| technical-specification.pdf (untouched, not built) | `2010e3aba5d2b47fe9cb2ca823f75d44e8a12c3bf120b8e96c407240cb4874d9` |

The 01664cc sources, built with both images, give the same bytes with either:
- testnet `1ca9801752d1051baefc1edc73fe31215ce8adeace7f51a953a1b0c2a34aead1`
- mainnet `8f343733fed9263b353f5a9aabdff03d12a98dd7d0f9db8fedba9ac3fb418d78`
- guide `323202f2816589a5c1f11a098decf13924390e933ffef51b04eb2d1d35d70b5f`

Each differs from the committed 1.2 / 1.12 bytes, and the build script reports "toolchain drift" and keeps the committed file.

**P4, committed files equal HEAD** (`check_blobs.sh`):
- Each of the four PDFs is a regular file, mode 100644, whose working blob equals its HEAD blob: guide `780f833b`, testnet `2012447a`, mainnet `bcc9ad42`, specification `1ed24b30`.
- `git diff --stat 01664cc..HEAD -- docs/partner/technical-specification` is empty, and the specification's PDF blob is the same at both commits.
- The other files the site reads are regular and equal HEAD: every `*.md`, every `metadata.yaml`, and the five shared assets.

**P1, properties** (`pdf_props.sh`):
- Pages: guide 81 (79 at 01664cc), testnet 1, mainnet 1. All are A4 (595.276 × 841.89 pt), PDF 1.7.
- The info dictionary is identical to 01664cc's apart from `Pages` and `File size`:
  - Title is the `#` heading, Subject is the metadata `description`, Author is "Telcoin Association", Producer is "WeasyPrint 70.0".
  - There are no dates and no XMP stream.
- Font sets are identical to 01664cc's, all embedded subsets: the guide has 6 Geist faces, each one-pager 5.
- No home directory, build path or user name appears in the info, the XMP or the uncompressed bytes. The second-path build shows it is absent from the compressed streams too.

**P6, one-pager cuts** (`git diff 01664cc..HEAD`, `p6_sentences.py` on the `-raw` text of 1.2 and 1.3):
- `theme.css` and `template.html` are `cmp`-identical between the two pages. Neither changed in `01664cc..HEAD`, and neither did `assets/` or the build script.
- The whole change between 1.2 and 1.3:
  - the table rows are now spec 3.1's;
  - the hyperthread bullet is replaced by F2;
  - the QLC bullet is gone from both pages;
  - testnet "Every node" gains "no QLC drives";
  - mainnet "Every node" becomes "swap off, time sync on, ext4 or xfs; none checked.";
  - the mainnet chain ID goes from 487 (`0x1e7`) to 731 (`0x2db`);
  - the version goes from 1.2 to 1.3.
- The round-trip bullets, the operating-system lines and every other sentence are unchanged. Nothing else disappeared.
- I tested whether each cut was needed with `PARTNER_MD` variants in a scratch clone:
  - testnet with its 1.2 bullets: 2 pages;
  - mainnet with only the QLC cut: 2 pages;
  - mainnet with ranked cut 2 instead of cut 3 (a one-line round-trip bullet): 2 pages, because the columns rebalance.
  So cut 3 was needed, and skipping cut 2 is not a defect.

**P5, the look:**
- One-pagers at 110 dpi, next to 1.2: nothing is clipped or behind the footer strip, and no cell overflows.
  - Every table row is on one line; the mainnet recommended cell does not wrap, so the column widths rightly stayed.
  - The bullets are balanced: testnet 3 lines left, 4 right; mainnet 3 and 3.
  - The callout, header band, badge and version line are intact.
- The guide at 70 dpi, all 81 pages, with zooms at 110 dpi on pp 16, 27, 30, 69, 71:
  - No table loses a column or overflows, no code block or callout is clipped, and split tables repeat their header row. There is no blank page.
  - `page_audit.py` confirms: all 72 contents entries name a heading on the stated page, every footer reads `Page N of 81`, and every running header names the current chapter.
  - The only defects are VP-1 and VP-2.
- Three possible causes, separated:
  - **The content change:** no defect, beyond the p71 instance of VP-1.
  - **pandoc 3.8.3 against 3.14:** none; the builds are byte-identical, at the tip and at 01664cc.
  - **Build environment against the published PDFs:**
    - The one-pagers built from the 1.2 sources have identical layout text, and their 110 dpi renders are pixel-identical (`cmp` of PPM files) to the committed 1.2 PDFs.
    - The guide built from the 1.12 sources has the same 79 pages, with the same characters on every page (`-raw` text, whitespace removed). Layout lines differ on 6 pages (15, 18, 26, 28, 60, 67): 36 lines, or 69 removed plus added lines as `diff` counts them.
- The two commit messages' toolchain statements are confirmed: byte-identical across pandoc versions, "PDF unchanged" on a second build, and the same text and render (one-pagers) or the same 79 pages and words (guide) from the unchanged sources.

**Gates for these files:**
- Every `*.sh` (5) has a shebang, `shellcheck` is clean at every severity, `bash -n` passes under bash 5.2 and in `bash:3.2` (3.2.57), and `tools/check-bash32.sh` is clean (5 files).
- The 5 Python files compile.

## Not proved

- **The reference toolchain:** how the 1.13 sources look when built with it (Homebrew on macOS); there is no macOS host here. So I cannot say whether VP-1 goes away there, or whether Pango or HarfBuzz is the cause.
- **Other viewers:** the renders were checked with poppler only, not in Preview, pdf.js or Acrobat.
- **The live site:** I did not run its Publish workflow. I checked only the rules AGENTS.md lists: the version line on page 1, regular files equal to their HEAD blobs, no confidentiality marking, and a date like "November 2026".
- **The guide's 1.12 rebuild:** compared with the published 1.12 by text only, not pixel by pixel; its line breaks differ on 6 pages, so its pixels differ there.
- **VP-2's mechanism:** inferred from the CSS and the one experiment, not traced in WeasyPrint. The experiment's side effects (short tables splitting) were not reviewed page by page.
- **Clearance figures:** measured on a 110 dpi raster, so each is ±1 px (±0.23 mm).
