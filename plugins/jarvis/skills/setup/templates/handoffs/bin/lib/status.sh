# shellcheck shell=bash
# Sourced by bin/jarvis; not run on its own.
# ---------------------------------------------------------------- start / status

cmd_start() {
  local me old who=""
  [ -f "$OPEN" ] || [ -z "$TEAM_CONF" ] || open_new || die "can't write $OPEN"
  [ -f "$OPEN" ] || die "no $OPEN — run jarvis:setup first"
  need_host
  # a non-Claude Jarvis: OPEN.md names its agent and model after the terminal id; Claude
  # Code here would be a second Jarvis the config doesn't run
  if ! lead_is_claude; then
    [ -z "${CLAUDECODE:-}" ] || [ "${1:-}" = --force ] \
      || die "$H/jarvis.conf runs Jarvis on $(lead_agent) (JARVIS_LEAD_AGENT=$(lead_agent)) and this is Claude Code: the user starts Jarvis with handoffs/bin/jarvis lead. jarvis start --force claims this terminal anyway"
    who=" · $(lead_agent)/$(lead_model)"
    [ -z "${JARVIS_LEAD_LAUNCHED_AGENT:-}" ] || [ "$JARVIS_LEAD_LAUNCHED_AGENT" = "$(lead_agent)" ] \
      || echo "jarvis: this Jarvis was started as $JARVIS_LEAD_LAUNCHED_AGENT, and $H/jarvis.conf now says $(lead_agent): the user restarts it with handoffs/bin/jarvis lead" >&2
  fi
  me=$(host self)
  [ -n "$me" ] || die "host $HOST gives no id for this terminal — run Jarvis in a Superset terminal, an Ultron session or a tmux pane"
  old=$(jarvis_terminal)
  if [ -n "$old" ] && [ "$old" != "$me" ] && [ "${1:-}" != --force ] \
     && host list | grep -qxF "$old"; then
    die "another Jarvis ($old) is still open — ask the user, then: jarvis start --force"
  fi
  open_set "Jarvis session" "$me$who"
  mkdir -p "$STATE"
  cmd_status
}

cmd_status() {
  local b line id brief ho ids="" n=0 changed claimed unclaimed sz
  [ -f "$OPEN" ] || [ -z "$TEAM_CONF" ] || die "no $OPEN — run jarvis start, which makes it"
  [ -f "$OPEN" ] || die "no $OPEN — run jarvis:setup first"
  [ -z "$TEAM_CONF" ] || team_line

  b=$(band)
  printf 'band: %s\n' "$(printf '%s' "$b" | tr '\t' ' ' | sed 's/ /: /')"
  case "$(printf '%s' "$b" | cut -f1)" in
    green|amber|red) open_set "Usage band" "$(printf '%s' "$b" | cut -f1) ($(printf '%s' "$b" | cut -f2 | cut -d, -f1), $(date +%H:%M))" ;;
  esac

  # every active Claude session on the machine, from Claude Code's session records
  cap_counts
  printf 'claude sessions: %s\n' "$(cap_summary)"
  lead_status
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
    case "$(basename "$ho")" in OPEN.md|OPEN.*.md|OPEN-*.md|TEMPLATE.md|JARVIS.md|LESSONS.md) continue ;; esac
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
  printf '%s: %s question(s) for the user · %s to-do · %s KB\n' "${OPEN##*/}" "$q" "$n" "$(( (sz + 512) / 1024 ))"
  open_checks "$sz"
  lessons_hint
  models_status_line
  watch_running || echo "watcher: not running — start it: handoffs/bin/jarvis watch --start"
  cmd_leftovers --quiet
  cmd_doctor --quiet
}

# A non-Claude Jarvis: its model and idle time, whether the watcher can clear it, and
# loudly, a quota error its screen or its hooks showed (lead-limit, written by the
# watcher or jarvis hook lead). A Claude Jarvis: nothing.
lead_status() {
  local a m e t idle why launched
  case "${JARVIS_LEAD_AGENT:-claude}" in
    claude) return 0 ;;
    agy|codex|opencode) ;;
    *) echo "JARVIS_LEAD_AGENT=$JARVIS_LEAD_AGENT is not claude, agy, codex or opencode: Jarvis is treated as Claude, and jarvis lead won't start it"; return 0 ;;
  esac
  a=$(lead_agent); m=$(lead_model); e=$(lead_effort)
  idle=$(jarvis_idle_min)
  printf 'jarvis: %s/%s%s · not counted toward the Claude caps%s\n' "$a" "${m:-(no model)}" "${e:+ $e}" "${idle:+ · idle $idle min}"
  why=$(lead_validate) || echo "jarvis: $why"
  launched=$(rec_get "$STATE/lead.launch" agent)
  [ -z "$launched" ] || [ "$launched" = "$a" ] \
    || echo "jarvis: the running Jarvis was started on $launched; $H/jarvis.conf now says $a — the user restarts it with handoffs/bin/jarvis lead"
  case "$(lead_get reset)" in
    requested) echo "jarvis: the watcher sent it $(lead_attr CLEAR) and waits for a new session to confirm it: no clear until then" ;;
    unconfirmed) echo "jarvis: reset unconfirmed: after $(lead_attr CLEAR) its turns still came from the old session, so the watcher won't clear it again until jarvis lead restarts it" ;;
    *) [ -n "$idle" ] || echo "jarvis: idle unknown; automatic clear disabled until turn signals arrive" ;;
  esac
  [ "$(lead_get prompt)" != pending ] || echo "jarvis: the prompt after the watcher's clear hasn't reached it yet; the watcher sends it again"
  [ -f "$STATE/lead-limit" ] || return 0
  t=$(rec_get "$STATE/lead-limit" t)
  printf 'JARVIS IS LIMITED: its %s showed "%s" at %s (%s/%s). %s\n' \
    "$(rec_get "$STATE/lead-limit" source)" "$(rec_get "$STATE/lead-limit" text)" \
    "$(date -r "${t:-0}" +%H:%M 2>/dev/null || date -d "@${t:-0}" +%H:%M 2>/dev/null)" "$a" "${m:-?}" "$(lead_attr ADVICE)"
}

# jarvis lead [--print] [--force]: Jarvis on JARVIS_LEAD_AGENT (agy, codex or opencode), in
# this terminal, launched as JARVIS_AGENT_<cli> launches a worker, through its row's
# PREPARE (lib/lead.sh): Jarvis's own hooks, which name this launch's generation, and
# the start prompt that tells it it is Jarvis. --print writes a preview of the launch
# (handoffs/.jarvis/launch/lead/preview, never the running one's files) and shows it;
# --force skips only the check that agy has the jarvis plugin.
cmd_lead() {
  local x print=0 force=0 a cli m e cmd why out d gen launch prompt me old
  for x; do case "$x" in --print) print=1 ;; --force) force=1 ;; *) die "usage: jarvis lead [--print] [--force]" ;; esac; done
  case "${JARVIS_LEAD_AGENT:-claude}" in
    claude) die "$H/jarvis.conf runs Jarvis on Claude Code (JARVIS_LEAD_AGENT=claude): the user opens Claude Code as usual. jarvis lead starts a Jarvis on agy, codex or opencode: set JARVIS_LEAD_AGENT there first" ;;
    agy|codex|opencode) ;;
    *) die "JARVIS_LEAD_AGENT=$JARVIS_LEAD_AGENT in $H/jarvis.conf: give claude, agy, codex or opencode" ;;
  esac
  a=$(lead_agent); cli=$(lead_attr CLI); m=$(lead_model); e=$(lead_effort)
  why=$(lead_validate) || die "$why"
  cmd=$(agent_cmd "$cli") || die "no launch line for $cli: JARVIS_AGENT_$cli is empty"
  why=$(lead_instructions) || die "$why: a $a Jarvis reads its instructions from there. Re-run jarvis:setup (or its upgrade) to copy them"
  if [ $print = 0 ]; then
    [ -z "${CLAUDECODE:-}${ANTIGRAVITY_AGENT:-}${OPENCODE:-}${CODEX_THREAD_ID:-}${CODEX_SHELL:-}" ] && [ "${JARVIS_ROLE:-}" != worker ] \
      || die "this runs inside an agent: the user runs jarvis lead in a terminal of their own (--print shows the launch)"
    have "$cli" || die "no $cli on PATH: install it first"
    if [ "$a" = agy ] && [ $force = 0 ] && have jq && out=$(agy plugin list --json 2>/dev/null) \
       && ! printf '%s' "$out" | jq -e 'any(.[]?; .name == "jarvis" and .enabled != false)' >/dev/null 2>&1; then
      die "agy has no jarvis plugin, so it has no jarvis:run skill: run agy plugin import claude (it copies your Claude Code plugins) or agy plugin install <the jarvis plugin's folder> once. --force starts it anyway"
    fi
    need_host
    me=$(host self)
    [ -n "$me" ] || die "host $HOST gives no id for this terminal — run jarvis lead in a Superset terminal, an Ultron session or a tmux pane"
    old=$(jarvis_terminal)
    if [ -n "$old" ] && [ "$old" != "$me" ] && host list | grep -qxF "$old"; then
      die "another Jarvis ($old) is still open — close it first, or ask it to; jarvis lead doesn't take it over"
    fi
    gen="$(now)-$$-${RANDOM:-0}"
    launch="$STATE/launch/lead.sh"
    # agy keeps its hooks where they always were; the others' files go in a folder per launch
    if [ "$a" = agy ]; then d="$STATE/launch/lead"; else d="$STATE/launch/lead/g-$gen"; fi
  else
    gen=preview; d="$STATE/launch/lead/preview"; launch="$d/lead.sh"
  fi
  mkdir -p "$d" || die "can't make $d"
  # a subshell: a PREPARE that fails (it says why) leaves no launch script behind
  (
    echo "# written by jarvis lead: Jarvis on $a, in the terminal that ran it"
    echo "unset CLAUDECODE CLAUDE_CODE_SESSION_ID CLAUDE_CODE_ENTRYPOINT JARVIS_ROLE JARVIS_BRIEF JARVIS_RUN"
    echo "export JARVIS_ROLE=lead JARVIS_LEAD_LAUNCHED_AGENT=$a"
    "$(lead_attr PREPARE)" "$ROOT/$d" "$gen" "$(tmux_sq "$ROOT/$BIN/jarvis")" || exit 1
    echo "$cmd"
  ) > "$launch.$$" && mv "$launch.$$" "$launch" || { rm -f "$launch.$$"; die "can't write the launch for $a ($launch)"; }
  prompt="$(lead_role) run handoffs/bin/jarvis start, then tell the user what is open."
  if [ $print = 1 ]; then
    printf 'JARVIS_MODEL=%s JARVIS_EFFORT=%s sh %s\n' "$m" "$e" "$launch"
    sed 's/^/  /' "$launch"
    printf 'prompt: %s\n' "$prompt"
    return 0
  fi
  # this launch is now the one: older launches' hooks are stale, its state starts afresh
  lead_lock || die "can't lock $STATE/lead.lock (a hook holding it?): try again"
  printf 'agent: %s\nterminal: %s\ngeneration: %s\n' "$a" "$me" "$gen" > "$STATE/lead.launch.$$" && mv "$STATE/lead.launch.$$" "$STATE/lead.launch" \
    || { lead_unlock; die "can't write $STATE/lead.launch"; }
  rm -f "$STATE/lead.state"; lead_limit_clear; lead_stamp unknown
  lead_unlock
  for x in "$STATE"/launch/lead/g-*; do [ "$x" = "$d" ] || rm -rf "$x"; done
  exec env JARVIS_AGENT="$cli" JARVIS_MODEL="$m" JARVIS_EFFORT="$e" JARVIS_PROMPT="$prompt" sh "$launch"
}

open_checks() { # $1 = OPEN.md's size in bytes; one line per check that fires, nothing when clean
  local n=0 no text name merged on=${OPEN##*/}
  [ "$1" -gt $((JARVIS_OPEN_MAX_KB * 1024)) ] && printf '%s is %s KB (limit %s): move finished notes to jarvis log; one line per item\n' \
    "$on" "$(( ($1 + 512) / 1024 ))" "$JARVIS_OPEN_MAX_KB"
  awk -v on="$on" '/^## /{t = $0; sub(/[[:space:]]+$/, "", t)
    if (t != "## Questions for the user" && t != "## Running workers" && t != "## Waiting on Jarvis" && t != "## To-do")
      printf "%s has a section that belongs in the log: \"%s\"\n", on, t}' "$OPEN"
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
      n=$((n + 1)); [ $n -le 5 ] && echo "$on line $no names $name, already merged"
      break
    done
  done <<EOF
$(awk '/^## /{on = ($0 ~ /^## (To-do|Waiting on Jarvis)/); next} on && /^- / {print NR "\t" $0}' "$OPEN")
EOF
  [ $n -gt 5 ] && echo "… and $((n - 5)) more"
  return 0
}

# Team mode (a local conf): this person's role, branch and notes file, and the notes
# file jarvis start makes when it isn't there yet
team_line() {
  printf 'role: %s · branch: %s · notes: %s\n' "$TEAM_ROLE" "$(git symbolic-ref -q --short HEAD 2>/dev/null || echo "(detached)")" "$OPEN"
}

open_new() {
  mkdir -p "$(dirname "$OPEN")" || return 1
  cat > "$OPEN" <<'EOF' || return 1
# Open items

Jarvis reads this first, every session, and keeps it current. One line per
item. Finished notes go to `jarvis log`, not here. Team mode: this is one
person's notes file, and each teammate's Jarvis keeps its own.

Jarvis session: <terminal id — `handoffs/bin/jarvis start` writes it>
Usage band: <green | amber | red> — `handoffs/bin/jarvis status` writes it from the statusline reading

## Questions for the user

## Running workers

## Waiting on Jarvis

## To-do
EOF
  echo "made $OPEN"
}

lessons_hint() { # one line when 10+ merged handoffs are unread by the lessons pass, or a lesson has expired; silent otherwise
  local out n
  command -v python3 >/dev/null 2>&1 && [ -f "$BIN/jarvis-lessons.py" ] || return 0
  out=$(python3 -I "$BIN/jarvis-lessons.py" status 2>/dev/null) || return 0
  n=$(printf '%s' "$out" | sed -n 's/.*"new_handoffs":\([0-9][0-9]*\).*/\1/p')
  if [ "${n:-0}" -ge 10 ]; then
    printf 'lessons: %s handoffs since the last pass — jarvis lessons propose\n' "$n"
  elif printf '%s' "$out" | grep -q '"expired_ids":\["'; then
    printf 'lessons: an entry has expired — jarvis lessons propose\n'
  fi
  return 0
}

log_file() { # $1 = YYYY-MM: jarvis log's month file; team mode's owner gets one of their own
  printf '%s' "$H/log/$1${JARVIS_OWNER:+.$JARVIS_OWNER}.md"
}

cmd_log() { # jarvis log "<text>": one line on this month's log; the text is data, written as given
  local now month f
  [ -n "$*" ] || die "usage: jarvis log '<text>'"
  now=$(date '+%Y-%m-%d %H:%M'); month=$(printf '%s' "$now" | cut -c1-7)
  f=$(log_file "$month")
  mkdir -p "$H/log" || die "can't make $H/log"
  [ -f "$f" ] || printf '# Jarvis log %s\n\n' "$month" > "$f"
  printf -- '- %s · %s\n' "$now" "$(printf '%s' "$*" | tr '\n\r' '  ')" >> "$f" || die "can't write $f"
  echo "logged: $f"
}
