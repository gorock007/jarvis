# FAQ and troubleshooting

**`jarvis: no host`**
Jarvis isn't running in a Superset terminal, an Ultron session or inside tmux. Start it in one
of them (see [Start Jarvis](hosts.md#start-jarvis)), or set `JARVIS_HOST` in
`handoffs/jarvis.conf`.

**A worker won't start: "unknown model"**
Your host doesn't accept that model ID. The error lists the IDs it does
accept. Update the table in your `CLAUDE.md`, or run `jarvis:setup` again to
check the IDs.

**Codex or OpenCode rows don't work**
On Superset, check `superset agents list --local`; on Ultron, `ultron agent list`. On tmux, check that
`codex` / `opencode` are on your PATH. Until an agent is available, Jarvis
sends those tasks to Claude models.

**Two Jarvis sessions are running**
`jarvis start` writes the session's terminal ID to `OPEN.md`. If the recorded
Jarvis terminal is still open, it refuses, and Jarvis asks you before taking
over.

**My message was stopped: "Jarvis has been idle … min"**
That's the idle guard. Jarvis's prompt cache has expired, so your message
would have paid to write its whole context again. Type `/clear` and then
"resume" for a cheap fresh session that reloads from `OPEN.md`. Or send the
same message again to go ahead anyway.

**`jarvis spawn` refused at a Claude cap**
That's working as intended. The refusal names the cap (machine-wide, this
project or Opus), its count, and every session holding a slot, yours
included. The brief waits under To-do and is spawned when a slot frees. If
the task is small and fenced, OpenCode or Codex can take it now, and
`model: sonnet` avoids the Opus cap. `jarvis sessions` lists what counts, and
the idle ones it lists are yours to close. Raise `JARVIS_MAX_CLAUDE_GLOBAL`,
`JARVIS_MAX_CLAUDE` or `JARVIS_MAX_OPUS` in `handoffs/jarvis.conf` if you want
more parallel Claude sessions and accept the faster burn. `--force` passes a
cap and writes a `cap-force` line in `handoffs/.jarvis/audit.log`.

**`band: amber unknown band, treated as amber`** (or "stale reading")
The statusline tap hasn't produced a fresh reading. It needs `jq`, and the
`.claude/settings.json` of at least one repo you use Claude Code in must set
the statusline to `jarvis statusline`: the reading is machine-wide, so any
Jarvis repo feeds it. Until then every spawn runs under the amber caps.
Writing a band into `OPEN.md` doesn't change what spawn enforces.

**A worker was asked for a handoff and then interrupted**
It hit a budget (minutes, cost, context, failed tests). Jarvis reads its
terminal, waits for the partial handoff, and respawns the brief sharper or
smaller. If the work was on track, `jarvis budget <terminal> usd=30` raises
the limit and re-arms the ask. The worker's terminal is never closed.

**`jarvis spawn` refused a brief that hit its budget**
The brief needs sharpening or splitting first. Respawn it with `--after` its
latest handoff.

**How do I use Fable for one task?**
See [The Fable rule](fable.md#how-do-i-use-fable-for-one-task).

**A worker is stuck on a permission prompt**
`jarvis watch` checks each worker's screen every minute. It wakes Jarvis
when a worker sits at a trust or approval prompt, or when the screen hasn't
changed for `JARVIS_STALL_MIN` minutes and the worker has no handoff. Jarvis
reads the terminal and answers the prompt or sends a nudge with
`jarvis send`. It treats a prompt for something outside the
brief as a question for you. You can also say "check on the workers".

**A Codex worker sat at "Trust this folder?"**
Codex asks once for each folder path, and every checkout has its own
path. Since 0.3.2, `jarvis spawn` records the checkout as trusted in
`~/.codex/config.toml` (or `$CODEX_HOME`) before a Codex worker starts, as
answering "Yes" would. An existing entry for that path, trusted or not, is
left alone. A repo set up with an older version needs "update Jarvis in this
repo" to get this.

**A browser or server a worker started is still running after it finished**
Closing a worker's terminal doesn't stop what the worker started. Claude
Code runs each Bash command in its own process group, outside the
terminal's. A headless Chrome whose script crashed is adopted by PID 1 and
keeps running; two did, at 100% CPU, for ten days. Since 0.3.4 Jarvis
handles this in three places:

- `jarvis merge` stops what the closed worker left running.
- `jarvis status` lists anything still running from a closed worker.
- A worker checks its own with `jarvis leftovers --mine` before handing off.

How it decides what's whose: Claude Code gives each session a scratch folder,
`/tmp/claude-<uid>/<project>/<session id>/`, and workers keep browser
profiles and logs there. A process counts as a worker's only if its command
line names that worker's own session folder, or it shares a process group
with one when the group has no terminal.

What it never touches:
- processes matched by name
- another worker's processes, or a session that isn't a worker
- the command's own process group
- anything listed under **Processes left running** in the worker's handoff

Each PID is checked again right before it's signalled, so a reused PID is
left alone. Set `JARVIS_REAP=0` in `jarvis.conf` to have merge list and not
stop. `jarvis leftovers <brief> --stop` stops one worker's leftovers by
hand. It refuses while that worker's terminal is open. Codex and OpenCode
workers have no such folder, so they stop their own processes by PID, as
`AGENTS.md` asks.

**Can I use it without Codex?**
Yes. Everything except media and computer-use tasks runs on Claude. Without
Codex, the red band can't move heavy work anywhere, so you'll need to manage
usage more carefully.

**Does it work with other agents?**
Yes. Workers can be any agent CLI that reads `AGENTS.md`: Claude Code, Codex
and OpenCode are built in, and on Superset or Ultron every agent they list works. On tmux,
add one line to `handoffs/jarvis.conf` for another agent (see
[Hosts and agents](hosts.md#hosts-and-agents)). Jarvis itself is written for Claude
Code.

**Should `handoffs/` be in `.gitignore`?**
No. It's tracked on purpose as the project's memory. The one exception is
`handoffs/.jev/`, Jev's local log, which setup adds to `.gitignore`.

**`jev.sh` always says `skipped`**
The reason is in the brackets: `TYPESAFE_API_KEY not set` (export it in the
profile your worker terminals load), `jq not installed`, or
`TypeSafe API unavailable` (a bad key, a network problem, or a reply slower
than 8 seconds). None of these stop Jarvis from working.

## Jarvis vs. `superset:orchestrate`

| | **Jarvis** | **`superset:orchestrate`** |
| --- | --- | --- |
| Shape | One lead agent that runs across sessions | A one-off fan-out |
| Checkout | Shared: workers in terminals of one workspace | An isolated worktree and branch per worker |
| Git | Jarvis commits each handoff to your branch | Results merged as PRs |
| Memory | `handoffs/OPEN.md` + `handoffs/merged/` | Per run |
| Model routing | Per task, based on usage | Your choice |
| Best for | Running a product day to day | "Split this migration into ten slices" |

They work well together. Use Jarvis for daily work, and have it use
`orchestrate` for a big parallel job when needed.
