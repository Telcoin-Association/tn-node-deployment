#!/usr/bin/env python3
"""V-DOC-PDF P5: tile binary PPM page renders into PNG contact sheets (no PIL here).

Usage: montage.py OUT_DIR COLS ROWS PAGE.ppm...

Pages are placed row by row, COLS x ROWS per sheet, on a mid-grey ground with an
8 px gutter, in the order given; sheet k is written as OUT_DIR/sheet-<first>-<last>.png
with the 1-based positions of its first and last page in the list. OUT_DIR must
exist. Only the P6 binary PPM that pdftoppm writes (maxval 255) is read.
"""
import struct
import sys
import zlib
from pathlib import Path

GUTTER = 8
GROUND = b"\x80\x80\x80"


def read_ppm(path):
    data = Path(path).read_bytes()
    fields = []
    pos = 0
    while len(fields) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b"#":
            pos = data.index(b"\n", pos) + 1
            continue
        end = pos
        while not data[end:end + 1].isspace():
            end += 1
        fields.append(data[pos:end])
        pos = end
    pos += 1
    if fields[0] != b"P6" or fields[3] != b"255":
        raise SystemExit(f"{path}: not a P6 maxval-255 PPM")
    w, h = int(fields[1]), int(fields[2])
    return w, h, data[pos:pos + w * h * 3]


def write_png(path, w, h, rows):
    raw = b"".join(b"\x00" + r for r in rows)

    def chunk(tag, body):
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")
    Path(path).write_bytes(png)


def main():
    if len(sys.argv) < 5:
        print(__doc__)
        return 2
    out = Path(sys.argv[1])
    cols, rows_n = int(sys.argv[2]), int(sys.argv[3])
    pages = sys.argv[4:]
    per = cols * rows_n
    for start in range(0, len(pages), per):
        group = [read_ppm(p) for p in pages[start:start + per]]
        pw = max(g[0] for g in group)
        ph = max(g[1] for g in group)
        n_rows = (len(group) + cols - 1) // cols
        sw = cols * pw + (cols + 1) * GUTTER
        sh = n_rows * ph + (n_rows + 1) * GUTTER
        sheet = [bytearray(GROUND * sw) for _ in range(sh)]
        for i, (w, h, px) in enumerate(group):
            x0 = GUTTER + (i % cols) * (pw + GUTTER)
            y0 = GUTTER + (i // cols) * (ph + GUTTER)
            for y in range(h):
                sheet[y0 + y][x0 * 3:(x0 + w) * 3] = px[y * w * 3:(y + 1) * w * 3]
        name = out / f"sheet-{start + 1:03d}-{start + len(group):03d}.png"
        write_png(name, sw, sh, [bytes(r) for r in sheet])
        print(name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
