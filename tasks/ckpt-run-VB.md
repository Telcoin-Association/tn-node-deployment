status: DONE, report handed back; clone clean at def6961 (git status --short empty) (VB verifier, branch docs/spec-1.3-public def6961)

Clone: /var/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/9e8efab4-ccd8-4e70-8b1b-387187e040a7/scratchpad/vb/clone
Harness: .../scratchpad/vb/harness (common.sh, c1_scope.sh, c2_repro.sh, c34_text.sh/.py, c4_pixels.sh/.py, c5_render.sh, c5_bbox.sh, c6_marking.sh + mutate.py [CASES=, NOPT=1, TAG=], c7_script.sh, c8_msgs.sh, c9_stale.sh, c10_ci.sh)
Outputs: .../scratchpad/vb/out (c6.log, c6-extra.log, c6-nopt.log, c6-L.log, png/, c7/)

Finished checks:
- 1 scope: PASS.
- 2 repro: PASS (93412a4 and def6961: 4x PDF unchanged, clean).
- 3 HEAD spec PDF: PASS (37 pages, 0 confidential, Version 1.3 line on 1-37 = old footer pages 2-37 + cover).
- 4 nothing moved: PASS (words equal 37/37; 243 whitespace-only -layout diffs; pixel diff only footer band / cover version line).
- 5 visual: PASS (centre 105.00 mm, y 258.90-262.06 both).
- 6 marking: with pdftotext A,B,B2(css uppercase+old footer),C,D,E,E2,F1,F2,H1(nbsp),L(badge uppercase+letter-spacing) all rc=1, PDFs untouched; G inert; A via --all rc=1.
  J (description:) and K (author:) -> marking in PDF Info dict, rc=0, committed PDF overwritten.
  Without pdftotext: A,B,D,F2 rc=0 and committed PDF overwritten with the marking (only a 'note:' line); C,E fail lint; G inert.
- 7 script: PASS.
- 8 prose: commit-message test claims all reproduced; CHANGELOG "From now on the build fails on the marking in any partner document" overstated (pdftotext, Info dict); band nit.
- 9 stale: PASS with note (followup.md:714).
- 10 CI: no job builds partner PDFs; manifest "Not a release change"; PR pin check skipped; gen-checksums clean; bash32/perl-interp/network-hits clean; shellcheck error-level rc=0 over all *.sh.

Findings:
1 (low-med) guard misses PDF Info dict (metadata description:/author:) -> repro J/K.
2 (low-med) without pdftotext, template/CSS/metadata/lowercase routes write the marked PDF with exit 0; CI never runs the build -> repro NOPT A.
3 (low) CHANGELOG sentence overstates.
4 (nit) commit 93412a4 band 261.5 vs measured 261.96 / line box 262.06.
5 (info) followup.md:714 mentions specification 1.2 (pre-existing dated item).
