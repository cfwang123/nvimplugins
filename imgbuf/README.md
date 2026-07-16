# imgbuf.nvim

在 Neovim 里预览图片：默认 **字符画 + 高清叠层**（WezTerm/Kitty/Ghostty 上自动检测；其它终端仅字符画）。

不把每个像素做成 highlight 组，因此不会触发 `E849: Too many highlight and syntax groups`。

![imgbuf 截图](../images/imgbuf.png)

## 功能

- **block / half / braille** 三种符号模式（默认 **block**）
- **缩放**：默认**拉伸铺满**；`s` 切换为窗口内**等比**（可再按 `s` 回拉伸）
- **底部按键提示**
- **自动预览**：`:e photo.png` / 文件树打开
- **剪贴板**：`:ImgbufClipboard`
- **窗口缩放**防抖重绘、只读、禁止滚动
- **文件树友好**（NERDTree / NvimTree / neo-tree）
- **高清默认开启**（`hd = "always"`）：终端支持时自动叠像素图（WezTerm/Kitty/Ghostty + Pillow）；否则仅字符画

## 依赖

| 组件 | 要求 |
|------|------|
| Neovim | 0.9+（推荐 0.10+） |
| 字符画 | chafa **或** Python 3 + Pillow |
| 高清叠层 | WezTerm / Kitty / Ghostty + **Pillow**（`hd=always` 默认） |

**chafa（推荐）**：`scoop install chafa`  
**高清/字符画 Python**：`pip install Pillow`

## 安装（vim-plug）

路径请改成你的本机目录。

**无需** `require('imgbuf').setup()`：插件加载后即用默认配置。  
需要改参数时再调用 `setup({ ... })`。

```vim
call plug#begin()
Plug '/path/to/vim/imgbuf'
call plug#end()

" 可选
" lua require('imgbuf').setup({ backend = 'chafa' })
```

## 用法

```vim
:e photo.png
:Imgbuf path/to/image.png
:ImgbufClipboard
:ImgbufMode block
:ImgbufRefresh
:ImgbufScale           " 切换 fit/fill
:ImgbufScale fit
:ImgbufScale fill
```

| 键 | 作用 |
|----|------|
| `q` | 关闭 |
| `r` | 刷新 |
| `1` | block 字符画 |
| `2` | half（`▀`） |
| `3` | braille（点阵） |
| `s` | 拉伸 (fill) ↔ 等比适配窗口 (fit) |
| `o` | 用系统默认程序打开原图 |

| 缩放 | 含义 |
|------|------|
| **fill**（默认） | 拉伸铺满窗口（可能变形） |
| **fit** | 等比缩放到窗口内并**居中**；高清叠层与字符画对齐重叠 |

## 配置（可选）

不调用 `setup()` 时使用内置默认值。需要改参数时：

```lua
require("imgbuf").setup({
  backend = "auto",   -- "auto" | "chafa" | "python"
  mode = "block",     -- "block" | "half" | "braille"
  scale = "fill",     -- "fill" 拉伸 | "fit" 等比（s 切换）
  hd = "always",      -- 默认：检测终端支持则叠高清；"never" 关闭
  -- hd_tmux = true,  -- tmux 内也尝试
  show_help = true,
  auto_open = true,
})
```

默认 **`hd = "always"`**：在 WezTerm / Kitty / Ghostty 等支持图形协议的终端上，字符画之上自动叠像素图（需 `pip install Pillow`）。不支持或检测失败时只显示字符画。设 `hd = "never"` 可关掉高清。

可多次调用；后一次以默认值为底再合并你传入的字段。

## 原理

1. 在编辑区开 **terminal buffer**，字符画（chafa / render.py）
2. 若 `hd` 开启且终端支持：宿主 TTY 叠 iTerm2/Kitty 像素图
3. 文件树友好：收回误开的 vsplit

## 目录

```
imgbuf/
  plugin/imgbuf.lua
  lua/imgbuf/init.lua
  lua/imgbuf/graphics.lua
  scripts/render.py
  scripts/gfx_prepare.py
  README.md
```

## 故障排除

| 现象 | 处理 |
|------|------|
| 无颜色 | 开启真彩色终端 / `termguicolors` |
| 启动失败 | 检查 chafa 或 `pip install Pillow` |
| 点阵字符 | `:ImgbufMode block` 或按 `1` |
| NERDTree 多一列 | 更新插件；文本 `o` 应覆盖预览 |

## 相关

- 仓库总览：[../README.md](../README.md)
- 绘图插件：[../drawbuf/README.md](../drawbuf/README.md)
