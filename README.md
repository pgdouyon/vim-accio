Accio
=====

Accio asynchronously *summons* build/compiler/linter output to your screen by
wrapping the `:compiler` and `:make` commands using both [Neovim][]'s and Vim
8's job control API.  Output from these programs is displayed in the following
ways:

- Populating the quickfix list
- Placing signs on the error lines
- Echoing the error message when the cursor is on an error line.

Note: Vim 8's job API appears to still be unstable at the time of this writing
and causes occasional seg faults.  I've increased the update interval to try
and account for it but use with caution and try not to issue too many Accio
commands in a short span of time.


Usage
-----

Accio doesn't provide any pre-configured compilers/syntax checkers, instead it
utilizes compiler plugins to run whatever build/compiler/linter programs they
specify and parse their output.  Vim ships with several compiler plugins but
writing your own is fairly straightforward (`:h write-compiler-plugin`).

To run a single compiler plugin just pass its name to Accio:

- i.e. `:Accio javac`

To run multiple compiler plugins at once and aggregate their results into one
quickfix list, pass a list of compiler names to Accio:

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
determining the classpath in a maven project with Git as the VCS and using
Fugitive to locate the project root folder:

```vim
let current_compiler = "IntelliJ"

function! s:get_classpath()
    let project_git_dir = fugitive#extract_git_dir(expand("%:p"))
    let project_root = fnamemodify(project_git_dir, ":h")
    let classpath_cmd = printf("cd %s && mvn dependency:build-classpath", shellescape(project_root))
    let classpath_pattern = 'classpath:\n\zs[^[].\{-\}\ze\n'
    let maven_output = system(classpath_cmd)
    let maven_classes = project_root . "/target/classes:"
    let classpath = maven_classes . matchstr(maven_output, classpath_pattern)
    return classpath
endfunction

if !exists("b:loaded_javac_classpath")
    let b:loaded_javac_classpath = s:get_classpath()
endif

if exists(":CompilerSet") != 2		" older Vim always used :setlocal
  command -nargs=* CompilerSet setlocal <args>
endif

let $CLASSPATH=b:loaded_javac_classpath
CompilerSet makeprg=javac\ %
CompilerSet errorformat=%E%f:%l:\ %m,%-Z%p^,%-C%.%#,%-G%.%#
```

Save this script to `$HOME/.vim/compiler/IntelliJ.vim` and it can be run
through Accio with the command `:Accio IntelliJ`.


#### Configuration and Features

- `<Plug>AccioPrevWarning` and `<Plug>AccioNextWarning`
    - Mappings to jump to the previous/next error line.
    - By default these are mapped to `[w` and `]w` (mnemonic: warning).
- `accio#statusline()`
    - Statusline function that will report the number of errors in the current
      buffer.
    - Example usage: `set statusline+=%#WarningMsg#%{accio#statusline()}%*`
- `g:accio_auto_copen`
    - Set to 1 to automatically open the quickfix list when the Accio command
      is invoked, 0 otherwise.


### Differences from [Neomake][]

Accio is borne out of my irrational hatred of pre-configured makers and it is
intended to be a lightweight alternative to Neomake.  My hope for Accio is to
feel like it gives more control/flexibility over your compilers/linters.

The other main difference between the two plugins is that Neomake uses both the
quickfix list and location list depending on which version of the command you
run.  Accio will only use the quickfix list for all possible invocations.

- I've put a lot of thought into it and come to the conclusion that the
  transience of location lists are not a good fit for asynchronous operation or
  error reporting.
- I would still entertain arguments in favor of the location list, just open up
  an issue about it.
- For anyone worried about Accio trashing their quickfix list, Accio makes an
  effort to reuse the quickfix list wherever possible.


Installation
------------

* [Pathogen][]
    * `cd ~/.vim/bundle && git clone https://github.com/pgdouyon/vim-accio.git`
* [Vim-Plug][]
    * `Plug 'pgdouyon/vim-accio'`
* Manual Install
    * Copy all the files into the appropriate directory under `~/.vim` on \*nix or
      `$HOME/vimfiles` on Windows


License
-------

Copyright (c) 2016 Pierre-Guy Douyon.  Distributed under the MIT License.


[Neovim]: https://github.com/neovim/neovim
[Neomake]: https://github.com/neomake/neomake
[Pathogen]: https://github.com/tpope/vim-pathogen
[Vim-Plug]: https://github.com/junegunn/vim-plug
