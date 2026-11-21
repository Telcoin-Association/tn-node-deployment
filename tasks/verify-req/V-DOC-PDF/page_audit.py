#!/usr/bin/env python3
"""V-DOC-PDF P5: structural audit of the guide's pages from `pdftotext -layout`.

Usage: page_audit.py GUIDE_LAYOUT

Checks, and prints every exception:
- footer: each page after the cover ends with `Page N of M`, N the page index, M
  the page count;
- contents: every entry `<number> <title> .... <page>` of the contents pages names
  a heading found at column 0 of a body page with the same number and title, on
  that page;
- running header: each body page's first line ends with the chapter (`N Title`) of
  the last chapter heading at or before that page (a body line is a heading only
  when its number and title are a contents entry; the guide numbers no level the
  contents leave out);
- stranded headings: a numbered heading that is the last non-blank body line of its
  page (its content starts on the next page), or that has only one body line under
  it on its page;
- short pages: a body page with fewer than 20 non-blank body lines whose next page
  does not start a chapter (something was pushed to the next page);
- blank pages: a page with no body line.
Exit 0 always (it reports; the caller judges).
"""
import re
import sys

HEAD = re.compile(r"^(\d+(?:\.\d+)*) (\S.*?)\s*$")
TOC = re.compile(r"^\s*(\d+(?:\.\d+)?)\s+(.*?)\s*\.{2,}\s*(\d+)\s*$")
FOOT = re.compile(r"Page (\d+) of (\d+)\s*$")


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    pages = open(sys.argv[1], encoding="utf-8").read().split("\f")
    if pages and not pages[-1].strip():
        pages = pages[:-1]
    total = len(pages)
    print(f"pages: {total}")
    toc = []
    bodies = {}
    problems = 0
    for idx, page in enumerate(pages, 1):
        lines = page.splitlines()
        nonblank = [ln for ln in lines if ln.strip()]
        if idx == 1:
            continue
        foot = [ln for ln in nonblank if FOOT.search(ln)]
        m = FOOT.search(foot[-1]) if foot else None
        if not m or int(m.group(1)) != idx or int(m.group(2)) != total:
            print(f"FOOTER page {idx}: {foot[-1].strip() if foot else 'none'}")
            problems += 1
        body = nonblank[1:-1] if len(nonblank) >= 2 else []
        bodies[idx] = (nonblank[0] if nonblank else "", body)
        for ln in body:
            t = TOC.match(ln)
            if t and idx <= 4:
                toc.append((t.group(1), t.group(2).strip(), int(t.group(3)), idx))
    first_body = max(p for _, _, _, p in toc) + 1 if toc else 2
    # A body line counts as a heading only when its number and title are a contents
    # entry: prose can start at column 0 with a number ("16 GB, ...").
    known = {(num, title) for num, title, _, _ in toc}
    found = {}
    chapter_at = {}
    current = None
    for idx in range(first_body, total + 1):
        hdr, body = bodies.get(idx, ("", []))
        for pos, ln in enumerate(body):
            h = HEAD.match(ln)
            if h and (h.group(1), h.group(2)) in known:
                found.setdefault(h.group(1), []).append((h.group(2), idx, pos, len(body)))
                if "." not in h.group(1):
                    current = f"{h.group(1)} {h.group(2)}"
        chapter_at[idx] = current
        if not body:
            print(f"BLANK page {idx}")
            problems += 1
    print(f"contents entries: {len(toc)}; numbered body headings: {sum(len(v) for v in found.values())}")
    for num, title, page, _ in toc:
        hits = [f for f in found.get(num, []) if f[0] == title]
        if not hits:
            near = found.get(num, [])
            print(f"TOC {num} '{title}' p{page}: no body heading with that number and title (found {near[:2]})")
            problems += 1
        elif hits[0][1] != page:
            print(f"TOC {num} '{title}': contents says page {page}, heading is on page {hits[0][1]}")
            problems += 1
    for idx in range(first_body, total + 1):
        hdr, _ = bodies.get(idx, ("", []))
        chap = chapter_at.get(idx)
        if chap and not hdr.rstrip().endswith(chap):
            print(f"HEADER page {idx}: '{hdr.strip()[-60:]}' expected to end with '{chap}'")
            problems += 1
    stranded = []
    for num, occ in found.items():
        for title, idx, pos, n in occ:
            after = n - pos - 1
            if after <= 1:
                stranded.append((idx, num, title, after))
    for idx, num, title, after in sorted(stranded):
        print(f"STRANDED page {idx}: heading {num} '{title}' has {after} body line(s) under it on its page")
    chapter_pages = {occ[0][1] for num, occ in found.items() if "." not in num}
    for idx in range(first_body, total + 1):
        _, body = bodies.get(idx, ("", []))
        if 0 < len(body) < 20 and (idx + 1) not in chapter_pages and idx != total:
            print(f"SHORT page {idx}: {len(body)} body lines; next page starts: '{(bodies.get(idx + 1, ('', ['']))[1] or [''])[0].strip()[:70]}'")
    print(f"footer/contents/header/blank problems: {problems}; stranded headings: {len(stranded)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
