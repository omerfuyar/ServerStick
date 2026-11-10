# Interactive shells switch to fish (the desktop's shell). Non-interactive 'ssh host <cmd>'
# never reads this file, so scripts still get zsh. Set NOFISH=1 to stay in zsh.
if [[ -o interactive && -z "$NOFISH" && -x /usr/bin/fish ]]; then
    exec /usr/bin/fish
fi
