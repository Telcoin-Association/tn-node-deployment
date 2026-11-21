status: done

# GUIDE checkpoint (guide 1.13)

Worktree /home/drtnarg/coding/telcoin/tnd-req-guide, branch req/guide, tip 7a686dc.
Scratch: /var/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/46275ae3-5cf9-4f35-b799-c09950443243/scratchpad/guide/
(guide-committed.pdf = HEAD's PDF; guide-baseline-383.pdf = unchanged sources built with pandoc 3.8.3;
committed.txt / baseline.txt = their pdftotext -layout; base/p-NN.png = baseline pages at 70 dpi;
guide-new1.pdf / new1.txt / new/p-NN.png = first build; guide-new2.pdf / new2.txt = final build)

Sections:
- [x] step 0 baseline
- [x] A hardware
- [x] B chain configs
- [x] C chain id
- [x] build and gates
- [x] pages looked at
- [x] commit (1264ea6)

## Step 0 finding

Committed PDF (pandoc 3.14, WeasyPrint 70.0): 79 pages. Unchanged sources in tn-pdf-tools
(pandoc 3.8.3, WeasyPrint 70.0): 79 pages. Every page carries the same words
(whitespace-normalised per page); page breaks identical. Differences are line breaks only:
69 changed pdftotext lines; right-hand table columns sit about one character further left
(page 15 install-method table, page 67 troubleshooting table, running headers/footers),
and some paragraphs wrap one word earlier or later (pages 15, 16, 26, 28, 60, 67). Two inline
code spans break at a different point: `/opt/telcoin/telcoin-network` on page 15 now breaks
after `/opt/`; `-o ProxyCommand=...` on page 26 now breaks between `-` and `o`. Three
premature line breaks before an inline code span or link (p15 "command," / p28 "catches" /
p67 "RPC"). No table, callout or code block renders differently. Not a defect: proceed.

Side note: in the container the worktree's .git points at the main checkout, which is not
mounted, so git fails inside and the build's toolchain-drift guard is off (it printed
"Wrote ... (79 pages)" instead of "toolchain drift"). Restored the PDF with git checkout.

## A hardware
Hardware per role: tables = spec 3.1 byte-identical (diffed); F1 lead, F2, F5 under the testnet
table, F6 under the mainnet table, QLC + RTT lines, F7 paragraph. Walkthrough steps 2-3 (F11).
Prerequisites line "of your network". Troubleshooting [WARN] row (F8). AWS: Preset/DataVolumeSize
rows, F9 paragraph, volume bullet (15,000 IOPS, 300 MiB/s), F10 paragraph + bullet list.

## B chain configs
Checked-bullet sentence (pinned tag, never default branch); step 8 (pinned dir, no pull,
clone prompt for Docker/release/existing); step 10 (directory, --genesis-dir, hint);
Where things land: new /etc/telcoin/chain-configs/<network>/ row, /opt/telcoin-source row;
menu 13 cell + paragraph (git pull sentence gone, Nothing to refresh, clone offer);
new troubleshooting row for setup's rc-1/rc-2 lines.

## C chain id
GD-1, GD-2, GD-3 (check-node.sh:1392). grep 487|0x1e7|1e7: none. 26.04 count 5.

## Build and gates
81 pages (was 79). Gates pass. Version 1.13 · November 2026 on p1; Ubuntu 26.04 LTS
(recommended) present; 11/11 table rows of spec 3.1 found in pdftotext; no 487, 0x1e7,
c7i.8xlarge, "These figures come from", N vCPU (M cores), no 2 TB in the testnet table.
Second build: "PDF unchanged" (byte-identical).

## Pages looked at
All 81 at 70 dpi. Content edits render fine (p7-8 hardware, p14-15 walkthrough, p19-20
layout table, p26-28 AWS, p29 check-node quote, p38/40 menu 13, p51, p71 troubleshooting).
Pre-existing (also in committed 1.12 and baseline): headings stranded on an otherwise empty
page before a long table: p18 (3.6), p63 (8.3), p66-67 (9 intro, 9.1), p70 (9.2), p73 (9.3),
p77 (9.5); theme.css table break-inside: avoid + h3 break-after: avoid. Toolchain: premature
line breaks p16, p27, p30, p69 as in baseline, plus a new one on p71 ("take the release" /
"that launches mainnet", Mainnet-not-enabled row) after the new row changed column widths.
