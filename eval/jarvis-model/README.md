# Which model should Jarvis run on?

Jarvis coordinates. It routes briefs, reviews handoffs and decides what to
commit. It ran on `fable`/`high` until the usage evaluation found that a
Fable coordinator turn costs about twice an Opus 5.5 turn. This folder
measures whether the cheaper configs coordinate as well. It compares three
(the result is below: Jarvis moved to `opus55-high`):

| config | `--model` | `--effort` |
| --- | --- | --- |
| `fable-high` | `fable` (Claude Fable 5.1) | `high` |
| `opus55-high` | `claude-opus-5-5` | `high` |
| `opus55-xhigh` | `claude-opus-5-5` | `xhigh` |

The evaluation has two halves. First, an offline eval on fixed fixtures,
which is cheap and repeatable. Then an in-situ comparison on real work.

## Offline: the fixtures

**Routing (40 fixtures).** These are the briefs in `eval/briefs/`, labelled
in `eval/labels.json`. The header (worker/model/effort) is stripped the same
way `jev.sh` strips it. The candidate gets `model-routing.md` as its routing
guide and answers `{tier, agent, model, effort, reason}`. Scoring:

- tier exact, or in the label's `accept` set
- **too low**, the costly miss: a failed worker and a respawn
- too high, which only costs tokens
- agent rules: media and computer-use work goes to Codex `gpt-6-astra`,
  security work to `gpt-5.6-sol`, and OpenCode only for light or trivial work
  with no real secrets

**Review (8 fixtures, `review/`).** Each fixture holds a brief, the worker's
handoff, `git status --porcelain` and the diff. The candidate reviews it
under the jarvis:run review rules, `handoffs.md`, the AGENTS.md worker rules
and the diff-reviewer rubric. It answers `{verdict, findings[]}`.

| fixture | planted problem | right verdict |
| --- | --- | --- |
| 01-missing-file | new helper `cli/_dates.py` not in the handoff's file list | send back |
| 02-unlisted-shared-edit | shared `tokens.ts` edited, not named in the handoff | send back |
| 03-out-of-scope | edit in `billing/payments/`, which the brief fenced off | send back |
| 04-logic-bug | 1-based page sliced as `page*size`; the tests only check lengths | send back |
| 05-untrue-checks | "tests look good", no commands; the only new test is skipped | send back |
| 06-git-violation | worker ran `git checkout -- web/package.json`, wiping another worker's edit | either, but the finding is required |
| 07-clean-docstrings | none | commit |
| 08-clean-rename-with-neighbour | none; another worker's files are dirty in `git status` | commit |

Scoring counts verdict accuracy and defect recall. A finding counts as a
match when its kind and file both match. False alarms are blocking findings
on the two clean fixtures. `nit` findings don't count against a candidate.

Each call runs `claude -p` in an empty temp directory with
`--setting-sources "" --strict-mcp-config --disable-slash-commands --tools ""
--no-session-persistence`. It loads no user settings, skills, MCP servers or
tools, so all three configs carry the same ~6.6k-token fixed overhead. The
reference text is read live from `plugins/jarvis/skills/`, and each record
stores a hash of its prompt and system prompt. A plugin change therefore
shows up as a different hash, not as a silent difference in results.

## Run it

```bash
eval/jarvis-model/run.sh --dry-run                    # what would run, the first prompt; free
eval/jarvis-model/run.sh --limit 2 --tasks routing    # a small slice
eval/jarvis-model/run.sh --repeat 3 --out eval/jarvis-model/results/full   # the real thing
python3 eval/jarvis-model/score.py eval/jarvis-model/results/full --detail
```

Runs resume. A record that already exists in `--out` is skipped, so you can
extend a run with more `--repeat`, configs or tasks and score it all
together. `results/` is git-ignored.

**What it costs.** These are API-equivalent prices from the pilot below. A
fixture costs about $0.19 on `fable-high` and about $0.07 on either Opus 5.5
config. One pass over all 48 fixtures is 144 calls, about **$15**, and
`--repeat 3` is about **$45**. That is subscription usage, so check `/usage`
first. Most of it is Fable. `--configs opus55-high:claude-opus-5-5:high,…`
runs a subset.

## Result (3 Nov 2026, Sonnet vs a fresh Opus 5.5, `--repeat 3`, 288 calls, $20.91)

`opus55-high` was re-run because the plugin's reference docs changed since
1 Oct, so its old records have a different prompt hash. 288 records: 2
configs × 48 fixtures × 3, none missing. Run with
`--configs sonnet-high:sonnet:high,opus55-high:claude-opus-5-5:high`.

| config | routing tier ok | too low | too high | agent ok | review verdict ok | defect recall | false alarms | $/task | $ per correct | total $ |
|---|---|---|---|---|---|---|---|---|---|---|
| `sonnet-high` | 94% (113/120) | 4 | 3 | 98% (117/120) | 100% (24/24) | 100% (18/18) | 0 | $0.048 | $0.051 | $6.93 |
| `opus55-high` | 95% (114/120) | 3 | 3 | 98% (117/120) | 100% (24/24) | 100% (18/18) | 0 | $0.097 | $0.101 | $13.98 |

**Verdict for `sonnet-high` against the v0.8 pass bar: PASS on all four.**

| criterion | bar | `sonnet-high` | |
|---|---|---|---|
| routing tier accuracy | ≥ 93% | 94.2% (113/120) | PASS, by one run: a single further miss would make it 93.3%, two would fail |
| "too low" on a top-tier brief | none | 0 (all 30 answers on the 10 top-tier briefs were `top`) | PASS |
| defect recall | 100% | 100% (18/18) | PASS |
| false alarms | ≤ 1 | 0 | PASS |

**Misses (`sonnet-high`).** Fixture, what it answered, what the label wants:

- `22-default-page-size-50`, 3 of 3 repeats: `trivial`/OpenCode, label `light`.
  Same miss as `opus55-high` in all 3 repeats, and as all three configs on
  1 Oct. Both tiers go to OpenCode, so it costs nothing in practice.
- `15-weekly-report-dst-bug`, repeat 3 only: `light`/Claude `sonnet` medium,
  label `workhorse`. **This is the only miss that is Sonnet's own**: it is
  the 4th "too low", against 3 for Opus. A DST bug sent to a lighter worker
  is the kind of miss that costs a respawn. Repeats 1 and 2 were right.
- `38-dependency-vulnerability-review`, 3 of 3: `workhorse` on Codex
  `gpt-5.6-sol`, label `light`. Same as `opus55-high` and as 1 Oct. The
  routing guide sends security work to Sol, so the label is the likelier
  mistake (see 1 Oct).
- `40-upload-pipeline-security-audit`, 3 of 3 (agent only): tier `top` is
  right, but the answer was Codex `gpt-6-astra` where the scorer wants
  `gpt-5.6-sol` (the security rule wins over the top-tier rule). Same for
  `opus55-high`.

**Routing held and review didn't slip.** There is no split to act on:

- Review: Sonnet got 24/24 verdicts, caught all 18 planted defects (kind
  and file) and raised no false alarm, the same as Opus. On the git-violation
  fixture (06) it flagged the violation in all 3 repeats and sent back each
  time.
- Routing: Sonnet and Opus missed the same fixtures, `22` and `38` in all
  3 repeats each. Sonnet's one extra miss is `15` repeat 3.
- So on these fixtures there is no sign that Jarvis would need to keep an
  Opus `diff-reviewer` if it ran on Sonnet. The caveat is the thin margin on
  tier accuracy and the one real "too low" on a workhorse brief; 3 repeats
  can't tell a 1-in-3 flake on one fixture from noise.
- Cost: $0.048 per call against $0.097, about half. The gap is smaller than
  Fable vs Opus because both are cheap at this prompt size. In real Jarvis
  sessions (~216k of context) the per-token price gap applies to every cache
  write.

**Scorer change.** `score.py` still required top-tier briefs to go to
`claude`, which has been wrong since 0.7.0 (top tier is Codex `gpt-6-astra`
unless Fable is allowed). Before the fix, "agent ok" read 78% (93/120) for
both configs, all of it that stale rule. I changed `expected_route` so top
tier expects Codex `gpt-6-astra`; tier, review and cost numbers are
unaffected. Not checked: the 1 Oct numbers were not re-scored with the new
rule.

What this doesn't show is the same as 1 Oct: long multi-turn coordination
and how sharp Jarvis's own briefs are. The model choice is the user's to
rule on; nothing here changes it.

## Result (1 Oct 2026, `--repeat 3`, 432 calls, $53.51)

**Jarvis now runs on `claude-opus-5-5` at `high`.**

| config | routing tier ok | too low | too high | agent ok | review verdict ok | defect recall | false alarms | $/task | $ per correct | total $ |
|---|---|---|---|---|---|---|---|---|---|---|
| `fable-high` | 95% (114/120) | 3 | 3 | 99% (119/120) | 100% (24/24) | 100% (18/18) | 0 | $0.214 | $0.223 | $30.84 |
| `opus55-high` | 95% (114/120) | 3 | 3 | 100% (120/120) | 100% (24/24) | 100% (18/18) | 0 | $0.076 | $0.080 | $10.98 |
| `opus55-xhigh` | 95% (114/120) | 3 | 3 | 100% (120/120) | 96% (23/24) | 100% (18/18) | 1 | $0.081 | $0.085 | $11.69 |

- **The models agreed on every routing miss.** All three got the same two
  briefs wrong, the same way, in every repeat:
  - 22 (default page size) was called `trivial` instead of `light`. Both
    tiers go to OpenCode, so these "too low" answers cost nothing in practice.
  - 38 (dependency vulnerability review) was sent to Codex `gpt-5.6-sol` as
    workhorse. The routing guide sends security work to Sol, so the label is
    the likelier mistake.
- **Every config caught every planted defect.** On fixture 06 every run
  flagged the git violation, but the verdict varied: `commit` in 1 of 3
  Fable runs, 2 of 3 `high` runs and 3 of 3 `xhigh` runs. The fixture
  accepts either, as long as the finding is there.
- **`xhigh` bought nothing.** It used 60% more output tokens than `high` and
  produced the only false alarm (a `checks_missing` on clean fixture 08).
- **Fable cost 2.8× as much per call** for the same answers, and used about
  the same number of tokens as Opus. The gap is the price: in real sessions,
  where Jarvis carries ~216k of context, it applies to every cache write
  ($20 vs $8 per MTok).

What this doesn't show: long multi-turn coordination, or how sharp Jarvis's
own briefs are on undecided work. The in-situ comparison below checks that.
Re-run this eval if `jarvis usage` shows more `corrected` or `escalated`
outcomes after the switch.

## Pilot (30 Sep 2026, 9 calls, $0.98)

Fixtures: 2 routing briefs (01 top, 30 trivial) and 1 review (01-missing-file).

| config | routing tier ok | agent ok | review verdict ok | recall | $/task | output tok/task |
|---|---|---|---|---|---|---|
| fable-high | 2/2 | 2/2 | 1/1 | 1/1 | $0.186 | 374 |
| opus55-high | 2/2 | 2/2 | 1/1 | 1/1 | $0.069 | 325 |
| opus55-xhigh | 2/2 | 2/2 | 1/1 | 1/1 | $0.069 | 363 |

This only shows that the pipeline works. The pilot fixtures are the easy
ones, and all three configs got all of them right. The cost gap is almost
entirely the per-token price: every call writes its ~8k-token prompt to the
cache, and Fable writes at $20/MTok against Opus 5.5's $8. At these sizes
`xhigh` adds very little thinking. It should matter more on 04, 05 and 06
and on the ambiguous routing briefs, and those are the fixtures that decide
the result.

## In situ: real sessions

Offline fixtures can't show how a coordinator does over a long session:
whether its briefs are sharp enough to route workers a tier lower, how often
workers bounce back, or how many turns a merge takes. After the offline
eval:

1. Run Jarvis on each config for a few days of ordinary work, one config at
   a time, in the same repos. Launch it with the matching `--model`/`--effort`
   and record the config in `OPEN.md`.
2. Compare the periods with `handoffs/bin/jarvis usage --since <start>
   --until <end>`, one run per config's dates. It reports **cost per merged
   handoff** and **coordinating ÷ building** for the period (1.13 before
   the 0.3 changes; the target is ≤ 0.3), plus Jarvis's $/turn and average
   context by model. Transcripts record the model but not the effort, so
   `high` and `xhigh` on Opus 5.5 can only be told apart by their dates.
3. Record each brief's outcome at merge with `jarvis merge --outcome
   <clean|corrected|escalated|respawned>`. A cheaper coordinator that leaves
   more briefs `corrected` or `escalated` isn't cheaper.

## Limits

- The fixtures are synthetic. They are realistic in shape, but they were
  written for this eval, and both halves of each review fixture come from
  one author.
- Single runs are noisy. Use `--repeat 3` at least before you believe a gap
  of one or two fixtures.
- The candidate reviews from text and can't run commands. Real Jarvis can
  run the checks, which helps most on 05.
- These dollars are API-equivalent, a proxy for how fast a subscription
  limit is used, not a bill. A real Jarvis turn carries 100–400k of
  context, so there the per-token price gap matters more than it does in
  these ~8k-token calls.
- Routing labels are one person's judgement. `accept` covers the briefs
  that honestly sit between two tiers.
