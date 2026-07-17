# tts.nvim

**English** | [中文](README.zh.md)

Windows **SAPI** text-to-speech for Neovim: command speak, buffer preview with live segment highlight, selection playback (voice preference remembered).

![tts screenshot](../images/tts.png)

## Dependencies

- Windows + SAPI voices  
- Neovim 0.9+  
- Python3 + **pywin32** (`pip install pywin32`)

## Usage

| Action | Description |
|--------|-------------|
| `:TTS hello` | Speak text |
| **normal** `<leader>vo` | Control bar + **bright-yellow highlight on source** |
| **visual** `<leader>vo` | Speak selection (same remembered voice) |
| `<leader>vs` | Stop all + close control bar |

Control bar: clickable buttons; voice picker is a **float**. Source segment uses yellow background highlight.

Keys: `←`/`→` segment · `↑`/`↓` volume · `Space` pause · `v` voice · `q` stop. Visual mode disabled in control bar; highlight clears when playback ends.

## Config

```lua
require("tts").setup({
  python = "python",
  volume = 80,
  rate = 0,
  keys_play = "<leader>vo",
  keys_stop = "<leader>vs",
  -- voice = "Huihui", -- optional default; float choice is persisted
})
```

Voice is **not** auto-switched by language. Choosing in the float saves to `stdpath("data")/tts-nvim-prefs.json` for next time.
