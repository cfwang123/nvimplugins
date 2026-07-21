# mdview.nvim

**English** | [中文](README.zh.md)

Preview Markdown inside Neovim: **single-window reading** (`:MdView`) or **side-by-side** (`:MdSideView`).

Pure Lua parse + read-only preview buffer; code highlighting, TOC, tables, images rendered with block characters, link jumps, optional terminal HD overlays.

- Demo: [testdata/demo.md](./testdata/demo.md)
- Screenshots: [testdata/screenshots/](./testdata/screenshots/)

## Features

| Area | Description |
|------|-------------|
| Single / side | `:MdView` source ⇄ preview; `:MdSideView` paired view + scroll sync / `_` cursor mark |
| Style | Headings (optional auto numbers), bold, italic, `` code ``, strike, `==mark==` (preview + **editor yellow + conceal `==`**), links |
| Lists / quotes / HR / tables | GFM tables; dynamic columns; images in cells; escaped `\|` |
| Code blocks | Border, language, line numbers, gray bg, fold after 10 lines, **`c` / `yc` / [Copy]**, TS→syntax→plain |
| TOC | Top of preview; `t` in preview / **`<leader>toc`** in editor (configurable) opens TOC float |
| Links | Preview/editor Enter or Ctrl+LeftMouse; `#heading` / `#1. heading` anchors; md → target preview; `Ctrl-o` back |
| Images | Block chars in preview; `gi`/Enter float; **editor** Enter/Ctrl-click on `![](…)`; `gh` page HD; `o` system open |
| HTML | `<details>` / `<summary>`, `<img>`, `<font color/style>` (color / bold / italic; preview + editor) |
| Layout | Soft-wrap to preview width; reflow on resize |

---

## Install

From **① minimal** to **③ full**. Use your local paths.

### ① Minimal (works out of the box)

**Neovim 0.9+ only** — no Python, no Tree-sitter, no config.

You get: headings/lists/tables/code (plain or syntax), TOC, links, side sync, etc.  
You do **not** get: block-character images, float HD, Tree-sitter code highlight.

#### vim-plug (local path)

```vim
call plug#begin()
" mdview subfolder only
Plug '/path/to/nvimplugins/mdview'
" or whole-repo (network): Plug 'cfwang123/nvimplugins'  then :PlugInstall
call plug#end()
```

#### Manual rtp

```lua
vim.opt.rtp:prepend("/path/to/nvimplugins/mdview")
-- ensure plugin/mdview.lua is sourced at startup (or packadd)
```

No `setup()` required:

```vim
:e /path/to/nvimplugins/mdview/testdata/demo.md
:MdSideView
" or
:MdView
```

Default global maps (if free):

| Key | Command |
|-----|---------|
| `<leader>mv` | `:MdView` |
| `<leader>ms` | `:MdSideView` |
| `<leader>toc` | TOC float from editor/preview (`keys.toc`) |

Disable default keys:

```lua
require("mdview").setup({
  keys = { view = false, side = false, toc = false },
})
```

---

### ② Recommended (daily Markdown)

On top of ①:

| Dependency | Role |
|------------|------|
| **`termguicolors`** | Colors / block-character images look right |
| **Python 3 + Pillow** | Truecolor block images, float base + HD encode |
| **Tree-sitter** + language parsers | Code block highlighting (else syntax / plain) |

#### System deps

```bash
pip install Pillow
# or: python -m pip install Pillow
```

Tree-sitter example:

```lua
require("nvim-treesitter.configs").setup({
  ensure_installed = { "lua", "python", "javascript", "bash", "markdown" },
  highlight = { enable = true },
})
```

Install parsers as needed (`:TSInstall lua python`, etc.).

#### Suggested `setup`

```lua
require("mdview").setup({
  split_direction = "right",
  width = 0.45,
  code_fold_lines = 10,
  code_highlight = "auto", -- treesitter → syntax → plain
  sync_scroll = true,
  sync_cursor_block = true,
  keys = {
    view = "<leader>mv",
    side = "<leader>ms",
    toc = "<leader>toc",     -- TOC float from editor (false to disable)
  },
  image = {
    mode = "thumb",          -- block-character images in preview
    python = "python",
    open_with = "float",
    float_hd = "never",      -- tier ②: blocks only in float first
    float_scale = "fit",
  },
})
```

Then you get:

- Preview images as block characters, `gi` float (blocks)
- Code highlight (clearer with TS)
- Side-source cursor → preview `_` mark

---

### ③ Full (HD + complete experience)

On top of ②:

| Dependency | Role |
|------------|------|
| **WezTerm / Kitty / Ghostty** | Graphics protocol; float HD, `gh` temporary in-page HD |
| Truecolor terminal | Better blocks + HD look |
| Python 3 + **Pillow** | Block-character images (`thumb.py`) |

#### Terminals

- **WezTerm**: recommended; float / `gh` via iTerm protocol overlay  
- **Kitty / Ghostty**: Kitty protocol  
- **Alacritty etc.**: usually no graphics protocol → blocks only, no pixel HD  
- **Inside tmux**: HD off by default; set `image.hd_tmux = true` / `graphics_tmux = true`  
- **SSH**: HD off by default; set `hd_ssh` / `graphics_ssh`

#### Full `setup` example

```lua
require("mdview").setup({
  split_direction = "right",
  width = 0.45,
  heading_conceal = true,
  list_bullets = { "●", "○" },
  toc = true,
  toc_min_level = 1,
  toc_max_level = 3,
  code_fold_lines = 10,
  code_highlight = "auto",
  code_line_numbers = true,
  sync_scroll = true,
  sync_cursor_block = true,
  sync_reverse = true,
  keys = {
    view = "<leader>mv",
    side = "<leader>ms",
    toc = "<leader>toc",
  },
  image = {
    mode = "thumb",
    max_height = 0,
    max_images = 20,
    backend = "auto",
    python = "python",
    open_with = "float",
    float_scale = "fit",     -- fit contain | fill stretch
    -- preview: no auto HD (scroll glitches); use gh temporarily
    hd = "never",
    float_hd = "always",
    hd_tmux = false,
    hd_ssh = false,
  },
  html = {
    img = true,
    details = true,
    details_default_open = false,
  },
})
```

Capability matrix:

| Capability | ① min | ② rec | ③ full |
|------------|:-----:|:-----:|:------:|
| Source/preview, TOC, tables, links, folds | ✓ | ✓ | ✓ |
| Tree-sitter code | — | ✓ | ✓ |
| Block-character images / float blocks | — | ✓ | ✓ |
| Float pixel HD (`gi`) | — | optional | ✓ |
| Temporary in-page HD (`gh`) | — | — | ✓ |
| Side `_` cursor, cross-file preview jumps | ✓ | ✓ | ✓ |

#### Smoke test

```vim
:e /path/to/nvimplugins/mdview/testdata/demo.md
:MdSideView
" in preview: ? help · t TOC · c copy code · gi image · gh in-page HD
```

```bash
python -c "from PIL import Image; print('Pillow OK')"
```

---

## Commands

| Command | Action |
|---------|--------|
| `:MdView` | Toggle source / preview in one window |
| `:MdSideView` | Toggle side preview (**one** preview window per tab) |
| `:MdSideView open` / `close` | Explicit open/close |
| `:MdViewRefresh` | Force re-render |
| `:MdViewSync` | Sync side preview to source cursor |
| `:MdViewToc` | Toggle TOC float (editor or preview) |
| `:MdViewPasteImage` | Save **clipboard image** as `images/yyyyMMddHHmmss.png` and insert `![](...)` |

With side open, switching to another **markdown** buffer in the same tab follows that file; non-md keeps the current preview.

## Preview keys

| Key | Action |
|-----|--------|
| `q` | Close preview / back to source |
| `r` | Refresh preview |
| (auto) | Reload source + re-render when the md file changes **on disk** and the buffer is not modified (`watch_external`) |
| `<CR>` | TOC / code fold / details / image / **md link → target preview** |
| `gi` | Image float |
| `gh` | Temporary in-page HD (cleared on scroll / focus / resize) |
| `o` | System-open image |
| `c` / `yc` | Copy code block under cursor |
| `gs` | Jump to source line |
| `go` | Top TOC in document |
| `t` | TOC float (preview only; editor uses `<leader>toc`) |
| `<C-o>` | Back: in-doc jump → previous md preview |
| `L` | Toggle Chinese / English UI (hint bar, help, Copy labels; persisted) |
| `?` | Help float |

## Editor (Markdown source)

Works without opening preview (auto-mapped on `markdown` buffers once the plugin loads):

| Key | Action |
|-----|--------|
| `<CR>` | On `![alt](path)` → image float; on `[text](url)` → jump (`#` anchor / external md **source** / web) |
| `Ctrl`+LeftMouse | Same |
| `<C-o>` | Jump back (Vim jumplist; in-doc anchors and external md) |
| `<CR>` elsewhere | Default Vim behavior |
| (auto) | **Non-cursor lines**: show `![alt](url)` as **`🖼 name`** (empty alt → `image`; full syntax on the cursor line). Disable with `source_image_conceal = false` |
| **`"+p`** / **`"+P`** | **Smart paste** (recommended): clipboard image → `images/yyyyMMddHHmmss.png` + `![image](images/...)`; otherwise normal text paste |
| **`Ctrl-Shift-v`** / **`Shift-Insert`** | Same (Shift-Insert also in insert mode) |
| `:MdViewPasteImage` | Image-only paste (notify if clipboard has no image) |

### Paste image

1. **Save** the markdown file first (directory is required)  
2. Copy a screenshot / image to the clipboard  
3. In normal mode press **`"+p`** (or `:MdViewPasteImage` / `Ctrl-Shift-v`)  
4. Creates `<md-dir>/images/`, writes `yyyyMMddHHmmss.png` (suffix `_2`… on collision), inserts e.g. `![image](images/20260721143005.png)`  

Requires **Python3 + Pillow** (same as block thumbnails).

#### Custom key (e.g. `Q`)

| Mapping | Image paste? | Notes |
|---------|:------------:|-------|
| `nmap Q "+p` | yes | recursive → hits mdview's `p` intercept |
| `nnoremap Q "+p` | **no** | non-recursive → builtin `p`, skips plugin |
| bind Lua | yes | best with `nnoremap` |

```vim
" A: recursive
nmap Q "+p

" B: noremap → call plugin (recommended)
nnoremap Q <Cmd>lua require('mdview').smart_clipboard_paste()<CR>
```

```lua
require("mdview").setup({
  paste_image = {
    enable = true,
    dir = "images",
    alt = "image",        -- ![image](...)
    intercept_clipboard_put = true, -- intercept p/P when register is +/*
    keys = {
      insert = { "<C-S-v>", "<S-Insert>" },
      normal = { "<C-S-v>" },
    },
  },
})
```

## Config notes

All defaults: `lua/mdview/config.lua`.

### Image behavior

- **In preview**: block characters only by default (`hd = "never"`); use **`gh`** for temporary HD  
- **float / `gi`**: blocks + optional pixel HD (`float_hd = "always"`)  
- **Paste**: clipboard image → `images/yyyyMMddHHmmss.png` + Markdown link  
- Needs **Pillow**; HD also needs a graphics-protocol terminal  

## Layout

```
mdview/
  plugin/mdview.lua
  lua/mdview/
  scripts/thumb.py
  scripts/gfx_prepare.py
  testdata/demo.md
  testdata/screenshots/
  README.md
  README.zh.md
```

## Related

- Repo overview: [English](../README.md) · [中文](../README.zh.md)
