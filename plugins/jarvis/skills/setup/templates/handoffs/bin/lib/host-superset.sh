# shellcheck shell=bash
# Sourced by bin/jarvis; not run on its own.
superset_self() { printf '%s' "${SUPERSET_TERMINAL_ID:-}"; }

superset_spawn() {
  local agent=$1 model=$2 effort=$3 prompt=$4 a out
  shift 5
  # each attachment becomes "--attachment <path>" at the end of the list, the original dropped
  for a in "$@"; do set -- "$@" --attachment "$a"; shift; done
  # a launch can't carry --settings here; an agent config can (JARVIS_FABLE_SUPERSET_AGENT).
  # Another agent naming fable keeps its own config, and the backstop stays in force.
  if [ "${FABLE_LIFT:-0}" = 1 ] && [ "$agent" = claude ]; then
    [ -n "$JARVIS_FABLE_SUPERSET_AGENT" ] || { echo "$FABLE_SUPERSET_MSG" >&2; return 1; }
    agent=$JARVIS_FABLE_SUPERSET_AGENT
  fi
  set -- "$@" --workspace "$WS" --agent "$agent" --prompt "$prompt" --json
  case "$model" in ""|\<*) ;; *) set -- "$@" --model "$model" ;; esac
  [ -n "$effort" ] && set -- "$@" --effort "$effort"
  out=$(superset agents create "$@" 2>&1) || { echo "$out" >&2; return 1; }
  printf '%s' "$out" | jq -r '.sessionId // empty' 2>/dev/null | grep . || { echo "no sessionId in: $out" >&2; return 1; }
}

superset_run() { superset terminals create --workspace "$WS" --command "$2" --json >/dev/null; }

superset_list() {
  local out
  out=$(superset terminals list --workspace "$WS" --json 2>/dev/null) || return 1
  printf '%s' "$out" | jq -r '.sessions[]? | select(.exited | not) | .terminalId'
}

superset_titles() {
  superset terminals list --workspace "$WS" --json 2>/dev/null \
    | jq -r '.sessions[]? | select(.exited | not) | [.terminalId, (.customTitle // .title // "")] | @tsv'
}

superset_read() {
  superset terminals read --workspace "$WS" --terminal "$1" --max-lines "$2" --json 2>/dev/null \
    | { have jq && jq -r '.text // empty' || cat; }
}

superset_send() {
  if [ "${2:-}" = --keys ]; then
    superset terminals send --workspace "$WS" --terminal "$1" --keys "${3:-}" >/dev/null
  else
    superset terminals send --workspace "$WS" --terminal "$1" --text "$2" >/dev/null
  fi
}

superset_close() { superset terminals close --workspace "$WS" --terminal "$1" >/dev/null; }
