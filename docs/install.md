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

It finds two skills, `setup` and `run`. Install both.

## Option 3: Manual

```bash
git clone https://github.com/gorock007/jarvis.git
mkdir -p ~/.claude/skills
cp -R jarvis/plugins/jarvis/skills/setup ~/.claude/skills/jarvis-setup
cp -R jarvis/plugins/jarvis/skills/run   ~/.claude/skills/jarvis-run
```

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
