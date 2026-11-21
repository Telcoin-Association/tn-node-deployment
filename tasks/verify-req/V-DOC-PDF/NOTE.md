# Note on the V-DOC-PDF report (orchestrator, 2026-11-21)

`REPORT.md` examined the three PDFs as they stood at `d7c16b1`, built in the Debian 12
`tn-pdf-tools` container. Its finding VP-1 (five guide lines broken early, one inside an
`ssh -o` option) led to a second look at the toolchain: an image on Ubuntu 26.04 with pandoc
3.14 and WeasyPrint 70.0 (Pango 1.57.0, HarfBuzz 12.3.2) rebuilds main's 1.12 and 1.2 PDFs
byte for byte from their unchanged sources. The three PDFs were then rebuilt in that image
and replaced in the two partner commits, so the sha256 values in `REPORT.md` are those of the
earlier builds, not of the committed files.

Rerun by the orchestrator on the replaced PDFs, with this directory's harness
(`extract_text.sh`, `check_text.py`) and the Ubuntu 26.04 image:

- text checks: 80 of 80 pass (the same assertions as P2);
- pages: guide 81, each one-pager 1; a second build reports "PDF unchanged" for all three;
- the VP-1 probes (`command,` alone, `then pass -`, `catches` alone, `RPC` alone, `release`
  alone) find nothing;
- the two one-pagers and guide pages 7 and 27 were rendered and looked at;
- each PDF equals its blob in HEAD, and the partner site's `build-site.sh` builds from the
  final tip (the PR body gives the commit).

VP-2 (headings alone on a page), VP-3 and VP-4 are properties of the theme and the sources and
stand as reported; `followup.md` records VP-2 and VP-3.
