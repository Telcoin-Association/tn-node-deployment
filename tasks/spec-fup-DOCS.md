# DOCS: documentation for scripts-v2.1.0 (issues #34, #32, #33, #43, #44, #46 and every package)

Read `tasks/spec-fup-shared.md` first, then every `tasks/ckpt-fup-*.md` "Docs notes" and the
verifiers' records under `tasks/verify-fup/`. Worktree `~/coding/telcoin/tnd-fup-DOCS`,
branch `fup/DOCS` from the integration branch AFTER the last code commit, checkpoint
`tasks/ckpt-fup-DOCS.md`.

## Owned files

`README.md`, `OPERATOR.md`, `AGENTS.md`, `WGVPN.md` (only if a fact there changed),
`docs/testnet-addons.md`, `followup.md`, `docs/partner/mno-node-guide/mno-node-guide.md`,
`docs/partner/mno-node-guide/metadata.yaml` (version "1.6", date), the rebuilt
`docs/partner/mno-node-guide/mno-node-guide.pdf`, new `CHANGELOG/scripts-v2.1.0.md`.
Not the technical specification.

## Sources of truth

The code on the integration branch (verify every sentence you write with grep or by running
the script's `--help`), the package checkpoints' "Docs notes", the verifiers' findings. Write
nothing a checkpoint claims that the code does not show.

## Required content

1. Wording sweep (#34, nine findings of the triage; verify each still applies on the branch):
   health port 43174 described as "testnet" where it is the devnet/kuma monitor source; the
   plaintext passphrase file called "testnet only" (check the code: it is refused on mainnet
   and on devnet?); floor messages that pair systemd 250 with Ubuntu 24.04 (24.04 ships
   systemd 255; say what the code checks); README and partner manual "verify a release by
   hand" skipping the chain-config lines (bring both up to OPERATOR.md 4.10, #44);
   `/etc/credstore.encrypted` in docs/testnet-addons.md:208 (OBS changed the unit: write the
   real path); `ui/server.py:4940` docstring (the orchestrator hands you the finding; if it is
   code, hand it back as an open issue instead); `followup.md:427` stale item; "per-operator
   token" wording where the token is per-hub today.
2. followup.md: close the items this PR fixes (remove or mark done with the commit), rewrite
   :50-53 (mainnet images: the repository is ghcr, the remaining gap is the tag-scheme
   confirmation #46 and the U-6 issue #1728), put the telcoin-network issue numbers
   #1725-#1735 at :10-11 (they are posted), record the deferred 2-of-N (#40) and #39.
3. Per package: README (reference), OPERATOR.md (runbook), partner guide (operator
   procedure, plain language), AGENTS.md (conventions): LIB-A mainnet flag and refusals,
   floor on update/edit paths, digest rule; LIB-B epoch derivation (replace the 300/90
   sentences in AGENTS.md "Restarts and the epoch boundary", README, OPERATOR), cap rule,
   check-node network note, the #33 late case with `TN_UPDATE_VOTE_ROLLBACK` (partner guide
   too); KEYS runbook chapter in OPERATOR.md (backup, restore after the old host is gone,
   snapshots, rotation, decommissioning, lost passphrase; mark the `keytool verify` step as
   active only on releases that have it, #1730) and the `remove-node` note; AUDIT
   `--host-baseline`; OBS token file, rotation, TLS pin, sync-note sha; REL `expires=`,
   `--check`, check-node block; FW the limit; UI-S the P2P field and status link; NET-2 the
   marker (AGENTS.md "Lints"); GOV the CI section and a "Contributing" note (required
   contexts, signed commits once #30's ruleset is on, no job renames).
4. `CHANGELOG/scripts-v2.1.0.md` in the style of `CHANGELOG/scripts-v2.0.0.md` (read it),
   plus the README changelog entries per bumped script (one `### <script> v2.1.0` paragraph
   each; the orchestrator gives you the final list of bumped files: every touched tracked
   script, lib/common 2.1.0, lib/observability, ui/server.py 2.1.0, update-scripts 2.1.0).
5. Partner guide 1.6: only what an MNO operator does differently (mainnet is still not
   selectable: say so plainly; the rotation command; the baseline flag; the release check
   command; the late-update paragraph). Rebuild the PDF with the documented container
   command; commit the PDF.

## Gates

The private-ops-path grep of the shared spec finds nothing; no line-number references in prose; the `human-writing` skill's
rules (no filler, no em-dashes, specific verbs); every command you quote runs as written
(`bash -n`-level check of snippets, `--help` for flags); the sync-note sha equals
`sha256sum observability/config.alloy`; markdown link targets exist; the PDF builds
byte-identically twice.
