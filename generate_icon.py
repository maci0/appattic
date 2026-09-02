#!/usr/bin/env python3
"""Rasterize the AppAttic mark (same geometry as packaging/appattic.svg)."""
import os
import struct
import zlib

# DESIGN.md tokens.
BG = (30, 30, 30, 255)  # #1e1e1e dark list fill
BLUE = (10, 132, 255, 255)  # #0a84ff accent
PANEL = (46, 46, 46, 255)  # #2e2e2e dark chrome
RED = (255, 69, 58, 255)  # #ff453a REMOVE
GREEN = (48, 209, 88, 255)  # #30d158 KEEP

def create_png(width, height, pixels):
    def chunk(chunk_type, data):
        c = chunk_type + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    raw = bytearray()
    row = width * 4
    for y in range(height):
        raw.append(0)
        raw.extend(pixels[y * row : (y + 1) * row])
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )


def packbits(data):
    out = bytearray()
    i = 0
    n = len(data)
    while i < n:
        run = 1
        while i + run < n and run < 128 and data[i + run] == data[i]:
            run += 1
        if run >= 3:
            out.append((1 - run) & 0xFF)
            out.append(data[i])
            i += run
            continue
        j = i
        while j < n and j - i < 128:
            run2 = 1
            while j + run2 < n and run2 < 128 and data[j + run2] == data[j]:
                run2 += 1
            if run2 >= 3:
                break
            j += 1
        out.append(j - i - 1)
        out.extend(data[i:j])
        i = j
    return bytes(out)


def argb_icon(pixels, size):
    a, r, g, b = bytearray(), bytearray(), bytearray(), bytearray()
    for i in range(0, size * size * 4, 4):
        r.append(pixels[i])
        g.append(pixels[i + 1])
        b.append(pixels[i + 2])
        a.append(pixels[i + 3])
    return b"ARGB" + packbits(bytes(a)) + packbits(bytes(r)) + packbits(bytes(g)) + packbits(bytes(b))


def create_icns(images):
    parts = []
    for ostype, data in images:
        parts.append(ostype + struct.pack(">I", 8 + len(data)) + data)
    body = b"".join(parts)
    return b"icns" + struct.pack(">I", 8 + len(body)) + body


def draw_icon(size):
    pixels = [0] * (size * size * 4)

    def set_pixel(x, y, color):
        if 0 <= x < size and 0 <= y < size:
            idx = (y * size + x) * 4
            pixels[idx : idx + 4] = color

    def sx(v):
        return v * size / 128.0

    def fill_rounded_rect(x1, y1, x2, y2, r, color):
        x1, y1, x2, y2 = int(x1), int(y1), int(round(x2)), int(round(y2))
        r = max(0, min(int(round(r)), (x2 - x1) // 2, (y2 - y1) // 2))
        for y in range(max(0, y1), min(size, y2)):
            for x in range(max(0, x1), min(size, x2)):
                cx = x1 + r if x < x1 + r else (x2 - 1 - r if x >= x2 - r else None)
                cy = y1 + r if y < y1 + r else (y2 - 1 - r if y >= y2 - r else None)
                if cx is not None and cy is not None:
                    if (x - cx) ** 2 + (y - cy) ** 2 > r * r:
                        continue
                set_pixel(x, y, color)

    def fill_triangle(x1, y1, x2, y2, x3, y3, color):
        minx = max(0, int(min(x1, x2, x3)))
        maxx = min(size, int(max(x1, x2, x3)) + 1)
        miny = max(0, int(min(y1, y2, y3)))
        maxy = min(size, int(max(y1, y2, y3)) + 1)
        den = (y2 - y3) * (x1 - x3) + (x3 - x2) * (y1 - y3)
        if den == 0:
            return
        for y in range(miny, maxy):
            py = y + 0.5
            for x in range(minx, maxx):
                px = x + 0.5
                a = ((y2 - y3) * (px - x3) + (x3 - x2) * (py - y3)) / den
                b = ((y3 - y1) * (px - x3) + (x1 - x3) * (py - y3)) / den
                c = 1.0 - a - b
                if a >= 0 and b >= 0 and c >= 0:
                    set_pixel(x, y, color)

    def fill_rect(x1, y1, x2, y2, color):
        for y in range(max(0, int(y1)), min(size, int(round(y2)))):
            for x in range(max(0, int(x1)), min(size, int(round(x2)))):
                set_pixel(x, y, color)

    fill_rounded_rect(0, 0, size, size, sx(24), BG)
    fill_triangle(sx(24), sx(72), sx(64), sx(40), sx(104), sx(72), BLUE)
    fill_rect(sx(24), sx(72), sx(104), sx(96), BLUE)
    fill_rect(sx(34), sx(72), sx(94), sx(96), PANEL)
    fill_rounded_rect(sx(52), sx(80), sx(76), sx(96), sx(2), BLUE)
    fill_rounded_rect(sx(40), sx(52), sx(54), sx(66), sx(2), GREEN)
    fill_rounded_rect(sx(74), sx(52), sx(88), sx(66), sx(2), RED)
    return pixels


def main():
    root = os.path.dirname(os.path.abspath(__file__))
    sizes = {
        16: None,
        32: None,
        64: None,
        128: None,
        256: None,
        512: None,
        1024: None,
    }
    for sz in sizes:
        sizes[sz] = draw_icon(sz)

    png = {sz: create_png(sz, sz, px) for sz, px in sizes.items()}
    images = [
        (b"ic04", argb_icon(sizes[16], 16)),
        (b"ic05", argb_icon(sizes[32], 32)),
        (b"ic11", png[32]),
        (b"ic12", png[64]),
        (b"ic07", png[128]),
        (b"ic08", png[256]),
        (b"ic13", png[256]),
        (b"ic09", png[512]),
        (b"ic14", png[512]),
        (b"ic10", png[1024]),
    ]
    icns_path = os.path.join(root, "packaging", "AppAttic.icns")
    with open(icns_path, "wb") as f:
        f.write(create_icns(images))
    print("Generated", icns_path)


if __name__ == "__main__":
    main()
