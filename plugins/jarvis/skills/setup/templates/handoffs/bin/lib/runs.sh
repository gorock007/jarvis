# shellcheck shell=bash
# Sourced by bin/jarvis; not run on its own.
# ---------------------------------------------------------------- runs

# One file per spawn, handoffs/.jarvis/runs/<run>, run = the terminal id the host
# returned: "key: value" lines (run, brief, agent, model, effort, host, spawned,
# state, ended, reason, outcome); state is running | merged | closed | lost. It
# holds what spawn and close decided. Whether a process is alive is asked of ps,
# Claude Code's session records and the host each time, never stored.
RUNS="$STATE/runs"

run_ok() { case "$1" in ""|.|..|*[!A-Za-z0-9_%.-]*) return 1 ;; esac; }

# Every update is read, merged and moved into place under a kernel flock on the
# record's own lock file, handoffs/.jarvis/run-locks/<run>.write-lock (outside runs/,
# so runs_of never reads one), so merge --verify, watch and close writing at once
# don't lose each other's keys. jarvis-verify.py writes through _run-set, the same lock.
RUN_SET_PL='
use strict; use warnings; use Fcntl qw(:DEFAULT :flock);
my ($lk, $f, $need, $ck, $cv, @kv) = @ARGV;
sysopen(my $l, $lk, O_RDWR | O_CREAT, 0600) or die "jarvis: cannot open $lk: $!\n";
flock($l, LOCK_EX) or die "jarvis: cannot lock $lk: $!\n";
exit 4 if $need && !-f $f;
my @r;
if (open(my $in, "<", $f)) { @r = <$in>; close $in; chomp @r }
if (length $ck) { my ($v) = map { substr($_, length($ck) + 2) } grep { index($_, "$ck: ") == 0 } @r; exit 3 if ($v // "") ne $cv }
while (@kv >= 2) {
  my ($k, $v) = splice @kv, 0, 2;
  $v =~ s/\n/ /g;
  my ($done, @o) = (0);
  for (@r) { if (index($_, "$k: ") == 0 || $_ eq "$k:") { push @o, "$k: $v" unless $done++; next } push @o, $_ }
  push @o, "$k: $v" unless $done;
  @r = @o;
}
(my $tmp = $f) =~ s{([^/]*)$}{.tmp.$1.$$};
sysopen(my $o, $tmp, O_WRONLY | O_CREAT | O_TRUNC, 0600) or die "jarvis: cannot write $tmp: $!\n";
print $o map { "$_\n" } @r;
close $o or die "jarvis: cannot write $tmp: $!\n";
rename $tmp, $f or do { unlink $tmp; die "jarvis: cannot replace $f: $!\n" };
'

run_write() { # $1 = run, $2 = 1: only an existing record (else exit 4), $3 $4 = only while key $3 is $4 (else exit 3; "" = always), then <key> <value> pairs
  local lk="$STATE/run-locks"
  [ "$RUNS" = "$STATE/runs" ] || lk="$lk/${RUNS##*/}"
  mkdir -p "$RUNS" "$lk" || return 1
  perl -e "$RUN_SET_PL" "$lk/$1.write-lock" "$RUNS/$1" "$2" "$3" "$4" "${@:5}"
}

run_set() { # $1 = run, then <key> <value> pairs
  local run=$1 f tmp
  run_ok "$run" || return 1
  shift
  if have perl; then run_write "$run" 0 "" "" "$@"; return; fi
  [ -n "${RUN_SET_WARNED:-}" ] || echo "jarvis: no perl here, so run records are written without their lock; an update made at the same moment can be lost" >&2
  RUN_SET_WARNED=1
  mkdir -p "$RUNS" && tmp=$(mktemp "$RUNS/.tmp.XXXXXX") || return 1
  f="$RUNS/$run"
  [ -f "$f" ] && cat "$f" > "$tmp"
  while [ $# -ge 2 ]; do
    J_V=$(printf '%s' "$2" | tr '\n' ' ') awk -v k="$1" '
      index($0, k ": ") == 1 || $0 == k ":" { if (!done) print k ": " ENVIRON["J_V"]; done = 1; next }
      {print} END { if (!done) print k ": " ENVIRON["J_V"] }' "$tmp" > "$tmp.n" && mv "$tmp.n" "$tmp"
    shift 2
  done
  mv "$tmp" "$f"
}

run_resolve() { # $1 = a terminal id, maybe cut short as status prints it: the run whose id it is or starts, else $1 unchanged (the host may know it); dies naming the runs when it starts several
  local f m="" n=0
  run_ok "$1" && [ ! -f "$RUNS/$1" ] || { printf '%s\n' "$1"; return 0; }
  for f in "$RUNS/$1"*; do
    [ -f "$f" ] || continue
    case ${f##*/} in .*) continue ;; esac   # run_set's temp files
    m="$m ${f##*/}"; n=$((n + 1))
  done
  [ "$n" -le 1 ] || die "$1 starts $n runs:$m; give more of the id"
  m=${m# }
  printf '%s\n' "${m:-$1}"
}

run_get() { # $1 = run, $2 = key
  run_ok "$1" && [ -f "$RUNS/$1" ] || return 0
  awk -v k="$2" 'index($0, k ": ") == 1 {print substr($0, length(k) + 3); exit}' "$RUNS/$1"
}

cmd_run_set() { # merge --verify's record writes: _run-set [--if <key> <value>] <run> <key> <value>…; never creates a record
  local ck="" cv="" run
  if [ "${1:-}" = --if ]; then ck=${2:-}; cv=${3:-}; shift 3 || exit 2; fi
  run=${1:-}
  run_ok "$run" || exit 4
  have perl || { echo "jarvis _run-set: needs perl for the record's lock" >&2; exit 2; }
  shift
  run_write "$run" 1 "$ck" "$cv" "$@" # 1: whether the record exists is asked under its lock
}

runs_of() { # $1 = brief, $2 = only runs in this state: the runs spawned from that brief, oldest first
  local b=$1 s=${2:-}
  set -- "$RUNS"/*
  [ -f "$1" ] || return 0
  awk -v b="$b" -v s="$s" '
    FNR == 1 { n++; f[n] = FILENAME; sub(/.*\//, "", f[n]) }
    index($0, "brief: ") == 1 { br[n] = substr($0, 8) }
    index($0, "state: ") == 1 { st[n] = substr($0, 8) }
    index($0, "spawned: ") == 1 { sp[n] = substr($0, 10) + 0 }
    END { for (i = 1; i <= n; i++) if (br[i] == b && (s == "" || st[i] == s)) print sp[i] + 0, f[i] }' "$@" \
    | sort -n | awk '{print $2}'
}

lstart_of() { # $1 = pid: its start time as ps tells it in UTC, spaces as _; empty if gone or a zombie
  TZ=UTC LC_ALL=C ps -o stat=,lstart= -p "$1" 2>/dev/null | awk '$1 !~ /^Z/ && NF >= 6 {print $2 "_" $3 "_" $4 "_" $5 "_" $6}'
}

same_proc() { [ -n "$2" ] && [ "$(lstart_of "$1")" = "$2" ]; } # $1 pid, $2 its start time: still that process?

start_epoch() { # $1 = a start time from lstart_of
  local t; t=$(printf '%s' "$1" | tr _ ' ')
  date -j -u -f '%a %b %d %T %Y' "$t" +%s 2>/dev/null || date -u -d "$t" +%s 2>/dev/null
}

ancestors() { # this command's PID and those of the processes above it
  local p=$$
  while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
    printf '%s ' "$p"; p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  done
}

# "<pid> <procstart> <session> <status>" for each live Claude process whose cwd is
# this checkout, from Claude Code's session records (sessions/<pid>.json). They are
# undocumented: used when present. A record names its process's start time
# (procStart, UTC), so a PID reused since then doesn't match; a record without one
# matches only a process whose command line runs claude.
claude_here() {
  local a b d f recs="" q
  have jq || return 0
  q='select(type == "object" and .pid != null and .sessionId != null)
     | [(.pid | tostring), .sessionId, (.cwd // ""), (.procStart // ""), (.status // "")] | @tsv'
  a=$(cd "$CLAUDE_DIR/sessions" 2>/dev/null && pwd -P)
  b=$(cd "$HOME/.claude/sessions" 2>/dev/null && pwd -P)
  [ "$a" = "$b" ] && b=""
  for d in "$a" "$b"; do
    [ -n "$d" ] || continue
    set -- "$d"/*.json
    [ -f "$1" ] || continue
    # one jq for the lot; file by file only if one of them doesn't parse
    recs="$recs$(jq -r "$q" "$@" 2>/dev/null || for f; do jq -r "$q" "$f" 2>/dev/null; done)
"
  done
  [ -n "$recs" ] || return 0
  TZ=UTC LC_ALL=C ps -axww -o pid=,uid=,stat=,lstart=,command= 2>/dev/null \
    | J_RECS="$recs" J_UID=$(id -u) J_ROOT="$ROOT" J_PHYS=$(pwd -P) awk '
      BEGIN {
        n = split(ENVIRON["J_RECS"], r, "\n")
        for (i = 1; i <= n; i++) {
          if (split(r[i], f, "\t") < 3 || (f[3] != ENVIRON["J_ROOT"] && f[3] != ENVIRON["J_PHYS"])) continue
          ps = f[4]; gsub(/[ \t]+/, " ", ps); sub(/^ /, "", ps); sub(/ $/, "", ps)
          sid[f[1]] = f[2]; start[f[1]] = ps; st[f[1]] = (f[5] == "" ? "-" : f[5])
        }
      }
      $2 == ENVIRON["J_UID"] && ($1 in sid) && $3 !~ /^Z/ {
        ls = $4 " " $5 " " $6 " " $7 " " $8
        if (start[$1] != "") { if (start[$1] != ls) next }
        else { c = $0; for (k = 0; k < 8; k++) sub(/^[ \t]*[^ \t]+[ \t]+/, "", c); if (c !~ /(^|\/)claude( |$)/) next }
        gsub(/ /, "_", ls); print $1, ls, sid[$1], st[$1]
      }'
}

run_by_start() { # $1 = brief, $2 = a process's start time: the run of that brief spawned last before it
  local t r s best="" bs=-1
  t=$(start_epoch "$2")
  [ -n "$t" ] || return 0
  for r in $(runs_of "$1"); do
    s=$(run_get "$r" spawned); case "$s" in ""|*[!0-9]*) s=0 ;; esac
    if [ "$s" -le $((t + 1)) ] && [ "$s" -gt "$bs" ]; then best=$r; bs=$s; fi
  done
  echo "$best"
}

merged_at() { # $1 = a handoff in handoffs/merged/: when it was added there (its commit, else its mtime)
  local t
  [ -f "$1" ] || return 0
  t=$(git log --diff-filter=A --format=%ct -1 -- "$1" 2>/dev/null)
  [ -n "$t" ] || t=$(mtime "$1")
  [ "$t" != 0 ] && echo "$t"
}

# Someone resuming a finished worker's transcript later (claude --resume) runs a
# new process with the worker's session. One that started more than 60 s after
# the run ended is never the run's worker.
after_end() { # $1 = a start time from lstart_of, $2 = when the run ended (epoch; empty = it hasn't)
  local t
  case "$2" in ""|*[!0-9]*) return 1 ;; esac
  t=$(start_epoch "$1")
  [ -n "$t" ] && [ "$t" -gt $(($2 + 60)) ]
}

# The Claude processes of a run, as claude_here lines. A session is the run's when
# the prompt hook saw it in the run's terminal, or, when no terminal's record names
# it, when its transcript opens with the spawn prompt for the run's brief (and, if
# the brief was spawned more than once, the run is the last one spawned before the
# process started). Never this command or anything above it, nor a process that
# started after the run ended (after_end).
agent_procs() { # $1 = run
  local run=$1 brief n=0 anc end pid ps sid st own
  brief=$(run_get "$run" brief)
  end=$(run_get "$run" ended)
  [ -n "$brief" ] && n=$(runs_of "$brief" | wc -l | tr -d ' ')
  anc=" $(ancestors)"
  claude_here | while read -r pid ps sid st; do
    case "$anc" in *" $pid "*) continue ;; esac
    after_end "$ps" "$end" && continue
    own=$(grep -lxF "$sid" "$STATE"/sessions/* 2>/dev/null)
    if [ -n "$own" ]; then
      printf '%s\n' "$own" | grep -qxF "$STATE/sessions/$run" || continue
    else
      [ -n "$brief" ] && [ "$(brief_of_session "$sid")" = "$brief" ] || continue
      [ "$n" -le 1 ] || [ "$(run_by_start "$brief" "$ps")" = "$run" ] || continue
    fi
    echo "$pid $ps $sid $st"
  done
}

alive_of() { # $1 = agent_procs lines: those whose PID is still the same process
  printf '%s\n' "$1" | while read -r pid ps rest; do
    [ -n "$pid" ] && same_proc "$pid" "$ps" && echo "$pid $ps $rest"
  done
}

has_pid() { printf '%s\n' "$2" | awk -v p="$1" '$1 == p {f = 1} END {exit !f}'; } # $1 pid, $2 lines

term_listed() { host list 2>/dev/null | grep -qxF "$1"; } # unknown (host can't be asked) = not listed

audit() { # $1 action, $2 run, $3 brief, $4 target (terminal=… | pid=… procstart=…), $5 result
  mkdir -p "$STATE" && printf '%s %s run=%s brief=%s %s result=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "${3:--}" "$4" "$5" >> "$STATE/audit.log"
}

signal_procs() { # $1 = TERM | KILL, $2 = agent_procs lines, $3 run, $4 brief; each re-checked first
  local pid ps r
  printf '%s\n' "$2" | while read -r pid ps _; do
    [ -n "$pid" ] || continue
    if ! same_proc "$pid" "$ps"; then r="skipped: no longer that process"
    elif kill "-$1" "$pid" 2>/dev/null; then r="$1 sent"
    else r="$1 failed"; fi
    audit signal "$3" "$4" "pid=$pid procstart=$ps" "$r"
  done
}

# Stop agent processes that should have gone (alive_of lines): TERM, up to 10 s, then
# KILL, each re-checked just before its signal. Prints "<pid> <what happened>" for each.
reap_left() { # $1 = alive_of lines, $2 run, $3 brief
  local hard i=0 pid
  signal_procs TERM "$1" "$2" "$3"
  while [ $i -lt 10 ] && [ -n "$(alive_of "$1")" ]; do sleep 1; i=$((i + 1)); done
  hard=$(alive_of "$1")
  [ -n "$hard" ] && signal_procs KILL "$hard" "$2" "$3" && sleep 1
  for pid in $(printf '%s\n' "$1" | awk '{print $1}'); do
    if has_pid "$pid" "$(alive_of "$hard")"; then echo "$pid still running after KILL"
    elif has_pid "$pid" "$hard"; then echo "$pid stopped (KILL)"
    else echo "$pid stopped (TERM)"; fi
  done
}

# Close a run's terminal and make sure its agent went: note the run's Claude
# processes first, close (its error kept), then wait up to JARVIS_STOP_GRACE s for
# the terminal to leave the host's list and each process to exit. One still there
# is stopped, TERM then KILL after 10 s (JARVIS_REAP=1), or named (0). Prints what
# happened as one fragment of the caller's line; fails when the close did.
stop_run() { # $1 = run, $2 = merged | closed, $3 = why
  local run=$1 brief procs err out ok=0 i=0 left pid r
  brief=$(run_get "$run" brief)
  procs=$(agent_procs "$run")
  if err=$(host close "$run" 2>&1 >/dev/null); then
    ok=1; out="closed $(short "$run")"
    audit close "$run" "$brief" "terminal=$run" ok
  else
    err=$(printf '%s\n' "$err" | sed -e 's/^jarvis: //' | grep -v '^[[:space:]]*$' | head -n 1)
    out="close FAILED for $(short "$run"): ${err:-the host gave no reason}"
    audit close "$run" "$brief" "terminal=$run" "FAILED: ${err:-no reason given}"
  fi
  if [ $ok = 1 ]; then
    while [ $i -lt "$JARVIS_STOP_GRACE" ] && { term_listed "$run" || [ -n "$(alive_of "$procs")" ]; }; do
      sleep 1; i=$((i + 1))
    done
    term_listed "$run" && out="$out · terminal $(short "$run") still listed after $JARVIS_STOP_GRACE s"
  fi
  left=$(alive_of "$procs")
  if [ -n "$left" ] && [ "$JARVIS_REAP" = 1 ]; then
    while read -r pid r; do
      [ -n "$pid" ] && out="$out · worker pid $pid didn't exit on close: $r"
    done <<EOF
$(reap_left "$left" "$run" "$brief")
EOF
  elif [ -n "$left" ]; then
    for pid in $(printf '%s\n' "$left" | awk '{print $1}'); do
      out="$out · worker pid $pid didn't exit on close: still running (JARVIS_REAP=0; stop it: kill $pid)"
      audit list "$run" "$brief" "pid=$pid procstart=$(lstart_of "$pid")" "left running (JARVIS_REAP=0)"
    done
  fi
  run_set "$run" state "$2" ended "$(now)" reason "$3" outcome "$out"
  echo "$out"
  [ $ok = 1 ]
}

# Every worker terminal of a brief that may still be open: its running runs, then,
# for briefs spawned before the registry, the started: terminal and the Running
# workers line (read before merge drops it), unless the registry says it has ended.
brief_runs() { # $1 = brief
  { runs_of "$1" running
    brief_terminal "$1"
    running_lines | awk -v b="$1" '{n = split($0, f, " · "); for (i = 1; i <= n; i++) if (f[i] == b) print}' \
      | sed -n 's/.*· term \([^ ]*\) ·.*/\1/p'
  } | awk 'NF && !seen[$0]++' | while read -r r; do
    case "$(run_get "$r" state)" in ""|running) echo "$r" ;; esac
  done
}
