# tablemode.nvim

[English](README.md) | **中文**

仿 [vim-table-mode](https://github.com/dhruvasagar/vim-table-mode) 的 **Markdown / GFM 表格模式**：开启后即时对齐、单元格移动、块选复制；默认以 **mdview 风格 Unicode 框线**编辑，退出或保存时还原为标准 `| --- |` ASCII 表。

> 模块名用 **`tablemode`**，避免与 Lua 内置库 `table` 冲突。

## 依赖

| 组件 | 说明 |
|------|------|
| Neovim 0.9+ | 纯 Lua，无 Python / 外部命令 |

## 安装

```vim
Plug '/path/to/nvimplugins/tablemode'
" 或整仓 nvimplugins（默认包含 tablemode）
```

```lua
-- lazy.nvim 整仓
{ "cfwang123/nvimplugins", lazy = false }
```

## 快速上手

1. 在 Markdown 中写好 GFM 表（或用 `|` 现画），按 **`<leader>tm`** / **`:TableModeToggle`** 开启表格模式。  
2. **开启后**表格会变成 mdview 式框线（可编辑、可对齐）：

```text
┌──────────────────┬──────────────────────────┬────────────┐
│ name             │ address                  │ phone      │
├──────────────────┼──────────────────────────┼────────────┤
│ John Adams       │ 1600 Pennsylvania Avenue │ 0123456789 │
│ Sherlock Holmes  │ 221B Baker Street        │ 0987654321 │
└──────────────────┴──────────────────────────┴────────────┘
```

3. 单元格内输入时**防抖自动重排列宽**（默认约 60ms）；离开插入模式再对齐一次。  
4. 再按 **`<leader>tm`** 退出：还原为 GFM ASCII，并清除高亮。

```text
| name             | address                  | phone      |
| ---------------- | ------------------------ | ---------- |
| John Adams       | 1600 Pennsylvania Avenue | 0123456789 |
| Sherlock Holmes  | 221B Baker Street        | 0987654321 |
```

5. 需要手动对齐：`<leader>tr` / `:TableModeRealign`。

### 从零画表（插入模式）

```text
| name | address | phone |
||
```

第二行 `||` 会展开为表头分隔线；继续按 `|` 填列并自动对齐。开启 `preview_style = "unicode"` 时，按 `|` 会写入 `│`。

## Unicode 预览与 GFM 还原

| 时机 | 行为 |
|------|------|
| **开启 tablemode** | buffer 内表格 → Unicode 框线（`┌─┬─┐` / `│` / `├─┼─┤` / `└─┴─┘`） |
| **编辑 / 对齐** | 始终按当前样式（默认框线）重排 |
| **退出 tablemode** | 框线表 → 标准 GFM `\| --- \|` |
| **`:w` 保存** | 先写成 GFM 再落盘；若仍开启模式，保存后 buffer 再恢复为框线预览 |

- 磁盘上始终是 **标准 Markdown 表**（对齐标记 `:---` / `:---:` / `---:` 会保留）。  
- 对齐信息写在中线格内（如 `┼:──:┼`），还原 GFM 时写回。  
- 设 `preview_style = "gfm"` 可关闭框线预览，开启时也保持 ASCII。  
- 默认 `disable_conceal = true`：开启时 `conceallevel=0`，避免 `**加粗**` 等隐藏标记把竖线「挤歪」；退出时恢复原值。

## 命令

| 命令 | 说明 |
|------|------|
| **`:TableModeToggle`** | 开/关当前 buffer 的表格模式 |
| **`:TableModeEnable`** / **`:TableModeDisable`** | 开启 / 关闭 |
| **`:TableModeRealign`** | 对齐光标所在表格 |
| **`:Tableize`** | 将当前行或可视选区转为表格（默认逗号分隔） |
| **`:Tableize/;`** 或 **`:Tableize ;`** | 指定分隔符 |

## 默认快捷键

| 键 | 作用 |
|----|------|
| **`<leader>tm`** | 开/关表格模式 |
| **`<leader>tr`** | 重新对齐 |

Tableize / 删行删列 / 插列等默认**不绑定**；需要时在 `setup` 里设 `keys_*`。

### 开启模式后（buffer 局部）

| 键 | 作用 |
|----|------|
| **`|`**（插入） | 插入竖线并自动对齐（unicode 预览时写入 `│`）；表头下空行 `||` → 分隔/中线；**表末**空行 `|` → 追加空数据行 |
| **`Tab` / `Shift-Tab`** | 下一 / 上一单元格（跳过框线与分隔行；末格 Tab 追加空行） |
| **`←` `→` `↑` `↓` / `hjkl`（normal）** | 一次一格；**到边界再按**则按默认运动**移出表格** |
| **`Ctrl-v`（或 `Ctrl-q`）** | **单元格块选**：进入时至少选中当前**整格** |
| **块选中 `hjkl` / 方向键** | 每次扩展 **一列 / 一行** 单元格（跳过分隔行） |
| **`gy`（可视）** | 复制为 **Excel 风格 TSV**（Tab 分列，去掉竖线）；普通 **`y`** 不接管 |
| **`]|` / `[|`** | 下一 / 上一单元格（行末绕到下一行） |
| **`}|` / `{|`** | 下 / 上一行同列单元格 |
| **`i|` / `a|`** | 单元格文本对象 |

### 块选复制示例

在表格内 `Ctrl-v` 选中格矩形后按 `gy`：

```text
│ name            │ address                  │ phone      │
│ John Adams      │ 1600 Pennsylvania Avenue │ 0123456789 │
│ Sherlock Holmes │ 221B Baker Street        │ 0987654321 │
```

剪贴板（Tab 分隔，可粘贴到 Excel）：

```text
John Adams	1600 Pennsylvania Avenue	0123456789
Sherlock Holmes	221B Baker Street	0987654321
```

## 对齐

GFM 分隔行中的 `:`（退出后仍保留）：

```text
| left | center | right |
|:-----|:------:|------:|
| a    | b      |     c |
```

开启 unicode 预览时中线会带上对应对齐标记。

## 状态栏

开启后：

- `vim.b.tablemode == true`
- `vim.g.tablemode_status == "TABLE"`（可放入 statusline）

```vim
set statusline+=%{get(g:,'tablemode_status','')}
```

## 配置

```lua
require("tablemode").setup({
  corner = "|",            -- GFM 单元格竖线
  corner_corner = "|",     -- 分隔交叉角；"+" 可得 |---+---|
  fillchar = "-",
  header_fillchar = "-",   -- ReST 可用 "="
  align_char = ":",
  delimiter = ",",         -- Tableize 默认分隔符
  tableize_header_sep = true,
  auto_align = true,              -- 总开关：| 与编辑时对齐
  auto_align_live = true,         -- 编辑单元格内容时实时对齐
  auto_align_ms = 60,             -- 实时对齐防抖（毫秒）；0=立即；IME 可调大
  auto_align_on_insert_leave = true,
  smart_syntax = true,            -- markdown / rst 自动角样式
  ui_lang = "auto",               -- 通知语言 "zh" | "en" | "auto"
  keys_toggle = "<leader>tm",
  keys_realign = "<leader>tr",
  keys_tableize = false,           -- 需要时设为 "<leader>tt" 等
  keys_tableize_op = false,        -- 例如 "<leader>T"
  keys_delete_row = false,         -- 例如 "<leader>tdd"
  keys_delete_col = false,         -- 例如 "<leader>tdc"
  keys_insert_col_after = false,   -- 例如 "<leader>tic"
  keys_insert_col_before = false,  -- 例如 "<leader>tiC"
  map_motions = true,
  map_text_objects = true,
  map_tab = true,          -- Tab / Shift-Tab 换单元格
  tab_normal = false,      -- normal 也绑 Tab（会占用 <C-i> 跳转列表）
  tab_insert_row = true,   -- 最后一格再 Tab 追加空行
  map_arrows = true,       -- normal 方向键按单元格移动（边界可移出）
  map_hjkl = true,         -- normal hjkl 同上
  map_vblock = true,       -- Ctrl-v 格块选；可视 hjkl 扩格；gy 复制 TSV
  highlight = true,        -- 开启后高亮表头背景与表格线
  hl_header = "TableModeHeader",
  hl_border = "TableModeBorder",
  highlight_ms = 80,       -- 高亮刷新防抖
  preview_style = "unicode", -- 开启时 mdview 框线；"gfm" 保持 | --- |
  disable_conceal = true,  -- 开启时 conceallevel=0，避免 ** 错位
})
```

任意 `keys_*` 设为 `false` 可关闭该快捷键。

### 高亮组

| 组 | 作用 | 默认 |
|----|------|------|
| **`TableModeHeader`** | 表头**单元格文字**背景（不含两侧空格 / 竖线） | 很淡蓝底 `#e3f0fb` |
| **`TableModeBorder`** | 表格线：`\|` `-` `:` `=` `+` 与 Unicode `─` `│` `┌┐└┘├┤┬┴┼` | 蓝色前景 + **加粗** |

可用 `hi TableModeHeader ...` / `hi TableModeBorder ...` 自定义。

### ReST 风格

```lua
require("tablemode").setup({
  corner = "|",
  corner_corner = "+",
  header_fillchar = "=",
  smart_syntax = true, -- filetype=rst 时也会自动套用
  preview_style = "gfm", -- ReST 通常不需要 unicode 预览
})
```

### 关闭框线预览

```lua
require("tablemode").setup({
  preview_style = "gfm", -- 开启时仍编辑 | --- | ASCII
})
```

## 与 vim-table-mode 的差异

| 项目 | 本插件 |
|------|--------|
| 实现 | 纯 Lua，无 Vimscript |
| 开启时外观 | 默认 **Unicode 框线**（可关）；退出还原 GFM |
| 公式 / 电子表格 | **未实现**（`$3=$2*$1` 等） |
| 单元格着色 yes/no | **未实现** |
| 默认分隔角 | GFM `|`（非 `+`） |
| TSV 复制 | 可视模式 **`gy`**（普通 `y` 不接管） |
| 模块名 | `tablemode`（避免覆盖 Lua `table`） |

## 说明

- 表格范围：连续含 `|` 或 Unicode 框线字符的行；空行或非表行截断。  
- 列宽按 `strdisplaywidth` 计算（中文友好）。  
- 可与 **mdview** 同用：源 buffer 编辑，预览侧看渲染结果。  
- 保存时 buffer 会短暂切到 GFM 再写盘；保存后若仍开启模式会恢复框线且不标脏（`modified=false`）。
