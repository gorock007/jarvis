# shellcheck shell=bash
# Sourced by bin/jarvis; not run on its own.

# tmux: each worker gets a window in Jarvis's tmux session, named after its brief and
# tagged @jarvis, so close never touches a pane Jarvis didn't open. When the agent
# exits, the window stays up with its last screen until merge closes it.
tmux_self() { printf '%s' "${TMUX_PANE:-}"; }

tmux_session() { # the session Jarvis runs in, where workers go
  tmux display-message -p -t "${TMUX_PANE:-$(jarvis_terminal)}" '#{session_id}' 2>/dev/null
}

tmux_spawn() {
  local agent=$1 model=$2 effort=$3 prompt=$4 name=$5 cmd a sess launch id
  shift 5
  cmd=$(agent_cmd "$agent") || { echo "no launch command for agent '$agent': add JARVIS_AGENT_$agent to $H/jarvis.conf" >&2; return 1; }
  sess=$(tmux_session) || { echo "can't find Jarvis's tmux session" >&2; return 1; }
  for a in "$@"; do prompt="$prompt Read this attached file first: $a"; done
  # a script file, not a tmux command string: tmux runs those in the user's shell, and
  # the launch line is written for sh
  mkdir -p "$STATE/launch"
  launch="$STATE/launch/$name.sh"
  {
    echo "# written by jarvis spawn; tmux runs it in the worker's window"
    echo "unset CLAUDECODE CLAUDE_CODE_SESSION_ID CLAUDE_CODE_ENTRYPOINT JARVIS_ROLE JARVIS_BRIEF JARVIS_RUN"
    # a worker's hooks write its events (jarvis hook event) under its brief, signed with
    # its run: the pane id, which tmux gives the window as $TMUX_PANE and spawn as the id
    # shellcheck disable=SC2016
    case "$agent" in claude|codex|opencode) [ -n "${SPAWN_BRIEF:-}" ] \
      && echo "export JARVIS_ROLE=worker JARVIS_BRIEF='$(printf '%s' "$SPAWN_BRIEF" | sed "s/'/'\\\\''/g")'" \
      && echo 'export JARVIS_RUN="${TMUX_PANE:-}"' ;; esac
    tmux_event_lines "$agent"
    tmux_fable_lines "$model"
    echo "$cmd"
    # shellcheck disable=SC2016
    echo 's=$?; printf "\n[jarvis] %s exited (%s). Its window stays open until jarvis merge or close.\n" "$JARVIS_AGENT" "$s"'
    # OpenCode has no session-end event a plugin can rely on: its exit is the end
    [ "$agent" = opencode ] && [ -n "${SPAWN_BRIEF:-}" ] && echo "$(tmux_sq "$ROOT/$BIN/jarvis") hook event ended </dev/null"
    echo "exec tail -f /dev/null"
  } > "$launch"
  id=$(tmux new-window -d -P -F '#{pane_id}' -t "$sess:" -n "$name" -c "$ROOT" \
    -e "JARVIS_AGENT=$agent" -e "JARVIS_MODEL=$model" -e "JARVIS_EFFORT=$effort" -e "JARVIS_PROMPT=$prompt" \
    "sh $launch") || return 1
  tmux set-option -p -t "$id" @jarvis "$name" 2>/dev/null
  echo "$id"
}

tmux_sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }   # quoted for sh
url_path() { # a file path as a URL's path: % first; # and ? would end it, \ reads as /; tab, CR and LF would break the line the URL sits on
  local p=$1
  p=${p//\%/%25}; p=${p//$'\n'/%0A}   # sed reads lines, so the LF goes here
  printf '%s' "$p" | sed -e 's/ /%20/g' -e 's/#/%23/g' -e 's/?/%3F/g' -e 's/"/%22/g' -e 's/\\/%5C/g' \
    -e "s/$(printf '\t')/%09/g" -e "s/$(printf '\r')/%0D/g"
}

# Turn events for a tmux Codex or OpenCode worker, per run, never in the user's config:
# - codex: a codex() wrapper adds -c hooks (UserPromptSubmit, Stop, PermissionRequest,
#   SessionEnd; Claude's stdin shapes) to the user's own hooks and notify. Codex runs
#   session-flag hooks only under --dangerously-bypass-hook-trust, which
#   JARVIS_AGENT_codex passes; a line without it keeps the screen path.
# - opencode: a plugin, handoffs/.jarvis/launch/opencode-events.js, added through
#   OPENCODE_CONFIG_CONTENT (its plugin list adds to the user's); none if that's set.
# Superset and Ultron launch these agents themselves: the screen path stays.
tmux_event_lines() { # $1 = agent
  local j e c v
  [ -n "${SPAWN_BRIEF:-}" ] || return 0
  j=$(tmux_sq "$ROOT/$BIN/jarvis")
  case "$1" in
    codex)
      printf 'codex() { command codex'
      for e in UserPromptSubmit:working Stop:stop PermissionRequest:permission SessionEnd:ended; do
        c=$(printf '%s hook event %s' "$j" "${e#*:}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')   # a TOML string
        # built by assignment from single quotes: a {a,b} in a quoted word was brace-expanded on CI's macOS bash
        v='[{hooks=[{type="command",command="'"$c"'",timeout=10}]}]'
        printf ' -c %s' "$(tmux_sq "hooks.${e%%:*}=$v")"
      done
      echo ' "$@"; }' ;;
    opencode)
      if ! { tmux_opencode_plugin > "$STATE/launch/.opencode-events.$$" \
        && mv "$STATE/launch/.opencode-events.$$" "$STATE/launch/opencode-events.js"; }; then
        rm -f "$STATE/launch/.opencode-events.$$"; return 0
      fi
      c=$(printf 'file://%s' "$(url_path "$ROOT/$STATE/launch/opencode-events.js")" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')   # a JSON string
      echo "[ -n \"\${OPENCODE_CONFIG_CONTENT:-}\" ] || export OPENCODE_CONFIG_CONTENT=$(tmux_sq "{\"plugin\":[\"$c\"]}")" ;;
  esac
}

# The OpenCode plugin: the root session's busy → working, busy to idle → stop,
# permission.asked → permission, question.asked → waiting; subagent sessions ignored.
tmux_opencode_plugin() {
  cat <<'JS'
// written by jarvis spawn: an OpenCode worker's turn events, as jarvis hook event
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
const bin = fileURLToPath(new URL("../../bin/jarvis", import.meta.url));
export const JarvisEvents = async () => {
  if (process.env.JARVIS_ROLE !== "worker" || !process.env.JARVIS_BRIEF) return {};
  const child = new Set();
  let busy = false;
  const send = (kind) => {
    try { spawn(bin, ["hook", "event", kind], { stdio: "ignore" }).on("error", () => {}); } catch {}
  };
  return {
    event: async ({ event }) => {
      const p = event.properties || {};
      if (p.info?.parentID && p.info?.id) child.add(p.info.id);
      if (p.sessionID && child.has(p.sessionID)) return;
      if (event.type === "session.status") {
        if (p.status?.type === "busy" && !busy) { busy = true; send("working"); }
        else if (p.status?.type === "idle" && busy) { busy = false; send("stop"); }
      } else if (event.type === "permission.asked") send("permission");
      else if (event.type === "question.asked") send("waiting");
    },
  };
};
JS
}

# The final check once more, inside the launch script, for any agent (one may wrap
# claude): the window's environment comes from the tmux server too, and the script can
# be edited before it runs. So: no alias variable may point at Fable, JARVIS_MODEL must
# be the model spawn checked, and only an authorized run gets the allowlist that lifts
# the backstop. $1 = that model.
tmux_fable_lines() {
  local v q
  q=$(printf '%s' "$1" | sed "s/'/'\\\\''/g")   # quoted for sh: ' becomes '\''
  for v in ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL \
           ANTHROPIC_SMALL_FAST_MODEL CLAUDE_CODE_SUBAGENT_MODEL; do
    echo "case \"\$(printf '%s' \"\${$v:-}\" | tr '[:upper:]' '[:lower:]')\" in *fable*) unset $v ;; esac"
  done
  echo "if [ \"\$JARVIS_MODEL\" != '$q' ]; then printf '[jarvis] refused: JARVIS_MODEL is not the model spawn checked (%s)\\n' '$q'; exec tail -f /dev/null; fi"
  if [ "${FABLE_LIFT:-0}" = 1 ]; then
    echo "claude() { command claude --settings '$FABLE_SETTINGS' \"\$@\"; }"
  else
    echo "case \"\$(printf '%s' \"\${JARVIS_MODEL%%\\[*}\" | tr '[:upper:]' '[:lower:]')\" in *fable*) printf '[jarvis] refused: fable without authorization\\n'; exec tail -f /dev/null ;; esac"
  fi
}

tmux_run() { tmux new-window -d -t "$(tmux_session):" -n "$1" -c "$ROOT" "$2"; }

tmux_list() { tmux list-panes -a -F '#{pane_id}' 2>/dev/null; }

tmux_read() { # the screen plus scrollback, trailing blank lines dropped, then the last $2
  tmux capture-pane -p -J -t "$1" -S "-$2" 2>/dev/null | sed -e 's/[[:space:]]*$//' \
    | awk '{l[NR] = $0} NF {last = NR} END {for (i = 1; i <= last; i++) print l[i]}' | tail -n "$2"
}

tmux_send() {
  local id=$1 k
  if [ "${2:-}" = --keys ]; then
    for k in $(printf '%s' "${3:-}" | tr ',' ' '); do
      case "$k" in
        enter) k=Enter ;; esc|escape) k=Escape ;; tab) k=Tab ;; shift+tab) k=BTab ;; space) k=Space ;;
        up) k=Up ;; down) k=Down ;; left) k=Left ;; right) k=Right ;; backspace) k=BSpace ;;
        ctrl+?) k="C-${k#ctrl+}" ;; alt+*) k="M-${k#alt+}" ;; f[0-9]|f1[0-2]) k=$(printf '%s' "$k" | tr f F) ;;
        ?) tmux send-keys -t "$id" -l -- "$k" || return 1; continue ;;
      esac
      tmux send-keys -t "$id" "$k" || return 1
    done
    return 0
  fi
  # one line: a newline would press Enter mid-message. The pause lets a TUI take the
  # text as typed before Enter arrives.
  tmux send-keys -t "$id" -l -- "$(printf '%s' "$2" | tr '\n' ' ')" && sleep 0.5 && tmux send-keys -t "$id" Enter
}

tmux_close() {
  [ -n "$(tmux display-message -p -t "$1" '#{@jarvis}' 2>/dev/null)" ] || { echo "$1 is not a window jarvis spawn opened" >&2; return 1; }
  tmux kill-pane -t "$1"
}

