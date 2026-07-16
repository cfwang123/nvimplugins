# imgbuf.nvim

在 Neovim **terminal** 里预览图片：chafa 风格 **1/4 格字符**（`▘▝▖▗▀▄▌▐█`）+ 真彩色 ANSI。

不把每个像素做成 highlight 组，因此不会触发 `E849: Too many highlight and syntax groups`。

![imgbuf 截图](../images/imgbuf.png)

## 功能

- **block / half / braille** 三种符号模式（默认 **block**，chafa 四分格）
- **缩放模式**：等比适配（fit）↔ 拉伸铺满（fill）（`s`）
- **底部按键提示行**（反色条，显示当前模式/缩放）
- **自动预览**：`:e photo.png` 或从文件树打开图片
- **剪贴板图片**：`:ImgbufClipboard`（Pillow `ImageGrab`）
- **窗口缩放**防抖后按新尺寸重绘
- **预览只读**：不会把字符画写回原图
- **禁止滚动**：锁视图，屏蔽 j/k、滚轮等
- **文件树友好**（NERDTree / NvimTree / neo-tree 等）
  - `o` 打开图片 → **覆盖**右侧编辑区，不额外 vsplit
  - 右侧是预览时，`o` 打开**文本** → 覆盖预览，收回误开的分屏

## 依赖

| 组件 | 要求 |
|------|------|
| Neovim | 0.9+（推荐 0.10+） |
| 渲染后端 | 二选一（`backend = "auto"`） |

**后端 A — chafa（推荐）**

- 安装 [chafa](https://hpjansson.org/chafa/) 到 `PATH`
- Windows 示例：`scoop install chafa`

**后端 B — Python 回退**

- Python 3
- `pip install Pillow`

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
| `1` | block（默认） |
| `2` | half（`▀`） |
| `3` | braille（点阵） |
| `s` | 等比 (fit) ↔ 填充 (fill) |

预览区**最底一行**为反色按键提示（含当前模式 / 缩放）。

| 缩放 | 含义 |
|------|------|
| **fit** | 等比缩放，完整显示（可能留边） |
| **fill** | 拉伸铺满窗口（可能变形） |

## 配置（可选）

不调用 `setup()` 时使用内置默认值。需要改参数时：

```lua
require("imgbuf").setup({
  backend = "auto",   -- "auto" | "chafa" | "python"
  mode = "block",     -- "block" | "half" | "braille"
  scale = "fit",      -- "fit" | "fill"
  show_help = true,   -- 底部按键提示
  auto_open = true,
  -- 其余见 lua/imgbuf/init.lua 的 default_config
})
```

可多次调用；后一次以默认值为底再合并你传入的字段。

## 原理

1. 在编辑区（避开文件树）开 **terminal buffer**
2. 运行 `chafa` 或 `scripts/render.py --format ansi`
3. 终端解析 ANSI 真彩色
4. 对 terminal「不可用」导致的 vsplit 做收回，避免挡文本编辑

## 目录

```
imgbuf/
  plugin/imgbuf.lua
  lua/imgbuf/init.lua
  scripts/render.py
  README.md
  .gitignore
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
