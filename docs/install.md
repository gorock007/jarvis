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

## Option 4: Without Claude Code (`install.sh`)

For a repo whose Jarvis runs on agy, Codex or OpenCode, with no Claude Code
on the machine. Clone this repo once, then run its installer from the root
of the repo you're setting up:

```bash
git clone https://github.com/gorock007/jarvis.git ~/src/jarvis
cd path/to/your-repo
~/src/jarvis/plugins/jarvis/install.sh
```

It finds the agent CLIs and hosts on your PATH, and asks its questions only
when it runs in a terminal. It fills in the same templates `jarvis:setup`
uses, copies the run skill a Codex or OpenCode Jarvis reads to
`handoffs/skills/jarvis-run/`, and ends by printing the next step.

| Flag | What it sets |
| --- | --- |
| `--lead claude\|agy\|codex\|opencode` | The agent Jarvis runs on. Default: `claude` if it's installed, else `codex`, `agy`, `opencode`, in that order. |
| `--lead-model <id>` | Jarvis's model. Defaults: claude `claude-opus-5-5`, agy `gemini-4-neon-high` (experimental), codex `gpt-6-astra`. OpenCode has none: give `provider/model`. |
| `--workers a,b` | The agents workers may run on, comma-separated. |
| `--host superset\|ultron\|tmux` | The host the workers run on. |
| `--checks "<cmd>"` | The checks workers run before handing off. |
| `--yes` | Take the defaults without asking. |

It refuses any Fable model, and a repo that already has `handoffs/JARVIS.md`
(upgrade that one with `jarvis:setup`). For an agy lead it prints the
`agy plugin install …` line for you to run; it doesn't run it.

Recommended leads: Claude Opus 5.5, or Gemini Neon on agy. Neon as Jarvis
is experimental until a live trial passes. How each lead starts, and what
it lacks next to a Claude Jarvis: [Jarvis on another agent](hosts.md#jarvis-on-another-agent).

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
