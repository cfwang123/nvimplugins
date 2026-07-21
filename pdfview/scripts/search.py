# -*- coding: utf-8 -*-
"""PDF 全文搜索（PyMuPDF，不依赖结构化提取缓存）。

  python -X utf8 search.py <pdf> <query> [max_hits]

Stdout JSON:
  {"ok": true, "query": "...", "hits": [{"page": 1, "snippet": "...", "line": "..."}], "total": N}
"""
from __future__ import annotations

import json
import re
import sys
from typing import Any, Dict, List

try:
    import fitz
except ImportError:
    print(json.dumps({"ok": False, "error": "PyMuPDF required (pip install pymupdf)"}, ensure_ascii=False))
    sys.exit(2)


def snippet_around(text: str, pos: int, needle_len: int, radius: int = 48) -> str:
    a = max(0, pos - radius)
    b = min(len(text), pos + needle_len + radius)
    s = text[a:b].replace("\n", " ").replace("\r", " ")
    s = re.sub(r"\s+", " ", s).strip()
    if a > 0:
        s = "…" + s
    if b < len(text):
        s = s + "…"
    return s


def search_page_text(page_text: str, query: str, page_no: int, max_per_page: int = 8) -> List[Dict[str, Any]]:
    if not page_text or not query:
        return []
    # 大小写不敏感（对中文等同普通 find）
    hay = page_text
    needle = query
    try:
        hay_cf = page_text.casefold()
        needle_cf = query.casefold()
    except Exception:
        hay_cf, needle_cf = page_text.lower(), query.lower()

    hits: List[Dict[str, Any]] = []
    start = 0
    while len(hits) < max_per_page:
        pos = hay_cf.find(needle_cf, start)
        if pos < 0:
            break
        snip = snippet_around(hay, pos, len(needle))
        # 取所在「行」概要
        line_start = hay.rfind("\n", 0, pos) + 1
        line_end = hay.find("\n", pos)
        if line_end < 0:
            line_end = len(hay)
        line = re.sub(r"\s+", " ", hay[line_start:line_end]).strip()
        if len(line) > 120:
            line = line[:117] + "…"
        hits.append(
            {
                "page": page_no,
                "snippet": snip,
                "line": line or snip,
                "col": pos - line_start,
            }
        )
        start = pos + max(1, len(needle_cf))
    return hits


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8")
        except Exception:
            pass

    if len(sys.argv) < 3:
        print(json.dumps({"ok": False, "error": "usage: search.py <pdf> <query> [max_hits]"}, ensure_ascii=False))
        return 2

    pdf = sys.argv[1]
    query = sys.argv[2]
    max_hits = int(sys.argv[3]) if len(sys.argv) > 3 else 200
    max_hits = max(1, min(2000, max_hits))

    if not query or not query.strip():
        print(json.dumps({"ok": False, "error": "empty query"}, ensure_ascii=False))
        return 2

    try:
        doc = fitz.open(pdf)
    except Exception as e:
        print(json.dumps({"ok": False, "error": f"open failed: {e}"}, ensure_ascii=False))
        return 1

    try:
        all_hits: List[Dict[str, Any]] = []
        for i in range(doc.page_count):
            if len(all_hits) >= max_hits:
                break
            try:
                text = doc[i].get_text("text") or ""
            except Exception:
                text = ""
            remain = max_hits - len(all_hits)
            page_hits = search_page_text(text, query.strip(), i + 1, max_per_page=min(8, remain))
            all_hits.extend(page_hits)

        print(
            json.dumps(
                {
                    "ok": True,
                    "query": query.strip(),
                    "page_count": doc.page_count,
                    "total": len(all_hits),
                    "hits": all_hits,
                    "truncated": len(all_hits) >= max_hits,
                },
                ensure_ascii=False,
            )
        )
        return 0
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}, ensure_ascii=False))
        return 1
    finally:
        doc.close()


if __name__ == "__main__":
    raise SystemExit(main())
