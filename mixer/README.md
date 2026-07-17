# mixer.nvim

**English** | [中文](README.zh.md)

Play **MIDI** and built-in songs inside Neovim via Windows **`winmm.dll`** (MCI sequencer).

## Dependencies

| Component | Notes |
|-----------|--------|
| **Windows** | uses `winmm.dll` |
| Neovim 0.9+ | |
| Python3 | stdlib only (`ctypes` → DLL) |

## Install

```vim
Plug '/path/to/nvimplugins/mixer'
" or whole-repo nvimplugins (includes mixer by default)
```

## Usage

| Action | Description |
|--------|-------------|
| **Open `.mid` / `.midi`** | Auto player UI + play (`auto_open`) |
| `:Mixer` | Open empty player |
| `:Mixer twinkle` | Load preset and play |
| `:Mixer path/to/song.mid` | Play a MIDI file |
| `:MixerStop` | Stop |
| `<leader>mx` | Open player (configurable) |

### Player (music-style minimal bar)

Four lines only: **title · status/time/vol · progress · buttons**. No text selection, no scrolling.

| Key / button | Action |
|--------------|--------|
| `Space` / Play·Pause | Play / pause |
| `x` / Stop | Stop |
| `f` / Songs | **Float** to pick a built-in preset |
| `L` / lang | UI language |
| `+` / `-` | Volume |
| `q` | Close and stop |

### Built-in presets (`f` float)

| id | Song |
|----|------|
| `twinkle` | Twinkle Twinkle |
| `ode` | Ode to Joy (excerpt) |
| `scales` | Multi-timbre scale tour |
| `groove` | Mini groove (incl. drum channel) |
| `sakura` | Pentatonic air |

Presets are written to a temporary `.mid` then played by `winmm`.

## Config

```lua
require("mixer").setup({
  python = "python",
  volume = 70,
  auto_open = true,  -- open .mid → player
  auto_play = true,
  fit_height = true, -- auto height only in vertical stack; not when sole window/column
  ui_lang = "auto",  -- "zh" | "en" | "auto"
  keys_open = "<leader>mx",
})
```

## Notes

- Path: `Python` → `ctypes` → **`winmm.dll` `mciSendString`** → system MIDI synth.
- Timbre depends on the OS MIDI device (usually Microsoft GS Wavetable Synth).
- **Windows** + **`.mid` / `.midi` only**.
- **Height**: same as music — auto-fit content height only when the player sits in a **vertical stack** (horizontal split with other windows). Sole window or full-height column in a vsplit is left alone.
- No sound? Check volume, default device, and GS synth enabled.

## Layout

```
mixer/
  plugin/mixer.lua
  lua/mixer/
  scripts/midi_synth.py
  README.md
  README.zh.md
```
