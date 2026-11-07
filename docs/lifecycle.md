# Worker lifecycle and heavy checks

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
[`lifecycle.md`](../plugins/jarvis/skills/run/references/lifecycle.md).
