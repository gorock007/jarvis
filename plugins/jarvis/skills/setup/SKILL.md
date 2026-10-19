---
name: setup
description: Install or upgrade the Jarvis workflow in the current repo — a main agent ("Jarvis") the user talks to, which delegates building to worker agents on separate Superset terminals, with usage-aware model routing (Claude Code fable/opus/sonnet/haiku, Codex astra/sol/terra/luna, OpenCode free models), a cap on concurrent Claude sessions, a shared-checkout worker contract, a handoff/OPEN.md system, and handoffs/bin/jarvis (spawn, status, merge, a model-free watcher, an idle-reload guard, usage reporting). Writes CLAUDE.md, AGENTS.md, handoffs/ and .claude/. Use whenever the user says "set up Jarvis", "add the Jarvis workflow", "update Jarvis in this repo", "make this repo use workers", "orchestrate with Superset terminals", or wants one coordinating agent plus parallel workers in Superset. Requires the Superset CLI (`superset`) — this workflow only works inside Superset.
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
- `handoffs/OPEN.md` (Jarvis's pending list), `briefs/`, `merged/`, and the
  brief and handoff templates.
- `handoffs/jarvis.conf`: the Claude cap, the band thresholds, the idle
  limit, and whether merge stops what a worker left running.
- `handoffs/bin/jarvis`: `start`, `status`, `spawn`, `merge`, `leftovers`,
  `watch`, `band`, `usage`, plus the prompt-guard hook and the statusline
  tap. It needs `jq` and, for `usage`, `python3`.
- `handoffs/bin/cc_usage_audit.py`: the transcript analyser behind
  `jarvis usage`.
- `handoffs/bin/jev.sh`: optional brief lint and terminal triage. It does
  nothing without a `TYPESAFE_API_KEY`.
- `.claude/settings.json`, which does four things:
  - puts subagents on Sonnet (`CLAUDE_CODE_SUBAGENT_MODEL`)
  - turns off the security-guidance per-stop review, while keeping its
    per-commit review, on Sonnet
  - installs the idle-reload guard (`UserPromptSubmit`), which also records
    which Claude session runs in each terminal, and the statusline tap
  - switches off plugins this repo doesn't use
- `.claude/agents/scout.md` and `diff-reviewer.md`: read-only subagents
  pinned to Sonnet.

Why each piece exists, with the measured numbers, is in the `jarvis:run`
skill's `references/efficiency.md`. Read `templates/handoffs/JARVIS.md`
and `templates/AGENTS.md` once before you start, so you know what the
placeholders mean.

## 1. Check the ground

- `superset --version` must work. If it doesn't, stop. This workflow depends
  on `superset agents create` and `terminals read|send`, so it is
  Superset-only. Say so and point at https://docs.superset.sh/install.
- `command -v jq python3`. `jq` is needed for `jarvis spawn`, the guard, the
  band and the statusline tap. Without it those fail open, and the user
  loses the enforcement. `python3` is only needed for `jarvis usage`. Say
  what's missing.
- `superset agents list --local`: note which agent presets exist (`claude`,
  `codex`, `opencode`, …). The routing table sends media and computer-use
  work to Codex, and small fenced work to OpenCode's free models. If either
  isn't configured, keep the table, but say those rows won't work until it
  is, and that `sonnet`/`haiku` cover the OpenCode slice meanwhile.
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

## 2. Interview — one batch, then build

Ask everything in one message, with your best guess pre-filled from the repo
so the user can just say "yes":

1. **Project name** (default: repo directory name).
2. **Where the app lives**: repo root, or a subfolder (`app/`, `web/`)? If
   it's a subfolder, workers should read that folder's own
   CLAUDE.md/AGENTS.md too.
3. **Checks** workers run before handing off. Infer them from the repo
   (`package.json` scripts, `pyproject.toml`, `Makefile`, CI config).
4. **Things only Jarvis may do besides git**: applying DB migrations,
   deploying, cutting releases, editing lockfiles, touching real user data.
5. **How the user verifies work**: a phone build, a browser at a URL, CLI
   commands from the handoff, or tests only.
6. **Shared files** workers must edit minimally: root layout, design
   tokens, `package.json`/`pyproject.toml`, global config.
7. **Claude cap**: how many Claude sessions may run at once, **Jarvis
   included**. The default is 3 (Jarvis plus two workers). When the 5-hour
   window ran out, 11 were running at once. Codex and OpenCode don't count.
8. **Free tier**: is the user happy sending mechanical work to OpenCode's
   free models? What must never go there? In most repos that's real
   credentials, production data and proprietary logic. Free models are
   served by third parties.
9. **Usage bands**: the defaults are amber at 50%, or when on pace to use
   the whole 5-hour window, and red at 75%. Ask whether those suit.
10. **Plugins to switch off here.** List the user's globally enabled plugins
    (`jq .enabledPlugins ~/.claude/settings.json`) and propose switching off
    the ones this repo plainly doesn't use (Stripe in a repo with no
    payments, Swift LSP in a Python repo). Every enabled plugin adds to every
    session's skill listing, and workers pay for it on every turn. Keep
    `jarvis` and `security-guidance` on.
11. **Statusline tap**: the repo's statusline becomes `jarvis statusline`.
    It saves Claude Code's 5-hour reading so the band is computed, not
    guessed, then runs the user's own statusline unchanged. The default is
    yes. Without it, Jarvis asks for `/usage` numbers.
12. **Jev (optional)**: `handoffs/bin/jev.sh` lints briefs before a spawn
    and makes `jarvis status` show one line per quiet worker. It sends brief
    text and the bottom of worker terminals to TypeSafe, with secret-shaped
    strings masked. It needs a `TYPESAFE_API_KEY` (docs.typesafe.ai).
    Install it anyway (it's inert without a key) unless the user says no.

Skip any question the repo answers unambiguously, and say what you assumed.

## 3. Write the files

Replace the placeholders:

| Placeholder | In | Becomes |
| --- | --- | --- |
| `{{PROJECT_NAME}}` | CLAUDE.md, AGENTS.md, JARVIS.md | project name |
| `{{APP_DIR_NOTE}}` | CLAUDE.md, AGENTS.md | e.g. "The app lives at the repo root." or "The app lives in `app/`; read `app/CLAUDE.md` too." |
| `{{CHECKS}}` | CLAUDE.md, AGENTS.md | the check commands, as a shell line |
| `{{JARVIS_ONLY}}` | JARVIS.md, AGENTS.md | a sentence: "applying SQLite migrations, editing `uv.lock`, tagging releases." |
| `{{VERIFY}}` | JARVIS.md, AGENTS.md | a sentence on how the user checks work |
| `{{SHARED_FILES}}` | JARVIS.md, AGENTS.md | comma-separated paths |
| `{{FREE_TIER_NEVER}}` | JARVIS.md | what must never go to OpenCode |
| `{{MAX_CLAUDE}}`, `{{AMBER}}`, `{{RED}}` | jarvis.conf | numbers (defaults 3, 50, 75) |

Then:

- Copy `templates/handoffs/` to `<repo>/handoffs/`, keeping the `.gitkeep`s,
  and `chmod +x handoffs/bin/jarvis handoffs/bin/jev.sh`. Skip `jev.sh` if
  the user said no to Jev.
- Copy `templates/.claude/agents/` to `<repo>/.claude/agents/`. If the repo
  already has agents with those names, leave them alone and say so.
- **`.claude/settings.json`**: merge the template into any existing file
  with `jq`, never overwrite it. Keep the user's keys. Append to existing
  hook arrays. Add `"<plugin>@<marketplace>": false` to `enabledPlugins` for
  each plugin from question 10. If the project already sets a `statusLine`,
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
  prints its help.
- Confirm the model ids the host accepts:
  `superset agents create --workspace "$SUPERSET_WORKSPACE_ID" --agent claude --model __probe__ --prompt x`
  fails with an error that lists the accepted ids (the same works for
  `--agent codex`).
- If Jev was installed: `handoffs/bin/jev.sh --dry-run brief
  handoffs/briefs/TEMPLATE.md` should print a JSON request.
- Tell the user how to start Jarvis and its watcher, with their project id
  from `superset projects list` filled in:

```bash
superset ws create --project <projectId> --name main --checkout local --local \
  --agent claude --model claude-opus-5-5 --effort high \
  --prompt "You are Jarvis. Use the jarvis:run skill: read handoffs/JARVIS.md and handoffs/OPEN.md, run handoffs/bin/jarvis start, then tell me what's open."
superset terminals create --workspace <workspaceId> --command "handoffs/bin/jarvis watch"
```

  In the desktop app: open the project's shared-checkout workspace, launch
  Claude Code on **claude-opus-5-5** / **high** with that first message, and open a
  plain terminal running `handoffs/bin/jarvis watch`. Jarvis also starts
  the watcher itself if it finds none.

  Jarvis runs on `claude-opus-5-5` at `high`, not `fable`: in
  `eval/jarvis-model/` it routed and reviewed as well as Fable at about a
  third of the cost. Mention it if the user asks about cost.

- Offer to commit: `chore: add Jarvis workflow`. Commit only if the user
  says yes. In a Jarvis repo, git belongs to Jarvis.

## 5. Upgrading a repo set up with jarvis 0.2 or earlier

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

## Notes

- One workspace, many terminals. Workers share the checkout, which is why
  the git rules in `AGENTS.md` are absolute. If the user wants isolated
  worktrees per worker instead, that is Superset's built-in
  `superset:orchestrate` skill, not this one. Say so rather than bending
  this workflow.
- Keep the templates' voice: short rules, plain words, each rule with its
  reason. `CLAUDE.md` and `AGENTS.md` are read by every session, so every
  line in them has to earn its tokens.
