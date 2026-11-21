#!/usr/bin/env python3
"""V-DOC-PDF P2: text assertions on the three partner PDFs rebuilt in the round.

Usage: check_text.py TEXTDIR REPO SPEC

TEXTDIR holds, for each of mno-node-guide, testnet-node-requirements and
mainnet-node-requirements, `<doc>.layout.txt` (pdftotext -layout) and
`<doc>.plain.txt` (plain pdftotext) and `<doc>.raw.txt` (pdftotext -raw), as
extract_text.sh writes them.
REPO is the repository root (the guide's Markdown is read from it).
SPEC is tasks/spec-req-shared.md (the tables of section 3.1 and F2 of section 5
are read from it, so the expected text is the spec's, character for character).

Normalisation, stated once:
- Table rows are read from the -layout text: the header line
  `Role  Minimum  Recommended`, then the next N non-blank lines (N = rows in the
  spec), each split on runs of two or more spaces. Each line must give exactly
  three cells equal to the spec's row; the line after the last row must not be a
  wrapped continuation (indented by 10+ spaces, or splitting into 3 cells). So
  "each row on one line" and "no other row" are both checked.
- Prose ("flat") is the -raw text (content order, so the one-pagers' two columns
  do not interleave, and line-end hyphens are kept: plain pdftotext drops them,
  "single-\\nthreaded" -> "singlethreaded") with a line-end hyphen joined to the
  next line (`-\\n` -> `-`; the theme sets no hyphenation, so every such hyphen
  is real) and every run of whitespace collapsed to one space. Code spans render
  with a space inside brackets, e.g. `( 0x7e1 )`, so id checks allow optional
  spaces there. Every "no X" check runs over the flat -raw, plain and -layout
  texts together, so a hit in any one of them fails.
Exit 0 when every assertion holds, 1 otherwise. Prints one PASS/FAIL line each.
"""
import re
import sys
from pathlib import Path

FAILS = []


def check(ok, label, detail=""):
    print(("PASS " if ok else "FAIL ") + label + (f"  [{detail}]" if detail else ""))
    if not ok:
        FAILS.append(label)


def spec_tables(spec_text):
    """Return {'testnet': rows, 'mainnet': rows} from section 3.1 of the spec."""
    sec = spec_text.split("### 3.1", 1)[1].split("### 3.2", 1)[0]
    out = {}
    for key, marker in (("testnet", "Testnet (Adiri):"), ("mainnet", "Mainnet:")):
        part = sec.split(marker, 1)[1]
        rows = []
        started = False
        for line in part.splitlines():
            s = line.strip()
            if s.startswith("|"):
                started = True
                cells = [c.strip() for c in s.strip("|").split("|")]
                if cells[0] in ("Role",) or set(cells[0]) <= set("-"):
                    continue
                rows.append(tuple(cells))
            elif started:
                break
        out[key] = rows
    return out


def spec_f2(spec_text):
    m = re.search(r"^\| F2 \| `([^`]+)` \|", spec_text, re.M)
    return m.group(1)


def flat(text):
    t = re.sub(r"-\n[ \t]*", "-", text)
    return re.sub(r"\s+", " ", t)


HEADER = re.compile(r"^\s*Role\s{2,}Minimum\s{2,}Recommended\s*$")


def table_after(lines, start, nrows):
    """Find the first table header at or after line `start`; return (rows, next_line, hdr_idx)."""
    i = start
    while i < len(lines) and not HEADER.match(lines[i]):
        i += 1
    if i == len(lines):
        return None, None, None
    hdr = i
    rows = []
    i += 1
    while i < len(lines) and len(rows) < nrows:
        if lines[i].strip():
            rows.append(tuple(re.split(r"\s{2,}", lines[i].strip())))
        i += 1
    nxt = None
    while i < len(lines):
        if lines[i].strip():
            nxt = lines[i]
            break
        i += 1
    return rows, nxt, hdr


def check_table(lines, start, expected, label):
    rows, nxt, hdr = table_after(lines, start, len(expected))
    if rows is None:
        check(False, f"{label}: table header found")
        return None
    check(True, f"{label}: table header found at layout line {hdr + 1}")
    for n, (got, exp) in enumerate(zip(rows, expected), 1):
        check(got == exp, f"{label}: row {n} equals spec 3.1 `{' | '.join(exp)}`",
              "" if got == exp else f"got {got!r}")
    check(len(rows) == len(expected), f"{label}: {len(expected)} rows")
    cont = nxt is not None and (re.match(r"^ {10,}\S", nxt) or len(re.split(r"\s{2,}", nxt.strip())) == 3)
    check(not cont, f"{label}: no wrapped or extra row after the last row",
          "" if not cont else f"next line {nxt!r}")
    return rows


def no(pattern, text, label, flags=0):
    hits = [m.group(0) for m in re.finditer(pattern, text, flags)]
    check(not hits, label, "" if not hits else f"{len(hits)} hit(s): {hits[:5]!r}")


def contexts(pattern, text, width=40):
    return [text[max(0, m.start() - width):m.end() + width] for m in re.finditer(pattern, text)]


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        return 2
    tdir, repo, spec_path = (Path(a) for a in sys.argv[1:])
    spec = spec_path.read_text(encoding="utf-8")
    tables = spec_tables(spec)
    f2 = spec_f2(spec)
    check(len(tables["testnet"]) == 5 and len(tables["mainnet"]) == 6,
          "spec 3.1 parsed: 5 testnet rows, 6 mainnet rows")

    got_tables = {}
    for doc, net, version in (("testnet-node-requirements", "testnet", "1.3"),
                              ("mainnet-node-requirements", "mainnet", "1.3")):
        lay = (tdir / f"{doc}.layout.txt").read_text(encoding="utf-8")
        f = flat((tdir / f"{doc}.raw.txt").read_text(encoding="utf-8"))
        neg = "\n".join((f, flat((tdir / f"{doc}.plain.txt").read_text(encoding="utf-8")), flat(lay)))
        page1 = lay.split("\f", 1)[0]
        check(f"Version {version} · November 2026" in page1, f"{doc}: `Version {version} · November 2026` on page 1")
        check("Ubuntu 26.04 LTS (recommended)" in f, f"{doc}: `Ubuntu 26.04 LTS (recommended)`")
        got_tables[net] = check_table(lay.splitlines(), 0, tables[net], f"{doc}")
        check(f2 in f, f"{doc}: F2 verbatim")
        if net == "testnet":
            check(re.search(r"2017 \(\s*0x7e1\s*\)", f) is not None, f"{doc}: chain ID 2017 (0x7e1)")
            no(r"2 TB", neg, f"{doc}: no `2 TB`")
        else:
            check(re.search(r"\b731 \(\s*0x2db\s*\)", f) is not None, f"{doc}: chain ID 731 (0x2db)")
            no(r"487", neg, f"{doc}: no `487`")
            no(r"0x1e7", neg, f"{doc}: no `0x1e7`", re.I)
            no(r"Storage, every role", neg, f"{doc}: no `Storage, every role`")
        no(r"hyperthread", neg, f"{doc}: no `hyperthread`", re.I)
        no(r"physical cores", neg, f"{doc}: no `physical cores`", re.I)
        no(r"[0-9]+ vCPU \([0-9]+ cores", neg, f"{doc}: no vCPU-before-cores figure")
        no(r"\blegacy\b", neg, f"{doc}: no `legacy`", re.I)
        no(r"confidential\s+and\s+proprietary", neg, f"{doc}: no confidentiality marking", re.I)

    doc = "mno-node-guide"
    lay = (tdir / f"{doc}.layout.txt").read_text(encoding="utf-8")
    f = flat((tdir / f"{doc}.raw.txt").read_text(encoding="utf-8"))
    neg = "\n".join((f, flat((tdir / f"{doc}.plain.txt").read_text(encoding="utf-8")), flat(lay)))
    md = (repo / "docs/partner" / doc / f"{doc}.md").read_text(encoding="utf-8")
    page1 = lay.split("\f", 1)[0]
    check("Version 1.13 · November 2026" in page1, f"{doc}: `Version 1.13 · November 2026` on page 1")
    check("Ubuntu 26.04 LTS (recommended)" in f, f"{doc}: `Ubuntu 26.04 LTS (recommended)`")
    lines = lay.splitlines()
    starts = {}
    for key, marker in (("testnet", "Testnet (Adiri):"), ("mainnet", "Mainnet:")):
        idx = [i for i, ln in enumerate(lines) if ln.strip() == marker]
        check(len(idx) == 1, f"{doc}: one line `{marker}`", f"{len(idx)} found")
        starts[key] = idx[0] if idx else 0
    gt = check_table(lines, starts["testnet"], tables["testnet"], f"{doc} testnet")
    gm = check_table(lines, starts["mainnet"], tables["mainnet"], f"{doc} mainnet")
    check(f2 in f, f"{doc}: F2 verbatim")
    # 731 / 0x2db wherever the Markdown has them, and nowhere else.
    for tok in ("731", "0x2db"):
        n_md = len(re.findall(rf"(?<![\w.,]){re.escape(tok)}(?![\w])", md))
        n_pdf = len(re.findall(rf"(?<![\w.,]){re.escape(tok)}(?![\w])", f))
        check(n_md == n_pdf and n_md > 0, f"{doc}: `{tok}` occurs as often in the PDF as in the Markdown",
              f"md {n_md}, pdf {n_pdf}")
    check(re.search(r"Mainnet 731 \(\s*0x2db\s*\)", f) is not None, f"{doc}: networks row `Mainnet 731 (0x2db)`")
    check(re.search(r"0x2db\s*mainnet", f) is not None, f"{doc}: `0x2db mainnet` (eth_chainId line)")
    check("not chain 731 (mainnet)" in f, f"{doc}: check-node message `not chain 731 (mainnet)`")
    check("/etc/telcoin/chain-configs/" in f, f"{doc}: `/etc/telcoin/chain-configs/`")
    check("v0.16.0-adiri" in f, f"{doc}: `v0.16.0-adiri`")
    no(r"487", neg, f"{doc}: no `487`")
    no(r"0x1e7", neg, f"{doc}: no `0x1e7`", re.I)
    no(r"c7i\.8xlarge", neg, f"{doc}: no `c7i.8xlarge`")
    no(r"These figures come from", neg, f"{doc}: no `These figures come from`")
    no(r"git pull failed", neg, f"{doc}: no `git pull failed`")
    no(r"rolls back unchanged", neg, f"{doc}: no `rolls back unchanged`")
    no(r"\blegacy\b", neg, f"{doc}: no `legacy`", re.I)
    no(r"[0-9]+ vCPU \([0-9]+ cores", neg, f"{doc}: no vCPU-before-cores figure")
    no(r"confidential\s+and\s+proprietary", neg, f"{doc}: no confidentiality marking", re.I)
    # The guide's tables equal the one-pagers' tables, cell for cell.
    for net, g in (("testnet", gt), ("mainnet", gm)):
        o = got_tables.get(net)
        check(g is not None and o is not None and list(g) == list(o),
              f"guide {net} table cells == {net} one-pager table cells", f"{len(g or [])} rows")
    print(f"\n{len(FAILS)} failure(s)")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
