# pdfview.nvim

[English](README.md) | **中文**

在 Neovim 内打开 **PDF / Word** 并进入**结构化预览**（不是二进制乱码，也不是整页截图）。

- 文本：**颜色 / 粗体 / 斜体**（及等宽字体）
- 图片：**Python+Pillow** 色块；**Enter / 点击 / `gi`** 打开 float，支持时**自动高清叠层**（同 mdview）
- 表格：Unicode 边框渲染
- 页内 `gh`：临时高清（滚动/失焦清除）

演示：

- PDF：[`testdata/demo.pdf`](./testdata/demo.pdf)
- Word：[`testdata/demo.docx`](./testdata/demo.docx)

![pdfview 截图](../images/pdfview-pdf.png)

## 功能一览

| 能力 | 说明 |
|------|------|
| 自动打开 | 打开 `.pdf` / `.docx` / `.doc` 即预览（`auto_open`） |
| 文本样式 | span/run 级颜色、bold、italic、mono |
| 表格 | PDF：`find_tables`；Word：`w:tbl` |
| 图片 | Python+Pillow 色块字符画 |
| Enter / 点击 / `gi` | float 大图 + 终端支持时 **attach_float 高清** |
| `gh` | 当前可见区图片临时高清 |
| 翻页 | `]` 下一页，`[` 上一页（PDF） |

## 依赖

| 组件 | 作用 |
|------|------|
| Neovim 0.9+ | 宿主 |
| Python 3 + **PyMuPDF** | PDF 提取 |
| Python 3（标准库） | **DOCX** 提取（zip + xml，无需 python-docx） |
| LibreOffice `soffice`（可选） | 旧 **.doc** → docx |
| Python 3 + **Pillow** | 预览内色块 + float/gh 高清编码 |
| WezTerm / Kitty / Ghostty | float / `gh` 像素高清 |

```bash
pip install pymupdf Pillow
# 可选 .doc：安装 LibreOffice，保证 soffice 在 PATH
```

## 安装

### 分目录

```vim
Plug '/path/to/nvimplugins/pdfview'
```

### 整仓

```vim
Plug 'cfwang123/nvimplugins'
```

装好后**无需 `setup()`**。打开文件或：

```vim
:PdfView
:PdfView /path/to/file.pdf
:DocView /path/to/file.docx   " 别名
:PdfViewRefresh
:PdfViewClose
```

## 快捷键（预览 buffer）

| 键 | 作用 |
|----|------|
| `q` / `Esc` | 关闭预览 |
| `r` | 强制重新提取并渲染 |
| `]` | 下一页（PDF） |
| `[` | 上一页（PDF） |
| `gg` | 第 1 页；`42gg` 跳到第 42 页 |
| `G` | 最后一页；`42G` 跳到第 42 页 |
| `gp` | 输入页码跳转 |
| **`t`** | 打开/关闭左侧 **大纲 TOC**（有大纲时默认开启） |
| **`/`** | **全文搜索**（右侧结果窗；PDF 扫全书） |
| **Enter / 双击** | 跳到对应页（结果窗内） |
| `n` / `N` | 搜索结果：下/上一条 |
| `q` | 关闭搜索结果窗 |
| **Enter / 鼠标点击** | 光标处图片 → float（支持则高清） |
| `gi` | 同上 |
| `gh` | 当前页临时高清（再按 gh / 滚动 / 失焦清除） |
| `o` | 系统打开文档，或光标在图上时打开该图 |
| `?` | 帮助 |

## 配置示例

```lua
require("pdfview").setup({
  auto_open = true,
  python = "python",
  max_pages = 0,          -- 提取页数上限；0 = 不限制（仍按需懒提取）
  -- 大 PDF：按页懒提取 + 视口懒渲染（上千页手册也不会一次抽完卡死）
  lazy_render = true,
  lazy_threshold = 12,    -- 页数 ≥ 此值启用预览懒渲染
  viewport_buffer = 2,    -- 可见页上下各多渲染/提取几页
  extract_chunk = 8,      -- 打开时先同步提取前 N 页
  toc = true,             -- 有 PDF 大纲时默认开左侧 TOC
  toc_width = 32,
  table_style = "unicode", -- unicode | ascii | minimal
  page_sep = true,
  image = {
    mode = "thumb",       -- thumb | placeholder | off
    backend = "python",   -- python+Pillow 字符画；none 关闭
    open_with = "float",  -- Enter/点击/gi
    max_height = 0,
    max_images = 30,
    cell_aspect = 0.5,
    float_scale = "fit",  -- fit 等比 | fill 拉伸
    float_hd = "always",  -- float 内高清（终端支持时）
    python = "python",
    hd_tmux = false,
    hd_ssh = false,
  },
})
```

关闭自动打开：

```lua
require("pdfview").setup({ auto_open = false })
```

## 工作原理（简）

| 格式 | 脚本 |
|------|------|
| PDF | `scripts/extract.py`（PyMuPDF） |
| DOCX | `scripts/extract_docx.py`（标准库） |
| DOC | 先 soffice 转 docx，再同上 |

提取结果 → Lua `render`（真彩色 / 表 / 色块图）→ Enter 时 `image.open_float`：█ 底层 + `graphics.attach_float` 高清。

**懒提取 + 懒渲染（默认开）**：

- **提取**：打开时只同步抽前 `extract_chunk` 页；滚动靠近未加载页时**异步**补提取（单页缓存于 `stdpath("cache")/pdfview/.../pages/`）。
- **已提取页**：始终完整显示（滚走再滚回不丢内容）。
- **未提取页**：等高占位（`stub_page_lines`，默认 36 行），滚动约 50% ≈ 手册中部。
- 上千页芯片手册可秒开，不会一次抽完全书卡死 Neovim。

缓存：`stdpath("cache")/pdfview/<hash>/`

## 说明：打开 `.docx` 报 zip / unzip 错

Neovim 自带 `zipPlugin` 会把 `.docx` 当 zip 浏览。本插件会：

1. 从 `g:zipPlugin_ext` 去掉 Word 扩展  
2. 重绑 `augroup zip`，避免 `zip#Browse`  
3. 用 `BufReadCmd` 兜底直接进 pdfview  

若仍看到 `unzip not available`，确认已加载最新 pdfview，并重启 Neovim（或 `:lua require("pdfview.zipfix").install()`）。

`vim.tbl_flatten is deprecated` 来自其它运行时/插件（非 pdfview），与打开 docx 无关。

## 限制

- 扫描版 PDF 几乎只有图  
- 复杂多栏版式可能顺序偏差  
- 旧 `.doc` 依赖 LibreOffice；建议另存为 `.docx`  
- Word 复杂浮动图/文本框可能漏检  
- 高清需图形协议终端；tmux/SSH 默认关  
