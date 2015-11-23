"==============================================================================
"File:        accio.vim
"Description: Neovim job-control wrapper around :compiler and :make
"Maintainer:  Pierre-Guy Douyon <pgdouyon@alum.mit.edu>
"License:     MIT
"==============================================================================

let s:save_cpo = &cpoptions
set cpoptions&vim

let s:jobs_in_progress = 0
let s:accio_echoed_message = 0
let s:accio_queue = []
let s:accio_quickfix_list = []
let s:accio_compiler_task_ids = []
let s:compiler_tasks = {}
let s:accio_line_errors = {}
let s:errors_by_line = {}


" ======================================================================
" Public API
" ======================================================================
function! accio#accio(...) abort
    let args = get(a:000, 0, [])
    let focus = get(a:000, 1, 0)
    let tasks = type(args) == type("") ? [args] : args

    if empty(tasks)
        if exists("g:accio_focus") && !empty(g:accio_focus)
            let tasks = g:accio_focus
        else
            let inferred = get(b:, "accio", get(b:, "current_compiler", []))
            let tasks = type(inferred) == type("") ? [inferred] : inferred
        endif
    elseif focus
        let g:accio_focus = tasks
    endif

    if empty(tasks)
        echohl ErrorMsg | echo "Accio: no task specified" | echohl None
        return
    endif

    if exists("*jobstart")
        call s:accio_do_async(tasks)
    else
        call s:accio_do_sync(tasks)
    endif
endfunction


function! accio#obliviate() abort
    unlet! g:accio_focus
endfunction


function! accio#next_warning(forward, visual_mode) abort
    let current_line = line(".")
    let bufnr = bufnr("%")
    let warning_lines = map(keys(get(s:accio_line_errors, bufnr, {})), 'str2nr(v:val)')
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


function! accio#statusline(...)
    let format = get(a:000, 0, "Errors: %d")
    let no_errors = get(a:000, 1, printf(format, 0))
    let bufnr = bufnr("%")
    let error_count = len(get(s:accio_line_errors, bufnr, {}))
    return error_count ? printf(format, error_count) : no_errors
endfunction


function! accio#echo_message(...)
    let has_restriction = a:0
    let compiler_restriction = a:0 ? a:1 : ""
    let buffer_line_errors = get(s:accio_line_errors, bufnr("%"), {})
    let line_error = get(buffer_line_errors, line("."), {})
    let message = get(line_error, "text", "")
    let compiler = get(line_error, "accio_compiler", "")
    let meets_restriction = !has_restriction || (compiler ==# compiler_restriction)
    if meets_restriction
        if !empty(message)
            redraw
            echohl WarningMsg | echo message | echohl None
            let s:accio_echoed_message = 1
        elseif s:accio_echoed_message
            echo
            let s:accio_echoed_message = 0
        endif
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
    if a:event ==# "exit"
        let s:jobs_in_progress -= 1
        if !compiler_task.is_output_synced
            let compiler_task.last_update_time = s:get_current_time()
            call s:parse_quickfix_errors(compiler_task)
            call s:update_quickfix_list(compiler_task)
            call s:update_display(compiler_task)
        endif
        call s:clear_stale_compiler_errors(compiler_task)
        call s:refresh_all_signs(compiler_task)
        call s:cleanup(compiler_task)
        call s:accio_process_queue()
    else
        call s:save_compiler_output(compiler_task, a:data)
        if s:get_current_time() - compiler_task.last_update_time >= g:accio_update_interval
            let compiler_task.last_update_time = s:get_current_time()
            call s:parse_quickfix_errors(compiler_task)
            call s:update_quickfix_list(compiler_task)
            call s:update_display(compiler_task)
        endif
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
function! accio#parse_args(args)
    if empty(a:args)
        return []
    elseif a:args[0] ==# "[" && a:args[-1:] ==# "]"
        return eval(a:args)
    else
        return [a:args]
    endif
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
    let save_loclist = getloclist(0)
    let save_errorformat = &g:errorformat
    let &g:errorformat = a:compiler_task.errorformat
    call setloclist(0, [], "r")
    laddexpr a:compiler_task.output
    let a:compiler_task.qflist = getloclist(0)
    let a:compiler_task.is_output_synced = 1
    let &g:errorformat = save_errorformat
    call setloclist(0, save_loclist, "r")
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
    let old_qflist = get(s:get_compiler_task(a:compiler, a:compiler_target), "qflist", [])
    let compiler_task = {}
    let compiler_task.compiler = a:compiler
    let compiler_task.target = a:compiler_target
    let compiler_task.command = a:compiler_command
    let compiler_task.errorformat = a:errorformat
    let compiler_task.old_qflist = old_qflist
    let compiler_task.qflist = []
    let compiler_task.output = []
    let compiler_task.is_output_synced = 1
    let compiler_task.last_update_time = s:get_current_time() - (g:accio_update_interval / 2)
    return compiler_task
endfunction


function! s:get_compiler_task(compiler, compiler_target)
    if !has_key(s:compiler_tasks, a:compiler_target)
        let s:compiler_tasks[a:compiler_target] = {}
    endif
    return get(s:compiler_tasks[a:compiler_target], a:compiler, {})
endfunction


function! s:save_compiler_task(compiler_task)
    if !has_key(s:compiler_tasks, a:compiler_task.target)
        let s:compiler_tasks[a:compiler_task.target] = {}
    endif
    let s:compiler_tasks[a:compiler_task.target][a:compiler_task.compiler] = a:compiler_task
endfunction


function! s:save_compiler_output(compiler_task, compiler_output)
    let output = filter(a:compiler_output, 'v:val !~# "^\\s*$"')
    let a:compiler_task.output += output
    let a:compiler_task.is_output_synced = 0
endfunction


function! s:cleanup(compiler_task)
    " Try and reclaim some memory to avoid memory leaks
    let a:compiler_task.output = []
endfunction


" ======================================================================
" Display Functions
" ======================================================================
function! s:update_display(compiler_task)
    let compiler_errors = deepcopy(a:compiler_task.qflist)
    call s:set_accio_compiler(compiler_errors, a:compiler_task.compiler)
    call s:format_error_messages(compiler_errors, a:compiler_task.compiler)
    call s:clear_compiler_errors(compiler_errors, a:compiler_task.compiler)
    call s:update_line_errors(compiler_errors, a:compiler_task.compiler)
endfunction


function! s:set_accio_compiler(errors, compiler)
    call map(a:errors, 'extend(v:val, {"accio_compiler": a:compiler})')
endfunction


function! s:format_error_messages(errors, compiler)
    let tab_spaces = repeat(' ', &tabstop)
    let message_prefix = printf("[Accio - %s] ", a:compiler)
    for error in a:errors
        let message = get(error, "text", "No error message available...")
        let message = substitute(message, '\n', ' ', 'g')
        let message = substitute(message, '\t', tab_spaces, 'g')
        let error.text = s:truncate(message_prefix . message, &columns - 1)
    endfor
endfunction


function! s:clear_compiler_errors(errors, compiler)
    for error in a:errors
        let bufnr = error.bufnr
        let lnum = error.lnum
        if bufnr > 0 && lnum > 0
            let compiler_to_remove = a:compiler
            let errors_by_line = s:get_errors_by_line(bufnr, lnum)
            call s:remove_errors_by_compiler(errors_by_line, compiler_to_remove)
            call s:set_errors_by_line(bufnr, lnum, errors_by_line)
        endif
    endfor
endfunction


function! s:update_line_errors(errors, compiler)
    for error in a:errors
        let bufnr = error.bufnr
        let lnum = error.lnum
        if bufnr > 0 && lnum > 0
            let current_line_error = s:get_line_error(bufnr, lnum)
            let errors_by_line = uniq(sort(add(s:get_errors_by_line(bufnr, lnum), error)))
            let best_error = s:get_best_error(errors_by_line)
            call s:set_errors_by_line(bufnr, lnum, errors_by_line)
            if current_line_error !=# best_error
                call s:set_line_error(bufnr, lnum, best_error)
                call s:unplace_sign(current_line_error)
                call s:place_sign(best_error)
            endif
        endif
    endfor
endfunction


function! s:refresh_all_signs(compiler_task)
    for error in a:compiler_task.qflist
        let bufnr = error.bufnr
        let lnum = error.lnum
        if bufnr > 0 && lnum > 0
            let current_line_error = s:get_line_error(bufnr, lnum)
            call s:unplace_sign(current_line_error)
            call s:place_sign(current_line_error)
        endif
    endfor
endfunction


function! s:clear_stale_compiler_errors(compiler_task)
    let [old_qflist, qflist] = [a:compiler_task.old_qflist, a:compiler_task.qflist]
    let stale_errors = filter(old_qflist, 'index(qflist, v:val) == -1')
    call s:set_accio_compiler(stale_errors, a:compiler_task.compiler)
    call s:format_error_messages(stale_errors, a:compiler_task.compiler)
    for error in stale_errors
        let bufnr = error.bufnr
        let lnum = error.lnum
        if bufnr > 0 && lnum > 0
            call s:remove_from_errors_by_line(error)
            if s:get_line_error(bufnr, lnum) ==# error
                call s:remove_line_error(bufnr, lnum)
            endif
        endif
    endfor
    silent! unlet a:compiler_task.old_qflist
    call accio#echo_message(a:compiler_task.compiler)
endfunction


function! s:get_errors_by_line(bufnr, lnum)
    if !has_key(s:errors_by_line, a:bufnr)
        let s:errors_by_line[a:bufnr] = {}
    endif
    return get(s:errors_by_line[a:bufnr], a:lnum, [])
endfunction


function! s:set_errors_by_line(bufnr, lnum, errors_by_line)
    if !has_key(s:errors_by_line, a:bufnr)
        let s:errors_by_line[a:bufnr] = {}
    endif
    let s:errors_by_line[a:bufnr][a:lnum] = a:errors_by_line
endfunction


function! s:get_line_error(bufnr, lnum)
    if !has_key(s:accio_line_errors, a:bufnr)
        let s:accio_line_errors[a:bufnr] = {}
    endif
    return get(s:accio_line_errors[a:bufnr], a:lnum, {})
endfunction


function! s:set_line_error(bufnr, lnum, line_error)
    if !has_key(s:accio_line_errors, a:bufnr)
        let s:accio_line_errors[a:bufnr] = {}
    endif
    let s:accio_line_errors[a:bufnr][a:lnum] = a:line_error
endfunction


function! s:remove_line_error(bufnr, lnum)
    let errors_by_line = s:get_errors_by_line(a:bufnr, a:lnum)
    call s:unplace_sign(s:get_line_error(a:bufnr, a:lnum))
    silent! unlet s:accio_line_errors[a:bufnr][a:lnum]
    if !empty(errors_by_line)
        let best_error = s:get_best_error(errors_by_line)
        call s:set_line_error(a:bufnr, a:lnum, best_error)
        call s:place_sign(best_error)
    endif
endfunction


function! s:remove_from_errors_by_line(error)
    let errors_by_line = s:get_errors_by_line(a:error.bufnr, a:error.lnum)
    let errors_by_line_index = index(errors_by_line, a:error)
    if errors_by_line_index >= 0
        call remove(errors_by_line, errors_by_line_index)
        call s:set_errors_by_line(a:error.bufnr, a:error.lnum, errors_by_line)
    endif
endfunction


function! s:remove_errors_by_compiler(errors_by_line, compiler)
    call filter(a:errors_by_line, 'get(v:val, "accio_compiler") !=# a:compiler')
endfunction


function! s:get_best_error(errors)
    return sort(a:errors, function("s:sort_by_error_type"))[0]
endfunction


function! s:place_sign(error)
    let sign_type = get(a:error, "type", "E")
    let sign_name = (sign_type =~? '[EF]') ? "AccioError" : "AccioWarning"
    let sign_id = s:construct_sign_id(a:error.accio_compiler, a:error.lnum)
    execute printf("sign unplace %s buffer=%d", sign_id, a:error.bufnr)
    execute printf("sign place %s line=%d name=%s buffer=%d",
                \ sign_id, a:error.lnum, sign_name, a:error.bufnr)
endfunction


function! s:unplace_sign(error)
    if !empty(a:error)
        let sign_id = s:construct_sign_id(a:error.accio_compiler, a:error.lnum)
        execute printf("sign unplace %d buffer=%d", sign_id, a:error.bufnr)
    endif
endfunction


" ======================================================================
" Process Queue/Arglist
" ======================================================================
function! s:accio_do_async(tasks)
    let save_makeprg = &l:makeprg
    let save_errorformat = &l:errorformat
    let [compiler, compiler_args] = matchlist(a:tasks[0], '^\(\S*\)\s*\(.*\)')[1:2]
    let [compiler_command, compiler_target] = s:parse_makeprg(compiler, compiler_args)
    if s:jobs_in_progress
        call add(s:accio_queue, [a:tasks, bufnr("%")])
    else
        let s:quickfix_cleared = 0
        let s:accio_compiler_task_ids = []
        let compiler_task = s:new_compiler_task(compiler, compiler_target, compiler_command, &l:errorformat)
        call s:start_job(compiler_task)
        call s:process_arglist(a:tasks[1:])
        call s:save_compiler_task(compiler_task)
        let s:jobs_in_progress = 1 + len(a:tasks[1:])
    endif
    let &l:makeprg = save_makeprg
    let &l:errorformat = save_errorformat
endfunction


function! s:accio_do_sync(tasks)
    let save_makeprg = &l:makeprg
    let save_errorformat = &l:errorformat
    for task in a:tasks
        let [compiler, compiler_args] = matchlist(task, '^\(\S*\)\s*\(.*\)')[1:2]
        execute printf("compiler %s | silent noautocmd make! %s", compiler, compiler_args)
        redraw!
        let qflist = getqflist()
        let compiler_target = s:get_compiler_target(&l:makeprg, compiler_args)
        let compiler_task = s:new_compiler_task(compiler, compiler_target, &l:makeprg, &l:errorformat)
        let compiler_task.qflist = qflist
        call s:update_display(compiler_task)
        call s:clear_stale_compiler_errors(compiler_task)
        call s:refresh_all_signs(compiler_task)
        call s:save_compiler_task(compiler_task)
        call extend(s:accio_quickfix_list, qflist)
        silent! colder
    endfor
    let &l:makeprg = save_makeprg
    let &l:errorformat = save_errorformat
    let force_update = !empty(s:accio_quickfix_list) || g:accio_create_empty_quickfix
    call s:set_quickfix_list(s:accio_quickfix_list, force_update)
    call s:cwindow()
endfunction


function! s:process_arglist(rest)
    for task in a:rest
        call s:accio_do_async([task])
        let s:jobs_in_progress = 0
    endfor
endfunction


function! s:accio_process_queue()
    if !empty(s:accio_queue)
        call uniq(sort(s:accio_queue))
        let save_buffer = bufnr("%")
        let [tasks, target_buffer] = remove(s:accio_queue, 0)
        execute "silent! buffer " . target_buffer
        call s:accio_do_async(tasks)
        execute "buffer " save_buffer
    endif
endfunction


" ======================================================================
" Utils
" ======================================================================
function! s:get_current_time()
    let time = map(split(reltimestr(reltime()), '\.'), 'str2nr(v:val)')
    let [seconds, microseconds] = time
    let milliseconds = (seconds * 1000) + (microseconds / 1000)
    return milliseconds
endfunction


function! s:truncate(string, length)
    let nth_char = byteidx(a:string, a:length)
    let needs_truncation = (nth_char != -1)
    return needs_truncation ? strpart(a:string, 0, nth_char) : a:string
endfunction


function! s:construct_sign_id(compiler, lnum)
    let sign_id_max_length = 9
    let sign_id = a:lnum . s:hash(a:compiler)
    return s:truncate(sign_id, sign_id_max_length)
endfunction


function! s:hash(input_string)
    let chars = split(a:input_string, '\zs')
    return join(map(chars, 'float2nr(fmod(char2nr(v:val), 10))'), '')
endfunction


function! s:sort_by_error_type(error1, error2)
    let error_type1 = get(a:error1, "type", "")
    let error_type2 = get(a:error2, "type", "")
    if (error_type1 ==? error_type2)
        return get(a:error1, "col", 10000) - get(a:error2, "col", 10000)
    elseif (error_type1 ==? "E") || (error_type2 ==? "E")
        return (error_type2 ==? "E") - (error_type1 ==? "E")
    elseif (error_type1 ==? "F") || (error_type2 ==? "F")
        return (error_type2 ==? "F") - (error_type1 ==? "F")
    endif
    return get(a:error1, "col", 10000) - get(a:error2, "col", 10000)
endfunction

let &cpoptions = s:save_cpo
unlet s:save_cpo
