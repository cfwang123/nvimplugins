# bookmarks

**English** | [中文](README.zh.md)

File/folder **bookmarks** sidebar (right split). Open files; open dirs with **NERDTree** / Neotree and `cd`.  
Storage is compatible with the Vim `vimplugins` plugin: default file is `stdpath("data")/vimplugins/bookmarks.txt`.

## Requirements

| Component | Notes |
|-----------|--------|
| Neovim 0.9+ | Pure Lua |
| NERDTree / Neotree | Optional for directories |

## Install

```vim
Plug '/path/to/nvimplugins/bookmarks'
" or whole-repo nvimplugins (includes bookmarks by default)
```

```lua
{ "cfwang123/nvimplugins", lazy = false }
```

## Keys

| Key | Action | Scope |
|-----|--------|--------|
| `<leader>bo` | Open bookmarks on the right | Global |

**Sidebar only** (buffer-local; does not affect edit windows):

| Key | Action |
|-----|--------|
| `o` / `Enter` | Open file; dir → NERDTree/Neotree + `cd` |
| `t` | Open in new tab |
| `S` | Toggle full path / short name (dedupe via common prefix) |
| `dd` | Remove entry |
| `A` / `D` | Add file/dir from previous buffer |
| `r` | Reload |
| `q` / `Esc` | Close |

> From an edit window, use `:BookmarksAddFile` / `:BookmarksAddDir`, or set `keys_add_file` / `keys_add_dir` in setup.

## Config

```lua
require("bookmarks").setup({
  width = 36,
  -- keys_open = "<leader>bo",
  -- Optional global add keys (off by default so A/D stay as Neovim defaults):
  -- keys_add_file = "<leader>ba",
  -- keys_add_dir = "<leader>bd",
  -- no_mappings = true,  -- disable all default global maps
})
```

## Commands

- `:BookmarksOpen` / `:BookmarksToggle` / `:BookmarksClose`
- `:BookmarksAddFile` / `:BookmarksAddDir`
- `:BookmarksRefresh`
