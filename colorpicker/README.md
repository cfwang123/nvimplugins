# colorpicker.nvim

**English** | [中文](README.zh.md)

Terminal **HSV color picker** float: SV plane + H/S/V/A sliders (truecolor). On confirm, **inserts or replaces** a CSS color. In-buffer **`██`** swatches; **click the `#` of a hex color** to open the picker.

## Requirements

| Component | Notes |
|-----------|--------|
| Neovim 0.9+ | **Pure Lua** — no Python / network |
| `termguicolors` | Enabled automatically on open |

## Install

```vim
Plug '/path/to/nvimplugins/colorpicker'
" or whole-repo nvimplugins (includes colorpicker by default)
```

```lua
{ "cfwang123/nvimplugins", lazy = false }  -- lazy.nvim whole repo
```

## Quick start

1. **`<leader>co`** or **`:ColorPicker`**  
2. **Hue**: **`[`/`]`** or **`,`/`.`** step **1 H-bar cell** (wraps between 0° and the rightmost cell)  
3. **SV plane**: **`h`/`l`** one S column, **`j`/`k`** one V row; or click  
4. **Alpha A** (default 100%): **`5`** / **`a`** then **`h`/`l`** or click the A bar  
5. **`Tab`** format; **`Enter`** / **double-click** finish; **`y`** yank; **`q`** cancel; **`L`** language  

If the cursor is on `#rrggbb` / `rgb()` / `hsl()` etc., that token is loaded and **replaced** on confirm. Visual selection of UI text is disabled inside the float.

### Keyboard steps (by **cell**, not 1% / 1°)

| Keys | Step |
|------|------|
| **`h` `l`** / **← →** | Focused channel **1 cell** (S column on plane) |
| **`j` `k`** / **↓ ↑** | On plane: V **1 row**; on bars: cycle focus |
| **`[` `]`** / **`,` `.`** | Hue **1 H-bar cell**; **`[`** at leftmost → rightmost, **`]`** at rightmost → leftmost |
| **`+/-`** / **`{}`** / **`<>`** / **Shift+arrows** | Coarse (default **5 cells**) |

Steps align to `plane_w` / `plane_h` / `bar_w`; values snap to grid.

### In-buffer preview

- **`██`** left of each CSS color (display only; **no** background on the code text)  
- **Click hex `#`** (on mouse release) → open picker bound to replace  
- Clicking hex digits or `rgb(...)` text does **not** open the picker  
- Does **not** block mouse-drag visual selection  
- **`:ColorPickerPreview`** manual refresh; large files scan the visible range  

## Commands

| Command | Description |
|---------|-------------|
| **`:ColorPicker`** `[format]` | Open; optional `hex` / `rgb` / `rgba` / `hsl` / `hsla` / `hex_alpha` |
| **`:Colorpicker`** | Alias |
| **`:ColorPickerClose`** | Close float |
| **`:ColorPickerPreview`** | Refresh `██` swatches |

## Default keys

| Key | Action |
|-----|--------|
| **`<leader>co`** | Open picker |
| **`,` `.`** / **`[` `]`** | Hue 1 cell (wrap) |
| **`<` `>`** / **`{` `}`** | Hue coarse (default 5 cells) |
| **`h` `l`** / **← →** | Channel 1 cell |
| **`j` `k`** / **↓ ↑** | Plane V 1 row / cycle focus |
| **`+/-`** / **Shift+←→** | Coarse 5 cells |
| **`1`–`5`** / **`a`** / **`Space`** | Focus H/S/V/plane/A; cycle |
| **`Tab`** / **`f`** | Next CSS format |
| **`Enter`** | Insert or replace and close |
| **`y`** | Yank (keep open) |
| **`w` / `b` / `r`** | White / black / reset |
| **`L`** | Language |
| **`q` / `Esc`** | Cancel |
| **Left click** | Pick on plane / bars |
| **Double-click** | Confirm |
| **Click in-buffer `#`** | Open and replace that hex |

## Config

```lua
require("colorpicker").setup({
  ui_lang = "auto",            -- "auto" | "zh" | "en"
  border = "rounded",
  keys_open = "<leader>co",    -- false to disable
  default_format = "hex",      -- hex | rgb | rgba | hsl | hsla | hex_alpha
  default_h = 210,
  default_s = 0.75,
  default_v = 0.9,
  default_a = 1,               -- opacity 100%
  plane_w = 28,
  plane_h = 10,
  bar_w = 36,
  step_h_coarse = 5,           -- hue coarse cells
  step_sv_coarse = 5,          -- S/V/A coarse cells (fine = always 1 cell)
  parse_under_cursor = true,
  replace_under_cursor = true,
  yank_also = false,
  preview = true,              -- in-buffer ██
  preview_auto = true,
  preview_max_lines = 4000,
  preview_filetypes = nil,     -- e.g. { "css", "html" }; nil = all
})
```

## Output examples

| Format | Example |
|--------|---------|
| `hex` | `#2e7d32` |
| `hex_alpha` | `#2e7d32ff` |
| `rgb` | `rgb(46, 125, 50)` |
| `rgba` | `rgba(46, 125, 50, 1)` |
| `hsl` | `hsl(123, 46%, 34%)` |
| `hsla` | `hsla(123, 46%, 34%, 1)` |

When `a<1`: `hex`→`hex_alpha`, `rgb`→`rgba`, `hsl`→`hsla`.

## Notes

- Interaction is **HSV**; CSS `hsl`/`hsla` is standard **HSL**.  
- Rightmost hue cell is stored as **360°** (same color as 0°); marker sits on the right; **`[`** at 0° jumps there.  
- Swatches use a **fixed pool** of highlight groups, recolored with `set_hl` — avoids **E849 Too many highlight groups**.  
- Language prefs: `stdpath("data")/colorpicker-nvim-prefs.json`.  
- Truecolor terminal recommended (`termguicolors`).
