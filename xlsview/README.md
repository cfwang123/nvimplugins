# xlsview.nvim

**English** | [中文](README.zh.md)

Preview **Excel (.xlsx / .xlsm)** workbooks inside Neovim: grid, cell colors / bold / italic / fill, multi-sheet navigation.

Demo: [`testdata/demo.xlsx`](./testdata/demo.xlsx)

## Features

| Feature | Notes |
|---------|--------|
| Auto-open | Opening `.xlsx` / `.xlsm` enters preview |
| Styles | Font color, bold, italic, fill, alignment |
| Sheets | `n`/`p`, `]`/`[`, `gt`/`gT`, `1`-`9`, click tabs |
| Width | Columns fit the window |
| Zip fix | Avoid zipPlugin treating xlsx as archive |

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
| `?` | Help |

## Config

```lua
require("xlsview").setup({
  auto_open = true,
  python = "python",
  max_rows = 500,
  max_cols = 64,
  table_style = "unicode",
  header_row = true,
})
```

## Limits

- Legacy `.xls` not supported (save as xlsx)  
- Formulas: cached values when available  
- Large sheets capped by `max_rows` / `max_cols`  
