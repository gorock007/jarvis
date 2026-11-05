# shellcheck shell=bash
# Sourced by bin/jarvis; not run on its own.
# ---------------------------------------------------------------- claude sessions, machine-wide

# The caps count every Claude session on this machine, Jarvis's or not, from Claude
# Code's session records ($CLAUDE_DIR/sessions/<pid>.json, and ~/.claude's when they
# differ). Each is verified against ps as claude_here does: a dead PID, or one reused
# since (procStart differs), doesn't count, so a stale record needs no cleaning and
# nothing is ever deleted. Hooks and headless runs (entrypoint sdk-*) don't count.
# Read only: nothing here signals a session.

proj_root() { # $1 = a physical path: the nearest directory above it (or it) with a .git, else itself
  local d=$1
  while [ -n "$d" ] && [ "$d" != / ]; do
    [ -e "$d/.git" ] && { printf '%s\n' "$d"; return; }
    d=${d%/*}
  done
  printf '%s\n' "$1"
}

sess_model() { # $1 = cwd, $2 = session id: the last assistant model in its transcript (tail only)
  local p t
  p=$(printf '%s' "$1" | sed 's#[^A-Za-z0-9]#-#g')
  for t in "$CLAUDE_DIR/projects/$p/$2.jsonl" "$HOME/.claude/projects/$p/$2.jsonl"; do
    [ -f "$t" ] || continue
    tail -n 200 "$t" | grep '"type":"assistant"' \
      | jq -r '.message.model // empty | select(. != "<synthetic>")' 2>/dev/null | tail -n 1
    return
  done
}

# "<pid>\t<session>\t<project root or cwd>\t<model>\t<why>\t<started ms>\t<updated ms>",
# one line per session that counts toward the caps. why: busy (its status), recent
# (updated in the last JARVIS_ACTIVE_MIN minutes), jarvis (this checkout's Jarvis or
# one of its running workers, whatever its status), pending (a spawn whose session
# record hasn't appeared yet: pid -, its entry's name as the session). Idle sessions
# burn nothing and don't count; $1 = --all lists them too, why idle. model is
# fable | opus | sonnet | haiku | unknown: a worker of this checkout's from the run
# registry, else its transcript's; unknown counts as Opus.
claude_active() {
  local all=${1:-} a b d f r recs="" q jar="" regm="" sid pid cwd why st up proj m used="" ep pr pm pn tmp
  have jq || return 0
  q='select(type == "object" and .pid != null and .sessionId != null)
     | [(.pid | tostring), .sessionId, (.cwd // ""), (.procStart // ""), (.status // ""),
        ([.updatedAt, .statusUpdatedAt, 0] | map(numbers) | max | floor | tostring),
        ([.startedAt, 0] | map(numbers) | max | floor | tostring), (.entrypoint // "")] | @tsv'
  a=$(cd "$CLAUDE_DIR/sessions" 2>/dev/null && pwd -P)
  b=$(cd "$HOME/.claude/sessions" 2>/dev/null && pwd -P)
  [ "$a" = "$b" ] && b=""
  for d in "$a" "$b"; do
    [ -n "$d" ] || continue
    set -- "$d"/*.json
    [ -f "$1" ] || continue
    recs="$recs$(jq -r "$q" "$@" 2>/dev/null || for f; do jq -r "$q" "$f" 2>/dev/null; done)
"
  done
  # Jarvis's sessions and its running workers', with the model each worker was spawned on
  jar=$(cat "$STATE/sessions/$(jarvis_terminal)" 2>/dev/null; jq -r '.session_id // empty' "$STATE/session.json" 2>/dev/null)
  for f in "$RUNS"/*; do
    [ -f "$f" ] && grep -qx 'state: running' "$f" || continue
    r=${f##*/}
    m=$(run_get "$r" model)
    for sid in $(cat "$STATE/sessions/$r" 2>/dev/null); do jar="$jar
$sid"; regm="$regm$sid $m
"; done
  done
  tmp=$(mktemp "${TMPDIR:-/tmp}/jarvis-active.XXXXXX") || return 0
  [ -n "$recs" ] && TZ=UTC LC_ALL=C ps -axww -o pid=,uid=,stat=,lstart=,command= 2>/dev/null \
    | J_RECS="$recs" J_UID=$(id -u) J_JAR="$jar" J_NOW="$(now)000" J_WIN=$((JARVIS_ACTIVE_MIN * 60000)) J_ALL="$all" awk '
      BEGIN {
        n = split(ENVIRON["J_JAR"], j, "\n"); for (i = 1; i <= n; i++) if (j[i] != "") jar[j[i]] = 1
        n = split(ENVIRON["J_RECS"], r, "\n")
        for (i = 1; i <= n; i++) {
          if (split(r[i], f, "\t") < 7 || f[8] ~ /^sdk-/) continue
          ps = f[4]; gsub(/[ \t]+/, " ", ps); sub(/^ /, "", ps); sub(/ $/, "", ps)
          sid[f[1]] = f[2]; cwd[f[1]] = f[3]; start[f[1]] = ps; st[f[1]] = f[5]; up[f[1]] = f[6] + 0; born[f[1]] = f[7] + 0
        }
      }
      $2 == ENVIRON["J_UID"] && ($1 in sid) && $3 !~ /^Z/ {
        p = $1; ls = $4 " " $5 " " $6 " " $7 " " $8
        if (start[p] != "") { if (start[p] != ls) next }
        else { c = $0; for (k = 0; k < 8; k++) sub(/^[ \t]*[^ \t]+[ \t]+/, "", c); if (c !~ /(^|\/)claude( |$)/) next }
        why = st[p] == "busy" ? "busy" : up[p] >= ENVIRON["J_NOW"] - ENVIRON["J_WIN"] ? "recent" : (sid[p] in jar) ? "jarvis" : "idle"
        if (why == "idle" && ENVIRON["J_ALL"] == "") next
        print p "\t" sid[p] "\t" cwd[p] "\t" why "\t" born[p] "\t" up[p]
      }' > "$tmp"
  # per session: its project and model
  while IFS=$TAB read -r pid sid cwd why st up; do
    [ -n "$pid" ] || continue
    proj=$(cd "$cwd" 2>/dev/null && proj_root "$(pwd -P)")
    [ -n "$proj" ] || proj=$cwd
    m=-
    if [ "$why" != idle ]; then
      m=$(printf '%s' "$regm" | awk -v s="$sid" '$1 == s {print $2; exit}')
      [ -n "$m" ] || m=$(sess_model "$cwd" "$sid")
      if [ -z "$m" ]; then m=unknown; else m=$(model_canon claude "$m") || m=unknown; fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pid" "$sid" "$proj" "$m" "$why" "$st" "$up"
  done < "$tmp" > "$tmp.l"
  cat "$tmp.l"
  # a spawn counts until a session that started after it shows up in its project, its
  # run has ended, or JARVIS_PENDING_SEC has passed
  for f in "$JHOME"/spawning/*; do
    [ -f "$f" ] || continue
    ep=$(rec_get "$f" epoch); pr=$(rec_get "$f" project); pm=$(rec_get "$f" model); pn=$(rec_get "$f" run)
    case "$ep" in ""|*[!0-9]*) continue ;; esac
    [ $(( $(now) - ep )) -lt "$JARVIS_PENDING_SEC" ] || continue
    if [ -n "$pn" ] && run_ok "$pn" && [ -f "$pr/$STATE/runs/$pn" ] && ! grep -qx 'state: running' "$pr/$STATE/runs/$pn"; then continue; fi
    sid=$(awk -F'\t' -v p="$pr" -v t=$(( (ep - 5) * 1000 )) -v used="$used" '
      $5 != "idle" && $3 == p && $6 + 0 >= t && index(used, " " $2 " ") == 0 {print $2; exit}' "$tmp.l")
    if [ -n "$sid" ]; then used="$used $sid "; continue; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' - "${f##*/}" "$pr" "${pm:-unknown}" pending "${ep}000" "${ep}000"
  done
  rm -f "$tmp" "$tmp.l"
}

heavy() { case "$1" in opus|fable|unknown) return 0 ;; esac; return 1; } # counts toward the Opus cap

jarvis_sids() { # $1 = a project root: the session ids of its Jarvis coordinator, one a line (none without one)
  local t
  t=$(sed -n 's/^Jarvis session:[[:space:]]*//p' "$1/$OPEN" 2>/dev/null | head -n 1 | awk '{print $1}' | grep -v '^<')
  case "$t" in ""|*/*|.*) return 0 ;; esac
  cat "$1/$STATE/sessions/$t" 2>/dev/null
  have jq && jq -r '.session_id // empty' "$1/$STATE/session.json" 2>/dev/null
  return 0
}

# Sets CAP_BAND, the effective caps CAP_G (machine) CAP_P (this checkout) CAP_O (Opus),
# the counts N_ALL N_HERE N_OPUS, N_OPEN (OPEN.md's, Jarvis included), CAP_LINES (the
# sessions that count), CAP_IDLE (the idle ones) and CAP_JARVIS (" <sid> " for each
# Jarvis coordinator session, any repo's). This checkout counts as whichever is higher:
# OPEN.md's Jarvis + running Claude workers, or its active sessions; so Jarvis and its
# workers always count, whatever their status, and none counts twice. The machine-wide
# and Opus caps leave out every repo's Jarvis: they count workers and the user's own
# sessions (a pending spawn always counts).
cap_counts() {
  local all pid sid proj m why rest here=0 here_w=0 hh=0 oth=0 oh=0 open_h=0 roots=$TAB s j
  CAP_BAND=$(band | cut -f1)
  case "$CAP_BAND" in
    red) CAP_G=$JARVIS_RED_GLOBAL; CAP_O=$JARVIS_RED_OPUS ;;
    amber) CAP_G=$JARVIS_AMBER_GLOBAL; CAP_O=$JARVIS_AMBER_OPUS ;;
    *) CAP_G=$JARVIS_MAX_CLAUDE_GLOBAL; CAP_O=$JARVIS_MAX_OPUS ;;
  esac
  # a band never raises a cap set lower for green
  [ "$CAP_G" -gt "$JARVIS_MAX_CLAUDE_GLOBAL" ] && CAP_G=$JARVIS_MAX_CLAUDE_GLOBAL
  [ "$CAP_O" -gt "$JARVIS_MAX_OPUS" ] && CAP_O=$JARVIS_MAX_OPUS
  CAP_P=$JARVIS_MAX_CLAUDE
  all=$(claude_active --all)
  CAP_LINES=$(printf '%s\n' "$all" | awk -F'\t' 'NF >= 5 && $5 != "idle"')
  CAP_IDLE=$(printf '%s\n' "$all" | awk -F'\t' 'NF >= 5 && $5 == "idle"')
  CAP_JARVIS=" "
  while IFS=$TAB read -r pid sid proj m why rest; do
    [ -n "$pid" ] || continue
    j=0
    if [ "$pid" != - ]; then
      case "$roots" in *"$TAB$proj$TAB"*) ;; *) # each root's Jarvis read once
        roots="$roots$proj$TAB"
        for s in $(jarvis_sids "$proj"); do CAP_JARVIS="$CAP_JARVIS$s "; done ;;
      esac
      case "$CAP_JARVIS" in *" $sid "*) j=1 ;; esac
    fi
    if [ "$proj" = "$ROOTP" ]; then
      here=$((here + 1))
      [ "$j" = 1 ] || { here_w=$((here_w + 1)); heavy "$m" && hh=$((hh + 1)); }
    elif [ "$j" = 0 ]; then oth=$((oth + 1)); heavy "$m" && oh=$((oh + 1)); fi
  done <<LINES
$CAP_LINES
LINES
  N_OPEN=$(claude_sessions)
  for m in $(running_lines | sed -n 's/.*· claude\/\([^ ]*\).*/\1/p'); do
    heavy "$(model_canon claude "$m" || echo unknown)" && open_h=$((open_h + 1))
  done
  N_HERE=$here; [ "$N_OPEN" -gt "$N_HERE" ] && N_HERE=$N_OPEN
  [ "$open_h" -gt "$hh" ] && hh=$open_h
  [ $((N_OPEN - 1)) -gt "$here_w" ] && here_w=$((N_OPEN - 1)) # OPEN.md's workers, without Jarvis
  N_ALL=$((oth + here_w))
  N_OPUS=$((oh + hh))
}

cap_summary() { # after cap_counts
  printf '%s of %s machine-wide (%s of %s here · opus %s of %s)' "$N_ALL" "$CAP_G" "$N_HERE" "$CAP_P" "$N_OPUS" "$CAP_O"
  [ "$CAP_BAND" = green ] || printf ' — band %s caps' "$CAP_BAND"
  echo
}

# shellcheck disable=SC2088 # a path shown to the user, not expanded
tilde() { case "$1" in "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac; }

cap_holders() { # stdin: claude_active lines → "  pid 123 · ~/repo · opus · busy"
  local pid sid proj m why rest
  while IFS=$TAB read -r pid sid proj m why rest; do
    [ -n "$pid" ] || continue
    if [ "$pid" = - ]; then printf '  pending spawn %s · %s · %s\n' "$sid" "$(tilde "$proj")" "$m"
    else printf '  pid %s · %s · %s · %s\n' "$pid" "$(tilde "$proj")" "$m" "$why"; fi
  done
}

# `jarvis spawn` runs this under the machine-wide spawn lease (jarvis-lock.pl, class
# spawn, host 1): count, check the caps, record the spawn as pending. So two Jarvis
# instances can't both take the last slot. The launch runs after the lease is let go
# (a host CLI that starts a daemon would otherwise keep it for good); until the new
# session's record appears, the pending entry holds its slot.
# $1 = canonical model, $2 = force (0|1), $3 = brief, $4 = the entry to write.
cap_claim() {
  local canon=$1 force=$2 brief=$3 entry=$4 cap="" n lim who f
  cap_counts
  if [ "$N_ALL" -ge "$CAP_G" ]; then
    cap="machine-wide"; n=$N_ALL; lim=$CAP_G
    who=$(printf '%s\n' "$CAP_LINES" | awk -F'\t' -v j="$CAP_JARVIS" 'index(j, " " $2 " ") == 0' | cap_holders)
  elif [ "$N_HERE" -ge "$CAP_P" ]; then
    cap="this checkout"; n=$N_HERE; lim=$CAP_P
    who="$(printf '%s\n' "$CAP_LINES" | awk -F'\t' -v p="$ROOTP" '$3 == p' | cap_holders)
  OPEN.md: Jarvis + $((N_OPEN - 1)) running Claude worker(s)"
  elif heavy "$canon" && [ "$N_OPUS" -ge "$CAP_O" ]; then
    cap="Opus"; n=$N_OPUS; lim=$CAP_O
    who=$(printf '%s\n' "$CAP_LINES" | awk -F'\t' -v j="$CAP_JARVIS" \
      '($4 == "opus" || $4 == "fable" || $4 == "unknown") && index(j, " " $2 " ") == 0' | cap_holders)
  fi
  if [ -n "$cap" ]; then
    if [ "$force" = 1 ]; then
      audit cap-force - "$brief" "cap=$cap n=$n limit=$lim band=$CAP_BAND" passed
      echo "jarvis: --force: past the $cap Claude cap ($n of $lim, band $CAP_BAND); logged in $STATE/audit.log" >&2
    else
      {
        printf 'jarvis: Claude cap reached: %s, %s of %s' "$cap" "$n" "$lim"
        if [ "$CAP_BAND" = green ]; then echo; else echo " (band $CAP_BAND: caps lowered)"; fi
        echo "held by:"
        printf '%s\n' "${who:-  the count in OPEN.md}" | grep -v '^$'
        printf 'Options: queue it under To-do in OPEN.md; route it to Codex or OpenCode; or close one of your own idle sessions (handoffs/bin/jarvis sessions lists them)'
        [ "$cap" = Opus ] && printf '; or give it model: sonnet'
        echo ". --force passes this cap (logged)."
      } >&2
      exit 1
    fi
  fi
  (umask 077; mkdir -p "$JHOME/spawning") || exit 1
  for f in "$JHOME"/spawning/*; do # expired entries go
    [ -f "$f" ] || continue
    n=$(rec_get "$f" epoch); case "$n" in ""|*[!0-9]*) n=0 ;; esac
    [ $(( $(now) - n )) -lt "$JARVIS_PENDING_SEC" ] || rm -f "$f"
  done
  printf 'epoch: %s\nproject: %s\nmodel: %s\nbrief: %s\n' "$(now)" "$ROOTP" "$canon" "$brief" > "$entry.tmp" \
    && mv "$entry.tmp" "$entry" || exit 1
}

dur() { # $1 = seconds: 2d03h, 5h10m, 7m
  local s=$1
  [ "$s" -ge 0 ] 2>/dev/null || s=0
  if [ "$s" -ge 86400 ]; then printf '%dd%02dh' $((s / 86400)) $((s % 86400 / 3600))
  elif [ "$s" -ge 3600 ]; then printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
  else printf '%dm' $((s / 60)); fi
}

cmd_sessions() {
  local pid sid proj m why st up t old
  have jq || die "jq is needed to read Claude Code's session records"
  cap_counts
  echo "claude sessions: $(cap_summary)"
  echo "counting toward the caps (busy, active in the last $JARVIS_ACTIVE_MIN min, Jarvis's, or being spawned):"
  [ -n "$CAP_LINES" ] || echo "  none"
  while IFS=$TAB read -r pid sid proj m why st up; do
    [ -n "$pid" ] || continue
    printf '  %-7s %-7s %-7s %s  %s\n' "$pid" "$why" "$m" "$(tilde "$proj")" "$(short "$sid")"
  done <<LINES
$CAP_LINES
LINES
  [ "$N_OPEN" -gt 1 ] && echo "  (OPEN.md here: Jarvis + $((N_OPEN - 1)) running Claude worker(s))"
  # open for hours and idle: they cost nothing, but they're the user's to close
  t=$(now)
  old=$(printf '%s\n' "$CAP_IDLE" | awk -F'\t' -v t="$t" 'NF >= 7 && $6 > 0 && t * 1000 - $6 > 8 * 3600000')
  [ -n "$old" ] || return 0
  echo "idle, open more than 8 h (they burn nothing; close the ones you're done with yourself — jarvis never stops them):"
  while IFS=$TAB read -r pid sid proj m why st up; do
    [ -n "$pid" ] || continue
    printf '  pid %s · %s · open %s · last active %s ago\n' "$pid" "$(tilde "$proj")" \
      "$(dur $(( t - st / 1000 )))" "$(dur $(( t - up / 1000 )))"
  done <<LINES
$old
LINES
}
