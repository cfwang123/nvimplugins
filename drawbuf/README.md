# drawbuf.nvim

**English** | [中文](README.zh.md)

Draw with **Unicode block characters** in Neovim: mouse drag, line/rect/ellipse preview, fg/bg colors, clickable Chinese status bar, and colorful demo patterns.

![drawbuf screenshot](../images/drawbuf.png)

## Features

| Feature | Description |
|---------|-------------|
| Block brushes | **100%** `█`, **1/2** `▀▄▌▐`, **1/4·3/4** `▘▝▖▗▚▞▙▛▜▟` |
| Tools | Pencil, eraser, line, rectangle, ellipse, fill |
| Shapes | **press → drag preview → release to commit**; `Esc` cancels; uses current fg/bg |
| Colors | Fixed palette; float picker with truecolor swatches |
| Status bar | Clickable: tool / glyph / fg / bg / demos / save / quit / undo |
| Demos | Smiley, Nyan-style cat, dog, clouds, city, rainbow |
| Performance | **Dirty-line** incremental redraw |
| Size | `:Draw` fits the window (minus gutter) with a 1-cell white margin |

## Dependencies

- Neovim 0.9+
- `set termguicolors`
- `set mouse=a` (enabled automatically if empty when opening the canvas)

## Install (vim-plug)

Use your local path.

**No** `require('drawbuf').setup()` is required. Call `setup` only to override options.

```vim
call plug#begin()
Plug '/path/to/nvimplugins/drawbuf'
call plug#end()

" optional
" lua require('drawbuf').setup({ width = 100, height = 30 })
```

## Usage

```vim
:Draw              " default: fit current window, 1-cell margin
:Draw 60x20        " fixed size
:Draw sketch.draw  " open existing file
```

### Status bar (mouse)

| Button | Action |
|--------|--------|
| `[铅笔 ▾]` | Float tool menu (incl. ellipse) |
| `[字符:█ ▾]` | Float glyph picker |
| `[前景:██ ▾]` / `[背景:██ ▾]` | Float color pickers |
| `[演示 ▾]` | Load demo art |
| `[保存]` | Save `.draw` |
| `[清空]` | Clear canvas (undoable; `C` same) |
| `[撤销]` `[退出]` `[?]` | Undo / quit / help |

### Built-in demos

| Name | Content |
|------|---------|
| 笑脸 | Yellow smiley |
| 彩虹猫 | Nyan-style cat + rainbow trail |
| 狗 | Cartoon dog, grass, bone |
| 云 | Sky, sun, birds |
| 楼 | Night city skyline |
| 彩虹 | Arc rainbow + grass |

### Keys

| Key | Action |
|-----|--------|
| `hjkl` / arrows | Move |
| LMB drag | Pencil / shape: start → preview → end |
| RMB drag | Erase |
| `Space` | Draw / confirm shape |
| `Esc` | Cancel shape |
| `p` | Continuous paint toggle |
| `a`/`d`/`L`/`R`/`O`/`f` | Pencil/eraser/line/rect/ellipse/fill |
| `[]` `,` `.` `<>` | Glyph / fg / bg |
| `u` / `Ctrl-r` | Undo / redo |
| `C` | Clear |
| `s` / `q` | Save / quit |

## Config (optional)

```lua
require("drawbuf").setup({
  width = 80,
  height = 24,
  canvas_bg = "ffffff", -- white canvas; brush defaults to palette black
  statusline = true,
  -- see default_config in lua/drawbuf/init.lua
})
```

## File format `.draw`

```
DRAWBUF 80 24
████▀▀▄▄...
COLORS
11112222...
BGCOLORS
00001111...
```

## Performance

Default draw path updates **dirty lines only**; open / demos / undo use full refresh.

## Layout

```
drawbuf/
  plugin/drawbuf.lua
  lua/drawbuf/init.lua
  README.md
  README.zh.md
  .gitignore
```

## Related

- Repo overview: [English](../README.md) · [中文](../README.zh.md)
- Image preview: [English](../imgbuf/README.md) · [中文](../imgbuf/README.zh.md)
