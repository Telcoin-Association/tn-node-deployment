status: done

Agent D2, scripts-v2.2.0 round. Files: CHANGELOG/scripts-v2.2.0.md, CHANGELOG.md.
Coordinator corrections applied: AWS stacks use the sudo -u ubuntu form; hint lines carry `->`, no [INFO].

Completed sections:
- S1 done (CHANGELOG/scripts-v2.2.0.md):
  - summary ~7-10: gateway testnet pin (v0.18.0-adiri IMAGE_DIGEST-worker-gateway), devnet by digest, mainnet no pin.
  - intro keys paragraph ~53-61: three keys; 2.1.0 hosts cannot use update-scripts.sh -> new section; updater hint pointer.
  - component table: sstanfield key (new).
  - NEW section "## Updating from scripts-v2.1.0" after the table (two refusal lines, one-liner, who is affected, AWS sudo -u ubuntu form).
  - release keys table: sstanfield row; "Either key" -> any of the three + YubiKey sentence; 813fcf4 -> 172be74; 2.1.0 bullet trimmed to pointer.
  - setup-gateway bullet: "pins none" -> testnet pin full digest, mainnet empty.
  - update-scripts: tracks sstanfield.asc.
  - file table: sstanfield.asc row.
  - message table: 2.1.0 refusal row -> new section; gateway refusal row -> mainnet only; v0.18.0-adiri on 2.1.0 row -> new section.
  - Left open: gateway item -> mainnet pin only.
- S2 done (CHANGELOG/scripts-v2.2.0.md):
  - intro ~12: v0.18.0-adiri published 2026-11-24, first signed release on testnet.
  - update-scripts 2.2.0: new bullet, installer hint (NOSIG/EXPKEYSIG/REVKEYSIG; not BADSIG/EXPSIG/ERRSIG; once per run; `->` lines).
  - Node Manager UI 2.1.3: click 8.5.1 bullet (PR #63), install-ui --update rebuilds venv.
  - AWS section: opens "new since scripts-v2.1.0 (PR #71)"; existing-stacks bullet now says scripts need installer once as ubuntu.
  - Left open: removed "telcoin-network main still lists RSA key" item; added AWS publish not wired; added release-scripts key-set check follow-up.
  - No "planned v0.17.0" text found in the note.
- Coordinator correction 2: release note "Updating from scripts-v2.1.0" code block now five lines (warning, three gpgv lines with <date>, [ERROR]); no "two lines"/"exactly"; message-table row names the warning before the error.
- S3 done (CHANGELOG.md):
  - new top entry of ## Unreleased "Testnet worker-gateway pin, a third release key and the updater's installer hint ... -- lib/gateway 2.2.0, update-scripts 2.2.0" (pin, v0.18.0-adiri first signed, sstanfield key, hint, versions unchanged, 2.1.0 remedy + AWS ubuntu user).
  - release keys entry: added one line "Later in this cycle a third key, sstanfield's, was added".
  - Worker gateway entry Limits: added one sentence, testnet pin set later, mainnet still refuses.
  - Worker-gateway pins entry: added one line after "Both pins stay empty", testnet pin set later; kept "With both pins empty it downloads nothing and passes".
- S4 done: sweep. Release note: no hits left. CHANGELOG.md Unreleased: left as history with an added pointer sentence: "embeds both" (release keys entry), "Limits: no signed telcoin-network release ..." (Worker gateway entry), "Both pins stay empty" and "With both pins empty it downloads nothing and passes" (pins entry). Outside Unreleased-cycle window: line ~383 "expires 2028-10-16" in "Mainnet hardening round, October 2026 -- scripts-v2.0.0" entry (released history, beyond the 230-line window), left.
- S5 done: read-through as 2.1.0 and fresh-host operator; rewrapped intro line ~13 and the new section's lines; hint bullet reworded (hint already existed for other refusals in 2.1.0; ERRSIG worded as "gpgv reports an error", not "cannot check", which reads like the NOSIG "Can't check signature" line). diff --stat: CHANGELOG.md 27 +/-, CHANGELOG/scripts-v2.2.0.md 160 +/- (149 insertions, 38 deletions).
Remaining: none.
