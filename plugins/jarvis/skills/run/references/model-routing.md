# Model routing — who gets which task

Two questions decide everything: **what kind of decision is in this task**,
and **how much Claude usage is left**. Capability first, budget second.

**Fable is never used on Jarvis's own judgment.** A Claude worker runs on
`fable` only when the user authorized that one brief, at their own terminal
(section 2b). Work that would have gone to Fable goes to Codex `gpt-6-astra`.
Opus 5.5 is the default for substantial work, and `sonnet` or `haiku` cover
the smaller kinds.

Jarvis itself is Claude Code, started on `claude-opus-5-5` at `high`. Codex is
never Jarvis. Jarvis doesn't downgrade itself mid-session. When usage gets
tight, it routes *work* away, so the remaining budget goes to coordination.
Changing Jarvis's model means starting a fresh session. A `/model` switch
rewrites the whole cache.

Why Opus 5.5 and not Fable: `eval/jarvis-model/` in the plugin repo ran
`fable`/`high`, `claude-opus-5-5`/`high` and `claude-opus-5-5`/`xhigh` on 40
routing briefs and 8 handoff reviews with planted defects, three times each
(1 Oct 2026). All three routed 95% of briefs to the right tier, missing the
same two the same way, and all three caught every planted defect. Fable
cost 2.8× as much per call. `xhigh` added one false alarm and nothing else.
`jarvis usage` reports Jarvis's real cost per turn by model, so the offline
result can be checked against real sessions.

---

## 1. The test that picks the tier

> **Can the brief state what "done" looks like and how to verify it?**

- **No** — the worker has to decide what done means: it's choosing the shape
  of a subsystem, a schema, a prompt strategy; the spec is ambiguous or
  self-contradictory; the cause of the bug is unknown; a wrong call is
  expensive and won't show up in tests. → **Top tier**: Codex `gpt-6-astra`,
  or `fable` if the user authorized it for this brief.
- **Yes, and the work is still substantial** — the hard thinking is in the
  brief, not the task: build this endpoint the way the others are built,
  integrate this documented API, write the tests for this module, fix this
  bug with a known repro, hit this measurable performance target. →
  **Workhorse tier.**
- **Yes, and it's small** — a scoped tweak, docs, an audit, a summary. →
  **Light tier.**
- **Yes, and it's mechanical** — rename, reformat, move, one-liner. →
  **Trivial tier.**

Being *large* doesn't make a task top-tier; being *undecided* does. A
two-day feature with a clear spec is workhorse work. A fifty-line change to
how saves get classified is top-tier work.

## 2. Claude Code tiers

| Tier | `--model` | `--effort` | Send it |
| --- | --- | --- | --- |
| Top | `fable`, **only with `jarvis fable allow`** (2b). Otherwise this row is Codex `gpt-6-astra` (3). | `high` (`xhigh` when the task is both undecided and large) | New subsystems designed from scratch · data model / schema design · the classification & LLM pipeline, prompt and eval design · cross-cutting refactors touching many files at once · debugging where the cause is unknown · security-sensitive logic · briefs whose spec is ambiguous or contested · anything Jarvis can't cheaply verify afterwards |
| Workhorse | `claude-opus-5-5` (alias `opus`) | `high`; `medium` when the brief is tightly fenced | Well-specified feature work, however big: a new command or endpoint following an existing pattern · integrating a documented API · test suites · a migration with a known shape · a bug with a known repro · performance work with a target number · a second pass on something a top-tier worker already designed |
| Light | `sonnet` | `medium` | Scoped tweaks, docs, reading and auditing, summarising diffs. Also Jarvis's own read-only subagents. |
| Trivial | `haiku` | `low` | Renames, formatting, moving files, one-line fixes — but these are OpenCode's default slice; use `haiku` when OpenCode isn't configured or the task touches anything sensitive. |

`opus` at `high` is the right default for the majority of briefs, and the
tier Jarvis reaches for unless the task genuinely fails the test above. A
task that fails it goes to Codex `gpt-6-astra`, not to `fable`. A brief that
came back with questions is not a reason to go up a tier: answer it and let
the same worker finish, or sharpen the brief and respawn at the same tier.

**The workhorse model is Claude Opus 5.5, pinned.** Spawn it as
`--model claude-opus-5-5`, not the `opus` alias. The alias resolves to the
same model on Claude Code 2.1.282 and later, but a pinned id is one thing
fewer to wonder about when a handoff looks off. Everywhere else in these docs
`opus` is shorthand for that id. What matters about Opus 5.5 for routing:

- It is cheaper than Opus 5 per token ($4 / $20 per MTok, cache reads $0.20)
  and cheaper again per finished task — at `medium` it matched or beat
  Opus 5 at `high` on agentic coding with roughly half the tokens, and it
  catches more in code review with fewer false alarms.
- Thinking is always on and can't be disabled, so `--effort` is the only
  cost lever. Pass it explicitly: the API default is `medium`, one level
  below Opus 5's. `high` stays the tier default; use `medium` for a workhorse
  brief that is small and tightly fenced.
- It reports its work in plainer language, which makes handoffs easier to
  review, and reads screenshots and charts accurately without extra tooling.

Jarvis itself runs on `claude-opus-5-5` at `high`. Its own calls are routing
and review, where Opus 5.5 matched Fable in the eval.

**Design/build split.** When a task is top-tier only because nobody has
decided the shape yet, consider splitting it: a short `gpt-6-astra` brief
that produces the decision (schema, interface, approach — written into the
handoff, no implementation), then an `opus` brief that builds it. Cheaper,
and the decision ends up on the record in `handoffs/merged/`.

## 2b. Fable: only when the user authorizes one brief

`fable` is the most expensive model on the account, and on a shared
5-hour window it is the one that ran it out. So the default is no. A Claude
worker runs on it only when the user allowed that brief, once:

```bash
handoffs/bin/jarvis fable allow handoffs/briefs/<file>.md   # the user, in their own terminal
```

`allow` prints the brief's title and checkout, and asks for its slug typed
back. It refuses from inside an agent session or without a real terminal, so
Jarvis can't run it. Jarvis can't authorize Fable for itself, and neither
can a worker.

- **One authorization, one spawn.** It names the brief's file and a hash of
  its text (the `started:` lines aside), so editing `model:` or the body
  voids it. It is used up by the spawn that launches the run, and expires
  after `JARVIS_FABLE_TTL_MIN` minutes (120). A respawn needs a new one.
- **Every alias counts.** Any model that names fable, in any case, with or
  without a `[1m]` suffix, on any worker agent, is Fable. `--force` doesn't
  pass the check. The red band refuses Fable even when authorized.
- **Amber allows it** when authorized. The caps still apply, and Fable
  counts against the Opus cap.
- **Superset** can't add a setting to one launch, so an authorized Fable
  worker there needs an agent config of its own: set
  `JARVIS_FABLE_SUPERSET_AGENT` in `jarvis.conf` (the steps are in the
  comments there). Unset, spawn refuses Fable on Superset. tmux and Ultron
  lift the block for that one launch.
- **The Claude Code side.** `jarvis fable backstop --apply` writes
  `availableModels: ["opus","sonnet","haiku"]` into the user-level
  `~/.claude/settings.json`, so Claude Code itself substitutes Opus for
  Fable, including for an Agent-tool `model:` override. It is user-level,
  so it also stops the user's own `/model fable`: the user decides. A
  PreToolUse hook (`jarvis hook pretool`) denies a Fable subagent and any
  edit that adds Fable to a settings allowlist. Spawn refuses when the
  environment or any settings file would route a worker to Fable.
- **The record.** Every allow, denial, use and revoke is a line in
  `~/.jarvis/fable/audit.log`. `jarvis fable list` shows pending and used
  authorizations and the log tail, `jarvis fable revoke <brief>` cancels one.
  `jarvis status` shows `fable: blocked (backstop on)`, or the command to turn
  the backstop on.

When Jarvis thinks a brief really needs Fable, it says so to the user in one
line, with the reason, and puts `gpt-6-astra` in the brief meanwhile. If
the user then runs `fable allow`, change `model:` to `fable` and spawn.

## 3. Codex tiers

Two kinds of task go to Codex **always**, whatever the Claude fleet is
doing, because Codex has the capability built in:

| Task | `--model` | `--effort` |
| --- | --- | --- |
| **Any image or media asset** — logos, icons, app-store or social images, doc screenshots, editing or resizing images | `gpt-6-astra` | `high` |
| **App testing that needs computer use** — clicking through a real UI, driving a desktop app, verifying a flow a human would click | `gpt-6-astra` | `high` |

Everything else stays on Claude Code until the fleet is busy or usage is
tight, except the top tier, which comes here without waiting for either
(Fable is off unless authorized). The same test above picks the Codex tier:

| Tier | `--model` | `--effort` | Send it |
| --- | --- | --- | --- |
| Top | `gpt-6-astra` | `high` (`xhigh` when undecided and large) | Every top-tier case unless the user authorized Fable: undecided shape, unknown cause, ambiguous spec, security-sensitive design, end-to-end work across code and tools. Also all media and computer-use work. |
| Workhorse | `gpt-5.6-sol` | `high` | The `opus` cases — well-specified substantial work — **and all security work** (audits, hardening, dependency and vulnerability review, threat modelling), which goes to Sol by preference even when the Claude fleet is free. |
| Light | `gpt-5.6-terra` | `medium` | Everyday scoped work, tests, docs. |
| Trivial | `gpt-5.6-luna` | `low` | Mechanical edits, and high-volume structured work (extraction, classification, transformation) where a good result is obvious. |

Codex's `max`/`ultra` reasoning modes exist but cost a lot of time; use
`xhigh` as the ceiling unless the user asks otherwise.

## 3b. OpenCode — the free tier

OpenCode runs free models (the list rotates: Union Alpha, Muse Spark,
Nemotron, Ling, MiMo and friends come and go). They cost **nothing against
your Claude or Codex quota**, which makes OpenCode the right first choice for
work that doesn't need a paid model — every small task it absorbs is quota
kept for the work that does.

They are also weaker, smaller-context, and less reliable in long agentic
loops. So OpenCode gets a narrow, well-fenced slice:

| Send it | Don't send it |
| --- | --- |
| Mechanical edits: renames, formatting, moving files, one-line fixes | Anything top-tier or workhorse — undecided shape, ambiguous spec, unknown cause |
| A single well-specified change in one or two files, with a pattern to copy | Work spanning many files, or needing a lot of the codebase in context |
| Tests for existing code where the assertions are obvious | Security work, migrations, dependency changes |
| Docs, comments, config tweaks, README updates | The classification / LLM pipeline, prompts, or anything defining product behaviour |
| Repetitive structured work with an obvious right answer | Anything touching real credentials, real user data, or anything you wouldn't send to a free third-party provider |

That last row matters and isn't about quality: free models are served by
whoever is providing them. Treat an OpenCode worker as an untrusted
destination for data. Fixtures and synthetic samples only.

### When OpenCode is the default, not the fallback

In the **green** band, light and trivial tier work goes to OpenCode *first*
when it passes the table above — not to `sonnet`/`haiku`. Preserving the
Claude pool for top and workhorse briefs is the point. In amber and red it
becomes more valuable still: OpenCode work is free, so the bands never push
work *away* from it.

The brief matters even more here than elsewhere. A weak model with a fuzzy
brief will wander through the repo, touch files it shouldn't, and hand back
something you have to unpick — in a shared checkout that costs you real time.
An OpenCode brief should name the exact files, give the exact pattern, and
fence the scope hard. If you can't fence it that tightly, it isn't an
OpenCode task.

### Spawning

`handoffs/bin/jarvis spawn` handles OpenCode like any worker: header
`worker: opencode`, and the prompt gets the extra fence ("touch only the
files it lists, never run git commands that change state"). Two mechanics
differ from Claude and Codex:

- **No effort.** `spawn` drops it for OpenCode. Superset's agents reject an
  explicit effort override, and the tmux launch line has no flag for it.
- **The model is uncertain.** Which ids OpenCode accepts depends on the
  providers configured on that machine, and the free model list rotates.
  Leave `model:` as a `<placeholder>` to use whatever the user has selected
  in OpenCode's own picker, or check `opencode models` once. Don't hardcode
  a free model name into a brief — it may be gone next week.

### Escalation: fail cheap, once

An OpenCode worker that stalls, loops, ignores the scope fence, or hands back
a handoff that fails checks gets **one** correction over `jarvis send`.
If the second attempt is still wrong, stop: `jarvis close` it, revert
nothing yourself (the worker's edits are uncommitted — have the worker leave
a `status: partial` handoff, or if it's incoherent, note the files it touched
and check them in the diff), and respawn on `sonnet`. Two failed rounds of
babysitting costs more of your context than the Claude tokens you saved.

Track this: if a kind of task keeps bouncing back from OpenCode, it belongs a
tier up, and say so in `OPEN.md` so future sessions don't retry it.

## 4. The usage ladder

Claude Code usage is shared across Jarvis and every Claude session on the
account, so the budget is one pool. `jarvis status` computes the **band**
and writes it into `handoffs/OPEN.md`. `jarvis spawn` enforces it. The
thresholds are in `handoffs/jarvis.conf`.

| Band | Routing and caps |
| --- | --- |
| **Green: under 50%, and not on pace to use the window** | The table above, unchanged. Light and trivial work still prefers OpenCode, because free work is free in every band. Caps: 4 machine-wide, 3 here, 2 Opus (section 5). |
| **Amber: 50% and over, burning fast, a reading that is missing or stale, or 7-day at 80%+** | Caps drop to **3 machine-wide and 2 Opus** (Jarvis counts). Fable stays unavailable unless authorized, as in every band. Light and trivial tiers are unchanged. Jarvis keeps its model. |
| **Red: 75% and over, about to run out, a usage-limit message in a worker, a failed Claude spawn, or 7-day at 95%+** | Caps drop to **2 machine-wide and no new Opus**. New top-tier and workhorse briefs go to **Codex** (`gpt-6-astra` / `gpt-5.6-sol`). Claude Code is kept for Jarvis and for workers already in flight. Fable is refused even when authorized. Anything OpenCode can safely take, it takes. Tell the user plainly that you've moved the fleet and why. |

The band fails closed. **No reading, an unreadable one, or one older than
`JARVIS_STALE_MIN` (30) minutes whose window hasn't reset reads as amber**,
and the explanation says "unknown" or "stale". A reading whose window has
since reset counts as green only when it is under 5 hours old. So a repo
whose statusline isn't wired up, or a machine nobody has used for a day, gets
the amber caps until a fresh reading arrives. Fix the cause (section below)
rather than writing the band in by hand.

**Burn rate.** The band also looks at how fast the 5-hour percentage is
rising. Over the last `JARVIS_BURN_MIN` (20) minutes, it is amber when that
pace would use the window up before it resets, or reaches `JARVIS_BURN_AMBER`
(15) points, and red when it would hit 100% within 30 minutes. `jarvis
band` shows it as `burning 18 pts/20 min (100% in 26 min)`.

### When a running worker's band got worse

Never kill a worker mid-edit: its work is uncommitted in the shared
checkout and would be lost. A band change doesn't touch running workers. If
the caps are now exceeded, new spawns wait. If the user wants a running
worker moved to a cheaper tier (and in the rare case of a running authorized
`fable` worker):

1. `jarvis send` it: *"Usage band changed. Finish the phase you're on, write a `status: partial` handoff with the exact file list and what's left, then stop."*
2. When the handoff appears, review and commit what's done as normal.
3. `jarvis close` the terminal (merge closes it for you unless you passed `--keep-open`).
4. Change the brief header to the cheaper `model:` and note why
   (`model: claude-opus-5-5 (usage band; was fable)`). Then respawn from the
   **same brief**, naming the partial handoff so the new worker picks up
   where the old one stopped:

```bash
handoffs/bin/jarvis spawn handoffs/briefs/<file>.md --after handoffs/merged/<partial>.md
```

The respawn must not name `fable` again: the old authorization was used up,
and the user didn't give a new one. A worker already near the end of its last
phase is worth letting finish instead. Switching costs a handoff cycle.

### How Jarvis reads usage

No host reports Claude usage (there is no `superset usage`). Claude Code itself hands its
statusline the account's rate-limit numbers: 5-hour and 7-day percentages
and when each resets. The statusline is `jarvis statusline`, a tap that
saves those numbers machine-wide to `~/.jarvis/usage.json` (and a copy under
`handoffs/.jarvis/`), appends one line a minute to `~/.jarvis/usage.hist`
for the burn rate, and then runs the user's own statusline unchanged. Every
Claude session whose repo has the tap refreshes the reading, workers
included, since they all spend from one account. **A repo without the tap
contributes nothing**, so wire it into at least the repo Jarvis runs in.

- **`jarvis band` / `jarvis status`** compute the band from that reading:
  the percentage, how far into the window you are, the pace (the percentage
  projected to the end of the window) and the burn rate.
- **No reading** (`band: amber unknown band…`): the tap hasn't run yet.
  Check the statusline setup (`jarvis:setup`). The caps stay at amber
  meanwhile, and writing a band into `OPEN.md` doesn't change that: spawn
  reads the reading, not `OPEN.md`.
- **Worker terminals**: `jarvis read` shows a usage-limit or rate-limit
  message when one is hit. One of those means Red for that fleet regardless
  of what the percentage said.
- **A failed spawn** (`jarvis spawn` of a Claude brief fails at the host) is
  also Red.
- **The user** may just tell you ("I'm at 60%"). Take it for your own
  routing choices and record it. Spawn's caps still follow the reading.

`jarvis status` writes the band and the time into `OPEN.md`
(`Usage band: amber (5h 58% used, 14:20)`). A band computed from real
readings can loosen as the window rolls on. That's correct: it reflects the
actual pace.

## 5. The Claude caps (separate from usage)

`jarvis spawn` refuses a Claude worker that would put the machine past any of
three caps (`handoffs/jarvis.conf`):

| Cap | Green | Amber | Red | Setting |
| --- | --- | --- | --- | --- |
| Active Claude sessions, **machine-wide**, every repo and the user's own included | 4 | 3 | 2 | `JARVIS_MAX_CLAUDE_GLOBAL` |
| Sessions in **this checkout**, Jarvis included | 3 | 3 | 3 | `JARVIS_MAX_CLAUDE` |
| Sessions **on Opus** (Fable and a model that can't be told count too) | 2 | 2 | 0 | `JARVIS_MAX_OPUS` |

The amber and red values are `JARVIS_AMBER_GLOBAL`, `JARVIS_AMBER_OPUS`,
`JARVIS_RED_GLOBAL` and `JARVIS_RED_OPUS`.

A session counts while it is busy or was active in the last
`JARVIS_ACTIVE_MIN` (10) minutes. This checkout's Jarvis and running workers
always count. A session idle for hours burns nothing and doesn't. A spawn
holds its slot for up to `JARVIS_PENDING_SEC` (180) while its session
starts, and the count and claim happen under a machine-wide lease, so two
repos spawning at once can't both take the last slot. A band never raises a
cap the conf set lower. Codex and OpenCode workers don't count.

`handoffs/bin/jarvis sessions` lists the sessions that count (pid, why,
model, project), the Jarvis and worker count from `OPEN.md`, and any idle
session open more than 8 hours, which the user may want to close.
`jarvis status` shows the same summary in one line. **Jarvis never stops a
session it didn't spawn**, and never stops one to make room.

The cap is about the 5-hour window, not about any one task. Eleven sessions
at once is how a window ran out in two and a half hours. At a cap, the
refusal names the cap, its count and limit, and each session that holds a
slot. The next brief either waits under **To-do**, or goes to the agent
whose test it passes: OpenCode for fenced light or mechanical work, Codex
for the rest (security first), or `model: sonnet` when it is the Opus cap.
Don't kill running workers, and don't `--force` past a cap to go faster.
`--force` does pass all three caps, never Fable, and writes a `cap-force`
line to `handoffs/.jarvis/audit.log`: use it only when the user told you to
spend, and say so. A failed spawn also means the fleet is busy, and for
Claude it means red.

## 6. If a model id is rejected

The host validates `--model` before launching and its error names every id
that agent accepts. Pick the same tier from that list (newest flagship →
Top; the balanced one → Workhorse; the cheap one → Light/Trivial) and, if it
recurs, update the table in `CLAUDE.md` so future sessions don't hit it. If
the pinned `claude-opus-5-5` is what gets rejected, the `opus` alias tracks
the newest Opus release and is the fallback.

## 7. The shadow classifier

Where the repo has `handoffs/bin/jev.sh`, `jev.sh brief <file>` also logs a
tier of its own beside yours. It has **no authority**: it never prints its
verdict, and nothing in this file changes because of it. It exists to find
out, over thirty-odd briefs with recorded outcomes, whether a cheap classifier
agrees with you and whether it's right when it doesn't. The rule for what
happens then is in `references/jev.md`.

## 8. Writing it down

Every brief header carries `worker:`, `model:`, `effort:` — and, when the
band or a cap changed the choice, a note (`model: claude-opus-5-5 (Opus cap
full; was sonnet)`). That way a re-spawn is a copy of one line, and the
record shows why. A top-tier brief names `gpt-6-astra` unless the user
authorized Fable for it.
