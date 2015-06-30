"==============================================================================
"File:        accio.vim
"Description: Neovim job-control wrapper around :compiler and :make
"Maintainer:  Pierre-Guy Douyon <pgdouyon@alum.mit.edu>
"License:     MIT
"==============================================================================

let s:save_cpo = &cpoptions
set cpoptions&vim

let s:accio_sign_id = '954'
let s:jobs_in_progress = 0
let s:accio_echoed_message = 0
let s:accio_queue = []
let s:accio_quickfix_list = []
let s:accio_compiler_task_ids = []
let s:compiler_tasks = {}
let s:accio_messages = {}


" ======================================================================
" Public API
" ======================================================================
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
        let s:accio_compiler_task_ids = []
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
    call s:set_quickfix_list([])
    for arg in s:parse_accio_args(a:args)
        let [compiler, compiler_args] = matchlist(arg, '^\(\S*\)\s*\(.*\)')[1:2]
        execute printf("silent! colder | compiler %s | silent noautocmd make! %s | redraw!", compiler, compiler_args)
        let qflist = getqflist()
        let compiler_target = s:get_compiler_target(&l:makeprg, compiler_args)
        let compiler_task = s:new_compiler_task(compiler, compiler_target, &l:makeprg, &l:errorformat)
        call s:clear_display(compiler_task)
        let compiler_task.qflist = qflist
        call s:update_display(compiler_task)
        call s:save_compiler_task(compiler_task)
        call extend(s:accio_quickfix_list, qflist)
    endfor
    let &l:makeprg = save_makeprg
    let &l:errorformat = save_errorformat
    call setqflist(s:accio_quickfix_list, "r")
    call s:cwindow()
endfunction


function! accio#next_warning(forward, visual_mode) abort
    let current_line = line(".")
    let bufnr = bufnr("%")
    let warning_lines = map(keys(get(s:accio_messages, bufnr, {})), 'str2nr(v:val)')
    let sorted_lines = uniq(sort(add(warning_lines, current_line), 'n'))
    let current_index = index(sorted_lines, current_line)
    if a:forward
        let target_index = min([current_index + v:count1, len(sorted_lines) - 1])
    else
        let target_index = max([current_index - v:count1, 0])
    endif
    let target = sorted_lines[target_index]
    let jump_command = (target == current_line ? "" : target."G")
    let visual_mode = a:visual_mode ? "gv" : ""
    execute "silent! normal!" visual_mode . jump_command
endfunction


function! accio#statusline()
    let bufnr = bufnr("%")
    let statusline = "Errors: "
    let error_count = len(get(s:accio_messages, bufnr, {}))
    return statusline . error_count
endfunction


function! accio#echo_message()
    let buffer_messages = get(s:accio_messages, bufnr("%"), {})
    let message = get(buffer_messages, line("."), "")
    if !empty(message)
        echohl WarningMsg | echo message | echohl None
        let s:accio_echoed_message = 1
    elseif s:accio_echoed_message
        echo
        let s:accio_echoed_message = 0
    endif
endfunction


" ======================================================================
" Job Control API
" ======================================================================
function! s:start_job(compiler_task)
    let job_args = [&shell, '-c', a:compiler_task.command]
    let job_opts = {'compiler_task': a:compiler_task}
    call extend(job_opts, s:job_control_callbacks)
    call jobstart(job_args, job_opts)
endfunction


function! s:job_handler(id, data, event)
    let compiler_task = self.compiler_task
    if !compiler_task.is_display_cleared | call s:clear_display(compiler_task) | endif
    if a:event ==# "exit"
        let s:jobs_in_progress -= 1
        call s:accio_process_queue()
    else
        call s:save_compiler_output(compiler_task, a:data)
        call s:parse_quickfix_errors(compiler_task)
        call s:update_quickfix_list(compiler_task)
        call s:update_display(compiler_task)
    endif
    call s:cwindow()
endfunction


let s:job_control_callbacks = {
    \ 'on_stdout': function('s:job_handler'),
    \ 'on_stderr': function('s:job_handler'),
    \ 'on_exit': function('s:job_handler'),
    \ }


" ======================================================================
" Parsing Functions
" ======================================================================
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


" ======================================================================
" Quickfix List
" ======================================================================
function! s:set_quickfix_list(qflist, ...)
    let force_update = a:0 ? a:1 : 1
    if s:is_accio_quickfix_list() || force_update
        let action = s:is_accio_quickfix_list() ? "r" : " "
        let s:accio_quickfix_list = a:qflist
        let s:quickfix_cleared = 1
        call setqflist(s:accio_quickfix_list, action)
    endif
endfunction


function! s:parse_quickfix_errors(compiler_task)
    let save_quickfix_list = getqflist()
    let save_errorformat = &g:errorformat
    let &g:errorformat = a:compiler_task.errorformat
    let partial_output = a:compiler_task.partial_nontruncated_output + a:compiler_task.truncated_output
    call setqflist([], "r")
    caddexpr partial_output
    let partial_qflist = getqflist()
    let previous_last_complete_error_index = index(partial_qflist, a:compiler_task.previous_last_complete_error)
    let previous_truncated_error_index = (previous_last_complete_error_index != -1) ? previous_last_complete_error_index + 1 : -1
    let truncated_error_index = len(partial_qflist) - 1
    if truncated_error_index >= previous_truncated_error_index + 2
        let a:compiler_task.previous_last_complete_error = partial_qflist[-2]
        let a:compiler_task.partial_nontruncated_output = a:compiler_task.truncated_output
        let a:compiler_task.truncated_output = []
    endif
    if len(a:compiler_task.qflist) <= 1
        let a:compiler_task.qflist = partial_qflist
    else
        let last_complete_error = remove(a:compiler_task.qflist, -2, -1)[0]
        let last_complete_error_index = index(partial_qflist, last_complete_error)
        call extend(a:compiler_task.qflist, partial_qflist[last_complete_error_index : ])
    endif
    let &g:errorformat = save_errorformat
    call setqflist(save_quickfix_list, "r")
endfunction


function! s:update_quickfix_list(compiler_task)
    let quickfix_list = []
    let compiler_task_id = [a:compiler_task.compiler, a:compiler_task.target]
    call uniq(sort(add(s:accio_compiler_task_ids, compiler_task_id)))
    for [compiler, target] in s:accio_compiler_task_ids
        let compiler_task = s:get_compiler_task(compiler, target)
        let quickfix_list += compiler_task.qflist
    endfor
    let force_update = (s:quickfix_cleared || !empty(quickfix_list) || g:accio_create_empty_quickfix)
    call s:set_quickfix_list(quickfix_list, force_update)
endfunction


function! s:is_accio_quickfix_list()
    return (getqflist() ==# s:accio_quickfix_list)
endfunction


function! s:cwindow()
    if g:accio_auto_copen && s:is_accio_quickfix_list()
        if empty(getqflist()) && s:jobs_in_progress == 0
            cclose
        else
            let height = min([len(getqflist()), 10])
            execute printf("copen %d | %d wincmd w", height, winnr())
        endif
    endif
endfunction


" ======================================================================
" Compiler Task API
" ======================================================================
function! s:new_compiler_task(compiler, compiler_target, compiler_command, errorformat)
    let template = {"signs": [], "qflist": []}
    let compiler_task = s:get_compiler_task(a:compiler, a:compiler_target, template)
    let compiler_task.compiler = a:compiler
    let compiler_task.target = a:compiler_target
    let compiler_task.command = a:compiler_command
    let compiler_task.errorformat = a:errorformat
    let compiler_task.truncated_output = []
    let compiler_task.partial_nontruncated_output = []
    let compiler_task.previous_last_complete_error = {}
    let compiler_task.is_display_cleared = 0
    return compiler_task
endfunction


function! s:get_compiler_task(compiler, compiler_target, ...)
    if !has_key(s:compiler_tasks, a:compiler_target)
        let s:compiler_tasks[a:compiler_target] = {}
    endif
    let default = (a:0 ? a:1 : {})
    return get(s:compiler_tasks[a:compiler_target], a:compiler, default)
endfunction


function! s:save_compiler_task(compiler_task)
    if !has_key(s:compiler_tasks, a:compiler_task.target)
        let s:compiler_tasks[a:compiler_task.target] = {}
    endif
    let s:compiler_tasks[a:compiler_task.target][a:compiler_task.compiler] = a:compiler_task
endfunction


function! s:save_compiler_output(compiler_task, compiler_output)
    let output = filter(a:compiler_output, 'v:val !~# "^\\s*$"')
    let a:compiler_task.truncated_output += output
endfunction


" ======================================================================
" Display Functions
" ======================================================================
function! s:clear_display(compiler_task)
    let old_signs = a:compiler_task.signs
    let a:compiler_task.signs = []
    let a:compiler_task.qflist = []
    let a:compiler_task.is_display_cleared = 1
    call s:unplace_signs(old_signs)
    call s:clear_sign_messages(old_signs)
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


function! s:update_display(compiler_task)
    let signs = filter(copy(a:compiler_task.qflist), 'v:val.bufnr > 0 && v:val.lnum > 0')
    let a:compiler_task.signs = signs
    call s:place_signs(a:compiler_task.signs)
    call s:save_sign_messages(a:compiler_task.signs, a:compiler_task.compiler)
    call accio#echo_message()
endfunction


function! s:place_signs(errors)
    for error in a:errors
        let id = error.bufnr . s:accio_sign_id . error.lnum
        let sign_type = get(error, "type", "E")
        let sign_name = (sign_type =~? '^[EF]') ? "AccioError" : "AccioWarning"
        execute printf("sign place %d line=%d name=%s buffer=%d",
                    \ id, error.lnum, sign_name, error.bufnr)
    endfor
endfunction


function! s:save_sign_messages(signs, compiler)
    let tab_spaces = repeat(' ', &tabstop)
    let message_prefix = printf("[Accio - %s] ", a:compiler)
    for sign in a:signs
        if !has_key(s:accio_messages, sign.bufnr)
            let s:accio_messages[sign.bufnr] = {}
        endif
        let msg = get(sign, "text", "No error message available...")
        let msg = substitute(msg, '\n', ' ', 'g')
        let msg = substitute(msg, '\t', tab_spaces, 'g')
        let msg = strpart(message_prefix . msg, 0, &columns - 1)
        let s:accio_messages[sign.bufnr][sign.lnum] = msg
    endfor
endfunction


" ======================================================================
" Process Queue/Arglist
" ======================================================================
function! s:process_arglist(rest)
    for args in a:rest
        call accio#accio(args)
        let s:jobs_in_progress = 0
    endfor
endfunction


function! s:accio_process_queue()
    if !empty(s:accio_queue)
        call uniq(sort(s:accio_queue))
        let save_buffer = bufnr("%")
        let [accio_args, target_buffer] = remove(s:accio_queue, 0)
        execute "silent! buffer " . target_buffer
        call accio#accio(accio_args)
        execute "buffer " save_buffer
    endif
endfunction

let &cpoptions = s:save_cpo
unlet s:save_cpo
