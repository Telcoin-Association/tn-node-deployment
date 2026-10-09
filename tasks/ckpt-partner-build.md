status: complete (all 8 sections)
task: C — partner PDF build pipeline (plan Part 3)

completed sections:
- 1 toolchain: brew install pandoc weasyprint OK. pandoc 3.11, WeasyPrint version 70.0 (python 3.14.8 bundled). No poppler/pdftotext, no pdftoppm, no mutool/gs. shellcheck present.
- 2 assets: logos from tel3.telcoin.network (network-light 16195 B viewBox 0 0 262 41; association-white 20215 B viewBox 0 0 272 36; path+clipPath(rect) only, no text/font/href). Fonts v1.7.2 tag (commit a73329da8fc6) fonts/Geist/webfonts + fonts/GeistMono/webfonts woff2 all OK (45-52 KB each). OFL.txt 4383 + LICENSE.txt 4368 from repo root at tag. assets/README.md written.
- 3 metadata.yaml written; date-meta = 2026-10-01 (no explicit date-meta needed).
- 4 template.html written. Uses $pagetitle$ in <title> (plain text). contact/repo-url are NOT autolinked by pandoc (plain text), so template wraps them in <a href="mailto:$contact$"> / <a href="$repo-url$">.
- 5 theme.css written; sample build OK: cover gradient on @page cover works, 5 pages, fonts embedded, empty weasyprint log. FIX applied: Geist Mono calt swallowed the space in " --flag" -> font-variant-ligatures:none + font-feature-settings "calt" 0,"liga" 0 on pre/code.
- 6 tools/build-partner-pdf.sh written; /bin/bash -n, bash -n, shellcheck (all severities) clean. PARTNER_MD override documented in --help (candidate only, committed PDF untouched, page range warns). Coordinator course-correction: forbidden/H1 checks fence-aware -> forbidden text fails in prose, only WARNS inside fences (trade-off, report it).
- 7 build+iterate: real guide builds, 31 pages, empty weasyprint.log, deterministic (2nd run "PDF unchanged", identical bytes). CSS fixes: th code readable on navy; td code overflow-wrap:break-word (break-all squeezed code columns and split identifiers); table break-inside:avoid + table,pre break-before:avoid (no 1-row widows, lead-in kept with table/code). Added 'cannot be loaded' to the weasyprint fail regex (missing @font-face logs a WARNING without "Failed to load"). Visual pass of all pages done via pdfsheet contact sheets. REMAINING: anti-churn tests in scratch clone, section 8 negative tests.
- 7b anti-churn verified in a throwaway scratch clone (scratchpad/clone, committed there only): unchanged / drift warn (exit 0, committed kept) / --force writes / md change writes + metadata-bump warn / untracked source counts as change. Dropped duplicate gradient on .cover (@page cover gradient renders full-bleed). Final: 31 pages, 222 KB, byte-identical reruns.
- 8 negative tests: grant@ in PARTNER_MD copy -> exit 1; --bogus -> exit 2; dangling #link -> 1; 2nd H1 + legacy -> 1; no contact -> 1; --observer inside a fence -> warn only; fake pandoc 3.1.3 / weasyprint 60.2 -> exit 1 with brew hint. All also pass under /bin/bash 3.2. PARTNER_MD outputs now named build/<name>.* so they never clobber the guide's preview.

notes:
- visual check tool: scratchpad/pdf2png (swiftc CoreGraphics renderer, built from scratchpad/pdf2png.swift): ./pdf2png <pdf> <outdir> <dpi> [first last]
- PDF uses object streams (/ObjStm): raw bytes have 0 /Type /Page; zlib-decompress every stream then regex.
- pandoc emits alerts as <div class="warning"><div class="title"><p>Warning</p></div>...; numbering spans header-section-number / toc-section-number present; ids are GitHub slugs.
- lint must be fence-aware: guide has a '# behind NAT' bash comment in a code block (exactly-one-H1 check must skip fences).
- Task B finished: real guide is final (911 lines); build against it. sample.md only for negative tests.
