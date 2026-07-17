# nvimplugins

[English](README.md) | **中文**

> **About** — 面向 Neovim 的小型实验与工具插件集合：含 **mdview**（Markdown 预览）、**music**（打开音频即在 buffer 中播放）、**imgbuf**（终端图片预览）、**nvimgames**（扫雷 / 推箱子 / 24 点 / 方块）、**drawbuf**（Unicode 色块绘图）。各插件可独立安装，互不强制依赖。

面向终端里「好玩、好用、少依赖」的实验与日常小工具。

**两种装法任选其一：**

| 方式 | 说明 |
|------|------|
| **整仓（网络）** | `Plug 'cfwang123/nvimplugins'`，从 GitHub 拉取；根目录 `plugin/nvimplugins.lua` 自动加载全部子插件 |
| **分目录（本地路径）** | 只 `Plug` 需要的子文件夹（如 `…/mdview`） |

## 插件一览

| 插件 | 简介 | 文档 |
|------|------|------|
| **[mdview](mdview/)** | 在 Neovim 内预览 Markdown：单窗阅读（`:MdView`）或侧边源码对照（`:MdSideView`）。纯 Lua 渲染标题/列表/GFM 表/代码块（可选 Tree-sitter 高亮）、TOC、链接与锚点跳转、图片用色块字符渲染与可选终端高清叠层。 | [EN](mdview/README.md) · [中文](mdview/README.zh.md) |
| **[music](music/)** | 打开音频文件即在 buffer 中变成播放器：播放/暂停/进度条拖动、音量、同目录上一首/下一首与曲目列表、LRC 歌词同步高亮、会话恢复；Python 守护进程（just_playback / pygame）后台播，可隐藏 UI 不抢焦。 | [EN](music/README.md) · [中文](music/README.zh.md) |
| **[imgbuf](imgbuf/)** | 打开图片做字符画预览（block / half / braille），默认拉伸铺满、可切等比；支持自动预览、剪贴板、文件树友好；在 WezTerm/Kitty/Ghostty 上可叠像素高清层（chafa 或 Python+Pillow）。 | [EN](imgbuf/README.md) · [中文](imgbuf/README.zh.md) |
| **[nvimgames](nvimgames/)** | 终端小游戏合集：扫雷、推箱子（自带多关）、24 点扑克、俄罗斯方块（含特殊块与可选人机对战）；`:NvimGames` 浮动选单一键进入。 | [EN](nvimgames/README.md) · [中文](nvimgames/README.zh.md) |
| **[drawbuf](drawbuf/)** | 用 Unicode 色块在 buffer 里画画：铅笔/橡皮/直线/矩形/椭圆/填充，真彩色调色板与可点中文状态栏，支持撤销重做、`.draw` 存盘与内置彩色演示图案。 | [EN](drawbuf/README.md) · [中文](drawbuf/README.zh.md) |

## 截图

| mdview（侧栏） | music | imgbuf |
|:--------------:|:-----:|:------:|
| ![mdview](mdview/testdata/screenshots/1.png) | ![music](images/music.png) | ![imgbuf](images/imgbuf.png) |

| 扫雷 | 推箱子 | 24点 | 俄罗斯方块 |
|:----:|:------:|:----:|:----------:|
| ![扫雷](images/mine.png) | ![推箱子](images/sokoban.png) | ![24点](images/twentyfour.png) | ![俄罗斯方块](images/tetris.png) |

| drawbuf |
|:-------:|
| ![drawbuf](images/drawbuf.png) |

mdview 更多场景见 [mdview/testdata/screenshots/](mdview/testdata/screenshots/) 与演示文 [mdview/testdata/demo.md](mdview/testdata/demo.md)。

## 依赖摘要

| 插件 | Neovim | 其他 |
|------|--------|------|
| mdview | 0.9+ | 核心无额外依赖；色块字符渲染需 Pillow（或 chafa）；代码高亮可选 Tree-sitter；像素高清需图形协议终端 |
| music | 0.9+ | Python3 + **just_playback**（或 pygame 回退） |
| imgbuf | 0.9+ | chafa **或** Python3 + Pillow；高清需 WezTerm/Kitty/Ghostty + Pillow |
| nvimgames | 0.9+ | `termguicolors`；扫雷建议 `mouse=a`；推箱子自带 `data/levels.json` |
| drawbuf | 0.9+ | `termguicolors`；建议 `mouse=a` |

## 快速安装

**不必**统一 `setup()`（要改参数时再 `require(...).setup`）。  
整仓与分目录**不要混装同一批插件**；若混装，子插件有 `loaded_*` 守卫，一般不会重复注册命令，但 `rtp` 会多一份路径。

### 方式 A：整仓 — vim-plug 网络安装（推荐「全要」）

仓库：[cfwang123/nvimplugins](https://github.com/cfwang123/nvimplugins)。  
根目录 `plugin/nvimplugins.lua` 会把各子目录加入 `runtimepath` 并 source 各自的 `plugin/`。

#### vim-plug

```vim
call plug#begin()
Plug 'cfwang123/nvimplugins'
call plug#end()
```

首次（或更新后）执行 **`:PlugInstall`**（更新可用 `:PlugUpdate`）。

只要部分子插件时，在 `plug#end()` **之前**设置（名与目录一致）：

```vim
let g:nvimplugins_enable = ['mdview', 'music', 'imgbuf']
call plug#begin()
Plug 'cfwang123/nvimplugins'
call plug#end()
```

#### lazy.nvim

```lua
{
  "cfwang123/nvimplugins",
  lazy = false,
  -- 可选：只启用部分（须在插件加载前生效；也可用 init）
  -- init = function()
  --   vim.g.nvimplugins_enable = { "mdview", "music", "imgbuf" }
  -- end,
}
```

### 方式 B：分目录 — 本地路径（推荐「只要某几个」）

只装需要的子目录时，对本地克隆路径使用 `Plug` / `dir`。

#### vim-plug

```vim
call plug#begin()
Plug '/path/to/nvimplugins/mdview'
Plug '/path/to/nvimplugins/music'
Plug '/path/to/nvimplugins/imgbuf'
Plug '/path/to/nvimplugins/nvimgames'
Plug '/path/to/nvimplugins/drawbuf'
call plug#end()
```

#### lazy.nvim（示例）

```lua
{
  { dir = "/path/to/nvimplugins/mdview", name = "mdview", lazy = false },
  { dir = "/path/to/nvimplugins/music", name = "music", lazy = false },
  { dir = "/path/to/nvimplugins/imgbuf", name = "imgbuf", lazy = false },
  { dir = "/path/to/nvimplugins/nvimgames", name = "nvimgames", lazy = false },
  { dir = "/path/to/nvimplugins/drawbuf", name = "drawbuf", lazy = false },
}
```

各插件从简到全的安装说明见子目录 README（mdview 有 ①最简 → ③完整 分档）。

### 可选 `setup()`（分插件）

**全部可选。** 插件加载后即用默认配置（命令 / 自动打开无需 `setup`）。只有要改参数时才调用 `require("…").setup({ ... })`。写在插件已进入 `rtp` 之后（例如 `plug#end()` 之后）。

```lua
-- mdview — Markdown 预览（完整项见 mdview/README）
require("mdview").setup({
  split_direction = "right",
  width = 0.45,
  keys = { view = "<leader>mv", side = "<leader>ms" }, -- 或 false 关闭
  image = {
    mode = "thumb",
    python = "python",
    float_hd = "always", -- 终端支持时 float 内像素高清
  },
})

-- music — buffer 音频播放器
require("music").setup({
  volume = 70,
  auto_open = true,
  auto_play = true,
  toggle_key = "<M-m>", -- Alt+M 显示/隐藏
  statusline_when_hidden = false,
  python = "python",
})

-- imgbuf — 图片字符画 + 可选高清叠层
require("imgbuf").setup({
  backend = "auto", -- "auto" | "chafa" | "python"
  mode = "block",   -- "block" | "half" | "braille"
  scale = "fill",   -- "fill" | "fit"
  hd = "always",    -- "always" | "never"
  auto_open = true,
})

-- nvimgames — 小游戏
require("nvimgames").setup({
  mine = { difficulty = "beginner" }, -- beginner | intermediate | expert
  sokoban = { remember_level = true },
  twentyfour = { solvable_only = true },
  tetris = { special_score = 1000 },
})

-- drawbuf — Unicode 色块绘图
require("drawbuf").setup({
  width = 80,
  height = 24,
  canvas_bg = "ffffff",
  statusline = true,
})
```

完整选项见各子插件 README / `lua/*/init.lua`（mdview：`lua/mdview/config.lua`）。

## 文档索引

| 插件 | 入口 |
|------|------|
| mdview | [EN](mdview/README.md) · [中文](mdview/README.zh.md) · [demo](mdview/testdata/demo.md) · [截图](mdview/testdata/screenshots/) |
| music | [EN](music/README.md) · [中文](music/README.zh.md) |
| imgbuf | [EN](imgbuf/README.md) · [中文](imgbuf/README.zh.md) |
| nvimgames | [EN](nvimgames/README.md) · [中文](nvimgames/README.zh.md) |
| drawbuf | [EN](drawbuf/README.md) · [中文](drawbuf/README.zh.md) |

## 许可与说明

个人 / 原型向合集，按需拷贝子目录使用即可。问题与改动建议落在对应插件目录下。
