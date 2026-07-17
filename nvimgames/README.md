# nvimgames.nvim

**English** | [中文](README.zh.md)

Mini-games for Neovim:

| Game | Command | Notes |
|------|---------|-------|
| **Minesweeper** | `:Mine` | Windows-style colored minesweeper |
| **Sokoban** | `:Sokoban` | Level-based (245 levels in `data/levels.json`) |
| **24-point** | `:Game24` | Colored poker cards, make 24 |
| **Tetris** | `:Tetris` | Classic + special clear pieces |
| **Menu** | `:NvimGames` | Float picker (number keys / Esc) |

Or jump straight in: `:NvimGames mine` / `sokoban` / `game24` / `tetris` (or `1`–`4`).

## Screenshots

| Minesweeper | Sokoban |
|:-----------:|:-------:|
| ![mine](../images/mine.png) | ![sokoban](../images/sokoban.png) |

| 24-point | Tetris |
|:--------:|:------:|
| ![24](../images/twentyfour.png) | ![tetris](../images/tetris.png) |

## Dependencies

- Neovim 0.9+ (Sokoban needs `vim.json`)
- `termguicolors`
- Minesweeper benefits from `mouse=a` (auto-enabled if empty)

## Install (vim-plug)

Use your local path.

```vim
call plug#begin()
Plug '/path/to/nvimplugins/nvimgames'
call plug#end()

lua require('nvimgames').setup()
```

### Config example

```lua
require("nvimgames").setup({
  mine = {
    difficulty = "beginner", -- beginner | intermediate | expert
  },
  sokoban = {
    -- levels_file = "D:/path/to/levels.json",
    -- remember_level = true,
    -- state_file = ".../sokoban.json",
  },
  twentyfour = {
    solvable_only = true, -- only solvable deals (default true)
  },
  tetris = {
    special_score = 1000, -- one special piece per 1000 points
    -- tick_ms = 600,
  },
})
```

---

## Minesweeper `:Mine`

### Features

- Beginner / intermediate / expert (9×9·10 / 16×16·40 / 30×16·99)
- LMB open, RMB flag, **chord** (both buttons or middle)
- First click safe (including neighbors)
- Top bar: **remaining mines / face / timer** (red LED style)
- Win/lose: 😎 / 😵
- **No text selection** (Visual / drag select blocked)

### Usage

```vim
:Mine
:Mine beginner
:Mine intermediate
:Mine expert
:Mine 初级
```

### Mouse

| Action | Effect |
|--------|--------|
| LMB on cell | Open (on release, for chording) |
| RMB on cell | Flag / unflag |
| **Both buttons** | **Chord** |
| Middle | Chord |
| Top face | Restart |
| Bottom [初级][中级][高级][重开] | Difficulty / restart |

### Keyboard

| Key | Action |
|-----|--------|
| `hjkl` / arrows | Move selection |
| `Space` | Open |
| `m` | Flag |
| `c` | Chord |
| `1` / `2` / `3` | Beg / mid / exp |
| `r` | Restart |
| `q` | Quit |
| `?` | Help |

---

## Sokoban `:Sokoban`

### Features

- Full level pack (`data/levels.json`)
- Push counting (pure moves free, same as C version)
- Undo: back to state before last **push**
- Colored tiles: wall / `◎` target / box / player
- Hidden cursor; **Space** after clear → next level
- Visual select disabled

### Usage

```vim
:Sokoban        " last level (or 1)
:Sokoban 10     " level 10 (saved as progress)
```

Progress: `stdpath('data')/nvimgames/sokoban.json`.

| Key | Action |
|-----|--------|
| `hjkl` / arrows | Move |
| `z` | Undo (to last push) |
| `r` | Restart level |
| `n` / `p` | Next / previous level |
| **`Space`** | **After clear: next level** |
| `g` | Jump to level |
| `q` | Quit |
| `?` | Help |

---

## Menu `:NvimGames`

No args → centered **float**:

```
  1  Minesweeper (Mine)
  2  Sokoban
  3  24-point (Game24)
  4  Tetris

  Number to select · Esc to quit
```

| Key | Action |
|-----|--------|
| `1`–`4` | Enter game |
| `Esc` / `q` | Close menu |

---

## 24-point `:Game24`

### Features

- Four colored poker cards (♠♥♣♦)
- Solvable deals only by default
- Enter arithmetic; each number once; result 24
- Optional solution reveal; scoring

### Usage

```vim
:Game24
:NvimGames 3
```

| Key | Action |
|-----|--------|
| Type after `公式>` | Edit expression (insert on start) |
| `Enter` | Check = 24 |
| `Space` | After fail: clear input |
| `i` | Jump to formula line |
| `r` | New deal |
| `h` | Toggle solution |
| `q` | Quit |
| `?` | Help |

Ranks: `A=1`, `J=11`, `Q=12`, `K=13`.  
Examples: `(8/(3-8/3))`, `8*3-(3-3)`.

---

## Tetris `:Tetris`

### Features

- Standard 7 pieces, saturated colors, ghost placement
- Line clear scoring, level speed-up
- **Special pieces** (arrow orientation `↓←↑→`)
  - One special per **`special_score`** (default 1000) points
  - After lock + fill/clear finish, special score resets to **0**
  - `z`/`x`/↑ rotate orientation
  - **↓** fills column below; **←/→** fill row to the side (animated cell by cell)
  - **↑** does **not** fill — only **1** cell
- Ghost: dim same-color / special shows orientation
- **Next** piece preview (including special ↓)
- **Vs AI** (`:Tetris vs`)
  - Split boards: you / CPU; **shared normal bag sequence**
  - Separate next previews; specials still per-score
  - Heavier garbage for bigger clears (triangular); garbage after opponent piece locks

### Usage

```vim
:Tetris          " solo
:Tetris vs       " vs AI
:NvimGames 4
```

| Key | Action |
|-----|--------|
| `h`/`l` or ←/→ | Move |
| `j` or ↓ | Soft drop |
| `k`/`x`/`↑` | Rotate CW |
| `z` | Rotate CCW |
| `Space` | Hard drop |
| `p` | Pause |
| `r` | Restart (same mode) |
| `v` | Switch to vs AI |
| `m` | Switch to solo |
| `q` | Quit |
| `?` | Help |

---

## Layout

```
nvimgames/
  plugin/nvimgames.lua
  lua/nvimgames/
    init.lua
    menu.lua
    mine.lua
    sokoban.lua
    twentyfour.lua
    tetris.lua
  data/levels.json
  README.md
  README.zh.md
```

## Related

- Repo overview: [English](../README.md) · [中文](../README.zh.md)
