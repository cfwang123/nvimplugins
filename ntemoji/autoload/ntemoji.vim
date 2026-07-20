" autoload/ntemoji.vim — NERDTree emoji flag helper
if exists('g:autoloaded_ntemoji')
  finish
endif
let g:autoloaded_ntemoji = 1

" 是否已装/已加载 vim-devicons（有则 ntemoji 整插件不启用）
" g:ntemoji_force = 1 可强制启用（不推荐）
function! ntemoji#devicons_present() abort
  if get(g:, 'ntemoji_force', 0)
    return 0
  endif
  if get(g:, 'loaded_webdevicons', 0)
    return 1
  endif
  if exists('*WebDevIconsGetFileTypeSymbol')
    return 1
  endif
  " runtimepath 上已有插件文件（vim-plug 安装后即使尚未 source 也能判）
  if !empty(globpath(&runtimepath, 'plugin/webdevicons.vim', 0, 1))
    return 1
  endif
  if !empty(globpath(&runtimepath, 'nerdtree_plugin/webdevicons.vim', 0, 1))
    return 1
  endif
  return 0
endfunction

function! ntemoji#should_enable() abort
  if get(g:, 'ntemoji_enabled', 1) == 0
    return 0
  endif
  if ntemoji#devicons_present()
    let g:ntemoji_enabled = 0
    return 0
  endif
  return 1
endfunction

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
  if !ntemoji#should_enable()
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
  if !ntemoji#should_enable()
    return 0
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
" 用 conceal 隐藏中括号（vim-devicons 同思路，并加 matchadd 兜底）
function! ntemoji#setup_conceal() abort
  if !ntemoji#should_enable()
    return
  endif
  if get(g:, 'ntemoji_conceal_brackets', 1) == 0
    return
  endif
  augroup ntemoji_conceal_nerdtree_brackets
    autocmd!
    autocmd FileType nerdtree call ntemoji#apply_conceal()
    " NERDTree 加载 syntax 后会 clear，并可能把 conceallevel 改回 2
    autocmd Syntax nerdtree call ntemoji#apply_conceal()
    " matchadd 是 window-local：进入树窗口时再挂一次
    autocmd BufWinEnter,WinEnter * if &filetype ==# 'nerdtree' | call ntemoji#apply_conceal() | endif
    " 部分 NERDTree 操作只改 buffer 文本、不重触发 Syntax
    autocmd User NERDTreeInit,NERDTreeNewRoot call ntemoji#apply_conceal()
  augroup END
  if &filetype ==# 'nerdtree'
    call ntemoji#apply_conceal()
  endif
endfunction

function! ntemoji#apply_conceal() abort
  if !ntemoji#should_enable()
    return
  endif
  if get(g:, 'ntemoji_conceal_brackets', 1) == 0
    return
  endif
  if &filetype !=# 'nerdtree'
    return
  endif

  " 1) 与 vim-devicons 相同：嵌在 NERDTreeFlags 内（有时因 nesting 失败）
  silent! syntax match ntemojiHideBrackets "\[" contained conceal containedin=NERDTreeFlags,NERDTreeLinkFile,NERDTreeLinkDir
  silent! syntax match ntemojiHideBrackets "\]" contained conceal containedin=NERDTreeFlags,NERDTreeLinkFile,NERDTreeLinkDir

  " 2) 不依赖 syntax 嵌套：匹配短 flag 形如 [ … ] 的左右括号
  "    （emoji / git flag 都较短；避免误伤帮助文本里其它 []）
  silent! syntax match ntemojiHideOpen /\[\ze[^[\]]\{1,40}\]/ conceal
  silent! syntax match ntemojiHideClose /\[[^[\]]\{1,40}\zs\]/ conceal

  " 3) matchadd 兜底（不依赖 syntax 组；Neovim 下为 window-local）
  if exists('w:ntemoji_match_ids')
    for s:id in w:ntemoji_match_ids
      silent! call matchdelete(s:id)
    endfor
  endif
  let w:ntemoji_match_ids = []
  try
    call add(w:ntemoji_match_ids, matchadd('Conceal', '\[\ze[^[\]]\{1,40}\]', 100, -1, {'conceal': ''}))
    call add(w:ntemoji_match_ids, matchadd('Conceal', '\[[^[\]]\{1,40}\zs\]', 100, -1, {'conceal': ''}))
  catch
    " 旧 Vim 无 conceal 字典参数时退回仅 syntax
  endtry

  setlocal conceallevel=3
  setlocal concealcursor=nvic
endfunction

