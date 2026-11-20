status: done (VA-S, verifier of build-site.sh at 0ee1951) - verdict FAIL, small fix validated

harness: /var/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/9e8efab4-ccd8-4e70-8b1b-387187e040a7/scratchpad/vas/harness
(lib.sh + check1..check10, check5b, check6k, check6k2, checkfix; results in ../logs/<check>.results)

finished checks:
- check1 static: shellcheck clean, no disable, set -euo pipefail, nothing sourced/eval'd (3/3)
- check2 red/green: RED rc1, one gate line (gate 5 spec, 36 hits), no out; GREEN rc0 (5/5)
- check3 green output vs contract: 48/48
- check4 truncation (first/last) gate 2, version bump (1st/3rd/last) gate 4: 5/5
- check5 gates 0-5 + multi-failure: 62/62; check5b gate 6 + templates: 11/11
- check6 usage/safety: 38/38 + SIGTERM sweep (28/31 killed) + build-phase TERM/INT (20/20),
  no leftovers. info: corrupt .git/index -> rc 128; relative <src> "v=1" -> bogus gate 3.
- check7 src read-only: 5 fingerprints unchanged, control proves sensitivity (6/6)
- check8 hostile: 22 pass, 6 FAIL (symlinks followed x3 + environ demo, skip-worktree,
  assume-unchanged, clean filter in <src>/.git/config runs)
- check9 sparse emulation: 7/7, source_tree equal to full clone
- check10 determinism: 4/4, only built_at differs (also other TZ, LANG, cwd)
- checkfix: tracked() replaced by a byte-for-byte HEAD comparison + symlink refusal in
  sites/fix/build-site.sh: 16/16 (closes symlink and index-flag cases, keeps all others)

note: RED/GREEN object files share inodes (39 hardlinks) with the harness's local bare
clones; mtimes of 7 objects changed at 13:09:38 (git freshening through a hardlink, not the
script, which only saw RED/GREEN via read-only mounts). HEAD and status unchanged.
