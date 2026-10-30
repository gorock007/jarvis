# <one-line task title>
worker: claude | codex | opencode
model: <claude-opus-5-5 | sonnet | haiku | gpt-6-astra | gpt-5.6-sol | gpt-5.6-terra | gpt-5.6-luna | fable (only after the user ran `jarvis fable allow` for this brief)>
  # note the reason when a cap or the band changed the choice, e.g. `claude-opus-5-5 (Opus cap full; was sonnet)`
effort: <low | medium | high | xhigh>
budget: <optional, overrides jarvis.conf: min=120 usd=25 ctx=350k tests=8 attempts=3>
started: <YYYY-MM-DD HH:MM> · terminal: <filled in by jarvis spawn>

## Goal
<what done looks like for THIS phase, in one paragraph>

## Context
<decisions already made, files to read first, the previous phase's handoff in handoffs/merged/>

## Scope
- May touch: <paths>
- Must not touch: <paths>
- Shared files (edit minimally, name in handoff): <paths>

## Phase
<one phase. A job with several phases gets one brief per phase; the next one
is spawned with `jarvis spawn <brief> --after <this handoff>`>

## Checks
<targeted checks for what this phase touches, output filtered: `pytest -q tests/x 2>&1 | tail -30`.
A heavy suite (Docker, e2e, full) only through its wrapped script or
`handoffs/bin/jarvis lock <class> --reuse -- <command>`, and only if this phase needs it>

## Questions first
Put every question in one first handoff (`status: blocked`) and stop. After
the answers arrive on your terminal, finish this phase without stopping
again. If you have no questions, build straight through.
