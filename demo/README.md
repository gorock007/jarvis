# demo

`record.sh` records one real, unattended Jarvis run on tmux, as raw footage for the
60–90 s demo (plan Phase 5). It builds a throwaway toy repo (`splitbill`, a bill splitter)
in `/tmp/jarvis-demo-XXXX`, sets it up as `jarvis:setup` would from this checkout's
template, and starts Jarvis there with `claude --plugin-dir` on a copy of `plugins/jarvis`.
The script then types one request and later the user's answer. Jarvis spawns two workers,
passes on a worker's question, and merges both handoffs.

```bash
bash demo/record.sh               # real run: Opus Jarvis + two workers, about 15–30 min
DEMO_DRY=1 bash demo/record.sh    # fake Jarvis and workers: no model, about 1 min
```

**Before a real run:** Jarvis and its workers run with `--permission-mode bypassPermissions` under your
own HOME (the same mode workers always use), on fixed scripted input in the throwaway `/tmp` repo.
`DEMO_DRY=1` runs no model at all.

Needs tmux, git, jq, perl, python3, asciinema, agg and ffmpeg (`brew install asciinema agg`).
Knobs: `DEMO_LIMIT_MIN`, `DEMO_OUT`, `DEMO_KEEP=1`, `DEMO_RENDER=0`.

It writes to `~/Movies/jarvis-demo/raw/<stamp>/`, never into the repo:

- `<window>.cast` and `<window>.mp4`: one recording per tmux window (`jarvis`,
  `jarvis-watch`, each worker), 80×30 plus tmux's status row. Stack two for 9:16, tile them for 16:9.
- `beats.json`: the four beats, plus each recording's start and end, in seconds from the start of `jarvis.cast`.
- `commits.txt`: the toy repo's `git log --oneline`. Also: `events.tsv`, `toy-handoffs/`,
  `toy-diff.patch`, `jarvis-final-screen.txt`.

Its own tmux server and every process under it stop when the script exits.
