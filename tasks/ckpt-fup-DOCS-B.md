status: done

Package DOCS-B: partner guide 1.6 (docs/partner/mno-node-guide/mno-node-guide.md, metadata.yaml, PDF) for scripts-v2.1.0.

## Sections
- [x] 0. Read specs, AGENTS.md "Partner documents", ORCH and package checkpoints, verifier corrections
- [x] 1. Verify each claim against the code in this worktree (mainnet flag, floor call sites, mainnet digest rule, epoch derivation, late vote case, keytool verify, host baseline, token file + --rotate-token, update-scripts --check + expiry, P2P limit, UI P2P field + status link, restore commands tested in ubuntu:24.04)
- [x] 2. mno-node-guide.md edits (chapters per the deliverable list)
- [x] 3. metadata.yaml bump (1.6, November 2026)
- [x] 4. PDF build twice, cmp, pdftotext headings (73 pages, sha256 a2a25c266c66f2468663c6b9c9b92e244d390bbeaff7f38f07378d2aea5e9ab0 both builds; second run "PDF unchanged" and its fresh build/ output cmp-identical; pdftotext lists "3.10 Host baseline (optional)" and "5.9 Key lifecycle", "Version 1.6")
- [x] 5. Gates (private-path grep empty in md/yaml/pdf text; no line refs; no em dashes; bash -n on every new bash block; code lines <= 90; heading links checked by the build; no support@/grant@) and commit 0d8a3b0

## Operator-visible changes
(none: docs only)

## Docs notes
(n/a)

## Tests run
- build: docker tn-pdf-tools:latest (pandoc 3.8.3, WeasyPrint 70.0) twice, cmp identical
- restore commands (groupadd/useradd/install -d/tar/chown/passfile) run in ubuntu:24.04 against lib/common.sh: tn_service_user_ok ok, _tn_data_layout_dir rc 0, _tn_passfile_trim_safe ok

## Open issues
- Orchestrator note (mid-task): four behaviours change on the implementers' branches after 17bd2d8; the guide writes the NEW behaviour, which this worktree's code does not show yet: (1) an explicit TN_EPOCH_WAIT_MAX is kept, never raised, with a warning; (3) remove-node keeps the P2P limit boot copy and the host baseline while another node unit remains; failed --host-baseline install leaves nothing behind. Items (2) push URLs and (4) Manage node ports are not in the guide.
- Script messages name support@telcoin.org (update-scripts.sh expiry warning, install.sh, check-node.sh, setup-node.sh); the partner guide's only contact is devs@telcoin.org, so the guide says devs@ there.
- edit-config.sh --help still says the wait applies "when the boundary is within five minutes": true for testnet's 6 h epoch, stale for a longer epoch (derived margin up to 900 s). Code owner's fix.
- Claims left out: the scripts-release by-hand check of OPERATOR.md 4.10 (the guide's by-hand check is the node release; the scripts check names a signer identity address); Alloy TLS pin and push URLs (not operator procedure, guide does not mention push URLs); Manage node ports limit rewrite; check-node unknown-network note; any statement that no node release has keytool verify yet (not shown by this repo).
- Restore: the scripts never re-own a restored data dir, so the guide gives groupadd/useradd/install -d/tar/chown and the passphrase file; tested against the library checks in ubuntu:24.04, not as a full setup run.
- format-output agent not run; the guide's one-sentence-per-line layout was kept by hand.

