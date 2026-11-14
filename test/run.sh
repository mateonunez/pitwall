#!/bin/sh
# Self-check on a throwaway tmux server: hook → state, the unread mark, title fallback, idempotent load, ls order.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
L="pitwall-test-$$"
T="tmux -L $L"
fail=0
trap '$T kill-server 2>/dev/null' EXIT

eq() { if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: expected '$3', got '$2'"; fail=1; fi; }

$T -f /dev/null new-session -d -s s -n one -x 120 -y 30
$T new-window -d -t s -n two
$T set -g window-status-format '#I #W' \; set -g window-status-current-format '#I #W' \; set -g status-right 'R'
$T run-shell "'$ROOT/pitwall.tmux'"
$T run-shell "'$ROOT/pitwall.tmux'" # twice: must not wrap anything twice

SOCK=$($T display -p '#{socket_path}')
P1=$($T display -p -t s:one '#{pane_id}')
P2=$($T display -p -t s:two '#{pane_id}')
hook() { echo "${3:-{\}}" | TMUX="$SOCK,0,0" TMUX_PANE="$1" "$ROOT/bin/pitwall-hook" "$2" codex; }
state() { $T display -p -t "$1" '#{E:@pitwall-state-fmt}'; }

eq "loaded once into window-status-format" "$($T show -gv window-status-format | grep -o '@pitwall-glyph' | wc -l | tr -d ' ')" 1
eq "loaded once into status-right" "$($T show -gv status-right | grep -o '@pitwall-summary' | wc -l | tr -d ' ')" 1

hook "$P2" SessionStart;      eq "SessionStart → idle" "$(state s:two)" idle
hook "$P2" PreToolUse;        eq "PreToolUse → working" "$(state s:two)" working
sleep 0.5
eq "working starts the spinner ticker" "$($T display -p '#{?#{@pitwall_tick_pid},yes,no} #{?#{@pitwall_spin},yes,no}')" "yes yes"
hook "$P2" PermissionRequest; eq "PermissionRequest → asking" "$(state s:two)" asking
sleep 1.6
eq "ticker stops once nothing works" "$($T display -p '#{?#{@pitwall_tick_pid},running,stopped}')" stopped
hook "$P2" Notification '{"notification_type":"idle_prompt"}'; eq "idle Notification keeps state" "$(state s:two)" asking
hook "$P2" PostToolUse;       eq "PostToolUse → working" "$(state s:two)" working
hook "$P2" Stop;              eq "Stop away from the lane → done" "$(state s:two)" done
eq "harness recorded" "$($T display -p -t s:two '#{@pitwall_harness}')" codex

out=$(TMUX="$SOCK,0,0" "$ROOT/bin/pitwall" ls | head -1)
case $out in "@1  s/two "*done*) eq "ls puts done first" ok ok ;; *) eq "ls puts done first" "$out" "@1  s/two … done" ;; esac
TMUX="$SOCK,0,0" "$ROOT/bin/pitwall" ls --json | python3 -I -c 'import json,sys; d=json.load(sys.stdin); assert d[0]["state"]=="done", d' &&
  eq "ls --json parses" ok ok || eq "ls --json parses" bad ok

$T select-window -t s:two; sleep 0.3
eq "visiting the lane clears done" "$(state s:two)" idle

hook "$P1" Notification '{"notification_type":"permission_prompt"}'; eq "permission Notification → asking" "$(state s:one)" asking
hook "$P1" SessionEnd;        eq "SessionEnd → gone" "$(state s:one)" gone

$T set -pu -t "$P1" @pitwall_state \; select-pane -t "$P1" -T '⠙ Working on it | dir'
eq "spinner in the title → working without hooks" "$(state s:one)" working

eq "task loses its spinner and Codex dir" "$(TMUX="$SOCK,0,0" "$ROOT/bin/pitwall" _lanes | awk -F '\t' '$4 == "one" { print $8 }')" "Working on it"

$T set -p -t "$P1" @pitwall_state asking \; set -p -t "$P2" @pitwall_state done \; select-window -t s:one
W1=$P1; W2=$P2
eq "next from an asking lane goes to the next one" "$(TMUX="$SOCK,0,0" "$ROOT/bin/pitwall" next --dry)" "$W2"
$T set -p -t "$P2" @pitwall_state working
eq "next with only this lane waiting stays put" "$(TMUX="$SOCK,0,0" "$ROOT/bin/pitwall" next --dry)" ""
$T select-window -t s:two
eq "next from elsewhere goes to the waiting lane" "$(TMUX="$SOCK,0,0" "$ROOT/bin/pitwall" next --dry)" "$W1"

eq "glyph renders for asking" "$($T set -p -t "$P2" @pitwall_state asking \; display -p -t s:two '#{E:@pitwall-glyph-plain}')" "◆ "
hook "$P2" Stop # s:two is now the active window of an unattached session: still done
eq "Stop with no client attached → done" "$(state s:two)" done

# Several agents in one window: each pane is its own lane, the window shows the most urgent.
$T select-window -t s:one
P3=$($T split-window -d -P -F '#{pane_id}' -t s:one)
hook "$P1" PreToolUse
hook "$P3" PermissionRequest
eq "two agents in one window keep their own state" "$($T display -p -t "$P1" '#{E:@pitwall-state-fmt}') $($T display -p -t "$P3" '#{E:@pitwall-state-fmt}')" "working asking"
eq "the window shows its most urgent pane" "$($T display -p -t s:one '#{E:@pitwall-window-fmt}')" asking
eq "ls lists both panes as lanes" "$(TMUX="$SOCK,0,0" "$ROOT/bin/pitwall" ls | awk '$2 ~ /^s\/one\./ { n++ } END { print n }')" 2
hook "$P3" Stop
eq "visiting a window clears every done pane in it" "$($T select-window -t s:two \; select-window -t s:one; sleep 0.3; $T display -p -t "$P3" '#{@pitwall_state}')" idle

exit $fail
