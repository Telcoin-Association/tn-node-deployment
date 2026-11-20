Title: docs/partner: technical specification 1.3 without the confidentiality footer

Branch: `docs/spec-1.3-public` (35214c4, 2e6ce45) into `main`

---

## Summary

The partner documents are about to be published at `https://run.telcoin.network`, so the
technical specification can no longer print "Telcoin Association Confidential and Proprietary
Information." in its running footer. This PR publishes the specification as version 1.3 with
that line replaced by "Version 1.3 · November 2026", and makes the PDF build refuse the
marking from now on.

The content is unchanged from 1.2. The specification is still 37 pages. Page by page the
words are the same and in the same order, and the rendered pixels differ only at the cover's
version line and in the footer line's band on pages 2 to 37.

The guide and both one-pagers are byte-for-byte untouched.

## Changes

- `docs/partner/technical-specification/`: `metadata.yaml` drops `confidentiality:` and moves
  to version 1.3. The footer line in `template.html` prints version and date and keeps its
  place and style (`.run-conf` is renamed `.run-meta` in `theme.css`). The PDF is rebuilt.
- `tools/build-partner-pdf.sh`: the `confidentiality` requirement and its warning are gone.
  The lint, which runs before anything is built and needs no `pdftotext`, now fails when
  "Confidential and Proprietary" appears in a document's Markdown, `metadata.yaml`,
  `template.html` or `theme.css`. It matches in any case, across line breaks, and with a
  no-break space between the words. When `pdftotext` is installed, the PDF text is checked
  the same way after the build.
- `AGENTS.md` and `CHANGELOG.md` say what is checked where.

The plan for this change only added the phrase to the script's `FORBIDDEN` list. The check on
the sources came out of review: the marking used to live in `metadata.yaml` and the template,
which the Markdown lint never read, and metadata such as `description:` also reaches the PDF's
document properties, which no check on the PDF text can see.

## What the guard does not catch

- It matches the wording the 1.2 footer used. "Confidential & Proprietary", or the two words
  in the other order, pass.
- On a machine without `pdftotext`, a phrase that only the rendered page puts together passes
  the build: the words split by markup in a template, or an HTML entity between them. The
  publish step of the site requires `pdftotext` and checks the PDF text again.
- A comment in a YAML, HTML or CSS source that quotes the marking fails the lint. No committed
  file contains either word today.

## How it was checked

All builds ran in the `tn-pdf-tools` container (pandoc 3.8.3, WeasyPrint 70.0). Two independent
passes worked from fresh clones at paths other than where the PDF was built.

- `bash tools/build-partner-pdf.sh --all` prints "PDF unchanged" for all four documents (77,
  37, 1 and 1 pages) at each commit.
- The specification PDF has no "confidential" in its page text in any case, and none in its
  document properties. "Version 1.3 · November 2026" is on every page, once.
- Against the 1.2 PDF on `main`: the word sequence is equal on 37 of 37 pages once the footer
  and the cover's version line are set aside; a pixel diff of every page finds changes only at
  the cover's version line and in the footer band (259.3 to 262.1 mm from the top).
- The guide, testnet and mainnet PDFs have the same blob as on `main`.
- Each of these fails the build before anything is written, and leaves the committed PDF as it
  was: the old footer back in `template.html` (also with `pdftotext` hidden); the marking in
  `description:` or `author:` of a `metadata.yaml`, split across two lines of a folded scalar,
  or with a no-break space between the words; `content: "CONFIDENTIAL AND PROPRIETARY"` in a
  stylesheet; the phrase in lower case wrapped across two Markdown lines; the marking in another
  document's metadata or template.
- A `confidentiality:` key on its own in `metadata.yaml` is inert.
- `shellcheck -x` at the severities CI uses, `bash -n` and `tools/check-bash32.sh` are clean on
  the script.

CI does not build the PDFs. The diff touches no released script, `MANIFEST` entry or checksum
file, so no scripts release is needed.

## Follow-up

PR-2 (`docs/run-telcoin-network-links`, stacked on this branch) points the one-pagers and the
maintainer notes at the hosted copies. It merges once `https://run.telcoin.network/guide` is
live.
