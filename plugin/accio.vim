"==============================================================================
"File:        accio.vim
"Description: Neovim job-control wrapper around :compiler and :make
"Maintainer:  Pierre-Guy Douyon <pgdouyon@alum.mit.edu>
"Version:     1.0.0
"Last Change: 2014-12-30
"License:     MIT <../LICENSE>
"==============================================================================

if exists("g:loaded_accio")
    finish
endif
let g:loaded_accio = 1

let s:save_cpo = &cpoptions
set cpoptions&vim

" ----------------------------------------------------------------------
" Configuration and Defaults
" ----------------------------------------------------------------------
sign define AccioError text=>> texthl=Error
sign define AccioWarning text=>> texthl=Todo

let s:job_prefix = 'accio_'
let s:makeprg_errors = {}

function! s:accio(args)
    let [accio_prg, accio_args] = matchlist(a:args, '^\(\S*\)\s*\(.*\)')[1:2]
    execute "compiler " . accio_prg

    let makeprg = matchstr(&l:makeprg, '^\s*\zs\S*')
    let makeargs = matchstr(&l:makeprg, '^\s*\S*\s*\zs.*') . accio_args
    let makeargs = substitute(makeargs, '\\\@<!\%(%\|#\)', '\=expand(submatch(0))', 'g')
    let is_make_local = ((&l:makeprg . accio_args) =~# '[^\\]\%(%\|#\)')
    let makeprg_target = (is_make_local ? bufnr("%") : "global")

    let new_loclist = ""
    lgetexpr new_loclist
    call s:clear_makeprg_errors(makeprg, makeprg_target)

    let job_name = s:job_prefix . makeprg . "_" . makeprg_target
    execute printf("autocmd! JobActivity %s call <SID>job_handler('%s', '%s')",
        \ job_name, makeprg, makeprg_target)
    call jobstart(job_name, makeprg, split(makeargs))
endfunction


function! s:job_handler(makeprg, makeprg_target)
    if v:job_data[1] !=# "exit"
        let errors = s:add_to_loclist(v:job_data[2])
        call s:place_signs(errors)
        call extend(s:makeprg_errors[a:makeprg][a:makeprg_target], errors)
    endif
endfunction


function! s:add_to_loclist(error_lines)
    let save_errorformat = &g:errorformat
    let &g:errorformat = &l:errorformat
    laddexpr a:error_lines
    let errors = getloclist(0)
    let &g:errorformat = save_errorformat
    return errors
endfunction


function! s:place_signs(errors)
    for error in a:errors
        if (get(error, "bufnr", 0) < 1) || (get(error, "lnum", 0) < 1)
            continue
        endif
        let id = error.bufnr . error.lnum
        let sign_name = "AccioError"
        execute printf("sign place %s line=%d name=%s buffer=%d",
            \ id, error.lnum, sign_name, error.bufnr)
    endfor
endfunction


function! s:clear_makeprg_errors(makeprg, makeprg_target)
    if !has_key(s:makeprg_errors, a:makeprg)
        let s:makeprg_errors[a:makeprg] = {}
    endif
    for error in get(s:makeprg_errors[a:makeprg], a:makeprg_target, [])
        if get(error, "bufnr", 0) < 1 || get(error, "lnum", 0) < 1
            continue
        endif
        let id = error.bufnr . error.lnum
        execute "sign unplace " . id . " buffer=" . error.bufnr
    endfor
    let s:makeprg_errors[a:makeprg][a:makeprg_target] = []
endfunction


command! -nargs=+ -complete=compiler Accio call <SID>accio(<q-args>)

let &cpoptions = s:save_cpo
unlet s:save_cpo
