# How Jarvis works

## What it does

| | |
| --- | --- |
| 🧠 **One lead agent** | You talk only to Jarvis. It plans, decides, and briefs, and it does no editing in its own terminal. |
| 🛠️ **Parallel workers** | Each task runs in its own terminal (a Superset terminal, an Ultron session or a tmux window) on the same checkout. Jarvis starts independent tasks at the same time. |
| 🎯 **Model routing** | Each task goes to the cheapest agent and model that can do it well: Claude Code (`claude-opus-5-5` / `sonnet` / `haiku`), Codex, or OpenCode's free models. `fable` is off unless you authorize one brief yourself. |
| 📉 **Usage bands** | Jarvis reads Claude Code's own 5-hour usage numbers and the burn rate. Past 50%, on pace to run out, or with no fresh reading, the session caps drop. Past 75%, new heavy work goes to Codex. `jarvis spawn` enforces both. |
| 🚦 **Caps on Claude sessions** | At most 4 Claude sessions run at once on the machine (every repo, your own sessions included, Jarvis sessions not counted), 3 per project (Jarvis included) and 2 Opus workers. Codex and OpenCode don't count. Extra briefs wait in a queue or go to the free tier, so parallel work doesn't use up your 5-hour window in two hours. |
| ⏱️ **Worker budgets** | Each worker has limits on working time, estimated cost, context, failed tests and attempts. Past one it is asked for a partial handoff, then interrupted. Nothing is closed. |
| ❓ **Grouped questions** | Workers never wait for you. They write their questions into a handoff file, and Jarvis collects them into one numbered message for you. |
| ✅ **Review and commit** | Jarvis checks each handoff against `git status`, reads the diff, and runs your checks. Then it commits only the listed files, one commit per task. |
| 📒 **Memory in your repo** | `handoffs/OPEN.md` lists what's running, what's blocked, and what's next, so `/clear` and new sessions don't lose anything. |
| 💸 **Cost controls that are enforced** | Routine steps are one command each (`jarvis status`, `spawn`, `merge`). A free watcher wakes Jarvis when work lands and clears it after a long idle, instead of paying to reload its whole context. Subagents run on `sonnet`, and a security review runs once per merge. |

The plugin has two skills:

- **`jarvis:setup`** runs once per repo. It asks you a few questions and adds
  the Jarvis workflow files to your project.
- **`jarvis:run`** is the playbook Jarvis follows every session: briefing,
  starting workers, checking on them, reviewing, and merging.

## Talking to Jarvis

Plain language works. Some useful phrases:

| Say | Jarvis will |
| --- | --- |
| "spin off a worker for X" / "delegate this" | Write a brief, pick a model, and start a worker |
| "what's open?" | Summarize running workers, pending questions, and the to-do list |
| "check on the workers" | Read worker terminals and new handoffs in one pass |
| "merge the handoffs" | Review, run checks, commit each finished handoff, and push |
| "I'm running low on usage" | Move to the amber or red band and send new work to cheaper models |
| "answers: 1. yes 2. use Postgres" | Pass your answers to the right workers |

Jarvis only stops to ask you about **product decisions** or **risky
actions**: deleting real data, force-pushing, rewriting history, touching
production, or spending money. It makes everything else, like which model,
how to split the work, and when to start a worker, on its own and tells you
in one line.

## How it works

```
 ┌────────── brief ──────────┐
 │                           ▼
Jarvis                  worker (own terminal, shared checkout)
 ▲  │                        │
 │  │   status: blocked ◀────┤  questions, all at once
 │  └── answers ────────────▶│
 │                           │
 └──── status: done ◀────────┘  handoff: files changed, checks run, notes
        │
        ├─ file list vs git status
        ├─ diff review (+ run checks)
        ├─ Jarvis-only steps (migrations, lockfiles, releases)
        └─ one commit → move handoff to handoffs/merged/ → push → close terminal
```

**1. Brief.** Jarvis writes `handoffs/briefs/YYYY-MM-DD-HHMM-<slug>.md`. It
names the exact files, an existing pattern to copy, what "done" means and the
command that proves it, and which files the worker may and may not touch.
**The more precise the brief, the smaller the model it needs.**

**2. Start.** `handoffs/bin/jarvis spawn <brief>` lints the brief and
checks the usage band and the Claude cap. Then it starts the worker in a
new terminal on the host, with the agent, model, and effort from the brief
header, and records the terminal ID in the brief and in `OPEN.md`.

**3. Ask once.** If a worker has questions, it writes them all into its first
handoff with `status: blocked`. Jarvis collects questions from every blocked
worker into one message for you, then sends each worker its answers with
`jarvis send`.

**4. Build.** The worker does the one phase its brief describes, runs the
checks, and writes a handoff listing the files it changed. A job with
several phases gets one brief per phase. Each new worker starts fresh from
the previous handoff instead of carrying 300k tokens of history.

**5. Wait without spending.** Jarvis doesn't poll or sleep. `jarvis watch`
wakes it when a handoff lands, or when a worker hits a usage limit, sits at a
trust or approval prompt, or shows the same screen for `JARVIS_STALL_MIN`
minutes (15 by default) with no handoff. If Jarvis has sat idle long enough for its
prompt cache to expire, the watcher sends `/clear` first. The fresh session
then reloads from `OPEN.md` for a fraction of what reloading the old
conversation would cost.

**6. Review and merge.** `jarvis merge <handoff> --check` compares the file
list with `git status`. Jarvis then reads the diff and runs the checks if
needed. `jarvis merge` commits **only those files** with a `Co-Authored-By`
line naming the worker, moves the handoff to `handoffs/merged/`, pushes,
closes every worker terminal of that brief, checks each agent exited, and
updates `OPEN.md`, all in one call. Then it stops whatever the worker left
running (see the [FAQ](faq.md) on leftover browsers).

Two rules keep the shared checkout safe:

1. **Only Jarvis uses git.** Workers never commit, stash, reset, check out,
   rebase, or clean.
2. **Workers never wait for you.** Their questions go through Jarvis.

## What gets added to your repo

| Path | Purpose |
| --- | --- |
| `CLAUDE.md` | A few lines every session loads: who is Jarvis and who is a worker, and your checks. Kept short because workers load it too. |
| `AGENTS.md` | The worker rules, read by Claude Code, Codex and OpenCode: git rules, shared-file rules, ask once, one brief then hand off, handoff format |
| `handoffs/JARVIS.md` | Jarvis's rules for this project: what only Jarvis may do, how you verify work, shared files, budget rules. Only Jarvis reads it. |
| `handoffs/jarvis.conf` | The Claude caps, band thresholds, worker budgets, idle limit, whether merge stops leftover processes |
| `handoffs/bin/jarvis` | `start`, `status`, `spawn`, `merge`, `close`, `doctor`, `leftovers`, `lock`, `resources`, `watch`, `band`, `usage`, `sessions`, `budget`, `fable`, plus the idle guard and Fable guard hooks and the statusline tap |
| `handoffs/bin/jarvis-lock.pl` | The lease behind `jarvis lock` (needs `perl`, which macOS ships) |
| `handoffs/bin/cc_usage_audit.py` | Prices your local Claude Code transcripts for `jarvis usage` |
| `handoffs/OPEN.md` | The one pending list: Jarvis's terminal, usage band, running workers, questions for you, to-do |
| `handoffs/TEMPLATE.md` | Handoff format |
| `handoffs/briefs/` | Briefs Jarvis writes, plus `TEMPLATE.md` |
| `handoffs/merged/` | Reviewed handoffs, committed together with the work they describe |
| `handoffs/bin/jev.sh` | Optional Jev helper. Does nothing without a `TYPESAFE_API_KEY`. Its log, `handoffs/.jev/`, is git-ignored. |
| `.claude/settings.json` | Subagents on `sonnet`; security-guidance reviews once per commit instead of after every stop; the idle guard, the Fable guard and the statusline tap; plugins this repo doesn't use switched off; Jarvis's read-only commands (status, read, band …) allowed without a prompt; anything that starts, sends, merges or runs a command still asks. Merged into any settings you already have. |
| `.claude/agents/scout.md` | Read-only explorer subagent pinned to `sonnet`. Answers in under 300 words. |
| `.claude/agents/diff-reviewer.md` | Read-only diff reviewer subagent pinned to `sonnet` |

`handoffs/` is **tracked in git on purpose**. It's your project's record of
what was decided and why.

## Customizing

After setup, **your repo's `handoffs/JARVIS.md` takes priority over the
skill**. Edit it to change what only Jarvis may do, how you verify work,
shared files, and any routing rule. Edit `handoffs/jarvis.conf` to change
the Claude caps, the band thresholds, the worker budgets, the idle limit,
and whether merges push (`JARVIS_PUSH`). Two more keys tune the watcher and
the idle guard: `JARVIS_WATCH_SEC` (how often it looks) and
`JARVIS_GUARD_TOKENS` (how much context the guard ignores). Your checks live in `CLAUDE.md`.

Workers follow `AGENTS.md`. Add project-specific rules there, such as
"never edit `src/theme/tokens.ts`" or "use pnpm, not npm".
