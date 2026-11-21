#!/usr/bin/env python3
"""V-DOC-PDF P6: which sentences of the 1.2 one-pager PDFs are missing from the 1.3 PDFs.

Usage: p6_sentences.py OLD_RAW NEW_RAW

Both arguments are `pdftotext -raw` dumps of one page. Each is flattened (line-end
hyphen joined, spaces collapsed), each bullet sign starts a new line, and every
line of the -raw dump (one visual line of the page) is cut further at ". " or "; "
before a capital, digit, backquote or bracket. The units compared are therefore
visual lines or sentences, whichever is shorter; a unit counts as present when it
occurs anywhere in the other page's fully flattened text. Every old sentence that does not
occur in the new flat text is printed, then every new sentence absent from the old
text, so the output is the complete text delta in both directions.
"""
import re
import sys


def flat(text):
    t = re.sub(r"-\n[ \t]*", "-", text)
    t = t.replace("•", "\n")
    return re.sub(r"[ \t]+", " ", t)


def sentences(text):
    out = []
    for line in flat(text).split("\n"):
        line = line.strip()
        if not line:
            continue
        for s in re.split(r"(?<=[.;])\s+(?=[A-Z0-9`(])", line):
            s = s.strip()
            if len(s) >= 12:
                out.append(s)
    return out


def norm(text):
    return re.sub(r"\s+", " ", flat(text))


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    old = open(sys.argv[1], encoding="utf-8").read()
    new = open(sys.argv[2], encoding="utf-8").read()
    old_n, new_n = norm(old), norm(new)
    gone = [s for s in sentences(old) if s not in new_n]
    added = [s for s in sentences(new) if s not in old_n]
    print(f"old sentences: {len(sentences(old))}, missing from new: {len(gone)}")
    for s in gone:
        print("  - " + s)
    print(f"new sentences: {len(sentences(new))}, absent from old: {len(added)}")
    for s in added:
        print("  + " + s)
    return 0


if __name__ == "__main__":
    sys.exit(main())
