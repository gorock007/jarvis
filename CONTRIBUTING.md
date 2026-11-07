# Contributing

Issues and pull requests are welcome, especially:

- updates when Superset CLI flags or model IDs change
- routing and efficiency improvements based on real usage
- clearer templates and setup questions

When editing skills, keep the templates' style: short rules in plain words,
each with its reason. Every line of a generated `CLAUDE.md` is read in every
Jarvis session, so leave out generic advice.

## Repository layout

```
.agent-marketplace.json              Superset marketplace manifest
.claude-plugin/marketplace.json      Claude Code marketplace manifest
plugins/jarvis/
  plugin.json                        Superset plugin manifest
  .claude-plugin/plugin.json         Claude Code plugin manifest
  skills/
    setup/
      SKILL.md                       jarvis:setup: interview + install
      templates/                     CLAUDE.md, AGENTS.md, handoffs/ (JARVIS.md, jarvis.conf, bin/jarvis, bin/lib/, bin/jarvis-lock.pl, bin/jev.sh), .claude/
    run/
      SKILL.md                       jarvis:run: the operating playbook
      references/
        hosts.md                     Superset, Ultron and tmux hosts, agent launch lines, adding either
        model-routing.md             routing table and reasoning
        handoffs.md                  brief and handoff formats, review steps
        efficiency.md                where tokens go and how to spend fewer
        lifecycle.md                 run registry, verified close, jarvis doctor, jarvis lock
        jev.md                       the optional Jev helper and the shadow-routing rule
docs/                                guides for people: install, hosts, routing, usage, lifecycle, Fable, Jev, FAQ, how it works
eval/                                labelled briefs and terminal tails; run.sh (live) tests jev.sh, selftest.sh (offline) tests jev.sh and bin/jarvis
eval/jarvis-model/                   compares Jarvis on fable/high vs claude-opus-5-5/high vs /xhigh
```

## Publishing a new version (maintainers)

Run `eval/selftest.sh` first. It's offline and free, and it covers
`bin/jarvis` and `jev.sh`. Then commit the change on its own and publish in
a second commit:

```bash
v=0.6.1   # the new version
sed -i '' -E "s/\"version\": \"[0-9.]+\"/\"version\": \"$v\"/" \
  .agent-marketplace.json plugins/jarvis/plugin.json plugins/jarvis/.claude-plugin/plugin.json
git commit -am "publish jarvis@$v"
git tag "jarvis@$v" && git push origin main "jarvis@$v"
```

A release is a git tag, and installs pin to it. Keep the `version` in those
three files the same. (Superset CLI 1.38 dropped `superset plugins`, which
used to do the bump as `superset plugins publish jarvis --bump patch`.)

Existing installs don't update themselves. Claude Code users run
`claude plugin marketplace update jarvis` and
`claude plugin update jarvis@jarvis`, then restart. Repos already
set up keep their copied `handoffs/` files until someone says "update Jarvis
in this repo".
