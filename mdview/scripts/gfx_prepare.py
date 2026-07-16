# -*- coding: utf-8 -*-
"""为 mdview 高清叠层准备 PNG。

用法:
  gfx_prepare.py path cols rows [fit|fill] [layout_rows] [skip_rows]

fill = 拉伸铺满单元格像素盒
fit  = 等比缩放到盒内并居中（透明边 letterbox）

layout_rows / skip_rows（可选）:
  先按 cols×layout_rows 完整布局，再从 skip_rows 行起裁 rows 行
  （不整体缩放进更矮区域）。
  - 底部不够：skip=0，取顶部 rows 行
  - 顶部滚出：skip>0，取可见的下半部分

stdout: 临时 PNG 绝对路径
"""
from __future__ import annotations

import os
import sys
import tempfile


def main() -> int:
    if len(sys.argv) < 4:
        print(
            "usage: gfx_prepare.py path cols rows [fit|fill] [layout_rows] [skip_rows]",
            file=sys.stderr,
        )
        return 2
    path = sys.argv[1]
    cols = max(1, int(sys.argv[2]))
    rows = max(1, int(sys.argv[3]))
    scale = (sys.argv[4] if len(sys.argv) > 4 else "fill").lower()
    if scale in ("stretch", "fill"):
        scale = "fill"
    else:
        scale = "fit"

    layout_rows = rows
    skip_rows = 0
    if len(sys.argv) > 5:
        try:
            layout_rows = max(1, int(sys.argv[5]))
        except ValueError:
            layout_rows = rows
    if len(sys.argv) > 6:
        try:
            skip_rows = max(0, int(sys.argv[6]))
        except ValueError:
            skip_rows = 0

    if layout_rows < rows + skip_rows:
        layout_rows = rows + skip_rows
    if skip_rows + rows > layout_rows:
        skip_rows = max(0, layout_rows - rows)

    cell_w, cell_h = 10, 20
    box_w = min(3200, max(1, cols * cell_w))
    box_h = min(2200, max(1, layout_rows * cell_h))
    crop_y = min(box_h, skip_rows * cell_h)
    crop_h = min(box_h - crop_y, max(1, rows * cell_h))

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
            out_im = im.resize((box_w, box_h), Image.Resampling.LANCZOS)
        else:
            font_aspect = 0.5
            cols_per_row = (iw / float(ih)) / font_aspect
            cell_cols = cols
            cell_rows = max(1, int(round(cell_cols / cols_per_row)))
            if cell_rows > layout_rows:
                cell_rows = layout_rows
                cell_cols = max(1, int(round(cell_rows * cols_per_row)))
            cell_cols = max(1, min(cols, cell_cols))
            cell_rows = max(1, min(layout_rows, cell_rows))
            content_w = max(1, int(round(box_w * cell_cols / float(cols))))
            content_h = max(1, int(round(box_h * cell_rows / float(layout_rows))))
            s = min(content_w / float(iw), content_h / float(ih))
            nw = max(1, int(round(iw * s)))
            nh = max(1, int(round(ih * s)))
            scaled = im.resize((nw, nh), Image.Resampling.LANCZOS)
            out_im = Image.new("RGBA", (box_w, box_h), (0, 0, 0, 0))
            ox = (box_w - nw) // 2
            oy = (box_h - nh) // 2
            out_im.paste(scaled, (ox, oy), scaled)

        # 按行裁切：取 [skip_rows, skip_rows+rows) 对应像素带
        if crop_y > 0 or crop_h < box_h:
            out_im = out_im.crop((0, crop_y, box_w, crop_y + crop_h))

        fd, out = tempfile.mkstemp(prefix="mdview_hd_", suffix=".png")
        os.close(fd)
        out_im.save(out, "PNG", optimize=True)
        print(out)
        return 0
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
