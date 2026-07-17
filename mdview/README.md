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
| Style | Headings (optional auto numbers), bold, italic, `` code ``, strike, `==mark==`, links |
| Lists / quotes / HR / tables | GFM tables; dynamic columns; images in cells; escaped `\|` |
| Code blocks | Border, language, line numbers, gray bg, fold after 10 lines, **`c` / `yc` / [Copy]**, TS→syntax→plain |
| TOC | Top of preview; `t` opens TOC float |
| Links | Enter/click; `#heading` / `#1. heading` anchors; md files → target preview; `Ctrl-o` back |
| Images | Block-character render in preview; `gi`/Enter float; `gh` temporary in-page HD; `o` system open |
| HTML | `<details>` / `<summary>`, `<img>` |
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
" or whole-repo: Plug '/path/to/nvimplugins' (see repo root README)
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

Disable default keys:

```lua
require("mdview").setup({
  keys = { view = false, side = false },
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
  },
  image = {
    mode = "thumb",          -- block-character images in preview
    python = "python",
    open_with = "float",
    float_hd = "never",      -- tier ②: blocks only in float first
    float_scale = "fill",
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
| (Optional) chafa | Alternate backend when `image.backend = "auto"` |

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
  },
  image = {
    mode = "thumb",
    max_height = 0,
    max_images = 20,
    backend = "auto",
    python = "python",
    open_with = "float",
    float_scale = "fill",
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

With side open, switching to another **markdown** buffer in the same tab follows that file; non-md keeps the current preview.

## Preview keys

| Key | Action |
|-----|--------|
| `q` | Close preview / back to source |
| `r` | Refresh |
| `<CR>` | TOC / code fold / details / image / **md link → target preview** |
| `gi` | Image float |
| `gh` | Temporary in-page HD (cleared on scroll / focus / resize) |
| `o` | System-open image |
| `c` / `yc` | Copy code block under cursor |
| `gs` | Jump to source line |
| `go` | Top TOC in document |
| `t` | TOC float |
| `<C-o>` | Back: in-doc jump → previous md preview |
| `?` | Help float |

## Config notes

All defaults: `lua/mdview/config.lua`.

### Image behavior

- **In preview**: block characters only by default (`hd = "never"`); use **`gh`** for temporary HD  
- **float / `gi`**: blocks + optional pixel HD (`float_hd = "always"`)  
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
