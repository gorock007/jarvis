#!/usr/bin/env bash
# Offline test of worker budgets in bin/jarvis: working minutes (watcher ticks whose
# screen changed), the API-equivalent estimate, context and failed test runs read
# incrementally from synthetic transcripts by cc_usage_audit.py --budget, the per-brief
# budget: line, the ask (once), the pause (Escape after the grace period, only while the
# worker still works with no handoff), `jarvis budget`, the respawn gate (--after,
# --force), the status line and the usage waste signal. A throwaway repo with the
# template's handoffs/, a fake superset that records what it's sent, and a throwaway
# HOME, JARVIS_HOME and CLAUDE_CONFIG_DIR. Nothing launches a model; nothing is closed or
# signalled, which the test checks at the end.
#
#   eval/budgettest.sh
# `[ … ]; check "…" $?` reads the test's own status.
# shellcheck disable=SC2319,SC2154,SC2016  # $p is the trap's own loop variable; the $s in single quotes are regex
set -u
here=$(cd "$(dirname "$0")" && pwd)
tpl="$here/../plugins/jarvis/skills/setup/templates"
tmp=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/jarvis-budgettest.XXXXXX")" && pwd -P)
procs="$tmp/procs"
trap 'for p in $(cat "$procs" 2>/dev/null); do kill "$p" 2>/dev/null; done; rm -rf "$tmp"' EXIT
fails=0
ok() { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; fails=$((fails + 1)); }
check() { if [ "$2" = 0 ]; then ok "$1"; else bad "$1"; fi; }
for c in jq python3; do
  command -v $c >/dev/null 2>&1 || { echo "budgettest: skipped ($c not installed)"; echo "budgettest: all passed"; exit 0; }
done

export HOME="$tmp/home" JARVIS_HOME="$tmp/jh" CLAUDE_CONFIG_DIR="$tmp/home/.claude" CODEX_HOME="$tmp/codex" SUPERSET_HOME_DIR="$tmp/sshome"
export GIT_AUTHOR_NAME=budgettest GIT_AUTHOR_EMAIL=budgettest@example.invalid GIT_COMMITTER_NAME=budgettest GIT_COMMITTER_EMAIL=budgettest@example.invalid
export FAKE_LOG="$tmp/fake.log" SCREENS="$tmp/screens" SUPERSET_WORKSPACE_ID=ws SUPERSET_TERMINAL_ID=jarvis-t PATH="$tmp/fake:$PATH"
unset TYPESAFE_API_KEY TMUX TMUX_PANE ULTRON_SESSION_ID JARVIS_HOST JARVIS_LOCK_DIR ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL \
  ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_SMALL_FAST_MODEL CLAUDE_CODE_SUBAGENT_MODEL
mkdir -p "$tmp/fake" "$CLAUDE_CONFIG_DIR/sessions" "$JARVIS_HOME" "$SCREENS" "$tmp/sshome/state"
# a terminal's screen is $SCREENS/<terminal> (empty: "Working…"); send and close are only logged
cat > "$tmp/fake/superset" <<'EOT'
#!/bin/bash
echo "superset $*" >> "$FAKE_LOG"
case "$1 $2" in
  "agents create") n=$(( $(cat "$FAKE_LOG.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_LOG.n"
    printf '{"kind":"terminal","sessionId":"term-%s"}\n' "$n" ;;
  "terminals read") jq -n --arg t "$(cat "$SCREENS/$6" 2>/dev/null || echo 'Working… esc to interrupt')" '{text: $t}' ;;
  "terminals list") printf '{"sessions":[]}\n' ;;
esac
EOT
chmod +x "$tmp/fake/superset"

repo="$tmp/repo"
mkdir -p "$repo" && cd "$repo" || exit 1
git init -q && cp -R "$tpl/handoffs" . \
  && sed -e 's/{{MAX_CLAUDE}}/50/' -e 's/{{AMBER}}/50/' -e 's/{{RED}}/75/' "$tpl/handoffs/jarvis.conf" > handoffs/jarvis.conf \
  && printf 'JARVIS_MAX_CLAUDE_GLOBAL=50 JARVIS_MAX_OPUS=50 JARVIS_AMBER_GLOBAL=50 JARVIS_AMBER_OPUS=50\n' >> handoffs/jarvis.conf \
  && git add -A && git commit -qm init && handoffs/bin/jarvis start >/dev/null 2>&1
now=$(date +%s)
echo "{\"five_hour\":{\"used_percentage\":10,\"resets_at\":$((now + 4 * 3600))},\"ts\":$now}" > "$JARVIS_HOME/usage.json"
J() { handoffs/bin/jarvis "$@"; }
proj=$(pwd -P | sed 's#[^A-Za-z0-9]#-#g')
tdir="$CLAUDE_CONFIG_DIR/projects/$proj"; mkdir -p "$tdir"
mk() { # $1 brief name, $2 worker, $3 model, $4 budget line or ""
  { printf '# %s\nworker: %s\nmodel: %s\neffort: high\n' "$1" "$2" "$3"
    [ -n "${4:-}" ] && printf 'budget: %s\n' "$4"
    printf '\n## Goal\nx\n'; } > "handoffs/briefs/$1.md"
}
tid() { sed -n 's/.*terminal: \([^ ]*\).*/\1/p' "handoffs/briefs/$1.md" | head -n 1; }
reg() { sed -n "s/^$2: //p" "handoffs/.jarvis/runs/$1" | head -n 1; }   # $1 run, $2 key
setkv() { # $1 file, $2 key, $3 value: as run_set writes it
  awk -v k="$2" -v v="$3" 'index($0, k ": ") == 1 {print k ": " v; d = 1; next} {print} END {if (!d) print k ": " v}' "$1" > "$1.n" && mv "$1.n" "$1"
}
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z; }
# rec <file> <requestId> <input> <output> <cache read> <cache write 1h> [sidechain]: one assistant record, opus-5-5
rec() {
  printf '{"type":"assistant","timestamp":"%s","requestId":"%s","isSidechain":%s,"message":{"model":"claude-opus-5-5","usage":{"input_tokens":%s,"output_tokens":%s,"cache_read_input_tokens":%s,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":%s}}}}\n' \
    "$(iso "$(date +%s)")" "$2" "${7:-false}" "$3" "$4" "$5" "$6" >> "$1"
}
bashcall() { # <file> <tool id> <command> <failed 0|1>: a Bash tool call and its result
  printf '{"type":"assistant","timestamp":"%s","requestId":"rb-%s","message":{"model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":1},"content":[{"type":"tool_use","id":"%s","name":"Bash","input":{"command":"%s"}}]}}\n' \
    "$(iso "$(date +%s)")" "$2" "$2" "$3" >> "$1"
  if [ "$4" = 1 ]; then
    printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"%s","is_error":true,"content":"Exit code 1"}]}}\n' "$2" >> "$1"
  else
    printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"%s","content":"all passed"}]}}\n' "$2" >> "$1"
  fi
}
worker() { # $1 brief name, $2 run, $3 session id: the prompt hook's record and a transcript opening with the spawn prompt
  mkdir -p handoffs/.jarvis/sessions && echo "$3" >> "handoffs/.jarvis/sessions/$2"
  printf '{"type":"user","message":{"role":"user","content":"You are a Jarvis worker. Read AGENTS.md, then do the task in handoffs/briefs/%s.md. Put every question in one first handoff."}}\n' "$1" > "$tdir/$3.jsonl"
}
tick() { cat "$FAKE_LOG" >> "$FAKE_LOG.all" 2>/dev/null; : > "$FAKE_LOG"; J watch --once >/dev/null 2>&1; }
asks() { grep -c "terminals send .*--terminal $1 --text \[jarvis\] Budget reached" "$FAKE_LOG"; }   # in the last tick
asks_all() { cat "$FAKE_LOG.all" "$FAKE_LOG" | grep -c "terminals send .*--terminal $1 --text \[jarvis\] Budget reached"; }
budfile() { echo "handoffs/.jarvis/budget/$1"; }
# a fake agent process for every worker, to show at the end that nothing was signalled
sleep 900 >/dev/null 2>&1 & echo $! >> "$procs"; agentpid=$!; disown "$agentpid" 2>/dev/null

echo "incremental pricing (cc_usage_audit.py --budget)"
audit="$tpl/handoffs/bin/cc_usage_audit.py"
f="$tmp/inc.jsonl"; : > "$f"
rec "$f" r1 100 1000 50000 2000; rec "$f" r2 10 5000 120000 0
o1=$(python3 "$audit" --budget "$tmp/inc.state" "$f")
off1=$(jq '.files[] .off' "$tmp/inc.state")
[ "$off1" = "$(wc -c < "$f" | tr -d ' ')" ]; check "the offset is the file's size after a read of whole lines" $?
# a streamed request split across two reads, and half a line not yet written
rec "$f" r3 5 100 130000 0
printf '%s' '{"type":"assistant","timestamp":"2026-10-30T10:00:00.000Z","requestId":"r4","message":{"model":"claude-opus-5-5","usage":' >> "$f"
python3 "$audit" --budget "$tmp/inc.state" "$f" >/dev/null
off2=$(jq '.files[] .off' "$tmp/inc.state")
[ "$off2" -gt "$off1" ] && [ "$off2" -lt "$(wc -c < "$f" | tr -d ' ')" ]; check "the offset advances, and stops before a half-written line" $?
printf '%s\n' '{"input_tokens":1,"output_tokens":2000,"cache_read_input_tokens":140000}}}' >> "$f"
rec "$f" r3 5 900 130000 0      # r3's later record replaces its first (last one wins)
o3=$(python3 "$audit" --budget "$tmp/inc.state" "$f")
full=$(python3 "$audit" --budget "$tmp/full.state" "$f")
[ "$o3" = "$full" ]; check "appended reads add up to the same total as one full read ($o3)" $?
[ "$o1" != "$o3" ] && [ "$(echo "$o3" | cut -d' ' -f2)" = 130005 ]; check "context is the last main-thread turn's" $?
ref=$(python3 -B -c '
import sys, datetime as dt; sys.path.insert(0, sys.argv[2]); import cc_usage_audit as a
_, rs = a.load_file(sys.argv[1], dt.datetime(2000, 1, 1, tzinfo=dt.timezone.utc), a.PRICES)
print("%.4f" % sum(r["usd"] for r in rs))' "$f" "$tpl/handoffs/bin")
[ "$ref" = "$(echo "$o3" | cut -d' ' -f1)" ]; check "the estimate matches the audit's own pricing (\$$ref)" $?
big="$tmp/big.jsonl"
python3 -c '
import json, sys
with open(sys.argv[1], "w") as f:
    for i in range(3000):
        f.write(json.dumps({"type": "assistant", "timestamp": "2026-10-30T10:00:00.000Z", "requestId": "b%d" % i,
            "message": {"model": "claude-opus-5-5", "content": [{"type": "text", "text": "x" * 2000}],
                        "usage": {"input_tokens": 10, "output_tokens": 300, "cache_read_input_tokens": 380000}}}) + "\n")' "$big"
s=$(python3 -c 'import time; print(time.time())')
python3 "$audit" --budget "$tmp/big.state" "$big" >/dev/null
rec "$big" bz 10 300 400000 0
python3 "$audit" --budget "$tmp/big.state" "$big" >/dev/null
e=$(python3 -c 'import time; print(time.time())')
awk -v s="$s" -v e="$e" 'BEGIN { exit !(e - s < 1.5) }'; check "a 3000-turn, 400k-context transcript: first read and one append in under 1.5 s together" $?

echo "working minutes"
mk m1 claude claude-opus-5-5 ""
J spawn handoffs/briefs/m1.md >/dev/null 2>&1; m1=$(tid m1)
worker m1 "$m1" sm1
echo "screen 1" > "$SCREENS/$m1"; tick
setkv "$(budfile "$m1")" seen $(( $(date +%s) - 50 ))
echo "screen 2" > "$SCREENS/$m1"; tick
w=$(sed -n 's/^work: //p' "$(budfile "$m1")")
[ "$w" -ge 50 ] && [ "$w" -le 52 ]; check "a tick whose screen changed adds the time since the last tick ($w s)" $?
setkv "$(budfile "$m1")" seen $(( $(date +%s) - 50 )); tick
[ "$(sed -n 's/^work: //p' "$(budfile "$m1")")" = "$w" ]; check "a tick whose screen didn't change adds nothing (waiting for answers is free)" $?
setkv "$(budfile "$m1")" seen $(( $(date +%s) - 3000 )); echo "screen 3" > "$SCREENS/$m1"; tick
w2=$(sed -n 's/^work: //p' "$(budfile "$m1")")
[ $((w2 - w)) -le 120 ] && [ $((w2 - w)) -ge 119 ]; check "…at most two ticks' worth after a gap (the watcher wasn't running)" $?
[ "$(asks "$m1")" = 0 ]; check "under budget: no ask" $?

echo "the minutes budget, the ask, once"
setkv "$(budfile "$m1")" work 5400; echo "screen 4" > "$SCREENS/$m1"; tick
grep -q "terminals send --workspace ws --terminal $m1 --text \[jarvis\] Budget reached (min: 90m/90m)\. Stop the current approach now\. Write your handoff with status: partial — what's done, what's left, what you tried that failed and why — then stop\." "$FAKE_LOG"
check "90 working minutes: the worker is asked for a partial handoff, in the brief's words" $?
grep -q "terminal jarvis-t --text \[jarvis watch\].*worker ${m1:0:8} hit its min budget — asked for a partial handoff" "$FAKE_LOG"; check "…and Jarvis is woken" $?
reg "$m1" budget | grep -Eq '^min 90m/90m [0-9]+$' && reg "$m1" budget_asked | grep -Eq '^[0-9]+$'; check "the run registry records budget: and budget_asked:" $?
echo "screen 5" > "$SCREENS/$m1"; tick; echo "screen 5b" > "$SCREENS/$m1"; tick
[ "$(asks_all "$m1")" = 1 ]; check "the ask is sent once, not every tick" $?

echo "the pause"
echo "screen 6" > "$SCREENS/$m1"; tick
! grep -q "terminal $m1 --keys" "$FAKE_LOG"; check "inside the grace period: no Escape" $?
setkv "handoffs/.jarvis/runs/$m1" budget_asked $(( $(date +%s) - 11 * 60 ))
echo "screen 7" > "$SCREENS/$m1"; tick
grep -q "terminals send --workspace ws --terminal $m1 --keys esc" "$FAKE_LOG"; check "past the grace period, still working, no handoff: Escape" $?
grep -q "worker ${m1:0:8} paused over budget, no handoff — read its terminal" "$FAKE_LOG" && reg "$m1" paused | grep -Eq '^[0-9]+$'
check "…paused: recorded, and Jarvis is woken" $?
echo "screen 8" > "$SCREENS/$m1"; tick
! grep -q "terminal $m1 --keys" "$FAKE_LOG"; check "the pause happens once" $?

mk m2 claude claude-opus-5-5 "min=1"
J spawn handoffs/briefs/m2.md >/dev/null 2>&1; m2=$(tid m2); worker m2 "$m2" sm2
echo a > "$SCREENS/$m2"; tick; setkv "$(budfile "$m2")" work 61; echo b > "$SCREENS/$m2"; tick
[ "$(asks "$m2")" = 1 ] && grep -q "min: 1m/1m" "$FAKE_LOG"; check "a brief's budget: line overrides the default (min=1)" $?
setkv "handoffs/.jarvis/runs/$m2" budget_asked $(( $(date +%s) - 11 * 60 )); setkv "$(budfile "$m2")" changed $(( $(date +%s) - 600 ))
tick; tick   # the screen stays "b": not working
! cat "$FAKE_LOG.all" "$FAKE_LOG" | grep -q "terminal $m2 --keys"; check "a screen that stopped changing isn't paused (the stall alert covers it)" $?

mk m3 claude claude-opus-5-5 "min=1"
J spawn handoffs/briefs/m3.md >/dev/null 2>&1; m3=$(tid m3); worker m3 "$m3" sm3
echo a > "$SCREENS/$m3"; tick; setkv "$(budfile "$m3")" work 61; echo b > "$SCREENS/$m3"; tick
setkv "handoffs/.jarvis/runs/$m3" budget_asked $(( $(date +%s) - 11 * 60 ))
printf '# m3\nstatus: partial\nbrief: handoffs/briefs/m3.md\n## Files\n- x — created\n' > handoffs/hm3.md
echo c > "$SCREENS/$m3"; tick
! grep -q "terminal $m3 --keys" "$FAKE_LOG"; check "a handoff that landed in the grace period: no Escape" $?

echo "estimate, context and failed tests"
mk u1 claude claude-opus-5-5 "usd=2"
J spawn handoffs/briefs/u1.md >/dev/null 2>&1; u1=$(tid u1); worker u1 "$u1" su1
rec "$tdir/su1.jsonl" a1 0 50000 0 0          # $1.00
tick; [ "$(asks "$u1")" = 0 ]; check "\$1.0 of \$2: no ask" $?
mkdir -p "$tdir/su1/subagents"; rec "$tdir/su1/subagents/agent-x.jsonl" s1 0 60000 0 0 true   # $1.20 in a subagent
tick; [ "$(asks "$u1")" = 0 ]; check "the transcript is read at most every JARVIS_BUDGET_SEC" $?
setkv "$(budfile "$u1")" measured 0; tick
grep -q "terminal $u1 --text \[jarvis\] Budget reached (usd: \$2.2/\$2)" "$FAKE_LOG"; check "\$2.2 with the subagent's share: the usd budget trips" $?
jq -e '[.files | keys[]] | length == 2' "$(budfile "$u1").json" >/dev/null; check "…each transcript has its own offset in budget/<run>.json" $?

mk c1 claude claude-opus-5-5 "ctx=100k"
J spawn handoffs/briefs/c1.md >/dev/null 2>&1; c1=$(tid c1); worker c1 "$c1" sc1
rec "$tdir/sc1.jsonl" c1a 10 10 90000 0; tick
[ "$(asks "$c1")" = 0 ]; check "90k of 100k context: no ask" $?
rec "$tdir/sc1.jsonl" c1b 10 10 125000 0; setkv "$(budfile "$c1")" measured 0; tick
grep -q "terminal $c1 --text \[jarvis\] Budget reached (ctx: 125k/100k)" "$FAKE_LOG"; check "125k: the ctx budget trips (ctx=100k)" $?

mk t1 claude claude-opus-5-5 "tests=2"
J spawn handoffs/briefs/t1.md >/dev/null 2>&1; t1=$(tid t1); worker t1 "$t1" st1
bashcall "$tdir/st1.jsonl" tu1 "pytest -q" 1; bashcall "$tdir/st1.jsonl" tu2 "ls" 1; bashcall "$tdir/st1.jsonl" tu3 "eval/selftest.sh" 0
tick; [ "$(asks "$t1")" = 0 ]; check "one failed test run (a failed ls doesn't count): no ask" $?
bashcall "$tdir/st1.jsonl" tu4 "npm test" 1; setkv "$(budfile "$t1")" measured 0; tick
grep -q "terminal $t1 --text \[jarvis\] Budget reached (tests: 2/2)" "$FAKE_LOG"; check "two failed test runs: the tests budget trips (tests=2)" $?

mk d1 claude claude-opus-5-5 "usd=1"
J spawn handoffs/briefs/d1.md >/dev/null 2>&1; d1=$(tid d1); worker d1 "$d1" sd1
rec "$tdir/sd1.jsonl" d1a 0 100000 0 0
printf '# d1\nstatus: done\nbrief: handoffs/briefs/d1.md\n## Files\n- y — created\n' > handoffs/hd1.md
tick; [ "$(asks "$d1")" = 0 ]; check "a worker that already handed off (done) isn't asked" $?

mk s1 claude claude-opus-5-5 "usd=1"
J spawn handoffs/briefs/s1.md >/dev/null 2>&1; s1=$(tid s1)
sp=$(reg "$s1" spawned)
printf '{"type":"user","message":{"role":"user","content":"You are a Jarvis worker. Read AGENTS.md, then do the task in handoffs/briefs/s1.md. Put every question in one first handoff."}}\n' > "$tdir/ss1.jsonl"
rec "$tdir/ss1.jsonl" s1a 0 100000 0 0
printf '{"pid":1,"sessionId":"ss1","cwd":"%s","startedAt":%s000}\n' "$(pwd -P)" "$((sp + 1))" > "$CLAUDE_CONFIG_DIR/sessions/1.json"
tick; grep -q "terminal $s1 --text \[jarvis\] Budget reached (usd: \$2.0/\$1)" "$FAKE_LOG"; check "no prompt-hook record: the session is found from Claude Code's session records" $?
rm -f "$CLAUDE_CONFIG_DIR/sessions/1.json"

echo "codex: minutes only"
mk x1 codex gpt-5.6-sol "usd=0 ctx=1 tests=0"
J spawn handoffs/briefs/x1.md >/dev/null 2>&1; x1=$(tid x1)
echo a > "$SCREENS/$x1"; tick
[ "$(asks "$x1")" = 0 ]; check "a Codex worker has no estimate, context or tests budget (all set to 0 here)" $?
out=$(J status 2>/dev/null)
printf '%s\n' "$out" | grep -A1 "${x1:0:8}" | grep -Eq 'budget: 0m/90m working \([0-9]+m since spawn\)$'; check "status: a Codex worker shows minutes only" $?
setkv "$(budfile "$x1")" work 5400; echo b > "$SCREENS/$x1"; tick
[ "$(asks "$x1")" = 1 ]; check "…and its minutes budget trips" $?

echo "status"
out=$(J status 2>/dev/null)
printf '%s\n' "$out" | grep -A1 "${c1:0:8}" | grep -Eq 'budget: 0m/90m working \([0-9]+m since spawn\) · \$0\.0/\$15 · ctx 125k/100k \(over\) · tests 0/6 · asked for a partial handoff [0-9]{2}:[0-9]{2}$'
check "status: one budget line per worker, over-budget items marked" $?
printf '%s\n' "$out" | grep -A1 "${m1:0:8}" | grep -q '90m/90m working .*(over).* · paused [0-9][0-9]:[0-9][0-9]$'; check "status: minutes over, asked and paused" $?

echo "jarvis budget (raise a running worker's limits)"
J budget "$c1" ctx=200k usd=20 >/dev/null 2>&1; check "jarvis budget sets a run's limits" $?
[ "$(reg "$c1" limits)" = "ctx=200000 usd=20" ] && [ -z "$(reg "$c1" budget)" ] && [ -z "$(reg "$c1" budget_asked)" ] \
  && reg "$c1" budget_was | grep -q '^ctx 125k/100k'
check "…clears budget:/budget_asked: (re-armed) and keeps the old one as budget_was:" $?
grep -q "budget-raise run=$c1 brief=handoffs/briefs/c1.md limits=ctx=200000,usd=20 result=set" handoffs/.jarvis/audit.log; check "…with an audit line" $?
J budget "$c1" ctx=150k >/dev/null 2>&1; [ "$(reg "$c1" limits)" = "usd=20 ctx=150000" ]; check "…a later call replaces only the keys it names" $?
J budget "$c1" attempts=5 >/dev/null 2>&1; [ $? = 1 ]; check "…and refuses attempts= (per brief)" $?
J budget "$c1" | grep -q '^0m/90m working (.* since spawn) · \$0\.0/\$20 · ctx 125k/150k · tests 0/6$'; check "jarvis budget <terminal> alone prints its budget line" $?
setkv "$(budfile "$c1")" measured 0; tick
[ "$(asks "$c1")" = 0 ]; check "under the raised limit: no ask" $?
rec "$tdir/sc1.jsonl" c1c 10 10 160000 0; setkv "$(budfile "$c1")" measured 0; tick
grep -q "terminal $c1 --text \[jarvis\] Budget reached (ctx: 160k/150k)" "$FAKE_LOG"; check "over it again: asked again (re-armed)" $?

echo "respawn gate"
out=$(J spawn handoffs/briefs/u1.md 2>&1); rc=$?
[ $rc = 1 ] && printf '%s' "$out" | grep -q "can't be respawned yet: a run of it reached its budget: $u1 (usd \$2.2/\$2)" \
  && printf '%s' "$out" | grep -q 'sharpen or split the brief, then respawn with --after'
check "a brief whose run reached its budget is refused, with what to do" $?
printf '# other\nstatus: partial\nbrief: handoffs/briefs/t1.md\n' > handoffs/hx.md
J spawn handoffs/briefs/u1.md --after handoffs/hx.md >/dev/null 2>&1; [ $? = 1 ]; check "--after a handoff for another brief: refused" $?
printf '# u1\nstatus: partial\nbrief: handoffs/briefs/u1.md\n' > handoffs/hu1.md
touch -t 202001010000 handoffs/hu1.md
J spawn handoffs/briefs/u1.md --after handoffs/hu1.md >/dev/null 2>&1; [ $? = 1 ]; check "--after a handoff older than the latest run: refused" $?
touch handoffs/hu1.md
J spawn handoffs/briefs/u1.md --after handoffs/hu1.md >/dev/null 2>&1; check "--after the partial handoff: spawned" $?
mk a1 claude claude-opus-5-5 ""
J spawn handoffs/briefs/a1.md >/dev/null 2>&1 && J spawn handoffs/briefs/a1.md >/dev/null 2>&1; check "two runs of a brief are fine" $?
out=$(J spawn handoffs/briefs/a1.md 2>&1); [ $? = 1 ] && printf '%s' "$out" | grep -q 'it has used its 2 attempts'; check "a third is refused (attempts=2)" $?
n=$(grep -c . handoffs/.jarvis/audit.log)
J spawn handoffs/briefs/a1.md --force >/dev/null 2>&1; check "--force passes the gate" $?
[ "$(grep -c . handoffs/.jarvis/audit.log)" = $((n + 1)) ] && tail -n 1 handoffs/.jarvis/audit.log | grep -q 'budget-force run=- brief=handoffs/briefs/a1.md runs=2 attempts=2 budget=- result=passed'
check "…logged in audit.log" $?
mk a2 claude claude-opus-5-5 "attempts=3"
J spawn handoffs/briefs/a2.md >/dev/null 2>&1; J spawn handoffs/briefs/a2.md >/dev/null 2>&1
J spawn handoffs/briefs/a2.md >/dev/null 2>&1; check "a brief's attempts=3 allows a third run" $?

echo "jarvis usage"
out=$(J usage --days 1 2>/dev/null)
printf '%s\n' "$out" | grep -Eq 'over budget \(this repo\): [0-9]+ runs asked for a partial handoff · 1 paused'; check "usage counts the runs that reached a budget among the waste signals" $?

echo "nothing closed or signalled"
! cat "$FAKE_LOG.all" "$FAKE_LOG" | grep -q 'terminals close'; check "no terminal was closed" $?
kill -0 "$agentpid" 2>/dev/null; check "the fake agent process is still alive" $?
! grep -Eq 'reap|signal|kill|TERM' handoffs/.jarvis/audit.log; check "the audit log records no signal" $?

echo; [ "$fails" = 0 ] && echo "budgettest: all passed" || { echo "budgettest: $fails failed"; exit 1; }
