# es.nvim

**English** | [中文](README.zh.md)

Search files in Neovim via the **Everything** CLI (`es.exe`).

![es icon](../images/es.png)

## Requirements

| Component | Notes |
|-----------|--------|
| **Windows** | Everything is Windows-only |
| [Everything](https://www.voidtools.com/) | Must be running |
| [ES (CLI)](https://www.voidtools.com/support/everything/command_line_interface/) | `es.exe` on PATH or `es_cmd` |
| Neovim 0.9+ | |

## Install

```vim
Plug '/path/to/nvimplugins/es'
```

## Usage

| Action | Description |
|--------|-------------|
| **`<leader>es`** | Open picker |
| **`:ES`** / **`:Es`** | Open picker |
| **`:ES foo*.lua`** | Open with query |

On open, the **current working directory** is prefilled in **double quotes** with a trailing space, e.g.:

```text
🔍 "D:\VS_Projects\AIPrototype" 
```

(No trailing `\` — es CLI returns 0 hits for paths like `C:\Program Files\`.)

Type more keywords after the trailing space. Space-separated terms are **AND**ed, e.g.:

```text
"D:\proj\" README es
```

Clear with Backspace / `Ctrl-u` for whole-disk search.

### Input

| Key | Action |
|-----|--------|
| Printable chars | Insert at cursor |
| `←` / `→` or `Ctrl-b` / `Ctrl-f` | Move cursor |
| `Home` / `End` or `Ctrl-a` / `Ctrl-e` | Start / end of query |
| `<BS>` | Delete before cursor |
| `<Del>` | Delete after cursor |
| `<C-w>` | Delete previous word |
| `<C-u>` | Clear query |
| `<C-y>` | Paste |
| `<C-o>` | Edit full query in dialog |
| `<C-g>` | Refill current cwd |

### Results / other

| Key | Action |
|-----|--------|
| `↑` / `↓` | Select result |
| `<Tab>` | Toggle prompt / list focus |
| `<CR>` | Open |
| `<C-v>` / `<C-x>` / `<C-t>` | vsplit / split / tab |
| **`F2` / `Alt-s` / `Ctrl-s`** | **Toggle size column** (`s` when list is focused) |
| **`Ctrl-o`** | **Open with system** default app |
| **`Ctrl-p`** | **Copy path** to clipboard |
| **`Ctrl-r`** | **Reveal in Explorer** |
| Type directly | **Chinese IME works** (opens in insert mode) |
| **`L` / `Ctrl-l`** | **Toggle UI language** zh/en (system default; remembered) |
| `Esc` | Insert: leave input; Normal: close |
| `i` / `a` | Enter input mode from normal |
| `F3` | Edit full query in dialog |
| `<C-c>` | Close |

Long paths collapse middle folders to `...`.  
Results under the current pwd are shown **relative** (prefix stripped) and sorted **first**.  
Paths show an **emoji type icon** by extension.  
Size column is on by default (**F2** toggles). Matched terms are **highlighted**.

## Config

```lua
require("es").setup({
  es_cmd = "es",
  ui_lang = "auto",    -- "auto" | "zh" | "en"; L / Ctrl-l toggles & remembers
  max_results = 10000, -- virtual list: only visible rows are rendered
  keys_open = "<leader>es",
  files_only = true,
  prefill_cwd = true,
  show_size = true,
  open_cmd = "edit",
  icon = "🔍",
  extra_args = {},
  debounce_ms = 120,
  width = 0.85,
  height = 0.65,
  border = "rounded",
  encoding = "utf-8",
})
```

Legacy `cwd_only` maps to `prefill_cwd`.

## Notes

- Pipeline: `es.exe -size -export-csv` → temp UTF-8 file → open.
- **Windows only.** Ensure Everything is running.
