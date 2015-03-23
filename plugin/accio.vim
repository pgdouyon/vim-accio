"==============================================================================
"File:        accio.vim
"Description: Neovim job-control wrapper around :compiler and :make
"Maintainer:  Pierre-Guy Douyon <pgdouyon@alum.mit.edu>
"Version:     1.0.0
"Last Change: 2015-03-20
"License:     MIT
"==============================================================================

if exists("g:loaded_accio") || !has("nvim")
    finish
endif
let g:loaded_accio = 1

let s:save_cpo = &cpoptions
set cpoptions&vim

sign define AccioError text=>> texthl=Error
sign define AccioWarning text=>> texthl=IncSearch

nnoremap <silent> <Plug>AccioPrevWarning :<C-U>call accio#next_warning(0, 0)<CR>
xnoremap <silent> <Plug>AccioPrevWarning :<C-U>call accio#next_warning(0, 1)<CR>
onoremap <silent> <Plug>AccioPrevWarning :<C-U>call accio#next_warning(0, 0)<CR>

nnoremap <silent> <Plug>AccioNextWarning :<C-U>call accio#next_warning(1, 0)<CR>
xnoremap <silent> <Plug>AccioNextWarning :<C-U>call accio#next_warning(1, 1)<CR>
onoremap <silent> <Plug>AccioNextWarning :<C-U>call accio#next_warning(1, 0)<CR>

if !hasmapto("<Plug>AccioPrevWarning") && !hasmapto("<Plug>AccioNextWarning")
    map [w <Plug>AccioPrevWarning
    map ]w <Plug>AccioNextWarning
endif

augroup accio
    autocmd!
    autocmd CursorMoved * call accio#echo_message()
augroup END

command! -nargs=+ -complete=compiler Accio call accio#accio(<q-args>)

let &cpoptions = s:save_cpo
unlet s:save_cpo
