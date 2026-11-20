status: done (all 8 checks), verdict PASS WITH NOTES; report returned to orchestrator

Finished checks: 1, 2, 3, 4, 5, 6, 7, 8
- 1 workflow vs contract: PASS (harness/check1_workflow.py, 37 asserts, uses: lines byte-identical to REF, actionlint silent)

Setup done: VAW/src-green (clone of GREEN ecf035f), VAW/site-repo (clone of site 0ee1951), VAW/site (built, exit 0).
Docs facts fetched (agent a20ab550582ea874c): CNAME ignored w/ Actions (docs quote); 60-day schedule (docs quote);
github-pages env: Actions-source auto env has NO documented branch rule, docs *recommend* adding one; deploy-pages
README: environment "recommended", OIDC ref claim checked; verified domain covers immediate subdomains; wildcard warning;
CAA must allow letsencrypt.org; no documented cache time; repository_dispatch runs default branch.

Notes:
- To test in check 2: symlinked asset (OFL.txt / svg) in src -> does build copy target outside src? SVG script content ungated?
- 2 attack surface: DONE (harness/check2_probes.sh). Findings: P1 tracked symlink OFL.txt -> file outside src is
  followed and served, exit 0 (cp -- at build-site.sh:321,329 dereferences); P2 symlinked PDF -> outside PDF served,
  exit 0; P3 SVG logo with <script> served, exit 0 (no SVG content gate); P4 symlinked dir caught by gate 0.
  No ${{ }} in run:, client_payload unused, checkout 2 ref fixed to main. Env branch rule is the real control; the if: is
  convenience only (branch dispatch uses branch's workflow). Pages acceptance of a deploy job without environment: unproven.
- 3 served output (root): PASS, 56 asserts 0 fail (harness/check3_serve.py in container http.server). 404 body is
  http.server's own, not 404.html (Pages-dependent).
- 4 sub-path /tn-partner-site/: PASS for index, stubs, css fonts, pdfs, aliases (check3 + check4_links_http.py);
  404 page: 8 root-absolute refs leave the sub-path (style, logo, /, 4 aliases) - by design.
- 5 markup/links: PASS (harness/check5_markup.py, 113 asserts 0 fail); note: the 4 stubs have no <h1>.
- 6 README: commands all run as written (URL/host swapped) PASS (harness/check6_readme.sh 30 asserts 0 fail,
  check6_gate6.sh). Exit codes 0/1/2, failed run leaves no/empty out, no temp leftovers, src unchanged incl .git,
  site_commit unknown, sha256sum flow, header/alias/404 loops, source_tree compare. Notes: README Links "Document"
  names differ from titles; "Add or rename" omits site/404.html alias list; http.server binds all interfaces.
  DNS (public dig): run.telcoin.network resolves via wildcard to 216.150.x (Vercel); CAA allows letsencrypt.org.
- 8 housekeeping: PASS. LICENSE-* cmp-identical to REF; modes 100755 build-site.sh only; .gitignore /src/ /_site/
  covers local build (git status clean after build+serve); no person/private address/secret in tracked files
  (only devs@telcoin.org); no Claude trailer in commit msg; fonts LICENSE.txt+OFL.txt served, cmp == src; shellcheck clean.
- 2 addendum: harness/check2_ci_checkout.sh emulates actions/checkout layout (shallow, cone sparse docs/partner at
  ./src): build exit 0, source.txt == full-clone build. Cone mode also checks out top-level files (data only).
  Concurrency: a branch dispatch can replace a pending main run in group pages (stale site until next run), low.
- 7 setup review: DONE (harness/check7_dns.sh). Order safe (verify -> Pages domain + DNS back to back -> HTTPS).
  Org verification TXT already present; wildcard confirmed; CAA allows letsencrypt.org; install.* CNAME same pattern.
  Gaps: keep TXT record; no links before Enforce HTTPS; no HSTS on Pages; retirement step; branch deploy without
  environment: unproven, test after setup; ruleset only "recommended".
