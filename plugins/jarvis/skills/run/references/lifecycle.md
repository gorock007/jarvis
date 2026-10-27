# Lifecycle and locks — how workers end, and how heavy checks share the machine

Two problems, one file. A worker that finished can stay alive: its agent CLI
sits at a prompt in a terminal nobody closes, and it no longer counts toward
the Claude cap. And workers can't see each other's heavy commands: three of
them once ran the same Docker test suite at once, and the machine stalled.

The fixes:

- **Lifecycle.** Every spawn leaves a run record. Merge and close end the
  worker and check that it's gone. `jarvis doctor` explains everything still
  alive.
- **Locks.** A heavy command runs only while it holds a lease for its class.
  The lease is shared by every process on the machine.

```bash
handoffs/bin/jarvis close <terminal>               # cancel a worker: close, verify, record
handoffs/bin/jarvis doctor [--apply | --quiet]     # what's alive in this checkout, and why
handoffs/bin/jarvis lock <class> [--wait <sec>] [--reuse] -- <command…>
handoffs/bin/jarvis resources [--json]             # who holds each lease, who's queued
```

## Who owns what

On every host the terminal is the boundary. On Superset the chain is: the
host's terminal → a login shell → the agent CLI → each command the agent
runs. tmux and Ultron have the same shape.

Jarvis acts only on what it can show it started:

- a run it recorded,
- whose identity it checked again just before acting.

Everything else is reported and left alone: terminals it didn't open, Claude
sessions that aren't workers, other repos' processes.

## The run registry

`jarvis spawn` writes one small file per worker: `handoffs/.jarvis/runs/<run>`.
The run id is the host's terminal id. The file holds `key: value` lines:

```
run: t1
brief: handoffs/briefs/2026-10-27-0100-a.md
agent: claude
model: sonnet
effort: low
host: fake
spawned: 1793085162
state: merged
ended: 1793085170
reason: merged e8fe75f
outcome: closed t1
```

`state` is `running`, `merged`, `closed` or `lost`. That's the whole state
machine. Whether a process is alive, busy or idle is never stored. It's read
from `ps`, Claude Code's session records and the host's terminal list at the
moment of asking. A stored copy of that would only go stale.

Spawn also writes the terminal into the brief's `started:` line. It inserts
the line when the brief has none. A brief without that line used to leave
its worker with no record, and merge then had nothing to close.

If the brief already has a `running` run, spawn warns. Merge closes every
worker of a brief, so it names the `jarvis close <id>` for the old one.

Every close, signal and lost-marking is one line in
`handoffs/.jarvis/audit.log`:

```
2026-10-27T07:12:50Z close run=t1 brief=handoffs/briefs/2026-10-27-0100-a.md terminal=t1 result=ok
2026-10-27T07:12:59Z lost run=t4 brief=handoffs/briefs/2026-10-27-0100-c.md terminal=t4 result=marked lost
```

The actions are `close`, `signal`, `list` and `lost`.

## Ending a worker

**Merge** closes every `running` run of the brief. For a brief spawned before
the registry existed, it also closes the terminal in its `started:` line or
its OPEN.md entry. Then, for each run:

1. It notes the run's agent processes. A Claude session belongs to the run
   when the prompt hook recorded it in that terminal, or when its transcript
   names the brief.
2. It asks the host to close the terminal, and keeps the error if there is one.
3. It waits up to `JARVIS_STOP_GRACE` seconds (10) for the terminal to leave
   the host's list and the noted processes to exit.
4. A survivor is stopped with TERM, then KILL after 10 s, when
   `JARVIS_REAP=1`. Its pid and start time are checked again before each
   signal. With `JARVIS_REAP=0` it is only named, with the `kill` to run.
5. It writes `state`, `ended`, `reason` and `outcome` to the run record.

Every failure is on the merge line, never swallowed:

```
merged e8fe75f · 1 files · not pushed · closed t1 · OPEN.md updated in the same commit
```

Other outcomes read `close FAILED for t1: <the host's error>`,
`worker pid N didn't exit on close: stopped (TERM)`, or
`terminal t1 still listed after 10 s`. Merge stops the worker's leftover
processes only when every close succeeded.

`merge --keep-open` closes nothing, and the run stays `running`:

```
--keep-open: nothing closed; still open: t3 . Later: handoffs/bin/jarvis close <terminal>
```

Doctor counts that worker as running, not finished, so it won't nag. End it
with `jarvis close` when the follow-up is done.

**`jarvis close <terminal>` is cancel.** It runs the same close, wait and
verify as merge, and records the run as `closed`. It drops the worker from
OPEN.md only when the close worked. It refuses Jarvis's own terminal.

```
$ handoffs/bin/jarvis close t2
closed t2 · dropped it from Running workers
$ handoffs/bin/jarvis close t2
close FAILED for t2: Error: terminal t2 not found          # exit 1
```

Merge doesn't ask the agent to exit first. An LLM is not a reliable
acknowledgement, and asking costs a turn. The handoff is the agent's "done".
Closing the terminal is the one way to end it that always works.

## jarvis doctor

`handoffs/bin/jarvis doctor` is read-only. It makes one pass over `ps`,
Claude's session records, the host's terminal list and the registry, and
prints five blocks:

```
agent processes (Claude, in this checkout):
  none
terminals on fake:
  jarvis-t · Jarvis
  t3 · FINISHED but open · 2026-10-27-0100-b · merged
  t99 · unknown (left alone) · "title"
registry:
  run t4 · lost: running, but its terminal is gone and no agent of it is alive · 2026-10-27-0100-c
leftovers:
  none
locks:
  none held or queued here or machine-wide
act on the FINISHED and lost ones (nothing else is touched): handoffs/bin/jarvis doctor --apply
```

- **Agent processes** are Jarvis, `worker, running`, `worker, FINISHED` (its
  run is merged or closed, or it has no record and its handoff is in
  `merged/`), or `not a worker (left alone)`. A busy finished worker is
  marked `busy: left alone`.
- **Terminals** are Jarvis, `worker, running`, `FINISHED but open` or
  `unknown (left alone)`. An unknown terminal shows its title when the host
  has the optional `titles` op (see `hosts.md`).
- **Registry** lists `lost` runs: still `running`, but the host doesn't list
  the terminal and no agent of the run is alive.
- **Leftovers** is `jarvis leftovers`' report. **Locks** is `jarvis
  resources`, cut down to held slots and waiting queues of this checkout's
  classes and the machine-wide ones.

`--apply` acts on three things, in this order, and prints and audits each:

1. A finished run's open terminal: the same close, wait and verify as merge.
   It skips a terminal whose agent is busy.
2. A finished agent whose terminal is gone: TERM then KILL, identity checked
   before each signal. This ignores `JARVIS_REAP`, because `--apply` is an
   explicit request. It skips a busy agent, and does nothing when the host
   can't be asked.
3. A lost run: checked again, then marked `state: lost`.

```
doctor: closed t3 (2026-10-27-0100-b, finished)
doctor: marked run t4 lost (2026-10-27-0100-c): its terminal is gone and no agent of it is alive
```

Nothing else is ever touched. Unknown terminals and non-worker sessions are
reported, not acted on, and they don't count in the one-liner.

`--quiet` prints that one-liner, or nothing when there's nothing to act on:

```
doctor: 1 finished terminal open — handoffs/bin/jarvis doctor
```

`jarvis status` ends with it, and so does `jarvis start` (through status).
**When it appears, act on it.** Run `jarvis doctor` and read what it found.
Then run `--apply` if it lists only finished and lost things. A busy finished
worker is a question: is it really done?

Doctor finds Jarvis by the prompt hook's records. In a repo still on an older
`bin/jarvis`, Jarvis shows as `not a worker` until the repo is upgraded,
unless doctor runs from Jarvis's own terminal. It's never acted on either way.

## Heavy checks: who runs what

The policy every template follows:

- **Workers run targeted checks** for what they touched: unit tests, lint,
  the typecheck of their modules. They run them freely and in parallel.
- **Heavy suites** are the ones the repo marks heavy: Docker, e2e, the full
  suite. They run only through the repo's wrapped scripts or `jarvis lock
  <class> -- <command>`. Never bare, and never twice in a row: `--reuse`
  reports a pass on the identical tree instead of running it again.
- **Lock waits are normal.** Wait. Don't work around the lock, and never
  kill the holder.
- **The merge gate.** Jarvis runs the authoritative heavy verification once
  for the integration candidate, under the lock with `--reuse`. That's after
  merging a wave, or before merging a handoff that touches what the heavy
  suite covers. The result goes in the merge message or OPEN.md.

**Enforcement lives in the repo's scripts, not in instructions.** An
instruction can be forgotten. A wrapped script can't be called without the
lease. At setup, and on "update Jarvis in this repo", Jarvis looks for heavy
suites in the project's scripts (docker, compose, testcontainers, e2e,
playwright, "full") and proposes wrapping them:

```json
"test:docker": "handoffs/bin/jarvis lock docker -- vitest run --project docker"
```

It edits the project's scripts only when the user says yes. Every caller
then goes through the lease: any agent, the user, CI.

The checkout is shared. So a suite that writes shared artifacts (build
output, a dev database) gets a lock class of its own, even when it's light
on CPU: two runs at once would corrupt each other's output.

## jarvis lock

```bash
handoffs/bin/jarvis lock <class> [--wait <sec>] [--reuse] -- <command…>
```

A class is `JARVIS_LOCK_<class>="<scope> <capacity>"` in `jarvis.conf`:

- scope `host`: one lease for the whole machine, across every repo
- scope `checkout`: one lease for this checkout only
- capacity: how many may run at once

Built in: `docker="host 1"` (one Docker suite on the machine) and
`suite="checkout 1"`. A conf line overrides them. Class names are `a-z`,
`0-9` and `_`.

Waiters queue in order. A waiter prints a line when it starts waiting, then
one every 60 s:

```
jarvis lock docker: waiting — held by pid 21831 (term 1a2b3c4d, 1s: sleep 3); 0 ahead
```

Exit codes:

- the command's own status (128+signal when it was signalled)
- `75` when `--wait` (default `JARVIS_LOCK_WAIT`, 3600 s) runs out:

  ```
  jarvis lock docker: gave up after 1s — held by pid 21831 (term 1a2b3c4d, 2s: sleep 3); 0 ahead. Wait longer with --wait <sec> or JARVIS_LOCK_WAIT
  ```

- `2` for a usage error, or an unknown or malformed class. The command
  isn't run:

  ```
  jarvis lock: no lock class 'e2e'. Add one to handoffs/jarvis.conf, e.g. JARVIS_LOCK_e2e="host 1" (host = machine-wide, checkout = this checkout only; then how many at once)
  ```

The lease is a kernel `flock` on a file in `JARVIS_LOCK_DIR`
(`~/.jarvis/locks`). The command and everything it starts inherit it, so the
lease lasts exactly as long as any process of the run. When the last one
exits, even by SIGKILL, the kernel releases it. So a lease can't go stale,
and there's nothing to reclaim. If the wrapper itself is killed, the
command's processes keep the lease until they exit, because they're still
using the resource. Kill the process group to free it.

A command that calls `jarvis lock` for a class it already holds runs
straight through, so a wrapped script inside a wrapped script doesn't
deadlock.

It needs perl, which macOS ships (macOS has no `flock(1)`).

- **No perl, on CI** (`CI` set and not `0`/`false`): it runs the command
  without the lease, and says so. A CI runner has no other agents to queue
  behind.
- **No perl, anywhere else:** exit 2. The command isn't run.
- **`bin/jarvis-lock.pl` missing:** exit 2, "re-run jarvis:setup". This
  happens when a repo was upgraded by copying only `bin/jarvis`.

`lock` needs no OPEN.md, no host and no `jarvis.conf`. It works from any
directory, and runs the command in the directory it was called from.

## --reuse

With `--reuse`, a pass (exit 0) is stored. A later run with the same key
within `JARVIS_REUSE_MAX_AGE` seconds (7200) is reported instead of run:

```
jarvis lock suite: passed at 18:12 (0s ago, term 1a2b3c4d, session 5e6f7a8b) on this exact tree, command and directory — not re-running. To run it anyway, run it without --reuse.
```

The key is: the class, the working tree, the directory relative to the
checkout root, the command line, and the values of the variables named in
`JARVIS_REUSE_ENV`. The tree is the working tree as `git add -A` would see
it, untracked files included and ignored files left out. Failures are never
stored. Outside a git checkout it says so and runs the command.

**Keep logs out of the tree.** A command that writes a log or report into
the checkout, somewhere not gitignored, changes the tree it's keyed on. So
the next run never matches. Write logs outside the checkout, or into an
ignored folder. (Jarvis hit exactly this in its own test.)

## jarvis resources

```
docker · machine
  slot 0  held  pid 21831 · term 1a2b3c4d · 1s · sleep 3
  queue empty · 0 stored passes
suite · /path/to/checkout
  slot 0  free
  queue empty · 6 stored passes
```

Every class that has been used on this machine, each slot held or free (with
holder pid, terminal, age and command), the queue and the stored passes.
`--json` gives the same thing as JSON. Whether a slot is held always comes
from the lock itself. A leftover holder record on a free slot is shown as
stale.

## Settings

All in `handoffs/jarvis.conf`:

| Setting | Default | What it does |
| --- | --- | --- |
| `JARVIS_REAP` | `1` | Merge and close stop a closed worker's surviving agent and its leftovers. `0`: they only name them. |
| `JARVIS_STOP_GRACE` | `10` | Seconds merge and close wait for a closed terminal and its agent to go |
| `JARVIS_LOCK_<class>` | `docker="host 1"`, `suite="checkout 1"` | A lock class: `"<host\|checkout> <capacity>"` |
| `JARVIS_LOCK_WAIT` | `3600` | Seconds a waiter queues before exit 75. `--wait` overrides it. |
| `JARVIS_LOCK_DIR` | `~/.jarvis/locks` | Where the leases live. Per user, so two users don't share leases. |
| `JARVIS_REUSE_MAX_AGE` | `7200` | How old a stored pass may be and still be reused |
| `JARVIS_REUSE_ENV` | empty | Variables whose values count toward "identical", e.g. `"NODE_ENV"` |

`JARVIS_REAP` and `JARVIS_STOP_GRACE` are set in the script and in
`jarvis.conf`, so an exported variable doesn't change them: edit the conf.
The lock settings can also come from the environment when the conf doesn't
set them.

## Limits

- Tested on macOS. Linux should behave the same (`flock` semantics, `ps`)
  but hasn't been run.
- Identity checks for Codex and OpenCode workers stop at the terminal: they
  leave no per-process record. Their close is verified with the host's list.
- Claude Code's session records (`~/.claude/sessions/`) are undocumented.
  Doctor uses them when present and never depends on them.
- A lease is per user (`$HOME`). Two users on one machine don't queue for
  each other.

## Not built, on purpose

- **No database or heartbeats.** Process state is read from the OS when it's
  needed. A heartbeat is a second, staler copy of what the OS already knows,
  and it needs a writer loop to keep it alive.
- **No large state machine.** Four run states cover every action doctor
  takes.
- **No global reaper.** Doctor acts only when asked (`--apply`), and only on
  what Jarvis owns.
- **No command parsing or PreToolUse hook for heavy commands.** A hook would
  work only for Claude and would have to guess from shell text. Wrapping the
  script where it's declared catches every caller.
- **No stale-lease reclaim, owner check or PID-reuse handling for locks.**
  The kernel releases a flock when its holder dies, so none of these can go
  wrong.
- **No CPU or thermal monitor, scheduler, or Docker container cleanup.**
  What a repo's suite leaves behind is the repo's to clean up.
