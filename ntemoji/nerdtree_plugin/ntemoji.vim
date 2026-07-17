" NERDTree auto-sources runtimepath **/nerdtree_plugin/*.vim
" Register emoji flags as soon as NERDTree loads this file.
if exists('g:loaded_ntemoji_nerdtree_plugin')
  finish
endif
let g:loaded_ntemoji_nerdtree_plugin = 1

" 已装 vim-devicons → 整插件不启用
if ntemoji#devicons_present()
  let g:ntemoji_enabled = 0
  finish
endif

" Ensure lua module defaults
silent! lua require('ntemoji').ensure_setup()

" setup 后可能因 devicons 关闭
if get(g:, 'ntemoji_enabled', 1) == 0
  finish
endif

if exists('g:NERDTreePathNotifier')
  call ntemoji#register()
else
  " 仅补 conceal（监听稍后由 plugin 注册）
  call ntemoji#setup_conceal()
endif
