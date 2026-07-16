# vim 插件集

本地 **Neovim** 小插件合集：图片预览、色块绘图、小游戏、音频播放。每个子目录是一个可独立安装的插件，互不强制依赖。

面向终端里「好玩、好用、少依赖」的实验与日常小工具；安装方式以 vim-plug / lazy.nvim 本地路径为主。

## 插件一览

| 插件 | 一句话 | 文档 |
|------|--------|------|
| **[imgbuf](imgbuf/)** | 在 terminal 里用 chafa / ANSI 预览图片 | [imgbuf/README.md](imgbuf/README.md) |
| **[drawbuf](drawbuf/)** | 在 buffer 里用 Unicode 色块画画 | [drawbuf/README.md](drawbuf/README.md) |
| **[nvimgames](nvimgames/)** | 小游戏合集：扫雷 / 推箱子 / 24点 / 方块 | [nvimgames/README.md](nvimgames/README.md) |
| **[music](music/)** | 打开音频文件 → buffer 播放器（进度条 / 可视化） | [music/README.md](music/README.md) |

## 截图

| imgbuf | drawbuf | 扫雷 |
|:------:|:-------:|:----:|
| ![imgbuf](images/imgbuf.png) | ![drawbuf](images/drawbuf.png) | ![扫雷](images/mine.png) |

| 推箱子 | 24点 | 俄罗斯方块 |
|:------:|:----:|:----------:|
| ![推箱子](images/sokoban.png) | ![24点](images/twentyfour.png) | ![俄罗斯方块](images/tetris.png) |

## 依赖摘要

| 插件 | Neovim | 其他 |
|------|--------|------|
| imgbuf | 0.9+ | chafa **或** Python3 + Pillow |
| drawbuf | 0.9+ | `termguicolors`；建议 `mouse=a` |
| nvimgames | 0.9+ | `termguicolors`；扫雷建议 `mouse=a`；推箱子自带 `data/levels.json` |
| music | 0.9+ | Python3 + **pygame**（或 just_playback） |

## 快速安装（示例）

路径改成你的本机目录。各插件可只装需要的那一个；**不必**统一 `setup()`（除需改参数外）。

```vim
call plug#begin()
Plug '/path/to/vim/imgbuf'
Plug '/path/to/vim/drawbuf'
Plug '/path/to/vim/nvimgames'
Plug '/path/to/vim/music'
call plug#end()
```

更细的懒加载、命令与快捷键见各子目录 README。

## 目录结构

```
vim/
  imgbuf/      # 图片预览
  drawbuf/     # 色块绘图
  nvimgames/   # 小游戏
  music/       # 音频播放器
  tmp/         # 本地临时文件（已 gitignore）
  README.md
  AGENTS.md
```

## 文档索引

- [imgbuf.nvim — 图片预览](imgbuf/README.md)
- [drawbuf.nvim — 色块绘图](drawbuf/README.md)
- [nvimgames.nvim — 扫雷 / 推箱子 / 24点 / 方块](nvimgames/README.md)
- [music.nvim — 音频播放](music/README.md)

## 许可与说明

个人 / 原型向合集，按需拷贝子目录使用即可。问题与改动建议落在对应插件目录下。
