# shellcheck shell=bash
# Sourced by bin/jarvis; not run on its own.
# ---------------------------------------------------------------- fable

# No worker starts on Fable unless the user authorized that exact brief, once, at a
# real terminal: a Claude worker, or any other whose model names fable (an agent of
# jarvis.conf or a Superset agent config may wrap claude). `jarvis fable allow <brief>` reads the brief's slug from /dev/tty,
# which an agent's Bash tool doesn't have, and refuses when an agent CLI is among its
# parent processes or has left its variables in the environment. That is a speed bump,
# not a lock: an agent set on it can still open a pty of its own, detach from its
# parent, or write a record by hand. The layers left then are the audit log, the
# PreToolUse hook (no Fable subagent, no Fable put into a settings allowlist) and the
# backstop: a user-level availableModels without Fable, which Claude Code enforces by
# running the default model instead, Agent-tool overrides included. The backstop alone
# holds against a Bash command editing a settings file and an agent definition's
# model: fable; nothing here checks those.
#
# An authorization is a record in $FABLE_DIR/pending/: the brief's physical path, the
# sha256 of the brief without its started: lines (spawn rewrites those), this
# checkout's root and when it was allowed. Spawn moves it into used/, the run's name
# appended, right before the launch, and host() checks that it did. Anything missing,
# unreadable, edited, from another checkout or older than JARVIS_FABLE_TTL_MIN refuses;
# so does a red band, --force or not. Every allow, deny, consume and revoke is one line
# of $FABLE_DIR/audit.log. Allowlists merge across settings files (an entry in any
# scope lets a model in), so a project or local settings file listing fable undoes the
# backstop: spawn refuses while one exists here, and status and doctor name it.

FABLE_DIR="${JARVIS_HOME:-$HOME/.jarvis}/fable"
FABLE_ALLOWED='["opus","sonnet","haiku"]'   # the backstop's availableModels: aliases cover the full ids
# shellcheck disable=SC2034 # read by lib/host-*.sh
FABLE_SETTINGS='{"availableModels":["opus","sonnet","haiku","fable"]}'   # added to one authorized launch
# shellcheck disable=SC2034 # read by lib/spawn.sh and lib/host-superset.sh
FABLE_SUPERSET_MSG="Superset can't pass --settings to a single launch, so under the backstop an authorized fable worker would run on Opus. Set JARVIS_FABLE_SUPERSET_AGENT in $H/jarvis.conf (see the comment there), run Jarvis on tmux or Ultron, or use worker: codex, model: gpt-6-astra"
FABLE_REMAP_VARS="ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_SMALL_FAST_MODEL CLAUDE_CODE_SUBAGENT_MODEL"
FABLE_WHY=""
FABLE_REC=""
FABLE_LIFT=0

# $1 agent, $2 model: fable for any agent whose model names it ([…] suffix aside: an
# agent of jarvis.conf, or a Superset agent config, may wrap claude); for claude also
# opus | sonnet | haiku, failing when it can't tell; other for any other agent's model
model_canon() {
  local m
  m=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  case "${m%%\[*}" in *fable*) echo fable; return 0 ;; esac
  [ "$1" = claude ] || { echo other; return 0; }
  printf '%s' "$m" | grep -Eq '^[a-z0-9._:-]+(\[[a-z0-9._:-]*\])?$' || return 1
  case "$m" in *fable*) echo fable; return 0 ;; esac
  m=${m%%\[*}
  case "$m" in
    opus|claude-opus-*) echo opus ;;
    sonnet|claude-sonnet-*) echo sonnet ;;
    haiku|claude-haiku-*) echo haiku ;;
    *) return 1 ;; # best, default, opusplan, empty, unknown: any of them might resolve to Fable
  esac
}

model_refusal() {
  echo "model '$1' isn't one jarvis can resolve for a Claude worker, and an alias it can't resolve might be Fable: use model: claude-opus-5-5, sonnet or haiku"
}

fable_needs() { # $1 = brief
  echo "fable needs your authorization for this brief: run handoffs/bin/jarvis fable allow $1 in your own terminal — or use worker: codex, model: gpt-6-astra"
}

fable_log() { # $1 event, $2 brief, $3 hash, $4 run, $5 reason: one line of the audit log; fails when it can't write
  ( umask 077; mkdir -p "$FABLE_DIR" \
    && printf '%s %s root=%s brief=%s hash=%s run=%s reason=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$ROOT" \
      "${2:--}" "${3:--}" "${4:--}" "$(printf '%s' "${5:--}" | tr '\n' ' ')" >> "$FABLE_DIR/audit.log" ) 2>/dev/null
}

fable_refuse() { # $1 brief, $2 run, $3 reason for the log, $4 message: log a deny, then stop
  fable_log deny "$1" - "$2" "$3"
  die "$4"
}

phys_path() { (cd "$(dirname "$1")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$1")"); }

brief_hash() { # $1 = brief: sha256 of it without its started: lines
  local h
  [ -r "$1" ] || return 1
  if have shasum; then h=$(grep -v '^started:' "$1" | shasum -a 256)
  elif have sha256sum; then h=$(grep -v '^started:' "$1" | sha256sum)
  else return 1; fi
  h=${h%% *}
  [ ${#h} = 64 ] && echo "$h"
}

rec_get() { awk -v k="$2" 'index($0, k ": ") == 1 {print substr($0, length(k) + 3); exit}' "$1" 2>/dev/null; } # $1 record, $2 key

# The usable pending record for brief $1, in FABLE_REC; else FABLE_WHY says what's wrong.
fable_find() {
  local p h root f t ttl
  FABLE_REC=""
  FABLE_WHY="no authorization for this brief"
  p=$(phys_path "$1") && h=$(brief_hash "$1") || { FABLE_WHY="can't read or hash the brief"; return 1; }
  root=$(cd "$ROOT" && pwd -P)
  ttl=$JARVIS_FABLE_TTL_MIN
  case "$ttl" in ""|*[!0-9]*) ttl=0 ;; esac
  for f in "$FABLE_DIR"/pending/*; do
    [ -f "$f" ] || continue
    [ -r "$f" ] && [ -O "$f" ] || { FABLE_WHY="an authorization record is unreadable or not yours"; continue; }
    [ "$(rec_get "$f" brief)" = "$p" ] && [ "$(rec_get "$f" root)" = "$root" ] || continue
    [ "$(rec_get "$f" hash)" = "$h" ] || { FABLE_WHY="the brief changed after it was authorized"; continue; }
    t=$(rec_get "$f" allowed)
    case "$t" in ""|*[!0-9]*) FABLE_WHY="an authorization record is malformed"; continue ;; esac
    [ $(( $(now) - t )) -lt $((ttl * 60)) ] || { FABLE_WHY="the authorization expired (they last $ttl min)"; continue; }
    FABLE_REC=$f
    return 0
  done
  return 1
}

fable_consume() { # $1 brief, $2 run: use the authorization up, or refuse
  local h u
  fable_find "$1" || fable_refuse "$1" "$2" "consume: $FABLE_WHY" "$(fable_needs "$1") [$FABLE_WHY]"
  h=$(rec_get "$FABLE_REC" hash)
  u="$FABLE_DIR/used/$(basename "$FABLE_REC").$2"
  ( umask 077; mkdir -p "$FABLE_DIR/used" ) 2>/dev/null
  # rename(2): of two spawns racing for one record, one gets it
  mv "$FABLE_REC" "$u" 2>/dev/null && [ ! -e "$FABLE_REC" ] \
    || fable_refuse "$1" "$2" "consume: can't move the record into used/" "$(fable_needs "$1") [its authorization couldn't be used up: is $FABLE_DIR writable?]"
  printf 'consumed: %s\nrun: %s\n' "$(now)" "$2" >> "$u" 2>/dev/null \
    || fable_refuse "$1" "$2" "consume: can't write the used record" "$(fable_needs "$1") [can't write $u]"
  fable_log consume "$1" "$h" "$2" "spawn" \
    || die "$(fable_needs "$1") [can't write the audit log $FABLE_DIR/audit.log]"
}

# Refuse any launch while an alias variable, in this environment or a settings file's
# env, points at Fable, or while this checkout's own settings let Fable in. An agent
# other than `claude` may itself wrap Claude, so the environment is what matters here.
fable_preflight() { # $1 brief, $2 run
  local v val f
  for v in $FABLE_REMAP_VARS; do
    eval "val=\${$v:-}"
    case "$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')" in
      *fable*) fable_refuse "$1" "$2" "preflight: $v names fable" "$v=$val points a model alias at Fable: unset it before spawning a worker" ;;
    esac
  done
  have jq || fable_refuse "$1" "$2" "preflight: no jq" "jq is needed to check the settings files for Fable"
  # every settings file a worker here reads: user-level (Superset's default account
  # too), project, local. An alias variable in env, or modelOverrides, naming fable.
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    v=$(jq -r --arg vars " $FABLE_REMAP_VARS " '((.env // {}) | if type == "object" then to_entries[] else empty end
        | .key as $k | select(($vars | index(" " + $k + " ")) and (.value | tostring | ascii_downcase | test("fable"))) | $k),
      (if (.modelOverrides // {}) | tostring | ascii_downcase | test("fable") then "modelOverrides" else empty end)' "$f" 2>/dev/null | head -n 1)
    case "$v" in
      "") ;;
      modelOverrides) fable_refuse "$1" "$2" "preflight: $f modelOverrides names fable" "$f has a modelOverrides entry naming Fable: take it out before spawning a Claude worker" ;;
      *) fable_refuse "$1" "$2" "preflight: $f env $v names fable" "$f sets $v to Fable in its env: take it out before spawning a Claude worker" ;;
    esac
  done <<EOF
$(backstop_files)
$ROOT/.claude/settings.json
$ROOT/.claude/settings.local.json
EOF
  f=$(fable_holes | head -n 1)
  [ -z "$f" ] || fable_refuse "$1" "$2" "preflight: $f lists fable" "$f lists fable in availableModels, and allowlists merge across settings files, so it re-opens Fable for every session in this checkout, backstop or not: take it out"
}

fable_holes() { # this checkout's settings files whose availableModels lets Fable in (unparseable + mentions fable counts)
  local f
  for f in .claude/settings.json .claude/settings.local.json; do
    [ -f "$ROOT/$f" ] || continue
    if have jq && jq empty "$ROOT/$f" 2>/dev/null; then
      jq -e '(.availableModels // []) | if type == "array" then map(tostring | ascii_downcase | test("fable")) | any
             else tostring | ascii_downcase | test("fable") end' "$ROOT/$f" >/dev/null 2>&1 && echo "$f"
    else
      grep -qi fable "$ROOT/$f" && echo "$f"
    fi
  done
}

# The final check, from host() before any spawn (cmd_spawn's, a custom host's, a future
# caller's): the model resolves, nothing remaps it, and a Fable run has an authorization
# that spawn used up for this very run in the last two minutes, not yet launched.
# $@ = the spawn arguments: agent model effort prompt name.
fable_final() {
  local canon f u="" c root
  FABLE_LIFT=0
  canon=$(model_canon "$1" "$2") || fable_refuse - "$5" "final check: model '$2' can't be resolved" "$(model_refusal "$2")"
  fable_preflight - "$5"
  [ "$canon" = fable ] || return 0
  root=$(cd "$ROOT" && pwd -P)
  for f in "$FABLE_DIR"/used/*."$5"; do
    [ -f "$f" ] && [ -O "$f" ] && [ "$(rec_get "$f" run)" = "$5" ] && [ "$(rec_get "$f" root)" = "$root" ] || continue
    grep -q '^launched:' "$f" && continue
    c=$(rec_get "$f" consumed)
    case "$c" in ""|*[!0-9]*) continue ;; esac
    [ $(( $(now) - c )) -le 120 ] || continue
    u=$f
    break
  done
  [ -n "$u" ] || fable_refuse - "$5" "final check: no authorization used up for this run" \
    "fable needs your authorization: no authorization was used up for run '$5'. Spawn it with handoffs/bin/jarvis spawn after the user runs handoffs/bin/jarvis fable allow <brief> — or use worker: codex, model: gpt-6-astra"
  printf 'launched: %s\n' "$(now)" >> "$u" 2>/dev/null || fable_refuse - "$5" "final check: can't mark the record launched" "can't write $u"
  # shellcheck disable=SC2034 # read by lib/host-*.sh
  FABLE_LIFT=1
}

under_agent() { # prints why, when an agent CLI runs this: its variables, or one among the parent processes
  local v c p
  for v in CLAUDECODE CLAUDE_CODE_SESSION_ID CLAUDE_CODE_ENTRYPOINT CLAUDE_PID OPENCODE; do
    eval "c=\${$v:-}"
    [ -z "$c" ] || { echo "$v is set, so this runs inside an agent"; return 0; }
  done
  # CODEX_HOME is the user's own setting; Codex sets other CODEX_ variables for what it runs
  v=$(env | sed -n 's/^\(CODEX_[A-Z0-9_]*\)=.*/\1/p' | grep -vx CODEX_HOME | head -n 1)
  [ -z "$v" ] || { echo "$v is set, so this runs inside an agent"; return 0; }
  for p in $(ancestors); do
    c=$(ps -ww -o command= -p "$p" 2>/dev/null)
    printf '%s\n' "$c" | awk '{ a = $1; sub(/.*\//, "", a); sub(/\.(js|mjs|cjs|exe)$/, "", a)
        if (a ~ /^(claude|codex|opencode)$/ || $1 ~ /\/claude\/versions\// \
            || (a ~ /^(node|bun|deno)$/ && $2 ~ /(claude|codex|opencode)/)) f = 1 }
      END { exit !f }' && { echo "an agent is among this command's parent processes (pid $p: $(printf '%s' "$c" | cut -c1-60))"; return 0; }
  done
  return 1
}

cmd_fable() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift
  case "$sub" in
    allow) fable_allow "$@" ;;
    list) fable_list ;;
    revoke) fable_revoke "$@" ;;
    backstop) fable_backstop "$@" ;;
    *) die "usage: jarvis fable allow <brief.md> | list | revoke <brief.md> | backstop [--apply]" ;;
  esac
}

fable_allow() {
  local brief="${1:-}" slug title typed p h root rec tmp why
  [ -f "$brief" ] || die "usage: jarvis fable allow <handoffs/briefs/file.md>"
  [ "$(model_canon "$(field worker "$brief" | awk '{print $1}')" "$(field model "$brief" | awk '{print $1}')" 2>/dev/null)" = fable ] \
    || die "$brief isn't a Fable brief (its model: doesn't name fable): nothing to authorize"
  if why=$(under_agent); then
    fable_log deny "$brief" - - "allow: $why"
    die "refused: $why. Only the user authorizes Fable: in your own terminal, run handoffs/bin/jarvis fable allow $brief"
  fi
  { : </dev/tty; } 2>/dev/null || {
    fable_log deny "$brief" - - "allow: no terminal"
    die "refused: there's no terminal to confirm on (/dev/tty won't open). Run it yourself, in your own terminal"
  }
  p=$(phys_path "$brief") && h=$(brief_hash "$brief") || die "can't read or hash $brief"
  root=$(cd "$ROOT" && pwd -P)
  slug=$(basename "$brief" .md | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}-//')
  title=$(sed -n '1s/^#[[:space:]]*//p' "$brief")
  printf 'Authorize ONE Fable run of this brief:\n  %s\n  %s\n  in %s\nUsable once, for %s min. Type its slug to confirm: %s\n> ' \
    "$title" "$brief" "$root" "$JARVIS_FABLE_TTL_MIN" "$slug" >/dev/tty
  IFS= read -r typed </dev/tty || typed=""
  if [ "$typed" != "$slug" ]; then
    fable_log deny "$brief" "$h" - "allow: the slug typed didn't match"
    die "not authorized: that isn't the slug"
  fi
  ( umask 077; mkdir -p "$FABLE_DIR/pending" ) 2>/dev/null && chmod 700 "$FABLE_DIR" "$FABLE_DIR/pending" 2>/dev/null \
    && tmp=$(umask 077; mktemp "$FABLE_DIR/pending/.tmp.XXXXXX" 2>/dev/null) || die "can't write $FABLE_DIR/pending: not authorized"
  rec="$FABLE_DIR/pending/$slug.$(now).$$"
  { printf 'brief: %s\nhash: %s\nroot: %s\nallowed: %s\n' "$p" "$h" "$root" "$(now)" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$rec"; } 2>/dev/null \
    || { rm -f "$tmp"; die "can't write $rec: not authorized"; }
  fable_log allow "$brief" "$h" - "typed at $(tty </dev/tty 2>/dev/null || echo a terminal)" \
    || { rm -f "$rec"; die "can't write the audit log $FABLE_DIR/audit.log: not authorized"; }
  echo "authorized: the next spawn of $brief may run on Fable, once, within $JARVIS_FABLE_TTL_MIN min"
}

fable_revoke() {
  local brief="${1:-}" p f n=0
  [ -f "$brief" ] || die "usage: jarvis fable revoke <handoffs/briefs/file.md>"
  p=$(phys_path "$brief")
  for f in "$FABLE_DIR"/pending/*; do
    [ -f "$f" ] && [ "$(rec_get "$f" brief)" = "$p" ] || continue
    rm -f "$f" && n=$((n + 1)) && fable_log revoke "$brief" "$(rec_get "$f" hash)" - "jarvis fable revoke"
  done
  echo "revoked $n pending authorization(s) for $brief"
}

fable_list() {
  local f t ttl=$JARVIS_FABLE_TTL_MIN left any=0
  case "$ttl" in ""|*[!0-9]*) ttl=0 ;; esac
  echo "pending (in $FABLE_DIR):"
  for f in "$FABLE_DIR"/pending/*; do
    [ -f "$f" ] || continue
    any=1
    t=$(rec_get "$f" allowed)
    case "$t" in ""|*[!0-9]*) t=0 ;; esac
    left=$(( (t + ttl * 60 - $(now)) / 60 ))
    printf '  %s · %s · %s\n' "$(rec_get "$f" brief)" "$(rec_get "$f" root)" \
      "$(if [ "$left" -gt 0 ]; then echo "usable for $left more min"; else echo EXPIRED; fi)"
  done
  [ $any = 1 ] || echo "  none"
  echo "used (latest 10):"
  # shellcheck disable=SC2012
  ls -t "$FABLE_DIR"/used/ 2>/dev/null | head -n 10 | while read -r f; do
    f="$FABLE_DIR/used/$f"
    printf '  %s · run %s · %s\n' "$(rec_get "$f" brief)" "$(rec_get "$f" run)" \
      "$(if grep -q '^launched:' "$f"; then echo launched; else echo "used up, not launched"; fi)"
  done
  echo "log (latest 10):"
  tail -n 10 "$FABLE_DIR/audit.log" 2>/dev/null | sed 's/^/  /' || true
}

backstop_files() { # the user-level settings Claude Code reads for workers: the config dir's, and Superset's default account's when it sets one
  local d
  echo "$CLAUDE_DIR/settings.json"
  d=$(cat "${SUPERSET_HOME_DIR:-$HOME/.superset}/state/default-claude-config-dir" 2>/dev/null)
  [ -n "$d" ] && [ "$d/settings.json" != "$CLAUDE_DIR/settings.json" ] && echo "$d/settings.json"
  return 0
}

backstop_on() { # $1 = settings file: its availableModels is a non-empty list without Fable
  have jq && [ -f "$1" ] && jq -e '(.availableModels | type == "array" and length > 0)
    and ((.availableModels | map(tostring | ascii_downcase | test("fable")) | any) | not)' "$1" >/dev/null 2>&1
}

fable_status() { # `jarvis status`: one line, plus one per settings file here that re-opens Fable
  local f off=0
  if have jq; then
    while IFS= read -r f; do [ -n "$f" ] && { backstop_on "$f" || off=1; }; done <<EOF
$(backstop_files)
EOF
    if [ $off = 0 ]; then echo "fable: blocked (backstop on)"; else echo "fable: backstop off — handoffs/bin/jarvis fable backstop --apply"; fi
  else
    echo "fable: backstop not checked (no jq); spawn refuses Fable without your authorization anyway"
  fi
  fable_holes | while read -r f; do echo "fable: $f lists fable in availableModels, which re-opens it in this checkout — take it out"; done
}

fable_backstop() {
  local apply=0 f tmp bak mode
  case "${1:-}" in "") ;; --apply) apply=1 ;; *) die "usage: jarvis fable backstop [--apply]" ;; esac
  have jq || die "jq is needed to read and write settings.json"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if backstop_on "$f"; then echo "on: $f has availableModels $(jq -c .availableModels "$f") — Fable is blocked"; continue; fi
    if [ $apply = 0 ]; then
      if [ -f "$f" ]; then echo "off: $f has availableModels $(jq -c '.availableModels // "(none)"' "$f" 2>/dev/null || echo '(unreadable)')"
      else echo "off: $f doesn't exist"; fi
      echo "  apply: handoffs/bin/jarvis fable backstop --apply (it lists $FABLE_ALLOWED; Claude Code then runs the default model instead of Fable)"
      continue
    fi
    if [ -f "$f" ]; then
      jq empty "$f" 2>/dev/null || die "$f isn't valid JSON: left as it is"
      bak="$f.bak-jarvis-$(date +%Y%m%d%H%M%S)"
      cp -p "$f" "$bak" || die "can't back $f up to $bak: left as it is"
    else
      mkdir -p "$(dirname "$f")" || die "can't create $(dirname "$f")"
      bak=""
    fi
    tmp=$(mktemp "$f.jarvis.XXXXXX") || die "can't write beside $f"
    # keep a list the user already narrowed, minus Fable; else the default list
    { if [ -f "$f" ]; then cat "$f"; else echo '{}'; fi; } | jq --argjson a "$FABLE_ALLOWED" '
      ((.availableModels // []) | if type == "array" then map(select(tostring | ascii_downcase | test("fable") | not)) else [] end) as $k
      | .availableModels = (if ($k | length) > 0 then $k else $a end)' > "$tmp" || { rm -f "$tmp"; die "jq failed: $f left as it is"; }
    if [ -f "$f" ]; then mode=$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f" 2>/dev/null); [ -n "$mode" ] && chmod "$mode" "$tmp"; fi
    mv "$tmp" "$f" || { rm -f "$tmp"; die "can't replace $f"; }
    fable_log backstop - - - "applied to $f"
    echo "applied: $f availableModels $(jq -c .availableModels "$f")${bak:+ (backup: $bak)}"
  done <<EOF
$(backstop_files)
EOF
  fable_holes | while read -r f; do echo "but: $f lists fable in availableModels, which re-opens it in this checkout — take it out"; done
}
