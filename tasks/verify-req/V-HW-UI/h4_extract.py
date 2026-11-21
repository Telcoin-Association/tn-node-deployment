#!/usr/bin/env python3
"""V-HW-UI H4: pull the preflight code out of a page for node.

    python3 -I h4_extract.py INDEX_HTML OUT_JS [NAME | const:NAME ...]

Copies, verbatim, the page's `const esc`, `cap`, `setupNetwork`, `hwCores`,
`hwDiskLabel`, `hwTierRows`, `hwInfoRow` and `stepPreflight` (the ones the
page has: the 01664cc page has no hwCores / hwDiskLabel) into OUT_JS, each
function cut at its matching closing brace, and appends
`module.exports = {...}`. Extra NAMEs add more functions; const:NAME adds a
one-line `const NAME = ...;` (h5_flow.js uses both). Prints the names found
and the request line.
"""

import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()
names = ["cap", "setupNetwork", "hwCores", "hwDiskLabel", "hwTierRows", "hwInfoRow", "stepPreflight"]
names += [a for a in sys.argv[3:] if not a.startswith("const:")]
consts = [a[6:] for a in sys.argv[3:] if a.startswith("const:")]
out, found = [], []
for c in consts:
    m = re.search(r"^const " + c + r" = .*;\s*(//.*)?$", src, re.M)
    out.append(m.group(0))
    found.append(c)

m = re.search(r"^const esc = .*$", src, re.M)
out.append(m.group(0))
found.append("esc")


def cut(start):
    """The text from `start` to the brace that closes the first `{`."""
    i = src.index("{", src.index(")", start))
    depth = 0
    for j in range(i, len(src)):
        c = src[j]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return src[start:j + 1]
    raise SystemExit("unbalanced braces")


for n in names:
    m = re.search(r"^(?:async )?function " + n + r"\(", src, re.M)
    if not m:
        continue
    out.append(cut(m.start()))
    found.append(n)

out.append("module.exports = {" + ", ".join(found) + "};")
open(sys.argv[2], "w", encoding="utf-8").write("\n\n".join(out) + "\n")
req = re.search(r"^.*api\('/api/setup/preflight.*$", src, re.M)
print("found: " + " ".join(found))
print("request line: " + (req.group(0).strip() if req else "NONE"))
