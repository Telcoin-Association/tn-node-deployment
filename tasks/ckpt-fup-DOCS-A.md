status: in-progress (handed back at budget; sections 6-8 for a fresh agent)

DOCS-A checkpoint (Markdown docs of scripts-v2.1.0 except the partner guide).

## Sections
- [x] 0. Read specs, package checkpoints (Docs notes, Operator-visible changes), verifier corrections
- [x] 1. docs/testnet-addons.md (sync note, token file, TLS pin, credential path, firewall limit); WGVPN.md check
- [x] 2. AGENTS.md (restarts/epoch, self-update contract, Lints, CI, Contributing, host baseline, token file, vendored upstream)
- [x] 3. OPERATOR.md (key lifecycle chapter, host baseline, token rotation, release check, late post-update case, epoch defaults, firewall limit, #34 items)
- [x] 4. README.md reference entries + #34 items
- [x] 5. README.md "verify a release by hand" brought up to OPERATOR.md 4.10
- [ ] 6. README.md changelog (one ### <script> v2.1.0 per bumped file)
- [ ] 7. followup.md
- [ ] 8. CHANGELOG/scripts-v2.1.0.md
- [ ] 9. Gates (done for README/OPERATOR/AGENTS/testnet-addons: no private-path mention, no file:line refs in added lines, relative links and anchors resolve, sync sha = sha256sum, check-network-hits rc 0; still to run on followup.md and CHANGELOG/scripts-v2.1.0.md) (private-path grep, line refs, commands, links, sha, check-network-hits)

## Commits
- 9f02b6e docs: testnet add-ons (token file, rotation, TLS pin, P2P limit, sync note, credential path). WGVPN.md: no fact changed (checked).

- c5facaf docs: AGENTS.md mainnet switch, epoch wait, expiry, lint, CI, Contributing, vendored upstream
- aa5a482 docs: AGENTS.md ownership host baseline + token file
- e291b81 docs: OPERATOR.md key lifecycle (4.12), host baseline (4.13), release check, mainnet switch, P2P limit, epoch wait, late case, floor, keytool verify, token rotation, #34 health port/passphrase scope
- e1af9b5 docs: review-round behaviours (orchestrator message): explicit cap kept + warned, push URL override marker, remove-node keeps P2P limit + baseline beside another node, unchanged limit not rewritten, failed --host-baseline leaves nothing
- NOTE: the five review behaviours are written from the orchestrator's message, not from code (fixes in flight on implementer branches; this worktree still has the old code). The cap warning text is paraphrased (no exact string yet). Override clearing is written "re-enable with the flag omitted" (orchestrator to correct with OBS's words).
- eed1245 docs: README reference (mainnet switch, floor, digest rule, P2P limit subsection, Host baseline subsection, token file + rotate, release check + expiry, manual release checks with chain configs, epoch wait, late case, keytool verify, check-node lines, UI P2P field/limit row/status link/LimitCORE, remove-node teardown, #34 health port + passphrase scope)

## Remaining for a fresh agent (sections 6, 7, 8, then gates)
- 6. README "## Changelog" (heading at about the 1630s now; first entry "### lib/common v2.0.1 ..."): add one `### <script> v2.1.0 — <summary>` paragraph each, newest first, in the existing style (read the 2.0.0 entries), for: check-node, edit-config, firewall-setup, install-caddy, remove-node, setup-node, setup-observability, setup-vpn, update-node, update-scripts, ui/install-ui (install-ui: comment-only change of its sudoers comment), lib/common (COMMON_VERSION), observability (OBSERVABILITY_VERSION; config.alloy changed), telcoin-ui (UI_VERSION). The README sections written by DOCS-A are the source: P2P new-flow limit, Host baseline (auditd and AIDE), Keeping Scripts Up to Date (Release check, Release expiry), Docker Install Notes (mainnet digest rule), Updating the node, Editing the configuration, Removing a Node, Testnet Add-ons (token file), Restarts and the epoch boundary, UI System tab.
- 7. followup.md (read it; the shared spec says :50-53 mainnet images paragraph is stale, :10-11 says the U issues are not posted, :427 stale item of #34): close what this PR fixes, rewrite the mainnet images paragraph (ghcr; remaining gap: tag-scheme confirmation #46 and telcoin-network #1728), put #1725-#1735, add deferred #39, 2-of-N (#40), manifest reader (#41), and every item of tasks/ckpt-fup-ORCH.md "followup.md items collected this round" plus the open items listed below.
- 8. CHANGELOG/scripts-v2.1.0.md in the style of CHANGELOG/scripts-v2.0.0.md, per script with issue numbers (#33 late case docs, #35 token file, #40 expiry/--check, #41 P2P limit, #43 host baseline, #44 manual check, #46 digest rule, #47 network gating + lint, #49 epoch derivation, #30/#34 governance and wording).
- Orchestrator message (2026-11-03) review-round behaviours are already written into AGENTS/OPERATOR/README/testnet-addons; the CHANGELOG and README changelog must use them too: explicit TN_EPOCH_WAIT_MAX kept + warned (never raised); push URL override recorded with a marker and kept, default follows the release, 2.0.x env file counts as default, "re-enable with the flag omitted" clears (OBS to confirm wording); remove-node keeps p2p-limit.nft and the host baseline beside another node unit (menu and --json keys), torn down with the last; Manage node ports does not rewrite an unchanged table/boot copy; failed --host-baseline leaves no rules/config/marker; firewall lock on every apply path incl. the menu.

## Open issues
- Code wording, not editable by DOCS (#34 "per-operator token" where the token is per hub): setup-observability.sh header and two prompts ("Paste the per-operator obs ingest token", "You need a per-operator ingest token"), lib/observability.sh header comment, lib/common.sh two setup prompts ("Needs a per-operator ingest token", "Paste the per-operator obs ingest token"). Suggested: "the obs ingest token from the Association".
- Code wording (#34 systemd floor item): messages still pair systemd 250 with "Ubuntu 24.04" (Ubuntu 22.04 ships 249, 24.04 ships 255): lib/common.sh tn_os_floor_check "cannot encrypt credentials (needs 250, Ubuntu 24.04)", setup-node.sh setup_passphrase_method "--passphrase-method credential needs systemd 250 or later with systemd-creds (Ubuntu 24.04)" and "On <net> the BLS passphrase is kept only as an encrypted credential (systemd 250 or later, Ubuntu 24.04)" (the mainnet floor is 255), and the --passphrase-method tpm refusal says "below systemd 250 on testnet" (testnet and devnet). Docs (README, OPERATOR) say what the code checks; partner guide quotes the message (DOCS-B).
- OPERATOR.md 4.12 restore commands (groupadd/useradd/install -d/sudo -u telcoin tar, the bash read -rs passphrase file) are derived from create_directories ("an existing data dir must already belong to the service user") and setup_keep_stored_passphrase; not run end to end on a host.
- #34 sweep status: health port wording (README, OPERATOR) done; plaintext file "testnet only" -> "testnet and devnet only" (README) done; systemd 250/24.04 pairing is in code messages (above), docs state what the code checks; README manual release check brought to OPERATOR 4.10 (partner guide is DOCS-B); /etc/credstore.encrypted (testnet-addons) done; "per-operator token" fixed in docs, code strings listed above; followup.md stale item (section 7, not done); ui/server.py:4940 docstring: the finding text was never handed to DOCS-A, not checked.
- The orchestrator's review-round behaviours are documented from its message, not from code in this worktree (fixes in flight): verify against the final integration branch, especially the cap warning wording (paraphrased), the push URL override clearing ("re-enable with the flag omitted"), and that the "Manage node ports" unchanged-limit message exists.
- README "Health Check" bullet list keeps its existing "**Label** — text" style; the new "**Script release** —" bullet follows it (the only em-dash added; pre-existing style).
- human-writing skill asks for the format-output agent pass afterwards; not run (it would reflow README/OPERATOR far beyond this change).
- V1 docs-note correction applied: missing epochDuration does not give "<n>s by default" text; README quotes only the derived and env forms.
- KEYS docs note quoted "a registered BLS key cannot move to another address"; OPERATOR quotes the operator-facing "Refused: <addr> has staked (<status>). Its BLS key is registered to it on-chain..." (V2 D-3).
- AUDIT docs note "Not after ... the credential actions" is stale (c4322d4): docs say the baseline is refreshed after a passphrase action that went through.

