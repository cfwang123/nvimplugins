# httpbuf.nvim

[English](README.md) | **中文**

在 Neovim 里编辑 **HTTP 请求** 并查看响应：左请求 / 右响应，轻量 curl 或 Python 回退。

## 依赖

| 组件 | 说明 |
|------|------|
| Neovim 0.9+ | |
| **curl** 或 **Python3** | 优先 curl；否则 `scripts/http_req.py`（标准库 urllib） |

## 安装

```vim
Plug '/path/to/nvimplugins/httpbuf'
```

## 用法

| 操作 | 说明 |
|------|------|
| **`:HttpBuf`** / **`:Http`** | 打开编辑器（默认示例请求） |
| **`:HttpBuf GET https://example.com`** | 以参数为请求首行打开 |
| **`:HttpSend`** | 打开并用当前 buffer 内容发送 |
| **`<leader>http`** | 打开（可配置） |

### 请求格式

```http
GET https://httpbin.org/get
Accept: application/json
User-Agent: httpbuf

```

```http
POST https://httpbin.org/post
Content-Type: application/json

{"hello":"world"}
```

- 首行：`METHOD URL`（或仅 URL，默认 GET）
- 随后 `Header: value`
- 空行后为 body

### 按键

| 键 | 作用 |
|----|------|
| **`r`** / **`Ctrl-Enter`** | 发送 |
| `e` | 聚焦请求窗 |
| `y` | 复制响应正文 |
| **`L`** | 中/英文 |
| `q` / `Esc` | 关闭 |

## 配置

```lua
require("httpbuf").setup({
  python = "python",
  timeout = 30,
  prefer_curl = true,
  ui_lang = "auto",
  keys_open = "<leader>http",
})
```
