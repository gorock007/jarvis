# shellcheck shell=bash
# Sourced by bin/jarvis; not run on its own.
# ---------------------------------------------------------------- doctor

# What is alive in this checkout and why it is still there, from Claude Code's
# session records (claude_here: one ps), one host list and the run registry.
# Read-only. --apply acts only on what Jarvis positively owns and has finished: a
# merged/closed run's open terminal (stop_run), a finished worker's verified agent
# whose terminal is gone (TERM, then KILL), a running run whose terminal is gone and
# that has no agent (marked lost), an orphaned merge --verify worktree (doc_verify).
# A busy agent, a session that isn't a worker's and
# a terminal nobody recorded are reported, never touched. Each action is printed and
# audited. `status` (and so `start`) prints the --quiet line: the reconciliation
# after Jarvis crashes or restarts.

doc_merged() { # $1 = brief: its handoff in handoffs/merged/, if any
  grep -l "^brief:[[:space:]]*$1[[:space:]]*\$" "$H"/merged/*.md 2>/dev/null | head -n 1
}

doc_up() { # $1 = a start time from lstart_of: how long ago, e.g. 3d04h, 2h05m, 7m
  local e s
  e=$(start_epoch "$1")
  [ -n "$e" ] || { echo "?"; return; }
  s=$(( $(now) - e ))
  if [ $s -ge 86400 ]; then printf '%dd%02dh' $((s / 86400)) $((s % 86400 / 3600))
  elif [ $s -ge 3600 ]; then printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
  else printf '%dm' $((s / 60)); fi
}

# "<pid> <procstart> <session> <status> <class> <run> <brief> <terminal>" for each
# claude_here line, "-" for an empty field; class is jarvis | running | finished |
# resumed | other. The run is the registry's. A worker from before the registry has
# none: its brief comes from its transcript, its terminal from its prompt hook or
# brief. Jarvis is the session its prompt hook recorded or, when this runs in
# Jarvis's terminal, the Claude process above this command. A worker's session in a
# process that started after its run ended (the registry's ended, or when the
# handoff went into merged/) is resumed: someone reopened the transcript later.
doc_procs() { # $1 = Jarvis's terminal
  local jt=$1 jsid="" anc="" pid ps sid st t b r n class term e
  have jq && jsid=$(jq -r '.session_id // empty' "$STATE/session.json" 2>/dev/null)
  [ -n "$jt" ] && [ -n "$HOST" ] && [ "$("${HOST}_self" 2>/dev/null)" = "$jt" ] && anc=" $(ancestors)"
  claude_here | while read -r pid ps sid st; do
    t=$(grep -lxF "$sid" "$STATE"/sessions/* 2>/dev/null | head -n 1); t=${t##*/}
    r=""; b=""; class=other; term=""
    if [ "$sid" = "$jsid" ] || { [ -n "$jt" ] && [ "$t" = "$jt" ]; } || case "$anc" in *" $pid "*) true ;; *) false ;; esac
    then class=jarvis; term=$jt
    elif [ -n "$t" ] && run_ok "$t" && [ -f "$RUNS/$t" ]; then r=$t
    elif b=$(brief_of_session "$sid"); then
      n=$(runs_of "$b" | wc -l | tr -d ' ')
      if [ "$n" = 1 ]; then r=$(runs_of "$b"); elif [ "$n" -gt 1 ]; then r=$(run_by_start "$b" "$ps"); fi
      [ -n "$r" ] || term=${t:-$(brief_terminal "$b")}
    fi
    if [ -n "$r" ]; then
      term=$r; b=$(run_get "$r" brief)
      case "$(run_get "$r" state)" in merged|closed) class=finished ;; *) class=running ;; esac
    elif [ -n "$b" ]; then
      if [ -n "$(doc_merged "$b")" ]; then class=finished; else class=running; fi
    fi
    e=""
    if [ -n "$r" ]; then e=$(run_get "$r" ended)
    elif [ "$class" = finished ]; then e=$(merged_at "$(doc_merged "$b")"); fi
    after_end "$ps" "$e" && class=resumed
    echo "$pid $ps $sid $st $class ${r:--} ${b:--} ${term:--}"
  done
}

# "<terminal> <class> <run> <brief>" for each terminal the host lists; class is
# jarvis | running | finished | unknown (cmd_doctor makes a finished one resumed
# when it is a resumed session's terminal or of its brief). With no run record, a terminal is a
# worker's when a brief's started: line or a Running workers line names it.
doc_terms() { # $1 = host list, $2 = Jarvis's terminal
  local id b legacy
  legacy=$(grep -H '^started:.*terminal:' "$H"/briefs/*.md 2>/dev/null \
    | sed -n 's/^\([^:]*\):started:.*terminal:[[:space:]]*\([^ ]*\).*/\2 \1/p')
  printf '%s\n' "$1" | while read -r id; do
    [ -n "$id" ] || continue
    if [ "$id" = "$2" ]; then echo "$id jarvis - -"; continue; fi
    if run_ok "$id" && [ -f "$RUNS/$id" ]; then
      b=$(run_get "$id" brief)
      case "$(run_get "$id" state)" in
        merged|closed) echo "$id finished $id ${b:--}" ;;
        running) echo "$id running $id ${b:--}" ;;
        *) echo "$id unknown $id ${b:--}" ;; # a lost run's terminal back in the list: look, don't touch
      esac
      continue
    fi
    b=$(printf '%s\n' "$legacy" | awk -v t="$id" '$1 == t {print $2}' | tail -n 1)
    [ -n "$b" ] || b=$(running_lines | grep -F "· term $id ·" | grep -o "$H/briefs/[^ ]*\.md" | head -n 1)
    if [ -z "$b" ]; then echo "$id unknown - -"
    elif [ -n "$(doc_merged "$b")" ]; then echo "$id finished - $b"
    else echo "$id running - $b"; fi
  done
}

doc_lost() { # $1 = host list, $2 = doc_procs lines: "<run> <brief>" for each running run with neither
  local f r
  for f in "$RUNS"/*; do
    [ -f "$f" ] || continue
    r=${f##*/}
    [ "$(run_get "$r" state)" = running ] || continue
    printf '%s\n' "$1" | grep -qxF "$r" && continue
    printf '%s\n' "$2" | awk -v r="$r" '$6 == r {f = 1} END {exit !f}' && continue
    echo "$r $(run_get "$r" brief)"
  done
}

doc_locks() { # the held and queued leases of this checkout's classes and the machine's
  have perl || return 0
  (cmd_resources) 2>/dev/null | J_ROOT="$ROOT" J_PHYS=$(pwd -P) awk '
    /^[^ ]/ { i = index($0, " · "); w = (i ? substr($0, i + length(" · ")) : "")
              on = (w == "machine" || w == ENVIRON["J_ROOT"] || w == ENVIRON["J_PHYS"]); head = $0; shown = 0; next }
    on && ($0 ~ /^  slot [0-9]+  held/ || $0 ~ /^  queue [1-9]/) { if (!shown) print "  " head; shown = 1; print "  " $0 }'
}

doc_brief() { if [ "$1" = - ]; then echo "?"; else basename "$1" .md; fi; } # $1 = brief path or -

# merge --verify's worktrees a verifier killed along with its watchdog left behind, and run
# records stuck at verify_status: running; jarvis-verify.py doctor has the rules. No host needed.
doc_verify() { # $1 = "" (report; exits 3 when --apply has work) | --quiet | --apply
  local d
  [ -d "$STATE/verify" ] || grep -qsx 'verify_status: running' "$RUNS"/* \
    || git worktree list --porcelain 2>/dev/null | grep -qF "/$STATE/verify/" || return 0
  have python3 || { [ "$1" = --quiet ] || echo "  not checked: no python3 on PATH"; return 0; }
  d=$(dirname "$0")
  case "$d" in /*) ;; *) d="$JARVIS_CALLER_PWD/$d" ;; esac
  [ -f "$d/jarvis-verify.py" ] || { [ "$1" = --quiet ] || echo "  not checked: no $d/jarvis-verify.py — re-run jarvis:setup"; return 0; }
  python3 -I "$d/jarvis-verify.py" doctor --root "$ROOT" --runner "$d/$(basename "$0")" \
    --lock-dir "${JARVIS_LOCK_DIR:-$HOME/.jarvis/locks}" --grace "$JARVIS_STOP_GRACE" ${1:+"$1"}
}

cmd_doctor() {
  local apply=0 quiet=0 jt open="" listed=0 procs terms="" lost="" titles="" anc n1 n2 n3 out nv=0
  local pid ps sid st class run brief term id r s
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply) apply=1 ;;
      --quiet) quiet=1 ;;
      *) die "usage: jarvis doctor [--apply | --quiet]" ;;
    esac
    shift
  done
  jt=$(jarvis_terminal)
  [ -n "$HOST" ] && open=$(host list 2>/dev/null) && listed=1
  procs=$(doc_procs "$jt")
  if [ $listed = 1 ]; then terms=$(doc_terms "$open" "$jt"); lost=$(doc_lost "$open" "$procs"); fi
  # a finished terminal of a brief whose session was resumed may be where it runs now: resumed, left open
  terms=$(printf '%s\n' "$terms" | J_RT="$(printf '%s\n' "$procs" | awk '$5 == "resumed" {print $8; print "brief " $7}')" awk '
    BEGIN { n = split(ENVIRON["J_RT"], r, "\n"); for (i = 1; i <= n; i++) if (r[i] != "-" && r[i] != "brief -") rt[r[i]] = 1 }
    NF { if ($2 == "finished" && (($1 in rt) || (("brief " $4) in rt))) $2 = "resumed"; print }')
  n1=$(printf '%s\n' "$procs" | awk '$5 == "finished"' | wc -l | tr -d ' ')
  n2=$(printf '%s\n' "$terms" | awk '$2 == "finished"' | wc -l | tr -d ' ')
  n3=$(printf '%s\n' "$lost" | awk 'NF' | wc -l | tr -d ' ')

  if [ $quiet = 1 ]; then
    out=$(doc_verify --quiet)
    [ $((n1 + n2 + n3)) -gt 0 ] || [ -n "$out" ] || return 0
    [ -n "$out" ] && out=" · $out"
    [ "$n1" -gt 0 ] && out="$out · $n1 finished worker$([ "$n1" = 1 ] || echo s) still running"
    [ "$n2" -gt 0 ] && out="$out · $n2 finished terminal$([ "$n2" = 1 ] || echo s) open"
    [ "$n3" -gt 0 ] && out="$out · $n3 lost run$([ "$n3" = 1 ] || echo s)"
    echo "doctor: ${out# · } — handoffs/bin/jarvis doctor"
    return 0
  fi

  echo "agent processes (Claude, in this checkout):"
  [ -n "$procs" ] || echo "  none"
  printf '%s\n' "$procs" | while read -r pid ps sid st class run brief term; do
    [ -n "$pid" ] || continue
    printf '  pid %s · up %s · %s · session %s · ' "$pid" "$(doc_up "$ps")" "${st#-}" "$(short "$sid")"
    case "$class" in
      jarvis) echo "Jarvis" ;;
      other) echo "not a worker (left alone)" ;;
      resumed) echo "resumed after its brief finished (left alone) · $(doc_brief "$brief")" ;;
      running|finished)
        [ "$class" = finished ] && printf 'worker, FINISHED' || printf 'worker, running'
        printf ' · %s · ' "$(doc_brief "$brief")"
        if [ "$run" != - ]; then printf 'run %s (%s)' "$(short "$run")" "$(run_get "$run" state)"
        else printf 'no run record%s' "$([ "$class" = finished ] && echo ', handoff merged')"; fi
        case "$st" in busy|shell) [ "$class" = finished ] && printf ' · %s: left alone' "$st" ;; esac
        echo ;;
    esac
  done

  echo "terminals${HOST:+ on $HOST}:"
  if [ $listed = 0 ]; then
    echo "  the host can't be asked${HOST:- (no host)}: terminals and lost runs not checked"
  else
    [ -n "$terms" ] || echo "  none"
    printf '%s\n' "$terms" | awk '$2 == "unknown"' | grep -q . && type "${HOST}_titles" >/dev/null 2>&1 \
      && titles=$(host titles 2>/dev/null)
    printf '%s\n' "$terms" | while read -r id class run brief; do
      [ -n "$id" ] || continue
      printf '  %s · ' "$(short "$id")"
      case "$class" in
        jarvis) echo "Jarvis" ;;
        running) echo "worker, running · $(doc_brief "$brief")$([ "$run" = - ] && echo ' · no run record')" ;;
        finished|resumed)
          printf 'FINISHED but open · %s · %s' "$(doc_brief "$brief")" "$(if [ "$run" = - ]; then echo 'no run record, handoff merged'; else run_get "$run" state; fi)"
          [ "$class" = resumed ] && printf ' · a session resumed there after the brief finished (left alone)'
          echo ;;
        *) printf 'unknown (left alone)%s' "$([ "$run" != - ] && echo " · run $(run_get "$run" state) · $(doc_brief "$brief")")"
           s=$(printf '%s\n' "$titles" | awk -F '\t' -v t="$id" '$1 == t {print $2; exit}')
           [ -n "$s" ] && printf ' · "%s"' "$s"
           echo ;;
      esac
    done
  fi

  echo "registry:"
  if [ -n "$lost" ]; then
    printf '%s\n' "$lost" | while read -r r brief; do
      [ -n "$r" ] && echo "  run $(short "$r") · lost: running, but its terminal is gone and no agent of it is alive · $(doc_brief "${brief:--}")"
    done
  elif [ $listed = 1 ]; then echo "  no lost runs"
  else echo "  not checked (no host list)"; fi

  out=$(cmd_leftovers --quiet)
  echo "leftovers:"; if [ -n "$out" ]; then printf '%s\n' "$out" | sed 's/^/  /'; else echo "  none"; fi
  out=$(doc_locks)
  echo "locks:"; if [ -n "$out" ]; then printf '%s\n' "$out"; else echo "  none held or queued here or machine-wide"; fi
  out=$(doc_verify); nv=$?
  echo "verification worktrees:"; if [ -n "$out" ]; then printf '%s\n' "$out"; else echo "  none"; fi
  fable_status | grep -v 'blocked (backstop on)'

  if [ $apply = 0 ]; then
    { [ $((n1 + n2 + n3)) -gt 0 ] || [ $nv = 3 ]; } && echo "act on the FINISHED, lost and ORPHANED ones (nothing else is touched): handoffs/bin/jarvis doctor --apply"
    return 0
  fi

  # 1. a finished run's terminal still open: close it; stop_run stops its agent if it survives
  anc=" $(ancestors)"
  printf '%s\n' "$terms" | while read -r id class run brief; do
    [ "$class" = resumed ] && { echo "doctor: skipped $(short "$id"): a session resumed there after the brief finished"; continue; }
    [ "$class" = finished ] || continue
    s=$(printf '%s\n' "$procs" | awk -v t="$id" '$8 == t && ($4 == "busy" || $4 == "shell") {print $1}' | tr '\n' ' ')
    if [ -n "$s" ]; then echo "doctor: left $(short "$id") open: its agent is busy (pid ${s% })"; continue; fi
    if [ "$run" = - ]; then # ended, so stop_run's agent_procs leaves a resumed session alone
      run_set "$id" run "$id" brief "$brief" host "$HOST" state running ended "$(merged_at "$(doc_merged "$brief")")"
      s=merged
    else s=$(run_get "$id" state); fi
    echo "doctor: $(stop_run "$id" "$s" "jarvis doctor --apply" </dev/null) ($(doc_brief "$brief"), finished)"
  done
  # 2. a finished worker's agent whose terminal is gone: TERM, then KILL
  printf '%s\n' "$procs" | while read -r pid ps sid st class run brief term; do
    [ "$class" = finished ] || continue
    case "$anc" in *" $pid "*) continue ;; esac
    if [ $listed = 0 ]; then echo "doctor: left finished worker pid $pid: the host can't say whether its terminal is open"; continue; fi
    [ "$term" != - ] && printf '%s\n' "$open" | grep -qxF "$term" && continue # step 1 had it
    case "$st" in busy|shell) echo "doctor: left finished worker pid $pid running: it is $st"; continue ;; esac
    r=$run; [ "$r" != - ] || r=$term
    reap_left "$pid $ps $sid $st" "$r" "$brief" </dev/null | while read -r pid s; do
      echo "doctor: finished worker pid $pid ($(doc_brief "$brief"), terminal gone): $s"
    done
  done
  # 3. a running run with no terminal and no agent: lost, if that is still so
  printf '%s\n' "$lost" | while read -r r brief; do
    [ -n "$r" ] || continue
    if term_listed "$r" || [ -n "$(agent_procs "$r")" ]; then echo "doctor: left run $(short "$r"): it came back"; continue; fi
    run_set "$r" state lost ended "$(now)" reason "jarvis doctor --apply: terminal gone, no agent alive"
    audit lost "$r" "${brief:--}" "terminal=$r" "marked lost"
    echo "doctor: marked run $(short "$r") lost ($(doc_brief "${brief:--}")): its terminal is gone and no agent of it is alive"
  done
  # 4. an orphaned verification: rechecked under the checkout's verify lease, then removed
  doc_verify --apply </dev/null
}
