# Team mode: several people, one Jarvis each

Use it when more than one person works in the same repo and each runs their
own Jarvis, in their own clone. Each Jarvis keeps its own notes file, and a
contributor's Jarvis commits only on a branch. Without a local conf nothing
changes: `handoffs/OPEN.md`, the merge and the push work as they always have.

One checkout still has one Jarvis. Team mode is for separate clones of one
repo, not for two people sharing a working copy.

## The local conf

`handoffs/jarvis.local.conf` is one person's own settings. It is plain shell,
like `handoffs/jarvis.conf`, and `bin/jarvis` sources it right after that
file, so any key set here also overrides the shared conf for this person.
Keep it out of git: add `handoffs/jarvis.local.conf` to `.gitignore`.

```sh
JARVIS_OWNER=alice          # notes in handoffs/OPEN.alice.md
JARVIS_ROLE=contributor     # lead (the default) or contributor
# JARVIS_OPEN=handoffs/OPEN-alice.md   # any notes path, relative to the repo root; beats JARVIS_OWNER
```

- **`JARVIS_OWNER`**: letters, digits, `.`, `_` or `-`, not starting with
  `.`. The notes file becomes `handoffs/OPEN.<owner>.md`, `jarvis log` writes
  `handoffs/log/YYYY-MM.<owner>.md` (merge commits that file, not the shared
  `YYYY-MM.md`), and a contributor's "start a branch" hint uses the name.
- **`JARVIS_OPEN`**: the notes file outright, relative to the repo root.
- **`JARVIS_ROLE`**: `lead` or `contributor`. This is the team role. It
  doesn't touch the `JARVIS_ROLE=worker` that spawn gives a worker's hooks.
  Any other value stops `jarvis merge` until it's fixed.

`handoffs/.jarvis/local.conf`, where an early hand patch kept these keys, is
still read, after `handoffs/jarvis.local.conf`, so its values win.

With a local conf, `jarvis start` and `jarvis status` print one line first:

```
role: contributor · branch: alice/login · notes: handoffs/OPEN.alice.md
```

If the notes file isn't there yet, `jarvis start` makes it with the usual
headings (`made handoffs/OPEN.alice.md`). Every message that names the
notes file (status, the cap refusal, the merge line, the watcher's
fresh-session wake, the idle guard) uses the file's real name. The watcher
and status never take `OPEN.md`, `OPEN.*.md` or `OPEN-*.md` for a handoff.

## Every merge catches up first

This applies to every role. When `jarvis merge` will push (`JARVIS_PUSH=1`
and no `--no-push`), a remote is set and the branch has an upstream, merge
runs `git fetch` first. If the upstream has commits HEAD lacks, it
fast-forwards to them with `git merge --ff-only @{u}` and says
`merge: fast-forwarded N commit(s) from origin/main first`. Then it commits
on top and pushes. It never stashes and never makes a merge commit.

If it can't fast-forward (your branch has diverged, or a teammate's commit
touches a file you have uncommitted changes in), it stops before moving
anything:

```
jarvis: origin has commits this checkout can't fast-forward to (1 on origin/main): merge or wait for the overlapping handoff, then git merge --ff-only @{u} (nothing merged)
```

A failed fetch (offline, say) doesn't stop the merge. It prints
`merge: git fetch failed, so not caught up with origin/main first` and goes
on, and the push will say if it was refused.

## The contributor loop

A contributor's `jarvis merge` refuses the default branch: origin/HEAD's
target, else `main`, else `master`. It refuses a detached HEAD too, since
`git push -u origin HEAD` can't push one. `--check` still runs anywhere.

```
jarvis: contributor Jarvis: never commit on main. Start a branch first: git switch -c alice/<topic> origin/main
jarvis: contributor Jarvis: HEAD is detached. Start a branch first: git switch -c alice/<topic> origin/main
```

1. Start a branch from the shared one: `git switch -c alice/<topic> origin/main`.
2. Brief, spawn and merge as usual. Each merge commits on the branch and
   pushes it with `git push -u origin HEAD`. The merge line says
   `pushed alice/<topic>`.
3. Open a PR for the branch. A lead, or the repo's own review, lands it.
4. When it has landed, start the next topic the same way.

Your notes file is committed with each merge, so it is on your branch until
that branch lands. On a branch without it, `jarvis start` makes a fresh one.
To carry it over, run `git checkout alice/<old-topic> -- handoffs/OPEN.alice.md`.

A lead commits wherever it stands, the default branch included, and pushes
with plain `git push`, as Jarvis always has.

## What's shared and what isn't

Committed, so everyone has it: briefs, handoffs (once merged, under
`handoffs/merged/`), each person's notes file and `jarvis log` month file
(`handoffs/log/YYYY-MM.<owner>.md`), `JARVIS.md`, `jarvis.conf`.

Never shared:

- `handoffs/jarvis.local.conf`: per person, git-ignored.
- `handoffs/.jarvis/`: run records, watcher state, sessions, budgets and the
  audit log, all for this clone only (git-ignored as always).
- The usage band and the machine-wide Claude caps belong to each person's own
  machine and Claude account.
- Teammates' notes files: each Jarvis edits only its own. When the caps tell
  a repo's Jarvis from its workers, they read the `Jarvis session:` line of
  every `handoffs/OPEN*.md` in that checkout, so a Jarvis recorded in any of
  them counts as Jarvis.

Each person's notes file and log file are theirs alone, so a teammate's
pushed notes or log lines never collide with yours at the catch-up. Without
`JARVIS_OWNER` (only `JARVIS_OPEN`), `jarvis log` still writes the shared
`handoffs/log/YYYY-MM.md`.
