# Shared contract: the run.telcoin.network site repo (2026-11-20)

Read by units A1 (script and templates), A2 (workflow, README, licences) and the verifiers.
The orchestrator owns this file. If something here is wrong or cannot be met, say so in the
hand-back instead of deviating silently.

## What the site is

`Telcoin-Association/tn-partner-site` is a small public repo with GitHub Pages (source: GitHub
Actions), custom domain `run.telcoin.network`. At build time it reads the four committed partner
PDFs from `Telcoin-Association/tn-node-deployment` `main` (`docs/partner`) and serves them with a
landing page. Nothing is copied into the site repo. No pandoc, no WeasyPrint.

Local working copy: `/home/drtnarg/coding/telcoin/tn-partner-site` (git initialised, branch
`main`, no commits yet, `tasks/` is in `.git/info/exclude`). Only the orchestrator runs git
write commands there. Units write files and never `git add`, `git commit` or `git push`.

## Repo layout

| File | Owner |
|---|---|
| `build-site.sh` | A1 |
| `site/index.html` (template), `site/style.css`, `site/404.html`, `site/robots.txt` | A1 |
| `.github/workflows/publish.yml` | A2 |
| `README.md`, `LICENSE-APACHE`, `LICENSE-MIT` | A2 |

## The documents (one fixed table, in landing order)

| Order | Directory under `docs/partner` (also the file stem) | Alias |
|---|---|---|
| 1 | `testnet-node-requirements` | `testnet` |
| 2 | `mainnet-node-requirements` | `mainnet` |
| 3 | `mno-node-guide` | `guide` |
| 4 | `technical-specification` | `spec` |

Each directory holds `<stem>.md`, `metadata.yaml`, `<stem>.pdf`.

## `build-site.sh <src> <out>`

- bash, `set -euo pipefail`, shellcheck-clean with no `disable` directive unless a comment
  says why. Runs on `ubuntu-latest` (bash 5.2) and in the `tn-pdf-tools` container
  (debian 12, bash 5.2.15, git 2.39.5, poppler-utils). No macOS or bash 3.2 requirement.
- `<src>`: root of a tn-node-deployment git checkout. Read as data only: the script never
  executes, sources or writes anything under `<src>`.
- `<out>`: must not exist, or be an empty directory. Anything else is a usage error (exit 2).
  The script never deletes a path the caller named. It builds in a temporary sibling directory
  and moves it into place only after every gate passed; a failed run leaves no `<out>`.
- Needs `git`, `pdftotext`, `sha256sum`, `awk`. A missing tool is reported by name, exit 2.
- Exit codes: 0 built, 1 a gate failed, 2 usage or environment error.
- A gate failure prints `error: gate <n>: <what and which document>` on stderr. Run every gate
  for every document and report all failures before exiting 1, so one run shows the full list.
- Under `pipefail`, never pipe into `grep -q` (the writer gets EPIPE and the pipeline fails
  at random). Write `pdftotext` output to a temp file, or use a here-string.

### Reading metadata

- `version` and `date`: top-level scalars of `metadata.yaml`, read with the same awk as
  `_meta` in tn-node-deployment `tools/build-partner-pdf.sh` (lines 257-263 on `main`).
- Title: the single `# ` heading of `<stem>.md`, outside fenced code blocks (fence handling
  as `_fenced_lines` in the same script, lines 327-331).
- Every value that reaches HTML is escaped: `&`, `<`, `>`, `"`, `'`.
- bash 5.2 expands `&` in the replacement of `${var//pat/rep}` to the matched text
  (`patsub_replacement`). Escaped values contain `&`. Fill the template line by line (a
  placeholder sits alone on its line) rather than by pattern substitution, and test with a
  title that contains `&`, `<` and `"`.

### Gates

| Gate | Check |
|---|---|
| 0 | `<src>` is a git checkout, `docs/partner` exists, and `docs/partner` has no modified, deleted or untracked file (so `source_tree` describes exactly what is served) |
| 1 | each document has `<stem>.md`, `metadata.yaml`, `<stem>.pdf`; the shared assets the site copies exist |
| 2 | each PDF is non-empty, starts with `%PDF-`, and ends with `%%EOF` (trailing newline or CR allowed) |
| 3 | `version` matches `^[0-9]+\.[0-9]+(\.[0-9]+)?$`; `date` is an English month name, a space and a four-digit year; the `.md` has exactly one `# ` heading outside fences and its text is not empty |
| 4 | the text of page 1 of the PDF (`pdftotext -f 1 -l 1`) contains the line `Version <version> · <date>` (the separator is U+00B7 with one space each side). Catches a PDF that was not rebuilt after a metadata bump |
| 5 | the full text of no PDF contains `Confidential and Proprietary` (case-insensitive) |
| 6 | the built tree holds exactly the expected file list below, and no `*.html`, `*.css` or `*.txt` file in it contains `@@` |

Amended after A1's hand-back (2026-11-20), as built:

- The `@@` check covers text files only. The PDFs and the woff2 fonts hold the bytes `@@` by
  chance (guide 4 times, specification 20), so a check on every file could never pass.
- Gates 0 to 5 run for every document and are reported together. Gate 6 needs a built tree and
  runs only when they passed.
- A check that an earlier failure makes meaningless for a document is skipped: gates 2, 4, 5
  when the PDF is missing; gates 4, 5 when the PDF failed gate 2; gate 4 when gate 3 rejected
  the version or date. Gate 0 exits at once when `docs/partner` does not exist.
- Gate 0 also requires `<src>` to be the top of its checkout and every file the site copies to
  be tracked (an ignored but present PDF would otherwise be served without `source_tree`
  covering it).
- Exit 2 as well for: `<out>` a symlink or inside `<src>`; a template that does not hold each
  placeholder exactly once.
- Git runs in `<src>` with `--no-optional-locks -c core.fsmonitor=false`, so the index is not
  rewritten and no hook configured in `<src>` runs.
- An existing empty `<out>` is replaced by the built tree with one `mv -T`; a failed run
  leaves an empty `<out>` empty and creates none otherwise.
- Logo: `telcoin-network-light.svg` (white wordmark) on a navy band. Sizes in decimal units.

### Output tree (gate 6 list, exact)

```
404.html
assets/fonts/Geist-Regular.woff2
assets/fonts/Geist-SemiBold.woff2
assets/fonts/LICENSE.txt
assets/fonts/OFL.txt
assets/telcoin-network.svg
guide/index.html
index.html
mainnet-node-requirements.pdf
mainnet/index.html
mno-node-guide.pdf
robots.txt
source.txt
spec/index.html
style.css
technical-specification.pdf
testnet-node-requirements.pdf
testnet/index.html
```

- The four PDFs are byte-for-byte copies (`cmp` clean against `<src>`).
- Assets come from `<src>/docs/partner/assets` at build time: the two Geist weights and both
  licence texts from `fonts/geist/`, and one of `logos/telcoin-network-{dark,light}.svg`
  copied as `assets/telcoin-network.svg` (A1 picks the one that suits the page; see
  `docs/partner/assets/README.md` for what each is). The page sets its own colours and does
  not depend on the viewer's colour scheme, so one logo is enough.
- `index.html`: built from `site/index.html`. `@@DOCS@@` (alone on a line) becomes one entry
  per document in table order with title, `Version <v>`, date, file size in human units, the
  PDF link and the short link. `@@SOURCE@@` (alone on a line) becomes the footer provenance:
  the source repo link and the short source commit, linking to
  `https://github.com/Telcoin-Association/tn-node-deployment/commit/<full sha>`, and a link to
  `source.txt`. All hrefs on this page are relative (`mno-node-guide.pdf`, `guide/`,
  `style.css`), so the page also works under `https://telcoin-association.github.io/tn-partner-site/`.
- `<alias>/index.html`: no JavaScript. `<meta http-equiv="refresh" content="0; url=../<stem>.pdf">`,
  `<link rel="canonical" href="https://run.telcoin.network/<stem>.pdf">`,
  `<meta name="robots" content="noindex">`, and a visible fallback link to `../<stem>.pdf`.
- `404.html`: static copy of `site/404.html`; root-absolute links (`/`, `/style.css`,
  `/assets/...`) because it is served at any depth.
- `robots.txt`: allows everything.
- `source.txt`, exactly this shape (keys at line start, one space after the colon, a blank
  line, then `sha256sum` lines in table order so `grep -E '^[0-9a-f]{64}  ' source.txt |
  sha256sum -c` works from inside the tree):

```
source_repo: https://github.com/Telcoin-Association/tn-node-deployment
source_commit: <git -C <src> rev-parse HEAD>
source_tree: <git -C <src> rev-parse HEAD:docs/partner>
site_commit: <git rev-parse HEAD of the directory build-site.sh lives in, or "unknown">
built_at: <UTC, YYYY-MM-DDTHH:MM:SSZ>

<sha256>  testnet-node-requirements.pdf
<sha256>  mainnet-node-requirements.pdf
<sha256>  mno-node-guide.pdf
<sha256>  technical-specification.pdf
```

### Landing page content

- Static, no JavaScript, no external request (fonts and logo are local).
- `<title>` and `<h1>`: "Run a Telcoin Network node".
- One short lead sentence, then the four documents.
- Footer: `devs@telcoin.org` (mailto), the source repo, the source commit, `source.txt`.
- No link to `install.telcoin.network` (its root is a raw shell script).
- Look: follows the partner PDFs (Geist, the colours in
  `docs/partner/testnet-node-requirements/theme.css`). Readable on a phone.
- The site's public base URL `https://run.telcoin.network` is one constant in the script.

## Workflow `.github/workflows/publish.yml`

Mirrors tn-node-deployment `.github/workflows/publish-installer.yml` on `main`.

- Triggers: `push` to `main`, `workflow_dispatch`, `repository_dispatch` with type
  `partner-docs-updated`.
- `permissions: {}` at the top. `concurrency: {group: pages, cancel-in-progress: false}`.
- Job `build` (`contents: read`): checkout of this repo (`persist-credentials: false`); second
  checkout with `repository: Telcoin-Association/tn-node-deployment`, `ref: main`, `path: src`,
  `sparse-checkout: docs/partner`, `persist-credentials: false` (public repo: no token, no
  secret); install `poppler-utils` only if `pdftotext` is missing; `bash build-site.sh src _site`;
  `upload-pages-artifact` with `path: _site`.
- Job `deploy` (`pages: write`, `id-token: write`, environment `github-pages` with the page
  URL): `needs: build`, and runs only when `github.ref == 'refs/heads/main'`, so a manual run
  from another branch builds and checks but does not deploy.
- Pins, identical to the installer workflow:
  - `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1`
  - `actions/upload-pages-artifact@fc324d3547104276b827a68afc52ff2a11cc49c9 # v5.0.0`
  - `actions/deploy-pages@368f82528645a54fb793d4d04e342629a3f51346 # v5.0.1`
- No `CNAME` file: with the Actions source the custom domain is a repo setting.

## Rules for every unit

- Read only the paths your brief lists. If you need something else, hand back and say what.
- Prose (README, comments, page copy): load the `human-writing` skill first and follow it.
  Sentence-case headings, no emoji, no bold-header bullets, straight quotes.
- Checkpoint file as named in your brief: a `status:` header and the list of finished
  sections, rewritten after each section. On start, read it and continue from the first
  unfinished section.
- If Write is refused for a file, do not work around it: return the complete text in the
  final answer.
- Docker commands use absolute host paths, never `$PWD`.
- Final answer: a summary (what exists, what was checked with counts and the tree each check
  ran on, what is open), not file dumps.

## Amended after verification (2026-11-20, VA-S and VA-W on site commit 0ee1951)

These points replace what is written above where they differ.

### Gate 0: the build reads only what HEAD records

Finding: `git status` calls a committed symlink clean, and index flags (`skip-worktree`,
`assume-unchanged`) hide edits, so the build published files that git does not record, with
exit 0 (a symlink to `/proc/self/environ` as a licence text was served).

Gate 0 no longer rests on `git status`. For every file the build reads (per document the
`<stem>.md`, `metadata.yaml` and `<stem>.pdf`; the five shared assets):

- the working file is a regular file and not a symbolic link;
- its path exists in `HEAD` as a blob;
- `git hash-object --no-filters -- <path>` equals `git rev-parse HEAD:<path>`.

So the output is a function of `HEAD`, and `source_commit` and `source_tree` describe exactly
what is served. `git status` and `git ls-files` are gone from the script: an untracked or
edited file that the build does not read no longer fails gate 0 (it cannot reach the site),
and no clean filter configured in `<src>` runs. Gate 0 still requires `<src>` to be the top
of a git checkout and `HEAD:docs/partner` to be a tree.

A missing file is still gate 1. A file that is present but not in `HEAD` (ignored, or staged
and not committed) is gate 0.

### Gate 1: the logo is pinned

Finding: the logo SVG is served from the site's origin and an SVG can carry script; nothing
checked its content.

`build-site.sh` holds `LOGO_SHA256`, the SHA-256 of the reviewed logo
(`docs/partner/assets/logos/telcoin-network-light.svg`, today
`3094cdd0523665d8548737ac40e299c1ecd36670a9b002f7f30d87868fa2b528`). Gate 1 fails when the
logo in `<src>` has another hash; the message says to review the new file and update the
constant. No pattern scan of the SVG. The fonts are not pinned.

### Smaller points in the script

- `<src>` is made absolute before use (a relative `<src>` shaped like `v=1` was read by awk
  as a variable assignment).
- Every git failure prints an `error:` line and exits 1 (gate 0) or 2; never a bare git exit
  code.
- The built tree's modes are normalised before the move (`u=rwX,go=rX`), so a restrictive
  umask cannot produce an artifact Pages cannot read.

### Workflow

- `concurrency.group` is `pages-${{ github.ref }}`, still without cancel. In one shared group
  a run started from another branch (which builds and does not deploy) could replace a pending
  run of `main`, and that publish would be dropped.

### README

- "What the build checks": rows 0 and 1 as above. "Build locally": the preview binds to
  `127.0.0.1`; an uncommitted change to a file the site reads fails gate 0.
- "Add or rename a document": also `site/404.html` (it names the four short links) and the
  README's own Links table. A changed logo needs its new SHA-256 in `LOGO_SHA256`.
- "One-time setup": written as steps to follow, not as done. Keep the org's
  `_github-pages-challenge-…` TXT record for as long as the site exists. Share the links only
  after "Enforce HTTPS" is ticked. Once after setup, confirm that a run from another branch
  cannot deploy. To retire the site, delete the `run` DNS record first, then remove the custom
  domain.
- Who decides what is published: whoever can merge to `main` of tn-node-deployment decides
  what the next run publishes; whoever can push to `main` of this repo decides how.
