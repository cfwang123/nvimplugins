# tablemode.nvim

**English** | [中文](README.zh.md)

A **Markdown / GFM table mode** inspired by [vim-table-mode](https://github.com/dhruvasagar/vim-table-mode): live align, cell motions, block select & TSV yank. While mode is on, tables render as **mdview-style Unicode boxes**; leaving mode or saving restores standard `| --- |` ASCII.

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

1. Write a GFM table (or start with `|`), then **`<leader>tm`** / **`:TableModeToggle`**.  
2. **With mode on**, the table becomes an editable mdview-style box:

```text
┌──────────────────┬──────────────────────────┬────────────┐
│ name             │ address                  │ phone      │
├──────────────────┼──────────────────────────┼────────────┤
│ John Adams       │ 1600 Pennsylvania Avenue │ 0123456789 │
│ Sherlock Holmes  │ 221B Baker Street        │ 0987654321 │
└──────────────────┴──────────────────────────┴────────────┘
```

3. Typing in a cell **live-realigns** the table (debounced, default ~60ms); one more pass on InsertLeave.  
4. Toggle **`<leader>tm`** again to leave: restore GFM ASCII and clear highlights.

```text
| name             | address                  | phone      |
| ---------------- | ------------------------ | ---------- |
| John Adams       | 1600 Pennsylvania Avenue | 0123456789 |
| Sherlock Holmes  | 221B Baker Street        | 0987654321 |
```

5. Manual realign: **`<leader>tr`** / **`:TableModeRealign`**.

### Draw a table from scratch (insert)

```text
| name | address | phone |
||
```

`||` on the second line expands to a header separator; further `|` keystrokes realign. With `preview_style = "unicode"`, `|` inserts `│`.

## Unicode preview ↔ GFM restore

| When | Behavior |
|------|----------|
| **Enable tablemode** | Buffer tables → Unicode boxes (`┌─┬─┐` / `│` / `├─┼─┤` / `└─┴─┘`) |
| **Edit / realign** | Always reformat in the current style (boxes by default) |
| **Disable tablemode** | Boxes → standard GFM `\| --- \|` |
| **`:w` save** | Convert to GFM for disk; if mode stays on, restore box preview after write |

- On disk you always get **standard Markdown tables** (alignment `:---` / `:---:` / `---:` is preserved).  
- Alignment is stored in the mid-border cells and written back on restore.  
- Set `preview_style = "gfm"` to keep ASCII while mode is on.  
- Default `disable_conceal = true`: while on, `conceallevel=0` so hidden `**bold**` markers do not shift pipes; restored on exit.

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

Tableize / delete-insert row-col keys are **off by default**; set `keys_*` in `setup` if you want them.

### While mode is on (buffer-local)

| Key | Action |
|-----|--------|
| **`|`** (insert) | Insert bar + realign (writes `│` in unicode preview); after header, bare `||` → separator/mid border; **below a complete table**, `|` appends an empty data row |
| **`Tab` / `Shift-Tab`** | Next / previous cell (skip frames & seps; Tab on last cell appends a row) |
| **`←` `→` `↑` `↓` / `hjkl` (normal)** | One cell at a time; **at edge, further press exits** the table |
| **`Ctrl-v` (or `Ctrl-q`)** | **Cell block select**: at least the **current cell** |
| **`hjkl` / arrows in block select** | Expand by **one column / row** of cells |
| **`gy` (visual)** | Yank **Excel-style TSV** (tabs, strips bars); plain **`y`** is unchanged |
| **`]|` / `[|`** | Next / previous cell (wraps across rows) |
| **`}|` / `{|`** | Cell below / above |
| **`i|` / `a|`** | Cell text objects |

### Block yank example

`Ctrl-v` a cell rectangle, then `gy`:

```text
│ name            │ address                  │ phone      │
│ John Adams      │ 1600 Pennsylvania Avenue │ 0123456789 │
│ Sherlock Holmes │ 221B Baker Street        │ 0987654321 │
```

Clipboard (tabs — paste into Excel):

```text
John Adams	1600 Pennsylvania Avenue	0123456789
Sherlock Holmes	221B Baker Street	0987654321
```

## Alignment

`:` in the GFM separator (kept after exit):

```text
| left | center | right |
|:-----|:------:|------:|
| a    | b      |     c |
```

Unicode mid-borders carry the same alignment markers while mode is on.

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
  keys_tableize = false,           -- e.g. "<leader>tt"
  keys_tableize_op = false,        -- e.g. "<leader>T"
  keys_delete_row = false,         -- e.g. "<leader>tdd"
  keys_delete_col = false,         -- e.g. "<leader>tdc"
  keys_insert_col_after = false,   -- e.g. "<leader>tic"
  keys_insert_col_before = false,  -- e.g. "<leader>tiC"
  map_motions = true,
  map_text_objects = true,
  map_tab = true,          -- Tab / Shift-Tab between cells
  tab_normal = false,      -- also map Tab in normal (steals <C-i> jumplist)
  tab_insert_row = true,   -- Tab on last cell appends empty row
  map_arrows = true,       -- arrows by cell; edge exits table
  map_hjkl = true,         -- same for hjkl
  map_vblock = true,       -- Ctrl-v cell block; visual hjkl expand; gy → TSV
  highlight = true,        -- header bg + border colors while mode is on
  hl_header = "TableModeHeader",
  hl_border = "TableModeBorder",
  highlight_ms = 80,
  preview_style = "unicode", -- mdview boxes while on; "gfm" keeps | --- |
  disable_conceal = true,  -- conceallevel=0 while on (avoid ** misalignment)
})
```

Set any `keys_*` to `false` to disable it.

### Highlight groups

| Group | Role | Default |
|-------|------|---------|
| **`TableModeHeader`** | Header **cell text** background only (not padding / bars) | very light blue bg `#e3f0fb` |
| **`TableModeBorder`** | Bars: `\|` `-` `:` `=` `+` and Unicode `─` `│` `┌┐└┘├┤┬┴┼` | blue fg + **bold** |

Override with `hi TableModeHeader ...` / `hi TableModeBorder ...`.

### ReST style

```lua
require("tablemode").setup({
  corner = "|",
  corner_corner = "+",
  header_fillchar = "=",
  smart_syntax = true, -- also auto for filetype=rst
  preview_style = "gfm", -- usually no unicode boxes for ReST
})
```

### Disable box preview

```lua
require("tablemode").setup({
  preview_style = "gfm", -- keep | --- | while mode is on
})
```

## vs vim-table-mode

| Topic | This plugin |
|-------|-------------|
| Implementation | Pure Lua |
| Look while on | **Unicode boxes** by default (optional); restore GFM on exit |
| Spreadsheet formulas | **Not implemented** |
| yes/no cell highlights | **Not implemented** |
| Default corners | GFM `\|` (not `+`) |
| TSV yank | Visual **`gy`** (plain `y` unchanged) |
| Module name | `tablemode` |

## Notes

- A table is a run of consecutive lines containing `|` or Unicode box characters.  
- Column width uses `strdisplaywidth` (CJK-friendly).  
- Works well with **mdview**: edit in the source buffer, preview rendered GFM.  
- On save, the buffer briefly becomes GFM for the write, then restores boxes if mode is still on (`modified` cleared after restore).
