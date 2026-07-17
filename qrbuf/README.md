# qrbuf.nvim

**English** | [中文](README.zh.md)

Encode text as a **QR code** and show it in a Neovim float using Unicode half-block characters.

## Requirements

| Component | Notes |
|-----------|--------|
| Neovim 0.9+ | |
| **Python3** | stdlib only (`scripts/qrgen.py`) |

## Install

```vim
Plug '/path/to/nvimplugins/qrbuf'
```

## Usage

| Action | Description |
|--------|-------------|
| **`:QrBuf`** / **`:QR`** | Current line → QR |
| **`:QrBuf text`** | Explicit text |
| **Visual + `:QrBuf`** | Selection |
| **`<leader>qr`** | Configurable map |

### Keys

| Key | Action |
|-----|--------|
| `q` / `Esc` | Close |
| `y` | Copy source text |
| `+` / `-` | Zoom |
| **`L`** | Toggle UI language |

## Config

```lua
require("qrbuf").setup({
  python = "python",
  zoom = 1,
  invert = false,
  ui_lang = "auto",
  keys_open = "<leader>qr",
})
```

## Notes

- Uses [Nayuki QR-Code-generator](https://github.com/nayuki/QR-Code-generator) (MIT), vendored as `scripts/qrcodegen.py`.
- 4-module quiet zone; black modules on white float (`█▀▄`).
