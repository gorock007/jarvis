# shellcheck shell=bash
# Sourced by bin/jarvis; not run on its own.

# ---------------------------------------------------------------- hosts

# A host runs agents in terminals that Jarvis can read and type into. It is seven
# functions named <host>_<op>; everything else in this script is the same on any host.
#   self                                 this terminal's id
#   spawn <agent> <model> <effort> <prompt> <name> [<attachment>...]
#                                        start a worker in a new terminal in this checkout,
#                                        print its terminal id; errors go to stderr
#   run <name> <command>                 a plain command in a terminal of its own
#   list                                 the ids of the open terminals, one per line;
#                                        fails when the host can't be asked (none open is not a failure)
#   read <id> <lines>                    the bottom of a terminal's screen, as text
#   send <id> <text>                     type text and press Enter
#   send <id> --keys <k,k>               press keys, in Superset's names (enter, esc,
#                                        tab, shift+tab, up, ctrl+c, a single character)
#   close <id>                           close a terminal
#   titles                               optional: "<id>\t<title>" per open terminal, so
#                                        `jarvis doctor` can name the ones it doesn't know
#   clear <id>                           optional: restart Jarvis's agent on a fresh
#                                        context in the same terminal; without it the
#                                        watcher types /clear
# Built in: superset, ultron and tmux. Another (an IDE, a remote box) defines the same
# functions in handoffs/bin/hosts/<name>.sh and is picked with JARVIS_HOST=<name> in
# jarvis.conf.
# Every spawn passes the Fable final check in host() first. For an authorized Fable run
# it sets FABLE_LIFT=1, and the spawn adds --settings "$FABLE_SETTINGS" to that one
# claude launch, so the user-level allowlist without Fable (the backstop) lets it through.
# A host that can't pass it leaves the backstop in force: the worker runs on Opus.

agent_cmd() { # $1 = agent: the sh command line a terminal host runs for it
  local v
  case "$1" in ""|*[!a-z0-9_]*) return 1 ;; esac
  eval "v=\${JARVIS_AGENT_$1:-}"
  [ -n "$v" ] && printf '%s\n' "$v"
}

host_pick() {
  if [ -n "$JARVIS_HOST" ]; then echo "$JARVIS_HOST"
  elif [ -n "${SUPERSET_WORKSPACE_ID:-}" ]; then echo superset
  elif [ -n "${ULTRON_SESSION_ID:-}" ]; then echo ultron
  elif [ -n "${TMUX:-}" ]; then echo tmux
  fi
}

need_host() {
  [ -n "$HOST" ] || die "no host: run Jarvis in a Superset terminal, an Ultron session or inside tmux, or set JARVIS_HOST in $H/jarvis.conf"
}

host() { # $1 = op, then its arguments
  local op=$1
  shift
  need_host
  type "${HOST}_$op" >/dev/null 2>&1 || die "host $HOST has no $op: define ${HOST}_$op in $BIN/hosts/$HOST.sh"
  [ "$op" = spawn ] && fable_final "$@"   # whoever called, the last word before a launch
  "${HOST}_$op" "$@"
}
