status: done (2026-11-20) - all sections finished; hand-back sent

finished sections:
- script: build-site.sh (sha256 d9292e99...). Gate 0 per-file HEAD comparison (committed()), HEAD:docs/partner/
  must be a tree, LOGO_SHA256 pin in gate 1, <src> absolute, CDPATH unset, cd failures -> die,
  git stderr kept apart from show-prefix output, chmod -R u=rwX,go=rX before mv. shellcheck silent.
- tests: harness copy a3/harness-vas (VAS -> a3/vas-run, rm -rf -> aside, expectation changes "A3 E1".."E12",
  check5b copies working script into site clones, checkfix -> $SITE/build-site.sh + makes h-symlink-environ),
  new cases check11.sh 54/54. Run 1 log a3/run-all-1.log; results a3/vas-run/logs/*.results.
  All pass except check6k2 run 1 (one SIGINT run hung in bash, killed by me); 3 reruns pass;
  probes: 240 SIGINT runs of fixed script 0 hangs (a3/probe-int-new*.txt), 40 original 0 hangs,
  300 minimal-script runs 0 hangs.
- workflow: concurrency group pages-${{ github.ref }}, comment rewritten; actionlint silent.
- README: who decides; gate rows 0/1 + sentences under the table; --bind 127.0.0.1 and 127.0.0.1:8000;
  'a file the site reads'; 404.html + Links table + logo paragraph; one-time setup as steps 1-8 + retire.

notes: RED/GREEN object mtimes changed (hardlinks shared with harness bare clones, git freshening);
  fsck clean, HEAD and status unchanged.
