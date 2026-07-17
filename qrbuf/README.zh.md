# qrbuf.nvim

[English](README.md) | **中文**

将文本编码为 **二维码**，在 Neovim 浮窗中以 Unicode 半块字符显示（可手机扫码，视终端字体而定）。

## 依赖

| 组件 | 说明 |
|------|------|
| Neovim 0.9+ | |
| **Python3** | 标准库即可（内置 `scripts/qrgen.py`） |

## 安装

```vim
Plug '/path/to/nvimplugins/qrbuf'
" 或整仓 nvimplugins
```

## 用法

| 操作 | 说明 |
|------|------|
| **`:QrBuf`** / **`:QR`** | 当前行 → 二维码 |
| **`:QrBuf 文本`** | 指定文本 |
| **可视选中后 `<leader>qr`** | **用选中文字**生成二维码 |
| **可视选区后 `:QrBuf`** | 同上 |
| **`<leader>qr`（normal）** | 当前行 |

### 浮窗按键

| 键 | 作用 |
|----|------|
| `q` / `Esc` | 关闭 |
| `y` | 复制原文到剪贴板 |
| `+` / `-` | **宽高同时**放大 / 缩小（不超过屏幕、不换行） |
| **`L`** | 中/英文界面 |

## 配置

```lua
require("qrbuf").setup({
  python = "python",
  zoom = 1,
  invert = false,
  ui_lang = "auto",
  keys_open = "<leader>qr",
})
```

## 说明

- 使用 [Nayuki QR-Code-generator](https://github.com/nayuki/QR-Code-generator)（MIT，vendored：`scripts/qrcodegen.py`），可正常扫码。
- 默认 4 模块静区；矩阵以黑块 `█▀▄` 画在白底浮窗上。
- 编码 UTF-8；容量随 QR 版本自动升高（过长会由库报错）。
