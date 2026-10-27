#!/usr/bin/env bash
# Offline test of `jarvis lock` and `jarvis resources` (bin/jarvis-lock.pl): FIFO
# order, capacity, SIGKILLed wrappers and waiters, --wait, nesting, --reuse, checkout
# vs host scope. Throwaway checkouts with the template's bin files, a throwaway lock
# dir (JARVIS_LOCK_DIR; ~/.jarvis is never touched), and real processes of its own,
# each in a process group the EXIT trap kills.
#
#   eval/locktest.sh
# `[ … ]; check "…" $?` reads the test's own status, and the single-quoted scripts
# expand in the shell they're written for, not this one.
# shellcheck disable=SC2016,SC2154,SC2319
set -u
here=$(cd "$(dirname "$0")" && pwd)
tpl="$here/../plugins/jarvis/skills/setup/templates"
tmp=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/jarvis-locktest.XXXXXX")" && pwd -P)
groups="$tmp/groups"
trap 'for g in $(cat "$groups" 2>/dev/null); do kill -9 -- "-$g" "$g" 2>/dev/null; done; rm -rf "$tmp"' EXIT
export JARVIS_LOCK_DIR="$tmp/locks" JARVIS_LOCK_POLL=0.05
unset JARVIS_LOCKS_HELD JARVIS_LOCK_WAIT JARVIS_REUSE_ENV JARVIS_REUSE_MAX_AGE SUPERSET_WORKSPACE_ID SUPERSET_TERMINAL_ID TMUX TMUX_PANE ULTRON_SESSION_ID
fails=0
ok() { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; fails=$((fails + 1)); }
check() { if [ "$2" = 0 ]; then ok "$1"; else bad "$1"; fi; }

ts() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
waitfor() { # $1 = seconds, then a test: poll until it holds
  local n=$(($1 * 20))
  shift
  while [ $n -gt 0 ]; do "$@" && return 0; sleep 0.05; n=$((n - 1)); done
  return 1
}
bg_in() { # $1 = dir, then a command: start it there in the background, in a process group of its own
  local d=$1
  shift
  perl -e 'chdir(shift) or die "chdir: $!"; setpgrp(0, 0); exec { $ARGV[0] } @ARGV or die "exec: $!"' "$d" "$@" 2>>"$tmp/bg.err" &
  bgpid=$!
  echo "$bgpid" >> "$groups"
}
stop() { kill -9 -- "-$1" "$1" 2>/dev/null; wait "$1" 2>/dev/null; } # a group bg_in started
free() { (cd "$1" && handoffs/bin/jarvis lock "$2" --wait 0 -- true 2>/dev/null); } # $1 = checkout, $2 = class
mkrepo() { # $1 = dir: a checkout with the template's bin files and one extra class
  mkdir -p "$1/handoffs/bin" "$1/sub" && (
    cd "$1" && git init -q
    cp "$tpl/handoffs/bin/jarvis" "$tpl/handoffs/bin/jarvis-lock.pl" handoffs/bin/
    sed -e 's/{{MAX_CLAUDE}}/3/' -e 's/{{AMBER}}/50/' -e 's/{{RED}}/75/' "$tpl/handoffs/jarvis.conf" > handoffs/jarvis.conf
    echo 'JARVIS_LOCK_pair="host 2"' >> handoffs/jarvis.conf
    echo a > app.txt && echo s > sub/s.txt
    git add -A && git -c user.name=t -c user.email=t@t commit -qm init
  )
}

# job <name> <seconds> <log>: logs when it starts and ends
printf '%s\n' '#!/bin/sh' 't() { perl -MTime::HiRes=time -e '"'"'printf "%.3f", time'"'"'; }' \
  'echo "$1 start $(t)" >> "$3"; sleep "$2"; echo "$1 end $(t)" >> "$3"' > "$tmp/job"
# hold <flag> <seconds>: says it has the lease, then holds it from a child process too
printf '%s\n' '#!/bin/sh' 'touch "$1"; sleep "$2"' > "$tmp/hold"
# stamp <file>: the time it ran
printf '%s\n' '#!/bin/sh' 'perl -MTime::HiRes=time -e '"'"'printf "%.3f\n", time'"'"' > "$1"' > "$tmp/stamp"
chmod +x "$tmp/job" "$tmp/hold" "$tmp/stamp"

r1="$tmp/r1"; r2="$tmp/r2"
mkrepo "$r1"; mkrepo "$r2"
cd "$r1" || exit 1
J=handoffs/bin/jarvis

echo "1. FIFO on one machine-wide slot"
L="$tmp/t1.log"; pids=""
for i in 1 2 3 4; do bg_in "$r1" "$J" lock docker -- "$tmp/job" "j$i" 0.4 "$L"; pids="$pids $bgpid"; sleep 0.2; done
for p in $pids; do wait "$p"; done
[ "$(awk '$2 == "start" {print $3, $1}' "$L" | sort -n | awk '{printf "%s ", $2}')" = "j1 j2 j3 j4 " ]; check "four waiters run in the order they started" $?
awk '{t[$1 " " $2] = $3} END {for (i = 2; i <= 4; i++) if (t["j" i " start"] < t["j" (i - 1) " end"]) exit 1; if (NR != 8) exit 1}' "$L"; check "…and their runs never overlap" $?

echo "2. classes and capacity"
bg_in "$r1" "$J" lock docker -- "$tmp/hold" "$tmp/f2" 30; h2=$bgpid
waitfor 5 test -e "$tmp/f2"
$J lock suite --wait 0 -- true; check "a suite lock runs while docker is held" $?
bg_in "$r1" "$J" lock pair -- "$tmp/hold" "$tmp/f2a" 30; p2a=$bgpid
bg_in "$r1" "$J" lock pair -- "$tmp/hold" "$tmp/f2b" 30; p2b=$bgpid
waitfor 5 test -e "$tmp/f2a" && waitfor 5 test -e "$tmp/f2b"; check "capacity 2 runs two at once" $?
$J lock pair --wait 0 -- true 2>/dev/null; [ $? = 75 ]; check "…and the third waits" $?
stop "$h2"; stop "$p2a"; stop "$p2b"

echo "3. a SIGKILLed wrapper"
waitfor 5 free "$r1" docker
bg_in "$r1" "$J" lock docker -- "$tmp/hold" "$tmp/f3" 30; w3=$bgpid
waitfor 5 test -e "$tmp/f3"
kill -9 "$w3"; wait "$w3" 2>/dev/null
$J lock docker --wait 0 -- true 2>/dev/null; [ $? = 75 ]; check "its command (and the command's child) keep the lease" $?
bg_in "$r1" "$J" lock docker --wait 20 -- "$tmp/stamp" "$tmp/f3b"; n3=$bgpid
sleep 0.5; t0=$(ts); kill -9 -- "-$w3"
waitfor 5 test -s "$tmp/f3b" && awk -v t0="$t0" '{exit !($1 - t0 < 1)}' "$tmp/f3b"; check "killing the group frees it: the next waiter runs at once" $?
wait "$n3"

echo "4. a SIGKILLed waiter"
bg_in "$r1" "$J" lock docker -- "$tmp/hold" "$tmp/f4" 30; h4=$bgpid
waitfor 5 test -e "$tmp/f4"
bg_in "$r1" "$J" lock docker --wait 30 -- "$tmp/stamp" "$tmp/f4a"; w4a=$bgpid; sleep 0.3
bg_in "$r1" "$J" lock docker --wait 30 -- "$tmp/stamp" "$tmp/f4b"; w4b=$bgpid; sleep 0.3
[ "$(ls "$JARVIS_LOCK_DIR/docker.q" | wc -l | tr -d ' ')" = 2 ]; check "two waiters, two tickets" $?
kill -9 "$w4a"; wait "$w4a" 2>/dev/null
stop "$h4"
waitfor 5 test -s "$tmp/f4b" && [ ! -e "$tmp/f4a" ]; check "the queue moves past the dead waiter" $?
wait "$w4b"
[ -z "$(ls "$JARVIS_LOCK_DIR/docker.q")" ]; check "…and its ticket is pruned" $?

echo "5. --wait and errors"
bg_in "$r1" env SUPERSET_TERMINAL_ID=locktest-t5 "$J" lock docker -- "$tmp/hold" "$tmp/f5" 30; h5=$bgpid
waitfor 5 test -e "$tmp/f5"
s=$(ts); out=$($J lock docker --wait 1 -- true 2>&1); rc=$?
[ $rc = 75 ] && printf '%s' "$out" | grep -q 'gave up after 1s — held by pid [0-9]* (term locktest, [0-9]*s: .*hold'; check "--wait 1 on a held lock: exit 75, naming the holder" $?
awk -v s="$s" -v e="$(ts)" 'BEGIN {exit !(e - s >= 1 && e - s < 3)}'; check "…after about a second" $?
printf '%s' "$out" | grep -q 'waiting — held by pid'; check "…and says it's waiting first" $?
out=$($J lock nosuch -- true 2>&1); [ $? = 2 ] && printf '%s' "$out" | grep -q 'JARVIS_LOCK_nosuch="host 1"'; check "unknown class: exit 2, naming the conf line" $?
out=$(JARVIS_LOCK_odd="nowhere x" $J lock odd -- true 2>&1); [ $? = 2 ] && printf '%s' "$out" | grep -q "isn't"; check "malformed class: exit 2" $?
$J lock 'Bad-Name' -- true 2>/dev/null; [ $? = 2 ]; check "a class name outside [a-z0-9_]: exit 2" $?

echo "8. resources"
bg_in "$r1" "$J" lock docker --wait 30 -- true; q8=$bgpid; sleep 0.3
printf 'pid: 99999\nstart: 1\ncmd: ghost run\n' > "$JARVIS_LOCK_DIR/ghost.slot0"
out=$($J resources)
printf '%s\n' "$out" | grep -q '^  slot 0  held  pid [0-9]* · term locktest · [0-9]*s · .*/f5 30$' && printf '%s\n' "$out" | grep -q '^  queue 1 waiting'; check "shows the holder and the queue while held" $?
printf '%s\n' "$out" | sed -n '/^ghost/,/^[a-z]/p' | grep -q 'slot 0  free  (stale'; check "…and a stale record as free" $?
$J resources --json | perl -MJSON::PP -e 'my %k = map { $_->{key} => $_ } @{ decode_json(join "", <STDIN>) };
  exit !($k{docker}{slots}[0]{held} && $k{docker}{queue}{waiting} == 1 && !$k{ghost}{slots}[0]{held} && $k{ghost}{slots}[0]{stale})'; check "--json says the same" $?
stop "$h5"; wait "$q8"

echo "6. nesting, exit status, directory"
out=$($J lock docker --wait 5 -- "$J" lock docker --wait 5 -- sh -c 'exit 3' 2>&1); rc=$?
[ $rc = 3 ]; check "a nested same-class lock doesn't deadlock; exit 3 comes back as 3" $?
[ "$($J lock suite -- sh -c 'echo "$JARVIS_LOCKS_HELD"')" = "suite@$(printf '%s' "$r1" | perl -MDigest::SHA=sha1_hex -ne 'print substr(sha1_hex($_), 0, 12)')" ]; check "the command sees JARVIS_LOCKS_HELD with its key" $?
[ "$(cd sub && ../handoffs/bin/jarvis lock suite -- pwd -P)" = "$r1/sub" ]; check "the command runs in the caller's subdirectory" $?
$J lock suite -- sh -c 'kill -TERM $$'; [ $? = 143 ]; check "a command killed by TERM: exit 143" $?
bg_in "$r1" "$J" lock suite -- perl -e '$SIG{TERM} = sub { exit 7 }; open F, ">", shift; close F; sleep 30' "$tmp/f6"; w6=$bgpid
waitfor 5 test -e "$tmp/f6"; kill -TERM "$w6"; wait "$w6"; [ $? = 7 ]; check "TERM to the wrapper is forwarded to the command" $?

echo "7. --reuse"
R="$tmp/t7.log"
run7() { $J lock suite --reuse -- sh -c 'echo ran >> "$1"' _ "$R" 2>"$tmp/t7.err"; }
lines() { wc -l < "$1" | tr -d ' '; }
run7; run7; [ "$(lines "$R")" = 1 ] && grep -q 'not re-running' "$tmp/t7.err"; check "a second identical run is skipped" $?
grep -q 'without --reuse' "$tmp/t7.err"; check "…saying how to run it anyway" $?
echo b >> app.txt; run7; [ "$(lines "$R")" = 2 ]; check "editing a tracked file reruns" $?
echo n > new.txt; run7; [ "$(lines "$R")" = 3 ]; check "adding an untracked file reruns" $?
printf 'ign.txt\n' > .gitignore; run7; echo x > ign.txt; run7; [ "$(lines "$R")" = 4 ]; check "an ignored file doesn't" $?
(cd sub && ../handoffs/bin/jarvis lock suite --reuse -- sh -c 'echo ran >> "$1"' _ "$R" 2>/dev/null); [ "$(lines "$R")" = 5 ]; check "another directory reruns" $?
F="$tmp/t7f.log"
for i in 1 2; do $J lock suite --reuse -- sh -c 'echo ran >> "$1"; exit 1' _ "$F" 2>/dev/null; done; [ "$(lines "$F")" = 2 ]; check "a failure is never reused" $?
[ -z "$(git diff --cached --name-only)" ] && ! git ls-files --error-unmatch new.txt >/dev/null 2>&1; check "the real index is never written" $?

echo "9. scope"
bg_in "$r1" "$J" lock suite -- "$tmp/hold" "$tmp/f9" 30; h9=$bgpid
waitfor 5 test -e "$tmp/f9"
free "$r2" suite; check "checkout scope: another checkout isn't blocked" $?
free "$r1" suite; [ $? = 75 ]; check "…the same checkout is" $?
grep -qx "$r1" "$JARVIS_LOCK_DIR"/suite@*.where; check "…and the lock dir names it" $?
bg_in "$r1" "$J" lock docker -- "$tmp/hold" "$tmp/f9b" 30; h9b=$bgpid
waitfor 5 test -e "$tmp/f9b"
free "$r2" docker; [ $? = 75 ]; check "host scope blocks across checkouts" $?
stop "$h9"; stop "$h9b"

echo "no Jarvis state"
nr="$tmp/plain"; mkdir -p "$nr"
(cd "$nr" && git init -q && cp -R "$tpl/handoffs" . && rm -f handoffs/jarvis.conf handoffs/OPEN.md && handoffs/bin/jarvis lock docker -- true); check "runs with no jarvis.conf, no OPEN.md and no host" $?
rm -f "$nr/handoffs/bin/jarvis-lock.pl"; out=$(cd "$nr" && handoffs/bin/jarvis lock docker -- touch "$nr/ran" 2>&1); [ $? = 2 ] && [ ! -e "$nr/ran" ] && printf '%s' "$out" | grep -q 'jarvis:setup'; check "without bin/jarvis-lock.pl: exit 2, command not run" $?

echo; [ "$fails" = 0 ] && echo "locktest: all passed" || { echo "locktest: $fails failed"; exit 1; }
