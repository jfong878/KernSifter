#!/usr/bin/env python3
"""Generates the KernSifter app icon set (PNG / ICO / ICNS) with the
Python standard library only — no Pillow, no ImageMagick.

Outputs into src-tauri/icons/:
  32x32.png, 128x128.png, 128x128@2x.png (256), icon.png (512),
  icon.ico (16/32/48/256), icon.icns (128/256/512)

Re-run any time the artwork changes:  python3 scripts/generate_icons.py
"""
import os
import struct
import sys
import zlib

OUT = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src-tauri", "icons")
)

# ── artwork ────────────────────────────────────────────────────────────────

BG_TOP = (79, 124, 255)    # #4f7cff
BG_BOT = (27, 46, 102)     # #1b2e66
WHITE = (255, 255, 255)
STAR_CENTER = (0.50, 0.40)
STAR_RADIUS = 0.165
DOTS = [(0.30, 0.72, 0.032), (0.55, 0.82, 0.024), (0.73, 0.62, 0.017)]


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def inside_rounded_rect(u, v, radius):
    if radius <= u <= 1 - radius and radius <= v <= 1 - radius:
        return True
    for cu, cv in ((radius, radius), (1 - radius, radius),
                   (radius, 1 - radius), (1 - radius, 1 - radius)):
        if (u - cu) ** 2 + (v - cv) ** 2 <= radius ** 2:
            return True
    return False


def render(size):
    radius = 0.21
    rows = []
    for y in range(size):
        v = (y + 0.5) / size
        row = []
        for x in range(size):
            u = (x + 0.5) / size
            if not inside_rounded_rect(u, v, radius):
                row.append((0, 0, 0, 0))  # transparent outside the tile
                continue
            t = (u + v) / 2
            px = lerp(BG_TOP, BG_BOT, t)
            du, dv = u - STAR_CENTER[0], v - STAR_CENTER[1]
            if (abs(du) ** 4 + abs(dv) ** 4) ** 0.25 <= STAR_RADIUS:
                px = WHITE
            for cu, cv, cr in DOTS:
                if (u - cu) ** 2 + (v - cv) ** 2 <= cr ** 2:
                    px = WHITE
            row.append((*px, 255))
        rows.append(row)
    return rows

# ── encoders ───────────────────────────────────────────────────────────────

def png_bytes(size, rows):
    raw = b"".join(
        b"\x00" + b"".join(struct.pack("BBBB", *p) for p in row) for row in rows
    )

    def chunk(tag, data):
        # PNG chunk layout: [length:4][type:4][data][crc:4]
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))


def ico_bytes(images):
    """images: list of (size, png). PNG-compressed entries (Vista+)."""
    images = sorted(images)
    entries = b""
    blobs = b""
    offset = 6 + 16 * len(images)
    for size, png in images:
        dim = 0 if size >= 256 else size
        entries += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(png), offset)
        blobs += png
        offset += len(png)
    return struct.pack("<HHH", 0, 1, len(images)) + entries + blobs


def icns_bytes(chunks):
    """chunks: list of (fourcc, png). PNG-compressed icns chunks are valid."""
    body = b"".join(fourcc + struct.pack(">I", 8 + len(png)) + png for fourcc, png in chunks)
    return b"icns" + struct.pack(">I", 8 + len(body)) + body


def ascii_preview(rows, size):
    out = []
    step = max(1, size // 16)
    for y in range(0, size, step):
        line = ""
        for x in range(0, size, step):
            r, g, b, a = rows[y][x]
            lum = (0.299 * r + 0.587 * g + 0.114 * b) * (a / 255)
            line += " .:-=+*#%@"[min(9, int(lum / 25.6))]
        out.append(line)
    return "\n".join(out)

# ── main ───────────────────────────────────────────────────────────────────

def main():
    os.makedirs(OUT, exist_ok=True)
    rendered = {s: render(s) for s in (16, 32, 48, 128, 256, 512)}
    pngs = {s: png_bytes(s, rendered[s]) for s in rendered}

    files = {
        "32x32.png": pngs[32],
        "128x128.png": pngs[128],
        "128x128@2x.png": pngs[256],
        "icon.png": pngs[512],
        "icon.ico": ico_bytes([(16, pngs[16]), (32, pngs[32]), (48, pngs[48]), (256, pngs[256])]),
        "icon.icns": icns_bytes([(b"ic07", pngs[128]), (b"ic08", pngs[256]), (b"ic09", pngs[512])]),
    }
    for name, data in files.items():
        path = os.path.join(OUT, name)
        with open(path, "wb") as f:
            f.write(data)
        print(f"wrote {name:20s} {len(data):8d} bytes")

    print("\n512px preview:\n" + ascii_preview(rendered[512], 512))

    # sanity: each file starts with the expected signature
    checks = {
        "32x32.png": b"\x89PNG",
        "icon.png": b"\x89PNG",
        "icon.ico": b"\x00\x00\x01\x00",  # reserved(2) + type=1 icon(2)
        "icon.icns": b"icns",
    }
    for name, magic in checks.items():
        with open(os.path.join(OUT, name), "rb") as f:
            head = f.read(len(magic))
        assert head == magic, (name, head)
    print("headers OK")


if __name__ == "__main__":
    sys.exit(main())
