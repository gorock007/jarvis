# The Fable rule

**Fable is never used unless you authorize one brief, at your own terminal.**
Jarvis doesn't pick it, a band change doesn't escalate to it, and a brief
that came back with questions doesn't move up to it. Work that would have
gone there goes to `gpt-6-astra`. To use it for one task, see
[How do I use Fable for one task?](#how-do-i-use-fable-for-one-task) below. Two
guards back this up: `jarvis spawn` checks every spelling of the model name
(`--force` doesn't pass it), and an `availableModels` list in your
`~/.claude/settings.json` makes Claude Code itself substitute Opus for Fable,
including for subagents. Setup asks before writing that list, because it
applies in every repo and also stops your own `/model fable`.

## How do I use Fable for one task?

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
