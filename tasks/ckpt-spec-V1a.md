status: done

# Checkpoint V1 (V1a chrome + V1b body)

Unit V1 writes docs/partner/technical-specification/{template.html,theme.css}.
Render dir: /private/tmp/claude-501/-Users-grant-coding-telcoin-tn-node-deployment/474df373-eb73-43be-adbe-ffcbd2a2657a/scratchpad/render/

## Completed sections
- [x] 1. Read inputs, measured the original (pdftotext -bbox, pixel sampling).
- [x] 2. template.html + cover/header/footer CSS. 26 pages. Cover clean (no margin boxes,
      no white edge); band + tab + pill from page 2; "Page | 2 / 26" .. "Page | 26 / 26".
      Notes: template header is a pandoc "$--" comment (an HTML comment would be filled
      in); dcterms meta guarded by $if(date-meta)$ ("April 2026" does not normalise, which
      made WeasyPrint warn). Pill cells need an explicit height (anonymous table row gets no
      extra height). Footer wash is a two-stop gradient sized to the strip (a first stop at
      49% bent the curve). box-shadow on the pill dropped: WeasyPrint 70 draws the blur
      with hard edge lines; retried a small shadow: seams visible at 400 dpi, so none.
- [x] 3. Body CSS done: Inter 11pt/15.3pt justified, h1 20pt / h2 14pt / h3 12pt regular black,
      chapters only numbered "N.", TOC 3 levels with leader(" ") (original has no dots),
      bullets via positioned ::before (bullet 90pt, text 108pt as original), tables
      lavender 10.5pt with 1pt white gutters, split between rows only with >= 2 rows each
      side and repeated thead (plan: break-inside auto). No orphan headings, no overflow
      (checked with pdftotext -bbox). 25 pages.
- [x] 4. Final gates: WeasyPrint log empty (0 bytes); 25 pages A4; pdftotext shows
      devs@telcoin.org, the confidentiality line (24 pages) and "Page | 2 / 25" ..
      "Page | 25 / 25"; second build prints "PDF unchanged"; fonts embedded: Inter
      Regular/Medium/Bold + Geist Mono, no fallback. Untracked in the doc dir: md,
      metadata, pdf, template.html, theme.css. Renders (60 dpi p-*.png, 96 dpi hi-*.png,
      contact.png) left in the render dir.

## Measurements from the original PDF (points; A4 595.9 x 841.9)
- Text column 72..523.3pt (25.4 mm margins both sides). Body text top 72pt.
- Body Inter Regular 11pt (bbox 13.3/1.211), line pitch 15.3pt (1.39), justified, black.
  Paragraph gap = one empty line (~15.3pt).
- Chapter heading Inter Regular 20pt BLACK ("5. Epoch boundaries"), h2 14pt regular black,
  h3 ~12pt regular black. (Plan said #424761 bold; sampled pixels are #000.)
- TOC: title 20pt regular; entries 11pt, pitch 16.3pt; chapters bold "N. Title" with a
  blank line between chapters; level 2 indent 36pt, level 3 indent 54pt; page numbers
  right-aligned, no dotted leaders.
- Running header: band 0..56pt (19.8 mm) gradient #F1F1FD -> #FEFEFF, hairline at bottom;
  white tab from x=340.8pt (120.2 mm) to page edge, rounded bottom-left (~3.2 mm);
  title 9pt black at x=72pt, baseline ~31.9pt; logo 33.7 x 5.2 mm centred in the tab, top 8.2 mm.
- Footer: grey #666666 8pt line centred, baseline ~261.6 mm; pill x 6.6..202.9 mm,
  y 269.6..285.5 mm, radius ~3.5 mm, light border, soft shadow; assoc. logo 45 x 6 mm at
  x 13.2 mm; divider x 64 mm; "telcoin.org" x 70 mm ~12pt #424761; "Page | N / M" 10pt
  right edge 184.4 mm. Bottom gradient white (~785pt) -> #ECECFD (842pt).
- Tables: header #c9cfed bold, cells #f4f5ff, white gutters ~1pt, cell padding ~5pt, 11pt.
- Lists: bullet ● at +18pt, text at +36pt, ~10pt between items.
- Cover: logo 64 mm wide at (27.9 mm, 72 mm); title Inter Bold 41pt #43475F top 301pt;
  "Technical Specification" Inter Medium 16pt #7A81A1 top 378pt. Card (with
  background-size: cover) x 0..163 mm, y 53.6..248 mm.
- Original counts the TOC page as 1 (cover unnumbered); we count the cover (task asks for
  "Page | 2 / N" on page 2).

## pandoc HTML structure (verified)
- nav#TOC > p.toc-title + ul > li > a > span.toc-section-number "1" + " Title"; nested ul for 2 and 3.
- main > h1[data-number] > span.header-section-number; h2, h3 likewise (h4 in md -> h3).
- Tables: plain table/thead/tbody, no colgroup. Code: pre.text > code.
