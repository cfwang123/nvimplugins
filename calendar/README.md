# calendar.nvim

**English** | [中文](README.zh.md)

Terminal **month calendar float**: solar date, live clock, Chinese lunar date, solar terms / traditional & fixed holidays; month/year navigation, per-day notes and color marks.

## Requirements

| Component | Notes |
|-----------|--------|
| Neovim 0.9+ | **Pure Lua** — no Python / network |

Lunar data covers **1900–2100**. Notes and colors are stored in `stdpath("data")/calendar-nvim-notes.json`.

## Install

```vim
Plug '/path/to/nvimplugins/calendar'
" or the whole nvimplugins repo (calendar is enabled by default)
```

```lua
-- lazy.nvim monorepo
{ "cfwang123/nvimplugins", lazy = false }
```

## Quick start

1. **`<leader>cal`** or **`:Calendar`** opens the float  
2. **`h` / `l`** day, **`j` / `k`** week; **`[` / `]`** month, **`{` / `}`** year  
3. **`t`** today; **`n`** note; **`c`** cycle color mark; **`x`** clear note & mark  
4. **`L`** UI language; **`q`** close  

Each cell’s second line is a short lunar label (month name on the 1st). Holidays / solar terms take priority.

**Note marker**: days with a note show a trailing red **`●`** after the lunar/holiday label (light red on the blue selected cell). Appears after **`n`**; removed by **`x`**.

## Commands

| Command | Description |
|---------|-------------|
| **`:Calendar`** | Open month float |
| **`:CalendarClose`** | Close float |

## Default keys

| Key | Action |
|-----|--------|
| **`<leader>cal`** | Open calendar |
| **`h` `l`** / **← →** | Prev / next day |
| **`k` `j`** / **↑ ↓** | Prev / next week |
| **`[` `]`** or **`<` `>`** | Prev / next month |
| **`{` `}`** | Prev / next year |
| **`t`** | Today |
| **`n`** | Edit note (`vim.ui.input`) |
| **`c`** | Cycle color (red/orange/yellow/green/blue/purple/pink) |
| **`x`** | Clear note and mark |
| **`L`** | Language |
| **`q` / `Esc`** | Close |
| **Left mouse** | Select day (if mouse enabled) |

## Config

```lua
require("calendar").setup({
  ui_lang = "auto",       -- "auto" | "zh" | "en"
  border = "rounded",
  keys_open = "<leader>cal", -- false to disable
  clock_ms = 1000,        -- title clock refresh; 0 = off
})
```

## Notes

- **Holidays**: built-in fixed solar dates, traditional lunar festivals, and approximate 24 solar terms — not official workday adjustments.  
- **Highlight priority**: selected day (full-cell blue) > custom color mark (day number) > today > weekend/festival; note **`●`** stays red.  
- Highlights use UTF-8 byte columns so CJK lunar labels align with selection.  
- Language preference is saved under `stdpath("data")/calendar-nvim-prefs.json`.
