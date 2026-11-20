status: done (unit A5)

Done:
- setup: scratch a5/ created; old tree of 4918da6 extracted (git archive) to a5/old-site; harness lib copied to a5/h/lib.sh (paths -> a5); PR2 fsck baseline in a5/logs/fsck-pr2-before.txt (rc 0, 174 dangling objects only)
- pre-edit tests 2+3 on the OLD script (a5/logs/t23-before.log): replace -> rc 0, source_commit 0e21144f, served mno PDF != its blob (hole confirmed); lazy -> rc 1, 17 gate-0 lines + 17x4 "fatal: Could not read from remote repository..." lines, ext:: marker created during the build (hole confirmed). A first attempt (t23-before-probe-bug.log) created the marker in setup via cat-file -e; probe fixed to test the loose file.
- edit done: build-site.sh git_src (one line, as specified) + 4-line comment; README.md line 110 (after "It reads `src` as data..."). shellcheck clean, diff --stat 2 files, diff --check clean.
- test 1 after (a5/logs/t1-after.log): PR2 rc 0, 18 files, sha256sum -c OK (4 lines), verify_out OK; RED rc 1, 1 gate line, gate 5 only.
- tests 2+3 after (a5/logs/t23-after.log): replace rc 1 "error: gate 0: docs/partner/mno-node-guide/mno-node-guide.pdf differs from the file HEAD records (changed and not committed), so source_tree does not describe it"; lazy rc 1, no marker, 17 gate-0 lines + 17 git lines "fatal: transport 'ext' not allowed" (rev-parse stderr not redirected in committed()).
- tests 4+5 after (a5/logs/t45-after.log): CI-shaped clone of PR2 (shallow, blob:none, cone sparse) rc 0, 18 files, objects + FETCH_HEAD unchanged, no "not allowed" line; committed symlink rc 1 "is a symbolic link"; skip-worktree rc 1 "differs from the file HEAD records".
- test 6 (a5/vas-run-all.log, a5/vas-run/logs/*.results): 385 passed, 0 failed, per-file counts identical to the verifier's run; all 10 build-site.sh copies the suite made hold the edit.
- test 7: shellcheck silent; diff --stat 4918da6 = README.md, build-site.sh; diff --check clean.
- test 8: git fsck --full on PR2 rc 0, same 174 dangling objects as the baseline, no replace refs, no partialClone, clean status.
