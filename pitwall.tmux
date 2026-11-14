#!/usr/bin/env sh
# pitwall: TPM entry. Wires the lane formats, keys and tmux hooks into the running server.
# Safe to run again: every change is idempotent. Nothing here starts a process per redraw.

DIR=$(cd "$(dirname "$0")" && pwd)

opt() { v=$(tmux show -gqv "$1"); printf %s "${v:-$2}"; }

ASK=$(opt @pitwall-color-asking '#f59e0b')
DONE=$(opt @pitwall-color-done '#00c758')
GONE=$(opt @pitwall-color-gone '#fb2c36')
KEY_BOARD=$(opt @pitwall-key-board 'A')
KEY_NEXT=$(opt @pitwall-key-next 'a')
KEY_RESTORE=$(opt @pitwall-key-restore 'R')

AGENT='^(codex|claude|[0-9.]+)$' # Claude Code shows up as its version, e.g. 2.1.323

# A lane is a pane running an agent; a window can hold several. A pane's state: the hook's word when there is
# one, else read from the pane title: Codex writes "[ ! ] Action Required" while it waits for you and prefixes a braille
# spinner while it works; Claude prefixes a star glyph, ✳ at rest.
tmux set -g @pitwall-state-fmt "#{?#{@pitwall_state},#{@pitwall_state},#{?#{m:*Action Required*,#{pane_title}},asking,#{?#{m/r:^[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏⣾⣽⣻⢿⡿⣟⣯⣷],#{pane_title}},working,#{?#{m/r:$AGENT,#{pane_current_command}},#{?#{m/r:^[✶✻✽✢·*],#{pane_title}},working,idle},}}}}"

S='#{E:@pitwall-state-fmt}'
# A window shows its most urgent pane: asking, then done, working, idle, gone.
tmux set -g @pitwall-window-fmt "#{?#{m:*asking*,#{P:$S }},asking,#{?#{m:*done*,#{P:$S }},done,#{?#{m:*working*,#{P:$S }},working,#{?#{m:*idle*,#{P:$S }},idle,#{?#{m:*gone*,#{P:$S }},gone,}}}}}"
W='#{E:@pitwall-window-fmt}'
glyph() { # $1 asking style, $2 done style, $3 gone style
  printf '%s' "#{?#{==:$W,asking},$1◆ ,#{?#{==:$W,done},$2✓ ,#{?#{==:$W,working},#{?#{@pitwall_spin},#{@pitwall_spin},⠙} ,#{?#{==:$W,idle},○ ,#{?#{==:$W,gone},$3✗ ,}}}}}"
}
# The colour also carries to the window name that follows; the current window keeps its own style.
tmux set -g @pitwall-glyph "$(glyph "#[fg=$ASK bold]" "#[fg=$DONE bold]" "#[fg=$GONE]")"
tmux set -g @pitwall-glyph-plain "$(glyph '' '' '')"
# Right side: lanes that need you, lanes waiting to be restored after a crash, then the usage limits.
tmux set -g @pitwall-summary "#{W:#{P:#{?#{==:$S,asking},#[fg=$ASK bold]◆ ,}#{?#{==:$S,done},#[fg=$DONE bold]✓ ,}}}#[nobold]#{?#{&&:#{@pitwall_restorable},#{!=:#{@pitwall_restorable},0}},#[fg=$ASK]↺ #{@pitwall_restorable}  ,}#{?#{@pitwall_quota},#{@pitwall_quota}  ,}"

# Put the glyph before the window name in whatever format the theme already has.
inject() { # $1 option, $2 glyph option
  f=$(tmux show -gv "$1")
  case $f in *@pitwall-*) return ;; esac
  case $f in
    *'#W'*) f=$(printf '%s' "$f" | sed "s/#W/#{E:$2}#W/") ;;
    *) f="#{E:$2}$f" ;;
  esac
  tmux set -g "$1" "$f"
}
inject window-status-format @pitwall-glyph
inject window-status-current-format @pitwall-glyph-plain

r=$(tmux show -gv status-right)
case $r in *@pitwall-summary*) ;; *) tmux set -g status-right "#{E:@pitwall-summary}#[default]$r" ;; esac

# Agent windows are named after the agent's directory instead of the process (2.1.323 → dotfiles).
# The hook records it (@pitwall_name): the pane's current path follows every command the agent runs.
if [ "$(opt @pitwall-rename on)" = on ]; then
  a=$(tmux show -gv automatic-rename-format)
  case $a in *'@pitwall_name'*) ;; *) tmux set -g automatic-rename-format "#{?#{@pitwall_name},#{@pitwall_name},#{?#{&&:#{m/r:$AGENT,#{pane_current_command}},#{pane_start_path}},#{b:pane_start_path},$a}}" ;; esac
fi

# The unread mark: visiting a window turns its panes that finished while you were away from done into idle.
CLEAR="if -F '#{m:*done*,#{P:#{@pitwall_state} }}' \"run-shell -b \\\"'$DIR/bin/pitwall' seen '#{window_id}'\\\"\""
tmux set-hook -g 'session-window-changed[73]' "$CLEAR"
tmux set-hook -g 'client-session-changed[73]' "$CLEAR"
tmux set-hook -g 'client-attached[73]' "$CLEAR"

# Board and jump. Not choose-tree: its j/k are compiled into tmux, and navigation here is Colemak (n/e).
# The board wants a bash that reads with sub-second timeouts; the macOS /bin/bash 3.2 only manages whole seconds.
BASH_BIN=bash
for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do [ -x "$b" ] && BASH_BIN=$b && break; done
tmux bind "$KEY_BOARD" display-popup -E -w 84% -h 78% -b rounded -S "fg=#404040" "'$BASH_BIN' '$DIR/bin/pitwall-board'"
tmux bind "$KEY_NEXT" run-shell "'$DIR/bin/pitwall' next"
tmux bind "$KEY_RESTORE" display-popup -E -w 70% -h 50% -b rounded -S "fg=#404040" "'$DIR/bin/pitwall' _restore-prompt"

# Lanes may already be working when the plugin loads (or a client attaches): start the spinner.
tmux set-hook -g 'client-attached[74]' "run-shell -b \"'$DIR/bin/pitwall-tick'\""
tmux run-shell -b "'$DIR/bin/pitwall-tick'"

# After a crash, say how many lanes can come back (↺ N, prefix R). Refresh the usage limits in the background.
tmux run-shell -b "tmux set -g @pitwall_restorable \"\$('$DIR/bin/pitwall' restore --count)\""
[ "$(opt @pitwall-quota on)" = on ] && tmux run-shell -b "'$DIR/bin/pitwall' quota --refresh"
