# shellcheck shell=bash
# Sourced by bin/jarvis; not run on its own.

# Ultron: its daemon runs each agent in a session (s_…) in this checkout's project and
# launches the agent itself, as Superset does. A Claude Jarvis there is usually a chat
# session (stream transport): it has no screen, so read and send go through `chat`.
ult() { if have ultron; then ultron "$@"; else "$HOME/.ultron/bin/ultron" "$@"; fi; }

ultron_self() { printf '%s' "${ULTRON_SESSION_ID:-}"; }

ultron_chat() { # whether session $1 is a chat session
  [ "$(ult term get "$1" --json 2>/dev/null | jq -r '.transport // empty' 2>/dev/null)" = stream ]
}

ultron_spawn() {
  local agent=$1 model=$2 effort=$3 prompt=$4 name=$5 a out
  shift 5
  for a in "$@"; do set -- "$@" --attachment "$a"; shift; done
  set -- "$@" --agent "$agent" --role worker --title "$name" --cwd "$ROOT" --prompt "$prompt" --json
  case "$model" in ""|\<*) ;; *) set -- "$@" --model "$model" ;; esac
  [ -n "$effort" ] && set -- "$@" --effort "$effort"
  # extra args for claude itself; another agent's CLI wouldn't take them
  [ "${FABLE_LIFT:-0}" = 1 ] && [ "$agent" = claude ] && set -- "$@" -- --settings "$FABLE_SETTINGS"
  out=$(ult agent spawn "$@" 2>&1) || { echo "$out (is this checkout an Ultron project? ultron project add .)" >&2; return 1; }
  printf '%s' "$out" | jq -r '.id // empty' 2>/dev/null | grep . || { echo "no id in: $out" >&2; return 1; }
}

ultron_run() { ult term create --title "$1" --command "$2" --cwd "$ROOT" --json >/dev/null; }

ultron_list() {
  local out
  out=$(ult term list --json 2>/dev/null) || return 1
  printf '%s' "$out" | jq -r '.[]? | select(.state | IN("exited", "failed") | not) | .id'
}

ultron_read() { # a chat session's conversation stands in for its screen
  if ultron_chat "$1"; then
    ult chat history "$1" --limit 200 --json 2>/dev/null | jq -r '.events[]? | .data as $d
      | if .kind == "user_message" then ($d.text // "" | split("\n")[] | "> " + .)
        elif .kind == "assistant_message" then ($d.text // "")
        elif .kind == "tool_use" then "[tool \($d.name // "?")]"
        elif .kind == "turn_finished" then "[turn done]"
        else empty end' 2>/dev/null | tail -n "$2"
    return
  fi
  ult term read "$1" --max-lines "$2" --json 2>/dev/null | { have jq && jq -r '.screen // empty' || cat; }
}

ultron_send() {
  local id=$1 k b
  if [ "${2:-}" = --keys ]; then
    ultron_chat "$id" && { echo "$id is a chat session: it takes text, not keys" >&2; return 1; }
    # term send types its text as is, so a key is the bytes a terminal sends for it
    for k in $(printf '%s' "${3:-}" | tr ',' ' '); do
      case "$k" in
        enter) ult term send "$id" --text "" --json >/dev/null || return 1; continue ;;
        esc|escape) b=$'\e' ;; tab) b=$'\t' ;; shift+tab) b=$'\e[Z' ;; space) b=" " ;; backspace) b=$'\x7f' ;;
        up) b=$'\e[A' ;; down) b=$'\e[B' ;; right) b=$'\e[C' ;; left) b=$'\e[D' ;;
        ctrl+[a-z]) b=$(printf "\\$(printf '%03o' $(( $(printf '%d' "'${k#ctrl+}") - 96 )))") ;;
        alt+?) b=$'\e'"${k#alt+}" ;;
        ?) b=$k ;;
        *) echo "ultron: no key '$k'" >&2; return 1 ;;
      esac
      ult term send "$id" --text "$b" --no-submit --json >/dev/null || return 1
    done
    return 0
  fi
  if ultron_chat "$id"; then
    ult chat send "$id" --text "$2" --json >/dev/null
  else
    ult term send "$id" --text "$(printf '%s' "$2" | tr '\n' ' ')" --json >/dev/null
  fi
}

ultron_close() { ult term close "$1" --json >/dev/null; }

ultron_clear() { ult term clear "$1" --json >/dev/null; } # same session id, fresh agent
