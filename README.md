Accio
=====

Accio asynchronously *summons* build/compiler/linter output to your screen by
wrapping the `:compiler` and `:make` commands with [Neovim][]'s job control
API.  Output from these programs is displayed in the following ways:

1. The quickfix list
2. Placing signs on the error lines
3. Echoing the error message when the cursor is on an error line.

Note: Accio also provides a synchronous version of its API for Vim.


Usage
-----

Accio doesn't provide any pre-configured compilers/syntax checkers, instead it
utilizes compiler plugins to run whatever build/compiler/linter programs they
specify and parse their output.  Vim ships with several compiler plugins but
writing your own is fairly straightforward (`:h write-compiler-plugin`).

To run a single compiler plugin just pass its name to Accio:

- `:Accio <compiler>`
- i.e. `:Accio javac`

To run multiple compiler plugins at once and aggregrate their results into one
quickfix list, pass a list of compiler names to Accio:

- `:Accio ["<compiler1>", "<compiler2>"]`
- i.e. `:Accio ["javac", "checkstyle"]`
- Note: the compiler names must be quoted, otherwise Vim will attempt to
  resolve them as variable names and throw an error

Adding support for a new compiler is as simple as writing a compiler plugin for
it and storing it under `$HOME/.vim/compiler/` or `$HOME/vimfiles/compiler` for
Windows.

Accio is not limited to compiler plugins designed to analyze a single file.  It
can run any compiler plugin, even ones that kick off a project build script.
Accio should be able to handle it and load the results into the quickfix list
asynchronously.


#### Javac Example

Vim ships with a javac compiler, but it provides no way to specify the
classpath javac should use, instead it relies on the `$CLASSPATH` environment
variable being set up correctly.  Unfortunately, this scheme doesn't work well
if you're working on multiple Java projects where each project has its own
classpath.

One solution is to use a compiler plugin to help determine the classpath for
each individual buffer.  Below is an example javac compiler plugin for
determining the classpath in a maven project:

```vim
let current_compiler = "IntelliJ"

function! s:get_classpath()
    let project_home_pattern = '\V' . escape($PROJECT_HOME, '\') . '/\[^/]\*/'
    let project_home = matchstr(expand("%:p"), project_home_pattern)
    let classpath_cmd = printf("cd %s && mvn dependency:build-classpath", shellescape(project_home))
    let classpath_pattern = 'classpath:\n\zs[^[].\{-\}\ze\n'
    let maven_output = system(classpath_cmd)
    let classpath = project_home . "/target/classes:" . matchstr(maven_output, classpath_pattern)
    return classpath
endfunction

if !exists("b:loaded_javac_classpath")
    let b:loaded_javac_classpath = s:get_classpath()
endif

if exists(":CompilerSet") != 2		" older Vim always used :setlocal
  command -nargs=* CompilerSet setlocal <args>
endif

let $CLASSPATH=b:loaded_javac_classpath
CompilerSet makeprg=javac\ -d\ $PROJECTS_HOME/trash\ %
CompilerSet errorformat=%E%f:%l:\ %m,%-Z%p^,%-C%.%#,%-G%.%#
```

Save this script to `$HOME/.vim/compiler/IntelliJ.vim` and it can be run
through Accio with the command `:Accio IntelliJ`.


#### Configuration and Features

- Accio provides mappings to jump to the next/previous error line.  By default
  these are mapped to `[w` and `]w` (mnemonic: warning) but can be remapped
  using the `<Plug>` mappings.
    - `<Plug>AccioPrevWarning`
    - `<Plug>AccioNextWarning`
- Accio provides a statusline function that will report the number of errors in
  the current buffer.
    - `set statusline+=%#WarningMsg#%{accio#statusline()}%*`
- By default, Accio does not open the quickfix list when invoked.  You can
  change this via the `g:accio_auto_copen` variable:
    - `let g:accio_auto_copen = 1`



### Differences from [Neomake][]

- Neomake ships with pre-configured makers and also allows you to specify your
  own makers.
    - I personally don't like the idea of pre-configured checkers (and I think
      I'm in the minority here) and have found compiler plugins to be much more
      flexible and easier to use.
    - This is pretty much the principal difference between Neomake and Accio
      and the reason I made this plugin in the first place.
- Neomake does support compiler plugins, but you still have to run the
  `:compiler` command separately.  Accio bundles the `:compiler` and `:make`
  commands into one.
- Neomake uses both the quickfix list and location list depending on which
  version of the command you run.  Accio only uses the quickfix list.
    - I've put a lot of thought into it and come to the conclusion that the
      transience of location lists are not a good fit for asynchronous
      operation or error reporting.
    - If anyone ever ends up actually using this plugin I would still entertain
      arguments in favor of the location list, just open up an issue about it.
    - For anyone worried about Accio trashing their quickfix list, Accio tries
      to reuse the quickfix list (rather than constantly creating a new one),
      to avoid filling up all of the saved quickfix lists with Accio lists.
- Neomake is essentially a superset of Accio.  My plan for Accio is to be a
  lightweight alternative to Neomake that hopefully feels like it gives more
  control over your compilers/linters.


Installation
------------

* [Pathogen][]
    * `cd ~/.vim/bundle && git clone https://github.com/pgdouyon/vim-accio.git`
* [Vundle][]
    * `Plugin 'pgdouyon/vim-accio'`
* [NeoBundle][]
    * `NeoBundle 'pgdouyon/vim-accio'`
* [Vim-Plug][]
    * `Plug 'pgdouyon/vim-accio'`
* Manual Install
    * Copy all the files into the appropriate directory under `~/.vim` on \*nix or
      `$HOME/vimfiles` on Windows


License
-------

Copyright (c) 2015 Pierre-Guy Douyon.  Distributed under the MIT License.


[Neovim]: https://github.com/neovim/neovim
[Neomake]: https://github.com/benekastah/neomake
[Pathogen]: https://github.com/tpope/vim-pathogen
[Vundle]: https://github.com/gmarik/Vundle.vim
[NeoBundle]: https://github.com/Shougo/neobundle.vim
[Vim-Plug]: https://github.com/junegunn/vim-plug
