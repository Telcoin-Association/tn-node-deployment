status: done

Agent D3 (scripts-v2.2.0 round): AGENTS.md and followup.md.

Completed sections:
- S1 AGENTS.md "Self-update and integrity contract":
  - ~911-918 Rotating bullet: keys of grantkee and MavenRain -> grantkee, MavenRain and
    sstanfield; quotes the 2.1.0 refusal text (no remedy named); adds the three-YubiKey sentence.
  - ~919-924 new bullet "The reinstall hint": verify_manifest calls reinstall_hint after the
    "not signed by a Telcoin release key" error for NOSIG/EXPKEYSIG/REVKEYSIG, not BADSIG/EXPSIG/
    ERRSIG; never twice; keep it. (Code at time of writing: hint NOT yet in verify_manifest;
    re-check at end.)
  - ~925-928 Key expiry: added sstanfield 2028-11-19 9D72...052C; "From that date" -> "From its date".
  - ~948 cut-release prep: "else the one key" + "with three keys there, it refuses until --key
    or user.signingkey names one" (pick_key dies on n>1).
  - Left: 857 "rerun the installer one-liner" (true), 883 grantkee.asc bootstrap (true),
    1277 throwaway key test line (check tools/tests diff at end).
  - Coordinator note: no `[INFO]` quoted anywhere (checked).

- S2 AGENTS.md "Worker gateway" / CI:
  - ~517-520 pins bullet: added "From scripts-v2.2.0 the testnet pin is set (v0.18.0-adiri image,
    line in lib/gateway.sh) and the mainnet pin is empty, so a mainnet enable refuses (quoted)".
  - ~566-568 fixture list: gateway_setup_test.sh first checks shipped pins (set together, pass
    _gw_pin_ok), then blanks both pins. Checked against test lines 308-322 (block present).
  - ~1181-1183 CI manifest job: added "with the testnet pin set ... downloads that release's
    signed files and checks the pin".
  - Fixture tests section 1294-1300: nothing stale.

- S3 followup.md (Release prep + AWS):
  - removed old 22-30 item "no RELEASE/MANIFEST on main yet; first ceremony" (closed: RELEASE on
    main names scripts-v2.1.0 2026-11-10; file convention = remove closed items).
  - ~28-30 key expiry: added sstanfield 2028-11-19 9D72...052C.
  - ~34-45 2.2.0 key item: three ed25519 keys; quotes 2.1.0 refusal; AWS stacks + sudo -u ubuntu
    one-liner (coordinator text); docs give the one-liner keyed on the refusal; 2.2.0 updater
    names the installer. Still open.
  - removed old 47-50 item (telcoin-network main RSA key / first tn release signed): closed.
  - ~46-49 NEW item: release-scripts.sh key-continuity check vs previous tag's key set, with
    override; closes when check + test are in.
  - ~61-65 1-of-1 -> 1-of-3, threshold still 1, #40 now possible, remains a decision.
  - ~73-82 v0.17.0 fallback item -> v0.18.0-adiri first signed (2026-11-24); fallbacks go once
    v0.18.0+ everywhere; they stay as fallbacks; 2.2.0 removes none.
  - ~848-849 AWS publish: upload job fails on scripts-v2.2.0 tag until wired; installer untouched.
  - Left: 785-788 README "Node releases" RSA sentence (README is another agent's; re-check end).
    889-894 AWS "Check the template against scripts-v2.2.0" (still open, untested).

- S4 checks: tools/tests/run.sh tools/tests/ci_pins_test.sh -> 62 checks, 0 failures.
  git diff --stat: AGENTS.md 40 (+28/-12 approx), followup.md 66 lines touched.
- End checks:
  - reinstall_hint NOT yet in verify_manifest (calls only at 746, 761, 1022, 1159, 1164 as on
    main); AGENTS.md hint bullet describes the spec behaviour, unverified against code.
  - gateway_setup_test.sh shipped-pin block present (+18 lines); AGENTS.md line matches it.
  - tools/tests diff: only gateway_setup_test.sh; release_scripts/cut_release tests unchanged,
    so the "throwaway key in the SCRIPTS row of grantkee.asc" line stays.
  - README.md:1500 still names the RSA key; followup item "README Node releases" left open.
