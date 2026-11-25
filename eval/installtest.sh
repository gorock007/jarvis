#!/usr/bin/env bash
# Offline test of plugins/jarvis/install.sh: each case runs it in a throwaway git repo,
# with fake agent CLIs and hosts on a PATH that holds nothing else but the system tools
# it needs. The fakes log every call and exit at once; nothing is left running.
# No model, no network, no cost. Run it on both bashes:
#
#   eval/installtest.sh && /bin/bash eval/installtest.sh
# shellcheck disable=SC2016,SC2086,SC2319 # literal backticks; $ALL splits on purpose; the check "…" $? idiom
set -u
# One brace group ending in exit, so bash reads the whole file before running any of it
# (another worker's mid-run edit can't replay part of it).
{
here=$(cd "$(dirname "$0")" && pwd -P)
root=$(cd "$here/.." && pwd -P)
INST="$root/plugins/jarvis/install.sh"
TPL="$root/plugins/jarvis/skills/setup/templates"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/jarvis-installtest.XXXXXX")
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
# nothing below may reach the real ~/.jarvis, ~/.claude or the user's CLI config
export HOME="$tmp/home" JARVIS_HOME="$tmp/jh" CLAUDE_CONFIG_DIR="$tmp/cc" JARVIS_MODELS_REFRESH_H=0
export GIT_AUTHOR_NAME=installtest GIT_AUTHOR_EMAIL=installtest@example.invalid GIT_COMMITTER_NAME=installtest GIT_COMMITTER_EMAIL=installtest@example.invalid
unset CLAUDECODE CLAUDE_CODE_SESSION_ID CLAUDE_CODE_ENTRYPOINT ANTIGRAVITY_AGENT OPENCODE CODEX_THREAD_ID CODEX_SHELL \
  JARVIS_ROLE JARVIS_BRIEF JARVIS_RUN TMUX SUPERSET_WORKSPACE_ID ULTRON_SESSION_ID
mkdir -p "$HOME" "$JARVIS_HOME" "$CLAUDE_CONFIG_DIR"
export FAKE_LOG="$tmp/fake.log"
fails=0
ok() { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; fails=$((fails + 1)); }
check() { if [ "$2" = 0 ]; then ok "$1"; else bad "$1"; fi; }

# The system tools, one symlink each, so no real agent CLI or host on this machine is seen.
# bash is the one running this test: install.sh is run with it, and handoffs/bin/jarvis's
# `#!/usr/bin/env bash` finds it here.
sys="$tmp/sys"; mkdir -p "$sys"
for t in sh env git awk sed grep find cp mv mkdir chmod cat tr dirname basename rm rmdir perl python3 \
         date head tail sort uniq wc ls ln readlink touch mktemp id uname cut tee xargs od shasum cksum \
         diff cmp sleep ps hostname stat expr comm printf tput less; do
  p=$(command -v "$t" 2>/dev/null) && [ -x "$p" ] && ln -s "$p" "$sys/$t"
done
ln -s "$BASH" "$sys/bash"
nojq="$tmp/sys-nojq"; cp -R "$sys" "$nojq"
p=$(command -v jq) && ln -s "$p" "$sys/jq"

# fakes <names…>: a folder of fake CLIs, printed. Each logs "<name> <args>" and answers
# what install.sh and jarvis lead --print may ask; anything else just exits 0.
n=0
fakes() {
  n=$((n + 1)); local d="$tmp/fakes-$n" f
  mkdir -p "$d"
  for f in "$@"; do
    cat > "$d/$f" <<'EOF'
#!/bin/sh
me=$(basename "$0")
echo "$me $*" >> "$FAKE_LOG"
case "$me $1" in
  "tmux -V") echo "tmux ${FAKE_TMUX_V:-3.4}" ;;
  "opencode models") printf 'opencode/big-pickle\nanthropic/claude-sonnet-5-5\nnot an id\n' ;;
  "agy plugin") echo '[]' ;;
esac
exit 0
EOF
    chmod +x "$d/$f"
  done
  echo "$d"
}
ALL="claude codex agy opencode superset ultron tmux"

newrepo() { # a fresh git repo in $R; the rest of the arguments are files to create in it ("path=content")
  n=$((n + 1)); R="$tmp/repo $n"   # a space in the path, as real checkouts can have
  mkdir -p "$R" && git -C "$R" init -q
  local kv
  for kv in "$@"; do mkdir -p "$(dirname "$R/${kv%%=*}")"; printf '%s\n' "${kv#*=}" > "$R/${kv%%=*}"; done
}
snap() { (cd "$R" && find . -path ./.git -prune -o -print | LC_ALL=C sort) }
# inst <fakes dir> <args…>: run install.sh in $R, not on a terminal; output in $OUT, status in $RC
inst() {
  local f=$1; shift
  : > "$FAKE_LOG"
  OUT=$(cd "$R" && PATH="$f:$sys" "$BASH" "$INST" "$@" </dev/null 2>&1); RC=$?
}
said() { printf '%s' "$OUT" | grep -qF -- "$1"; }
conf() { grep -qx -- "$1" "$R/handoffs/jarvis.conf"; }   # a whole line of jarvis.conf
# jarvis <args…>: the installed handoffs/bin/jarvis in $R, with its own home
J() { (cd "$R" && HOME="$tmp/jhome" JARVIS_HOME="$tmp/jhome/.jarvis" CLAUDE_CONFIG_DIR="$tmp/jhome/.claude" PATH="$sys" handoffs/bin/jarvis "$@") }
home_clean() { [ -z "$(find "$HOME" "$JARVIS_HOME" "$CLAUDE_CONFIG_DIR" -mindepth 1 | head -n 1)" ]; }
# the model never ran: the only calls install.sh made were tmux -V and opencode models
only_listings() { ! grep -vxE 'tmux -V|opencode models' "$FAKE_LOG" | grep -q .; }
no_paths() { ! grep -rlF -e "$tmp" -e "$root" "$R" --exclude-dir=.git --exclude-dir=.jarvis 2>/dev/null | grep -q .; }

echo "refusals (nothing written)"
F=$(fakes tmux); newrepo; before=$(snap); inst "$F" --yes
[ $RC = 1 ] && said "no agent CLI on PATH" && said "claude" && said "opencode" && [ "$(snap)" = "$before" ]; check "no agent CLI: refused, says what to install" $?
F=$(fakes claude codex); newrepo; before=$(snap); inst "$F" --yes
[ $RC = 1 ] && said "no host" && said "tmux 3.0" && said "superset" && [ "$(snap)" = "$before" ]; check "no host: refused, says what to install" $?
F=$(fakes claude tmux); newrepo; before=$(snap); FAKE_TMUX_V=2.9 inst "$F" --yes
[ $RC = 1 ] && said "tmux 2.9 is too old" && [ "$(snap)" = "$before" ]; check "tmux older than 3.0 isn't a host" $?
F=$(fakes $ALL); newrepo "handoffs/JARVIS.md=# old"; before=$(snap); inst "$F" --yes
[ $RC = 1 ] && said "already set up; upgrade with jarvis:setup" && [ "$(snap)" = "$before" ]; check "handoffs/JARVIS.md exists: already set up" $?
newrepo "handoffs/OPEN.md=# old"; before=$(snap); inst "$F" --yes
[ $RC = 1 ] && said "already set up" && [ "$(snap)" = "$before" ]; check "an older Jarvis (handoffs/OPEN.md): already set up" $?
newrepo "CLAUDE.md=Run handoffs/bin/jarvis start"; before=$(snap); inst "$F" --yes
[ $RC = 1 ] && said "already set up" && [ "$(snap)" = "$before" ]; check "a CLAUDE.md naming handoffs/bin/jarvis: already set up" $?
newrepo "sub/x=1"; before=$(snap); OUT=$(cd "$R/sub" && PATH="$F:$sys" "$BASH" "$INST" --yes </dev/null 2>&1); RC=$?
[ $RC = 1 ] && said "repo's root" && [ "$(snap)" = "$before" ]; check "run from a folder inside the repo: refused" $?
n=$((n + 1)); mkdir -p "$tmp/plain $n"; OUT=$(cd "$tmp/plain $n" && PATH="$F:$sys" "$BASH" "$INST" --yes </dev/null 2>&1); RC=$?
[ $RC = 1 ] && said "isn't a git repo" && [ -z "$(ls -A "$tmp/plain $n")" ]; check "not a git repo: refused" $?
newrepo; before=$(snap)
inst "$F" --yes --lead-model claude-FABLE-5; [ $RC = 1 ] && said "Fable never runs Jarvis" && [ "$(snap)" = "$before" ]; check "--lead-model with Fable in any case: refused" $?
inst "$F" --yes --lead opencode --lead-model anthropic/Fable-x; [ $RC = 1 ] && said "Fable never runs Jarvis" && [ "$(snap)" = "$before" ]; check "…behind a provider too" $?
inst "$F" --yes --lead opencode; [ $RC = 1 ] && said "--lead-model provider/model" && said "opencode models" && [ "$(snap)" = "$before" ]; check "opencode lead, no --lead-model, --yes: refused, names the flag" $?
inst "$F" --lead opencode; [ $RC = 1 ] && said "--lead-model" && [ "$(snap)" = "$before" ]; check "…and the same without --yes when stdin isn't a terminal" $?
inst "$F" --yes --lead opencode --lead-model big-pickle; [ $RC = 1 ] && said "provider/model" && [ "$(snap)" = "$before" ]; check "opencode model without a provider: refused" $?
inst "$F" --yes --lead-model "two words"; [ $RC = 1 ] && [ "$(snap)" = "$before" ]; check "a model id with a space: refused" $?
inst "$F" --yes --lead gemini; [ $RC = 2 ] && said "give claude, agy, codex or opencode" && [ "$(snap)" = "$before" ]; check "--lead gemini: bad argument (exit 2)" $?
inst "$F" --yes --host screen; [ $RC = 2 ] && [ "$(snap)" = "$before" ]; check "--host screen: bad argument (exit 2)" $?
inst "$F" --yes --frobnicate; [ $RC = 2 ] && said "unknown argument" && [ "$(snap)" = "$before" ]; check "an unknown flag: exit 2" $?
inst "$F" --yes --lead; [ $RC = 2 ] && said "needs a value" && [ "$(snap)" = "$before" ]; check "a flag without its value: exit 2" $?
inst "$F" --yes --workers claude,gemini; [ $RC = 1 ] && said "gemini" && [ "$(snap)" = "$before" ]; check "--workers with an unknown agent: refused" $?
inst "$F" --yes --checks ""; [ $RC = 1 ] && said "empty" && [ "$(snap)" = "$before" ]; check "--checks empty: refused" $?
inst "$F" --yes --checks "a
b"; [ $RC = 1 ] && said "one shell line" && [ "$(snap)" = "$before" ]; check "--checks over two lines: refused" $?
F2=$(fakes claude tmux)
inst "$F2" --yes --lead codex; [ $RC = 1 ] && said "codex isn't on PATH" && [ "$(snap)" = "$before" ]; check "--lead an agent that isn't installed: refused" $?
inst "$F2" --yes --host superset; [ $RC = 1 ] && said "isn't available" && [ "$(snap)" = "$before" ]; check "--host one that isn't installed: refused" $?
inst "$F2" --yes --workers claude,codex; [ $RC = 1 ] && said "codex isn't on PATH" && [ "$(snap)" = "$before" ]; check "--workers one that isn't installed: refused" $?
newrepo ".claude/settings.json={ not json"; before=$(snap); inst "$F" --yes
[ $RC = 1 ] && said "isn't a JSON object" && [ "$(snap)" = "$before" ]; check "an existing .claude/settings.json that isn't JSON: refused before writing" $?
newrepo '.claude/settings.json={"hooks":{"Stop":"not a list"}}'; before=$(snap); inst "$F" --yes
[ $RC = 1 ] && said "can't merge Jarvis's settings" && [ "$(snap)" = "$before" ]; check "a settings.json the merge can't read: refused before writing" $?
newrepo '.claude/settings.json={"model":"x"}'; before=$(snap); : > "$FAKE_LOG"
OUT=$(cd "$R" && PATH="$F:$nojq" "$BASH" "$INST" --yes </dev/null 2>&1); RC=$?
[ $RC = 1 ] && said "needs jq" && [ "$(snap)" = "$before" ]; check "an existing settings.json and no jq: refused before writing" $?
home_clean; check "no refusal wrote to the home folder" $?

echo "defaults: every agent and host, stdin not a terminal, no --yes"
F=$(fakes $ALL); newrepo 'package.json={"scripts":{"test":"vitest run","dev":"vite"}}' "package-lock.json={}"
inst "$F"
check "exit 0" $RC
said "agents: claude codex agy opencode" && said "hosts:  superset ultron tmux"; check "prints the agents and hosts it found" $?
conf JARVIS_LEAD_AGENT=claude && grep -q '^JARVIS_LEAD_MODEL=claude-opus-5-5 ' "$R/handoffs/jarvis.conf" && conf JARVIS_HOST=superset; check "jarvis.conf: lead claude/claude-opus-5-5, host superset" $?
said "claude-opus-5-5 (recommended)"; check "the model is shown as recommended" $?
conf JARVIS_MAX_CLAUDE=3 && conf JARVIS_AMBER=50 && conf JARVIS_RED=75; check "jarvis.conf: the setup skill's defaults for the caps and bands" $?
grep -qF '`npm test`' "$R/CLAUDE.md" && grep -qF '`npm test`' "$R/AGENTS.md"; check "checks inferred from package.json: npm test, in CLAUDE.md and AGENTS.md" $?
! grep -rlE '\{\{[A-Z_]+\}\}' "$R" --exclude-dir=.git | grep -q .; check "no {{placeholder}} left anywhere" $?
grep -q '^# Working in repo [0-9]* as a worker' "$R/AGENTS.md" && grep -q '^# Jarvis in repo [0-9]*$' "$R/handoffs/JARVIS.md"; check "the project name is the folder's" $?
grep -qF '`package-lock.json`' "$R/handoffs/JARVIS.md" && grep -qF '`package.json`' "$R/AGENTS.md"; check "the lockfile is Jarvis-only, package.json is a shared file" $?
grep -q 'in a browser' "$R/handoffs/JARVIS.md"; check "a dev script means the user verifies in a browser" $?
grep -q '^install.sh set this repo up for workers on claude, codex, agy, opencode\.' "$R/handoffs/JARVIS.md"; check "JARVIS.md names every detected agent as a worker" $?
for f in jarvis jarvis-lock.pl jev.sh; do [ -x "$R/handoffs/bin/$f" ] || false; done; check "handoffs/bin/jarvis, jarvis-lock.pl and jev.sh are executable" $?
(cd "$TPL/handoffs" && find . -type f ! -name .DS_Store) | while IFS= read -r f; do [ -f "$R/handoffs/$f" ] || exit 1; done; check "every template file under handoffs/ is there, lib/ and the .gitkeeps included" $?
cmp -s "$TPL/handoffs/bin/lib/lead.sh" "$R/handoffs/bin/lib/lead.sh" && cmp -s "$TPL/handoffs/bin/jarvis" "$R/handoffs/bin/jarvis"; check "…copied unchanged" $?
[ ! -e "$R/handoffs/skills" ]; check "a Claude lead gets no handoffs/skills/ copy" $?
jq -S . "$TPL/.claude/settings.json" > "$tmp/want.json" && jq -S . "$R/.claude/settings.json" | cmp -s - "$tmp/want.json"; check ".claude/settings.json is the template (no file there before)" $?
cmp -s "$TPL/.claude/agents/scout.md" "$R/.claude/agents/scout.md" && cmp -s "$TPL/.claude/agents/diff-reviewer.md" "$R/.claude/agents/diff-reviewer.md"; check ".claude/agents/ copied" $?
for l in handoffs/.jev/ handoffs/.jarvis/ handoffs/jarvis.local.conf; do grep -qxF "$l" "$R/.gitignore" || false; done; check ".gitignore has the three local paths" $?
said "you're Jarvis" && said "claude plugin install jarvis@jarvis"; check "next step: open Claude Code and say you're Jarvis" $?
only_listings; check "it called no agent CLI beyond tmux -V and opencode models" $?
home_clean; check "it wrote nothing to the home folder (user config untouched)" $?
no_paths; check "no local path in anything it wrote" $?
J > "$tmp/help" 2>&1; [ $? = 2 ] && grep -q 'jarvis lead' "$tmp/help" && ! grep -q 're-run jarvis:setup' "$tmp/help"; check "handoffs/bin/jarvis with no arguments loads every lib file and prints its help" $?
J lead --print >/dev/null 2>&1; [ $? = 1 ]; check "jarvis lead --print refuses a Claude lead, as it should" $?
echo '{}' | J hook prompt > "$tmp/hp" 2>&1 && [ ! -s "$tmp/hp" ]; check "jarvis hook prompt: exit 0, prints nothing" $?
inst "$F" --yes; [ $RC = 1 ] && said "already set up"; check "a second run is refused" $?

echo "--yes takes the same defaults"
newrepo; inst "$F" --yes
[ $RC = 0 ] && conf JARVIS_LEAD_AGENT=claude && conf JARVIS_HOST=superset && grep -qF '`true`' "$R/CLAUDE.md" && said 'checks are `true`'; check "--yes: claude, superset; no test command, so checks true with a note" $?
grep -q 'the checks only' "$R/handoffs/JARVIS.md"; check "an empty repo: verification by the checks only" $?

echo "codex lead (no claude)"
F=$(fakes codex agy opencode ultron tmux); newrepo "go.mod=module x"
inst "$F" --yes
[ $RC = 0 ] && conf JARVIS_LEAD_AGENT=codex && grep -q '^JARVIS_LEAD_MODEL=gpt-6-astra ' "$R/handoffs/jarvis.conf" && conf JARVIS_HOST=ultron; check "no claude: lead codex/gpt-6-astra, host ultron before tmux" $?
grep -qF '`go test ./...`' "$R/CLAUDE.md"; check "checks inferred from go.mod: go test ./..." $?
[ ! -e "$R/.claude" ] && [ -f "$R/CLAUDE.md" ]; check "no .claude/ without claude (CLAUDE.md still written)" $?
cmp -s "$root/plugins/jarvis/skills/run/SKILL.md" "$R/handoffs/skills/jarvis-run/SKILL.md" \
  && diff -r "$root/plugins/jarvis/skills/run/references" "$R/handoffs/skills/jarvis-run/references" >/dev/null; check "the run skill copied to handoffs/skills/jarvis-run/ (SKILL.md, references/)" $?
said "handoffs/bin/jarvis lead" && said "Ultron session" && said "trust this folder"; check "next step: jarvis lead, on its host" $?
only_listings && home_clean && no_paths; check "no model called, home untouched, no local paths" $?
J lead --print > "$tmp/lp" 2>&1; check "jarvis lead --print accepts the codex setup" $?
grep -q 'gpt-6-astra' "$tmp/lp" && grep -q 'You are Jarvis, on codex' "$tmp/lp" && grep -q 'handoffs/skills/jarvis-run/SKILL.md' "$tmp/lp"; check "…its model, its role prompt and the skill copy" $?

echo "agy lead"
F=$(fakes agy tmux); newrepo "Cargo.toml=[package]"
inst "$F" --yes
[ $RC = 0 ] && conf JARVIS_LEAD_AGENT=agy && grep -q '^JARVIS_LEAD_MODEL=gemini-4-neon-high ' "$R/handoffs/jarvis.conf" && conf JARVIS_HOST=tmux; check "agy only: lead agy/gemini-4-neon-high, host tmux" $?
said "recommended, experimental"; check "the model is shown as recommended, experimental" $?
said "agy plugin install $root/plugins/jarvis" && ! grep -q 'plugin install' "$FAKE_LOG"; check "prints agy plugin install <the plugin folder>, doesn't run it" $?
grep -qF '`cargo test`' "$R/AGENTS.md"; check "checks inferred from Cargo.toml: cargo test" $?
[ ! -e "$R/handoffs/skills" ] && [ ! -e "$R/.claude" ]; check "no skill copy (agy reads the plugin) and no .claude/" $?
only_listings && home_clean && no_paths; check "no model called, home untouched, no local paths" $?
J lead --print > "$tmp/lp" 2>&1 && grep -q 'JARVIS_MODEL=gemini-4-neon-high' "$tmp/lp" && grep -q 'You are Jarvis, on agy' "$tmp/lp"; check "jarvis lead --print accepts the agy setup" $?

echo "opencode lead"
F=$(fakes opencode tmux); newrepo "pyproject.toml=[tool.pytest.ini_options]"
inst "$F" --yes --lead-model opencode/big-pickle
[ $RC = 0 ] && conf JARVIS_LEAD_AGENT=opencode && grep -q '^JARVIS_LEAD_MODEL=opencode/big-pickle ' "$R/handoffs/jarvis.conf"; check "--lead-model opencode/big-pickle with --yes: written" $?
grep -qF '`pytest`' "$R/CLAUDE.md"; check "checks inferred from pyproject.toml: pytest" $?
[ -s "$R/handoffs/skills/jarvis-run/SKILL.md" ]; check "the run skill copied for an opencode lead" $?
J lead --print > "$tmp/lp" 2>&1 && grep -q 'opencode/big-pickle' "$tmp/lp"; check "jarvis lead --print accepts the opencode setup" $?

echo "flags"
F=$(fakes $ALL); newrepo "Makefile=test:"
inst "$F" --lead=codex --workers codex,claude,codex --host tmux --checks 'make check && echo "a/b" | grep -q a\1' --yes
[ $RC = 0 ] && conf JARVIS_LEAD_AGENT=codex && conf JARVIS_HOST=tmux; check "--lead=codex --host tmux" $?
grep -qF '`make check && echo "a/b" | grep -q a\1`' "$R/CLAUDE.md" && grep -qF '`make check && echo "a/b" | grep -q a\1`' "$R/AGENTS.md"; check "--checks verbatim, & / \\ and quotes kept" $?
grep -q 'workers on codex, claude\.' "$R/handoffs/JARVIS.md"; check "--workers in order, deduplicated" $?
[ -f "$R/.claude/settings.json" ] && [ -s "$R/handoffs/skills/jarvis-run/SKILL.md" ]; check "claude installed: .claude/ written for a codex lead too, beside the skill copy" $?
newrepo "Makefile=test:"; inst "$F" --yes --host ultron --lead agy --lead-model gemini-4-neon-low
[ $RC = 0 ] && conf JARVIS_HOST=ultron && grep -q '^JARVIS_LEAD_MODEL=gemini-4-neon-low ' "$R/handoffs/jarvis.conf" && grep -qF '`make test`' "$R/CLAUDE.md"; check "--host ultron, --lead-model for agy; checks from the Makefile: make test" $?
newrepo 'package.json={"scripts":{"test":"echo \"Error: no test specified\" && exit 1"}}' "pnpm-lock.yaml=x"
inst "$F" --yes; grep -qF '`true`' "$R/CLAUDE.md"; check "npm's placeholder test script isn't a check" $?
newrepo 'package.json={"scripts":{"test":"vitest"}}' "pnpm-lock.yaml=x"
inst "$F" --yes; grep -qF '`pnpm test`' "$R/CLAUDE.md"; check "a pnpm lockfile: pnpm test" $?

echo "merging into what's there"
cat > "$tmp/user.json" <<'EOF'
{
  "model": "opus",
  "env": {"CLAUDE_CODE_SUBAGENT_MODEL": "haiku", "MINE": "1"},
  "permissions": {"allow": ["Bash(ls)", "Bash(handoffs/bin/jarvis *)", "Bash(./handoffs/bin/jarvis usage *)"], "deny": ["Bash(rm -rf *)"]},
  "hooks": {
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "my-hook"},
                                    {"type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/handoffs/bin/jarvis hook prompt", "timeout": 10}]}],
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "bash-guard"}]}]
  },
  "statusLine": {"type": "command", "command": "my-status --say 'hi'"},
  "enabledPlugins": {"x@y": true}
}
EOF
newrepo "CLAUDE.md=# My rules" "AGENTS.md=# Agents: be nice" ".gitignore=node_modules" ".claude/agents/scout.md=my scout"
cp "$tmp/user.json" "$R/.claude/settings.json"
inst "$F" --yes
s="$R/.claude/settings.json"
[ $RC = 0 ]; check "exit 0" $?
jq -e '.model == "opus" and .env.MINE == "1" and .env.CLAUDE_CODE_SUBAGENT_MODEL == "haiku" and .env.ENABLE_STOP_REVIEW == "0" and .enabledPlugins["x@y"] == true' "$s" >/dev/null; check "the user's keys kept; their env values win; Jarvis's env added" $?
jq -e '.permissions.deny == ["Bash(rm -rf *)"] and (.permissions.allow | index("Bash(ls)")) != null
       and (.permissions.allow | map(select(. == "Bash(handoffs/bin/jarvis *)" or . == "Bash(./handoffs/bin/jarvis usage *)")) | length) == 0' "$s" >/dev/null; check "deny and the user's allow rules kept; the broad and retired jarvis rules gone" $?
jq -e --slurpfile t "$TPL/.claude/settings.json" '($t[0].permissions.allow - .permissions.allow) == [] and (.permissions.allow | length) == (.permissions.allow | unique | length)' "$s" >/dev/null; check "every reviewed allow rule added, none twice" $?
jq -e '[.hooks.UserPromptSubmit[].hooks[].command] | (index("my-hook") != null) and (map(select(endswith("jarvis hook prompt"))) | length) == 1 and (map(select(endswith("jarvis hook event working"))) | length) == 1' "$s" >/dev/null; check "UserPromptSubmit: the user's hook kept, Jarvis's two there once each" $?
jq -e '(.hooks.PreToolUse | length) == 2 and .hooks.PreToolUse[0].matcher == "Bash" and .hooks.PreToolUse[1].matcher == "Agent|Task|Edit|Write|MultiEdit"' "$s" >/dev/null; check "PreToolUse: the Fable guard appended as its own matcher" $?
jq -e '.hooks.Stop and .hooks.Notification and .hooks.SessionEnd' "$s" >/dev/null; check "Stop, Notification and SessionEnd added" $?
jq -e --slurpfile t "$TPL/.claude/settings.json" '.statusLine == $t[0].statusLine' "$s" >/dev/null; check "statusLine is the tap" $?
v=$(cd "$R" && sh -c '. handoffs/jarvis.conf; printf %s "$JARVIS_STATUSLINE_CMD"'); [ "$v" = "my-status --say 'hi'" ]; check "the old statusline goes to JARVIS_STATUSLINE_CMD, quotes intact" $?
[ "$(head -n 1 "$R/CLAUDE.md")" = "# My rules" ] && grep -q '^# Working in repo' "$R/CLAUDE.md" && [ "$(head -n 1 "$R/AGENTS.md")" = "# Agents: be nice" ] && grep -q 'as a worker$' "$R/AGENTS.md"; check "existing CLAUDE.md and AGENTS.md kept, Jarvis's part appended" $?
said "appended Jarvis's part to your CLAUDE.md"; check "…and it says so" $?
[ "$(cat "$R/.claude/agents/scout.md")" = "my scout" ] && said "kept your .claude/agents/scout.md" && [ -f "$R/.claude/agents/diff-reviewer.md" ]; check "an existing agent of the same name is left alone, and named" $?
[ "$(head -n 1 "$R/.gitignore")" = node_modules ] && [ "$(grep -c . "$R/.gitignore")" = 4 ]; check ".gitignore: its line kept, three added on lines of their own" $?

echo "on a terminal"
# A pseudo-terminal from python3's pty module. Each answer is typed only once install.sh
# has printed a prompt (output ending in ": "), so nothing races its reads.
cat > "$tmp/drive-pty.py" <<'PY'
import os, pty, select, sys, time
answers = sys.argv[1].split("\n") if sys.argv[1] else []
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[2], sys.argv[2:])
out, seen, end = b"", 0, time.time() + 30
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    if answers and len(out) > seen and out.endswith(b": "):
        os.write(fd, answers.pop(0).encode() + b"\n")
        seen = len(out)
else:
    os.kill(pid, 9)
_, st = os.waitpid(pid, 0)
sys.stdout.write(out.decode(errors="replace").replace("\r", ""))
sys.exit(os.WEXITSTATUS(st) if os.WIFEXITED(st) else 99)
PY
if command -v python3 >/dev/null 2>&1; then
  # tty <fakes> <answers, one per line> <args…>: run install.sh on a terminal, answering its prompts
  tty() {
    local f=$1 in=$2; shift 2
    : > "$FAKE_LOG"
    OUT=$(cd "$R" && PATH="$f:$sys" python3 -I "$tmp/drive-pty.py" "$in" "$BASH" "$INST" "$@" 2>&1); RC=$?
  }
  F=$(fakes claude codex ultron tmux); newrepo
  tty "$F" "gemini
codex
claude-Fable-9

codex,foo
codex

make check && echo a/b"
  [ $RC = 0 ] && conf JARVIS_LEAD_AGENT=codex && grep -q '^JARVIS_LEAD_MODEL=gpt-6-astra ' "$R/handoffs/jarvis.conf" && conf JARVIS_HOST=ultron; check "asks: a bad lead and a Fable model are asked again; empty takes the default" $?
  said "Fable never runs Jarvis" && said "gemini: pick one of claude, codex" && said "foo: give claude"; check "…saying why" $?
  grep -q 'workers on codex\.' "$R/handoffs/JARVIS.md" && grep -qF '`make check && echo a/b`' "$R/CLAUDE.md"; check "…workers and checks as typed" $?
  F=$(fakes opencode tmux); newrepo
  tty "$F" "
2



"
  [ $RC = 0 ] && grep -q '^JARVIS_LEAD_MODEL=anthropic/claude-sonnet-5-5 ' "$R/handoffs/jarvis.conf"; check "opencode: lists opencode models and takes a number" $?
  said "opencode/big-pickle" && ! said "not an id"; check "…the list holds only well-formed provider/model ids" $?
  newrepo; tty "$F" "" --yes --lead-model opencode/big-pickle
  [ $RC = 0 ] && conf JARVIS_LEAD_AGENT=opencode && ! said "]: "; check "--yes on a terminal never prompts" $?
  newrepo; tty "$F" "" --lead opencode --lead-model opencode/big-pickle --workers opencode --host tmux --checks true
  [ $RC = 0 ] && ! said "]: "; check "every choice given by a flag: no prompt" $?
else
  echo "  skip  no python3: the prompts weren't tested"
fi

home_clean; check "nothing anywhere wrote to the home folder" $?
echo
if [ $fails = 0 ]; then echo "installtest: all passed ($BASH_VERSION)"; else echo "installtest: $fails FAILED ($BASH_VERSION)"; fi
[ $fails = 0 ]; exit
}
