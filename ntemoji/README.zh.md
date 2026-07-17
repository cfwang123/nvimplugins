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
- 若仍加载 **vim-devicons**，ntemoji **自动跳过**并提示警告。
- **不**接管 airline 状态栏图标（有意为之）。
- 整仓安装时默认启用 `ntemoji`。

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
