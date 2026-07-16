# music.nvim

打开**音频文件**时，在 **buffer** 里变成简易播放器（类似 imgbuf 打开图片）。

无播放列表：上一首 / 下一首 = **同目录**相邻音频。

## 播放后端（Python）

不再依赖 **mpv / ffplay** 一次性子进程。改为启动**一个长期运行的** `scripts/player.py`，通过 stdin/stdout JSON 控制：

| 能力 | 说明 |
|------|------|
| 播放 / 暂停 / 恢复 | 进程内控制 |
| 进度跳转 | 绝对秒数 seek（进度条拖动） |
| 音量 | 0–100 实时调节 |
| 时长 | mutagen（可选）/ wav / ffprobe（可选） |

底层引擎优先级：

1. **just_playback**（若已安装，seek 更稳）  
2. **pygame**（本机常见；你已具备即可用）

> 说明：从 Neovim 看仍会 `jobstart` 一个 Python 进程，但这是**可控守护进程**，不是无法遥控的 ffplay 窗口。

## 功能

| 能力 | 说明 |
|------|------|
| 打开即播 | `:e song.mp3` / `:Music song.mp3` |
| 播放控制 | 播放、暂停、重播、停止 |
| 同目录切换 | 下一首 / 上一首（按文件名排序） |
| 进度 | `当前 / 总长`（分:秒） |
| 进度条 | 可 **点击 / 拖动** 跳转 |
| 可视化 | 彩色伪频谱 |
| 彩色按钮 | 播放/暂停/上/下/停止/音量/循环/关闭等 |

## 依赖

| 组件 | 要求 |
|------|------|
| Neovim | 0.9+（推荐 0.10+） |
| Python 3 | `PATH` 中可执行 `python` |
| 音频库 | **pygame** 或 **just_playback** |

```text
pip install pygame
# 可选，seek 体验更好：
pip install just_playback
# 可选，读更多格式时长：
pip install mutagen
```

可选：`ffprobe` 用于时长探测回退。

鼠标：`set mouse=a`（拖动进度条；打开时若为空会自动打开）。

## 安装（vim-plug）

**无需** `setup()`：加载即用默认配置。

```vim
call plug#begin()

Plug '/path/to/vim/music', {
  \ 'on': ['Music', 'MusicToggle', 'MusicNext', 'MusicPrev', 'MusicStop'],
  \ }

call plug#end()

augroup MusicPlugLazy
  autocmd!
  autocmd BufReadPre *.mp3,*.flac,*.wav,*.ogg,*.m4a,*.aac,*.opus,*.wma
    \ call plug#load('music')
augroup END

" 可选
" lua require('music').setup({ volume = 80, python = 'python' })
```

## 用法

```vim
:e D:/Music/track.mp3
:Music D:/Music/track.mp3
:MusicToggle
:MusicNext
:MusicPrev
:MusicStop
```

### 界面快捷键 / 按钮

| 操作 | 键 / 按钮 |
|------|-----------|
| 播放/暂停 | `Space` / 按钮 |
| 上/下一首 | `N` `n` 或 `</>` |
| ±5 秒 | `h` `l` / 方向键 / 按钮 |
| 进度跳转 | 点击/拖动进度条 |
| 音量 | `+/-` / 按钮 |
| 循环 | `L` / 按钮 |
| 关闭并停播 | `q` |

## 配置（可选）

```lua
require("music").setup({
  volume = 70,
  auto_open = true,
  auto_play = true,
  auto_next = true,
  loop = false,
  viz = true,
  viz_height = 8,
  poll_ms = 200,
  python = "python",  -- 或 python3 / 绝对路径
})
```

## 说明

- 播放器 **buffer 不显示**时会停止出声。  
- 退出 Neovim 会向 Python 发送 `quit` 并结束守护进程。  
- 关闭播放器 buffer（`q`）停止播放。  
