"==============================================================================
"File:        accio.vim
"Description: Neovim job-control wrapper around :compiler and :make
"Maintainer:  Pierre-Guy Douyon <pgdouyon@alum.mit.edu>
"License:     MIT
"==============================================================================

if exists("g:loaded_accio")
    finish
endif
let g:loaded_accio = 1

let s:save_cpo = &cpoptions
set cpoptions&vim

let g:accio_auto_copen = get(g:, "accio_auto_copen", 0)
let g:accio_create_empty_quickfix = get(g:, "accio_create_empty_quickfix", 1)
let g:accio_update_interval = get(g:, "accio_update_interval", 500)

sign define AccioError text=>> texthl=AccioErrorSign
sign define AccioWarning text=>> texthl=AccioWarningSign

highlight default link AccioErrorSign ErrorMsg
highlight default link AccioWarningSign WarningMsg

nnoremap <silent> <Plug>AccioPrevWarning :<C-U>call accio#next_warning(0, 0)<CR>
xnoremap <silent> <Plug>AccioPrevWarning :<C-U>call accio#next_warning(0, 1)<CR>
onoremap <silent> <Plug>AccioPrevWarning :<C-U>call accio#next_warning(0, 0)<CR>

nnoremap <silent> <Plug>AccioNextWarning :<C-U>call accio#next_warning(1, 0)<CR>
xnoremap <silent> <Plug>AccioNextWarning :<C-U>call accio#next_warning(1, 1)<CR>
onoremap <silent> <Plug>AccioNextWarning :<C-U>call accio#next_warning(1, 0)<CR>

if !hasmapto("<Plug>AccioPrevWarning") && !hasmapto("<Plug>AccioNextWarning")
    map [w <Plug>AccioPrevWarning
    map ]w <Plug>AccioNextWarning
    sunmap [w
    sunmap ]w
endif

augroup accio
    autocmd!
    autocmd CursorMoved * call accio#echo_message()
augroup END

command! -bar -nargs=+ -complete=compiler Accio call accio#accio(accio#parse_args(<q-args>))

let &cpoptions = s:save_cpo
unlet s:save_cpo
