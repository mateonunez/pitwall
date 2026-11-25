# Local counts of explicit feature use. Looping hooks and background refreshes do not write to this directory.
FEATURE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/pitwall/features
FEATURE_CATALOG='answer branch-diff close-lane copy-resume dashboard diff favorite handoff-create handoff-import handoff-list handoff-open handoff-queue handoff-stage inbox interrupt lane-list lane-stats mark-read move new-agent new-worktree next open-lazygit open-nvim open-pr page-navigation read-output rename-lane restart-lane restore restore-picker search search-output select-lanes send undo-move usage visit-lane visit-workspace workspace-close workspace-create workspace-recipe-run workspace-recipe-save workspace-rename worktree-done'

feature_use() (
  [ "${PITWALL_FEATURE_USAGE:-on}" != off ] || return 0
  case $1 in '' | -* | *[!a-z0-9-]*) return 0 ;; esac
  if [ "$#" -eq 2 ]; then
    [ "${#1}" -le 64 ] || return 0
    case $2 in view | action | command) ;; *) return 0 ;; esac
    feature=plugin.$1.$2
  else
    case " $FEATURE_CATALOG " in *" $1 "*) feature=$1 ;; *) return 0 ;; esac
  fi
  now_epoch=$(date -u +%s) || return 0
  umask 077
  [ -d "$FEATURE_DIR" ] || mkdir -p "$FEATURE_DIR" || return 0
  printf '%s\n' "$feature" >>"$FEATURE_DIR/$((now_epoch / 86400)).log"
) 2>/dev/null || true

feature_report() (
  [ "$#" -eq 0 ] || { echo "usage: pitwall features" >&2; return 1; }
  today=$(date -u +%s) || return 1
  set --
  for file in "$FEATURE_DIR"/*.log; do [ -f "$file" ] && [ -r "$file" ] && set -- "$@" "$file"; done
  printf '%-35s %8s %8s %8s\n' FEATURE '7 DAYS' '30 DAYS' TOTAL
  LC_ALL=C FEATURE_INDEX="$PINDEX" awk -v catalog="$FEATURE_CATALOG" -v today="$((today / 86400))" '
    function plugin(id) { return id ~ /^[a-z0-9][a-z0-9-]*$/ && length(id) <= 64 }
    BEGIN {
      index_file = ENVIRON["FEATURE_INDEX"]
      n = split(catalog, names, " ")
      for (i = 1; i <= n; i++) known[names[i]] = 1
      while ((getline line < index_file) > 0) {
        split(line, p, "\t")
        if (!plugin(p[1])) continue
        if (p[5] != "" && p[5] != "-") {
          known["plugin." p[1] ".view"] = 1
          known["plugin." p[1] ".action"] = 1
        }
        if (p[6] != "" && p[6] != "-") known["plugin." p[1] ".command"] = 1
      }
      close(index_file)
    }
    FNR == 1 {
      day = FILENAME
      sub(/^.*\//, "", day)
      sub(/\.log$/, "", day)
      valid = (day ~ /^[0-9]+$/ && day + 0 <= today)
      age = today - day
    }
    valid && (($0 in known) || ($0 ~ /^plugin\.[a-z0-9][a-z0-9-]*\.(view|action|command)$/ && length($0) <= 79)) {
      total[$0]++
      if (age < 7) week[$0]++
      if (age < 30) month[$0]++
    }
    END {
      for (f in total) known[f] = 1
      for (f in known) printf "%-35s %8d %8d %8d\n", f, week[f], month[f], total[f]
    }
  ' "$@" </dev/null | LC_ALL=C sort -k3,3nr -k4,4nr -k1,1
)
