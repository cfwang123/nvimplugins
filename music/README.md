# music.nvim

打开**音频文件**时，在 **buffer** 里变成简易播放器（类似 imgbuf 打开图片）。

无播放列表：上一首 / 下一首 = **同目录**相邻音频。

## 功能

| 能力 | 说明 |
|------|------|
| 打开即播 | `:e song.mp3` / `:Music song.mp3`（`auto_open` / `auto_play`） |
| 播放控制 | 播放、暂停、重播、停止 |
| 同目录切换 | 下一首 / 上一首（按文件名排序） |
| 进度 | `当前 / 总长`（分:秒） |
| 进度条 | 可 **点击 / 拖动** 跳转 |
| 可视化 | 彩色伪频谱（播放时律动） |
| 彩色按钮 | 可点击：播放/暂停/上/下/停止/音量/循环/关闭等 |
| 音量 | 按钮或 `+/-` |

## 依赖

| 组件 | 要求 |
|------|------|
| Neovim | 0.9+（推荐 0.10+） |
| 播放器 | **mpv**（推荐，跳转/进度更准）或 **ffplay** |
| 可选 | `ffprobe` 读取时长 |
| 鼠标 | `set mouse=a`（拖动进度条；打开时若为空会自动打开） |

**推荐安装 mpv**（进度轮询、暂停、绝对跳转都更稳）：

```text
scoop install mpv
# 或 winget install mpv
```

ffplay 也可播；跳转会重启进程，暂停为“停在当前位置再开”。

## 安装（vim-plug）

**无需** `setup()`：加载即用默认配置。

```vim
call plug#begin()

Plug 'D:/VS_Projects/AIPrototype/vim/music', {
  \ 'on': ['Music', 'MusicToggle', 'MusicNext', 'MusicPrev', 'MusicStop'],
  \ }

call plug#end()

" 打开音频时懒加载（auto_open 需要已加载）
augroup MusicPlugLazy
  autocmd!
  autocmd BufReadPre *.mp3,*.flac,*.wav,*.ogg,*.m4a,*.aac,*.opus,*.wma
    \ call plug#load('music')
augroup END

" 可选改参
" lua require('music').setup({ volume = 80, viz_height = 10 })
```

立即加载：

```vim
Plug 'D:/VS_Projects/AIPrototype/vim/music'
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

### 界面（彩色 + 可点按钮）

- 标题 / 状态 / 时间：高亮配色（Catppuccin 风）
- 进度条：蓝填充 + 紫滑块，**点击 / 拖动** 跳转
- 频谱：多色柱条动画
- 按钮行（鼠标点击即可）：
  - `⏮ 上一首` `▶ 播放` / `⏸ 暂停` `⏭ 下一首` `⏹ 停止`
  - `⏪ -5s` `⏩ +5s` `🔉 -` `🔊 +` `🔁 循环` `↻ 重播` `✕ 关闭`

### 快捷键（播放器 buffer）

| 键 | 作用 |
|----|------|
| `Space` | 播放 / 暂停 |
| `n` / `N` 或 `>` / `<` | 同目录下一首 / 上一首 |
| `h` `l` / ← → | 快退 / 快进 5 秒 |
| 鼠标点按钮 | 对应操作 |
| 鼠标点/拖进度条 | 跳转 |
| `+` `-` | 音量 |
| `r` | 从头播放 |
| `L` | 单曲循环 |
| `q` / `Esc` | 关闭 buffer 并停止 |

## 配置（可选）

```lua
require("music").setup({
  backend = "auto",       -- "auto" | "mpv" | "ffplay"
  volume = 70,
  auto_open = true,       -- 打开音频扩展名时进入播放器
  auto_play = true,       -- 打开后自动播放
  auto_next = true,       -- 播完同目录下一首
  loop = false,           -- 单曲循环默认
  viz = true,             -- 伪频谱
  viz_height = 8,
  poll_ms = 200,          -- UI 刷新
  extensions = { "mp3", "flac", "wav", "ogg", "m4a", "aac", "opus", "wma" },
})
```

## 说明

- 关闭播放器 buffer（`q`）会 **停止** 播放。
- **播放器 buffer 不在任何窗口显示时**会停止出声（切换走 / 关窗都会）。
- **退出 Neovim** 时会结束托管播放进程，并强制结束本机所有 `ffplay`（防残留）。
- 可视化为基于时间的伪频谱，不解析真实音频波形（实现简单、CPU 低）。
- 旧版 `ffplay` 可能忽略部分参数，基本播放一般仍可用。
