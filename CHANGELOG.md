# Changelog

## 1.0.0 — 2026-11-09

- Split `bin/jarvis` (3,075 lines) into a 211-line entry script and 21 modules under `bin/lib/`; CI runs every offline test and strict shellcheck on Ubuntu and macOS.
- Batch watcher wake-ups (`JARVIS_BATCH_SEC`), log each wake with its reason, and handle routine events without waking Jarvis: Codex folder trust, edit approvals inside a brief's May-touch paths, a first nudge for a stalled worker. Claude Code's own trust screen always wakes Jarvis.
- Workers report their state through hooks (`jarvis hook event`: working, stop, notification, ended): Claude Code everywhere, Codex and OpenCode on tmux. A busy worker isn't nudged for a frozen screen until `JARVIS_BUSY_STALL_MIN`.
- `jarvis merge --check --verify [--reuse]` re-runs a handoff's checks in a throwaway worktree holding only its listed files; spawn warns when May-touch scopes overlap (`JARVIS_OVERLAP=warn|refuse`); `doctor` cleans leftover verify worktrees.
- Setup asks 3 questions (checks, Claude cap, statusline tap) instead of 13; README cut to 163 lines with the rest in `docs/`.
- Jarvis's own read-only commands, exact `start`/`status` and `log` run without a permission prompt; everything that spawns, sends, merges or locks still asks (security-reviewed).
- `jarvis log` keeps history out of `OPEN.md`; `jarvis lessons` proposes, reviews and applies lessons from past handoffs for briefs and reviews.
- `merge --outcome corrected --reason checks|scope|logic`; `jarvis usage` reads the same subscription reading as `band`, counts merged handoffs kept out of git, and honours `--until`.
- `jarvis send` on Superset fails loudly when nothing reached the worker.
- Fixes: Codex hook values on tmux were brace-expanded into broken `-c` arguments by some bash builds; verify recorded two finish times a second apart on a fresh run.

## 0.7.1 — 2026-10-30

- Count workers, but not the repository's Jarvis session, toward machine-wide and Opus caps.

## 0.7.0 — 2026-10-30

- Make Fable opt-in and enforce fail-closed model and capacity gates.
- Add machine-wide Claude caps, worker budgets, checkpoints, and pause handling.
- Expand usage reporting with per-worker and per-brief costs, waste signals, and context growth.
- Guard `.claude` parents and symlinked leaves in the pretool hook.

## 0.6.1 — 2026-10-27

- Leave a resumed session's terminal and processes alone.
- Ensure a resumed session after its brief finishes is never treated as the worker.

## 0.6.0 — 2026-10-27

- Add heavy-check policy, merge gates, and lifecycle documentation.
- Add doctor census and cleanup for finished or lost agents, terminals, and runs.
- Add machine-wide leases for heavy commands.
- Record run starts and verify close on merge or close.

## 0.5.0 — 2026-10-20

- Add Ultron as a built-in host.

## 0.4.1 — 2026-10-20

- Rename the project and plugin identity to Jarvis.

## 0.4.0 — 2026-10-20

- Run Jarvis on Superset or tmux, with any agent CLI as a worker.

## 0.3.4 — 2026-10-20

- Stop leftover worker processes when a worker is merged.

## 0.3.3 — 2026-10-18

- Avoid staging a handoff at its old path during merge.

## 0.3.2 — 2026-10-18

- Wake Jarvis for workers stuck at a prompt or frozen, with Codex pre-trusted.

## 0.3.1 — 2026-10-01

- Run Jarvis on Claude Opus 5.5 at high instead of Fable.

## 0.3.0 — 2026-09-30

- Install new files, merge settings, and upgrade 0.2 repositories during setup.
- Use short sessions, event-driven waiting, and commands over turns.
- Move Jarvis rules to handoffs/JARVIS.md and use one brief per phase.
- Add Sonnet subagents, per-merge security review, and budget-enforced routine commands.
- Add Opus routing and optional Jev helpers.

## 0.1.1 — 2026-09-17

- Add the Jarvis plugin with setup and run skills.
