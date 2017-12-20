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
        \ 'on_stdout': function('accio#on_output'),
        \ 'on_stderr': function('accio#on_output'),
        \ 'on_exit': function('accio#on_exit')
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
        return s:job_id(job)
    endfunction

    function! s:vim_out_cb(channel, output)
        let job = ch_getjob(a:channel)
        let arglist = s:callback_arglist(job, a:output, 'stdout')
        let dict = s:callback_dict(job)
        call call('accio#on_output', arglist, dict)
    endfunction

    function! s:vim_err_cb(channel, output)
        let job = ch_getjob(a:channel)
        let arglist = s:callback_arglist(job, a:output, 'stderr')
        let dict = s:callback_dict(job)
        call call('accio#on_output', arglist, dict)
    endfunction

    function! s:vim_close_cb(channel)
        let job = ch_getjob(a:channel)
        let timer_id = timer_start(100, function('s:check_job_status'), {'repeat': -1})
        let s:timers[timer_id] = job
    endfunction

    function! s:callback_arglist(job, output, event)
        return [s:job_id(a:job), split(a:output, '\v\r?\n', 1), a:event]
    endfunction

    function! s:callback_dict(job)
        return {'compiler_task': s:compiler_tasks[s:job_id(a:job)]}
    endfunction

    let s:callbacks = {
        \ 'out_cb': function('s:vim_out_cb'),
        \ 'err_cb': function('s:vim_err_cb'),
        \ 'close_cb': function('s:vim_close_cb'),
        \ 'mode': 'raw',
        \ 'in_io': 'null',
        \ }

    function! s:vim_callback_handler(job, output, event)
        let job_id = s:job_id(a:job)
        let compiler_task = s:compiler_tasks[job_id]
        call call('accio#job_handler', [job_id, a:output, a:event], {'compiler_task': compiler_task})
    endfunction

    function! s:job_id(job)
        return job_info(a:job).process
    endfunction

    function! s:save_compiler_task(job, compiler_task)
        let job_id = s:job_id(a:job)
        let s:compiler_tasks[job_id] = a:compiler_task
    endfunction

    function! s:check_job_status(timer_id)
        let job = s:timers[a:timer_id]
        let job_status = job_status(job)
        try
            if job_status ==# 'dead'
                let arglist = [s:job_id(job), job_info(job)['exitval'], 'exit']
                let dict = s:callback_dict(job)
                call call('accio#on_exit', arglist, dict)
            endif
        finally
            if job_status !=# 'run'
                call timer_stop(a:timer_id)
                call remove(s:timers, a:timer_id)
            endif
        endtry
    endfunction

endif

let &cpoptions = s:save_cpo
unlet s:save_cpo
