# ntemoji

**English** | [中文](README.zh.md)

Emoji icons for **NERDTree** — no Nerd Font, no **vim-devicons**.

Uses NERDTree’s official `PathNotifier` + `flagSet` (same hook as webdevicons), with plain emoji that work under **Consolas** and most terminal fonts.

## Requirements

| Component | Notes |
|-----------|--------|
| Neovim 0.9+ | |
| [NERDTree](https://github.com/preservim/nerdtree) | Must be installed |
| **Do not** load `ryanoasis/vim-devicons` | Double icons / conflicts |

## Install

```vim
Plug '/path/to/nvimplugins/ntemoji'
" or whole-repo:
" Plug 'cfwang123/nvimplugins'
```

## Usage

No setup required. Open NERDTree (`:NERDTree`) — files/folders get emoji flags.

```lua
require("ntemoji").setup({
  folder_closed = "📁",
  folder_open = "📂",
  default_file = "📄",
  extension = {
    md = "📝",
    json = "📋",
    tutor = "📘",
    -- merge with defaults
  },
  exact = {
    [".gitignore"] = "🙈",
  },
})
```

## Defaults (sample)

| Kind | Emoji |
|------|--------|
| Folder | 📁 / 📂 |
| Default file | 📄 |
| `.md` | 📝 |
| `.json` | 📋 |
| `.tutor` | 📘 |
| images | 🖼️ |
| archives | 📦 |

## Notes

- NERDTree always wraps flags as `[…]`. ntemoji **conceals** those brackets by default (`conceal_brackets = true`).
- **Auto-disable**: if **vim-devicons** is loaded or present on `runtimepath`, ntemoji **does not enable** (no flags, no conceal). Remove `Plug 'ryanoasis/vim-devicons'` to use ntemoji.
  - Optional: `let g:ntemoji_notify_skip = 1` to print a one-line notice when skipped.
  - Force (not recommended): `let g:ntemoji_force = 1`.
- Airline statusline icons are **not** handled here (by design).
- Whole-repo bundle includes `ntemoji` by default (`plugin/nvimplugins.lua`).

## Layout

```
ntemoji/
  plugin/ntemoji.lua
  lua/ntemoji/init.lua
  autoload/ntemoji.vim
  nerdtree_plugin/ntemoji.vim
  README.md
  README.zh.md
```
