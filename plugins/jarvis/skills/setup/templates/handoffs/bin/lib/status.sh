# shellcheck shell=bash
# Sourced by bin/jarvis; not run on its own.
# ---------------------------------------------------------------- start / status

cmd_start() {
  local me old
  [ -f "$OPEN" ] || die "no $OPEN — run jarvis:setup first"
  need_host
  me=$(host self)
  [ -n "$me" ] || die "host $HOST gives no id for this terminal — run Jarvis in a Superset terminal, an Ultron session or a tmux pane"
  old=$(jarvis_terminal)
  if [ -n "$old" ] && [ "$old" != "$me" ] && [ "${1:-}" != --force ] \
     && host list | grep -qxF "$old"; then
    die "another Jarvis ($old) is still open — ask the user, then: jarvis start --force"
  fi
  open_set "Jarvis session" "$me"
  mkdir -p "$STATE"
  cmd_status
}

cmd_status() {
  local b line id brief ho ids="" n=0 changed claimed unclaimed sz
  [ -f "$OPEN" ] || die "no $OPEN — run jarvis:setup first"

  b=$(band)
  printf 'band: %s\n' "$(printf '%s' "$b" | tr '\t' ' ' | sed 's/ /: /')"
  case "$(printf '%s' "$b" | cut -f1)" in
    green|amber|red) open_set "Usage band" "$(printf '%s' "$b" | cut -f1) ($(printf '%s' "$b" | cut -f2 | cut -d, -f1), $(date +%H:%M))" ;;
  esac

  # every active Claude session on the machine, from Claude Code's session records
  cap_counts
  printf 'claude sessions: %s\n' "$(cap_summary)"
  fable_status
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$((n + 1))
    id=$(printf '%s' "$line" | sed -n 's/.*term \([^ ]*\).*/\1/p')
    brief=$(printf '%s' "$line" | grep -o "$H/briefs/[^ ]*\.md" | head -n 1)
    ho=""
    [ -n "$brief" ] && ho=$(grep -l "^brief:[[:space:]]*$brief" "$H"/*.md 2>/dev/null | head -n 1)
    printf '  %s %s %s' "$(short "$id")" "$(printf '%s' "$line" | awk -F' · ' '{print $2}')" "$(basename "${brief:-?}" .md)"
    if [ -n "$ho" ]; then printf '  → %s (%s)\n' "$ho" "$(field status "$ho")"; else echo; fi
    run_ok "$id" && [ -f "$RUNS/$id" ] && printf '      budget: %s\n' "$(budget_line "$id")"
    [ -n "$id" ] && [ -z "$ho" ] && ids="$ids $id"
  done <<EOF
$(running_lines)
EOF
  [ $n = 0 ] && echo "  no workers running"

  if [ -n "$ids" ]; then
    echo "workers still at it:"
    if [ -x "$BIN/jev.sh" ]; then
      # shellcheck disable=SC2086
      "$BIN/jev.sh" triage $ids 2>/dev/null | sed 's/^/  /'
    else
      for id in $ids; do
        printf '  %s\n' "$(short "$id")"
        host read "$id" 40 | sed -e 's/[[:space:]]*$//' | grep -v '^$' | tail -n 4 | sed 's/^/      /'
      done
    fi
  fi

  # handoffs on disk that no running worker accounts for
  for ho in "$H"/*.md; do
    [ -f "$ho" ] || continue
    case "$(basename "$ho")" in OPEN.md|TEMPLATE.md|JARVIS.md) continue ;; esac
    brief=$(field brief "$ho")
    running_lines | grep -q "${brief:-@@none@@}" && continue
    echo "handoff not tied to a running worker: $ho ($(field status "$ho"))"
  done

  changed=$(git status --porcelain -uall 2>/dev/null | grep -v " $H/" | wc -l | tr -d ' ')
  claimed=0
  for ho in "$H"/*.md; do [ -f "$ho" ] && claimed=$((claimed + $(listed_files "$ho" | wc -l))); done
  unclaimed=$((changed - claimed)); [ $unclaimed -lt 0 ] && unclaimed=0
  printf 'git: %s changed outside handoffs/ · about %s not in any handoff yet · %s\n' \
    "$changed" "$unclaimed" "$(git log -1 --format='last commit %h %ar' 2>/dev/null)"
  n=$(awk '/^## /{on = ($0 ~ /^## To-do/); next} on && /^- /' "$OPEN" | wc -l | tr -d ' ')
  q=$(awk '/^## /{on = ($0 ~ /^## Questions for the user/); next} on && /^- /' "$OPEN" | wc -l | tr -d ' ')
  sz=$(wc -c < "$OPEN" | tr -d ' ')
  printf 'OPEN.md: %s question(s) for the user · %s to-do · %s KB\n' "$q" "$n" "$(( (sz + 512) / 1024 ))"
  open_checks "$sz"
  watch_running || echo "watcher: not running — start it: handoffs/bin/jarvis watch --start"
  cmd_leftovers --quiet
  cmd_doctor --quiet
}

open_checks() { # $1 = OPEN.md's size in bytes; one line per check that fires, nothing when clean
  local n=0 no text name merged
  [ "$1" -gt $((JARVIS_OPEN_MAX_KB * 1024)) ] && printf 'OPEN.md is %s KB (limit %s): move finished notes to jarvis log; one line per item\n' \
    "$(( ($1 + 512) / 1024 ))" "$JARVIS_OPEN_MAX_KB"
  awk '/^## /{t = $0; sub(/[[:space:]]+$/, "", t)
    if (t != "## Questions for the user" && t != "## Running workers" && t != "## Waiting on Jarvis" && t != "## To-do")
      printf "OPEN.md has a section that belongs in the log: \"%s\"\n", t}' "$OPEN"
  n=$(awk '/^## /{on = ($0 ~ /^## To-do/); next} on && /^- / && length($0) > 300' "$OPEN" | wc -l | tr -d ' ')
  [ "$n" = 1 ] && echo "1 to-do line over 300 characters"
  [ "$n" -gt 1 ] && echo "$n to-do lines over 300 characters"
  # a To-do or Waiting-on-Jarvis line still naming a brief or handoff that's merged
  # shellcheck disable=SC2016 # the backticks are literal: a brief field may be `quoted`
  merged=$(sed -n 's/^brief:[[:space:]]*`\{0,1\}\([^[:space:]`]*\).*/\1/p' "$H"/merged/*.md 2>/dev/null)
  n=0
  while IFS="$TAB" read -r no text; do
    for name in $(printf '%s' "$text" | grep -oE "$H/(briefs/)?[A-Za-z0-9._-]+\.md"); do
      case "$name" in
        "$H"/briefs/*) printf '%s\n' "$merged" | grep -qxF "$name" || continue ;;
        *) [ ! -e "$name" ] && [ -f "$H/merged/${name#"$H"/}" ] || continue ;;
      esac
      n=$((n + 1)); [ $n -le 5 ] && echo "OPEN.md line $no names $name, already merged"
      break
    done
  done <<EOF
$(awk '/^## /{on = ($0 ~ /^## (To-do|Waiting on Jarvis)/); next} on && /^- / {print NR "\t" $0}' "$OPEN")
EOF
  [ $n -gt 5 ] && echo "… and $((n - 5)) more"
  return 0
}

cmd_log() { # jarvis log "<text>": one line on this month's log; the text is data, written as given
  local now month f
  [ -n "$*" ] || die "usage: jarvis log '<text>'"
  now=$(date '+%Y-%m-%d %H:%M'); month=$(printf '%s' "$now" | cut -c1-7)
  f="$H/log/$month.md"
  mkdir -p "$H/log" || die "can't make $H/log"
  [ -f "$f" ] || printf '# Jarvis log %s\n\n' "$month" > "$f"
  printf -- '- %s · %s\n' "$now" "$(printf '%s' "$*" | tr '\n\r' '  ')" >> "$f" || die "can't write $f"
  echo "logged: $f"
}
