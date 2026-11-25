status: done

Agent A, scripts-v2.2.0 round: third release key (sstanfield).

Completed sections:
- S1 done: submodule vendor/tn-release-signing at 172be748508160d3aba03f2378d0c0a76a5a7e31,
  gitlink staged (git add). FETCH_HEAD of origin main == 172be74 (origin has not moved).
  Diff 813fcf4..172be74: M KEYS.md, A keys/sstanfield.asc, nothing else. Key: ed25519 [SC]
  9D72ECBEE3AA983FA8671DA511423DE08DDE052C, expires 2028-11-19; matches KEYS.md row
  (@sstanfield, main, added 2026-11-20 upstream) and https://github.com/sstanfield.gpg.
- S2 done: lib/release-keys/sstanfield.asc (new, 1 armored block, LF, ends in newline) from
  the object store at 172be74. grantkee.asc and MavenRain.asc cmp-identical to keys/ at 172be74.
  Sidecars untouched (note: lib/release-keys/README has a README.sha256 sidecar, which S5 makes
  stale; the orchestrator regenerates it).
- S3 done: update-scripts.sh line 297, SCRIPTS row for sstanfield.asc after MavenRain.asc.
- S4 done: install.sh lines 283-301, the 19 lines of sstanfield.asc appended to the
  TN_RELEASE_KEYS heredoc, right before the terminator (now line 302). Built with the awk of
  release-scripts.sh rewrite_installer (keys_concat order, LC_ALL=C), TN_SCRIPTS_TAG untouched;
  the embedded block cmp-equals the concatenation of the three key files. Mode 755 kept.
- S5 done: lib/release-keys/README: line 56 "The same maintainer key signs" -> "keys sign";
  line 98 table row sstanfield; lines 100-102 "All three are ..." (rewrapped 3 lines, <= 80
  cols); lines 114-115 expiry sentence lists all three. Other "both"/"two" uses (66, 155) read
  correctly with three keys and stay.
- S6 done: check-release-keys.sh rc 0 naming MavenRain.asc grantkee.asc sstanfield.asc;
  bash -n and check-bash32 clean on update-scripts.sh and install.sh; the five fixture tests
  pass under bash 5.3.15 and /bin/bash 3.2.57 (0 failures, 0 skipped); no test edits needed.
  grep: the only shipped place naming key files one by one is update-scripts.sh SCRIPTS
  (now three rows); tests strip key rows generically.
