" 整仓入口：vim-plug 在启动阶段只把仓库根加入 rtp；plugin 脚本在 init 之后加载。
" 用户只需一行：Plug 'cfwang123/nvimplugins'
" 本文件负责把各子插件 plugin/ 挂上（命令等）；require 走根目录 lua/* 代理。
if exists('g:loaded_nvimplugins_bundle_vim')
  finish
endif
let g:loaded_nvimplugins_bundle_vim = 1

let s:lua = expand('<sfile>:p:h') . '/nvimplugins.lua'
if filereadable(s:lua)
  execute 'luafile' fnameescape(s:lua)
endif
