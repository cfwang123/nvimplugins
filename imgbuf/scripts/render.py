#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Chafa-style image renderer for Neovim buffer display.

Protocol (stdout, UTF-8):
  META cols=<c> rows=<r> mode=<mode>
  one line per row; cells space-separated as:
    <codepoint_hex>:<fg_rrggbb>:<bg_rrggbb>

Modes:
  block    - 2x2 quarter-block symbols (chafa default style: ▘▝▖▗▀▄▌▐█)
  braille  - 2x4 braille dots (⠋⣿ …) higher density, not block cells
  half     - classic half-block ▀ (catimg-like)
"""

from __future__ import annotations

import argparse
import sys
from typing import List, Sequence, Tuple

try:
    from PIL import Image
except ImportError:
    print("ERROR: Pillow is required (pip install Pillow)", file=sys.stderr)
    sys.exit(2)

RGB = Tuple[int, int, int]
Cell = Tuple[str, RGB, RGB]

# Braille dot bit order (Unicode braille patterns):
#  1 4
#  2 5
#  3 6
#  7 8
BRAILLE_MAP = (
    (0, 0, 0x01),
    (0, 1, 0x02),
    (0, 2, 0x04),
    (1, 0, 0x08),
    (1, 1, 0x10),
    (1, 2, 0x20),
    (0, 3, 0x40),
    (1, 3, 0x80),
)

# 2x2 quadrant bit -> block element (bit0=UL, bit1=UR, bit2=LL, bit3=LR)
BLOCK_CHARS = (
    " ",
    "▘",
    "▝",
    "▀",
    "▖",
    "▌",
    "▞",
    "▛",
    "▗",
    "▚",
    "▐",
    "▜",
    "▄",
    "▙",
    "▟",
    "█",
)


def luminance(c: RGB) -> float:
    r, g, b = c
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def color_dist2(a: RGB, b: RGB) -> float:
    dr = a[0] - b[0]
    dg = a[1] - b[1]
    db = a[2] - b[2]
    return (2 + a[0] / 256.0) * dr * dr + 4 * dg * dg + (2 + (255 - a[0]) / 256.0) * db * db


def avg_colors(colors: Sequence[RGB]) -> RGB:
    if not colors:
        return (0, 0, 0)
    n = len(colors)
    return (
        sum(c[0] for c in colors) // n,
        sum(c[1] for c in colors) // n,
        sum(c[2] for c in colors) // n,
    )


def hex_rgb(c: RGB) -> str:
    return f"{c[0]:02x}{c[1]:02x}{c[2]:02x}"


def get_pixel(px, x: int, y: int, w: int, h: int) -> RGB:
    x = max(0, min(w - 1, x))
    y = max(0, min(h - 1, y))
    p = px[x, y]
    if len(p) >= 3:
        return (int(p[0]), int(p[1]), int(p[2]))
    v = int(p[0])
    return (v, v, v)


def ordered_bias(x: int, y: int, strength: float) -> float:
    """4x4 Bayer matrix bias for ordered dithering."""
    bayer = (
        (0, 8, 2, 10),
        (12, 4, 14, 6),
        (3, 11, 1, 9),
        (15, 7, 13, 5),
    )
    return (bayer[y & 3][x & 3] / 16.0 - 0.5) * strength * 48.0


def fit_cells(
    src_w: int,
    src_h: int,
    max_cols: int,
    max_rows: int,
) -> Tuple[int, int]:
    """Fit image into max_cols x max_rows cells, preserving aspect.

    Assumes a typical monospace cell is about twice as tall as wide, so
    visual aspect ≈ (cols / rows) * 0.5.
    """
    if src_w <= 0 or src_h <= 0:
        return 1, 1

    max_cols = max(1, max_cols)
    max_rows = max(1, max_rows)
    font_aspect = 0.5  # cell width / cell height
    # visual_aspect = (cols/rows) * font_aspect == src_w/src_h
    cols_per_row = (src_w / src_h) / font_aspect

    cols = max_cols
    rows = max(1, int(round(cols / cols_per_row)))
    if rows > max_rows:
        rows = max_rows
        cols = max(1, int(round(rows * cols_per_row)))

    cols = max(1, min(max_cols, cols))
    rows = max(1, min(max_rows, rows))
    return cols, rows


def load_image(path: str) -> Image.Image:
    img = Image.open(path).convert("RGBA")
    bg = Image.new("RGBA", img.size, (0, 0, 0, 255))
    return Image.alpha_composite(bg, img).convert("RGB")


def load_and_resize(path: str, sample_w: int, sample_h: int) -> Image.Image:
    img = load_image(path)
    return img.resize((max(1, sample_w), max(1, sample_h)), Image.Resampling.LANCZOS)


def render_braille(img: Image.Image, cols: int, rows: int, dither: float) -> List[List[Cell]]:
    sample_w, sample_h = cols * 2, rows * 4
    if img.size != (sample_w, sample_h):
        img = img.resize((sample_w, sample_h), Image.Resampling.LANCZOS)
    px = img.load()
    w, h = img.size
    grid: List[List[Cell]] = []

    for row in range(rows):
        line: List[Cell] = []
        for col in range(cols):
            samples: List[Tuple[int, int, int, RGB]] = []
            for dx, dy, bit in BRAILLE_MAP:
                x = col * 2 + dx
                y = row * 4 + dy
                samples.append((bit, x, y, get_pixel(px, x, y, w, h)))

            mean_l = sum(luminance(c) for *_, c in samples) / len(samples)
            bits = 0
            on_cols: List[RGB] = []
            off_cols: List[RGB] = []
            for bit, x, y, c in samples:
                thr = mean_l + ordered_bias(x, y, dither)
                if luminance(c) >= thr:
                    bits |= bit
                    on_cols.append(c)
                else:
                    off_cols.append(c)

            all_c = [c for *_, c in samples]
            # Chafa-like: saturated FG on dark BG so colors stay vivid in terminal.
            # Using two mid-tone averages (on/off) often makes FG≈BG → looks monochrome.
            cell_avg = avg_colors(all_c)
            if bits == 0:
                # empty cell: paint bg color via space with matching bg
                line.append((" ", cell_avg, cell_avg))
            else:
                fg = avg_colors(on_cols) if on_cols else cell_avg
                if off_cols:
                    bg = avg_colors(off_cols)
                    # If contrast too low, darken bg so FG color pops
                    if abs(luminance(fg) - luminance(bg)) < 28:
                        bg = (
                            max(0, bg[0] // 3),
                            max(0, bg[1] // 3),
                            max(0, bg[2] // 3),
                        )
                else:
                    bg = (
                        max(0, fg[0] // 4),
                        max(0, fg[1] // 4),
                        max(0, fg[2] // 4),
                    )
                line.append((chr(0x2800 + bits), fg, bg))
        grid.append(line)
    return grid


def best_block_cell(pixels: Sequence[RGB]) -> Cell:
    """Pick best 2x2 quarter-block symbol + fg/bg (chafa block symbols).

    Bit layout matches Unicode quadrant blocks:
      bit0 = upper-left  (▘)
      bit1 = upper-right (▝)
      bit2 = lower-left  (▖)
      bit3 = lower-right (▗)
    Character is drawn with FG on set bits and BG on unset bits.
    """
    best_err = float("inf")
    best: Cell = (" ", avg_colors(pixels), avg_colors(pixels))

    # Exhaustive 16-symbol search (same family chafa uses for --symbols block)
    for mask in range(16):
        on = [pixels[i] for i in range(4) if mask & (1 << i)]
        off = [pixels[i] for i in range(4) if not (mask & (1 << i))]

        if mask == 0:
            bg = avg_colors(pixels)
            fg = bg
            ch = " "
            err = sum(color_dist2(p, bg) for p in pixels)
        elif mask == 0xF:
            fg = avg_colors(pixels)
            bg = fg
            ch = "█"
            err = sum(color_dist2(p, fg) for p in pixels)
        else:
            fg = avg_colors(on)
            bg = avg_colors(off)
            ch = BLOCK_CHARS[mask]
            err = 0.0
            for i, p in enumerate(pixels):
                target = fg if (mask & (1 << i)) else bg
                err += color_dist2(p, target)

        if err < best_err:
            best_err = err
            best = (ch, fg, bg)

    return best


def render_block(img: Image.Image, cols: int, rows: int) -> List[List[Cell]]:
    sample_w, sample_h = cols * 2, rows * 2
    if img.size != (sample_w, sample_h):
        img = img.resize((sample_w, sample_h), Image.Resampling.LANCZOS)
    px = img.load()
    w, h = img.size
    grid: List[List[Cell]] = []
    for row in range(rows):
        line: List[Cell] = []
        for col in range(cols):
            pix = [
                get_pixel(px, col * 2 + 0, row * 2 + 0, w, h),
                get_pixel(px, col * 2 + 1, row * 2 + 0, w, h),
                get_pixel(px, col * 2 + 0, row * 2 + 1, w, h),
                get_pixel(px, col * 2 + 1, row * 2 + 1, w, h),
            ]
            line.append(best_block_cell(pix))
        grid.append(line)
    return grid


def render_half(img: Image.Image, cols: int, rows: int) -> List[List[Cell]]:
    sample_w, sample_h = cols, rows * 2
    if img.size != (sample_w, sample_h):
        img = img.resize((sample_w, sample_h), Image.Resampling.LANCZOS)
    px = img.load()
    w, h = img.size
    grid: List[List[Cell]] = []
    for row in range(rows):
        line: List[Cell] = []
        for col in range(cols):
            top = get_pixel(px, col, row * 2, w, h)
            bot = get_pixel(px, col, row * 2 + 1, w, h)
            line.append(("▀", top, bot))
        grid.append(line)
    return grid


def emit_protocol(grid: List[List[Cell]], mode: str) -> None:
    """Legacy line protocol for buffer backends (kept for debugging)."""
    rows = len(grid)
    cols = len(grid[0]) if rows else 0
    sys.stdout.write(f"META cols={cols} rows={rows} mode={mode}\n")
    for line in grid:
        parts = []
        for ch, fg, bg in line:
            cp = f"{ord(ch):X}"
            parts.append(f"{cp}:{hex_rgb(fg)}:{hex_rgb(bg)}")
        sys.stdout.write(" ".join(parts) + "\n")


def emit_ansi(grid: List[List[Cell]]) -> None:
    """Truecolor ANSI for terminal display (no nvim highlight groups)."""
    reset = "\x1b[0m"
    out = getattr(sys.stdout, "buffer", None)
    chunks: List[str] = []
    for line in grid:
        parts: List[str] = []
        prev_fg = None
        prev_bg = None
        for ch, fg, bg in line:
            if fg != prev_fg or bg != prev_bg:
                parts.append(
                    f"\x1b[38;2;{fg[0]};{fg[1]};{fg[2]}m"
                    f"\x1b[48;2;{bg[0]};{bg[1]};{bg[2]}m"
                )
                prev_fg, prev_bg = fg, bg
            parts.append(ch)
        parts.append(reset)
        parts.append("\n")
        chunks.append("".join(parts))
    chunks.append(reset)
    data = "".join(chunks).encode("utf-8")
    if out is not None:
        out.write(data)
        out.flush()
    else:
        sys.stdout.write(data.decode("utf-8"))
        sys.stdout.flush()


def main() -> int:
    ap = argparse.ArgumentParser(description="Chafa-style image renderer")
    ap.add_argument("path", help="Image path")
    ap.add_argument("--cols", type=int, required=True)
    ap.add_argument("--rows", type=int, required=True)
    ap.add_argument(
        "--mode",
        choices=("block", "braille", "half"),
        default="block",
        help="Render mode (default: block = chafa quarter cells)",
    )
    ap.add_argument(
        "--dither",
        type=float,
        default=0.35,
        help="Ordered dither strength for braille (0=off)",
    )
    ap.add_argument(
        "--format",
        choices=("ansi", "protocol"),
        default="ansi",
        help="Output format (ansi for terminal, protocol for debug)",
    )
    ap.add_argument(
        "--scale",
        choices=("fit", "fill"),
        default="fit",
        help="fit=keep aspect; fill=stretch to cols x rows",
    )
    args = ap.parse_args()

    max_cols = max(1, args.cols)
    max_rows = max(1, args.rows)

    with Image.open(args.path) as probe:
        src_w, src_h = probe.size

    if args.scale == "fill":
        cols, rows = max_cols, max_rows
    else:
        cols, rows = fit_cells(src_w, src_h, max_cols, max_rows)

    if args.mode == "braille":
        cell_w, cell_h = 2, 4
    elif args.mode == "block":
        cell_w, cell_h = 2, 2
    else:
        cell_w, cell_h = 1, 2

    img = load_and_resize(args.path, cols * cell_w, rows * cell_h)

    if args.mode == "braille":
        grid = render_braille(img, cols, rows, args.dither)
    elif args.mode == "block":
        grid = render_block(img, cols, rows)
    else:
        grid = render_half(img, cols, rows)

    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")

    if args.format == "ansi":
        emit_ansi(grid)
    else:
        emit_protocol(grid, args.mode)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
