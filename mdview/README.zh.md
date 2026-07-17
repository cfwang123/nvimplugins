# mdview.nvim

[English](README.md) | **中文**

在 Neovim 内预览 Markdown：**单窗阅读**（`:MdView`）或 **侧边对照**（`:MdSideView`）。

纯 Lua 解析 + 只读预览 buffer；代码高亮、TOC、表格、图片用色块字符渲染、链接跳转、可选终端高清叠层。

- 功能演示：[testdata/demo.md](./testdata/demo.md)
- 截图：[testdata/screenshots/](./testdata/screenshots/)

## 功能一览

| 能力 | 说明 |
|------|------|
| 单窗 / 侧边 | `:MdView` 源⇄预览；`:MdSideView` 对照 + 同步滚动 / 光标 `_` 标记 |
| 样式 | 标题（可自动序号）、粗体、斜体、`` code ``、删除线、`==mark==`、链接 |
| 列表 / 引用 / HR / 表 | GFM 表；列宽动态；表内图；单元格 `\|` 转义 |
| 代码块 | 边框、语言、行号、灰底、默认 10 行折叠、**`c` / `yc` / [Copy]**、TS→syntax→单色 |
| TOC | 预览顶目录；`t` 打开目录 float |
| 链接 | Enter/点击；`#标题` / `#1. 标题` 锚点；md 文件→目标预览；`Ctrl-o` 返回 |
| 图片 | 预览内用色块字符渲染；`gi`/Enter float；`gh` 临时页内高清；`o` 系统打开 |
| HTML | `<details>` / `<summary>`、`<img>` |
| 排版 | 按预览宽度软折行，变宽自动重排 |

---

## 安装

按需求从 **① 最简** 装到 **③ 完整功能**。路径请改成你的本机目录。

### ① 最简安装（开箱即用）

**只需 Neovim 0.9+**，无需 Python、无需 Tree-sitter、无需改配置。

得到：标题/列表/表/代码块（单色或 syntax）、TOC、链接、侧栏同步等**核心预览**。  
没有：图片色块字符渲染、float 高清、代码 TS 高亮。

#### vim-plug（本地路径）

```vim
call plug#begin()
" 仅装 mdview 子目录
Plug '/path/to/nvimplugins/mdview'
" 或整仓网络安装：Plug 'cfwang123/nvimplugins'  然后 :PlugInstall
call plug#end()
```

#### 手动 rtp

```lua
vim.opt.rtp:prepend("/path/to/nvimplugins/mdview")
-- 确保 plugin/mdview.lua 被加载（启动时 source 或 packadd）
```
装好后**无需 `setup()`**，直接：

```vim
:e /path/to/nvimplugins/mdview/testdata/demo.md
:MdSideView
" 或
:MdView
```

默认全局键（若未被占用）：

| 键 | 命令 |
|----|------|
| `<leader>mv` | `:MdView` |
| `<leader>ms` | `:MdSideView` |

关闭默认键：

```lua
require("mdview").setup({
  keys = { view = false, side = false },
})
```

---

### ② 推荐安装（日常 Markdown 阅读）

在 ① 的基础上增加：

| 依赖 | 作用 |
|------|------|
| **`termguicolors`** | 颜色/色块字符渲染正常 |
| **Python 3 + Pillow** | 图片色块真彩渲染、float 底层与高清编码 |
| **Tree-sitter** + 常用语言 parser | 代码块语法高亮（否则 syntax / 单色） |

#### 系统依赖

```bash
# Python 色块渲染 / 高清 PNG
pip install Pillow
# 或: python -m pip install Pillow

# 可选：系统里有 python / python3 即可；可用 image.python 指定解释器
```

Tree-sitter（任选其一）：

```lua
-- nvim-treesitter 示例
require("nvim-treesitter.configs").setup({
  ensure_installed = { "lua", "python", "javascript", "bash", "markdown" },
  highlight = { enable = true },
})
```

并保证已安装对应 parser（`:TSInstall lua python` 等）。

#### 推荐 `setup`

```lua
require("mdview").setup({
  split_direction = "right",
  width = 0.45,
  show_key_hint = true, -- 预览顶部灰色快捷键提示
  ui_lang = "auto",     -- 界面 "auto" | "zh" | "en"；预览中按 L 切换
  code_fold_lines = 10,
  code_highlight = "auto", -- treesitter → syntax → 单色
  sync_scroll = true,
  sync_cursor_block = true,
  keys = {
    view = "<leader>mv",
    side = "<leader>ms",
  },
  image = {
    mode = "thumb",          -- 预览内色块字符渲染
    python = "python",       -- 或 "python3" / 绝对路径
    open_with = "float",
    float_hd = "never",      -- ② 可先关高清，仅色块
    float_scale = "fill",
  },
})
```

此时可用：

- 预览顶部灰色快捷键提示
- 预览图片色块渲染、`gi` float 大图（色块）
- 代码块高亮（有 TS 时更清晰）
- 侧栏源码光标 → 预览 `_` 标记

---

### ③ 完整功能安装（高清 + 全体验）

在 ② 的基础上再配：

| 依赖 | 作用 |
|------|------|
| **WezTerm / Kitty / Ghostty** | 终端图形协议；float 高清、`gh` 页内临时高清 |
| 真彩终端 + 足够色域 | 色块与高清观感更好 |
| （可选）chafa | `image.backend = "auto"` 时可作为色块渲染备选 |

#### 终端

- **WezTerm**：推荐；float / `gh` 走 iTerm 协议叠层  
- **Kitty / Ghostty**：Kitty 协议  
- **Alacritty 等**：一般无图形协议 → 仅色块字符，无像素高清  
- **tmux 内**：默认关高清；需 `image.hd_tmux = true` / `graphics_tmux = true`（且 tmux 需放行图形序列）  
- **SSH**：默认关高清；需 `hd_ssh` / `graphics_ssh`

#### 完整示例 `setup`

```lua
require("mdview").setup({
  split_direction = "right",
  width = 0.45,
  heading_conceal = true,      -- 预览隐藏 ###，保留/生成序号
  list_bullets = { "●", "○" },
  toc = true,
  toc_min_level = 1,
  toc_max_level = 3,
  code_fold_lines = 10,
  code_highlight = "auto",
  code_line_numbers = true,
  sync_scroll = true,
  sync_cursor_block = true,
  sync_reverse = true,
  keys = {
    view = "<leader>mv",
    side = "<leader>ms",
  },
  image = {
    mode = "thumb",
    max_height = 0,            -- 0 = 高度随宽比例；>0 限制最大行数
    max_images = 20,
    backend = "auto",          -- python Pillow / chafa
    python = "python",
    open_with = "float",
    float_scale = "fill",      -- fill 拉伸 | fit 等比 letterbox
    -- 预览内默认不自动高清（滚动易乱）；用 gh 临时开
    hd = "never",
    -- float 与 gi：终端支持则像素高清
    float_hd = "always",
    hd_tmux = false,
    hd_ssh = false,
  },
  html = {
    img = true,
    details = true,
    details_default_open = false,
  },
})
```

完整能力对照：

| 能力 | ① 最简 | ② 推荐 | ③ 完整 |
|------|:------:|:------:|:------:|
| 源/预览、TOC、表、链接、折叠 | ✓ | ✓ | ✓ |
| 代码 TS 高亮 | — | ✓ | ✓ |
| 图片用色块字符渲染 / float 色块 | — | ✓ | ✓ |
| float 像素高清（`gi`） | — | 可选 | ✓ |
| 页内临时高清（`gh`） | — | — | ✓ |
| 侧栏光标 `_`、跨文件预览跳转 | ✓ | ✓ | ✓ |

#### 自检

```vim
:e /path/to/nvimplugins/mdview/testdata/demo.md
:MdSideView
" 预览顶部灰色快捷键提示；? 完整帮助 · t 目录 · c 复制 · gi/gh 图
```

```bash
python -c "from PIL import Image; print('Pillow OK')"
```

---

## 命令

| 命令 | 作用 |
|------|------|
| `:MdView` | 单窗切换源 / 预览 |
| `:MdSideView` | 侧边预览 toggle（**每 tab 仅一个**预览窗） |
| `:MdSideView open` / `close` | 显式开/关 |
| `:MdViewRefresh` | 强制重渲染 |
| `:MdViewSync` | 侧边按源光标同步 |

侧边开启后，同 tab 切换其它 **markdown** buffer 时预览会跟到该文件；非 md 则保持当前预览。

## 预览键位

| 键 | 作用 |
|----|------|
| `q` | 关闭预览 / 单窗回源 |
| `r` | 刷新预览 |
| （自动） | 源 md **被外部程序改写**且 buffer 无未保存修改时自动 reload 并重绘（`watch_external`） |
| `<CR>` | TOC / 代码折叠 / details / 图片 / **md 链接→目标预览** |
| `gi` | 图片 float 大图 |
| `gh` | 当前页临时高清（滚动 / 焦点切换 / 改窗大小清除） |
| `o` | 系统打开图片 |
| `c` / `yc` | 复制光标处代码块 |
| `gs` | 跳到源对应行 |
| `go` | 文内 TOC 顶部 |
| `t` | 目录 float |
| `<C-o>` | 返回：文内跳转 → 上一篇 md 预览 |
| `L` | 切换中/英文界面（顶栏提示、帮助、复制按钮等；记住偏好） |
| `?` | 帮助 float |

## 配置摘要

全部默认项见 `lua/mdview/config.lua`。

### 图片行为简述

- **预览内**：默认仅色块字符渲染（`hd = "never"`）；需要时用 **`gh`** 临时叠高清  
- **float / `gi`**：色块 + 可选像素高清（`float_hd = "always"`）  
- 需 **Pillow**；高清还需支持图形协议的终端  

## 目录

```
mdview/
  plugin/mdview.lua
  lua/mdview/
  scripts/thumb.py
  scripts/gfx_prepare.py
  testdata/demo.md
  testdata/screenshots/
  README.md
  README.zh.md
```

## 相关

- 仓库总览：[English](../README.md) · [中文](../README.zh.md)
