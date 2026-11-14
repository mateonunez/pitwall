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
ran() { $T capture-pane -p -t "$PA" | grep -cE '^resumed s-api[[:space:]]*$'; }
i=0; while [ "$(ran)" != 1 ] && [ $i -lt 150 ]; do sleep 0.1; i=$((i + 1)); done
eq "the resume command ran in its pane" "$(ran)" 1
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

exit $fail
