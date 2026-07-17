# nvimplugins

[English](README.md) | **中文**

> **About** — 面向 Neovim 的小型实验与工具插件集合：含 **mdview**（Markdown 预览）、**music**（打开音频即在 buffer 中播放）、**imgbuf**（终端图片预览）、**nvimgames**（扫雷 / 推箱子 / 24 点 / 方块）、**drawbuf**（Unicode 色块绘图）。各插件可独立安装，互不强制依赖。

面向终端里「好玩、好用、少依赖」的实验与日常小工具；安装以 **本地路径**（vim-plug / lazy.nvim / `rtp`）为主。

**两种装法任选其一：**

| 方式 | 说明 |
|------|------|
| **整仓** | 只 `Plug` / `dir` 指向仓库根 `nvimplugins/`，自动加载全部子插件 |
| **分目录** | 只装需要的子文件夹（如 `…/mdview`），互不影响 |

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

路径改成你的本机目录。**不必**统一 `setup()`（要改参数时再 `require(...).setup`）。  
整仓与分目录**不要混装同一批插件**（可只整仓，或只分子目录）；若混装，子插件自带 `loaded_*` 守卫，一般不会重复注册命令，但 `rtp` 会多一份路径。

### 方式 A：整仓（推荐「全要」）

根目录的 `plugin/nvimplugins.lua` 会把各子目录加入 `runtimepath` 并 source 各自的 `plugin/`。

#### vim-plug

```vim
call plug#begin()
Plug '/path/to/nvimplugins'
call plug#end()
```

只要部分子插件时，在 `plug#end()` **之前**设置（名与目录一致）：

```vim
let g:nvimplugins_enable = ['mdview', 'music', 'imgbuf']
call plug#begin()
Plug '/path/to/nvimplugins'
call plug#end()
```

#### lazy.nvim

```lua
{
  dir = "/path/to/nvimplugins",
  name = "nvimplugins",
  lazy = false,
  -- 可选：只启用部分（须在插件加载前生效；也可用 init）
  -- init = function()
  --   vim.g.nvimplugins_enable = { "mdview", "music", "imgbuf" }
  -- end,
}
```

### 方式 B：分目录（推荐「只要某几个」）

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
