# videobuf.nvim

[English](README.md) | **中文**

在 Neovim 内嵌预览/播放视频：上方字符画面，下方字幕与控制条（体验对齐 **music** / **imgbuf**）。

![videobuf 截图](../images/videobuf.png)

## 能力概要

- 打开视频进入预览 buffer（`:Videobuf` / 自动打开视配置）
- 播放 / 暂停 / 停止 / 重播、seek、音量、循环
- 帧率可调；同名时间轴字幕（内嵌当前句高亮）
- 中英文界面（控制条按钮，与 music 类似）

## 依赖

- Neovim 0.9+
- Python3 + 解码依赖（见 `scripts/videod.py`）

## 安装

```vim
Plug '/path/to/nvimplugins/videobuf'
" 或整仓 nvimplugins（默认包含 videobuf）
```
