---
name: setup
description: Install or upgrade the Jarvis workflow in the current repo — a main agent ("Jarvis") the user talks to, which delegates building to worker agents (Claude Code, Codex, OpenCode or any agent CLI) on separate terminals — in Superset, Ultron or tmux — with usage-aware model routing (Claude Code opus/sonnet/haiku, Codex astra/sol/terra/luna, OpenCode free models; Fable only when the user authorizes one brief), machine-wide caps on concurrent Claude sessions, worker budgets, a shared-checkout worker contract, a handoff/OPEN.md system, and handoffs/bin/jarvis (spawn, status, merge, a model-free watcher, an idle-reload guard, usage reporting). Writes CLAUDE.md, AGENTS.md, handoffs/ and .claude/. Asks three questions (`advanced` asks all). Use whenever the user says "set up Jarvis", "add the Jarvis workflow", "update Jarvis in this repo", "make this repo use workers", "orchestrate with Superset terminals", "run workers in tmux", or wants one coordinating agent plus parallel workers. Needs a host for the workers: Superset, Ultron, or tmux anywhere else.
---

# jarvis:setup — install the Jarvis workflow into a repo

You are about to turn this repo into a Jarvis-run project, or bring an
existing one up to date. The result, written from `templates/` next to this
file:

- `CLAUDE.md`: a few lines that every session loads, workers included. It
  says who is who, points Jarvis at its files, and lists the checks. Keep it
  short. Measured worker sessions started at ~55k tokens, and the old,
  longer `CLAUDE.md` was 3k of that.
- `AGENTS.md`: the worker contract, read natively by Codex and OpenCode and
  by Claude Code workers. It covers git rules, shared files, ask-once, one
  brief then hand off, and the handoff format.
- `handoffs/JARVIS.md`: this project's rules for Jarvis. Only Jarvis reads
  it.
- `handoffs/OPEN.md` (Jarvis's pending list), `briefs/`, `merged/`, `log/`
  (`jarvis log`'s month files: finished notes, read by nothing at session
  start), and the brief and handoff templates.
- `handoffs/jarvis.conf`: the Claude caps (per checkout, machine-wide, Opus),
  the band thresholds and burn-rate limits, worker budgets, the Fable
  authorization lifetime, the idle limit, and whether merge stops what a
  worker left running, plus spawn's overlap mode and the `--verify` timeout cap. Most
  keys are commented defaults.
- `handoffs/bin/jarvis`: `start`, `status`, `log`, `spawn`, `merge`, `close`,
  `doctor`, `leftovers`, `lock`, `resources`, `watch`, `band`, `usage`,
  `sessions`, `budget`, `fable`, plus the prompt-guard and PreToolUse hooks
  and the statusline tap. It needs `jq` and, for `usage`, `merge --verify`
  and the overlap check, `python3`.
- `handoffs/bin/lib/`: the modules `bin/jarvis` sources: `core.sh`,
  `hosts.sh` and one file per host, `caps.sh`, `spawn.sh`, `merge.sh`,
  `watch.sh` and the rest. `bin/jarvis` doesn't run without them. Copy the
  folder whole and never edit one file of it alone.
- `handoffs/bin/jarvis-lock.pl`: the lease behind `jarvis lock` and
  `jarvis resources`. It needs `perl`, which macOS ships.
- `handoffs/bin/jarvis-verify.py`: the engine behind `jarvis merge --check
  --verify` and doctor's verification block. It needs `python3`.
- `handoffs/bin/jarvis-scope.py`: spawn's May-touch overlap check. It needs
  `python3`; without it spawn warns "unknown overlap".
- `handoffs/bin/cc_usage_audit.py`: the transcript analyser behind
  `jarvis usage`.
- `handoffs/bin/jev.sh`: optional brief lint and terminal triage. It does
  nothing without a `TYPESAFE_API_KEY`.
- the hidden `.claude/` folder, including `settings.json`, which does seven things:
  - puts subagents on Sonnet (`CLAUDE_CODE_SUBAGENT_MODEL`)
  - turns off the security-guidance per-stop review, while keeping its
    per-commit review, on Sonnet
  - installs the idle-reload guard (`UserPromptSubmit`), which also records
    which Claude session runs in each terminal, and the statusline tap
  - installs the Fable guard (`PreToolUse` on `Agent|Task|Edit|Write|MultiEdit`,
    `jarvis hook pretool`), which denies a Fable subagent and any edit that
    lets Fable into a settings allowlist
  - installs the worker event hooks (`UserPromptSubmit`, `Stop`,
    `Notification`, `SessionEnd` → `jarvis hook event`), which tell Jarvis a
    worker's state; they act only for a worker (`JARVIS_ROLE=worker` from
    spawn, or on Superset and Ultron its run record)
  - switches off plugins this repo doesn't use
  - allows Jarvis's read-only commands (`permissions.allow`: `start`, `status`,
    `band`, `sessions`, `resources`, `doctor`, `read *`, `usage *`, and
    `log *`, which only appends a line to `handoffs/log/`), so its
    session doesn't ask for those; everything else still asks (`spawn`,
    `merge`, `send`, `close`, `lock`, `budget`, `fable`, `doctor --apply`,
    `leftovers`, `watch`, `start --force`)
- `.claude/agents/scout.md` and `diff-reviewer.md`: read-only subagents
  pinned to Sonnet.

Why each piece exists, with the measured numbers, is in the `jarvis:run`
skill's `references/efficiency.md`. Read `templates/handoffs/JARVIS.md`
and `templates/AGENTS.md` once before you start, so you know what the
placeholders mean.

## 1. Check the ground

- **The host.** Workers need terminals Jarvis can start, read and type
  into. In a Superset terminal (`$SUPERSET_WORKSPACE_ID` set, `superset
  --version` works), that's Superset. In an Ultron session
  (`$ULTRON_SESSION_ID` set, `ultron daemon status` answers), it's Ultron;
  register the checkout with `ultron project add .` if `ultron project get`
  fails. Anywhere else it's tmux: `tmux -V` must work, version 3.0 or
  later. If none is available, stop and say what to install
  (https://docs.superset.sh/install, Ultron, or tmux from the package
  manager). The host is detected each time `jarvis` runs, so a repo set up
  under one works under the others. See the `jarvis:run` skill's
  `references/hosts.md`.
- `command -v jq python3 perl`. `jq` is needed for `jarvis spawn`, the hooks, the
  band and the statusline tap. Without it spawn refuses, the band reads amber
  and the Fable checks refuse, while the hooks and the guard let everything
  through. `python3` is needed for `jarvis usage` and the worker budgets'
  cost and context readings.
  `perl` is needed for `jarvis lock`: without it a wrapped heavy script
  refuses to run (exit 2), except on CI. Say what's missing.
- Which agents exist: on Superset, `superset agents list --local`; on
  Ultron, `ultron agent list`; on tmux, `command -v claude codex opencode`. The routing table sends media
  and computer-use work to Codex, and small fenced work to OpenCode's free
  models. If either is missing, keep the table, but say those rows won't
  work until it is installed, and that `sonnet`/`haiku` cover the OpenCode
  slice meanwhile. Another agent CLI the user wants (Gemini, Amp…) is a
  `JARVIS_AGENT_<name>` line in `jarvis.conf` for tmux; Superset and
  Ultron launch their own agents, so any agent they list works as is.
- The workhorse tier is pinned to `claude-opus-5-5`. If a spawn ever rejects
  that id, switch to the `opus` alias and tell the user.
- Optional, for Jev: check whether `TYPESAFE_API_KEY` is set. Never print
  the key.
- **Is Jarvis already here?** A `handoffs/OPEN.md` or a `CLAUDE.md` that
  names Jarvis means this is an **upgrade**. Follow section 5 as well.
  Otherwise, if `CLAUDE.md`, `AGENTS.md` or `.claude/settings.json` already
  exist, read them. You will **merge**, not overwrite: keep every
  project-specific rule they already hold. Show the user the diff before
  writing.

## 2. Interview — three questions, then build

Ask three questions and show the rest as defaults, in one message. For "set
up Jarvis, advanced" or the argument `--advanced`, ask all 13 as one batch:
the three questions, plus each default below as a question.

**Questions** (best guess pre-filled so the user can say "yes"):

1. **Checks** workers run before handing off. Infer them from the repo
   (`package.json` scripts, `pyproject.toml`, `Makefile`, CI config).
2. **Claude sessions cap**: how many may run in this checkout at
   once, **Jarvis included**. Default 3 (Jarvis plus two workers). Spawn also
   enforces 4 machine-wide (every repo, the user's own sessions too) and 2 on
   Opus; Codex and OpenCode don't count. Those two stay defaults in
   `jarvis.conf`.
3. **Statusline tap**: the repo's statusline becomes `jarvis statusline`. It
   saves Claude Code's 5-hour reading, machine-wide, so the band (how much of
   the 5-hour usage is spent) is computed, not guessed, then runs the user's
   own statusline unchanged. **It is
   required for the band:** with no tap in any Jarvis repo, nothing writes a
   reading, the band reads amber on every spawn, and the caps stay lowered
   (3 machine-wide, 2 Opus). The default is yes. Ask once more if the user
   says no, and say that.

**Defaults (change any of these?)**: in the same message, one line each: the
value it will write and how it was derived (one clause). "Yes" to all is a
valid answer.

- **Project name**: the repo directory name.
- **Where the app lives**: repo root, or the subfolder (`app/`, `web/`) that
  holds the manifest; then workers also read its own CLAUDE.md/AGENTS.md.
- **Only Jarvis may do, besides git**: DB migrations, deploys and releases
  where the repo has them, lockfile edits, touching real user data.
- **How the user verifies**: from the repo's shape: a browser at a URL (web
  app), a phone build (mobile), CLI commands from the handoff (CLI or
  library), else the checks only.
- **Shared files** workers edit minimally: the root layout, design tokens,
  `package.json`/`pyproject.toml` and global config that exist.
- **Free tier**: OpenCode's free models for mechanical work; never:
  credentials, production data, proprietary logic (third parties serve them).
- **Usage bands**: amber at 50%, or when on pace to use the whole 5-hour
  window; red at 75%. The tool's defaults.
- **Plugins to switch off**: from `jq .enabledPlugins ~/.claude/settings.json`,
  only the plainly unused (Stripe with no payments, Swift LSP in a Python
  repo): each enabled plugin adds to every session's start-up tokens. Keep
  `jarvis` and `security-guidance` on.
- **Jev**: installed, inert: `handoffs/bin/jev.sh` lints briefs and summarises
  quiet workers, and sends brief text and terminal bottoms (secret-shaped
  strings masked) to TypeSafe only with a `TYPESAFE_API_KEY`. Skip if the user
  says no.
- **Heavy suites**: scan the scripts (`package.json`, `Makefile`, `justfile`,
  CI config) for Docker, compose, testcontainers, e2e, playwright, anything
  called "full": several at once can stall the machine. Propose wrapping each
  where it's declared, so only one runs at a time:
  `"test:docker": "handoffs/bin/jarvis lock docker -- vitest run --project docker"`.
  Built-in classes: `docker` (one on the machine), `suite` (one per checkout);
  a suite writing shared artifacts in the checkout gets its own
  `JARVIS_LOCK_<class>` line in `jarvis.conf`. Show each change. **"Yes" to the
  defaults doesn't apply it:** edit the scripts only on an explicit yes to the
  wrapping. Logs a suite writes into the checkout go to an ignored folder, or
  `--reuse` never matches.

Say what you assumed where the repo didn't answer.

## 3. Write the files

Replace the placeholders, each from an answer or its default (none stays
empty):

| Placeholder | In | Becomes |
| --- | --- | --- |
| `{{PROJECT_NAME}}` | CLAUDE.md, AGENTS.md, JARVIS.md | project name |
| `{{APP_DIR_NOTE}}` | CLAUDE.md, AGENTS.md | e.g. "The app lives at the repo root." or "The app lives in `app/`; read `app/CLAUDE.md` too." |
| `{{CHECKS}}` | CLAUDE.md, AGENTS.md | the check commands, inserted verbatim as a shell line; do not send a value containing `&` or `/` through `sed` |
| `{{JARVIS_ONLY}}` | JARVIS.md, AGENTS.md | a sentence: "applying SQLite migrations, editing `uv.lock`, tagging releases." |
| `{{VERIFY}}` | JARVIS.md, AGENTS.md | a sentence on how the user checks work |
| `{{SHARED_FILES}}` | JARVIS.md, AGENTS.md | comma-separated paths |
| `{{FREE_TIER_NEVER}}` | JARVIS.md | what must never go to OpenCode |
| `{{MAX_CLAUDE}}`, `{{AMBER}}`, `{{RED}}` | jarvis.conf | numbers (defaults 3, 50, 75) |

The other `jarvis.conf` keys stay as the template has them, commented at
their defaults: `JARVIS_MAX_CLAUDE_GLOBAL`, `JARVIS_MAX_OPUS`,
`JARVIS_AMBER_GLOBAL`/`_OPUS`, `JARVIS_RED_GLOBAL`/`_OPUS`,
`JARVIS_ACTIVE_MIN`, `JARVIS_PENDING_SEC`, `JARVIS_STALE_MIN`,
`JARVIS_BURN_MIN`, `JARVIS_BURN_AMBER`, the `JARVIS_BUDGET_*` limits,
`JARVIS_FABLE_TTL_MIN`, `JARVIS_FABLE_SUPERSET_AGENT`, `JARVIS_SPAWN_WAIT`,
`JARVIS_OVERLAP` and `JARVIS_VERIFY_MAX_SEC`. When upgrading an existing
`jarvis.conf`, append the ones it lacks.

Then:

- Copy `templates/handoffs/` to `<repo>/handoffs/`, keeping the `.gitkeep`s
  (this includes `handoffs/bin/lib/`, which `bin/jarvis` sources and which
  needs no `chmod`, and `handoffs/bin/jarvis-verify.py` and
  `handoffs/bin/jarvis-scope.py`, which run through `python3` and need no
  `chmod`), and `chmod +x handoffs/bin/jarvis handoffs/bin/jarvis-lock.pl handoffs/bin/jev.sh`.
  Skip `jev.sh` if the user said no to Jev.
- Apply the heavy-suite wrappers the user said yes to in the heavy-suites default, and
  any `JARVIS_LOCK_<class>` lines to `jarvis.conf`.
- Copy the hidden `templates/.claude/agents/` folder to
  `<repo>/.claude/agents/`. If the repo already has agents with those names,
  leave them alone and say so.
- **The hidden `.claude/settings.json`**: merge the template into any existing file
  with `jq`, never overwrite it. Keep the user's keys. Append to existing
  hook arrays, including the `PreToolUse` Fable guard. Append the template's
  `permissions.allow` rules (the read-only `handoffs/bin/jarvis` ones and `log *`, each
  in the `handoffs/bin/jarvis …` and `./handoffs/bin/jarvis …` spellings) to
  any existing `permissions.allow` without duplicating them, remove the
  broad `Bash(handoffs/bin/jarvis *)` and `Bash(./handoffs/bin/jarvis *)`
  rules if an earlier dev build added them, and keep the user's own rules and every `deny`
  and `ask` entry. Add
  `"<plugin>@<marketplace>": false` to `enabledPlugins` for
  each plugin in the plugins default. If the project already sets a `statusLine`,
  put its command in `handoffs/jarvis.conf` as `JARVIS_STATUSLINE_CMD='…'`
  so the tap still runs it. The tap reads the user-level statusline by
  itself. If the user said no to the tap, leave `statusLine` out.
- If the app lives in a subfolder that has its own `CLAUDE.md`, add one line
  at the top of it: "This project runs the Jarvis workflow — see the root
  `CLAUDE.md` and `AGENTS.md`."
- `.gitignore`: add `handoffs/.jev/` and `handoffs/.jarvis/`, which hold
  local logs, readings and watcher state. The rest of `handoffs/` is tracked
  on purpose. It is the project's memory.

## 4. Verify and hand over

- Grep the written files for any `{{` left.
- `handoffs/bin/jarvis band` should print a band, or `unknown` until the
  first statusline refresh. `echo '{}' | handoffs/bin/jarvis hook prompt`
  must exit 0 and print nothing. `handoffs/bin/jarvis` with no arguments
  prints its help (that loads every file of `lib/`).
  `handoffs/bin/jarvis lock suite -- true` must exit 0.
- On Superset, confirm the model ids the host accepts:
  `superset agents create --workspace "$SUPERSET_WORKSPACE_ID" --agent claude --model __probe__ --prompt x`
  fails with an error that lists the accepted ids (the same works for
  `--agent codex`). On Ultron, `ultron agent models --agent claude` (and
  `codex`) lists them. On tmux, `claude --help` lists `--model`/`--effort`,
  and the agent CLIs reject a bad model when the worker starts.
- If Jev was installed: `handoffs/bin/jev.sh --dry-run brief
  handoffs/briefs/TEMPLATE.md` should print a JSON request.
- **Fable backstop (user-level: ask first).** Run `handoffs/bin/jarvis fable
  backstop`. If it says the backstop is off, ask the user before `--apply`,
  and say what it does: it writes `availableModels: ["opus","sonnet","haiku"]`
  into their `~/.claude/settings.json` (and Superset's default account, when
  there is one), which is **user-level**, so it applies in every repo and also
  stops their own `/model fable`. It leaves a `settings.json.bak-jarvis-<ts>`
  beside the file, keeps any narrower list they have, and is undone by
  restoring that backup or editing the list. Without it Jarvis still never
  routes to Fable, and spawn still refuses it, but a Claude session could
  pick it up through an Agent-tool model override. On Superset, also offer
  `JARVIS_FABLE_SUPERSET_AGENT` (see the comments in `jarvis.conf`) only if
  the user wants to be able to authorize Fable workers there.
- Tell the user how to start Jarvis. On Superset, with their project id
  from `superset projects list` filled in:

```bash
superset ws create --project <projectId> --name main --checkout local --local \
  --agent claude --model claude-opus-5-5 --effort high \
  --prompt "You are Jarvis. Use the jarvis:run skill: read handoffs/JARVIS.md and handoffs/OPEN.md, run handoffs/bin/jarvis start, then tell me what's open."
```

  In the desktop app: open the project's shared-checkout workspace and
  launch Claude Code on **claude-opus-5-5** / **high** with that first
  message. Anywhere else, from a plain terminal in the repo root:

```bash
tmux new-session -s jarvis \
  "claude --model claude-opus-5-5 --effort high 'You are Jarvis. Use the jarvis:run skill: read handoffs/JARVIS.md and handoffs/OPEN.md, run handoffs/bin/jarvis start, then tell me what is open.'"
```

  If you are already inside tmux, run just this `claude` command in the
  current pane:

```bash
claude --model claude-opus-5-5 --effort high 'You are Jarvis. Use the jarvis:run skill: read handoffs/JARVIS.md and handoffs/OPEN.md, run handoffs/bin/jarvis start, then tell me what is open.'
```

  Workers then open as windows in that tmux session (`prefix + w` lists
  them). Spawn's launch script gives Codex and OpenCode workers turn events
  there (a `codex()` wrapper, an OpenCode plugin), without touching their
  config. On Ultron, from the repo root (Ultron's own Jarvis kit is a
  separate plugin; this starts the jarvis one):

```bash
ultron project add .
ultron agent spawn --role jarvis --agent claude --model claude-opus-5-5 --effort high \
  --permission-mode bypassPermissions --title jarvis \
  --prompt "You are Jarvis. Use the jarvis:run skill: read handoffs/JARVIS.md and handoffs/OPEN.md, run handoffs/bin/jarvis start, then tell me what's open."
```

  Then talk to it in the Ultron app, or `ultron chat send <id> --text …`.
  `bypassPermissions` because a chat Jarvis can't answer a permission
  prompt. On any host Jarvis starts the watcher itself
  (`handoffs/bin/jarvis watch --start`) when `jarvis status` says it isn't
  running.

  Jarvis runs on `claude-opus-5-5` at `high`: in `eval/jarvis-model/` it
  routed and reviewed as well as Fable at about a third of the cost. Workers
  never run on Fable unless the user authorizes one brief with `jarvis fable
  allow`. Mention it if the user asks about cost.

- Offer to commit: `chore: add Jarvis workflow`. Commit only if the user
  says yes. In a Jarvis repo, git belongs to Jarvis.

## 5. Upgrading a repo set up with jarvis 0.2 or earlier

A repo is upgraded by following every section from its own version up to the
latest, in order. Wherever a step copies `handoffs/bin/jarvis`, replace the
whole `handoffs/bin/lib/` first, as section 9 step 1 describes (a repo older
than 0.8 has no `lib/` yet: create it).

The old layout kept every Jarvis rule in `CLAUDE.md`, which every worker
loaded too. Move it without losing anything project-specific:

1. From the old `CLAUDE.md`, recover the values the old placeholders held:
   the "Only Jarvis does these" sentence, **Verification**, the **Checks**
   line, and the fleet cap (`N+ Claude workers`). Also collect any rule the
   user added by hand.
2. Write the new `CLAUDE.md`, `handoffs/JARVIS.md` and
   `handoffs/jarvis.conf` from the templates using those values. Put
   hand-written rules in `JARVIS.md` if they are Jarvis-only, and in
   `CLAUDE.md` only if every session needs them. The old cap counted
   workers only, and the new one counts Jarvis too. Propose 3, and show the
   user the old number.
3. `OPEN.md`: keep every item. Replace the two header lines with the
   template's, and leave the item lists as they are. `jarvis status`
   rewrites the band line on its first run.
4. Copy the new `handoffs/bin/` files, the brief template and `AGENTS.md`
   (merge any project rules into it). Merge `.claude/settings.json` as in
   section 3.
5. Show the user the diff, then list what changed for them. They start the
   watcher once. The first message after a long idle may be stopped once.
   Spawns can now be refused at the cap or by the band.

## 6. Upgrading a repo set up with jarvis 0.3

0.4 runs on tmux (and since 0.5, Ultron) as well as Superset, with any agent CLI
as a worker.

1. Copy the new `handoffs/bin/jarvis`, `handoffs/bin/jarvis-lock.pl`,
   `handoffs/bin/jarvis-verify.py`, `handoffs/bin/jarvis-scope.py` and
   `handoffs/bin/jev.sh` over the old ones.
2. Append the `JARVIS_HOST` and `JARVIS_AGENT_*` block from the template
   `jarvis.conf` (commented out, it changes nothing; the defaults are in
   the script).
3. Nothing else changes on Superset. Tell the user: the watcher now starts
   with `handoffs/bin/jarvis watch --start` on any host, and
   `jarvis read | send | close` replace raw `superset terminals` calls.

## 7. Upgrading a repo set up with jarvis 0.5

This release adds the run registry, verified close, `jarvis doctor` and
`jarvis lock`. See the `jarvis:run` skill's `references/lifecycle.md`.

1. Copy the new `handoffs/bin/jarvis` **and `handoffs/bin/jarvis-lock.pl`**
   (new; `chmod +x` it), plus `jarvis-verify.py`, `jarvis-scope.py` and
   `jev.sh`. Without the `.pl` file, `jarvis lock` exits 2 and says to re-run
   jarvis:setup.
2. Append the `JARVIS_STOP_GRACE` block and the `jarvis lock` comment block
   from the template `jarvis.conf`. Both change nothing until edited.
3. Add the "Run heavy suites only through their lock" rule to `AGENTS.md`,
   the merge gate and the new loop lines to `handoffs/JARVIS.md`, and the
   new **Checks** wording to `handoffs/briefs/TEMPLATE.md`. Keep the
   project's own rules.
4. Do the heavy-suite step (section 2, heavy suites): find the suites,
   propose the wrappers, and edit only on the user's yes.
5. Tell the user: merge now closes every worker of a brief and checks it
   exited; `jarvis close` cancels a worker the same way; `status` ends with
   a `doctor:` line when finished workers or terminals are still around.

## 8. Upgrading a repo set up with jarvis 0.6

This release makes Fable opt-in, counts Claude sessions machine-wide, makes
the band fail closed, adds worker budgets and extends `jarvis usage`.

1. Copy the new `handoffs/bin/jarvis`, `handoffs/bin/cc_usage_audit.py`,
   `handoffs/bin/jarvis-lock.pl`, `handoffs/bin/jarvis-verify.py`,
   `handoffs/bin/jarvis-scope.py` and `handoffs/bin/jev.sh`.
2. Append the cap, band, budget and Fable blocks from the template
   `jarvis.conf` (commented, so nothing changes until edited). An existing
   `JARVIS_MAX_CLAUDE` stays as it is.
3. Merge the template `.claude/settings.json`: it adds the `PreToolUse`
   Fable guard. Check the statusline tap is there too: **without it the band
   reads amber** (section 2, statusline tap).
4. Update `AGENTS.md` (the budget rule), `handoffs/JARVIS.md` (the budget
   rules section) and `handoffs/briefs/TEMPLATE.md` (the model list and the
   `budget:` line). Keep the project's own rules.
5. Ask the user before `handoffs/bin/jarvis fable backstop --apply` (section
   4), saying it is user-level.
6. Tell the user: Jarvis no longer routes to Fable and sends top-tier work to
   Codex `gpt-6-astra`; to use Fable for one brief they type `jarvis fable
   allow <brief>` themselves; spawns are refused past 4 Claude sessions on the
   machine, 3 here or 2 on Opus; workers are asked for a partial handoff past
   a budget; and `jarvis usage` now shows per-worker cost.

## 9. Upgrading a repo set up with jarvis 0.7

This release adds `jarvis merge --check --verify [--reuse]`, which runs a
brief's checks on HEAD plus only the listed changes in a throwaway worktree,
and spawn's May-touch overlap warning. See the `jarvis:run` skill's
`references/lifecycle.md`.

1. Replace `handoffs/bin/lib/` whole with the template's before copying
   `bin/jarvis`. `bin/jarvis` is split into modules there, and it stops
   with 're-run jarvis:setup' without them. Copy it to
   `handoffs/bin/lib.new`, then
   `rm -rf handoffs/bin/lib && mv handoffs/bin/lib.new handoffs/bin/lib`.
   Leave `handoffs/bin/hosts/` (the user's own hosts) alone. Then copy
   the new `handoffs/bin/jarvis` and `handoffs/bin/jarvis-lock.pl`,
   plus the two new helpers `handoffs/bin/jarvis-verify.py` and
   `handoffs/bin/jarvis-scope.py` (run through `python3`, no `chmod`
   needed). Without `jarvis-verify.py`, `--verify` exits 2; without
   `jarvis-scope.py`, spawn warns "unknown overlap … re-run jarvis:setup".
2. Append the `JARVIS_SPAWN_WAIT`/`JARVIS_OVERLAP` block and the
   `JARVIS_VERIFY_MAX_SEC` lines from the template `jarvis.conf`
   (commented, so nothing changes). If the repo's conf defines a lock class
   named `verify` or `spawn`, rename it: both are now reserved.
3. Update `handoffs/briefs/TEMPLATE.md` (the `- May touch:` row and the
   `bash verify` example under **Checks**) and `handoffs/JARVIS.md` (the
   merge gate, the `--verify` loop line and the **Overlap** rule). Keep the
   project's own rules. Existing briefs need no change.
4. Merge the template `.claude/settings.json` with `jq` as in section 3:
   append the `jarvis hook event working` object to the existing
   `UserPromptSubmit` entry's `hooks` (keep `hook prompt`), and add the
   `Stop`, `Notification` and `SessionEnd` entries, appending to any the
   user already has. Skip any object whose `command` is already there, so
   running the step twice adds nothing. Also append the read-only
   `permissions.allow` rules from section 3 (skip any already there, remove
   the two broad `jarvis *` rules; keep the user's own rules and `deny`/`ask`
   entries), so Jarvis's read-only commands stop prompting. The hook entries write a worker's state to its
   event file and do nothing in any other session: only a worker has
   `JARVIS_ROLE` from spawn, or a running run record on Superset or Ultron.
5. Tell the user: spawn now warns when a new brief's May-touch row meets a
   running worker's, and warns "unknown" for a row with prose around its
   paths (`JARVIS_OVERLAP=refuse` makes both a refusal); a brief can mark
   commands as ```` ```bash verify class=light timeout=300 ```` blocks for
   `merge --check --verify`, and a pass there is a pre-merge observation,
   not an approval.

## Notes

- One checkout, many terminals. Workers share it, which is why the git
  rules in `AGENTS.md` are absolute. If the user wants isolated
  worktrees per worker instead, that is Superset's built-in
  `superset:orchestrate` skill, not this one. Say so rather than bending
  this workflow.
- Keep the templates' voice: short rules, plain words, each rule with its
  reason. `CLAUDE.md` and `AGENTS.md` are read by every session, so every
  line in them has to earn its tokens.
- `bin/jarvis` and `bin/lib/` are one unit: every upgrade copies both, lib
  first, and replaces lib whole.
