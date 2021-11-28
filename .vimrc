inoremap jk <ESC>
if (&t_Co > 2 || has("gui_running")) && !exists("syntax_on")
    syntax on
endif

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
nnoremap <leader>pv :wincmd v<bar> :wincmd R<bar> :Ex<bar> :vertical resize 30<CR>
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

call plug#begin('~/.vim/plugged')

Plug 'doums/darcula'
Plug 'morhetz/gruvbox'
Plug 'leafgarland/typescript-vim'
Plug 'Valloric/YouCompleteMe'
Plug 'mbbill/undotree'
Plug 'tpope/vim-surround'
Plug 'mattn/emmet-vim'

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
nnoremap <silent> <leader>gd :YcmCompleter GoTo<CR>
nnoremap <silent> <leader>yf :YcmCompleter FixIt<CR>
