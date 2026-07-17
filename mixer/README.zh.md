# mixer.nvim

[English](README.md) | **中文**

在 Neovim 里播放 **MIDI** 与内置曲目：通过 Windows 自带 **`winmm.dll`**（MCI sequencer）走系统 MIDI 出端口（通常为 **Microsoft GS Wavetable Synth**）。

## 依赖

| 组件 | 说明 |
|------|------|
| **Windows** | 使用 `winmm.dll` |
| Neovim 0.9+ | |
| Python3 | 仅标准库（ctypes 调 DLL） |

## 安装

```vim
Plug '/path/to/nvimplugins/mixer'
" 或整仓 nvimplugins（默认包含 mixer）
```

## 用法

| 操作 | 说明 |
|------|------|
| **打开 `.mid` / `.midi`** | 自动变成精简播放器并开始播放（`auto_open`） |
| `:Mixer` | 打开空播放器 |
| `:Mixer twinkle` | 加载预设并播放 |
| `:Mixer path/to/song.mid` | 播放指定 MIDI |
| `:MixerStop` | 停止 |
| `<leader>mx` | 打开播放器（可配置） |

### 播放器（对齐 music 精简条）

仅 4 行：**标题 · 状态/时间/音量 · 进度条 · 按钮**。禁止选字与滚动。

| 键 / 按钮 | 作用 |
|-----------|------|
| `Space` / 播放·暂停 | 播放 / 暂停 |
| `x` / 停止 | 停止 |
| `f` / 曲目 | **浮窗**选择内置预设 |
| `L` / 中英 | 界面语言 |
| `+` / `-` | 音量 |
| `q` | 关闭并停止 |

### 内置预设（`f` 浮窗）

| id | 曲目 |
|----|------|
| `twinkle` | 小星星 |
| `ode` | 欢乐颂片段 |
| `scales` | 多音色音阶巡演 |
| `groove` | 迷你律动（含鼓组通道） |
| `sakura` | 五声音韵 |

预设写成临时 `.mid` 后由 `winmm` 播放。

## 配置

```lua
require("mixer").setup({
  python = "python",
  volume = 70,
  auto_open = true,  -- 打开 .mid 自动进入播放器
  auto_play = true,
  fit_height = true, -- 上下分屏时按内容压高度；独占整列不改高度
  ui_lang = "auto",  -- "zh" | "en" | "auto"
  keys_open = "<leader>mx",
})
```

## 说明

- 播放链路：`Python` → `ctypes` → **`winmm.dll` `mciSendString`** → 系统 MIDI 合成器。
- 音色取决于系统 MIDI 设备（通常 Microsoft GS Wavetable Synth）。
- 仅 **Windows** + **`.mid` / `.midi`**。
- **高度**：与 music 相同——仅当窗口在**上下分屏**（竖直方向还有其它窗）时自动适配内容高度；唯一窗口或 vsplit 整列独占时不强制高度。
- 无声时检查系统音量、默认设备与 GS 合成器是否启用。

## 目录

```
mixer/
  plugin/mixer.lua
  lua/mixer/
  scripts/midi_synth.py
  README.md
  README.zh.md
```
