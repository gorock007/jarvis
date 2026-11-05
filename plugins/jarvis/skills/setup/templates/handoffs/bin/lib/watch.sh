# shellcheck shell=bash
# Sourced by bin/jarvis; not run on its own.
LIMIT_RE="(usage|rate|session|weekly|daily|hourly|5-hour) limit (was |has been )?(reached|exceeded|hit)|(hit|reached|exceeded) (your|the) [a-z0-9 -]*limit|limit reached|quota (was |has been )?(exceeded|exhausted)|out of credits|too many requests"
# A worker sitting at a trust or approval prompt does nothing until someone answers it.
PROMPT_RE="trust (this|the files in this) folder|do you trust|is this a project you created or one you trust|allow codex to work in this folder|press enter to confirm|would you like to (run|make|apply)|do you want to (proceed|make this edit|create|overwrite|run|allow)|allow (this|once)|\\(y/n\\)|\\[y/n\\]"

# ---------------------------------------------------------------- watch

jarvis_idle_min() { # minutes since the Jarvis transcript last changed; empty if unknown
  local tp
  have jq || return
  tp=$(jq -r '.transcript_path // empty' "$STATE/session.json" 2>/dev/null)
  [ -n "$tp" ] && [ -f "$tp" ] || return
  echo $(( ($(now) - $(mtime "$tp")) / 60 ))
}

send_jarvis() { # $1 = text
  host send "$(jarvis_terminal)" "$1" >/dev/null 2>&1
}

watch_running() { # a `jarvis watch` loop for this checkout is alive
  local p
  p=$(cat "$STATE/watch.pid" 2>/dev/null) && [ -n "$p" ] \
    && ps -p "$p" -o command= 2>/dev/null | grep -q "jarvis watch"
}

# One "<UTC time>\t<woke|cleared|nojarvis|auto>\t<reasons>\t<n events>" line per wake/action in
# watch.log; reasons are the sorted kinds from the tick's events (`jarvis usage` counts them).
watch_log() { # $1 = woke | cleared | nojarvis | auto, $2 = kinds, one per event/action
  local k
  k=$(printf '%s\n' $2 | sort -u | paste -sd, -)
  mkdir -p "$STATE" && printf '%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$k" "$(echo $2 | wc -w | tr -d ' ')" >> "$STATE/watch.log"
}

fastpath_on() { case " $JARVIS_FASTPATH " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# Return kind<TAB>key<TAB>path only for a fully recognized, allowlisted prompt.
# Python supplies realpath (including missing files below symlinked parents). Missing
# Python, malformed scope, truncated headers and unknown UI shapes all fail closed.
watch_prompt_action() { # $1 run, $2 screen
  local agent brief screen=$2
  agent=$(run_get "$1" agent); brief=$(run_get "$1" brief)
  [ "$(run_get "$1" state)" = running ] && [ -f "$brief" ] && have python3 || return 1
  case "$agent" in codex) fastpath_on trust ;; claude) fastpath_on edit ;; *) return 1 ;; esac || return 1
  # detection saw watch_tick's 15 lines; the edit attempt alone re-reads 80, for the
  # header above a full diff (a failed read is an empty screen, which fails closed)
  [ "$agent" = claude ] && screen=$(host read "$1" 80 2>/dev/null | sed -e 's/[[:space:]]*$//')
  python3 -I - "$ROOTP" "$brief" "$agent" "$(run_get "$1" spawned)" "$screen" <<'PY'
import os, re, sys
from pathlib import Path

root, brief, agent, spawned, screen = sys.argv[1:]
def deny():
    sys.exit(1)

# Do not interpret terminal escape/control sequences as a path or an approval.
if any(ord(c) < 32 and c not in "\n\t" for c in screen):
    deny()
raw_lines = [s.rstrip() for s in screen.splitlines()]
# Both layouts below are copied from live screens (Claude Code 2.1.311, Codex
# 0.157.1; eval/terminals/41-48). Any other shape, wording or width fails closed.
if agent == "codex":
    # The trust prompt is a full screen of its own: blank rows, then exactly
    #   Folder access / <checkout path, maybe wrapped> / blank / the paragraph /
    #   blank / › 1. Trust and continue / 2. Quit / blank / enter continue · esc quit
    rows = raw_lines
    while rows and not rows[0]:
        rows = rows[1:]
    gaps = [i for i, s in enumerate(rows) if not s]
    if len(gaps) != 3 or rows[0] != "  Folder access" or gaps[0] < 2:
        deny()
    folder, para, menu, foot = rows[1:gaps[0]], rows[gaps[0] + 1:gaps[1]], rows[gaps[1] + 1:gaps[2]], rows[gaps[2] + 1:]
    text = "Trust this folder? Codex can read, edit, and run files here, subject to your permission settings. " \
        "Folder settings can run code automatically, even without a model request. " \
        "Continue only if you trust these files. Your trust decision will be saved."
    if any(not s.startswith("  ") or s[2:3] == " " for s in folder + para) or " ".join(s[2:] for s in para) != text \
            or menu != ["› 1. Trust and continue", "  2. Quit"] or foot != ["  enter continue · esc quit"]:
        deny()
    # A wrapped path is split mid-word, so its rows join with nothing between them.
    shown = "".join(s[2:] for s in folder)
    try:
        if not os.path.isabs(shown) or not os.path.samefile(shown, root):
            deny()
    except OSError:
        deny()
    # Trust highlighted: Enter confirms it. A digit only moves the highlight in
    # this menu, so with Quit highlighted nothing is sent (the menu check above).
    print("trust\tenter\ttrust")
    sys.exit(0)

# Claude's edit dialog ends the screen, nothing in a box or gutter:
#   ⏺ Update|Write(<path>)        the tool header, if it hasn't scrolled off
#   ──────────                    full-width rule
#    Edit file | Create file | Overwrite file
#    <path>                       one row; a long one is shortened to …<tail>
#   ╌╌╌╌╌╌╌╌╌╌                    then diff rows, then ╌╌╌╌╌╌╌╌╌╌ again
#    Do you want to make this edit to <name>? | create <name>? | overwrite <name>?
#    ❯ 1. Yes / 2. Yes, and switch to accept edits (…) / 3. No / blank / footer
# The path comes only from the row under the title. Diff rows are untrusted text,
# but each starts with its line number or, wrapped, with 3+ spaces, so none can
# pass for a rule or title row (column 0 or 1).
kinds = {"Edit file": ("Update", r"make this edit to"), "Create file": ("Write", r"create"),
         "Overwrite file": ("Write", r"overwrite")}
tail = raw_lines
while tail and not tail[-1]:
    tail = tail[:-1]
if len(tail) < 12 or tail[-1] != " Esc to cancel · Tab to amend" or tail[-2] != "":
    deny()
end = len(tail) - 2
opts = [i for i in range(end) if tail[i].startswith(" ❯ 1. ")]
if len(opts) != 1 or tail[end - 1] != "   3. No":
    deny()
idx = opts[0] - 1   # the question, and the only prompt-like row on the screen
if any(re.search(r"(?i)would you like|do you want|bash command|allow once", s) for i, s in enumerate(tail) if i != idx):
    deny()
option2 = " ".join(s.strip() for s in tail[opts[0] + 1:end - 1])
if tail[opts[0]] != " ❯ 1. Yes" or not tail[opts[0] + 1].startswith("   2. ") \
        or any(not s.startswith("      ") for s in tail[opts[0] + 2:end - 1]) \
        or option2 != "2. Yes, and switch to accept edits (auto-approve file edits and common file commands) for this session (shift+tab)":
    deny()
low = idx - 1
if low < 5 or not re.fullmatch(r"╌{20,}", tail[low]):
    deny()
high = low - 1
while high >= 0 and re.match(r" {0,6}\d+(?: |$)| {3,}\S", tail[high]):
    # A row that echoes a tool header or dialog title is not trusted as plain diff.
    if re.search(r"⏺|(?:Edit|Create|Overwrite) file", tail[high]):
        deny()
    high -= 1
if high < 3 or tail[high] != tail[low] or len(tail[high - 3]) != len(tail[low]) \
        or not re.fullmatch(r"─+", tail[high - 3]) or high == low - 1:
    deny()
title, path = tail[high - 2][1:], tail[high - 1][1:]
if tail[high - 2][:1] != " " or tail[high - 1][:1] != " " or title not in kinds:
    deny()
tool, ask = kinds[title]
prompt = re.fullmatch(r" Do you want to " + ask + r" ([^/?]+)\?", tail[idx])
if not prompt or not path or path != path.strip() or os.path.basename(path) != prompt[1]:
    deny()
# Above the dialog: no rule or title row (dialog chrome there means this
# "dialog" sits inside another one), and the nearest line, if any is visible, is
# the matching tool header, not itself under another pending edit header.
if any(re.fullmatch(r"─{20,}|╌{20,}| (?:Edit|Create|Overwrite) file", s) for s in tail[:high - 3]):
    deny()
above = [s.strip() for s in tail[:high - 3] if s.strip()]
if above:
    head = re.fullmatch(r"⏺ (Update|Write)\(([^()]+)\)", above[-1])
    if not head or head[1] != tool or head[2] != path or (len(above) > 1 and re.match(r"⏺ (?:Update|Write)\(", above[-2])):
        deny()

def resolve(p):
    if not re.fullmatch(r"[A-Za-z0-9_./@+ -]+", p) or ".." in p.split("/"):
        deny()
    lexical = os.path.abspath(os.path.join(root, p))
    try:
        real = str(Path(lexical).resolve())
        # Even an intermediate symlink outside followed by one back inside is
        # outside this allowlist. Check each prefix, including missing parents.
        prefix = lexical
        while prefix != root and os.path.commonpath([root, prefix]) == root:
            if os.path.commonpath([root, str(Path(prefix).resolve())]) != root:
                deny()
            prefix = os.path.dirname(prefix)
    except (OSError, RuntimeError):
        deny()
    if any(os.path.commonpath([root, x]) != root for x in (lexical, real)):
        deny()
    return lexical, real

lexical, real = resolve(path)
try:
    content = Path(brief).read_text()
    scopes = re.findall(r"(?ms)^## Scope\s*\n(.*?)(?=^## |\Z)", content)
    if len(scopes) != 1:
        deny()
    def entries(label):
        rows = re.findall(r"(?m)^- " + label + r":(.*)$", scopes[0])
        if len(rows) > 1 or (label == "May touch" and not rows):
            deny()
        if not rows or rows[0].strip().lower() in ("", "none"):
            return []
        result = []
        for entry in rows[0].split(","):
            entry = entry.strip()
            spans = re.findall(r"`([^`]*)`", entry)
            if re.fullmatch(r"`[^`]*`", entry):
                entry = spans[0]
            elif len(spans) == 1 and entry.count("`") == 2:
                # Prose around one backticked path ("root `handoffs/`", "new files in `x/`").
                # As an exclusion it names the whole path, which only widens it; as a
                # grant the prose may narrow it, so the entry grants nothing.
                if label == "May touch":
                    continue
                entry = spans[0]
            elif "`" in entry or re.search(r"\s", entry):
                deny()
            a, b = resolve(entry)
            result.append((a, b, entry.endswith("/") or os.path.isdir(a)))
        return result
    allow, block = entries("May touch"), entries("Must not touch")
    def matches(entry, folded=False):
        a, b, directory = entry
        xs, ys = (lexical, real), (a, b)
        if folded:
            xs, ys = [x.casefold() for x in xs], [y.casefold() for y in ys]
        return any(x == y or (directory and x.startswith(y.rstrip("/") + "/"))
                   for x in xs for y in ys)
    def same(entry):  # the file, or a folder above it, is an existing exclusion
        a, b, directory = entry
        p = real
        while os.path.commonpath([root, p]) == root:
            if os.path.exists(p) and os.path.exists(b) and os.path.samefile(p, b):
                return True
            if not directory or p == root:
                return False
            p = os.path.dirname(p)
        return False
    # Be conservative on every filesystem: case variants of an exclusion stay
    # excluded, and an allow entry with different casing never grants access.
    if (not any(map(matches, allow)) or any(matches(e, True) for e in block)
            or any(map(same, block)) or any(matches(e, True) and not matches(e) for e in allow)):
        deny()
    for candidate in (lexical, real):
        rel = os.path.relpath(candidate, root)
        parts = rel.lower().split("/")
        name = parts[-1]
        if any(p in (".claude", ".git") for p in parts) or name.startswith(("settings", ".env")) or name.endswith((".pem", ".key")) or name == "jarvis.conf":
            deny()
        if parts[0] == "handoffs":
            # Only an identifiable handoff from this run, explicitly listed as a
            # file, can bypass the root handoffs exclusion. New/unknown ones wake.
            if len(parts) != 2 or not name.endswith(".md") or not any(a == lexical and not d for a, b, d in allow):
                deny()
            handoff = Path(candidate)
            owners = re.findall(r"(?m)^brief:\s*(\S+)\s*$", handoff.read_text())
            if owners != [brief] or handoff.stat().st_mtime < int(spawned):
                deny()
    print("edit\tenter\t" + os.path.relpath(lexical, root))
except (OSError, ValueError):
    deny()
PY
}

watch_auto_prompt() { # $1 run, $2 screen, $3 event | screen (what raised it); send first, record only successful actions
  local action kind keys path
  action=$(watch_prompt_action "$1" "$2") || return 1
  IFS="$TAB" read -r kind keys path <<EOF
$action
EOF
  host send "$1" --keys "$keys" >/dev/null 2>&1 || return 1
  watch_log source "$kind:${3:-screen}"
  watch_log auto "$kind"
  audit "auto-$kind" "$1" "$(run_get "$1" brief)" "path=$path key=$keys" sent
}

# The batch the watcher holds before waking Jarvis: "opened: <epoch>" (when its first
# event arrived), "kinds: ...", "events: ..." and "nojarvis: 1" once that's logged.
PENDING="$STATE/watch.pending"

pending_get() { # $1 = key
  [ -f "$PENDING" ] || return 0
  awk -v k="$1" 'index($0, k ": ") == 1 {print substr($0, length(k) + 3); exit}' "$PENDING"
}

pending_put() { # $1 = opened, $2 = kinds, $3 = events, $4 = nojarvis; written to a temp file, then moved
  local tmp
  mkdir -p "$STATE" && tmp=$(mktemp "$STATE/.pending.XXXXXX") || return 1
  printf 'opened: %s\nkinds: %s\nevents: %s\nnojarvis: %s\n' "$1" "$2" "$(printf '%s' "$3" | tr '\n' ' ')" "$4" > "$tmp" \
    && mv "$tmp" "$PENDING"
}

# A worker's last hook event (jarvis hook event) of its own run since it was spawned, so
# a respawn of the brief starts clean and the old worker's late lines (its ended after
# jarvis close) don't count; a line with no run counts for none: "<t> <kind> <turn> <line>", where turn
# is when its current turn began (its last working event, else the spawn) and line the
# event's line number (with t, the dedup key). Empty: no events file, or an agent that
# writes none (Claude does; Codex and OpenCode on tmux).
watch_event() { # $1 = run
  local brief f
  case "$(run_get "$1" agent)" in claude|codex|opencode) ;; *) return 0 ;; esac
  brief=$(run_get "$1" brief)
  f="$STATE/events/$(basename "${brief:-@}" .md).jsonl"
  [ -n "$brief" ] && [ -f "$f" ] || return 0
  awk -v sp="$(run_get "$1" spawned | grep -Ex '[0-9]+' || echo 0)" -v run="$1" '
    match($0, /^[{]"t":[0-9]+,"kind":"[a-z]+","run":"[^"]*"/) {
      h = substr($0, 6, RLENGTH - 6); t = h; sub(/,.*/, "", t); k = h; sub(/.*"kind":"/, "", k); sub(/".*/, "", k)
      r = h; sub(/.*"run":"/, "", r)
      if (r != run || t + 0 < sp + 0 || k !~ /^(working|stop|permission|waiting|ended)$/) next
      if (k == "working") w = t
      lt = t; lk = k; ln = NR }
    END { if (ln) print lt, lk, (w ? w : sp + 0), ln }' "$f"
}

handoff_since() { # $1 = brief, $2 = epoch: a handoff for the brief in handoffs/, written (or rewritten) at or after it
  local ho b
  [ -n "$1" ] || return 1
  for ho in "$H"/*.md; do
    [ -f "$ho" ] || continue
    case "${ho##*/}" in OPEN.md|TEMPLATE.md|JARVIS.md) continue ;; esac
    # the brief's path on its brief: line as merge finds it, with ./, quotes or a note
    # around it; it must end there (x.md.old isn't x.md)
    # an absolute path counts when it is this checkout's (as git or pwd -P names it) plus the brief
    b=$(field brief "$ho" | sed 's#^[^A-Za-z0-9_/]*##')
    case "$b" in
      "$ROOT/${1#./}"|"$ROOT/${1#./}"[!A-Za-z0-9_.-]*|"$ROOTP/${1#./}"|"$ROOTP/${1#./}"[!A-Za-z0-9_.-]*) ;;
      *) b=${b#"${b%%[!/]*}"}; case "$b" in "${1#./}"|"${1#./}"[!A-Za-z0-9_.-]*) ;; *) continue ;; esac ;;
    esac
    [ "$(mtime "$ho")" -ge "$2" ] && return 0
  done
  return 1
}

# The stall path, whether the screen or a hook event raised it: the one nudge, then a
# wake once another JARVIS_STALL_MIN has passed. Adds to watch_tick's events and kinds.
watch_stall() { # $1 run, $2 event | screen, $3 dedup key, $4 the event's text
  local nudged t
  if fastpath_on nudge && [ "$(run_get "$1" state)" = running ]; then
    nudged=$(run_get "$1" nudged); t=$(now)
    if [ -z "$nudged" ]; then
      if host send "$1" "Finish the phase or write your handoff now." >/dev/null 2>&1; then
        run_set "$1" nudged "$t"
        watch_log source "nudge:$2"
        watch_log auto nudge
        audit auto-nudge "$1" "$(run_get "$1" brief)" "prompt=stall key=enter" sent
        return 0
      fi
    elif [ $(( t - nudged )) -lt $(( JARVIS_STALL_MIN * 60 )) ]; then
      return 0
    fi
  fi
  grep -qxF "$3" "$seen" && return 0
  echo "$3" >> "$seen"; events="$events $4;"; kinds="$kinds stall"
  watch_log source "stall:$2"
}

watch_tick() {
  local seen="$STATE/watch.seen" events="" kinds="" ho key id tail_ idle term line brief sum scr stale b opened new t read_lines=15
  local ev et ek eturn en pe src
  touch "$seen"
  for ho in "$H"/*.md; do
    [ -f "$ho" ] || continue
    case "$(basename "$ho")" in OPEN.md|TEMPLATE.md|JARVIS.md) continue ;; esac
    key="$ho $(mtime "$ho") $(field status "$ho")"
    grep -qxF "$key" "$seen" && continue
    echo "$key" >> "$seen"
    events="$events handoff $ho ($(field status "$ho"));"; kinds="$kinds handoff"
  done
  while IFS= read -r line; do
    id=$(printf '%s' "$line" | sed -n 's/.*term \([^ ]*\).*/\1/p')
    [ -n "$id" ] || continue
    tail_=$(host read "$id" "$read_lines" 2>/dev/null | sed -e 's/[[:space:]]*$//')
    b=$(budget_tick "$id" "$tail_" </dev/null)
    [ -n "$b" ] && { events="$events$b"; kinds="$kinds budget"; }
    # a worker's own hook events come first; the screen is the fallback
    ev=$(watch_event "$id"); ek=""; pe=""
    if [ -n "$ev" ]; then
      read -r et ek eturn en <<EOF
$ev
EOF
      brief=$(run_get "$id" brief)
      if [ "$ek" = ended ]; then
        key="ended $id $en $et"
        if ! handoff_since "$brief" "$eturn" && ! grep -qxF "$key" "$seen"; then
          echo "$key" >> "$seen"; events="$events worker $(short "$id") ended without a handoff — read its terminal;"; kinds="$kinds ended"
          watch_log source ended:event
        fi
      fi
      # a permission event is acted on once; after that the screen decides
      [ "$ek" = permission ] && ! grep -qxF "pev $id $en $et" "$seen" && pe=1
    fi
    sum=$(printf '%s' "$tail_" | cksum | cut -d' ' -f1)
    scr="$STATE/screen-$id"
    if [ -n "$tail_" ] && printf '%s' "$tail_" | grep -Eiq "$LIMIT_RE"; then
      key="limit $id $(date +%Y%m%d%H)"
      grep -qxF "$key" "$seen" || { echo "$key" >> "$seen"; events="$events usage limit in worker $(short "$id");"; kinds="$kinds limit"; }
    elif [ "$ek" = ended ]; then
      :   # the session is over: no prompt to answer, no turn to stall
    elif [ -n "$pe" ] || { [ -n "$tail_" ] && printf '%s' "$tail_" | grep -Eiq "$PROMPT_RE"; }; then
      src=screen; [ -n "$pe" ] && { src=event; echo "pev $id $en $et" >> "$seen"; }
      key="prompt $id $sum"
      # A successful send is not proof the UI accepted it. If this screen is
      # observed again, raise the normal deduplicated prompt event, never retry.
      if ! grep -qxF "auto $id $sum" "$seen" && ! grep -qxF "$key" "$seen" && watch_auto_prompt "$id" "$tail_" "$src"; then
        echo "auto $id $sum" >> "$seen"
        continue
      fi
      t=""; grep -qxF "auto $id $sum" "$seen" && t=" (the automatic answer did not take)"
      grep -qxF "$key" "$seen" || { echo "$key" >> "$seen"; events="$events worker $(short "$id") is waiting at a prompt$t — read its terminal;"; kinds="$kinds prompt"; watch_log source "prompt:$src"; }
    elif [ "$ek" = stop ] || [ "$ek" = waiting ]; then
      # its turn is over: stalled once that's JARVIS_STALL_MIN old with no handoff since the
      # turn began, and the screen has been frozen that long too. A screen that changed
      # since the event is a worker at work again (a background job woke it, and no
      # prompt hook fires for that), so the clock runs from the later of the two; the
      # screen's record is the frozen-screen check's own (the first look is a change)
      [ "$(cat "$scr" 2>/dev/null)" = "$sum" ] || echo "$sum" > "$scr"
      t=$(mtime "$scr"); [ "$t" -gt "$et" ] || t=$et
      stale=$(( ($(now) - et) / 60 ))
      [ $(( ($(now) - t) / 60 )) -ge "$JARVIS_STALL_MIN" ] && ! handoff_since "$brief" "$eturn" \
        && watch_stall "$id" event "stall $id event $en $et" "worker $(short "$id") finished its turn ${stale} min ago (hook event: $ek) and has no handoff — read its terminal"
    elif [ -n "$tail_" ]; then
      # working, or no hook events: a working agent's screen keeps changing (spinner,
      # timer, output); a frozen one with no handoff is stuck at something the patterns
      # above don't know
      if [ "$(cat "$scr" 2>/dev/null)" != "$sum" ]; then
        echo "$sum" > "$scr"
      else
        stale=$(( ($(now) - $(mtime "$scr")) / 60 ))
        brief=$(printf '%s' "$line" | grep -o "$H/briefs/[^ ]*\.md" | head -n 1)
        if [ "$stale" -ge "$JARVIS_STALL_MIN" ] && ! handoff_since "$brief" 0; then
          watch_stall "$id" screen "stall $id $sum" "worker $(short "$id")'s screen hasn't changed in ${stale} min and it has no handoff — read its terminal"
        fi
      fi
    fi
  done <<EOF
$(running_lines)
EOF
  # this tick's events join the pending batch; the batch goes out as one message on the
  # first tick JARVIS_BATCH_SEC after it opened, so a burst costs Jarvis one turn
  new=$events
  opened=$(pending_get opened)
  [ -f "$PENDING" ] && case "$opened" in ""|*[!0-9]*) opened=0 ;; esac   # unreadable: send what's there now
  if [ -n "$new" ]; then
    [ -n "$opened" ] || opened=$(now)
    pending_put "$opened" "$(pending_get kinds)$kinds" "$(pending_get events)$new" "$(pending_get nojarvis)"
  fi
  [ -n "$opened" ] || return 0
  if [ $(( $(now) - opened )) -lt "$JARVIS_BATCH_SEC" ]; then
    [ -z "$new" ] || echo "$(date +%H:%M) holding for the batch (due in $(( opened + JARVIS_BATCH_SEC - $(now) ))s):$new"
    return 0
  fi
  events=$(pending_get events); kinds=$(pending_get kinds)
  [ -n "$events" ] || { rm -f "$PENDING"; return 0; }

  term=$(jarvis_terminal)
  if [ -z "$term" ]; then # the batch waits for a Jarvis session; nojarvis is logged once per batch
    if [ -z "$(pending_get nojarvis)" ]; then
      watch_log nojarvis "$kinds"; pending_put "$opened" "$kinds" "$events" 1
      echo "$(date +%H:%M) events but no Jarvis session in $OPEN:$events"
    elif [ -n "$new" ]; then
      echo "$(date +%H:%M) events but no Jarvis session in $OPEN:$new"
    fi
    return 0
  fi
  idle=$(jarvis_idle_min)
  if [ -n "$idle" ] && [ "$idle" -ge "$JARVIS_IDLE_MIN" ]; then
    if type "${HOST}_clear" >/dev/null 2>&1; then host clear "$term" && sleep 5
    else send_jarvis "/clear"; sleep 3
    fi
    send_jarvis "[jarvis watch] Fresh session: Jarvis was idle ${idle} min, so its cache had expired. You are Jarvis — use the jarvis:run skill, read handoffs/JARVIS.md and handoffs/OPEN.md, run handoffs/bin/jarvis status, then handle:$events"
    watch_log cleared "$kinds"
    echo "$(date +%H:%M) cleared Jarvis (idle ${idle} min) and woke it:$events"
  else
    send_jarvis "[jarvis watch]$events"
    watch_log woke "$kinds"
    echo "$(date +%H:%M) woke Jarvis:$events"
  fi
  rm -f "$PENDING"
}

cmd_watch() {
  need_host
  mkdir -p "$STATE"
  if [ "${1:-}" = --once ]; then watch_tick; return; fi
  if [ "${1:-}" = --start ]; then
    watch_running && { echo "jarvis watch is already running (pid $(cat "$STATE/watch.pid"))"; return 0; }
    host run jarvis-watch "handoffs/bin/jarvis watch" && echo "started jarvis watch in its own terminal on $HOST"
    return
  fi
  watch_running && die "jarvis watch is already running (pid $(cat "$STATE/watch.pid"))"
  echo $$ > "$STATE/watch.pid"
  # first pass only learns what's already there
  for ho in "$H"/*.md; do
    [ -f "$ho" ] && echo "$ho $(mtime "$ho") $(field status "$ho")" >> "$STATE/watch.seen"
  done
  echo "jarvis watch: every ${JARVIS_WATCH_SEC}s (handoffs, limits, prompts, workers frozen ${JARVIS_STALL_MIN}+ min); $( [ "$JARVIS_BATCH_SEC" -gt 0 ] 2>/dev/null && echo "batches events for ${JARVIS_BATCH_SEC}s, then wakes Jarvis once" || echo "wakes Jarvis at once"); clears Jarvis first after ${JARVIS_IDLE_MIN} min idle. Ctrl-C to stop."
  while :; do sleep "$JARVIS_WATCH_SEC"; watch_tick; done
}
