# music.nvim

打开**音频文件**时，在 **buffer** 里变成简易播放器（类似 imgbuf 打开图片）。

![music 截图](../images/music.png)

无播放列表：上一首 / 下一首 = **同目录**相邻音频（`PgUp` / `PgDn`；`f` 打开列表点选）。

## 播放后端（Python）

不再依赖 **mpv / ffplay** 一次性子进程。改为启动**一个长期运行的** `scripts/player.py`，通过 stdin/stdout JSON 控制：

| 能力 | 说明 |
|------|------|
| 播放 / 暂停 / 恢复 | 进程内控制 |
| 进度跳转 | 绝对秒数 seek（进度条拖动） |
| 音量 | 0–100 实时调节 |
| 时长 | mutagen（可选）/ wav / ffprobe（可选） |

底层引擎优先级：

1. **just_playback**（**首选**，seek / 进度 / 音量更稳）  
2. **pygame**（未安装 just_playback 时自动回退，并给出警告）

推荐安装：

```text
pip install just_playback
# 可选回退 / 时长：
pip install pygame mutagen
```

> 说明：从 Neovim 看仍会 `jobstart` 一个 Python 进程，但这是**可控守护进程**，不是无法遥控的 ffplay 窗口。

## 功能

| 能力 | 说明 |
|------|------|
| 打开即播 | `:e song.mp3` / `:Music song.mp3` |
| 播放控制 | 播放、暂停、重播、停止 |
| 同目录切换 | 下一首 / 上一首（按文件名排序） |
| 进度 | `当前 / 总长`（分:秒） |
| 进度条 | 可 **点击 / 拖动** 跳转 |
| 全局单例 | 全 Neovim 仅一个播放器 buffer；其它 tab 打开会关掉旧窗口 |
| 显隐 UI | `Alt+M`（可配）显示/隐藏；**底部分屏且不抢焦**；隐藏后后台继续播 |
| 隐藏状态栏 | 配置 `statusline_when_hidden` 后显示 `[歌名,1:22/3:33]` |
| 会话恢复 | 关闭/退出时保存文件夹、文件、进度；再次打开恢复 |
| Dirty 刷新 | 进度/歌词按行局部重绘，不整 buffer 闪烁 |
| 自动高度 | 仅**上下分屏**时按内容缩高度；整列只有 music 不改 |
| 文字按钮 | 无 emoji，带快捷键标注 |
| 禁止滚动 | 锁视图，屏蔽 j/k 等 |

## 依赖

| 组件 | 要求 |
|------|------|
| Neovim | 0.9+（推荐 0.10+） |
| Python 3 | `PATH` 中可执行 `python` |
| 音频库 | **just_playback**（首选）；**pygame** 作回退 |

```text
pip install just_playback
# 回退引擎（可选）：
pip install pygame
# 可选，读更多格式时长：
pip install mutagen
```

可选：`ffprobe` 用于时长探测回退。

鼠标：`set mouse=a`（拖动进度条；打开时若为空会自动打开）。

## 安装（vim-plug）

**无需** `setup()`：加载即用默认配置。

```vim
call plug#begin()
Plug '/path/to/vim/music'
call plug#end()

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

### 界面快捷键 / 可点文字

操作行示例：`上一首PgUp, 播放Space, 下一首PgDn, 停止x, 循环:关L, 重播r, 歌词g, 列表f, 关闭q`

| 操作 | 键 |
|------|-----|
| 播放/暂停 | `Space` |
| 上/下一首 | `PgUp` / `PgDn` |
| 停止 | `x` |
| 循环 | `L` |
| 重播 | `r` |
| 歌词 | `g`：上方分屏全文；播放器内嵌当前句（中英同时高亮）；已唱部分加深 |
| 列表 | `f`：同目录曲目列表显隐；打开后焦点在列表 |
| 焦点切换 | `Tab`：播放器 ↔ 列表（列表打开时） |
| 关闭并停止 | `q` |
| 进度 | 拖动进度条；`h`/`l` ±5s |
| 音量 | `+/-`、上/下方向键、滚轮 |
| 显示/隐藏 UI | `Alt+M`（隐藏后后台播） |

### 曲目列表（`f`）

| 操作 | 键 |
|------|-----|
| 上/下移动 | `↑` / `↓`（或 `k` / `j`） |
| 翻页 | `PgUp` / `PgDn` |
| 播放选中 | `Space` / `Enter` / 双击（播放后**自动关列表**） |
| 单击 | 仅选中 |
| 关闭列表 | `f` / `q` |
| 回播放器 | `Tab` |

### 歌词文件

与音频同目录、同名：`song.mp3` → `song.lrc`（标准 LRC 时间轴）：

```text
[00:12.00]第一句歌词
[00:15.50]第二句歌词
```

- 同一时间戳的中/英两行会**同时高亮**（时间差 ≤ 0.08s 视为一组）。
- 播放器内嵌歌词：已唱部分**深橙色**，未唱部分灰色（按句内进度估算）。
- 歌词窗内 `q`/`g` 可关闭。

## 配置（可选）

```lua
require("music").setup({
  volume = 70,
  auto_open = true,
  auto_play = true,
  auto_next = true,
  loop = false,
  fit_height = true,    -- 上下分屏时按内容缩高度
  toggle_key = "<M-m>", -- Alt+M 显示/隐藏
  poll_ms = 100,        -- 10f/s：进度条与歌词跟进
  -- 隐藏播放器 UI 时，状态栏显示 [歌名,1:22/3:33]
  statusline_when_hidden = false,
  python = "python",
})
```

`statusline_when_hidden = true` 时：

- 会写入 `g:music_statusline`，并尽量挂到 `statusline`（内置 statusline 或已有自定义串）。
- 也可自行接入：`%{g:music_statusline}` 或 `require('music').statusline()`（lualine 等）。

会话文件：`stdpath("data")/music-nvim-session.json`。

## 说明

- **`Alt+M` 隐藏** UI 时**继续播放**；再次 `Alt+M` 显示底栏且**焦点留在代码窗**。  
- 打开歌词面板后同样**回到代码窗**，少抢焦。  
- 无播放器时 `Alt+M` / `:Music` 无参：从上次文件+进度恢复。  
- **`q` 关闭**会停止播放并删除 buffer（仍会写入会话）。  
- 退出 Neovim 保存会话并结束 Python 守护进程。  
- 自动高度：竖直方向还有其它窗口时才缩高度；vsplit 整列只有 music 不改。  
- UI 刷新为 **dirty**（只改变化的行 / 高亮），进度轮询不再整 buffer 重写。  

