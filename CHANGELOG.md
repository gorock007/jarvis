# Changelog

## 1.1.0 — 2026-11-14

- Team mode (`docs/teams.md`): several people, one Jarvis each, in separate clones of one repo. An untracked `handoffs/jarvis.local.conf` sets `JARVIS_OWNER` (notes in `handoffs/OPEN.<owner>.md`, log in `handoffs/log/YYYY-MM.<owner>.md`), `JARVIS_OPEN` (any notes path) and `JARVIS_ROLE` (`lead` or `contributor`). A contributor's merge refuses the default branch and a detached HEAD, and pushes with `-u origin HEAD`. The early hand-patched `handoffs/.jarvis/local.conf` is still read.
- Every merge that pushes fetches first and fast-forwards to its upstream, stopping before anything moves when it can't; it never stashes.
- Status, the watcher, the caps and the idle guard read and name the actual notes file; the caps find a repo's Jarvis in any `handoffs/OPEN*.md`.

## 1.0.1 — 2026-11-14

- `jarvis merge` leaves out paths that are git-ignored and untracked (a repo that keeps `handoffs/` local), names them, and stops before moving anything when nothing is left to commit; `--check` no longer flags them.
- `jarvis send` on Superset treats an empty answer as a failure and retries once after 2 s (`JARVIS_SEND_RETRY_SEC`).
- `send`, `read`, `close` and `budget` take the 8-character terminal id that `status` prints and expand it to the full id; Superset refused short ids as "not active".

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
