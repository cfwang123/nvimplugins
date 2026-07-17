# -*- coding: utf-8 -*-
"""PDF → 结构化 JSON（供 pdfview.nvim 渲染）。

依赖: PyMuPDF (fitz)

用法:
  python -X utf8 extract.py <pdf_path> <out_json> [img_dir] [max_pages]

stdout 最后一行: OK <page_count> 或 ERROR <msg>
"""
from __future__ import annotations

import json
import os
import sys
import hashlib
from typing import Any, Dict, List, Optional, Tuple

try:
    import fitz  # PyMuPDF
except ImportError:
    print("ERROR: PyMuPDF required (pip install pymupdf)", file=sys.stderr)
    sys.exit(2)


def color_to_hex(c: int) -> str:
    """PyMuPDF span color 为 sRGB int。"""
    if c is None:
        return "#000000"
    r = (c >> 16) & 0xFF
    g = (c >> 8) & 0xFF
    b = c & 0xFF
    return f"#{r:02x}{g:02x}{b:02x}"


def flags_style(flags: int) -> Tuple[bool, bool, bool]:
    """返回 (bold, italic, mono)。

    PyMuPDF TextPage flags:
      bit0 superscript, bit1 italic, bit2 serifed,
      bit3 monospaced, bit4 bold
    """
    flags = int(flags or 0)
    italic = bool(flags & 2)
    mono = bool(flags & 8)
    bold = bool(flags & 16)
    return bold, italic, mono


def font_name_style(font: str) -> Tuple[bool, bool]:
    """从字体名推断 bold/italic（flags 有时不准）。"""
    f = (font or "").lower().replace(" ", "").replace("-", "")
    bold = any(
        k in f
        for k in (
            "bold",
            "black",
            "heavy",
            "semibold",
            "demi",
            "hebo",  # Helvetica-Bold 简写
            "boldmt",
        )
    ) or f.endswith("bd") or (f.endswith("b") and len(f) <= 6)
    italic = any(
        k in f
        for k in (
            "italic",
            "oblique",
            "heit",  # Helvetica-Oblique 简写
            "ital",
            "slant",
            "obli",
        )
    ) or (f.endswith("i") and len(f) <= 6 and "bi" not in f)
    # 常见组合 bi / bolditalic
    if "bolditalic" in f or "boldoblique" in f or f.endswith("bi") or "hebi" in f:
        bold, italic = True, True
    return bold, italic


def rect_overlap(a: Tuple[float, float, float, float], b: Tuple[float, float, float, float]) -> float:
    """IoU-ish：交集面积 / 较小矩形面积。"""
    ax0, ay0, ax1, ay1 = a
    bx0, by0, bx1, by1 = b
    ix0, iy0 = max(ax0, bx0), max(ay0, by0)
    ix1, iy1 = min(ax1, bx1), min(ay1, by1)
    if ix1 <= ix0 or iy1 <= iy0:
        return 0.0
    inter = (ix1 - ix0) * (iy1 - iy0)
    area_a = max(1e-6, (ax1 - ax0) * (ay1 - ay0))
    area_b = max(1e-6, (bx1 - bx0) * (by1 - by0))
    return inter / min(area_a, area_b)


def inside_any(rect: Tuple[float, float, float, float], zones: List[Tuple[float, float, float, float]], thr: float = 0.5) -> bool:
    for z in zones:
        if rect_overlap(rect, z) >= thr:
            return True
    return False


def ensure_dir(p: str) -> None:
    os.makedirs(p, exist_ok=True)


def save_image(doc: "fitz.Document", xref: int, img_dir: str, page_i: int, idx: int) -> Optional[str]:
    try:
        base = doc.extract_image(xref)
    except Exception:
        return None
    if not base or not base.get("image"):
        return None
    ext = (base.get("ext") or "png").lower()
    if ext == "jpeg":
        ext = "jpg"
    name = f"p{page_i + 1}_img{idx + 1}.{ext}"
    path = os.path.join(img_dir, name)
    try:
        with open(path, "wb") as f:
            f.write(base["image"])
        return path
    except OSError:
        return None


def extract_tables(page: "fitz.Page") -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    try:
        finder = page.find_tables()
    except Exception:
        return out
    tables = getattr(finder, "tables", None) or []
    for t in tables:
        try:
            rows = t.extract() or []
        except Exception:
            rows = []
        # 清洗 None
        clean = []
        for row in rows:
            clean.append([("" if c is None else str(c).replace("\n", " ").strip()) for c in (row or [])])
        if not clean:
            continue
        bbox = getattr(t, "bbox", None)
        if bbox is None:
            continue
        out.append(
            {
                "type": "table",
                "bbox": [float(bbox[0]), float(bbox[1]), float(bbox[2]), float(bbox[3])],
                "rows": clean,
                "header": True,  # 默认首行作表头
            }
        )
    return out


def extract_images(doc: "fitz.Document", page: "fitz.Page", page_i: int, img_dir: str, table_zones: List) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    seen = set()
    try:
        images = page.get_images(full=True)
    except Exception:
        return out
    idx = 0
    for info in images:
        xref = info[0]
        try:
            rects = page.get_image_rects(xref)
        except Exception:
            rects = []
        if not rects:
            # 仍尝试导出一次
            path = save_image(doc, xref, img_dir, page_i, idx)
            if path:
                out.append(
                    {
                        "type": "image",
                        "bbox": [0.0, 0.0, 100.0, 100.0],
                        "path": path,
                        "width": 0,
                        "height": 0,
                    }
                )
                idx += 1
            continue
        for rect in rects:
            bb = (float(rect.x0), float(rect.y0), float(rect.x1), float(rect.y1))
            key = (xref, round(bb[0], 1), round(bb[1], 1))
            if key in seen:
                continue
            seen.add(key)
            if inside_any(bb, table_zones, 0.6):
                continue
            w = max(0.0, bb[2] - bb[0])
            h = max(0.0, bb[3] - bb[1])
            # 过小装饰图跳过
            if w < 12 or h < 12:
                continue
            path = save_image(doc, xref, img_dir, page_i, idx)
            if not path:
                continue
            out.append(
                {
                    "type": "image",
                    "bbox": list(bb),
                    "path": path,
                    "width": int(w),
                    "height": int(h),
                }
            )
            idx += 1
    return out


def line_to_spans(line: Dict[str, Any]) -> List[Dict[str, Any]]:
    spans_out: List[Dict[str, Any]] = []
    for sp in line.get("spans") or []:
        text = sp.get("text") or ""
        if text == "":
            continue
        flags = int(sp.get("flags") or 0)
        bold, italic, mono = flags_style(flags)
        fb, fi = font_name_style(sp.get("font") or "")
        bold = bold or fb
        italic = italic or fi
        size = float(sp.get("size") or 0)
        color = color_to_hex(int(sp.get("color") or 0))
        origin = sp.get("origin") or sp.get("bbox") or [0, 0]
        x0 = float(origin[0]) if origin is not None else 0.0
        # span bbox 更稳
        sbb = sp.get("bbox")
        if sbb is not None and len(sbb) >= 1:
            x0 = float(sbb[0])
        spans_out.append(
            {
                "text": text,
                "bold": bold,
                "italic": italic,
                "mono": mono,
                "size": size,
                "color": color,
                "font": sp.get("font") or "",
                "x0": x0,
            }
        )
    return spans_out


def _line_y_center(ln: Dict[str, Any]) -> float:
    bb = ln.get("bbox") or [0, 0, 0, 0]
    return (float(bb[1]) + float(bb[3])) / 2.0


def _line_height(ln: Dict[str, Any]) -> float:
    bb = ln.get("bbox") or [0, 0, 0, 0]
    return max(1.0, float(bb[3]) - float(bb[1]))


def merge_same_baseline_lines(lines: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """PyMuPDF 常把同一视觉行（彩色/粗体分片、x 不连续）拆成多条 line。

    按 y 中心合并为同一逻辑行，span 按 x0 排序拼接。
    """
    if not lines:
        return lines
    # 先按 y 再按 x 排序，保证合并顺序稳定
    ordered = sorted(
        lines,
        key=lambda ln: (_line_y_center(ln), float((ln.get("bbox") or [0])[0])),
    )
    merged: List[Dict[str, Any]] = []
    for ln in ordered:
        if not merged:
            merged.append(
                {
                    "spans": list(ln.get("spans") or []),
                    "bbox": list(ln.get("bbox") or [0, 0, 0, 0]),
                }
            )
            continue
        prev = merged[-1]
        yc = _line_y_center(ln)
        pyc = _line_y_center(prev)
        thr = max(2.0, min(_line_height(ln), _line_height(prev)) * 0.45)
        if abs(yc - pyc) <= thr:
            # 合并 spans；若接缝两侧都无空白且 x 有明显间隙，补一个空格
            prev_spans = prev.get("spans") or []
            next_spans = list(ln.get("spans") or [])
            if prev_spans and next_spans:
                left = prev_spans[-1].get("text") or ""
                right = next_spans[0].get("text") or ""
                gap = float((ln.get("bbox") or [0])[0]) - float((prev.get("bbox") or [0, 0, 0])[2])
                if (
                    gap > 1.5
                    and left
                    and right
                    and not left[-1].isspace()
                    and not right[0].isspace()
                ):
                    # 在右侧 span 前插空格，保留样式用左侧默认
                    next_spans[0] = dict(next_spans[0])
                    next_spans[0]["text"] = " " + right
            combined = prev_spans + next_spans
            combined.sort(key=lambda s: float(s.get("x0") or 0))
            prev["spans"] = combined
            pbb = prev["bbox"]
            lbb = ln.get("bbox") or pbb
            prev["bbox"] = [
                min(float(pbb[0]), float(lbb[0])),
                min(float(pbb[1]), float(lbb[1])),
                max(float(pbb[2]), float(lbb[2])),
                max(float(pbb[3]), float(lbb[3])),
            ]
        else:
            merged.append(
                {
                    "spans": list(ln.get("spans") or []),
                    "bbox": list(ln.get("bbox") or [0, 0, 0, 0]),
                }
            )
    return merged


def extract_text_blocks(page: "fitz.Page", table_zones: List, image_zones: List) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    try:
        data = page.get_text("dict", flags=fitz.TEXT_PRESERVE_WHITESPACE)
    except Exception:
        data = page.get_text("dict")
    for block in data.get("blocks") or []:
        if block.get("type") != 0:
            continue
        bb = (
            float(block.get("bbox", [0, 0, 0, 0])[0]),
            float(block.get("bbox", [0, 0, 0, 0])[1]),
            float(block.get("bbox", [0, 0, 0, 0])[2]),
            float(block.get("bbox", [0, 0, 0, 0])[3]),
        )
        if inside_any(bb, table_zones, 0.55):
            continue
        # 完全落在大图上的 OCR/标签文本保留；与图重叠过高且几乎空则跳过
        lines_out: List[Dict[str, Any]] = []
        for line in block.get("lines") or []:
            spans = line_to_spans(line)
            if not spans:
                continue
            lbb = line.get("bbox") or block.get("bbox")
            lines_out.append(
                {
                    "spans": spans,
                    "bbox": [float(lbb[0]), float(lbb[1]), float(lbb[2]), float(lbb[3])],
                }
            )
        if not lines_out:
            continue
        # 同一基线（同视觉行）合并，避免「colored / italic」被拆成多行
        lines_out = merge_same_baseline_lines(lines_out)
        # 估计字号（用于标题判断）
        sizes = []
        for ln in lines_out:
            for sp in ln["spans"]:
                if sp["size"] > 0:
                    sizes.append(sp["size"])
        avg_size = sum(sizes) / len(sizes) if sizes else 11.0
        out.append(
            {
                "type": "text",
                "bbox": list(bb),
                "lines": lines_out,
                "avg_size": avg_size,
            }
        )
    return out


def sort_key(item: Dict[str, Any]) -> Tuple[float, float]:
    bb = item.get("bbox") or [0, 0, 0, 0]
    return (float(bb[1]), float(bb[0]))


def extract_page(doc: "fitz.Document", page_i: int, img_dir: str) -> Dict[str, Any]:
    page = doc[page_i]
    rect = page.rect
    tables = extract_tables(page)
    table_zones = [tuple(t["bbox"]) for t in tables]  # type: ignore
    images = extract_images(doc, page, page_i, img_dir, table_zones)
    image_zones = [tuple(im["bbox"]) for im in images]  # type: ignore
    texts = extract_text_blocks(page, table_zones, image_zones)

    blocks = tables + images + texts
    blocks.sort(key=sort_key)

    return {
        "page": page_i + 1,
        "width": float(rect.width),
        "height": float(rect.height),
        "blocks": blocks,
    }


def meta_of(doc: "fitz.Document") -> Dict[str, Any]:
    m = doc.metadata or {}
    return {
        "title": m.get("title") or "",
        "author": m.get("author") or "",
        "subject": m.get("subject") or "",
        "creator": m.get("creator") or "",
        "page_count": doc.page_count,
    }


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: extract.py <pdf> <out_json> [img_dir] [max_pages]", file=sys.stderr)
        return 2
    pdf = os.path.abspath(sys.argv[1])
    out_json = os.path.abspath(sys.argv[2])
    img_dir = os.path.abspath(sys.argv[3]) if len(sys.argv) > 3 else os.path.join(os.path.dirname(out_json), "images")
    max_pages = int(sys.argv[4]) if len(sys.argv) > 4 else 0

    if not os.path.isfile(pdf):
        print(f"ERROR: file not found: {pdf}", file=sys.stderr)
        return 1

    ensure_dir(os.path.dirname(out_json) or ".")
    ensure_dir(img_dir)

    try:
        doc = fitz.open(pdf)
    except Exception as e:
        print(f"ERROR: open failed: {e}", file=sys.stderr)
        return 1

    try:
        n = doc.page_count
        limit = n if max_pages <= 0 else min(n, max_pages)
        pages = []
        for i in range(limit):
            pages.append(extract_page(doc, i, img_dir))
        # 缓存指纹
        try:
            st = os.stat(pdf)
            mtime = int(st.st_mtime)
            size = int(st.st_size)
        except OSError:
            mtime, size = 0, 0
        payload = {
            "version": 1,
            "path": pdf,
            "mtime": mtime,
            "size": size,
            "meta": meta_of(doc),
            "pages": pages,
            "page_count": n,
            "extracted_pages": limit,
        }
        with open(out_json, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False)
        print(f"OK {n}")
        return 0
    except Exception as e:
        print(f"ERROR: extract failed: {e}", file=sys.stderr)
        return 1
    finally:
        doc.close()


if __name__ == "__main__":
    sys.exit(main())
