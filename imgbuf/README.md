# imgbuf.nvim

**English** | [中文](README.zh.md)

Preview images in Neovim: default **character art + HD overlay** (auto-detected on WezTerm/Kitty/Ghostty; other terminals show character art only).

Pixels are **not** turned into individual highlight groups, so you avoid `E849: Too many highlight and syntax groups`.

![imgbuf screenshot](../images/imgbuf.png)

## Features

- **block / half / braille** glyph modes (default **block**)
- **Scale**: default **fill**; press `s` for **fit** inside the window (press again to fill)
- Bottom key hints
- **Auto preview**: `:e photo.png` / open from a file tree
- **Clipboard**: `:ImgbufClipboard`
- Debounced redraw on resize; read-only; scroll locked
- **File-tree friendly** (NERDTree / NvimTree / neo-tree)
- **HD on by default** (`hd = "always"`): pixel overlay when the terminal supports it (WezTerm/Kitty/Ghostty + Pillow); otherwise character art only

## Dependencies

| Component | Requirement |
|-----------|-------------|
| Neovim | 0.9+ (0.10+ recommended) |
| Character art | chafa **or** Python 3 + Pillow |
| HD overlay | WezTerm / Kitty / Ghostty + **Pillow** (`hd=always` default) |

**chafa (recommended)**: `scoop install chafa`  
**HD / Python art**: `pip install Pillow`

## Install (vim-plug)

Use your local path.

**No** `require('imgbuf').setup()` is required: defaults apply on load.  
Call `setup({ ... })` only to override options.

```vim
call plug#begin()
Plug '/path/to/nvimplugins/imgbuf'
call plug#end()

" optional
" lua require('imgbuf').setup({ backend = 'chafa' })
```

## Usage

```vim
:e photo.png
:Imgbuf path/to/image.png
:ImgbufClipboard
:ImgbufMode block
:ImgbufRefresh
:ImgbufScale           " toggle fit/fill
:ImgbufScale fit
:ImgbufScale fill
```

| Key | Action |
|-----|--------|
| `q` | Close |
| `r` | Refresh |
| `1` | block art |
| `2` | half (`▀`) |
| `3` | braille |
| `s` | fill ↔ fit |
| `o` | Open original with the system handler |

| Scale | Meaning |
|-------|---------|
| **fill** (default) | Stretch to window (may distort) |
| **fit** | Letterbox/center inside the window; HD overlay aligns with the art |

## Config (optional)

```lua
require("imgbuf").setup({
  backend = "auto",   -- "auto" | "chafa" | "python"
  mode = "block",     -- "block" | "half" | "braille"
  scale = "fill",     -- "fill" | "fit" (toggle with s)
  hd = "always",      -- overlay when supported; "never" to disable
  -- hd_tmux = true,
  show_help = true,
  auto_open = true,
})
```

Default **`hd = "always"`**: on graphics-protocol terminals, a pixel image is layered on top of the character art (needs Pillow). Unsupported terminals show art only. Use `hd = "never"` to force that off.

Later `setup` calls merge on top of defaults.

## How it works

1. Open a **terminal buffer** in the edit area for character art (chafa / `render.py`)
2. If `hd` is on and supported: host TTY overlays iTerm2/Kitty pixel graphics
3. File-tree friendly: reclaim accidental vsplits

## Layout

```
imgbuf/
  plugin/imgbuf.lua
  lua/imgbuf/init.lua
  lua/imgbuf/graphics.lua
  scripts/render.py
  scripts/gfx_prepare.py
  README.md
  README.zh.md
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| No color | Truecolor terminal / `termguicolors` |
| Fail to start | Check chafa or `pip install Pillow` |
| Braille glyphs | `:ImgbufMode block` or press `1` |
| Extra NERDTree column | Update plugin; text `o` should replace preview |

## Related

- Repo overview: [English](../README.md) · [中文](../README.zh.md)
- Drawing plugin: [English](../drawbuf/README.md) · [中文](../drawbuf/README.zh.md)
