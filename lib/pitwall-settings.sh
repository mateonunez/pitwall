# shellcheck shell=sh
SETTINGS=${XDG_CONFIG_HOME:-$HOME/.config}/pitwall/settings

settings_option() {
  case $1 in
    automanaged) option=@pitwall_automanaged ;;
    grouping) option=@pitwall_dash_group ;;
    *) option=@pitwall-$1 ;;
  esac
}

settings_binding() {
  tmux list-keys 2>/dev/null | PITWALL_BINDING="$1" awk '$3 == "prefix" && $4 == ENVIRON["PITWALL_BINDING"] { print; exit }'
}

settings_spec() {
  while IFS="$TAB" read -r name kind default group title help; do
    [ "$name" != "$1" ] || return 0
  done <"$DIR/lib/pitwall-settings.tsv"
  case $1 in
    resume-[a-z0-9]*)
      case ${1#resume-} in *[!a-z0-9_-]*) return 1 ;; esac
      kind=resume default=-
      ;;
    *) return 1 ;;
  esac
}

settings_valid() {
  case $value in *[[:cntrl:]]* | *';') return 1 ;; esac
  case $kind in
    *,*) case ,$kind, in *,"$value",*) [ -n "$value" ] ;; *) return 1 ;; esac ;;
    seconds) case $value in '' | *[!0-9]*) return 1 ;; esac; [ "$value" -le 2147483647 ] ;;
    interval) awk -v v="$value" 'BEGIN { exit !(v ~ /^[0-9]*[.]?[0-9]+$/ && v > 0 && v <= 2147483647) }' ;;
    colour)
      case $value in \#??????) case ${value#\#} in *[!0-9a-fA-F]*) return 1 ;; esac ;; *) return 1 ;; esac ;;
    path) case $value in /*) return 0 ;; *) return 1 ;; esac ;;
    regex) [ -n "$value" ] && { grep -E -e "$value" </dev/null; [ "$?" -eq 1 ]; } ;;
    resume) case $value in -) [ "$default" = - ] ;; *'{id}'*) return 0 ;; *) return 1 ;; esac ;;
    command) [ -n "$value" ] ;;
    key) case $value in '' | -* | *[[:space:]]*) return 1 ;; esac
      tmux bind-key -T pitwall-settings -- "$value" display-message '' || return 1
      canonical=$(tmux list-keys | awk '$3 == "pitwall-settings" { print $4; exit }')
      tmux unbind-key -T pitwall-settings -- "$value" || return 1
      [ -n "$canonical" ] ;;
    *) return 1 ;;
  esac
}

settings_set() {
  if [ "$kind:$value" = resume:- ]; then tmux set -gu "$option"
  else tmux set -g -- "$option" "$value"; fi
}

settings_apply() {
  case $key in
    key-* | layout | tab-caps | color-* | rename | agents)
      # Run directly on this socket. The loader reads overrides again and rebuilds its own formats.
      "$DIR/pitwall.tmux" ;;
    quota | codexbar)
      tmux set -gu @pitwall_quota \; set -gu @pitwall_quota_plain \; set -gu @pitwall_quota_data \; set -gu @pitwall_quota_at
      tmux run-shell -b "'$DIR/bin/pitwall' quota --refresh" ;;
    system)
      [ "$value" != off ] || tmux set -gu @pitwall_sys_hist \; set -gu @pitwall_system \; set -gu @pitwall_system_short ;;
    idle-after) tmux run-shell -b "'$DIR/bin/pitwall' _route" ;;
    automanaged)
      [ "$value" != on ] || tmux run-shell -b "'$DIR/bin/pitwall' _route" ;;
  esac
}

cmd_settings() (
  case ${1:-} in
    _load)
      for file in "$SETTINGS/"*; do
        [ -f "$file" ] || continue
        key=${file##*/}
        settings_spec "$key" || continue
        case $kind in file | profile) continue ;; esac
        IFS= read -r value <"$file" || continue
        settings_valid || continue
        settings_option "$key"
        settings_set
      done
      return 0 ;;
    _profiles)
      tmux show -g | awk '$1 ~ /^@pitwall-resume-[a-z0-9_-]+$/ { sub(/^@pitwall-resume-/, "", $1); print $1 }'
      return ;;
    _values | '')
      list_only=${1:+yes}
      set --
      while IFS="$TAB" read -r key kind default group title help; do
        case $kind in file | profile) continue ;; esac
        settings_option "$key"
        set -- "$@" \; display -p "#{${option}}"
      done <"$DIR/lib/pitwall-settings.tsv"
      shift
      if [ -n "$list_only" ]; then tmux "$@"
      else
        tmux "$@" | awk -F '\t' '
          NR == FNR { if ($2 != "file" && $2 != "profile") { key[++n] = $1; def[n] = $3 } next }
          { ++i; print key[i], (length($0) ? $0 : def[i]) }
        ' "$DIR/lib/pitwall-settings.tsv" -
      fi
      return ;;
  esac

  key=$1
  settings_spec "$key" || { echo "Unknown setting: $key" >&2; return 1; }
  settings_option "$key"
  if [ "$#" -eq 1 ]; then
    value=$(tmux show -gqv "$option")
    printf '%s\n' "${value:-$default}"
    return
  fi
  value=$2
  tmux wait-for -L pitwall-settings || return 1
  temp=''
  trap '[ -z "$temp" ] || rm -f "$temp"; tmux wait-for -U pitwall-settings 2>/dev/null' EXIT
  trap 'exit 1' HUP INT TERM
  settings_valid || { echo "Enter a valid $kind value." >&2; return 1; }
  if [ "$kind" = key ]; then
    value=$canonical
    binding=$(settings_binding "$value")
    case $binding in
      '') ;;
      *"$DIR/bin/pitwall"*)
        used=$(tmux show -gqv "@pitwall_bound_${key#key-}")
        [ "$value" = "$used" ] || { echo 'That prefix key already has a binding.' >&2; return 1; } ;;
      *) echo 'That prefix key already has a binding.' >&2; return 1 ;;
    esac
  fi
  mkdir -p "$SETTINGS"
  [ ! -d "$SETTINGS/$key" ] || { echo 'The settings file is a directory.' >&2; return 1; }
  temp=$(mktemp "$SETTINGS/.setting.XXXXXX")
  printf '%s\n' "$value" >"$temp"
  mv -f "$temp" "$SETTINGS/$key"
  settings_set
  settings_apply
)
