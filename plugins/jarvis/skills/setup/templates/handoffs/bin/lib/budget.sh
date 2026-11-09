# shellcheck shell=bash
# Sourced by bin/jarvis; not run on its own.
# ---------------------------------------------------------------- budgets

# Each worker gets a budget: working minutes (the watcher's ticks in which its screen
# changed, so time spent waiting for the user's answers costs nothing), and for a
# Claude worker its transcripts' API-equivalent estimate (subagents included), its
# last turn's context and its failed test runs; a brief gets JARVIS_BUDGET_ATTEMPTS
# runs. Past one, the watcher asks the worker once for a partial handoff. Still working
# with no handoff JARVIS_BUDGET_GRACE_MIN later, it presses Escape, which interrupts
# the turn (nothing is closed or signalled), and wakes Jarvis. A brief whose run blew
# its budget, or that has used its attempts, needs `spawn --after <handoff>`, or
# --force (logged). A brief's "budget: min=120 usd=25 ctx=350k tests=8 attempts=3"
# header line overrides the defaults; `jarvis budget <run> usd=30` overrides those for
# one run and re-arms its ask and pause.
# $STATE/budget/<run> holds what the watcher counted (key: value lines, as a run);
# <run>.json the transcripts' byte offsets and running totals, kept by
# cc_usage_audit.py --budget, so each read takes only what was appended.
BUD="$STATE/budget"

bud_get() { RUNS=$BUD run_get "$@"; } # $1 run, $2 key
bud_set() { RUNS=$BUD run_set "$@"; } # $1 run, then <key> <value> pairs

budget_kv() { # $1 = key=value → BK, BV (ctx may end in k); fails on anything else
  case "$1" in *=*) ;; *) return 1 ;; esac
  BK=${1%%=*}; BV=${1#*=}
  case "$BK$BV" in ctx*[kK]) BV="${BV%?}000" ;; esac
  case "$BK" in
    usd) printf '%s' "$BV" | grep -Eq '^[0-9]+(\.[0-9]+)?$' ;;
    min|ctx|tests|attempts) case "$BV" in ""|*[!0-9]*) return 1 ;; esac ;;
    *) return 1 ;;
  esac
}

# shellcheck disable=SC2034 # BL_* and U_* are read through eval, in budget_hit and budget_fmt
budget_limits() { # $1 = brief, $2 = run (optional): sets BL_min BL_usd BL_ctx BL_tests BL_attempts
  local kv
  BL_min=$JARVIS_BUDGET_MIN BL_usd=$JARVIS_BUDGET_USD BL_ctx=$JARVIS_BUDGET_CTX
  BL_tests=$JARVIS_BUDGET_TESTS BL_attempts=$JARVIS_BUDGET_ATTEMPTS
  set -f
  for kv in $(awk '/^## /{exit} /^budget:/ {sub(/^budget:[[:space:]]*/, ""); if (!/^</) print; exit}' "$1" 2>/dev/null) \
            $(run_get "${2:-}" limits); do
    budget_kv "$kv" && eval "BL_$BK=\$BV"
  done
  set +f
}

budget_find() { # $1 = run: its session when the prompt hook recorded none, from Claude Code's session records
  local sp brief d sid cwd
  sp=$(run_get "$1" spawned); brief=$(run_get "$1" brief)
  case "$sp" in ""|*[!0-9]*) return 0 ;; esac
  have jq || return 0
  for d in "$CLAUDE_DIR/sessions" "$HOME/.claude/sessions"; do
    set -- "$d"/*.json
    [ -f "$1" ] || continue
    jq -r --argjson t $(( (sp - 5) * 1000 )) \
      'select(type == "object" and (.startedAt // 0) >= $t and .sessionId != null) | "\(.startedAt) \(.sessionId) \(.cwd // "")"' "$@" 2>/dev/null
  done | sort -n | while read -r _ sid cwd; do
    [ "$(cd "$cwd" 2>/dev/null && proj_root "$(pwd -P)")" = "$ROOTP" ] || continue
    [ "$(brief_of_session "$sid")" = "$brief" ] && { echo "$sid"; break; }
  done
}

budget_files() { # $1 = run: its transcripts, each session's subagents' included, one per line
  local r=$1 sids sid d f
  sids=$(cat "$STATE/sessions/$r" 2>/dev/null)
  [ -n "$sids" ] || sids=$(bud_get "$r" sid)
  if [ -z "$sids" ]; then sids=$(budget_find "$r"); [ -n "$sids" ] && bud_set "$r" sid "$sids"; fi
  for sid in $sids; do
    for d in "$CLAUDE_DIR/projects/$PROJ" "$HOME/.claude/projects/$PROJ"; do
      [ -f "$d/$sid.jsonl" ] || continue
      printf '%s\n' "$d/$sid.jsonl"
      for f in "$d/$sid"/subagents/*.jsonl; do [ -f "$f" ] && printf '%s\n' "$f"; done
      break
    done
  done
}

budget_measure() { # $1 = run, $2 = now: read its transcripts now, else at most every JARVIS_BUDGET_SEC
  local r=$1 last f d out
  [ "$(run_get "$r" agent)" = claude ] && have python3 || return 0
  last=$(bud_get "$r" measured)
  case "$last" in ""|*[!0-9]*) last=0 ;; esac
  [ "${2:-}" = now ] || [ $(( $(now) - last )) -ge "$JARVIS_BUDGET_SEC" ] || return 0
  d=$(dirname "$0")
  case "$d" in /*) ;; *) d="$JARVIS_CALLER_PWD/$d" ;; esac
  set --
  while IFS= read -r f; do [ -n "$f" ] && set -- "$@" "$f"; done <<EOF
$(budget_files "$r")
EOF
  if [ $# = 0 ]; then bud_set "$r" measured "$(now)"; return 0; fi
  mkdir -p "$BUD" && out=$(python3 "$d/cc_usage_audit.py" --budget "$BUD/$r.json" "$@" 2>/dev/null) || return 0
  set -- $out
  [ $# = 3 ] && bud_set "$r" measured "$(now)" usd "$1" ctx "$2" tests "$3"
}

budget_screen() { # $1 = run, $2 = its screen's checksum: a tick in which the screen changed is working time
  local r=$1 t seen work
  t=$(now); seen=$(bud_get "$r" seen); work=$(bud_get "$r" work)
  case "$seen" in ""|*[!0-9]*) seen="" ;; esac
  case "$work" in ""|*[!0-9]*) work=0 ;; esac
  if [ "$(bud_get "$r" screen)" != "$2" ]; then
    # at most two ticks' worth: a watcher that was stopped didn't see it working
    [ -n "$seen" ] && work=$(( work + (t - seen < 2 * JARVIS_WATCH_SEC ? t - seen : 2 * JARVIS_WATCH_SEC) ))
    bud_set "$r" screen "$2" seen "$t" work "$work" changed "$t"
  else
    bud_set "$r" seen "$t"
  fi
}

# shellcheck disable=SC2034
budget_use() { # $1 = run: U_min U_usd U_ctx U_tests (U_usd empty: no transcript read yet) and its limits
  local r=$1 w
  budget_limits "$(run_get "$r" brief)" "$r"
  w=$(bud_get "$r" work)
  case "$w" in ""|*[!0-9]*) w=0 ;; esac
  U_min=$((w / 60)) U_usd="" U_ctx="" U_tests=""
  [ "$(run_get "$r" agent)" = claude ] || return 0
  U_usd=$(bud_get "$r" usd) U_ctx=$(bud_get "$r" ctx) U_tests=$(bud_get "$r" tests)
}

budget_hit() { # $1 = min | usd | ctx | tests, after budget_use: reached?
  local u l
  eval "u=\${U_$1:-}; l=\$BL_$1"
  [ -n "$u" ] && awk -v u="$u" -v l="$l" 'BEGIN { exit !(u + 0 >= l + 0) }'
}

budget_fmt() { # $1 = key, after budget_use: "<used>/<limit>" as shown
  local u l
  eval "u=\${U_$1:-0}; l=\$BL_$1"
  case "$1" in
    min) printf '%sm/%sm' "$u" "$l" ;;
    usd) awk -v u="$u" -v l="$l" 'BEGIN { printf "$%.1f/$%s", u, l }' ;;
    ctx) awk -v u="$u" -v l="$l" 'BEGIN { printf "%dk/%dk", u / 1000 + 0.5, l / 1000 + 0.5 }' ;;
    *) printf '%s/%s' "$u" "$l" ;;
  esac
}

budget_reached() { # after budget_use: "<which>: <used>/<limit>" for the first budget reached
  local k
  for k in min usd ctx tests; do budget_hit $k && { printf '%s: %s' $k "$(budget_fmt $k)"; return 0; }; done
  return 1
}

hm() { date -r "$1" +%H:%M 2>/dev/null || date -d "@$1" +%H:%M; } # $1 = epoch

budget_line() { # $1 = run: "42m/90m working (1h50m since spawn) · $6.1/$15 · ctx 180k/300k · tests 1/6"
  local r=$1 sp k s x
  budget_measure "$r" now
  budget_use "$r"
  sp=$(run_get "$r" spawned)
  case "$sp" in ""|*[!0-9]*) sp=$(now) ;; esac
  s="$(budget_fmt min) working ($(dur $(( $(now) - sp ))) since spawn)"
  budget_hit min && s="$s (over)"
  if [ "$(run_get "$r" agent)" = claude ]; then
    if [ -n "$U_usd" ]; then
      for k in usd ctx tests; do
        case $k in ctx) x="ctx $(budget_fmt ctx)" ;; tests) x="tests $(budget_fmt tests)" ;; *) x=$(budget_fmt usd) ;; esac
        budget_hit $k && x="$x (over)"
        s="$s · $x"
      done
    else
      s="$s · no transcript found yet"
    fi
  fi
  x=$(run_get "$r" budget_asked); [ -n "$x" ] && s="$s · asked for a partial handoff $(hm "$x")"
  x=$(run_get "$r" paused); [ -n "$x" ] && s="$s · paused $(hm "$x")"
  printf '%s\n' "$s"
}

budget_handoff() { # $1 = brief, $2 = epoch, $3 = 0: skip blocked ones: a handoff for the brief written since $2
  local ho
  for ho in $(grep -l "^brief:[[:space:]]*$1" "$H"/*.md "$H"/merged/*.md 2>/dev/null); do
    [ "$(mtime "$ho")" -ge "$2" ] || continue
    [ "${3:-1}" = 0 ] && [ "$(field status "$ho")" = blocked ] && continue
    echo "$ho"; return 0
  done
  return 1
}

# The watcher, each tick, per running worker: $1 = run, $2 = the bottom of its screen.
# Counts working time, then asks once, then pauses once. Prints events for Jarvis.
budget_tick() {
  local r=$1 brief asked over t ch sp
  run_ok "$r" && [ -f "$RUNS/$r" ] && [ "$(run_get "$r" state)" = running ] || return 0
  [ -n "$2" ] && budget_screen "$r" "$(printf '%s' "$2" | cksum | cut -d' ' -f1)"
  t=$(now); brief=$(run_get "$r" brief)
  sp=$(run_get "$r" spawned); case "$sp" in ""|*[!0-9]*) sp=0 ;; esac
  asked=$(run_get "$r" budget_asked)
  if [ -z "$asked" ]; then
    # one that has handed off (done or partial) since it was spawned is finished
    budget_handoff "$brief" "$sp" 0 >/dev/null && return 0
    budget_measure "$r"
    budget_use "$r"
    over=$(budget_reached) || return 0
    run_set "$r" budget "${over%%:*} ${over#*: } $t" budget_asked "$t"
    if host send "$r" "[jarvis] Budget reached ($over). Stop the current approach now. Write your handoff with status: partial — what's done, what's left, what you tried that failed and why — then stop." >/dev/null 2>&1; then
      printf ' worker %s hit its %s budget — asked for a partial handoff;' "$(short "$r")" "${over%%:*}"
    else
      printf " worker %s hit its %s budget, and the ask couldn't be typed into its terminal — read it;" "$(short "$r")" "${over%%:*}"
    fi
    return 0
  fi
  [ -z "$(run_get "$r" paused)$(run_get "$r" pause_failed)" ] || return 0
  [ $(( t - asked )) -ge $(( JARVIS_BUDGET_GRACE_MIN * 60 )) ] || return 0
  budget_handoff "$brief" "$asked" >/dev/null && return 0
  # still working: its screen changed within the last two ticks
  ch=$(bud_get "$r" changed); case "$ch" in ""|*[!0-9]*) ch=0 ;; esac
  [ $(( t - ch )) -le $(( 2 * JARVIS_WATCH_SEC )) ] || return 0
  if host send "$r" --keys esc >/dev/null 2>&1; then
    run_set "$r" paused "$t"
    printf ' worker %s paused over budget, no handoff — read its terminal;' "$(short "$r")"
  else
    run_set "$r" pause_failed "$t"
    printf " worker %s is over budget with no handoff, and its terminal took no Escape — read it;" "$(short "$r")"
  fi
}

# spawn: a brief whose run blew its budget, or that has used its attempts, is respawned
# only --after a handoff for it written since its latest run started, or with --force
budget_gate() { # $1 = brief, $2 = --after's handoff or empty, $3 = force (0|1)
  local brief=$1 after=$2 runs r n=0 blown="" last=0 sp why ho
  runs=$(runs_of "$brief")
  for r in $runs; do
    n=$((n + 1))
    [ -n "$(run_get "$r" budget)" ] && blown="$blown${blown:+, }$r ($(run_get "$r" budget | awk '{print $1 " " $2}'))"
    sp=$(run_get "$r" spawned)
    case "$sp" in ""|*[!0-9]*) ;; *) [ "$sp" -gt "$last" ] && last=$sp ;; esac
  done
  budget_limits "$brief"
  if [ -n "$blown" ]; then why="a run of it reached its budget: $blown"
  elif [ "$n" -ge "$BL_attempts" ]; then why="it has used its $BL_attempts attempts ($(echo $runs | sed 's/ /, /g'))"
  else return 0; fi
  if [ -n "$after" ]; then
    [ "$(field brief "$after" | sed 's#^\./##')" = "${brief#./}" ] \
      || die "$brief can't be respawned yet: $why. --after $after isn't a handoff for it (its brief: is '$(field brief "$after")')"
    [ "$(mtime "$after")" -ge "$last" ] \
      || die "$brief can't be respawned yet: $why. --after $after was written before its latest run started: ask that worker for its handoff, or --force"
    return 0
  fi
  if [ "$3" = 1 ]; then
    audit budget-force - "$brief" "runs=$n attempts=$BL_attempts budget=$([ -n "$blown" ] && echo reached || echo -)" passed
    echo "jarvis: --force: past the respawn gate ($why); logged in $STATE/audit.log" >&2
    return 0
  fi
  ho=$(handoff_of "$brief")
  die "$brief can't be respawned yet: $why. Read its partial handoff${ho:+ ($ho)}, sharpen or split the brief, then respawn with --after <that handoff>. --force passes this (logged)."
}

cmd_budget() { # jarvis budget <run> [min=N] [usd=N] [ctx=N[k]] [tests=N]
  local r=${1:-} kv old="" set="" limits b
  [ -n "$r" ] || die "usage: jarvis budget <terminal> [min=N] [usd=N] [ctx=N[k]] [tests=N]"
  run_ok "$r" && [ -f "$RUNS/$r" ] || die "no run $r in $RUNS"
  shift
  [ $# -gt 0 ] || { budget_line "$r"; return 0; }
  for kv; do
    budget_kv "$kv" && [ "$BK" != attempts ] \
      || die "$kv: give min=, usd=, ctx= or tests= a number (attempts is per brief: its budget: line)"
    set="$set $BK=$BV"
  done
  # the new values replace the run's earlier ones, key by key
  for kv in $(run_get "$r" limits); do
    case " $set " in *" ${kv%%=*}="*) ;; *) old="$old $kv" ;; esac
  done
  limits=$(echo $old $set)
  b=$(run_get "$r" budget)
  [ -n "$b" ] && run_set "$r" budget_was "$b"
  run_set "$r" limits "$limits" budget "" budget_asked "" paused "" pause_failed ""
  audit budget-raise "$r" "$(run_get "$r" brief)" "limits=$(printf '%s' "$limits" | tr ' ' ,)" set
  echo "run $(short "$r"): limits $limits; its ask and pause are re-armed"
  budget_line "$r"
}
