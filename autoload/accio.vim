"==============================================================================
"File:        accio.vim
"Description: Neovim job-control wrapper around :compiler and :make
"Maintainer:  Pierre-Guy Douyon <pgdouyon@alum.mit.edu>
"Version:     1.0.0
"Last Change: 2015-03-23
"License:     MIT
"==============================================================================

let s:save_cpo = &cpoptions
set cpoptions&vim

" ----------------------------------------------------------------------
" Configuration and Defaults
" ----------------------------------------------------------------------
let s:job_prefix = 'accio'
let s:accio_sign_id = '954'
let s:jobs_in_progress = 0
let s:accio_queue = []
let s:accio_quickfix_list = []
let s:accio_jobs = {}
let s:accio_messages = {}


function! accio#accio(args)
    let save_makeprg = &l:makeprg
    let save_errorformat = &l:errorformat
    let [args; rest] = s:parse_accio_args(a:args)
    let [compiler, compiler_args] = matchlist(args, '^\(\S*\)\s*\(.*\)')[1:2]
    let [make_command, make_target] = s:parse_makeprg(compiler, compiler_args)
    if s:jobs_in_progress
        call add(s:accio_queue, [a:args, bufnr("%")])
    else
        let s:quickfix_cleared = 0
        let accio_job = s:new_accio_job(compiler, make_target, &l:errorformat)
        call s:start_job(accio_job, make_command)
        call s:process_arglist(rest)
        let s:accio_jobs[make_target][compiler] = accio_job
        let s:jobs_in_progress = 1 + len(rest)
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
    let make_target = (is_make_local ? bufnr("%") : "global")
    let make_command = join([makeprg, makeargs])
    return [make_command, make_target]
endfunction


function! s:new_accio_job(compiler, make_target, errorformat)
    if !has_key(s:accio_jobs, a:make_target)
        let s:accio_jobs[a:make_target] = {}
    endif
    let template = {"signs": [], "errors": []}
    let accio_job = get(s:accio_jobs[a:make_target], a:compiler, template)
    let accio_job.compiler = a:compiler
    let accio_job.make_target = a:make_target
    let accio_job.errorformat = a:errorformat
    let accio_job.is_initialized = 0
    return accio_job
endfunction


function! s:start_job(accio_job, make_command)
    let compiler = a:accio_job.compiler
    let make_target = a:accio_job.make_target
    let job_name = s:get_job_name(compiler, make_target)
    execute printf("autocmd! JobActivity %s call <SID>job_handler('%s', '%s')", job_name, compiler, make_target)
    call jobstart(job_name, &sh, ['-c', a:make_command])
endfunction


function! s:get_job_name(compiler, make_target)
    return join([s:job_prefix, a:compiler, a:make_target], "_")
endfunction


function! s:process_arglist(rest)
    for args in a:rest
        call accio#accio(args)
        let s:jobs_in_progress = 0
    endfor
endfunction


function! s:job_handler(compiler, make_target)
    let accio_job = s:accio_jobs[a:make_target][a:compiler]
    if !accio_job.is_initialized | call s:initialize_accio_job(accio_job) | endif
    if !s:quickfix_cleared | call s:initialize_quickfix() | endif
    if v:job_data[1] ==# "exit"
        let s:jobs_in_progress -= 1
        execute "autocmd! JobActivity " . s:get_job_name(a:compiler, a:make_target)
        call s:accio_process_queue()
    else
        let errors = s:add_to_error_window(v:job_data[2], accio_job.errorformat)
        let signs = filter(errors, 'v:val.bufnr > 0 && v:val.lnum > 0')
        let [accio_job.errors, accio_job.signs] += [errors, signs]
        call s:place_signs(signs)
        call s:save_sign_messages(signs, a:compiler)
    endif
    if g:accio_auto_copen && !empty(getqflist())
        execute printf("copen %d | %d wincmd w", len(getqflist()), winnr())
    endif
endfunction


function! s:initialize_accio_job(accio_job)
    let old_signs = a:accio_job.signs
    let a:accio_job.signs = []
    let a:accio_job.errors = []
    let a:accio_job.is_initialized = 1
    call s:unplace_signs(old_signs)
    call s:clear_sign_messages(old_signs)
endfunction


function! s:initialize_quickfix()
    if s:is_accio_quickfix_list()
        call setqflist([], "r")
    else
        call setqflist([])
    endif
    let s:quickfix_cleared = 1
    let s:accio_quickfix_list = []
endfunction


function! s:add_to_error_window(error_lines, errorformat)
    if !s:is_accio_quickfix_list()
        call setqflist(s:accio_quickfix_list)
    endif
    let save_errorformat = &g:errorformat
    let &g:errorformat = a:errorformat
    let initial_errors = getqflist() | call setqflist([], "r")
    caddexpr a:error_lines
    let new_errors = getqflist() | call setqflist([], "r")
    let s:accio_quickfix_list = extend(initial_errors, new_errors)
    call setqflist(s:accio_quickfix_list, "a")
    let &g:errorformat = save_errorformat
    return new_errors
endfunction


function! s:is_accio_quickfix_list()
    return (getqflist() ==# s:accio_quickfix_list)
endfunction


function! s:place_signs(errors)
    for error in a:errors
        let id = error.bufnr . s:accio_sign_id . error.lnum
        let sign_type = get(error, "type", "E")
        let sign_name = (sign_type =~? '^[EF]') ? "AccioError" : "AccioWarning"
        let sign = {"id": id, "lnum": error.lnum, "name": sign_name, "bufnr": error.bufnr}
        execute printf("sign place %d line=%d name=%s buffer=%d",
                    \ sign.id, sign.lnum, sign.name, sign.bufnr)
    endfor
endfunction


function! s:save_sign_messages(signs, compiler)
    for sign in a:signs
        if !has_key(s:accio_messages, sign.bufnr)
            let s:accio_messages[sign.bufnr] = {}
        endif
        let tab_spaces = repeat(' ', &tabstop)
        let message_prefix = printf("[Accio - %s] ", a:compiler)
        let msg = get(sign, "text", "No error message available...")
        let msg = substitute(msg, '\n', ' ', 'g')
        let msg = substitute(msg, '\t', tab_spaces, 'g')
        let msg = strpart(msg, 0, &columns - 1)
        let s:accio_messages[sign.bufnr][sign.lnum] = message_prefix . msg
    endfor
endfunction


function! accio#echo_message()
    let buffer_messages = get(s:accio_messages, bufnr("%"), {})
    let message = get(buffer_messages, line("."), "")
    if !empty(message)
        echohl WarningMsg | echo message | echohl None
        let b:accio_echoed_message = 1
    elseif exists("b:accio_echoed_message") && b:accio_echoed_message
        echo
        let b:accio_echoed_message = 0
    endif
endfunction


function! s:unplace_signs(signs)
    for sign in a:signs
        let id = sign.bufnr . s:accio_sign_id . sign.lnum
        execute "sign unplace " . id . " buffer=" . sign.bufnr
    endfor
endfunction


function! s:clear_sign_messages(signs)
    for sign in a:signs
        let bufnr = sign.bufnr
        let lnum = sign.lnum
        silent! unlet s:accio_messages[bufnr][lnum]
    endfor
endfunction


function! s:accio_process_queue()
    if !empty(s:accio_queue)
        call uniq(sort(s:accio_queue))
        let save_buffer = bufnr("%")
        let [accio_args, target_buffer] = s:accio_queue[0]
        execute "silent! buffer " . target_buffer
        call accio#accio(accio_args)
        execute "buffer " save_buffer
    endif
endfunction


function! accio#statusline()
    let bufnr = bufnr("%")
    let statusline = "Errors: "
    let error_count = len(get(s:accio_messages, bufnr, {}))
    return statusline . error_count
endfunction


function! accio#next_warning(forward, visual_mode) abort
    let current_line = line(".")
    let bufnr = bufnr("%")
    let warning_lines = keys(s:accio_messages[bufnr])
    let [prev, next] = [min(warning_lines), max(warning_lines)]
    for wl in warning_lines
        if wl < current_line
            let prev = max([prev, wl])
        elseif wl > current_line
            let next = min([next, wl])
        endif
    endfor
    let target = a:forward ? next : prev
    let visual_mode = a:visual_mode ? "gv" : ""
    execute "normal!" visual_mode . target . "G"
endfunction

let &cpoptions = s:save_cpo
unlet s:save_cpo
