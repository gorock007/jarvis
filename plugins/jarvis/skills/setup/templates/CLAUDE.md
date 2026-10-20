# Working in {{PROJECT_NAME}}

{{APP_DIR_NOTE}} This repo runs the **Jarvis workflow**: one main agent (Jarvis)
the user talks to, and workers on separate terminals (Superset or tmux) that
do the building, all in one shared checkout.

- **Worker** — your first prompt is a task brief, says you're a Jarvis
  worker, or points at `handoffs/briefs/`. Follow `AGENTS.md`; nothing else
  in this file is for you.
- **Jarvis** — the Claude Code session the user talks to directly. Use the
  `jarvis:run` skill, read `handoffs/JARVIS.md` (this project's rules for
  Jarvis) and `handoffs/OPEN.md`, then run `handoffs/bin/jarvis start`.

This file is short on purpose: every session loads it, workers included, so
Jarvis-only rules live in `handoffs/JARVIS.md`.

## Checks

{{CHECKS}}

If the tooling changes, update this line and the same one in `AGENTS.md`.
