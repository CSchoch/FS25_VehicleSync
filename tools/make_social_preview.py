#!/usr/bin/env python3
"""
Draws the GitHub social preview card (_art/social_preview.png, 1280x640) from the mod icon in the
colours of the in-cab terminal. Upload it under Settings > General > Social preview on GitHub.

Needs Pillow and the Segoe UI fonts of Windows; run tools/make_icon.py first.

Usage:  python tools/make_social_preview.py
"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

MOD_ROOT = Path(__file__).resolve().parent.parent
ART_DIR = MOD_ROOT / "_art"
ICON_PATH = ART_DIR / "icon_VehicleSync.png"
PNG_PATH = ART_DIR / "social_preview.png"
FONT_DIR = Path("C:/Windows/Fonts")

WIDTH, HEIGHT = 1280, 640
ICON = 400
MARGIN = 80

# VehicleSyncHudLayout.COLOR (sRGB)
GLASS = (0x1B, 0x21, 0x24)
BEZEL = (0x2C, 0x34, 0x38)
STRAW = (0xD6, 0xB8, 0x5A)
PAPER = (0xEC, 0xE8, 0xDC)
MUTED = (0xA9, 0xB1, 0xB4)
TRACKING = (0x7F, 0xBF, 0x6A)


def font(name, size):
    return ImageFont.truetype(str(FONT_DIR / name), size)


def main():
    img = Image.new("RGB", (WIDTH, HEIGHT), GLASS)
    d = ImageDraw.Draw(img)

    # green stripe on the left, like the state bar of the terminal while tracking
    d.rectangle([0, 0, 12, HEIGHT], fill=TRACKING)

    icon = Image.open(ICON_PATH).convert("RGBA").resize((ICON, ICON), Image.LANCZOS)
    mask = Image.new("L", (ICON, ICON), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, ICON - 1, ICON - 1], radius=36, fill=255)
    top = (HEIGHT - ICON) // 2
    img.paste(icon, (MARGIN, top), mask)

    x = MARGIN + ICON + 64
    d.text((x, top + 10), "FARMING SIMULATOR 25 MOD", font=font("segoeuib.ttf", 26), fill=STRAW)
    d.text((x, top + 46), "Vehicle Sync", font=font("segoeuib.ttf", 92), fill=PAPER)
    tagline = ["The harvester steers the grain cart.", "Unload on the go - in multiplayer."]
    for i, line in enumerate(tagline):
        d.text((x, top + 176 + i * 46), line, font=font("segoeui.ttf", 36), fill=MUTED)

    chip_font = font("segoeuib.ttf", 24)
    cx, cy = x, top + ICON - 52
    for label in ["Multiplayer", "Driver assist", "In-cab terminal"]:
        w = d.textlength(label, font=chip_font)
        d.rounded_rectangle([cx, cy, cx + w + 36, cy + 48], radius=8, fill=BEZEL)
        d.text((cx + 18, cy + 24), label, font=chip_font, fill=PAPER, anchor="lm")
        cx += w + 36 + 14

    img.save(PNG_PATH)
    print(f"wrote {PNG_PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
