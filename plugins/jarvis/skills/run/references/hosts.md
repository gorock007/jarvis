# Hosts and agents — where workers run, and what runs in them

Jarvis needs two things from wherever it runs: terminals it can start an
agent in, and a way to read and type into them. That's the **host**. What
runs inside each terminal is the **agent**: Claude Code, Codex, OpenCode, or
any other agent CLI. The two are independent, so any agent runs on any host.

You never call a host directly. These commands work the same on every host:

```bash
handoffs/bin/jarvis spawn <brief.md> [--after <handoff>] [--attach <file>]...
handoffs/bin/jarvis read  <terminal> [<lines>]       # bottom of a worker's screen (default 80 lines)
handoffs/bin/jarvis send  <terminal> "<text>"        # types it and presses Enter
handoffs/bin/jarvis send  <terminal> --keys enter    # or esc, tab, shift+tab, up, down, 1, y, ctrl+c, comma-separated
handoffs/bin/jarvis close <terminal>                 # a worker you're giving up on; merge closes finished ones
handoffs/bin/jarvis watch --start                    # the watcher, in a terminal of its own
```

## Which host

`handoffs/bin/jarvis` picks one in this order:

1. `JARVIS_HOST` in `handoffs/jarvis.conf`, if it's set.
2. **superset**, when `$SUPERSET_WORKSPACE_ID` is set (a Superset terminal).
3. **ultron**, when `$ULTRON_SESSION_ID` is set (an Ultron session).
4. **tmux**, when `$TMUX` is set (inside a tmux session).

Otherwise it stops and says so. Jarvis's own terminal id comes from the
host: `$SUPERSET_TERMINAL_ID` on Superset, `$ULTRON_SESSION_ID` (`s_1a2b3c4d`)
on Ultron, `$TMUX_PANE` (`%12`) on tmux.

### Superset

Workers start with `superset agents create --agent <worker>` in this
workspace (shared checkout). Superset knows each agent's launch command, so
any of its presets works as `worker:`. Run `superset agents list --local` to
see them. `--attach` becomes Superset's `--attachment` (an upload). Start
Jarvis in the project's **local** workspace (`--checkout local`). The default
worktree workspace is a different model, `superset:orchestrate`.

### Ultron

Workers start with `ultron agent spawn --role worker` in this checkout's
Ultron project, titled after the brief. Ultron launches each agent itself,
so any agent `ultron agent list` shows works as `worker:`, and it refuses a
model id the agent doesn't accept (`ultron agent models --agent <a>`).
`--attach` becomes Ultron's `--attachment`. The checkout must be an Ultron
project: `ultron project add .` once.

A Claude Jarvis on Ultron is usually a chat session, not a terminal. It
works the same: `jarvis read` shows its conversation, and `jarvis send`
(the watcher included) sends a chat turn. A chat session takes text, not
`--keys`. After a long idle the watcher restarts Jarvis on a fresh context
with `ultron term clear`, which keeps the session id, instead of typing
`/clear`.

Ultron's daemon also has its own event stream, tasks and asks, which its
own Jarvis kit (`ultron-jarvis`) uses. This plugin doesn't: its watcher
polls like on the other hosts.

### tmux

Each worker gets a window in Jarvis's tmux session, named after the brief's
slug. The script sets a `@jarvis` tag on it, and `close` only closes tagged
panes. When the agent exits, its window stays open with the last screen
until merge or close. `tmux attach` and `prefix + w` let the user watch any
worker. `--attach` adds the file's path to the prompt, for the agent to read
itself.

tmux doesn't know how to launch agents, so `jarvis.conf` tells it, one line
per agent: `JARVIS_AGENT_<name>`. The line is a `sh` command reading
`$JARVIS_MODEL`, `$JARVIS_EFFORT` and `$JARVIS_PROMPT`. Built in, with the
flags Superset's presets launch with:

```sh
JARVIS_AGENT_claude='claude --dangerously-skip-permissions ${JARVIS_MODEL:+--model "$JARVIS_MODEL"} ${JARVIS_EFFORT:+--effort "$JARVIS_EFFORT"} "$JARVIS_PROMPT"'
JARVIS_AGENT_codex='codex --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust ${JARVIS_MODEL:+-m "$JARVIS_MODEL"} ${JARVIS_EFFORT:+-c model_reasoning_effort="$JARVIS_EFFORT"} -- "$JARVIS_PROMPT"'
JARVIS_AGENT_opencode='opencode ${JARVIS_MODEL:+-m "$JARVIS_MODEL"} --prompt "$JARVIS_PROMPT"'
```

These skip permission prompts (Claude) and the approval sandbox (Codex), as
Superset's presets do: a worker runs any command as the user, unattended.
That's what lets workers never wait. On a machine where that's too much
trust, such as a shared server, override the lines in `jarvis.conf`, or run
Jarvis in a container. Workers will then stop at approval prompts, and the
watcher wakes Jarvis for each one.

Adding an agent is one line, and then `worker: gemini` works in a brief:

```sh
JARVIS_AGENT_gemini='gemini --approval-mode=auto_edit ${JARVIS_MODEL:+-m "$JARVIS_MODEL"} "$JARVIS_PROMPT"'
```

The launch script for each worker is written to
`handoffs/.jarvis/launch/<slug>.sh`. Read it when a worker won't start.

## Adding a host

A host is seven shell functions, `<name>_self`, `_spawn`, `_run`, `_list`,
`_read`, `_send` and `_close`, in `handoffs/bin/hosts/<name>.sh`, plus an
optional `_clear` if the host can restart an agent on a fresh context. Select it
with `JARVIS_HOST=<name>` in `jarvis.conf`. The contract is spelled out in
the "hosts" comment block of `handoffs/bin/jarvis`, and the superset and
tmux functions next to it are working examples. Nothing else in the
workflow changes.

## Raw host commands, for what the script doesn't cover

Superset (inside a Superset terminal, `$SUPERSET_WORKSPACE_ID` is set):

```bash
superset agents create --workspace "$SUPERSET_WORKSPACE_ID" --agent claude --resume-session <id>   # restore a killed agent
superset agents create … --model __probe__ --prompt x    # the error lists every model id that agent accepts
open "superset://v2-workspace/$SUPERSET_WORKSPACE_ID?terminalId=<id>"   # focus one worker in the desktop app
```

Ultron:

```bash
ultron term list                       # sessions, with role, agent, model and state
ultron term attach <id>                # watch one worker's terminal
ultron agent resume <id>               # relaunch an ended Claude/Codex session on its saved conversation
```

tmux:

```bash
tmux list-windows -F '#{window_index} #{window_name} #{pane_id} #{@jarvis}'   # workers and their ids
tmux select-window -t <pane id>                                              # show one worker
```

## Starting Jarvis (the user does this, or the setup skill prints it)

On Superset:

```bash
superset ws create --project <projectId> --name main --checkout local --local \
  --agent claude --model claude-opus-5-5 --effort high \
  --prompt "You are Jarvis. Use the jarvis:run skill: read handoffs/JARVIS.md and handoffs/OPEN.md, run handoffs/bin/jarvis start, then tell me what's open."
```

On tmux, from the repo root:

```bash
tmux new-session -s jarvis \
  "claude --model claude-opus-5-5 --effort high 'You are Jarvis. Use the jarvis:run skill: read handoffs/JARVIS.md and handoffs/OPEN.md, run handoffs/bin/jarvis start, then tell me what is open.'"
```

On Ultron, from the repo root:

```bash
ultron project add .
ultron agent spawn --role jarvis --agent claude --model claude-opus-5-5 --effort high \
  --permission-mode bypassPermissions --title jarvis \
  --prompt "You are Jarvis. Use the jarvis:run skill: read handoffs/JARVIS.md and handoffs/OPEN.md, run handoffs/bin/jarvis start, then tell me what's open."
```

A chat Jarvis needs `bypassPermissions`: nobody can answer a permission
prompt in chat mode.

On any host, Jarvis then runs `handoffs/bin/jarvis watch --start` once.
