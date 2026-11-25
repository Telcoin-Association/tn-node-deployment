status: done

# Docs fix agent G (review round, scripts-v2.2.0)

Completed items:

1. Hint narrowed to NOSIG and EXPKEYSIG (code checked: verify_manifest case is `NOSIG|EXPKEYSIG`,
   bootstrap passes nohint).
   - OPERATOR.md 952: "expired or been revoked" -> "expired"; 953 kept (BADSIG); new 954: no hint
     for a revoked key, with the one-sentence reason.
   - README.md 1428: bullet now "or the signing key has expired"; adds revoked key gets no hint
     with the reason.
   - README.md 2368-2375: Changelog bullet rewrapped: expired key only; revoked key and first-run
     bootstrap get no hint, with the reason.
   - CHANGELOG/scripts-v2.2.0.md 355-374: bullet "has expired"; paragraph adds revoked key reason
     and the first signed run (bootstrap) gets no hint.
   - CHANGELOG.md 21-23: "signed by a key that has expired"; no hint for a revoked key, which the
     installer refuses too.
   - AGENTS.md 925-935: verdicts NOSIG/EXPKEYSIG; REVKEYSIG with reason; BADSIG/EXPSIG/ERRSIG;
     bootstrap keys (nohint); "never prints twice" kept; THRESHOLD sentence added.
2. AWS contradiction.
   - README.md 252-253: stack itself needs no change; its scripts do: installer once as `ubuntu`,
     as the paragraph above says.
   - OPERATOR.md 791-792 ("Changing the stack later"): same, pointing at **Updates** above.
3. OPERATOR.md 775: "once setup has written `/etc/telcoin/.node-meta`, its association fails ...
   on each daily run until ...".
4. Key id generalised.
   - CHANGELOG/scripts-v2.2.0.md 91-92: banner and `Latest release: scripts-v2.2.0` first; output
     ends with these lines; exits 1. 102-104: id is grantkee's ed25519 key, which signs this
     release; a later release names its signer's id. 607 table row: `<id>`, value for this release.
   - OPERATOR.md 947-948 (4.1): warning with `<id>`; new line: for scripts-v2.2.0 the id is
     28FD56AD2F9FAE47, grantkee's ed25519 key. Troubleshooting row (~2728): message cell `<id>`,
     cause cell names the value for scripts-v2.2.0 (one mention).
   - README.md 1465: warning with `<id>`, plus one sentence giving the value for scripts-v2.2.0.
5. CHANGELOG/scripts-v2.2.0.md 120-124: update-scripts 2.0.0 host stops with `Release
   scripts-v2.2.0 has no MANIFEST.sig; nothing was changed.`; same installer remedy. (Verified
   against commit 2570ab6, SCRIPT_VERSION 2.0.0: `Release $1 has no $2`, $2 = MANIFEST.sig.)
6. CHANGELOG/scripts-v2.2.0.md 115-117: `sudo bash ~/telcoin-node-scripts/ui/install-ui.sh
   --update`. Left: lines ~167 and ~555 (other sections) keep `sudo bash ui/install-ui.sh`.
7. lib/release-keys/README 56-59: same keys sign node and script releases; script releases signed
   since scripts-v2.1.0, the first signed one; these keys sign them from scripts-v2.2.0. 80-col wrap.
8. followup.md:
   - ~83-89 (v0.18.0-adiri item): tag listing runs when the API cannot be read or lists no final
     testnet release; DEFAULT_DOCKER_IMAGE when that listing gives no image and when the newest
     release's signed files cannot be downloaded or checked; registry digest for a named tag with
     no signed release and when no release key is installed.
   - ~65-70 (1-of-3 item): THRESHOLD verdict sentence.
   - new item after the release-scripts.sh key-set check (~50-53): installer hint and install.sh
     always install to ~/telcoin-node-scripts (INSTALL_DIR readonly).
9. Sweep: no branch-added line matches the four phrases (left: CHANGELOG.md 272, 386 history;
   README 1494 and followup 623 are about gpgv/verify-tag exit status, not the hint). Table rows
   touched: OPERATOR troubleshooting row 4 pipes = header; release-note refusal row 3 = header.
   No em dashes added.
