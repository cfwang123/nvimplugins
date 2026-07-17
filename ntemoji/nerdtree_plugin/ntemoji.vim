" NERDTree auto-sources runtimepath **/nerdtree_plugin/*.vim
" Register emoji flags as soon as NERDTree loads this file.
if exists('g:loaded_ntemoji_nerdtree_plugin')
  finish
endif
let g:loaded_ntemoji_nerdtree_plugin = 1

" Ensure lua module defaults
silent! lua require('ntemoji').ensure_setup()

if exists('g:NERDTreePathNotifier')
  call ntemoji#register()
else
  " 仅补 conceal（监听稍后由 plugin 注册）
  call ntemoji#setup_conceal()
endif
