status: done (all 11 edits applied, checks run; report handed back)

# Checkpoint U2 (guide 1.4 refresh, 2026-10-15)

Final line numbers after all edits.

OPERATOR.md
- section 9, items 10a-10d (replace start-limit-hit row with four rows): applied, L1269-1272
- section 9, item 9 (worker is inactive row after the Workers row): applied, L1231
- section 9, item 8 (CvvInactive row cause): applied, L1225
- section 6.7, item 7 (tn_nodeMode bullet, second sentence on the same line): applied, L975
- section 4.2, item 5 (recovery paragraph after the wait paragraph): applied, L509-510 (blank L508)
- section 4.2, item 6 (Cannot check database (epoch) pointer after "read the journal..."): applied, L493-494
- section 2.7, item 4 (network-config opt-in keys paragraph): applied, L350-353 (blank L349)
- section 2.7, item 3 (bootstrap peers are discovery hints): applied, L331, placed after "It needs v0.15.0-adiri or later." rather than after the flag line so "It needs" keeps its referent
- section 1.1, item 2 (clock drift correction, old L97): applied, L97-98
- section 0, item 1 (CvvInactive vocabulary row): applied, L69

README.md
- Bootstrap peers, item 3 (discovery hints, in the first paragraph after "the node dials them at start."): applied, L826
- Restarts and the epoch boundary, item 5 (recovery paragraph): applied, L765 (blank L764); placed after the "Pass a variable through sudo" paragraph instead of after L753, so the variables table stays under the paragraph it explains

Checks
- git diff --stat -- OPERATOR.md README.md: 2 files, 24 insertions, 6 deletions (the full stat also lists files other agents edit)
- grep 'next release': only README.md L2004, a pre-existing historical changelog entry (L2002 at HEAD), not touched
- added lines mentioning consensus-db/epoch: 3, each names which directory it means
