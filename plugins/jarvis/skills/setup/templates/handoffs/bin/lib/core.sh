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

claude_sessions() { # Jarvis plus every running Claude worker
  echo $(( $(running_lines | grep -c '· claude/') + 1 ))
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

