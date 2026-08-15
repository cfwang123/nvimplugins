# Changelog

All notable changes to this repository are documented in this file.

---

## 2026-08-15

### English

#### mdview

- Code block expand/collapse is **incremental** (patch that block only; no full re-parse/re-render).
- **Enter** still toggles fold anywhere in the code block; **mouse** only on the gray fold line (`⋯ N more · <CR> expand` / `⋯ <CR> collapse`).
- **Segment-based preview updates**: source edits re-render only dirty top-level AST blocks (paragraph / table / code / list / …); headings still force a full refresh (TOC).
- **`<details>`** expand/collapse is incremental (same segment patch path).
- **`L` language toggle** only rewrites UI strings (key hint, TOC title, `[Copy]` labels); no full re-parse.

### 中文

#### mdview

- 代码块展开/收起改为**增量刷新**（只 patch 该块，不再整文件 parse + render）。
- **Enter** 在代码块内任意位置仍可切换折叠；**鼠标**仅点底部灰字行（`⋯ N more · <CR> expand` / `⋯ <CR> collapse`）才切换。
- **按段增量预览**：源码编辑只重渲脏的顶层 AST 段（段落 / 表格 / 代码 / 列表等）；标题变更仍全量（牵动 TOC）。
- **`<details>`** 展开/收起走同一套段 patch。
- **`L` 切语言**只改文案（顶栏、TOC 标题、`[复制]`），不再整篇 re-parse。

---

## 2026-08-13

### English

#### colorpicker

- In-buffer preview no longer inserts **`██`** (it split markdown inline code and looked like a stain). CSS tokens are now **painted with that color as background** and black/white text by luminance. Click `#` to edit is unchanged.

#### mdview

- Editor: task-list **`[ ]` / `[x]`** are no longer concealed. mdview sets `conceallevel=2` for `==` / images; treesitter then hid checkbox brackets as shortcut-link delimiters.

### 中文

#### colorpicker

- 文件内预览不再插入 **`██`**（会撑开 Markdown 行内代码，看起来像色块污渍）。改为给色码**铺该色底**，字色按亮度黑/白。单击 `#` 打开取色器不变。

#### mdview

- 编辑区：任务列表 **`[ ]` / `[x]`** 不再被 conceal。mdview 为 `==` / 图片打开 `conceallevel=2` 后，treesitter 把复选框方括号当成 shortcut link 藏掉了。

---

## 2026-08-12

### English

#### bookmarks

- Keys scope: default global maps are only `<leader>bo`. `A` / `D` (and other panel actions) are **buffer-local** in the bookmarks sidebar so edit windows keep Neovim defaults (`A` append EOL, `D` delete to EOL).
- Optional global add keys via setup: `keys_add_file` / `keys_add_dir` (default `false`). Or use `:BookmarksAddFile` / `:BookmarksAddDir`.

#### mdview

- Fix: on **Neovim 0.9**, link highlights were dropped because extmark option `url` (0.10+) made the whole `set_extmark` fail under `pcall`. Links now keep **blue text + blue underline** (`fg`/`sp`); `url` is only set on 0.10+.
- Link color follows theme markdown-link groups when available, else GitHub-like blue on light bg / bright blue on dark bg (avoids pink/red underlines from theme `guisp`).
- Links strip optional destination title / `<angled>` path; missing local targets notify `link target not found`.

#### tablemode

- Fix: typing `|` on an empty line **below a complete table** no longer expands into a header/separator (or bottom border). It now inserts a **new empty data row** with the correct column count.
- Separator expansion (`||` / pipe-only after the first header row) still works when the table has **one data row and no header separator yet**.

### 中文

#### bookmarks

- 快捷键范围：默认全局仅 `<leader>bo`；`A` / `D` 等操作键仅在收藏夹窗口内生效（buffer-local），文件编辑等窗口恢复 Neovim 默认行为。
- 如需全局添加快捷键，可在 setup 设置 `keys_add_file` / `keys_add_dir`（默认 `false`）；或使用命令 `:BookmarksAddFile` / `:BookmarksAddDir`。

#### mdview

- 修复：**Neovim 0.9** 下链接高亮全部丢失——extmark 的 `url` 仅 0.10+ 支持，写入后整次 `set_extmark` 在 `pcall` 中失败。现为**蓝字 + 蓝色下划线**（`fg`/`sp`）；`url` 仅在 0.10+ 设置。
- 链接色优先跟主题 markdown 链接组；否则浅色底用 GitHub 蓝、深色底用亮蓝（避免主题 `guisp` 变成红/粉下划线）。
- 链接目标去掉可选 title / `<尖括号>`；本地路径不存在时提示 `链接目标不存在`。

#### tablemode

- 修复：在**已完整表格下方**空行输入 `|` 时，不再误展开成表头分隔线/底线；改为按列数追加**空数据行**。
- 从零画表时，表头下一行的 `|` / `||` 在「仅一行数据且尚无分隔线」时仍会展开为分隔行。

---

## 2026-08-02

### English

#### mdview

- Tables use **content-sized column widths** when they fit: no longer stretch the last column to fill the preview window. Wide tables still compress into the available width.

### 中文

#### mdview

- 表格在能放下时**按内容定宽**，不再把余量塞进最后一列以撑满预览窗；内容过宽时仍压缩进可用宽度。

---

## 2026-07-28

### English

#### colorpicker (new)

- New sub-plugin **colorpicker**: HSV float with SV plane + **H/S/V/A** sliders (truecolor); pure Lua.
- **`:ColorPicker`** / **`<leader>co`**: **Enter** or **double-click** inserts/replaces CSS (`hex` / `rgb` / `rgba` / `hsl` / `hsla` / `hex_alpha`); **`y`** yanks; **`Tab`** format; **`L`** language.
- **Keyboard steps by UI cell** (not 1% / 1°): **`hjkl`** / **`[]`** / **`,` `.`** = 1 cell; coarse default **5** cells (`step_*_coarse`).
- Hue **wraps**: at leftmost (0°), **`[`** jumps to rightmost cell (stored as 360°, same color as 0°); **`]`** from rightmost back to 0°.
- Cursor on color token → load and **replace** on confirm; float disables visual UI select; mouse hit-test by character cell.
- **In-buffer `██`**: display only (no bg on code text); **click hex `#`** to open/replace; does not block mouse-drag visual select; **`:ColorPickerPreview`**.
- **Fixed highlight pool** (`hlpool`: `ColorpickerC*` / `ColorpickerPrev*`) + dynamic `set_hl` — avoids **E849 Too many highlight groups**.
- Registered in bundle defaults, help catalog, root README.

#### calendar (new)

- New sub-plugin **calendar**: month float with solar date, live clock, Chinese lunar (1900–2100), solar terms & holidays.
- **`:Calendar`** / **`<leader>cal`**: navigate day/week/month/year; **`n`** notes, **`c`** color marks, **`x`** clear; **`L`** language.
- Notes/colors in `stdpath("data")/calendar-nvim-notes.json`; pure Lua, no network.
- Registered in bundle defaults, help catalog, root README.

#### calendar

- **Selection / cell highlights** use UTF-8 **byte** ranges (fixes misaligned lunar-line HL on CJK).
- Days with a note show a trailing red **`●`** (`CalendarNoteDot`; light red on selected cell).

#### bundle / i18n keys

- **UI language toggle unified to `L`** across plugins:
  - **music** / **videobuf**: `L` = language; **`o`** = loop (was `L`).
  - **drawbuf**: `L` = language; **`|`** = line tool (was `L`).
  - **nvimgames** (menu + all games): `L` = language (was `u`/`U`).
- Root README, help catalog, and plugin READMEs updated.

#### mdview

- Preview **headings** (`#`…`######`): forced **bold** and distinct level colors (`MdViewH1`–`MdViewH6`; no longer link-only to `Title` / stack `MdViewBold`).

#### tablemode

- **Live cell realign** while table mode is on: typing inside a cell debounced-realigns the whole table (`auto_align_live`, default on; `auto_align_ms = 60`).
- Final realign on **InsertLeave**; changes joined with **undojoin** so one undo undoes type+align.
- Cursor kept on the same cell/content offset across padding changes.
- **Cell block select** (like xlsview): **`Ctrl-v` / `Ctrl-q`** selects at least the current cell; visual **`hjkl` / arrows** expand by one column/row; **`y` / `Ctrl-c`** yanks **TSV** (tabs, strips `|`). Config: `map_vblock`.
- **Table highlights** while mode is on: header row background (`TableModeHeader`) and border color (`TableModeBorder` for `|` / separator). Config: `highlight`, `hl_header`, `hl_border`.

#### tablemode (new)

- New sub-plugin **tablemode** (vim-table-mode style, pure Lua; name avoids shadowing Lua `table`).
- **`:TableModeToggle`** / **`<leader>tm`**: buffer-local table mode; insert **`|`** live-aligns; **`||`** expands to a header separator.
- **`:TableModeRealign`** / **`<leader>tr`**, **`:Tableize`** / **`<leader>tt`**, delimiter prompt **`<leader>T`**.
- Cell motions **`]|` `[|` `}|` `{|`**, text objects **`i|` `a|`**, delete/insert row & column maps.
- GFM alignment (`:---`, `---:`, `:---:`); markdown/rst smart corners; `vim.g.tablemode_status` for statusline.
- Registered in bundle defaults, help catalog, root README.

---

### 中文

#### colorpicker（新插件）

- 新增子插件 **colorpicker**：HSV 浮窗（SV 平面 + **H/S/V/A** 滑条，真彩色）；纯 Lua。
- **`:ColorPicker`** / **`<leader>co`**：**Enter** 或 **双击** 插入/替换 CSS；**`y`** 复制；**`Tab`** 格式；**`L`** 中英。
- **键盘按 UI 格步进**（非 1% / 1°）：**`hjkl`** / **`[]`** / **`,` `.`** = 1 格；粗调默认 **5** 格（`step_*_coarse`）。
- 色相**环绕**：最左 0° 时 **`[`** 到最右格（内部 360°，与 0° 同色）；最右 **`]`** 回到 0°。
- 光标在色码上 → 确认时**替换**；浮窗禁 visual；鼠标按字符格命中。
- **文件内 `██`**：仅展示（色码无背景）；**单击 hex 的 `#`** 打开并替换；不挡拖选；**`:ColorPickerPreview`**。
- **固定高亮池**（`hlpool`）+ 动态 `set_hl`，避免 **E849 Too many highlight groups**。
- 已加入整仓默认加载、帮助目录与根 README。

#### calendar（新插件）

- 新增子插件 **calendar**：月历浮窗，公历 + 实时时钟 + 农历（1900–2100）+ 节气/节日。
- **`:Calendar`** / **`<leader>cal`**：按日/周/月/年浏览；**`n`** 备注、**`c`** 颜色、**`x`** 清除；**`L`** 中英。
- 备注与颜色存 `stdpath("data")/calendar-nvim-notes.json`；纯 Lua，无网络。
- 已加入整仓默认加载、帮助目录与根 README。

#### calendar

- **选中/格子高亮**按 UTF-8 **字节**偏移计算（修复中文农历行高亮错位）。
- 有备注的日期在农历标签后显示红色 **`●`**（`CalendarNoteDot`；选中格内为浅红）。

#### 合集 / 中英快捷键

- **界面语言切换统一为 `L`**：
  - **music** / **videobuf**：`L` = 中英；**`o`** = 循环（原 `L`）。
  - **drawbuf**：`L` = 中英；**`|`** = 直线工具（原 `L`）。
  - **nvimgames**（选单与各游戏）：`L` = 中英（原 `u`/`U`）。
- 已更新总 README、帮助目录与相关子插件文档。

#### mdview

- 预览 **标题**（`#`…`######`）：强制 **加粗**，并按层级使用独立颜色（`MdViewH1`–`MdViewH6`；不再只链 `Title` 或叠 `MdViewBold` 盖色）。

#### tablemode

- **编辑单元格时实时对齐**：表格模式开启后，在格内输入会防抖重排整表（`auto_align_live`，默认开；`auto_align_ms = 60`）。
- **InsertLeave** 再对齐一次；用 **undojoin** 合并输入与对齐，撤销一步即可。
- 光标保持在同一单元格/内容偏移（适配 padding 变化）。
- **单元格块选**（对齐 xlsview）：**`Ctrl-v` / `Ctrl-q`** 至少选中当前整格；可视 **`hjkl` / 方向键** 每次扩一列/行；**`y` / `Ctrl-c`** 复制为 **TSV**（Tab 分列，去掉 `|`）。配置项：`map_vblock`。
- **表格高亮**（模式开启时）：表头行背景（`TableModeHeader`）、表格线颜色（`TableModeBorder`，含 `|` 与分隔行）。配置：`highlight`、`hl_header`、`hl_border`。

#### tablemode（新插件）

- 新增子插件 **tablemode**（仿 vim-table-mode，纯 Lua；不用 `table` 作模块名以免覆盖 Lua 内置库）。
- **`:TableModeToggle`** / **`<leader>tm`**：按 buffer 开启；插入 **`|`** 即时对齐；**`||`** 展开为表头分隔行。
- **`:TableModeRealign`** / **`<leader>tr`**，**`:Tableize`** / **`<leader>tt`**，自定义分隔符 **`<leader>T`**。
- 单元格移动 **`]|` `[|` `}|` `{|`**，文本对象 **`i|` `a|`**，删行/删列/插列快捷键。
- GFM 对齐标记；markdown/rst 智能角样式；`vim.g.tablemode_status` 可供 statusline。
- 已加入整仓默认加载、帮助目录与根 README。

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
