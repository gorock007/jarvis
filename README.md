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

---

## Contents

- [Who it's for](#whos-it-for)
- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Talking to Jarvis](#talking-to-jarvis)
- [How it works](#how-it-works)
- [What gets added to your repo](#what-gets-added-to-your-repo)
- [Hosts and agents](#hosts-and-agents)
- [Model routing](#model-routing)
- [Usage-aware spending](#usage-aware-spending)
- [Worker lifecycle and heavy checks](#worker-lifecycle-and-heavy-checks)
- [Token efficiency](#token-efficiency)
- [Optional: Jev](#optional-jev)
- [Customizing](#customizing)
- [Jarvis vs. `superset:orchestrate`](#jarvis-vs-supersetorchestrate)
- [FAQ and troubleshooting](#faq-and-troubleshooting)
- [Repository layout](#repository-layout)
- [Contributing](#contributing)
- [License](#license)

---

## Who it's for

Jarvis is a good fit if you:

- **Use Claude Code**, and maybe Codex or OpenCode too, in Superset, in Ultron, or in a
  terminal with tmux (locally, over SSH, or on a server).
- **Build a product day to day** and want several agents working in parallel
  without keeping track of each terminal yourself.
- **Keep running out of usage**, and want the expensive models saved for hard
  work while routine tasks go to cheaper or free models.
- **Want one clean commit per task** and a record of every decision, instead
  of a dozen agents all writing to git at once.
- **Lose track of work between sessions.** Jarvis keeps its state in files in
  your repo, so you can pick up tomorrow where you left off.

It's probably not for you if:

- **You can use none of Superset, Ultron or tmux.** Workers need terminals Jarvis
  can start, read and type into. A host of your own is seven shell
  functions (see [Hosts and agents](#hosts-and-agents)).
- **You only need one large parallel job**, like splitting a migration into
  ten slices, each on its own branch. Superset's built-in
  `superset:orchestrate` skill is made for that. See the
  [comparison](#jarvis-vs-supersetorchestrate).
- **You'd rather work in a single agent session** and review every edit as it
  happens.

## What it does

| | |
| --- | --- |
| 🧠 **One lead agent** | You talk only to Jarvis. It plans, decides, and briefs, and it does no editing in its own terminal. |
| 🛠️ **Parallel workers** | Each task runs in its own terminal (a Superset terminal, an Ultron session or a tmux window) on the same checkout. Jarvis starts independent tasks at the same time. |
| 🎯 **Model routing** | Each task goes to the cheapest agent and model that can do it well: Claude Code (`claude-opus-5-5` / `sonnet` / `haiku`), Codex, or OpenCode's free models. `fable` is off unless you authorize one brief yourself. |
| 📉 **Usage bands** | Jarvis reads Claude Code's own 5-hour usage numbers and the burn rate. Past 50%, on pace to run out, or with no fresh reading, the session caps drop. Past 75%, new heavy work goes to Codex. `jarvis spawn` enforces both. |
| 🚦 **Caps on Claude sessions** | At most 4 Claude sessions run at once on the machine (every repo, your own sessions included), 3 per project and 2 on Opus. Codex and OpenCode don't count. Extra briefs wait in a queue or go to the free tier, so parallel work doesn't use up your 5-hour window in two hours. |
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

## Requirements

| Requirement | Why |
| --- | --- |
| A host for the workers: the [Superset](https://docs.superset.sh/install) desktop app and CLI (built against CLI v1.28), **or** [Ultron](https://github.com/subiixu/Ultron), **or** [tmux](https://github.com/tmux/tmux/wiki/Installing) 3.0+ | Jarvis starts, reads and types into worker terminals through it. See [Hosts and agents](#hosts-and-agents). |
| [Claude Code](https://claude.com/claude-code) (on Superset, configured as an agent) | Jarvis itself and most workers run on it |
| A git repository | Jarvis commits each handoff |
| *Optional:* Codex | Images and other media, computer-use testing, and extra work when your Claude usage is high |
| *Optional:* OpenCode | Free models for small, tightly scoped tasks |
| `jq` (and `python3` for `jarvis usage`) | `handoffs/bin/jarvis` reads JSON from the host and Claude Code. Without `jq`, `jarvis spawn` refuses and the band reads amber. |
| *Optional:* a [TypeSafe](https://docs.typesafe.ai) API key in `TYPESAFE_API_KEY` | Brief lint and one-line worker polling through Jev. See [Optional: Jev](#optional-jev). |

Without Codex or OpenCode, Jarvis still works. Those tasks go to Claude
models instead.

## Installation

Pick **one** of these.

### Option 1: Claude Code plugin marketplace (recommended)

Inside Claude Code:

```
/plugin marketplace add gorock007/jarvis
/plugin install jarvis@jarvis
```

Updates arrive through `/plugin`, and the skills are named `jarvis:setup`
and `jarvis:run`.

### Option 2: Skills CLI

For Claude Code, Codex, or any agent that reads `SKILL.md` files:

```bash
npx skills add gorock007/jarvis
```

It finds two skills, `setup` and `run`. Install both.

### Option 3: Manual

```bash
git clone https://github.com/gorock007/jarvis.git
mkdir -p ~/.claude/skills
cp -R jarvis/plugins/jarvis/skills/setup ~/.claude/skills/jarvis-setup
cp -R jarvis/plugins/jarvis/skills/run   ~/.claude/skills/jarvis-run
```

### Check that it installed

Open a new Claude Code session and ask *"what skills do you have?"* You should
see `setup` and `run` from the `jarvis` plugin.

### Moving from superset-jarvis

The repo was renamed from `gorock007/superset-jarvis` in 0.4.1, and the
plugin is now `jarvis@jarvis`. An install under the old name keeps updating
through GitHub's redirect for now, but move it over once:

```
claude plugin marketplace remove superset-jarvis
claude plugin marketplace add gorock007/jarvis
claude plugin install jarvis@jarvis
```

Repos you set up with Jarvis need no changes.

## Quick start

### 1. Set up Jarvis in your repo (once)

Open your project in Superset, in Ultron, or in a terminal inside tmux. In any Claude
Code session, say:

> **set up Jarvis in this repo**

`jarvis:setup` checks the host (Superset, Ultron or tmux) and which agents you have
installed. Then it asks all its questions in one message, with answers
already guessed from your repo, so you can often just say "yes":

1. Project name
2. Where the app lives (repo root or a subfolder)
3. Checks workers must run before handing off, such as `bun run typecheck && bun test` or `pytest && ruff check .`
4. What only Jarvis may do besides git, such as applying migrations, deploying, or editing lockfiles
5. How you check finished work: a phone build, a browser URL, CLI commands, or tests only
6. Shared files workers should change as little as possible
7. How many Claude sessions may run at once, Jarvis included (default 3)
8. Whether you're comfortable sending small tasks to OpenCode's free models
9. Usage band thresholds (default 50% and 75%)
10. Which of your globally enabled plugins to switch off in this repo
11. Whether to add the statusline tap that lets Jarvis read your 5-hour usage
12. Whether to install Jev

It then writes `CLAUDE.md`, `AGENTS.md`, `handoffs/` and `.claude/`. If any
of them already exist, it **merges** the new sections into them and shows
you the diff first. Running it again in a repo set up with an older version
upgrades that repo. On Superset it also checks which model
IDs the host accepts and replaces any it doesn't recognize.

### 2. Start Jarvis

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

**Anywhere else, with tmux**, from the repo root:

```bash
tmux new-session -s jarvis \
  "claude --model claude-opus-5-5 --effort high 'You are Jarvis. Use the jarvis:run skill: read handoffs/JARVIS.md and handoffs/OPEN.md, run handoffs/bin/jarvis start, then tell me what is open.'"
```

Workers open as windows in that session. `prefix + w` lists them, and
`tmux attach -t jarvis` gets you back in after you detach or log out.

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

### 3. Talk to it

> Add a dark mode toggle to settings and fix the flaky login test.

Jarvis writes two briefs, starts two workers on suitable models, and tells you
what it did. When the workers finish, it reviews their work, commits it, and
tells you what to check.

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
running (see the FAQ on leftover browsers).

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
| `.claude/settings.json` | Subagents on `sonnet`; security-guidance reviews once per commit instead of after every stop; the idle guard, the Fable guard and the statusline tap; plugins this repo doesn't use switched off. Merged into any settings you already have. |
| `.claude/agents/scout.md` | Read-only explorer subagent pinned to `sonnet`. Answers in under 300 words. |
| `.claude/agents/diff-reviewer.md` | Read-only diff reviewer subagent pinned to `sonnet` |

`handoffs/` is **tracked in git on purpose**. It's your project's record of
what was decided and why.

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

Details: [`hosts.md`](plugins/jarvis/skills/run/references/hosts.md).

## Model routing

The tier depends on one question: **can the brief say what "done" looks like
and how to verify it?** If yes, Claude Opus 5.5 at `high` can handle it, and that covers
most work. If no (the approach isn't decided, the spec is unclear, the cause
is unknown, or a wrong call would be expensive), it goes to Codex
`gpt-6-astra`. How *undecided* a task is matters more than how big it is.

| Tier | Claude Code | Codex | OpenCode (free) |
| --- | --- | --- | --- |
| Top: worker must decide the approach | `fable` · high, **only if you authorize that brief** | `gpt-6-astra` · high | never |
| Workhorse: substantial but specified | `claude-opus-5-5` · high | `gpt-5.6-sol` · high | never |
| Light: scoped tweaks, docs, audits | `sonnet` · medium | `gpt-5.6-terra` · medium | if tightly scoped |
| Trivial: renames, formatting | `haiku` · low | `gpt-5.6-luna` · low | **first choice** |

These always go to Codex: **any image or media asset** and **app testing that
needs computer use**. Security work goes to `gpt-5.6-sol` when possible.

**Workers default to Claude Opus 5.5.** It is pinned as `claude-opus-5-5`
rather than left to the `opus` alias, so a worker never silently lands on
Opus 5. Opus 5.5 costs less per token than Opus 5 ($4 / $20 per million) and
finishes agentic coding work with fewer tokens, so it is the right home for
well-specified briefs. It runs at `medium` when a brief is tightly fenced.
Its thinking is always on, so Jarvis always passes `--effort`.

**Jarvis itself runs on Opus 5.5 at `high` too.** It used to run on Fable
5.1. [`eval/jarvis-model/`](eval/jarvis-model/) tested `fable`/`high`,
`claude-opus-5-5`/`high` and `claude-opus-5-5`/`xhigh` on 40 routing briefs
and 8 handoff reviews with planted defects, three times each. All three
picked the right tier for 95% of briefs and caught every planted defect.
Fable cost 2.8× as much per call, and `xhigh` added only a false alarm.
`jarvis usage` shows Jarvis's real cost per turn by model.

**Fable is never used unless you authorize one brief, at your own terminal.**
Jarvis doesn't pick it, a band change doesn't escalate to it, and a brief
that came back with questions doesn't move up to it. Work that would have
gone there goes to `gpt-6-astra`. To use it for one task, see
the FAQ entry [How do I use Fable for one task?](#faq-and-troubleshooting). Two
guards back this up: `jarvis spawn` checks every spelling of the model name
(`--force` doesn't pass it), and an `availableModels` list in your
`~/.claude/settings.json` makes Claude Code itself substitute Opus for Fable,
including for subagents. Setup asks before writing that list, because it
applies in every repo and also stops your own `/model fable`.

**OpenCode is the free tier.** Jarvis considers it before `sonnet` or `haiku`,
because every small task it handles saves your Claude and Codex quota. Jarvis
tells OpenCode exactly which files to change and which pattern to follow, and
never gives it top- or workhorse-tier work. Free models are run by third
parties, so it never sees real credentials or user data. If OpenCode gets a
task wrong, Jarvis gives it one correction, then moves the task to `sonnet`.

Three caps apply to Claude sessions: **4 machine-wide** (every repo and your
own sessions included), **3 in this project** (Jarvis included) and **2 on
Opus**. Past any of them, `jarvis spawn` refuses and names who holds each
slot (`jarvis sessions` shows them any time). The brief then waits under
To-do in `OPEN.md`, or goes to OpenCode or Codex if it fits them. Idle
sessions don't count, and Jarvis never stops a session it didn't start.

> Model IDs change over time. `jarvis:setup` checks which IDs your Superset
> host accepts and updates the table. The full reasoning is in
> [`model-routing.md`](plugins/jarvis/skills/run/references/model-routing.md).

## Usage-aware spending

Jarvis and every Claude session draw from the same usage limit, so Jarvis
tracks a **band** and records it in `OPEN.md`. The band sets how many Claude
sessions may run:

| Band | Trigger | Caps (machine-wide · Opus) | What changes |
| --- | --- | --- | --- |
| 🟢 Green | under 50%, and not on pace to run out | 4 · 2 | The routing table as written |
| 🟡 Amber | 50%+, burning fast (on pace to use the whole 5-hour window before it resets, or 15+ points in 20 minutes), a 7-day reading at 80%+, or no reading or a stale one | 3 · 2 | New Claude work waits sooner. Running workers are untouched. |
| 🔴 Red | 75%+, about to hit 100% within 30 minutes, a 7-day reading at 95%+, a usage-limit message, or a failed start | 2 · 0 | New top- and workhorse-tier briefs go to Codex. Claude is kept for Jarvis and workers already running. |

The numbers come from Claude Code itself. The repo's statusline is a small
tap that saves the 5-hour and 7-day readings machine-wide, in
`~/.jarvis/usage.json`, and then runs your own statusline unchanged. One
reading serves every repo, because the limit belongs to the account. **The
band fails closed**: with no reading, or one older than 30 minutes whose
window hasn't reset, it reads amber, so a repo with no statusline tap, or a
machine nobody has used for a day, gets the lower caps instead of free
rein. `jarvis status` turns the reading into a band, and `jarvis spawn`
enforces it. Running agents in parallel doesn't make any single task more
expensive, but it squeezes a day's spend into one window. That's why the
band watches the burn rate as well as the total. Jarvis doesn't change its
own model mid-session. It sends work elsewhere, so the remaining budget goes
to coordination.

**`jarvis usage` says what it cost, with labels.** It prices your local
transcripts at API list prices and says so: an **API-equivalent estimate, not
your subscription usage**. The real subscription numbers (5-hour and 7-day)
are printed on their own line, with the age of the reading. It shows the top
workers and briefs by cost, with attempts, context growth and outcome, and
waste signals: abandoned runs, briefs run more than once, workers with many
failed test runs, sessions left open for hours, and the share of worker cost
spent above 150k of context. `--all-projects` covers every repo on the
machine.

## Worker lifecycle and heavy checks

**Workers end when they're done.** Every spawn leaves a run record in
`handoffs/.jarvis/runs/`. `jarvis merge` closes every worker of the brief,
then checks that the terminal is gone and the agent exited. A survivor is
stopped, with its identity checked again first. Every failure is printed on
the merge line. `jarvis close` cancels a worker the same way.

**`jarvis doctor` explains what's still alive**: every agent process and
terminal in this checkout, with the run and brief that own it. `--apply`
ends only the finished and lost ones Jarvis recorded, and logs each action
in `handoffs/.jarvis/audit.log`. Unknown terminals and other sessions are
never touched. `jarvis status` ends with a `doctor:` line when there's
something to act on.

**Workers have budgets.** Each running Claude worker gets 90 working
minutes (time its screen changed), about $15 of estimated cost, 300k of
context, 6 failed test runs and 2 attempts per brief. Codex and OpenCode
workers get minutes and attempts. Past one, `jarvis watch` types a single
message into the worker's terminal asking for a partial handoff. If it keeps
working with none after 10 minutes, the watcher presses Escape and wakes
Jarvis. **Nothing is ever closed or signalled**: a worker's edits are
uncommitted in the shared checkout. A brief can set its own limits with a
`budget: min=120 usd=25 ctx=350k tests=8 attempts=3` header line, and
`jarvis budget <terminal> usd=30` raises one running worker's limit. A brief
that hit its budget, or has used its attempts, is refused on respawn until
Jarvis sharpens or splits it and spawns with `--after` its handoff
(`--force` passes this and is logged). `jarvis status` shows each worker's
use on one line.

**Heavy suites take turns.** Workers run targeted checks (unit tests, lint,
typecheck) freely. Suites your repo marks heavy (Docker, e2e, the full
suite) run only under a lease shared by every process on the machine. Wrap
them where they're declared, and every caller queues: any agent, you, CI.

```json
"test:docker": "handoffs/bin/jarvis lock docker -- vitest run --project docker"
```

Setup proposes these wrappers and edits your scripts only on your yes.
`--reuse` reports a pass on the identical tree instead of running it again.
Jarvis runs the heavy suites once per integration, before or after merging,
and records the result.

| Command | What it does |
| --- | --- |
| `jarvis close <terminal>` | Cancel a worker: close, verify it exited, record |
| `jarvis doctor [--apply \| --quiet]` | What's alive in this checkout and why; `--apply` ends the finished and lost ones |
| `jarvis budget <terminal> [usd=N …]` | A worker's budget use; with values, raise its limits (logged) |
| `jarvis sessions` | The Claude sessions counting toward the caps, machine-wide |
| `jarvis lock <class> [--wait <sec>] [--reuse] -- <command…>` | Run a command only while holding its class's lease; waiters queue in order |
| `jarvis resources [--json]` | Who holds each lease, who's waiting, stored passes |

Details, settings and limits:
[`lifecycle.md`](plugins/jarvis/skills/run/references/lifecycle.md).

## Token efficiency

Version 0.3 came out of measuring where Jarvis's usage actually went, over
12 days of real transcripts. The coordinator cost more than the workers it
coordinated ($251 against $222 at API prices). Most of that went on waiting
and checking, not on deciding. Each measured cause now has a mechanism
behind it, not just advice:

| Measured cause | Mechanism |
| --- | --- |
| 18 turns (2%) that reloaded an idle coordinator's whole context cost 31% of its spend | `jarvis watch` clears Jarvis after a long idle before waking it, and a prompt guard stops your first message after one |
| Routine check-ins were 46% of coordinator spend, at ~$0.25 each | `jarvis status`, `spawn` and `merge` turn many turns into one call |
| A security-review hook ran after every stop of every worker: 116 runs, $71 | Per-stop review off, one review per merge commit, on Sonnet |
| Built-in subagents inherited Opus and Fable: $59 | `CLAUDE_CODE_SUBAGENT_MODEL=sonnet` in the repo's settings |
| Workers carried whole jobs to 350–420k context | One brief per phase, a shorter `CLAUDE.md`, unused plugins off |
| 11 sessions at once used up the 5-hour window in 2.5 hours | A cap on Claude sessions, and a band that watches the burn rate |

`handoffs/bin/jarvis usage` reports the numbers that show whether this
worked: coordinating ÷ building (about 1.13 when measured, target ≤ 0.3),
cost per merged handoff, and the worst 5-hour window. Details are in
[`efficiency.md`](plugins/jarvis/skills/run/references/efficiency.md).

## Optional: Jev

[Jev](https://docs.typesafe.ai) is TypeSafe's fast decision model. It doesn't
write text. You send it some state and yes/no, pick-one, or rating questions,
and it returns probabilities in well under a second for a fraction of a cent.
Jarvis can use it for two small, frequent judgements, through
`handoffs/bin/jev.sh`:

- **Brief lint.** Before a worker starts, `jev.sh brief <file>` checks the
  brief for the five things that let a smaller model do the job (exact files,
  a pattern to copy, done plus the command that proves it, a scope fence, the
  prior handoff) and names what's missing.
- **Worker polling.** `jev.sh triage <ids>` reads the worker terminals outside
  Jarvis's context and returns one line per worker, for example
  `a1b2 working (0.94)`. It shows the screen only for a worker that is
  blocked, asking, limited, finished, stuck, or unclear. Usage-limit messages
  are caught by a text rule, not by the model.

It also runs an experiment: each brief gets a **shadow** model-tier verdict
from Jev, logged next to the model Jarvis chose and how the brief turned out.
Jev's verdict is never shown to Jarvis and changes nothing. After about 30
briefs, `jev.sh report` tells you whether the classifier has earned an
advisory role. Nobody has published accuracy numbers for routing coding work
this way, so it has to earn it on your own briefs first.

**Jev advises and never decides.** Without `jq`, without a key, or when the
API fails or takes longer than 8 seconds, the script prints
`jev: skipped (…)`, exits cleanly, and Jarvis works exactly as it does without
it.

**Privacy.** Brief text (without its header) and the bottom 60 lines of
polled worker terminals are sent to TypeSafe. Secret-shaped strings are masked
first, but masking can miss things. If terminal contents must not leave your
machine, don't set `TYPESAFE_API_KEY` in that repo. Run any command with
`--dry-run` to see exactly what would be sent.

To turn it on, set `TYPESAFE_API_KEY` in the shell profile your worker
terminals load. Details are in
[`jev.md`](plugins/jarvis/skills/run/references/jev.md). The labelled fixtures
and the pass/fail gates used to test the questions are in [`eval/`](eval/).
`eval/selftest.sh` checks the fail-open paths and the masking with no key and no network.

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

## FAQ and troubleshooting

**`jarvis: no host`**
Jarvis isn't running in a Superset terminal, an Ultron session or inside tmux. Start it in one
of them (see [Start Jarvis](#2-start-jarvis)), or set `JARVIS_HOST` in
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

Fable is off by default, for Jarvis's own choices and for every worker. To
run one brief on it, you authorize that brief yourself, in your own terminal
(not through Jarvis, and not inside an agent session):

```bash
handoffs/bin/jarvis fable allow handoffs/briefs/<file>.md
```

It shows the brief's title and checkout and asks you to type its slug. Then
set `model: fable` in the brief and ask Jarvis to spawn it. The authorization
is single-use, tied to that brief's text, and expires after
`JARVIS_FABLE_TTL_MIN` minutes (120). It also can't pass the red band. On
Superset you first need an agent config that allows Fable, named in
`JARVIS_FABLE_SUPERSET_AGENT` (the steps are in `jarvis.conf`). `jarvis fable
list` shows what's pending and what was used, and `jarvis fable revoke
<brief>` cancels one. Every use is logged in `~/.jarvis/fable/audit.log`.

`jarvis fable backstop` checks whether your user-level `availableModels`
keeps Fable out of every other session. `--apply` writes it and keeps a
backup. This stops your own `/model fable` too, so lift it by restoring the
backup or editing the list.

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
[Hosts and agents](#hosts-and-agents)). Jarvis itself is written for Claude
Code.

**Should `handoffs/` be in `.gitignore`?**
No. It's tracked on purpose as the project's memory. The one exception is
`handoffs/.jev/`, Jev's local log, which setup adds to `.gitignore`.

**`jev.sh` always says `skipped`**
The reason is in the brackets: `TYPESAFE_API_KEY not set` (export it in the
profile your worker terminals load), `jq not installed`, or
`TypeSafe API unavailable` (a bad key, a network problem, or a reply slower
than 8 seconds). None of these stop Jarvis from working.

## Repository layout

```
.agent-marketplace.json              Superset marketplace manifest
.claude-plugin/marketplace.json      Claude Code marketplace manifest
plugins/jarvis/
  plugin.json                        Superset plugin manifest
  .claude-plugin/plugin.json         Claude Code plugin manifest
  skills/
    setup/
      SKILL.md                       jarvis:setup: interview + install
      templates/                     CLAUDE.md, AGENTS.md, handoffs/ (JARVIS.md, jarvis.conf, bin/jarvis, bin/jarvis-lock.pl, bin/jev.sh), .claude/
    run/
      SKILL.md                       jarvis:run: the operating playbook
      references/
        hosts.md                     Superset, Ultron and tmux hosts, agent launch lines, adding either
        model-routing.md             routing table and reasoning
        handoffs.md                  brief and handoff formats, review steps
        efficiency.md                where tokens go and how to spend fewer
        lifecycle.md                 run registry, verified close, jarvis doctor, jarvis lock
        jev.md                       the optional Jev helper and the shadow-routing rule
eval/                                labelled briefs and terminal tails; run.sh (live) tests jev.sh, selftest.sh (offline) tests jev.sh and bin/jarvis
eval/jarvis-model/                   compares Jarvis on fable/high vs claude-opus-5-5/high vs /xhigh
```

## Contributing

Issues and pull requests are welcome, especially:

- updates when Superset CLI flags or model IDs change
- routing and efficiency improvements based on real usage
- clearer templates and setup questions

When editing skills, keep the templates' style: short rules in plain words,
each with its reason. Every line of a generated `CLAUDE.md` is read in every
Jarvis session, so leave out generic advice.

### Publishing a new version (maintainers)

Run `eval/selftest.sh` first. It's offline and free, and it covers
`bin/jarvis` and `jev.sh`. Then commit the change on its own and publish in
a second commit:

```bash
v=0.6.1   # the new version
sed -i '' -E "s/\"version\": \"[0-9.]+\"/\"version\": \"$v\"/" \
  .agent-marketplace.json plugins/jarvis/plugin.json plugins/jarvis/.claude-plugin/plugin.json
git commit -am "publish jarvis@$v"
git tag "jarvis@$v" && git push origin main "jarvis@$v"
```

A release is a git tag, and installs pin to it. Keep the `version` in those
three files the same. (Superset CLI 1.38 dropped `superset plugins`, which
used to do the bump as `superset plugins publish jarvis --bump patch`.)

Existing installs don't update themselves. Claude Code users run
`claude plugin marketplace update jarvis` and
`claude plugin update jarvis@jarvis`, then restart. Repos already
set up keep their copied `handoffs/` files until someone says "update Jarvis
in this repo".

## License

[MIT](LICENSE) © 2026 Gorock
