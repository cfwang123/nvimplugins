# colorpicker.nvim

[English](README.md) | **中文**

终端 **HSV 取色浮窗**：SV 平面 + H/S/V/A 滑条（真彩色）；确认后**插入**或**替换** CSS 颜色。文件内给每个色码**铺上该色底**（自动黑/白字）；**单击 hex 的 `#`** 可打开取色器。

## 依赖

| 组件 | 说明 |
|------|------|
| Neovim 0.9+ | **纯 Lua**，无 Python / 网络 |
| `termguicolors` | 打开时自动开启 |

## 安装

```vim
Plug '/path/to/nvimplugins/colorpicker'
" 或整仓 nvimplugins（默认包含 colorpicker）
```

```lua
{ "cfwang123/nvimplugins", lazy = false }  -- lazy.nvim 整仓
```

## 快速上手

1. **`<leader>co`** 或 **`:ColorPicker`** 打开  
2. **色相**：**`[`/`]`** 或 **`,`/`.`** 按 H 条 **1 格** 步进（可在 0° 与最右格之间**环绕**）  
3. **SV 平面**：**`h`/`l`** 饱和度 1 列，**`j`/`k`** 明度 1 行；或鼠标点选  
4. **透明度 A**（默认 100%）：**`5`** / **`a`** 聚焦后 **`h`/`l`** 或点 A 条  
5. **`Tab`** 切换输出格式；**`Enter`** / **双击** 完成；**`y`** 复制；**`q`** 取消；**`L`** 中英  

光标在 `#rrggbb` / `rgb()` / `hsl()` 等上时，打开会载入该色，完成时**替换**原 token。浮窗内禁止 visual 选中 UI 文字。

### 键盘步进（按格，不是 1% / 1°）

| 键 | 步进 |
|----|------|
| **`h` `l`** / **← →** | 当前焦点 **1 格**（平面上 = 饱和度列） |
| **`j` `k`** / **↓ ↑** | 平面上明度 **1 行**；在滑条焦点时切换通道 |
| **`[` `]`** / **`,` `.`** | 色相 **H 条 1 格**；在最左时 **`[`** → 最右，最右时 **`]`** → 最左 |
| **`+/-`** / **`{}`** / **`<>`** / **Shift+方向** | 粗调（默认 **5 格**） |

格数对齐 `plane_w` / `plane_h` / `bar_w`；数值贴格点。

### 文件内预览

- 每个 CSS 色码（`#rrggbb` / `rgb()` / `hsl()`）**直接铺该色底**，字色按亮度黑或白——不插入 **`██`**，不撑开行内代码、不打断折行  
- **单击 hex 的 `#`**（松开鼠标）→ 打开取色器并绑定替换  
- 点 `#` 后的数字或 `rgb(...)` 等 → **不弹窗**  
- **不拦截**鼠标拖动 visual 选文字  
- **`:ColorPickerPreview`** 手动刷新；大文件默认只扫可见区域  

## 命令

| 命令 | 说明 |
|------|------|
| **`:ColorPicker`** `[format]` | 打开；可选 `hex` / `rgb` / `rgba` / `hsl` / `hsla` / `hex_alpha` |
| **`:Colorpicker`** | 别名 |
| **`:ColorPickerClose`** | 关闭浮窗 |
| **`:ColorPickerPreview`** | 刷新文件内色码铺色 |

## 默认快捷键

| 键 | 作用 |
|----|------|
| **`<leader>co`** | 打开取色器 |
| **`,` `.`** / **`[` `]`** | 色相 1 格（环绕） |
| **`<` `>`** / **`{` `}`** | 色相粗调（默认 5 格） |
| **`h` `l`** / **← →** | 当前通道 1 格 |
| **`j` `k`** / **↓ ↑** | 平面明度 1 行 / 切换焦点 |
| **`+/-`** / **Shift+←→** | 粗调 5 格 |
| **`1`–`5`** / **`a`** / **`Space`** | 焦点 H/S/V/平面/A；循环 |
| **`Tab`** / **`f`** | 下一 CSS 格式 |
| **`Enter`** | 插入或替换并关闭 |
| **`y`** | 复制（不关闭） |
| **`w` / `b` / `r`** | 白 / 黑 / 重置 |
| **`L`** | 中英文 |
| **`q` / `Esc`** | 取消 |
| **鼠标单击** | 平面 / 滑条选色 |
| **鼠标双击** | 直接完成 |
| **单击文件内 `#`** | 打开并替换该 hex |

## 配置

```lua
require("colorpicker").setup({
  ui_lang = "auto",            -- "auto" | "zh" | "en"
  border = "rounded",
  keys_open = "<leader>co",    -- false 关闭
  default_format = "hex",      -- hex | rgb | rgba | hsl | hsla | hex_alpha
  default_h = 210,
  default_s = 0.75,
  default_v = 0.9,
  default_a = 1,               -- 透明度 100%
  plane_w = 28,
  plane_h = 10,
  bar_w = 36,
  step_h_coarse = 5,           -- 色相粗调格数
  step_sv_coarse = 5,          -- S/V/A 粗调格数（细调固定 1 格）
  parse_under_cursor = true,
  replace_under_cursor = true,
  yank_also = false,
  preview = true,              -- 文件内给色码铺色
  preview_auto = true,
  preview_max_lines = 4000,
  preview_filetypes = nil,     -- 如 { "css", "html" }；nil=不限
})
```

## 输出示例

| 格式 | 示例 |
|------|------|
| `hex` | `#2e7d32` |
| `hex_alpha` | `#2e7d32ff` |
| `rgb` | `rgb(46, 125, 50)` |
| `rgba` | `rgba(46, 125, 50, 1)` |
| `hsl` | `hsl(123, 46%, 34%)` |
| `hsla` | `hsla(123, 46%, 34%, 1)` |

`a<1` 时：`hex`→`hex_alpha`，`rgb`→`rgba`，`hsl`→`hsla`。

## 说明

- 交互 **HSV**；CSS `hsl`/`hsla` 输出为标准 **HSL**。  
- 色相最右格内部记为 360°（与 0° 同色），滑块在最右；**`[`** 在 0° 时跳到最右。  
- 浮窗/预览色块使用**固定数量** highlight 组，绘制时动态 `set_hl`，避免 **E849 Too many highlight groups**。  
- 语言偏好：`stdpath("data")/colorpicker-nvim-prefs.json`。  
- 建议真彩色终端（`termguicolors`）。
