#!/usr/bin/env bash
# Demo D1 (research plan v0.8-v1.0, Phase 5 "Demo"): one real, unattended Jarvis run on tmux,
# recorded as raw footage for the edit. The four beats:
#   1. one message: the script types one plain-English request into Jarvis's pane
#   2. two workers start: Jarvis writes two briefs and spawns them, each in its own tmux window
#   3. a question batch: a worker hands off blocked, Jarvis puts the question to "the user",
#      and the script types the answer
#   4. a merge with two commits: both handoffs merged into the toy repo
#
# Everything runs in a throwaway folder, /tmp/jarvis-demo-XXXX: a toy repo (splitbill, a bill
# splitter) set up the way jarvis:setup would on tmux, from this checkout's template; a copy of the
# plugin source for `claude --plugin-dir`; and a JARVIS_HOME of its own. Jarvis and its workers run
# on a tmux server of their own (its own socket, killed by that socket on exit). Each window is
# recorded on its own (asciinema, headless, read-only tmux clients), so the edit can stack panes for
# 9:16 or lay them side by side for 16:9.
#
# Output: ~/Movies/jarvis-demo/raw/<stamp>/ — <window>.cast and .mp4 per window, beats.json
# (seconds from the start of jarvis.cast), commits.txt, events.tsv, and the toy repo's handoffs.
#
# Knobs (env): DEMO_DRY=1 (a fake Jarvis and fake workers: no model, no usage), DEMO_LIMIT_MIN
# (40 real, 5 dry), DEMO_OUT (default ~/Movies/jarvis-demo/raw), DEMO_KEEP=1 (keep the /tmp folder),
# DEMO_RENDER=0 (casts only), DEMO_TRUST_ONLY=1 (start the real Claude Jarvis with no prompt, answer
# the folder-trust screen, check Claude reached its prompt, stop: no usage). Run with bash or /bin/bash (3.2).
set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
tpl="$repo/plugins/jarvis/skills/setup/templates"
DRY=${DEMO_DRY:-0}
TRUST_ONLY=${DEMO_TRUST_ONLY:-0}
COLS=80; ROWS=30                      # every window; the camera clients are one row taller (tmux's status bar)
FONT=28                               # agg font size in px
if [ "$DRY" = 1 ]; then LIMIT_MIN=${DEMO_LIMIT_MIN:-5}; else LIMIT_MIN=${DEMO_LIMIT_MIN:-40}; fi
OUT_ROOT=${DEMO_OUT:-$HOME/Movies/jarvis-demo/raw}
RENDER=${DEMO_RENDER:-1}

for need in tmux git jq perl python3 asciinema; do
  command -v "$need" >/dev/null 2>&1 || { echo "record: needs $need" >&2; exit 2; }
done
if [ "$RENDER" = 1 ]; then
  for need in agg ffmpeg; do command -v "$need" >/dev/null 2>&1 || { echo "record: needs $need (or DEMO_RENDER=0)" >&2; exit 2; }; done
fi
[ "$DRY" = 1 ] || command -v claude >/dev/null 2>&1 || { echo "record: needs claude" >&2; exit 2; }
[ -d "$tpl/handoffs" ] || { echo "record: no template at $tpl/handoffs" >&2; exit 2; }

stamp=$(date +%Y%m%d-%H%M%S)
[ "$DRY" = 1 ] && stamp="$stamp-dry"
[ "$TRUST_ONLY" = 1 ] && { stamp="$stamp-trust"; RENDER=0; }
out="$OUT_ROOT/$stamp"
mkdir -p "$out" || exit 2
work=$(mktemp -d /tmp/jarvis-demo-XXXX) || exit 2
work=$(cd "$work" && pwd -P)
toy="$work/splitbill"
ev="$out/events.tsv"
marks="$work/jarvis.marks"
S=splitbill                           # Jarvis's tmux session; workers open as its windows
sock="jarvis-demo-$$"
LANG_=en_US.UTF-8
: > "$ev"; : > "$marks"

ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000'; }
log_ev() { printf '%s\t%s\t%s\t%s\n' "$(ms)" "$1" "${2:-}" "${3:-}" >> "$ev"; echo "[record] $1 ${2:-} ${3:-}" | cut -c1-160; }

# The server starts from a clean environment: nothing of this terminal's (no Superset ids, no
# CLAUDECODE) reaches Jarvis or its workers.
srv_env() {
  env -i HOME="$HOME" USER="${USER:-}" LOGNAME="${LOGNAME:-${USER:-}}" PATH="$PATH" SHELL="${SHELL:-/bin/sh}" \
    TMPDIR="${TMPDIR:-/tmp}" TERM=xterm-256color COLORTERM=truecolor LANG="$LANG_" \
    JARVIS_HOME="$work/jh" DEMO_MARKS="$marks" "$@"
}
TM() { srv_env tmux -u -L "$sock" -f "$work/tmux.conf" "$@"; }

cleanup() {
  trap - EXIT INT TERM
  local p pids
  # this run's panes and everything under them, by PID, for the check after the server is gone
  pids=$(TM list-panes -a -F '#{pane_pid}' 2>/dev/null | sort -u)
  for p in $pids; do pids="$pids $(pgrep -P "$p" 2>/dev/null | tr '\n' ' ')"; done
  for f in "$work"/cams/*; do [ -f "$f" ] && kill "$(sed -n 2p "$f")" 2>/dev/null; done
  TM kill-server >/dev/null 2>&1
  rm -f "/tmp/tmux-$(id -u)/$sock"
  for p in $pids; do
    i=0; while kill -0 "$p" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
    kill -0 "$p" 2>/dev/null && { echo "[record] stopping leftover pid $p"; kill "$p" 2>/dev/null; }
  done
  if [ -n "${DEMO_KEEP:-}" ]; then echo "kept $work"; else rm -rf "$work"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------- the toy repo
make_toy() {
  mkdir -p "$toy/receipts" && cd "$toy" || return 1
  git init -q && git config user.email demo@example.com && git config user.name "Demo User"
  cat > README.md <<'EOF'
# splitbill

Two small scripts for splitting a restaurant bill.

    $ python3 receipt.py receipts/dinner.txt
    Margherita pizza      14.50
    ...
    Subtotal              84.50

    $ python3 splitbill.py 84.50 3 --tip 18
    Each person pays $33.24

Tests: `python3 -m unittest -q`
EOF
  cat > splitbill.py <<'EOF'
#!/usr/bin/env python3
"""Split a restaurant bill evenly.

    python3 splitbill.py 84.50 3 --tip 18
    Each person pays $33.24
"""
import argparse
from fractions import Fraction


def to_cents(amount):
    """'84.50' -> 8450"""
    return int(Fraction(amount) * 100)


def money(cents):
    return f"${cents // 100}.{cents % 100:02d}"


def share(total_cents, people, tip_percent=0):
    """One person's share in cents: the bill plus tip, split evenly, rounded to the nearest cent."""
    exact = Fraction(total_cents) * (100 + Fraction(tip_percent)) / (100 * people)
    return int(exact + Fraction(1, 2))


def main(argv=None):
    p = argparse.ArgumentParser(description="Split a restaurant bill evenly.")
    p.add_argument("total", help="the bill, e.g. 84.50")
    p.add_argument("people", type=int, help="how many people are paying")
    p.add_argument("--tip", type=Fraction, default=Fraction(0), help="tip in percent, e.g. 18")
    args = p.parse_args(argv)
    if args.people < 1:
        p.error("people must be at least 1")
    print(f"Each person pays {money(share(to_cents(args.total), args.people, args.tip))}")


if __name__ == "__main__":
    main()
EOF
  cat > test_splitbill.py <<'EOF'
import contextlib
import io
import unittest

import splitbill


class SplitTest(unittest.TestCase):
    def test_to_cents(self):
        self.assertEqual(splitbill.to_cents("84.50"), 8450)

    def test_money(self):
        self.assertEqual(splitbill.money(5), "$0.05")
        self.assertEqual(splitbill.money(3324), "$33.24")

    def test_share_with_tip(self):
        self.assertEqual(splitbill.share(8450, 3, 18), 3324)

    def test_cli(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            splitbill.main(["84.50", "3", "--tip", "18"])
        self.assertEqual(buf.getvalue(), "Each person pays $33.24\n")


if __name__ == "__main__":
    unittest.main()
EOF
  cat > receipt.py <<'EOF'
#!/usr/bin/env python3
"""Print a receipt's items and its subtotal.

    python3 receipt.py receipts/dinner.txt
"""
import argparse


def read_items(path):
    """Each line is '<item>  <price>': the price is the last word. Blank lines and # comments are skipped."""
    items = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            name, price = line.rsplit(None, 1)
            items.append((name, round(float(price) * 100)))
    return items


def render(items):
    width = max(len(name) for name, _ in items + [("Subtotal", 0)])
    lines = [f"{name.ljust(width)}  {cents / 100:>7.2f}" for name, cents in items]
    lines.append(f"{'Subtotal'.ljust(width)}  {sum(c for _, c in items) / 100:>7.2f}")
    return "\n".join(lines)


def main(argv=None):
    p = argparse.ArgumentParser(description="Print a receipt's items and its subtotal.")
    p.add_argument("file", help="a receipt, e.g. receipts/dinner.txt")
    args = p.parse_args(argv)
    print(render(read_items(args.file)))


if __name__ == "__main__":
    main()
EOF
  cat > test_receipt.py <<'EOF'
import unittest

import receipt


class ReceiptTest(unittest.TestCase):
    def test_read_items(self):
        items = receipt.read_items("receipts/dinner.txt")
        self.assertEqual(len(items), 6)
        self.assertEqual(items[0], ("Margherita pizza", 1450))

    def test_subtotal(self):
        out = receipt.render(receipt.read_items("receipts/dinner.txt"))
        self.assertTrue(out.splitlines()[-1].endswith("84.50"))


if __name__ == "__main__":
    unittest.main()
EOF
  cat > receipts/dinner.txt <<'EOF'
# Thursday dinner, table 4
Margherita pizza      14.50
Mushroom risotto      18.00
Caesar salad          11.25
Tiramisu               8.75
Sparkling water x2     6.00
Bottle of Chianti     26.00
EOF
  printf '__pycache__/\n' > .gitignore
  git add -A && git commit -q -m "splitbill: bill splitter and receipt reader"

  # ---- Jarvis, the way jarvis:setup writes it on tmux (the three questions answered with defaults)
  cp "$tpl/CLAUDE.md" "$tpl/AGENTS.md" .
  cp -R "$tpl/handoffs" handoffs
  mkdir -p .claude && cp -R "$tpl/.claude/agents" .claude/agents
  chmod +x handoffs/bin/jarvis handoffs/bin/jarvis-lock.pl handoffs/bin/jev.sh
  P_PROJECT_NAME=splitbill \
  P_APP_DIR_NOTE="The app lives at the repo root." \
  P_CHECKS="python3 -m unittest -q" \
  P_JARVIS_ONLY="tagging releases." \
  P_VERIFY="the user runs the CLI commands from the handoff (python3 splitbill.py …, python3 receipt.py …)." \
  P_SHARED_FILES="README.md" \
  P_FREE_TIER_NEVER="credentials or real user data." \
  P_MAX_CLAUDE=3 P_AMBER=50 P_RED=75 \
    perl -CSD -pi -e 's/\{\{([A-Z_]+)\}\}/exists $ENV{"P_$1"} ? $ENV{"P_$1"} : $&/ge' \
      CLAUDE.md AGENTS.md handoffs/JARVIS.md handoffs/jarvis.conf
  grep -l '{{' CLAUDE.md AGENTS.md handoffs/JARVIS.md handoffs/jarvis.conf && { echo "record: placeholders left" >&2; return 1; }
  # setup's plugins default: switch off the user's plugins this repo plainly doesn't use (all but
  # security-guidance); the installed jarvis too, so only the --plugin-dir copy of the source loads
  jq --argjson off "$(jq -c '[.enabledPlugins // {} | to_entries[] | select(.value == true) | .key
        | select(startswith("security-guidance@") | not)] | map({(.): false}) | add // {}' "$HOME/.claude/settings.json" 2>/dev/null || echo '{}')" \
    '.enabledPlugins = ((.enabledPlugins // {}) + $off)' "$tpl/.claude/settings.json" > .claude/settings.json
  printf 'handoffs/.jev/\nhandoffs/.jarvis/\n' >> .gitignore
  # Demo only, in this throwaway repo: the band is amber, and amber's machine-wide caps (3, 2 Opus)
  # are already held by other sessions on this machine, so the demo's two workers would be refused.
  # jarvis.conf is read after lib/defaults.sh, so these lines lift the green and amber caps here
  # alone (red keeps its defaults). A shorter watcher tick keeps the footage from idling.
  cat >> handoffs/jarvis.conf <<'EOF'

# ---- demo/record.sh (throwaway repo only)
JARVIS_MAX_CLAUDE_GLOBAL=12
JARVIS_AMBER_GLOBAL=12
JARVIS_MAX_OPUS=6
JARVIS_AMBER_OPUS=6
JARVIS_PUSH=0
JARVIS_WATCH_SEC=10
JARVIS_BATCH_SEC=10
EOF
  [ "$DRY" = 1 ] && echo "JARVIS_AGENT_claude='sh \"$work/fake-worker.sh\"'" >> handoffs/jarvis.conf
  git add -A && git commit -q -m "Add the Jarvis workflow"
  # Demo only, untracked: a Stop/prompt hook that tells the script when Jarvis (not a worker) is idle
  cat > "$work/mark.sh" <<'EOF'
#!/bin/sh
cat >/dev/null
[ "${DEMO_ROLE:-}" = jarvis ] || exit 0
printf '%s %s\n' "$1" "$(perl -MTime::HiRes=time -e 'printf "%d", time()*1000')" >> "$DEMO_MARKS"
exit 0
EOF
  jq -n --arg m "sh $work/mark.sh" '{hooks: {
      UserPromptSubmit: [{hooks: [{type: "command", command: ($m + " prompt"), timeout: 5}]}],
      Stop: [{hooks: [{type: "command", command: ($m + " stop"), timeout: 5}]}]}}' > .claude/settings.local.json
  echo ".claude/settings.local.json" >> .git/info/exclude
}

# ---------------------------------------------------------------- dry run: a fake Jarvis and fake workers
make_fakes() {
  cat > "$work/fake-jarvis.sh" <<'EOF'
#!/bin/sh
# dry run: the jarvis commands a real Jarvis would run, no model
mark() { printf '%s %s\n' "$1" "$(perl -MTime::HiRes=time -e 'printf "%d", time()*1000')" >> "$DEMO_MARKS"; }
J=handoffs/bin/jarvis
mark prompt; echo "fake Jarvis (dry run)"
$J start | tail -n 5; $J watch --start
mark stop
printf '> '; read -r msg; mark prompt; echo "user: $msg"
for t in names:splitbill.py sort:receipt.py; do
  b=handoffs/briefs/2026-11-08-1200-${t%%:*}.md
  printf '# %s\nworker: claude\nmodel: claude-sonnet-5-5\neffort: medium\nstarted: <x>\n\n## Goal\nfake\n\n## Scope\n- May touch: `%s`, `test_%s`\n' \
    "${t%%:*}" "${t#*:}" "${t#*:}" > "$b"
  $J spawn "$b" 2>&1 | tail -n 2
done
mark stop
until grep -l '^status: blocked' handoffs/*.md >/dev/null 2>&1; do sleep 1; done
mark prompt; sleep 2
q=$(grep -l '^status: blocked' handoffs/*.md | head -n 1)
awk '/^## Questions for the user/{on=1; next} /^## /{on=0} on && NF' "$q"
perl -0pi -e 's/(## Questions for the user\n)/$1- fake · names · Q1 who pays the odd cent?\n/' handoffs/OPEN.md
mark stop
printf '> '; read -r ans; mark prompt
term=$(sed -n 's/^started:.*terminal: *//p' handoffs/briefs/2026-11-08-1200-names.md | awk '{print $1}')
$J send "$term" "Answers: $ans"
perl -0pi -e 's/- fake · names · Q1[^\n]*\n//' handoffs/OPEN.md
mark stop
n=0
while [ "$n" -lt 2 ]; do
  for h in handoffs/2026-11-08-1201-*.md; do
    [ -f "$h" ] && grep -qx 'status: done' "$h" || continue
    mark prompt; $J merge "$h" -m "splitbill: ${h##*-} (dry run)" --outcome clean 2>&1 | tail -n 3; n=$((n + 1)); mark stop
  done
  sleep 1
done
echo "fake Jarvis: both merged"; exec tail -f /dev/null
EOF
  cat > "$work/fake-worker.sh" <<'EOF'
#!/bin/sh
# dry run: a worker that hands off blocked (names) or done (sort), no model
slug=$(basename "$JARVIS_BRIEF" .md | sed 's/^[0-9-]*//')
file=splitbill.py; [ "$slug" = sort ] && file=receipt.py
h=handoffs/2026-11-08-1201-$slug.md
handoff() { # $1 status, $2 files block, $3 questions
  printf '# fake %s\nstatus: %s\nagent: claude fake\nbrief: %s\n## What the user asked\nfake\n## What changed\nfake\n## Files\n%s\n## Checks run\nnone (dry run)\n## Processes left running\nnone\n## Questions for the user\n%s\n## Notes for Jarvis\nnone\n' \
    "$slug" "$1" "$JARVIS_BRIEF" "$2" "$3" > "$h"
}
echo "fake worker: $JARVIS_BRIEF"; sleep 4
if [ "$slug" = names ]; then
  handoff blocked "" "1. 84.50 + 18% split three ways is 99.71: who pays the odd cents?"
  echo "handed off blocked; waiting for answers"; read -r ans; echo "got: $ans"; sleep 3
fi
echo "# $slug: done (dry run)" >> "$file"
handoff done "- $file — modified" "none"
echo "handed off: $h"; exec tail -f /dev/null
EOF
}

# ---------------------------------------------------------------- tmux and the cameras
cat > "$work/tmux.conf" <<EOF
set -g default-terminal tmux-256color
set -as terminal-features ',xterm-256color:RGB'
set -g focus-events on
set -g escape-time 10
set -g history-limit 5000
set -g default-size ${COLS}x${ROWS}
set -g automatic-rename off
set -g allow-rename off
set -g status-style 'bg=colour236,fg=colour250'
set -g status-left ''
set -g status-right ' splitbill · tmux '
set -g window-status-format ' #W '
set -g window-status-current-format '#[bold,bg=colour31,fg=colour255] #W '
EOF

mkdir -p "$work/cams" "$work/jh"
# the band from this machine's own statusline reading, copied (read only) into the demo's JARVIS_HOME;
# the demo Jarvis's statusline keeps it fresh from there
for f in usage.json usage.hist; do [ -f "$HOME/.jarvis/$f" ] && cp "$HOME/.jarvis/$f" "$work/jh/$f"; done

cam_start() { # $1 name, $2 tmux session to show (attached read-only, no resize)
  local f="$work/cams/$1" t
  t=$(ms)
  srv_env asciinema rec --headless -q -f asciicast-v2 --window-size "${COLS}x$((ROWS + 1))" \
    -c "tmux -u -L $sock attach -f read-only,ignore-size -t '=$2'" "$out/$1.cast" >/dev/null 2>&1 &
  printf '%s\n%s\n%s\n' "$2" "$!" "$t" > "$f"
  log_ev rec_start "$1" "$1.cast"
}
cam_for_window() { # $1 window id, $2 name: a session of its own that holds only that window
  local cs="cam-$2"
  TM new-session -d -s "$cs" -x "$COLS" -y "$ROWS" "sleep 86400" \; \
     link-window -d -s "$1" -t "$cs:9" \; kill-window -t "$cs:0" \; select-window -t "$cs:9" || return 1
  cam_start "$2" "$cs"
}

# ---------------------------------------------------------------- the run
make_toy || exit 1
[ "$DRY" = 1 ] && make_fakes
mkdir -p "$work/plugin" && cp -R "$repo/plugins/jarvis" "$work/plugin/jarvis"
start_prompt="You are Jarvis. Use the jarvis:run skill: read handoffs/JARVIS.md and handoffs/OPEN.md, run handoffs/bin/jarvis start, then tell me what is open."
if [ "$DRY" = 1 ]; then
  jcmd="DEMO_ROLE=jarvis sh $work/fake-jarvis.sh"
else
  printf '#!/bin/sh\nexport DEMO_ROLE=jarvis\nclaude --plugin-dir %s --model claude-opus-5-5 --effort high --permission-mode bypassPermissions %s\nprintf "\\n[demo] Jarvis exited (%%s)\\n" "$?"\nexec tail -f /dev/null\n' \
    "$work/plugin/jarvis" "$([ "$TRUST_ONLY" = 1 ] || echo "'$start_prompt'")" > "$work/jarvis.sh"
  jcmd="sh $work/jarvis.sh"
fi

message="Two small things for splitbill, and they can run in parallel. 1) Let me split by name: \`python3 splitbill.py 84.50 --tip 18 --names Ana,Ben,Cy\` should print one line per person with what they owe. I haven't decided who pays the odd cents when the bill doesn't split evenly, so have that worker lay out the options and ask me before it builds that part. 2) \`python3 receipt.py receipts/dinner.txt --sort price\` should list the most expensive items first. Spawn both now."
answer="Odd cents go to the first names in the list, one cent each, so the lines add up to exactly the bill plus tip. Anything else, use your judgement."

type_into() { # $1 pane, $2 text: typed a word at a time, then Enter
  local w
  set -f
  for w in $2; do TM send-keys -t "$1" -l -- "$w " ; sleep 0.07; done
  set +f
  sleep 1.2; TM send-keys -t "$1" Enter
}

# A fresh folder asks "trust this folder?" with "No, exit" highlighted (one variant also lists the
# tool permissions .claude/settings.json pre-approves). Every pane here is this run's own, in its own
# throwaway folder. The screen draws before it takes keys, and Enter on "No, exit" quits Claude, so:
# let it settle, press Down, and press Enter only once "Yes, I trust this folder" is highlighted.
trust_pane() { # $1 pane
  local i scr
  sleep 2
  for i in 1 2 3 4 5 6; do
    scr=$(TM capture-pane -p -t "$1" 2>/dev/null)
    printf '%s\n' "$scr" | grep -q 'Yes, I trust this folder' || return 1
    if printf '%s\n' "$scr" | grep -q '❯ *Yes, I trust this folder'; then
      TM send-keys -t "$1" Enter; return 0
    fi
    TM send-keys -t "$1" Down; sleep 1
  done
  return 1
}

jp=$(TM new-session -d -s "$S" -n jarvis -x "$COLS" -y "$ROWS" -c "$toy" -P -F '#{pane_id}' "$jcmd") || { echo "record: tmux failed" >&2; exit 1; }
jw=$(TM display-message -p -t "$jp" '#{window_id}')
cam_start jarvis "$S"
t_start=$(ms)
echo "[record] $stamp · tmux -L $sock · $work · limit ${LIMIT_MIN} min$([ "$DRY" = 1 ] && echo ' · DRY RUN')"

jarvis_state() { # "idle <ms>" | "busy <ms>" | "none 0"
  local l; l=$(tail -n 1 "$marks" 2>/dev/null)
  case "$l" in stop\ *) echo "idle ${l#stop }" ;; prompt\ *) echo "busy ${l#prompt }" ;; *) echo "none 0" ;; esac
}
open_questions() { awk '/^## Questions for the user/{on=1; next} /^## /{on=0} on && /^- /' "$toy/handoffs/OPEN.md" 2>/dev/null | grep -c .; }
field() { sed -n "s/^$1:[[:space:]]*//p" "$2" | head -n 1; }

known=" $jw "; trusted=" "; workers=0; typed=0; blocked_at=0; answered=0; merges=0; done_at=0; jq_asked=0
base=$(git -C "$toy" rev-parse HEAD); seen_commits=" "; seen_blocked=" "
deadline=$(( t_start + LIMIT_MIN * 60000 ))
while :; do
  now=$(ms)
  [ "$now" -lt "$deadline" ] || { log_ev timeout "${LIMIT_MIN} min"; break; }
  panes=$(TM list-panes -s -t "=$S" -F '#{window_id}|#{pane_id}|#{window_name}|#{@jarvis}' 2>/dev/null)
  tagged=0
  while IFS='|' read -r wid pid wname tag; do
    [ -n "$wid" ] || continue
    [ -n "$tag" ] && tagged=$((tagged + 1))
    case "$known" in *" $wid "*) ;; *)
      known="$known$wid "
      name=$(printf '%s' "$wname" | tr -c 'A-Za-z0-9._-' '-')
      cam_for_window "$wid" "$name" || log_ev cam_failed "$name"
      if [ -n "$tag" ]; then workers=$((workers + 1)); log_ev worker_spawned "$name" "$pid"; else log_ev window "$name" "$pid"; fi ;;
    esac
    case "$trusted" in *" $pid "*) ;; *)
      if TM capture-pane -p -t "$pid" 2>/dev/null | grep -q 'Yes, I trust this folder'; then
        if trust_pane "$pid"; then trusted="$trusted$pid "; log_ev trust "$wname" "$pid"; else log_ev trust_retry "$wname" "$pid"; fi
      fi ;;
    esac
  done <<EOF
$panes
EOF
  # cameras whose window has closed (merge closes a worker's window, and its camera session with it)
  for f in "$work"/cams/*; do
    [ -f "$f" ] || continue
    case "$f" in *.ended) continue ;; esac
    kill -0 "$(sed -n 2p "$f")" 2>/dev/null || { log_ev rec_end "${f##*/}"; mv "$f" "$f.ended"; }
  done
  if [ "$TRUST_ONLY" = 1 ]; then
    case "$trusted" in *" $jp "*)
      sleep 6
      if TM capture-pane -p -t "$jp" | grep -q 'bypass permissions on'; then log_ev trust_ok "Claude at its prompt"; else log_ev trust_failed "$(TM capture-pane -p -t "$jp" | grep . | tail -n 3 | tr '\n' ' ')"; fi
      break ;;
    esac
    [ $(( now - t_start )) -lt 60000 ] || { log_ev trust_failed "no trust screen answered in 60 s"; break; }
    sleep 0.5; continue
  fi
  read -r jst jms <<EOF
$(jarvis_state)
EOF
  # beat 1: Jarvis has finished its first turn; type the request
  if [ "$typed" = 0 ] && [ "$jst" = idle ]; then
    sleep 3; type_into "$jp" "$message"; typed=1; log_ev typed_message "$message"
    msg_at=$(ms)
  fi
  # beat 3: a blocked handoff, then Jarvis idle again with the question put to the user
  for h in "$toy"/handoffs/*.md; do
    case "${h##*/}" in OPEN.md|JARVIS.md|TEMPLATE.md|LESSONS.md) continue ;; esac
    [ -f "$h" ] && [ "$(field status "$h")" = blocked ] || continue
    case "$seen_blocked" in *" ${h##*/} "*) continue ;; esac
    seen_blocked="$seen_blocked${h##*/} "
    [ "$blocked_at" = 0 ] && blocked_at=$(ms)
    cp "$h" "$out/blocked-${h##*/}"
    log_ev blocked "handoffs/${h##*/}"
  done
  if [ "$blocked_at" != 0 ] && [ "$answered" = 0 ] && [ "$jst" = idle ] && [ "$jms" -gt "$blocked_at" ]; then
    if [ "$(open_questions)" -gt 0 ] || [ $(( now - jms )) -gt 20000 ]; then
      log_ev question_shown "$(open_questions) in OPEN.md"
      sleep 4; type_into "$jp" "$answer"; answered=1; log_ev answer_typed "$answer"
    fi
  fi
  # Jarvis asking the user itself before spawning: answered the same way, logged apart
  if [ "$typed" = 1 ] && [ "$workers" = 0 ] && [ "$jq_asked" = 0 ] && [ "$jst" = idle ] \
     && [ "$jms" -gt "$msg_at" ] && [ $(( now - jms )) -gt 15000 ]; then
    log_ev jarvis_question "Jarvis asked before spawning"
    type_into "$jp" "$answer"; jq_asked=1; log_ev answer_typed "$answer"
  fi
  # beat 4: merge commits
  for c in $(git -C "$toy" rev-list --reverse "$base..HEAD" 2>/dev/null); do
    case "$seen_commits" in *" $c "*) continue ;; esac
    seen_commits="$seen_commits$c "; merges=$((merges + 1))
    log_ev merge "$(git -C "$toy" log -1 --format=%h "$c")" "$(git -C "$toy" log -1 --format=%s "$c")"
  done
  if [ "$merges" -ge 2 ]; then
    [ "$done_at" = 0 ] && done_at=$now
    if { [ "$tagged" = 0 ] && [ "$jst" = idle ] && [ $(( now - jms )) -gt 8000 ]; } || [ $(( now - done_at )) -gt 120000 ]; then
      log_ev finished "$merges commits"; break
    fi
  fi
  sleep 0.5
done

sleep 4   # a little tail on every camera
for f in "$work"/cams/*; do
  [ -f "$f" ] || continue
  case "$f" in *.ended) continue ;; esac
  TM detach-client -s "=$(sed -n 1p "$f")" >/dev/null 2>&1
done
for f in "$work"/cams/*; do
  [ -f "$f" ] || continue
  case "$f" in *.ended) continue ;; esac
  p=$(sed -n 2p "$f"); i=0
  while kill -0 "$p" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
  log_ev rec_end "${f##*/}"; mv "$f" "$f.ended"
done
TM capture-pane -p -t "$jp" -S -200 > "$out/jarvis-final-screen.txt" 2>/dev/null

git -C "$toy" log --oneline > "$out/commits.txt"
mkdir -p "$out/toy-handoffs"
cp -R "$toy/handoffs/briefs" "$toy/handoffs/merged" "$toy/handoffs/OPEN.md" "$out/toy-handoffs/" 2>/dev/null
for h in "$toy"/handoffs/*.md; do
  case "${h##*/}" in OPEN.md|JARVIS.md|TEMPLATE.md|LESSONS.md) ;; *) [ -f "$h" ] && cp "$h" "$out/toy-handoffs/" ;; esac
done
cp "$toy/handoffs/.jarvis/watch.log" "$out/toy-handoffs/watch.log" 2>/dev/null
git -C "$toy" diff "$base" HEAD -- . ':!handoffs' > "$out/toy-diff.patch" 2>/dev/null

# ---------------------------------------------------------------- render, then the beat log
if [ "$RENDER" = 1 ]; then
  for c in "$out"/*.cast; do
    [ -s "$c" ] || continue
    b=${c%.cast}
    echo "[record] rendering ${b##*/}"
    agg --font-size "$FONT" --theme github-dark --idle-time-limit 100000 --fps-cap 15 --last-frame-duration 1 \
      "$c" "$work/render.gif" >/dev/null 2>&1 \
      && ffmpeg -y -loglevel error -i "$work/render.gif" -movflags +faststart -pix_fmt yuv420p \
        -vf 'scale=trunc(iw/2)*2:trunc(ih/2)*2' -r 30 -c:v libx264 -crf 20 "$b.mp4" \
      || echo "[record] render failed: ${b##*/}"
    rm -f "$work/render.gif"
  done
fi

DEMO_DRYRUN=$DRY DEMO_COLS=$COLS DEMO_ROWS=$ROWS DEMO_FONT=$FONT DEMO_STAMP=$stamp \
  python3 -I - "$ev" "$out" <<'PY'
import json, os, re, sys
ev, out = sys.argv[1], sys.argv[2]
rows = []
for line in open(ev, encoding="utf-8"):
    p = line.rstrip("\n").split("\t")
    p += [""] * (4 - len(p))
    rows.append((int(p[0]), p[1], p[2], p[3]))
t0 = next((t for t, k, a, _ in rows if k == "rec_start" and a == "jarvis"), rows[0][0] if rows else 0)
s = lambda t: round((t - t0) / 1000, 1)
first = lambda k: next(((t, a, b) for t, kk, a, b in rows if kk == k), None)
recs = {}
for t, k, a, b in rows:
    if k == "rec_start":
        recs[a] = {"name": a, "cast": b, "mp4": b[:-5] + ".mp4" if os.path.exists(os.path.join(out, b[:-5] + ".mp4")) else None,
                   "starts_at": s(t), "ends_at": None}
    elif k == "rec_end" and a in recs and recs[a]["ends_at"] is None:
        recs[a]["ends_at"] = s(t)
workers = [{"window": a, "pane": b, "at": s(t)} for t, k, a, b in rows if k == "worker_spawned"]
merges = [{"commit": a, "subject": b, "at": s(t)} for t, k, a, b in rows if k == "merge"]
blocked = [{"handoff": a, "at": s(t)} for t, k, a, b in rows if k == "blocked"]
questions = []
for f in sorted(os.listdir(out)):
    if f.startswith("blocked-"):
        txt = open(os.path.join(out, f), encoding="utf-8").read()
        m = re.search(r"^## Questions for the user\n(.*?)(?=^## |\Z)", txt, re.S | re.M)
        if m and m.group(1).strip():
            questions.append({"handoff": f[len("blocked-"):], "text": m.group(1).strip()})
msg, shown, ans, jq = first("typed_message"), first("question_shown"), first("answer_typed"), first("jarvis_question")
beats = [
    {"beat": 1, "name": "one message", "at": s(msg[0]) if msg else None, "text": msg[1] if msg else None},
    {"beat": 2, "name": "two workers start", "at": workers[1]["at"] if len(workers) > 1 else None, "workers": workers},
    {"beat": 3, "name": "a question batch",
     "at": s(ans[0]) if ans and blocked else None,
     "blocked": blocked, "question_shown_at": s(shown[0]) if shown else None,
     "jarvis_asked_before_spawning_at": s(jq[0]) if jq else None,
     "answer_typed_at": s(ans[0]) if ans else None, "answer": ans[1] if ans else None, "questions": questions},
    {"beat": 4, "name": "a merge with two commits", "at": merges[1]["at"] if len(merges) > 1 else None, "merges": merges},
]
end = next(((t, k) for t, k, a, b in rows if k in ("finished", "timeout")), None)
doc = {
    "run": os.environ["DEMO_STAMP"], "dry_run": os.environ["DEMO_DRYRUN"] == "1",
    "times": "seconds from the start of jarvis.cast (each recording's own start is starts_at)",
    "terminal": {"cols": int(os.environ["DEMO_COLS"]), "rows": int(os.environ["DEMO_ROWS"]),
                 "recorded_rows": int(os.environ["DEMO_ROWS"]) + 1, "status_bar": "tmux, bottom row",
                 "render_font_px": int(os.environ["DEMO_FONT"]), "render_theme": "github-dark"},
    "layout": "one recording per tmux window (Jarvis, its watcher, each worker), each 80x31: stack two for 9:16, tile for 16:9",
    "claude_statusline": "kept (Jarvis's own statusline tap: real usage)",
    "all_beats": all(b["at"] is not None for b in beats),
    "ended": {"how": end[1] if end else None, "at": s(end[0]) if end else None},
    "beats": beats,
    "recordings": list(recs.values()),
    "events": [{"at": s(t), "kind": k, "a": a, "b": b} for t, k, a, b in rows],
}
json.dump(doc, open(os.path.join(out, "beats.json"), "w", encoding="utf-8"), indent=2, ensure_ascii=False)
print(f"[record] beats: " + ", ".join(f"{b['beat']}={b['at']}" for b in beats) + f" · all beats: {doc['all_beats']}")
PY

echo "[record] commits:"; sed 's/^/  /' "$out/commits.txt"
echo "[record] footage: $out"
