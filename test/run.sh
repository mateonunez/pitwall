#!/bin/sh
# Self-check on a throwaway tmux server: hook → state, the unread mark, title fallback, idempotent load, ls order.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
L="pitwall-test-$$"
T="tmux -L $L"
fail=0

eq() { if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: expected '$3', got '$2'"; fail=1; fi; }

# Never touch the real config or state: not from this script, not from what the test server runs in the background.
XDG_CONFIG_HOME=$(mktemp -d) XDG_STATE_HOME=$(mktemp -d)
export XDG_CONFIG_HOME XDG_STATE_HOME
ISOLATED="$XDG_CONFIG_HOME $XDG_STATE_HOME"
trap '$T kill-server 2>/dev/null; rm -rf $ISOLATED' EXIT
$T -f /dev/null new-session -d -s s -n one -x 120 -y 30
isolate() { $T set-environment -g XDG_CONFIG_HOME "$XDG_CONFIG_HOME" \; set-environment -g XDG_STATE_HOME "$XDG_STATE_HOME"; }
isolate
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
eq "tmux's help (prefix ?) lists pitwall's keys" "$($T list-keys -N | grep -c 'pitwall:')" 4
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
hook "$P2" Stop '{"background_tasks":[{"id":"a1","type":"subagent","status":"running","description":"a } ] in it"},{"id":"b1","type":"shell","status":"running"}]}'
eq "Stop with a subagent still running → still working" "$(state s:two)" working
hook "$P2" Stop '{"background_tasks":[{"id":"b1","type":"shell","status":"running","command":"pnpm dev"}]}'
eq "a background shell alone does not keep it working" "$(state s:two)" done
hook "$P2" PostToolUse
hook "$P2" Stop '{"background_tasks":[]}'; eq "Stop away from the lane → done" "$(state s:two)" done
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

$T select-pane -t "$P1" -T '[ . ] Action Required | Approve the deploy | dir'
eq "Codex's Action Required title → asking without hooks" "$(state s:one)" asking
eq "and the task keeps only its words" "$(TMUX="$SOCK,0,0" "$ROOT/bin/pitwall" _lanes | awk -F '\t' '$4 == "one" { print $8 }')" "Approve the deploy"
$T select-pane -t "$P1" -T '⠙ Working on it | dir'
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

# --- a lane asking for too long becomes urgent, with one delayed check and no polling --------------------------
$T set -g @pitwall-urgent-after 1
hook "$P2" PostToolUse
hook "$P2" PermissionRequest
i=0; while [ -z "$($T display -p -t "$P2" '#{@pitwall_urgent}')" ] && [ $i -lt 40 ]; do sleep 0.1; i=$((i + 1)); done
eq "still asking after the wait → urgent" "$($T display -p -t "$P2" '#{@pitwall_urgent}')" 1
eq "the window's ◆ turns red" "$($T display -p -t s:two '#{E:@pitwall-glyph}' | grep -c 'fg=#fb2c36 bold]◆')" 1
hook "$P2" PostToolUse
eq "moving on clears urgent" "$($T display -p -t "$P2" '#{?#{@pitwall_urgent},set,clear}')" clear
hook "$P2" PermissionRequest
hook "$P2" PostToolUse
sleep 1.6
eq "a lane that moved before the wait is not escalated" "$($T display -p -t "$P2" '#{?#{@pitwall_urgent},set,clear}')" clear
$T set -g @pitwall-urgent-after 0
$T set -g @pitwall_bell 3
eq "Needs you's count shows in the status line" "$($T display -p -t s:two '#{E:@pitwall-summary}' | grep -c '⚑ 3')" 1
$T set -gu @pitwall_bell

# --- save and restore, with a throwaway state directory ----------------------------------------------------
LANES="$XDG_STATE_HOME/pitwall/lanes"
pw() { TMUX="$SOCK,0,0" "$ROOT/bin/pitwall" "$@"; }

hook "$P2" UserPromptSubmit '{"session_id":"s-hook","transcript_path":"/tmp/t.jsonl","cwd":"/tmp"}'
eq "a new session writes its record" "$(cut -f2,3,4 "$LANES/s-hook" 2>/dev/null | tr '\t' ' ')" "s-hook /tmp s"
eq "and remembers its transcript" "$($T display -p -t "$P2" '#{@pitwall_transcript}')" /tmp/t.jsonl
hook "$P2" SessionEnd '{"session_id":"s-hook","reason":"other"}'
eq "an exit by signal keeps the record" "$([ -f "$LANES/s-hook" ] && echo kept)" kept
hook "$P2" SessionEnd '{"session_id":"s-hook","reason":"prompt_input_exit"}'
eq "a deliberate exit forgets it" "$([ -f "$LANES/s-hook" ] && echo kept || echo gone)" gone

now=$(date +%s)
server=$($T display -p '#{pid}')
printf 'claude\ts-api\t/tmp\twork\t2\tapi\t1\t1\t%s\n' "$now" >"$LANES/s-api"       # a server that died
printf 'codex\ts-api2\t/tmp\twork\t2\tapi\t2\t1\t%s\n' "$now" >"$LANES/s-api2"      # same window, second pane
printf 'claude\ts-web\t/tmp\twork\t3\tweb\t1\t%s\t%s\n' "$server" "$now" >"$LANES/s-web" # closed on this server
$T set -g @pitwall-resume-claude 'echo resumed {id}' \; set -g @pitwall-resume-codex 'echo resumed {id}' \; set -g default-shell /bin/sh

eq "restore counts the lanes of a dead server" "$(pw restore --count)" 2
pw restore >/dev/null
sleep 0.5
eq "restore rebuilds the window with both agents" "$($T display -p -t '=work:2' '#{window_name} #{window_panes}')" "api 2"
eq "each pane resumes its own session" "$($T list-panes -t '=work:2' -F '#{@pitwall_session}' | sort | tr '\n' ' ')" "s-api s-api2 "
PA=$($T list-panes -t '=work:2' -F '#{pane_id} #{@pitwall_session}' | awk '$2 == "s-api" { print $1 }')
# The resume command reaches its own pane (typed into a fresh shell, so the line itself is the evidence).
ran() { $T capture-pane -p -J -t "$PA" | grep -qE 'echo resumed s-api[[:space:]]*$' && echo yes || echo no; }
i=0; while [ "$(ran)" != yes ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
eq "the resume command reached its pane" "$(ran)" yes
[ "$(ran)" = yes ] || { echo "      pane $PA shows:"; $T capture-pane -p -J -t "$PA" | sed 's/^/      | /'; }
eq "a lane closed on purpose stays closed" "$($T list-windows -t '=work' -F '#{window_index}' | grep -c '^3$')" 0
eq "restoring twice opens nothing new" "$(pw restore --count)" 0
eq "saved tells running from closed" "$(pw saved | awk '{ print $1 }' | sort | uniq -c | awk '{ printf "%s=%s ", $2, $1 }')" "closed=1 running=2 "

# --- usage limits, from a synthetic CodexBar payload -------------------------------------------------------
quota() { printf '%s' "$1" | "$ROOT/bin/pitwall-quota" 1800000000 | tail -1; }
eq "limits read as session and week" \
  "$(quota '[{"provider":"claude","usage":{"primary":{"usedPercent":7},"secondary":{"usedPercent":34}}}]')" "claude 5h 7% · wk 34%"
eq "each window shows the time to its reset" \
  "$(quota '[{"provider":"codex","usage":{"primary":{"usedPercent":12,"resetsAt":"2027-01-15T09:30:00Z"},"secondary":{"usedPercent":91,"resetsAt":"2027-01-18T08:00:00Z"}}}]')" "codex 5h 12% ↻1h · wk 91% ↻3d"
eq "a week on course to run out turns amber" \
  "$(printf '%s' '[{"provider":"claude","usage":{"secondary":{"usedPercent":40}},"pace":{"secondary":{"willLastToReset":false}}}]' | "$ROOT/bin/pitwall-quota" 1800000000 | head -1 | grep -c '#f59e0b]40%')" 1
eq "no data, no segment" "$(quota '[]')" ""

# --- OpenTimeline signals, against an address nothing listens on --------------------------------------------
XDG_STATE_HOME=$(mktemp -d) XDG_CONFIG_HOME=$(mktemp -d)
export XDG_STATE_HOME XDG_CONFIG_HOME
ISOLATED="$ISOLATED $XDG_CONFIG_HOME $XDG_STATE_HOME"
isolate
PENDING="$XDG_STATE_HOME/pitwall/signals.jsonl"
TMUX="$SOCK,0,0" "$ROOT/bin/pitwall-signal" "$P2" working asking
eq "not connected, nothing is sent or kept" "$([ -f "$PENDING" ] && echo kept || echo none)" none
echo t >"$XDG_CONFIG_HOME/token"
pw ot connect "$XDG_CONFIG_HOME/token" --url http://127.0.0.1:9 >/dev/null
TMUX="$SOCK,0,0" "$ROOT/bin/pitwall-signal" "$P2" working asking
eq "an unreachable Timeline keeps the signal" "$(wc -l <"$PENDING" | tr -d ' ')" 1
eq "asking needs attention" "$(python3 -I -c 'import json,sys; s=json.loads(open(sys.argv[1]).readline()); print(s["kind"], s["attention"], s["subject"])' "$PENDING")" "lane.state attention lane:s/two"
$T set -p -t "$P2" @pitwall_state asking
hook "$P2" PostToolUse # leaving asking: the hook sends the change in the background
i=0; while [ "$(wc -l <"$PENDING" | tr -d ' ')" != 2 ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
eq "leaving asking is reported too, with attention none" "$(tail -1 "$PENDING" | python3 -I -c 'import json,sys; s=json.load(sys.stdin); print(s["state"], s["attention"])')" "working none"
TMUX="$SOCK,0,0" "$ROOT/bin/pitwall-signal" "$P2" 10m asking urgent
eq "an escalation is sent as urgent" "$(tail -1 "$PENDING" | python3 -I -c 'import json,sys; s=json.load(sys.stdin); print(s["state"], s["attention"], s["summary"])')" "asking urgent s/two: still asking after 10m"

# --- workspaces: a lane moves to another session and keeps running ---------------------------------------------
eq "workspaces list each session with its lanes" "$(pw ws | grep -c ' s ')" 1
$T set -p -t "$P2" @pitwall_state asking \; set -p -t "$P2" @pitwall_session s-move
mkdir -p "$XDG_STATE_HOME/pitwall/lanes"
printf 'claude\ts-move\t/tmp\ts\t2\ttwo\t0\t%s\t%s\n' "$($T display -p '#{pid}')" "$(date +%s)" >"$XDG_STATE_HOME/pitwall/lanes/s-move"
pw move two lab >/dev/null
eq "the window moved to a new workspace" "$($T display -p -t "$P2" '#{session_name}:#{window_name}')" "lab:two"
eq "the new workspace holds only the moved window" "$($T list-windows -t '=lab' | wc -l | tr -d ' ')" 1
eq "its agent kept running, with its state" "$($T display -p -t "$P2" '#{@pitwall_state}')" asking
eq "its restore record follows it" "$(cut -f4 "$XDG_STATE_HOME/pitwall/lanes/s-move")" lab
eq "another workspace that needs you shows in the status line" "$($T display -p -t s:one '#{E:@pitwall-summary}' | grep -c '◆ lab')" 1
eq "a workspace with agents is not closed by accident" "$(pw ws close lab 2>/dev/null; $T has-session -t '=lab' && echo kept)" kept
pw ws rename lab oss >/dev/null
eq "renaming a workspace keeps its records in step" "$(cut -f4 "$XDG_STATE_HOME/pitwall/lanes/s-move")" oss
pw move "oss:two" s >/dev/null
eq "and the lane can come back" "$($T display -p -t "$P2" '#{session_name}')" s
echo '{"session_id":"s-move"}' | TMUX="$SOCK,0,0" TMUX_PANE='' "$ROOT/bin/pitwall-hook" PreToolUse claude
eq "a hook without TMUX_PANE finds its pane by the session it holds" "$(state s:two)" working
echo '{"session_id":"nobody"}' | TMUX="$SOCK,0,0" TMUX_PANE='' "$ROOT/bin/pitwall-hook" Stop claude
eq "and one whose session no pane holds changes nothing" "$(state s:two)" working

# Codex runs hooks in a shared daemon whose TMUX_PANE names a pane long gone (tmux 3.7 then prints empty fields
# and exits 0). Two Codex in one directory are told apart by the thread name in their title; a lone Claude by
# its directory. Fake agents: copies of sleep named like the real processes.
FAKE=$(mktemp -d); ISOLATED="$ISOLATED $FAKE"
for a in codex 2.1.327; do cp /bin/sleep "$FAKE/$a"; command -v codesign >/dev/null && codesign -f -s - "$FAKE/$a" 2>/dev/null; done; mkdir -p "$FAKE/proj" "$FAKE/home"
printf '{"id":"cx-b","thread_name":"Fix the board"}\n' >"$FAKE/home/session_index.jsonl"
CA=$($T new-window -d -P -F '#{pane_id}' -t s: -n cxa -c "$FAKE/proj" "$FAKE/codex 300")
CB=$($T new-window -d -P -F '#{pane_id}' -t s: -n cxb -c "$FAKE/proj" "$FAKE/codex 300")
CL=$($T new-window -d -P -F '#{pane_id}' -t s: -n cl -c "$FAKE" "$FAKE/2.1.327 300")
$T select-pane -t "$CA" -T 'Ship the docs | proj' \; select-pane -t "$CB" -T 'Fix the board | proj'
sleep 0.3
daemon() { echo "{\"session_id\":\"$1\",\"cwd\":\"$2\"}" | TMUX="$SOCK,0,0" TMUX_PANE=%999 CODEX_HOME="$FAKE/home" "$ROOT/bin/pitwall-hook" "$3" "$4"; }
daemon cx-b "$FAKE/proj" PreToolUse codex
eq "a daemon's stale pane: the Codex lane is found by its thread name" "$($T display -p -t "$CB" '#{@pitwall_state}')" working
eq "and the other Codex in that directory is left alone" "$($T display -p -t "$CA" '#{@pitwall_state}')" ""
daemon cx-b "$FAKE/proj" Stop codex
eq "once found, its session leads back to it" "$($T display -p -t "$CB" '#{@pitwall_state}')" done
eq "and the record is right, not empty fields" "$(cut -f4,6 "$XDG_STATE_HOME/pitwall/lanes/cx-b")" "s	cxb"
daemon cx-z "$FAKE/proj" PreToolUse codex
eq "two Codex and no thread name to tell them apart: neither is touched" "$($T display -p -t "$CA" '#{@pitwall_state}')" ""
echo "{\"session_id\":\"cl-1\",\"cwd\":\"$FAKE\"}" | TMUX="$SOCK,0,0" TMUX_PANE='' "$ROOT/bin/pitwall-hook" UserPromptSubmit claude
eq "a Claude hook without tmux finds the one Claude in its directory" "$($T display -p -t "$CL" '#{@pitwall_state} #{@pitwall_name}')" "working $(basename "$FAKE")"
$T kill-pane -t "$CA" \; kill-pane -t "$CB" \; kill-pane -t "$CL"

# A window moving out leaves no gap (tmux renumbers only on close), even when moved by hand; records follow.
$T set -g renumber-windows on \; new-session -d -s r -n ra \; new-window -d -t r:1 -n rb \; new-window -d -t r:2 -n rc
$T set -p -t r:rc @pitwall_session s-rc \; set -p -t r:ra @pitwall_session s-ra
printf 'claude\ts-rc\t/tmp\tr\t2\trc\t0\t1\t1\n' >"$XDG_STATE_HOME/pitwall/lanes/s-rc"
printf 'claude\ts-ra\t/tmp\tr\t0\tra\t0\t1\t1\n' >"$XDG_STATE_HOME/pitwall/lanes/s-ra"
$T move-window -d -s r:ra -t '=s:'
i=0; until [ "$($T list-windows -t '=r' -F '#I' | tr '\n' ' ')" = "0 1 " ] || [ $i -ge 30 ]; do sleep 0.1; i=$((i + 1)); done
sleep 0.2
eq "moving a window out renumbers what stays" "$($T list-windows -t '=r' -F '#I:#W' | tr '\n' ' ')" "0:rb 1:rc "
eq "the records of the windows that shifted follow" "$(cut -f5 "$XDG_STATE_HOME/pitwall/lanes/s-rc")" 1
eq "and the moved window's own record, moved by hand" "$(cut -f4,5 "$XDG_STATE_HOME/pitwall/lanes/s-ra")" "s	$($T list-windows -t '=s' -F '#I #W' | awk '$2 == "ra" { print $1 }')"
$T kill-session -t r \; kill-window -t s:ra

# --- the board, driven like a person would: keys in, screen out -------------------------------------------------
# Its own server with four known lanes (alpha, beta, gamma in lab; delta in oss), the board in a pane of its own.
B="tmux -L pitwall-board-$$"
trap '$T kill-server 2>/dev/null; $B kill-server 2>/dev/null; rm -rf $ISOLATED' EXIT
$B -f /dev/null new-session -d -s lab -n alpha -x 150 -y 45
$B new-window -d -t lab -n beta \; new-window -d -t lab -n gamma \; new-session -d -s oss -n delta
$B set-environment -g XDG_CONFIG_HOME "$XDG_CONFIG_HOME" \; set-environment -g XDG_STATE_HOME "$XDG_STATE_HOME"
$B run-shell "'$ROOT/pitwall.tmux'"
lane() { $B set -p -t "$1" @pitwall_state "$2" \; set -p -t "$1" @pitwall_harness codex \; select-pane -t "$1" -T "task of ${1#*:}"; }
lane lab:alpha asking; lane lab:beta idle; lane lab:gamma working; lane oss:delta idle
BASH_BIN=bash # the board runs on the bash pitwall.tmux would pick
for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do [ -x "$b" ] && BASH_BIN=$b && break; done
$B new-session -d -s ui -x 150 -y 45 "env TERM=xterm-256color '$BASH_BIN' '$ROOT/bin/pitwall-board'"
screen() { $B capture-pane -p -t ui; }
until_screen() { # until_screen <grep pattern> [absent]: wait up to 4 s for the screen to show (or lose) it
  i=0
  while [ $i -lt 40 ]; do
    if [ "${2:-}" = absent ]; then screen | grep -q -- "$1" || return 0; else screen | grep -q -- "$1" && return 0; fi
    sleep 0.1; i=$((i + 1))
  done
  echo "FAIL  the board never showed${2:+ the absence of} '$1'"; fail=1 # a timeout is a failure, not a skipped check
  return 1
}
keys() { $B send-keys -t ui "$@"; sleep 0.3; }
esc() { $B send-keys -t ui Escape; sleep 1.2; } # on bash 3.2 a lone esc waits a second to rule out an arrow
row() { screen | grep -E "[○◆✓⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] $1 "; }

until_screen delta && eq "the board lists every lane" "$(screen | grep -cE '[○◆✓⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] (alpha|beta|gamma|delta) ')" 4
keys -l /; keys -l del
until_screen alpha absent && eq "/ filters as you type" "$(screen | grep -cE '[○◆✓⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] (alpha|delta) ')" 1
esc
until_screen alpha && eq "esc clears the filter" "$(screen | grep -cE '[○◆✓⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] (alpha|beta|gamma|delta) ')" 4

eq "the cursor stays on its lane when the filter goes" "$(row delta | grep -c '▌')" 1
keys -l d; keys -l v # first row: the most urgent lane, alpha, asking
eq "v selects the lane under the cursor" "$(row alpha | grep -c '●')" 1
lane lab:alpha idle # alpha drops below gamma: rows re-sort under the selection
sleep 1.6
eq "the selection follows the lane when rows re-sort" "$(row alpha | grep -c '●') $(row gamma | grep -c '●')" "1 0"
keys -l /; keys -l del; keys Enter
until_screen 'hidden by the filter' && eq "selected lanes the filter hides are counted" "$(screen | grep -c '1 hidden by the filter')" 1
esc
eq "esc clears the selection first" "$(screen | grep -c 'selected') $(screen | grep -cE '[○◆✓⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] (alpha|delta) ')" "0 1"
esc
until_screen alpha && eq "then the filter" "$(screen | grep -cE '[○◆✓⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] (alpha|beta|gamma|delta) ')" 4
eq "and the filter line is gone, not just its rows" "$(screen | grep -cE '^ +/ ')" 0

keys -l /; keys -l lab; keys Enter; keys -l V
eq "V selects everything shown" "$(screen | grep -c '3 selected')" 1
keys -l m; keys -l c; keys -l parked; keys Enter
sleep 0.8
eq "m moves exactly the selection" "$($B list-windows -t '=parked' -F '#W' | sort | tr '\n' ' ')" "alpha beta gamma "
eq "and leaves the rest where it was" "$($B list-windows -t '=oss' -F '#W' | tr '\n' ' ')" "delta "
eq "and the selection is cleared" "$(screen | grep -c 'selected')" 0
esc; keys -l g; keys -l g
until_screen WORKSPACES && eq "g g shows one row per workspace" "$(screen | grep -cE '^ *▌? *(oss|parked) +[0-9]+ lane')" 2
n=0; while ! screen | grep -q '▌ *oss ' && [ $n -lt 4 ]; do keys -l n; n=$((n + 1)); done
keys -l v
eq "v in the workspaces view selects that workspace's lanes" "$(screen | grep -c 'move 1 lane ')" 1
esc
keys Enter
until_screen "view state" && eq "⏎ opens a workspace, filter cleared: only its lanes" "$(screen | grep -cE '[○◆✓⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] (alpha|beta|gamma|delta) ')" 1
$B kill-server

exit $fail
