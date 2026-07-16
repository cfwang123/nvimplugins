# -*- coding: utf-8 -*-
"""为 imgbuf 高清叠层准备 PNG。

用法:
  gfx_prepare.py path cols rows [fit|fill]

fill = 拉伸铺满窗口单元格对应的像素盒
fit  = 等比缩放到盒内并居中（透明/黑边 letterbox）

stdout: 临时 PNG 绝对路径
"""
from __future__ import annotations

import os
import sys
import tempfile


def main() -> int:
    if len(sys.argv) < 4:
        print("usage: gfx_prepare.py path cols rows [fit|fill]", file=sys.stderr)
        return 2
    path = sys.argv[1]
    cols = max(1, int(sys.argv[2]))
    rows = max(1, int(sys.argv[3]))
    scale = (sys.argv[4] if len(sys.argv) > 4 else "fill").lower()
    if scale in ("stretch", "fill"):
        scale = "fill"
    else:
        scale = "fit"

    # 单元格像素近似（终端字符格）
    cell_w, cell_h = 10, 20
    box_w = min(3200, max(1, cols * cell_w))
    box_h = min(2200, max(1, rows * cell_h))

    try:
        from PIL import Image
    except ImportError:
        print("ERROR: Pillow required", file=sys.stderr)
        return 2

    try:
        im = Image.open(path)
        if getattr(im, "is_animated", False):
            im.seek(0)
        im = im.convert("RGBA")
        iw, ih = im.size
        if iw < 1 or ih < 1:
            print("ERROR: empty image", file=sys.stderr)
            return 1

        if scale == "fill":
            # 拉伸铺满整个窗口像素盒（与字符画 fill 一致）
            out_im = im.resize((box_w, box_h), Image.Resampling.LANCZOS)
        else:
            # 等比缩放到盒内并居中；透明边 letterbox
            # 与字符画 pad_center 使用同一 max 盒，叠层才能精确盖住字符画
            # 字体宽高比近似 0.5，与 render.py fit_cells 一致
            font_aspect = 0.5
            cols_per_row = (iw / float(ih)) / font_aspect
            # 先按单元格网格等比（与 render.py 同源逻辑）
            cell_cols = cols
            cell_rows = max(1, int(round(cell_cols / cols_per_row)))
            if cell_rows > rows:
                cell_rows = rows
                cell_cols = max(1, int(round(cell_rows * cols_per_row)))
            cell_cols = max(1, min(cols, cell_cols))
            cell_rows = max(1, min(rows, cell_rows))
            # 像素盒内对应区域
            content_w = max(1, int(round(box_w * cell_cols / float(cols))))
            content_h = max(1, int(round(box_h * cell_rows / float(rows))))
            s = min(content_w / float(iw), content_h / float(ih))
            nw = max(1, int(round(iw * s)))
            nh = max(1, int(round(ih * s)))
            scaled = im.resize((nw, nh), Image.Resampling.LANCZOS)
            out_im = Image.new("RGBA", (box_w, box_h), (0, 0, 0, 0))
            # 与字符画相同：在整窗盒内居中
            ox = (box_w - nw) // 2
            oy = (box_h - nh) // 2
            out_im.paste(scaled, (ox, oy), scaled)

        fd, out = tempfile.mkstemp(prefix="imgbuf_hd_", suffix=".png")
        os.close(fd)
        out_im.save(out, "PNG", optimize=True)
        print(out)
        return 0
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
