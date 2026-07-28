# tablemode.nvim

[English](README.md) | **中文**

仿 [vim-table-mode](https://github.com/dhruvasagar/vim-table-mode) 的 **Markdown / GFM 表格模式**：开启后输入 `|` 即时对齐，支持 CSV 转表、单元格移动、删/插列。

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

1. **`<leader>tm`** 或 **`:TableModeToggle`** 开启表格模式  
2. 插入模式输入：

```text
| name | address | phone |
||
```

第二行的 `||` 会展开为表头分隔线，继续用 `|` 填数据时自动对齐：

```text
| name            | address                  | phone      |
|-----------------|--------------------------|------------|
| John Adams      | 1600 Pennsylvania Avenue | 0123456789 |
| Sherlock Holmes | 221B Baker Street        | 0987654321 |
```

3. 在单元格里继续输入文字时，**会防抖自动重排整表列宽**（默认约 60ms）；退出插入模式时再对齐一次。  
4. 关掉模式：再按一次 **`<leader>tm`**。需要手动对齐时用 **`<leader>tr`** / **`:TableModeRealign`**。

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
| **`<leader>tt`** | Tableize（normal：当前行；visual：选区） |
| **`<leader>T`** | Tableize 并提示输入分隔符 |
| **`<leader>tdd`** | 删除当前行（可 `[count]`） |
| **`<leader>tdc`** | 删除当前列（可 `[count]`） |
| **`<leader>tic`** | 在光标后插入列 |
| **`<leader>tiC`** | 在光标前插入列 |

### 开启模式后（buffer 局部）

| 键 | 作用 |
|----|------|
| **`|`**（插入） | 插入竖线并自动对齐；空行 `||` → 分隔行 |
| **`Tab` / `Shift-Tab`** | 下一 / 上一单元格（跳过分隔行；末格 Tab 追加空行） |
| **`←` `→` `↑` `↓` / `hjkl`（normal）** | 一次一格；**到边界再按**则按默认运动**移出表格** |
| **`]|` / `[|`** | 下一 / 上一单元格（行末绕到下一行） |
| **`}|` / `{|`** | 下 / 上一行同列单元格 |
| **`i|` / `a|`** | 单元格文本对象（内 / 含右侧 `\|`） |

## 对齐

分隔行中可用 `:` 控制列对齐（与 GFM 一致）：

```text
| left | center | right |
|:-----|:------:|------:|
| a    | b      |     c |
```

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
  corner = "|",            -- 单元格竖线
  corner_corner = "|",     -- 分隔交叉角；"+" 可得 |---+---|
  fillchar = "-",
  header_fillchar = "-",   -- ReST 可用 "="
  align_char = ":",
  delimiter = ",",         -- Tableize 默认分隔符
  tableize_header_sep = true,
  auto_align = true,              -- 总开关：| 与编辑时对齐
  auto_align_live = true,         -- 编辑单元格内容时实时对齐
  auto_align_ms = 60,             -- 实时对齐防抖（毫秒）；0=立即；IME 可调大
  auto_align_on_insert_leave = true, -- 离开插入模式再对齐一次
  smart_syntax = true,            -- markdown / rst 自动角样式
  ui_lang = "auto",               -- 通知语言 "zh" | "en" | "auto"
  keys_toggle = "<leader>tm",
  keys_realign = "<leader>tr",
  keys_tableize = "<leader>tt",
  keys_tableize_op = "<leader>T",
  keys_delete_row = "<leader>tdd",
  keys_delete_col = "<leader>tdc",
  keys_insert_col_after = "<leader>tic",
  keys_insert_col_before = "<leader>tiC",
  map_motions = true,
  map_text_objects = true,
  map_tab = true,          -- Tab / Shift-Tab 换单元格
  tab_normal = false,      -- normal 也绑 Tab（会占用 <C-i> 跳转列表）
  tab_insert_row = true,   -- 最后一格再 Tab 追加空行
  map_arrows = true,       -- normal 方向键按单元格移动（边界可移出）
  map_hjkl = true,         -- normal hjkl 同上
})
```

任意键设为 `false` 可关闭。

### ReST 风格

```lua
require("tablemode").setup({
  corner = "|",
  corner_corner = "+",
  header_fillchar = "=",
  smart_syntax = true, -- filetype=rst 时也会自动套用
})
```

## 与 vim-table-mode 的差异

| 项目 | 本插件 |
|------|--------|
| 实现 | 纯 Lua，无 Vimscript |
| 公式 / 电子表格 | **未实现**（`$3=$2*$1` 等） |
| 单元格着色 yes/no | **未实现** |
| 默认分隔角 | GFM `|`（非 `+`） |
| 模块名 | `tablemode`（避免覆盖 Lua `table`） |

## 说明

- 表格范围：连续含 `|` 的行；空行或非表行截断。
- 中文等宽字符按 `strdisplaywidth` 计算列宽。
- 可与 **mdview** 预览同用：在源 buffer 编辑，预览侧看渲染结果。
