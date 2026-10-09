status: done
unit: B3 update-node.sh 1.1.62 (verifier V-B(b))
verdict: G2b: PASS
harness: scratchpad/VBb/ (tests.sh + cases.sh, stubs/; h/un.sh = script minus main, sourced at TOP LEVEL; h/lib/common.sh copy rooted at TN_ROOT_PREFIX)
completed sections:
- item1 PASS, item2 PASS (help never documented --json/--check/etc. in old either; nothing operator-relevant dropped), item3 PASS, item4 PASS, item5 PASS, item6 PASS, item7 PASS (sweep listed in report)
- totals: 51 cases x bash3.2+bash5 all OK (410 asserts each, 0 FAIL); negative control vs b5d912b fails strip asserts
notes: see final report (version source for non-tag source refs; "Re-run setup-node.sh" wording; CHANGELOG lacks 1.1.62 entry; check-node hint wording)
