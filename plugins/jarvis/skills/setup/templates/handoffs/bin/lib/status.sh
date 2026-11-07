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
  local b line id brief ho ids="" n=0 changed claimed unclaimed
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
  printf 'OPEN.md: %s question(s) for the user · %s to-do\n' "$q" "$n"
  watch_running || echo "watcher: not running — start it: handoffs/bin/jarvis watch --start"
  cmd_leftovers --quiet
  cmd_doctor --quiet
}
