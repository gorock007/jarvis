# Jev — the optional fast classifier

`handoffs/bin/jev.sh` calls Jev, TypeSafe's "System One" model
(docs.typesafe.ai). Jev doesn't write text: you send it some state and typed
questions — yes/no (*Noul*), pick-one (*Choice*), rate-on-a-rubric (*Score*) —
and it returns probabilities your code can threshold. It costs a fraction of a
cent per call and answers in well under a second, which makes it the right tool
for small, literal, high-frequency judgements, and the wrong tool for anything
that needs reasoning or knowledge of the repo.

**Jev advises, never decides.** Every call is fail-open: no
`TYPESAFE_API_KEY`, no `jq`, an API error or an 8-second timeout prints
`jev: skipped (<reason>)` and exits 0. When you see that, do what this skill
said before Jev existed.

## What it does for you

| Command | When | What you get |
| --- | --- | --- |
| `jev.sh brief <brief.md>` | after the header is filled in, before spawning | The missing ones of the five brief elements (exact files · pattern to copy · done + proving command · may/must-not fence · prior handoff). Exit 1 if any of the first four is missing; `prior` is advice only, since a fresh task has nothing to link. |
| `jev.sh triage <id>...` | inside `jarvis status`, for workers without a handoff yet | One line per worker. The last 15 lines of the screen are added only when the worker isn't plainly `working`, or confidence is under 0.6. |
| `jev.sh outcome <brief.md> <result>` | `jarvis merge --outcome <result>` records it; call it directly when a brief is abandoned | Records `clean` (merged as handed off), `corrected` (needed a `jarvis send` correction), `escalated` (respawned a tier up), or `respawned` (respawned for any other reason). |
| `jev.sh report` | when the user asks, or at 30 outcomes | The summary below. |

`--dry-run` on any of them prints the request instead of sending it.

### Reading triage

States: `working`, `waiting_for_answer`, `permission_prompt`, `usage_limit`,
`finished`, `looping_or_stuck`, `crashed`.

- `usage_limit` comes from a text rule, not from Jev, and always shows the
  screen. A worker that is *writing* a rate limiter can trip it — the line then
  reads `usage_limit (1.00 · jev: working 0.93)`; look at the tail and judge.
  Treat a real one as the red band.
- `finished` with no handoff file means the worker forgot the contract: send
  it back for the handoff.
- Triage never replaces the handoff file. `ls -t handoffs/*.md | head -5`
  stays in the poll.
- If a worker turns out to have been blocked while triage said `working`,
  say so to the user and note it in `OPEN.md` — that is the failure this
  feature must not have, and it's worth switching back to raw reads over.

## Shadow routing

`jev.sh brief` also asks Jev the routing questions — can done be verified, is
the shape undecided, is the cause unknown, how big is it, is it media /
computer-use / security work, does it touch real secrets — derives a tier from
the answers in code, and logs it next to the `worker:`/`model:`/`effort:` you
wrote. It strips the header before sending, and it **prints nothing about its
verdict**, so neither of you anchors the other. You route exactly as
`model-routing.md` says.

This is an experiment, not a feature. Nobody has published accuracy numbers
for routing coding work with Jev, and a wrong tier costs more in retries than
the classifier could ever save. `jev.sh report` shows, per brief, whether Jev
said lower / same / higher than you did, and how those briefs ended.

**Graduation rule** — at 30 or more briefs with an outcome:

- Jev's tier becomes *advisory* (shown at spawn; you note the reason in the
  brief header when you override it) only if the briefs where Jev said
  **lower** ended `clean` at least as often as the rest, **and** the report
  shows no `! Jev was two tiers too low` line.
- Otherwise routing stays as it is and the routing questions should be
  removed from `jev.sh` to save the tokens.

Advisory is lopsided on purpose, because the two mistakes don't cost the same:
a tier too low is a failed worker and a respawn, a tier too high is only
tokens. A **higher** suggestion is always shown. A **lower** one is shown only
when Jev's confidence is 0.8 or more, and a close call is shown as the top two
tiers with their probabilities, not as a pick. Jev unavailable means no
suggestion — never a default tier.

Either way it's the user's decision; show them the report.

## What leaves the machine

The brief (minus its header) and the bottom 60 lines of each triaged terminal
are sent to TypeSafe's API. `jev.sh` masks secret-shaped strings first
(API keys and tokens by shape, JWTs, private-key blocks, `Bearer …`, cookies,
`scheme://user:pass@host` URLs, `password: …`-style assignments, and the literal
value of any environment variable with a credential-like name), but masking is
a net, not a guarantee: a customer name or a private document has no shape. On a repo where terminal contents must not go to a third
party, don't set `TYPESAFE_API_KEY` there. The log lives in `handoffs/.jev/`
and is git-ignored.

## Known limits of the model

Jev reads literally, can't count or compare dates, and gets worse as
irrelevant state grows. That is why the script asks several plain questions
and combines them in code rather than asking "which model should run this?",
and why it sends 60 lines rather than the whole scrollback. If you change a
question in `jev.sh`, re-run `eval/run.sh` in the plugin repo before trusting
it; `eval/selftest.sh` checks the fail-open paths and the masking for free.
