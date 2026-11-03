status: done

DOCS-C checkpoint (sections 6, 7, 8 of the DOCS round, after DOCS-A's sections 0 to 5).
Order of work: 8 first (so the README entries can link to it), then 6, then 7, then gates.

## Sections
- [x] 0. Read DOCS-A ckpt, shared + DOCS spec, ORCH ckpt, package docs notes, verifier ckpts, README changelog 2.0.x, CHANGELOG/scripts-v2.0.0.md, followup.md
- [x] 8. CHANGELOG/scripts-v2.1.0.md (0fa6be5)
- [x] 6. README.md changelog (14 entries, 415808a)
- [x] 7. followup.md (dfda90d)
- [x] 9. Gates: private-path grep empty on the three files; no line-number refs in added prose (and the three old ones in followup.md replaced); links resolve (CHANGELOG/scripts-v2.1.0.md, scripts-v2.0.0.md#before-you-update, #host-baseline-43); quoted commands parse (bash -n) and their flags exist (--check, --rotate-token, --token-stdin, --enable, --host-baseline, --expires, --require-fresh); check-network-hits clean 146/24 rc 0; no code file touched

## Facts gathered (for a resumed agent)
- Integration branch hardening-followups (read-only) has moved past this worktree's base 17bd2d8:
  dfc85de cap kept + warned (exact text: "TN_EPOCH_WAIT_MAX <cap> is shorter than margin <M> + settle <S> + two polls; the restart may land before the epoch has settled. Set it to at least <need>, or TN_SKIP_EPOCH_WAIT=1 to skip the wait on purpose."),
  c88c24d push URL override marker OBS_PUSH_URL_SOURCE=override / OBS_METRICS_PUSH_URL_SOURCE=override, "--push-url default" clears it, line "The logs push URL follows the release default: <new> (was <old>)...",
  9a038b5 #34 code wording (hub's token, systemd floor messages), df32045 help text margin.
  Not yet on the integration branch when read: remove-node keeps the host baseline beside another node, Manage node ports unchanged limit, failed --host-baseline leaves nothing (written from the orchestrator's statement).
- Issue map: #45 mainnet switch, #46 digest rule, #51 floor, #49 epoch, #47 network gating + lint, #33 late case (docs), #32 keys, #43 host baseline, #35 token, #40 expiry, #41 P2P limit, #44 manual check, #30/#31 governance + CI, #34 wording (closed), #39 deferred.
- telcoin-network: #1725 U-3, #1726 U-4 (closed; PR #694 merged 2026-10-28), #1727 U-5, #1728 U-6, #1729 U-7, #1730 U-8, #1731 U-9, #1732 U-10, #1733 U-11, #1734 U-12, #1735 U-13; U-1/U-2 merged as PR #1715.
- followup.md stale item (#34 triage, line 427 at 8cb1b0b): `_tn_release_sig_ok` NO_PUBKEY item; code now warns on an unknown signer (_tn_gpg_status_verdict). Also NODE_TYPE item: migrate-node-naming 2.0.0 removes NODE_TYPE too.

## Commits
- 0fa6be5 docs: CHANGELOG/scripts-v2.1.0.md describes the release per script, with the new files, keys, variables, refusals and what stays open
- 415808a docs: README changelog has a v2.1.0 entry for each script, library and UI file the release bumps
- dfda90d docs: followup.md drops what scripts-v2.1.0 closed, names the telcoin-network issues, and adds the items this round found or deferred

## Open issues
- docs/testnet-addons.md (DOCS-A, e1af9b5) says "To drop an override, re-enable with the flag omitted"; the code (c88c24d) keeps a recorded override when the flag is omitted and clears it with `--push-url default` / `--metrics-push-url default`. Needs a one-line fix there (not in DOCS-C's three files).
- Written from the orchestrator's statement, not shown by code in this worktree or on hardening-followups at 9a038b5: remove-node keeps the host baseline beside another node unit (the P2P-limit half is in code, 2e4b6db), "Manage node ports" does not rewrite an unchanged limit, a failed --host-baseline leaves no rules/config/marker. `--push-url default` is on hardening-followups (c88c24d), not in this worktree. Check against the final integration branch.
- Left out (code did not show it, or superseded): the ORCH item "audit rules written before the AIDE step, so a failed init leaves the rules and no marker" (superseded by the review fix); AUDIT O-1 "TERM during aide --init leaves the marker and rules without a database" (not re-checked against the review fix); V3 N5 "gate prints 2 blank lines on --json stdout" (not reproduced); V5 notes N1-N7 (text not in the checkpoint).
- README changelog headings keep the existing " — " separator of every other entry (body prose has none). lib/common and lib/observability headings use "lib/common.sh v2.1.0" / "lib/observability.sh v2.1.0" as the brief asked; older entries say "lib/common vX" / "observability vX".
- CHANGELOG/scripts-v2.1.0.md: one line in the governance bullet runs past the 100-column wrap (cosmetic).
