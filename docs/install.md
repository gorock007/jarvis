# Installation

Pick **one** of these.

## Option 1: Claude Code plugin marketplace (recommended)

Inside Claude Code:

```
/plugin marketplace add gorock007/jarvis
/plugin install jarvis@jarvis
```

Updates arrive through `/plugin`, and the skills are named `jarvis:setup`
and `jarvis:run`.

## Option 2: Skills CLI

For Claude Code, Codex, or any agent that reads `SKILL.md` files:

```bash
npx skills add gorock007/jarvis
```

It finds two skills, `setup` and `run`. Install both. They are called `setup`
and `run` (the `name:` in each `SKILL.md`), without the `jarvis:` prefix a
plugin install adds. To start, say "set up Jarvis in this repo" for `setup`,
and in the start prompt (see [Start Jarvis](hosts.md#start-jarvis)) write
"Use the run skill" where it says "Use the jarvis:run skill".

## Option 3: Manual

```bash
git clone https://github.com/gorock007/jarvis.git
mkdir -p ~/.claude/skills
cp -R jarvis/plugins/jarvis/skills/setup ~/.claude/skills/jarvis-setup
cp -R jarvis/plugins/jarvis/skills/run   ~/.claude/skills/jarvis-run
```

The folders are named `jarvis-setup` and `jarvis-run`, but the skills inside
are still called `setup` and `run` (the `name:` in each `SKILL.md`). Start them
the same way as under Option 2: "set up Jarvis in this repo", and "Use the run
skill" in the start prompt.

## Check that it installed

Open a new Claude Code session and ask *"what skills do you have?"* You should
see `setup` and `run` from the `jarvis` plugin.

## Moving from superset-jarvis

The repo was renamed from `gorock007/superset-jarvis` in 0.4.1, and the
plugin is now `jarvis@jarvis`. An install under the old name keeps updating
through GitHub's redirect for now, but move it over once:

```
claude plugin marketplace remove superset-jarvis
claude plugin marketplace add gorock007/jarvis
claude plugin install jarvis@jarvis
```

Repos you set up with Jarvis need no changes.
