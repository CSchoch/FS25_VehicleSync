#!/usr/bin/env python3
"""
Draws the mod icon (top view: harvester unloading into a synced grain cart) and converts it to
icon_VehicleSync.dds (512x512, BC1, no mipmaps). The FS25 TestRunner requires 512x512 mod icons
(the ModHub guideline PDF v5.9.1 still says 256x256, which is the FS22 size).

Needs Pillow and texconv.exe (DirectXTex). texconv is searched on PATH, in tools/ and in the
FS25_WorkflowManager tools folder next to this mod.

Usage:  python tools/make_icon.py
"""

import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

MOD_ROOT = Path(__file__).resolve().parent.parent
ART_DIR = MOD_ROOT / "_art"
PNG_PATH = ART_DIR / "icon_VehicleSync.png"
DDS_NAME = "icon_VehicleSync.dds"

SIZE = 512
SS = 4  # supersampling
S = SIZE * SS
UNIT = S / 256  # drawing coordinates are given on a 256 grid


def texconv_path():
    found = shutil.which("texconv")
    if found:
        return found
    for p in [MOD_ROOT / "tools" / "texconv.exe",
              MOD_ROOT.parent / "FS25_WorkflowManager" / "tools" / "texconv.exe"]:
        if p.exists():
            return str(p)
    return None


def px(v):
    return int(v * UNIT)


def rect(d, x0, y0, x1, y1, fill, r=0, outline=None, width=0):
    d.rounded_rectangle([px(x0), px(y0), px(x1), px(y1)], radius=px(r), fill=fill,
                        outline=outline, width=px(width))


def draw():
    img = Image.new("RGB", (S, S))
    d = ImageDraw.Draw(img)

    # background: dark field gradient with stubble rows
    for y in range(S):
        t = y / S
        c = (int(46 + 30 * t), int(64 + 26 * t), int(38 + 14 * t))
        d.line([(0, y), (S, y)], fill=c)
    for i in range(-2, 14):
        x = px(i * 22)
        d.line([(x, 0), (x + px(12), S)], fill=(92, 108, 60), width=px(2))

    # harvested / standing crop split
    d.polygon([(0, 0), (px(70), 0), (px(70), S), (0, S)], fill=(176, 150, 72))
    for i in range(0, 8):
        x = px(4 + i * 9)
        d.line([(x, 0), (x, S)], fill=(150, 124, 54), width=px(2))

    # harvester (left, heading up)
    rect(d, 52, 36, 152, 58, (70, 70, 70), r=4)                       # header
    rect(d, 72, 56, 132, 196, (214, 176, 38), r=10, outline=(60, 50, 20), width=2)  # body
    rect(d, 84, 70, 120, 104, (40, 60, 80), r=5)                       # cab glass
    rect(d, 80, 120, 124, 176, (190, 150, 30), r=6)                    # grain tank
    # unloading pipe to the right
    d.line([(px(126), px(118)), (px(196), px(96))], fill=(60, 60, 60), width=px(12))
    d.line([(px(126), px(118)), (px(196), px(96))], fill=(214, 176, 38), width=px(7))

    # grain cart under the pipe outlet (right)
    rect(d, 176, 84, 236, 172, (180, 40, 36), r=8, outline=(70, 20, 18), width=2)
    rect(d, 184, 94, 228, 162, (206, 170, 80), r=4)                    # grain
    d.ellipse([px(196), px(90), px(214), px(106)], fill=(230, 196, 104))  # fresh grain pile
    # tractor pulling the cart
    d.line([(px(206), px(84)), (px(206), px(66))], fill=(40, 40, 40), width=px(4))
    rect(d, 188, 18, 224, 68, (60, 120, 170), r=7, outline=(20, 40, 60), width=2)
    rect(d, 194, 38, 218, 58, (30, 50, 70), r=4)

    # sync link: dashed line + radio arcs between cab and tractor
    for i in range(6):
        x0 = 128 + i * 11
        d.line([(px(x0), px(210)), (px(x0 + 6), px(210))], fill=(255, 255, 255), width=px(4))
    for r, a in [(14, 255), (24, 190), (34, 120)]:
        d.arc([px(206 - r), px(210 - r), px(206 + r), px(210 + r)], start=200, end=340,
              fill=(255, 255, 255), width=px(4))
    d.ellipse([px(100), px(202), px(116), px(218)], fill=(120, 230, 120))
    d.ellipse([px(198), px(202), px(214), px(218)], fill=(120, 230, 120))

    img = img.filter(ImageFilter.SMOOTH)
    return img.resize((SIZE, SIZE), Image.LANCZOS)


def main():
    ART_DIR.mkdir(exist_ok=True)
    draw().save(PNG_PATH)
    print(f"wrote {PNG_PATH}")

    texconv = texconv_path()
    if texconv is None:
        print("texconv.exe not found - PNG only")
        return 1
    subprocess.run([texconv, "-nologo", "-y", "-f", "BC1_UNORM", "-m", "1", "-o", str(MOD_ROOT),
                    str(PNG_PATH)], check=True)
    produced = MOD_ROOT / (PNG_PATH.stem + ".dds")
    target = MOD_ROOT / DDS_NAME
    if produced != target:
        produced.replace(target)
    print(f"wrote {target}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
