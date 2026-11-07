# Optional: Jev

[Jev](https://docs.typesafe.ai) is TypeSafe's fast decision model. It doesn't
write text. You send it some state and yes/no, pick-one, or rating questions,
and it returns probabilities in well under a second for a fraction of a cent.
Jarvis can use it for two small, frequent judgements, through
`handoffs/bin/jev.sh`:

- **Brief lint.** Before a worker starts, `jev.sh brief <file>` checks the
  brief for the five things that let a smaller model do the job (exact files,
  a pattern to copy, done plus the command that proves it, a scope fence, the
  prior handoff) and names what's missing.
- **Worker polling.** `jev.sh triage <ids>` reads the worker terminals outside
  Jarvis's context and returns one line per worker, for example
  `a1b2 working (0.94)`. It shows the screen only for a worker that is
  blocked, asking, limited, finished, stuck, or unclear. Usage-limit messages
  are caught by a text rule, not by the model.

It also runs an experiment: each brief gets a **shadow** model-tier verdict
from Jev, logged next to the model Jarvis chose and how the brief turned out.
Jev's verdict is never shown to Jarvis and changes nothing. After about 30
briefs, `jev.sh report` tells you whether the classifier has earned an
advisory role. Nobody has published accuracy numbers for routing coding work
this way, so it has to earn it on your own briefs first.

**Jev advises and never decides.** Without `jq`, without a key, or when the
API fails or takes longer than 8 seconds, the script prints
`jev: skipped (…)`, exits cleanly, and Jarvis works exactly as it does without
it.

**Privacy.** Brief text (without its header) and the bottom 60 lines of
polled worker terminals are sent to TypeSafe. Secret-shaped strings are masked
first, but masking can miss things. If terminal contents must not leave your
machine, don't set `TYPESAFE_API_KEY` in that repo. Run any command with
`--dry-run` to see exactly what would be sent.

To turn it on, set `TYPESAFE_API_KEY` in the shell profile your worker
terminals load. Details are in
[`jev.md`](../plugins/jarvis/skills/run/references/jev.md). The labelled fixtures
and the pass/fail gates used to test the questions are in [`eval/`](../eval/).
`eval/selftest.sh` checks the fail-open paths and the masking with no key and no network.
