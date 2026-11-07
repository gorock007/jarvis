# Lessons replay (m5)

Held-out test of m2 §6, simplified: do lessons generated from earlier merges help an Opus reviewer catch
defects that Jarvis's own reviews once missed? Ten commits (8 with known misses = 12 atomic labels, 2 clean
controls), three repetitions per arm, 60 isolated reviews, pass bar frozen before any result.

Not run by CI. A run spends money (estimate in the handoff); `prepare.py --dry-run` spends nothing.

## Files

| File | What |
| --- | --- |
| `labels.json` | the 12 labels (mechanism, file, what a catch must say), written before any model call |
| `prompts/reviewer.txt` | m2 §6 reviewer prompt, verbatim, as the system prompt |
| `prepare.py` | builds one throwaway repo per target from sources dated before that commit, runs the real `jarvis-lessons.py propose` then `apply` unchanged, stages the target's paths, runs the real `select`, writes the packets |
| `cases.json` | the freeze: full commit ids, source counts, hashes of packets and lessons |
| `fixtures/<commit>/` | `packet.baseline.txt`, `packet.treatment.txt` (identical bytes except the lessons section), `LESSONS.md`, `select.txt`, `paths.txt`, run record |
| `run.sh` | the 60 reviewer calls, one at a time, resumable |
| `prepare.py --blind` | `results/blind.md` (outputs under random ids, arms hidden), `results/key.json`, `results/annotations.template.json` |
| `score.py` | `--check` validates everything; without it, applies the pass bar to `results/annotations.json` |

## Run order

```
python3 -I prepare.py --dry-run --work <scratch dir>   # estimate; stop if over $20
python3 -I prepare.py --work <scratch dir>             # lessons (Sonnet) + freeze
./run.sh                                               # 60 Opus reviews
python3 -I prepare.py --blind
python3 -I score.py --check
# Jarvis: fill results/annotations.json from blind.md, then
python3 -I score.py
```

## Design as built

- **Sources per target C**: merged handoffs whose filename time (Australia/Sydney) is before C's commit time,
  Jev outcome rows and shadow-review rows with their own UTC timestamp before it, and security bullets from
  `handoffs/log/2026-11.md` dated before it (a date with no time counts as the end of that day). C's own
  handoff, brief, outcome and review rows, the m2 design handoff and anything from 2026-11-07 21:00 on are out.
  Prepare stops if an eligible source names the target's commit or brief.
- **Lessons**: the production collector takes the latest 10 eligible handoffs and the logs that fit its bundle cap;
  one Sonnet 5.5 pass; `apply` unchanged. A failed proposal means empty lessons for that target (recorded in
  `fixtures/<commit>/lessons-run.json`). No `LESSONS.md` exists at the start, which is an empty accepted file.
- **Selection**: generation runs in a history-only repo; only afterwards do the target's changed paths appear
  there as empty files, so production `select` does not drop scoped entries for lack of paths. Treatment gets
  exactly `select --audience review` output (cap 6 entries / 3 KB).
- **Packet**: historical `run/SKILL.md` and `references/handoffs.md` from C^, the brief and handoff, and the full
  `git diff C^ C`; whole files at C only for c8f8e5d (the script whose exit status the doc states) and
  1131ecd (`bin/jarvis`, `lib/lock.sh`, `lib/defaults.sh`, the lock helper). Session ids and home paths are replaced.
- **Reviewer**: `claude-opus-5-5`, high effort, empty working directory, no settings/MCP/tools/slash commands,
  no session persistence, one turn, `--json-schema` output, `--max-budget-usd` 0.50 (raised per fixture only when
  the frozen estimate is higher; see `results/order.tsv`). Prompt caching is left on, which only lowers cost.
- **Order**: fixtures chronological; repetition 1 and 3 run baseline first, 2 treatment first.

## Caveats

- `handoffs/` is git-ignored, so history is not provable from git. The current `handoffs/merged/` copies, the shadow
  review log, the Jev log and `handoffs/log/2026-11.md` stand in as the historical record (handoffs are not edited
  after merge). The old OPEN.md is not available; its security bullets are absent.
- Packets are the diff plus policy, brief and handoff, which is what Jarvis really reviews, not curated excerpts, so a defect whose
  evidence lies outside the diff (351ab83's real-screen provenance, 3b1ab75's forgeable records) is harder to see in
  both arms. 351ab83's label is unverified; totals are reported with and without it.
- Three repetitions on the same ten commits are not ten independent trials. A pass supports "no worse and perhaps
  better on this repository", not generalisation.
- The 2026-11-06 model-test bullet (it lists the earlier targets' misses) is dated before 1131ecd and is part of that
  target's history; it is excluded for every earlier target.
