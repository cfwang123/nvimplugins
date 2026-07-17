# httpbuf.nvim

**English** | [中文](README.zh.md)

Edit **HTTP requests** and inspect responses in Neovim (request left / response right). Uses **curl** when available, else Python `urllib`.

## Requirements

| Component | Notes |
|-----------|--------|
| Neovim 0.9+ | |
| **curl** or **Python3** | Prefer curl; fallback `scripts/http_req.py` |

## Install

```vim
Plug '/path/to/nvimplugins/httpbuf'
```

## Usage

| Action | Description |
|--------|-------------|
| **`:HttpBuf`** / **`:Http`** | Open editor (sample request) |
| **`:HttpBuf GET https://example.com`** | Open with first line |
| **`:HttpSend`** | Open using current buffer as request |
| **`<leader>http`** | Open (configurable) |

### Request format

```http
GET https://httpbin.org/get
Accept: application/json

```

```http
POST https://httpbin.org/post
Content-Type: application/json

{"hello":"world"}
```

### Keys

| Key | Action |
|-----|--------|
| **`r`** / **`Ctrl-Enter`** | Send |
| `e` | Focus request |
| `y` | Copy response |
| **`L`** | Toggle language |
| `q` / `Esc` | Close |

## Config

```lua
require("httpbuf").setup({
  python = "python",
  timeout = 30,
  prefer_curl = true,
  ui_lang = "auto",
  keys_open = "<leader>http",
})
```
