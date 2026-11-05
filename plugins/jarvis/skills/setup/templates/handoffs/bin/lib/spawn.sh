# shellcheck shell=bash
# Sourced by bin/jarvis; not run on its own.
# ---------------------------------------------------------------- spawn

# Codex trusts folders one path at a time and asks "Trust this folder?" on its first
# run in each one; a worker spawned into that prompt sits there until someone answers.
# Record the answer up front, as pressing Yes would. An existing entry is left alone.
codex_trust() {
  local cfg="${CODEX_HOME:-$HOME/.codex}/config.toml"
  case "$ROOT" in *\"*|*\\*) return 0 ;; esac
  grep -qF "[projects.\"$ROOT\"]" "$cfg" 2>/dev/null && return 0
  mkdir -p "$(dirname "$cfg")" \
    && printf '\n[projects."%s"]\ntrust_level = "trusted"\n' "$ROOT" >> "$cfg" \
    && echo "trusted $ROOT in $cfg, so Codex starts without its folder prompt"
}

cmd_spawn() {
  local brief="" after="" force=0 atts="" worker model effort tier canon prompt name b ifs
  while [ $# -gt 0 ]; do
    case "$1" in
      --after) after="${2:-}"; shift 2 ;;
      --attach) [ -f "${2:-}" ] || die "no file to attach: ${2:-}"; atts="$atts${atts:+
}$2"; shift 2 ;;
      --force) force=1; shift ;;
      *) brief="$1"; shift ;;
    esac
  done
  case "$JARVIS_OVERLAP" in warn|refuse) ;; *)
    echo "jarvis spawn: JARVIS_OVERLAP='$JARVIS_OVERLAP' in $H/jarvis.conf must be warn or refuse (nothing spawned)" >&2; exit 2 ;;
  esac
  [ -f "$brief" ] || die "usage: jarvis spawn <handoffs/briefs/file.md> [--after <partial handoff>] [--attach <file>]... [--force]"
  have jq || die "jq is needed to read the spawn result"
  need_host

  worker=$(field worker "$brief" | awk '{print $1}')
  model=$(field model "$brief" | awk '{print $1}')
  effort=$(field effort "$brief" | awk '{print $1}')
  case "$worker" in
    ""|\<*|*[!a-z0-9_]*) die "brief header needs worker: claude | codex | opencode | another agent the host knows" ;;
  esac
  case "$model" in \<*) model="" ;; esac
  case "$effort" in \<*) effort="" ;; esac
  case "$worker" in claude|codex) [ -n "$model" ] || die "brief header needs a model" ;; esac
  [ "$worker" = opencode ] && effort=""
  # the tier goes by the model's canonical name, so no alias skips the band checks;
  # a Claude model that can't be named is refused (it might resolve to Fable), and any
  # worker whose model names fable goes through every Fable check
  canon=$(model_canon "$worker" "$model") || fable_refuse "$brief" - "spawn: model '$model' can't be resolved" "$(model_refusal "$model")"
  fable_preflight "$brief" -
  case "$canon" in fable) tier=top ;; opus) tier=workhorse ;; *) tier=other ;; esac

  b=$(band | cut -f1)
  # Fable: never without the user's authorization for this brief, --force or not; never
  # in the red band even with it; amber allows an authorized one
  if [ "$canon" = fable ]; then
    [ "$b" = red ] && fable_refuse "$brief" - "spawn: red band" "band is red: fable is off even when authorized. New top-tier work goes to Codex: worker: codex, model: gpt-6-astra"
    [ "$worker" = claude ] && [ "$HOST" = superset ] && [ -z "$JARVIS_FABLE_SUPERSET_AGENT" ] && fable_refuse "$brief" - "spawn: superset has no fable agent config" "$FABLE_SUPERSET_MSG"
    fable_find "$brief" || fable_refuse "$brief" - "spawn: $FABLE_WHY" "$(fable_needs "$brief") [$FABLE_WHY]"
  fi

  if [ -x "$BIN/jev.sh" ]; then
    "$BIN/jev.sh" brief "$brief" || [ $force = 1 ] || die "sharpen the brief (or --force if the lint is wrong)"
  fi

  if [ "$worker" = claude ] && [ $force = 0 ]; then
    [ "$b" = red ] && [ "$tier" != other ] && die "band is red: new $tier-tier work goes to Codex (gpt-6-astra / gpt-5.6-sol). Edit the header, or --force"
  fi

  # a brief that blew its budget or used its attempts waits until Jarvis has read why
  budget_gate "$brief" "$after" "$force"

  prompt="You are a Jarvis worker. Read AGENTS.md, then do the task in $brief."
  [ -n "$after" ] && prompt="$prompt $after records what is already done — start from there."
  [ "$worker" = opencode ] && prompt="$prompt Touch only the files it lists. Never run git commands that change state."
  prompt="$prompt Put every question in one first handoff (status: blocked); once answered, finish this brief and hand off."

  # the brief's slug names the terminal: 2026-10-20-1030-fix-login.md → fix-login
  name=$(basename "$brief" .md | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}-//; s/[^A-Za-z0-9._-]/-/g')
  # attachments as the trailing arguments, one per line of $atts
  ifs=$IFS
  IFS='
'
  set -f
  # shellcheck disable=SC2086
  set -- $atts
  set +f
  IFS=$ifs
  spawn_leased "$brief" "$worker" "$model" "$effort" "$canon" "$force" "$name" "$prompt" "$@"
}

# The scope check, the launch and the record, one spawn at a time per checkout: under
# this checkout's spawn lease (jarvis-lock.pl, class spawn, checkout scope), taken
# before the machine-wide one spawn_claim takes for the caps. The leased part runs as
# `jarvis _spawn` in a child of the lease helper, which alone holds the lease, so
# nothing the host starts (a terminal server, a daemon) inherits it.
spawn_leased() { # $@ = spawn_go's arguments
  local pl dir="${JARVIS_LOCK_DIR:-$JHOME/locks}" rc=0 ran
  if have perl && pl=$(lock_pl 2>/dev/null); then
    ran=$(mktemp "${TMPDIR:-/tmp}/jarvis-spawn.XXXXXX") || die "can't write a temporary file: spawn refused"
    JARVIS_SPAWN_RAN="$ran" JARVIS_SPAWN_LEASE="$ROOTP" JARVIS_LOCK_NOINHERIT=1 JARVIS_CALLER_PWD="$JARVIS_CALLER_PWD" \
      JARVIS_LOCK_DIR="$dir" JARVIS_LOCK_POLL="${JARVIS_LOCK_POLL:-0.2}" \
      perl "$pl" run spawn checkout 1 "$ROOT" "${JARVIS_SPAWN_WAIT:-120}" 0 "$0" _spawn "$@" || rc=$?
    if [ -s "$ran" ] || [ $rc -le 1 ]; then # the leased part ran: its exit, its own message
      rm -f "$ran"
      [ $rc -lt 128 ] || echo "jarvis spawn: interrupted (exit $rc)" >&2
      exit $rc
    fi
    rm -f "$ran"
    case $rc in
      75) die "another spawn in this checkout has held its spawn lease for ${JARVIS_SPAWN_WAIT:-120}s: try again (jarvis resources shows who)" ;;
      *) die "can't take the spawn lease of this checkout in $dir (exit $rc): spawn refused" ;;
    esac
  fi
  if [ "$JARVIS_OVERLAP" = refuse ]; then
    echo "jarvis spawn: refused (JARVIS_OVERLAP=refuse): no perl or $BIN/jarvis-lock.pl here, so this checkout's spawn lease can't be taken and the overlap check isn't atomic" >&2
    exit 1
  fi
  echo "jarvis spawn: no perl or $BIN/jarvis-lock.pl here: overlap check not atomic (a spawn at the same moment can pass it too)" >&2
  spawn_go "$@"
}

# "<terminal>\t<brief>" for each running worker: the registry's running runs, then the
# OPEN.md lines no record covers (spawned before the registry). A record in any other
# state is a finished worker, whatever OPEN.md still says. One with no brief is listed
# with an empty one: jarvis-scope.py counts its scope as unknown.
overlap_running() {
  local f t b
  for f in "$RUNS"/*; do
    [ -f "$f" ] && [ "$(rec_get "$f" state)" = running ] && printf '%s\t%s\n' "${f##*/}" "$(rec_get "$f" brief)"
  done
  running_lines | awk -F' · ' '{t = $3; sub(/^term /, "", t); print t "\t" $4}' | while IFS="$TAB" read -r t b; do
    [ -n "$t$b" ] || continue
    run_ok "$t" && [ -f "$RUNS/$t" ] && continue
    printf '%s\t%s\n' "$t" "$b"
  done
}

spawn_overlap() { # $1 = brief: print where its May-touch scope meets a running worker's; refuse on it with JARVIS_OVERLAP=refuse
  local running out="" rc=0 why="" d
  running=$(overlap_running)
  [ -n "$running" ] || return 0
  d=$(dirname "$0")
  case "$d" in /*) ;; *) d="$JARVIS_CALLER_PWD/$d" ;; esac
  if ! have python3; then why="no python3 on PATH"
  elif [ ! -f "$d/jarvis-scope.py" ]; then why="no $BIN/jarvis-scope.py (re-run jarvis:setup)"
  else
    out=$(printf '%s\n' "$running" | python3 -I "$d/jarvis-scope.py" overlap "$ROOTP" "$1") || rc=$?
    case "$rc" in
      0) return 0 ;;
      1) [ -n "$out" ] || why="jarvis-scope.py found a conflict it didn't name" ;;
      *) why="jarvis-scope.py failed (exit $rc)" ;;
    esac
  fi
  [ -z "$why" ] || out="unknown overlap: $why, so $1's scope wasn't compared with the $(printf '%s\n' "$running" | grep -c .) running worker(s)' — queue it under To-do until they are handed off, or fix the install"
  if [ "$JARVIS_OVERLAP" = refuse ]; then
    printf '%s\n' "$out" | sed 's/^/jarvis spawn: refused (JARVIS_OVERLAP=refuse): /' >&2
    exit 1
  fi
  printf '%s\n' "$out" | sed 's/^/jarvis spawn: /' >&2
  [ -z "$why" ] || echo "jarvis spawn: spawning anyway (JARVIS_OVERLAP=warn)" >&2
}

spawn_go() { # $1 brief, $2 worker, $3 model, $4 effort, $5 canon, $6 force, $7 name, $8 prompt, then the attachments
  local brief=$1 worker=$2 model=$3 effort=$4 canon=$5 force=$6 name=$7 prompt=$8 id old spawned
  shift 8
  spawn_overlap "$brief"
  old=$(runs_of "$brief" running | tr '\n' ' ' | sed 's/ $//')
  # the caps: counted, checked and the slot taken under the machine-wide spawn lease;
  # a launch that fails gives the slot back
  if [ "$worker" = claude ]; then
    SPAWN_PENDING="$JHOME/spawning/$name.$(now).$$"
    spawn_claim "$canon" "$force" "$brief" "$SPAWN_PENDING" || exit $?
    trap 'rm -f "$SPAWN_PENDING"' EXIT
  fi
  [ "$worker" = codex ] && codex_trust
  # used up here, last thing before the launch: a failed launch needs a new `fable allow`
  [ "$canon" = fable ] && fable_consume "$brief" "$name"
  # taken before the host starts the agent, so the agent's own start time is never earlier
  spawned=$(now)
  SPAWN_BRIEF=$brief   # for a host that writes the launch line (tmux): not exported
  id=$(host spawn "$worker" "$model" "$effort" "$prompt" "$name" "$@") \
    || die "spawn failed on $HOST (a failed Claude spawn can mean the red band)"
  [ -n "$id" ] || die "spawn on $HOST returned no terminal id"
  if [ -n "${SPAWN_PENDING:-}" ]; then # launched: the entry stays until its session shows up, or the run ends
    trap - EXIT
    run_ok "$id" && printf 'run: %s\n' "$id" >> "$SPAWN_PENDING"
  fi

  brief_set_started "$brief" "started: $(date '+%Y-%m-%d %H:%M') · terminal: $id"
  if run_ok "$id"; then
    rm -f "$RUNS/$id"
    run_set "$id" run "$id" brief "$brief" agent "$worker" model "${model:-default}" effort "${effort:--}" \
      host "$HOST" spawned "$spawned" state running
  else
    echo "warning: terminal id '$id' has characters the run registry doesn't take: not recorded in $RUNS, so merge closes it only through the brief's started: line"
  fi
  open_add_running "- $(date '+%Y-%m-%d %H:%M') · $worker/${model:-default}${effort:+ $effort} · term $id · $brief"
  cap_counts
  echo "spawned $(short "$id") $worker/${model:-default}${effort:+ $effort} ← $brief (claude sessions: $(cap_summary))"
  [ -n "$old" ] && echo "warning: $brief already had a running worker ($old); merge closes every worker of this brief. To close the old one now: handoffs/bin/jarvis close ${old%% *}"
  return 0
}

spawn_claim() { # $@ = cap_claim's arguments: run it under the spawn lease, one spawn at a time machine-wide
  local pl dir="${JARVIS_LOCK_DIR:-$JHOME/locks}" rc=0
  if have perl && pl=$(lock_pl 2>/dev/null); then
    JARVIS_CALLER_PWD="$JARVIS_CALLER_PWD" JARVIS_LOCK_DIR="$dir" JARVIS_LOCK_POLL="${JARVIS_LOCK_POLL:-0.2}" \
      perl "$pl" run spawn host 1 "$ROOT" "${JARVIS_SPAWN_WAIT:-120}" 0 "$0" _claim "$@" || rc=$?
    case $rc in
      0|1) return $rc ;; # 1: a cap, already explained
      75) die "another spawn has held the spawn lease for ${JARVIS_SPAWN_WAIT:-120}s: try again (jarvis resources shows who)" ;;
      *) die "can't take the spawn lease in $dir (exit $rc), so the caps can't be checked: spawn refused" ;;
    esac
  else
    echo "jarvis: no perl here, so the cap check can't be made atomic across repos; checking without the lease" >&2
    (cap_claim "$@")
  fi
}

# Record the terminal in the brief: rewrite its started: line, or add one after the
# header (worker/model/effort), else after the title.
brief_set_started() { # $1 = brief, $2 = the line
  local tmp
  if grep -q '^started:' "$1"; then
    tmp=$(mktemp) && awk -v s="$2" '/^started:/ {print s; next} {print}' "$1" > "$tmp" && cat "$tmp" > "$1"
  else
    tmp=$(mktemp) && awk -v s="$2" '
      NR == FNR { if (/^## /) stop = 1; if (!stop && /^(worker|model|effort):/) at = FNR; next }
      {print} FNR == (at ? at : 1) {print s}' "$1" "$1" > "$tmp" && cat "$tmp" > "$1"
  fi
  rm -f "${tmp:-}"
}
