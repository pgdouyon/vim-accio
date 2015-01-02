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
let s:sign_id_prefix = '954'
let s:accio_queue = []
let s:in_progress = {}
let s:accio_signs = {}
let s:accio_sign_messages = {}

function! s:accio(args)
    let [accio_prg, accio_args] = matchlist(a:args, '^\(\S*\)\s*\(.*\)')[1:2]
    execute "compiler " . accio_prg

    let makeprg = matchstr(&l:makeprg, '^\s*\zs\S*')
    let makeargs = matchstr(&l:makeprg, '^\s*\S*\s*\zs.*') . accio_args
    let makeargs = substitute(makeargs, '\\\@<!\%(%\|#\)', '\=expand(submatch(0))', 'g')
    let is_make_local = ((&l:makeprg . accio_args) =~# '[^\\]\%(%\|#\)')
    let makeprg_target = (is_make_local ? bufnr("%") : "global")

    let make_in_progress = s:is_in_progress(makeprg, makeprg_target)
    if make_in_progress
        call add(s:accio_queue, a:args)
        return
    endif
    let s:in_progress[makeprg][makeprg_target] = 1

    let new_loclist = ""
    lgetexpr new_loclist

    if !has_key(s:accio_signs, makeprg)
        let s:accio_signs[makeprg] = {}
    endif
    let signs = get(s:accio_signs[makeprg], makeprg_target, [])
    let s:accio_signs[makeprg][makeprg_target] = []
    call s:unplace_signs(signs)
    call s:clear_sign_messages(signs)

    let job_name = s:job_prefix . makeprg . "_" . makeprg_target
    execute printf("autocmd! JobActivity %s call <SID>job_handler('%s', '%s')",
        \ job_name, makeprg, makeprg_target)
    call jobstart(job_name, makeprg, split(makeargs))
endfunction


function! s:is_in_progress(makeprg, makeprg_target)
    if !has_key(s:in_progress, a:makeprg)
        let s:in_progress[a:makeprg] = {}
    endif

    if a:makeprg_target ==# "global"
        let in_progress = !empty(s:in_progress[a:makeprg])
    else
        let in_progress = get(s:in_progress[a:makeprg], a:makeprg_target, 0)
    endif
    return in_progress
endfunction


function! s:job_handler(makeprg, makeprg_target)
    if v:job_data[1] ==# "exit"
        silent! unlet s:in_progress[a:makeprg][a:makeprg_target]
    else
        let errors = s:add_to_loclist(v:job_data[2])
        let signs =  filter(errors, 'v:val.bufnr > 0 && v:val.lnum > 0')
        call s:place_signs(signs)
        call s:save_sign_messages(signs)
        call extend(s:accio_signs[a:makeprg][a:makeprg_target], signs)
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
        let id = error.bufnr . s:sign_id_prefix . error.lnum
        let sign_name = "AccioError"
        let accio_sign = {"id": id, "lnum": error.lnum, "name": sign_name, "bufnr": error.bufnr}
        let external_signs = s:get_external_signs(error.bufnr, error.lnum)

        for sgn in external_signs
            execute printf("sign unplace %d buffer=%d", sgn.id, sgn.bufnr)
        endfor
        for sgn in [accio_sign] + external_signs
            execute printf("sign place %d line=%d name=%s buffer=%d",
                \ sgn.id, sgn.lnum, sgn.name, sgn.bufnr)
        endfor
    endfor
endfunction


function! s:get_external_signs(bufnr, lnum)
    redir => signlist
    silent! execute "sign place buffer=" . a:bufnr
    redir END

    let signs = []
    for signline in split(signlist, '\n')[2:]
        let tokens = split(signline, '\s*\w*=')
        let lnum = tokens[0]
        let id = tokens[1]
        let name = tokens[2]

        if (lnum == a:lnum) && (name !~# '^Accio')
            let sgn = {"id": id, "lnum": lnum, "name": name, "bufnr": a:bufnr}
            call add(signs, sgn)
        endif
    endfor
    return signs
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


function! s:echo_accio_message()
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
    if !empty(s:accio_queue)
        let accio = s:accio_queue[0]
        call filter(s:accio_queue, 'v:val !=# '.accio)
        call s:accio(accio)
    endif
endfunction


function! accio#statusline()
    let bufnr = winbufnr(0)
    let statusline = "Errors: "
    let error_count = len(s:accio_sign_messages[bufnr])
    return statusline . error_count
endfunction


augroup accio
    autocmd!
    autocmd CursorHold,CursorHoldI * call <SID>accio_process_queue()
    autocmd CursorMoved * call <SID>echo_accio_message()
augroup END


command! -nargs=+ -complete=compiler Accio call <SID>accio(<q-args>)

let &cpoptions = s:save_cpo
unlet s:save_cpo
