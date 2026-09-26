#!/usr/bin/env python3
"""
Draws the HUD icon atlas of the Vehicle Sync terminal and converts it to textures/hud_icons.dds
(256x256, BC3 with alpha, 4 mip levels).

The atlas is a 4x4 grid of 64 px cells with white glyphs on transparent background; the HUD tints
them with Overlay:setColor. Cell order must match VehicleSyncHudLayout.ICON:
    row 0: harvester, cart, arrow up, arrow down
    row 1: arrow left, arrow right, home crosshair, close
    row 2: solid white (used for all plain rectangles)

Needs Pillow and texconv.exe (DirectXTex), see tools/make_icon.py.

Usage:  python tools/make_hud_icons.py
"""

import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw

from make_icon import texconv_path

MOD_ROOT = Path(__file__).resolve().parent.parent
ART_DIR = MOD_ROOT / "_art"
PNG_PATH = ART_DIR / "hud_icons.png"
TEXTURE_DIR = MOD_ROOT / "textures"
DDS_NAME = "hud_icons.dds"

CELL = 64
GRID = 4
SS = 4  # supersampling
WHITE = (255, 255, 255, 255)
CLEAR = (0, 0, 0, 0)


class Cell:
    """Draws into one atlas cell with coordinates on the 64 px cell grid"""

    def __init__(self, draw, col, row):
        self.d = draw
        self.ox = col * CELL * SS
        self.oy = row * CELL * SS

    def p(self, x, y):
        return (self.ox + int(x * SS), self.oy + int(y * SS))

    def rect(self, x0, y0, x1, y1, fill=WHITE, r=0):
        self.d.rounded_rectangle([self.p(x0, y0), self.p(x1, y1)], radius=int(r * SS), fill=fill)

    def poly(self, points, fill=WHITE):
        self.d.polygon([self.p(x, y) for x, y in points], fill=fill)

    def line(self, x0, y0, x1, y1, width):
        self.d.line([self.p(x0, y0), self.p(x1, y1)], fill=WHITE, width=int(width * SS))

    def ring(self, cx, cy, r, width):
        self.d.ellipse([self.p(cx - r, cy - r), self.p(cx + r, cy + r)], outline=WHITE, width=int(width * SS))


def harvester(c):
    c.rect(6, 5, 58, 13, r=2)            # header
    c.rect(27, 12, 37, 19)               # feeder house
    c.rect(18, 17, 46, 59, r=6)          # body
    c.rect(23, 21, 41, 31, CLEAR, r=3)   # cab glass
    c.rect(23, 36, 41, 54, CLEAR, r=3)   # grain tank
    c.rect(26, 39, 38, 51, r=2)          # grain


def cart(c):
    c.rect(30, 4, 34, 18)                # drawbar
    c.rect(16, 16, 48, 60, r=5)          # box
    c.rect(21, 21, 43, 55, CLEAR, r=3)
    c.rect(25, 25, 39, 51, r=2)          # grain


def arrow_up(c):
    c.poly([(32, 7), (56, 34), (8, 34)])
    c.rect(23, 33, 41, 57)


def rotated(base, angle):
    """Renders a glyph into a temporary cell and rotates it"""
    tile = Image.new("RGBA", (CELL * SS, CELL * SS), CLEAR)
    base(Cell(ImageDraw.Draw(tile), 0, 0))
    return tile.rotate(angle, resample=Image.BICUBIC)


def home(c):
    c.ring(32, 32, 19, 5)
    c.line(32, 4, 32, 22, 5)
    c.line(32, 42, 32, 60, 5)
    c.line(4, 32, 22, 32, 5)
    c.line(42, 32, 60, 32, 5)


def close(c):
    c.line(14, 14, 50, 50, 8)
    c.line(50, 14, 14, 50, 8)


def solid(c):
    c.rect(0, 0, 64, 64)


def draw():
    size = CELL * GRID * SS
    img = Image.new("RGBA", (size, size), CLEAR)
    d = ImageDraw.Draw(img)

    harvester(Cell(d, 0, 0))
    cart(Cell(d, 1, 0))
    arrow_up(Cell(d, 2, 0))
    for (col, row), angle in [((3, 0), 180), ((0, 1), 90), ((1, 1), -90)]:
        img.alpha_composite(rotated(arrow_up, angle), (col * CELL * SS, row * CELL * SS))
    home(Cell(d, 2, 1))
    close(Cell(d, 3, 1))
    solid(Cell(d, 0, 2))

    return img.resize((CELL * GRID, CELL * GRID), Image.LANCZOS)


def main():
    ART_DIR.mkdir(exist_ok=True)
    TEXTURE_DIR.mkdir(exist_ok=True)
    draw().save(PNG_PATH)
    print(f"wrote {PNG_PATH}")

    texconv = texconv_path()
    if texconv is None:
        print("texconv.exe not found - PNG only")
        return 1
    subprocess.run([texconv, "-nologo", "-y", "-f", "BC3_UNORM", "-m", "4", "-o", str(TEXTURE_DIR),
                    str(PNG_PATH)], check=True)
    produced = TEXTURE_DIR / (PNG_PATH.stem + ".dds")
    target = TEXTURE_DIR / DDS_NAME
    if produced != target:
        produced.replace(target)
    print(f"wrote {target}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
