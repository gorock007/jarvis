# shellcheck shell=bash
# Sourced by bin/jarvis; not run on its own.
# Claude Code's UserPromptSubmit, Stop, Notification and SessionEnd hooks, in every
# session of the checkout: a worker appends one line to its brief's event file,
# handoffs/.jarvis/events/<brief>.jsonl, {"t":<epoch>,"kind":"…","run":"…","detail":"…"};
# the watcher reads it before the screen. Anything else does nothing. Before config and
# host loading, and it never fails a hook: no output (UserPromptSubmit's stdout goes to
# the model), exit 0 whatever happens (2 on Stop would block the agent). A worker is
# JARVIS_ROLE=worker plus JARVIS_BRIEF (tmux's launch script sets both, and JARVIS_RUN,
# its pane), else the terminal Superset or Ultron gave it ($SUPERSET_TERMINAL_ID,
# $ULTRON_SESSION_ID) names a run record of a running Claude worker with a brief;
# Jarvis's terminal has none. That record is written once the host returns the terminal
# id, so a Superset or Ultron worker's first `working` event can come too early and is
# lost. run is the writer's run (JARVIS_RUN, or that terminal), empty when unknown: two
# runs of one brief share the file, and the watcher counts only its run's lines.
#   working       a prompt was submitted
#   stop          the turn finished; detail: its last_assistant_message, one line, 200 chars
#   notification  permission_prompt → permission; idle_prompt, agent_needs_input,
#                 elicitation_dialog, elicitation_url_dialog → waiting; any other → none
#   ended         the session ended (detail: its reason); clear and resume aren't an end:
#                 the terminal goes on in a new session, so they write nothing
#   permission, waiting   as written
if [ "${1:-} ${2:-}" = "hook event" ]; then
  (
    # stdin closed: a pipe would take fd 0, and cat would wait on its own output
    true 3<&0 || exec </dev/null
    k=${3:-}; in=""; d=""; b=""; f=""; t=""; w=""
    case "$k" in working|stop|notification|ended|permission|waiting) ;; *) exit 0 ;; esac
    r=${CLAUDE_PROJECT_DIR:-}
    [ -n "$r" ] && [ -d "$r/handoffs" ] || r=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
    if [ "${JARVIS_ROLE:-}" = worker ] && [ -n "${JARVIS_BRIEF:-}" ]; then b=$JARVIS_BRIEF; w=${JARVIS_RUN:-}
    else
      for t in "${SUPERSET_TERMINAL_ID:-}" "${ULTRON_SESSION_ID:-}"; do
        case "$t" in ""|.|..|*[!A-Za-z0-9_%.-]*) continue ;; esac
        b=$(awk 'index($0, "brief: ") == 1 {b = substr($0, 8)} $0 == "agent: claude" {a = 1} $0 == "state: running" {s = 1}
          END {if (a && s) print b}' "$r/handoffs/.jarvis/runs/$t" 2>/dev/null)
        [ -n "$b" ] && { w=$t; break; }
      done
    fi
    case "$w" in .|..|*[!A-Za-z0-9_%.-]*) w="" ;; esac
    f=${b##*/}; f=${f%.md}
    case "$f" in ""|.*|*[!A-Za-z0-9_.-]*) exit 0 ;; esac
    # one string field of the hook's JSON: jq when it parses, else the last "key":"value"
    # (its escapes roughly undone), on one line
    case "$k" in notification) t=notification_type ;; ended) t=reason ;; stop) t=last_assistant_message ;; *) t="" ;; esac
    if [ -n "$t" ]; then
      [ -t 0 ] || in=$(cat)
      d=$(printf '%s' "$in" | jq -r --arg t "$t" '.[$t] // empty | strings' 2>/dev/null) \
        || d=$(printf '%s' "$in" | sed -nE "s/.*\"$t\"[[:space:]]*:[[:space:]]*\"(([^\"\\\\]|\\\\.)*)\".*/\\1/p" | tail -n 1 \
          | sed -e 's/\\[nrt]/ /g' -e 's/\\"/"/g' -e 's/\\\\/\\/g')
      d=$(printf '%s' "$d" | tr '\n\r\t' '   ' | tr -d '\000-\037')
      d=${d:0:200}
    fi
    case "$k" in
      notification)
        case "$d" in
          permission_prompt) k=permission ;;
          idle_prompt|agent_needs_input|elicitation_dialog|elicitation_url_dialog) k=waiting ;;
          *) exit 0 ;;
        esac ;;
      ended) case "$d" in clear|resume) exit 0 ;; esac ;;
    esac
    d=$(printf '%s' "$d" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')   # a JSON string
    mkdir -p "$r/handoffs/.jarvis/events" || exit 0
    # one short line in one write to an O_APPEND file: concurrent hooks never interleave
    printf '{"t":%s,"kind":"%s","run":"%s","detail":"%s"}\n' "$(date +%s)" "$k" "$w" "$d" >> "$r/handoffs/.jarvis/events/$f.jsonl"
  ) >/dev/null 2>&1
  exit 0
fi
