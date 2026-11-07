# Jarvis

**You talk to one agent. A team of agents does the building.**

Jarvis is an open-source workflow for running one coordinating agent plus a
fleet of workers, in [Superset](https://superset.sh),
[Ultron](https://github.com/subiixu/Ultron), or plain
[tmux](https://github.com/tmux/tmux) anywhere else. It ships as a Claude
Code plugin. The coordinating agent, called Jarvis, plans the work and writes
a short brief for each task. It starts worker agents (Claude Code, Codex,
OpenCode, or any other agent CLI) in separate terminals, reviews what they
hand back, and commits it. You never manage the
workers. You talk to Jarvis, and Jarvis manages them.

```
you ──▶ Jarvis (Claude Code · opus 5.5 · high)
            │  brief ──▶ worker A  claude / opus 5.5     ──▶ handoff ─┐
            │  brief ──▶ worker B  claude / sonnet       ──▶ handoff ─┤─▶ Jarvis reviews, commits, pushes
            │  brief ──▶ worker C  codex  / gpt-6-astra  ──▶ handoff ─┘   (image asset)
            └─ handoffs/OPEN.md — the one list of what's pending
```

A **brief** is a task written for one worker. A **handoff** is what the worker
hands back. The **band** is how much of your 5-hour usage is spent: green, amber or red.

---

## Who it's for

Jarvis is a good fit if you:

- **Use Claude Code**, and maybe Codex or OpenCode too, in Superset, in Ultron, or in a
  terminal with tmux (locally, over SSH, or on a server).
- **Build a product day to day** and want several agents working in parallel
  without keeping track of each terminal yourself.
- **Keep running out of usage**, and want the expensive models saved for hard
  work while routine tasks go to cheaper or free models.
- **Want one clean commit per task** and a record of every decision.
- **Lose track of work between sessions.** Jarvis keeps its state in files in
  your repo.

It's probably not for you if:

- **You can use none of Superset, Ultron or tmux.** Workers need terminals Jarvis
  can start, read and type into.
- **You only need one large parallel job**, like splitting a migration into
  ten slices. Superset's built-in `superset:orchestrate` skill is made for
  that. See the [comparison](docs/faq.md#jarvis-vs-supersetorchestrate).
- **You'd rather work in a single agent session** and review every edit as it
  happens.

## Requirements

| Requirement | Why |
| --- | --- |
| A host for the workers: the [Superset](https://docs.superset.sh/install) desktop app and CLI (Superset host only: Claude Code configured as an agent, built against CLI v1.28), **or** [Ultron](https://github.com/subiixu/Ultron), **or** [tmux](https://github.com/tmux/tmux/wiki/Installing) 3.0+ | Jarvis starts, reads and types into worker terminals through it. See [Hosts and agents](docs/hosts.md#hosts-and-agents). |
| [Claude Code](https://claude.com/claude-code) CLI on your PATH | Jarvis itself and most workers run on it |
| A git repository | Jarvis commits each handoff |
| `jq` (and `python3` for `jarvis usage`) | `handoffs/bin/jarvis` reads JSON from the host and Claude Code |
| *Optional:* Codex, OpenCode | Codex for images, computer-use testing and extra work at high usage; OpenCode's free models for small tasks. Without them those tasks go to Claude models. |
| *Optional:* a [TypeSafe](https://docs.typesafe.ai) API key in `TYPESAFE_API_KEY` | Brief lint and one-line worker polling. See [Optional: Jev](docs/jev.md#optional-jev). |

## Quick start (tmux)

In Claude Code, in your repo, type:

```
/plugin marketplace add gorock007/jarvis
/plugin install jarvis@jarvis
```

Then say:

```
set up Jarvis in this repo
```

If `jarvis:setup` isn't found, restart Claude Code.

Setup checks the host and which agents you have installed. Then it
asks **three** questions in one message, with answers already guessed from
your repo, so you can often just say "yes": the checks workers run before
handing off; how many Claude sessions may run in this checkout at once,
Jarvis included (default 3); and whether to add the statusline tap that lets
Jarvis read your 5-hour usage. The other ten settings are shown once as
defaults you can change. Say "advanced" to be asked all 13. It then writes
`CLAUDE.md`, `AGENTS.md`, `handoffs/` and `.claude/`, merging into any that
exist and showing you the diff first. After that it asks one more yes/no, on a
user-level model restriction (the Fable backstop, which edits
`~/.claude/settings.json`), and offers to commit. Accept the commit, or
`jarvis status` will show setup's files as uncommitted changes.

Then start Jarvis from the repo root. From a plain terminal, run:

```bash
tmux new-session -s jarvis \
  "claude --model claude-opus-5-5 --effort high 'You are Jarvis. Use the jarvis:run skill: read handoffs/JARVIS.md and handoffs/OPEN.md, run handoffs/bin/jarvis start, then tell me what is open.'"
```

If you're already inside tmux, run only the `claude --model … '…'` part in the
current pane (a nested `tmux new-session` refuses), and workers open as windows
of your current session. Either way, `prefix + w` lists the workers. With the
command above, `tmux attach -t jarvis` gets you back in after you detach or
log out. Workers run unattended: Claude workers launch with
`--dangerously-skip-permissions` (Codex with its own bypass flags), and their
brief is the fence. Setup lets Jarvis run its
read-only commands (status, read, band …) without asking; anything that starts,
sends, merges or runs a command still asks. Now talk to it:

> Add a dark mode toggle to settings and fix the flaky login test.

Jarvis writes two briefs, starts two workers on suitable models, and tells you
what it did. When the workers finish, it reviews their work, commits it, and
tells you what to check. If `jarvis spawn` refuses a worker, it's the session
cap: 4 Claude sessions machine-wide, and your own other Claude windows count.
Close some; see the [FAQ entry](docs/faq.md).

On Superset or Ultron, the start command differs: see
[docs/hosts.md](docs/hosts.md).

## Other install options

The quick start already installed the plugin (Option 1: the Claude Code
marketplace), so don't run it twice. The other two:

- **Option 2, Skills CLI:** `npx skills add gorock007/jarvis`, for Claude
  Code, Codex, or any agent that reads `SKILL.md` files. See [docs/install.md](docs/install.md).
- **Option 3, manual:** clone the repo and copy two skill folders. See
  [docs/install.md](docs/install.md).

[docs/install.md](docs/install.md) also covers checking that it installed and
moving from `superset-jarvis`.

## Learn more

- [Install](docs/install.md): all options, checking it, moving from superset-jarvis
- [Hosts](docs/hosts.md): starting Jarvis on Superset, Ultron or tmux; agents and custom hosts
- [How it works](docs/how-it-works.md): what it does, talking to Jarvis, what gets added to your repo, customizing
- [Model routing](docs/routing.md): which agent and model gets which task
- [Usage-aware spending](docs/usage.md): bands, caps and token efficiency
- [Worker lifecycle and heavy checks](docs/lifecycle.md): budgets, `jarvis doctor`, `jarvis lock`
- [The Fable rule](docs/fable.md): why it is off, and how to authorize one brief
- [Optional: Jev](docs/jev.md): brief lint and worker polling
- [FAQ and troubleshooting](docs/faq.md), including Jarvis vs. `superset:orchestrate`
- [Contributing](CONTRIBUTING.md): repository layout, contributing, publishing a version

## Results

From Jarvis's own usage report (`handoffs/bin/jarvis usage`). Dollar figures are
API-equivalent estimates at list prices, not subscription usage.

| Measured | coordinating ÷ building | cost per merged handoff |
| --- | --- | --- |
| First measured | 1.13 | not recorded |
| November 2026 baseline (v0.7.1, 187 merged handoffs) | 0.37 | $7.30 |
| v1.0 | to be measured | to be measured |

The target is ≤ 0.3. The baseline is in
[docs/benchmarks/2026-11-baseline.md](docs/benchmarks/2026-11-baseline.md).

## License

[MIT](LICENSE) © 2026 Gorock
