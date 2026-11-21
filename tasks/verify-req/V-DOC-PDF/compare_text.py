#!/usr/bin/env python3
"""V-DOC-PDF P5: compare two `pdftotext -layout` dumps page by page.

Usage: compare_text.py A_LAYOUT B_LAYOUT [--show N] [--raw A_RAW B_RAW]

Prints the page counts, then per page: whether the words (whitespace-split tokens,
in order) are identical, and how many layout lines differ (difflib, after
stripping trailing spaces). A page whose words are identical but whose lines
differ has the same text broken into lines differently. With --show N it prints
the first N differing line pairs of the first pages that differ. With --raw it
also compares the two `pdftotext -raw` dumps page by page with every whitespace
character removed: equal strings mean the page carries the same characters in
the same order, so a word-level difference in the layout dump is only a token
split at a new line break (`/opt/` + `telcoin/...`, `-` + `o`) or a table's
columns interleaving differently.
Exit 0 always (it reports; the caller judges).
"""
import difflib
import sys


def pages(path):
    text = open(path, encoding="utf-8").read()
    ps = text.split("\f")
    if ps and not ps[-1].strip():
        ps = ps[:-1]
    return ps


def main():
    args = sys.argv[1:]
    show = 0
    raw = None
    if "--raw" in args:
        i = args.index("--raw")
        raw = (args[i + 1], args[i + 2])
        del args[i:i + 3]
    if "--show" in args:
        i = args.index("--show")
        show = int(args[i + 1])
        del args[i:i + 2]
    if len(args) != 2:
        print(__doc__)
        return 2
    a, b = pages(args[0]), pages(args[1])
    print(f"pages: A {len(a)}, B {len(b)}")
    total_lines = 0
    unified = 0
    word_diff_pages = []
    line_diff_pages = []
    shown = 0
    for n in range(max(len(a), len(b))):
        pa = a[n] if n < len(a) else ""
        pb = b[n] if n < len(b) else ""
        wa, wb = pa.split(), pb.split()
        la = [ln.rstrip() for ln in pa.splitlines()]
        lb = [ln.rstrip() for ln in pb.splitlines()]
        sm = difflib.SequenceMatcher(None, la, lb, autojunk=False)
        changed = 0
        for tag, i1, i2, j1, j2 in sm.get_opcodes():
            if tag != "equal":
                changed += max(i2 - i1, j2 - j1)
                unified += (i2 - i1) + (j2 - j1)
                if shown < show:
                    print(f"--- page {n + 1}:")
                    for ln in la[i1:i2]:
                        print("  A| " + ln)
                    for ln in lb[j1:j2]:
                        print("  B| " + ln)
                    shown += 1
        total_lines += changed
        if wa != wb:
            word_diff_pages.append(n + 1)
        if changed:
            line_diff_pages.append((n + 1, changed))
    print(f"pages whose words differ: {len(word_diff_pages)} {word_diff_pages}")
    print(f"pages whose layout lines differ: {len(line_diff_pages)}; differing lines (max of both sides per hunk): {total_lines}")
    print(f"lines removed + added (as diff counts them): {unified}")
    print("per page (page, lines): " + ", ".join(f"{p}:{c}" for p, c in line_diff_pages))
    if raw:
        ra, rb = pages(raw[0]), pages(raw[1])
        bad = [n + 1 for n in range(max(len(ra), len(rb)))
               if "".join((ra[n] if n < len(ra) else "").split()) != "".join((rb[n] if n < len(rb) else "").split())]
        print(f"raw pages: A {len(ra)}, B {len(rb)}; pages whose characters (whitespace removed) differ: {len(bad)} {bad}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
