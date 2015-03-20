"==============================================================================
"File:        accio.vim
"Description: Neovim job-control wrapper around :compiler and :make
"Maintainer:  Pierre-Guy Douyon <pgdouyon@alum.mit.edu>
"Version:     1.0.0
"Last Change: 2015-03-20
"License:     MIT
"==============================================================================

let s:save_cpo = &cpoptions
set cpoptions&vim

" ----------------------------------------------------------------------
" Configuration and Defaults
" ----------------------------------------------------------------------
let s:job_prefix = 'accio_'
let s:sign_id_prefix = '954'
let s:in_progress = 0
let s:accio_queue = []
let s:accio_signs = {}
let s:accio_sign_messages = {}


function! accio#accio(args, ...)
    let save_makeprg = &l:makeprg
    let save_errorformat = &l:errorformat
    let [args; rest] = s:parse_accio_args(a:args)
    let [accio_prg, accio_args] = matchlist(args, '^\(\S*\)\s*\(.*\)')[1:2]
    let [makeprg, makeargs, makeprg_target] = s:parse_makeprg(accio_prg, accio_args)
    if s:in_progress
        call add(s:accio_queue, [a:args, makeprg_target])
    else
        let clear_quickfix = a:0 ? a:1 : 1
        call s:setup_accio(makeprg, makeprg_target, clear_quickfix)
        let job_name = s:get_job_name(makeprg, makeprg_target)
        execute printf("autocmd! JobActivity %s call <SID>job_handler('%s', '%s', '%s')",
                    \ job_name, makeprg, makeprg_target, &l:errorformat)
        call jobstart(job_name, makeprg, split(makeargs))
        call s:process_arglist(rest)
        let s:in_progress = 1 + len(rest)
    endif
    let &l:makeprg = save_makeprg
    let &l:errorformat = save_errorformat
endfunction


function! s:parse_accio_args(args)
    if a:args[0] ==# "[" && a:args[-1:] ==# "]"
        let args = eval(a:args)[0]
        let rest = eval(a:args)[1:]
    else
        let args = a:args
        let rest = []
    endif
    return [args] + rest
endfunction


function! s:parse_makeprg(compiler, args)
    execute "compiler " . a:compiler
    let [makeprg, makeargs] = matchlist(&l:makeprg, '^\s*\(\S*\)\s*\(.*\)')[1:2]
    let makeargs = (makeargs =~ '\$\*') ? substitute(makeargs, '\$\*', escape(a:args, '&\'), 'g') : makeargs." ".a:args
    let makeargs = substitute(makeargs, '\\\@<!\%(%\|#\)\%(:[phtre~.S]\)*', '\=expand(submatch(0))', 'g')
    let local_make_re = '[^\\]\%(%\|#\)'
    let is_make_local = (&l:makeprg =~# local_make_re) || (a:args =~# local_make_re)
    let makeprg_target = (is_make_local ? bufnr("%") : "global")
    return [makeprg, makeargs, makeprg_target]
endfunction


function! s:setup_accio(makeprg, makeprg_target, clear_quickfix)
    if !has_key(s:accio_signs, a:makeprg)
        let s:accio_signs[a:makeprg] = {}
    endif

    if a:clear_quickfix
        cgetexpr []
    endif
    let signs = get(s:accio_signs[a:makeprg], a:makeprg_target, [])
    let s:accio_signs[a:makeprg][a:makeprg_target] = []
    call s:unplace_signs(signs)
    call s:clear_sign_messages(signs)
endfunction


function! s:get_job_name(makeprg, makeprg_target)
    return s:job_prefix . a:makeprg . "_" . a:makeprg_target
endfunction


function! s:process_arglist(rest)
    for arg in a:rest
        call accio#accio(arg, 0)
        let s:in_progress = 0
    endfor
endfunction


function! s:job_handler(makeprg, makeprg_target, errorformat)
    if v:job_data[1] ==# "exit"
        let s:in_progress -= 1
        execute "autocmd! JobActivity " . s:get_job_name(a:makeprg, a:makeprg_target)
        call s:accio_process_queue()
    else
        let errors = s:add_to_error_window(v:job_data[2], a:errorformat)
        let signs = filter(errors, 'v:val.bufnr > 0 && v:val.lnum > 0')
        call s:place_signs(signs)
        call s:save_sign_messages(signs)
        call extend(s:accio_signs[a:makeprg][a:makeprg_target], signs)
        execute "cwindow | " winnr() " wincmd w"
    endif
endfunction


function! s:add_to_error_window(error_lines, errorformat)
    let save_errorformat = &g:errorformat
    let &g:errorformat = a:errorformat
    caddexpr a:error_lines
    let errors = getqflist()
    let &g:errorformat = save_errorformat
    return errors
endfunction


function! s:place_signs(errors)
    for error in a:errors
        let id = error.bufnr . s:sign_id_prefix . error.lnum
        let sign_type = get(error, "type", "E")
        let sign_name = (sign_type =~? '^[EF]') ? "AccioError" : "AccioWarning"
        let sign = {"id": id, "lnum": error.lnum, "name": sign_name, "bufnr": error.bufnr}
        execute printf("sign place %d line=%d name=%s buffer=%d",
                    \ sign.id, sign.lnum, sign.name, sign.bufnr)
    endfor
endfunction


function! s:save_sign_messages(signs)
    for sign in a:signs
        if !has_key(s:accio_sign_messages, sign.bufnr)
            let s:accio_sign_messages[sign.bufnr] = {}
        endif
        let tab_spaces = repeat(' ', &tabstop)
        let msg = get(sign, "text", "No error message available...")
        let msg = substitute(msg, '\n', ' ', 'g')
        let msg = substitute(msg, '\t', tab_spaces, 'g')
        let msg = strpart(msg, 0, &columns - 1)
        let s:accio_sign_messages[sign.bufnr][sign.lnum] = "[Accio] " . msg
    endfor
endfunction


function! accio#echo_message()
    let bufnr = bufnr("%")
    let lnum = line(".")
    if has_key(s:accio_sign_messages, bufnr) && has_key(s:accio_sign_messages[bufnr], lnum)
        echohl WarningMsg | echo s:accio_sign_messages[bufnr][lnum] | echohl None
    else
        echo
    endif
endfunction


function! s:unplace_signs(signs)
    for sign in a:signs
        let id = sign.bufnr . s:sign_id_prefix . sign.lnum
        execute "sign unplace " . id . " buffer=" . sign.bufnr
    endfor
endfunction


function! s:clear_sign_messages(signs)
    for sign in a:signs
        let bufnr = sign.bufnr
        let lnum = sign.lnum
        silent! unlet s:accio_sign_messages[bufnr][lnum]
    endfor
endfunction


function! s:accio_process_queue()
    let save_buffer = bufnr("%")
    call uniq(sort(s:accio_queue))
    for call_args in s:accio_queue
        let accio_args = call_args[0]
        let target_buffer = call_args[1]
        execute "silent! buffer " . target_buffer
        call accio#accio(accio_args)
    endfor
    execute "buffer " save_buffer
endfunction


function! accio#statusline()
    let bufnr = bufnr("%")
    let statusline = "Errors: "
    let error_count = len(get(s:accio_sign_messages, bufnr, {}))
    return statusline . error_count
endfunction

let &cpoptions = s:save_cpo
unlet s:save_cpo
