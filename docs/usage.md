# Usage-aware spending

Jarvis and every Claude session draw from the same usage limit, so Jarvis
tracks a **band** and records it in `OPEN.md`. The band sets how many Claude
sessions may run:

| Band | Trigger | Caps (machine-wide · Opus workers, Jarvis not counted) | What changes |
| --- | --- | --- | --- |
| 🟢 Green | under 50%, and not on pace to run out | 4 · 2 | The routing table as written |
| 🟡 Amber | 50%+, burning fast (on pace to use the whole 5-hour window before it resets, or 15+ points in 20 minutes), a 7-day reading at 80%+, or no reading or a stale one | 3 · 2 | New Claude work waits sooner. Running workers are untouched. |
| 🔴 Red | 75%+, about to hit 100% within 30 minutes, a 7-day reading at 95%+, a usage-limit message, or a failed start | 2 · 0 | New top- and workhorse-tier briefs go to Codex. Claude is kept for Jarvis and workers already running. |

The numbers come from Claude Code itself. The repo's statusline is a small
tap that saves the 5-hour and 7-day readings machine-wide, in
`~/.jarvis/usage.json`, and then runs your own statusline unchanged. One
reading serves every repo, because the limit belongs to the account. **The
band fails closed**: with no reading, or one older than 30 minutes whose
window hasn't reset, it reads amber, so a repo with no statusline tap, or a
machine nobody has used for a day, gets the lower caps instead of free
rein. `jarvis status` turns the reading into a band, and `jarvis spawn`
enforces it. Running agents in parallel doesn't make any single task more
expensive, but it squeezes a day's spend into one window. That's why the
band watches the burn rate as well as the total. Jarvis doesn't change its
own model mid-session. It sends work elsewhere, so the remaining budget goes
to coordination.

**`jarvis usage` says what it cost, with labels.** It prices your local
transcripts at API list prices and says so: an **API-equivalent estimate, not
your subscription usage**. The real subscription numbers (5-hour and 7-day)
are printed on their own line, with the age of the reading. It shows the top
workers and briefs by cost, with attempts, context growth and outcome, and
waste signals: abandoned runs, briefs run more than once, workers with many
failed test runs, sessions left open for hours, and the share of worker cost
spent above 150k of context. `--all-projects` covers every repo on the
machine.

`jarvis usage` selects the same subscription reading as `jarvis band`: the
machine-wide file (`JARVIS_HOME/usage.json`, default `~/.jarvis/usage.json`),
falling back to `handoffs/.jarvis/usage.json` when that file is missing or empty.
For this repo's merged-handoff count, Git history remains authoritative for
tracked files. Ignored, untracked Markdown files in `handoffs/merged/` also
count when their modification times fall within the report window; the report
labels this approximate portion. Editing or copying those files can change
that estimate. Run records are not counted because several attempts can lead
to one handoff. Wake-ups come from `handoffs/.jarvis/watch.log`; a missing log
means no recorded events, not that no watcher is running. Older watchers may
need restarting after an upgrade before they write events; quiet ticks do
not create a log.

## Lessons pass

`jarvis lessons propose` makes one isolated call to Sonnet 5.5 (no tools, no
prompt caching, a bundle of up to 160 KB of merged handoffs and review
evidence) and costs roughly $0.2–0.4 API-equivalent per pass. `status`, `show` and `select` call no model, and `propose` is
refused in the red band. Run it when `jarvis status` says 10 or more handoffs
are waiting.

## Token efficiency

Version 0.3 came out of measuring where Jarvis's usage actually went, over
12 days of real transcripts. The coordinator cost more than the workers it
coordinated ($251 against $222 at API prices). Most of that went on waiting
and checking, not on deciding. Each measured cause now has a mechanism
behind it, not just advice:

| Measured cause | Mechanism |
| --- | --- |
| 18 turns (2%) that reloaded an idle coordinator's whole context cost 31% of its spend | `jarvis watch` clears Jarvis after a long idle before waking it, and a prompt guard stops your first message after one |
| Routine check-ins were 46% of coordinator spend, at ~$0.25 each | `jarvis status`, `spawn` and `merge` turn many turns into one call |
| A security-review hook ran after every stop of every worker: 116 runs, $71 | Per-stop review off, one review per merge commit, on Sonnet |
| Built-in subagents inherited Opus and Fable: $59 | `CLAUDE_CODE_SUBAGENT_MODEL=sonnet` in the repo's settings |
| Workers carried whole jobs to 350–420k context | One brief per phase, a shorter `CLAUDE.md`, unused plugins off |
| 11 sessions at once used up the 5-hour window in 2.5 hours | A cap on Claude sessions, and a band that watches the burn rate |

`handoffs/bin/jarvis usage` reports the numbers that show whether this
worked: coordinating ÷ building (1.13 when first measured, 0.37 in the
[November 2026 baseline](benchmarks/2026-11-baseline.md), target ≤ 0.3),
cost per merged handoff, and the worst 5-hour window. Details are in
[`efficiency.md`](../plugins/jarvis/skills/run/references/efficiency.md).
