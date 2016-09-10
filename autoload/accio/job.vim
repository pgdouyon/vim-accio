"==============================================================================
"File:        job.vim
"Description: Neovim job-control wrapper around :compiler and :make
"Maintainer:  Pierre-Guy Douyon <pgdouyon@alum.mit.edu>
"License:     MIT
"==============================================================================

let s:save_cpo = &cpoptions
set cpoptions&vim

function! accio#job#start(compiler_task, callback)
    let job_command = [&shell, '-c', a:compiler_task.command]
    let opts = { 'compiler_task': a:compiler_task, 'on_stdout': a:callback,
                \ 'on_stderr': a:callback, 'on_exit': a:callback }
    return jobstart(job_command, opts)
endfunction

let &cpoptions = s:save_cpo
unlet s:save_cpo
