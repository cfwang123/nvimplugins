# Changelog

All notable changes to this repository are documented in this file.

---

## 2026-07-21

### English

#### mdview

- **Paste clipboard image** into the Markdown source buffer:
  - Saves under the md file as `images/yyyyMMddHHmmss.png` (suffix `_2`… on same-second collision).
  - Inserts `![image](images/...)` (configurable `paste_image.alt`, default `"image"`).
  - Requires **Python + Pillow**; prefers `g:python3_host_prog`, then `image.python` / `python` / `python3`.
  - Command **`:MdViewPasteImage`**; API **`require("mdview").smart_clipboard_paste()`** for custom keys (e.g. `Q`).
- **Smart paste keys** (markdown source only):
  - Intercepts **`p` / `P`** when the register is `+` / `*` (covers typed `"+p` and recursive `nmap Q "+p`).
  - Also handles the common case where a Lua-mapped `p` loses `vim.v.register` (`"+` → `"`): if the default register has no text, still try clipboard image, then fall back to `"+` text paste.
  - Insert: **`Ctrl-Shift-v`**, **`Shift-Insert`** (image first, else clipboard text).
  - Config: `paste_image` (`enable`, `dir`, `alt`, `intercept_clipboard_put`, `keys`).
- **Source image conceal** (editor, non-cursor lines):
  - `![alt](url)` displays as **`🖼 name`** (`alt` empty → `image`); full syntax on the cursor line.
  - Config: `source_image_conceal` (default `true`).
- Help / README: document paste flow, `nnoremap` vs `nmap` for `Q`, and `smart_clipboard_paste`.

---

### 中文

#### mdview

- **粘贴剪贴板图片**到 Markdown 源 buffer：
  - 保存到 md 旁 `images/yyyyMMddHHmmss.png`（同秒冲突加 `_2`…）。
  - 插入 `![image](images/...)`（`paste_image.alt` 可配，默认 `"image"`）。
  - 依赖 **Python + Pillow**；解释器优先 `g:python3_host_prog`，其次 `image.python` / `python` / `python3`。
  - 命令 **`:MdViewPasteImage`**；自定义键可绑 **`require("mdview").smart_clipboard_paste()`**（如 `Q`）。
- **智能粘贴键**（仅 markdown 源）：
  - 拦截 **`p` / `P`**，寄存器为 `+` / `*` 时贴图（覆盖手动 `"+p` 与递归 `nmap Q "+p`）。
  - 兼容 Lua 映射后 **`vim.v.register` 丢失**（`"+` 变成 `"`）：默认寄存器无文本时仍尝试剪贴板图，再回退 `"+` 文本粘贴。
  - 插入模式：**`Ctrl-Shift-v`**、**`Shift-Insert`**（有图优先，否则粘贴文本）。
  - 配置项：`paste_image`（`enable` / `dir` / `alt` / `intercept_clipboard_put` / `keys`）。
- **源码图片折叠显示**（编辑窗、非光标行）：
  - `![alt](url)` 显示为 **`🖼 name`**（`alt` 为空 → `image`）；光标行显示完整源码。
  - 配置：`source_image_conceal`（默认 `true`）。
- 帮助 / README：补充粘贴流程、`Q` 的 `nnoremap`/`nmap` 说明与 `smart_clipboard_paste`。

---

## 2026-07-20

### English

#### mdview

- Image float default scale changed from **fill (stretch)** to **fit** (aspect-preserving letterbox).
- Block-character float art is **centered** inside the float when using fit.
- Character thumbs no longer depend on **chafa**; rendering is **Python + Pillow** only (`thumb.py`). Config `image.backend` defaults to `"python"`.

#### pdfview

- Same image float **fit** default and block-art letterbox centering as mdview.
- Character thumbs: **Python + Pillow** only (chafa path removed).
- **Lazy extract + lazy render** for large PDFs (e.g. 1000+ page manuals):
  - Open extracts only the first `extract_chunk` pages (default 8).
  - Further pages load on demand when scrolling or jumping nearby.
  - Unextracted pages use equal-height stubs (`stub_page_lines`) so scrollbar position roughly tracks document progress.
  - Already extracted pages stay fully rendered when you scroll away and back.
- **Full-text search** (`/`):
  - Right-hand results panel (not a float).
  - PDF search uses PyMuPDF over the whole file (independent of lazy extract).
  - Enter / double-click jumps to the hit; **n / N** next/previous hit.
  - Highlights query in both the preview and the results list.
  - **q** closes the search panel (and TOC if open) before closing the preview.
- **Page navigation**:
  - Page turn: **]** next, **[** previous only (no longer **n** / **p** for pages).
  - **gg** first page; **G** last page; **`{count}G` / `{count}gg`** jump to page; **gp** prompt for page number.
- **Left TOC** from PDF outline (bookmarks):
  - Auto-opens when the document has an outline (`toc = true` by default).
  - Toggle with **t**; Enter/double-click jumps to page; tracks current page highlight.

#### weather

- Added a **China domestic** weather source (China Weather Net data via itboy CDN, no API key).
- Default `source = "auto"`: **Chinese system locale → domestic source** (fallback Open-Meteo on failure); **otherwise → Open-Meteo**.
- Ships `scripts/citycode.json` for city name → city code resolution.

---

### 中文

#### mdview

- 图片 float 默认由 **fill 拉伸** 改为 **fit 等比**（letterbox 留边）。
- fit 模式下 █ 字符画在 float 内 **居中**。
- 字符画不再依赖 **chafa**，仅使用 **Python + Pillow**（`thumb.py`）。`image.backend` 默认 `"python"`。

#### pdfview

- 图片 float 默认 fit、字符画居中，与 mdview 一致。
- 字符画仅 **Python + Pillow**（移除 chafa）。
- **大 PDF 懒提取 + 懒渲染**（可应对千页级手册）：
  - 打开时只同步提取前 `extract_chunk` 页（默认 8）。
  - 滚动/跳页靠近时再按需提取。
  - 未提取页用等高占位（`stub_page_lines`），滚动条比例接近真实页序。
  - 已提取页滚走再滚回仍完整显示。
- **全文搜索**（`/`）：
  - 右侧结果专用窗（非 float）。
  - PDF 用 PyMuPDF 扫全书（与懒提取无关）。
  - Enter / 双击跳转；**n / N** 下/上一条。
  - 预览区与结果列表均高亮关键词。
  - **q** 优先关搜索/目录，再关预览。
- **翻页与跳页**：
  - 翻页仅用 **]** / **[**（不再用 n/p 翻页）。
  - **gg** 首页；**G** 末页；**`{count}G` / `{count}gg`** 跳页；**gp** 输入页码。
- **左侧 TOC 大纲**（PDF 书签）：
  - 有大纲时默认打开（`toc = true`）。
  - **t** 开关；Enter/双击跳页；随当前页高亮条目。

#### weather

- 新增**国内天气源**（中国天气网数据 / itboy CDN，无需 Key）。
- 默认 `source = "auto"`：**系统中文 → 国内源**（失败回退 Open-Meteo）；**非中文 → Open-Meteo**。
- 附带 `scripts/citycode.json` 城市名 → 城市码。
