#!/usr/bin/env bash
# install.sh — set up the Jarvis workflow in the git repo you run it from, from any agent
# CLI: no Claude Code needed. It is jarvis:setup's sections 1–4 made mechanical. It finds
# the agent CLIs and hosts on PATH, asks (or takes from flags) the lead, its model, the
# workers, the host and the checks, then writes CLAUDE.md, AGENTS.md, handoffs/ and, when
# claude is installed, .claude/ from skills/setup/templates/. Where the skill asks for
# judgment it takes the default and says how to change it.
# It calls no model, writes nothing outside the repo and never the user's own CLI config.
# A repo already set up is refused; --upgrade brings it to this plugin instead.
#
#   cd <your repo> && <a clone of jarvis>/plugins/jarvis/install.sh [flags]
#     --lead claude|agy|codex|opencode   the agent Jarvis runs on
#     --lead-model <id>                  its model (opencode: provider/model, required)
#     --workers a,b                      the agents workers may run on
#     --host superset|ultron|tmux        where workers run
#     --checks "<cmd>"                   what workers run before handing off
#     --yes                              accept the defaults, never prompt
#     --upgrade [--lead …] [--lead-model …] [--yes]
#                                        upgrade a repo already set up (jarvis:setup 5–11)
# It prompts only when stdin is a terminal and --yes isn't given; otherwise it takes the
# defaults. Exit 0 = set up, 1 = refused (nothing written), 2 = bad arguments.
# shellcheck disable=SC2015,SC2016 # "A && B || die": it dies when either fails, as meant; literal backticks
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
bad() { printf 'install.sh: %s\n' "$*" >&2; printf 'usage: install.sh [--lead claude|agy|codex|opencode] [--lead-model <id>] [--workers a,b] [--host superset|ultron|tmux] [--checks "<cmd>"] [--yes]\n       install.sh --upgrade [--lead claude|agy|codex|opencode] [--lead-model <id>] [--yes]\n' >&2; exit 2; }
have() { command -v "$1" >/dev/null 2>&1; }
in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }
comma() { printf '%s' "$*" | sed 's/ /, /g'; }

# ---------------------------------------------------------------- arguments

O_LEAD="" O_MODEL="" O_WORKERS="" O_HOST="" O_CHECKS="" YES=0 UPGRADE=0
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
    --upgrade) UPGRADE=1; shift ;;
    -h|--help) sed -n '2,21s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) bad "unknown argument: $1" ;;
  esac
done
if [ $UPGRADE = 1 ] && [ $((G_WORKERS + G_HOST + G_CHECKS)) -gt 0 ]; then
  bad "--upgrade takes only --lead, --lead-model and --yes: the workers, host and checks stay as the repo has them"
fi
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
if [ $UPGRADE = 0 ]; then
  [ ! -e handoffs/JARVIS.md ] || die "already set up; upgrade with install.sh --upgrade or jarvis:setup (handoffs/JARVIS.md exists)"
  for f in handoffs/OPEN.md handoffs/jarvis.conf handoffs/bin/jarvis; do
    [ ! -e "$f" ] || die "already set up; upgrade with jarvis:setup ($f exists: an older Jarvis)"
  done
  [ -f CLAUDE.md ] && grep -qE 'handoffs/bin/jarvis|Jarvis workflow' CLAUDE.md \
    && die "already set up; upgrade with jarvis:setup (CLAUDE.md names the Jarvis workflow: an older Jarvis)"
fi

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
if [ $UPGRADE = 0 ]; then
  [ -n "$found_agents" ] || die "no agent CLI on PATH: install one of Claude Code (claude), Codex (codex), Antigravity (agy) or OpenCode (opencode), then run this again"
  [ -n "$found_hosts" ] || die "no host for the workers: install Superset (https://docs.superset.sh/install), Ultron, or tmux 3.0 or later from your package manager, then run this again"
fi

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

# ---------------------------------------------------------------- helpers both paths use

plugin_version() { sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PLUGIN/.claude-plugin/plugin.json" 2>/dev/null | head -n 1; }
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
conf_put() { # $1 = file, $2 = key, $3 = value: the last "KEY=" line, else the first "# KEY=" line, becomes
  # KEY=value with the rest of that line (its comment) kept; with neither, it's appended
  K=$2 V=$3 awk 'BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"] }
    { line[NR] = $0; if (index($0, k "=") == 1) on = NR; else if (!off && index($0, "# " k "=") == 1) off = NR }
    END {
      at = on ? on : off
      for (i = 1; i <= NR; i++) {
        if (i != at) { print line[i]; continue }
        rest = line[i]; sub(/^# /, "", rest); rest = substr(rest, length(k) + 2); sub(/^[^ ]*/, "", rest)
        print k "=" v rest
      }
      if (!at) print k "=" v
    }' "$1" > "$1.install.$$" && mv "$1.install.$$" "$1" || die "can't write $1"
}
copy_tree() { # $1 = from, $2 = to: every file not already there; prints the ones kept
  (cd "$1" && find . -type d) | while IFS= read -r d; do mkdir -p "$2/$d" || exit 1; done || die "can't make the folders in $2"
  (cd "$1" && find . -type f ! -name .DS_Store) | while IFS= read -r f; do
    if [ -e "$2/$f" ]; then echo "  kept your ${2%/}/${f#./}"; continue; fi
    cp -p "$1/$f" "$2/$f" || exit 1
  done || die "can't copy $1 to $2"
}
gitignore_add() { # $1 = a .gitignore: the local paths added, each on a line of its own
  touch "$1" || die "can't write $1"
  [ ! -s "$1" ] || [ -z "$(tail -c 1 "$1")" ] || printf '\n' >> "$1"
  for l in $IGNORES; do grep -qxF "$l" "$1" || printf '%s\n' "$l" >> "$1"; done
}
settings_merge() { # .claude/settings.json and the template merged into $merged; dies, writing nothing, when it can't
  have jq || die ".claude/settings.json exists and merging into it needs jq: install jq, then run this again"
  jq -e 'type == "object"' .claude/settings.json >/dev/null 2>&1 || die ".claude/settings.json isn't a JSON object: fix it, then run this again"
  # jarvis:setup section 3's merge: the user's keys and rules kept, Jarvis's appended once,
  # its broad and retired allow rules removed, the statusline tap in (the old one goes to
  # JARVIS_STATUSLINE_CMD). Made before any write, so a file it can't merge stops it.
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
}
statusline_keep() { # $1 = a jarvis.conf: the repo's own statusline, which the tap replaced, kept as JARVIS_STATUSLINE_CMD
  [ -n "$old_tap" ] && [ "$old_tap" != "$tap" ] || return 0
  grep -q '^JARVIS_STATUSLINE_CMD=' "$1" && { echo "handoffs/jarvis.conf already sets JARVIS_STATUSLINE_CMD, so your statusLine command ($old_tap) isn't in it: put it there by hand if it should run"; return 0; }
  case "$old_tap" in
    *"
"*) echo "your statusLine command has a newline in it: put it in handoffs/jarvis.conf as JARVIS_STATUSLINE_CMD by hand" ;;
    *) q=$(printf '%s' "$old_tap" | sed "s/'/'\\\\''/g")
       printf "\n# The repo's own statusline, which the tap (jarvis statusline) runs after saving its reading.\nJARVIS_STATUSLINE_CMD='%s'\n" "$q" >> "$1" \
         || die "can't write $1" ;;
  esac
}

# ---------------------------------------------------------------- --upgrade

# jarvis:setup sections 5–11 made mechanical, for a repo that has handoffs/JARVIS.md (set
# up with jarvis 0.3 or later). Each step is decided by what the repo holds, not by its
# version. Everything is first staged inside .git, compared with the repo, and written
# only when no file it changes has uncommitted changes and no worker is running, so a
# refusal writes nothing and a second run changes nothing. Where a step needs judgment it
# adds, never deletes, the project's own text; what it can't place goes under "do by hand".

U="" UN="" UDEL="" UHAND="" UNOTE=""
u_hand() { printf -- '- %s\n' "$*" >> "$UHAND"; }
u_note() { printf -- '- %s\n' "$*" >> "$UNOTE"; }
u_stage() { # $1 = a repo path: prints its staged copy, made from the repo's file on first use
  mkdir -p "$(dirname "$UN/$1")" || die "can't stage $1"
  [ -e "$UN/$1" ] || [ ! -f "$1" ] || cp -p "$1" "$UN/$1" || die "can't stage $1"
  printf '%s\n' "$UN/$1"
}
u_tree() { # $1 = template folder, $2 = repo folder: $2 staged as a copy of $1 (its other files deleted)
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    mkdir -p "$(dirname "$UN/$2/$f")" && cp -p "$1/$f" "$UN/$2/$f" || die "can't stage $2/$f"
  done <<EOF
$(cd "$1" && find . -type f ! -name .DS_Store | sed 's|^\./||')
EOF
  [ -d "$2" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] && [ ! -e "$1/$f" ] && printf '%s\n' "$2/$f" >> "$UDEL"
  done <<EOF
$(cd "$2" && find . -type f | sed 's|^\./||')
EOF
}
flat() { tr '\n\t' '  ' < "$1" | tr -s ' ' | sed 's/^ //; s/ $//'; }   # a file as one line, spaces squeezed
wrap() { awk '{ n = split($0, w, " "); l = ""; for (i = 1; i <= n; i++) { if (l != "" && length(l) + 1 + length(w[i]) > 76) { print l; l = w[i] } else l = l (l == "" ? "" : " ") w[i] } if (l != "") print l }'; }
para() { # $1 = file, $2 = text: the paragraph whose first line starts with it
  START=$2 awk 'BEGIN { s = ENVIRON["START"]; pb = 1 }
    /^[[:space:]]*$/ { if (on) exit; pb = 1; next }
    pb && index($0, s) == 1 { on = 1 } { pb = 0 } on' "$1"
}
para_replace() { # $1 = file, $2 = start, $3 = end ("" = any), $4 = new lines: prints $1 with the one paragraph
  # that (spaces squeezed) starts with $2 and ends with $3 replaced; exit 3 unless exactly one does
  START=$2 END=$3 awk -v newf="$4" '
    function flush(   t, i, l) {
      if (!n) return
      t = text; gsub(/[[:space:]]+/, " ", t); sub(/^ /, "", t); sub(/ $/, "", t)
      if (index(t, ENVIRON["START"]) == 1 && (ENVIRON["END"] == "" || substr(t, length(t) - length(ENVIRON["END"]) + 1) == ENVIRON["END"])) {
        hits++; while ((getline l < newf) > 0) out[++o] = l; close(newf)
      } else for (i = 1; i <= n; i++) out[++o] = buf[i]
      n = 0; text = ""
    }
    /^[[:space:]]*$/ { flush(); out[++o] = $0; next }
    { buf[++n] = $0; text = text " " $0 }
    END { flush(); if (hits != 1) exit 3; for (i = 1; i <= o; i++) print out[i] }' "$1"
}
line_insert() { # $1 = file, $2 = before|after, $3 = ERE, $4 = new lines: prints $1 with them next to the one
  # line matching $3, indented as it is; exit 3 unless exactly one line matches
  RE=$3 awk -v where="$2" -v newf="$4" '
    { line[NR] = $0; if ($0 ~ ENVIRON["RE"]) { hits++; at = NR } }
    END {
      if (hits != 1) exit 3
      match(line[at], /^[ \t]*/); ind = substr(line[at], 1, RLENGTH)
      for (i = 1; i <= NR; i++) {
        if (i == at && where == "after") print line[i]
        if (i == at) { while ((getline l < newf) > 0) print (l == "" ? "" : ind l); close(newf) }
        if (i != at || where != "after") print line[i]
      }
    }' "$1"
}
conf_missing() { # $1 = a jarvis.conf, $2 = the filled template: the template's blocks none of whose keys $1
  # mentions (set or commented), and from a block it mentions in part, the key lines it lacks
  awk '
    function key(l,   k) {
      if (!match(l, /^(# )?JARVIS_[A-Za-z0-9_]+=/)) return ""
      k = substr(l, RSTART, RLENGTH - 1); sub(/^# /, "", k); return k
    }
    function flush(   i, k, nk, miss, take) {
      nk = 0; miss = 0
      for (i = 1; i <= n; i++) if ((k = key(b[i])) != "") { nk++; if (!(k in have)) miss++ }
      if (nk && miss == nk) { printf "\n"; for (i = 1; i <= n; i++) print b[i] }
      else if (miss) {
        printf "\n"; take = 0
        for (i = 1; i <= n; i++) {
          if ((k = key(b[i])) != "") take = !(k in have); else if (b[i] !~ /^#  /) take = 0
          if (take) print b[i]
        }
      }
      n = 0
    }
    FNR == NR {
      if (match($0, /^[ \t]*(#[ \t]*)?(export[ \t]+)?JARVIS_[A-Za-z0-9_]+=/)) {
        k = substr($0, RSTART, RLENGTH - 1); sub(/^[ \t]*(#[ \t]*)?(export[ \t]+)?/, "", k); have[k] = 1
      }
      next
    }
    /^[ \t]*$/ { flush(); next }
    { b[++n] = $0 }
    END { flush() }' "$1" "$2"
}
conf_get() { # $1 = key: its value in handoffs/jarvis.conf (the last line setting it), without quotes or comment
  [ -f handoffs/jarvis.conf ] || return 0
  sed -n "s/^$1=//p" handoffs/jarvis.conf | tail -n 1 | sed -e 's/[[:space:]][[:space:]]*#.*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}
ver_lt() { # $1 < $2, as dotted numbers
  awk -v a="$1" -v b="$2" 'BEGIN { n = split(a, x, "."); m = split(b, y, "."); if (m > n) n = m
    for (i = 1; i <= n; i++) { if (x[i] + 0 < y[i] + 0) exit 0; if (x[i] + 0 > y[i] + 0) exit 1 } exit 1 }'
}

upgrade() {
  local f s v_to v_from cur lead="" model="" why eff running sent p_agents p_jarvis p_claude rel what x1 x2 dirty="" st jl
  if [ ! -f handoffs/JARVIS.md ]; then
    for f in handoffs/OPEN.md handoffs/jarvis.conf handoffs/bin/jarvis; do
      [ ! -e "$f" ] || die "set up by jarvis 0.2 or earlier ($f, but no handoffs/JARVIS.md): upgrade it with jarvis:setup, whose section 5 moves its rules by judgment"
    done
    die "not set up: run without --upgrade (there's no handoffs/JARVIS.md)"
  fi
  running=$(for f in handoffs/OPEN.md handoffs/OPEN.*.md; do
    [ -f "$f" ] && awk -v f="$f" '/^## /{on = ($0 ~ /^## Running workers/); next} on && /^- / {print "  " f ": " $0}' "$f"
  done)
  [ -z "$running" ] || die "workers are running: merge or close them first (handoffs/bin/jarvis status), then run this again
$running"
  v_to=$(plugin_version)
  [ -n "$v_to" ] || die "can't read the version in $PLUGIN/.claude-plugin/plugin.json"
  v_from=$(conf_get JARVIS_PLUGIN_VERSION)
  if [ -n "$v_from" ] && ver_lt "$v_to" "$v_from"; then
    die "jarvis $v_from upgraded this repo last, and this clone is jarvis $v_to: update the clone, then run this again"
  fi

  # the lead: the same checks as a fresh install, only when a flag asks for a change
  cur=$(conf_get JARVIS_LEAD_AGENT); cur=${cur:-claude}
  if [ $G_LEAD = 1 ]; then
    in_list "$O_LEAD" "$found_agents" || die "--lead $O_LEAD: $O_LEAD isn't on PATH (found: ${found_agents:-none})"
    lead=$O_LEAD
  elif [ $G_MODEL = 1 ]; then
    in_list "$cur" "$AGENTS" || die "--lead-model: handoffs/jarvis.conf's JARVIS_LEAD_AGENT=$cur isn't claude, agy, codex or opencode; pass --lead too"
    lead=$cur
  fi
  if [ -n "$lead" ]; then
    if [ $G_MODEL = 1 ]; then why=$(model_ok "$lead" "$O_MODEL") || die "--lead-model $why"; model=$O_MODEL
    elif [ "$lead" = opencode ]; then die "an OpenCode Jarvis has no default model: pass --lead-model provider/model (opencode models lists them)"
    else model=$(default_model "$lead"); fi
  fi
  eff=${lead:-$cur}

  U="$(git rev-parse --absolute-git-dir)/jarvis-upgrade.$$" || die "can't find the repo's .git"
  UN="$U/new" UDEL="$U/del" UHAND="$U/hand" UNOTE="$U/note"
  trap 'rm -rf "$U"' EXIT
  mkdir -p "$UN" && : > "$UDEL" && : > "$UHAND" && : > "$UNOTE" || die "can't make $U"
  export P_MAX_CLAUDE=3 P_AMBER=50 P_RED=75

  # 1. handoffs/bin: lib/ replaced whole, then every helper beside bin/jarvis (hosts/ left alone)
  u_tree "$T/handoffs/bin/lib" handoffs/bin/lib
  for f in "$T"/handoffs/bin/*; do
    [ -f "$f" ] || continue
    if [ "${f##*/}" = jev.sh ] && [ ! -e handoffs/bin/jev.sh ]; then u_note "handoffs/bin/jev.sh isn't there (Jev was left out at setup), so it wasn't added"; continue; fi
    cp -p "$f" "$UN/handoffs/bin/${f##*/}" || die "can't stage handoffs/bin/${f##*/}"
  done
  chmod +x "$UN/handoffs/bin/jarvis" "$UN/handoffs/bin/jarvis-lock.pl" || die "can't chmod the staged handoffs/bin"
  [ ! -f "$UN/handoffs/bin/jev.sh" ] || chmod +x "$UN/handoffs/bin/jev.sh" || die "can't chmod the staged jev.sh"

  # 2. the other template files under handoffs/: the ones missing added, the rest kept
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in bin/*) continue ;; esac
    rel=handoffs/$f
    if [ ! -e "$rel" ]; then
      [ "$f" = OPEN.md ] && ls handoffs/OPEN.*.md >/dev/null 2>&1 && continue   # team mode: each person's notes file
      s=$(u_stage "$rel"); cp -p "$T/$rel" "$s" && fill "$s" || die "can't stage $rel"
    else
      case "$f" in TEMPLATE.md|briefs/TEMPLATE.md)
        cmp -s "$T/$rel" "$rel" || u_hand "$rel differs from the plugin's template (jarvis:setup sections 7–9 changed it): merge in what's new, keeping your own lines — diff $rel $T/$rel" ;;
      esac
    fi
  done <<EOF
$(cd "$T/handoffs" && find . -type f ! -name .DS_Store | sed 's|^\./||')
EOF

  # 3. jarvis.conf: every value kept; the template's blocks and keys it lacks appended
  s=$(u_stage handoffs/jarvis.conf)
  cp "$T/handoffs/jarvis.conf" "$U/tpl.conf" && fill "$U/tpl.conf" || die "can't read the template jarvis.conf"
  conf_missing "$s" "$U/tpl.conf" > "$U/add.conf" || die "can't compare handoffs/jarvis.conf with the template"
  if [ -s "$U/add.conf" ]; then
    [ ! -s "$s" ] || [ -z "$(tail -c 1 "$s")" ] || printf '\n' >> "$s"
    cat "$U/add.conf" >> "$s" || die "can't stage handoffs/jarvis.conf"
  fi
  if [ -n "$lead" ]; then conf_put "$s" JARVIS_LEAD_AGENT "$lead"; conf_put "$s" JARVIS_LEAD_MODEL "$model"; fi
  conf_put "$s" JARVIS_PLUGIN_VERSION "$v_to"
  grep -q 'jarvis\.local\.conf' "$s" \
    || u_hand "handoffs/jarvis.conf: add the template's header comment on handoffs/jarvis.local.conf (jarvis:setup section 10 step 3)"

  # 4. the run skill, which a Codex or OpenCode Jarvis reads from the repo: kept matching the plugin
  if [ "$eff" = codex ] || [ "$eff" = opencode ] || [ -d handoffs/skills/jarvis-run ]; then
    u_tree "$RUN" handoffs/skills/jarvis-run
  fi

  # 5. section 11 step 3's paragraphs, each placed by an anchor the file must hold
  p_agents="$U/p.agents" p_jarvis="$U/p.jarvis" p_claude="$U/p.claude"
  para "$T/AGENTS.md" "This repo runs the Jarvis workflow." > "$p_agents"
  para "$T/handoffs/JARVIS.md" "**Jarvis on another agent**" > "$p_jarvis"
  sent=$(flat "$T/CLAUDE.md" | sed -n 's/.*\(If `handoffs\/jarvis\.conf` sets `JARVIS_LEAD_AGENT`.*second Jarvis\.\).*/\1/p')
  printf '%s\n' "$sent" | wrap > "$p_claude"
  [ -s "$p_agents" ] && [ -s "$p_jarvis" ] && [ -n "$sent" ] || die "the templates no longer hold section 11's paragraphs: this install.sh doesn't match them"

  if [ ! -f AGENTS.md ]; then u_hand "AGENTS.md is missing: write it from $T/AGENTS.md, filling its placeholders (jarvis:setup section 3)"
  else
    s=$(u_stage AGENTS.md)
    case "$(flat "$s")" in
      *"$(flat "$p_agents")"*) ;;
      *) if para_replace "$s" "This repo runs the Jarvis workflow" '`CLAUDE.md` instead.' "$p_agents" > "$U/x"; then cat "$U/x" > "$s"
         else u_hand "AGENTS.md: no one role paragraph (\"This repo runs the Jarvis workflow…\", ending \"\`CLAUDE.md\` instead.\") to replace. Put this one in place of yours:"
           sed 's/^/      /' "$p_agents" >> "$UHAND"; fi ;;
    esac
    grep -qF 'Run heavy suites only through their lock' "$s" || u_hand "AGENTS.md: add the template's \"Run heavy suites only through their lock\" rule (jarvis:setup section 7 step 3), from $T/AGENTS.md"
    grep -qF 'Budget reached' "$s" || u_hand "AGENTS.md: add the template's \"Budget reached\" rule (jarvis:setup section 8 step 4), from $T/AGENTS.md"
  fi

  s=$(u_stage handoffs/JARVIS.md)
  if ! grep -qF '**Jarvis on another agent**' "$s"; then
    { cat "$p_jarvis"; echo; } > "$U/p.jarvis2"
    if para_replace "$s" "**Jarvis on agy**" "" "$p_jarvis" > "$U/x"; then cat "$U/x" > "$s"
    elif line_insert "$s" before '^## Budget rules[[:space:]]*$' "$U/p.jarvis2" > "$U/x"; then cat "$U/x" > "$s"
    else u_hand "handoffs/JARVIS.md: no \"## Budget rules\" heading to put it before. Add this paragraph at the end of \"## The loop\":"
      sed 's/^/      /' "$p_jarvis" >> "$UHAND"; fi
  fi
  grep -qF '**The merge gate.**' "$s" || u_hand "handoffs/JARVIS.md: add the template's \"The merge gate\" bullet (jarvis:setup sections 7 and 9), from $T/handoffs/JARVIS.md"
  grep -qF '**Team mode:**' "$s" || u_hand "handoffs/JARVIS.md: add the template's \"Team mode\" bullet (jarvis:setup section 10 step 3), from $T/handoffs/JARVIS.md"

  if [ ! -f CLAUDE.md ]; then u_hand "CLAUDE.md is missing: write it from $T/CLAUDE.md, filling its placeholders (jarvis:setup section 3)"
  else
    s=$(u_stage CLAUDE.md)
    case "$(flat "$s")" in
      *"$sent"*) ;;
      *) if line_insert "$s" after 'then run `handoffs/bin/jarvis start`\.[[:space:]]*$' "$p_claude" > "$U/x"; then cat "$U/x" > "$s"
         else u_hand "CLAUDE.md: no one line ending \"then run \`handoffs/bin/jarvis start\`.\" to add it after. Add this to the Jarvis bullet:"
           sed 's/^/      /' "$p_claude" >> "$UHAND"; fi ;;
    esac
  fi

  # 6. .gitignore: the local paths
  gitignore_add "$(u_stage .gitignore)"

  # 7. .claude/, only where Claude Code is installed (as a fresh install does)
  if in_list claude "$found_agents"; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if [ ! -e ".claude/agents/$f" ]; then s=$(u_stage ".claude/agents/$f"); cp -p "$T/.claude/agents/$f" "$s" || die "can't stage .claude/agents/$f"
      elif ! cmp -s "$T/.claude/agents/$f" ".claude/agents/$f"; then u_note ".claude/agents/$f is yours, not the template's: kept"; fi
    done <<EOF
$(cd "$T/.claude/agents" && find . -type f ! -name .DS_Store | sed 's|^\./||')
EOF
    if [ -e .claude/settings.json ]; then
      settings_merge
      [ "$(printf '%s\n' "$merged" | jq -S .)" = "$(jq -S . .claude/settings.json)" ] || printf '%s\n' "$merged" > "$(u_stage .claude/settings.json)" || die "can't stage .claude/settings.json"
      why=$(statusline_keep "$UN/handoffs/jarvis.conf"); [ -z "$why" ] || u_hand "$why"
    else
      cp "$T/.claude/settings.json" "$(u_stage .claude/settings.json)" || die "can't stage .claude/settings.json"
    fi
  else
    u_note ".claude/ left as it is: claude isn't on PATH (run this again once it is)"
  fi

  # what would change: staged files that differ from the repo's, and the deletions
  : > "$U/list"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if [ -L "$rel" ]; then u_hand "$rel is a symlink, so it wasn't upgraded: replace it with $T/$rel or point it there"; continue; fi
    if [ ! -e "$rel" ]; then printf '%s\tcreated\n' "$rel" >> "$U/list"; continue; fi
    x1=0; [ -x "$rel" ] && x1=1; x2=0; [ -x "$UN/$rel" ] && x2=1
    cmp -s "$UN/$rel" "$rel" && [ $x1 = $x2 ] || printf '%s\tmodified\n' "$rel" >> "$U/list"
  done <<EOF
$(cd "$UN" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
EOF
  while IFS= read -r rel; do
    [ -n "$rel" ] && [ -e "$rel" ] && printf '%s\tdeleted\n' "$rel" >> "$U/list"
  done < "$UDEL"
  while IFS="$(printf '\t')" read -r rel what; do
    [ -z "$(git status --porcelain -- "$rel" 2>/dev/null)" ] || dirty="$dirty
  $rel"
  done < "$U/list"
  [ -z "$dirty" ] || die "these files it would write have uncommitted changes: commit them or undo them, then run this again$dirty"

  say ""
  say "upgrade: jarvis ${v_from:-of an unknown version (no JARVIS_PLUGIN_VERSION yet)} → $v_to"
  if [ -s "$U/list" ] && [ $INTERACTIVE = 1 ]; then
    sed 's/	/ — /; s/^/  /' "$U/list"
    ask "Write these $(wc -l < "$U/list" | tr -d ' ') changes" "y"
    case "$REPLY" in y|Y|yes) ;; *) die "nothing written" ;; esac
  fi
  while IFS="$(printf '\t')" read -r rel what; do
    if [ "$what" = deleted ]; then rm -f "$rel" || die "can't delete $rel"; continue; fi
    mkdir -p "$(dirname "$rel")" && cp -p "$UN/$rel" "$rel.install.$$" && mv -f "$rel.install.$$" "$rel" \
      || { rm -f "$rel.install.$$"; die "can't write $rel"; }
  done < "$U/list"

  # jarvis status's lead line; the band line status writes into the notes file is put back
  mkdir -p "$U/open" || die "can't make $U/open"
  for f in handoffs/OPEN*.md; do [ -f "$f" ] && cp -p "$f" "$U/open/"; done
  st=$(JARVIS_MODELS_REFRESH_H=0 handoffs/bin/jarvis status </dev/null 2>&1) || st="jarvis: handoffs/bin/jarvis status failed: $(printf '%s\n' "$st" | tail -n 1)
$st"
  for f in handoffs/OPEN*.md; do
    [ -f "$f" ] || continue
    # whole, mode included: status's rewrite goes through mktemp, which leaves it 0600
    if [ -f "$U/open/${f##*/}" ]; then cp -p "$U/open/${f##*/}" "$f" || die "can't put $f back as it was"; else rm -f "$f"; fi
  done
  jl=$(printf '%s\n' "$st" | grep -E '^(jarvis: |JARVIS_LEAD_AGENT=|JARVIS IS LIMITED)')
  [ -n "$jl" ] || jl="jarvis: $eff — Claude Code is Jarvis here, so status prints no lead line"

  if [ "$eff" = agy ]; then
    say "agy needs the jarvis:run skill, once (this script doesn't run it):"
    say "  agy plugin install $PLUGIN"
  fi
  if [ -s "$UNOTE" ]; then say "left as they were:"; cat "$UNOTE"; fi
  if [ -s "$U/list" ]; then
    say "changed (nothing committed: look it over with git diff, then commit it, e.g. \"chore: upgrade Jarvis to $v_to\"):"
    sed 's/	/ — /; s/^/- /' "$U/list"
  else
    say "changed: nothing — already up to date with jarvis $v_to"
  fi
  say "do by hand:"
  if [ -s "$UHAND" ]; then cat "$UHAND"; else say "- nothing"; fi
  printf '%s\n' "$jl"
}
[ $UPGRADE = 0 ] || { upgrade; exit 0; }

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
[ $claude_files = 0 ] || [ ! -e .claude/settings.json ] || settings_merge

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

say ""
copy_tree "$T/handoffs" handoffs
chmod +x handoffs/bin/jarvis handoffs/bin/jarvis-lock.pl handoffs/bin/jev.sh || die "can't chmod handoffs/bin"
fill handoffs/JARVIS.md
fill handoffs/jarvis.conf
conf_put handoffs/jarvis.conf JARVIS_HOST "$host"
conf_put handoffs/jarvis.conf JARVIS_LEAD_AGENT "$lead"
conf_put handoffs/jarvis.conf JARVIS_LEAD_MODEL "$model"
v=$(plugin_version); [ -z "$v" ] || conf_put handoffs/jarvis.conf JARVIS_PLUGIN_VERSION "$v"
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
    statusline_keep handoffs/jarvis.conf
    say "merged Jarvis's hooks, permissions, env and statusline tap into your .claude/settings.json (git diff shows them)"
  else
    cp "$T/.claude/settings.json" .claude/settings.json || die "can't write .claude/settings.json"
    say "wrote .claude/ (settings.json, agents/)"
  fi
fi

gitignore_add .gitignore

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
