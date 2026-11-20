# Plan: host the partner PDFs at run.telcoin.network (2026-11-20)

Operators and MNO partners get browser links to the four partner PDFs. A new public repo
`Telcoin-Association/tn-partner-site` (GitHub Pages, Actions source, custom domain
`run.telcoin.network`) reads the committed PDFs from this repo's `main` at build time and serves
them with a landing page. Two PRs here: the specification at 1.3 without the confidentiality
footer (PR-1), then the links to the hosted copies (PR-2, stacked, merged once `/guide` is live).

`origin/main` at 2d1bdc7. Worktree `~/coding/telcoin/tnd-spec-13` holds both branches in turn.
Site working copy `~/coding/telcoin/tn-partner-site`. Shared site contract:
`tasks/spec-run-site.md`. Checkpoints `tasks/ckpt-run-<unit>.md`.

## Decisions (user, 2026-11-20)

- Hosting: a new small public repo with GitHub Pages, the same mechanism as
  `install.telcoin.network` and `docs.telcoin.network`. Nothing is duplicated or moved.
- Domain: `run.telcoin.network`.
- All four PDFs are served. The specification's footer line "Telcoin Association Confidential
  and Proprietary Information" is dropped in a new revision.
- Defaults: repo name `tn-partner-site`; publishing is a manual "Run workflow" after a docs
  merge (the workflow also accepts `repository_dispatch`); `robots.txt` allows indexing; the
  landing page takes Geist and the Telcoin Network logo from `docs/partner/assets` at build time.

## URIs

| URI | Serves |
|---|---|
| `https://run.telcoin.network/` | landing page |
| `https://run.telcoin.network/mno-node-guide.pdf` | MNO node guide |
| `https://run.telcoin.network/testnet-node-requirements.pdf` | testnet one-pager |
| `https://run.telcoin.network/mainnet-node-requirements.pdf` | mainnet one-pager |
| `https://run.telcoin.network/technical-specification.pdf` | technical specification |
| `/guide`, `/testnet`, `/mainnet`, `/spec` | short aliases that redirect to the PDFs |

## P0 Setup (orchestrator)

- [x] `git fetch`; worktree `tnd-spec-13` on `docs/spec-1.3-public` off `origin/main` (2d1bdc7)
- [x] `git init -b main` in `~/coding/telcoin/tn-partner-site`, `tasks/` excluded
- [x] scratch clone of `origin/main` (`src-main`) as the read source
- [x] the plan's line references re-checked against `origin/main`
- [x] baseline: page 1 of each PDF prints `Version <v> · <date>`; the specification's text has
      the marking 36 times, the other three none; pages 1, 1, 77, 37
- [x] shared site contract `tasks/spec-run-site.md`

## P1 (parallel, opus)

- [x] A1: `build-site.sh`, `site/index.html`, `site/style.css`, `site/404.html`, `site/robots.txt`
      (its harness 115/115; the contract's `@@` check narrowed to text files, since the PDFs
      and fonts hold those bytes by chance; first local site commit 0ee1951)
- [x] A2: `.github/workflows/publish.yml`, `README.md`, `LICENSE-APACHE`, `LICENSE-MIT`
      (actionlint clean, pins identical to the installer workflow; the orchestrator added a
      `.gitignore` for `/src/` and `/_site/`)
- [x] B: PR-1 on `docs/spec-1.3-public` (93412a4, def6961): metadata 1.3 without `confidentiality`, template and
      theme `.run-meta`, build script without `NEED_CONFIDENTIALITY`/`CONFIDENTIALITY` and with
      the marking in `FORBIDDEN`, AGENTS.md, CHANGELOG, the rebuilt specification PDF;
      `--all` reports the other three unchanged

## P2

- [x] VB: PASS WITH NOTES from a fresh clone at a different path. Scope 7 files; both commits
      rebuild to four "PDF unchanged"; 37 pages; no marking in any form; word sequences equal on
      37 of 37 pages; pixels differ only at the cover's version line and the footer band.
      Findings: (1) the marking passes through `metadata.yaml` into the PDF's document
      properties; (2) without `pdftotext` every non-Markdown route passes; (3) the CHANGELOG
      sentence overstates; (4) the pixel band in the first commit message was 0.5 mm off
- [x] orchestrator: first commit message reworded with VB's band (tips now 35214c4, ecf035f;
      trees identical to 93412a4, def6961); first local site commit 0ee1951
- [x] B2 (fresh writer): the lint checks each document's sources (Markdown, metadata,
      template, stylesheet) for the marking in any case, without `pdftotext`; CHANGELOG and
      AGENTS.md say what is checked where; folded into the tip commit (9da2a07, +19 -5 in the
      script, no PDF changed)
- [x] VB2 (fresh verifier): PASS WITH NOTES. Findings 1 and 2 closed on every named route,
      with and without `pdftotext`; prose and commit-message claims re-run and true. New:
      a no-break space between the words in `metadata.yaml` passes every check (`tr` is
      bytewise). By design and left: other wordings; markup-split phrases without `pdftotext`
- [x] B3: U+00A0 folded in the lint loop (the verifier's validated line), header comment;
      tip 2e6ce45, script only (+6 -3)
- [x] orchestrator: checked from a fresh clone at another path: four "PDF unchanged"; the
      no-break-space case exits 1 at the lint; shellcheck and `bash -n` clean; no trailers
- [x] orchestrator: `docs/spec-1.3-public` pushed (35214c4, 2e6ce45); PR-2 rebased onto it
      (797dcb5, e957fd9; `docs/partner` tree still a6d248b; four "PDF unchanged")

## P3 (parallel, opus)

- [x] VA-S: FAIL on `build-site.sh` at 0ee1951, everything else in the contract passing
      (red/green, 48 output checks, every gate, usage and safety, `<src>` only read, sparse
      emulation, determinism). Findings: (1) committed symlinks are followed out of `<src>`
      and published; (2) edits hidden by index flags are served; (3) a clean filter in
      `<src>/.git/config` runs under `git status`; (4) a failing `git status` exits 128
      without an `error:` line; (5) a relative `<src>` shaped like `v=1` confuses awk
- [x] orchestrator: decisions written into the contract ("Amended after verification"):
      gate 0 compares each file the build reads with its blob in `HEAD` (no `git status`),
      gate 1 pins the logo's SHA-256, the concurrency group is per ref, README setup section
- [x] A3 (fresh writer): the site fix round. `committed()` replaces `tracked()` (regular
      file, in `HEAD`, `hash-object --no-filters` equals `rev-parse HEAD:<path>`); `LOGO_SHA256`;
      absolute `<src>`; `error:` lines for git failures; modes normalised; group
      `pages-${{ github.ref }}`; README. The earlier harness reruns green with twelve
      expectations changed for the new gate 0, 54 new cases pass. One SIGINT hang in several
      hundred runs, not reproduced. 281k tokens: over budget, see lessons
- [x] orchestrator: two README wording notes from VC (publish rule, the short link without
      its slash), one comment; site commit a3c70b8; the fixed build passes on Ubuntu 24.04
      against PR-2 (18 files, 1.1/1.1/1.9/1.3, hashes verify)
- [x] VA2-S (fresh verifier): PASS WITH NOTES at a3c70b8. Nine reported cases closed (the
      old script passes all nine); twenty-odd ways around gate 0 refused or serving exactly
      HEAD's bytes; logo pin; modes; exit codes 0, 1, 2 only; the earlier harness 385 passed,
      0 failed; sparse emulation fetches nothing; 300 signalled runs, no hang, one leftover
      temp directory. Left: (1) a race between the check and the copy needs a writer in
      `<src>` during the build; (2) `git replace`; (3) a remote command via lazy fetch; (4) a
      SIGTERM to bash alone can leave a temp directory
- [x] A5: `--no-replace-objects` and `GIT_ALLOW_PROTOCOL=none` in `git_src` (the verifier's
      tested line) for (2) and (3); (1) documented in the README; (4) left. Both repros
      closed, the harness again 385 passed, 0 failed; the orchestrator's run on Ubuntu 24.04:
      green exit 0, the marked specification gate 5, a symlinked licence gate 0. Site commit
      ad25b0b
- [x] VA2-W (fresh verifier): PASS WITH NOTES at a3c70b8 and PR-2 0e21144. The group change
      is right for every pair of triggers; six violations of the constraints PR-2 names each
      refuse the build; served-output regression 49 and 113 checks, 0 fail. Notes: the
      first deploy needs PR-1 merged (today's `main` fails gate 5); the branch-deploy test in
      setup did not test the environment's branch rule (two runs needed); the workflow header
      still said "a partner PDF change"; "Add or rename" missed two places; gate 0 missing
      from "fixed where"; the retirement sentence incomplete
- [x] A4: those README and comment fixes (prose only); site commit 4918da6
- [x] C: PR-2 on `docs/run-telcoin-network-links` (0e7053b, 93f3969): both one-pagers end
      Contact with "The full operator guide is at run.telcoin.network/guide." at 1.1, one page
      each; README note and maintainer paragraph; two AGENTS.md bullets (publishing; the two
      constraints the site's build puts on the documents); CHANGELOG entry

## P4

- [x] VC: PASS WITH NOTES from a fresh clone. Scope 9 files; both commits rebuild to four
      "PDF unchanged"; each one-pager is one page at 1.1 with one link annotation to
      `https://run.telcoin.network/guide`; text and pixels differ only in the version line
      and the Contact sentence; the site build (0ee1951) accepts the branch (1.1/1.1/1.9/1.3,
      `source_tree` a6d248b). Notes: AGENTS.md omits two of the site's constraints (gate 3
      shapes, the five shared assets); "a change to a partner PDF" should be "a change under
      `docs/partner`"; the currency check needs `git fetch origin`; "never renamed or removed"
- [x] C2: the wording fixes and the files-and-logo bullet, folded into PR-2's tip (bb4f8a5,
      three prose files, `docs/partner` tree still a6d248b); the orchestrator pointed one
      sentence at the site README's "Add or rename a document" (tip 0e21144)
- [x] orchestrator: records committed, `docs/run-telcoin-network-links` pushed; PR titles and
      bodies in `tasks/pr-body-run-1-spec.md` and `tasks/pr-body-run-2-links.md`

## P5 (after the user's steps)

- [ ] VD: verdict on the live site (after steps 6-9, again after step 10)

## User-only steps

0. Org Settings, Pages, Verified domains: `telcoin.network` is verified.
1. Create `Telcoin-Association/tn-partner-site`, public and empty.
2. Settings, Pages, Source: GitHub Actions.
3. Settings, Environments, `github-pages`: deployment branches `main` only.
4. Recommended: a ruleset on `main` requiring a pull request.
5. Merge PR-1. The site code is then pushed over SSH; the first run deploys to
   `https://telcoin-association.github.io/tn-partner-site/`.
6. Settings, Pages, Custom domain `run.telcoin.network`, Save.
7. Vercel DNS: `run` CNAME `telcoin-association.github.io`.
8. Wait for "DNS check successful" and the certificate.
9. Tick "Enforce HTTPS".
10. Merge PR-2, then run the publish workflow once more.

## House rules

- Agents on opus, each with an explicit read list and a checkpoint rewritten after every section.
- No Claude trailer or footer; commit messages go through a file.
- Nothing is pushed to `main`; branches only. `install.telcoin.network` and its workflow are
  not touched.

## Review

In `tasks/todo.md`, "Review: partner documents at run.telcoin.network (2026-11-20)".
Lessons in `tasks/lessons.md`, "Partner documents site round (2026-11-20)".
