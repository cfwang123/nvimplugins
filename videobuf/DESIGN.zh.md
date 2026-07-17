# videobuf 功能设计

> 在 Neovim **内嵌**预览/播放视频：上方画面区全刷渲染，下方字幕 + 控制文本（对齐 music）。  
> 前提验证：`:ImgbufAnimTest` 在真彩 ANSI 全刷路径下 **10fps 流畅**，可作为画面刷新基线。  
> **明确不做**：外挂播放器、HD 像素叠层。

[English](DESIGN.md) | **中文**

![videobuf 截图](../images/videobuf.png)

---

## 1. 目标与非目标

### 1.1 目标

| 项 | 说明 |
|----|------|
| 打开即播 | `:e video.mp4` / `:Videobuf path` 进入预览 buffer |
| 单 buffer 布局 | **上方**视频画面，**下方**字幕行 + 固定控制文本区 |
| 纯内嵌 | 画面与声音均在 Neovim/守护进程内完成，**不**调起系统/mpv 等外挂播放 |
| 可控播放 | 播放/暂停、seek、音量、停止、重播 |
| FPS 实时可调 | 播放中随时升/降目标帧率，状态行与后端同步 |
| 字幕 | 同 music 歌词：同名时间轴文件，内嵌当前句高亮 |
| 体验一致 | 快捷键与可点文字对齐 **music**；打开/文件树友好对齐 **imgbuf** |
| 可降级 | 解码能力不足时：静止首帧 + 仍可听音频（若有）/ 提示依赖；**不**引导外挂播放 |

### 1.2 非目标

- **外挂播放**：系统默认播放器、`mpv` 外窗、`o` 外开、vo=kitty 外接画面等一律不做
- **HD 叠层**：不做 Kitty/iTerm/WezTerm 像素图叠层；仅真彩色块 / 字符画
- 剪辑、字幕烧录进画面、多轨混音
- 浏览器级 30/60fps 高清（预览以可调 FPS 为产品手段，默认 **10**）
- 在 nvim 内实现完整播放器生态（列表云同步、在线流等）

---

## 2. 界面布局（单 buffer）

```
┌──────────────────────────────────────────────────────────┐
│                                                          │
│                   视频画面区 (主区域)                      │
│              真彩色块 / 字符画（无 HD 叠层）                │
│           占满窗口高度 − 字幕行 − 控制区行数                 │
│                                                          │
├──────────────────────────────────────────────────────────┤
│  [已唱部分加深] 当前字幕 / 双语  [未唱灰色]                 │  ← 字幕行（同 music）
│ 文件名 · 01:23/05:40 · ♪70 · fps:10 · ▶播放               │  ← 状态行
│ [========●----------------]  可点击/拖动进度条              │  ← 进度行
│ 播放Space  停止x  重播r  循环:关L  字幕g  fps-[,]+  关闭q │  ← 按钮行
└──────────────────────────────────────────────────────────┘
```

### 2.1 分区规则

| 区域 | 行数 | 内容 | 刷新策略 |
|------|------|------|----------|
| **画面区** | `win_height − bottom_rows` | 当前视频帧（ANSI 色块/字符画） | 按**当前目标 FPS** 全刷 |
| **字幕行** | 1（可关） | 当前句；双语可同屏；已唱加深（同 music） | 随 position dirty 刷新 |
| **状态行** | 1 | 标题、时间、音量、**目标/实测 fps**、状态 | dirty 局部刷新 |
| **进度行** | 1 | 可拖动进度条 | dirty 局部刷新 |
| **按钮行** | 1（可选 +1 帮助） | 文字按钮 + 快捷键标注 | 状态变化时刷新 |

- 底部默认 **4 行**：字幕 + 状态 + 进度 + 按钮。  
  - `show_lyrics = false` 时无字幕行 → 3 行。  
  - `show_help = true` 时可再 +1 行提示。
- 窗口缩放：重算 `cols / video_rows`，通知后端 `resize`，继续播。
- 禁止滚动：锁 `topline`，屏蔽 j/k 等（同 imgbuf/music）。

### 2.2 字幕行（对齐 music）

| 项 | 说明 |
|----|------|
| 文件 | 与视频同目录、同名：`demo.mp4` → `demo.lrc` 或 `demo.srt`（优先 lrc，其次 srt） |
| 内嵌 | 控制区**上方一行**显示当前句（中英时间接近则同时显示，同 music ≤0.08s 组） |
| 高亮 | 已唱部分**深色/深橙**，未唱灰色（按句内进度估算） |
| 全文 | `g`：上方分屏打开全文字幕，当前句滚动定位（同 music 歌词窗） |
| 无文件 | 字幕行显示占位或空行（可配置隐藏空字幕行） |

### 2.3 FPS 实时调节

| 项 | 说明 |
|----|------|
| 默认 | `fps = 10` |
| 范围 | 建议 `fps_min = 1` … `fps_max = 30`（配置可改） |
| 快捷键 | `[` 降低、`]` 升高（步进默认 1）；按钮行显示 `fps:10` 可点 |
| 生效 | **播放中立即生效**：nvim 改本地目标间隔 + 向后端发 `{"cmd":"fps","fps":N}` |
| 展示 | 状态行：`fps:10`（目标）；调试可显示 `avg≈9.8`（实测） |
| 自适应（可选 P2） | draw 连续超时可**建议**降 fps，但用户手动设置优先、不被静默覆盖 |

### 2.4 布局实现注意

| 方案 | 说明 | 建议 |
|------|------|------|
| **A. 单一 terminal + 分区写** | 画面 ANSI 全刷，底栏每帧重画 | 实现简单；底栏易闪 |
| **B. 单一 terminal：画面全刷，底栏定位覆写** | 帧循环只写 `video_rows`，字幕/控制独立更新 | **首版推荐** |
| **C. 上下两个 window** | 上画面 / 下普通 buffer | 分屏管理复杂，暂不采用 |
| **D. 普通 buffer + extmark 画画面** | set_lines 色块 | 易触发 highlight 组数上限，不作主路径 |

**首版采用 B**：一个 terminal buffer；画面按目标 FPS 全刷；字幕与控制行按需更新。

---

## 3. 功能列表

### 3.1 P0 — 最小可用（MVP）

| ID | 功能 | 说明 |
|----|------|------|
| F01 | 打开视频 | `mp4` / `mkv` / `webm` / `avi` / `mov` 等；`:Videobuf` / `:e` 自动进入 |
| F02 | 布局 | 上画面 + 下（字幕行 + 状态 + 进度 + 按钮） |
| F03 | 播放 / 暂停 | `Space`；按钮文字同步 |
| F04 | 停止 | `x`：停在 0 或当前帧静止 |
| F05 | 进度显示 | `当前位置 / 总时长` |
| F06 | 进度条 | 点击 / 拖动 seek |
| F07 | 键盘 seek | `h`/`l` ±5s；`H`/`L` ±30s |
| F08 | 音量 | `+`/`-`、上下方向键；0–100 |
| F09 | 关闭 | `q`：停播、结束守护任务、关 buffer |
| F10 | 单例 | 全局仅一个 videobuf；再开替换当前 |
| F11 | 首帧 | 打开时至少显示一帧 |
| F12 | 目标帧率 | 默认 10fps；路径对齐 animtest |
| F13 | **FPS 实时调节** | `[`/`]` 或命令修改，播放中立即生效 |
| F14 | **字幕行** | 同 music：内嵌当前句 + 时间轴同步 |

### 3.2 P1 — 好用

| ID | 功能 | 说明 |
|----|------|------|
| F20 | 重播 | `r`：seek 0 并播放 |
| F21 | 循环 | `L`：单文件循环 开/关 |
| F22 | 静音 | `m`：静音与恢复 |
| F23 | 字幕全文窗 | `g`：分屏全文 + 当前句定位（同 music） |
| F24 | 元信息 | 分辨率、编码（ffprobe）；`i` 或状态区 |
| F25 | 文件树友好 | 不误占侧栏（抄 imgbuf） |
| F26 | 窗口缩放 | 防抖 resize 后继续播 |
| F27 | 同目录切换 | `PgUp` / `PgDn` |
| F28 | 列表 | `f`：同目录视频列表 |
| F29 | 会话恢复 | path + position + **fps** |
| F30 | 隐藏 UI 继续播 | 可选 `Alt+V`：隐藏窗口，**音频继续、画面停更**（仍非外挂） |
| F31 | 播放速度 | 若后端支持：0.5x / 1x / 1.5x / 2x（与 FPS 调节独立） |

### 3.3 P2 — 增强画面（仍无 HD、无外挂）

| ID | 功能 | 说明 |
|----|------|------|
| F40 | 字符模式 | `1` block / `2` half / `3` braille |
| F41 | 缩放模式 | `s`：fit ↔ fill |
| F42 | FPS 建议降档 | draw 超时提示或可选自动建议（不覆盖用户锁定） |
| F43 | 仅音频模式 | 画面停刷，只播音轨（弱机器）；字幕与控制仍更新 |
| F44 | 多格式字幕 | `.lrc` / `.srt`；基础 `.ass` 抽白文本（可选） |

### 3.4 P3 — 兼容与边界

| ID | 功能 | 说明 |
|----|------|------|
| F50 | 后端：内嵌帧流 | **唯一主路径**：Python + ffmpeg 抽帧 + 音频时钟 |
| F51 | 无 ffmpeg | 明确报错/依赖提示；可尝试仅音频（若库可读）+ 无画面占位 |
| F52 | 无字幕文件 | 字幕行空或隐藏；不影响播放 |
| F53 | 不做剪贴板视频 | 与图片不同 |

### 3.5 明确删除 / 不做的功能

| 原设想 | 处理 |
|--------|------|
| 系统播放器打开（`o`） | **删除** |
| mpv / 外窗 / IPC 外挂画面 | **删除** |
| 仅封面 + 提示外开 | **删除**（可静止首帧，但不外开） |
| HD 像素叠层 | **删除** |
| 依赖 imgbuf.graphics | **不依赖** |

---

## 4. 交互设计

### 4.1 快捷键（默认）

| 键 | 动作 |
|----|------|
| `Space` | 播放 / 暂停 |
| `x` | 停止 |
| `r` | 重播 |
| `L` | 循环开关 |
| `m` | 静音 |
| `g` | 字幕全文窗显隐 |
| `h` / `l` | −5s / +5s |
| `H` / `L` | −30s / +30s |
| `+` / `-` | 音量 ±5 |
| `↑` / `↓` | 音量 |
| `[` / `]` | **目标 FPS −1 / +1**（实时） |
| `PgUp` / `PgDn` | 同目录上/下一个视频 |
| `f` | 同目录列表 |
| `s` | fit / fill |
| `1` `2` `3` | 字符画模式 |
| `q` | 关闭并停止 |
| 进度条 | 鼠标点击 / 拖动 |
| 文字按钮 | 鼠标点击（同 music） |

### 4.2 按钮行文案示例

```text
 暂停Space  停止x  重播r  循环:关L  字幕g  fps:10[,]+  列表f  关闭q
```

- 播放中：「暂停Space」；暂停时：「播放Space」。  
- `fps:10` 显示当前目标；`[` / `]` 在按钮标注中提示。

### 4.3 状态行文案示例

```text
 demo.mp4  │  01:23/05:40  │  ♪70  │  fps:10  │  ▶播放
```

可选调试：`fps:10 (avg 9.7)`。

### 4.4 字幕行文案示例

```text
  Already sung part... | current line bilingual
```

无字幕时：` （无字幕）` 或留空（由 `show_lyrics` / `hide_empty_lyrics` 控制）。

---

## 5. 命令与配置

### 5.1 用户命令

| 命令 | 说明 |
|------|------|
| `:Videobuf [path]` | 打开视频；无参则用当前文件 |
| `:VideobufToggle` | 播放/暂停 |
| `:VideobufStop` | 停止 |
| `:VideobufNext` / `:VideobufPrev` | 同目录切换 |
| `:VideobufFps [n]` | 设置目标 FPS（实时）；无参打印当前值 |
| `:VideobufClose` | 关闭 |
| `:VideobufAnimTest [fps]` | 全刷测试（可迁入） |

### 5.2 配置草案

```lua
require("videobuf").setup({
  auto_open = true,
  auto_play = true,
  fps = 10,                 -- 默认目标帧率
  fps_min = 1,              -- 实时调节下限
  fps_max = 30,             -- 实时调节上限
  fps_step = 1,             -- [ ] 步进
  volume = 70,
  loop = false,
  scale = "fit",            -- "fit" | "fill"
  mode = "block",           -- "block" | "half" | "braille"
  show_lyrics = true,       -- 字幕行
  hide_empty_lyrics = false,-- 无字幕时是否隐藏该行
  control_rows = nil,       -- nil=按 show_lyrics/help 自动（字幕+3 或 3）
  show_help = false,
  backend = "ffmpeg",       -- 仅内嵌；无 mpv/外挂
  seek_step = 5,
  seek_step_large = 30,
  python = "python",
  filetypes = { "mp4", "mkv", "webm", "avi", "mov", "m4v", "wmv", "flv" },
  toggle_key = "<M-v>",     -- 显隐 UI（可选，仍为内嵌后台）
})
```

---

## 6. 架构设计

### 6.1 目录结构（规划）

```text
videobuf/
  DESIGN.zh.md          ← 本文件
  DESIGN.md             ← 英文（可选）
  README.zh.md
  README.md
  plugin/videobuf.lua
  lua/videobuf/
    init.lua            -- setup / 命令 / 单例 / auto_open
    ui.lua              -- 字幕行 + 控制区、按钮、进度条、fps 显示
    lyrics.lua          -- 字幕加载/同步（可抄 music/lyrics）
    frame.lua           -- 画面尺寸、ANSI 帧写出、按目标 FPS 调度
    player.lua          -- 与 videod.py JSON 通信
    playlist.lua        -- 同目录列表
  scripts/
    videod.py           -- 抽帧 + 音频 + 时钟（唯一播放后端）
```

### 6.2 数据流

```text
        ┌──────────────────────────────────────────┐
        │                 Neovim                    │
        │  videobuf buffer (terminal, 无 HD)         │
        │  ┌──────────┐ ┌─────────┐ ┌────────────┐  │
        │  │ frame.lua│ │lyrics.lua│ │ ui.lua     │  │
        │  │ 画面全刷  │ │ 字幕行   │ │ 状态/进度/键│  │
        │  └────▲─────┘ └────▲────┘ └─────▲──────┘  │
        │       │ frame      │ position   │ status  │
        │  player.lua ◄──────┴────────────┘         │
        └──────────────┼────────────────────────────┘
                       │ stdin/stdout JSON
                       ▼
                scripts/videod.py
                  · ffmpeg 解码/抽帧（内嵌）
                  · 音频 just_playback / pygame
                  · 音频时钟选帧
                  · 接受实时 fps 变更
```

### 6.3 后端协议（草案，对齐 music）

**请求 nvim → python：**

```json
{"cmd":"open","path":"...","fps":10,"cols":120,"rows":30,"scale":"fit","volume":70,"start":0}
{"cmd":"play"} | {"cmd":"pause"} | {"cmd":"toggle"} | {"cmd":"stop"}
{"cmd":"seek","position":12.3}
{"cmd":"volume","volume":50}
{"cmd":"fps","fps":12}
{"cmd":"resize","cols":100,"rows":28,"scale":"fit"}
{"cmd":"loop","loop":true}
{"cmd":"status"} | {"cmd":"quit"}
```

**响应 python → nvim：**

```json
{"ok":true,"event":"status","status":"playing","path":"...","position":1.2,"duration":180.0,"volume":70,"fps":12,"width":1920,"height":1080}
{"ok":true,"event":"frame","format":"ansi","cols":120,"rows":30,"seq":42,"position":1.25,"data":"...ANSI..."}
{"ok":true,"event":"ended","path":"..."}
{"ok":false,"error":"..."}
```

> `frame.data` 也可改为临时文件/长度前缀二进制，避免超大 JSON 行。

### 6.4 音画与字幕同步

1. **音频时钟为主**，视频按目标 FPS 取帧，来不及则丢帧。  
2. 字幕与进度以同一 `position` 驱动（同 music 歌词）。  
3. 暂停：停音频 + 停帧；保留最后一帧与当前字幕。  
4. seek：清帧队列 → 关键帧 + 字幕重定位 → 再播。  
5. 改 FPS：只改画面取样密度，**不**改变音频播放速度（速度另键，若做）。

### 6.5 与现有插件关系

| 插件 | 复用点 |
|------|--------|
| **music** | JSON 守护进程、进度条、按钮、列表、会话、单例、**歌词/字幕同步与全文窗** |
| **imgbuf** | 文件树友好、字符模式、fit/fill、terminal 打开方式（**不**用 graphics/HD） |
| **animtest** | 全刷性能基线；FPS 调节手感可参考 |

挂载：根 `plugin/nvimplugins.lua` 的 `default_plugins` 增加 `"videobuf"`。

---

## 7. 依赖

| 组件 | 要求 | 用途 |
|------|------|------|
| Neovim | 0.9+（推荐 0.10+） | UI / job / timer |
| ffmpeg / ffprobe | **必装（内嵌抽帧）** | 时长、抽帧 |
| Python 3 | PATH 可执行 | 守护进程 |
| just_playback 或 pygame | 与 music 相同 | 音轨 |
| Pillow（可选） | 帧缩放 | 字符画前处理 |
| chafa（可选） | 帧→字符 | 可与自研 ANSI 二选一 |
| 真彩色终端 | `termguicolors` | 色块画面 |

**不依赖**：mpv、系统默认播放器调用、Kitty/iTerm 图形协议、imgbuf.graphics。

---

## 8. 实现分期

### Phase 0 — 已完成验证

- [x] `:ImgbufAnimTest` 全刷 10fps 流畅

### Phase 1 — MVP（P0 画面 + 控制 + FPS）

- [x] 插件骨架 + auto_open + 单例  
- [x] 上画面 / 下控制布局（含字幕行）  
- [x] ffmpeg 内嵌抽帧 + 按目标 FPS 全刷  
- [x] 播放/暂停/停止/seek/进度条  
- [x] **FPS 实时调节**（`[`/`]`、`:VideobufFps`）  
- [x] 音量 + 状态行  

**验收**：内嵌能动；改 FPS 立即影响画面刷新；无任何外挂拉起。  
**实现备注（2026-07-17）**：已落地可测；抽帧参数兼容旧版 ffmpeg（避免 `-hide_banner` / `force_original_aspect_ratio`）。

### Phase 2 — 音画 + 字幕（P0 收尾 + P1）

- [x] 音频轨 + 音频时钟同步（有音轨时抽 wav；无则墙钟）  
- [x] **字幕行 + `g` 全文窗**（lrc/srt）  
- [x] 循环 / 重播 / 静音  
- [x] 同目录切换（`PgUp`/`PgDn`）；列表 `f` 仍待  
- [x] 文件树友好 + resize  

**验收**：音画大致同步；有 lrc/srt 时字幕跟播；seek 后字幕正确。

### Phase 3 — 体验（P1/P2）

- [ ] 会话恢复（含 fps）  
- [ ] 显隐 UI 后台仅音频  
- [ ] block/half/braille、fit/fill  
- [ ] 仅音频模式、无 ffmpeg 明确报错  

**验收**：弱机器可降 FPS/关画面；不出现外挂或 HD 路径。

### Phase 4 — 可选增强

- [ ] 播放速度  
- [ ] 更丰富字幕格式  

---

## 9. 风险与对策

| 风险 | 对策 |
|------|------|
| 大窗口 draw 超时 | 限 max 分辨率；**用户实时降 fps**；fill 时先缩源帧 |
| JSON 整帧过大 | 临时文件 / 二进制帧通道 |
| Windows 终端性能 | 默认 10fps；提供 1–30 实时调节 |
| 音画不同步 | 音频主时钟 + 丢帧 |
| 字幕与画面错位 | 共用 position；seek 后重算句索引 |
| 终端残影 / resize | 停更 → 清屏 → resize → 再播 |
| 与 music 抢音频设备 | videobuf 打开时 pause music（互斥） |

---

## 10. 验收清单（产品视角）

1. `:e demo.mp4` 后内容窗变为 videobuf，不占文件树。  
2. 上方运动画面，下方可见**字幕行（若有）+ 控制三行**。  
3. 全程**无**系统播放器 / mpv 窗口弹出。  
4. **无** HD 像素叠层；仅字符画/色块。  
5. `Space`、进度拖动可靠；`[`/`]` **实时**改变刷新率并在状态行体现。  
6. 同名 `.lrc`/`.srt` 时字幕随进度更新；`g` 可开全文。  
7. `q` 后无残留 Python/ffmpeg 子进程。  

---

## 11. 命名与对外接口

| 项 | 值 |
|----|----|
| 插件名 | `videobuf` |
| 模块 | `require("videobuf")` |
| filetype | `videobuf` |
| 主要 API | `setup` / `open` / `toggle` / `stop` / `close` / `next` / `prev` / `set_fps` |

---

## 12. 修订记录

| 日期 | 说明 |
|------|------|
| 2026-07-17 | 初稿：animtest 基线；单 buffer 上视频下控制；P0–P3 分期 |
| 2026-07-17 | **修订**：取消外挂播放与 HD 叠层；增加字幕行（同 music）；FPS 实时可调；唯一后端内嵌 ffmpeg 帧流 |
