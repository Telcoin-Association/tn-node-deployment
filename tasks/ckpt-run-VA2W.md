status: done (all six checks finished; verdict PASS WITH NOTES)

# VA2-W checkpoint

Scratch: /var/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/9e8efab4-ccd8-4e70-8b1b-387187e040a7/scratchpad/va2w
(siteclone/ = site repo clone, src/ = GitHub clone checked out at PR2 0e21144, _site built;
pr2-base/, pr2-reg/ = PR2 clones; viol/ = violation clones; scripts/ = my scripts;
site/ = regression build; regress-check3.txt, regress-check5.txt = harness output)

## Finished checks

1. Workflow: PASS. Diff touches only the concurrency comment and group; actionlint rc 0, no
   output; shellcheck rc 0. All deploying runs (push main, dispatch main, repository_dispatch =
   default branch) share pages-refs/heads/main; branch runs get their own group and skip
   deploy. No overlap, order kept. Comment true. Info: re-running only an old run's deploy job
   can redeploy an older artifact (manual, pre-existing).

2. Site README changed lines: PASS WITH NOTES.
   - Rows 0/1 match committed() and the logo check. PR2 logo sha256 = LOGO_SHA256.
   - Build locally as written: clone of GitHub main 2d1bdc7 FAILS gate 5 (tech spec 36 hits),
     rc 1, no _site. With PR2 0e21144 checked out in src: rc 0; 127.0.0.1:8000 serves / and
     aliases 200, PDFs application/pdf; rebuild into existing _site rc 2.
   - "Add or rename" omits README "Checks after a deploy" loops (171, 177) and index.html
     lead/description prose. "Failures of gates 1 to 5" leaves gate 0 unplaced.
   - Unchanged parts still true.

3. One-time setup: PASS WITH NOTES. Order matches GitHub docs (verify domain; add domain in
   GitHub before DNS; immediate subdomains covered). DNS today: CAA allows letsencrypt.org;
   run.telcoin.network and a random name resolve to Vercel 216.150.16.129/216.150.1.65
   (wildcard); _github-pages-challenge-telcoin-association TXT exists. Step 5 fails today
   (gate 5 on main). Step 8 removes environment:, so it never tests step 3; deploy-pages
   source sends no environment (artifact_id, pages_build_version, oidc_token). Retirement
   order right but incomplete (TTL wait, unpublish, wildcard fallback).

4. PR-2 statements: PASS. Violations rc 1, no output: t1 day-date gate 3; t1b month bump
   gate 4; t2 renamed OFL.txt gate 1; t3 changed logo gate 1; t4 dirty .md gate 0; t6
   committed symlink gate 0; t5 unread files rc 0. build-partner-pdf.sh accepts
   "20 November 2026" (rc 0). PR2 commits not on main: 35214c4, 2e6ce45, 797dcb5, 0e21144.

5. Cross-repo agreement: PASS WITH NOTE. Publish rule, currency check, short-link rule and
   document list agree. Workflow header comment still says "a partner PDF change".

6. Regression: PASS. check3 49 PASS 0 FAIL; check5 113 PASS 0 FAIL; landing 1.1 1.1 1.9 1.3.
