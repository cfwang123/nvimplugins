# -*- coding: utf-8 -*-
"""mdview 缩略图：█ 色块 + 真彩色。

协议 MDVIEW_THUMB2（stdout, UTF-8）：
  MDVIEW_THUMB2
  <w> <h>
  <rrggbb> ...

宽固定 full_w；高度按「像素比例 × 终端字符宽高比」自适应，
避免把字符格当成正方形导致图像被纵向拉长。

cell_aspect = 单元格像素宽/高，常见终端约 0.5（字比画布竖长）。
"""
from __future__ import annotations

import sys


def size_width_full(iw: int, ih: int, full_w: int, max_h=None, cell_aspect: float = 0.5):
    """宽 = full_w 列；高按视觉比例。

    像素比例 iw:ih 映射到字符网格时：
      visual_w / visual_h = (w * cell_w) / (h * cell_h) = (w/h) * cell_aspect
      要 visual_w/visual_h = iw/ih
      => h/w = (ih/iw) * cell_aspect
      => h = w * ih/iw * cell_aspect
    """
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


def main() -> int:
    if len(sys.argv) < 4:
        print(
            "usage: thumb.py path width max_height [mode] [cell_aspect]",
            file=sys.stderr,
        )
        return 2
    path = sys.argv[1]
    full_w = max(1, int(sys.argv[2]))
    max_h_arg = int(sys.argv[3])
    max_h = max_h_arg if max_h_arg > 0 else None
    mode = "width_full"
    cell_aspect = 0.5

    # 兼容：argv[4] 可能是 palette 数字 / mode / cell_aspect
    # argv[5] 可能是 mode / cell_aspect
    # argv[6] 可能是 cell_aspect
    for a in sys.argv[4:]:
        if a in ("width_full", "fit", "stretch"):
            mode = a
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
        # 在 full_w x box_h 内等比（已含 cell_aspect）
        # 目标：w<=full_w, h<=box_h, h/w = ih/iw*cell_aspect
        ratio = (ih / iw) * cell_aspect
        w = full_w
        h = max(1, int(round(w * ratio)))
        if h > box_h:
            h = box_h
            w = max(1, int(round(h / ratio))) if ratio > 0 else full_w
            w = min(w, full_w)
    else:
        w, h = size_width_full(iw, ih, full_w, max_h, cell_aspect)

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
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
