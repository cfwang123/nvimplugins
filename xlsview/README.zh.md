# xlsview.nvim

[English](README.md) | **中文**

在 Neovim 内预览 **Excel（.xlsx / .xlsm）** 工作簿：表格边框、单元格颜色 / 粗体 / 斜体 / 底色，多工作表切换，Excel 风格跳格与块选复制。

演示：[`testdata/demo.xlsx`](./testdata/demo.xlsx)

## 功能

| 能力 | 说明 |
|------|------|
| 自动打开 | 打开 `.xlsx` / `.xlsm` 即预览（不弹 hit-enter） |
| 样式 | 字体色、粗体、斜体、单元格底色、对齐 |
| 多表 | `n`/`p`、`]`/`[`、`gt`/`gT`、数字键、点击标签 |
| 列宽 | 默认**按内容定宽**，表宽于窗口时 **横向滚动**（不挤成全是 `…`） |
| 跳格 | 方向键 / `hjkl` / `Tab` 按**单元格**移动（Excel 风格） |
| 格块选 | `Ctrl-v` 选中**当前整格**；方向键一次扩展一行/一列格 |
| 复制 | 块选后 `y` 复制单元格文本（忽略 `│`，空格对齐，类 Excel） |
| zip 冲突 | 避免 Neovim zipPlugin 把 xlsx 当压缩包 |

## 依赖

```bash
pip install openpyxl
```

| 组件 | 作用 |
|------|------|
| Neovim 0.9+ | 宿主 |
| Python3 + **openpyxl** | 提取工作表与样式 |

## 安装

```vim
Plug '/path/to/nvimplugins/xlsview'
" 或整仓 Plug 'cfwang123/nvimplugins'
```

```vim
:e book.xlsx
:XlsView
:XlsViewRefresh
:XlsViewClose
```

## 快捷键

| 键 | 作用 |
|----|------|
| `q` / `Esc` | 关闭 |
| `r` | 重新提取 |
| `n` / `]` / `gt` | 下一表 |
| `p` / `[` / `gT` | 上一表 |
| `1`–`9` | 跳到第 N 表 |
| 点击标签 | 切换工作表 |
| `↑` `↓` `←` `→` / `hjkl` | 跳到邻近单元格 |
| `Tab` / `S-Tab` | 下一格 / 上一格（行末换行） |
| `0` / `$` | 本行首格 / 末格 |
| `Ctrl-v`（或 `Ctrl-q`） | **单元格块选**：进入时选中当前**整格** |
| 块选中 `↑↓←→` / `hjkl` | 一次扩展 **一行/一列单元格** |
| `y` / `Ctrl-c` | 复制选中**单元格**文本（忽略 `│`） |
| `v` / `V` | 普通字符 / 行选择 |
| `zh` / `zl` | 视口横向滚动（不跳格） |
| `L` | 中/英文界面 |
| `?` | 帮助 |

### 块选复制示例

`Ctrl-v` 拉矩形后 `y`（空单元格仍占列，与 xlsx 一致）：

```text
A01    2-1上装    40001
              40002
A02    1-1上装    40003
              40004
```

选区碰到两边的 `│` 会忽略边框。

## 配置

```lua
require("xlsview").setup({
  auto_open = true,
  python = "python",
  max_rows = 500,
  max_cols = 64,
  table_style = "unicode", -- unicode | ascii | minimal
  header_row = true,
  show_row_numbers = false,
  ui_lang = "auto", -- L 切换
  -- 列多时：按内容定宽 + 横向滚动（默认）；true 会压进窗口（易出现 …）
  fit_to_window = false,
  min_col_width = 6,
  max_col_width = 28,
})
```

## 限制

- 旧 **`.xls`** 暂不支持（请另存为 xlsx）  
- 公式：尽量显示缓存结果（`data_only`）；未计算过可能看到公式文本  
- 超大表受 `max_rows` / `max_cols` 限制  
- 合并单元格仅导出范围信息，显示以主格值为准  
