#!/bin/sh
tmux list-sessions -F '#{?session_attached,,#{session_name}}' | \
    sed '/^$/d' | \
    fzf --reverse --header ' Sessions' --prompt ' > ' \
        --no-scrollbar --no-info --no-separator \
        --border none --margin 0 --padding 0 \
        --pointer '>' \
        --color='bg:#fffcf0,fg:#100f0f,hl:#4385be,fg+:#100f0f,bg+:#e6e4d9,hl+:#4385be,prompt:#879a39,pointer:#4385be,header:#878580' | \
    xargs tmux switch-client -t
