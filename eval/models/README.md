# eval/models: compare models on your own tasks

Runs one set of tasks through several models headless and keeps every answer.
You get two kinds of result:

- **Blind writing.** You judge each writing task's drafts without knowing
  which model wrote which (`blind.sh`).
- **Scored results.** Planted-bug code review and long-context questions,
  checked against an answer key you wrote. No model does the judging
  (`score.sh`).

```sh
eval/models/run.sh <suite> --dry-run        # the calls, token sizes, estimated cost
eval/models/run.sh <suite>                  # make the calls
eval/models/score.sh <out>                  # review and longctx scores, cost
eval/models/blind.sh <out> make             # the blind lineup of writing drafts
eval/models/blind.sh <out> vote             # judge it in the terminal
eval/models/blind.sh <out> reveal           # results per model
```

`eval/models/examples/` is a tiny synthetic suite with two tasks of each kind.
`bash eval/models/test.sh` runs the whole flow on it with fake model CLIs.

## Keep real tasks out of git

Real tasks come from your other projects, so they never go in this repo. Put
suites in `handoffs/.jarvis/eval/models/suites/<name>/`. `handoffs/` is
git-excluded here, and outputs default to `handoffs/.jarvis/eval/models/runs/`.
A suite under `suites/` can be named without its path:
`eval/models/run.sh my-posts`. Set `EVAL_MODELS_HOME` to keep both somewhere
else.

## Writing a suite

```
my-suite/
  tasks/          one .md file per task; the file name is the task's name
  files/          anything the tasks quote (any layout you like)
  tags.txt        optional: tags a judge can put on a draft, one per line
```

A task file is a short header, a `---` line, then the prompt:

```
kind: review
title: shopping cart with two planted bugs
context: files/cart.py
bug: B1 files/cart.py:13-14
bug: B2 files/cart.py:24-25
tolerance: 1
---
Review this Python module for bugs. Ignore style.
```

Header keys. Lines starting with `#` are comments, and the header may also
open with a `---` line, as front matter does.

| key | what it does |
|---|---|
| `kind:` | `writing`, `review` or `longctx` (required) |
| `context:` | file globs, relative to the suite (or absolute), quoted in full before the prompt. Repeatable, several per line. A directory means every file under it, without dot-files. No `**`. |
| `title:` | a short label, shown in the blind lineup |
| `group:` | the task's group in the blind reveal (for example `linkedin post`, `email`); defaults to the kind |
| `bug: <id> <path>:<line>[-<line>]` | review: one planted bug. The path is the one shown in the prompt, which is the context path as written. |
| `tolerance:` | review: how many lines off a reported bug may be (default 2) |
| `answer: <id> = <answer> \| <alternative>` | longctx: one question's accepted answers |
| `numbered:` | `yes` or `no`: put line numbers in the quoted files (default yes for review) |
| `output_tokens:` | output tokens assumed for the cost estimate (default 4000 for writing and review, 2000 for longctx) |

The prompt each model gets is built in this order: one line saying it has no
tools and should answer from the prompt alone, then the context files as
`=== FILE <path> === … === END FILE <path> ===`, then your prompt text, then a
fixed format line:

- **review**: `BUG: <path>:<line> — <reason>` per bug, or `NO BUGS`.
- **longctx**: `<id>: <answer>` per question. Write the ids (`Q1`, `Q2`, …)
  in your prompt.

`run.sh` saves each prompt as `prompts/<task>.txt` in the output folder.
`--dry-run` prints every prompt's size in tokens, estimated as bytes ÷ 2.
Claude calls measured 2.1 to 2.8 bytes a token (prose near the top,
line-numbered code and large code corpora near the bottom), so the estimate
errs high on purpose.

### Writing tasks

A writing task has just `kind: writing`, the prompt and maybe `context:`
(for example, the notes a post should be based on). Nothing scores it. You
judge it blind.

### Review tasks: planting bugs

Write or copy a file, then break it on purpose and note each break as a `bug:`
line, with a `#` comment saying what is wrong. A range (`13-14`) covers a bug
that spans lines. A reported line counts if it falls inside the range, give or
take `tolerance`. Each planted bug can be found once. A reported bug that
matches no planted bug is a false positive, so `score.sh` shows recall and
precision. Report paths may drop leading folders (`cart.py` matches
`files/cart.py`). Plant bugs that are unambiguous, or a model that flags a real
second problem gets marked as a false positive.

### Long-context tasks

Point `context:` at the material (one big file, or a folder of them) and ask
questions with short, exact answers: a number, a name, a version. List every
spelling you would accept: `answer: Q1 = 9 | nine | 9 days`. Before comparing,
both sides drop case, quotes, markdown `*`/`` ` ``, `,;!?` and a trailing
period. For each question id, the model's last answer line counts. A good
long-context task hides its facts in the middle and puts near misses next to
them, as the example changelog does with its out-of-order versions.

## Models

Ids are `cli:model[@effort]`:

| id | runs |
|---|---|
| `claude:claude-opus-5-5@medium` | `claude -p --model claude-opus-5-5 --effort medium --output-format json`. `claude:x` means `claude:x@high`. |
| `agy:gemini-4-neon-high` | `agy --print-timeout <t>s --model gemini-4-neon-high --sandbox -p "<prompt>"`. The effort is part of the id (`agy models` lists them). |
| `codex:<model>[@effort]` | `codex exec -m <model> --sandbox read-only --ephemeral`, prompt on stdin |

The default `--models` is the first comparison: `agy:gemini-4-neon-high`,
`agy:gemini-4-neon-medium`, `agy:gemini-4-argon-high`,
`agy:gemini-4-argon-medium`, `claude:claude-opus-5-5@high` and
`claude:claude-opus-5-5@medium`.

Every call runs in its own empty temp directory, with stdin closed or holding
the prompt:

- claude: tools off (`--tools ""`), no MCP servers, no settings files, no
  session saved, one turn, and its system prompt is the "no tools" line.
- agy: `--sandbox`; codex: a read-only sandbox.

If a model writes into its directory anyway, the call is flagged
(`cwd_written` in `calls.jsonl`).

agy cuts any single message at about 190 KB, so a prompt over 150000 bytes
(`EVAL_AGY_INLINE_MAX` to change it) is not sent inline: `run.sh` writes it
into the call's work dir as `prompt.md` and tells agy to read it in full with
its file tool and follow the instructions at its end, the way an agy worker
reads a repo. `delivery` in `calls.jsonl` says `inline` or `file` (claude and
codex are always `inline`); the harness's own `prompt.md` does not count as the
model writing files.

## Cost and limits

- `--dry-run` prints the number of calls per CLI and the estimated dollar cost
  of the claude calls: estimated input plus 800 tokens of CLI overhead, plus
  `output_tokens`, at the model's list price. It also lists any call whose
  estimate passes `--max-usd`.
- `--max-usd` (default 0.50) is a per-call cap. If any planned claude call's
  estimate passes it, the run stops before making any call. The cap is also
  passed to `claude --max-budget-usd`, and a call that hits it stops the run.
- **The prompt cache is off for `claude -p`** (`DISABLE_PROMPT_CACHING=1`).
  Each prompt is sent once, so a cache write would only add cost: 1.25× the
  input price for a 5-minute write, 2× for a 1-hour write.
- agy calls cost no dollars. Each one takes a request from the Google AI Pro
  daily pool, so their count is printed instead. Codex calls draw on the
  ChatGPT plan and are counted too.
- `calls.jsonl` holds one line per call attempt: model, effort, ok,
  seconds, estimated prompt tokens, estimated vs actual dollars, actual tokens
  and cache reads/writes for claude. `run.sh` and `score.sh` end with a
  per-model summary of it.
- These calls are not registered with Jarvis's session caps. Keep runs small,
  or run them when the usage band is green.

## Reruns

A rerun with the same `--out` only makes the calls that have no answer yet.
Failed calls leave no answer, so a rerun retries them. A rerun with
`--models` naming a new model adds it to the same run. If a task's prompt has
changed since its answers were recorded, the rerun refuses. Start a new
`--out` instead. `--only w1*,r2-backup` and `--kind writing` limit the tasks.

## Blind judging

`blind.sh <out> make` builds the **lineup**. For each writing task it takes
every model's answer and labels them Draft 1..N, in an order shuffled for
each task (`--seed` repeats an order). It writes:

- `lineup.json`: the tasks, prompt paths, draft files, the three verdicts and
  the suite's tags. It holds no model names and is plain enough for a web page
  to read.
- `lineup-key.json`: which model wrote which draft. Don't open it until you
  are done.

`make` also warns about any draft that names a model or vendor ("As a Gemini
model…"), which would give its author away.

`blind.sh <out> vote` shows each task's prompt and all its drafts, then asks
you, for each draft:

- a verdict: **s**hip as-is, **l**ight edit or **r**ewrite
- tags, as numbers from the suite's `tags.txt`
- an optional note

Then it asks for one top pick. Each task you finish is appended to
`lineup-votes.jsonl` as
`{task, top, drafts: [{label, verdict, tags, note}], at}`. Any question
accepts `q` (quit; the current task isn't saved) or `x` (skip the task), and
`vote` resumes where you stopped.

`blind.sh <out> reveal` prints three things:

- for each model, overall and per task group:
  - top-pick rate
  - ship-or-light-edit rate
  - ship-as-is rate
  - its three most common tags
- each task's top pick
- how often each label position was the top pick, to catch an order bias

`blind.sh <out> pairs make|vote|reveal|status` is the older A/B mode. It pairs
every two models per task, and you vote a / b / tie. Its files are
`pairs.json`, `pairs-key.json` and `pairs-votes.jsonl`.

## Output folder

```
run.json          suite, models, cap, cache setting, CLI versions
tasks/<t>.json    the parsed header and answer key, prompt size and hash
prompts/<t>.txt   the exact prompt every model got
answers/<t>/<model>.txt
raw/<t>/<model>.out|.err   each CLI's raw output
calls.jsonl       one line per call attempt
scores.json       from score.sh
lineup.json, lineup-key.json, lineup-votes.jsonl, lineup/<t>/draft-<n>.txt
pairs.json, pairs-key.json, pairs-votes.jsonl, blind/
```
