---@mod nvimgames.i18n zh/en UI + system language detect
local M = {}

---@type "zh"|"en"
local lang = "zh"

local STR = {
  zh = {
    -- menu
    menu_title = "nvimgames",
    menu_hint = "数字选择 · u 中英文 · Esc 退出",
    game_mine = "扫雷",
    game_sokoban = "推箱子",
    game_twentyfour = "24点",
    game_tetris = "俄罗斯方块",
    lang_btn = " 中文/EN ",
    lang_switched = "界面语言: 中文",

    -- common
    quit = "退出",
    help = "帮助",
    restart = "重开",
    pause = "暂停",

    -- mine
    mine_diff_beginner = "初级",
    mine_diff_intermediate = "中级",
    mine_diff_expert = "高级",
    mine_won = " 状态: 胜利！点击 🙂 再来一局",
    mine_lost = " 状态: 踩雷… 点击 🙂 重开",
    mine_ready = " %s %dx%d  雷:%d  | 左键开 右键旗  中键/双键:弦开  1/2/3难度  u语言  q退出",
    mine_playing = " %s  剩余雷:%d  用时:%ds  | 左键开 右键旗  u语言  q退出",
    mine_footer = " [%s] [%s] [%s]   [%s]  [%s]",
    mine_help = "扫雷\n左键:开格  右键:插旗  中键:弦开\n1/2/3:初/中/高  r:重开  u:中英文  hjkl:选择  空格:开  m:旗  c:弦  q:退出",

    -- sokoban
    sokoban_title = " 推箱子  关卡 %d/%d  %s  步数:%d  %s",
    sokoban_cleared = "★ 过关！",
    sokoban_help = " hjkl/方向键移动  z撤销  r重开  n/p下/上关  g跳关  u中英文  q退出 ",
    sokoban_next = " ★ 过关！按 Space 进入下一关，或 r 重玩本关 ",
    sokoban_jump = "跳转到关卡 (1-%d): ",
    sokoban_help_box = "推箱子\nhjkl 移动  z 撤销  r 重开  n/p 下/上关  g 跳关\nu 中英文\n过关后 Space 下一关  q 退出\n箱=箱子  ◎=目标  人=玩家  墙=墙",
    sokoban_btn_lang = "[中文/EN]",
    sokoban_no_level = "sokoban: 找不到关卡文件 ",
    sokoban_bad_json = "sokoban: 关卡 JSON 解析失败",
    sokoban_bad_level = "sokoban: 无效关卡 ",

    -- twentyfour
    tf_title = "  24 点  |  得分:%d  局数:%d  ",
    tf_help = "  公式行输入  Enter 判定  出错后 Space 清空  r 新牌  h 答案  u 中英文  q 退出  ",
    tf_help_box = "24点\n在「公式>」后直接输入算式，Enter 判定\n出错后 Space 清空输入；r 新牌会清空公式\nA=1 J=11 Q=12 K=13；四则运算 + - * / ()\ni 编辑  r 新牌  h 答案  u 中英文  点击底栏按钮也可切换  q 退出\n例: (8/(3-8/3))",
    tf_cleared = "  已清空，请重新输入",
    tf_btn_lang = "[中文/EN]",
    tf_expr_prefix = "  公式> ",
    tf_points = "  点数: %s   （A=1  J=11  Q=12  K=13）",
    tf_answer = "  参考答案: %s",
    tf_prompt = "  在「公式>」后输入算式，按 Enter 判定",
    tf_prompt_default = "  在下方公式行输入，按 Enter 判定是否等于 24",
    tf_already = "  本局已答对，按 r 发新牌",
    tf_empty_input = "  公式为空，请在「公式>」后输入",
    tf_ok_next = "  ★ %s  按 r 下一局",
    tf_bad_space = "  ✗ %s  （Space 清空输入）",
    tf_show_ans = "  已显示参考答案",
    tf_hide_ans = "  已隐藏参考答案",
    tf_no_ans = "  本局无解或求解失败",
    tf_only_ops = "只允许数字与 + - * / ( )",
    tf_expr_empty = "公式为空",
    tf_expr_long = "公式过长",
    tf_syntax = "语法错误: %s",
    tf_calc_err = "计算错误: %s",
    tf_not_number = "结果不是数字",
    tf_invalid = "结果无效（除零？）",
    tf_parse_fail = "数字解析失败",
    tf_no_decimal = "本游戏只使用整数，不要写小数",
    tf_need_4 = "必须正好使用 4 个数字（当前 %d 个）",
    tf_use_cards = "必须用完这 4 个数各一次：需要 [%s]，公式里是 [%s]",
    tf_eval_fail = "计算失败",
    tf_correct = "正确！= %g",
    tf_wrong_val = "结果是 %g，不是 24",

    -- tetris
    tetris_help = "  hjkl移动 空格硬降 z/x转  p暂停  r重开  v人机  u语言  q退出  ",
    tetris_help_vs = "  hjkl移动 空格硬降 z/x转  p暂停  r重开  m单人  u语言  q退出 | 消越多罚越重 ",
    tetris_over = "  ★ GAME OVER  按 r 重开  v 人机  u 语言  q 退出",
    tetris_you_win = "  你赢了！按 r 再战  m 单人  u 语言  q 退出",
    tetris_ai_win = "  电脑获胜！按 r 再战  m 单人  u 语言  q 退出",
    tetris_draw = "  双双出局… 按 r 再战  u 语言  q 退出",
    tetris_help_box = "俄罗斯方块\n操作: hjkl/方向  空格硬降  z/x 旋转  p 暂停  r 重开  u 中英文  q 退出\nv 人机对战  m 单人\n对战: 惩罚=三角数(清行+特殊格)；对方落地后顶入垃圾\n特殊↓←↑→: 箭头=朝向；↓填下 ←→填侧；↑仅1格",
    tetris_btn_lang = "[中文/EN]",
    tetris_mode_versus = "人机对战",
    tetris_mode_solo = "单人",
    tetris_special_ready = "就绪/使用中",
    tetris_title = "  俄罗斯方块 [%s]  你:%d分/%d行 特殊↓:%s  ",
    tetris_title_ai = "电脑:%d分 特殊:%s 待攻你/它:%d/%d  ",
    tetris_title_level = "级:%d  ",
    tetris_you = " 你",
    tetris_ai = " 电脑",
    tetris_next = "下一",
    tetris_paused = "  已暂停  按 p 继续",
    tetris_resume = "  继续",
    tetris_label_you = "你",
    tetris_label_ai = "电脑",
    tetris_cleared = "  %s 消除 %d 行！",
    tetris_punish = "  %s 清 %d（行%d+填%d）→ 惩罚 %s %d 行垃圾",
    tetris_garbage = "  %s 遭受 %d 行垃圾干扰！",
    tetris_special_up = "  %s 特殊↑ 仅 1 格（不能向上填充）",
    tetris_special_fill = "  %s 特殊%s 填充%s前方…",
    tetris_special_cell = "  %s 特殊%s 填格 %d/%d",
    tetris_dir_down = "下",
    tetris_dir_left = "左",
    tetris_dir_up = "上",
    tetris_dir_right = "右",
    tetris_axis_col = "下方列",
    tetris_axis_row = "侧向行",
    tetris_start_versus = "  人机对战！双方方块顺序相同；消越多罚越重；右侧显示下一块",
    tetris_start_solo = "  单人  每 %d 分出 1 个特殊↓（用完后重新计分）  右侧=下一  v 人机",
  },
  en = {
    menu_title = "nvimgames",
    menu_hint = "1-4 select · u language · Esc quit",
    game_mine = "Minesweeper",
    game_sokoban = "Sokoban",
    game_twentyfour = "24 Points",
    game_tetris = "Tetris",
    lang_btn = " EN/中文 ",
    lang_switched = "UI language: English",

    quit = "quit",
    help = "help",
    restart = "Restart",
    pause = "pause",

    mine_diff_beginner = "Beginner",
    mine_diff_intermediate = "Intermediate",
    mine_diff_expert = "Expert",
    mine_won = " Status: You win! Click 🙂 for a new game",
    mine_lost = " Status: Boom… Click 🙂 to restart",
    mine_ready = " %s %dx%d  mines:%d  | LMB open  RMB flag  MMB/chord  1/2/3 difficulty  u lang  q quit",
    mine_playing = " %s  left:%d  time:%ds  | LMB open  RMB flag  u lang  q quit",
    mine_footer = " [%s] [%s] [%s]   [%s]  [%s]",
    mine_help = "Minesweeper\nLMB:open  RMB:flag  MMB:chord\n1/2/3:difficulty  r:restart  u:language  hjkl  Space:open  m:flag  c:chord  q:quit",

    sokoban_title = " Sokoban  Lv %d/%d  %s  steps:%d  %s",
    sokoban_cleared = "★ Cleared!",
    sokoban_help = " hjkl/arrows move  z undo  r restart  n/p next/prev  g jump  u lang  q quit ",
    sokoban_next = " ★ Cleared! Space=next level, r=retry ",
    sokoban_jump = "Jump to level (1-%d): ",
    sokoban_help_box = "Sokoban\nhjkl move  z undo  r restart  n/p next/prev  g jump\nu language\nSpace after clear for next  q quit",
    sokoban_btn_lang = "[EN/中文]",
    sokoban_no_level = "sokoban: level file not found ",
    sokoban_bad_json = "sokoban: bad level JSON",
    sokoban_bad_level = "sokoban: invalid level ",

    tf_title = "  24 Points  |  score:%d  rounds:%d  ",
    tf_help = "  type formula  Enter check  Space clear after error  r new  h hint  u lang  q quit  ",
    tf_help_box = "24 Points\nType formula after expr> , Enter to check\nSpace clears after error; r deals new cards\nA=1 J=11 Q=12 K=13; ops + - * / ()\ni edit  r new  h hint  u language (or click bottom button)  q quit\ne.g. (8/(3-8/3))",
    tf_cleared = "  Cleared, type again",
    tf_btn_lang = "[EN/中文]",
    tf_expr_prefix = "  expr> ",
    tf_points = "  Values: %s   (A=1  J=11  Q=12  K=13)",
    tf_answer = "  Answer: %s",
    tf_prompt = "  Type after expr> and press Enter",
    tf_prompt_default = "  Type formula below, Enter to check if equals 24",
    tf_already = "  Already solved, press r for new cards",
    tf_empty_input = "  Empty formula, type after expr>",
    tf_ok_next = "  ★ %s  press r for next",
    tf_bad_space = "  ✗ %s  (Space to clear)",
    tf_show_ans = "  Answer shown",
    tf_hide_ans = "  Answer hidden",
    tf_no_ans = "  No solution or solve failed",
    tf_only_ops = "Only digits and + - * / ( ) allowed",
    tf_expr_empty = "empty formula",
    tf_expr_long = "formula too long",
    tf_syntax = "syntax error: %s",
    tf_calc_err = "calc error: %s",
    tf_not_number = "result is not a number",
    tf_invalid = "invalid result (div by zero?)",
    tf_parse_fail = "failed to parse numbers",
    tf_no_decimal = "integers only, no decimals",
    tf_need_4 = "must use exactly 4 numbers (got %d)",
    tf_use_cards = "use each of the 4 cards once: need [%s], got [%s]",
    tf_eval_fail = "evaluation failed",
    tf_correct = "correct! = %g",
    tf_wrong_val = "got %g, not 24",

    tetris_help = "  hjkl move  Space hard-drop  z/x rotate  p pause  r restart  v vs-AI  u lang  q quit  ",
    tetris_help_vs = "  hjkl move  Space hard-drop  z/x rotate  p pause  r restart  m solo  u lang  q quit | more clears=more garbage ",
    tetris_over = "  ★ GAME OVER  r restart  v vs-AI  u lang  q quit",
    tetris_you_win = "  You win!  r again  m solo  u lang  q quit",
    tetris_ai_win = "  AI wins!  r again  m solo  u lang  q quit",
    tetris_draw = "  Both out…  r again  u lang  q quit",
    tetris_help_box = "Tetris\nhjkl/arrows  Space hard-drop  z/x rotate  p pause  r restart  u language  q quit\nv vs-AI  m solo\nvs: triangular garbage (lines+special cells)\nspecial ↓←↑→: arrow=dir; ↓ fill down; ←→ side; ↑ 1 cell only",
    tetris_btn_lang = "[EN/中文]",
    tetris_mode_versus = "vs AI",
    tetris_mode_solo = "solo",
    tetris_special_ready = "ready/active",
    tetris_title = "  Tetris [%s]  you:%d pts/%d ln  sp↓:%s  ",
    tetris_title_ai = "AI:%d pts sp:%s garbage you/it:%d/%d  ",
    tetris_title_level = "Lv:%d  ",
    tetris_you = " You",
    tetris_ai = " AI",
    tetris_next = "next",
    tetris_paused = "  Paused  press p to resume",
    tetris_resume = "  Resumed",
    tetris_label_you = "You",
    tetris_label_ai = "AI",
    tetris_cleared = "  %s cleared %d lines!",
    tetris_punish = "  %s clear %d (ln%d+fill%d) → garbage to %s: %d",
    tetris_garbage = "  %s hit by %d garbage lines!",
    tetris_special_up = "  %s special↑ only 1 cell (cannot fill up)",
    tetris_special_fill = "  %s special%s filling %s…",
    tetris_special_cell = "  %s special%s cell %d/%d",
    tetris_dir_down = "↓",
    tetris_dir_left = "←",
    tetris_dir_up = "↑",
    tetris_dir_right = "→",
    tetris_axis_col = "column below",
    tetris_axis_row = "side row",
    tetris_start_versus = "  vs AI! same piece sequence; more clears = more garbage; next on the right",
    tetris_start_solo = "  Solo  every %d pts → 1 special↓ (resets after use)  right=next  v vs-AI",
  },
}

function M.detect()
  local cands = {
    vim.v.lang,
    vim.env.LC_ALL,
    vim.env.LC_MESSAGES,
    vim.env.LANG,
    vim.o.langmenu,
  }
  for _, c in ipairs(cands) do
    if type(c) == "string" and c ~= "" and c ~= "C" and c ~= "POSIX" then
      local low = c:lower()
      if low:match("^zh")
        or low:find("chinese", 1, true)
        or low:find("china", 1, true)
        or low:find("taiwan", 1, true)
      then
        return "zh"
      end
      if low:match("^en") then
        return "en"
      end
    end
  end
  if vim.fn.has("win32") == 1 then
    local ok, out = pcall(function()
      return vim.fn.system({
        "powershell",
        "-NoProfile",
        "-Command",
        "[System.Globalization.CultureInfo]::CurrentUICulture.Name",
      })
    end)
    if ok and type(out) == "string" then
      local low = out:lower():gsub("%s+", "")
      if low:match("^zh") then
        return "zh"
      end
    end
  end
  return "en"
end

function M.setup(user_lang)
  if user_lang == "zh" or user_lang == "en" then
    lang = user_lang
  else
    lang = M.detect()
  end
  return lang
end

function M.get()
  return lang
end

function M.set(l)
  if l == "zh" or l == "en" then
    lang = l
  end
  return lang
end

function M.toggle()
  lang = (lang == "zh") and "en" or "zh"
  return lang
end

---@param key string
---@return string
function M.t(key)
  local pack = STR[lang] or STR.en
  return pack[key] or STR.en[key] or key
end

---sprintf helper
function M.tf(key, ...)
  return string.format(M.t(key), ...)
end

return M
