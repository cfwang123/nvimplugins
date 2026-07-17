# ntemoji

[English](README.md) | **中文**

给 **NERDTree** 用 emoji 图标——不依赖 Nerd Font，也不需要 **vim-devicons**。

通过 NERDTree 官方的 `PathNotifier` + `flagSet`（与 webdevicons 同一扩展点）写入图标，普通 emoji 在 **Consolas** 等字体下也能显示。

## 依赖

| 组件 | 说明 |
|------|------|
| Neovim 0.9+ | |
| [NERDTree](https://github.com/preservim/nerdtree) | 需已安装 |
| **不要**再加载 `ryanoasis/vim-devicons` | 会双图标冲突 |

## 安装

```vim
Plug '/path/to/nvimplugins/ntemoji'
" 或整仓：
" Plug 'cfwang123/nvimplugins'
```

## 用法

无需 `setup()`。打开 NERDTree（`:NERDTree`）即显示 emoji。

```lua
require("ntemoji").setup({
  folder_closed = "📁",
  folder_open = "📂",
  default_file = "📄",
  extension = {
    md = "📝",
    json = "📋",
    tutor = "📘",
  },
  exact = {
    [".gitignore"] = "🙈",
  },
})
```

## 默认示例

| 类型 | Emoji |
|------|--------|
| 目录 | 📁 / 📂 |
| 默认文件 | 📄 |
| `.md` | 📝 |
| `.json` | 📋 |
| `.tutor` | 📘 |
| 图片 | 🖼️ |
| 压缩包 | 📦 |

## 说明

- NERDTree 会把 flag 渲染成 `[图标]`；ntemoji 默认用 **conceal 隐藏中括号**（`conceal_brackets = true`）。
- **自动不启用**：若已安装/加载 **vim-devicons**（`runtimepath` 上有插件，或已 `loaded_webdevicons`），ntemoji **整插件关闭**（不写 flag、不做 conceal）。要用 ntemoji 请去掉 `Plug 'ryanoasis/vim-devicons'`。
  - 可选：`let g:ntemoji_notify_skip = 1` 跳过时提示一行。
  - 强制启用（不推荐）：`let g:ntemoji_force = 1`。
- **不**接管 airline 状态栏图标（有意为之）。
- 整仓安装时默认带上 `ntemoji`（见 `plugin/nvimplugins.lua`）。

## 目录

```
ntemoji/
  plugin/ntemoji.lua
  lua/ntemoji/init.lua
  autoload/ntemoji.vim
  nerdtree_plugin/ntemoji.vim
  README.md
  README.zh.md
```
