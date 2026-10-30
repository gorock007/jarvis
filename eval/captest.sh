#!/usr/bin/env bash
# Offline test of the machine-wide Claude caps and the usage band in bin/jarvis: every
# active Claude session on the machine counts (busy or recently updated; idle, dead,
# reused-PID and sdk-* ones don't), per checkout and Opus caps, the spawn lease (two
# repos racing for the last slot), pending spawns, the band failing closed (no reading,
# stale), the burn rate, band-lowered caps and --force. Two throwaway repos with the
# template's handoffs/, a fake superset, fake session records for `sleep` processes this
# test starts, and a throwaway HOME, JARVIS_HOME and CLAUDE_CONFIG_DIR: ~/.jarvis and
# ~/.claude are never touched. Nothing launches a model, and nothing here is signalled
# until the test checks at the end that every fake session process is still alive.
#
#   eval/captest.sh
# `[ … ]; check "…" $?` reads the test's own status.
# shellcheck disable=SC2319,SC2012,SC2013
set -u
here=$(cd "$(dirname "$0")" && pwd)
tpl="$here/../plugins/jarvis/skills/setup/templates"
tmp=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/jarvis-captest.XXXXXX")" && pwd -P)
procs="$tmp/procs"
trap 'for p in $(cat "$procs" 2>/dev/null); do kill "$p" 2>/dev/null; done; rm -rf "$tmp"' EXIT
fails=0
ok() { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; fails=$((fails + 1)); }
check() { if [ "$2" = 0 ]; then ok "$1"; else bad "$1"; fi; }
command -v jq >/dev/null 2>&1 || { echo "captest: skipped (jq not installed)"; echo "captest: all passed"; exit 0; }

export HOME="$tmp/home" JARVIS_HOME="$tmp/jh" CLAUDE_CONFIG_DIR="$tmp/home/.claude" CODEX_HOME="$tmp/codex" SUPERSET_HOME_DIR="$tmp/sshome"
export GIT_AUTHOR_NAME=captest GIT_AUTHOR_EMAIL=captest@example.invalid GIT_COMMITTER_NAME=captest GIT_COMMITTER_EMAIL=captest@example.invalid
export FAKE_LOG="$tmp/fake.log" SUPERSET_WORKSPACE_ID=ws SUPERSET_TERMINAL_ID=jarvis-t PATH="$tmp/fake:$PATH"
unset TYPESAFE_API_KEY TMUX TMUX_PANE ULTRON_SESSION_ID JARVIS_HOST JARVIS_LOCK_DIR ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL \
  ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_SMALL_FAST_MODEL CLAUDE_CODE_SUBAGENT_MODEL
mkdir -p "$tmp/fake" "$CLAUDE_CONFIG_DIR/sessions" "$JARVIS_HOME" "$tmp/sshome/state"
cat > "$tmp/fake/superset" <<'EOT'
#!/bin/bash
echo "superset $*" >> "$FAKE_LOG"
case "$1 $2" in
  "agents create") [ -z "${FAKE_FAIL:-}" ] || exit 1
    n=$(( $(cat "$FAKE_LOG.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_LOG.n"
    printf '{"kind":"terminal","sessionId":"term-%s"}\n' "$n" ;;
  "terminals list") printf '{"sessions":[]}\n' ;;
esac
EOT
chmod +x "$tmp/fake/superset"

mkrepo() { # $1 = name: a checkout with the template's handoffs/ and Jarvis started in it
  mkdir -p "$tmp/$1" && (
    cd "$tmp/$1" && git init -q && cp -R "$tpl/handoffs" . \
      && sed -e 's/{{MAX_CLAUDE}}/3/' -e 's/{{AMBER}}/50/' -e 's/{{RED}}/75/' "$tpl/handoffs/jarvis.conf" > handoffs/jarvis.conf \
      && git add -A && git commit -qm init && handoffs/bin/jarvis start >/dev/null 2>&1
  )
}
mk() { # $1 repo, $2 brief name, $3 worker, $4 model
  printf '# %s\nworker: %s\nmodel: %s\neffort: high\n\n## Goal\nx\n' "$2" "$3" "$4" > "$tmp/$1/handoffs/briefs/$2.md"
}
J() { local r=$1; shift; (cd "$tmp/$r" && handoffs/bin/jarvis "$@"); }
spawn() { local r=$1 b=$2; shift 2; J "$r" spawn "handoffs/briefs/$b.md" "$@"; }

# sess <cwd> <status> <updated, seconds ago> [model|-] [entrypoint] [procStart] [started, seconds ago] → its pid
# A `sleep` this test starts stands in for the claude process; its session record is
# written as Claude Code writes them, and a transcript names its model unless it's -.
sess() {
  local p st n
  sleep 900 >/dev/null 2>&1 &
  p=$!; echo "$p" >> "$procs"; disown "$p" 2>/dev/null   # stopped by the EXIT trap, without a job notice
  st=${6:-$(TZ=UTC LC_ALL=C ps -o lstart= -p "$p" | tr -s ' ' | sed 's/ $//')}
  n=$(date +%s)
  mkdir -p "$1"
  printf '{"pid":%s,"sessionId":"s%s","cwd":"%s","procStart":"%s","status":"%s","updatedAt":%s000,"statusUpdatedAt":%s000,"startedAt":%s000,"entrypoint":"%s","kind":"interactive","version":"2.1.311"}\n' \
    "$p" "$p" "$1" "$st" "$2" $((n - $3)) $((n - $3)) $((n - ${7:-0})) "${5:-cli}" > "$CLAUDE_CONFIG_DIR/sessions/$p.json"
  if [ "${4:--}" != - ]; then
    mkdir -p "$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$1" | sed 's#[^A-Za-z0-9]#-#g')"
    printf '{"type":"assistant","message":{"model":"%s","role":"assistant","content":[{"type":"tool_use","input":{"model":"haiku"}}]}}\n' "$4" \
      > "$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$1" | sed 's#[^A-Za-z0-9]#-#g')/s$p.jsonl"
  fi
  echo "$p"
}
reset() { # no session records, no pending spawns, no running workers in either repo
  rm -f "$CLAUDE_CONFIG_DIR"/sessions/*.json; rm -rf "$JARVIS_HOME/spawning"
  for r in A B; do sed -i.bak '/ · term /d' "$tmp/$r/handoffs/OPEN.md" && rm -f "$tmp/$r/handoffs/OPEN.md.bak"; done
}
reading() { # $1 5h %, $2 resets in (s), $3 age (s): the machine-wide reading
  local n; n=$(date +%s)
  printf '{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":10,"resets_at":%s},"ts":%s}\n' \
    "$1" $((n + $2)) $((n + 86400)) $((n - $3)) > "$JARVIS_HOME/usage.json"
}
green() { rm -f "$JARVIS_HOME/usage.hist"; reading 10 7200 0; }

mkrepo A; mkrepo B
for r in A B; do mk $r son claude sonnet; mk $r opus claude claude-opus-5-5; mk $r cx codex gpt-5.6-sol; mk $r fab claude fable; done
mkdir -p "$tmp/A/sub"

echo "machine-wide cap"
green; reset
for i in 1 2 3 4; do sess "$tmp/o$i" busy 5 claude-sonnet-5-5 >/dev/null; done
out=$(spawn A son 2>&1); rc=$?
[ $rc = 1 ] && printf '%s' "$out" | grep -q 'Claude cap reached: machine-wide, 5 of 4'; check "4 active sessions in other projects → refused" $?
printf '%s' "$out" | grep -q "pid [0-9]* · $tmp/o1 · sonnet · busy" && printf '%s' "$out" | grep -q 'Options: queue it under To-do' \
  && printf '%s' "$out" | grep -q 'close one of your own idle sessions'; check "…naming the sessions (pid, project, model) and the options" $?
[ ! -d "$JARVIS_HOME/spawning" ] || [ -z "$(ls "$JARVIS_HOME/spawning")" ]; check "…and leaves no pending entry" $?
out=$(spawn A cx 2>&1); check "a Codex worker isn't held by the Claude caps" $?
reset
for i in 1 2; do sess "$tmp/o$i" busy 5 claude-sonnet-5-5 >/dev/null; done
spawn A son >/dev/null 2>&1; check "2 elsewhere + Jarvis here → spawned (4th slot)" $?

echo "what counts"
reset
for i in 1 2 3 4 5; do sess "$tmp/o$i" idle 10800 claude-sonnet-5-5 >/dev/null; done
spawn A son >/dev/null 2>&1; check "sessions idle for hours don't count" $?
reset
for i in 1 2 3 4 5; do sess "$tmp/o$i" idle 10800 claude-sonnet-5-5 >/dev/null; done
for i in 6 7 8; do sess "$tmp/o$i" busy 10800 claude-sonnet-5-5 >/dev/null; done
spawn A son >/dev/null 2>&1; [ $? = 1 ]; check "a busy one does, however long ago it was updated (3 busy + Jarvis)" $?
reset
for i in 1 2 3; do sess "$tmp/o$i" idle 120 claude-sonnet-5-5 >/dev/null; done
spawn A son >/dev/null 2>&1; [ $? = 1 ]; check "an idle one updated 2 min ago counts (recent)" $?
reset
true & dead=$!; wait "$dead"
printf '{"pid":%s,"sessionId":"sdead","cwd":"%s/o1","procStart":"Thu Jan  1 00:00:00 2026","status":"busy","updatedAt":%s000,"entrypoint":"cli"}\n' \
  "$dead" "$tmp" "$(date +%s)" > "$CLAUDE_CONFIG_DIR/sessions/$dead.json"
reused=$(sess "$tmp/o2" busy 5 claude-sonnet-5-5 cli "Thu Jan  1 00:00:00 2026")
for i in 3 4; do sess "$tmp/o$i" busy 5 claude-sonnet-5-5 >/dev/null; done
out=$(J B sessions)
! printf '%s' "$out" | grep -q "^  $dead " && ! printf '%s' "$out" | grep -q "^  $reused "; check "a dead PID and a reused one (procStart differs) aren't listed" $?
spawn A son >/dev/null 2>&1; check "…and don't count (2 real + Jarvis → spawned)" $?
reset
for i in 1 2 3 4; do sess "$tmp/o$i" busy 5 claude-sonnet-5-5 sdk-py >/dev/null; done
sess "$tmp/o5" busy 5 claude-sonnet-5-5 sdk-ts >/dev/null
spawn A son >/dev/null 2>&1; check "sdk-* sessions (hooks, headless) are ignored" $?

echo "per checkout and Opus"
reset
sess "$tmp/A" busy 5 claude-sonnet-5-5 >/dev/null; sess "$tmp/A" busy 5 claude-sonnet-5-5 >/dev/null
sess "$tmp/A/sub" busy 5 claude-sonnet-5-5 >/dev/null
out=$(spawn A son 2>&1); [ $? = 1 ] && printf '%s' "$out" | grep -q 'Claude cap reached: this checkout, 3 of 3'; check "3 active sessions in this checkout (one in a subfolder) → refused (per checkout)" $?
out=$(spawn B son 2>&1); [ $? = 1 ] && printf '%s' "$out" | grep -q 'machine-wide, 4 of 4'; check "…and the other repo counts them machine-wide (3 + its Jarvis = 4 → refused)" $?
reset
sess "$tmp/o1" busy 5 claude-opus-5-5 >/dev/null; unk=$(sess "$tmp/o2" busy 5 -)
out=$(spawn A opus 2>&1); [ $? = 1 ] && printf '%s' "$out" | grep -q 'Claude cap reached: Opus, 2 of 2'; check "Opus 2: one opus + one whose model can't be told → refused" $?
printf '%s' "$out" | grep -q "pid $unk · .* · unknown · busy" && printf '%s' "$out" | grep -q 'model: sonnet'; check "…the unknown one named, and sonnet offered" $?
spawn A son >/dev/null 2>&1; check "…a Sonnet worker still spawns" $?
reset
sess "$tmp/o1" busy 5 '<synthetic>' >/dev/null
J B sessions | grep -q ' busy    unknown '; check "a transcript whose last model is <synthetic> reads unknown" $?

echo "race and pending spawns"
reset
for i in 1 2; do sess "$tmp/o$i" busy 5 claude-sonnet-5-5 >/dev/null; done
(spawn A son > "$tmp/ra" 2>&1; echo $? > "$tmp/ra.rc") & pa=$!
(spawn B son > "$tmp/rb" 2>&1; echo $? > "$tmp/rb.rc") & pb=$!
wait "$pa" "$pb"
[ "$(cat "$tmp/ra.rc")$(cat "$tmp/rb.rc")" = 01 ] || [ "$(cat "$tmp/ra.rc")$(cat "$tmp/rb.rc")" = 10 ]; check "two repos racing for the last slot: exactly one spawns" $?
cat "$tmp/ra" "$tmp/rb" | grep -q 'pending spawn son\.'; check "…the other is refused by the winner's pending spawn" $?
reset
for i in 1 2; do sess "$tmp/o$i" busy 5 claude-sonnet-5-5 >/dev/null; done
spawn A son >/dev/null 2>&1
J B sessions | grep -q "^  -       pending sonnet  $tmp/A  son\."; check "a spawn counts as pending, machine-wide" $?
spawn B son >/dev/null 2>&1; [ $? = 1 ]; check "…and holds its slot (B refused)" $?
pf=$(ls "$JARVIS_HOME"/spawning/* | head -n 1)
grep -q '^run: term-' "$pf"; check "…the entry records the run once launched" $?
sed -i.bak "s/^epoch: .*/epoch: $(( $(date +%s) - 200 ))/" "$pf" && rm -f "$pf.bak"
sed -i.bak '/ · term /d' "$tmp/A/handoffs/OPEN.md" && rm -f "$tmp/A/handoffs/OPEN.md.bak"
! J B sessions | grep -q pending && spawn B son >/dev/null 2>&1; check "…until 180 s pass" $?
reset
for i in 1 2; do sess "$tmp/o$i" busy 5 claude-sonnet-5-5 >/dev/null; done
spawn A son >/dev/null 2>&1
sess "$tmp/A" busy 1 claude-sonnet-5-5 >/dev/null
out=$(J B sessions); ! printf '%s' "$out" | grep -q pending && [ "$(printf '%s\n' "$out" | grep -c "  $tmp/A  ")" = 1 ]; check "…or until the new session's record appears (counted once)" $?
reset
spawn A son >/dev/null 2>&1
run=$(sed -n 's/^run: //p' "$JARVIS_HOME"/spawning/*)
sed -i.bak 's/^state: running/state: merged/' "$tmp/A/handoffs/.jarvis/runs/$run" && rm -f "$tmp/A/handoffs/.jarvis/runs/$run.bak"
! J B sessions | grep -q pending; check "…or until its run has ended" $?
reset
FAKE_FAIL=1 spawn A son >/dev/null 2>&1; [ $? = 1 ] && [ -z "$(ls "$JARVIS_HOME/spawning" 2>/dev/null)" ]; check "a launch that fails gives its slot back" $?

echo "Jarvis's own sessions"
reset
jp=$(sess "$tmp/A" idle 10800 claude-opus-5-5)
mkdir -p "$tmp/A/handoffs/.jarvis/sessions" && echo "s$jp" > "$tmp/A/handoffs/.jarvis/sessions/jarvis-t"
spawn A son >/dev/null 2>&1
wt=$(sed -n 's/.*terminal: //p' "$tmp/A/handoffs/briefs/son.md")
wp=$(sess "$tmp/A" idle 10800 -); echo "s$wp" > "$tmp/A/handoffs/.jarvis/sessions/$wt"
out=$(J A sessions)
printf '%s' "$out" | grep -q "^  $jp  *jarvis  opus " && printf '%s' "$out" | grep -q "^  $wp  *jarvis  sonnet "; check "Jarvis and its running worker count while idle, the worker on its registry model" $?
! J B sessions | grep -q "^  $jp "; check "…but another repo's idle Jarvis doesn't count there" $?

echo "usage band"
reset; rm -f "$JARVIS_HOME/usage.json" "$JARVIS_HOME/usage.hist"
J A band | grep -q '^amber unknown band, treated as amber: no statusline reading'; check "no reading → amber, saying why" $?
reading 10 7200 2400
J A band | grep -q '^amber stale reading (40 min old), treated as amber'; check "a 40-min-old reading, window not reset → amber (stale)" $?
reading 10 -600 3600
J A band | grep -q '^green the 5-hour window has reset'; check "window reset since a 1 h old reading → green" $?
reading 10 -600 21600
J A band | grep -q '^amber unknown band'; check "…but a 6 h old one → amber (unknown)" $?
printf '{"five_hour":{"used_percentage":10,"resets_at":%s}}\n' $(( $(date +%s) + 3600 )) > "$JARVIS_HOME/usage.json"
J A band | grep -q '^amber unknown band'; check "a reading without a time → amber" $?
rm -f "$JARVIS_HOME/usage.json"; mkdir -p "$tmp/A/handoffs/.jarvis"
printf '{"five_hour":{"used_percentage":10,"resets_at":%s},"ts":%s}\n' $(( $(date +%s) + 7200 )) "$(date +%s)" > "$tmp/A/handoffs/.jarvis/usage.json"
J A band | grep -q '^green'; check "no machine-wide reading → the repo's own" $?
rm -f "$tmp/A/handoffs/.jarvis/usage.json"
n=$(date +%s)
echo "{\"model\":{},\"rate_limits\":{\"five_hour\":{\"used_percentage\":20,\"resets_at\":$((n + 7200))}}}" | JARVIS_STATUSLINE_CMD='cat >/dev/null' J A statusline
echo "{\"model\":{},\"rate_limits\":{\"five_hour\":{\"used_percentage\":21,\"resets_at\":$((n + 7200))}}}" | JARVIS_STATUSLINE_CMD='cat >/dev/null' J B statusline
jq -e '.five_hour.used_percentage == 21' "$JARVIS_HOME/usage.json" >/dev/null && [ -s "$tmp/A/handoffs/.jarvis/usage.json" ]; check "statusline writes the machine-wide reading (and the repo's copy)" $?
[ "$(wc -l < "$JARVIS_HOME/usage.hist" | tr -d ' ')" = 1 ] && grep -q "^[0-9]* 20 - $((n + 7200))\$" "$JARVIS_HOME/usage.hist"; check "…and one history line a minute at most" $?
awk -v n="$n" 'BEGIN { for (i = 600; i > 0; i--) print n - i * 70, 5, 1, n + 7200 }' > "$JARVIS_HOME/usage.hist"
echo "{\"model\":{},\"rate_limits\":{\"five_hour\":{\"used_percentage\":21,\"resets_at\":$((n + 7200))}}}" | JARVIS_STATUSLINE_CMD='cat >/dev/null' J A statusline
[ "$(wc -l < "$JARVIS_HOME/usage.hist" | tr -d ' ')" = 500 ] && tail -n 1 "$JARVIS_HOME/usage.hist" | grep -q ' 21 '; check "…keeping the last 500" $?

echo "burn rate"
hist() { n=$(date +%s); printf '%s %s 10 %s\n' "$@" > "$JARVIS_HOME/usage.hist"; }
n=$(date +%s); reading 20 10800 0; hist $((n - 1500)) 20 $((n + 10800)) $((n - 600)) 20 $((n + 10800))
J A band | grep -q '^green .*burning 0 pts/20 min'; check "a flat history → green" $?
reading 38 10800 0; hist $((n - 1260)) 20 $((n + 10800))
J A band | grep -q '^amber .*burning 17 pts/20 min'; check "a burst (18 points in 21 min) → amber" $?
reading 60 10800 0; hist $((n - 1200)) 30 $((n + 10800))
J A band | grep -q '^red .*burning 30 pts/20 min (100% in 26 min)'; check "a bigger one at 60% → red (100% within 30 min)" $?
reading 30 10800 0; hist $((n - 1200)) 22 $((n + 10800))
J A band | grep -q '^amber .*burning 8 pts/20 min (100% in 175 min)'; check "a slow burn that empties the window before it resets → amber" $?
reading 60 10800 0; hist $((n - 1200)) 30 $((n - 7200))
J A band | grep -q '^amber' && ! J A band | grep -q burning; check "history from an earlier window is ignored" $?

echo "band-lowered caps and --force"
rm -f "$JARVIS_HOME/usage.hist"; reset; reading 55 7200 0
for i in 1 2; do sess "$tmp/o$i" busy 5 claude-sonnet-5-5 >/dev/null; done
out=$(spawn A son 2>&1); [ $? = 1 ] && printf '%s' "$out" | grep -q 'machine-wide, 3 of 3 (band amber: caps lowered)'; check "amber: machine-wide cap 3" $?
J A status | grep -q '^claude sessions: 3 of 3 machine-wide (1 of 3 here · opus 0 of 1) — band amber caps$'; check "status shows the effective caps" $?
reset; sess "$tmp/o1" busy 5 claude-opus-5-5 >/dev/null
out=$(spawn A opus 2>&1); [ $? = 1 ] && printf '%s' "$out" | grep -q 'Opus, 1 of 1'; check "amber: Opus cap 1" $?
reset; reading 80 7200 0; sess "$tmp/o1" busy 5 claude-sonnet-5-5 >/dev/null
out=$(spawn A son 2>&1); [ $? = 1 ] && printf '%s' "$out" | grep -q 'machine-wide, 2 of 2 (band red'; check "red: machine-wide cap 2" $?
out=$(spawn A opus 2>&1); [ $? = 1 ] && printf '%s' "$out" | grep -q 'band is red'; check "red: no new Opus work" $?
green; reset
for i in 1 2 3 4; do sess "$tmp/o$i" busy 5 claude-sonnet-5-5 >/dev/null; done
out=$(spawn A son --force 2>&1) && printf '%s' "$out" | grep -q -- '--force: past the machine-wide Claude cap (5 of 4'; check "--force passes the machine-wide cap" $?
grep -q 'cap-force run=- brief=handoffs/briefs/son.md cap=machine-wide n=5 limit=4 band=green result=passed' "$tmp/A/handoffs/.jarvis/audit.log"; check "…logged in the audit log" $?
out=$(spawn A fab --force 2>&1); [ $? = 1 ] && printf '%s' "$out" | grep -q 'fable'; check "…but never Fable" $?
reset; sess "$tmp/A" busy 5 claude-sonnet-5-5 >/dev/null; sess "$tmp/A" busy 5 claude-sonnet-5-5 >/dev/null; sess "$tmp/A" busy 5 claude-sonnet-5-5 >/dev/null
spawn A son --force >/dev/null 2>&1; check "--force passes the per-checkout cap" $?

echo "sessions"
reset
old=$(sess "$tmp/o1" idle 32400 claude-sonnet-5-5 cli "" 36000)
sess "$tmp/o2" idle 3600 claude-sonnet-5-5 cli "" 7200 >/dev/null
out=$(J A sessions)
printf '%s' "$out" | grep -q "^  pid $old · $tmp/o1 · open 10h00m · last active 9h00m ago" \
  && [ "$(printf '%s\n' "$out" | grep -c '^  pid ')" = 1 ] && printf '%s' "$out" | grep -q 'close the ones you.re done with yourself'; check "jarvis sessions: idle sessions open more than 8 h, as a hint to close them" $?

echo "nothing signalled"
alive=0; total=0
for p in $(cat "$procs"); do total=$((total + 1)); kill -0 "$p" 2>/dev/null && [ "$(ps -o stat= -p "$p" | cut -c1)" != Z ] && alive=$((alive + 1)); done
[ "$alive" = "$total" ] && [ "$total" -gt 20 ]; check "every fake session process is still alive ($alive of $total)" $?

echo; [ "$fails" = 0 ] && echo "captest: all passed" || { echo "captest: $fails failed"; exit 1; }
