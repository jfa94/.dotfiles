inoremap jk <ESC>
if (&t_Co > 2 || has("gui_running")) && !exists("syntax_on")
    syntax on
endif

set term=xterm-256color

let mapleader=" "

set hidden
set noerrorbells
set tabstop=4 softtabstop=4
set shiftwidth=4
set expandtab
set smartindent
set nowrap
set relativenumber
set textwidth=120
set colorcolumn=+1
set noswapfile
set nobackup
set undodir=~/.vim/undodir
set undofile
set nohlsearch
set smartcase
set ignorecase
set incsearch
set scrolloff=5
set signcolumn=yes
set splitbelow
set splitright
set list lcs=tab:>>,nbsp:␣,trail:·,precedes:←,extends:→

let g:html_indent_tags = 'li\|p'

nnoremap <leader>f gg=G<C-o>
nnoremap <leader>h :wincmd h<CR>
nnoremap <leader>j :wincmd j<CR>
nnoremap <leader>k :wincmd k<CR>
nnoremap <leader>l :wincmd l<CR>
nnoremap <leader>r :%s/
nnoremap <leader>pv :NERDTree<CR>
nnoremap <silent> <leader>+ :vertical resize +5<CR>
nnoremap <silent> <leader>- :vertical resize -5<CR>

vnoremap J :m '>+1<CR>gv=gv
vnoremap K :m '<-2<CR>gv=gv
inoremap <C-j> <esc>:m .+1<CR>==
inoremap <C-k> <esc>:m .-2<CR>==

inoremap , ,<C-g>u
inoremap . .<C-g>u
inoremap ! !<C-g>u
inoremap ? ?<C-g>u
inoremap ;; <ESC>mT A;<ESC> `T :delmarks T<CR>i
inoremap ,, <ESC>mT A,<ESC> `T :delmarks T<CR>i
inoremap {<CR> {<CR>}<ESC>ko<Tab>
inoremap [<CR> [<CR>]<ESC>ko<Tab>
inoremap (<CR> (<CR>)<ESC>ko<Tab>
inoremap {{ <ESC>A{<CR>}<ESC>ko<Tab>

call plug#begin('~/.vim/plugged')

Plug 'doums/darcula'
Plug 'leafgarland/typescript-vim'
" Plug 'Valloric/YouCompleteMe'
Plug 'dense-analysis/ale'
Plug 'mbbill/undotree'
Plug 'tpope/vim-surround'
Plug 'mattn/emmet-vim'
Plug 'junegunn/fzf', { 'do': { -> fzf#install() } }
Plug 'junegunn/fzf.vim'
Plug 'preservim/nerdtree'

call plug#end()

if (has("termguicolors"))
    set termguicolors
endif
colorscheme darcula

let g:netrw_browse_split=2
let g:netrw_winsize = 25

"emmet-vim remap
imap <buffer> <expr> <tab> emmet#expandAbbrIntelligent("\<tab>")

nnoremap <leader>u :UndotreeShow<CR>
" nnoremap <silent> <leader>gd :YcmCompleter GoTo<CR>
" nnoremap <silent> <leader>yf :YcmCompleter FixIt<CR>
nnoremap <silent> <leader>gd :ALEGoToDefinition GoTo<CR>
nnoremap <silent> <leader>fi :ALEFix<CR>

nnoremap <leader>/ :GFiles<CR>

" Exit Vim if NERDTree is the only window remaining in the only tab.
autocmd BufEnter * if tabpagenr('$') == 1 && winnr('$') == 1 && exists('b:NERDTree') && b:NERDTree.isTabTree() | quit | endif

" Close the tab if NERDTree is the only window remaining in it.
autocmd BufEnter * if winnr('$') == 1 && exists('b:NERDTree') && b:NERDTree.isTabTree() | quit | endif

" Open the existing NERDTree on each new tab.
autocmd BufWinEnter * if getcmdwintype() == '' | silent NERDTreeMirror | endif
