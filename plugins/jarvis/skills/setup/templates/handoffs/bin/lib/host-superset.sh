# shellcheck shell=bash
# Sourced by bin/jarvis; not run on its own.
superset_self() { printf '%s' "${SUPERSET_TERMINAL_ID:-}"; }

AGY_SUPERSET_MSG="no agy worker on Superset: its Antigravity preset (--mode accept-edits) asks before every shell command. Add an agy agent config with --dangerously-skip-permissions in Superset's agent settings (or add the flag to the preset), then set JARVIS_AGY_SUPERSET_AGENT=<its id, or agy> in $H/jarvis.conf — or spawn it on tmux"

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
  # Superset's agy preset runs --mode accept-edits, which stops at every shell command for
  # approval: an agy worker needs an agent config that skips permissions
  if [ "$agent" = agy ]; then
    [ -n "$JARVIS_AGY_SUPERSET_AGENT" ] || { echo "$AGY_SUPERSET_MSG" >&2; return 1; }
    agent=$JARVIS_AGY_SUPERSET_AGENT
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

superset_send() { # the CLI's error stays on stderr; no output, or JSON that says nothing went in, is a failure too
  if [ "${2:-}" = --keys ]; then set -- "$1" --keys "${3:-}"
  # a text that starts with "-" is taken for an option and refused unless it is --text=…
  else case "$2" in -*) set -- "$1" "--text=$2" ;; *) set -- "$1" --text "$2" ;; esac
  fi
  # a busy terminal can refuse or answer nothing once and take it a moment later; every failure
  # here means nothing went in, so one retry can't type it twice
  superset_send_once "$@" && return 0
  sleep "${JARVIS_SEND_RETRY_SEC:-2}"
  superset_send_once "$@"
}

superset_send_once() {
  local out
  out=$(superset terminals send --workspace "$WS" --terminal "$@" --json) || return 1
  [ -n "$out" ] || { echo "superset took nothing into $1: no output" >&2; return 1; }
  case "$out" in
    '{'*) have jq || return 0
      printf '%s' "$out" | jq -e '.submitted == true or (.keys // 0) > 0' >/dev/null 2>&1 \
        || { echo "superset took nothing into $1: $out" >&2; return 1; } ;;
  esac
}

superset_close() { superset terminals close --workspace "$WS" --terminal "$1" >/dev/null; }
