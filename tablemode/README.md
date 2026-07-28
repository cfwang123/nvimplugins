# tablemode.nvim

**English** | [中文](README.zh.md)

A **Markdown / GFM table mode** inspired by [vim-table-mode](https://github.com/dhruvasagar/vim-table-mode): live-align on `|`, Tableize from CSV, cell motions, insert/delete columns.

> Module name is **`tablemode`** so it never shadows Lua’s built-in `table` library.

## Requirements

| Component | Notes |
|-----------|--------|
| Neovim 0.9+ | Pure Lua; no Python or external tools |

## Install

```vim
Plug '/path/to/nvimplugins/tablemode'
" or whole-repo nvimplugins (includes tablemode by default)
```

```lua
-- lazy.nvim whole repo
{ "cfwang123/nvimplugins", lazy = false }
```

## Quick start

1. **`<leader>tm`** or **`:TableModeToggle`**  
2. In insert mode type:

```text
| name | address | phone |
||
```

`||` on the second line expands to a header separator; further `|` keystrokes realign the table:

```text
| name            | address                  | phone      |
|-----------------|--------------------------|------------|
| John Adams      | 1600 Pennsylvania Avenue | 0123456789 |
| Sherlock Holmes | 221B Baker Street        | 0987654321 |
```

3. While typing inside a cell, the table **live-realigns** (debounced, default ~60ms); one more pass on InsertLeave.  
4. While mode is on, **header rows** get a background and **borders** (`|` / separator lines) are colored.  
5. Toggle off with **`<leader>tm`**. Manual realign: **`<leader>tr`** / **`:TableModeRealign`**.

## Commands

| Command | Description |
|---------|-------------|
| **`:TableModeToggle`** | Toggle table mode for the current buffer |
| **`:TableModeEnable`** / **`:TableModeDisable`** | Enable / disable |
| **`:TableModeRealign`** | Realign the table under the cursor |
| **`:Tableize`** | Convert current line or visual range into a table (default `,`) |
| **`:Tableize/;`** or **`:Tableize ;`** | Use a custom delimiter |

## Default keys

| Key | Action |
|-----|--------|
| **`<leader>tm`** | Toggle table mode |
| **`<leader>tr`** | Realign |
| **`<leader>tt`** | Tableize (line / visual) |
| **`<leader>T`** | Tableize with delimiter prompt |
| **`<leader>tdd`** | Delete row(s) (`[count]`) |
| **`<leader>tdc`** | Delete column(s) |
| **`<leader>tic`** | Insert column after cursor |
| **`<leader>tiC`** | Insert column before cursor |

### While mode is on (buffer-local)

| Key | Action |
|-----|--------|
| **`|`** (insert) | Insert bar + realign; bare `||` → separator row |
| **`Tab` / `Shift-Tab`** | Next / previous cell (skip separators; Tab on last cell appends a row) |
| **`←` `→` `↑` `↓` / `hjkl` (normal)** | One cell at a time; **at edge, further press exits** the table (default motion) |
| **`Ctrl-v` (or `Ctrl-q`)** | **Cell block select**: enters with at least the **current cell** selected |
| **`hjkl` / arrows in block select** | Expand by **one column / row** of cells (skips separator rows) |
| **`y` / `Ctrl-c` after selection** | Yank as **Excel-style TSV** (tab-separated, strips `\|`) |
| **`]|` / `[|`** | Next / previous cell (wraps across rows) |
| **`}|` / `{|`** | Cell below / above |
| **`i|` / `a|`** | Cell text objects |

### Block yank example

`Ctrl-v` a cell rectangle inside the table, then `y`:

```text
| name            | address                  | phone      |
|-----------------|--------------------------|------------|
| John Adams      | 1600 Pennsylvania Avenue | 0123456789 |
| Sherlock Holmes | 221B Baker Street        | 0987654321 |
```

Clipboard (tabs between columns — paste into Excel):

```text
John Adams	1600 Pennsylvania Avenue	0123456789
Sherlock Holmes	221B Baker Street	0987654321
```

## Alignment

Use `:` in the separator row (GFM style):

```text
| left | center | right |
|:-----|:------:|------:|
| a    | b      |     c |
```

## Statusline

When enabled:

- `vim.b.tablemode == true`
- `vim.g.tablemode_status == "TABLE"`

```vim
set statusline+=%{get(g:,'tablemode_status','')}
```

## Config

```lua
require("tablemode").setup({
  corner = "|",
  corner_corner = "|",     -- use "+" for |---+---|
  fillchar = "-",
  header_fillchar = "-",
  align_char = ":",
  delimiter = ",",
  tableize_header_sep = true,
  auto_align = true,              -- master switch for | and live align
  auto_align_live = true,         -- realign while editing cell text
  auto_align_ms = 60,             -- debounce ms; 0 = immediate; raise for IME
  auto_align_on_insert_leave = true,
  smart_syntax = true,            -- markdown / rst corner presets
  ui_lang = "auto",
  keys_toggle = "<leader>tm",
  keys_realign = "<leader>tr",
  keys_tableize = "<leader>tt",
  keys_tableize_op = "<leader>T",
  keys_delete_row = "<leader>tdd",
  keys_delete_col = "<leader>tdc",
  keys_insert_col_after = "<leader>tic",
  keys_insert_col_before = "<leader>tiC",
  map_motions = true,
  map_text_objects = true,
  map_tab = true,          -- Tab / Shift-Tab between cells
  tab_normal = false,      -- also map Tab in normal (steals <C-i> jumplist)
  tab_insert_row = true,   -- Tab on last cell appends empty row
  map_arrows = true,       -- arrows by cell; edge exits table
  map_hjkl = true,         -- same for hjkl
  map_vblock = true,       -- Ctrl-v cell block; visual hjkl expand; y → TSV
  highlight = true,        -- header bg + border colors while mode is on
  hl_header = "TableModeHeader",
  hl_border = "TableModeBorder",
  highlight_ms = 80,
})
```

Set any key to `false` to disable it.

### Highlight groups

| Group | Role | Default |
|-------|------|---------|
| **`TableModeHeader`** | Header **cell text** background only (not spaces / `\|`) | pale blue bg `#6b8fb5` |
| **`TableModeBorder`** | Borders: `\|` and separator `-` `:` `=` `+` | blue fg + **bold** |

Override with `hi TableModeHeader ...` / `hi TableModeBorder ...` (`default` links — your definitions win).

## vs vim-table-mode

| Topic | This plugin |
|-------|-------------|
| Implementation | Pure Lua |
| Spreadsheet formulas | **Not implemented** |
| yes/no cell highlights | **Not implemented** |
| Default corners | GFM `\|` (not `+`) |
| Module name | `tablemode` |

## Notes

- A table is a run of consecutive lines containing `|`.
- Column width uses `strdisplaywidth` (CJK-friendly).
- Works well with **mdview**: edit in the source buffer, preview rendered GFM tables.
