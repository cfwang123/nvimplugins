" autoload/ntemoji.vim — NERDTree emoji flag helper
if exists('g:autoloaded_ntemoji')
  finish
endif
let g:autoloaded_ntemoji = 1

function! ntemoji#glyph_for_path(path) abort
  let is_dir = a:path.isDirectory ? 1 : 0
  let is_link = a:path.isSymLink ? 1 : 0
  let is_open = -1
  if is_dir && has_key(a:path, 'isOpen')
    let is_open = a:path.isOpen ? 1 : 0
  endif
  return luaeval(
        \ 'require("ntemoji").flag_string(_A[1], _A[2], _A[3], _A[4])',
        \ [a:path.str(), is_dir, is_open, is_link])
endfunction

function! ntemoji#refresh_listener(event) abort
  if get(g:, 'ntemoji_enabled', 1) == 0
    return
  endif
  " 与 vim-devicons 共存时不写 flag，避免双图标
  if get(g:, 'loaded_webdevicons', 0) || get(g:, 'webdevicons_enable', 0)
    return
  endif
  let path = a:event.subject
  let flag = ntemoji#glyph_for_path(path)
  call path.flagSet.clearFlags('ntemoji')
  if flag !=# ''
    call path.flagSet.addFlag('ntemoji', flag)
  endif
endfunction

function! ntemoji#register() abort
  if get(g:, 'ntemoji_listeners_registered', 0)
    return 1
  endif
  if !exists('g:NERDTreePathNotifier')
    return 0
  endif
  call g:NERDTreePathNotifier.AddListener('init', 'ntemoji#refresh_listener')
  call g:NERDTreePathNotifier.AddListener('refresh', 'ntemoji#refresh_listener')
  let g:ntemoji_listeners_registered = 1
  call ntemoji#setup_conceal()
  return 1
endfunction

" NERDTree FlagSet.renderToString() 固定输出 [flags]
" 用 conceal 隐藏中括号（同 vim-devicons 的做法）
function! ntemoji#setup_conceal() abort
  if get(g:, 'ntemoji_conceal_brackets', 1) == 0
    return
  endif
  augroup ntemoji_conceal_nerdtree_brackets
    autocmd!
    autocmd FileType nerdtree call ntemoji#apply_conceal()
    " NERDTree 渲染后会重设 syntax，再补一次
    autocmd Syntax nerdtree call ntemoji#apply_conceal()
  augroup END
  " 若已在 nerdtree 缓冲区内
  if &filetype ==# 'nerdtree'
    call ntemoji#apply_conceal()
  endif
endfunction

function! ntemoji#apply_conceal() abort
  if get(g:, 'ntemoji_conceal_brackets', 1) == 0
    return
  endif
  if &filetype !=# 'nerdtree'
    return
  endif
  " 隐藏 NERDTreeFlags（及 symlink 相关）语法组中的 []
  syntax match ntemojiHideBrackets "\[" contained conceal containedin=NERDTreeFlags,NERDTreeLinkFile,NERDTreeLinkDir
  syntax match ntemojiHideBrackets "\]" contained conceal containedin=NERDTreeFlags,NERDTreeLinkFile,NERDTreeLinkDir
  setlocal conceallevel=3
  setlocal concealcursor=nvic
endfunction
