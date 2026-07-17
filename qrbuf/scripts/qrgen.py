# -*- coding: utf-8 -*-
"""QR matrix generator CLI — uses vendored Nayuki qrcodegen (MIT).

Output JSON: { "size": N, "matrix": [[0|1, ...], ...] }  (includes quiet zone border)
"""
from __future__ import annotations

import json
import os
import sys

# 与本脚本同目录的 qrcodegen.py（Nayuki）
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from qrcodegen import QrCode  # type: ignore  # noqa: E402


def make_matrix(text: str, border: int = 4) -> list[list[int]]:
    """返回含静区的 0/1 矩阵。border 默认 4 模块（扫码识别更稳）。"""
    qr = QrCode.encode_text(text, QrCode.Ecc.MEDIUM)
    size = qr.get_size()
    n = size + border * 2
    mat: list[list[int]] = [[0] * n for _ in range(n)]
    for y in range(size):
        for x in range(size):
            # get_module: True = dark
            mat[y + border][x + border] = 1 if qr.get_module(x, y) else 0
    return mat


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8")
        except Exception:
            pass

    text = ""
    border = 4
    fpath = None
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("-b", "--border") and i + 1 < len(args):
            border = max(0, min(16, int(args[i + 1])))
            i += 2
        elif a in ("-t", "--text") and i + 1 < len(args):
            text = args[i + 1]
            i += 2
        elif a in ("-f", "--file") and i + 1 < len(args):
            fpath = args[i + 1]
            i += 2
        else:
            # 剩余合并为文本（兼容旧调用：qrgen.py "hello"）
            text = " ".join(args[i:])
            break

    if fpath:
        with open(fpath, "r", encoding="utf-8") as f:
            text = f.read()
    elif not text:
        text = sys.stdin.read()
    # 保留内容，仅去掉首尾多余空行
    text = text.replace("\r\n", "\n")
    if text.startswith("\n"):
        text = text.lstrip("\n")
    if text.endswith("\n") and text.count("\n") >= 1:
        text = text.rstrip("\n")
    if text == "":
        print(json.dumps({"error": "empty"}, ensure_ascii=False))
        return 1

    try:
        mat = make_matrix(text, border=border)
    except Exception as e:
        print(json.dumps({"error": str(e)}, ensure_ascii=False))
        return 2

    print(json.dumps({"size": len(mat), "matrix": mat, "border": border}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
