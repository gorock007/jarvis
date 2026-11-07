#!/usr/bin/env bash
# Phase 3 done-when, measured (research plan v0.8-v1.0, Phase 3):
#   1. after a Claude worker writes its handoff, does the watcher wake Jarvis within one tick?
#   2. how many false stall wake-ups does a working Claude worker cause with worker events on,
#      against the screen hash alone (events off)? Target: 80% fewer.
# Every run is a throwaway git repo with a copy of the template's handoffs/, on the tmux host, on
# a tmux server of its own (its own socket, killed by that socket on exit). Nothing else is touched.
# The "Jarvis" is a pane running `cat`. The workers are fake agents (shell scripts that make the
# same `jarvis hook event` calls a Claude worker's hooks make, and hold a screen frozen or changing),
# so the counts are deterministic; one real `claude --model claude-haiku-5-5` worker (P3_REAL=1)
# measures latency only, to show the real hooks fire.
#
# Events on / off: the watcher has no switch of its own. It reads the worker's event file when there
# is one and falls back to the screen hash when there isn't, so "events off" is a worker that makes no
# hook calls (what a repo without the Phase 3 hooks in .claude/settings.json looks like) and
# "events on" is the same worker making them.
#
# Knobs (env): P3_WATCH_SEC=5 (the tick, default 60 in jarvis), P3_STALL_MIN=1 (default 15),
# P3_REPS=3, P3_PAR=15 (runs at once), P3_REAL=1, P3_ONLY="b:on c:off" (just those cells, for debugging).
# Takes about 6 minutes at the defaults. Run with bash or /bin/bash (3.2).
set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
tpl="$repo/plugins/jarvis/skills/setup/templates"
WATCH_SEC=${P3_WATCH_SEC:-5}
STALL_MIN=${P3_STALL_MIN:-1}
BUSY_MIN=$(( STALL_MIN * 45 / 15 ))   # JARVIS_BUSY_STALL_MIN, scaled as the stall is (default 45 to 15)
REPS=${P3_REPS:-3}
PAR=${P3_PAR:-15}
REAL=${P3_REAL:-1}
ONLY=${P3_ONLY:-}
HOLD=$(( STALL_MIN * 180 - 15 ))   # b: the frozen stretch; past two stall intervals, so a stall wake is possible
LIMIT=$(( STALL_MIN * 300 ))       # c, d: how long to wait for a wake
SLACK_MS=1000                      # pane polling (250 ms) and tmux send-keys on top of the watcher's own tick

for need in tmux jq git perl python3; do
  command -v "$need" >/dev/null 2>&1 || { echo "phase3-measure: needs $need" >&2; exit 2; }
done
[ -d "$tpl/handoffs" ] || { echo "phase3-measure: no template at $tpl/handoffs" >&2; exit 2; }

work=$(mktemp -d "${TMPDIR:-/tmp}/p3measure.XXXXXX") || exit 2
work=$(cd "$work" && pwd -P)
sock="jarvis-p3measure-$$"
res="$work/res"; mkdir -p "$res"
TM() { env -u TMUX -u TMUX_PANE tmux -L "$sock" "$@"; }

cleanup() {
  trap - EXIT INT TERM
  jobs -p | while read -r p; do kill "$p" 2>/dev/null; done
  # this run's own tmux server, by its socket; its panes (fake agents, watchers, `cat`) go with it
  TM kill-server >/dev/null 2>&1
  rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$sock"
  [ -n "${P3_KEEP:-}" ] && echo "kept $work" || rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
trap 'exit 141' PIPE   # `| tail` closing early still cleans up

ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000'; }

# ---- the snapshot: one copy of the template, taken now, that every run copies from
snap="$work/snap"; mkdir -p "$snap"
cp -R "$tpl/handoffs" "$snap/handoffs"
[ -d "$tpl/.claude" ] && cp -R "$tpl/.claude" "$snap/.claude"
rm -f "$snap/handoffs/bin/jev.sh"

# ---- the fake agent: sh <scenario> <on|off> <bash> <hold seconds> <marker file>
cat > "$work/fake-agent.sh" <<'FAKE'
#!/bin/sh
scen=$1; evs=$2; bashbin=$3; hold=$4; mark=$5
ev() { [ "$evs" = on ] || return 0; printf '%s' "${2:-}" | "$bashbin" handoffs/bin/jarvis hook event "$1"; }
ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000'; }
handoff() {
  printf '# fake %s\nstatus: done\nagent: claude fake\nbrief: %s\n' "$scen" "${JARVIS_BRIEF:-}" > "handoffs/p3-$scen.md"
  ms > "$mark"
}
echo "fake claude worker, scenario $scen"
ev working
case "$scen" in
  a) i=0; while [ "$i" -lt 6 ]; do i=$((i + 1)); echo "working, step $i"; sleep 1; done
     handoff; ev stop '{"last_assistant_message":"handoff written"}'; sleep 3600 ;;
  b) echo "running a long tool call…"; sleep "$hold"      # the screen is frozen, the worker is not
     handoff; ev stop '{"last_assistant_message":"handoff written"}'; sleep 3600 ;;
  c) echo "stuck: nothing will change and no handoff is coming"; sleep 3600 ;;
  d) i=0; while [ "$i" -lt 4 ]; do i=$((i + 1)); echo "working, step $i"; sleep 2; done
     ev ended '{"reason":"other"}'; exit 0 ;;
esac
FAKE

# ---- one run ("cell"): $1 id, $2 scenario (a|b|c|d|real), $3 on|off, $4 batch seconds, $5 rep
run_cell() {
  local scen=$2 evs=$3 batch=$4 rep=$5 d="$work/cell-$1" out="$res/$1"
  local trusted=0 lastscr="" wscr sess="c$1" sr jp tenv wk t0 tw sp="" n pat limit pane
  mkdir -p "$d" && cd "$d" || return 1
  git init -q && git config user.email p3@example.com && git config user.name p3 && git commit -q --allow-empty -m init
  cp -R "$snap/handoffs" . && [ ! -d "$snap/.claude" ] || cp -R "$snap/.claude" .
  sed -e 's/{{MAX_CLAUDE}}/3/' -e 's/{{AMBER}}/50/' -e 's/{{RED}}/75/' "$snap/handoffs/jarvis.conf" > handoffs/jarvis.conf
  {
    echo "JARVIS_PUSH=0"
    echo "JARVIS_WATCH_SEC=$WATCH_SEC"
    echo "JARVIS_STALL_MIN=$STALL_MIN"
    echo "JARVIS_BUSY_STALL_MIN=$BUSY_MIN"
    echo "JARVIS_BATCH_SEC=$batch"
    [ "$scen" = real ] || echo "JARVIS_AGENT_claude='sh \"$work/fake-agent.sh\" $scen $evs \"$BASH\" $HOLD \"$d/t_handoff\"'"
  } >> handoffs/jarvis.conf
  if [ "$scen" = real ]; then
    printf '# real\nworker: claude\nmodel: claude-haiku-5-5\neffort: low\nstarted: <x>\n\n## Goal\nWrite the file handoffs/p3-real.md with exactly these three lines and do nothing else (no other tools, no other files):\n\n# real\nstatus: done\nbrief: handoffs/briefs/2026-11-08-1200-p3.md\n' > handoffs/briefs/2026-11-08-1200-p3.md
  else
    printf '# p3 %s\nworker: claude\nmodel: claude-haiku-5-5\neffort: low\nstarted: <x>\n' "$scen" > handoffs/briefs/2026-11-08-1200-p3.md
  fi
  git add -A && git commit -q -m setup
  # Jarvis: a pane running cat; the room it shares with its workers is this cell's tmux session
  jp=$(TM new-session -d -s "$sess" -c "$d" -x 160 -y 40 -P -F '#{pane_id}' "cat # $work")
  tenv=$(TM display-message -p '#{socket_path},#{pid},0')
  J() { env -u SUPERSET_WORKSPACE_ID -u SUPERSET_TERMINAL_ID TMUX="$tenv" TMUX_PANE="$jp" JARVIS_HOME="$d/jh" "$BASH" handoffs/bin/jarvis "$@"; }
  sr=$(J start 2>&1) || { printf 'scen=%s\nerror start: %s\n' "$scen" "$sr" > "$out"; return 1; }
  # the watcher, in a window of the cell's session, under the bash this script runs on
  TM new-window -d -t "$sess:" -n jarvis-watch -c "$d" \
    "env -u SUPERSET_WORKSPACE_ID -u SUPERSET_TERMINAL_ID JARVIS_HOME='$d/jh' '$BASH' handoffs/bin/jarvis watch; sleep 3600 # $work"
  sleep $(( WATCH_SEC + 1 ))   # its first pass only learns what is already there
  t0=$(ms)
  # The fake agents burn no usage, so they pass the machine-wide Claude cap (other projects' workers
  # fill it) with --force; the real haiku worker does not: if the cap refuses it, that is reported.
  [ "$scen" = real ] || sp=--force
  sr=$(J spawn handoffs/briefs/2026-11-08-1200-p3.md $sp 2>&1)
  wk=$(printf '%s\n' "$sr" | sed -n 's/^spawned \([^ ]*\) .*/\1/p')
  if [ -z "$wk" ]; then printf 'scen=%s\nerror spawn: %s\n' "$scen" "$sr" > "$out"; return 1; fi
  case "$scen" in
    a) limit=60 ;;
    real) limit=240 ;;
    b) limit=$(( HOLD + 60 )) ;;
    *) limit=$LIMIT ;;
  esac
  case "$scen" in
    a|b|real) pat='handoff handoffs/p3-' ;;
    c) pat="hasn't changed|finished its turn|mid-turn" ;;
    d) pat="ended without a handoff|hasn't changed" ;;
  esac
  tw=""; n=0
  while [ "$n" -lt $(( limit * 4 )) ]; do
    pane=$(TM capture-pane -p -J -t "$jp" 2>/dev/null)
    if printf '%s\n' "$pane" | grep '\[jarvis watch\]' | grep -Eq "$pat"; then tw=$(ms); break; fi
    if [ "$scen" = real ] && [ $(( n % 8 )) = 0 ]; then
      wscr=$(TM capture-pane -p -t "$wk" 2>/dev/null | sed -e 's/[[:space:]]*$//' | grep .)
      [ "$wscr" = "$lastscr" ] || { printf -- '--- +%ss\n%s\n' "$(( n / 4 ))" "$wscr" >> "$res/$1.screen"; lastscr=$wscr; }
      # A fresh folder asks "trust this folder?", with "No, exit" highlighted. This folder is the run's own
      # throwaway copy of the template, so in this one worker's pane: Down to "Yes", then Enter.
      if [ "$trusted" = 0 ] && printf '%s\n' "$wscr" | grep -q '❯ No, exit' && printf '%s\n' "$wscr" | grep -q 'Yes, I trust this folder'; then
        TM send-keys -t "$wk" Down && sleep 0.5 && TM send-keys -t "$wk" Enter && trusted=1
      fi
    fi
    sleep 0.25; n=$(( n + 1 ))
  done
  # the watcher logs a wake just after it sends it; b also gets two more ticks to show nothing else follows
  [ -z "$tw" ] || { [ "$scen" != b ] && sleep 2 || sleep $(( WATCH_SEC * 2 )); }
  # the numbers, from the cell's own watch.log
  local log="$d/handoffs/.jarvis/watch.log" woke stallw nudges srcs hw
  woke=$(awk -F'\t' '$2=="woke"||$2=="cleared"' "$log" 2>/dev/null)
  stallw=$(printf '%s\n' "$woke" | awk -F'\t' '$3 ~ /stall/' | grep -c .)
  hw=$(printf '%s\n' "$woke" | awk -F'\t' '$3 ~ /handoff/' | grep -c .)
  nudges=$(awk -F'\t' '$2=="auto" && $3=="nudge"' "$log" 2>/dev/null | grep -c .)
  srcs=$(awk -F'\t' '$2=="source" {print $3}' "$log" 2>/dev/null | sort | uniq -c | awk '{printf "%s%s×%s", s, $2, $1; s=" "}')
  {
    echo "scen=$scen"; echo "ev=$evs"; echo "batch=$batch"; echo "rep=$rep"
    echo "woke=$(printf '%s\n' "$woke" | grep -c .)"; echo "stall_wakes=$stallw"; echo "handoff_wakes=$hw"; echo "nudges=$nudges"
    echo "sources=${srcs:--}"
    if [ -n "$tw" ]; then echo "found=1"; echo "since_spawn_ms=$(( tw - t0 ))"; else echo "found=0"; fi
    if [ -n "$tw" ] && [ -f "$d/t_handoff" ]; then echo "latency_ms=$(( tw - $(cat "$d/t_handoff") ))"; fi
  } > "$out"
  if [ "$scen" = real ]; then
    # the real hooks: which event lines did the worker's Claude Code write?
    { echo "events=$(cat "$d"/handoffs/.jarvis/events/*.jsonl 2>/dev/null | jq -r '.kind' 2>/dev/null | sort | uniq -c | awk '{printf "%s%s×%s", s, $2, $1; s=" "}')"
      [ -f "$d/handoffs/p3-real.md" ] && echo "mtime_epoch=$(stat -f %m "$d/handoffs/p3-real.md" 2>/dev/null || stat -c %Y "$d/handoffs/p3-real.md")"
      echo "wake_epoch_s=$(( ${tw:-0} / 1000 ))"; } >> "$out"
  fi
  TM kill-session -t "$sess" >/dev/null 2>&1
  return 0
}

# ---- the plan
cells=""
for rep in $(seq "$REPS"); do
  for evs in on off; do
    cells="$cells a:$evs:0:$rep a:$evs:$WATCH_SEC:$rep b:$evs:0:$rep c:$evs:0:$rep d:$evs:0:$rep"
  done
done
[ "$REAL" = 1 ] && command -v claude >/dev/null 2>&1 && cells="$cells real:on:0:1"
if [ -n "$ONLY" ]; then
  keep=""
  for c in $cells; do
    for o in $ONLY; do
      case "$c" in "${o%%:*}:${o#*:}:"*) keep="$keep $c" ;; esac
    done
  done
  cells=$keep
fi

total=$(printf '%s\n' $cells | grep -c .)
echo "phase3-measure: $total runs, tick ${WATCH_SEC}s, stall ${STALL_MIN} min, busy stall ${BUSY_MIN} min, bash $BASH_VERSION, tmux server $sock"
TM start-server \; new-session -d -s p3-anchor "sleep 86400 # $work" 2>/dev/null
i=0
for c in $cells; do
  i=$((i + 1))
  while [ "$(jobs -r | grep -c .)" -ge "$PAR" ]; do sleep 1; done
  IFS=: read -r s e b r <<EOF
$c
EOF
  ( run_cell "$i" "$s" "$e" "$b" "$r" ) &
  sleep 0.3
done
wait

# ---- the tables
field() { sed -n "s/^$2=//p" "$1" | head -n 1; }
rows() { # scen, ev, batch: the result files of those runs
  local f
  for f in "$res"/*; do
    case "$f" in *.screen) continue ;; esac
    [ "$(field "$f" scen)" = "$1" ] && [ "$(field "$f" ev)" = "$2" ] && { [ -z "${3:-}" ] || [ "$(field "$f" batch)" = "$3" ]; } && echo "$f"
  done
}
stat_ms() { # min / median / max in seconds of the given ms values (stdin, one per line)
  sort -n | awk 'NF {v[++n]=$1} END {if (!n) {print "-"; exit}; m=v[int((n+1)/2)]; printf "%.1f / %.1f / %.1f", v[1]/1000, m/1000, v[n]/1000}'
}
errs=0
for f in "$res"/*; do
  case "$f" in *.screen) continue ;; esac
  grep -q '^error' "$f" && [ "$(field "$f" scen)" != real ] && { errs=$((errs + 1)); grep -h '^error' "$f"; }
done
fails=0

echo
echo "LATENCY: seconds from the worker writing its handoff to Jarvis's pane showing the wake (min / median / max)"
printf '%-28s %-7s %-5s %-22s %-16s %s\n' "watcher config" events runs "seconds" "ticks (median)" "within one tick"
for batch in 0 "$WATCH_SEC"; do
  for e in on off; do
    vals=""; ok=0; nrun=0
    for f in $(rows a "$e" "$batch"); do
      nrun=$((nrun + 1)); l=$(field "$f" latency_ms)
      [ -n "$l" ] && vals="$vals $l" && [ "$l" -le $(( WATCH_SEC * 1000 + SLACK_MS )) ] && ok=$((ok + 1))
    done
    med=$(printf '%s\n' $vals | sort -n | awk 'NF {v[++n]=$1} END {if (n) printf "%.2f", v[int((n+1)/2)]/('"$WATCH_SEC"'*1000)}')
    printf '%-28s %-7s %-5s %-22s %-16s %s\n' "JARVIS_BATCH_SEC=$batch" "$e" "$nrun" "$(printf '%s\n' $vals | stat_ms)" "${med:--}" "$ok/$nrun"
  done
done
for f in "$res"/*; do
  case "$f" in *.screen) continue ;; esac
  [ "$(field "$f" scen)" = real ] || continue
  grep -q '^error' "$f" && { echo "real claude haiku worker: not run: $(grep -h '^error' "$f")"; continue; }
  if [ "$(field "$f" found)" = 1 ]; then
    hm=$(field "$f" mtime_epoch)
    printf 'real claude haiku worker: events written: %s; handoff file mtime %s, wake seen by %s (whole seconds); latency %s s\n' \
      "$(field "$f" events)" "${hm:--}" "$(field "$f" wake_epoch_s)" "$(( $(field "$f" wake_epoch_s) - ${hm:-0} ))"
  else
    printf 'real claude haiku worker: no wake seen (events written: %s); screen saved as %s\n' "$(field "$f" events)" "$f.screen"
    [ -s "$f.screen" ] && sed 's/^/    | /' "$f.screen" | tail -n 12
  fi
done

echo
echo "FALSE STALLS: b = a working worker (frozen screen for ${HOLD}s, then a handoff). Stall wake-ups and nudges before the handoff are false."
printf '%-8s %-6s %-22s %-20s %s\n' scenario events "stall wake-ups per run" "nudges per run" "watcher sources"
tot_on=0; tot_off=0
for e in on off; do
  sw=""; nu=""; so=""; sum=0
  for f in $(rows b "$e"); do
    sw="$sw${sw:+,}$(field "$f" stall_wakes)"; nu="$nu${nu:+,}$(field "$f" nudges)"; so="$so $(field "$f" sources)"
    sum=$(( sum + $(field "$f" stall_wakes) ))
  done
  printf '%-8s %-6s %-22s %-20s %s\n' b "$e" "${sw:--} (total $sum)" "${nu:--}" "$(printf '%s\n' $so | sort | uniq -c | awk '{printf "%s%s", s, $2; s=" "}')"
  [ "$e" = on ] && tot_on=$sum || tot_off=$sum
done
if [ "$tot_off" -gt 0 ]; then
  red=$(( (tot_off - tot_on) * 100 / tot_off ))
  if [ "$red" -ge 80 ]; then verdict=PASS; else verdict=FAIL; fails=$((fails + 1)); fi
  echo "reduction with events on: ${red}% (target 80%): $verdict"
else
  echo "reduction with events on: n/a (no false stall wake-ups with events off)"
fi

echo
echo "CORRECT WAKES: c = truly stuck worker (stall wake is right, events must not hide it); d = worker that ends with no handoff"
printf '%-8s %-6s %-12s %s\n' scenario events "woke" "seconds from spawn to wake (min / median / max)"
for s in c d; do
  for e in on off; do
    n=0; g=0; vals=""
    for f in $(rows "$s" "$e"); do
      n=$((n + 1)); [ "$(field "$f" found)" = 1 ] && { g=$((g + 1)); vals="$vals $(field "$f" since_spawn_ms)"; }
    done
    printf '%-8s %-6s %-12s %s\n' "$s" "$e" "$g/$n" "$(printf '%s\n' $vals | stat_ms)"
    [ "$e" = on ] && [ "$g" -lt "$n" ] && fails=$((fails + 1))
  done
done
[ "$errs" = 0 ] || { echo "runs that failed to start: $errs"; fails=$((fails + 1)); }
echo
[ "$fails" = 0 ] && echo "phase3-measure: done" || echo "phase3-measure: done, $fails part(s) missed the target (see above)"
exit 0
