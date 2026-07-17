# -*- coding: utf-8 -*-
"""DOCX → 与 extract.py 相同结构的 JSON（纯标准库，无需 python-docx）。

用法:
  python -X utf8 extract_docx.py <docx_path> <out_json> [img_dir]

stdout: OK <1> 或 ERROR <msg>
"""
from __future__ import annotations

import json
import os
import re
import shutil
import sys
import zipfile
import xml.etree.ElementTree as ET
from typing import Any, Dict, List, Optional, Tuple

W_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
R_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
A_NS = "http://schemas.openxmlformats.org/drawingml/2006/main"
REL_NS = "http://schemas.openxmlformats.org/package/2006/relationships"
WP_NS = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"

NS = {
    "w": W_NS,
    "r": R_NS,
    "a": A_NS,
    "pr": REL_NS,
    "wp": WP_NS,
}


def qn(tag: str) -> str:
    """w:t → {ns}t"""
    if ":" not in tag:
        return tag
    p, n = tag.split(":", 1)
    return "{%s}%s" % (NS.get(p, p), n)


def local(tag: str) -> str:
    if tag.startswith("{"):
        return tag.rsplit("}", 1)[-1]
    if ":" in tag:
        return tag.split(":", 1)[-1]
    return tag


def ensure_dir(p: str) -> None:
    os.makedirs(p, exist_ok=True)


def theme_color_hex(val: str) -> str:
    """粗略主题色 → hex。"""
    m = {
        "dark1": "#000000",
        "light1": "#ffffff",
        "dark2": "#1f1f1f",
        "light2": "#eeeeee",
        "accent1": "#4472c4",
        "accent2": "#ed7d31",
        "accent3": "#a5a5a5",
        "accent4": "#ffc000",
        "accent5": "#5b9bd5",
        "accent6": "#70ad47",
        "hyperlink": "#0563c1",
        "followedHyperlink": "#954f72",
    }
    return m.get((val or "").lower(), "#000000")


def run_style(rPr: Optional[ET.Element]) -> Tuple[bool, bool, bool, str, float]:
    """返回 bold, italic, mono, color_hex, size_pt"""
    bold = italic = mono = False
    color = "#000000"
    size = 11.0
    if rPr is None:
        return bold, italic, mono, color, size
    for child in rPr:
        name = local(child.tag)
        if name == "b":
            # w:b w:val="0" 表示关
            val = child.get(qn("w:val"))
            if val is None or val not in ("0", "false", "off"):
                bold = True
        elif name == "i":
            val = child.get(qn("w:val"))
            if val is None or val not in ("0", "false", "off"):
                italic = True
        elif name == "rFonts":
            ascii_f = child.get(qn("w:ascii")) or child.get(qn("w:hAnsi")) or ""
            fl = ascii_f.lower()
            if any(k in fl for k in ("consolas", "courier", "mono", "menlo", "cascadia")):
                mono = True
        elif name == "color":
            val = child.get(qn("w:val"))
            theme = child.get(qn("w:themeColor"))
            if val and val.lower() != "auto":
                v = val.lstrip("#")
                if re.fullmatch(r"[0-9A-Fa-f]{6}", v):
                    color = "#" + v.lower()
            elif theme:
                color = theme_color_hex(theme)
        elif name == "sz":
            # half-points
            try:
                size = float(child.get(qn("w:val") or "22")) / 2.0
            except (TypeError, ValueError):
                pass
        elif name == "szCs":
            try:
                size = float(child.get(qn("w:val") or "22")) / 2.0
            except (TypeError, ValueError):
                pass
    return bold, italic, mono, color, size


def text_of_run(r: ET.Element) -> str:
    parts = []
    for t in r.iter():
        if local(t.tag) == "t" and t.text:
            parts.append(t.text)
        elif local(t.tag) == "tab":
            parts.append("\t")
        elif local(t.tag) in ("br", "cr"):
            parts.append("\n")
    return "".join(parts)


def extract_drawing_rids(el: ET.Element) -> List[str]:
    rids = []
    for node in el.iter():
        # a:blip r:embed
        if local(node.tag) == "blip":
            rid = node.get(qn("r:embed")) or node.get(
                "{%s}embed" % R_NS
            )
            if rid:
                rids.append(rid)
    return rids


def parse_relationships(zf: zipfile.ZipFile) -> Dict[str, str]:
    """rId → target path inside zip (word/...)"""
    rels: Dict[str, str] = {}
    name = "word/_rels/document.xml.rels"
    if name not in zf.namelist():
        return rels
    root = ET.fromstring(zf.read(name))
    for rel in root:
        if local(rel.tag) != "Relationship":
            continue
        rid = rel.get("Id")
        target = rel.get("Target")
        if not rid or not target:
            continue
        # Target 可能是 ../media/x 或 media/x
        target = target.replace("\\", "/")
        if target.startswith("/"):
            path = target.lstrip("/")
        elif target.startswith("../"):
            path = "word/" + target  # word/../media → 规范化
            path = os.path.normpath(path).replace("\\", "/")
        else:
            path = "word/" + target
        rels[rid] = path
    return rels


def export_image(zf: zipfile.ZipFile, zip_path: str, img_dir: str, idx: int) -> Optional[str]:
    if zip_path not in zf.namelist():
        # 再试 media 下
        base = os.path.basename(zip_path)
        alt = "word/media/" + base
        if alt in zf.namelist():
            zip_path = alt
        else:
            return None
    ext = os.path.splitext(zip_path)[1].lower().lstrip(".") or "png"
    if ext == "jpeg":
        ext = "jpg"
    out = os.path.join(img_dir, f"docx_img{idx}.{ext}")
    try:
        with zf.open(zip_path) as src, open(out, "wb") as dst:
            shutil.copyfileobj(src, dst)
        return out
    except OSError:
        return None


def paragraph_blocks(p: ET.Element, rels: Dict[str, str], zf: zipfile.ZipFile, img_dir: str, img_counter: List[int]) -> List[Dict[str, Any]]:
    """一个段落可能产出 text + 内嵌图。"""
    blocks: List[Dict[str, Any]] = []
    spans: List[Dict[str, Any]] = []
    # 段落级样式（标题）
    p_style = ""
    pPr = None
    for c in p:
        if local(c.tag) == "pPr":
            pPr = c
            break
    if pPr is not None:
        for c in pPr:
            if local(c.tag) == "pStyle":
                p_style = (c.get(qn("w:val")) or "").lower()

    heading_size = 0.0
    heading_bold = False
    if p_style.startswith("heading") or p_style.startswith("标题"):
        heading_bold = True
        m = re.search(r"(\d+)", p_style)
        level = int(m.group(1)) if m else 1
        heading_size = max(12.0, 22.0 - (level - 1) * 2)

    def flush_text():
        nonlocal spans
        if not spans:
            return
        # 合并同一样式相邻 span
        text = "".join(s["text"] for s in spans)
        if text.strip() == "" and text == "":
            spans = []
            return
        blocks.append(
            {
                "type": "text",
                "bbox": [0, 0, 0, 0],
                "avg_size": spans[0].get("size") or 11.0,
                "lines": [{"spans": spans, "bbox": [0, 0, 0, 0]}],
            }
        )
        spans = []

    for child in p:
        tag = local(child.tag)
        if tag == "r":
            # 图片可能在 run 的 drawing 里
            rids = extract_drawing_rids(child)
            if rids:
                flush_text()
                for rid in rids:
                    zp = rels.get(rid)
                    if not zp:
                        continue
                    img_counter[0] += 1
                    path = export_image(zf, zp, img_dir, img_counter[0])
                    if path:
                        blocks.append(
                            {
                                "type": "image",
                                "bbox": [0, 0, 200, 150],
                                "path": path,
                                "width": 200,
                                "height": 150,
                            }
                        )
            text = text_of_run(child)
            if not text:
                continue
            rPr = None
            for c in child:
                if local(c.tag) == "rPr":
                    rPr = c
                    break
            bold, italic, mono, color, size = run_style(rPr)
            if heading_bold:
                bold = True
            if heading_size > 0:
                size = heading_size
            # 按换行切
            parts = text.split("\n")
            for i, part in enumerate(parts):
                if part:
                    spans.append(
                        {
                            "text": part,
                            "bold": bold,
                            "italic": italic,
                            "mono": mono,
                            "size": size,
                            "color": color,
                            "font": "",
                        }
                    )
                if i < len(parts) - 1:
                    flush_text()
        elif tag == "hyperlink":
            # 递归 runs
            for r in child:
                if local(r.tag) != "r":
                    continue
                text = text_of_run(r)
                if not text:
                    continue
                rPr = None
                for c in r:
                    if local(c.tag) == "rPr":
                        rPr = c
                        break
                bold, italic, mono, color, size = run_style(rPr)
                if color == "#000000":
                    color = "#0563c1"
                spans.append(
                    {
                        "text": text,
                        "bold": bold,
                        "italic": italic,
                        "mono": mono,
                        "size": size,
                        "color": color,
                        "font": "",
                    }
                )
    flush_text()
    return blocks


def table_block(tbl: ET.Element) -> Dict[str, Any]:
    rows: List[List[str]] = []
    for tr in tbl:
        if local(tr.tag) != "tr":
            continue
        row: List[str] = []
        for tc in tr:
            if local(tc.tag) != "tc":
                continue
            texts = []
            for t in tc.iter():
                if local(t.tag) == "t" and t.text:
                    texts.append(t.text)
            row.append("".join(texts).replace("\n", " ").strip())
        if row:
            rows.append(row)
    return {
        "type": "table",
        "bbox": [0, 0, 0, 0],
        "rows": rows,
        "header": True,
    }


def read_core_props(zf: zipfile.ZipFile) -> Dict[str, str]:
    meta = {"title": "", "author": "", "subject": ""}
    name = "docProps/core.xml"
    if name not in zf.namelist():
        return meta
    try:
        root = ET.fromstring(zf.read(name))
    except ET.ParseError:
        return meta
    for el in root.iter():
        ln = local(el.tag)
        if ln == "title" and el.text:
            meta["title"] = el.text
        elif ln == "creator" and el.text:
            meta["author"] = el.text
        elif ln == "subject" and el.text:
            meta["subject"] = el.text
    return meta


def extract_docx(path: str, out_json: str, img_dir: str) -> int:
    ensure_dir(os.path.dirname(out_json) or ".")
    ensure_dir(img_dir)
    try:
        zf = zipfile.ZipFile(path, "r")
    except zipfile.BadZipFile as e:
        print(f"ERROR: not a valid docx (zip): {e}", file=sys.stderr)
        return 1

    with zf:
        if "word/document.xml" not in zf.namelist():
            print("ERROR: missing word/document.xml", file=sys.stderr)
            return 1
        rels = parse_relationships(zf)
        root = ET.fromstring(zf.read("word/document.xml"))
        body = None
        for el in root.iter():
            if local(el.tag) == "body":
                body = el
                break
        if body is None:
            print("ERROR: no document body", file=sys.stderr)
            return 1

        blocks: List[Dict[str, Any]] = []
        img_counter = [0]
        for child in body:
            tag = local(child.tag)
            if tag == "p":
                blocks.extend(paragraph_blocks(child, rels, zf, img_dir, img_counter))
            elif tag == "tbl":
                blocks.append(table_block(child))
            # sectPr 忽略

        core = read_core_props(zf)
        try:
            st = os.stat(path)
            mtime, size = int(st.st_mtime), int(st.st_size)
        except OSError:
            mtime, size = 0, 0

        payload = {
            "version": 1,
            "kind": "docx",
            "path": os.path.abspath(path),
            "mtime": mtime,
            "size": size,
            "meta": {
                "title": core.get("title") or "",
                "author": core.get("author") or "",
                "subject": core.get("subject") or "",
                "creator": "",
                "page_count": 1,
            },
            "pages": [
                {
                    "page": 1,
                    "width": 0,
                    "height": 0,
                    "blocks": blocks,
                }
            ],
            "page_count": 1,
            "extracted_pages": 1,
        }
        with open(out_json, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False)
        print("OK 1")
        return 0


def try_convert_doc_to_docx(doc_path: str, out_dir: str) -> Optional[str]:
    """旧 .doc：尝试 LibreOffice 转 docx。"""
    ensure_dir(out_dir)
    converters = []
    for name in ("soffice", "libreoffice"):
        # PATH 查找由调用方 system 处理；这里返回命令模板
        converters.append(name)
    import subprocess

    for cmd in converters:
        try:
            r = subprocess.run(
                [cmd, "--headless", "--convert-to", "docx", "--outdir", out_dir, doc_path],
                capture_output=True,
                text=True,
                timeout=120,
            )
            if r.returncode == 0:
                base = os.path.splitext(os.path.basename(doc_path))[0] + ".docx"
                cand = os.path.join(out_dir, base)
                if os.path.isfile(cand):
                    return cand
        except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
            continue
    return None


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: extract_docx.py <docx|doc> <out_json> [img_dir]", file=sys.stderr)
        return 2
    path = os.path.abspath(sys.argv[1])
    out_json = os.path.abspath(sys.argv[2])
    img_dir = os.path.abspath(sys.argv[3]) if len(sys.argv) > 3 else os.path.join(os.path.dirname(out_json), "images")

    if not os.path.isfile(path):
        print(f"ERROR: file not found: {path}", file=sys.stderr)
        return 1

    ext = os.path.splitext(path)[1].lower()
    if ext == ".doc":
        conv_dir = os.path.join(os.path.dirname(out_json), "converted")
        converted = try_convert_doc_to_docx(path, conv_dir)
        if not converted:
            print(
                "ERROR: .doc needs LibreOffice (soffice) to convert, or save as .docx",
                file=sys.stderr,
            )
            return 1
        path = converted
        ext = ".docx"

    if ext != ".docx":
        print(f"ERROR: unsupported: {ext}", file=sys.stderr)
        return 1

    return extract_docx(path, out_json, img_dir)


if __name__ == "__main__":
    sys.exit(main())
