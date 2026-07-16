# nvimplugins

本地 **Neovim** 小插件合集：图片预览、Markdown 预览、色块绘图、小游戏、音频播放。每个子目录是一个可独立安装的插件，互不强制依赖。

面向终端里「好玩、好用、少依赖」的实验与日常小工具；安装以 **本地路径**（vim-plug / lazy.nvim / `rtp`）为主。

## 插件一览

| 插件 | 一句话 | 文档 |
|------|--------|------|
| **[imgbuf](imgbuf/)** | 打开图片 → 字符画 + 可选高清叠层 | [imgbuf/README.md](imgbuf/README.md) |
| **[mdview](mdview/)** | Markdown 单窗/侧边预览（TOC、表、代码、图、链接跳转） | [mdview/README.md](mdview/README.md) |
| **[drawbuf](drawbuf/)** | 在 buffer 里用 Unicode 色块画画 | [drawbuf/README.md](drawbuf/README.md) |
| **[nvimgames](nvimgames/)** | 小游戏：扫雷 / 推箱子 / 24点 / 俄罗斯方块 | [nvimgames/README.md](nvimgames/README.md) |
| **[music](music/)** | 打开音频 → buffer 播放器（进度 / 歌词 / 列表） | [music/README.md](music/README.md) |

## 截图

| imgbuf | drawbuf | 扫雷 |
|:------:|:-------:|:----:|
| ![imgbuf](images/imgbuf.png) | ![drawbuf](images/drawbuf.png) | ![扫雷](images/mine.png) |

| 推箱子 | 24点 | 俄罗斯方块 |
|:------:|:----:|:----------:|
| ![推箱子](images/sokoban.png) | ![24点](images/twentyfour.png) | ![俄罗斯方块](images/tetris.png) |

| music | mdview（侧栏） |
|:-----:|:--------------:|
| ![music](images/music.png) | ![mdview](mdview/testdata/screenshots/1.png) |

mdview 更多场景见 [mdview/testdata/screenshots/](mdview/testdata/screenshots/) 与演示文 [mdview/testdata/demo.md](mdview/testdata/demo.md)。

## 依赖摘要

| 插件 | Neovim | 其他 |
|------|--------|------|
| imgbuf | 0.9+ | chafa **或** Python3 + Pillow；高清需 WezTerm/Kitty/Ghostty + Pillow |
| mdview | 0.9+ | 核心无额外依赖；█ 缩略需 Pillow（或 chafa）；代码高亮可选 Tree-sitter；像素高清需图形协议终端 |
| drawbuf | 0.9+ | `termguicolors`；建议 `mouse=a` |
| nvimgames | 0.9+ | `termguicolors`；扫雷建议 `mouse=a`；推箱子自带 `data/levels.json` |
| music | 0.9+ | Python3 + **just_playback**（或 pygame 回退） |

## 快速安装

路径改成你的本机目录。可只装需要的子目录；**不必**统一 `setup()`（要改参数时再 `require(...).setup`）。

### vim-plug

```vim
call plug#begin()
Plug '/path/to/nvimplugins/imgbuf'
Plug '/path/to/nvimplugins/mdview'
Plug '/path/to/nvimplugins/drawbuf'
Plug '/path/to/nvimplugins/nvimgames'
Plug '/path/to/nvimplugins/music'
call plug#end()
```

### lazy.nvim（示例）

```lua
{
  { dir = "/path/to/nvimplugins/imgbuf", name = "imgbuf", lazy = false },
  { dir = "/path/to/nvimplugins/mdview", name = "mdview", lazy = false },
  { dir = "/path/to/nvimplugins/drawbuf", name = "drawbuf", lazy = false },
  { dir = "/path/to/nvimplugins/nvimgames", name = "nvimgames", lazy = false },
  { dir = "/path/to/nvimplugins/music", name = "music", lazy = false },
}
```

各插件从简到全的安装说明见子目录 README（mdview 有 ①最简 → ③完整 分档）。

## 目录结构

```
nvimplugins/
  imgbuf/       # 图片预览
  mdview/       # Markdown 预览
  drawbuf/      # 色块绘图
  nvimgames/    # 小游戏
  music/        # 音频播放器
  images/       # 仓库 README 用截图
  tmp/          # 本地临时（gitignore）
  README.md
  AGENTS.md
```

## 文档索引

| 插件 | 入口 |
|------|------|
| imgbuf | [imgbuf/README.md](imgbuf/README.md) |
| mdview | [mdview/README.md](mdview/README.md) · [demo](mdview/testdata/demo.md) · [截图](mdview/testdata/screenshots/) |
| drawbuf | [drawbuf/README.md](drawbuf/README.md) |
| nvimgames | [nvimgames/README.md](nvimgames/README.md) |
| music | [music/README.md](music/README.md) |

## 许可与说明

个人 / 原型向合集，按需拷贝子目录使用即可。问题与改动建议落在对应插件目录下。
