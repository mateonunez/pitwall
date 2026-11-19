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
KEY_WORKSPACES=$(opt @pitwall-key-workspaces 'W')

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
# A lane asking for longer than @pitwall-urgent-after turns its window's ◆ red. (Built in single quotes: the shell
# would brace-expand this format inside a nested substitution.)
ASKING='#{?#{m:*1*,#{P:#{@pitwall_urgent} }},#[fg='"$GONE"' bold],#[fg='"$ASK"' bold]}'
tmux set -g @pitwall-glyph "$(glyph "$ASKING" "#[fg=$DONE bold]" "#[fg=$GONE]")"
tmux set -g @pitwall-glyph-plain "$(glyph '' '' '')"
# Right side: other workspaces with a lane that needs you, this workspace's lanes that do, lanes waiting to be
# restored after a crash, Needs you's count, then the usage limits.
OTHERS="#{S:#{?#{!=:#{session_name},#{client_session}},#{?#{m:*asking*,#{W:#{P:$S }}},#[fg=$ASK bold]◆ #{session_name}#[nobold]  ,#{?#{m:*done*,#{W:#{P:$S }}},#[fg=$DONE]✓ #{session_name}  ,}},}}"
tmux set -g @pitwall-summary "$OTHERS#{W:#{P:#{?#{==:$S,asking},#[fg=$ASK bold]◆ ,}#{?#{==:$S,done},#[fg=$DONE bold]✓ ,}}}#[nobold]#{?#{&&:#{@pitwall_restorable},#{!=:#{@pitwall_restorable},0}},#[fg=$ASK]↺ #{@pitwall_restorable}  ,}#{?#{&&:#{@pitwall_bell},#{!=:#{@pitwall_bell},0}},#[fg=$ASK bold]⚑ #{@pitwall_bell}#[nobold]  ,}#{?#{@pitwall_quota},#{@pitwall_quota}  ,}"

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

# --- tabs layout (@pitwall-layout tabs) ---------------------------------------------------------------------
# Top: the status line, moved up, as Chrome-style tab groups: each workspace a pill, the one you are in open with
# its windows as tabs. Bottom: tmux keeps every status line together, so the bottom bar is the border of the panes
# that touch the bottom: usage limits on the left, the machine and the clock on the right (bin/pitwall-sys).
# Formats live in options; status-format[0] and pane-border-format only point at them, so switching back can
# tell what pitwall set and undo exactly that.
if [ "$(opt @pitwall-layout inline)" = tabs ]; then
  STRIP=$(opt @pitwall-color-strip '#111111') TABBG=$(opt @pitwall-color-tab '#2a2a2a') PILL=$(opt @pitwall-color-pill '#1f1f1f')
  MUTED='#9ca3af' DIM='#6b7280' TEXT='#f3f4f6' DARK='#0a0a0a' SEP='#4b5563'
  if [ "$(opt @pitwall-tab-caps on)" = on ]; then L='' R=''; else L=' ' R=' '; fi # Nerd Font half circles
  count() { printf '%s' "#{n:#{W:#{P:#{?#{==:$S,$1},x,}}}}"; }
  A=$(count asking) D=$(count done)
  # Room per tab: what the pills leave, shared by the windows, between 6 and 24 cells.
  X='#{e|-:#{e|/:#{e|-:#{client_width},#{e|*:#{server_sessions},13}},#{session_windows}},7}'
  tmux set -g @pitwall-tab-width "#{?#{e|<:$X,6},6,#{?#{e|>:$X,24},24,$X}}"
  NAME='#{=/#{E:@pitwall-tab-width}/…:window_name}'
  # The open workspace's tabs share an amber underline, as a Chrome tab group shares its colour; the current tab is
  # lifted off the strip, with its number in amber. Numbers are there for prefix 1-9.
  TAB_OFF="#[range=window|#{window_index}]#[fg=$DIM bg=$STRIP underscore us=$ASK] #{window_index} #{E:@pitwall-glyph}#[fg=$MUTED nobold]$NAME #[norange]"
  TAB_ON="#[range=window|#{window_index}]#[fg=$TABBG bg=$STRIP nounderscore]$L#[fg=$ASK bg=$TABBG bold underscore us=$ASK]#{window_index} #[fg=$DIM nobold]#{E:@pitwall-glyph}#[fg=$TEXT bold]$NAME#[fg=$TABBG bg=$STRIP nobold nounderscore]$R#[norange]"
  HERE="#[range=session|#{session_id}]#[fg=$ASK bg=$STRIP]$L#[fg=$DARK bg=$ASK bold]#{session_name}#[fg=$ASK bg=$STRIP nobold]$R#[norange]#{W:$TAB_OFF,$TAB_ON}#[nounderscore bg=$STRIP]   "
  AWAY="#[range=session|#{session_id}]#[fg=$PILL bg=$STRIP]$L#[fg=$DIM bg=$PILL]#{session_name}#{?$A, #[fg=$ASK bold]◆$A#[nobold],}#{?$D, #[fg=$DONE bold]✓$D#[nobold],}#[fg=$PILL bg=$STRIP]$R#[norange]  "
  RIGHT="#{?client_prefix,#[fg=$ASK bold]prefix#[nobold]  ,}#{?#{&&:#{@pitwall_restorable},#{!=:#{@pitwall_restorable},0}},#[fg=$ASK]↺ #{@pitwall_restorable}  ,}#{?#{&&:#{@pitwall_bell},#{!=:#{@pitwall_bell},0}},#[fg=$ASK bold]⚑ #{@pitwall_bell}#[nobold]  ,}"
  tmux set -g @pitwall-tabs-fmt "#[fill=$STRIP bg=$STRIP]#[align=left] #{S:#{?#{==:#{session_name},#{client_session}},$HERE,$AWAY}}#[align=right bg=$STRIP]$RIGHT"
  # The right side gives way as the pane narrows: everything, then cpu, memory and disk, then the clock alone.
  ROOM='#{e|-:#{pane_width},#{?pane_at_left,60,0}}'
  FULL="#{?#{@pitwall_system},#{@pitwall_system}#[fg=$SEP] · ,}#[fg=$TEXT]#{@pitwall_clock} #[default]"
  SHORT="#{?#{@pitwall_system_short},#{@pitwall_system_short}#[fg=$SEP] · ,}#[fg=$TEXT]#{=5:@pitwall_clock} #[default]"
  CLOCK="#[fg=$TEXT]#{=5:@pitwall_clock} #[default]"
  tmux set -g @pitwall-rule-fmt "#{?pane_at_bottom,#{?pane_at_left,#[fg=$MUTED] #{?#{@pitwall_quota},#{@pitwall_quota} ,}#[default],}#[align=right]#{?pane_at_right, #{?#{e|>=:$ROOM,92},$FULL,#{?#{e|>=:$ROOM,48},$SHORT,$CLOCK}},},}"
  # Remember what the theme had, once, to give it back if the layout is switched off.
  [ -n "$(tmux show -gqv @pitwall_prev_position)" ] || tmux set -g @pitwall_prev_position "$(tmux show -gv status-position)" \; set -g @pitwall_prev_border "$(tmux show -gwv pane-border-status)"
  tmux set -g 'status-format[0]' '#{E:@pitwall-tabs-fmt}' \; set -g status-position top \
    \; setw -g pane-border-status bottom \; setw -g pane-border-format '#{E:@pitwall-rule-fmt}'
  tmux set -g @pitwall_clock "$(date '+%H:%M %d %b')"
  tmux set-hook -g 'client-attached[76]' "run-shell -b \"'$DIR/bin/pitwall-sys'\""
  tmux set -gu @pitwall_sys_pid \; run-shell -b "'$DIR/bin/pitwall-sys'" # a running one hands over at its next tick
elif [ "$(tmux show -gv 'status-format[0]')" = '#{E:@pitwall-tabs-fmt}' ]; then
  tmux set -gu status-format \; set -g status-position "$(opt @pitwall_prev_position bottom)" \
    \; setw -g pane-border-status "$(opt @pitwall_prev_border off)" \; setw -gu pane-border-format \
    \; set -gu @pitwall_prev_position \; set -gu @pitwall_prev_border \; set-hook -gu 'client-attached[76]'
fi

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

# With renumber-windows on, a window moving out of a session closes its gap too, not only one that closes
# (prefix . , the board's m, pitwall move). Deferred: while the hook runs, the window is still linked.
tmux set-hook -g 'window-unlinked[75]' "if -F '#{renumber-windows}' \"run-shell -b \\\"'$DIR/bin/pitwall' _reindex '#{hook_session_name}' '#{hook_window}'\\\"\""
[ "$(tmux show -gv renumber-windows)" = on ] && tmux run-shell -b "'$DIR/bin/pitwall' _reindex"

# Board and jump. Not choose-tree: its j/k are compiled into tmux, and navigation here is Colemak (n/e).
# The board wants a bash that reads with sub-second timeouts; the macOS /bin/bash 3.2 only manages whole seconds.
BASH_BIN=bash
for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do [ -x "$b" ] && BASH_BIN=$b && break; done
# Every key carries a note (-N), so tmux's own help (prefix ?) lists pitwall's keys too.
tmux bind -N "pitwall: the board (/ filter, w workspace, v select, m move, ? keys)" "$KEY_BOARD" display-popup -E -w 84% -h 78% -b rounded -S "fg=#404040" "'$BASH_BIN' '$DIR/bin/pitwall-board'"
tmux bind -N "pitwall: next lane that needs you (again to cycle)" "$KEY_NEXT" run-shell "'$DIR/bin/pitwall' next"
tmux bind -N "pitwall: workspaces (go, c new, r rename)" "$KEY_WORKSPACES" display-popup -E -w 60% -h 50% -b rounded -S "fg=#404040" "'$BASH_BIN' '$DIR/bin/pitwall-ws'"
tmux bind -N "pitwall: restore the lanes a dead tmux took with it" "$KEY_RESTORE" display-popup -E -w 70% -h 50% -b rounded -S "fg=#404040" "'$DIR/bin/pitwall' _restore-prompt"

# Lanes may already be working when the plugin loads (or a client attaches): start the spinner.
tmux set-hook -g 'client-attached[74]' "run-shell -b \"'$DIR/bin/pitwall-tick'\""
tmux run-shell -b "'$DIR/bin/pitwall-tick'"

# After a crash, say how many lanes can come back (↺ N, prefix R). Refresh the usage limits in the background.
tmux run-shell -b "tmux set -g @pitwall_restorable \"\$('$DIR/bin/pitwall' restore --count)\""
[ "$(opt @pitwall-quota on)" = on ] && tmux run-shell -b "'$DIR/bin/pitwall' quota --refresh"
true # the plugin loaded; a switched-off feature above is not a failure
