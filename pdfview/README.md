# pdfview.nvim

**English** | [中文](README.zh.md)

Open **PDF / Word** files inside Neovim as a **structured preview** (not raw binary, not full-page screenshots).

- Text: **color / bold / italic** (and monospace)
- Images: **Python+Pillow** block art; **Enter / click / `gi`** opens a float with **HD overlay when supported** (same path as mdview)
- Tables: Unicode borders
- `gh`: temporary page HD (clears on scroll/blur)

Demos:

- PDF: [`testdata/demo.pdf`](./testdata/demo.pdf)
- Word: [`testdata/demo.docx`](./testdata/demo.docx)

![pdfview screenshot](../images/pdfview-pdf.png)

## Features

| Feature | Notes |
|---------|--------|
| Auto-open | `.pdf` / `.docx` / `.doc` (`auto_open`) |
| Text styles | Per-span/run color, bold, italic, mono |
| Tables | PDF `find_tables`; Word `w:tbl` |
| Images | Python+Pillow block art |
| Enter / click / `gi` | Image float + `attach_float` HD when available |
| `gh` | Temporary HD for visible images |
| Pages | `n` / `]` next, `p` / `[` prev (PDF) |

## Dependencies

| Component | Role |
|-----------|------|
| Neovim 0.9+ | Host |
| Python 3 + **PyMuPDF** | PDF extract |
| Python 3 (stdlib) | **DOCX** extract (zip + xml) |
| LibreOffice `soffice` (optional) | Legacy **.doc** → docx |
| Python 3 + **Pillow** | In-preview block art + HD encode |
| WezTerm / Kitty / Ghostty | Float / `gh` pixel HD |

```bash
pip install pymupdf Pillow
```

## Install

```vim
Plug '/path/to/nvimplugins/pdfview'
" or whole-repo: Plug 'cfwang123/nvimplugins'
```

```vim
:PdfView
:DocView /path/to/file.docx
:PdfViewRefresh
:PdfViewClose
```

## Keys

| Key | Action |
|-----|--------|
| `q` / `Esc` | Close |
| `r` | Re-extract + render |
| `]` | Next page (PDF) |
| `[` | Prev page (PDF) |
| `gg` | First page; `42gg` jump to page 42 |
| `G` | Last page; `42G` jump to page 42 |
| `gp` | Prompt for page number |
| **`t`** | Toggle left **TOC** (auto-open when outline exists) |
| **`/`** | Full-text search (right panel; whole PDF) |
| **Enter / double-click** | Jump to hit (in results panel) |
| `n` / `N` | Search hits: next/prev |
| `q` | Close search panel |
| **Enter / click** | Image float (+ HD if supported) |
| `gi` | Same |
| `gh` | Temporary page HD |
| `o` | System-open document or image |
| `?` | Help |

## Config

```lua
require("pdfview").setup({
  auto_open = true,
  python = "python",
  -- large PDFs: lazy extract + render only near the window
  lazy_render = true,
  lazy_threshold = 12,
  viewport_buffer = 2,
  extract_chunk = 8, -- first pages extracted synchronously on open
  image = {
    backend = "python",
    open_with = "float",
    float_scale = "fit",
    float_hd = "always",
  },
})
```

## Limits

- Scanned PDFs are mostly images  
- Complex layouts may reorder  
- `.doc` needs LibreOffice; prefer `.docx`  
- HD needs graphics-protocol terminals  
- Large PDFs use **lazy extract** (first `extract_chunk` pages, then more as you scroll) plus viewport render; not a full-document parse on open  
