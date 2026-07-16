# nvimgames.nvim

Neovim 小游戏合集，目前包含：

| 游戏 | 命令 | 说明 |
|------|------|------|
| **扫雷** | `:Mine` | Windows 风格彩色扫雷 |
| **推箱子** | `:Sokoban` | 关卡制推箱子（`data/levels.json` 共 245 关） |
| **24点** | `:Game24` | 彩色扑克算 24 |
| **俄罗斯方块** | `:Tetris` | 经典方块 + 特殊清列 |
| **选单** | `:NvimGames` | 浮动窗口选游戏（数字键 / Esc） |

也可：`:NvimGames mine` / `sokoban` / `game24` / `tetris`（或 `1`–`4`）直接进对应游戏。

## 截图

| 扫雷 | 推箱子 |
|:----:|:------:|
| ![扫雷](../images/mine.png) | ![推箱子](../images/sokoban.png) |

| 24点 | 俄罗斯方块 |
|:----:|:----------:|
| ![24点](../images/twentyfour.png) | ![俄罗斯方块](../images/tetris.png) |

## 依赖

- Neovim 0.9+（推箱子需要 `vim.json`）
- `termguicolors`
- 扫雷建议 `mouse=a`（未开启时插件会自动打开）

## 安装（vim-plug）

路径请改成你的本机目录。

### 懒加载（推荐）

```vim
call plug#begin()

Plug '/path/to/vim/nvimgames', {
  \ 'on': ['Mine', 'Sokoban', 'Game24', 'Tetris', 'NvimGames'],
  \ }

call plug#end()

lua require('nvimgames').setup()
```

| 参数 | 含义 |
|------|------|
| `on` | 执行列出的 **Ex 命令** 时才加载插件 |

### 立即加载

```vim
call plug#begin()
Plug '/path/to/vim/nvimgames'
call plug#end()

lua require('nvimgames').setup()
```

### 配置示例

```lua
require("nvimgames").setup({
  mine = {
    difficulty = "beginner", -- beginner | intermediate | expert
  },
  sokoban = {
    -- levels_file = "D:/path/to/levels.json", -- 可选，默认用插件自带
    -- remember_level = true,                  -- 记住上次关卡（默认 true）
    -- state_file = ".../sokoban.json",        -- 进度文件路径
  },
  twentyfour = {
    solvable_only = true, -- 只发可解牌局（默认 true）
  },
  tetris = {
    special_score = 1000, -- 每 1000 分 1 个特殊块（用完后重新计）
    -- tick_ms = 600,
  },
})
```

---

## 扫雷 `:Mine`

### 功能

- 初级 / 中级 / 高级（9×9·10 雷 / 16×16·40 雷 / 30×16·99 雷）
- 左键开格、右键插旗、**左右键同时**或中键弦开
- 首次点击安全（周围也不布雷）
- 顶部 **剩余雷数 / 表情 / 计时**（红字 LED 风格）
- 胜负：😎 胜利 / 😵 踩雷
- **禁止选中字符**（屏蔽 Visual / 鼠标拖选）

### 用法

```vim
:Mine
:Mine beginner
:Mine intermediate
:Mine expert
:Mine 初级
```

### 鼠标

| 操作 | 作用 |
|------|------|
| 左键格子 | 打开（松开时开格，便于组合右键） |
| 右键格子 | 插旗 / 取消 |
| **左右键同时按** | **弦开** |
| 中键 | 弦开 |
| 点顶部表情 | 重开 |
| 底部 [初级][中级][高级][重开] | 切换难度 / 重开 |

### 键盘

| 键 | 作用 |
|----|------|
| `hjkl` / 方向键 | 移动选择格 |
| `Space` | 打开当前格 |
| `m` | 插旗 |
| `c` | 弦开 |
| `1` / `2` / `3` | 初 / 中 / 高 |
| `r` | 重开 |
| `q` | 退出 |
| `?` | 帮助 |

---

## 推箱子 `:Sokoban`

### 功能

- 完整关卡数据（`data/levels.json`）
- 推箱计步（纯移动不计步，与 C 版一致）
- 撤销：回到上一次**推箱**之前
- 彩色图块：`墙` / `◎`(目标) / `箱` / `人`
- 隐藏光标；过关后 **Space** 进入下一关
- 禁止 Visual 选中

### 用法

```vim
:Sokoban        " 上次关卡（无记录则第 1 关）
:Sokoban 10     " 第 10 关（并记为进度）
```

进度保存在 `stdpath('data')/nvimgames/sokoban.json`（换关 / 退出时写入）。

| 键 | 作用 |
|----|------|
| `hjkl` / 方向键 | 移动 |
| `z` | 撤销（跳到上次推箱前） |
| `r` | 重开本关 |
| `n` / `p` | 下一关 / 上一关 |
| **`Space`** | **过关后进入下一关** |
| `g` | 跳转到指定关卡 |
| `q` | 退出 |
| `?` | 帮助 |

关卡逻辑参考 `game/sokoban/c_app`。

---

## 选单 `:NvimGames`

无参时打开居中 **float** 窗口：

```
  1  扫雷 (Mine)
  2  推箱子 (Sokoban)
  3  24点 (Game24)
  4  俄罗斯方块 (Tetris)

  数字选择 · Esc 退出
```

| 键 | 作用 |
|----|------|
| `1`–`4` | 进入对应游戏 |
| `Esc` / `q` | 关闭选单 |

---

## 24点 `:Game24`

### 功能

- 随机发 4 张彩色扑克（♠♥♣♦，红黑分色）
- 默认只发**可解**牌局
- 输入四则运算公式，校验：数字各用一次、结果为 24
- 可看参考答案；计分

### 用法

```vim
:Game24
:NvimGames 3
```

| 键 | 作用 |
|----|------|
| 在 `公式>` 后直接打字 | 编辑算式（开局自动进入插入） |
| `Enter` | 判定是否等于 24 |
| `Space` | 判定失败后：清空输入 |
| `i` | 跳到公式行继续编辑 |
| `r` | 发新牌（并清空输入） |
| `h` | 显示/隐藏参考答案 |
| `q` | 退出 |
| `?` | 帮助 |

点数：`A=1`，`J=11`，`Q=12`，`K=13`。  
例：`(8/(3-8/3))`、`8*3-(3-3)` 等。

---

## 俄罗斯方块 `:Tetris`

### 功能

- 标准 7 种方块、固定高饱和配色、影子落点
- 消行计分、等级加速
- **特殊方块**（箭头表示朝向：`↓←↑→`）
  - 每累计 **`special_score`（默认 1000）分** 出现 **1 个**
  - **落地并填充/消除全部完成后**，特殊计分从 **0** 重新开始（过程中不再累加）
  - `z`/`x`/↑ 旋转朝向
  - **↓** 只填落点**下方**同列；**←/→** 只填箭头侧同行（一次一格动画）
  - **↑ 禁止填充**，仅 **1 格**
- 落点预览：同色暗淡块 / 特殊块影子显示朝向
- **下一个方块**预览（场地旁「下一」；含特殊↓）
- **人机对战**（`:Tetris vs`）
  - 左右双场地：你 / 电脑；**双方普通方块顺序相同**（共享 7-bag 序列）
  - 各自「下一」预览；特殊块仍按各自得分触发（插入一次，不打乱后续共用序列）
  - **一次清得越多惩罚越重**（三角数）：整行 + 特殊清除格数
  - **对方当前方块落地后**顶入垃圾

### 用法

```vim
:Tetris          " 单人
:Tetris vs       " 人机对战
:NvimGames 4
```

| 键 | 作用 |
|----|------|
| `h`/`l` 或 ←/→ | 左右移动 |
| `j` 或 ↓ | 软降 |
| `k`/`x`/`↑` | 顺时针旋转 |
| `z` | 逆时针旋转 |
| `Space` | 硬降 |
| `p` | 暂停 / 继续 |
| `r` | 重开（保持当前模式） |
| `v` | 切换到人机对战 |
| `m` | 切换到单人 |
| `q` | 退出 |
| `?` | 帮助 |

---

## 目录

```
nvimgames/
  plugin/nvimgames.lua      " :Mine / :Sokoban / :Game24 / :Tetris / :NvimGames
  lua/nvimgames/
    init.lua                " setup 入口
    menu.lua                " float 选单
    mine.lua                " 扫雷
    sokoban.lua             " 推箱子
    twentyfour.lua          " 24点
    tetris.lua              " 俄罗斯方块
  data/levels.json          " 推箱子关卡
  README.md
```

## 相关

- 仓库总览：[../README.md](../README.md)
