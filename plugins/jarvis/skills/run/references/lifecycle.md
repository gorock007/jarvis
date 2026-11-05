# Lifecycle and locks — how workers end, how long they run, and how heavy checks share the machine

Three problems, one file. A worker that finished can stay alive: its agent CLI
sits at a prompt in a terminal nobody closes, and it no longer counts toward
the Claude cap. And workers can't see each other's heavy commands: three of
them once ran the same Docker test suite at once, and the machine stalled.
And a worker that has gone wrong keeps spending: 67% of worker spend once
happened past 150k of context, and one brief was respawned again and again
without anyone changing it.

The fixes:

- **Lifecycle.** Every spawn leaves a run record. Merge and close end the
  worker and check that it's gone. `jarvis doctor` explains everything still
  alive.
- **Budgets.** Each worker has limits on working time, estimated cost,
  context, failed tests and attempts. Past one, it is asked for a partial
  handoff, and a brief that blew its budget isn't respawned unchanged.
- **Locks.** A heavy command runs only while it holds a lease for its class.
  The lease is shared by every process on the machine.

```bash
handoffs/bin/jarvis close <terminal>               # cancel a worker: close, verify, record
handoffs/bin/jarvis doctor [--apply | --quiet]     # what's alive in this checkout, and why
handoffs/bin/jarvis budget <terminal> [usd=N ...]  # a worker's budget use; with values, raise its limits
handoffs/bin/jarvis lock <class> [--wait <sec>] [--reuse] -- <command…>
handoffs/bin/jarvis resources [--json]             # who holds each lease, who's queued
handoffs/bin/jarvis merge <handoff> --check --verify [--reuse]  # run the brief's verify blocks, isolated
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

The actions are `close`, `signal`, `list` and `lost`. Three more record the
times Jarvis was told to go past a limit, each with `result=`:

```
cap-force run=- brief=handoffs/briefs/… cap=global n=4 limit=4 band=green result=passed
budget-force run=- brief=handoffs/briefs/… runs=3 attempts=2 budget=reached result=passed
budget-raise run=t3 brief=handoffs/briefs/… limits=usd=30 result=set
```

`cap-force` is `jarvis spawn --force` past a Claude cap, `budget-force` is
`--force` past the respawn gate, and `budget-raise` is `jarvis budget` with
values. Fable has its own log, `~/.jarvis/fable/audit.log`: every `allow`,
`deny`, `consume`, `revoke` and `backstop`, with the brief and the run. It
lives outside the repo, since the authorization is the user's.

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

`merge --outcome clean|corrected|escalated|respawned` also writes
`merge_outcome` (and, for `corrected`, the required `--reason
checks|scope|logic|other` as `merge_reason`) to each of those runs, with one
`merge-outcome` line in `audit.log`. Each watcher wake-up is one line in
`handoffs/.jarvis/watch.log` (time, woke|cleared|nojarvis, reasons, event
count), which `jarvis usage` counts. The watcher holds events for
`JARVIS_BATCH_SEC` (60) after the first one and then sends them as one
message, so a burst is one line and one Jarvis turn; `0` sends at once.

`JARVIS_FASTPATH="trust edit nudge"` answers Codex folder trust and Claude's
single-edit Yes only for an unambiguous path inside May touch and outside
Must not touch, `.claude/`, `.git/`, root `handoffs/` (except an identified,
explicitly listed handoff from this run), settings, env and credential files.
Unknown or truncated paths and command approvals wake Jarvis. A frozen worker
with no handoff gets one nudge after `JARVIS_STALL_MIN`, then wakes Jarvis if
still frozen for another interval. Remove a word to disable it; `""` disables
all three. Actions log `auto` with trust/edit/nudge in `watch.log` plus their
run, brief and path/prompt and key in `audit.log`; they never enter the batch.
`jarvis usage` counts only woke/cleared as wake-ups and reports auto-handled
trust, edit and nudge totals separately.

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

## Worker events

A worker's own hooks tell the watcher what state it is in, so it doesn't
have to guess from the screen. Each event is one line in
`handoffs/.jarvis/events/<brief>.jsonl` (the brief's file name without
`.md`):

```
{"t":1762345678,"kind":"stop","run":"%7","detail":"Done; handoff written."}
```

`t` is the epoch, `run` the writer's run (below) and `detail` one line of at
most 200 characters. Nothing is printed and the command always exits 0, so a
hook can't block a prompt or a stop.

**What writes them**

- **Claude Code**, on every host: the hooks in the settings template
  (`UserPromptSubmit`, `Stop`, `Notification`, `SessionEnd`) run
  `jarvis hook event <kind>`.
- **Codex, on tmux only**: the launch script defines a `codex()` function
  that adds per-run `-c hooks` for `UserPromptSubmit`, `Stop`,
  `PermissionRequest` and `SessionEnd`, next to the user's own hooks and
  `notify`.
- **OpenCode, on tmux only**: a plugin, `handoffs/.jarvis/launch/opencode-events.js`,
  added through `OPENCODE_CONFIG_CONTENT` (OpenCode adds its plugin list to
  the user's). The launch script writes the `ended` event itself after
  `opencode` exits.

**Kinds**

| Kind | Meaning | From |
| --- | --- | --- |
| `working` | a prompt was submitted | Claude `UserPromptSubmit`; Codex `UserPromptSubmit`; OpenCode busy |
| `stop` | the turn finished (`detail`: its last message) | Claude and Codex `Stop`; OpenCode idle |
| `permission` | waiting at an approval prompt | Claude `permission_prompt`; Codex `PermissionRequest`; OpenCode `permission.asked` |
| `waiting` | waiting for the user's input | Claude `idle_prompt`, `agent_needs_input`, `elicitation_dialog`, `elicitation_url_dialog`; OpenCode `question.asked` |
| `ended` | the session ended (`detail`: its reason) | `SessionEnd`; OpenCode: the launch script |

Any other Claude notification type writes nothing. A `SessionEnd` with reason
`clear` or `resume` writes nothing either: the terminal goes on in a new
session. OpenCode events come from the root session only. Codex has no idle
or waiting event, and its `Interrupt` isn't mapped.

**Who counts as a worker.** `JARVIS_ROLE=worker` with `JARVIS_BRIEF` set.
On tmux the launch script sets both for Claude, Codex and OpenCode workers,
and `JARVIS_RUN` too, the window's pane id. On Superset and Ultron there is
no launch script of ours: the hook finds the run record named after
`$SUPERSET_TERMINAL_ID` or `$ULTRON_SESSION_ID`, which must say `agent: claude`,
`state: running` and a brief, and writes that id as `run`. Jarvis's own
terminal has no such record, so its hooks do nothing. `run` is empty when
`JARVIS_ROLE=worker` is set without `JARVIS_RUN`.

**What the watcher does.** For each running worker it reads the last line
whose `run` is that worker's own and whose `t` is not before its spawn, so a
respawn starts clean and the old worker's late `ended` doesn't count. A line
with an empty `run`, or none (an event file from an older `jarvis`), counts
for no run, and that worker keeps the screen path. The usage-limit check
still reads the screen, for an ended worker too.

- **`ended`**, with no handoff for the brief written since the turn began
  (its last `working` event, else its spawn): "worker X ended without a
  handoff — read its terminal", once. No prompt or stall check after it.
- **`permission`**: goes through the prompt path once, even when the screen
  doesn't match a prompt pattern: the trust/edit auto-answer if
  `JARVIS_FASTPATH` allows it, else the "waiting at a prompt" event. After
  that the screen decides, because answering fires no new event.
- **`stop` or `waiting`**: a stall once both the event and the screen's last
  change are `JARVIS_STALL_MIN` old, with no handoff since the turn began.
  So a worker that woke on its own (whether a background job fires a prompt
  hook is unverified) is not nudged while its screen changes. Then the usual one nudge, and after another interval "worker X
  finished its turn N min ago (hook event: stop|waiting) and has no handoff
  — read its terminal". A fresh stop raises nothing.
- **`working`, no events, or another agent**: the frozen-screen check, as
  before.

Each raised or auto-handled event also writes a line to `watch.log` naming
what raised it: `<UTC time>`, a tab, `source`, a tab, `<kind>:<event|screen>`,
a tab, `1`. The tags are `ended:event`, `prompt:event`, `prompt:screen`,
`stall:event`, `stall:screen`, `nudge:event`, `nudge:screen`, `edit:event`,
`edit:screen`, `trust:event` and `trust:screen`. `jarvis usage` doesn't
count these lines.

**Limits**

- On Superset and Ultron a worker's first `working` event can fire before
  spawn has written its run record, and is lost; the next event is not.
- Codex and OpenCode workers on Superset and Ultron write no events: those
  hosts launch them, so they keep the screen path.
- Codex runs per-run hooks only with `--dangerously-bypass-hook-trust`, which
  the built-in `JARVIS_AGENT_codex` passes. A line without it, or one that
  starts `codex` through `exec` or an absolute path, skips the wrapper and
  keeps the screen path. With `OPENCODE_CONFIG_CONTENT` already set, so
  does OpenCode. With the built-in line Codex never asks for approval, so
  `permission` is not expected from it.
- A tmux worker spawned before its `jarvis` was upgraded has no
  `JARVIS_RUN`, so its lines have an empty `run` and count for nothing until
  it is respawned.
- An OpenCode `stop` has no detail, and a crash of its whole window writes no
  `ended`.
- Claude's `Notification` payload was never captured from a live permission
  prompt; its field names (`notification_type`) come from Claude Code's hooks
  reference.
- The event stall needs the screen to hold still, like the screen path. A
  worker UI that redraws something time-based while idle (a clock, a live
  statusline) is never nudged or woken. Claude Code's own statusline
  re-renders only when messages update, so the template's is fine.
- A truncated multibyte character is possible in `detail` under a C locale.

## Worker budgets

A worker that has gone wrong costs the most when nobody notices. Every
running Claude worker has five limits, and `jarvis watch` checks them on its
ticks. Codex and OpenCode workers have no transcript here, so only the first
and last apply to them.

| Limit | Default | Counts |
| --- | --- | --- |
| `min` | 90 | **Working minutes**: watcher ticks in which the worker's screen changed. A worker idle at its prompt, such as one waiting for answers, adds nothing. |
| `usd` | 15 | An API-equivalent estimate of its transcripts, subagents included (list prices, not a bill) |
| `ctx` | 300000 | The context of its last turn |
| `tests` | 6 | Failed test runs, counted as `jarvis usage` counts them |
| `attempts` | 2 | Runs of one brief, in any state: a per-brief limit, checked at spawn |

A brief overrides the defaults with a line in its header, above the first
`##`:

```
budget: min=120 usd=25 ctx=350k tests=8 attempts=3
```

**Step 1, the ask.** The first limit a running worker reaches (in the order
min, usd, ctx, tests), with no done or partial handoff for its brief yet,
makes the watcher type one message into its terminal: `[jarvis] Budget
reached (usd: $16.2/$15). Stop the current approach now. Write your handoff
with status: partial …`. It happens once. Jarvis is woken with `worker <id>
hit its usd budget — asked for a partial handoff`.

**Step 2, the pause.** `JARVIS_BUDGET_GRACE_MIN` (10) minutes after the ask,
if no handoff has landed and the screen is still changing, the watcher sends
Escape. That interrupts the agent and nothing more. Jarvis is woken with
`worker <id> paused over budget, no handoff — read its terminal`. A host
that takes no keys (an Ultron chat session) records `pause_failed` and wakes
Jarvis to read the terminal instead.

**A worker is never closed or signalled over budget.** Its edits are
uncommitted in the shared checkout. Jarvis decides what happens next: wait for
the partial handoff, send a nudge, or raise a limit with `jarvis budget
<terminal> usd=30` when the work is on track. That merges the values into
the run's limits, re-arms the ask and the pause, and writes a `budget-raise`
line. `attempts=` isn't settable there, since it is per brief. With no values
it prints the budget line. Workers already running when budgets arrive start
counting minutes at zero, but their cost and context are read from the
whole transcript, so one can be asked on the first tick.

**The respawn gate.** `jarvis spawn` refuses a brief when any of its runs
reached a budget, or when it already has `attempts` runs. The refusal names
the run and the limit and points at the latest handoff: sharpen or split the
brief, then respawn with `--after` that handoff. `--after` passes the gate
only with a handoff whose `brief:` is this brief and that was written after
the brief's latest run was spawned. `--force` passes it too, and writes
`budget-force`. The gate runs before the cap claim and any Fable
authorization is used, so a refusal costs neither.

`jarvis status` shows each running worker's use on one line:

```
      budget: 42m/90m working (1h50m since spawn) · $6.1/$15 · ctx 180k/300k · tests 1/6
```

An item over its limit says `(over)`, followed by `asked for a partial
handoff HH:MM` or `paused HH:MM`. `jarvis usage` counts these runs under
"over budget".

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
verification worktrees:
  handoffs/.jarvis/verify/t5/… · run t5 · ORPHANED: its verifier (pid 4242) and watchdog are gone · a registered worktree
act on the FINISHED, lost and ORPHANED ones (nothing else is touched): handoffs/bin/jarvis doctor --apply
```

- **Agent processes** are Jarvis, `worker, running`, `worker, FINISHED` (its
  run is merged or closed, or it has no record and its handoff is in
  `merged/`), or `not a worker (left alone)`. A busy finished worker is
  marked `busy: left alone`. A worker's session in a process that started
  more than 60 s after its run ended (or its handoff went into `merged/`) is
  `resumed after its brief finished (left alone)`: someone reopened the
  transcript later, so it is never counted or signalled, its brief's finished
  terminal is left open, and what it runs is never a leftover.
- **Terminals** are Jarvis, `worker, running`, `FINISHED but open` or
  `unknown (left alone)`. An unknown terminal shows its title when the host
  has the optional `titles` op (see `hosts.md`).
- **Registry** lists `lost` runs: still `running`, but the host doesn't list
  the terminal and no agent of the run is alive.
- **Leftovers** is `jarvis leftovers`' report. **Locks** is `jarvis
  resources`, cut down to held slots and waiting queues of this checkout's
  classes and the machine-wide ones.
- **Verification worktrees** are `merge --verify` attempts under
  `handoffs/.jarvis/verify/`: `running … (left alone)`, `ORPHANED` (its
  verifier and its watchdog are both gone, checked by PID and start time),
  or `left alone — look, then remove it yourself` when the ownership
  manifest can't be trusted or a process of it can't be accounted for. A run
  record stuck at `verify_status: running` with nothing alive is `stale`.
  The block is skipped, at no cost, when there is no verification state.

`--apply` acts on three things, in this order, and prints and audits each:

1. A finished run's open terminal: the same close, wait and verify as merge.
   It skips a terminal whose agent is busy.
2. A finished agent whose terminal is gone: TERM then KILL, identity checked
   before each signal. This ignores `JARVIS_REAP`, because `--apply` is an
   explicit request. It skips a busy agent, and does nothing when the host
   can't be asked.
3. A lost run: checked again, then marked `state: lost`.
4. An orphaned verification, under this checkout's `verify` lease (taken
   without waiting; while a verification runs, it reclaims nothing and says
   so): it stops that attempt's own check group, removes only its registered
   worktree, marks the result `interrupted` and the run `verify_status:
   stale`. Audited as `verify-orphan` or `verify-stale`.

```
doctor: closed t3 (2026-10-27-0100-b, finished)
doctor: marked run t4 lost (2026-10-27-0100-c): its terminal is gone and no agent of it is alive
```

Nothing else is ever touched. Unknown terminals and non-worker sessions are
reported, not acted on, and they don't count in the one-liner.

`--quiet` prints that one-liner, or nothing when there's nothing to act on
(it also counts orphaned verification worktrees and stale verify records):

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

## merge --check --verify

```bash
handoffs/bin/jarvis merge <handoff> --check --verify [--reuse]
```

Plain `--check` compares the file list with `git status`. `--verify` also
runs the brief's ```` ```bash verify ```` blocks (format:
`references/handoffs.md`) on **HEAD plus exactly the handoff's listed
changes**, in a detached worktree of its own. Other workers' dirty edits are
not in it, so they can't make a check pass or fail. It commits, moves and
closes nothing. It needs `python3` and `handoffs/bin/jarvis-verify.py`, and
perl when the brief has a run record (to write it safely).

- **Before anything runs** it reads `## Files` strictly: `- path — created |
  modified | deleted`, one path per line, no globs, folders, `..` or
  absolute paths. A listed path that doesn't match the checkout is exit 1. A
  brief with no verify blocks is exit 2 ("no executable Checks blocks").
- **Each block** runs in a fresh `bash --noprofile --norc -e -o pipefail`
  in its own process group. A class other than `light` runs under that
  class's lease of the original checkout, so a worktree check still queues
  behind the checkout's own `suite`. One verification runs per checkout at a
  time (the internal `verify` lease).
- **Output:** `verify: passed 2/2 checks at HEAD <short> · tree <short> ·
  isolated listed changes`, or the failing block, its exit and its last 40
  lines, with the full log under `handoffs/.jarvis/verify-results/`.
- **Exit codes:** `0` passed (or a pass reused) · `1` file-list mismatch, a
  required input missing, or a check failed · `2` bad brief, handoff or
  config, or a setup or cleanup failure · `75` a lease wait ran out, or HEAD,
  a listed file or an input changed while it ran (run it again) · `124` a
  check hit its `timeout=` · `129`/`130`/`143` HUP/INT/TERM, after cleanup.
- **Every exit** stops what is left of the check's group and removes the
  worktree. A watchdog in its own session does the same if the verifier dies.
  If both die, `jarvis doctor` finds the attempt.
- **The run record** of the brief's newest run gets `verify_status`
  (`running`, `passed`, `failed`, `error`, `timeout`, `interrupted`,
  `stale`), `verify_head`, `verify_tree`, `verify_key`, `verify_started`,
  `verify_finished`, `verify_exit`, `verify_check`, `verify_attempt`,
  `verify_log` and `verify_reused`. Lifecycle keys (`state`, `ended`) are
  left alone. Every record update now runs under a per-run lock in
  `handoffs/.jarvis/run-locks/`.

**A pass is an observation before merging, not an approval.** Nothing makes
an ordinary merge wait for one. Verify again after any relevant edit.

The checks are trusted code. The worktree keeps their normal writes away
from the shared checkout, but it isn't a sandbox: a check can still reach
outside it on purpose. Checks must not run git commands that change
branches or HEAD, write outside the worktree, or leave daemons running.

**`--reuse`** reports an earlier pass instead of running again when the
newest finished attempt with the same `verify_key`, for the same run, passed
and cleaned up less than `JARVIS_REUSE_MAX_AGE` seconds ago (0 = never), and
no block says `reuse=never`. The key covers HEAD, the candidate tree and
checked-out bytes, the listed changes, the brief (without `started:`), the
blocks and inputs, the runner and helper bytes, the lock settings, bash, the
OS and a digest of the environment (`PATH`, locale, `NODE_ENV` and friends,
plus the variables in `JARVIS_REUSE_ENV`; values are never stored). A later
failure blocks an older pass, and a reuse never extends a pass's life:

```
verify: reused pass from 18:12 (4m ago) · tree 3f2a9c1 · handoffs/.jarvis/verify-results/…
```

`--reuse` trusts this checkout's own `handoffs/.jarvis/` state. Anyone who
can write to the checkout, a worker included, could forge a stored pass. So
it is an opt-in convenience for Jarvis, not a gate.

## Spawn overlap

`jarvis spawn` compares the new brief's `- May touch:` row (grammar:
`references/handoffs.md`) with each running worker's. Running means a
registry record in `state: running`, or an `OPEN.md` running line with no
record. Merged, closed and lost runs don't count. It needs `python3` and
`handoffs/bin/jarvis-scope.py`. With nothing running it asks neither.

```
jarvis spawn: overlap: <new> [src/lib/] with running <other> [src/lib/x.py] — queue <new> under To-do until <other> is handed off, or narrow the scopes.
jarvis spawn: possible overlap: …        (globs or case that might meet)
jarvis spawn: overlap: <brief> is already running (term T) — close that worker first (handoffs/bin/jarvis close T), or wait for its handoff.
jarvis spawn: unknown overlap: <new>'s scope can't be read (<reason>), so it can't be compared with running … — give it a '- May touch:' row of paths, or queue it under To-do until they are handed off.
jarvis spawn: unknown overlap: running term T has no brief on record, so its scope can't be read — treat it as overlapping <new>: queue <new> under To-do until it is handed off, or close it (handoffs/bin/jarvis close T).
jarvis spawn: unknown overlap: no python3 on PATH | no handoffs/bin/jarvis-scope.py (re-run jarvis:setup) | jarvis-scope.py failed (exit N), …
```

- `JARVIS_OVERLAP=warn` (the default) prints these and spawns, adding
  `spawning anyway (JARVIS_OVERLAP=warn)` after an unknown one.
- `JARVIS_OVERLAP=refuse` prints `refused (JARVIS_OVERLAP=refuse): …` and
  spawns nothing. `--force` doesn't pass it. Any other value exits 2.
- **An unknown scope counts as overlapping.** Most older briefs have prose
  in their May-touch row, so they warn "unknown", and under `refuse` they
  are refused until the row is rewritten as paths.
  A running worker with no brief on record (a run record or `OPEN.md` line
  with a term but no brief) is unknown too.
- Must-not-touch rows aren't subtracted. This is a collision warning, not a
  permission check: it reserves nothing, and a worker can still edit any
  file.

The check, the launch and the run record happen under a per-checkout
`spawn` lease, so two spawns can't both pass the check and then both
launch. A spawn waits up to `JARVIS_SPAWN_WAIT` seconds (120) for it, then
says "another spawn in this checkout has held its spawn lease…". Any other
failure to take it is "can't take the spawn lease of this checkout…: spawn
refused". Once the leased part has started, spawn exits with that part's own
code (1 for a refusal inside it) and adds nothing to its message, except
`jarvis spawn: interrupted (exit N)` for a signal. The lease errors are only
for a lease that was never taken. The host's processes don't inherit the
lease. Without perl, warn
mode says `overlap check not atomic` and spawns, while refuse mode refuses.

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
| `JARVIS_BUDGET_MIN` | `90` | Working minutes before the ask |
| `JARVIS_BUDGET_USD` | `15` | Estimated dollars (API-equivalent) |
| `JARVIS_BUDGET_CTX` | `300000` | Context tokens of the last turn |
| `JARVIS_BUDGET_TESTS` | `6` | Failed test runs |
| `JARVIS_BUDGET_ATTEMPTS` | `2` | Runs per brief. A brief's `budget:` line overrides all five. |
| `JARVIS_BUDGET_SEC` | `300` | How often the watcher reads a worker's transcript |
| `JARVIS_BUDGET_GRACE_MIN` | `10` | Minutes between the ask and Escape |
| `JARVIS_REAP` | `1` | Merge and close stop a closed worker's surviving agent and its leftovers. `0`: they only name them. |
| `JARVIS_STOP_GRACE` | `10` | Seconds merge and close wait for a closed terminal and its agent to go |
| `JARVIS_LOCK_<class>` | `docker="host 1"`, `suite="checkout 1"` | A lock class: `"<host\|checkout> <capacity>"` |
| `JARVIS_LOCK_WAIT` | `3600` | Seconds a waiter queues before exit 75. `--wait` overrides it. |
| `JARVIS_LOCK_DIR` | `~/.jarvis/locks` | Where the leases live. Per user, so two users don't share leases. |
| `JARVIS_REUSE_MAX_AGE` | `7200` | How old a stored pass may be and still be reused |
| `JARVIS_REUSE_ENV` | empty | Variables whose values count toward "identical", e.g. `"NODE_ENV"` |
| `JARVIS_VERIFY_MAX_SEC` | `7200` | The largest `timeout=` a `bash verify` block may ask for |
| `JARVIS_OVERLAP` | `warn` | Spawn's scope check: `warn` and spawn, or `refuse` |
| `JARVIS_SPAWN_WAIT` | `120` | Seconds a spawn waits for another spawn's lease |

The two `JARVIS_REUSE_*` settings apply to `jarvis lock --reuse` and `merge
--verify --reuse` alike. `verify` and `spawn` are reserved lock class names:
they are Jarvis's own leases (one verification and one spawn at a time per
checkout), and `jarvis lock` refuses them.

State lives under `handoffs/.jarvis/`, which is ignored: `runs/` (the
registry), `run-locks/` (one write lock per run record), `verify/` (live
verification attempts, removed when each ends) and `verify-results/` (each
attempt's result and logs, kept).

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
