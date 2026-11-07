# Briefs and handoffs

Both live in `handoffs/` at the repo root, which is tracked in git: it is the
project's memory. Jarvis moves a reviewed handoff into `handoffs/merged/` in
the same commit as the feature.

## Brief — Jarvis → worker

`handoffs/briefs/YYYY-MM-DD-HHMM-<slug>.md`, from `handoffs/briefs/TEMPLATE.md`.

Header: `worker`, `model`, `effort`, an optional `budget:` line, `started`,
`terminal` (`jarvis spawn` fills the last two). When a cap or the band changed the model
choice, say so in the header (`model: claude-opus-5-5 (Opus cap full; was sonnet)`), so a
later re-spawn knows why. A re-spawn never goes up to `fable` by itself: that
takes the user's `jarvis fable allow <brief>`. `budget:` overrides the worker
budget for this brief (`budget: min=120 usd=25 ctx=350k tests=8 attempts=3`,
see `references/lifecycle.md`). Body: **Goal** (verifiable), **Context** (decisions already made,
files to read, prior handoffs), **Scope** (may / must-not / shared files),
**Phase**, **Checks**, and the ask-once instruction.

**One brief per phase.** A multi-phase job is a chain of briefs. Each one
is spawned after the previous handoff is merged, with
`jarvis spawn <brief> --after handoffs/merged/<previous>.md`, so each worker
starts fresh from a written handoff. It doesn't drag the earlier phases'
context along.

Good briefs are disjoint: no two running briefs list the same "may touch"
file. If they must overlap, name the shared file in both and tell the second
worker to read the first's handoff before editing it.

**The `- May touch:` row** is what `jarvis spawn` compares with every running
worker's (`references/lifecycle.md`). Write it as paths only:

```markdown
- May touch: `src/parse.py`, `src/lib/` (new helpers go here), `test/test_*.py`
```

- Comma-separated. Each path is bare or in backticks (backticks allow spaces).
- A trailing `/` is a folder and covers everything under it. A bare path
  without one is a file, unless that folder already exists or another
  entry's path runs through it (`src/new` and `src/new/*.ts` overlap).
- Globs: `*`, `?` and `[…]` within a name, `**` as a whole name. `[^…]`
  negates like `[!…]`.
- `none` means the brief edits nothing.
- A note goes in parentheses after its path. Prose around a path ("in
  `jarvis`: `watch_tick`, …") makes the scope unknown, which spawn treats as
  overlapping. So do braces, `$`, absolute paths and `..`, and `!` outside
  a `[…]` class.

**Checks `merge --check --verify` can run** go in fenced blocks under
`## Checks`. Only these run; prose and inline backticks around them are for
the reviewer:

````markdown
```bash verify class=light timeout=300
bash -n src/tool.sh
```

```bash verify class=suite timeout=1200 reuse=never
npm ci && npm test 2>&1 | tail -40
```

```json verify-inputs
{"requires":["test/fixtures/sample.json"],"copy":[],"dependencies":[]}
```
````

- `class=` and `timeout=` (seconds, at most `JARVIS_VERIFY_MAX_SEC`) are
  required. `light` runs at once. Any other class runs under that class's
  `jarvis lock` lease of the checkout, and its timer starts once the lease is
  held. A heavy check marked `light` is a brief defect.
- `reuse=never` keeps `--reuse` from reporting an earlier pass, for checks
  that install things or depend on a network service.
- Each block runs in a fresh `bash -e -o pipefail` at the worktree root, in
  order, stopping at the first failure. A `cd` lasts for its own block only.
- `verify-inputs` (one at most) lists what the checks need besides the
  source: `requires`, paths that must exist; `copy`, ignored or untracked
  files to copy in; `dependencies`, e.g.
  `{"path":"node_modules","kind":"node","lockfiles":["package-lock.json"],"manifests":["package.json"]}`.
  A virtualenv is never copied: create it in a first block.

## Handoff — worker → Jarvis

`handoffs/YYYY-MM-DD-HHMM-<slug>.md`, from `handoffs/TEMPLATE.md`.

```markdown
# <one-line task title>
status: done | blocked | partial
agent: claude <model> | codex <model>
brief: handoffs/briefs/<file>.md
## What the user asked
## What changed
## Files
- path — created | modified | deleted
## Checks run
## Questions for the user
## Notes for Jarvis
```

- `blocked` means: questions in **Questions for the user**, nothing built yet.
  Jarvis batches them; the worker keeps its terminal open and waits for
  `jarvis send`.
- `partial` means: some phases done, something stopped it. The **Files** list
  is still exact for what was touched. It is also the checkpoint a worker
  writes when it gets a `[jarvis] Budget reached` message. The next worker
  starts from it with `--after`, and the brief needs sharpening or splitting
  first (the respawn gate asks for that).
- A worker that gets more instructions for the same task updates the same
  handoff file — Jarvis never has two handoffs for one brief.

## Reviewing a handoff (Jarvis)

1. **File list vs reality.** `jarvis merge <handoff> --check` compares the
   list against `git status` and prints the diff stat. Every listed path
   must be changed. Anything unlisted that obviously belongs to this task
   goes back to the worker. This is the single most important check, because
   Jarvis commits by the list.
2. **Diff.** `git diff -- <listed files>` (first
   `jarvis lessons select --audience review --paths-from <file list>`); big
   diffs go to a Sonnet subagent for a summary. Look for edits to shared files that weren't named.
3. **Checks.** If **Checks run** is thin or says "not run", run them: the
   targeted ones here; heavy suites belong to the merge gate, under the lock
   (`references/lifecycle.md`). When the brief has `bash verify` blocks,
   `jarvis merge <handoff> --check --verify` runs them on HEAD plus only the
   listed changes, so another worker's edits can't make them pass or fail.
4. **Notes for Jarvis.** Do the Jarvis-only items (migration, release,
   lockfile). Note anything deferred in `OPEN.md`.
5. **Merge.** `jarvis merge <handoff> -m "<msg>" --outcome <o>` commits the
   listed files, the handoff move, the brief and `OPEN.md` in one commit,
   with a `Co-Authored-By` trailer for the worker. It pushes, closes the
   worker terminal and drops its `OPEN.md` lines.

## OPEN.md

One file, four lists: **Questions for the user**, **Running workers**,
**Waiting on Jarvis**, **To-do**. At the top are the current Jarvis terminal
id (`jarvis start`) and the usage band (`jarvis status`). `jarvis spawn`
and `jarvis merge` maintain **Running workers**. Jarvis can be `/clear`ed
between batches, so this file must always hold what a fresh session needs. Every state change above is a one-line edit here.
It holds only what's open: finished notes, session logs and "landed" records
go to `jarvis log "<text>"` (`handoffs/log/YYYY-MM.md`, committed by merge,
read by nothing at start). `jarvis status` prints its size and flags it over
`JARVIS_OPEN_MAX_KB` (16), an extra `## ` section, to-do lines over 300
characters, and lines naming a brief or handoff already merged. Jarvis never
reconstructs state by scanning folders or terminals; if `OPEN.md` is wrong,
fix `OPEN.md`.
