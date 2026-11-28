# shellcheck shell=sh
DRAFT_ID='#{pane_pid}:#{@pitwall_session}'
DRAFT_KIND="#{&&:#{==:#{E:@pitwall-state-fmt},idle},#{==:#{@pitwall_input_draft},$DRAFT_ID}}"
DRAFT_TABS="#{m:*x*,#{P:#{?$DRAFT_KIND,x,}}}"
MANAGED_BUCKETS='needs-you working draft review idle'
EMPTY_PANE='#{&&:#{@pitwall_empty_pid},#{==:#{@pitwall_empty_pid},#{pane_pid}}}'
EMPTY_WINDOW="#{&&:#{==:#{window_panes},1},$EMPTY_PANE}"
WORKSPACE_WINDOWS="#{n:#{W:#{?$EMPTY_WINDOW,,x}}}"
EMPTY_COMMAND="printf '\\r\\n  No agent tabs in this workspace yet.\\r\\n'; exec sleep 2147483647"
HERMES_TITLE='#{m/r:^hermes( |$),#{pane_title}}'

# Inspect the visible prompt and its continuation rows. The pane option stores an identity, never the input.
pane_has_draft() {
  start=$(($2 - 7))
  [ "$start" -ge 0 ] || start=0
  tmux capture-pane -pe -t "$3" -S "$start" -E "$2" 2>/dev/null |
    awk -v prompt="$1" '
      { gsub(/ /, " "); line[NR] = $0 }
      END {
        for (i = NR; i > 0; i--) {
          text = line[i]
          gsub(/\033\[[0-9;]*m/, "", text)
          continuation = text ~ /^  /
          sub(/^ */, "", text)
          if (index(text, prompt " ") == 1) break
          if (!continuation || text !~ /[^[:space:]]/) exit 1
        }
        if (i == 0) exit 1
        sub("^" prompt " *", "", text)
        if (i == NR && text !~ /[^[:space:]]/) exit 1
        body = substr(line[i], index(line[i], prompt) + length(prompt))
        sub(/^ */, "", body)
        while (match(body, /^\033\[[0-9;]*m/)) {
          sgr = substr(body, 3, RLENGTH - 3)
          if (sgr == "2" || sgr == "3") dim = 1
          if (sgr == "0" || sgr == "22" || sgr == "23") dim = 0
          body = substr(body, RLENGTH + 1)
          sub(/^ */, "", body)
        }
        exit (dim ? 1 : 0)
      }
    '
}

scan_window_drafts() {
  tmux list-panes -t "$1" -F "#{pane_id}$TAB$DRAFT_ID$TAB#{?#{@pitwall_harness},#{@pitwall_harness},#{?#{==:#{pane_current_command},codex},codex,#{?#{m/r:^(claude|[0-9.]+)$,#{pane_current_command}},claude,#{?$HERMES_TITLE,hermes,-}}}}$TAB#{cursor_y}$TAB#{pane_in_mode}$TAB#{?$DRAFT_KIND,1,0}" |
    while IFS="$TAB" read -r pane identity harness y mode marked; do
      [ "$mode" = 0 ] || continue
      case $harness in codex) prompt=› ;; claude | hermes) prompt=❯ ;; *) continue ;; esac
      case $identity in *[!A-Za-z0-9:_.-]*) continue ;; esac
      guard="#{==:$DRAFT_ID,$identity}"
      if pane_has_draft "$prompt" "$y" "$pane"; then
        [ "$marked" = 1 ] || tmux if-shell -F -t "$pane" "$guard" "set -p -t '$pane' @pitwall_input_draft '$identity'"
      elif [ "$marked" = 1 ]; then
        tmux if-shell -F -t "$pane" "$guard" "set -pu -t '$pane' @pitwall_input_draft"
      fi
    done
}

# Move whole agent tabs only, and defer while a client can see the tab.
ROUTE_AGENT="#{||:#{m/r:#{@pitwall_agent_regex},#{pane_current_command}},#{&&:#{||:#{@pitwall_session},$HERMES_TITLE},#{?#{m/r:^(-?(sh|bash|dash|zsh|fish|ksh|csh|tcsh)|login)\$,#{pane_current_command}},0,1}}}"
ROUTE_LANES="#{?#{m:*-*,#{P:#{?#{&&:#{?pane_dead,0,1},#{&&:$ROUTE_AGENT,#{m/r:^(asking|done|working|idle)$,#{E:@pitwall-state-fmt}}}},x,-}}},0,1}"
ROUTE_BUCKET="#{?#{==:#{E:@pitwall-window-fmt},asking},needs-you,#{?#{==:#{E:@pitwall-window-fmt},done},review,#{?#{&&:#{==:#{E:@pitwall-window-fmt},idle},$DRAFT_TABS},draft,#{E:@pitwall-window-fmt}}}}"
ROUTE_READY="#{?#{window_id},#{&&:#{==:#{@pitwall_automanaged},on},#{&&:$ROUTE_LANES,#{?#{||:#{window_linked},#{&&:#{session_attached},#{window_active}}},0,1}}},0}"
ROUTE_NEEDED="#{&&:$ROUTE_READY,#{!=:#{@pitwall_managed_bucket},$ROUTE_BUCKET}}"

create_bucket() (
  bucket=$1 dest=$1 n=1
  while tmux has-session -t "=$dest" 2>/dev/null; do
    if [ "$n" -eq 1 ]; then dest=pitwall-$bucket; else dest=pitwall-$bucket-$n; fi
    n=$((n + 1))
  done
  pane=$(tmux new-session -dPs "$dest" -F '#{pane_id}' -n empty "$EMPTY_COMMAND") || return 1
  tmux set -t "$pane" @pitwall_managed_bucket "$bucket" \; set -pF -t "$pane" @pitwall_empty_pid '#{pane_pid}'
  tmux display -p -t "$pane" '#{session_id}'
)

prune_empty() {
  tmux list-panes -s -t "$1" -f "$EMPTY_PANE" -F '#{pane_id}' |
    while IFS= read -r pane; do
      tmux if-shell -F -t "$pane" "#{&&:$EMPTY_PANE,#{?window_linked,0,#{||:#{>:#{session_windows},1},#{>:#{window_panes},1}}}}" \
        "kill-pane -t '$pane'" 2>/dev/null || true
    done
}

route_window() (
  win=$1
  snapshot=$(tmux display -p -t "$win" "#{?$ROUTE_READY,#{E:@pitwall-window-fmt} #{window_activity} #{?#{@pitwall_idle_due},#{@pitwall_idle_due},0} #{?#{@pitwall_managed_bucket},#{@pitwall_managed_bucket},-} #{session_id} #{session_windows} #{@pitwall_managed_index},}" 2>/dev/null)
  [ -n "$snapshot" ] || return 0
  read -r state activity pending current source_id source_windows origin_index <<EOF
$snapshot
EOF
  case $origin_index in
    '' | *@*) ;;
    *) tmux set -wF -t "$win" @pitwall_managed_index '#{@pitwall_managed_index}#{window_id}' && follow "$win" ;;
  esac
  if [ "$state" = idle ]; then
    scan_window_drafts "$win"
  fi
  base=$(tmux display -p -t "$win" "$ROUTE_BUCKET")
  bucket=$base
  idle_guard=1
  case $bucket in
    idle)
      # A single tmux timer per quiet window. Subsequent activity is checked at the deadline.
      due=$((activity + idle_after))
      if [ "$current" != idle ] && [ "$due" -gt "$route_now" ]; then
        bucket=review
        if [ "$pending" -le "$route_now" ] || [ "$pending" -gt "$due" ]; then
          tmux set -w -t "$win" @pitwall_idle_due "$due" \; run-shell -b -d "$((due - route_now))" "'$DIR/bin/pitwall' _route '$win'"
        fi
      else
        idle_guard="#{==:#{window_activity},$activity}"
      fi ;;
    working | needs-you | review | draft) ;;
    *) return 0 ;;
  esac
  if [ "$bucket" = "$current" ]; then
    [ "$source_windows" -le 1 ] || prune_empty "$source_id"
    return 0
  fi

  dest_id=$(tmux list-sessions -f "#{==:#{@pitwall_managed_bucket},$bucket}" -F '#{session_id}' | head -n 1)
  [ -n "$dest_id" ] || dest_id=$(create_bucket "$bucket") || return 0
  # A tmux session needs a window even after its last agent tab moves away.
  if [ "$current" != - ] && [ "$source_windows" = 1 ]; then
    pane=$(tmux new-window -dP -t "$source_id:" -F '#{pane_id}' -n empty "$EMPTY_COMMAND") || return 0
    tmux set -pF -t "$pane" @pitwall_empty_pid '#{pane_pid}'
  fi

  # Keep the original index and the window ID, since the source can reuse that index after the move.
  home='#{?#{@pitwall_managed_workspace},#{@pitwall_managed_workspace},#{session_name}}'
  guard="#{?$ROUTE_READY,#{&&:#{==:$ROUTE_BUCKET,$base},$idle_guard},0}"
  tmux if-shell -F -t "$win" "$guard" \
    "if-shell -F -t '$win' '#{?@pitwall_managed_origin,0,1}' { set -wF -t '$win' @pitwall_managed_index '#{window_index}#{window_id}'; set -wF -t '$win' @pitwall_managed_origin '$home' }; move-window -d -s '$win' -t '$dest_id:'" 2>/dev/null || true
  if [ "$(tmux display -p -t "$win" '#{session_id}' 2>/dev/null)" = "$dest_id" ]; then
    [ -n "$origin_index" ] || follow "$win"
    prune_empty "$dest_id"
  elif [ "$current" != - ]; then
    prune_empty "$source_id"
  fi
)

route_lock() {
  tmux wait-for -L pitwall-route || return 1
  trap 'tmux wait-for -U pitwall-route 2>/dev/null || true' EXIT
  trap 'exit 1' HUP INT TERM
}

cmd_route() (
  [ "$(tmux show -gqv @pitwall_automanaged)" = on ] || return 0
  route_lock || return 0
  idle_after=$(tmux show -gqv @pitwall-idle-after)
  case $idle_after in '' | *[!0-9]*) idle_after=900 ;; esac
  [ "$idle_after" -le 2147483647 ] 2>/dev/null || idle_after=900
  idle_after=$(printf '%s' "$idle_after" | sed 's/^0*//')
  idle_after=${idle_after:-0}
  route_now=$(date +%s)
  if [ "$#" -eq 0 ]; then
    buckets=$(tmux list-sessions -F '#{@pitwall_managed_bucket}' | tr '\n' ' ')
    for bucket in $MANAGED_BUCKETS; do
      case " $buckets " in *" $bucket "*) ;; *) create_bucket "$bucket" >/dev/null ;; esac
    done
    # shellcheck disable=SC2046 # one tmux window id per word
    set -- $(tmux list-windows -a -f "$ROUTE_READY" -F '#{window_id}')
  fi
  for win do
    case $win in @*) case ${win#@} in '' | *[!0-9]*) continue ;; esac ;; *) continue ;; esac
    route_window "$win"
  done
)

# Recipe membership follows the original workspace while a tab is routed.
workspace_windows() {
  tmux list-windows -a -f "#{?$EMPTY_WINDOW,0,1}" -F "#{session_name}$TAB#{@pitwall_managed_origin}$TAB#{window_id}$TAB#{window_name}" |
    PITWALL_HOME_WORKSPACE=$1 awk -F '\t' -v field="$2" '
      ($1 == ENVIRON["PITWALL_HOME_WORKSPACE"] || $2 == ENVIRON["PITWALL_HOME_WORKSPACE"]) && !seen[$3]++ {print $field}'
}

cmd_label() (
  action=$1 label=$2
  shift 2
  case $action in add | remove) ;; *) return 1 ;; esac
  case $label in '' | *[!a-z0-9_-]*) echo 'Use lowercase letters, digits, - or _ in a label' >&2; return 1 ;; esac
  [ "${#label}" -le 32 ] || { echo 'Labels can be up to 32 characters' >&2; return 1; }
  mkdir -p "$STATE/labels"
  tmux wait-for -L pitwall-labels
  trap 'tmux wait-for -U pitwall-labels 2>/dev/null || true' EXIT
  trap 'exit 1' HUP INT TERM
  # The dashboard supplies a snapshot of the pane's identity. Validate every target before editing.
  files=''
  for recipient do
    pane=${recipient%%:*}
    expected=${recipient#*:}
    case $pane in %*) case ${pane#%} in '' | *[!0-9]*) return 1 ;; esac ;; *) return 1 ;; esac
    key=$(tmux display -p -t "$pane" '#{@pitwall_harness}:#{@pitwall_session}' 2>/dev/null)
    case $key in :* | *: | *[!A-Za-z0-9:_.-]*) echo 'The lane needs a saved agent session' >&2; return 1 ;; esac
    [ "$key" = "$expected" ] || { echo 'The agent session changed' >&2; return 1; }
    case " $files " in *" $key "*) ;; *) files="$files $key" ;; esac
  done
  for key in $files; do
    path=$STATE/labels/$key
    temp=$(mktemp "$STATE/labels/.labels.XXXXXX")
    { if [ -f "$path" ]; then awk -v word="$label" '$0 != word' "$path"; fi
      if [ "$action" = add ]; then echo "$label"; fi; } | LC_ALL=C sort -u >"$temp"
    mv -f "$temp" "$path"
  done
  printf 'Label %s %s\n' "$label" "$( [ "$action" = add ] && echo added || echo removed )"
)

cmd_plan() (
  action=${1:-list} name=${2:-}
  case $action in
    list)
      for f in "$STATE/planned/"*; do [ ! -f "$f" ] || printf '%s\n' "${f##*/}"; done
      return 0 ;;
    add | drop | start) ;;
    *) return 1 ;;
  esac
  case $name in '' | .* | */* | *[[:cntrl:]]*) echo 'Use a saved recipe name' >&2; return 1 ;; esac
  plan_entry=$STATE/planned/$name
  if [ "$action" != drop ]; then
    recipe=$(up_list --plain | PITWALL_RECIPE_NAME=$name awk -F '\t' '$1 == ENVIRON["PITWALL_RECIPE_NAME"] { if (++n == 1) path = $5 } END { if (n == 1) print path }')
    [ -n "$recipe" ] || return 1
  fi
  case $action in
    add) mkdir -p "$STATE/planned"; : >"$plan_entry"; echo "Planned $name" ;;
    drop) rm -f -- "$plan_entry" ;;
    start) [ -f "$plan_entry" ] || return 1; cmd_up "$recipe"; rm -f -- "$plan_entry" ;;
  esac
)
