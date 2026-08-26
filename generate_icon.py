#!/usr/bin/env python3
"""Generate a simple AppAttic app icon as a PNG."""
import struct, zlib, os, sys

def create_png(width, height, pixels):
    """Create a PNG from raw RGBA pixel data."""
    def chunk(chunk_type, data):
        c = chunk_type + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
    
    header = b'\x89PNG\r\n\x1a\n'
    ihdr = chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
    
    raw_data = b''
    for y in range(height):
        raw_data += b'\x00'  # filter byte
        for x in range(width):
            idx = (y * width + x) * 4
            raw_data += bytes(pixels[idx:idx+4])
    
    idat = chunk(b'IDAT', zlib.compress(raw_data, 9))
    iend = chunk(b'IEND', b'')
    return header + ihdr + idat + iend

def draw_icon(size):
    """Draw the AppAttic icon."""
    import math
    pixels = [0] * (size * size * 4)
    
    # Colors
    bg = (13, 17, 23, 255)       # dark background
    blue = (88, 166, 255, 255)   # accent blue
    panel = (33, 38, 45, 255)    # panel color
    red = (248, 81, 73, 255)     # red accent
    green = (63, 185, 80, 255)   # green accent
    
    def set_pixel(x, y, color):
        if 0 <= x < size and 0 <= y < size:
            idx = (y * size + x) * 4
            pixels[idx:idx+4] = list(color)
    
    def fill_circle(cx, cy, r, color):
        for y in range(max(0, int(cy-r)), min(size, int(cy+r+1))):
            for x in range(max(0, int(cx-r)), min(size, int(cx+r+1))):
                if (x-cx)**2 + (y-cy)**2 <= r**2:
                    set_pixel(x, y, color)
    
    def fill_rounded_rect(x1, y1, x2, y2, r, color):
        for y in range(max(0, y1), min(size, y2)):
            for x in range(max(0, x1), min(size, x2)):
                # Check corners
                in_rect = True
                for cx, cy in [(x1+r, y1+r), (x2-r, y1+r), (x1+r, y2-r), (x2-r, y2-r)]:
                    if (x < x1+r or x >= x2-r) and (y < y1+r or y >= y2-r):
                        if (x-cx)**2 + (y-cy)**2 > r**2:
                            in_rect = False
                            break
                if in_rect:
                    set_pixel(x, y, color)
    
    s = size
    m = s // 8  # margin
    r = s // 6  # corner radius
    
    # Background: rounded square
    fill_rounded_rect(0, 0, s, s, r, bg)
    
    # Draw a stylized attic/box shape
    # Main box
    bx1 = s * 15 // 100
    by1 = s * 35 // 100
    bx2 = s * 85 // 100
    by2 = s * 82 // 100
    br = s // 20
    fill_rounded_rect(bx1, by1, bx2, by2, br, panel)
    
    # Roof/attic triangle
    roof_top = s * 18 // 100
    roof_peak_x = s // 2
    for y in range(roof_top, by1 + 2):
        progress = (y - roof_top) / max(1, (by1 - roof_top))
        half_width = int(progress * (bx2 - bx1) / 2)
        cx = roof_peak_x
        for x in range(cx - half_width, cx + half_width):
            if 0 <= x < s:
                set_pixel(x, y, blue)
    
    # Horizontal lines inside box (like data rows)
    line_h = max(2, s // 40)
    for i, (color, width_pct) in enumerate([(red, 70), (green, 50), (blue, 85), (red, 40)]):
        ly = by1 + s * (15 + i * 14) // 100
        lx1 = bx1 + s * 8 // 100
        lx2 = lx1 + (bx2 - bx1 - s * 16 // 100) * width_pct // 100
        for y in range(ly, ly + line_h):
            for x in range(lx1, lx2):
                if by1 < y < by2:
                    set_pixel(x, y, color)
    
    # Small "A" letter in the roof
    # Simple representation
    ax = roof_peak_x
    ay = s * 25 // 100
    fill_circle(ax, ay, s * 3 // 100, (13, 17, 23, 255))
    
    return pixels

# Generate multiple sizes
sizes = [1024, 512, 256, 128, 64, 32, 16]
icon_dir = 'packaging/AppIcon.appiconset'
os.makedirs(icon_dir, exist_ok=True)

for sz in sizes:
    pixels = draw_icon(sz)
    png = create_png(sz, sz, pixels)
    path = f'{icon_dir}/icon_{sz}x{sz}.png'
    with open(path, 'wb') as f:
        f.write(png)
    print(f'Generated {path} ({len(png)} bytes)')

# Also generate as the main app icon
pixels = draw_icon(512)
png = create_png(512, 512, pixels)
with open('packaging/AppIcon.png', 'wb') as f:
    f.write(png)

# Create Contents.json for the asset catalog
import json
contents = {
    "images": [
        {"filename": "icon_16x16.png", "idiom": "mac", "scale": "1x", "size": "16x16"},
        {"filename": "icon_32x32.png", "idiom": "mac", "scale": "2x", "size": "16x16"},
        {"filename": "icon_32x32.png", "idiom": "mac", "scale": "1x", "size": "32x32"},
        {"filename": "icon_64x64.png", "idiom": "mac", "scale": "2x", "size": "32x32"},
        {"filename": "icon_128x128.png", "idiom": "mac", "scale": "1x", "size": "128x128"},
        {"filename": "icon_256x256.png", "idiom": "mac", "scale": "2x", "size": "128x128"},
        {"filename": "icon_256x256.png", "idiom": "mac", "scale": "1x", "size": "256x256"},
        {"filename": "icon_512x512.png", "idiom": "mac", "scale": "2x", "size": "256x256"},
        {"filename": "icon_512x512.png", "idiom": "mac", "scale": "1x", "size": "512x512"},
        {"filename": "icon_1024x1024.png", "idiom": "mac", "scale": "2x", "size": "512x512"},
    ],
    "info": {"author": "xcode", "version": 1}
}
with open(f'{icon_dir}/Contents.json', 'w') as f:
    json.dump(contents, f, indent=2)

if sys.platform == 'darwin':
    import shutil, subprocess, tempfile
    iconutil = shutil.which('iconutil')
    if iconutil:
        iconset = tempfile.mkdtemp(suffix='.iconset')
        pairs = [
            ('icon_16x16.png', 'icon_16x16.png'),
            ('icon_32x32.png', 'icon_16x16@2x.png'),
            ('icon_32x32.png', 'icon_32x32.png'),
            ('icon_64x64.png', 'icon_32x32@2x.png'),
            ('icon_128x128.png', 'icon_128x128.png'),
            ('icon_256x256.png', 'icon_128x128@2x.png'),
            ('icon_256x256.png', 'icon_256x256.png'),
            ('icon_512x512.png', 'icon_256x256@2x.png'),
            ('icon_512x512.png', 'icon_512x512.png'),
            ('icon_1024x1024.png', 'icon_512x512@2x.png'),
        ]
        for src, dest in pairs:
            src_path = os.path.join(icon_dir, src)
            if os.path.isfile(src_path):
                shutil.copyfile(src_path, os.path.join(iconset, dest))
        icns = 'packaging/AppAttic.icns'
        subprocess.check_call([iconutil, '-c', 'icns', iconset, '-o', icns])
        shutil.rmtree(iconset, ignore_errors=True)
        print(f'Generated {icns}')

print('\nIcon generation complete!')
