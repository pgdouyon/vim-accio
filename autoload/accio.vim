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
let s:compiler_tasks = {}
let s:accio_messages = {}


function! accio#accio(args)
    let save_makeprg = &l:makeprg
    let save_errorformat = &l:errorformat
    let [args; rest] = s:parse_accio_args(a:args)
    let [compiler, compiler_args] = matchlist(args, '^\(\S*\)\s*\(.*\)')[1:2]
    let [compiler_command, compiler_target] = s:parse_makeprg(compiler, compiler_args)
    if s:jobs_in_progress
        call add(s:accio_queue, [a:args, bufnr("%")])
    else
        let s:quickfix_cleared = 0
        let compiler_task = s:new_compiler_task(compiler, compiler_target, compiler_command, &l:errorformat)
        call s:start_job(compiler_task)
        call s:process_arglist(rest)
        call s:save_compiler_task(compiler_task)
        let s:jobs_in_progress = 1 + len(rest)
    endif
    let &l:makeprg = save_makeprg
    let &l:errorformat = save_errorformat
endfunction


function! accio#accio_vim(args)
    let save_makeprg = &l:makeprg
    let save_errorformat = &l:errorformat
    call s:initialize_quickfix()
    for arg in s:parse_accio_args(a:args)
        let [compiler, compiler_args] = matchlist(arg, '^\(\S*\)\s*\(.*\)')[1:2]
        execute printf("silent! colder | compiler %s | silent noautocmd make! %s | redraw!", compiler, compiler_args)
        let errors = getqflist()
        let compiler_target = s:get_compiler_target(&l:makeprg, compiler_args)
        let compiler_task = s:new_compiler_task(compiler, compiler_target, &l:makeprg, &l:errorformat)
        call s:initialize_compiler_task(compiler_task)
        call s:update_signs(compiler_task, errors)
        call s:save_compiler_task(compiler_task)
        call extend(s:accio_quickfix_list, errors)
    endfor
    let &l:makeprg = save_makeprg
    let &l:errorformat = save_errorformat
    call setqflist(s:accio_quickfix_list, "r")
    call s:cwindow()
    doautocmd QuickFixCmdPost make
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
    let compiler_command = join([makeprg, makeargs])
    let compiler_target = s:get_compiler_target(&l:makeprg, a:args)
    return [compiler_command, compiler_target]
endfunction


function! s:get_compiler_target(makeprg, args)
    let local_make_re = '[^\\]\%(%\|#\)'
    let is_make_local = (a:makeprg =~# local_make_re) || (a:args =~# local_make_re)
    let compiler_target = (is_make_local ? bufnr("%") : "global")
    return compiler_target
endfunction


function! s:new_compiler_task(compiler, compiler_target, compiler_command, errorformat)
    let template = {"signs": [], "errors": []}
    let compiler_task = s:get_compiler_task(a:compiler, a:compiler_target, template)
    let compiler_task.compiler = a:compiler
    let compiler_task.target = a:compiler_target
    let compiler_task.command = a:compiler_command
    let compiler_task.errorformat = a:errorformat
    let compiler_task.is_initialized = 0
    return compiler_task
endfunction


function! s:get_compiler_task(compiler, compiler_target, ...)
    if !has_key(s:compiler_tasks, a:compiler_target)
        let s:compiler_tasks[a:compiler_target] = {}
    endif
    let default = (a:0 ? a:1 : s:new_compiler_task(a:compiler, a:compiler_target, &l:makeprg, &l:errorformat))
    return get(s:compiler_tasks[a:compiler_target], a:compiler, default)
endfunction


function! s:save_compiler_task(compiler_task)
    if !has_key(s:compiler_tasks, a:compiler_task.target)
        let s:compiler_tasks[a:compiler_task.target] = {}
    endif
    let s:compiler_tasks[a:compiler_task.target][a:compiler_task.compiler] = a:compiler_task
endfunction


function! s:start_job(compiler_task)
    let job_args = [&shell, '-c', a:compiler_task.command]
    let job_opts = {'compiler_task': a:compiler_task}
    call extend(job_opts, s:job_control_callbacks)
    call jobstart(job_args, job_opts)
endfunction


function! s:get_job_name(compiler, compiler_target)
    return join([s:job_prefix, a:compiler, a:compiler_target], "_")
endfunction


function! s:process_arglist(rest)
    for args in a:rest
        call accio#accio(args)
        let s:jobs_in_progress = 0
    endfor
endfunction


function! s:job_handler(id, data, event)
    let compiler_task = self.compiler_task
    if !compiler_task.is_initialized | call s:initialize_compiler_task(compiler_task) | endif
    if !s:quickfix_cleared | call s:initialize_quickfix() | endif
    if a:event ==# "exit"
        let s:jobs_in_progress -= 1
        call s:accio_process_queue()
    else
        let errors = s:add_to_error_window(a:data, compiler_task.errorformat)
        call s:update_signs(compiler_task, errors)
    endif
    call s:cwindow()
endfunction


let s:job_control_callbacks = {
    \ 'on_stdout': function('s:job_handler'),
    \ 'on_stderr': function('s:job_handler'),
    \ 'on_exit': function('s:job_handler'),
    \ }

function! s:initialize_compiler_task(compiler_task)
    let old_signs = a:compiler_task.signs
    let a:compiler_task.signs = []
    let a:compiler_task.errors = []
    let a:compiler_task.is_initialized = 1
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


function! s:update_signs(compiler_task, errors)
    let errors = a:errors
    let signs = filter(errors, 'v:val.bufnr > 0 && v:val.lnum > 0')
    let [a:compiler_task.errors, a:compiler_task.signs] += [errors, signs]
    call s:place_signs(a:compiler_task.signs)
    call s:save_sign_messages(a:compiler_task.signs, a:compiler_task.compiler)
    call accio#echo_message()
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


function! s:cwindow()
    if g:accio_auto_copen && !empty(getqflist())
        execute printf("copen %d | %d wincmd w", len(getqflist()), winnr())
    endif
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
    let warning_lines = keys(get(s:accio_messages, bufnr, {}))
    let [prev, next] = [min(warning_lines), max(warning_lines)]
    for wl in warning_lines
        if wl < current_line
            let prev = max([prev, wl])
        elseif wl > current_line
            let next = min([next, wl])
        endif
    endfor
    let target = a:forward ? next : prev
    let jump_command = (target > 0 ? target."G" : "")
    let visual_mode = a:visual_mode ? "gv" : ""
    execute "normal!" visual_mode . jump_command
endfunction

let &cpoptions = s:save_cpo
unlet s:save_cpo
