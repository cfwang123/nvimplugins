# -*- coding: utf-8 -*-
"""mdview 缩略图：█ 色块 / 2x2 四分块 + 真彩色。

协议 MDVIEW_THUMB2（预览 █ 全格）：
  MDVIEW_THUMB2
  <w> <h>
  <rrggbb> ...

协议 MDVIEW_BLOCK2（float 四分块：1 / 1/2 / 1/4 / 3/4）：
  MDVIEW_BLOCK2
  <w> <h>
  <codepoint_hex>:<fg_rrggbb>:<bg_rrggbb> ...

宽固定 full_w；高度按「像素比例 × 终端字符宽高比」自适应，
避免把字符格当成正方形导致图像被纵向拉长。

cell_aspect = 单元格像素宽/高，常见终端约 0.5（字比画布竖长）。
"""
from __future__ import annotations

import sys
from typing import List, Sequence, Tuple

RGB = Tuple[int, int, int]
Cell = Tuple[str, RGB, RGB]

# 2x2 象限 → 块字符（bit0=UL bit1=UR bit2=LL bit3=LR）
# 覆盖率：空 0、1/4、1/2、3/4、满 1
BLOCK_CHARS = (
    " ",  # 0
    "▘",  # 1 UL
    "▝",  # 2 UR
    "▀",  # 3 upper half
    "▖",  # 4 LL
    "▌",  # 5 left half
    "▞",  # 6
    "▛",  # 7 3/4
    "▗",  # 8 LR
    "▚",  # 9
    "▐",  # 10 right half
    "▜",  # 11 3/4
    "▄",  # 12 lower half
    "▙",  # 13 3/4
    "▟",  # 14 3/4
    "█",  # 15 full
)


def size_width_full(iw: int, ih: int, full_w: int, max_h=None, cell_aspect: float = 0.5):
    """宽 = full_w 列；高按视觉比例。"""
    full_w = max(1, full_w)
    iw = max(1, iw)
    ih = max(1, ih)
    if cell_aspect <= 0:
        cell_aspect = 0.5
    w = full_w
    h = max(1, int(round(float(full_w) * ih / iw * cell_aspect)))
    if max_h is not None and max_h > 0 and h > max_h:
        h = max_h
    return w, h


def quantize6(v: int) -> int:
    step = 8
    return min(255, (v // step) * step + step // 2)


def quantize_rgb(c: RGB) -> RGB:
    return (quantize6(c[0]), quantize6(c[1]), quantize6(c[2]))


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
    r, g, b = quantize_rgb(c)
    return f"{r:02x}{g:02x}{b:02x}"


def get_pixel(px, x: int, y: int, w: int, h: int) -> RGB:
    x = max(0, min(w - 1, x))
    y = max(0, min(h - 1, y))
    p = px[x, y]
    if len(p) >= 3:
        return (int(p[0]), int(p[1]), int(p[2]))
    v = int(p[0])
    return (v, v, v)


def best_block_cell(pixels: Sequence[RGB]) -> Cell:
    """2x2 四分块：选最优 mask + fg/bg（chafa block 风格）。"""
    best_err = float("inf")
    best: Cell = (" ", avg_colors(pixels), avg_colors(pixels))

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


def render_block_cells(Image, im, w: int, h: int) -> List[List[Cell]]:
    """按 w×h 字符格渲染；每格采样 2×2 像素。"""
    sample_w, sample_h = w * 2, h * 2
    if im.size != (sample_w, sample_h):
        im = im.resize((sample_w, sample_h), Image.Resampling.LANCZOS)
    px = im.load()
    sw, sh = im.size
    grid: List[List[Cell]] = []
    for row in range(h):
        line: List[Cell] = []
        for col in range(w):
            pix = [
                get_pixel(px, col * 2 + 0, row * 2 + 0, sw, sh),
                get_pixel(px, col * 2 + 1, row * 2 + 0, sw, sh),
                get_pixel(px, col * 2 + 0, row * 2 + 1, sw, sh),
                get_pixel(px, col * 2 + 1, row * 2 + 1, sw, sh),
            ]
            line.append(best_block_cell(pix))
        grid.append(line)
    return grid


def emit_thumb2(Image, im, w: int, h: int) -> None:
    im = im.resize((w, h), Image.Resampling.BOX)
    px = im.load()
    out = ["MDVIEW_THUMB2", f"{w} {h}"]
    for y in range(h):
        cells = []
        for x in range(w):
            r, g, b = px[x, y]
            r, g, b = quantize6(r), quantize6(g), quantize6(b)
            cells.append(f"{r:02x}{g:02x}{b:02x}")
        out.append(" ".join(cells))
    sys.stdout.write("\n".join(out) + "\n")


def emit_block2(grid: List[List[Cell]]) -> None:
    h = len(grid)
    w = len(grid[0]) if h else 0
    out = ["MDVIEW_BLOCK2", f"{w} {h}"]
    for row in grid:
        parts = []
        for ch, fg, bg in row:
            parts.append(f"{ord(ch):X}:{hex_rgb(fg)}:{hex_rgb(bg)}")
        out.append(" ".join(parts))
    sys.stdout.write("\n".join(out) + "\n")


def main() -> int:
    if len(sys.argv) < 4:
        print(
            "usage: thumb.py path width max_height [mode] [cell_aspect] [glyph]",
            file=sys.stderr,
        )
        return 2
    path = sys.argv[1]
    full_w = max(1, int(sys.argv[2]))
    max_h_arg = int(sys.argv[3])
    max_h = max_h_arg if max_h_arg > 0 else None
    mode = "width_full"
    cell_aspect = 0.5
    # glyph: full=█ 全格（默认）；block=2x2 四分块（float）
    glyph = "full"

    for a in sys.argv[4:]:
        if a in ("width_full", "fit", "stretch"):
            mode = a
        elif a in ("full", "block", "quarter"):
            glyph = "block" if a in ("block", "quarter") else "full"
        else:
            try:
                v = float(a)
                if v > 4:  # 旧 palette_size 忽略
                    pass
                elif v > 0:
                    cell_aspect = v
            except ValueError:
                pass

    try:
        from PIL import Image
    except ImportError:
        print("[no Pillow]", file=sys.stderr)
        return 1

    try:
        im = Image.open(path).convert("RGB")
    except Exception as e:
        print(f"[err] {e}", file=sys.stderr)
        return 1

    iw, ih = im.size
    if mode == "stretch":
        w, h = full_w, max(1, max_h or max(1, int(full_w * cell_aspect)))
    elif mode == "fit":
        box_h = max_h if max_h is not None else max(1, int(full_w * ih / iw * cell_aspect))
        ratio = (ih / iw) * cell_aspect
        w = full_w
        h = max(1, int(round(w * ratio)))
        if h > box_h:
            h = box_h
            w = max(1, int(round(h / ratio))) if ratio > 0 else full_w
            w = min(w, full_w)
    else:
        w, h = size_width_full(iw, ih, full_w, max_h, cell_aspect)

    if glyph == "block":
        grid = render_block_cells(Image, im, w, h)
        emit_block2(grid)
    else:
        emit_thumb2(Image, im, w, h)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
