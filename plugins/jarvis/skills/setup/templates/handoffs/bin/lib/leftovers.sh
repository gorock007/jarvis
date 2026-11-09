# shellcheck shell=bash
# Sourced by bin/jarvis; not run on its own.
# ---------------------------------------------------------------- leftovers

# A worker's Bash commands run in process groups of their own, away from its
# terminal's, so closing the terminal doesn't stop what they started; and a
# browser whose script crashed is adopted by launchd and runs until someone
# kills it (two did, for ten days). Claude Code gives each session a scratch
# folder, /tmp/claude-<uid>/<project>/<session id>/, and what a worker runs from
# there (a scratch browser profile, a script, a background task's log) carries
# that path on its command line. The path is the ownership mark. A leftover is
# a process of this user that carries the session id of a worker spawned from
# one of this repo's briefs, or that shares a process group with one when the
# group has no terminal (a Bash-tool group, never an interactive shell's).
# Nothing else is listed or stopped: no matching by name, no other session's.

SPAWN_RE="You are a Jarvis worker\\. Read AGENTS\\.md, then do the task in "

brief_terminal() {
  sed -n 's/.*terminal:[[:space:]]*\([^ ]*\).*/\1/p' "$1" 2>/dev/null | head -n 1 | grep -v '^<' || true
}

handoff_of() { # the latest handoff written for a brief, merged or not
  grep -l "^brief:[[:space:]]*$1" "$H"/*.md "$H"/merged/*.md 2>/dev/null | tail -n 1
}

live_sids() { # this checkout's session ids that a process of this user names on its command line
  ps -axww -o uid=,command= 2>/dev/null | J_UID=$(id -u) J_PROJ="$PROJ" awk '
    $1 == ENVIRON["J_UID"] {
      s = $0; key = "/claude-" ENVIRON["J_UID"] "/" ENVIRON["J_PROJ"] "/"
      while ((i = index(s, key)) > 0) {
        s = substr(s, i + length(key)); id = substr(s, 1, 36)
        if (length(id) == 36 && id ~ /^[0-9a-f-]+$/ && substr(s, 37, 1) == "/") print id
      }
    }' | sort -u
}

brief_of_session() { # the brief a session of this checkout worked from, if it was a worker
  local f="$CLAUDE_DIR/projects/$PROJ/$1.jsonl" b t
  # the spawn prompt names the brief, and it opens the worker's transcript
  [ -f "$f" ] && b=$(head -n 30 "$f" | grep -o "${SPAWN_RE}$H/briefs/[^ \"\\\\]*\\.md" | head -n 1 | sed 's/.* do the task in //')
  # a worker that ran /clear has a new transcript; the prompt hook saw it in the worker's terminal
  if [ -z "${b:-}" ] && t=$(grep -lxF "$1" "$STATE"/sessions/* 2>/dev/null | head -n 1) && [ -n "$t" ]; then
    b=$(grep -l "^started:.*terminal:[[:space:]]*$(basename "$t")" "$H"/briefs/*.md 2>/dev/null | head -n 1)
  fi
  [ -n "${b:-}" ] && [ -f "$b" ] && echo "$b"
}

# A session resumed after its brief finished (claude --resume, after_end) is
# someone's live session again: what it runs is its own, never a leftover.
worker_sessions() { # "<brief> <session id>" for each worker session something still names; $1 = only this brief
  local s b here="" got=0
  for s in $(live_sids); do
    b=$(brief_of_session "$s") || continue
    [ -z "${1:-}" ] || [ "$b" = "$1" ] || continue
    [ $got = 1 ] || { here=$(claude_here); got=1; }
    resumed_sid "$b" "$s" "$here" && continue
    echo "$b $s"
  done
}

resumed_sid() { # $1 = brief, $2 = session id, $3 = claude_here lines: a live process of it started after the brief's run ended?
  local pid ps sid r e
  while read -r pid ps sid _; do
    [ -n "$pid" ] && [ "$sid" = "$2" ] || continue
    r=$(run_by_start "$1" "$ps")
    if [ -n "$r" ]; then e=$(run_get "$r" ended); else e=$(merged_at "$(doc_merged "$1")"); fi
    after_end "$ps" "$e" && return 0
  done <<EOF
$3
EOF
  return 1
}

# What the given sessions left running, one process per line:
# "<session id> <pid> <pgid> <ppid> <elapsed> <%cpu> <command>". The session
# ids go to awk through the environment, so no command line here carries them;
# this command's own process group is never listed.
owned_procs() { # $@ = session ids
  [ $# -gt 0 ] || return 0
  ps -axww -o pid=,ppid=,pgid=,uid=,tty=,stat=,etime=,%cpu=,command= 2>/dev/null \
    | J_SIDS="$*" J_UID=$(id -u) J_SELF=$$ J_PGID=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ') awk '
    BEGIN { n = split(ENVIRON["J_SIDS"], sid, " "); u = ENVIRON["J_UID"] }
    {
      c = $0; for (k = 0; k < 8; k++) sub(/^[ \t]*[^ \t]+[ \t]+/, "", c); sub(/[ \t]+$/, "", c)
      pid[NR] = $1; ppid[NR] = $2; pg[NR] = $3; et[NR] = $7; cpu[NR] = $8; cmd[NR] = c
      if ($5 != "??" && $5 != "?") tty[$3] = 1
      # a zombie has already exited: nothing to stop
      mine[NR] = ($4 == u && $6 !~ /^Z/ && $1 != ENVIRON["J_SELF"] && $3 != ENVIRON["J_PGID"])
      if (!mine[NR]) next
      for (i = 1; i <= n; i++)
        if (c ~ ("/claude-" u "/[^/ ]+/" sid[i] "/")) { hit[NR] = sid[i]; if (!($3 in grp)) grp[$3] = sid[i]; break }
    }
    END {
      for (r = 1; r <= NR; r++) {
        if (!mine[r]) continue
        s = hit[r]
        if (s == "" && (pg[r] in grp) && !(pg[r] in tty)) s = grp[pg[r]]
        if (s != "") print s, pid[r], pg[r], ppid[r], et[r], cpu[r], cmd[r]
      }
    }'
}

show_procs() { # stdin: owned_procs lines; one line per process tree, its children counted
  awk -v u="$(id -u)" '
    { p[NR] = $2; pp[NR] = $4; e[NR] = $5; c[NR] = $6; x = $0
      for (k = 0; k < 6; k++) sub(/^[^ ]+ /, "", x); cmd[NR] = x; at[$2] = NR }
    END {
      for (r = 1; r <= NR; r++) {
        q = r; while ((pp[q] in at) && at[pp[q]] != q) q = at[pp[q]]
        top[r] = q; tc[q] += c[r]; if (q != r) kids[q]++
      }
      for (r = 1; r <= NR; r++) if (top[r] == r) {
        x = cmd[r]; gsub("[^ =]*/claude-" u "/[^/ ]+/[0-9a-f-]+/", "<scratch>/", x)
        # a long command line keeps its start and the argument that names the scratch folder
        if (length(x) > 100 && (i = index(x, "<scratch>/")) > 60) {
          while (i > 1 && substr(x, i - 1, 1) != " ") i--
          t = substr(x, i); sub(/ .*/, "", t); x = substr(x, 1, 50) " ... " t
        }
        if (length(x) > 140) x = substr(x, 1, 140) "..."
        printf "    pid %s · up %s · cpu %.0f%%%s%s · %s\n", p[r], e[r], tc[r], (pp[r] == 1 ? " · orphaned" : ""),
          (kids[r] ? " · +" kids[r] " child" (kids[r] > 1 ? "ren" : "") : ""), x
      }
    }'
}

declared_pids() { # the PIDs a handoff lists under "## Processes left running"
  [ -f "$1" ] || return 0
  awk '/^## /{on = ($0 ~ /^## Processes left running/); next} on && /^[[:space:]]*[-*] /' "$1" \
    | sed -E 's/^[[:space:]]*[-*][[:space:]]+`?([Pp][Ii][Dd][[:space:]]*)?//' | grep -oE '^[0-9]+' || true
}

drop_declared() { # $1 = owned_procs lines, $2 = declared PIDs: the lines outside their process groups
  local pid keep=""
  for pid in $2; do keep="$keep $(printf '%s\n' "$1" | awk -v p="$pid" '$2 == p {print $3}')"; done
  printf '%s\n' "$1" | awk -v k=" $(echo $keep) " 'NF && index(k, " " $3 " ") == 0'
}

still() { # $1 pid, $2 pgid, $3 command: is that PID still the process that was listed?
  [ "$(ps -o pgid= -p "$1" 2>/dev/null | tr -d ' ')" = "$2" ] || return 1
  [ "$(ps -ww -o command= -p "$1" 2>/dev/null | sed 's/[[:space:]]*$//')" = "$3" ]
}

# Stop the processes in $1 (owned_procs lines), except every process group
# holding a PID in $2. Each one is checked again right before it's signalled, so
# a PID reused since the listing is left alone. TERM, then KILL after 10 s.
# Prints "<stopped> <needed KILL>", counting a browser's helpers that exit with it.
stop_procs() {
  local list pid pgid cmd n=0 hard=0 i=0 alive
  list=$(drop_declared "$1" "$2")
  while read -r _ pid pgid _ _ _ cmd; do
    [ -n "$pid" ] && still "$pid" "$pgid" "$cmd" && n=$((n + 1))
  done <<EOF
$list
EOF
  while read -r _ pid pgid _ _ _ cmd; do
    [ -n "$pid" ] && still "$pid" "$pgid" "$cmd" && kill -TERM "$pid" 2>/dev/null
  done <<EOF
$list
EOF
  while [ $n -gt 0 ] && [ $i -lt 10 ]; do
    alive=0
    while read -r _ pid pgid _ _ _ cmd; do
      [ -n "$pid" ] && still "$pid" "$pgid" "$cmd" && alive=1
    done <<EOF
$list
EOF
    [ $alive = 0 ] && break
    sleep 1; i=$((i + 1))
  done
  while read -r _ pid pgid _ _ _ cmd; do
    [ -n "$pid" ] && still "$pid" "$pgid" "$cmd" && kill -KILL "$pid" 2>/dev/null && hard=$((hard + 1))
  done <<EOF
$list
EOF
  echo "$n $hard"
}

stopped_line() { # $1 = stop_procs output, $2 = the declared PIDs that were kept
  set -- $1 "${2:-}"
  printf 'stopped %s process(es)%s%s' "$1" "$([ "$2" -gt 0 ] && echo ", $2 only by SIGKILL")" \
    "${3:+ · kept $3 (with its process group), declared under Processes left running; --force ends it}"
}

kept_of() { # $1 = owned_procs lines, $2 = declared PIDs: those among the processes
  printf '%s\n' "$1" | awk -v k=" $(echo $2) " 'index(k, " " $2 " ") {print $2}' | tr '\n' ' ' | sed 's/ $//'
}

# merge, after the commit: what the worker left running. $1 brief, $2 its
# handoff, $3 1 = its terminal was just closed
merge_leftovers() {
  local sids procs keep
  sids=$(worker_sessions "$1" | awk '{print $2}')
  [ -n "$sids" ] || return 0
  # shellcheck disable=SC2086
  procs=$(owned_procs $sids)
  [ -n "$procs" ] || return 0
  if [ "$3" = 1 ] && [ "$JARVIS_REAP" = 1 ]; then
    keep=$(declared_pids "$2")
    echo "the worker left these running:"
    printf '%s\n' "$procs" | show_procs
    echo "  $(stopped_line "$(stop_procs "$procs" "$keep")" "$(kept_of "$procs" "$keep")")"
  else
    echo "the worker has these running$([ "$3" = 1 ] || echo ' (its terminal is still open)'):"
    printf '%s\n' "$procs" | show_procs
    echo "  to stop them: handoffs/bin/jarvis leftovers $1 --stop"
  fi
}

cmd_leftovers() {
  local brief="" stop=0 force=0 mine=0 quiet=0 map b sids procs open="" listed any=0 state term keep
  while [ $# -gt 0 ]; do
    case "$1" in
      --stop) stop=1; shift ;;
      --force) force=1; shift ;;
      --mine) mine=1; shift ;;
      --quiet) quiet=1; shift ;;
      *) brief="$1"; shift ;;
    esac
  done

  if [ $mine = 1 ]; then
    [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || die "no CLAUDE_CODE_SESSION_ID here: --mine lists a Claude Code session's own processes"
    procs=$(owned_procs "$CLAUDE_CODE_SESSION_ID")
    [ -n "$procs" ] || { echo "nothing this session started is still running (this command aside)"; return 0; }
    echo "still running from this session's scratch folder:"
    printf '%s\n' "$procs" | show_procs
    [ $stop = 1 ] && echo "  $(stopped_line "$(stop_procs "$procs" "")")"
    return 0
  fi

  [ $force = 1 ] && [ -z "$brief" ] && die "--force needs a brief: jarvis leftovers <brief> --stop --force"
  [ -z "$brief" ] || [ -f "$brief" ] || die "usage: jarvis leftovers [<handoffs/briefs/file.md>] [--stop [--force]] | --mine [--stop]"
  map=$(worker_sessions "$brief")
  [ -n "$map" ] || { [ $quiet = 1 ] || echo "nothing left running by ${brief:-any worker}"; return 0; }

  listed=0
  [ -n "$HOST" ] && open=$(host list 2>/dev/null) && listed=1
  for b in $(printf '%s\n' "$map" | awk '{print $1}' | sort -u); do
    sids=$(printf '%s\n' "$map" | awk -v b="$b" '$1 == b {print $2}')
    # shellcheck disable=SC2086
    procs=$(owned_procs $sids)
    [ -n "$procs" ] || continue
    term=$(brief_terminal "$b")
    if [ $listed = 0 ]; then state=unknown
    elif [ -n "$term" ] && printf '%s\n' "$open" | grep -qxF "$term"; then state=open
    else state=closed; fi
    [ $quiet = 1 ] && [ "$state" != closed ] && continue
    # status leaves out what the worker declared it left running on purpose
    [ $quiet = 1 ] && [ -z "$(drop_declared "$procs" "$(declared_pids "$(handoff_of "$b")")")" ] && continue
    [ $quiet = 1 ] && [ $any = 0 ] && echo "left running by closed workers (stop: handoffs/bin/jarvis leftovers <brief> --stop):"
    any=1
    echo "  $b (worker terminal $state):"
    printf '%s\n' "$procs" | show_procs
    [ $stop = 1 ] || continue
    if [ "$state" != closed ] && [ $force = 0 ]; then
      echo "    not stopped: the worker's terminal is $state and it may still be using them. Close it first, or --force"
      continue
    fi
    keep=""; [ $force = 1 ] || keep=$(declared_pids "$(handoff_of "$b")")
    echo "    $(stopped_line "$(stop_procs "$procs" "$keep")" "$(kept_of "$procs" "$keep")")"
  done
  [ $any = 1 ] || [ $quiet = 1 ] || echo "nothing left running by ${brief:-any worker}"
}
