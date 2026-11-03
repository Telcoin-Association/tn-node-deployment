status: done

# Checkpoint F2 (render-review fixes in theme.css / template.html)

## Completed sections
- read inputs (Q3 review, theme.css, template.html); measured original cover: title bbox top 301.33pt (106.3mm), 41pt; subtitle bbox top 378.38pt, 16pt; gap 27.44pt (9.7mm)
- 1 cover: .cover-head top 106.3mm; .cover-title 700 41pt/1.21; subtitle margin-top 9.7mm, 500 16pt/1.21 -> title top 301.31pt (orig 301.33), subtitle top 378.43 (orig 378.38)
- 2 bullets: ::before font-size 6.5pt, line-height 1, top 4.8pt, left -18pt -> ink 4.80pt wide, centre 3.79pt above baseline (orig 4.79, 3.75); ink x 90.46 (orig 90.83)

## Plan
1. cover title/subtitle
2. bullets
3. stretched justified lines next to long code spans
4. nits
5. final build, renders in render-f2/, header comment
- 3 stretched lines: NOT fixable in CSS without side effects (tested on WeasyPrint 70): `main p code {overflow-wrap:anywhere}` no change (token fits next line, so it moves); `main p {hyphens:auto}` fixes DST line only by reflow luck, precompile line still stretched, adds hyphenation doc-wide; `main p code {word-break:break-all}` fixes both but splits 24 identifiers (C|onsensusRegistry, app|lySlashes, Act|ive, c|oncludeEpoch). Theme left unchanged for item 3; recommend Markdown: long token at sentence/paragraph start or in a code block.
- 4a footer nits: .run-conf 7.4pt (measured orig 7.38-7.45pt; reviewer said 7.5); pill was 3.6pt low vs orig (761.7-807.4pt): .run-pill margin-top 7.75->6.75mm, height 15.9->16.2mm, cells 15.6->15.9mm -> pill 761.9-807.3, logo centre 784.58 (orig 784.59), site 785.18 (784.83); .run-page height 13.9mm + padding-bottom 2mm -> "P" cap 778.11-785.30 (orig 778.12-785.31); footer comment updated
- 5 final build: bash tools/build-partner-pdf.sh technical-specification OK, weasyprint.log empty, 38 pages; renders p-01..p-04, p-07, cmp01.png, cmp04.png in scratchpad/render-f2/ checked
- skipped: cover art stretch (distorts art 3%, 13pt), @page margin-bottom 44mm (changes pagination), code/td code 10pt (plan styling, reflows text), Page counter font Arial (Inter by design), all Markdown nits (bold col, Retired, curly quotes, U+2212, formula, Score col), table nowrap
