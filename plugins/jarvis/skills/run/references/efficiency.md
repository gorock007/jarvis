# Working cheaply without working worse

Jarvis coordinates the whole fleet and carries the longest context, so it's
the easiest session to overspend in. This file records where usage actually went
when it was measured, and which mechanism now handles each cause.

An earlier version of this file was only advice. The measurement showed the
advice wasn't enough: written guidance in a prompt gets followed some of the
time, and a budget holds only when something enforces it. So each cause
below now has a script, a setting or a hook behind it, and the prose explains
why it's there.

## What was measured

Local Claude Code transcripts from 16–27 Sep 2026, in three repos running
Jarvis, were priced per request at API rates with `cc_usage_audit.py` (the
same tool behind `handoffs/bin/jarvis usage`). The dollar figures are
API-equivalent, used as a proxy for how fast subscription limits go. They
aren't a bill.

- The coordinator cost **$251** (Jarvis $178 plus its subagents $73). The
  workers that did the building cost **$222**. Coordinating ÷ building was
  about 1.13.
- The 5-hour window ran out in under two and a half hours, at about $87, and
  94% of that went to the Jarvis setup. At the peak, 11 Claude sessions ran
  at once. The weekly limit was at 35% on day 4, so it wasn't the problem.
  The burst rate was.
- Per turn, the coordinator averaged 216k of context and $0.20. Half of that
  went on cache writes, meaning new material entering its context. On Fable
  5.1, reading the cache is cheap ($0.25/MTok) and writing to it is not
  ($20/MTok).

## Five causes and what handles each one

### 1. An idle coordinator paid to reload everything

The prompt cache lasts an hour. Jarvis often waited longer than that for
workers, and its next turn wrote its whole 200–400k context to the cache
again, at up to $7 a time on Fable. 18 of 874 coordinator turns did this (2%
of turns), and they cost 31% of everything the coordinator spent. 12 of the
18 came right after an idle gap of more than an hour.

**Now:**

- `jarvis watch` runs in a plain terminal, with no model. It wakes Jarvis
  when a handoff lands, or when a worker is at a usage limit, waiting at a
  prompt, or frozen for `JARVIS_STALL_MIN` minutes. If Jarvis has been idle past `JARVIS_IDLE_MIN`, it
  sends `/clear` first, so the fresh session reloads about 60–80k from
  `OPEN.md` instead of the old 300k.
- The prompt guard (`jarvis hook prompt`, a `UserPromptSubmit` hook) stops
  the user's first message after a long idle when the context is big. It
  says what the reload would cost and suggests `/clear`. Sending the
  message again goes through.
- **Your part:** stop every turn with `OPEN.md` true, and never switch
  `/model` mid-session.

### 2. Checking in cost as much as real work

A turn is priced by the context it carries, not by what it does.
Coordination turns cost 46% of the coordinator's spend: reading worker
terminals, handoffs and `OPEN.md`, running `jev.sh`, spawning, and sending
messages. Their tool results averaged under 1k tokens. What made each turn
expensive was the ~216k of context it carried.

**Now:** routine steps are one command each. `jarvis status` replaces a
terminal read per worker. `jarvis merge` replaces the 6–10 turns of checking
the file list, reading the diff stat, committing, moving the handoff,
pushing, closing the terminal and editing `OPEN.md`. `jarvis spawn`
replaces writing the command, parsing its JSON and editing the brief and
`OPEN.md`. The watcher replaces sleep loops.

**Your part:** spend turns on judgement. If you catch yourself doing the same
three steps again, suggest adding them to the script.

### 3. A hook that ran after every stop

The `security-guidance` plugin's Stop hook ran a full security review on
`claude-opus-4-7` every time any session stopped with changes. With ten
workers sharing one checkout, that meant 116 reviews for $71, up to $23 a
day, reviewing the same files over and over. The cost never appears in
`/usage`'s breakdown, because the hook runs as its own SDK session.

**Now:** the repo's `.claude/settings.json` sets `ENABLE_STOP_REVIEW=0`. The
plugin documents that switch for shared-worktree setups. It keeps the
per-commit review, which fires once per `jarvis merge`. It also sets
`SECURITY_REVIEW_MODEL` and `SG_AGENTIC_MODEL` to Sonnet. The general
lesson: anything that fires per stop, per edit or per session multiplies by
the number of agents.

### 4. Built-in subagents ran on expensive models

The pinned `scout` and `diff-reviewer` agents (Sonnet) were cheap. The
built-in ones ran on whatever model the parent used: Explore on Opus 5 cost
$32, and general-purpose and Plan on Fable cost $23.

**Now:** `CLAUDE_CODE_SUBAGENT_MODEL=sonnet` in the repo's settings puts
every subagent without its own `model:` on Sonnet, the built-in ones
included. The same repo settings can switch off plugins the repo doesn't
use (`enabledPlugins`), which also shortens every session's skill listing.

### 5. Workers never reset, and each started heavy

Briefs used to say "build every phase through to done", so one session
carried the whole job and grew to 350–420k of context. 67% of worker spend
happened past 150k. Every worker also started at about 55k tokens before
reading anything. About 23k of that is controllable: the skill listing
(~9k), deferred tool names (~4k), the orchestrator's `CLAUDE.md` (~3k),
MCP instructions (~2k) and the agent listing (~1k).

**Now:**

- **One brief per phase.** The next phase gets a fresh worker spawned with
  `--after` the previous handoff.
- `CLAUDE.md` is a few lines, because every worker loads it. The Jarvis
  rules moved to `handoffs/JARVIS.md`, which only Jarvis reads.
- Unused plugins are off in the repo's settings.
- **Model choice** roughly doubles or halves the cost per worker turn:
  Fable $0.20, Opus 5 $0.14, Opus 5.5 $0.10, Sonnet 5 $0.04. So use
  `claude-opus-5-5` at `medium` for tightly fenced briefs, and Codex
  `gpt-6-astra` when the shape is genuinely undecided. Fable only when the
  user authorizes that brief (see below).

## The burst: pacing the fleet

Running agents in parallel doesn't make any single task more expensive. It
squeezes a day's spend into one 5-hour window. On the day the window ran out,
spend went from $16 in the first half hour to $25 the next hour and $45 the
hour after, as more workers started.

**Now:**

- `jarvis spawn` refuses a Claude worker past the caps: 4 sessions
  machine-wide, 3 in this checkout (`JARVIS_MAX_CLAUDE`, Jarvis included), 2
  on Opus. Codex and OpenCode don't count toward them. See "October 30
  changes" below for how the machine-wide count works.
- The band comes from the burn rate as well as the percentage. The
  statusline tap saves Claude Code's own 5-hour reading, and the band turns
  amber when that reading is on pace to use the whole window before it
  resets. For example, 40% gone in the first hour is amber.
- Mechanical and tightly fenced work goes to OpenCode first in every band,
  and security work goes to Codex Sol, not only past 75%.

## October 30 changes

An audit of 0.6.1 on one machine found several ways usage could still run
away. The Opus-5.5 default and the cheaper loop above had worked: coordinating ÷ building was already down from
1.02 to 0.35. What remained was Fable reaching workers by routing, by
accident and by escalation, a cap that counted only one repo, a band that
trusted old readings, workers with no limit, and reports that couldn't say
which task cost what. Each now has a mechanism.

| Audit finding | Mechanism |
| --- | --- |
| The routing table sent the top tier to `fable` automatically, and "came back with questions" and "go back up after amber" escalated to it | Fable is default-deny. The top tier is Codex `gpt-6-astra`. A Claude worker runs on `fable` only after the user runs `jarvis fable allow <brief>` in their own terminal: one brief, one spawn, an audit line. The escalations are gone from the docs. |
| Only the literal `fable` counted as Fable, so `claude-fable-5-1`, `Fable` and `fable[1m]` skipped every check, and `--force` skipped them all | One canonical model check, run in spawn and again inside the host launch. Any alias, on any worker agent, is Fable. `--force` never passes it. |
| Inside any session, an Agent-tool `model: "fable"`, a settings allowlist or `/model fable` reached it unguarded | A user-level `availableModels` backstop (`jarvis fable backstop --apply`, asked of the user first), a PreToolUse hook that denies a Fable subagent and a settings edit that lets Fable in, and a spawn preflight that refuses when the environment or settings would route to it |
| The cap counted one repo's `OPEN.md`, so 11 Claude sessions across two repos didn't trip it | 4 machine-wide, 3 per checkout, 2 on Opus, counting every repo's active sessions and the user's own, claimed under a machine-wide lease so two spawns can't take one slot. `jarvis sessions` lists them. |
| The band read a per-repo file that a repo without a statusline never refreshed, treated a stale reading as green, and couldn't see a burst until the window average caught up | One machine-wide reading in `~/.jarvis/usage.json`. No reading or an old one is amber. A burn rate over the last 20 minutes turns the band amber or red early. Amber and red lower the caps (3 / 2 Opus, then 2 / 0 Opus). |
| A worker that kept working ran forever at any cost, and a brief could be respawned without limit | Budgets: working minutes, estimated cost, context, failed tests, attempts. Past one, the worker is asked once for a partial handoff, then interrupted with Escape, never closed. A brief that blew its budget needs `--after` its handoff to respawn. |
| Reports couldn't say which worker or brief cost what, what was abandoned, or how subscription use differed from list price | `jarvis usage` per-worker and per-brief cost, waste signals and context growth, with every dollar labeled |

**Reading `jarvis usage` now.** The first line says the dollars are an
**API-equivalent estimate at list prices, not your subscription usage**: a
way to compare work and configurations, not a bill. The subscription number is
printed separately, from the statusline reading (`subscription usage: 5h 64%
· 7d 52% · reading 65h41m old`), and says how old it is. Under the totals:

- **Workers** and **Most expensive briefs**, the top five by default, each
  with attempts, turns, context growth (`50k→192k`), duration and outcome
  (merged, lost, unmerged). `--all-projects` widens the report to the
  machine.
- **Waste signals**: abandoned sessions, briefs run more than once and the
  extra cost, workers with three or more failed test runs, sessions open for
  more than 8 hours and idle for one, the share of worker cost spent above
  150k of context, and runs that went over budget.

Read the repeated attempts and the above-150k share first: they are the two
that a sharper brief or a smaller phase fixes. If a brief shows two attempts
and a budget stop, the brief was the problem, not the worker.

## Measuring it

```bash
handoffs/bin/jarvis usage --days 7
```

It reports what you spent coordinating versus building (the target is ≤ 0.3,
down from about 1.13 when measured), the cost per merged handoff, the worst
5-hour window, reloads after idle, and Jarvis's cost per turn by model. The
lines added on 30 October are described above. That last one checks the Jarvis model comparison in `eval/jarvis-model/`
(which moved Jarvis from `fable` to `claude-opus-5-5`) against real sessions. Run it before and
after any change to how Jarvis works. If a number doesn't move, the change
didn't do what it was supposed to.

## Habits that still matter

- **A precise brief is a model downgrade.** Spending 2k tokens on a sharper
  brief routinely saves a worker 50k of exploration and drops it a tier. The
  five elements are in `SKILL.md`.
- **Read narrowly and filter at the source:** `rg -n … -C3`, `sed -n`,
  `git diff --stat`, and `pytest -q 2>&1 | tail -30` in the brief.
- **Say it when you choose for cost.** For example: "briefing this tightly so
  it runs on OpenCode". The user can then push back. Never degrade work
  silently.
