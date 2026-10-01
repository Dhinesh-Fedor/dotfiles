# ~/.bashrc
# This login shell configuration is small; foot opens Fish by default.

[[ $- != *i* ]] && return

alias ls='ls --color=auto'
alias grep='grep --color=auto'

PS1='[\u@\h \W]\$ '
export PATH="$PATH:$HOME/go/bin"
