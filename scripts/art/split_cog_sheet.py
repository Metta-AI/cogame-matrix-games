#!/usr/bin/env python3
"""Key, split and pad the nano-banana cog sheet into four pose sprites.

`scripts/art/source/cogs_sheet.png` is a single `gemini-2.5-flash-image`
render (playbooks/art-nanobanana.md): four Softmax cogs in a neutral white /
light-grey paint scheme on a flat chroma-green backdrop, one row, four poses.
The paint scheme is deliberately neutral so `gen_matrix_art.py` can retint the
same body into the eight seat liveries.

The backdrop colour is taken as the MEDIAN of the border pixels (corners
sometimes carry a smudge) and removed by a flood fill from the border, so a
green accent inside a cog survives. The row is then split on empty columns,
each part is padded to a square and resized.

    python3 scripts/art/split_cog_sheet.py data/cog

writes `data/cog/cog_idle.png`, `cog_carry.png`, `cog_hold.png`,
`cog_fire.png`. Deterministic: same sheet in, same bytes out.
"""

from __future__ import annotations

import sys
from collections import deque
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
SHEET = ROOT / "scripts" / "art" / "source" / "cogs_sheet.png"
POSES = ["cog_idle", "cog_carry", "cog_hold", "cog_fire"]
OUT_PX = 128
KEY_TOLERANCE = 60


def median_border(image: Image.Image) -> tuple[int, int, int]:
    width, height = image.size
    px = image.load()
    samples = []
    for x in range(width):
        samples.append(px[x, 0][:3])
        samples.append(px[x, height - 1][:3])
    for y in range(height):
        samples.append(px[0, y][:3])
        samples.append(px[width - 1, y][:3])
    channels = []
    for index in range(3):
        values = sorted(sample[index] for sample in samples)
        channels.append(values[len(values) // 2])
    return (channels[0], channels[1], channels[2])


def key_out(image: Image.Image) -> Image.Image:
    """Flood-fill the backdrop from every border pixel that matches the key."""
    image = image.convert("RGBA")
    width, height = image.size
    px = image.load()
    key = median_border(image)

    def is_key(x: int, y: int) -> bool:
        r, g, b, _ = px[x, y]
        return (
            abs(r - key[0]) <= KEY_TOLERANCE
            and abs(g - key[1]) <= KEY_TOLERANCE
            and abs(b - key[2]) <= KEY_TOLERANCE
        )

    seen = bytearray(width * height)
    queue: deque[tuple[int, int]] = deque()
    for x in range(width):
        for y in (0, height - 1):
            if not seen[y * width + x] and is_key(x, y):
                seen[y * width + x] = 1
                queue.append((x, y))
    for y in range(height):
        for x in (0, width - 1):
            if not seen[y * width + x] and is_key(x, y):
                seen[y * width + x] = 1
                queue.append((x, y))
    while queue:
        x, y = queue.popleft()
        px[x, y] = (0, 0, 0, 0)
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < width and 0 <= ny < height:
                if not seen[ny * width + nx] and is_key(nx, ny):
                    seen[ny * width + nx] = 1
                    queue.append((nx, ny))
    return image


def column_runs(image: Image.Image) -> list[tuple[int, int]]:
    width, height = image.size
    px = image.load()
    occupied = []
    for x in range(width):
        count = 0
        for y in range(height):
            if px[x, y][3] > 24:
                count += 1
                if count > 2:
                    break
        occupied.append(count > 2)
    runs = []
    start = None
    for x, live in enumerate(occupied):
        if live and start is None:
            start = x
        elif not live and start is not None:
            if x - start > width // 40:
                runs.append((start, x))
            start = None
    if start is not None:
        runs.append((start, width))
    return runs


def crop_square(image: Image.Image, x0: int, x1: int) -> Image.Image:
    part = image.crop((x0, 0, x1, image.size[1]))
    box = part.getbbox()
    if box:
        part = part.crop(box)
    side = max(part.size)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(part, ((side - part.size[0]) // 2, side - part.size[1]))
    return canvas.resize((OUT_PX, OUT_PX), Image.LANCZOS)


def main(out_dir: Path) -> int:
    if not SHEET.exists():
        print(f"missing source sheet: {SHEET}", file=sys.stderr)
        return 1
    out_dir.mkdir(parents=True, exist_ok=True)
    keyed = key_out(Image.open(SHEET))
    runs = column_runs(keyed)
    if len(runs) != len(POSES):
        print(f"expected {len(POSES)} cogs on the sheet, found {len(runs)}",
              file=sys.stderr)
        return 1
    for name, (x0, x1) in zip(POSES, runs):
        crop_square(keyed, x0, x1).save(out_dir / f"{name}.png")
        print(f"wrote {out_dir / (name + '.png')}")
    return 0


if __name__ == "__main__":
    target = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "data" / "cog"
    raise SystemExit(main(target))
