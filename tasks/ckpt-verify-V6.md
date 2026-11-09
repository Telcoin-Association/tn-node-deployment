# V6 checkpoint (verify NET-2 + GOV)
status: done

## Sections
- [x] 1. Read specs, AGENTS.md Lints/CI, diffs
- [x] 2a. NET-2 lint harness (bash 5.3, bash:3.2, ubuntu:24.04)
- [x] 2b. Sweep audit (>=40 sampled lines)
- [x] 2c. No-code-change proof (pretty-print, AST, --help)
- [x] 2d. Real gaps + variable-hidden hits
- [x] 3. GOV harness + mutation
- [x] 4. Compare implementer claims + docs notes
- [x] 5. Commit records

## Notes
- harness net2_harness.sh: bash5.3 51/52, bash:3.2 50/51 (+1 skip root), ubuntu:24.04 50/51 (+1 skip root); the 1 FAIL = marker line with code after --> also covers next line (NOTE). real tree: no line uses that form.
- implementer tests network_hits_test + ci_pins_test exit 0 on 5.3, 3.2, ubuntu 5.2; real lint clean 148/23 in all three.
- 2b sweep audit: sample (shuf seed V6) #1 13 16 18 19 22 25 28 31 34 36 37 41 44 48 56 59 62 65 68 71 74 77 80 84 87 90 91 93 94 96 99 102 105 108 111 115 118 121 125 + targeted 2 5 11 43 45 57 58 70 79 83 100 106 126 127 132 134 135 139 141 142 144 = 61 lines. No false reason. Imprecise: common.sh:1532 (DEFAULT_DOCKER_TAG also used as testnet example elsewhere). Mid-sentence marker lines (common.sh:1754/2002/4926, config.alloy:10/15). Messages on every network naming testnet tag floor (edit-config:2603/2633/2635, setup-node:2291-2315, update-node:298, check-node:772).
- 2c: pretty-print SAME for 8 .sh; common.sh differs by blank lines only (top-level comments); observability.sh heredoc gains 1 Alloy comment line (disclosed). server.py AST same except latest_source_tag docstring (disclosed). index.html/config.alloy same with markers stripped, BUT index.html:2406,3602,3604 markers are inside JS template literals -> rendered into DOM (NOTE). --help byte-identical pre/help/ann/tip on bash 5.3 and 3.2.
- 2d: edit-config mainnet example arm present (edit-config.sh:2518); remove-node custom_container_lines matches ghcr. Variable-hidden: DEFAULT_DOCKER_TAG/TESTNET_RPC_URL/GAR_IMAGE_BASE/TN_TESTNET_LEGACY_IMAGE_REPO all gated. NEW WARN: firewall-setup view_status on NETWORK=mainnet prints ERROR "TCP 43174 is CLOSED -- health monitoring will fail" and suggests restricting to TN_KUMA_SRC (kuma_mainnet_repro.sh).
- 3 GOV: ci_pins_test exit 0 bash 5.3/3.2/ubuntu; pyyaml parses 3 workflows; actionlint 1.7.7 rc 0 (tip and 3b760cc); gov_harness.sh 77/77 (pins, persist, permissions, names, coe identical 3b760cc..02adda6; 10 names once; network hits + 3 UI tests wired); pip freeze --all identical (19 lines) in python:3.10-slim; gov_mutation.sh 8/8 required caught; probes missed: `|| true`, step `if: false`, coe on fixture-tests, job `if: false` (NOTE). UI shell tests: host 548/1/9 checks, bash:3.2 root 548/24/9, non-root install_ui 1 check; python:3.10-slim pytest 281 passed + 548/13/9.
- 4 claims: NET-2 ckpt counts verified (pre-sweep 140/141, tip 148, markers per file match, network_hits_test 53 checks); GOV 49 checks, 9 fail on 3b760cc workflows (verified). NEW: issue #30 ruleset JSON has require_code_owner_review false and 8 contexts (no "fixture tests (macOS bash 3.2)", no "Ubuntu 24.04 VM assertions") -> CODEOWNERS line 1 + GOV docs note (10 required) disagree with it (WARN x2). Docs-note corrections: "nothing but the marker comment" not enforced; HTML markers in template literals render; pip freeze 19 lines vs "18 packages".
- 5: committed 8901161 (tasks/verify-fup/V6 only)
