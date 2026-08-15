# bookmarks

[English](README.md) | **中文**

文件 / 文件夹**收藏夹**：右侧 split 浏览，快速打开；目录优先 **NERDTree**（或 Neotree）并 `cd`。  
数据格式与 [vimplugins](https://github.com/) Vim 版兼容，默认同用 `stdpath("data")/vimplugins/bookmarks.txt`。

## 依赖

| 组件 | 说明 |
|------|------|
| Neovim 0.9+ | 纯 Lua |
| NERDTree / Neotree | 可选；打开目录时优先使用 |

## 安装

```vim
Plug '/path/to/nvimplugins/bookmarks'
" 或整仓 nvimplugins（默认包含 bookmarks）
```

```lua
{ "cfwang123/nvimplugins", lazy = false }
```

## 快捷键

| 按键 | 作用 | 作用范围 |
|------|------|----------|
| `<leader>bo` | 右侧打开收藏夹 | 全局 |

**仅收藏夹窗口内**有效（文件编辑等其它窗口不受影响）：

| 按键 | 作用 |
|------|------|
| `o` / `Enter` | 打开文件；目录则 NERDTree/Neotree + `cd` |
| `t` | 新 tab 打开 |
| `S` | 切换完整路径 / 仅名称（重名去掉公共前缀） |
| `dd` | 删除当前项 |
| `A` / `D` | 收藏打开面板前的文件 / 目录 |
| `r` | 重新加载 |
| `q` / `Esc` | 关闭 |

> 在编辑窗口添加收藏可用命令 `:BookmarksAddFile` / `:BookmarksAddDir`，或在 setup 里自定义 `keys_add_file` / `keys_add_dir`。

## 配置

```lua
require("bookmarks").setup({
  width = 36,
  -- file = vim.fn.stdpath("data") .. "/vimplugins/bookmarks.txt",
  -- keys_open = "<leader>bo",
  -- 如需在编辑窗口用快捷键添加收藏（默认关闭，避免覆盖 A/D）：
  -- keys_add_file = "<leader>ba",
  -- keys_add_dir = "<leader>bd",
  -- no_mappings = true,  -- 关闭全部默认全局映射
})
```

## 命令

- `:BookmarksOpen` / `:BookmarksToggle` / `:BookmarksClose`
- `:BookmarksAddFile` / `:BookmarksAddDir`
- `:BookmarksRefresh`
