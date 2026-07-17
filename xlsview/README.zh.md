# xlsview.nvim

[English](README.md) | **中文**

在 Neovim 内预览 **Excel（.xlsx / .xlsm）** 工作簿：表格边框、单元格颜色 / 粗体 / 斜体 / 底色，多工作表切换。

演示：[`testdata/demo.xlsx`](./testdata/demo.xlsx)

## 功能

| 能力 | 说明 |
|------|------|
| 自动打开 | 打开 `.xlsx` / `.xlsm` 即预览 |
| 样式 | 字体色、粗体、斜体、单元格底色、对齐 |
| 多表 | `n`/`p`、`]`/`[`、`gt`/`gT`、数字键、点击标签 |
| 列宽 | 按窗口宽度分配，超出截断 |
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
| `?` | 帮助 |

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
})
```

## 限制

- 旧 **`.xls`** 暂不支持（请另存为 xlsx）  
- 公式：尽量显示缓存结果（`data_only`）；未计算过可能看到公式文本  
- 超大表受 `max_rows` / `max_cols` 限制  
- 合并单元格仅导出范围信息，显示以主格值为准  
