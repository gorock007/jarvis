# shellcheck shell=bash
# Sourced by bin/jarvis; not run on its own.

die() { echo "jarvis: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
now() { date +%s; }
short() { printf '%s' "$1" | cut -c1-8; }
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; } # GNU first: GNU stat -f is a filesystem stat and succeeds

# ---------------------------------------------------------------- OPEN.md

jarvis_terminal() {
  sed -n 's/^Jarvis session:[[:space:]]*//p' "$OPEN" 2>/dev/null | head -n 1 | awk '{print $1}' | grep -v '^<' || true
}

# "- <when> · <agent>/<model> <effort> · term <id> · <brief> · <slug>"
running_lines() {
  awk '/^## /{on = ($0 ~ /^## Running workers/); next} on && /^- /' "$OPEN" 2>/dev/null
}

claude_sessions() { # Jarvis (on Claude) plus every running Claude worker
  echo $(( $(running_lines | grep -c '· claude/') + $(lead_n) ))
}

# ---------------------------------------------------------------- the agent Jarvis runs on

# JARVIS_LEAD_AGENT=agy runs Jarvis itself on agy (jarvis lead starts it); anything else
# is the default, Claude Code. An agy Jarvis is no Claude session: lead_n is what it adds
# to this checkout's Claude count.
lead_is_claude() { [ "${JARVIS_LEAD_AGENT:-claude}" != agy ]; }
lead_n() { if lead_is_claude; then echo 1; else echo 0; fi; }
lead_model() { printf '%s' "${JARVIS_LEAD_MODEL:-gemini-4-neon-high}"; }
lead_who() { # OPEN.md's count of this checkout's Claude sessions, in words
  if lead_is_claude; then printf 'Jarvis + %s running Claude worker(s)' "$(( $(claude_sessions) - 1 ))"
  else printf '%s running Claude worker(s) (Jarvis runs on agy)' "$(claude_sessions)"; fi
}
lead_stamp() { # $1 = working | stop | cleared: an agy Jarvis's last turn event, "<epoch> <kind>"
  mkdir -p "$STATE" && printf '%s %s\n' "$(now)" "$1" > "$STATE/lead.stamp.$$" && mv "$STATE/lead.stamp.$$" "$STATE/lead.stamp"
}
# What an agy Jarvis is told when it starts and after the watcher clears it: agy reads
# AGENTS.md, whose rule makes every other agent a worker unless its prompt says this.
lead_role() {
  printf 'You are Jarvis, on agy (JARVIS_LEAD_AGENT=agy in handoffs/jarvis.conf), not a worker: AGENTS.md'"'"'s worker rules are not yours. Use the jarvis:run skill, read handoffs/JARVIS.md and %s,' "$OPEN"
}

open_add_running() { # $1 = line
  local tmp; tmp=$(mktemp) || return 1
  awk -v line="$1" '{print} /^## Running workers/ && !done {print line; done=1}' "$OPEN" > "$tmp" && mv "$tmp" "$OPEN"
}

open_drop() { # drop list items that mention $1
  local tmp; tmp=$(mktemp) || return 1
  awk -v k="$1" '!(/^- / && index($0, k))' "$OPEN" > "$tmp" && mv "$tmp" "$OPEN"
}

open_set() { # $1 = "Jarvis session" | "Usage band", $2 = value
  local tmp; tmp=$(mktemp) || return 1
  awk -v k="$1" -v v="$2" 'index($0, k ":") == 1 {print k ": " v; next} {print}' "$OPEN" > "$tmp" && mv "$tmp" "$OPEN"
}

field() { # $1 = key, $2 = file: "key: value" from a brief header or handoff
  sed -n "s/^$1:[[:space:]]*//p" "$2" 2>/dev/null | head -n 1
}

