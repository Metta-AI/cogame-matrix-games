#!/usr/bin/env python3
"""Bake every Matrix Games board asset. Deterministic, re-runnable, committed.

Run from the repository root:

    python3 scripts/art/split_cog_sheet.py data/cog     # nano-banana poses
    python3 scripts/art/gen_matrix_art.py               # everything else

Inputs
------
* `data/cog/cog_{idle,carry,hold,fire}.png` -- the four poses split out of the
  nano-banana render `scripts/art/source/cogs_sheet.png`. They ship in a
  neutral white/grey paint scheme precisely so this script can retint them.
* nothing else. No download, no network, no placeholder.

Outputs
-------
* `data/rig_matrix/<livery>/{idle,carry,hold,fire}.png` -- the eight seat
  liveries, plus `armband.png`, the camp decal used only in
  `bach-or-stravinsky`.
* `data/tokens/<variant>_<index>.png` -- one hand-drawn silhouette per token
  per variant, on the token type's chrome colour. 7 variants x K = 17 sprites.
* `data/yard_floor.png` -- the tiled stained-concrete yard bake with faded
  court lines. Walls reuse the shipped `client/art/walls/{wall_h,wall_v}.jpg`.
* `data/beam_<livery>.png`, `data/reset_burst.png`, `data/pickup_spark.png`.
* every one of the above is mirrored into `client/art/` for the viewer bundle.

The retint is a hue/saturation transfer, not a multiply: the neutral cog's
value structure (screen face, tyre, shading) is preserved and only the plating
band moves to the livery hue, which is why eight liveries stay readable at
40 px.
"""

from __future__ import annotations

import colorsys
import math
import shutil
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "data"
CLIENT_ART = ROOT / "client" / "art"
POSES = ["idle", "carry", "hold", "fire"]

# Slot -> (alias, livery key, livery hex). Mirrors the seat table in
# docs/plans/2026-08-24-matrix-games-design.md and LiveryKeys/LiveryHex in
# src/matrix_games/sim_types.nim. Keep the three in step.
LIVERIES = [
    ("Ash", "cobalt", "#3f7cc4"),
    ("Birch", "sky", "#6fb3e8"),
    ("Cedar", "moss", "#45a85e"),
    ("Dune", "lime", "#8fd26a"),
    ("Elm", "rust", "#e0523a"),
    ("Fern", "ember", "#f08a4b"),
    ("Gorse", "brass", "#ddc531"),
    ("Holly", "plum", "#b06fd0"),
]

# Token chrome colours by type index: the same ["red","blue","green"] the
# viewer's momentum legend already knows.
TOKEN_COLORS = ["#e0523a", "#3f7cc4", "#45a85e"]

# variant -> the glyph drawn for each token index.
VARIANT_GLYPHS = {
    "running-with-scissors": ["rock", "scroll", "shears"],
    "prisoners-dilemma": ["handshake", "dagger"],
    "chicken": ["dove", "hawk"],
    "stag-hunt": ["antlers", "hare"],
    "bach-or-stravinsky": ["lute", "violin"],
    "pure-coordination": ["disc", "disc", "disc"],
    "rationalizable-coordination": ["disc", "disc", "disc"],
}

TOKEN_PX = 64
FLOOR_PX = 256


def hex_rgb(text: str) -> tuple[int, int, int]:
    text = text.lstrip("#")
    return (int(text[0:2], 16), int(text[2:4], 16), int(text[4:6], 16))


# ---------------------------------------------------------------- retinting

def despill(image: Image.Image) -> Image.Image:
    """Neutralise chroma-key spill left over from the keying pass."""
    image = image.convert("RGBA")
    px = image.load()
    width, height = image.size
    for y in range(height):
        for x in range(width):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            if g > r + 24 and g > b + 24:
                level = (r + b) // 2
                px[x, y] = (r, level, b, a)
    return image


def retint(image: Image.Image, hex_color: str) -> Image.Image:
    """Move the cog's neutral plating onto the livery hue.

    Pixels are classified by value and saturation: near-black (the screen
    face, the tyre, the outline) and the cyan eyes are left alone, everything
    else takes the livery hue with its own value curve preserved. That keeps
    eight liveries distinguishable while every cog still reads as the same
    Softmax cog.
    """
    target_r, target_g, target_b = hex_rgb(hex_color)
    th, ts, _tv = colorsys.rgb_to_hsv(
        target_r / 255.0, target_g / 255.0, target_b / 255.0)
    image = image.convert("RGBA")
    px = image.load()
    width, height = image.size
    for y in range(height):
        for x in range(width):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            h, s, v = colorsys.rgb_to_hsv(r / 255.0, g / 255.0, b / 255.0)
            if v < 0.22:
                continue                      # outline / tyre / screen glass
            if s > 0.35 and 0.42 < h < 0.60:
                continue                      # the cyan screen face + eyes
            # Plating: keep the value ramp, adopt the livery hue, and give
            # flat white panels a floor of saturation so the livery reads.
            nv = 0.20 + 0.80 * v
            ns = max(ts * 0.85, min(1.0, s + 0.55))
            nr, ng, nb = colorsys.hsv_to_rgb(th, ns, min(1.0, nv))
            px[x, y] = (int(nr * 255), int(ng * 255), int(nb * 255), a)
    return image


def armband(hex_color: str) -> Image.Image:
    """The camp decal: a chevron badge, drawn only in bach-or-stravinsky."""
    size = 32
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.ellipse((1, 1, size - 2, size - 2), fill=(28, 22, 16, 235),
                 outline=hex_rgb(hex_color), width=3)
    draw.polygon([(8, 21), (16, 9), (24, 21), (16, 17)],
                 fill=hex_rgb(hex_color))
    return image


# ------------------------------------------------------------- token glyphs

def token_sprite(glyph: str, hex_color: str, index: int) -> Image.Image:
    size = TOKEN_PX
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    body = hex_rgb(hex_color)
    ink = (26, 20, 14, 255)
    paper = (242, 232, 216, 255)
    # every token is a gem: a rounded plinth in the type's chrome colour with
    # the glyph cut out of it in paper, so the type reads by colour at board
    # scale and by silhouette at rest.
    draw.rounded_rectangle((4, 4, size - 5, size - 5), radius=12,
                           fill=body + (255,), outline=ink, width=3)
    draw.rounded_rectangle((8, 8, size - 9, 22), radius=8,
                           fill=(255, 255, 255, 46))
    cx, cy = size // 2, size // 2 + 2

    if glyph == "rock":
        draw.polygon([(cx - 15, cy + 11), (cx - 10, cy - 6), (cx + 2, cy - 13),
                      (cx + 14, cy - 3), (cx + 12, cy + 11)], fill=paper,
                     outline=ink)
        draw.line((cx - 6, cy + 2, cx + 4, cy - 4), fill=ink, width=2)
    elif glyph == "scroll":
        draw.rounded_rectangle((cx - 13, cy - 13, cx + 13, cy + 11), radius=3,
                               fill=paper, outline=ink, width=2)
        for row in range(3):
            draw.line((cx - 8, cy - 6 + row * 7, cx + 8, cy - 6 + row * 7),
                      fill=ink, width=2)
    elif glyph == "shears":
        draw.line((cx - 12, cy - 12, cx + 9, cy + 9), fill=paper, width=5)
        draw.line((cx + 12, cy - 12, cx - 9, cy + 9), fill=paper, width=5)
        draw.ellipse((cx - 15, cy + 5, cx - 5, cy + 15), outline=paper, width=3)
        draw.ellipse((cx + 5, cy + 5, cx + 15, cy + 15), outline=paper, width=3)
    elif glyph == "handshake":
        draw.rounded_rectangle((cx - 16, cy - 5, cx - 1, cy + 6), radius=4,
                               fill=paper, outline=ink, width=2)
        draw.rounded_rectangle((cx + 1, cy - 5, cx + 16, cy + 6), radius=4,
                               fill=paper, outline=ink, width=2)
        draw.line((cx, cy - 9, cx, cy + 10), fill=ink, width=2)
    elif glyph == "dagger":
        draw.polygon([(cx, cy - 16), (cx + 5, cy + 2), (cx, cy + 8),
                      (cx - 5, cy + 2)], fill=paper, outline=ink)
        draw.line((cx - 10, cy + 4, cx + 10, cy + 4), fill=paper, width=4)
        draw.line((cx, cy + 8, cx, cy + 15), fill=paper, width=4)
    elif glyph == "dove":
        draw.ellipse((cx - 13, cy - 6, cx + 7, cy + 8), fill=paper, outline=ink)
        draw.polygon([(cx - 4, cy - 4), (cx + 12, cy - 15), (cx + 7, cy + 1)],
                     fill=paper, outline=ink)
        draw.polygon([(cx + 6, cy - 8), (cx + 16, cy - 5), (cx + 6, cy - 2)],
                     fill=paper)
    elif glyph == "hawk":
        draw.polygon([(cx - 16, cy - 12), (cx, cy + 2), (cx + 16, cy - 12),
                      (cx + 8, cy + 12), (cx - 8, cy + 12)], fill=paper,
                     outline=ink)
        draw.line((cx, cy - 12, cx, cy + 12), fill=ink, width=2)
    elif glyph == "antlers":
        draw.line((cx, cy + 14, cx, cy - 2), fill=paper, width=4)
        for side in (-1, 1):
            draw.line((cx, cy - 2, cx + side * 13, cy - 14), fill=paper, width=4)
            draw.line((cx + side * 6, cy - 7, cx + side * 8, cy - 16),
                      fill=paper, width=3)
    elif glyph == "hare":
        draw.ellipse((cx - 9, cy - 2, cx + 9, cy + 14), fill=paper, outline=ink)
        for side in (-1, 1):
            draw.ellipse((cx + side * 6 - 4, cy - 17, cx + side * 6 + 4,
                          cy - 1), fill=paper, outline=ink)
    elif glyph == "lute":
        draw.ellipse((cx - 10, cy - 2, cx + 10, cy + 15), fill=paper,
                     outline=ink)
        draw.rectangle((cx - 3, cy - 17, cx + 3, cy - 1), fill=paper,
                       outline=ink)
        draw.ellipse((cx - 3, cy + 3, cx + 3, cy + 9), fill=ink)
    elif glyph == "violin":
        draw.polygon([(cx - 9, cy + 2), (cx - 6, cy - 6), (cx, cy - 9),
                      (cx + 6, cy - 6), (cx + 9, cy + 2), (cx + 5, cy + 14),
                      (cx - 5, cy + 14)], fill=paper, outline=ink)
        draw.line((cx, cy - 16, cx, cy - 8), fill=paper, width=4)
        draw.line((cx - 2, cy - 1, cx - 2, cy + 7), fill=ink, width=1)
        draw.line((cx + 2, cy - 1, cx + 2, cy + 7), fill=ink, width=1)
    else:  # "disc" -- pure / rationalizable coordination
        rings = index + 1
        for ring in range(rings):
            inset = 4 + ring * 5
            draw.ellipse((cx - 16 + inset, cy - 16 + inset,
                          cx + 16 - inset, cy + 16 - inset),
                         outline=paper, width=3)
        draw.ellipse((cx - 3, cy - 3, cx + 3, cy + 3), fill=paper)
    return image


# --------------------------------------------------------------- yard floor

def yard_floor() -> Image.Image:
    """Stained concrete with faded court lines, tiled by the renderer."""
    size = FLOOR_PX
    image = Image.new("RGB", (size, size), (56, 52, 47))
    px = image.load()
    # Deterministic value noise: a fixed integer hash, never `random`.
    for y in range(size):
        for x in range(size):
            h = (x * 374761393 + y * 668265263) & 0xFFFFFFFF
            h = (h ^ (h >> 13)) * 1274126177 & 0xFFFFFFFF
            n = (h >> 16) & 0x3F
            blot = int(18 * math.sin(x * 0.031) * math.sin(y * 0.027))
            v = 46 + (n >> 2) + blot
            px[x, y] = (max(20, min(96, v + 6)), max(18, min(92, v + 2)),
                        max(16, min(86, v - 3)))
    image = image.filter(ImageFilter.GaussianBlur(0.6))
    draw = ImageDraw.Draw(image, "RGBA")
    # faded court lines
    draw.rectangle((18, 18, size - 19, size - 19), outline=(210, 196, 168, 46),
                   width=3)
    draw.line((size // 2, 18, size // 2, size - 19), fill=(210, 196, 168, 34),
              width=3)
    draw.ellipse((size // 2 - 44, size // 2 - 44, size // 2 + 44,
                  size // 2 + 44), outline=(210, 196, 168, 34), width=3)
    return image


def beam_sprite(hex_color: str) -> Image.Image:
    width, height = 160, 24
    image = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    r, g, b = hex_rgb(hex_color)
    for row in range(height):
        d = abs(row - height / 2) / (height / 2)
        alpha = int(226 * (1.0 - d) ** 2)
        draw.line((0, row, width, row), fill=(r, g, b, alpha))
    draw.line((0, height // 2, width, height // 2), fill=(255, 246, 232, 236),
              width=2)
    return image


def reset_burst() -> Image.Image:
    size = 96
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    for ring in range(5):
        inset = 6 + ring * 8
        alpha = 190 - ring * 34
        draw.ellipse((inset, inset, size - inset, size - inset),
                     outline=(255, 236, 206, alpha), width=3)
    return image


def pickup_spark() -> Image.Image:
    size = 40
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    cx = cy = size // 2
    for step in range(8):
        angle = step * math.pi / 4
        draw.line((cx, cy,
                   cx + int(16 * math.cos(angle)),
                   cy + int(16 * math.sin(angle))),
                  fill=(255, 244, 214, 210), width=2)
    draw.ellipse((cx - 5, cy - 5, cx + 5, cy + 5), fill=(255, 250, 232, 240))
    return image


# --------------------------------------------------------------------- main

def main() -> int:
    poses = {}
    for pose in POSES:
        path = DATA / "cog" / f"cog_{pose}.png"
        if not path.exists():
            raise SystemExit(
                f"missing {path}; run scripts/art/split_cog_sheet.py first")
        poses[pose] = despill(Image.open(path))

    for _alias, key, hex_color in LIVERIES:
        out = DATA / "rig_matrix" / key
        out.mkdir(parents=True, exist_ok=True)
        for pose, image in poses.items():
            retint(image.copy(), hex_color).save(out / f"{pose}.png")
        armband(hex_color).save(out / "armband.png")
        beam_sprite(hex_color).save(DATA / f"beam_{key}.png")

    tokens = DATA / "tokens"
    tokens.mkdir(parents=True, exist_ok=True)
    for variant, glyphs in VARIANT_GLYPHS.items():
        for index, glyph in enumerate(glyphs):
            token_sprite(glyph, TOKEN_COLORS[index], index).save(
                tokens / f"{variant}_{index}.png")

    yard_floor().save(DATA / "yard_floor.png")
    reset_burst().save(DATA / "reset_burst.png")
    pickup_spark().save(DATA / "pickup_spark.png")

    # Mirror into client/art for the viewer bundle and the live /global page.
    CLIENT_ART.mkdir(parents=True, exist_ok=True)
    (CLIENT_ART / "rig_matrix").mkdir(parents=True, exist_ok=True)
    (CLIENT_ART / "tokens").mkdir(parents=True, exist_ok=True)
    for _alias, key, _hex in LIVERIES:
        dst = CLIENT_ART / "rig_matrix" / key
        dst.mkdir(parents=True, exist_ok=True)
        for name in POSES + ["armband"]:
            shutil.copyfile(DATA / "rig_matrix" / key / f"{name}.png",
                            dst / f"{name}.png")
        shutil.copyfile(DATA / f"beam_{key}.png",
                        CLIENT_ART / f"beam_{key}.png")
    for path in sorted(tokens.glob("*.png")):
        shutil.copyfile(path, CLIENT_ART / "tokens" / path.name)
    for name in ("yard_floor.png", "reset_burst.png", "pickup_spark.png"):
        shutil.copyfile(DATA / name, CLIENT_ART / name)
    print("matrix-games art baked into data/ and client/art/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
