# shellcheck shell=bash
# Sourced by bin/jarvis; not run on its own.
# ---------------------------------------------------------------- hooks

# UserPromptSubmit, Jarvis's terminal only: after a long idle the prompt cache has
# expired, and the next turn would write the whole context again. Stop the prompt
# once and suggest /clear; sending it again goes through.
hook_prompt() {
  local in sid tp prompt me last gap ctx model price usd marker
  have jq || exit 0
  in=$(cat)
  me=""
  [ -n "$HOST" ] && type "${HOST}_self" >/dev/null 2>&1 && me=$("${HOST}_self")
  sid=$(printf '%s' "$in" | jq -r '.session_id // empty')
  # every terminal: which Claude sessions ran in it, so `jarvis leftovers` can
  # tell what a worker started even after it ran /clear (tmux pane ids are %N)
  case "$me$sid" in
    *[!A-Za-z0-9_%-]*) ;;
    *) if [ -n "$me" ] && [ -n "$sid" ] && ! grep -qxF "$sid" "$STATE/sessions/$me" 2>/dev/null; then
         mkdir -p "$STATE/sessions" && echo "$sid" >> "$STATE/sessions/$me"
       fi ;;
  esac
  [ -n "$me" ] && [ "$me" = "$(jarvis_terminal)" ] || exit 0
  tp=$(printf '%s' "$in" | jq -r '.transcript_path // empty')
  prompt=$(printf '%s' "$in" | jq -r '.prompt // empty')
  [ -n "$sid" ] && [ -f "$tp" ] || exit 0
  mkdir -p "$STATE"
  # the watcher reads this to tell how long Jarvis has been idle
  jq -n --arg t "$me" --arg s "$sid" --arg p "$tp" --argjson ts "$(now)" \
    '{terminal: $t, session_id: $s, transcript_path: $p, ts: $ts}' > "$STATE/session.json"
  case "$prompt" in /*) exit 0 ;; esac

  last=$(tail -n 400 "$tp" | jq -c 'select(.type == "assistant" and .message.usage) |
      {t: .timestamp, m: .message.model, u: .message.usage}' 2>/dev/null | tail -n 1)
  [ -n "$last" ] || exit 0
  gap=$(printf '%s' "$last" | jq -r --argjson now "$(now)" \
    '(.t | sub("\\.[0-9]+"; "") | fromdateiso8601) as $t | (($now - $t) / 60 | floor)' 2>/dev/null) || exit 0
  ctx=$(printf '%s' "$last" | jq -r '.u | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)')
  model=$(printf '%s' "$last" | jq -r '.m // ""')
  [ "$gap" -ge "$JARVIS_IDLE_MIN" ] && [ "$ctx" -ge "$JARVIS_GUARD_TOKENS" ] || exit 0

  marker="$STATE/guard-$sid"
  if [ -f "$marker" ] && [ $(( $(now) - $(mtime "$marker") )) -lt 900 ]; then rm -f "$marker"; exit 0; fi
  touch "$marker"
  case "$model" in
    *fable*) price=20 ;; *opus-5-5*) price=8 ;; *opus*) price=10 ;; *sonnet*) price=4 ;; *haiku*) price=2 ;; *) price=10 ;;
  esac
  usd=$(awk -v t="$ctx" -v p="$price" 'BEGIN{printf "%.2f", t * p / 1000000}')
  jq -n --arg r "Jarvis has been idle ${gap} min, so its prompt cache has expired: this message would write all $((ctx / 1000))k tokens of context again (about \$${usd} at API prices). Cheaper: /clear, then \"resume\" — Jarvis reloads from $OPEN. To go ahead anyway, send your message again." \
    '{decision: "block", reason: $r}'
}

# A non-Claude Jarvis's own hooks (jarvis lead writes them; lib/lead.sh):
#   jarvis hook lead <working|stop|unknown|limit|ok> <agent> <generation>, the payload on stdin.
# A callback whose agent or generation isn't the running launch's (lead.launch) is
# dropped, as is a worker's. They stamp its last turn event, which the watcher reads for
# its idle time as it reads a Claude Jarvis's transcript, and record a quota error.
# - agy: PreInvocation → working, Stop → stop; a Stop whose error is Google's 429 marks it
#   limited, a clean one lifts a limit its hooks set. The old one-argument form (an agy
#   started before callbacks named their launch) counts only while no launch is recorded.
# - codex, opencode: only the root session's turns count. Until one is bound, a working
#   whose prompt begins "You are Jarvis, on <agent>" binds its session; after the watcher's
#   clear, that prompt from a different session confirms the clear (from the same one: the
#   reset is unconfirmed, and the watcher stops clearing). stop after stop keeps the first
#   one's time. limit carries an error (opencode: its plugin's session.error or retry);
#   ok is an error-free turn, which lifts a limit its hooks set. Silent, exit 0.
hook_lead() {
  local kind=${1:-} agent=${2:-} gen=${3:-} cur in=""
  case "$kind" in working|stop|unknown|limit|ok) ;; *) exit 0 ;; esac
  cur=$(lead_agent)
  [ "$cur" != claude ] && [ "${JARVIS_ROLE:-}" != worker ] || exit 0
  if [ -z "$agent" ]; then
    [ "$cur" = agy ] && [ ! -f "$STATE/lead.launch" ] || exit 0
    case "$kind" in working|stop) ;; *) exit 0 ;; esac
  else
    [ "$agent" = "$cur" ] && [ -n "$gen" ] || exit 0
  fi
  [ -t 0 ] || in=$(cat)
  lead_lock || exit 0
  trap lead_unlock EXIT
  # under the lock: a relaunch since this hook's launch makes it stale
  [ -z "$agent" ] || { [ "$(rec_get "$STATE/lead.launch" agent)" = "$agent" ] && [ "$(rec_get "$STATE/lead.launch" generation)" = "$gen" ]; } || exit 0
  if [ "$cur" = agy ]; then hook_lead_agy "$kind" "$in"; else hook_lead_root "$kind" "$in"; fi
  exit 0
} >/dev/null 2>&1

hook_lead_agy() { # $1 = kind, $2 = payload
  local err
  if [ "$1" = stop ] && have jq; then
    err=$(printf '%s' "$2" | jq -r '.error // empty | strings' 2>/dev/null)
    err=$(printf '%s' "$err" | tr '\n\r\t' '   ')
    if [ -z "$err" ]; then [ "$(rec_get "$STATE/lead-limit" source)" != hook ] || lead_limit_clear
    elif printf '%s' "$err" | grep -Eiq "$(lead_attr ERROR_RE)"; then lead_limit_set hook "$err"
    fi
  fi
  case "$1" in
    working) lead_stamp working ;;
    stop) case "$(lead_stamp_kind)" in stop|cleared) ;; *) lead_stamp stop ;; esac ;;
  esac
}

hook_lead_root() { # $1 = kind, $2 = payload
  local sid root e code
  have jq || return 0
  sid=$(printf '%s' "$2" | jq -r '(.session_id // .sessionID // empty) | strings' 2>/dev/null)
  case "$sid" in ""|*[!A-Za-z0-9_.:-]*) return 0 ;; esac
  root=$(lead_get root)
  if [ "$1" = working ] && printf '%s' "$2" | jq -e --arg p "$(lead_prefix)" '(.prompt // "") | strings | startswith($p)' >/dev/null 2>&1; then
    if [ -z "$root" ]; then
      if [ "$(lead_get reset)" != requested ]; then lead_put root "$sid"
      elif [ "$sid" != "$(lead_get oldroot)" ]; then lead_put root "$sid" reset "" oldroot ""; watch_log reset-confirmed "$(lead_agent)"
      else lead_put root "$sid" reset unconfirmed oldroot ""; watch_log reset-unconfirmed "$(lead_agent)"
      fi
      root=$sid
    elif [ "$sid" != "$root" ] && [ "$(lead_stamp_kind)" != working ]; then
      lead_put root "$sid"; root=$sid   # a new root while the old one is idle: the user's own new session
    fi
  fi
  [ "$sid" = "$root" ] || return 0
  case "$1" in
    working) lead_stamp working ;;
    stop) case "$(lead_stamp_kind)" in stop|cleared) ;; *) lead_stamp stop ;; esac ;;
    unknown) lead_stamp unknown ;;
    limit)
      e=$(printf '%s' "$2" | jq -r '.error // empty | strings' 2>/dev/null)
      e=$(printf '%s' "$e" | tr '\n\r\t' '   ')
      code=$(printf '%s' "$2" | jq -r '.status_code // empty | numbers' 2>/dev/null)
      if [ "$code" = 429 ] || { [ -n "$e" ] && [ -n "$(lead_attr ERROR_RE)" ] && printf '%s' "$e" | grep -Eiq "$(lead_attr ERROR_RE)"; }; then
        lead_limit_set hook "${e:-HTTP 429}"
      fi
      # a retry is still its turn; an error ends it, unless an idle follows
      if [ "$(printf '%s' "$2" | jq -r '.state // empty' 2>/dev/null)" = retry ]; then lead_stamp working; else lead_stamp unknown; fi ;;
    ok) [ "$(rec_get "$STATE/lead-limit" source)" != hook ] || lead_limit_clear ;;
  esac
}

# PreToolUse, every session in the checkout: deny an Agent/Task call whose model is
# Fable, and an Edit/Write/MultiEdit after which a settings file lets Fable in: in
# availableModels (that re-opens it: allowlists merge), modelOverrides, or an alias
# variable in env. A settings file is rebuilt as the edit would leave it and parsed by
# jq, which decodes \u escapes, so neither escapes nor a word split across edits get
# past. The top of this script has already left unless the input names fable or a
# settings*.json file. No jq, or input that doesn't parse: allow, and the backstop
# covers it. Not covered (documented limits; the backstop is what holds there): a Bash
# command writing the file, or an agent definition's model: fable.
hook_pretool() {
  local in tool m f lf d why="" cwd p parent base resolved guarded gd gdl target hops leaf_unresolved
  in=${JARVIS_HOOK_IN:-}
  have jq || exit 0
  tool=$(printf '%s' "$in" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
  case "$tool" in
    Agent|Task)
      m=$(printf '%s' "$in" | jq -r '.tool_input.model // empty' 2>/dev/null)
      case "$(printf '%s' "$m" | tr '[:upper:]' '[:lower:]')" in
        *fable*) why="Fable is off for subagents here: use model: \"sonnet\" (or leave model out; subagents default to Sonnet)" ;;
      esac ;;
    Edit|Write|MultiEdit)
      f=$(printf '%s' "$in" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
      cwd=$(printf '%s' "$in" | jq -r '.cwd // empty' 2>/dev/null)
      [ -n "$cwd" ] || cwd=$JARVIS_CALLER_PWD
      case "$f" in /*) p=$f ;; *) p=$cwd/$f ;; esac
      # First collapse repeated slashes and dot segments lexically. Then, when the
      # parent exists, resolve it physically so a symlinked directory cannot hide a
      # guarded settings file. Resolve an existing symlink leaf too; its own name may
      # be harmless while its target is settings.json. The leaf need not exist yet
      # (Write commonly creates it).
      p=$(printf '%s\n' "$p" | awk -F/ '{
        n = 0
        for (i = 1; i <= NF; i++) {
          if ($i == "" || $i == ".") continue
          if ($i == "..") { if (n > 0) n--; continue }
          a[++n] = $i
        }
        out = "/"
        for (i = 1; i <= n; i++) out = out (i > 1 ? "/" : "") a[i]
        print out
      }')
      parent=$(dirname "$p"); base=$(basename "$p"); resolved=0
      if [ -d "$parent" ]; then
        p=$(cd "$parent" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$base") && resolved=1
      fi
      leaf_unresolved=0
      if [ -L "$p" ]; then
        hops=0
        while [ -L "$p" ] && [ "$hops" -lt 10 ]; do
          target=$(readlink "$p" 2>/dev/null) || { leaf_unresolved=1; break; }
          case "$target" in /*) p=$target ;; *) p=$(dirname "$p")/$target ;; esac
          p=$(printf '%s\n' "$p" | awk -F/ '{
            n = 0
            for (i = 1; i <= NF; i++) {
              if ($i == "" || $i == ".") continue
              if ($i == "..") { if (n > 0) n--; continue }
              a[++n] = $i
            }
            out = "/"
            for (i = 1; i <= n; i++) out = out (i > 1 ? "/" : "") a[i]
            print out
          }')
          parent=$(dirname "$p"); base=$(basename "$p")
          if [ -d "$parent" ]; then
            p=$(cd "$parent" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$base") || { leaf_unresolved=1; break; }
          else
            leaf_unresolved=1; break
          fi
          hops=$((hops + 1))
        done
        [ $leaf_unresolved = 1 ] || { [ ! -L "$p" ] && [ -e "$p" ]; } || leaf_unresolved=1
        [ $leaf_unresolved = 0 ] || resolved=0
      fi
      lf=$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')
      base=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')
      case "$base" in settings*.json) ;; *) [ $leaf_unresolved = 1 ] || exit 0 ;; esac

      # Compare canonical directories case-blind (macOS paths are case-insensitive).
      # These are any .claude directory, plus the checkout and user-level settings
      # dirs explicitly (the latter need not themselves be named .claude).
      guarded=0; d=$(dirname "$lf")
      [ "$(basename "$d")" = .claude ] && guarded=1
      while IFS= read -r gd; do
        [ -n "$gd" ] || continue
        if [ -d "$gd" ]; then gd=$(cd "$gd" 2>/dev/null && pwd -P) || continue
        else
          gd=$(printf '%s\n' "$gd" | awk -F/ '{
            n = 0
            for (i = 1; i <= NF; i++) {
              if ($i == "" || $i == ".") continue
              if ($i == "..") { if (n > 0) n--; continue }
              a[++n] = $i
            }
            out = "/"
            for (i = 1; i <= n; i++) out = out (i > 1 ? "/" : "") a[i]
            print out
          }')
        fi
        gdl=$(printf '%s' "$gd" | tr '[:upper:]' '[:lower:]')
        [ "$d" = "$gdl" ] && { guarded=1; break; }
      done <<EOF
$ROOTP/.claude
$(backstop_files | while IFS= read -r gd; do dirname "$gd"; done)
EOF
      # If the parent cannot be resolved, a settings*.json basename still gets the
      # full content check. Failing open here would recreate the path differential.
      [ $guarded = 1 ] || [ $resolved = 0 ] || exit 0
      # the file as it would be after the edit; text that isn't JSON counts if it names fable
      m=$(printf '%s' "$in" | jq -r --arg cur "$(cat "$p" 2>/dev/null)" --arg vars " $FABLE_REMAP_VARS " '
        def rep($s; $o; $n; $all): ($s | split($o)) as $p
          | if ($p | length) < 2 then $s elif $all then $p | join($n) else $p[0] + $n + ($p[1:] | join($o)) end;
        .tool_input as $t
        | (if .tool_name == "Write" then ($t.content // "")
           elif .tool_name == "Edit" then rep($cur; $t.old_string // ""; $t.new_string // ""; $t.replace_all // false)
           else reduce ($t.edits // [])[] as $e ($cur; rep(.; $e.old_string // ""; $e.new_string // ""; $e.replace_all // false)) end) as $new
        | ($new | try fromjson catch null) as $j
        | def fab: tostring | ascii_downcase | test("fable");
          if ($j | type) == "object" then
            (($j.availableModels // []) | if type == "array" then map(fab) | any else fab end)
            or (($j.modelOverrides // {}) | fab)
            or (($j.env // {}) | if type == "object" then to_entries | map(select(.key as $k | $vars | index(" " + $k + " ")) | .value | fab) | any else false end)
          else ($new | ascii_downcase | test("fable")) end' 2>/dev/null)
      [ "$m" = true ] && why="After this edit $f lets Fable in (availableModels, modelOverrides or a model alias in env). Allowlists merge across settings files, so that re-opens Fable for every session that reads it. Leave it out: only the user authorizes Fable, one brief at a time (handoffs/bin/jarvis fable allow)."
      m=$f ;;
    *) exit 0 ;;
  esac
  [ -n "$why" ] || exit 0
  fable_log deny - - "$(printf '%s' "$in" | jq -r '.session_id // "-"' 2>/dev/null)" "hook: $tool ${m:--}"
  jq -n --arg r "$why" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
}

# Statusline tap: Claude Code hands the statusline its rate-limit numbers. Save
# them for `jarvis band`, then run the user's own statusline unchanged.
cmd_statusline() {
  local in cmd line
  in=$(cat)
  if have jq; then
    line=$(printf '%s' "$in" | jq -c --argjson ts "$(now)" 'select(.rate_limits.five_hour) | .rate_limits + {ts: $ts}' 2>/dev/null)
    if [ -n "$line" ]; then
      # the machine-wide reading `band` uses, its history, and this repo's own copy (`jarvis usage`)
      (umask 077; mkdir -p "$JHOME") 2>/dev/null && usage_save "$JHOME" "$line" && usage_hist "$line"
      mkdir -p "$STATE" 2>/dev/null && usage_save "$STATE" "$line"
    fi
    cmd="${JARVIS_STATUSLINE_CMD:-$(jq -r '.statusLine.command // empty' "$HOME/.claude/settings.json" 2>/dev/null)}"
  else
    cmd="${JARVIS_STATUSLINE_CMD:-}"
  fi
  case "$cmd" in *"jarvis statusline"*) cmd="" ;; esac
  if [ -n "$cmd" ]; then printf '%s' "$in" | sh -c "$cmd"
  elif have jq; then printf '%s' "$in" | jq -r '"\(.model.display_name // "") · 5h \(.rate_limits.five_hour.used_percentage // "?" | tostring | .[0:4])%"'
  fi
}

usage_save() { # $1 = dir, $2 = the reading: written to a temp file beside usage.json, then moved
  local tmp="$1/usage.json.$$"
  printf '%s\n' "$2" > "$tmp" 2>/dev/null && mv "$tmp" "$1/usage.json" || { rm -f "$tmp"; return 1; }
}

# One "<ts> <five_hour %> <seven_day %> <five_hour resets_at>" line per minute at most,
# the last 500 kept: the burn rate `band` reads.
usage_hist() { # $1 = the reading
  local h="$JHOME/usage.hist" l t
  l=$(printf '%s' "$1" | jq -r '"\(.ts) \(.five_hour.used_percentage // "-") \(.seven_day.used_percentage // "-") \(.five_hour.resets_at // "-")"' 2>/dev/null) || return 0
  t=$(tail -n 1 "$h" 2>/dev/null | awk '{print $1}')
  case "$t" in ""|*[!0-9]*) t=0 ;; esac
  [ $(( ${l%% *} - t )) -ge 60 ] || return 0
  printf '%s\n' "$l" >> "$h"
  [ "$(wc -l < "$h")" -gt 500 ] && tail -n 500 "$h" > "$h.$$" && mv "$h.$$" "$h"
  return 0
}
