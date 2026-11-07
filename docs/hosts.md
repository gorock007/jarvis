# Hosts and starting Jarvis

## Start Jarvis

**On Superset**, from a Superset terminal (find your project ID with
`superset projects list`):

```bash
superset ws create --project <projectId> --name main --checkout local --local \
  --agent claude --model claude-opus-5-5 --effort high \
  --prompt "You are Jarvis. Use the jarvis:run skill: read handoffs/JARVIS.md and handoffs/OPEN.md, run handoffs/bin/jarvis start, then tell me what's open."
```

Or, in the Superset desktop app, open the project's shared-checkout
workspace, launch Claude Code with model **claude-opus-5-5** and effort **high**, and
send the same first message.

> `--checkout local` matters. Jarvis and its workers share one working copy,
> and only Jarvis uses git.

**Anywhere else, with tmux**, from the repo root. Run this from a plain
terminal:

```bash
tmux new-session -s jarvis \
  "claude --model claude-opus-5-5 --effort high 'You are Jarvis. Use the jarvis:run skill: read handoffs/JARVIS.md and handoffs/OPEN.md, run handoffs/bin/jarvis start, then tell me what is open.'"
```

If you're already inside tmux, `tmux new-session` refuses to nest. Run only the
`claude --model … '…'` part in the current pane instead, and workers open as
windows of your current session.

Workers open as windows in Jarvis's tmux session. `prefix + w` lists them, and
`tmux attach -t jarvis` gets you back in after you detach or log out (when you
started the session with the command above).

**On Ultron**, from the repo root:

```bash
ultron project add .
ultron agent spawn --role jarvis --agent claude --model claude-opus-5-5 --effort high \
  --permission-mode bypassPermissions --title jarvis \
  --prompt "You are Jarvis. Use the jarvis:run skill: read handoffs/JARVIS.md and handoffs/OPEN.md, run handoffs/bin/jarvis start, then tell me what's open."
```

Then talk to it in the Ultron app. Workers show up there as sessions.

On any host Jarvis then starts the watcher (`handoffs/bin/jarvis watch
--start`). It's a plain loop with no model, so it costs no tokens. It wakes
Jarvis when a handoff lands, or when a worker hits a usage limit, sits at a
prompt, or freezes.

## Hosts and agents

Jarvis keeps two things apart: the **host**, which runs worker terminals,
and the **agent**, which is the CLI inside each one.

| Host | Picked when | Workers run as |
| --- | --- | --- |
| Superset | `$SUPERSET_WORKSPACE_ID` is set (a Superset terminal) | Superset terminals, via `superset agents create` |
| Ultron | `$ULTRON_SESSION_ID` is set (an Ultron session) | Ultron sessions, via `ultron agent spawn`; a chat Jarvis is read and woken through `ultron chat` |
| tmux | `$TMUX` is set (inside tmux) | windows in Jarvis's tmux session, tagged so Jarvis only closes its own |
| your own | `JARVIS_HOST=<name>` in `handoffs/jarvis.conf` | whatever `handoffs/bin/hosts/<name>.sh` does: seven functions (`self`, `spawn`, `run`, `list`, `read`, `send`, `close`) |

Every command works the same on each host: `jarvis spawn | read | send |
close | watch --start`. The skills only use those, never a host's own CLI.

Agents: Superset and Ultron launch their own agents, so any agent they list
works as `worker:` in a brief. On tmux, `handoffs/jarvis.conf` holds one launch line
per agent. `claude`, `codex` and `opencode` are built in with the same flags
Superset uses. Another agent is one more line:

```sh
JARVIS_AGENT_gemini='gemini --approval-mode=auto_edit ${JARVIS_MODEL:+-m "$JARVIS_MODEL"} "$JARVIS_PROMPT"'
```

The details are in the plugin's `run` skill:
[`hosts.md` on GitHub](https://github.com/gorock007/jarvis/blob/main/plugins/jarvis/skills/run/references/hosts.md).
