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
set textwidth=80
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

let g:html_indent_tags = 'li\|p'

nnoremap <leader>r gg=G<C-o>
nnoremap <leader>h :wincmd h<CR>
nnoremap <leader>j :wincmd j<CR>
nnoremap <leader>k :wincmd k<CR>
nnoremap <leader>l :wincmd l<CR>
nnoremap <leader>pv :wincmd v<bar> :Ex<bar> :vertical resize 30<CR>
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

call plug#begin('~/.vim/plugged')

Plug 'doums/darcula'
Plug 'morhetz/gruvbox'
Plug 'leafgarland/typescript-vim'
Plug 'tabnine/YouCompleteMe.git'
Plug 'mbbill/undotree'
Plug 'tpope/vim-surround'

call plug#end()

if (has("termguicolors"))
    set termguicolors
endif
"colorscheme darcula

let g:netrw_browse_split=2
let g:netrw_winsize = 25

nnoremap <leader>u :UndotreeShow
nnoremap <silent> <leader>gd :YcmCompleter GoTo<CR>
nnoremap <silent> <leader>yf :YcmCompleter FixIt<CR>
