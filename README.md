# nvimplugins

**English** | [中文](README.zh.md)

> **About** — Small experimental Neovim plugins: **mdview** (Markdown preview), **music** (open audio and play in a buffer), **imgbuf** (terminal image preview), **nvimgames** (Minesweeper / Sokoban / 24-point / Tetris), **drawbuf** (Unicode block drawing). Each plugin installs independently; no hard dependencies.

Focused on fun, practical, low-dependency terminal tooling.

**Two install styles (pick one):**

| Style | Description |
|-------|-------------|
| **Whole repo (network)** | `Plug 'cfwang123/nvimplugins'` — clone from GitHub; root `plugin/nvimplugins.lua` loads every sub-plugin |
| **Per plugin (local path)** | Plug only the subfolders you need (e.g. `…/mdview`) |

## Plugins

| Plugin | Overview | Docs |
|--------|----------|------|
| **[mdview](mdview/)** | Markdown preview inside Neovim: single-window reading (`:MdView`) or side-by-side source (`:MdSideView`). Pure Lua rendering for headings/lists/GFM tables/code blocks (optional Tree-sitter), TOC, link & anchor jumps, images rendered with block characters, and optional terminal HD overlays. | [EN](mdview/README.md) · [中文](mdview/README.zh.md) |
| **[music](music/)** | Open an audio file and turn the buffer into a player: play/pause, scrubbable progress bar, volume, prev/next in the same folder, track list, LRC lyrics sync, session restore. Python daemon backend (`just_playback` / pygame); hide UI without stealing focus. | [EN](music/README.md) · [中文](music/README.zh.md) |
| **[imgbuf](imgbuf/)** | Open images as character-art previews (block / half / braille); fill or fit scaling; auto-open, clipboard, file-tree friendly; optional pixel HD overlay on WezTerm/Kitty/Ghostty (chafa or Python+Pillow). | [EN](imgbuf/README.md) · [中文](imgbuf/README.zh.md) |
| **[nvimgames](nvimgames/)** | Terminal mini-games: Minesweeper, Sokoban (bundled levels), 24-point poker, Tetris (special pieces + optional vs AI). Launch from `:NvimGames` float menu. | [EN](nvimgames/README.md) · [中文](nvimgames/README.zh.md) |
| **[drawbuf](drawbuf/)** | Draw with Unicode block characters in a buffer: pencil/eraser/line/rect/ellipse/fill, truecolor palette, clickable status bar, undo/redo, `.draw` files, and built-in demo pictures. | [EN](drawbuf/README.md) · [中文](drawbuf/README.zh.md) |

## Screenshots

| mdview (side) | music | imgbuf |
|:--------------:|:-----:|:------:|
| ![mdview](mdview/testdata/screenshots/1.png) | ![music](images/music.png) | ![imgbuf](images/imgbuf.png) |

| Minesweeper | Sokoban | 24-point | Tetris |
|:-----------:|:-------:|:--------:|:------:|
| ![mine](images/mine.png) | ![sokoban](images/sokoban.png) | ![24](images/twentyfour.png) | ![tetris](images/tetris.png) |

| drawbuf |
|:-------:|
| ![drawbuf](images/drawbuf.png) |

More mdview shots: [mdview/testdata/screenshots/](mdview/testdata/screenshots/) and demo [mdview/testdata/demo.md](mdview/testdata/demo.md).

## Dependencies (summary)

| Plugin | Neovim | Other |
|--------|--------|-------|
| mdview | 0.9+ | Core needs nothing extra; block-character images need Pillow (or chafa); code highlight optional Tree-sitter; pixel HD needs a graphics-protocol terminal |
| music | 0.9+ | Python3 + **just_playback** (or pygame fallback) |
| imgbuf | 0.9+ | chafa **or** Python3 + Pillow; HD needs WezTerm/Kitty/Ghostty + Pillow |
| nvimgames | 0.9+ | `termguicolors`; Minesweeper benefits from `mouse=a`; Sokoban ships `data/levels.json` |
| drawbuf | 0.9+ | `termguicolors`; `mouse=a` recommended |

## Quick install

**No** shared `setup()` is required (call `require(...).setup` only when tuning options).  
Do **not** mix whole-repo and per-plugin installs for the same plugins. Double-load is mostly guarded by `loaded_*`, but `rtp` would list paths twice.

### Style A: whole repo via vim-plug (network)

Recommended when you want **all** sub-plugins. GitHub: [cfwang123/nvimplugins](https://github.com/cfwang123/nvimplugins).

Root `plugin/nvimplugins.lua` adds each subfolder to `runtimepath` and sources their `plugin/` files.

#### vim-plug

```vim
call plug#begin()
Plug 'cfwang123/nvimplugins'
call plug#end()
```

Then run **`:PlugInstall`** once (or after updates: `:PlugUpdate`).

To enable only some plugins, set this **before** `plug#end()` (names match directory names):

```vim
let g:nvimplugins_enable = ['mdview', 'music', 'imgbuf']
call plug#begin()
Plug 'cfwang123/nvimplugins'
call plug#end()
```

#### lazy.nvim

```lua
{
  "cfwang123/nvimplugins",
  lazy = false,
  -- optional subset (must apply before plugin load; or use init)
  -- init = function()
  --   vim.g.nvimplugins_enable = { "mdview", "music", "imgbuf" }
  -- end,
}
```

### Style B: per plugin (local path)

Use when you only need a few plugins. Point `Plug` / `dir` at the cloned subfolders (or a local checkout).

#### vim-plug

```vim
call plug#begin()
Plug '/path/to/nvimplugins/mdview'
Plug '/path/to/nvimplugins/music'
Plug '/path/to/nvimplugins/imgbuf'
Plug '/path/to/nvimplugins/nvimgames'
Plug '/path/to/nvimplugins/drawbuf'
call plug#end()
```

#### lazy.nvim (example)

```lua
{
  { dir = "/path/to/nvimplugins/mdview", name = "mdview", lazy = false },
  { dir = "/path/to/nvimplugins/music", name = "music", lazy = false },
  { dir = "/path/to/nvimplugins/imgbuf", name = "imgbuf", lazy = false },
  { dir = "/path/to/nvimplugins/nvimgames", name = "nvimgames", lazy = false },
  { dir = "/path/to/nvimplugins/drawbuf", name = "drawbuf", lazy = false },
}
```

Per-plugin install details live in each subdirectory README (mdview has tiers ① minimal → ③ full).

### Optional `setup()` (per plugin)

**All optional.** Loading the plugin applies defaults (commands / auto-open work without any `setup`). Call `require("…").setup({ ... })` only when you want to override options. Place it **after** the plugin is on `rtp` (e.g. after `plug#end()`).

```lua
-- mdview — Markdown preview (see mdview/README for full options)
require("mdview").setup({
  split_direction = "right",
  width = 0.45,
  keys = { view = "<leader>mv", side = "<leader>ms" }, -- or false to disable
  image = {
    mode = "thumb",
    python = "python",
    float_hd = "always", -- pixel HD in float when terminal supports it
  },
})

-- music — buffer audio player
require("music").setup({
  volume = 70,
  auto_open = true,
  auto_play = true,
  toggle_key = "<M-m>", -- Alt+M show/hide
  statusline_when_hidden = false,
  python = "python",
})

-- imgbuf — image character art + optional HD overlay
require("imgbuf").setup({
  backend = "auto", -- "auto" | "chafa" | "python"
  mode = "block",   -- "block" | "half" | "braille"
  scale = "fill",   -- "fill" | "fit"
  hd = "always",    -- "always" | "never"
  auto_open = true,
})

-- nvimgames — mini-games
require("nvimgames").setup({
  mine = { difficulty = "beginner" }, -- beginner | intermediate | expert
  sokoban = { remember_level = true },
  twentyfour = { solvable_only = true },
  tetris = { special_score = 1000 },
})

-- drawbuf — Unicode block drawing
require("drawbuf").setup({
  width = 80,
  height = 24,
  canvas_bg = "ffffff",
  statusline = true,
})
```

Full option lists: each plugin’s README / `lua/*/init.lua` (mdview: `lua/mdview/config.lua`).

## Doc index

| Plugin | Entry |
|--------|-------|
| mdview | [EN](mdview/README.md) · [中文](mdview/README.zh.md) · [demo](mdview/testdata/demo.md) · [screenshots](mdview/testdata/screenshots/) |
| music | [EN](music/README.md) · [中文](music/README.zh.md) |
| imgbuf | [EN](imgbuf/README.md) · [中文](imgbuf/README.zh.md) |
| nvimgames | [EN](nvimgames/README.md) · [中文](nvimgames/README.zh.md) |
| drawbuf | [EN](drawbuf/README.md) · [中文](drawbuf/README.zh.md) |

## License / notes

Personal / prototype collection. Copy subfolders as needed. Prefer filing issues and changes under the matching plugin directory.
