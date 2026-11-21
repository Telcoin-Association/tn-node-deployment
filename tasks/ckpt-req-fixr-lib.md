status: done

# FIXR-LIB checkpoint (worktree tnd-req-fixr-lib, base 1a3404b)

Order: fixes 1, 2, 4, 3, 8, then 5, 6, 7; tests; gates; commit.

## Sections
- [x] read (spec, report, code, tests)
- [x] fix 1 (V-FIX-S-01 clone reason via progress fn)
- [x] fix 2 (V-FIX-S-03 fetch stderr, rev-parse --git-dir, GIT_* unset)
- [x] fix 4 (V-FIX-S-05 in-place means root-owned real dirs; repair)
- [x] fix 3 (V-FIX-S-04 non-file entries refused before write)
- [x] fix 8 (V-FIX-S-10 9>&-, https, no lazy fetch on every git child)
- [x] fix 5 (V-FIX-S-07 mismatch lines name file by tag)
- [x] fix 6 (V-FIX-S-08 non-checkout dir refused before prompt)
- [x] fix 7 (V-FIX-S-09 staging under sweep)
- [x] tests: genesis_hash 192 green host (33 fail on base lib); chain_configs_tag 160 green host non-root (28 fail on base lib). Extra: unreadable blob (partial clone) gets its own message via ls-tree on the failure path
- [x] gates: lints clean; shellcheck no new warnings; whole suite 84/84 host and u26.04+git; five files green host/b32/u26; S5 rerun clean (s5-run2-*)
- [x] commit 92c3111 (FIXR-LIB: chain-config helpers after verification)

## Notes
- Design constraint: tools/tests/chain_configs_refresh_test.sh (not mine) stubs git:
  rev-parse of an unknown ref exits 1, asserts verbs "fetch rev-parse cat-file x3" and
  the exact no-copy text. So fix 2b adds NO git call: rev-parse rc other than 0/1
  (128 = git cannot read the repo) on the fallback lookups refuses rc 1.
- Its stand-in writers do not chmod; host umask 0002 -> 0775/0664 -> fix 4 repairs on
  every run there; keep the existing "already in" line first so its substring holds.
- In place = dest + parent real dirs, owner id -u (root on a host), mode exactly 755;
  files owner id -u, 644. id -u, not 0, so non-root fixtures see their own writes.
- Staging: tn_staging_dir + tag.$$.XXXXXX, fallback mktemp -d (non-root, unusable area).
