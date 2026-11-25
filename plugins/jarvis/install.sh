#!/usr/bin/env bash
# install.sh — set up the Jarvis workflow in the git repo you run it from, from any agent
# CLI: no Claude Code needed. It is jarvis:setup's sections 1–4 made mechanical. It finds
# the agent CLIs and hosts on PATH, asks (or takes from flags) the lead, its model, the
# workers, the host and the checks, then writes CLAUDE.md, AGENTS.md, handoffs/ and, when
# claude is installed, .claude/ from skills/setup/templates/. Where the skill asks for
# judgment it takes the default and says how to change it.
# It calls no model, writes nothing outside the repo and never the user's own CLI config.
# A repo already set up is refused: upgrades are jarvis:setup's.
#
#   cd <your repo> && <a clone of jarvis>/plugins/jarvis/install.sh [flags]
#     --lead claude|agy|codex|opencode   the agent Jarvis runs on
#     --lead-model <id>                  its model (opencode: provider/model, required)
#     --workers a,b                      the agents workers may run on
#     --host superset|ultron|tmux        where workers run
#     --checks "<cmd>"                   what workers run before handing off
#     --yes                              accept the defaults, never prompt
# It prompts only when stdin is a terminal and --yes isn't given; otherwise it takes the
# defaults. Exit 0 = set up, 1 = refused (nothing written), 2 = bad arguments.
# shellcheck disable=SC2015 # "A && B || die": it dies when either fails, as meant
set -u

PLUGIN=$(cd "$(dirname "$0")" && pwd -P)
T="$PLUGIN/skills/setup/templates"
RUN="$PLUGIN/skills/run"
AGENTS="claude codex agy opencode"    # also the lead's default order
HOSTS="superset ultron tmux"          # also the host's default order
MODEL_RE='^[A-Za-z0-9][A-Za-z0-9._:/@+-]*$'
IGNORES="handoffs/.jev/ handoffs/.jarvis/ handoffs/jarvis.local.conf"

say() { printf '%s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }
bad() { printf 'install.sh: %s\n' "$*" >&2; printf 'usage: install.sh [--lead claude|agy|codex|opencode] [--lead-model <id>] [--workers a,b] [--host superset|ultron|tmux] [--checks "<cmd>"] [--yes]\n' >&2; exit 2; }
have() { command -v "$1" >/dev/null 2>&1; }
in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }
comma() { printf '%s' "$*" | sed 's/ /, /g'; }

# ---------------------------------------------------------------- arguments

O_LEAD="" O_MODEL="" O_WORKERS="" O_HOST="" O_CHECKS="" YES=0
G_LEAD=0 G_MODEL=0 G_WORKERS=0 G_HOST=0 G_CHECKS=0
opt() { # $1 = flag, $2 = value
  case "$1" in
    --lead) O_LEAD=$2; G_LEAD=1 ;;
    --lead-model) O_MODEL=$2; G_MODEL=1 ;;
    --workers) O_WORKERS=$2; G_WORKERS=1 ;;
    --host) O_HOST=$2; G_HOST=1 ;;
    --checks) O_CHECKS=$2; G_CHECKS=1 ;;
  esac
}
while [ $# -gt 0 ]; do
  case "$1" in
    --lead|--lead-model|--workers|--host|--checks)
      [ $# -ge 2 ] || bad "$1 needs a value"
      opt "$1" "$2"; shift 2 ;;
    --lead=*|--lead-model=*|--workers=*|--host=*|--checks=*) opt "${1%%=*}" "${1#*=}"; shift ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) sed -n '2,19s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) bad "unknown argument: $1" ;;
  esac
done
if [ $G_LEAD = 1 ] && ! in_list "$O_LEAD" "$AGENTS"; then bad "--lead $O_LEAD: give claude, agy, codex or opencode"; fi
if [ $G_HOST = 1 ] && ! in_list "$O_HOST" "$HOSTS"; then bad "--host $O_HOST: give superset, ultron or tmux"; fi
INTERACTIVE=0
[ $YES = 0 ] && [ -t 0 ] && INTERACTIVE=1

ask() { # $1 = question, $2 = default: the answer in REPLY, the default when it's empty
  printf '%s [%s]: ' "$1" "$2"
  IFS= read -r REPLY || REPLY=""
  [ -n "$REPLY" ] || REPLY=$2
}

# ---------------------------------------------------------------- checks of the ground

[ -d "$T/handoffs/bin" ] && [ -f "$RUN/SKILL.md" ] || die "can't find the templates next to this script ($T): run install.sh from a clone of the jarvis repo"
have git || die "no git on PATH: install it first"
top=$(git rev-parse --show-toplevel 2>/dev/null) || die "this isn't a git repo: run install.sh from the root of the repo to set up (git init first)"
[ "$(cd "$top" && pwd -P)" = "$(pwd -P)" ] || die "run install.sh from the repo's root, not a folder inside it: cd $top"
[ ! -e handoffs/JARVIS.md ] || die "already set up; upgrade with jarvis:setup (handoffs/JARVIS.md exists)"
for f in handoffs/OPEN.md handoffs/jarvis.conf handoffs/bin/jarvis; do
  [ ! -e "$f" ] || die "already set up; upgrade with jarvis:setup ($f exists: an older Jarvis)"
done
[ -f CLAUDE.md ] && grep -qE 'handoffs/bin/jarvis|Jarvis workflow' CLAUDE.md \
  && die "already set up; upgrade with jarvis:setup (CLAUDE.md names the Jarvis workflow: an older Jarvis)"

found_agents=""
for a in $AGENTS; do have "$a" && found_agents="$found_agents${found_agents:+ }$a"; done
found_hosts=""
have superset && found_hosts="superset"
have ultron && found_hosts="$found_hosts${found_hosts:+ }ultron"
old_tmux=""
if have tmux; then
  v=$(tmux -V 2>/dev/null); v=${v#tmux }; v=${v#next-}; major=${v%%.*}
  case "$major" in ''|*[!0-9]*) major=0 ;; esac
  if [ "$major" -ge 3 ]; then found_hosts="$found_hosts${found_hosts:+ }tmux"; else old_tmux=" (tmux $v is too old: 3.0 or later)"; fi
fi
say "agents: ${found_agents:-none}"
say "hosts:  ${found_hosts:-none}$old_tmux"
[ -n "$found_agents" ] || die "no agent CLI on PATH: install one of Claude Code (claude), Codex (codex), Antigravity (agy) or OpenCode (opencode), then run this again"
[ -n "$found_hosts" ] || die "no host for the workers: install Superset (https://docs.superset.sh/install), Ultron, or tmux 3.0 or later from your package manager, then run this again"

# ---------------------------------------------------------------- the choices

model_ok() { # $1 = lead, $2 = model: prints why not and returns 1
  case "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" in *fable*) echo "$2: Fable never runs Jarvis"; return 1 ;; esac
  case "$2" in
    "") echo "the model id is empty"; return 1 ;;
    *[[:space:]]*|*[[:cntrl:]]*) echo "'$2' has a space or control character in it"; return 1 ;;
  esac
  printf '%s\n' "$2" | grep -Eq "$MODEL_RE" || { echo "$2 isn't a model id"; return 1; }
  if [ "$1" = opencode ]; then
    case "$2" in */*/*|*/) echo "$2: give it as provider/model (opencode models lists them)"; return 1 ;; */*) ;;
      *) echo "$2: give it as provider/model (opencode models lists them)"; return 1 ;; esac
  fi
  return 0
}
default_model() {
  case "$1" in claude) echo claude-opus-5-5 ;; agy) echo gemini-4-neon-high ;; codex) echo gpt-6-astra ;; *) echo "" ;; esac
}
model_note() {
  case "$1" in claude) echo " (recommended)" ;; agy) echo " (recommended, experimental: Neon as Jarvis hasn't passed a live trial yet)" ;; *) echo "" ;; esac
}
opencode_models() { # the ids `opencode models` lists (it calls no model), cut off after 30 s
  if have perl; then perl -e 'alarm shift; exec @ARGV or exit 127' 30 opencode models </dev/null 2>/dev/null
  else opencode models </dev/null 2>/dev/null; fi | awk -v re="$MODEL_RE" '$1 ~ re && $1 ~ /\// && length($1) <= 100 && !seen[$1]++ {print $1}'
}

# the lead
lead=""
for a in $AGENTS; do in_list "$a" "$found_agents" && { lead=$a; break; }; done
if [ $G_LEAD = 1 ]; then
  in_list "$O_LEAD" "$found_agents" || die "--lead $O_LEAD: $O_LEAD isn't on PATH (found: $found_agents)"
  lead=$O_LEAD
elif [ $INTERACTIVE = 1 ]; then
  while :; do
    ask "Jarvis runs on ($(comma "$found_agents"))" "$lead"
    in_list "$REPLY" "$found_agents" && { lead=$REPLY; break; }
    say "  $REPLY: pick one of $(comma "$found_agents")"
  done
fi

# its model
model=$(default_model "$lead")
if [ $G_MODEL = 1 ]; then
  why=$(model_ok "$lead" "$O_MODEL") || die "--lead-model $why"
  model=$O_MODEL
elif [ "$lead" = opencode ]; then
  [ $INTERACTIVE = 1 ] || die "an OpenCode Jarvis has no default model: pass --lead-model provider/model (opencode models lists them)"
  list=$(opencode_models)
  if [ -n "$list" ]; then
    say "OpenCode's models (opencode models):"
    printf '%s\n' "$list" | awk '{printf "  %3d  %s\n", NR, $0}'
  else
    say "opencode models listed nothing: type the id as provider/model"
  fi
  while :; do
    printf 'Jarvis model, a number or provider/model: '
    IFS= read -r REPLY || die "no model chosen: an OpenCode Jarvis needs one (--lead-model provider/model)"
    case "$REPLY" in ''|*[!0-9]*) m=$REPLY ;; *) m=$(printf '%s\n' "$list" | sed -n "${REPLY}p") ;; esac
    if why=$(model_ok opencode "$m"); then model=$m; break; fi
    say "  ${why:-$REPLY: not on the list}"
  done
elif [ $INTERACTIVE = 1 ]; then
  while :; do
    ask "Jarvis's model$(model_note "$lead")" "$model"
    if why=$(model_ok "$lead" "$REPLY"); then model=$REPLY; break; fi
    say "  $why"
  done
fi

# the workers
workers=$found_agents
if [ $G_WORKERS = 1 ] || [ $INTERACTIVE = 1 ]; then
  if [ $G_WORKERS = 1 ]; then w=$O_WORKERS; else ask "Workers may run on" "$(comma "$found_agents")"; w=$REPLY; fi
  while :; do
    workers="" why=""
    set -f   # a * typed here is a word, not the files in this folder
    for a in $(printf '%s' "$w" | tr ',' ' '); do
      if ! in_list "$a" "$AGENTS"; then why="$a: give claude, agy, codex or opencode"; break; fi
      if ! in_list "$a" "$found_agents"; then why="$a isn't on PATH (found: $found_agents)"; break; fi
      in_list "$a" "$workers" || workers="$workers${workers:+ }$a"
    done
    set +f
    [ -n "$why" ] || [ -n "$workers" ] || why="no workers given"
    [ -n "$why" ] || break
    [ $G_WORKERS = 0 ] || die "--workers $why"
    say "  $why"; ask "Workers may run on" "$(comma "$found_agents")"; w=$REPLY
  done
fi

# the host
host=""
for h in $HOSTS; do in_list "$h" "$found_hosts" && { host=$h; break; }; done
if [ $G_HOST = 1 ]; then
  in_list "$O_HOST" "$found_hosts" || die "--host $O_HOST: it isn't available here (found: $found_hosts)"
  host=$O_HOST
elif [ $INTERACTIVE = 1 ]; then
  while :; do
    ask "Workers' host ($(comma "$found_hosts"))" "$host"
    in_list "$REPLY" "$found_hosts" && { host=$REPLY; break; }
    say "  $REPLY: pick one of $(comma "$found_hosts")"
  done
fi

# the checks, inferred as jarvis:setup's interview does
infer_checks() {
  if [ -f package.json ] && grep -Eq '"test"[[:space:]]*:' package.json && ! grep -q 'no test specified' package.json; then
    if [ -f pnpm-lock.yaml ]; then echo "pnpm test"
    elif [ -f yarn.lock ]; then echo "yarn test"
    elif [ -f bun.lock ] || [ -f bun.lockb ]; then echo "bun run test"
    else echo "npm test"; fi
  elif [ -f pytest.ini ] || [ -f conftest.py ] || { [ -f pyproject.toml ] && grep -q 'pytest' pyproject.toml; } \
       || { [ -f setup.cfg ] && grep -q 'tool:pytest' setup.cfg; } || { [ -f tox.ini ] && grep -q 'pytest' tox.ini; }; then
    echo "pytest"
  elif [ -f go.mod ]; then echo "go test ./..."
  elif [ -f Cargo.toml ]; then echo "cargo test"
  else
    for f in Makefile makefile GNUmakefile; do
      [ -f "$f" ] && grep -Eq '^test[[:space:]]*:' "$f" && { echo "make test"; break; }
    done
  fi
}
checks=$(infer_checks)
checks_note=""
[ -n "$checks" ] || { checks=true; checks_note="no test command found, so the checks are \`true\`: put the real ones on the Checks lines of CLAUDE.md and AGENTS.md"; }
checks_ok() { # prints why not and returns 1
  case "$1" in "") echo "the checks are empty: give a command, or true"; return 1 ;; esac
  case "$1" in *"
"*) echo "the checks must be one shell line"; return 1 ;; esac
  case "$1" in *'`'*) echo "the checks can't contain a backtick: they go inside one in CLAUDE.md and AGENTS.md"; return 1 ;; esac
  return 0
}
if [ $G_CHECKS = 1 ]; then
  why=$(checks_ok "$O_CHECKS") || die "--checks: $why"
  checks=$O_CHECKS checks_note=""
elif [ $INTERACTIVE = 1 ]; then
  while :; do
    ask "Checks workers run before handing off" "$checks"
    if why=$(checks_ok "$REPLY"); then [ "$REPLY" = "$checks" ] || checks_note=""; checks=$REPLY; break; fi
    say "  $why"
  done
fi

# what the .claude/ merge needs, checked before anything is written
claude_files=0
in_list claude "$found_agents" && claude_files=1
if [ $claude_files = 1 ] && [ -e .claude/settings.json ]; then
  have jq || die ".claude/settings.json exists and merging into it needs jq: install jq, then run this again"
  jq -e 'type == "object"' .claude/settings.json >/dev/null 2>&1 || die ".claude/settings.json isn't a JSON object: fix it, then run this again"
  # jarvis:setup section 3's merge: the user's keys and rules kept, Jarvis's appended once,
  # its broad and retired allow rules removed, the statusline tap in (the old one goes to
  # JARVIS_STATUSLINE_CMD). Made now, so a file it can't merge stops before any write.
  old_tap=$(jq -r '(.statusLine | objects | .command) // empty' .claude/settings.json)
  tap=$(jq -r '.statusLine.command' "$T/.claude/settings.json")
  merged=$(jq --slurpfile t "$T/.claude/settings.json" '
      $t[0] as $t
      | ["Bash(handoffs/bin/jarvis *)", "Bash(./handoffs/bin/jarvis *)",
         "Bash(handoffs/bin/jarvis lessons select *)", "Bash(./handoffs/bin/jarvis lessons select *)",
         "Bash(handoffs/bin/jarvis usage *)", "Bash(./handoffs/bin/jarvis usage *)"] as $retired
      | .permissions = (.permissions // {})
      | .permissions.allow = ((.permissions.allow // []) | map(select(. as $r | $retired | index([$r]) | not))
                              | . + ($t.permissions.allow - .))
      | .env = ($t.env + (.env // {}))
      | .hooks = reduce ($t.hooks | to_entries[]) as $e (.hooks // {};
          .[$e.key] = reduce $e.value[] as $g (.[$e.key] // [];
            reduce $g.hooks[] as $h (.;
              if any(.[]?.hooks[]?; .command == $h.command) then .
              else ([range(length) as $k | select(.[$k].matcher == $g.matcher) | $k] | first) as $i
                | if $i == null then . + [$g | .hooks = [$h]] else .[$i].hooks += [$h] end
              end)))
      | .statusLine = $t.statusLine
      | .enabledPlugins = (.enabledPlugins // {})
    ' .claude/settings.json 2>&1) \
    || die "can't merge Jarvis's settings into .claude/settings.json ($merged): fix it, then run this again"
fi

# ---------------------------------------------------------------- the placeholders

lockfiles=""
for f in package-lock.json pnpm-lock.yaml yarn.lock bun.lock bun.lockb uv.lock poetry.lock Pipfile.lock Cargo.lock go.sum Gemfile.lock composer.lock; do
  [ -f "$f" ] && lockfiles="$lockfiles${lockfiles:+, }\`$f\`"
done
only=""
[ -z "$(find . -maxdepth 3 -type d -name migrations -not -path './.git/*' -not -path './node_modules/*' 2>/dev/null | head -n 1)" ] \
  || only="applying database migrations, "
[ -z "$lockfiles" ] || only="${only}editing $lockfiles, "
only="${only}deploys and releases, and touching real user data."

web=0
for f in index.html next.config.* vite.config.* astro.config.* svelte.config.*; do [ -e "$f" ] && web=1; done
[ -f package.json ] && grep -Eq '"(dev|start)"[[:space:]]*:' package.json && web=1
if [ $web = 1 ]; then
  verify="the user opens the app in a browser: the handoff names the URL, the page and what to look for."
elif [ -f package.json ] || [ -f pyproject.toml ] || [ -f setup.py ] || [ -f go.mod ] || [ -f Cargo.toml ] || [ -f Makefile ]; then
  verify="the user runs the commands the handoff lists and compares what they print with what it says to expect."
else
  verify="the checks only: the handoff says which ran and what they printed."
fi

shared=""
for f in package.json pyproject.toml Cargo.toml go.mod Makefile tsconfig.json setup.cfg .github/workflows; do
  [ -e "$f" ] && shared="$shared\`$f\`, "
done
shared="$shared\`.gitignore\`"

export P_PROJECT_NAME P_APP_DIR_NOTE P_CHECKS P_JARVIS_ONLY P_VERIFY P_SHARED_FILES P_FREE_TIER_NEVER P_MAX_CLAUDE P_AMBER P_RED
P_PROJECT_NAME=$(basename "$(pwd -P)")
P_APP_DIR_NOTE="The app lives at the repo root."
P_CHECKS=$checks
P_JARVIS_ONLY=$only
P_VERIFY=$verify
P_SHARED_FILES=$shared
P_FREE_TIER_NEVER="credentials, production data or proprietary logic: third parties serve those models."
P_MAX_CLAUDE=3 P_AMBER=50 P_RED=75

say ""
say "lead:    $lead"
say "model:   $model$(model_note "$lead")"
say "workers: $(comma "$workers")"
say "host:    $host"
say "checks:  $checks"

# ---------------------------------------------------------------- writing

fill() { # $1 = a file: every {{NAME}} becomes $P_NAME, verbatim (no sed: values hold & and /)
  awk '{
    out = ""; line = $0
    while ((i = index(line, "{{")) > 0) {
      rest = substr(line, i + 2); j = index(rest, "}}")
      if (j == 0) break
      name = substr(rest, 1, j - 1)
      if (("P_" name) in ENVIRON) { out = out substr(line, 1, i - 1) ENVIRON["P_" name]; line = substr(rest, j + 2) }
      else { out = out substr(line, 1, i + 1); line = rest }
    }
    print out line
  }' "$1" > "$1.install.$$" && mv "$1.install.$$" "$1" || die "can't write $1"
}
conf_set() { # $1 = file, $2 = ERE the line starts with, $3 = the new start of that line (the rest kept), else appended
  RE=$2 NEW=$3 awk 'BEGIN { re = ENVIRON["RE"]; new = ENVIRON["NEW"] }
    !done && match($0, re) { print new substr($0, RSTART + RLENGTH); done = 1; next } { print }
    END { if (!done) print new }' "$1" > "$1.install.$$" && mv "$1.install.$$" "$1" || die "can't write $1"
}
copy_tree() { # $1 = from, $2 = to: every file not already there; prints the ones kept
  (cd "$1" && find . -type d) | while IFS= read -r d; do mkdir -p "$2/$d" || exit 1; done || die "can't make the folders in $2"
  (cd "$1" && find . -type f ! -name .DS_Store) | while IFS= read -r f; do
    if [ -e "$2/$f" ]; then echo "  kept your ${2%/}/${f#./}"; continue; fi
    cp -p "$1/$f" "$2/$f" || exit 1
  done || die "can't copy $1 to $2"
}

say ""
copy_tree "$T/handoffs" handoffs
chmod +x handoffs/bin/jarvis handoffs/bin/jarvis-lock.pl handoffs/bin/jev.sh || die "can't chmod handoffs/bin"
fill handoffs/JARVIS.md
fill handoffs/jarvis.conf
conf_set handoffs/jarvis.conf '^JARVIS_HOST=[^ ]*' "JARVIS_HOST=$host"
conf_set handoffs/jarvis.conf '^# JARVIS_LEAD_AGENT=[^ ]*' "JARVIS_LEAD_AGENT=$lead"
conf_set handoffs/jarvis.conf '^# JARVIS_LEAD_MODEL=[^ ]*' "JARVIS_LEAD_MODEL=$model"
{ printf '\n## Worker agents\n\n'
  printf 'install.sh set this repo up for workers on %s. Spawn no other agent until the user has installed it and added it here.\n' "$(comma "$workers")"
} >> handoffs/JARVIS.md || die "can't write handoffs/JARVIS.md"
say "wrote handoffs/ (JARVIS.md, OPEN.md, jarvis.conf, bin/, briefs/)"

for f in CLAUDE.md AGENTS.md; do
  cp "$T/$f" "$f.install.$$" && fill "$f.install.$$" || die "can't write $f"
  if [ -e "$f" ]; then
    { printf '\n'; cat "$f.install.$$"; } >> "$f" && rm -f "$f.install.$$" || die "can't write $f"
    say "appended Jarvis's part to your $f: read it through and merge any rule that now says the same thing twice"
  else
    mv "$f.install.$$" "$f" || die "can't write $f"
    say "wrote $f"
  fi
done

if [ "$lead" = codex ] || [ "$lead" = opencode ]; then
  mkdir -p handoffs/skills/jarvis-run || die "can't make handoffs/skills/jarvis-run"
  copy_tree "$RUN" handoffs/skills/jarvis-run
  say "wrote handoffs/skills/jarvis-run/ (the jarvis:run skill, which a $lead Jarvis reads as a file)"
fi

if [ $claude_files = 1 ]; then
  mkdir -p .claude/agents || die "can't make .claude/agents"
  copy_tree "$T/.claude/agents" .claude/agents
  if [ -e .claude/settings.json ]; then
    printf '%s\n' "$merged" > .claude/settings.json.install.$$ && mv .claude/settings.json.install.$$ .claude/settings.json \
      || { rm -f .claude/settings.json.install.$$; die "can't merge .claude/settings.json"; }
    if [ -n "$old_tap" ] && [ "$old_tap" != "$tap" ]; then
      case "$old_tap" in
        *"
"*) say "your statusLine command has a newline in it: put it in handoffs/jarvis.conf as JARVIS_STATUSLINE_CMD by hand" ;;
        *) q=$(printf '%s' "$old_tap" | sed "s/'/'\\\\''/g")
           printf "\n# The repo's own statusline, which the tap (jarvis statusline) runs after saving its reading.\nJARVIS_STATUSLINE_CMD='%s'\n" "$q" >> handoffs/jarvis.conf \
             || die "can't write handoffs/jarvis.conf" ;;
      esac
    fi
    say "merged Jarvis's hooks, permissions, env and statusline tap into your .claude/settings.json (git diff shows them)"
  else
    cp "$T/.claude/settings.json" .claude/settings.json || die "can't write .claude/settings.json"
    say "wrote .claude/ (settings.json, agents/)"
  fi
fi

touch .gitignore || die "can't write .gitignore"
[ ! -s .gitignore ] || [ -z "$(tail -c 1 .gitignore)" ] || printf '\n' >> .gitignore
for l in $IGNORES; do grep -qxF "$l" .gitignore || printf '%s\n' "$l" >> .gitignore; done

left=$(grep -lE '\{\{[A-Z_]+\}\}' CLAUDE.md AGENTS.md handoffs/JARVIS.md handoffs/jarvis.conf 2>/dev/null)
[ -z "$left" ] || say "WARNING: a {{PLACEHOLDER}} is left in $(comma "$left"): the templates gained one this script doesn't know; fill it by hand"

# ---------------------------------------------------------------- what's next

say ""
say "Defaults taken (change them in the files named):"
[ -z "$checks_note" ] || say "- $checks_note"
say "- 3 Claude sessions at once here, Jarvis included; bands amber 50%, red 75% (handoffs/jarvis.conf)"
say "- JARVIS_HOST=$host pins the host; empty it in handoffs/jarvis.conf to pick it per terminal"
say "- only Jarvis: $only (handoffs/JARVIS.md, AGENTS.md)"
say "- verification: $verify (handoffs/JARVIS.md, AGENTS.md)"
[ $claude_files = 0 ] || say "- statusline tap on; no plugins switched off; heavy suites not wrapped in jarvis lock (jarvis:setup's interview does both)"
[ $claude_files = 1 ] || say "- no .claude/: claude isn't installed (jarvis:setup adds it once it is)"
say "- Jev installed and inert: handoffs/bin/jev.sh does nothing without TYPESAFE_API_KEY"
have jq || say "- jq is missing: jarvis spawn, the hooks and the band need it"
have python3 || say "- python3 is missing: jarvis usage, merge --verify and spawn's overlap check need it"
have perl || say "- perl is missing: jarvis lock needs it"

say ""
case "$lead" in
  claude)
    say "Next: open Claude Code in this repo on $model, effort high, and say \"you're Jarvis\"."
    case "$host" in
      tmux) say "  From a plain terminal: tmux new-session -s jarvis \"claude --model $model --effort high 'You are Jarvis.'\"" ;;
      superset) say "  In Superset: this project's shared-checkout workspace, Claude Code on $model / high." ;;
      ultron) say "  On Ultron: ultron project add . then ultron agent spawn --role jarvis --agent claude --model $model --effort high --permission-mode bypassPermissions --title jarvis --prompt \"You are Jarvis.\"" ;;
    esac
    say "  Claude Code needs the jarvis plugin: claude plugin marketplace add gorock007/jarvis && claude plugin install jarvis@jarvis" ;;
  *)
    if [ "$lead" = agy ]; then
      say "First, once, so agy has the jarvis:run skill (this script doesn't run it):"
      say "  agy plugin install $PLUGIN"
    fi
    case "$host" in
      tmux) where="inside tmux (tmux new-session -s jarvis), in this repo's root" ;;
      superset) where="in a Superset terminal of this project's shared-checkout workspace" ;;
      ultron) where="in an Ultron session in this repo (ultron project add . first)" ;;
    esac
    say "Next: $where, run handoffs/bin/jarvis lead"
    say "  It starts Jarvis on $lead/$model in that terminal."
    [ "$lead" != codex ] || say "  Codex may ask once to trust this folder." ;;
esac
say "Nothing is committed: look it over (git status), then commit it, e.g. \"chore: add Jarvis workflow\"."
exit 0
