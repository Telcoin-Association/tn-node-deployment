Title: docs: point the one-pagers and the maintainer notes at run.telcoin.network

Branch: `docs/run-telcoin-network-links` (797dcb5, 0e21144) into `main`, stacked on
`docs/spec-1.3-public`. Open it against `main` after PR-1 has merged, or against
`docs/spec-1.3-public` before.

Merge only once `https://run.telcoin.network/guide` is live: both one-pagers print that link.

---

## Summary

The four partner PDFs are served at `https://run.telcoin.network` by
[tn-partner-site](https://github.com/Telcoin-Association/tn-partner-site), which reads
`docs/partner` from `main` of this repo each time its Publish workflow runs. This PR points
this repo at the hosted copies.

| URL | Serves |
|---|---|
| `https://run.telcoin.network/` | landing page: the four documents with version and date |
| `/testnet`, `/testnet-node-requirements.pdf` | Adiri testnet node requirements |
| `/mainnet`, `/mainnet-node-requirements.pdf` | Mainnet node requirements |
| `/guide`, `/mno-node-guide.pdf` | node guide for mobile network operators |
| `/spec`, `/technical-specification.pdf` | technical specification |

File names carry no version, so each link serves the revision published last.

## Changes

- Both node requirements one-pagers, now version 1.1, end their Contact section with
  "The full operator guide is at run.telcoin.network/guide." instead of a link to the guide's
  PDF on GitHub. Nothing else on either page changed, and each is still one page. The page
  still names the repository in its footer.
- `README.md`: the note for mobile network operators gains the site and the four short links.
  The maintainer paragraph says how to link one partner document from another, how to publish
  and how to check that the site is current.
- `AGENTS.md` ("Partner documents"): the same in detail, and what the site's build requires of
  the documents here.
- `CHANGELOG.md`: one entry.

The guide and the specification PDFs are untouched.

## What maintainers do from now on

- After a change under `docs/partner` merges, run the Publish workflow of tn-partner-site:
  `gh workflow run publish.yml --repo Telcoin-Association/tn-partner-site --ref main`.
  A merge here publishes nothing by itself.
- The site is current when `source_tree` in `https://run.telcoin.network/source.txt` equals
  `git rev-parse origin/main:docs/partner` after `git fetch origin`.
- Link one partner document from another by its short link, never by a GitHub URL.

The site's build refuses to publish when a document's `version` or `date` has the wrong shape,
when page 1 of a PDF does not print `Version <version> · <date>` from its `metadata.yaml`, when
any PDF's text carries "Confidential and Proprietary", when a file it reads is a symbolic link
or differs from its blob in `HEAD`, or when the logo is not the reviewed file. A refused run
leaves the live site as it was.

## How it was checked

Builds ran in the `tn-pdf-tools` container; an independent pass worked from a fresh clone.

- `bash tools/build-partner-pdf.sh --all` prints "PDF unchanged" for all four documents (77,
  37, 1 and 1 pages) at each commit.
- Each one-pager: one page; page 1 prints `Version 1.1 · November 2026`; one link annotation
  to `https://run.telcoin.network/guide` (the old PDF had two, for the wrapped GitHub URL);
  no link to the guide on GitHub is left; `devs@telcoin.org` is still there.
- Against the 1.0 PDFs: in the page text only the version line and the Contact sentence
  differ; a pixel diff finds only those two bands; nothing is clipped.
- The site build accepts this branch: exit 0, the landing page shows 1.1, 1.1, 1.9 and 1.3,
  and `source_tree` equals `git rev-parse HEAD:docs/partner`. The same on Ubuntu 24.04 with
  its own `pdftotext`.

CI does not build the PDFs. The diff touches no released script, `MANIFEST` entry or checksum
file, so no scripts release is needed.

## Not proven until the site is live

GitHub Pages redirecting `/guide` to `/guide/` and serving the PDFs inline as
`application/pdf` was only checked against a local server. The stub page resolves to the PDF
from either form of the URL.
