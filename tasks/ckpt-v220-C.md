status: done

Agent C, scripts-v2.2.0: the updater's reinstall hint after a key-set refusal.

Completed sections:
- S1 update-scripts.sh: REINSTALL_HINTED=0 global (line 352-353); reinstall_hint gets a
  comment and prints at most once (537-544); verify_manifest comment documents [nohint] and
  the hint (641-649); hint for NOSIG/EXPKEYSIG/REVKEYSIG unless 5th arg nohint (667-671);
  check_release's installed-record call passes `quiet nohint` (1177). bash -n, bash32 lint,
  shellcheck error: clean.
- S2 tools/tests/updater_manifest_test.sh: helpers RI_HINT1/RI_HINT2, ri_hint_count,
  ri_hint_after after refused(); new checks in wrong signer (2), tampered manifest (1),
  expired (1), revoked (1), check tampered record (2), check newest signed by another key (2),
  new cases check installed record signed by another key (rc + says + 2) and installed record
  and newest signed by another key (rc + two refusals + 2). No existing check changed.
  Against HEAD's updater: 6 new checks fail; mutation without nohint: 2 fail; mutation
  without the once flag: 1 fails.
- S3 verified: bash 5 and /bin/bash 3.2: updater_manifest 292/0, release_scripts 167/0,
  install 113/0, cut_release 119/0. TN_TEST_FAKE_GPG=1: 291/0, 1 skip. bash:3.2 container:
  288/0, 2 skips (both pre-existing). shellcheck error severity clean on both files.
  Wrong-signer output captured (in the final report).

Notes:
- Wrong signer comes out of tn_sig_verdict as NOSIG (ERRSIG code 9 / NO_PUBKEY go to the unknown list).
