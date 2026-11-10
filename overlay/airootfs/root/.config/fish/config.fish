# Based on the desktop's fish setup (cachyos-fish-config + ~/.config/fish/config.fish).
# Root's login shell stays zsh so 'ssh host <cmd>' runs POSIX syntax; ~/.zshrc execs fish
# for interactive sessions, and tmux starts fish directly.

# The Linux console (tty1) has no Nerd Font: no icons, no fancy prompt there.
set -l on_console 0
test "$TERM" = linux; and set on_console 1

# fastfetch greeting, except on the local console where the status banner was just printed.
function fish_greeting
    test "$TERM" = linux; and return
    command -q fastfetch; and fastfetch
end

set -gx EDITOR micro
set -gx VISUAL micro
set -gx MANROFFOPT "-c"
command -q bat; and set -gx MANPAGER "sh -c 'col -bx | bat -l man -p'"
fish_add_path ~/.local/bin

## Functions (from cachyos-fish-config)
# !! and !$ like bash
function __history_previous_command
    switch (commandline -t)
        case "!"
            commandline -t $history[1]; commandline -f repaint
        case "*"
            commandline -i !
    end
end

function __history_previous_command_arguments
    switch (commandline -t)
        case "!"
            commandline -t ""
            commandline -f history-token-search-backward
        case "*"
            commandline -i '$'
    end
end

bind ! __history_previous_command
bind '$' __history_previous_command_arguments

function history
    builtin history --show-time='%F %T ' $argv
end

function backup --argument filename
    cp $filename $filename.bak
end

## Aliases (from cachyos-fish-config)
alias tarnow='tar -acf '
alias untar='tar -zxvf '
alias wget='wget -c '
alias psmem='ps auxf | sort -nr -k 4'
alias psmem10='ps auxf | sort -nr -k 4 | head -10'
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias .....='cd ../../../..'
alias grep='grep --color=auto'
alias jctl="journalctl -p 3 -xb"
alias tb='nc termbin.com 9999'

if status is-interactive
    # bat needs its theme cache built once before the custom 'noctalia' theme works.
    if command -q bat; and not test -e ~/.cache/bat/themes.bin
        bat cache --build >/dev/null 2>&1
    end

    test $on_console = 0; and command -q starship; and starship init fish | source
    command -q zoxide; and zoxide init fish --cmd cd | source

    if command -q eza
        set -l icons --icons=auto
        test $on_console = 1; and set icons --icons=never
        alias ls "eza -lh --group-directories-first $icons"
        alias lsa 'ls -a'
        alias la "eza -a --group-directories-first $icons"
        alias ll "eza -l --group-directories-first $icons"
        alias lt "eza --tree --level=2 --long $icons --git"
        alias lta 'lt -a'
    end
    command -q fzf; and command -q bat; and alias ff "fzf --preview 'bat --style=numbers --color=always {}'"
end
