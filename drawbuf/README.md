# drawbuf.nvim

在 Neovim 里用 **Unicode 色块** 画画：鼠标拖拽、直线/矩形/椭圆预览、前景/背景色、可点击中文状态栏、彩色演示图案。

## 功能一览

| 能力 | 说明 |
|------|------|
| 色块笔刷 | **100%** `█`，**1/2** `▀▄▌▐`，**1/4·3/4** `▘▝▖▗▚▞▙▛▜▟` |
| 工具 | 铅笔、橡皮、直线、矩形、椭圆、填充 |
| 形状绘制 | **按下 → 拖动预览 → 松开确认**；`Esc` 取消；预览用当前前景/背景色 |
| 颜色 | 固定调色板；float 色板真彩色预览 |
| 状态栏 | 中文可点：工具 / 字符 / 前景 / 背景 / 演示 / 保存 / 退出 / 撤销 |
| 演示 | 笑脸、彩虹猫、狗、云、楼、彩虹 |
| 性能 | **增量重绘**（脏行），大画布更流畅 |
| 尺寸 | `:Draw` 默认适应窗口（扣 gutter），四周留 1 格白边 |

## 依赖

- Neovim 0.9+
- `set termguicolors`
- `set mouse=a`（打开画布时若为空会自动打开）

## 安装（vim-plug）

路径请改成你的本机目录。

**无需** `require('drawbuf').setup()`：插件加载后即用默认配置。  
需要改参数时再调用 `setup({ ... })`。

### 懒加载（推荐）

```vim
call plug#begin()

" on：执行 :Draw 时才加载
Plug 'D:/VS_Projects/AIPrototype/vim/drawbuf', {
  \ 'on': ['Draw'],
  \ }

call plug#end()

" 可选：改默认参数
" lua require('drawbuf').setup({ canvas_bg = '11111b' })
```

| 参数 | 含义 |
|------|------|
| `on` | 执行列出的 **Ex 命令** 时才加载插件 |

### 立即加载

```vim
call plug#begin()
Plug 'D:/VS_Projects/AIPrototype/vim/drawbuf'
call plug#end()

" 可选
" lua require('drawbuf').setup({ width = 100, height = 30 })
```

## 用法

```vim
:Draw              " 默认：适应当前窗口，四周留 1 格白边
:Draw 60x20        " 指定宽高
:Draw sketch.draw  " 打开已有文件
```

### 状态栏（鼠标点击）

| 按钮 | 作用 |
|------|------|
| `[铅笔 ▾]` | float 切换工具（含椭圆） |
| `[字符:█ ▾]` | float 选择色块 |
| `[前景:██ ▾]` / `[背景:██ ▾]` | float 选色（可见色块）；点外部关闭 |
| `[演示 ▾]` | 加载预制彩色图案 |
| `[保存]` `[退出]` `[撤销]` `[?]` | 对应操作 |

### 内置演示

| 名称 | 内容 |
|------|------|
| 笑脸 | 黄色笑脸、腮红、微笑 |
| 彩虹猫 | Nyan 风彩虹拖尾 + 猫 |
| 狗 | 卡通小狗、草地、骨头 |
| 云 | 蓝天白云、太阳、小鸟 |
| 楼 | 夜景城市楼群与灯光 |
| 彩虹 | 拱形彩虹与草地 |

### 快捷键

| 键 | 作用 |
|----|------|
| `hjkl` / 方向键 | 移动 |
| 鼠标左键拖 | 铅笔绘制；形状：起点→预览→终点 |
| 鼠标右键拖 | 擦除 |
| `Space` | 绘制 / 形状确认 |
| `Esc` | 取消形状 |
| `p` | 连续绘制开关 |
| `a`/`d`/`L`/`R`/`O`/`f` | 铅笔/橡皮/直线/矩形/椭圆/填充 |
| `[]` `,` `.` `<>` | 字符 / 前景 / 背景 |
| `u` / `Ctrl-r` | 撤销 / 重做 |
| `s` / `q` | 保存 / 退出 |

## 配置（可选）

不调用 `setup()` 时使用内置默认值。需要改参数时：

```lua
require("drawbuf").setup({
  width = 80,
  height = 24,
  canvas_bg = "ffffff", -- 默认白底；画笔默认取调色板中的黑色
  statusline = true,
  -- 其余见 lua/drawbuf/init.lua 的 default_config
})
```

可多次调用；后一次以默认值为底再合并你传入的字段。

## 文件格式 `.draw`

```
DRAWBUF 80 24
████▀▀▄▄...
COLORS
11112222...
BGCOLORS
00001111...
```

## 性能

绘制默认 **按脏行增量更新**；打开、演示、撤销等会全量刷新。

## 目录

```
drawbuf/
  plugin/drawbuf.lua
  lua/drawbuf/init.lua
  README.md
  .gitignore
```

## 相关

- 仓库总览：[../README.md](../README.md)
- 图片预览：[../imgbuf/README.md](../imgbuf/README.md)
