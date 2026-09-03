if exists('g:loaded_lace_keymap_logger')
  finish
endif
let g:loaded_lace_keymap_logger = 1

if !exists('g:lace_keylog_path')
  let g:lace_keylog_path = exists('$LACE_KEYLOG') && !empty($LACE_KEYLOG) ? $LACE_KEYLOG : '.lace-keylog.jsonl'
endif
if !exists('g:lace_keylog_task')
  let g:lace_keylog_task = exists('$LACE_KEYLOG_TASK') ? $LACE_KEYLOG_TASK : ''
endif
if !exists('g:lace_keylog_redact')
  let g:lace_keylog_redact = !exists('$LACE_KEYLOG_REDACT') || $LACE_KEYLOG_REDACT !=# '0'
endif

let s:start = reltime()
let s:events = []
let s:seq = 0

function! s:IsTextMode(mode) abort
  return a:mode =~# '^[iRr]' || a:mode =~# '^c'
endfunction

function! s:KeyName(value) abort
  if empty(a:value)
    return ''
  endif
  return keytrans(a:value)
endfunction

function! s:Redact(mode, value) abort
  let name = s:KeyName(a:value)
  if !g:lace_keylog_redact || !s:IsTextMode(a:mode)
    return name
  endif

  if name =~# '^<.*>$'
    return name
  endif
  if name ==# "\t"
    return '<Tab>'
  endif
  if name ==# "\r" || name ==# "\n"
    return '<Enter>'
  endif
  if name ==# "\e"
    return '<Esc>'
  endif
  return '<text>'
endfunction

function! s:Record(mode) abort
  let typed = get(v:event, 'typedchar', '')
  let event = {
        \ 'type': 'key',
        \ 'seq': s:seq,
        \ 'time_ms': reltimefloat(reltime(s:start)) * 1000.0,
        \ 'mode': a:mode,
        \ 'typed': s:Redact(a:mode, typed),
        \ 'mapped': s:Redact(a:mode, v:char),
        \ 'is_typed': get(v:event, 'typed', v:false),
        \ 'line': line('.'),
        \ 'col': col('.'),
        \ 'changedtick': get(b:, 'changedtick', -1),
        \ }
  let s:seq += 1
  call add(s:events, json_encode(event))
endfunction

function! s:Flush() abort
  let header = json_encode({
        \ 'type': 'session',
        \ 'task': g:lace_keylog_task,
        \ 'editor': 'vim',
        \ 'version': v:versionlong,
        \ 'redacted': g:lace_keylog_redact,
        \ })
  let lines = [header] + s:events
  let parent = fnamemodify(g:lace_keylog_path, ':h')
  if !empty(parent) && parent !=# '.'
    call mkdir(parent, 'p')
  endif
  call writefile(lines, g:lace_keylog_path, 'a')
endfunction

augroup lace_keymap_logger
  autocmd!
  autocmd KeyInputPre * call <SID>Record(expand('<amatch>'))
  autocmd VimLeavePre * call <SID>Flush()
augroup END
