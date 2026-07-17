# xlsview.nvim

**English** | [中文](README.zh.md)

Preview **Excel (.xlsx / .xlsm)** workbooks inside Neovim: grid, cell colors / bold / italic / fill, multi-sheet navigation, Excel-like cell motion and block yank.

Demo: [`testdata/demo.xlsx`](./testdata/demo.xlsx)

## Features

| Feature | Notes |
|---------|--------|
| Auto-open | Opening `.xlsx` / `.xlsm` enters preview (no hit-enter spam) |
| Styles | Font color, bold, italic, fill, alignment |
| Sheets | `n`/`p`, `]`/`[`, `gt`/`gT`, `1`-`9`, click tabs |
| Column width | **Natural width** by default; wide tables use **horizontal scroll** (not crushed to `…`) |
| Cell motion | Arrows / `hjkl` / `Tab` move by **cell** (Excel-like) |
| Cell block | `Ctrl-v` selects the **full current cell**; arrows grow by one cell |
| Yank | `y` after selection copies **cell text** (ignores `│`, Excel-like spacing) |
| Zip fix | Avoid zipPlugin treating xlsx as an archive |

## Dependencies

```bash
pip install openpyxl
```

## Install

```vim
Plug '/path/to/nvimplugins/xlsview'
```

```vim
:XlsView
:XlsViewRefresh
:XlsViewClose
```

## Keys

| Key | Action |
|-----|--------|
| `q` / `Esc` | Close |
| `r` | Re-extract |
| `n` / `]` / `gt` | Next sheet |
| `p` / `[` / `gT` | Prev sheet |
| `1`–`9` | Jump to sheet N |
| Click tab | Switch sheet |
| `↑` `↓` `←` `→` / `hjkl` | Adjacent cell |
| `Tab` / `S-Tab` | Next / prev cell (wrap row) |
| `0` / `$` | First / last cell in row |
| `Ctrl-v` (or `Ctrl-q`) | **Cell block**: select full current cell |
| In block `↑↓←→` / `hjkl` | Extend by **one cell** row/column |
| `y` / `Ctrl-c` | Yank selected **cells** (ignore `│`) |
| `v` / `V` | Normal char / line visual |
| `zh` / `zl` | Pan view (no cell jump) |
| `L` | UI language |
| `?` | Help |

### Block yank example

`Ctrl-v` rectangle then `y` (empty cells keep columns, like Excel):

```text
A01    2-1上装    40001
              40002
A02    1-1上装    40003
              40004
```

Border `│` in the selection is ignored.

## Config

```lua
require("xlsview").setup({
  auto_open = true,
  python = "python",
  max_rows = 500,
  max_cols = 64,
  table_style = "unicode",
  header_row = true,
  ui_lang = "auto", -- L
  -- Wide sheets: natural column widths + horizontal scroll (default)
  fit_to_window = false,
  min_col_width = 6,
  max_col_width = 28,
})
```

## Limits

- Legacy `.xls` not supported (save as xlsx)  
- Formulas: cached values when available  
- Large sheets capped by `max_rows` / `max_cols`  
- Merged cells: main cell value only  
