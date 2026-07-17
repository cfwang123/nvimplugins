# nvimplugins

[English](README.md) | **中文**

> **About** — 面向 Neovim 的小型实验与工具插件集合：含 **mdview**（Markdown 预览）、**pdfview** / **xlsview**（文档表格预览）、**tts**（Windows 朗读）、**imgbuf**（图片）、**music** / **mixer**（音频与 MIDI）、**nvimgames**（小游戏）、**drawbuf**（色块绘图）、**videobuf**（视频）、**es**（Everything 搜文件）。各插件可独立安装，互不强制依赖。

面向终端里「好玩、好用、少依赖」的实验与日常小工具。多数 UI 支持**中/英文**切换（默认跟随系统语言，可记忆）。

**两种装法任选其一：**

| 方式 | 说明 |
|------|------|
| **整仓（网络）** | 只需一行 `Plug 'cfwang123/nvimplugins'`；根目录 `plugin/nvimplugins.lua` 自动加载全部子插件 |
| **分目录（本地路径）** | 只 `Plug` 需要的子文件夹（如 `…/mdview`） |

## 插件一览

| 插件 | 简介 | 文档 |
|------|------|------|
| **[mdview](mdview/)** | Markdown 预览：单窗（`:MdView`）或侧边对照（`:MdSideView`）。标题/列表/GFM 表/代码块、TOC、链接锚点、色块图与可选高清叠层。预览内 **`L`** 切换中英文。 | [EN](mdview/README.md) · [中文](mdview/README.zh.md) |
| **[pdfview](pdfview/)** | PDF / Word 预览：文字样式、表格、chafa 图；Enter/点击 float 高清，`gh` 页内临时高清。**`L`** 切换中英文。 | [EN](pdfview/README.md) · [中文](pdfview/README.zh.md) |
| **[xlsview](xlsview/)** | Excel（.xlsx/.xlsm）预览：单元格颜色/粗体/底色、多工作表、列宽适配窗口。**`L`** 切换中英文。 | [EN](xlsview/README.md) · [中文](xlsview/README.zh.md) |
| **[tts](tts/)** | Windows SAPI 朗读：`<leader>vo` **从光标所在段起播**（播放中再按可跳段）；控制条白底；音量/滚轮/语速；系统默认输出设备；**EN/中文** 按钮或 **`L`**。 | [EN](tts/README.md) · [中文](tts/README.zh.md) |
| **[imgbuf](imgbuf/)** | 图片字符画（block/half/braille），等比/拉伸；自动预览、剪贴板；WezTerm/Kitty/Ghostty 可选像素高清。底栏 **`L`** 中英文。 | [EN](imgbuf/README.md) · [中文](imgbuf/README.zh.md) |
| **[music](music/)** | 打开音频即 buffer 播放器：播放/暂停/进度条、音量、同目录切歌与列表、LRC 歌词、会话恢复。Python 后台播，可隐藏 UI。**`Y`** 或按钮切换中英文。 | [EN](music/README.md) · [中文](music/README.zh.md) |
| **[mixer](mixer/)** | Windows **winmm.dll** 播放 MIDI / 内置预设；`:Mixer` / `<leader>mx`。 | [EN](mixer/README.md) · [中文](mixer/README.zh.md) |
| **[nvimgames](nvimgames/)** | 扫雷、推箱子、**24 点**、俄罗斯方块。`:NvimGames` 选单。各游戏内 **`u`**（或按钮）切换中英文。 | [EN](nvimgames/README.md) · [中文](nvimgames/README.zh.md) |
| **[drawbuf](drawbuf/)** | Unicode 色块画布：铅笔/橡皮/直线/矩形/椭圆/填充、真彩色、可点状态栏、撤销、`.draw` 存盘与演示图。状态栏 **`[中英]`** 或 **`Y`** 切换语言。 | [EN](drawbuf/README.md) · [中文](drawbuf/README.zh.md) |
| **[videobuf](videobuf/)** | 终端视频预览（字符画帧 + 控制条）；与 music 类似的守护进程模式。 | [EN](videobuf/README.md) · [中文](videobuf/README.zh.md) |
| **[es](es/)** | Windows **Everything** 文件搜索（`es.exe`）：`:ES` / `<leader>es` 浮窗即时搜，回车打开。 | [EN](es/README.md) · [中文](es/README.zh.md) |

## 界面语言（中 / 英）

多数插件 UI 支持中英文，默认 **`ui_lang = "auto"`**（读系统语言；识别失败多为中文）。手动切换后写入 `stdpath("data")/*-nvim-prefs.json`，下次沿用。

| 插件 | 切换方式 |
|------|----------|
| mdview / pdfview / xlsview / imgbuf | 预览内 **`L`** |
| tts | 控制条 **EN / 中文** 或 **`L`** |
| music / mixer | 按钮 **中英(Y)** 或 **`Y`**（music 的 `L` 为单曲循环） |
| nvimgames（含 24 点） | 底栏按钮或 **`u`** |
| drawbuf | 状态栏 **[中英]** 或 **`Y`**（`L` 为直线工具） |
| es | 浮窗内 **`L`** 或 **`Ctrl-l`**（默认跟随系统语言，可记忆） |

```lua
require("mdview").setup({ ui_lang = "auto" }) -- 或 "zh" | "en"
require("tts").setup({ ui_lang = "zh" })
```

## 截图

**mdview**

![mdview](images/mdview.png)

**pdfview**（PDF）

![pdfview](images/pdfview-pdf.png)

**xlsview**

![xlsview](images/xlsview.png)

**tts**

![tts](images/tts.png)

**imgbuf**

![imgbuf](images/imgbuf.png)

**music**

![music](images/music.png)

**nvimgames** — 扫雷

![扫雷](images/mine.png)

**nvimgames** — 推箱子

![推箱子](images/sokoban.png)

**nvimgames** — 24点

![24点](images/twentyfour.png)

**nvimgames** — 俄罗斯方块

![俄罗斯方块](images/tetris.png)

**drawbuf**

![drawbuf](images/drawbuf.png)

**videobuf**

![videobuf](images/videobuf.png)

**es**（Everything 文件搜索）

![es](images/es.png)

mdview 更多场景见 [mdview/testdata/screenshots/](mdview/testdata/screenshots/) 与演示文 [mdview/testdata/demo.md](mdview/testdata/demo.md)。  
tts 测试稿：[tts/testdata/](tts/testdata/)（`sample.zh.txt` / `sample.en.txt`）。

## 依赖摘要

| 插件 | Neovim | 其他 |
|------|--------|------|
| mdview | 0.9+ | 核心无额外依赖；色块图需 Pillow（或 chafa）；代码高亮可选 Tree-sitter；像素高清需图形协议终端 |
| pdfview | 0.9+ | PDF：PyMuPDF；DOCX：仅标准库；DOC：可选 LibreOffice；图片 chafa/Pillow；高清 WezTerm/Kitty/Ghostty |
| xlsview | 0.9+ | Python3 + **openpyxl** |
| tts | 0.9+ | **Windows** + SAPI；Python3 + **pywin32** |
| imgbuf | 0.9+ | chafa **或** Python3 + Pillow；高清需 WezTerm/Kitty/Ghostty + Pillow |
| music | 0.9+ | Python3 + **just_playback**（或 pygame 回退） |
| mixer | 0.9+ | **Windows** + Python3（**winmm.dll**，标准库 ctypes） |
| nvimgames | 0.9+ | `termguicolors`；扫雷建议 `mouse=a`；推箱子自带 `data/levels.json` |
| drawbuf | 0.9+ | `termguicolors`；建议 `mouse=a` |
| videobuf | 0.9+ | Python3 + **av**（或 opencv-python）+ **just_playback** |
| es | 0.9+ | **Windows** + [Everything](https://www.voidtools.com/) + [es.exe CLI](https://www.voidtools.com/support/everything/command_line_interface/) |

**启动自动检测**：加载后只检查**必需** pip 包；缺失时弹出安装选项。安装过程打开预览窗口显示 pip 实时输出，结束后通知结果。  
- 含推荐包的完整检查：`:NvimpluginsDeps`（可跟插件名）  
- 调试探测：`:NvimpluginsDepsProbe`  
- 关闭提示：`let g:nvimplugins_skip_deps = 1`  
- 不询问直接装：`let g:nvimplugins_auto_install_deps = 1`  
- 推荐包可在菜单中选「忽略不再提示」（写入 `stdpath('data')/nvimplugins_deps.json`）  
本仓库 **无 npm 依赖**。

## 快速安装

**不必**统一 `setup()`（要改参数时再 `require(...).setup`）。  
整仓与分目录**不要混装同一批插件**；若混装，子插件有 `loaded_*` 守卫，一般不会重复注册命令，但 `rtp` 会多一份路径。

### 方式 A：整仓 — vim-plug 网络安装（推荐「全要」）

仓库：[cfwang123/nvimplugins](https://github.com/cfwang123/nvimplugins)。

**安装只需一行 `Plug`**，不必在用户 init 里写 bootstrap。`plug#end()` 之后即可 `require("imgbuf")` 等（根目录 `lua/*` 代理）；命令由启动时加载的 `plugin/nvimplugins.*` 注册。

#### vim-plug

```vim
call plug#begin()
Plug 'cfwang123/nvimplugins'
call plug#end()
```

首次执行 **`:PlugInstall`**（更新用 `:PlugUpdate`）。若改参数，再在 `plug#end()` **之后**可选写 `require("…").setup({...})`（属于配置，不是安装）。

可选：只启用部分子插件（在加载前设置，名与目录一致）：

```vim
let g:nvimplugins_enable = ['mdview', 'pdfview', 'xlsview', 'tts', 'imgbuf', 'music', 'mixer', 'nvimgames']
```

整仓默认启用：`mdview` · `pdfview` · `xlsview` · `tts` · `imgbuf` · `music` · `mixer` · `nvimgames` · `drawbuf` · `videobuf`。

#### lazy.nvim

```lua
{ "cfwang123/nvimplugins", lazy = false }
```

### 方式 B：分目录 — 本地路径（推荐「只要某几个」）

#### vim-plug

```vim
call plug#begin()
Plug '/path/to/nvimplugins/mdview'
Plug '/path/to/nvimplugins/pdfview'
Plug '/path/to/nvimplugins/xlsview'
Plug '/path/to/nvimplugins/tts'
Plug '/path/to/nvimplugins/imgbuf'
Plug '/path/to/nvimplugins/music'
Plug '/path/to/nvimplugins/mixer'
Plug '/path/to/nvimplugins/nvimgames'
Plug '/path/to/nvimplugins/drawbuf'
Plug '/path/to/nvimplugins/videobuf'
call plug#end()
```

#### lazy.nvim（示例）

```lua
{
  { dir = "/path/to/nvimplugins/mdview", name = "mdview", lazy = false },
  { dir = "/path/to/nvimplugins/pdfview", name = "pdfview", lazy = false },
  { dir = "/path/to/nvimplugins/xlsview", name = "xlsview", lazy = false },
  { dir = "/path/to/nvimplugins/tts", name = "tts", lazy = false },
  { dir = "/path/to/nvimplugins/imgbuf", name = "imgbuf", lazy = false },
  { dir = "/path/to/nvimplugins/music", name = "music", lazy = false },
  { dir = "/path/to/nvimplugins/mixer", name = "mixer", lazy = false },
  { dir = "/path/to/nvimplugins/nvimgames", name = "nvimgames", lazy = false },
  { dir = "/path/to/nvimplugins/drawbuf", name = "drawbuf", lazy = false },
  { dir = "/path/to/nvimplugins/videobuf", name = "videobuf", lazy = false },
}
```

各插件从简到全的安装说明见子目录 README（mdview 有 ①最简 → ③完整 分档）。

### 可选 `setup()`（分插件）

**全部可选。** 插件加载后即用默认配置。只有要改参数时才 `require("…").setup({ ... })`，写在插件已进入 `rtp` 之后（例如 `plug#end()` 之后）。

```lua
-- mdview — Markdown 预览
require("mdview").setup({
  split_direction = "right",
  width = 0.45,
  ui_lang = "auto", -- "auto" | "zh" | "en"；预览内 L 切换
  keys = { view = "<leader>mv", side = "<leader>ms" },
  image = {
    mode = "thumb",
    python = "python",
    float_hd = "always",
  },
})

-- pdfview — PDF / Word
require("pdfview").setup({
  auto_open = true,
  ui_lang = "auto", -- L 切换
  python = "python",
  image = {
    backend = "chafa",
    open_with = "float",
    float_hd = "always",
  },
})

-- xlsview — Excel
require("xlsview").setup({
  auto_open = true,
  ui_lang = "auto", -- L 切换
  python = "python",
  max_rows = 500,
  max_cols = 64,
})

-- tts — Windows SAPI 朗读
require("tts").setup({
  volume = 80,
  rate = 0,
  ui_lang = "auto", -- 控制条 EN/中文 或 L
  keys_play = "<leader>vo", -- 从光标段起播；播放中再按可跳段
  keys_stop = "<leader>vs",
  -- voice = "Huihui", -- 可选默认发音人；float 选择后会记住
})

-- imgbuf — 图片字符画 + 可选高清
require("imgbuf").setup({
  backend = "auto",
  mode = "block",
  scale = "fill",
  hd = "always",
  ui_lang = "auto", -- L 切换
  auto_open = true,
})

-- music — buffer 音频播放器
require("music").setup({
  volume = 70,
  auto_open = true,
  auto_play = true,
  toggle_key = "<M-m>",
  ui_lang = "auto", -- Y 切换；L 为单曲循环
  python = "python",
})

-- nvimgames — 小游戏（界面语言见 i18n / 游戏内 u）
require("nvimgames").setup({
  lang = "auto", -- "auto" | "zh" | "en"
  mine = { difficulty = "beginner" },
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
  ui_lang = "auto", -- 状态栏 [中英] 或 Y
})
```

完整选项见各子插件 README / `lua/*/config.lua`（或 `init.lua`）。

## 常用命令与快捷键（速查）

| 插件 | 命令 / 键 | 作用 |
|------|-----------|------|
| mdview | `<leader>mv` / `<leader>ms` · `L` | 单窗 / 侧边预览 · 中英文 |
| pdfview | 打开 pdf/docx · `L` · `gh` | 预览 · 中英文 · 页内高清 |
| xlsview | 打开 xlsx · `n`/`p` · `L` | 预览 · 换表 · 中英文 |
| tts | `<leader>vo` / `<leader>vs` · `L` | 从光标段播 / 停止 · 中英文 |
| imgbuf | 打开图片 · `L` | 预览 · 中英文 |
| music | 打开音频 · `<M-m>` · `Y` | 播放器 · 显隐 UI · 中英文 |
| mixer | `:Mixer` / `<leader>mx` · `L` | 混音器 · 中英文 |
| nvimgames | `:NvimGames` · 游戏内 `u` | 选单 · 中英文 |
| drawbuf | `:Draw` · `Y` | 画布 · 中英文 |

## 文档索引

| 插件 | 入口 |
|------|------|
| mdview | [EN](mdview/README.md) · [中文](mdview/README.zh.md) · [demo](mdview/testdata/demo.md) · [截图](mdview/testdata/screenshots/) |
| pdfview | [EN](pdfview/README.md) · [中文](pdfview/README.zh.md) |
| xlsview | [EN](xlsview/README.md) · [中文](xlsview/README.zh.md) |
| tts | [EN](tts/README.md) · [中文](tts/README.zh.md) · [测试稿](tts/testdata/) |
| imgbuf | [EN](imgbuf/README.md) · [中文](imgbuf/README.zh.md) |
| music | [EN](music/README.md) · [中文](music/README.zh.md) |
| mixer | [EN](mixer/README.md) · [中文](mixer/README.zh.md) |
| nvimgames | [EN](nvimgames/README.md) · [中文](nvimgames/README.zh.md) |
| drawbuf | [EN](drawbuf/README.md) · [中文](drawbuf/README.zh.md) |
| videobuf | [EN](videobuf/README.md) · [中文](videobuf/README.zh.md) · [设计](videobuf/DESIGN.zh.md) |

## 许可与说明

个人 / 原型向合集，按需拷贝子目录使用即可。问题与改动建议落在对应插件目录下。
