"==============================================================================
"File:        job.vim
"Description: Neovim job-control wrapper around :compiler and :make
"Maintainer:  Pierre-Guy Douyon <pgdouyon@alum.mit.edu>
"License:     MIT
"==============================================================================

let s:save_cpo = &cpoptions
set cpoptions&vim

if has("nvim")

    let s:callbacks = {
        \ 'on_stdout': function('accio#job_handler'),
        \ 'on_stderr': function('accio#job_handler'),
        \ 'on_exit': function('accio#job_handler')
        \ }

    function! accio#job#start(compiler_task)
        let job_command = [&shell, &shellcmdflag, a:compiler_task.command]
        let opts = extend({'compiler_task': a:compiler_task}, s:callbacks)
        return jobstart(job_command, opts)
    endfunction

else

    let s:timers = {}
    let s:compiler_tasks = {}

    function! accio#job#start(compiler_task)
        let job_command = [&shell, &shellcmdflag, a:compiler_task.command]
        let job = job_start(job_command, s:callbacks)
        call s:save_compiler_task(job, a:compiler_task)
        call s:timer_start(job)
        return s:job_id(job)
    endfunction

    function! s:vim_out_cb(channel, message)
        let data = split(a:message, '\n')
        call s:vim_callback_handler(ch_getjob(a:channel), data, 'stdout')
    endfunction

    function! s:vim_err_cb(channel, message)
        let data = split(a:message, '\n')
        call s:vim_callback_handler(ch_getjob(a:channel), data, 'stderr')
    endfunction

    function! s:vim_exit_cb(job, exit_status)
        call s:vim_callback_handler(a:job, a:exit_status, 'exit')
    endfunction

    let s:callbacks = {
        \ 'out_cb': function('s:vim_out_cb'),
        \ 'err_cb': function('s:vim_err_cb'),
        \ 'exit_cb': function('s:vim_exit_cb'),
        \ 'in_io': 'null',
        \ }

    function! s:vim_callback_handler(job, message, event)
        let job_id = s:job_id(a:job)
        let compiler_task = s:compiler_tasks[job_id]
        call call('accio#job_handler', [job_id, a:message, a:event], {'compiler_task': compiler_task})
    endfunction

    function! s:job_id(job)
        return job_info(a:job).process
    endfunction

    function! s:save_compiler_task(job, compiler_task)
        let job_id = s:job_id(a:job)
        let s:compiler_tasks[job_id] = a:compiler_task
    endfunction

    function! s:timer_start(job)
        let timer_id = timer_start(g:accio_update_interval, function('s:check_job_status'), {'repeat': -1})
        let s:timers[timer_id] = a:job
    endfunction

    function! s:check_job_status(timer_id)
        if job_status(s:timers[a:timer_id]) !=# 'run'
            call timer_stop(a:timer_id)
            call remove(s:timers, a:timer_id)
        endif
    endfunction

endif

let &cpoptions = s:save_cpo
unlet s:save_cpo
