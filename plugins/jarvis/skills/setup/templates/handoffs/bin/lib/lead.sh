# shellcheck shell=bash
# Sourced by bin/jarvis; not run on its own.
# ---------------------------------------------------------------- the agent Jarvis runs on

# JARVIS_LEAD_AGENT picks it: claude (the default: the user opens Claude Code, nothing
# here applies), or agy, codex or opencode, which the user starts with `jarvis lead`. A
# non-Claude Jarvis is no Claude session: lead_n is what it adds to this checkout's
# Claude count. Anything else is a typo: counted as Claude, and jarvis lead refuses it.
#
# One row per non-Claude lead, read only through lead_attr. These are implementation
# metadata, set after jarvis.conf on purpose: not a way to add a lead agent from config.
#   CLI            the JARVIS_AGENT_<cli> launch line it starts with, as a worker would
#   DEFAULT_MODEL  JARVIS_LEAD_MODEL when that's empty (opencode: none, it must be set)
#   DEFAULT_EFFORT JARVIS_LEAD_EFFORT when that's empty (agy, opencode: no effort at all)
#   PREPARE        writes its support files and prints the launch script's wrapper
#   INSTRUCTIONS   plugin: the jarvis:run skill it has installed; file: the copy setup
#                  writes to handoffs/skills/jarvis-run/, read as a file
#   CLEAR          what the watcher types to start it on a new conversation
#   RESET_CONFIRM  same-session: the clear is taken as done; new-root: done only when a
#                  turn arrives from a different root session than the one it cleared
#   SCREEN_RE      a quota/rate-limit error on its screen (ERE, case-blind)
#   ERROR_RE       the same in an error its hooks report; empty: its hooks report none
#   ADVICE         what the user can do about that
#   BYPASS         its permission-skipping flags: JARVIS_LEAD_PERMISSIONS=full adds them
#   ASK            JARVIS_LEAD_PERMISSIONS=ask drops BYPASS and adds these instead
# shellcheck disable=SC2034 # read by lead_attr, by name
{
JARVIS_LEAD_CLI_agy=agy
JARVIS_LEAD_CLI_codex=codex
JARVIS_LEAD_CLI_opencode=opencode
JARVIS_LEAD_DEFAULT_MODEL_agy=gemini-4-neon-high
JARVIS_LEAD_DEFAULT_MODEL_codex=gpt-6-astra
JARVIS_LEAD_DEFAULT_MODEL_opencode=""
JARVIS_LEAD_DEFAULT_EFFORT_agy=""
JARVIS_LEAD_DEFAULT_EFFORT_codex=high
JARVIS_LEAD_DEFAULT_EFFORT_opencode=""
JARVIS_LEAD_PREPARE_agy=lead_prepare_agy
JARVIS_LEAD_PREPARE_codex=lead_prepare_codex
JARVIS_LEAD_PREPARE_opencode=lead_prepare_opencode
JARVIS_LEAD_INSTRUCTIONS_agy=plugin
JARVIS_LEAD_INSTRUCTIONS_codex="file"
JARVIS_LEAD_INSTRUCTIONS_opencode="file"
JARVIS_LEAD_CLEAR_agy=/clear
JARVIS_LEAD_CLEAR_codex=/clear
JARVIS_LEAD_CLEAR_opencode=/new
JARVIS_LEAD_RESET_CONFIRM_agy=same-session
JARVIS_LEAD_RESET_CONFIRM_codex=new-root
JARVIS_LEAD_RESET_CONFIRM_opencode=new-root
JARVIS_LEAD_SCREEN_RE_agy='RESOURCE_EXHAUSTED[[:space:]]*\(code 429\)'
JARVIS_LEAD_SCREEN_RE_codex="you('|’)ve hit your usage limit|usage_limit_exceeded|rate_limit_exceeded|rate limit (reached|exceeded)|quota exceeded|insufficient_quota|unexpected status 429"
JARVIS_LEAD_SCREEN_RE_opencode="too many requests|rate_limit_exceeded|rate limit (reached|exceeded)|quota (exceeded|exhausted)|insufficient_quota|usage limit (reached|exceeded)|you('|’)ve hit your usage limit"
JARVIS_LEAD_ERROR_RE_agy='RESOURCE_EXHAUSTED|(^|[^0-9])429([^0-9]|$)'
JARVIS_LEAD_ERROR_RE_codex=""
JARVIS_LEAD_ERROR_RE_opencode=$JARVIS_LEAD_SCREEN_RE_opencode
# shellcheck disable=SC2016 # the backticks are literal
JARVIS_LEAD_ADVICE_agy='An agy Jarvis that gets a 429 sits silent until it is sent a message: `agy -p /quota` shows what is left; send it "resume" later, or run Jarvis on Claude (JARVIS_LEAD_AGENT=claude)'
JARVIS_LEAD_ADVICE_codex='Codex'"'"'s /status or the account'"'"'s usage page shows what is left; send it "resume" when it is available again, or run Jarvis on Claude (JARVIS_LEAD_AGENT=claude)'
JARVIS_LEAD_ADVICE_opencode='check the quota and billing of the provider JARVIS_LEAD_MODEL names; send it "resume" when it is available again, or run Jarvis on Claude (JARVIS_LEAD_AGENT=claude)'
JARVIS_LEAD_BYPASS_agy=--dangerously-skip-permissions
JARVIS_LEAD_BYPASS_codex=--dangerously-bypass-approvals-and-sandbox
JARVIS_LEAD_BYPASS_opencode=--auto
JARVIS_LEAD_ASK_agy="--mode accept-edits"
JARVIS_LEAD_ASK_codex=""
JARVIS_LEAD_ASK_opencode=""
}
LEAD_SKILL=handoffs/skills/jarvis-run/SKILL.md   # a file lead's instructions: setup's copy of the jarvis:run skill

lead_agent() { # the configured lead, or claude for an unset, empty or unknown value
  case "${JARVIS_LEAD_AGENT:-claude}" in agy|codex|opencode) printf '%s' "$JARVIS_LEAD_AGENT" ;; *) printf claude ;; esac
}
lead_is_claude() { [ "$(lead_agent)" = claude ]; }
lead_n() { if lead_is_claude; then echo 1; else echo 0; fi; }

lead_attr() { # $1 = field, $2 = agent (default: the configured one): that row's value
  local f=$1 a=${2:-$(lead_agent)} v
  case "$f" in CLI|DEFAULT_MODEL|DEFAULT_EFFORT|PREPARE|INSTRUCTIONS|CLEAR|RESET_CONFIRM|SCREEN_RE|ERROR_RE|ADVICE|BYPASS|ASK) ;; *) return 1 ;; esac
  case "$a" in agy|codex|opencode) ;; *) return 1 ;; esac
  v="JARVIS_LEAD_${f}_$a"
  printf '%s' "${!v}"
}

lead_model() { # JARVIS_LEAD_MODEL, else the row's default (empty for opencode: it has none)
  if [ -n "${JARVIS_LEAD_MODEL:-}" ]; then printf '%s' "$JARVIS_LEAD_MODEL"
  elif ! lead_is_claude; then lead_attr DEFAULT_MODEL; fi
}
lead_effort() {
  if [ -n "${JARVIS_LEAD_EFFORT:-}" ]; then printf '%s' "$JARVIS_LEAD_EFFORT"
  elif ! lead_is_claude; then lead_attr DEFAULT_EFFORT; fi
}
lead_perms() { printf '%s' "${JARVIS_LEAD_PERMISSIONS:-full}"; }

lead_validate() { # the configured lead's model, effort and permissions; says what's wrong and returns 1
  local a m e
  a=$(lead_agent); m=$(lead_model); e=$(lead_effort)
  case "$(printf '%s' "$m" | tr '[:upper:]' '[:lower:]')" in *fable*) echo "JARVIS_LEAD_MODEL=$m: Fable never runs Jarvis"; return 1 ;; esac
  case "$m" in *[[:cntrl:]]*) echo "JARVIS_LEAD_MODEL has a control character in it"; return 1 ;; esac
  if [ "$a" = opencode ]; then
    case "$m" in
      "") echo "JARVIS_LEAD_MODEL is empty: an OpenCode Jarvis needs one, as provider/model (opencode models lists them)"; return 1 ;;
      */*/*|/*|*/|*[[:space:]]*) echo "JARVIS_LEAD_MODEL=$m: give it as provider/model"; return 1 ;;
      */*) ;;
      *) echo "JARVIS_LEAD_MODEL=$m: give it as provider/model"; return 1 ;;
    esac
  fi
  if [ -n "${JARVIS_LEAD_EFFORT:-}" ] && [ "$a" != codex ]; then
    echo "JARVIS_LEAD_EFFORT=$JARVIS_LEAD_EFFORT: a $a Jarvis takes no effort setting (agy's is in its model id); leave it empty"; return 1
  fi
  case "$e" in *[!a-z]*) echo "JARVIS_LEAD_EFFORT=$e: low, medium, high or xhigh"; return 1 ;; esac
  case "$(lead_perms)" in full|ask) ;; *) echo "JARVIS_LEAD_PERMISSIONS=$JARVIS_LEAD_PERMISSIONS: full or ask"; return 1 ;; esac
  [ "$(lead_perms)" = ask ] && ! lead_asks && return 1
  return 0
}

# ask: the launch line must reach the lead_wrap function (its first word the bare CLI
# name), and nothing in it but the row's own BYPASS (which lead_wrap drops) may skip
# approvals. codex's --dangerously-bypass-hook-trust stays: it only lets the launch's
# own -c hooks run, and asks nothing less of the user.
lead_asks() {
  local cli line w first="" rest=""
  cli=$(lead_attr CLI); line=$(agent_cmd "$cli") || return 0   # none: cmd_lead says so
  set -f
  # shellcheck disable=SC2086 # split into words on purpose
  for w in $line; do
    [ -n "$first" ] || { first=$w; continue; }
    case " $(lead_attr BYPASS) " in *" $w "*) continue ;; esac
    [ "$cli $w" = "codex --dangerously-bypass-hook-trust" ] && continue
    rest="$rest $w"
  done
  set +f
  if [ "$first" != "$cli" ]; then
    echo "JARVIS_LEAD_PERMISSIONS=ask, but JARVIS_AGENT_$cli starts with $first, not $cli: jarvis can't take its approvals bypass off. Begin the line with $cli, or set JARVIS_LEAD_PERMISSIONS=full"; return 1
  fi
  case "$rest " in
    *dangerously*|*" --yolo "*|*" --full-auto "*|*danger-full-access*|*" -a never "*|*" --ask-for-approval never "*)
      echo "JARVIS_AGENT_$cli skips approvals (dangerously, --yolo, --full-auto, danger-full-access or -a never), and JARVIS_LEAD_PERMISSIONS=ask: take it out of that line, or set JARVIS_LEAD_PERMISSIONS=full"; return 1 ;;
  esac
}

lead_who() { # OPEN.md's count of this checkout's Claude sessions, in words
  if lead_is_claude; then printf 'Jarvis + %s running Claude worker(s)' "$(( $(claude_sessions) - 1 ))"
  else printf '%s running Claude worker(s) (Jarvis runs on %s)' "$(claude_sessions)" "$(lead_agent)"; fi
}

# ---------------------------------------------------------------- its state (handoffs/.jarvis, ignored)
#   lead.launch  agent, terminal, generation: what jarvis lead last started. Its hooks name
#                the agent and generation, and a callback that doesn't match is dropped.
#   lead.stamp   "<epoch> <kind>": its last turn event: working, stop, cleared or unknown
#   lead.state   root (the session its turns come from), oldroot and reset (requested,
#                unconfirmed) while the watcher clears it, prompt (pending: the clear went
#                out and the fresh prompt after it didn't yet)
#   lead-limit   a quota error its screen or hooks showed (lead_limit_set)

lead_stamp() { # $1 = working | stop | cleared | unknown
  mkdir -p "$STATE" && printf '%s %s\n' "$(now)" "$1" > "$STATE/lead.stamp.$$" && mv "$STATE/lead.stamp.$$" "$STATE/lead.stamp"
}
lead_stamp_kind() { awk '{print $2; exit}' "$STATE/lead.stamp" 2>/dev/null; }

lead_get() { rec_get "$STATE/lead.state" "$1"; }
lead_put() { # key value [key value…]: written to a temp file, then moved
  local tmp k v
  mkdir -p "$STATE" && tmp=$(mktemp "$STATE/.lead.state.XXXXXX") || return 1
  [ -f "$STATE/lead.state" ] && cp "$STATE/lead.state" "$tmp"
  while [ $# -ge 2 ]; do
    k=$1; v=$(printf '%s' "$2" | tr -d '\000-\037'); shift 2
    awk -v k="$k" -v v="$v" 'index($0, k ": ") != 1 {print} END {if (v != "") print k ": " v}' "$tmp" > "$tmp.n" && mv "$tmp.n" "$tmp"
  done
  mv "$tmp" "$STATE/lead.state"
}

# One writer at a time (its hooks, the watcher): a directory as the lock, with a bounded
# wait, and taken over when its holder has been gone 30s. No lock: the caller gives up.
lead_lock() {
  local i=0
  mkdir -p "$STATE" || return 1
  until mkdir "$STATE/lead.lock" 2>/dev/null; do
    i=$((i + 1))
    if [ $i -ge 50 ]; then
      [ $(( $(now) - $(mtime "$STATE/lead.lock") )) -ge 30 ] && rmdir "$STATE/lead.lock" 2>/dev/null && continue
      return 1
    fi
    sleep 0.1
  done
}
lead_unlock() { rmdir "$STATE/lead.lock" 2>/dev/null; return 0; }

lead_limit_set() { # $1 = screen | hook, $2 = what showed it; kept until it clears, the first one wins
  local tmp
  [ -f "$STATE/lead-limit" ] && return 0
  mkdir -p "$STATE" && tmp=$(mktemp "$STATE/.lead-limit.XXXXXX") || return 0
  printf 't: %s\nsource: %s\ntext: %s\n' "$(now)" "$1" "$(printf '%s' "$2" | tr -d '\000-\037' | sed 's/^[[:space:]]*//' | cut -c1-200)" > "$tmp" \
    && mv "$tmp" "$STATE/lead-limit"
}
lead_limit_clear() { rm -f "$STATE/lead-limit" "$STATE/lead-limit.told"; }

# ---------------------------------------------------------------- what it is told

lead_prefix() { printf 'You are Jarvis, on %s' "$(lead_agent)"; }

# What a non-Claude Jarvis is told when it starts and after the watcher clears it: it
# reads AGENTS.md, whose rule makes every other agent a worker unless its prompt says this.
lead_role() {
  local a; a=$(lead_agent)
  if [ "$(lead_attr INSTRUCTIONS)" = plugin ]; then
    printf '%s (JARVIS_LEAD_AGENT=%s in handoffs/jarvis.conf), not a worker: AGENTS.md'"'"'s worker rules are not yours. Use the jarvis:run skill, read handoffs/JARVIS.md and %s,' "$(lead_prefix)" "$a" "$OPEN"
  else
    printf '%s (JARVIS_LEAD_AGENT=%s in handoffs/jarvis.conf), not a worker: AGENTS.md'"'"'s worker rules are not yours. Read %s in full and follow it as the Jarvis run instructions; its references are relative to that file. Read handoffs/JARVIS.md and %s. Then' "$(lead_prefix)" "$a" "$LEAD_SKILL" "$OPEN"
  fi
}

lead_fresh_prompt() { # $1 = idle minutes (empty: a retry), $2 = the events: the prompt after the watcher cleared it
  local why="The watcher cleared its conversation."
  [ -z "$1" ] || why="Jarvis was idle $1 min, so the watcher cleared its conversation."
  if [ "$(lead_attr RESET_CONFIRM)" = same-session ]; then
    printf '[jarvis watch] Fresh session: %s %s run handoffs/bin/jarvis status, then handle:%s' "$why" "$(lead_role)" "$2"
  else # it binds the new session by its first words, so they come first
    printf '%s run handoffs/bin/jarvis status, then handle these. [jarvis watch] Fresh session: %s Events:%s' "$(lead_role)" "$why" "$2"
  fi
}

lead_instructions() { # a file lead's instructions are there, and each reference they name; says what's missing
  local r d
  [ "$(lead_attr INSTRUCTIONS)" = file ] || return 0
  [ -s "$LEAD_SKILL" ] || { echo "$LEAD_SKILL is missing or empty"; return 1; }
  d=$(dirname "$LEAD_SKILL")
  r=$(grep -oE 'references/[A-Za-z0-9._-]+\.md' "$LEAD_SKILL" | sort -u | while IFS= read -r r; do [ -s "$d/$r" ] || echo "$r"; done | head -n 1)
  [ -z "$r" ] || { echo "$d/$r is missing or empty (named by $LEAD_SKILL)"; return 1; }
}

# ---------------------------------------------------------------- launch support

# A <cli>() function for the launch script: drops the row's BYPASS flags from the launch
# line it is given, then runs the CLI with $2 (already quoted for sh), the permission
# flags JARVIS_LEAD_PERMISSIONS picks, then the rest.
lead_wrap() { # $1 = cli, $2 = flags before the launch line's own
  local strip="" f add
  for f in $(lead_attr BYPASS); do strip="$strip${strip:+|}$f"; done
  if [ "$(lead_perms)" = ask ]; then add=$(lead_attr ASK); else add=$(lead_attr BYPASS); fi
  printf '%s() {\n' "$1"
  # shellcheck disable=SC2016
  [ -z "$strip" ] || printf '  for a do shift; case "$a" in %s) ;; *) set -- "$@" "$a" ;; esac; done\n' "$strip"
  printf '  command %s%s%s "$@"\n}\n' "$1" "${2:+ $2}" "${add:+ $add}"
}

lead_cb() { # $1 = kind, $2 = jarvis (quoted for sh), $3 = generation: its hook command
  printf '%s hook lead %s %s %s' "$2" "$1" "$(lead_agent)" "$3"
}
json_str() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }   # inside "…" in JSON or TOML

# Each PREPARE gets $1 = its support folder (made, an absolute path), $2 = the
# generation, $3 = jarvis quoted for sh, and prints the launch script's lines for its CLI.

# agy: --add-dir a folder whose .agents/hooks.json agy loads beside the user's (PreInvocation
# of each model call → working, Stop → stop, its error read for a 429), and --settings
# trusting the checkout for this session only
lead_prepare_agy() {
  local d=$1 c v w s
  mkdir -p "$d/.agents" || return 1
  w=$(json_str "$(lead_cb working "$3" "$2") </dev/null"); s=$(json_str "$(lead_cb stop "$3" "$2")")
  { printf '{"jarvis-lead": {\n  "PreInvocation": [{"type": "command", "command": "%s", "timeout": 10}],\n  "Stop": [{"type": "command", "command": "%s", "timeout": 10}]\n}}\n' "$w" "$s" \
      > "$d/.agents/.hooks.$$" && mv "$d/.agents/.hooks.$$" "$d/.agents/hooks.json"; } || { rm -f "$d/.agents/.hooks.$$"; return 1; }
  c=$(json_str "$ROOT"); v=$(json_str "$ROOTP")
  [ "$v" = "$c" ] || c="$c\",\"$v"
  lead_wrap agy "--add-dir $(tmux_sq "$d") --settings $(tmux_sq "{\"trustedWorkspaces\":[\"$c\"]}")"
}

# codex: session-flag hooks (-c hooks.<Event>, beside the user's own hooks and notify,
# run under the launch line's --dangerously-bypass-hook-trust): UserPromptSubmit →
# working, Stop → stop (its answer is {}), Interrupt and SessionEnd → unknown. Its own
# daemon off, so this launch's environment is its own.
lead_prepare_codex() {
  local e c v flags="--no-daemon"
  for e in UserPromptSubmit:working:10 Stop:stop:10 Interrupt:unknown:3 SessionEnd:unknown:3; do
    c=$(lead_cb "$(printf '%s' "$e" | cut -d: -f2)" "$3" "$2")
    case "$e" in Stop:*) c="$c; echo '{}'" ;; esac
    c=$(json_str "$c")   # a TOML string
    # built by assignment from single quotes: a {a,b} in a quoted word was brace-expanded on CI's macOS bash
    v='[{hooks=[{type="command",command="'"$c"'",timeout='"${e##*:}"'}]}]'
    flags="$flags -c $(tmux_sq "hooks.${e%%:*}=$v")"
  done
  lead_wrap codex "$flags"
}

# opencode: the lead plugin (bin/lead-opencode.mjs) copied into this launch's folder with
# a sidecar naming jarvis, the agent and the generation, added to OPENCODE_CONFIG_CONTENT's
# plugin list (the rest of it kept; not valid JSON: refused), and the build agent, so a
# user's default plan agent doesn't make Jarvis read-only
lead_prepare_opencode() {
  local d=$1 oc u
  oc=${OPENCODE_CONFIG_CONTENT:-}; [ -n "$oc" ] || oc='{}'
  have jq || { echo "jarvis: an OpenCode Jarvis needs jq (its plugin goes into OPENCODE_CONFIG_CONTENT)" >&2; return 1; }
  [ -f "$BIN/lead-opencode.mjs" ] || { echo "jarvis: no $BIN/lead-opencode.mjs — re-run jarvis:setup" >&2; return 1; }
  u="file://$(url_path "$d/lead-opencode.mjs")"
  oc=$(printf '%s' "$oc" | jq -c --arg u "$u" '
    if type != "object" then error("it is not a JSON object")
    elif (.plugin // []) | type != "array" then error("its plugin is not a list")
    else .plugin = (((.plugin // []) - [$u]) + [$u]) end' 2>&1) \
    || { echo "jarvis: OPENCODE_CONFIG_CONTENT can't take the lead plugin: $oc. Fix or unset it; nothing was started" >&2; return 1; }
  cp "$BIN/lead-opencode.mjs" "$d/.lead-opencode.$$" && mv "$d/.lead-opencode.$$" "$d/lead-opencode.mjs" || return 1
  jq -n --arg j "$ROOT/$BIN/jarvis" --arg a opencode --arg g "$2" --arg p "$(lead_prefix)" \
    '{jarvis: $j, agent: $a, generation: $g, prefix: $p}' > "$d/.lead-opencode.$$" && mv "$d/.lead-opencode.$$" "$d/lead-opencode.json" || return 1
  echo "export OPENCODE_CONFIG_CONTENT=$(tmux_sq "$oc")"
  lead_wrap opencode "--agent build"
}

# ---------------------------------------------------------------- the watcher's clear

# Whether the watcher may clear it now: its last event a stop (or the last clear) $1+ min
# ago, no clear still unconfirmed or half-sent, not limited. Unknown idle never clears.
lead_clearable() { # $1 = idle minutes
  case "$(lead_stamp_kind)" in stop|cleared) ;; *) return 1 ;; esac
  [ -n "$1" ] && [ "$1" -ge "$JARVIS_IDLE_MIN" ] || return 1
  [ -z "$(lead_get reset)" ] && [ -z "$(lead_get prompt)" ] && [ ! -f "$STATE/lead-limit" ]
}

# The watcher's clear, with the batch: 0 = sent (the batch is used), 1 = keep the batch
# for a later tick, 2 = not clearable after all (wake it the plain way). $1 = idle min,
# $2 = events, $3 = kinds. same-session (agy): its /clear, the stamp restarts the idle
# clock. new-root (codex, opencode): the clear is only requested; a turn from a new root
# session confirms it (hook_lead), and until then nothing is cleared again.
lead_reset() {
  local a clear old line
  a=$(lead_agent); clear=$(lead_attr CLEAR)
  lead_lock || return 1
  if ! lead_clearable "$(jarvis_idle_min)"; then lead_unlock; return 2; fi
  if [ "$(lead_attr RESET_CONFIRM)" = same-session ]; then
    lead_unlock
    send_jarvis "$clear" || { echo "$(date +%H:%M) couldn't send $clear to Jarvis ($a); the events wait for the next tick"; return 1; }
    sleep "${JARVIS_LEAD_SETTLE_SEC:-3}"; lead_stamp cleared
    if ! send_jarvis "$(lead_fresh_prompt "$1" "$2")"; then
      lead_put prompt pending; echo "$(date +%H:%M) cleared Jarvis ($a) but couldn't wake it; the prompt goes again next tick"; return 1
    fi
    watch_log cleared "$3"
    echo "$(date +%H:%M) cleared Jarvis ($a, idle $1 min) and woke it:$2"
    return 0
  fi
  old=$(lead_get root)
  [ -n "$old" ] || { lead_unlock; return 2; }
  line=$(cat "$STATE/lead.stamp" 2>/dev/null)
  # from here its old session's events can't make it idle; a new root's role prompt confirms
  lead_put reset requested oldroot "$old" root ""; lead_stamp unknown
  lead_unlock
  if ! send_jarvis "$clear"; then
    if lead_lock; then # nothing was typed: back as it was
      [ "$(lead_get reset)" = requested ] && [ "$(lead_get oldroot)" = "$old" ] \
        && lead_put reset "" oldroot "" root "$old" && printf '%s\n' "$line" > "$STATE/lead.stamp"
      lead_unlock
    fi
    echo "$(date +%H:%M) couldn't send $clear to Jarvis ($a); the events wait for the next tick"
    return 1
  fi
  watch_log reset-requested "$a"
  lead_put prompt pending
  sleep "${JARVIS_LEAD_SETTLE_SEC:-3}"
  if ! send_jarvis "$(lead_fresh_prompt "$1" "$2")"; then
    echo "$(date +%H:%M) sent $clear to Jarvis ($a) but couldn't wake it; the prompt goes again next tick"; return 1
  fi
  lead_put prompt ""
  watch_log woke "$3"
  echo "$(date +%H:%M) sent $clear to Jarvis ($a, idle $1 min; a new session confirms it) and woke it:$2"
}
