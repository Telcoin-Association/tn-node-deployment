status: done

# V-A checkpoint: independent verification of WP-A (update-node.sh 1.2.1)

Scratch: /tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/3531cc68-33b7-4621-a420-efdcb7057faf/scratchpad/va-tests/
Harness: va-harness.sh <repo> [<old common.sh>]; baseline lib for skew = `git show df82deb:lib/common.sh` (COMMON 1.6.0) saved as common-df82deb.sh.

## Sections
- [x] 1. Diff review against the contract (a-n). Summary:
  (a) all four apply paths call storage_migration_begin before backup/epoch-wait/stop and put the
      STORAGE_MIGRATION block right before their rollback block (update-node.sh :717, :1089, :1791, :1891;
      blocks :810, :1189, :1849, :1950). OK.
  (b) done shape is byte-identical to contract §3.2; json_emit sets JSON_DONE_SENT so update_on_exit adds
      none. OK. But a run killed mid-verify gets update_on_exit's synthesized done with no
      storage_migration and no rolled_back (to test, X4).
  (c) rolled_back:true paths untouched; block gated on STORAGE_MIGRATION, reset to false at every begin. OK.
  (d)(e) marker only in the success branch; verify_failed calls clear_pending_state. OK.
  (f) --check field present in all arms; docker arm with unreadable image gives update_available:false
      + storage_migration:true (unknown counts as older; contract-conformant, odd).
  (g) both JSON prepare paths call begin after write_pending_state, before done. OK.
  (h) numeric wins incl. "0" (immediate failure, contract-conformant); "0900"/"08" pass the regex but
      (( )) reads them as octal -> loop runs 0 times (pre-existing since 1.2.0). LOW.
  (i) semantics match design; callers always strip with ##*/ (raw `10.0.0.5:5000/x:v0.15` would be
      misread as 10.0.0, but no caller passes raw). "v0.16"->"v0.15" (two-part) gives rc 0, not the
      design table's 1 (table meant x.y.z).
  (j) awk filter keeps only /epoch-N$ paths, never counts leftovers; no dir / empty / unreadable -> rc 1.
      Default awk FS splits a data dir path containing a space -> under-warns. LOW/NIT.
  (k) no bash 4 constructs seen (lint in §3).
  (l) every new global initialised at top (VERIFY_TIMEOUT_EXPLICIT, STORAGE_MIGRATION, UPDATE_HEALTH_OK);
      ${1}/${2} in verify_failed always passed. OK by reading; harness checks err files.
  (m) JSON mode returns before confirm; interactive confirm reads the terminal stdin (no fd swap). OK.
  (n) tn_resolve_data_dir (fallback.sh, unchanged since df82deb), version_gte, confirm exist in every
      lib; no new declare -F guard needed. OK.
  Extra from reading: message says "The node was left running" even when the unit never started;
  v0.16 rejects --observer / wildcard advertised addrs at startup BEFORE opening the store, yet the
  one-way path never rolls back (design trade-off, node left down); re-apply after a killed one-way
  apply backs up the NEW binary, so the printed undo restores the wrong file; interactive main exits 0
  after a failed apply (pre-existing).
- [x] 2. Own harness (scratch va-tests/va-harness.sh; suite runs twice: lib 1.6.1 and skew lib 1.6.0 from
  df82deb). Commands:
    TMPDIR=$D bash $D/va-harness.sh <repo> $D/common-df82deb.sh              (host bash 5.3.9)
    docker run --rm -e VA_IN_CONTAINER=1 -v <repo>:/repo:ro -v $D:/h:ro bash:3.2 bash /h/va-harness.sh /repo /h/common-df82deb.sh
    (same with bash:5.2). Prepare cases X6/X7 run only in containers (they write /tmp/tn-update-build.log).
  Results on the working tree: host bash 5.3.9 PASS=328 FAIL=4 OBS=12; bash 3.2.57 PASS=336 FAIL=4 OBS=12;
  bash 5.2.37 PASS=336 FAIL=4 OBS=12. The 4 FAILs are 2 confirmed defects x 2 suites:
    F1 TN_UPDATE_VERIFY_TIMEOUT=0900 -> "value too great for base", verify loop runs 0 times (window prints 0900).
    F2 data dir path with a space -> du/awk split, shortfall never warns.
  OBS (not failures): X4 killed mid-verify -> exactly one done (synthesized) but without storage_migration /
  rolled_back; X4 re-apply after the kill -> undo cmd restores a .bak holding the NEW binary; X1 start never
  succeeds -> msg says "left running"; A6c unreadable docker image -> update_available:false +
  storage_migration:true; truth-table notes (two-part versions, raw IP registry, both moot).
  Everything else green on all three bashes and with COMMON 1.6.0: all 8 design cases, explicit 300/abc/0/-1/
  " 300 "/"" windows, start failure, source+docker identity failure, main --json --check and --json --apply
  end to end, --help and --json --help, prepare warns (docker+source) before their ok done, no
  "unbound variable" anywhere.
  Proposed patch (va-tests/va-proposed.patch, 14+/4-, fixes F1, F2, the "left running" wording, and adds
  rolled_back:false,storage_migration:true to update_on_exit's done on a one-way apply): harness on the
  patched copy PASS=334/0 FAIL (bash 5.3.9) and PASS=342/0 FAIL (bash 3.2); check-bash32 clean, 3.2 parse ok,
  shellcheck finding set unchanged.
- [x] 3. Gates (spec §6), all green:
  bash -n, `/bin/bash tools/check-bash32.sh` ("clean") and bash:3.2 `bash -n` on update-node.sh,
  lib/common.sh, update-scripts.sh; shellcheck (koalaman/shellcheck:stable -x): 0 errors and the finding
  set is identical to df82deb's for all three files (update-node 2 warn SC1090 / 2 info / 1 style;
  common 13 warn / 3 info; update-scripts 2 warn); UI unittest in python:3.10-slim: 135 tests OK;
  ui/tests/helper_test.sh: 205 checks, 0 failed under bash 5.3.9 and bash 3.2.57; all five sidecars
  match their files, gen-checksums.sh ("36 sidecars") is idempotent and `git status -- '*.sha256'`
  lists exactly the five touched files' sidecars. UI_VERSION 1.9.1 bump also makes update-scripts
  redeploy the UI, which is what refreshes /opt/telcoin-ui-update/update-node.sh (the UI's engine copy).
- [x] 4. Reconciled with ckpt-v016-A.md + impl-a-tests/harness.sh (15 cases / 174 checks).
  They had, I did not: explicit-300 NON-migrating apply end to end (I only checked the window/poll count);
  JSON-mode begin with low disk (warn counts); a negative control against df82deb's whole script; their
  harness redirects /tmp/tn-update-build.log into the case dir (cleaner than my container-only guard).
  I had, they did not: F1 (0900 octal) and F2 (space in data dir), both failing tests; kill mid-verify
  (EXIT-trap done lacks storage_migration); unit never starts ("left running" wording); re-apply after a
  killed one-way apply (undo restores the new binary); interactive one-way SUCCESS path (marker written,
  rc 0 at ~150 s); source identity failure (they had docker only); interactive docker 'y' failure;
  json_prepare_source warn (they had docker only); main --json --check / --json --apply end to end; --help
  and --json --help; windows 0, -1, " 300 ", ""; .bak-*/.replaced leftovers and an unreadable epochs dir;
  skew run against COMMON 1.6.0. No disagreement on any shared case.
- [x] 5. Findings + verdict: no BLOCKER/HIGH/MED. LOW: F1 octal timeout (confirmed), F2 space in data dir
  (confirmed), F3 EXIT-trap done lacks storage_migration (confirmed; driver impact for V-C to judge),
  F4 "left running" when the unit never started (confirmed), F5 re-apply undo names the new binary's
  backup (confirmed, pre-existing pattern). NIT: unreadable-image --check, prepare text says 600 s when the
  driver applies with 900, interactive main exits 0 after a failed apply (pre-existing), no UI_VERSION
  1.9.1 history comment although the bump is what ships update-node 1.2.1 to UI users.
  Verdict: ship after these fixes (patch va-tests/va-proposed.patch, tested); none blocks the fleet roll.
