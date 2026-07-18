# taskmgr — Neovim 进程管理

类任务管理器的 float 面板：查看 CPU/内存、排序、列显隐与列宽、高占用着色、结束进程。

## 用法

| 方式 | 说明 |
|------|------|
| `<leader>ta` | 打开进程列表（可配置） |
| `:Taskmgr` | 同上 |
| `:TaskmgrRefresh` | 刷新 |
| `:TaskmgrClose` | 关闭 |

### 浮窗快捷键

| 键 | 作用 |
|----|------|
| `q` | 关闭 |
| `i` / `a` / `/` | 进入**窗口内搜索框**（insert；边输入边筛选/高亮） |
| `Esc` | 退出搜索编辑 → 清空关键词 → 关闭 |
| `F` | 清空搜索 |
| `r` | 刷新 |
| `Tab` / `]` / `[` | 选择当前列（标题 `列名*`） |
| `s` | 按当前列排序（再按切换升/降） |
| `D` | 隐藏当前列 |
| `+` / `-` | 当前列加宽 / 变窄 |
| `v` | 列显隐（弹出面板，逐列 ☑/☐） |
| `x` / `d` | 结束光标所在进程（确认） |
| `L` | 中/英 |
| `?` | 帮助 |

- CPU%、内存按占用程度着色（绿 → 黄 → 橙 → 红）；搜索匹配黄底高亮  
- 浮窗固定为编辑器 **80%×80%**，打开后尺寸不变；buffer **dirty 自绘**（只改变化行）  
- 列显隐 / 宽度 / 排序写入 `stdpath("data")/taskmgr-nvim-cols.json`

## 配置

```lua
require("taskmgr").setup({
  keys_open = "<leader>ta",
  refresh_ms = 2000,   -- 自动刷新；0 关闭
  sample_ms = 400,     -- CPU 采样间隔
  width_ratio = 0.8,   -- 固定浮窗宽
  height_ratio = 0.8,  -- 固定浮窗高
  ui_lang = "auto",    -- "zh" | "en" | "auto"
  -- CPU：默认 ≥3% 起背景色，四档加深
  cpu_hl_min = 3,
  cpu_levels = { 3, 15, 40, 70 },
  -- 内存：默认 ≥200MB 起背景色，四档加深
  mem_hl_min_mb = 200,
  mem_mb_levels = { 200, 500, 1000, 2000 },
  max_rows = 500,
})
```

- `cpu_hl_min` / `mem_hl_min_mb`：起色阈值（会覆盖对应 `levels` 的第一档）
- `cpu_levels` / `mem_mb_levels`：升序多档阈值，对应 1→4 档背景色

## 依赖

- Neovim 0.9+
- Python 3
- **必须**安装 **psutil**（Win / Linux / macOS 唯一后端）：

```bash
pip install psutil
# 或
python3 -m pip install --user psutil
```

### 平台说明

| 平台 | CPU | 内存列 | GPU% | 结束进程 |
|------|-----|--------|------|----------|
| Windows | 全核 100% | 提交大小 (vms) | nvidia-smi / 系统计数器 | `taskkill` |
| Linux | 全核 100% | USS→PSS→RSS | nvidia-smi（有驱动时） | `kill -TERM` |
| macOS | 全核 100% | USS/RSS | nvidia-smi（少见） | `kill -TERM` |

部分进程详情（命令行、USS）在 Linux 上可能需足够权限，否则对应字段为空或回退 RSS。

无需管理员即可查看多数进程；结束其它用户/系统进程可能失败。
