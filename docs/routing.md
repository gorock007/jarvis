# Model routing

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
5.1. [`eval/jarvis-model/`](../eval/jarvis-model/) tested `fable`/`high`,
`claude-opus-5-5`/`high` and `claude-opus-5-5`/`xhigh` on 40 routing briefs
and 8 handoff reviews with planted defects, three times each. All three
picked the right tier for 95% of briefs and caught every planted defect.
Fable cost 2.8× as much per call, and `xhigh` added only a false alarm.
`jarvis usage` shows Jarvis's real cost per turn by model.

**Fable is never used unless you authorize one brief, at your own terminal.** The rule and the steps are in [the Fable rule](fable.md).

**OpenCode is the free tier.** Jarvis considers it before `sonnet` or `haiku`,
because every small task it handles saves your Claude and Codex quota. Jarvis
tells OpenCode exactly which files to change and which pattern to follow, and
never gives it top- or workhorse-tier work. Free models are run by third
parties, so it never sees real credentials or user data. If OpenCode gets a
task wrong, Jarvis gives it one correction, then moves the task to `sonnet`.

Three caps apply to Claude sessions: **4 machine-wide** (every repo and your
own sessions included, Jarvis sessions not counted), **3 in this project**
(Jarvis included) and **2 Opus workers** (Jarvis doesn't count). Past any of them, `jarvis spawn` refuses and names who holds each
slot (`jarvis sessions` shows them any time). The brief then waits under
To-do in `OPEN.md`, or goes to OpenCode or Codex if it fits them. Idle
sessions don't count, and Jarvis never stops a session it didn't start.

> Model IDs change over time. `jarvis:setup` checks which IDs your Superset
> host accepts and updates the table. The full reasoning is in
> [`model-routing.md`](../plugins/jarvis/skills/run/references/model-routing.md).
