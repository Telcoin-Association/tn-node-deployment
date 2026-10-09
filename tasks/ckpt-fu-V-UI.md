status: done
sections:
- [x] 0 read specs (shared, ui, lessons) and the six UI files (targeted reads of server.py/index.html)
- [x] 1 helper harness (A.1): vui-tests/helper/harness.sh, 215 checks pass under /bin/bash 3.2.57 and bash 5.3.15; mutation-tested (arity, 64-char label, case-insensitive dash==host all caught)
- [x] 2 sudoers (A.2): textual heredoc extraction rendered by bash (SVC_USER=telcoin-ui), visudo -cf parsed OK; vui-tests/sudoers/check.py 406 pass (1 checker false positive on enumerated firewall-port); exact 23/wild 14/firewall 6/transitional 28 exactly; all 38 helper subcommands and all 39 server sudo argv shapes matched; env_keep = server sets + helper reads exactly, +RPC_DOMAIN, -RPC_PUBLIC/-INSTANCE; every pre-UI-1 sudoers line retained
- [x] 3 installer (A.3): vui-tests/installer/run.sh 60/60 under bash 5.3 and /bin/bash 3.2 (step order with the sudoers mv immediately before the restart; (a) visudo fail, (b) daemon-reload fail and cp fail, (c) pip fail, missing source, unparsable helper, fresh prompts, root check); installed sudoers byte-equal to the textual render, mode 440; bash -n both, check-bash32 clean, shellcheck error clean
- [x] 4 server (A.4, A.5): unittest discover 126 OK; test_public_readonly.py diff empty; ast 3.10 and a real Python 3.9 compile ok for 4 files; vui-tests/server/check_server.py 128 pass / 2 fail (both = finding 2)
- [x] 5 page (A.6): node --check OK; helpers 74/75 (fail = finding 1); streamLineHtml 5/5; walks pass in every scenario and slot except the fw16 variant (finding 1); xss variants: nothing executes; coordinator extra confirmed
- [x] 6 cross-file: no updater/CI reference to ui/dev, ui/tests, ui/test_*; none has a sidecar; UI_BUNDLE lists only shipped files; the 4 UI sidecars match the working files; __pycache__ is ignored; engines accept the helper argv
- [x] 7 implementer cross-check: ui/tests/helper_test.sh 205/205 under 3.2 and 5; unittest 126 OK
- [x] 8 report handed back

scratch dir: /private/tmp/claude-501/-Users-grant-coding-telcoin-tn-node-deployment/eddb430f-f0dc-43fe-9180-65cd421b1e88/scratchpad/vui-tests/

## Tests run
- vui-tests/helper/harness.sh (/bin/bash and bash): 215/215 each
- vui-tests/sudoers/check.py on the rendered heredoc: 406 pass; /usr/sbin/visudo -cf: parsed OK
- vui-tests/installer/run.sh (RUNBASH=bash and /bin/bash): 60/60 each
- ui-venv python -m unittest discover -s ui -p 'test_*.py': 126 OK
- vui-tests/server/check_server.py: 128 pass, 2 fail (finding 2)
- vui-tests/page/helpers.test.mjs: 74 pass, 1 fail (finding 1); sl.test.mjs 5/5
- vui-tests/page/run-walks.sh: public/private/unserved/legacy in both slots, fresh, fresh nodns, fresh-reject, xss x3, fw16
- ui/tests/helper_test.sh: 205/205 under 3.2.57 and 5.3.15

## Open issues (detail in the hand-back report)
1. error  index.html fwExtraPorts ignores p2p_ports `allowed` (firewall-setup 1.6.0 shape): a closed worker port shows "reported"; raw labels; serve.py fixtures use shapes firewall-setup never sends
2. warn   server.py setup 400 texts are not sentences and name the API field (`send rpc_domain`); host_error starts lowercase
3. warn   index.html role notice says "The validator view is from a cached/unknown answer" while the full-node view is shown
4-14. notes: serve.py fresh-reject answers its own 400 text; uncached helper-version failure logs a sudo denial per poll; API above required reads "outdated"; setup-node.sh stale comment; pre-existing onclick quoting; pre-existing line-number ref; log tail still EventSource; bootstrap_peers residual path disclosure; installer EOF read; default-role text when no address; stepPreflight null write
