#!/bin/sh
# Self-check on a throwaway tmux server: hook → state, the unread mark, title fallback, idempotent load, ls order.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
L="pitwall-test-$$"
T="tmux -L $L"
fail=0

eq() { if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: expected '$3', got '$2'"; fail=1; fi; }

# Never touch the real config or state: not from this script, not from what the test server runs in the background.
XDG_CONFIG_HOME=$(mktemp -d) XDG_STATE_HOME=$(mktemp -d) XDG_DATA_HOME=$(mktemp -d) # data: the installed plugins
export XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME XDG_CACHE_HOME="$XDG_DATA_HOME/cache"
export PITWALL_FEATURE_USAGE=on
ISOLATED="$XDG_CONFIG_HOME $XDG_STATE_HOME $XDG_DATA_HOME"
trap '$T kill-server 2>/dev/null; rm -rf $ISOLATED' EXIT
$T -f /dev/null new-session -d -s s -n one -x 120 -y 30
isolate() { $T set-environment -g XDG_CONFIG_HOME "$XDG_CONFIG_HOME" \; set-environment -g XDG_STATE_HOME "$XDG_STATE_HOME" \; set-environment -g XDG_DATA_HOME "$XDG_DATA_HOME"; }
isolate
$T new-window -d -t s -n two
$T set -g window-status-format '#I #W' \; set -g window-status-current-format '#I #W' \; set -g status-right 'R'
SOCK=$($T display -p '#{socket_path}')
unloaded_output=$(TMUX="$SOCK,0,0" "$ROOT/bin/pitwall" ls --workspace s --json 2>"$XDG_STATE_HOME/unloaded")
eq "a workspace on an unloaded server reports failure without JSON" "$? $unloaded_output" '1 '
eq "an unloaded server explains how to load Pitwall" "$(cat "$XDG_STATE_HOME/unloaded")" 'pitwall: not loaded in this tmux server (run pitwall.tmux)'
close_status=0
TMUX="$SOCK,0,0" "$ROOT/bin/pitwall" ws close s >/dev/null 2>&1 || close_status=$?
eq "workspace close refuses when it cannot inspect the lanes" "$close_status $($T has-session -t '=s' && echo kept)" "1 kept"
$T run-shell "'$ROOT/pitwall.tmux'"
$T run-shell "'$ROOT/pitwall.tmux'" # twice: must not wrap anything twice

P1=$($T display -p -t s:one '#{pane_id}')
P2=$($T display -p -t s:two '#{pane_id}')
hook() { echo "${3:-{\}}" | TMUX="$SOCK,0,0" TMUX_PANE="$1" "$ROOT/bin/pitwall-hook" "$2" "${4:-codex}"; }
state() { $T display -p -t "$1" '#{E:@pitwall-state-fmt}'; }

eq "loaded once into window-status-format" "$($T show -gv window-status-format | grep -o '@pitwall-glyph' | wc -l | tr -d ' ')" 1
eq "tmux's help (prefix ?) lists pitwall's keys: the dashboard, the jump, restore" "$($T list-keys -N | grep -c 'pitwall:')" 3
eq "loaded once into status-right" "$($T show -gv status-right | grep -o '@pitwall-summary' | wc -l | tr -d ' ')" 1

if [ "$($T display -p '#{version}')" = 3.7c ]; then
  # Capture the attached client from outside: capture-pane inside the popup cannot see its frame.
  observer="tmux -L pitwall-observer-$$"
  $T new-session -d -s scrolling 'while :; do echo background-output; sleep 0.03; done'
  $T set -t scrolling status-position top
  $observer -f /dev/null new-session -d -x 100 -y 32 "unset TMUX; exec $T attach -t scrolling"
  for _ in $(seq 1 50); do $T list-clients -t scrolling | grep -q . && break; sleep 0.1; done
  $observer send-keys C-b Space
  for _ in $(seq 1 50); do $observer capture-pane -p | grep -q '│  pitwall' && break; sleep 0.1; done
  stable=yes
  for _ in $(seq 1 15); do
    $observer capture-pane -p | grep -B1 '│  pitwall' | head -1 | grep -q '╭─*╮' || stable=no
    sleep 0.08
  done
  eq "the popup's upper frame survives scrolling behind it with a top status line" "$stable" yes
  $observer kill-server
  $T kill-session -t scrolling
fi

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

REC=$($T new-window -d -P -F '#{pane_id}' -t s: -n recovery)
recover() {
  printf '%s\n' "$2" | TMUX="$SOCK,0,0" TMUX_PANE="$REC" "$ROOT/bin/pitwall-hook" "$1" claude
}
recover UserPromptSubmit '{"session_id":"recover-old"}'
recover Stop '{"session_id":"recover-old","background_tasks":[{"type":"monitor","status":"running"}]}'
eq "Stop with a passive monitor clears the tab spinner" "$(state "$REC") $($T display -p -t "$REC" '#{E:@pitwall-glyph-plain}')" "done ✓ "
recover UserPromptSubmit '{"session_id":"recover-old"}'
recover Stop '{"session_id":"recover-old", "background_tasks": [ {"type":"subagent","status":"running"} ]}'
eq "a running subagent keeps its tab working with formatted JSON" "$(state "$REC")" working
recover UserPromptSubmit '{"session_id":"recover-old"}'
recover Notification '{"session_id":"other-session","notification_type":"idle_prompt"}'
eq "another session cannot clear the spinner" "$(state "$REC")" working
recover Notification '{"session_id":"recover-old","notification_type":"idle_prompt"}'
eq "confirmed idle recovers a stuck working tab" "$(state "$REC") $($T display -p -t "$REC" '#{E:@pitwall-glyph-plain}')" "done ✓ "
recover PermissionRequest '{"session_id":"recover-old"}'
recover Notification '{"session_id":"recover-old","notification_type":"idle_prompt"}'
eq "an idle notification leaves a pending permission alone" "$(state "$REC")" asking
recover SessionEnd '{"session_id":"recover-old","reason":"prompt_input_exit"}'
$T kill-pane -t "$REC"

hook "$P2" PostToolUse
hook "$P2" Stop '{"background_tasks":[]}'; eq "Stop away from the lane → done" "$(state s:two)" done
eq "harness recorded" "$($T display -p -t s:two '#{@pitwall_harness}')" codex

out=$(TMUX="$SOCK,0,0" "$ROOT/bin/pitwall" ls | head -1)
case $out in "@1  s/two "*done*) eq "ls puts done first" ok ok ;; *) eq "ls puts done first" "$out" "@1  s/two … done" ;; esac
TMUX="$SOCK,0,0" "$ROOT/bin/pitwall" ls --json | python3 -I -c 'import json,sys; d=json.load(sys.stdin); assert d[0]["state"]=="done", d' &&
  eq "ls --json parses" ok ok || eq "ls --json parses" bad ok

$T select-window -t s:two; sleep 0.3
eq "visiting the lane clears done" "$(state s:two)" idle
# tmux shows a background command's non-zero exit in the pane: seen and the quota refresh must exit 0 on no-ops.
eq "seen on a window with nothing done exits 0" "$(TMUX="$SOCK,0,0" "$ROOT/bin/pitwall" seen s:one >/dev/null; echo $?)" 0
$T set -g @pitwall-codexbar /usr/bin/true
eq "a quota refresh with nothing to show exits 0" "$(TMUX="$SOCK,0,0" "$ROOT/bin/pitwall" quota --refresh >/dev/null 2>&1; echo $?)" 0
$T set -gu @pitwall-codexbar

hook "$P1" Notification '{"notification_type":"permission_prompt"}'; eq "permission Notification → asking" "$(state s:one)" asking
QP=$($T new-window -d -P -F '#{pane_id}' -t s: -n qa "printf '\\n  \$ pnpm release --tag v1\\n\\n  Allow command?  › 1. Yes   2. Yes, always   3. No\\n'; exec sleep 300"); sleep 0.3
hook "$QP" PermissionRequest; sleep 1.2
eq "a lane that asks keeps its question and its answers" "$($T display -p -t "$QP" '#{@pitwall_question}|#{@pitwall_choices}')" "Allow pnpm release --tag v1?|1 Yes · 2 Yes, always · 3 No"
pw() { TMUX="$SOCK,0,0" "$ROOT/bin/pitwall" "$@"; }
QR=$(pw ls | awk '$2 ~ /\/qa$/ { print $1 }')
eq "the hook keeps today's ledger, and stats --today reads it" "$(pw stats --today --plain | awk -F '\t' -v p="$QP" '$1 == p { print ($4 >= 0 ? "ok" : "bad") }')" ok
eq "ls --json carries an asking lane's question and choices, for agents" "$(pw ls --json | python3 -I -c 'import json,sys; l=[x for x in json.load(sys.stdin) if x["window"]=="qa"][0]; print(l["question"], "|", l["choices"])')" "Allow pnpm release --tag v1? | 1 Yes · 2 Yes, always · 3 No"
if command -v nvim >/dev/null; then # the Neovim side reads the same lanes: an asking one shows in its status
  NV=$(TMUX="$SOCK,0,0" PATH="$ROOT/bin:$PATH" nvim --headless --clean --cmd "set rtp^=$ROOT" -c "lua local p = require('pitwall'); p.setup(); vim.wait(3000, function() return p.status() ~= '' end); io.write(p.status() .. ' ' .. vim.fn.exists(':Pitwall'))" -c qa 2>&1 | tail -1)
  eq "in Neovim, :Pitwall exists and the status counts the lanes that ask" "$(printf '%s' "$NV" | grep -c '◆[0-9].* 2')" 1
fi
pw answer "$QR" 1 >/dev/null; sleep 0.3
eq "answer sends one key to a lane that asks" "$($T capture-pane -p -t "$QP" | grep -v '^ *$' | tail -1)" 1
WR=$(pw ls | awk '$2 ~ /\/two$/ { print $1 }')
eq "and refuses a lane that does not ask" "$(pw answer "$WR" 1 2>&1 | grep -c 'is not asking')" 1
hook "$QP" PostToolUse
eq "and drops them once it moves on" "$($T display -p -t "$QP" '#{@pitwall_question}')" ""
$T kill-pane -t "$QP"
hook "$P1" SessionEnd; sleep 2.6; eq "SessionEnd, the pane back at its shell → gone" "$(state s:one)" gone

$T set -pu -t "$P1" @pitwall_state \; select-pane -t "$P1" -T '⠙ Working on it | dir'
eq "spinner in the title → working without hooks" "$(state s:one)" working

$T select-pane -t "$P1" -T '[ . ] Action Required | Approve the deploy | dir'
eq "Codex's Action Required title → asking without hooks" "$(state s:one)" asking
eq "and the task keeps only its words" "$(TMUX="$SOCK,0,0" "$ROOT/bin/pitwall" _lanes | awk -F '\t' '$4 == "one" { print $8 }')" "Approve the deploy"
$T select-pane -t "$P1" -T 'hermes chat'
eq "Hermes, titled hermes, is a lane without hooks too" "$(state s:one)" idle
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

# --- save and restore, with a throwaway state directory ----------------------------------------------------
LANES="$XDG_STATE_HOME/pitwall/lanes"
pw() { TMUX="$SOCK,0,0" "$ROOT/bin/pitwall" "$@"; }

hook "$P2" UserPromptSubmit '{"session_id":"s-hook","transcript_path":"/tmp/t.jsonl","cwd":"/tmp"}' claude
eq "a new session writes its record" "$(cut -f2,3,4 "$LANES/s-hook" 2>/dev/null | tr '\t' ' ')" "s-hook /tmp s"
eq "and remembers its transcript" "$($T display -p -t "$P2" '#{@pitwall_transcript}')" /tmp/t.jsonl
hook "$P2" SessionEnd '{"session_id":"s-hook","reason":"other"}' claude
eq "an exit by signal keeps the record" "$([ -f "$LANES/s-hook" ] && echo kept)" kept
hook "$P2" SessionEnd '{"session_id":"s-hook","reason":"prompt_input_exit"}' claude
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
eq "single restore cannot reopen a lane closed on this server" "$(pw restore --one s-web 2>&1)" "pitwall: this lane is no longer recoverable"
printf 'grok\ts-grok\t/tmp\tgone\t1\tg\t1\t1\t%s\n' "$now" >"$LANES/s-grok"
printf 'mystery\ts-myst\t/tmp\tgone\t1\tg\t2\t1\t%s\n' "$now" >"$LANES/s-myst"
eq "restore knows how grok resumes" "$(pw restore --dry | grep -c '(grok)')" 1
eq "an agent it does not know waits for @pitwall-resume-<agent>" "$(pw restore --dry | grep -c 'unknown agent mystery')$($T set -g @pitwall-resume-mystery 'mystery --again {id}'; pw restore --dry | grep -c '(mystery)')" 11
rm -f "$LANES/s-grok" "$LANES/s-myst"

if ! python3 "$ROOT/test/panels.py"; then fail=1; fi

# Feature use is independent of lanes and reports both time windows and unobserved features.
FEATURE_TEST=$(mktemp -d); ISOLATED="$ISOLATED $FEATURE_TEST"
feature_test() { XDG_STATE_HOME="$FEATURE_TEST" "$ROOT/bin/pitwall" "$@"; }
eq "a fresh feature report includes unused actions" "$(feature_test features | awk '$1 == "handoff-stage" { print $2, $3, $4 }')" "0 0 0"
(
  XDG_STATE_HOME=$FEATURE_TEST
  . "$ROOT/lib/pitwall-features.sh"
  feature_use inbox
  today=$(($(date -u +%s) / 86400))
  for age in 6 7 29 30; do printf 'inbox\n' >"$FEATURE_DIR/$((today - age)).log"; done
  PITWALL_FEATURE_USAGE=off feature_use inbox
  feature_use 'unexpected private text'
)
eq "feature time windows use UTC calendar days and opt-out stops new events" \
  "$(feature_test features | awk '$1 == "inbox" { print $2, $3, $4 }')" "2 4 5"
eq "feature logs only store the known action IDs" \
  "$(sort -u "$FEATURE_TEST/pitwall/features/"*.log)" inbox
printf '%s\n' 'not a feature' >>"$FEATURE_TEST/pitwall/features/$(($(date -u +%s) / 86400)).log"
eq "the report ignores malformed feature records" "$(feature_test features | grep -c 'not a feature')" 0

# --- usage limits, from a synthetic CodexBar payload -------------------------------------------------------
quota() { printf '%s' "$1" | "$ROOT/bin/pitwall-quota" 1800000000 | sed -n 2p; }
eq "limits read as session and week" \
  "$(quota '[{"provider":"claude","usage":{"primary":{"usedPercent":7},"secondary":{"usedPercent":34}}}]')" "claude 5h 7% · wk 34%"
eq "each window shows the time to its reset" \
  "$(quota '[{"provider":"codex","usage":{"primary":{"usedPercent":12,"resetsAt":"2027-01-15T09:30:00Z"},"secondary":{"usedPercent":91,"resetsAt":"2027-01-18T08:00:00Z"}}}]')" "codex 5h 12% ↻1h · wk 91% ↻3d"
eq "a week on course to run out turns amber" \
  "$(printf '%s' '[{"provider":"claude","usage":{"secondary":{"usedPercent":40}},"pace":{"secondary":{"willLastToReset":false}}}]' | "$ROOT/bin/pitwall-quota" 1800000000 | head -1 | grep -c '#f59e0b]40%')" 1
eq "no data, no segment" "$(quota '[]')" ""
eq "a reset in the past is due, without a new countdown" \
  "$(quota '[{"provider":"codex","usage":{"primary":{"usedPercent":42,"resetsAt":"2027-01-15T07:59:59Z"}}}]')" "codex 5h 42% ↻due"

# --- OpenTimeline signals, against an address nothing listens on --------------------------------------------
XDG_STATE_HOME=$(mktemp -d) XDG_CONFIG_HOME=$(mktemp -d)
export XDG_STATE_HOME XDG_CONFIG_HOME
ISOLATED="$ISOLATED $XDG_CONFIG_HOME $XDG_STATE_HOME"
isolate
PENDING="$XDG_STATE_HOME/pitwall/signals.jsonl"
OT="$ROOT/plugins/opentimeline/bin/opentimeline"
eq "no plugins yet: pitwall ot is not a command" "$(pw ot status 2>&1 | grep -c 'unknown command ot')" 1
eq "the OpenTimeline plugin installs by name, linked from the checkout" "$(pw plugin add opentimeline | grep -c 'opentimeline 0.1.0 installed: the OpenTimeline view, pitwall ot, on lane.state, lane.urgent') $(readlink "$XDG_DATA_HOME/pitwall/plugins/opentimeline")" "1 $ROOT/plugins/opentimeline"
eq "and lists itself" "$(pw plugin ls | grep -c '^opentimeline  *0.1.0  *official')" 1
TMUX="$SOCK,0,0" PITWALL="$ROOT/bin/pitwall" "$OT" hook lane.state "$P2" working asking
eq "not connected, nothing is sent or kept" "$([ -f "$PENDING" ] && echo kept || echo none)" none
echo t >"$XDG_CONFIG_HOME/token"
pw ot connect "$XDG_CONFIG_HOME/token" --url http://127.0.0.1:9 >/dev/null
eq "pitwall ot is the plugin's command" "$(sed -n 1p "$XDG_CONFIG_HOME/pitwall/opentimeline")" "http://127.0.0.1:9"
TMUX="$SOCK,0,0" PITWALL="$ROOT/bin/pitwall" "$OT" hook lane.state "$P2" working asking
eq "an unreachable Timeline keeps the signal" "$(wc -l <"$PENDING" | tr -d ' ')" 1
eq "asking needs attention" "$(python3 -I -c 'import json,sys; s=json.loads(open(sys.argv[1]).readline()); print(s["kind"], s["attention"], s["subject"])' "$PENDING")" "lane.state attention lane:s/two"
$T set -p -t "$P2" @pitwall_state asking
hook "$P2" PostToolUse # leaving asking: the hook sends the change in the background
i=0; while [ "$(wc -l <"$PENDING" | tr -d ' ')" != 2 ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
eq "leaving asking is reported too, with attention none" "$(tail -1 "$PENDING" | python3 -I -c 'import json,sys; s=json.load(sys.stdin); print(s["state"], s["attention"])')" "working none"
TMUX="$SOCK,0,0" PITWALL="$ROOT/bin/pitwall" "$OT" hook lane.urgent "$P2" 10
eq "an escalation is sent as urgent" "$(tail -1 "$PENDING" | python3 -I -c 'import json,sys; s=json.load(sys.stdin); print(s["state"], s["attention"], s["summary"])')" "asking urgent s/two: still asking after 10m"
$T set -g @pitwall_seg_opentimeline 3
eq "Needs you's count, the plugin's piece, shows in the status line" "$($T display -p -t s:two '#{E:@pitwall-summary}' | grep -c '⚑ 3')" 1
$T set -gu @pitwall_seg_opentimeline

# --- plugins: from a folder and from a git repo; a view, an action, a command, a hook, a piece of the status line -----
PLUG=$(mktemp -d "$ROOT/.fake.XXXXXX"); ISOLATED="$ISOLATED $PLUG" # not /tmp: CI mounts it noexec
mkdir -p "$PLUG/demo/bin"
cat >"$PLUG/demo/plugin.toml" <<'EOF'
name = "demo"
version = "1.0.0"
pitwall = ">=0.1"
run = "bin/demo"
events = "lane.state"
view = "Demo"
command = "tune"
segment = "♪"
segment_color = "muted"
EOF
cat >"$PLUG/demo/bin/demo" <<'EOF'
#!/bin/sh
here=$(cd "$(dirname "$0")/.." && pwd)
case $1 in
  hook) shift; echo "$*" >>"$here/events" ;;
  view)
    if [ -n "${PITWALL_VIEW_PREVIEW:-}" ] && [ -f "$here/loading" ]; then
      printf 'head\tCOLLECTIONS\tspotlight\nrow\tc1\t♫\tOld road music\t\troad music\n' >"$PITWALL_VIEW_PREVIEW.tmp"
      mv "$PITWALL_VIEW_PREVIEW.tmp" "$PITWALL_VIEW_PREVIEW"
    fi
    while [ -f "$here/first-page" ]; do sleep 0.1; done
    if [ -n "${PITWALL_VIEW_PREVIEW:-}" ] && [ -f "$here/loading" ]; then
      printf 'head\tCOLLECTIONS\tspotlight\nrow\tc1\t♫\tMore road music\t\troad music\n' >"$PITWALL_VIEW_PREVIEW.tmp"
      mv "$PITWALL_VIEW_PREVIEW.tmp" "$PITWALL_VIEW_PREVIEW"
    fi
    while [ -f "$here/loading" ]; do sleep 0.1; done
    if [ "${2-}" = collection ]; then
      printf 'head\tINSIDE COLLECTION\nrow\ti1\t·\tFirst item\t\tfirst item\nrow\ti2\t·\tSecond item\t\tsecond item\nact\ti2\tplay\t⏎\tPlay item\t\trun\n'
      exit
    fi
    printf 'pin\tt1\tk:⏎\n'
    printf 'unit\ttrack\ttracks\nbadge\t{green}♪\nright\tdemo totals\nhead\tQUEUE\tcount timeline\nrow\tt1\t{green}▶\tFirst song alpha\t{dim}3:12\tfirst song\talpha\t0\nrow\tt2\t{muted}·\tSecond song\t{dim}4:01\tsecond song\t\t0\nact\tt1\tplay\t⏎\tPlay it\tStarts the track.\trun\nact\tt1\tcopy\ty\tCopy the title\tInto the clipboard.\tcopy\tFirst song alpha\nside\tt1\t{dim}\t{green}NOW{/} PLAYING\nside\tt1\t{bold}{text}\tFirst song alpha\n'
    printf 'head\tCOLLECTIONS\tspotlight\nrow\tc1\t♫\tRoad music\t\troad music\nact\tc1\tbrowse\t⏎\tBrowse collection\t\tpage\tcollection\nact\tc1\thandoff\th\tImport fixture story\t\trun\tctrl-q\n' ;;
  act)
    if [ "$2" = handoff ]; then
      printf 'handoff\t'
      printf '# Fixture story\n\nThe first check passed.' | base64 | tr -d '\n'
      printf '\n'
      exit 0
    fi
    while [ -f "$here/action-wait" ]; do sleep 0.1; done
    echo "$2 $3" >>"$here/acts"
    printf 'notice\tplaying %s\n' "$3"
    [ "$3" != i2 ] || printf 'refresh\troot\n'
    ;;
  cmd) shift; echo "tune: $*" ;;
esac
EOF
chmod +x "$PLUG/demo/bin/demo"
eq "a local folder installs as a link" "$(pw plugin add "$PLUG/demo" | grep -c 'demo 1.0.0 installed') $(readlink "$XDG_DATA_HOME/pitwall/plugins/demo")" "1 $PLUG/demo"
eq "its command is pitwall's, and the help lists it" "$(pw tune up) $(pw --help | grep -c 'pitwall tune …  *from the demo plugin')" "tune: up 1"
eq "the report counts the plugin command and lists the unopened view at zero" \
  "$(pw features | awk '$1 == "plugin.demo.command" || $1 == "plugin.demo.view" { print $1, $4 }')" \
  "$(printf '%s\n' 'plugin.demo.command 1' 'plugin.demo.view 0')"
$T set -p -t "$P2" @pitwall_state working
hook "$P2" PermissionRequest
i=0; while ! grep -q asking "$PLUG/demo/events" 2>/dev/null && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
eq "a lane's state change reaches the plugins that listen" "$(cat "$PLUG/demo/events" 2>/dev/null)" "lane.state $P2 working asking"
$T set -g @pitwall_seg_demo 7
eq "and its piece of the status line shows while it holds something" "$($T display -p -t s:two '#{E:@pitwall-summary}' | grep -c '♪ 7')" 1
$T set -g @pitwall_seg_demo 0
eq "and hides at 0" "$($T display -p -t s:two '#{E:@pitwall-summary}' | grep -c '♪')" 0
printf 'segment_where = "rule"\n' >>"$PLUG/demo/plugin.toml"
$T set -g @pitwall-layout tabs; pw plugin _index
eq "a piece that asks for the rule goes there in the tabs layout" "$($T show -gv @pitwall-rule-segments | grep -c '@pitwall_seg_demo') $($T show -gv @pitwall-segments | grep -c '@pitwall_seg_demo')" "1 0"
$T set -gu @pitwall-layout; pw plugin _index
eq "and at the top in the inline layout, which has no rule" "$($T show -gv @pitwall-segments | grep -c '@pitwall_seg_demo')" 1
bad() { # bad <key> <value> <what the refusal says>: a copy of demo with one key changed is refused
  rm -rf "$PLUG/bad"; cp -R "$PLUG/demo" "$PLUG/bad"
  sed -i.bak "s|^$1 = .*|$1 = \"$2\"|" "$PLUG/bad/plugin.toml"; sed -i.bak 's|^name = .*|name = "bad"|' "$PLUG/bad/plugin.toml"
  [ "$1" = name ] && sed -i.bak "s|^name = .*|name = \"$2\"|" "$PLUG/bad/plugin.toml"
  pw plugin add "$PLUG/bad" 2>&1 | grep -c "$3"
}
eq "refused: a name that is not lowercase" "$(bad name Bad 'lowercase letters')" 1
eq "refused: a run outside the plugin" "$(bad run ../x 'inside the plugin')" 1
eq "refused: an event pitwall does not send" "$(bad events lane.nope 'no event called lane.nope')" 1
eq "refused: a command pitwall has" "$(bad command ls "pitwall ls is pitwall's own")" 1
eq "refused: a newer pitwall than this one" "$(bad pitwall '>=99.0' 'needs pitwall >=99.0')" 1
eq "refused: a segment somewhere pitwall does not draw" "$(bad segment_where sky 'segment_where is status or rule')" 1
eq "none of them was installed" "$(ls "$XDG_DATA_HOME/pitwall/plugins" | tr '\n' ' ')" "demo opentimeline "
REPO="$PLUG/repo"; cp -R "$PLUG/demo" "$REPO"
sed -i.bak 's|^name = .*|name = "gitdemo"|; s|^command = .*|command = "gtune"|; s|^view = .*||' "$REPO/plugin.toml"; rm -f "$REPO/plugin.toml.bak"
G="git -C $REPO -c user.email=t@t -c user.name=t"
$G init -q && $G add -A && $G commit -qm one
eq "a repo is shown first and installed only after a yes" "$(pw plugin add "file://$REPO" </dev/null 2>&1 | grep -c 'runs bin/demo with: pitwall gtune, on lane.state, ♪ in the status line') $(pw plugin add "file://$REPO" </dev/null 2>&1 | grep -c 'not installed') $([ -e "$XDG_DATA_HOME/pitwall/plugins/gitdemo" ] && echo there || echo absent)" "1 1 absent"
eq "with --yes it is cloned" "$(pw plugin add "file://$REPO" --yes | grep -c 'gitdemo installed') $(pw plugin ls | grep -A0 '^gitdemo' | grep -c "file://$REPO@")" "1 1"
sed -i.bak 's|^version = .*|version = "1.1.0"|' "$REPO/plugin.toml"; rm -f "$REPO/plugin.toml.bak"; $G commit -qam two
eq "update takes the repo's new commits after a yes" "$(pw plugin update gitdemo --yes | grep -c 'gitdemo: now at') $(pw plugin ls | grep '^gitdemo' | awk '{ print $2 }')" "1 1.1.0"
eq "doctor checks every plugin" "$(pw doctor | grep -c '^ok    plugin ')" 3
eq "rm deletes a clone, and only unlinks a folder" "$(pw plugin rm gitdemo; pw plugin rm demo; ls "$XDG_DATA_HOME/pitwall/plugins" | tr '\n' ' ')$([ -x "$PLUG/demo/bin/demo" ] && echo kept)" "pitwall: gitdemo removed
pitwall: demo removed
opentimeline kept"
eq "and its command goes with it" "$(pw tune x 2>&1 | grep -c 'unknown command tune')" 1
pw plugin add "$PLUG/demo" >/dev/null # the dashboard below shows its view

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
FAKE=$(mktemp -d "$ROOT/.fake.XXXXXX"); ISOLATED="$ISOLATED $FAKE" # not /tmp: CI mounts it noexec
for a in codex 2.1.327 opencode hermes; do # macOS names a process after its binary, Linux after its argv[0]
  if command -v codesign >/dev/null; then cp /bin/sleep "$FAKE/$a" && codesign -f -s - "$FAKE/$a" 2>/dev/null
  else printf '#!/bin/bash\nexec -a %s python3 -c "import time; time.sleep(int(\\"$1\\"))"\n' "$a" >"$FAKE/$a"; chmod +x "$FAKE/$a"; fi
done; mkdir -p "$FAKE/proj" "$FAKE/home"
printf '{"id":"cx-b","thread_name":"Fix the board"}\n' >"$FAKE/home/session_index.jsonl"
CA=$($T new-window -d -P -F '#{pane_id}' -t s: -n cxa -c "$FAKE/proj" "exec $FAKE/codex 300")
CB=$($T new-window -d -P -F '#{pane_id}' -t s: -n cxb -c "$FAKE/proj" "exec $FAKE/codex 300")
CL=$($T new-window -d -P -F '#{pane_id}' -t s: -n cl -c "$FAKE" "exec $FAKE/2.1.327 300")
$T select-pane -t "$CA" -T 'Ship the docs | proj' \; select-pane -t "$CB" -T 'Fix the board | proj'
sleep 0.3
daemon() { echo "{\"session_id\":\"$1\",\"cwd\":\"$2\"}" | TMUX="$SOCK,0,0" TMUX_PANE=%999 CODEX_HOME="$FAKE/home" "$ROOT/bin/pitwall-hook" "$3" "$4"; }
daemon cx-b "$FAKE/proj" PreToolUse codex
eq "a daemon's stale pane: the Codex lane is found by its thread name" "$($T display -p -t "$CB" '#{@pitwall_state}')" working
[ "$($T display -p -t "$CB" '#{@pitwall_state}')" = working ] || { echo "  FAKE=$FAKE ($(cd "$FAKE/proj" && pwd -P))"; $T list-panes -a -F '  #{pane_id} [#{pane_current_path}] [#{pane_current_command}] [#{pane_title}]'; }
eq "and the other Codex in that directory is left alone" "$($T display -p -t "$CA" '#{@pitwall_state}')" ""
daemon cx-b "$FAKE/proj" Stop codex
eq "once found, its session leads back to it" "$($T display -p -t "$CB" '#{@pitwall_state}')" done
eq "and the record is right, not empty fields" "$(cut -f4,6 "$XDG_STATE_HOME/pitwall/lanes/cx-b")" "s	cxb"
daemon cx-z "$FAKE/proj" PreToolUse codex
eq "two Codex and no thread name to tell them apart: neither is touched" "$($T display -p -t "$CA" '#{@pitwall_state}')" ""
$T set -p -t "$CA" @pitwall_session cx-a
hook "$CA" UserPromptSubmit '{"session_id":"cx-a"}'
hook "$CB" UserPromptSubmit '{"session_id":"cx-b"}'
hook "$CA" Stop '{"session_id":"cx-b"}'
eq "a daemon's live but wrong pane cannot take another Codex session" "$($T display -p -t "$CA" '#{@pitwall_session} #{@pitwall_state}') $($T display -p -t "$CB" '#{@pitwall_session} #{@pitwall_state}')" "cx-a working cx-b done"
hook "$CA" Stop '{"session_id":"unmatched"}'
eq "an unmatched Stop leaves the live pane alone" "$($T display -p -t "$CA" '#{@pitwall_session} #{@pitwall_state}')" "cx-a working"

codex_turn() { hook "$CA" "$1" "{\"session_id\":\"cx-a\",\"turn_id\":\"$2\"}"; }
codex_turn UserPromptSubmit first
codex_turn PermissionRequest first
codex_turn Interrupt first
eq "interrupt clears a Codex spinner or pending approval without Stop" "$(state "$CA")" idle
codex_turn PostToolUse first
eq "a late tool result cannot revive an interrupted Codex turn" "$(state "$CA")" idle
codex_turn UserPromptSubmit second
codex_turn UserPromptSubmit third
codex_turn Stop second
codex_turn Interrupt first
eq "old terminal events leave the current Codex turn working" "$(state "$CA")" working
hook "$CA" SessionStart '{"session_id":"cx-a","source":"compact"}'
eq "Codex compaction does not reset the current turn to idle" "$(state "$CA")" working

codex_turn UserPromptSubmit title-turn
CODEX_TTY=$($T display -p -t "$CA" '#{pane_tty}')
codex_title() { printf '\033]2;%s\007' "$1" > "$CODEX_TTY"; }
codex_title '⠙ Ship the docs | proj'
for _ in $(seq 1 15); do [ "$($T display -p -t "$CA" '#{@pitwall_codex_title_turn}')" = title-turn ] && break; sleep 0.1; done
codex_title 'Ship the docs | proj'
for _ in $(seq 1 15); do [ "$(state "$CA")" = done ] && break; sleep 0.1; done
eq "Codex title returning to rest settles a turn that sent no terminal hook" "$(state "$CA")" done
codex_turn PostToolUse title-turn
eq "a late tool result cannot revive a turn settled by the title" "$(state "$CA")" done
codex_turn UserPromptSubmit fourth
codex_title 'Ship more docs | proj'
eq "a plain title alone cannot settle an active Codex turn" "$(state "$CA")" working
codex_title '⠙ Ship more docs | proj'
for _ in $(seq 1 15); do [ "$($T display -p -t "$CA" '#{@pitwall_codex_title_turn}')" = fourth ] && break; sleep 0.1; done
codex_turn PermissionRequest fourth
codex_title 'Ship more docs | proj'
eq "title recovery leaves a pending approval alone" "$(state "$CA")" asking

echo "{\"session_id\":\"cl-1\",\"cwd\":\"$FAKE\"}" | TMUX="$SOCK,0,0" TMUX_PANE='' "$ROOT/bin/pitwall-hook" UserPromptSubmit claude
eq "a Claude hook without tmux finds the one Claude in its directory" "$($T display -p -t "$CL" '#{@pitwall_state} #{@pitwall_name}')" "working $(basename "$FAKE")"
echo '{"session_id":"cl-1","reason":"other"}' | TMUX="$SOCK,0,0" TMUX_PANE="$CL" "$ROOT/bin/pitwall-hook" SessionEnd claude; sleep 2.6
eq "a session that ends while its agent runs on (a resume, a reaped session) is not gone" "$($T display -p -t "$CL" '#{@pitwall_state}')" working
OC=$($T new-window -d -P -F '#{pane_id}' -t s: -n oc -c "$FAKE" "exec $FAKE/opencode 300"); sleep 0.3
eq "other agents are lanes before any hook, opencode here" "$($T display -p -t "$OC" '#{E:@pitwall-state-fmt}')" idle
$T kill-pane -t "$CA" \; kill-pane -t "$CB" \; kill-pane -t "$CL" \; kill-pane -t "$OC"

# After /new, the Hermes gateway has neither a pane hint nor a cwd for the new session.
HA=$($T new-window -d -P -F '#{pane_id}' -t s: -n ha -c "$FAKE/proj" "exec $FAKE/hermes 300")
HB=$($T new-window -d -P -F '#{pane_id}' -t s: -n hb -c "$FAKE/proj" "exec $FAKE/hermes 300")
$T select-pane -t "$HA" -T hermes \; select-pane -t "$HB" -T hermes
mkdir -p "$FAKE/home/terminal-sessions"
hermes_breadcrumb() {
  tty=$($T display -p -t "$1" '#{pane_tty}' | tr / -)
  printf '{"session_id": "%s", "cwd": "%s", "ts": %s}' "$2" "$FAKE/proj" "$(date +%s)" >"$FAKE/home/terminal-sessions/tty$tty"
}
hermes_breadcrumb "$HA" hermes-other
hermes_breadcrumb "$HB" hermes-new
hermes_breadcrumb "$P1" hermes-new # a stale marker in a plain shell
hermes_event() {
  printf '{"session_id": "%s", "cwd": "%s"}' "$1" "$FAKE/home" |
    TMUX="$SOCK,0,0" TMUX_PANE='' HERMES_HOME="$FAKE/home" "$ROOT/bin/pitwall-hook" "$2" hermes
}
hermes_event hermes-new UserPromptSubmit
eq "a Hermes gateway turn after /new updates the correct terminal" "$($T display -p -t "$HB" '#{@pitwall_session} #{@pitwall_state}')" "hermes-new working"
eq "the second Hermes lane in the same directory stays idle" "$(state "$HA")" idle
hermes_event hermes-new Stop
eq "the Hermes gateway turn clears the spinner on completion" "$(state "$HB")" done
eq "the Hermes restore record uses the lane's directory" "$(cut -f3 "$XDG_STATE_HOME/pitwall/lanes/hermes-new" 2>/dev/null)" "$(cd "$FAKE/proj" && pwd -P)"
$T kill-pane -t "$HA" \; kill-pane -t "$HB"

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

# --- the tabs layout: workspaces as tab groups on top, limits and the machine on the panes' bottom rule ---------
$T set -g @pitwall-layout tabs \; set -g @pitwall-system off \; set -g @pitwall-quota off
$T run-shell "'$ROOT/pitwall.tmux'"; $T run-shell "'$ROOT/pitwall.tmux'"
eq "tabs: the status line moves to the top" "$($T show -gv status-position)" top
eq "tabs: its first line is pitwall's, set once" "$($T show -gv 'status-format[0]')" '#{E:@pitwall-tabs-fmt}'
eq "tabs: the bottom bar is the panes' bottom border" "$($T show -gwv pane-border-status)" bottom
$T set -p -t "$P1" @pitwall_state asking \; set -p -t "$P2" @pitwall_state done \; set -g @pitwall_quota 'Q-LIMITS' \; set -g @pitwall_clock '10:24 19 Nov'
eq "tabs: another workspace is a pill with who waits there" "$($T display -p -t s:one '#{E:@pitwall-tabs-fmt}' | sed 's/#\[[^]]*\]//g' | grep -c 's ◆1 ✓1')" 1
eq "tabs: the bottom rule carries the limits and the clock" "$($T display -p -t "$P2" '#{E:@pitwall-rule-fmt}' | sed 's/#\[[^]]*\]//g' | tr -s ' ')" " Q-LIMITS 10:24 "
eq "the machine sampler reads at least the cpu" "$("$ROOT/bin/pitwall-sys" --once | grep -c '^cpu [0-9]*%')" 1
$T set -g @pitwall-layout inline \; run-shell "'$ROOT/pitwall.tmux'"
eq "switching back gives the theme its status line again" "$($T show -gv status-position) $($T show -gwv pane-border-status)" "bottom off"
eq "and tmux its own first line" "$($T show -gv 'status-format[0]' | grep -c pitwall-tabs)" 0

# --- install: Hermes's YAML gets a block appended, never rewritten -----------------------------------------------
H=$(mktemp -d); ISOLATED="$ISOLATED $H"; mkdir -p "$H/.claude/skills" "$H/.codex" "$H/.hermes"
printf '# my notes\nmodel: x\n' >"$H/.hermes/config.yaml"
HOME=$H HERMES_HOME= "$ROOT/bin/pitwall" install --write >/dev/null
eq "install wires Codex interruption and session shutdown hooks" "$(python3 -c 'import json, sys; print({"Interrupt", "SessionEnd"} <= json.load(open(sys.argv[1]))["hooks"].keys())' "$H/.codex/hooks.json")" True
eq "install links the agents' skill where an agent keeps skills" "$(readlink "$H/.claude/skills/pitwall" 2>/dev/null | sed 's|.*/skills/|skills/|')" skills/pitwall
eq "install appends seven Hermes hooks, tool calls included" "$(grep -c 'pitwall-hook .* hermes$' "$H/.hermes/config.yaml")" 7
eq "and keeps what was there, comments too" "$(head -2 "$H/.hermes/config.yaml" | tr '\n' ' ')" "# my notes model: x "
HOME=$H HERMES_HOME= "$ROOT/bin/pitwall" install --write >/dev/null
eq "a second install adds nothing" "$(grep -c '^hooks:' "$H/.hermes/config.yaml") $(grep -c 'pitwall-hook' "$H/.hermes/config.yaml")" "1 7"
awk '!/post_tool_call/ { print } /post_tool_call/ { getline; getline }' "$H/.hermes/config.yaml" >"$H/old" && mv "$H/old" "$H/.hermes/config.yaml"
HOME=$H HERMES_HOME= "$ROOT/bin/pitwall" install --write >/dev/null
eq "an older install, its block last in the file, gets the tool-call hook added at the end" "$(grep -c 'pitwall-hook' "$H/.hermes/config.yaml") $(tail -3 "$H/.hermes/config.yaml" | head -1)" "7   post_tool_call:"
printf 'hooks:\n  pre_tool_call: []\n' >"$H/.hermes/config.yaml"
eq "a config with its own hooks: block is left alone, the lines printed" "$(HOME=$H HERMES_HOME= "$ROOT/bin/pitwall" install --write | grep -c 'add these under it')$(grep -c pitwall "$H/.hermes/config.yaml")" 10

# --- pitwall up: a workspace from a small file; what is there stays, what is missing comes back ------------------
UPD="$XDG_CONFIG_HOME/pitwall/up"; mkdir -p "$UPD"; UPJ=$(mktemp -d "$ROOT/.up.XXXXXX"); ISOLATED="$ISOLATED $UPJ"; mkdir -p "$UPJ/sub"
printf '# a test recipe\nworkspace = "uplab"\ndir = "%s"\n\n[[tab]]\nname = "one"\nrun = "sleep 300"   # a comment\n\n[[tab]]\nname = "two"\ndir = "sub"\nrun = "sleep 301"\n[[tab.pane]]\nrun = "sleep 302"\n' "$UPJ" >"$UPD/demo.toml"
up() { TMUX="$SOCK,0,0" "$ROOT/bin/pitwall" up "$@" </dev/null; }
up --dry demo >/dev/null
eq "up --dry makes nothing" "$($T has-session -t '=uplab' 2>/dev/null && echo made || echo none)" none
up demo >/dev/null
eq "up makes the workspace and its tabs, a tab's dir relative to the workspace's" "$($T list-windows -t '=uplab' -F '#W' | tr '\n' ' ')$($T display -p -t '=uplab:two' '#{window_panes}')" "one two 2"
eq "and a relative dir lands in the workspace's folder" "$($T display -p -t '=uplab:two.1' '#{pane_start_path}' | sed "s|.*/||")" sub
eq "again, it keeps what is there and opens nothing" "$(up demo | grep -c 'already up') $($T list-windows -t '=uplab' | wc -l | tr -d ' ')" "2 2"
$T kill-window -t '=uplab:one'
eq "a tab closed by mistake comes back, alone" "$(up demo | grep -c '✓ one') $($T list-windows -t '=uplab' -F '#W' | sort | tr '\n' ' ')" "1 one two "
eq "up --list says it is up" "$(TMUX="$SOCK,0,0" "$ROOT/bin/pitwall" up --list | awk '$1 == "demo" { print $5 }')" up
printf 'name = "repo"\nworkspace = "uprepo"\n[[tab]] name = "r1"\nrun = "sleep 303"\n' >"$UPJ/.pitwall.toml"
up "$UPJ" >/dev/null 2>&1
eq "a repo's recipe it has not run before needs a yes" "$($T has-session -t '=uprepo' 2>/dev/null && echo ran || echo asked)" asked
up --yes "$UPJ" >/dev/null; $T kill-session -t '=uprepo'; up repo >/dev/null 2>&1
eq "once trusted it runs, and is known by its name" "$($T list-windows -t '=uprepo' -F '#W' 2>/dev/null)" r1
i=0; until [ "$($T display -p -t '=uplab:two.2' '#{pane_current_command}')" = sleep ] || [ $i -ge 60 ]; do sleep 0.1; i=$((i + 1)); done
TMUX="$SOCK,0,0" "$ROOT/bin/pitwall" up --save uplab >/dev/null
eq "up --save writes the recipe back from the open workspace" "$(grep -c '^\[\[tab\]\]' "$UPD/uplab.toml") $(grep -c 'run = "sleep 302"' "$UPD/uplab.toml")" "2 1"
$T new-window -d -t '=uplab:' -n three "sleep 304"
i=0; until grep -q 'name = "three"' "$UPD/uplab.toml" || [ $i -ge 80 ]; do sleep 0.1; i=$((i + 1)); done
eq "a saved recipe follows the workspace: a tab opened is written in" "$(grep -c 'name = "three"' "$UPD/uplab.toml")" 1
printf '# mine now\n' >>"$UPD/uplab.toml"; $T new-window -d -t '=uplab:' -n four "sleep 305"; sleep 3
eq "edited by hand, it is left alone" "$(grep -c 'name = "four"' "$UPD/uplab.toml") $(tail -1 "$UPD/uplab.toml")" "0 # mine now"
mkdir -p "$UPJ/bin"
cat >"$UPJ/bin/mv" <<'SH'
#!/bin/sh
"${PITWALL_TEST_MV}" "$@" || exit
for dest do :; done
if [ "$dest" = "$PITWALL_TEST_RECIPE" ]; then printf '# edited immediately after save\n' >>"$dest"; fi
SH
chmod +x "$UPJ/bin/mv"
REAL_MV=$(command -v mv)
TMUX="$SOCK,0,0" PATH="$UPJ/bin:$PATH" PITWALL_TEST_MV="$REAL_MV" PITWALL_TEST_RECIPE="$UPD/uplab.toml" \
  "$ROOT/bin/pitwall" up --save uplab >/dev/null
$T set-hook -gu 'after-new-window[77]'
$T new-window -d -t '=uplab:' -n five 'sleep 306'
TMUX="$SOCK,0,0" "$ROOT/bin/pitwall" _autosave uplab
eq "an edit immediately after a save stays out of the generated checksum" \
  "$(grep -c 'name = "five"' "$UPD/uplab.toml") $(tail -1 "$UPD/uplab.toml")" "0 # edited immediately after save"
$T run-shell "'$ROOT/pitwall.tmux'"
$T kill-session -t '=uplab' \; kill-session -t '=uprepo'
printf 'workspace = "upses"\n[[tab]]\nname = "a"\nagent = "fakeagent"\nsession = "s-42"\n' >"$UPD/ses.toml"
$T set -g @pitwall-resume-fakeagent 'fakeagent --resume {id}'
eq "a saved session is the one resumed" "$(up --dry ses | grep -c 'fakeagent, resumed')" 1
$T set -gu @pitwall-resume-fakeagent

# --- the dashboard, driven like a person would: keys in, screen out ---------------------------------------------
# Its own server with four known lanes (alpha, beta, gamma in lab; delta in oss), the dashboard in a pane of its own.
B="tmux -L pitwall-dash-$$"
trap '$T kill-server 2>/dev/null; $B kill-server 2>/dev/null; rm -rf $ISOLATED' EXIT
$B -f /dev/null new-session -d -s lab -n alpha -x 150 -y 45
$B set -g allow-set-title off 2>/dev/null # the tasks stay the test's (tmux 3.4 has no such option, nor a shell that sets titles)
$B new-window -d -t lab -n beta \; new-window -d -t lab -n gamma \; new-session -d -s oss -n delta
$B set-environment -g XDG_CONFIG_HOME "$XDG_CONFIG_HOME" \; set-environment -g XDG_STATE_HOME "$XDG_STATE_HOME" \; set-environment -g XDG_DATA_HOME "$XDG_DATA_HOME"
$B run-shell "'$ROOT/pitwall.tmux'"
eq "the dashboard is on prefix Space, the board and the workspace picker are gone" "$($B list-keys -T prefix | grep pitwall-dash | grep -c ' Space ') $($B list-keys -T prefix | grep -c 'pitwall-board\|pitwall-ws')" "1 0"
$B bind A display-popup "'/old/bin/pitwall-board'" \; bind W display-popup "'/old/bin/pitwall-ws'" \; bind B display-popup mine
$B run-shell "'$ROOT/pitwall.tmux'"
eq "an upgrade frees the keys the board and the picker had, and only those" "$($B list-keys -T prefix | grep -c 'pitwall-board\|pitwall-ws') $($B list-keys -T prefix | grep -c 'display-popup mine')" "0 1"
lane() { $B set -p -t "$1" @pitwall_state "$2" \; set -p -t "$1" @pitwall_harness codex \; select-pane -t "$1" -T "task of ${1#*:}"; }
lane lab:alpha asking; lane lab:beta idle; lane lab:gamma working; lane oss:delta idle
TRANSCRIPT="$XDG_STATE_HOME/gamma.jsonl"
printf '{"type":"turn_context","payload":{"model":"fixture-model"}}\n' >"$TRANSCRIPT"
$B set -p -t lab:gamma @pitwall_transcript "$TRANSCRIPT"
BASH_BIN=bash # the dashboard runs on the bash pitwall.tmux would pick
for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do [ -x "$b" ] && BASH_BIN=$b && break; done
touch "$PLUG/demo/loading" "$PLUG/demo/first-page"
$B new-session -d -s ui -x 150 -y 45 "env TERM=xterm-256color '$BASH_BIN' '$ROOT/bin/pitwall-dash'"
screen() { $B capture-pane -p -t ui; }
until_screen() { # until_screen <grep pattern> [absent]: wait up to 4 s for the screen to show (or lose) it
  i=0
  while [ $i -lt 40 ]; do
    if [ "${2:-}" = absent ]; then screen | grep -q -- "$1" || return 0; else screen | grep -q -- "$1" && return 0; fi
    sleep 0.1; i=$((i + 1))
  done
  echo "FAIL  the dashboard never showed${2:+ the absence of} '$1'"; fail=1 # a timeout is a failure, not a skipped check
  return 1
}
keys() { $B send-keys -t ui "$@"; sleep 0.3; }
esc() { $B send-keys -t ui Escape; sleep 1.2; } # on bash 3.2 a lone esc waits a second to rule out an arrow
row() { screen | grep -E "[○◆✓⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] $1 "; }
lanes_shown() { screen | grep -cE '[○◆✓⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] (alpha|beta|gamma|gam2|delta) '; }

until_screen delta && eq "the dashboard lists every lane" "$(lanes_shown)" 4
eq "with the search empty, who waits for you comes first" "$(screen | grep -A1 'WAITING FOR YOU' | grep -c '◆ alpha')" 1
eq "the Lanes footer keeps Git and editor shortcuts in the actions menu" "$(screen | tail -1 | grep -c 'diff nvim git pr')" 0
$B resize-window -t ui: -x 76 -y 25
until_screen '^─\{76\}$'
until_screen 'ctrl-q  create handoff'
until_screen 'ctrl-z  inbox'
until_screen 'shift-tab  previous'
eq "a narrow footer shows handoff and Inbox together before secondary shortcuts" \
  "$(screen | tail -4 | awk '/ctrl-q  create handoff.*ctrl-z  inbox/ { primary=NR } /shift-tab  previous/ { previous=NR } END { print (primary && previous && primary < previous) }')" 1
$B resize-window -t ui: -x 150 -y 45
keys Right
until_screen 'Open the worktree.s diff in lumen'
until_screen 'Open the folder in nvim'
until_screen 'Open the branch.s PR'
esc
# Inbox isolates actionable lanes. A newer question sorts below the one that has waited longer.
lane oss:delta asking; lane lab:beta done
$B set -p -t lab:alpha @pitwall_since "$((now - 1200))" \; set -p -t oss:delta @pitwall_since "$((now - 600))" \; set -p -t lab:beta @pitwall_since "$((now - 1800))"
$B set -p -t lab:alpha @pitwall_question 'Approve the fixture?'
keys -l INBOX; keys Enter
until_screen '◆ delta' && until_screen '✓ beta'
eq "Inbox sorts questions by wait and keeps only actionable lanes" "$(screen | awk '/◆ (alpha|delta) |✓ beta / { sub(/^.*[◆✓] /, ""); print $1 }' | tr '\n' ' ') $(lanes_shown)" "alpha delta beta  3"
until_screen 'Approve the fixture?'
keys -l beta; keys Right
until_screen 'Mark as read'
$B set -p -t lab:beta @pitwall_since "$now"
keys k
until_screen 'the lane changed'
eq "the Inbox leaves a newer completion unread" "$($B display -p -t lab:beta '#{@pitwall_state}')" done
keys -l beta; keys Right
until_screen 'Mark as read' && keys k
until_screen 'beta marked as read'
eq "Mark as read affects only the selected completion" "$($B display -p -t lab:beta '#{@pitwall_state}') $($B display -p -t lab:alpha '#{@pitwall_state}') $($B display -p -t oss:delta '#{@pitwall_state}')" "idle asking asking"
lane oss:delta idle
$B set -pu -t lab:alpha @pitwall_question
esc
until_screen 'WAITING FOR YOU'
keys C-z
until_screen 'Inbox · filter lanes'
esc
until_screen 'WAITING FOR YOU'
keys -l beta; keys Right
until_screen 'Add to favorites' && keys -l '*'
until_screen 'FAVORITES' && eq "an idle favorite appears above asking lanes, exactly once" "$(screen | awk '/FAVORITES/{f=NR} /WAITING FOR YOU/{w=NR} END{print (f && f<w)}') $(row beta | grep -c '★') $(lanes_shown)" "1 1 4"
keys -l lab
eq "favorites lead matching lanes in search" "$(screen | grep '▌' | grep -c 'beta ★')" 1
esc; keys C-f
for st in working done asking gone idle; do
  lane lab:beta "$st"
  case $st in working) symbol='[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]' ;; done) symbol=✓ ;; asking) symbol=◆ ;; gone) symbol=✗ ;; idle) symbol=○ ;; esac
  until_screen "$symbol beta ★" && eq "the favorite stays first in state grouping while $st" "$(screen | grep -A1 FAVORITES | grep -c 'beta ★') $(screen | grep -Ec '[○◆✓✗⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] beta ★')" "1 1"
done
$B new-session -d -s fav-ui -x 150 -y 45 "env TERM=xterm-256color '$BASH_BIN' '$ROOT/bin/pitwall-dash'"
i=0; until $B capture-pane -p -t fav-ui | grep -q 'beta ★' || [ $i -ge 40 ]; do sleep 0.1; i=$((i+1)); done
eq "another dashboard opens with the same favorite" "$($B capture-pane -p -t fav-ui | grep -A1 FAVORITES | grep -c 'beta ★')" 1
$B kill-session -t fav-ui
keys -l '*'
until_screen 'FAVORITES' absent && eq "unfavoriting returns the pane to its group and keeps it selected" "$(screen | grep '▌' | grep -c '○ beta') $(lanes_shown)" "1 4"
keys C-f
keys -l 'road'
until_screen 'Old road music' && eq "the last panel is searchable while the plugin is still fetching" "$(screen | grep '▌' | grep -c 'Old road music')" 1
rm "$PLUG/demo/first-page"
until_screen 'More road music' && eq "a second preview replaces the first and keeps the selected row" "$(screen | grep '▌' | grep -c 'More road music')" 1
rm -f "$PLUG/demo/loading"
until_screen 'Road music' && eq "the live result replaces the preview and keeps the selected row" "$(screen | grep '▌' | grep -c 'Road music')" 1
keys Enter
until_screen 'INSIDE COLLECTION' && keys -l 'second'
until_screen 'First item' absent && eq "the nested view filters its own rows" "$(screen | grep '▌' | grep -c 'Second item')" 1
eq "a detail page keeps the tab's pinned preview" "$(screen | grep -c '│ NOW PLAYING')" 1
touch "$PLUG/demo/action-wait"
keys Enter
until_screen 'Demo · Play item'
keys -l ' item'
until_screen '❯ second item▏'
rm "$PLUG/demo/action-wait"
until_screen 'playing i2' && eq "a slow action keeps typing responsive and leaves the filtered detail row selected" \
  "$(screen | grep '▌' | grep -c 'Second item')" 1
esc
until_screen 'First item' && esc
until_screen 'Road music' && eq "back restores the main search and the selected plugin row" "$(screen | grep -c '❯ road▏') $(screen | grep '▌' | grep -c 'Road music')" "1 1"
esc
keys -l del
until_screen alpha absent && eq "typing finds lanes" "$(lanes_shown) $(screen | grep -c 'ACTIONS ON DELTA')" "1 1"
keys -l xyz; $B send-keys -t ui BSpace BSpace BSpace; sleep 0.8
eq "a burst of backspaces lands, every one" "$(screen | grep -c '❯ del▏')" 1
esc
until_screen alpha && eq "esc empties the search" "$(lanes_shown)" 4
eq "a lane's task shows under it" "$(screen | grep -A1 '◆ alpha' | grep -c 'task of alpha')" 1
keys -l alpha; keys Right
until_screen 'ACTIONS ON ALPHA' && esc
eq "back from its actions, the cursor is still on the lane" "$(screen | grep '▌' | grep -c alpha)" 1
keys -l 1
until_screen 'answered 1 to alpha' && eq "1 answers the lane that asks, typed into its pane" "$($B capture-pane -p -t lab:alpha | grep -c '1$')" 1
$B send-keys -t lab:alpha C-u
keys C-n
eq "down skips the task line, to the next lane" "$(screen | grep '▌' | grep -cE '[○◆✓⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] ')" 1
keys C-f
until_screen '^ *WORKING' && eq "ctrl-f groups the lanes by state" "$(screen | grep -cE '^ *(WORKING|IDLE) *│')$(screen | grep -cE '^ *LAB *│')" 20
sleep 0.5; keys C-f # once the first redraw is on screen
until_screen '^ *LAB ' && eq "and again by workspace, remembered for the next opening" "$($B show -gv @pitwall_dash_group)" workspace
keys Tab
until_screen 'QUEUE' && eq "tab opens a plugin's view: its rows under their head, counted, its badge on the tab" "$(screen | grep -c 'QUEUE · 2 TRACKS') $(screen | grep -c 'Demo ♪') $(screen | grep -c 'demo totals')" "1 1 1"
eq "the row's preview is the plugin's, and names the lane it goes with" "$(screen | grep -c 'NOW PLAYING') $(screen | grep -c 'LANES')" "1 1"
keys Enter
until_screen 'playing t1' && eq "⏎ runs the row's first action through the plugin" "$(tail -1 "$PLUG/demo/acts")" "play t1"
keys C-y
until_screen 'copied: First song alpha' && eq "ctrl + its key runs the others, here a copy" "$($B show-buffer)" "First song alpha"
keys -l second
until_screen '▶ First song' absent && eq "the search filters its rows" "$(screen | grep -c 'Second song') $(screen | grep -c 'QUEUE · 1 TRACK')" "1 1"
keys C-k
until_screen 'playing t1' && eq "the pinned action keeps the filter and selection" "$(screen | grep -c '❯ second▏') $(screen | grep '▌' | grep -c 'Second song') $(screen | grep -c '│ NOW PLAYING')" "1 1 1"
esc
keys Tab
until_screen 'OPENTIMELINE IS NOT ANSWERING' && eq "tab opens OpenTimeline, which says when its server does not answer, and what to do" "$(screen | grep -c 'Try again\|Open the OpenTimeline repo')" 2
keys Tab
until_screen 'SESSIONS' && eq "tab again: Usage, every lane in the columns of its header" "$(screen | grep -c 'LANE  *AGENT  *MODEL  *CTX  *TOKENS  *CACHED  *COST  *TURNS  *TODAY  *WAITED') $(screen | grep -cE '(alpha|beta|gamma|delta)  +codex')" "1 4"
until_screen 'find sessions: lane'
usage_order() { sed 's/^▌/ /' | awk '$3 == "codex" && $2 ~ /^(alpha|beta|gamma|delta)$/ { print $2 }'; }
keys NPage
page_screen=$(screen)
eq "Page Down reaches the last lane, skipping section text" "$(printf '%s\n' "$page_screen" | awk '/^▌/ { print $3; exit }')" "$(printf '%s\n' "$page_screen" | usage_order | tail -1)"
keys PPage
page_screen=$(screen)
eq "Page Up returns to the first lane" "$(printf '%s\n' "$page_screen" | awk '/^▌/ { print $3; exit }')" "$(printf '%s\n' "$page_screen" | usage_order | head -1)"
keys -l gam
until_screen 'these lanes' && eq "in Usage the search finds sessions, and the total follows" "$(screen | grep -cE '(alpha|beta|gamma|delta)  +codex')" 1
until_screen 'transcript disk *[0-9][0-9.]* *[KMG]*i*B'
esc
keys Tab
until_screen 'WAITING FOR YOU' && eq "and tab comes back to the lanes" "$(lanes_shown)" 4
keys BTab
until_screen 'SESSIONS'
keys BTab
until_screen 'OPENTIMELINE IS NOT ANSWERING'
keys BTab
until_screen 'QUEUE · 2 TRACKS'
keys Right
until_screen 'ACTIONS ON THE TRACK'
keys BTab
until_screen 'WAITING FOR YOU' && eq "shift-tab cycles backwards through both plugins and leaves the actions menu" "$(lanes_shown)" 4

keys -l alpha; keys Right
until_screen 'ACTIONS ON ALPHA' && keys -l v
eq "right arrow, then v, selects the lane" "$(row alpha | grep -c '●')" 1
lane lab:alpha idle # alpha leaves "who waits for you" for lab's lanes: rows re-sort under the selection
sleep 1.6
eq "the selection follows the lane when rows re-sort" "$(row alpha | grep -c '●') $(row gamma | grep -c '●')" "1 0"
keys -l del
until_screen 'not shown' && eq "selected lanes the search hides are counted" "$(screen | grep -c '1 not shown')" 1
esc
eq "esc empties the search first, the selection stays" "$(screen | grep -c '1 selected')" 1
esc
eq "then the selection" "$(screen | grep -c 'selected')" 0

keys -l alpha; keys Right; keys -l v; keys -l beta; keys C-v
until_screen '● ○ beta' && eq "ctrl-v selects the lane mid-search, and the search stays" "$(screen | grep -c '❯ beta') $(row beta | grep -c '●')" "1 1"
esc
keys -l gamma; keys Right
until_screen 'ACTIONS ON GAMMA' && keys -l m
until_screen 'MOVE 2 LANES TO' && keys -l parked && keys Enter
sleep 0.8
eq "move takes exactly the selection" "$($B list-windows -t '=parked' -F '#W' | sort | tr '\n' ' ')" "alpha beta "
eq "and leaves the rest where it was" "$($B list-windows -t '=lab' -F '#W' | tr '\n' ' ')" "gamma "
eq "and clears the selection" "$(screen | grep -c 'selected')" 0

keys -l gamma; keys C-r # ctrl+letter acts mid-search
$B send-keys -t ui BSpace BSpace BSpace; sleep 0.6; keys -l m2; keys Enter
eq "r renames the tab" "$($B list-windows -t '=lab' -F '#W')" gam2
keys -l parked; n=0; while ! screen | grep -q '▌.*▣ parked' && [ $n -lt 6 ]; do keys C-n; n=$((n + 1)); done; keys Right
until_screen 'ACTIONS ON PARKED' && keys -l r
$B send-keys -t ui BSpace BSpace BSpace BSpace BSpace BSpace; sleep 0.6; keys -l later; keys Enter
eq "r on a workspace renames it" "$($B has-session -t '=later' 2>/dev/null && echo later)" later
keys -l undo
until_screen 'Undo the last move (2 tabs back)' && keys Enter
sleep 0.8
eq "u puts the tabs of the last move back" "$($B list-windows -t '=lab' -F '#W' | sort | tr '\n' ' ')" "alpha beta gam2 "
keys -l up
until_screen 'UP A WORKSPACE' && eq "«up» lists the recipes, with how much of each is up" "$(screen | grep -c 'demo .*uplab · 2 tabs · down')" 1
esc
keys -l 'rename del'
until_screen 'SUGGESTED' && eq "actions are searchable: «rename del» offers renaming delta first" "$(screen | grep '▌' | grep -c 'Rename tab · delta')" 1
esc
D=$($B display -p -t oss:delta '#{pane_id}')
keys -l delta; keys Right; keys -l x
until_screen 'close DELTA' && keys -l y
sleep 0.5
eq "x closes the lane, once you say y" "$($B display -p -t "$D" '#{pane_id}' 2>/dev/null | grep -c .)" 0

# A selection takes the group actions: two lanes picked, ctrl-x closes both after a y.
$B new-window -d -t lab -n eps \; new-window -d -t lab -n zet; lane lab:eps idle; lane lab:zet idle; sleep 1.4
keys -l 'select idle'
until_screen 'Select every idle lane' && eq "«select idle» offers to select every idle lane" "$(screen | grep '▌' | grep -c 'Select every idle lane')" 1
esc
keys -l eps; keys C-v; esc; keys -l zet; keys C-v; esc
keys C-x
until_screen 'close 2 lanes' && keys -l y
sleep 0.8
eq "ctrl-x with two lanes selected closes both, once you say y" "$($B list-windows -t '=lab' -F '#W' | grep -c 'eps\|zet') $(screen | grep -c selected)" "0 0"

# Opened from a lane, the dashboard starts on it; M moves it and takes you along, closing the dashboard.
G=$($B display -p -t lab:gam2 '#{pane_id}')
$B new-session -d -s ui2 -x 150 -y 45 "env TERM=xterm-256color PITWALL_FROM=$G '$BASH_BIN' '$ROOT/bin/pitwall-dash'"
i=0; until $B capture-pane -p -t ui2 | grep -q 'gam2' || [ $i -ge 40 ]; do sleep 0.1; i=$((i + 1)); done; sleep 0.3
eq "opened from a lane, the dashboard starts on it" "$($B capture-pane -p -t ui2 | grep '▌' | grep -c gam2)" 1
$B send-keys -t ui2 Right; sleep 0.4; $B send-keys -t ui2 M; sleep 0.5; $B send-keys -t ui2 -l followed; sleep 0.3; $B send-keys -t ui2 Enter
i=0; while $B has-session -t '=ui2' 2>/dev/null && [ $i -lt 40 ]; do sleep 0.1; i=$((i + 1)); done
eq "M moves the lane and closes the dashboard" "$($B display -p -t "$G" '#{session_name}') $($B has-session -t '=ui2' 2>/dev/null && echo open || echo closed)" "followed closed"
esc
eq "esc with nothing left to undo closes the dashboard" "$($B has-session -t '=ui' 2>/dev/null && echo open || echo closed)" closed

# The shortcut and the palette both use the dashboard. Only the chosen saved session starts.
eq "prefix R opens the dashboard in restore mode" "$($B list-keys -T prefix | awk '$4 == "R" && /pitwall-dash.*--restore/ { n++ } END { print n+0 }')" 1
RECOVERY_STATE=$(mktemp -d); ISOLATED="$ISOLATED $RECOVERY_STATE"
$B set-environment -g XDG_STATE_HOME "$RECOVERY_STATE"
mkdir -p "$RECOVERY_STATE/pitwall/lanes"
SAVED_REPO="$RECOVERY_STATE/saved project"
git init -q -b rescue-main "$SAVED_REPO"
printf 'claude\ts-saved-a\t%s\trescue\t0\talpha\t0\t1\t%s\n' "$SAVED_REPO" "$now" >"$RECOVERY_STATE/pitwall/lanes/s-saved-a"
printf 'codex\ts-saved-b\t/tmp\trescue\t1\tbeta\t0\t1\t%s\n' "$now" >"$RECOVERY_STATE/pitwall/lanes/s-saved-b"
EXISTING=$($B new-session -d -s rescue -n alpha -P -F '#{pane_id}')
$B set -g @pitwall-resume-claude 'echo resumed {id}'
$B new-session -d -s ui -x 150 -y 45 "env TERM=xterm-256color '$BASH_BIN' '$ROOT/bin/pitwall-dash' --restore"
until_screen '▌.*rescue/alpha'
until_screen 'current branch *rescue-main'
keys -l alpha
until_screen 'rescue/beta' absent
keys Enter
until_screen 'yes, restore RESCUE/ALPHA'
eq "opening restore confirmation creates no pane" "$($B list-panes -s -t '=rescue' -F '#{pane_id} #{@pitwall_session}')" "$EXISTING "
esc
until_screen '▌.*rescue/alpha'
until_screen 'rescue/beta' absent
keys Enter; keys y
until_screen 'lane restored'
eq "only the highlighted saved lane starts" "$($B list-panes -s -t '=rescue' -F '#{@pitwall_session}' | awk 'NF') $($B show -gqv @pitwall_restorable)" "s-saved-a 1"
eq "restoring one lane leaves the existing pane alone" "$($B display -p -t "$EXISTING" '#{@pitwall_session}' | awk 'NF') $($B list-panes -t '=rescue:alpha' | wc -l | tr -d ' ')" " 2"
until_screen 'No recoverable lane matches'
keys -l missing
esc
until_screen 'rescue/beta'
esc
until_screen 'WORKSPACES'
keys -l restore
until_screen '▌.*Find a recoverable lane'
keys Enter
until_screen 'rescue/beta'

# Both a lane checkpoint and a plugin import use the same recipient picker and stage a draft.
$B kill-session -t '=ui'
$B run-shell "'$ROOT/bin/pitwall' plugin _index"
printf 'keep the fixture changes\n' >"$SAVED_REPO/changed.txt"
SINK="$RECOVERY_STATE/staged"
cat >"$RECOVERY_STATE/sink.py" <<'PY'
import os
import sys

with open(sys.argv[1], "ab", buffering=0) as destination:
    while True:
        data = os.read(0, 4096)
        if not data:
            break
        destination.write(data)
PY
$B new-session -d -s transfer -n checkpoint-source -c "$SAVED_REPO"
lane transfer:checkpoint-source done
RECIPIENT=$($B new-window -d -P -F '#{pane_id}' -t '=transfer:' -n checkpoint-reader \
  "stty -echo -icanon; exec python3 '$RECOVERY_STATE/sink.py' '$SINK'")
$B set -p -t "$RECIPIENT" @pitwall_state idle \; set -p -t "$RECIPIENT" @pitwall_harness hermes \; set -p -t "$RECIPIENT" @pitwall_session fixture-reader
open_handoff_ui() { $B new-session -d -s ui -x 150 -y 45 "env TERM=xterm-256color '$BASH_BIN' '$ROOT/bin/pitwall-dash'"; }
open_handoff_ui
until_screen 'checkpoint-source'
keys -l checkpoint-source; keys Right
until_screen 'Create a handoff.*h  \^q'
esc
keys -l checkpoint-source
until_screen 'ctrl-q  create handoff'
keys C-q
until_screen 'handoff title'
keys -l 'Spotify playlist context'; keys Enter
until_screen 'handoff note'
keys -l 'Keep the fix and run the check. Decision: https://example.test/events/playlist'
until_screen 'Keep the fix and run the check' && keys Enter
until_screen 'STAGE HANDOFF FOR'
until_screen 'Keep the fix and run the check'
until_screen 'Branch: rescue-main'
until_screen 'changed.txt'
keys -l checkpoint-reader; keys Enter
until_screen 'y  stage draft for transfer/checkpoint-reader'
until_screen 'ctrl-o  open full handoff'
until_screen 'ctrl-g  open source link'
until_screen 'Press Enter there to send it'
eq "reviewing a handoff leaves the destination input alone" "$(wc -c <"$SINK" | tr -d ' ')" 0
$B set -p -t "$RECIPIENT" @pitwall_session fixture-replacement
keys y
until_screen 'the destination changed'
eq "a replacement session receives no draft" "$(wc -c <"$SINK" | tr -d ' ')" 0
keys Enter
until_screen 'leave in Inbox'
$B resize-window -t ui: -x 78 -y 30
until_screen '^─\{78\}$'
keys q
until_screen 'Handoff left in Inbox'
until_screen 'ctrl-z  inbox'
until_screen 'shift-tab  previous'
eq "the queue notice and navigation hints remain readable together" \
  "$(screen | tail -4 | awk '/Handoff left in Inbox/ { notice=1 } /ctrl-z  inbox/ { inbox=1 } /shift-tab  previous/ { previous=1 } END { print (notice && inbox && previous) }')" 1
$B resize-window -t ui: -x 150 -y 45
eq "leaving a handoff in Inbox does not type into the lane" "$(wc -c <"$SINK" | tr -d ' ')" 0
H_ID=$(XDG_STATE_HOME="$RECOVERY_STATE" "$ROOT/bin/pitwall" handoff list | awk 'NR == 1 { print $1 }')
$B kill-window -t '=transfer:checkpoint-source'
$B set -p -t "$RECIPIENT" @pitwall_state working
keys C-z; keys -l checkpoint-reader
until_screen 'HANDOFFS'
until_screen '▌.*transfer/checkpoint-reader.*working'
keys Enter
until_screen 'Keep the fix and run the check'
until_screen 'choose an idle agent'
keys y
eq "reviewing a queued handoff for a busy agent leaves its input alone" "$(wc -c <"$SINK" | tr -d ' ')" 0
esc
$B set -p -t "$RECIPIENT" @pitwall_state idle
until_screen '▌.*transfer/checkpoint-reader.*idle'
keys Enter
until_screen 'y  stage draft for transfer/checkpoint-reader'
keys y
i=0; until grep -q 'Read the handoff file' "$SINK" || [ $i -ge 40 ]; do sleep 0.1; i=$((i + 1)); done
eq "a handoff stages just the saved file reference without Enter" "$(python3 - "$SINK" "$H_ID" <<'PY'
import sys
from pathlib import Path

data = Path(sys.argv[1]).read_bytes()
print(int(bool(sys.argv[2]) and (sys.argv[2] + ".md").encode() in data and b"\r" not in data and b"\n" not in data))
PY
)" 1
eq "staging a queued handoff clears its Inbox mark" "$($B show -pqv -t "$RECIPIENT" @pitwall_handoff)" ''
i=0
while $B has-session -t '=ui' 2>/dev/null && [ "$i" -lt 40 ]; do sleep 0.1; i=$((i + 1)); done
open_handoff_ui
until_screen 'WORKSPACES'
keys -l handoffs; keys Enter
until_screen 'Spotify playlist context'
keys Enter
until_screen 'Keep the fix and run the check'
esc; esc
keys Tab
until_screen 'Road music'
keys -l road; keys Right
until_screen 'Import fixture story.*h  \^q'
esc
keys -l road; keys C-q
until_screen 'STAGE HANDOFF FOR'
until_screen 'The first check passed.'
eq "a plugin handoff is also kept with the native checkpoints" \
  "$(XDG_STATE_HOME="$RECOVERY_STATE" "$ROOT/bin/pitwall" handoff list | grep -c 'Fixture story')" 1
eq "the two handoff paths count completed saves, imports, queues and stages" \
  "$(XDG_STATE_HOME="$RECOVERY_STATE" "$ROOT/bin/pitwall" features | awk '$1 ~ /^handoff-(create|import|queue|stage)$/ { print $1, $4 }')" \
  "$(printf '%s\n' 'handoff-create 1' 'handoff-import 1' 'handoff-queue 1' 'handoff-stage 1')"
eq "the explicit plugin visit and action count once each despite background reads" \
  "$(XDG_STATE_HOME="$RECOVERY_STATE" "$ROOT/bin/pitwall" features | awk '$1 ~ /^plugin\.demo\.(action|view)$/ { print $1, $4 }')" \
  "$(printf '%s\n' 'plugin.demo.action 1' 'plugin.demo.view 1')"
mkdir -p "$RECOVERY_STATE/personal project/nested" "$RECOVERY_STATE/personal project-other" "$RECOVERY_STATE/dotfiles"
$B new-session -d -s scope -n personal -c "$RECOVERY_STATE/personal project/nested"
$B new-window -d -t '=scope:' -n outsider -c "$RECOVERY_STATE/personal project-other"
$B new-window -d -t '=scope:' -n dotfiles -c "$RECOVERY_STATE/dotfiles"
$B new-session -d -s scope-neighbor -n neighbor -c "$RECOVERY_STATE/personal project"
lane scope:personal idle; lane scope:outsider asking; lane scope:dotfiles idle; lane scope-neighbor:neighbor done
SCOPE_SOCKET=$($B display -p '#{socket_path}')
scoped_pitwall() { TMUX="$SCOPE_SOCKET,0,0" XDG_STATE_HOME="$RECOVERY_STATE" "$ROOT/bin/pitwall" "$@"; }
eq "scope intersects an exact workspace and approved directory roots" \
  "$(scoped_pitwall ls --workspace scope --root "$RECOVERY_STATE/personal project" --root "$RECOVERY_STATE/dotfiles" --json |
    python3 -c 'import json,sys; rows=json.load(sys.stdin); assert all(row["session"] == "scope" and row["ref"] == row["id"] for row in rows); print(" ".join(sorted(row["window"] for row in rows)))')" \
  "dotfiles personal"
eq "a missing workspace never falls back to a prefix or the global list" \
  "$(scoped_pitwall ls --workspace scop --json >/dev/null 2>&1 && echo leaked || echo refused)" refused
empty_output=$(scoped_pitwall ls --workspace scope --root "$SAVED_REPO" --json)
eq "a loaded workspace with no matches returns an empty list successfully" "$? $empty_output" '0 []'
HERE_PANE=$($B display -p -t '=scope:personal' '#{pane_id}')
HERE_HANDOFF=$(printf 'Scoped continuation\n' | TMUX_PANE="$HERE_PANE" scoped_pitwall handoff save --here)
eq "save --here uses the invoking pane and local note" \
  "$(scoped_pitwall handoff show "$HERE_HANDOFF" | grep -Ec 'Handoff from scope/personal|Scoped continuation')" 2
$B kill-server

# Find and reopen the same work after the server that created it has stopped.
B="tmux -L pitwall-handoff-reopen-$$"
mkdir -p "$RECOVERY_STATE/test-bin"
cat >"$RECOVERY_STATE/test-bin/open" <<'SH'
#!/bin/sh
printf '%s\n' "$1" >"$XDG_STATE_HOME/opened"
SH
chmod +x "$RECOVERY_STATE/test-bin/open"
SINK="$RECOVERY_STATE/reopened-input"
RECIPIENT=$($B -f /dev/null new-session -d -P -F '#{pane_id}' -s tomorrow -n new-reader \
  "stty -echo -icanon; exec python3 '$RECOVERY_STATE/sink.py' '$SINK'")
$B set-environment -g XDG_STATE_HOME "$RECOVERY_STATE"
$B set -g @pitwall-state-fmt '#{@pitwall_state}' \
  \; set -p -t "$RECIPIENT" @pitwall_state idle \
  \; set -p -t "$RECIPIENT" @pitwall_harness hermes \
  \; set -p -t "$RECIPIENT" @pitwall_session new-reader
$B new-session -d -s ui -x 150 -y 45 \
  "env PATH='$RECOVERY_STATE/test-bin:$PATH' TERM=xterm-256color '$BASH_BIN' '$ROOT/bin/pitwall-dash'"
until_screen 'new-reader'
keys -l 'playlist spotify'
until_screen '▌.*Spotify playlist context'
until_screen '⏎  open handoff'
keys Enter
until_screen 'Saved folder is available'
until_screen 'Keep the fix and run the check'
until_screen 'ctrl-g  open source link'
keys C-g
i=0; until [ -s "$RECOVERY_STATE/opened" ] || [ "$i" -ge 40 ]; do sleep 0.1; i=$((i + 1)); done
eq "opening a handoff decision uses the saved URL" "$(cat "$RECOVERY_STATE/opened")" 'https://example.test/events/playlist'
esc
until_screen '▌.*Spotify playlist context'
mv "$SAVED_REPO" "$RECOVERY_STATE/moved project"
keys Enter
until_screen 'Saved folder is missing'
keys -l new-reader; keys Enter
until_screen 'y  stage draft for tomorrow/new-reader'
eq "search and review in the new server leave the recipient alone" "$(wc -c <"$SINK" | tr -d ' ')" 0
keys y
i=0; until grep -Fq "$H_ID.md" "$SINK" || [ $i -ge 40 ]; do sleep 0.1; i=$((i + 1)); done
eq "the new server stages the original saved checkpoint as a draft" "$(
  python3 -c 'import sys; data=open(sys.argv[1],"rb").read(); print(int((sys.argv[2]+".md").encode() in data and b"\r" not in data and b"\n" not in data))' "$SINK" "$H_ID"
)" 1
eq "explicitly reopening a saved checkpoint counts as feature use" \
  "$(XDG_STATE_HOME="$RECOVERY_STATE" "$ROOT/bin/pitwall" features | awk '$1 == "handoff-open" { print $4 }')" 3
$B kill-server

PREFIX_STATE="$RECOVERY_STATE/prefix-check"
PREFIX_DIR="$PREFIX_STATE/pitwall/handoffs"
mkdir -p "$PREFIX_DIR"
printf 'first checkpoint\n' >"$PREFIX_DIR/a1000000000000000000000000000000.md"
show_prefix() { XDG_STATE_HOME="$PREFIX_STATE" PITWALL_FEATURE_USAGE=off "$ROOT/bin/pitwall" handoff show "$1"; }
eq "show reads a handoff by its unique prefix" "$(show_prefix a1)" "first checkpoint"
printf 'second checkpoint\n' >"$PREFIX_DIR/a1111111111111111111111111111111.md"
short_status=0
short_output=$(show_prefix a1 2>"$PREFIX_STATE/error") || short_status=$?
eq "show rejects a shared prefix without reading either checkpoint" "$short_status $short_output" "1 "
eq "a full ID still selects a checkpoint with a shared prefix" \
  "$(show_prefix a1111111111111111111111111111111)" "second checkpoint"

exit $fail
