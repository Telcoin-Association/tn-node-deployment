status: done

# A1 checkpoint (build-site.sh and site/ templates)

Scratch: /var/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/9e8efab4-ccd8-4e70-8b1b-387187e040a7/scratchpad/a1

## Sections
- [x] script skeleton and gates (build-site.sh, shellcheck clean)
- [x] output tree
- [x] templates and CSS (site/index.html, style.css, 404.html, robots.txt)
- [x] harness (a1/harness.sh: 115 passed, 0 failed; output in a1/harness-run.txt)
- [x] visual check (rough look: WeasyPrint 70 + pdftoppm, PNGs in a1/vis/; no browser on host)

## Notes
- Contract gap: the real PDFs and both Geist woff2 files contain the bytes `@@`
  (guide 4, spec 20, Regular 1, SemiBold 2). Gate 6's `@@` check is limited to the text
  outputs (*.html, *.css, *.txt).
- Gate 6 runs only after gates 0-5 pass (it needs a built tree).
- Logo: telcoin-network-light.svg (white wordmark) in a navy header band, as the one-pagers.
- Visual check caught a CSS bug: `docs/partner/*/theme.css` in the header comment closed
  the comment early and dropped the Regular @font-face. Fixed.
