# es.nvim

[English](README.md) | **中文**

用 **Everything** 命令行接口（`es.exe`）在 Neovim 中即时搜索文件。

![es icon](../images/es.png)

## 依赖

| 组件 | 说明 |
|------|------|
| **Windows** | Everything 仅支持 Windows |
| [Everything](https://www.voidtools.com/) | 后台索引服务需已运行 |
| [ES (CLI)](https://www.voidtools.com/support/everything/command_line_interface/) | `es.exe`，需在 `PATH` 中或配置 `es_cmd` |
| Neovim 0.9+ | |

## 安装

```vim
Plug '/path/to/nvimplugins/es'
" 或整仓 nvimplugins（默认包含 es）
```

## 用法

| 操作 | 说明 |
|------|------|
| **`<leader>es`** | 打开搜索浮窗 |
| **`:ES`** / **`:Es`** | 打开搜索浮窗 |
| **`:ES foo*.lua`** | 打开并立即搜索 |

打开时默认把 **当前 pwd** 填进输入框（**双引号** + 引号后空格），例如：

```text
🔍 "D:\path\to\project" 
```

（路径不带末尾 `\`，避免 `C:\path\to\Program Files\` 在 es CLI 下 0 结果。）

在引号后的空格处继续输入关键词即可。空格分隔的多个词为 **AND**（与）关系，例如：

```text
"D:\path\to\proj\" README es
```

会匹配路径含 `D:\path\to\proj\` 且同时含 `README` 与 `es` 的项。  
绝对路径词会用 es **`-path`** 精确限定目录（例如 `C:\path\to\Program Files` **不会**命中 `C:\path\to\Program Files (x86)`）。  
路径中含空格时引号已自动处理。可用 Backspace / `Ctrl-u` 清除后搜全盘。

### 输入框

| 键 | 作用 |
|----|------|
| 可打印字符 | 在光标处插入 |
| `←` / `→` 或 `Ctrl-b` / `Ctrl-f` | 移动光标 |
| `Home` / `End` 或 `Ctrl-a` / `Ctrl-e` | 行首 / 行尾 |
| `<BS>` | 删除光标前一个字符 |
| `<Del>` | 删除光标后一个字符 |
| `<C-w>` | 删除光标前一个词 |
| `<C-u>` | 清空全部查询 |
| `<C-y>` | 粘贴 |
| `<C-o>` | 弹窗编辑完整查询（适合中文） |
| `<C-g>` | 重新填入当前 pwd |

### 结果与其它

| 键 | 作用 |
|----|------|
| `↑` / `↓` 或 `<C-p>` / `<C-n>` | 选择结果 |
| `<Tab>` | 输入框 ↔ 列表焦点 |
| `<CR>` | 打开当前项 |
| `<C-v>` / `<C-x>` / `<C-t>` | 竖分 / 横分 / 新标签 |
| **`F2` / `Alt-s` / `Ctrl-s`** | **显示/隐藏文件大小列**（列表焦点下也可按 `s`） |
| **`Ctrl-o`** | **系统默认程序打开**当前项 |
| **`Ctrl-p`** | **复制路径**到剪贴板 |
| **`Ctrl-r`** | **资源管理器**中显示并选中 |
| 直接输入 | **支持中文 IME**（打开即 insert 模式） |
| **`L` / `Ctrl-l`** | **切换中/英文界面**（跟随系统，可记忆） |
| `Esc` | insert 下：退出输入；normal 下：关闭 |
| `i` / `a` | normal 下重新进入输入 |
| `F3` | 弹窗编辑完整查询 |
| `<C-c>` | 关闭 |

- 路径过长时中间省略为 `...`
- **当前 pwd 下的结果**：列表去掉 pwd 前缀（相对路径），并**排在其它结果前面**
- **虚拟列表**：最多 10000 条结果，buffer 只渲染窗口可见行（滚动时动态填充）
- 路径左侧有 **emoji 文件类型图标**（按扩展名）
- 大小列默认开启（B / K / M / G），**F2** 可随时开关
- 结果中与输入关键词匹配的片段会**黄底高亮**
- 标题栏绿色边框 + 🔍，风格贴近 Everything

## 配置

```lua
require("es").setup({
  es_cmd = "es",
  ui_lang = "auto",    -- "auto" | "zh" | "en"；L / Ctrl-l 切换并记忆
  max_results = 10000, -- 虚拟列表，仅渲染可见行
  keys_open = "<leader>es",
  files_only = true,
  prefill_cwd = true,  -- 打开时预填当前目录路径
  show_size = true,
  open_cmd = "edit",
  icon = "🔍",         -- 标题/输入行图标
  extra_args = {},
  debounce_ms = 120,
  width = 0.85,
  height = 0.65,
  border = "rounded",
  encoding = "utf-8",
})
```

旧配置名 `cwd_only` 仍兼容，等同于 `prefill_cwd`。

## 说明

- 调用链：`es.exe -size -export-csv` → 临时 UTF-8 文件 → 列表 → 打开。
- 仅 **Windows**。确认 Everything 托盘进程在运行。

## 目录

```
es/
  lua/es/init.lua
  plugin/es.lua
  README.md
  README.zh.md
```
