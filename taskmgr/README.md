# taskmgr — Neovim process manager

Task-manager style float: process list, sort, column show/hide & width, intensity highlights, kill process.

## Usage

| Action | |
|--------|--|
| `<leader>ta` | Open (configurable) |
| `:Taskmgr` | Same |
| `:TaskmgrRefresh` | Refresh |
| `:TaskmgrClose` | Close |

### Keys inside the float

| Key | Action |
|-----|--------|
| `q` | Close |
| `i` / `a` / `/` | Enter **in-window search** (insert; live filter + highlight) |
| `Esc` | Leave search → clear query → close |
| `F` | Clear search |
| `r` | Refresh |
| `c` / `m` / `p` / `n` | Sort CPU / Mem / PID / Name |
| `S` | Toggle asc/desc |
| `Tab` / `]` / `[` | Select **width column** (header shows `name*`) |
| `+` / `-` | Wider / narrower focused column |
| `v` | Column visibility (popup, per-column ☑/☐) |
| `x` / `d` | Kill process under cursor (confirm) |
| `L` | Language |
| `?` | Help |

CPU% and memory cells are colored by intensity; search matches use yellow highlight.
Float size is fixed at **80%×80%** of the editor (no resize after open). Buffer uses **dirty self-draw** (only changed lines rewritten).
Column prefs: `stdpath("data")/taskmgr-nvim-cols.json`.

## Setup

```lua
require("taskmgr").setup({
  keys_open = "<leader>ta",
  refresh_ms = 2000,
  sample_ms = 400,
  width_ratio = 0.8,
  height_ratio = 0.8,
  ui_lang = "auto",
  -- CPU: highlight from 3% (4 intensity steps)
  cpu_hl_min = 3,
  cpu_levels = { 3, 15, 40, 70 },
  -- Memory: highlight from 200MB RSS
  mem_hl_min_mb = 200,
  mem_mb_levels = { 200, 500, 1000, 2000 },
})
```

## Dependencies

- Neovim 0.9+
- Python 3
- **Required**: `psutil` (single backend for Windows / Linux / macOS)

```bash
pip install psutil
# or
python3 -m pip install --user psutil
```

### Platform notes

| Platform | CPU | Memory column | GPU% | Kill |
|----------|-----|---------------|------|------|
| Windows | all cores = 100% | commit (vms) | nvidia-smi / counters | `taskkill` |
| Linux | all cores = 100% | USS→PSS→RSS | nvidia-smi if available | `kill -TERM` |
| macOS | all cores = 100% | USS/RSS | nvidia-smi (rare) | `kill -TERM` |

Some fields (cmdline, USS) on Linux may need sufficient permissions.

No admin required for normal listing; killing protected processes may fail.
