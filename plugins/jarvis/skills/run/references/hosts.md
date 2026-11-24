# Hosts and agents — where workers run, and what runs in them

Jarvis needs two things from wherever it runs: terminals it can start an
agent in, and a way to read and type into them. That's the **host**. What
runs inside each terminal is the **agent**: Claude Code, Codex, OpenCode, agy, or
any other agent CLI. The two are independent, so any agent runs on any host.

You never call a host directly. These commands work the same on every host:

```bash
handoffs/bin/jarvis spawn <brief.md> [--after <handoff>] [--attach <file>]...
handoffs/bin/jarvis read  <terminal> [<lines>]       # bottom of a worker's screen (default 80 lines)
handoffs/bin/jarvis send  <terminal> "<text>"        # types it and presses Enter; prints whom it reached
handoffs/bin/jarvis send  <terminal> --keys enter    # or esc, tab, shift+tab, up, down, 1, y, ctrl+c, comma-separated
handoffs/bin/jarvis close <terminal>                 # cancel a worker: close, verify it exited, record; merge closes finished ones
handoffs/bin/jarvis watch --start                    # the watcher, in a terminal of its own
```

`jarvis send <terminal> "<text>"` prints `sent to <terminal> · <agent>
worker, <state> · <brief>` (or "Jarvis's own terminal", or "not a worker
jarvis spawned"), so a wrong id shows at once. It exits 1 with the reason on
stderr when the host refuses the text, or when the terminal's screen stays
exactly as it was for `JARVIS_SEND_CHECK_SEC` seconds (default 3, 0 turns
the check off). A busy agent's screen moves anyway, so a pass there only
means the host took the text; `jarvis read` shows whether it's queued.

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
JARVIS_AGENT_agy='agy --dangerously-skip-permissions ${JARVIS_MODEL:+--model "$JARVIS_MODEL"} ${JARVIS_EFFORT:+--effort "$JARVIS_EFFORT"} -i "$JARVIS_PROMPT"'
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

It also gives the worker its turn events (`references/lifecycle.md`, "Worker
events"): `JARVIS_ROLE=worker`, `JARVIS_BRIEF` and `JARVIS_RUN` (the pane id)
for Claude, Codex, OpenCode and agy, a `codex()` function that adds per-run hooks,
an `agy()` function (below), and for OpenCode a plugin (`OPENCODE_CONFIG_CONTENT`, unless you set it) and
an `ended` event after it exits (agy too). The Codex hooks need
`--dangerously-bypass-hook-trust` in the Codex line, as the built-in one has,
and `codex` called by name, not through `exec` or an absolute path. Superset
and Ultron launch Codex and OpenCode themselves, so those workers write no
events there. The same goes for agy on Superset.

### agy (Antigravity CLI)

The `-i` in the line keeps the session open: agy's own `--prompt` is print
mode, one turn and exit. agy reads both `AGENTS.md` and `GEMINI.md` itself.
On tmux the launch script defines an `agy()` function that adds two things
for that run only, and writes nothing to the user's agy config:

- **Hooks.** `--add-dir handoffs/.jarvis/launch/agy`, a folder holding
  `.agents/hooks.json`. agy loads those hooks beside the user's own global
  ones, and both fire. (`--settings` refuses a `hooks` key.) The events:
  the first `PreInvocation` of a turn (`invocationNum` 0) → `working`,
  since `PreInvocation` fires before every model call; `Stop` → `stop`,
  with no detail; `ended` is written by the launch script after agy exits.
  agy has no permission or session-end event.
- **Folder trust.** `--settings '{"trustedWorkspaces":[…]}'` names the
  checkout, so agy doesn't stop at "Do you trust the contents of this
  project?" (it asks even with `--dangerously-skip-permissions`). It lasts
  for the session; the user's settings file isn't changed.

**Superset needs an agent config.** Superset's own `agy` preset runs
`--mode accept-edits`, which auto-denies shell commands in unattended
mode. So spawn refuses `worker: agy` on Superset until you add an agent
config that runs agy with `--dangerously-skip-permissions` (or add the flag
to the preset) and set `JARVIS_AGY_SUPERSET_AGENT=<its id, or agy>` in
`jarvis.conf`. tmux needs none of this.

**Effort.** agy refuses `--effort` beside a model id that already names one.
A model id ending in `-low`, `-medium`, `-high`, `-xhigh` or `-max`
(`gemini-4-neon-high`) carries the effort, and spawn drops the brief's
`effort:`. With a bare id (`gemini-4-neon`) the brief's effort is passed as
`--effort`.

**Quota.** `agy -p /quota` prints the remaining Gemini quota (5-hour and
weekly, with reset times) without a model call. Jarvis doesn't read it; it
is for checking by hand.

**Capacity errors.** agy can get `RESOURCE_EXHAUSTED` (code 429) from
Google's servers even while `/quota` shows quota left. The worker then sits
idle at its prompt, and `jarvis status` reads that screen as crashed. Treat
it as a capacity problem, not a crash: retry later, or route the brief to
another agent.

## Adding a host

A host is seven shell functions, `<name>_self`, `_spawn`, `_run`, `_list`,
`_read`, `_send` and `_close`, in `handoffs/bin/hosts/<name>.sh`. Two more
are optional:

- `_clear`, if the host can restart an agent on a fresh context.
- `_titles`, printing `<id><TAB><title>` per open terminal, so `jarvis
  doctor` can name the terminals it doesn't know.

Select it with `JARVIS_HOST=<name>` in `jarvis.conf`. The contract is spelled out in
the "hosts" comment block of `handoffs/bin/lib/hosts.sh`, and
`lib/host-superset.sh` and `lib/host-tmux.sh` are working examples. Nothing
else in the workflow changes.

`_close` must end what runs in the terminal, not just hide it: closing the
terminal is how merge and `jarvis close` stop a worker's agent. On a pty that
happens by itself (the agent gets SIGHUP). After a close, merge waits for the
terminal to leave `_list` and for the agent to exit, and it reports one that
didn't. Print the reason on stderr when a close fails: it goes on the merge
line. See `lifecycle.md`.

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

### Jarvis on agy

A repo can run Jarvis itself on agy (Gemini 4 Neon, on Google's quota)
instead of Claude Code. Claude stays the default; nothing changes for a repo
that doesn't opt in. To switch, put this in `handoffs/jarvis.conf`:

```bash
JARVIS_LEAD_AGENT=agy
JARVIS_LEAD_MODEL=gemini-4-neon-high   # the default; its effort is in the id
```

Install the jarvis plugin into agy once, so it has the `jarvis:run` skill:
`agy plugin import claude` (it copies the user's Claude Code plugins) or
`agy plugin install <the jarvis plugin's folder>`. Then, from the repo root,
in the terminal Jarvis is to run in (a tmux pane, or a plain Superset
terminal; no Superset agent config is needed):

```bash
handoffs/bin/jarvis lead            # --print shows the launch instead
```

`jarvis lead` launches agy as `JARVIS_AGENT_agy` launches a worker
(`--dangerously-skip-permissions`, `-i`), plus:

- **Its own hooks**: `--add-dir handoffs/.jarvis/launch/lead`, whose
  `.agents/hooks.json` runs `jarvis hook lead working` before every model
  call and `jarvis hook lead stop` when a turn ends. They write
  `handoffs/.jarvis/lead.stamp`, which stands in for the Claude transcript
  the watcher reads for Jarvis's idle time.
- **Session trust** for the checkout, as for an agy worker.
- **The start prompt**: "You are Jarvis, on agy …: use the jarvis:run
  skill, read handoffs/JARVIS.md and OPEN.md, run handoffs/bin/jarvis
  start". agy reads `AGENTS.md`, whose role rule makes every other agent a
  worker except one whose prompt begins "You are Jarvis, on agy". The prompt
  carries the role, not a `GEMINI.md`, because agy workers read `GEMINI.md`
  too, and because the watcher sends the same words after a clear.

`jarvis start` then writes `Jarvis session: <terminal> · agy/<model>` in
`OPEN.md`. It refuses to run in Claude Code while the config says agy
(`--force` claims the terminal anyway), and `jarvis lead` refuses unless the
config says agy.

**What changes for an agy Jarvis:**

- **Caps.** It isn't a Claude session: `JARVIS_MAX_CLAUDE` counts only Claude
  workers in this checkout, so the default 3 allows three.
- **Idle clear.** The watcher reads idle time from `lead.stamp`. That is the
  minutes since its last Stop, and 0 while a turn is running. Past
  `JARVIS_IDLE_MIN` it types agy's own `/clear` (a new conversation, the same
  session; never a host's `clear`), restarts the clock, and sends the start
  prompt with the events.
- **Its own quota.** A 429 (`RESOURCE_EXHAUSTED`) from Google leaves Jarvis
  silent at its prompt. The band can't see this, because the band is the
  Claude fleet's. The watcher reads Jarvis's screen on every tick. On
  `RESOURCE_EXHAUSTED (code 429)`, or a Stop hook whose `error` carries a
  429, it rings the bell and prints a `JARVIS IS LIMITED` line in its own
  terminal, at most once an hour, and logs `jarvis-limit` in `watch.log`.
  `jarvis status` shows the same line until the screen moves on or a clean
  Stop comes. Wake events still go to Jarvis.
- **Merge review.** Neon may be the only merge reviewer when it is Jarvis
  (user ruling, 2026-11-25). Workers on agy are still never the only
  reviewer.

**What an agy Jarvis loses** (each degrades quietly, with no errors):

- the prompt guard (Claude's `UserPromptSubmit`) that stops the first message
  after a long idle;
- the statusline: the band still comes from the machine-wide reading, which
  only Claude sessions write. With no Claude session running it goes stale,
  and the band reads amber;
- `jarvis usage`'s coordinating cost. It prices Claude transcripts only, and
  says that Jarvis runs on agy;
- `jarvis doctor`'s session checks for Jarvis. Its process isn't a Claude
  one; doctor still names its terminal;
- the PreToolUse Fable guard and Claude's subagents (`.claude/agents/`). agy
  has its own tools, and the run skill's Claude-only tools have no agy
  equivalent;
- `setup/SKILL.md` is past agy's 24 000-byte skill limit, so its tail is
  cut there. Run setup in Claude Code. `run/SKILL.md` fits.

A real agy Jarvis has not yet run a full session. Try it in a throwaway repo
first.
