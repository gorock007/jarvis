#!/usr/bin/env bash
# Offline self-test of jev.sh (fail-open paths, request shape, secret masking)
# and of bin/jarvis (spawn cap and band, merge, the idle guard, the watcher,
# the statusline tap, leftover processes, the tmux host), against a throwaway repo, a fake
# `superset` and real processes of its own, all stopped before it exits.
# No API key, no network, no cost — run it after any change to either script.
#
#   eval/selftest.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
jev="$here/../plugins/jarvis/skills/setup/templates/handoffs/bin/jev.sh"
brief="$here/briefs/$(ls "$here/briefs" | head -n 1)"
term="$here/terminals/$(ls "$here/terminals" | head -n 1)"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/jev-selftest.XXXXXX")
export JEV_LOG_DIR="$tmp/log"
# spawn counts every Claude session on the machine and reads ~/.jarvis: keep the real ones out
export HOME="$tmp/home" JARVIS_HOME="$tmp/jh" CLAUDE_CONFIG_DIR="$tmp/cc" GIT_AUTHOR_NAME=selftest GIT_AUTHOR_EMAIL=selftest@example.invalid GIT_COMMITTER_NAME=selftest GIT_COMMITTER_EMAIL=selftest@example.invalid
fails=0
ok() { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; fails=$((fails + 1)); }
check() { if [ "$2" = 0 ]; then ok "$1"; else bad "$1"; fi; }

echo "fail-open"
out=$(env -u TYPESAFE_API_KEY "$jev" brief "$brief" 2>&1); rc=$?
[ $rc = 0 ] && printf '%s' "$out" | grep -q '^jev: skipped'; check "brief without a key skips, exit 0" $?
out=$(env -u TYPESAFE_API_KEY "$jev" triage --file "$term" 2>&1); rc=$?
[ $rc = 0 ] && [ -n "$out" ]; check "triage without a key falls back to the raw tail, exit 0" $?
start=$(date +%s)
out=$(TYPESAFE_API_KEY=selftest TYPESAFE_API_URL=http://127.0.0.1:9/ "$jev" brief "$brief" 2>&1); rc=$?
[ $rc = 0 ] && printf '%s' "$out" | grep -q '^jev: skipped'; check "brief with the API unreachable skips, exit 0" $?
[ $(( $(date +%s) - start )) -le 20 ]; check "…and gives up within 20s" $?
out=$(env -u TYPESAFE_API_KEY "$jev" outcome "$brief" clean 2>&1); check "outcome needs no key" $?
[ ! -e "$JEV_LOG_DIR/log.jsonl" ] || ! grep -q '"kind":"brief"' "$JEV_LOG_DIR/log.jsonl"; check "skipped calls log no verdict" $?

if command -v jq >/dev/null 2>&1; then
  echo "request shape (--dry-run)"
  p=$(env -u TYPESAFE_API_KEY "$jev" --dry-run brief "$brief" 2>/dev/null)
  printf '%s' "$p" | jq -e '(.questions | length) == 13 and (.state | type) == "string" and .model != null' >/dev/null; check "brief: 13 questions, string state, a model" $?
  printf '%s' "$p" | jq -e '.state | test("(^|\n)(worker|model|effort):") | not' >/dev/null; check "brief: Jarvis's model choice is stripped from the state" $?
  printf '%s' "$p" | jq -e '[.questions[] | .type] | unique - ["noul","score","choice"] == []' >/dev/null; check "brief: only noul/score/choice questions" $?
  p=$(env -u TYPESAFE_API_KEY "$jev" --dry-run triage --file "$term" 2>/dev/null)
  printf '%s' "$p" | jq -es '.[0].questions | has("state") and has("repeating")' >/dev/null; check "triage: state + repeating questions" $?
else
  echo "request shape: skipped (jq not installed)"
fi

echo "masking"
# Token shapes are split with "" and joined at run time, so no token-shaped
# literal sits in the repo.
eval "$(awk '/^clean\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$jev")"
export SELFTEST_DEPLOY_TOKEN="literal-env-value-xyz123"
masked=$(sed 's/""//g' <<EOT | clean
DATABASE_URL=postgres://app:hunter2secret@db.internal:5432/notes
password: "correct horse battery"
  "api_key": "abcd1234efgh",
clientSecret=qqqq1111wwww
-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEA1234
-----END RSA PRIVATE KEY-----
gh""p_FAKE1234567890abcdefgh github""_pat_11ABCDEFG0123456789abcdefgh
AI""zaSyA1234567890abcdefghijklmnopqrstuv s""k_live_FAKE1234567890abcdef
h""f_FAKEabcdefghijklmnopqrstuv s""k-ant-FAKE-abcdefghijklmnop
Authorization: Bearer abcdefghijklmnop123456
Set-Cookie: sid=s3ss10nvalue123; Path=/
echo literal-env-value-xyz123
Keybindings: src/keys.ts and tokenizer: fast-bpe-v2
Tests: 12 passed, 0 failed
EOT
)
for leak in hunter2secret "correct horse" abcd1234efgh qqqq1111wwww MIIEow FAKE AIzaSy abcdefghijklmnop123456 s3ss10nvalue123 literal-env-value; do
  printf '%s' "$masked" | grep -q -- "$leak"; [ $? != 0 ]; check "masks $leak" $?
done
for keep in "src/keys.ts" "fast-bpe-v2" "12 passed" "db.internal:5432/notes"; do
  printf '%s' "$masked" | grep -q -- "$keep"; check "keeps $keep" $?
done

if command -v jq >/dev/null 2>&1; then
  echo "bin/jarvis (throwaway repo, fake superset)"
  tpl="$here/../plugins/jarvis/skills/setup/templates"
  sb="$tmp/sb"; mkdir -p "$sb" "$tmp/fake"
  git init -q --bare "$tmp/origin.git"
  cat > "$tmp/fake/superset" <<'EOT'
#!/bin/bash
echo "superset $*" >> "$FAKE_LOG"
case "$1 $2" in
  "agents create") n=$(( $(cat "$FAKE_LOG.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_LOG.n"
    printf '{"kind":"terminal","sessionId":"term-%s"}\n' "$n" ;;
  "terminals close") [ -z "${FAKE_CLOSE_FAIL:-}" ] || { echo "Error: terminal $6 not found" >&2; exit 1; } ;;
  "terminals read") printf '{"text":"%s"}\n' "${FAKE_SCREEN:-Working… esc to interrupt}" ;;
  "terminals list") printf '{"sessions":[%s]}\n' "$(printf '%s' "${FAKE_OPEN:-}" | sed -E 's/([^ ]+)/{"terminalId":"\1","exited":false,"title":"shell-\1"}/g; s/ /,/g')" ;;
esac
EOT
  chmod +x "$tmp/fake/superset"
  (
    cd "$sb" || exit 1
    export PATH="$tmp/fake:$PATH" FAKE_LOG="$tmp/fake.log" SUPERSET_WORKSPACE_ID=ws SUPERSET_TERMINAL_ID=jarvis-t
    unset TYPESAFE_API_KEY
    git init -q && git remote add origin "$tmp/origin.git"
    cp -R "$tpl/handoffs" . && sed -e 's/{{MAX_CLAUDE}}/3/' -e 's/{{AMBER}}/50/' -e 's/{{RED}}/75/' "$tpl/handoffs/jarvis.conf" > handoffs/jarvis.conf
    echo a > app.txt && git add -A && git commit -qm init && git push -q -u origin HEAD 2>/dev/null
    J=handoffs/bin/jarvis
    mk() { printf '# %s\nworker: %s\nmodel: %s\neffort: %s\nstarted: <x> · terminal: <x>\n\n## Goal\nx\n' "$1" "$2" "$3" "$4" > "handoffs/briefs/$1.md"; }
    mk b1 claude claude-opus-5-5 high; mk b2 claude sonnet medium; mk b3 claude claude-opus-5-5 medium; mk b4 opencode "" ""; mk b5 claude fable high

    $J start >/dev/null; grep -q '^Jarvis session: jarvis-t' handoffs/OPEN.md; check "start records this terminal in OPEN.md" $?
    $J spawn handoffs/briefs/b1.md >/dev/null 2>&1 && $J spawn handoffs/briefs/b2.md >/dev/null 2>&1; check "spawns two Claude workers under the cap" $?
    grep -q 'terminal: term-1' handoffs/briefs/b1.md; check "spawn writes the terminal into the brief" $?
    grep -q -- '--model claude-opus-5-5 --effort high' "$FAKE_LOG"; check "spawn passes model and effort from the header" $?
    $J spawn handoffs/briefs/b3.md >/dev/null 2>&1; [ $? = 1 ]; check "refuses a third Claude worker (cap 3, Jarvis included)" $?
    $J spawn handoffs/briefs/b4.md >/dev/null 2>&1; check "OpenCode doesn't count toward the cap" $?
    ! grep 'agent opencode' "$FAKE_LOG" | grep -q -- '--effort'; check "OpenCode gets no --effort" $?

    now=$(date +%s)
    echo "{\"model\":{},\"rate_limits\":{\"five_hour\":{\"used_percentage\":40,\"resets_at\":$((now + 4 * 3600))}}}" \
      | JARVIS_STATUSLINE_CMD='cat >/dev/null; echo mine' $J statusline | grep -qx mine; check "statusline tap runs the user's statusline" $?
    $J band | grep -q '^amber .*on pace for 200%'; check "40% in the first hour is amber (pace)" $?
    echo "{\"five_hour\":{\"used_percentage\":30,\"resets_at\":$((now + 2 * 3600))},\"ts\":$now}" > "$JARVIS_HOME/usage.json"
    $J band | grep -q '^green'; check "30% three hours in is green" $?
    echo "{\"five_hour\":{\"used_percentage\":80,\"resets_at\":$((now + 3600))},\"ts\":$now}" > "$JARVIS_HOME/usage.json"
    $J band | grep -q '^red'; check "80% is red" $?
    echo "{\"five_hour\":{\"used_percentage\":55,\"resets_at\":$((now + 3600))},\"ts\":$now}" > "$JARVIS_HOME/usage.json"
    sed -i.bak '/b2.md/d' handoffs/OPEN.md && rm -f handoffs/OPEN.md.bak
    out=$(JARVIS_HOME="$tmp/jh" $J spawn handoffs/briefs/b5.md 2>&1); [ $? = 1 ] && printf '%s' "$out" | grep -q 'fable'; check "an unauthorized fable worker is refused (eval/fabletest.sh tests the rest)" $?

    mkdir -p src && echo x > src/new.txt && echo b > app.txt && echo other > other.txt
    printf '# Add new\nstatus: done\nagent: claude claude-opus-5-5\nbrief: handoffs/briefs/b1.md\n## Files\n- `src/new.txt` — created\n- app.txt — modified\n- gone.txt — modified\n## Checks run\nnone\n' > handoffs/h1.md
    $J merge handoffs/h1.md --check >/dev/null; [ $? = 1 ]; check "merge --check flags a listed file that didn't change" $?
    sed -i.bak '/gone.txt/d' handoffs/h1.md && rm -f handoffs/h1.md.bak
    $J merge handoffs/h1.md --check | grep -q 'other.txt'; check "merge --check lists changes outside the handoff" $?
    $J merge handoffs/h1.md >/dev/null; check "merge succeeds" $?
    [ "$(git show --name-only --format= HEAD | sort | tr '\n' ' ')" = "app.txt handoffs/OPEN.md handoffs/briefs/b1.md handoffs/merged/h1.md src/new.txt " ]; check "commit holds exactly the listed files, the handoff, the brief and OPEN.md" $?
    git log -1 --format=%B | grep -q 'Co-Authored-By: Claude Code <claude-opus-5-5> worker'; check "worker trailer" $?
    git status --porcelain | grep -q 'other.txt'; check "another worker's file is left alone" $?
    [ "$(git rev-parse HEAD)" = "$(git -C "$tmp/origin.git" rev-parse HEAD)" ]; check "merge pushes" $?
    grep -q 'terminals close --workspace ws --terminal term-1' "$FAKE_LOG"; check "merge closes the worker" $?
    ! grep -q 'b1.md' handoffs/OPEN.md; check "merge drops the worker from OPEN.md" $?

    old=$(date -u -r $((now - 70 * 60)) +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d "@$((now - 70 * 60))" +%Y-%m-%dT%H:%M:%S.000Z)
    printf '{"type":"assistant","timestamp":"%s","message":{"model":"claude-fable-5-1","usage":{"input_tokens":5,"cache_read_input_tokens":240000,"cache_creation_input_tokens":3000}}}\n' "$old" > "$tmp/t.jsonl"
    hp() { printf '{"session_id":"s","transcript_path":"%s","prompt":"%s"}' "$tmp/t.jsonl" "$1" | $J hook prompt; }
    hp "hello" | jq -e '.decision == "block"' >/dev/null; check "guard stops the first message after 70 min idle at 243k" $?
    [ -z "$(hp "hello")" ]; check "…and lets the same message through when sent again" $?
    [ -z "$(hp "/clear")" ]; check "…and never stops a slash command" $?
    [ -z "$(SUPERSET_TERMINAL_ID=worker-t hp "hello")" ]; check "guard ignores worker terminals" $?
    [ -z "$(echo '{}' | $J hook prompt)" ]; check "guard is quiet on empty input" $?

    touch -t "$(date -r $((now - 70 * 60)) +%Y%m%d%H%M 2>/dev/null || date -d "@$((now - 70 * 60))" +%Y%m%d%H%M)" "$tmp/t.jsonl"
    : > "$FAKE_LOG"
    printf '# t\nstatus: done\nbrief: handoffs/briefs/b4.md\n## Files\n- other.txt — created\n' > handoffs/h4.md
    $J watch --once >/dev/null
    grep -q 'send .*--text /clear' "$FAKE_LOG" && grep -q 'send .*Fresh session.*h4.md' "$FAKE_LOG"; check "watch clears an idle Jarvis, then wakes it with the handoff" $?
    : > "$FAKE_LOG"; $J watch --once >/dev/null; ! grep -q 'terminals send' "$FAKE_LOG"; check "watch stays quiet when nothing changed" $?

    export CODEX_HOME="$tmp/codex"; mk b6 codex gpt-5.6-sol high
    $J spawn handoffs/briefs/b6.md >/dev/null 2>&1; check "spawns a Codex worker" $?
    grep -qxF "[projects.\"$(pwd -P)\"]" "$CODEX_HOME/config.toml"; check "Codex spawn pre-trusts the checkout in Codex's config" $?
    $J spawn handoffs/briefs/b6.md >/dev/null 2>&1
    [ "$(grep -c '^\[projects\.' "$CODEX_HOME/config.toml")" = 1 ]; check "…once, however many Codex workers follow" $?
    : > "$FAKE_LOG"; FAKE_SCREEN="  Trust this folder? › 1. Yes, continue  2. No, quit" $J watch --once >/dev/null
    grep -q 'send .*waiting at a prompt' "$FAKE_LOG"; check "watch wakes Jarvis for a worker at a trust prompt" $?
    : > "$FAKE_LOG"; FAKE_SCREEN="  Trust this folder? › 1. Yes, continue  2. No, quit" $J watch --once >/dev/null
    ! grep -q 'terminals send' "$FAKE_LOG"; check "…once per prompt" $?
    echo 'JARVIS_STALL_MIN=0' >> handoffs/jarvis.conf
    FAKE_SCREEN="frozen" $J watch --once >/dev/null; : > "$FAKE_LOG"; FAKE_SCREEN="frozen" $J watch --once >/dev/null
    grep -q "send .*screen hasn't changed" "$FAKE_LOG"; check "watch wakes Jarvis for a frozen worker with no handoff" $?
    b4t=$(sed -n 's/.*terminal: //p' handoffs/briefs/b4.md)
    [ -n "$b4t" ] && ! grep -q "$b4t's screen" "$FAKE_LOG"; check "…but not for one that already handed off" $?

    echo s > self.txt
    printf '# Self-listing\nstatus: done\nagent: codex gpt-5.6-sol\n## Files\n- self.txt — created\n- handoffs/h7.md — this handoff\n' > handoffs/h7.md
    $J merge handoffs/h7.md --no-push >/dev/null 2>&1; check "merge takes a handoff that lists itself" $?
    git show --name-only --format= HEAD | grep -qx 'handoffs/merged/h7.md' && [ ! -e handoffs/h7.md ]; check "…and commits it at its merged path only" $?

    echo "bin/jarvis leftovers (real processes, fake Claude config)"
    uid=$(id -u); proj=$(git rev-parse --show-toplevel | sed 's#[^A-Za-z0-9]#-#g')
    export CLAUDE_CONFIG_DIR="$tmp/cc"; mkdir -p "$CLAUDE_CONFIG_DIR/projects/$proj"
    scr="$tmp/claude-$uid/$proj"; groups="$tmp/fixture-groups"
    trap 'for g in $(cat "$groups" 2>/dev/null); do kill -9 -- "-$g" "$g" 2>/dev/null; done' EXIT
    uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
    alive() { kill -0 "$1" 2>/dev/null && [ "$(ps -o stat= -p "$1" | cut -c1)" != Z ]; }
    # like a Bash-tool command: a process group with no terminal, a parent naming
    # the session's scratch folder and a child that doesn't
    fixture() { # $1 = session id → prints the parent's pid (= its process group)
      mkdir -p "$scr/$1/scratchpad"
      python3 -c 'import os, subprocess, time; os.setsid(); subprocess.Popen(["sleep", "300"]); time.sleep(300)' \
        "$scr/$1/scratchpad/lab" >/dev/null 2>&1 &
      echo $! | tee -a "$groups"
    }
    worker() { # $1 = brief name, $2 = session id, $3 = terminal: a brief and the worker's transcript
      printf '# %s\nworker: claude\nmodel: claude-opus-5-5\neffort: high\nstarted: 2026-10-19 10:00 · terminal: %s\n\n## Goal\nx\n' "$1" "$3" > "handoffs/briefs/$1.md"
      { for i in 1 2 3 4 5; do echo '{"type":"system"}'; done
        printf '{"type":"user","message":{"role":"user","content":"You are a Jarvis worker. Read AGENTS.md, then do the task in handoffs/briefs/%s.md. Put every question in one first handoff."}}\n' "$1"
      } > "$CLAUDE_CONFIG_DIR/projects/$proj/$2.jsonl"
    }
    wa=$(uuid); wb=$(uuid); wc=$(uuid); wj=$(uuid)
    worker la "$wa" term-a; worker lb "$wb" term-b
    printf '# lc\nworker: claude\nmodel: sonnet\neffort: medium\nstarted: 2026-10-19 10:00 · terminal: term-c\n\n## Goal\nx\n' > handoffs/briefs/lc.md
    pa=$(fixture "$wa"); pb=$(fixture "$wb"); pc=$(fixture "$wc"); pj=$(fixture "$wj")
    # a browser whose script died: the launcher exits, its child carries on under PID 1
    python3 -c 'import os, subprocess, sys; os.setsid(); subprocess.Popen(["python3", "-c", "import time; time.sleep(300)", sys.argv[1]])' \
      "$scr/$wa/scratchpad/lab/tmp1/p" >/dev/null 2>&1 & po=$!; echo "$po" >> "$groups"
    # one in this shell's own process group, as the caller's own Bash command would be
    python3 -c 'import time; time.sleep(300)' "$scr/$wj/scratchpad/self" >/dev/null 2>&1 & ps_self=$!; echo "$ps_self" >> "$groups"
    sleep 1
    orphan=$(ps -axo pid=,pgid=,command= | awk -v g="$po" '$2 == g && /tmp1\/p/ {print $1}')
    # a worker that ran /clear: a transcript with no spawn prompt, seen only by the prompt hook
    printf '{"session_id":"%s","transcript_path":"/nonexistent","prompt":"hi"}' "$wc" | SUPERSET_TERMINAL_ID=term-c $J hook prompt
    grep -qx "$wc" handoffs/.jarvis/sessions/term-c; check "the prompt hook records each terminal's session" $?

    out=$($J leftovers)
    printf '%s' "$out" | grep -q 'briefs/la.md (worker terminal closed)' && printf '%s' "$out" | grep -q 'briefs/lb.md' \
      && printf '%s' "$out" | grep -q 'briefs/lc.md'; check "leftovers finds each worker's processes, /clear'd one included" $?
    printf '%s' "$out" | grep -q "pid $orphan .*orphaned"; check "…marks the one adopted by PID 1 as orphaned" $?
    printf '%s' "$out" | grep -q "pid $pa .*+1 child"; check "…counts a parent's child processes with it" $?
    printf '%s' "$out" | grep -q '<scratch>/scratchpad/lab'; check "…and shortens the scratch path" $?
    ! printf '%s' "$out" | grep -q "pid $pj "; check "a session that isn't a worker's is never listed" $?
    $J status | grep -q 'left running by closed workers'; check "status reports closed workers' leftovers" $?
    ! FAKE_OPEN='term-a term-b term-c' $J status | grep -q 'left running'; check "…but not open workers'" $?

    FAKE_OPEN='term-a' $J leftovers handoffs/briefs/la.md --stop | grep -q 'not stopped'; check "--stop refuses while the worker's terminal is open" $?
    alive "$pa" && alive "$orphan"; check "…and leaves its processes running" $?

    echo la > la.txt
    printf '# la\nstatus: done\nagent: claude claude-opus-5-5\nbrief: handoffs/briefs/la.md\n## Files\n- la.txt — created\n## Processes left running\nnone\n' > handoffs/hla.md
    out=$($J merge handoffs/hla.md --no-push); printf '%s' "$out" | grep -q 'closed term-a'; check "merge closes the worker" $?
    printf '%s' "$out" | grep -q 'stopped 3 process(es)'; check "…then stops what it left: the parent, its child and the orphan" $?
    sleep 1; ! alive "$pa" && ! alive "$orphan" && [ -z "$(ps -axo pgid= | awk -v g="$pa" '$1 == g')" ]; check "…all of them gone" $?
    alive "$pb" && alive "$pc" && alive "$pj"; check "another worker's processes, and a non-worker session's, are untouched" $?

    echo lb > lb.txt
    printf '# lb\nstatus: done\nagent: claude claude-opus-5-5\nbrief: handoffs/briefs/lb.md\n## Files\n- lb.txt — created\n## Processes left running\n- %s — dev server the user is clicking through\n' "$pb" > handoffs/hlb.md
    out=$($J merge handoffs/hlb.md --no-push); printf '%s' "$out" | grep -q "kept $pb"; check "merge keeps what the handoff declares under Processes left running" $?
    alive "$pb"; check "…and it keeps running" $?
    ! $J status | grep -q 'briefs/lb.md'; check "status doesn't nag about a declared process" $?
    $J leftovers handoffs/briefs/lb.md --stop >/dev/null; alive "$pb"; check "--stop honours the declaration too" $?
    $J leftovers handoffs/briefs/lb.md --stop --force | grep -q 'stopped 2'; check "--stop --force ends it" $?
    sleep 1; ! alive "$pb"; check "…and it's gone" $?

    $J leftovers handoffs/briefs/lc.md --stop | grep -q 'stopped 2'; check "a /clear'd worker's leftovers stop by the hook's record" $?
    $J leftovers --force >/dev/null 2>&1; [ $? = 1 ]; check "--force needs a brief" $?

    out=$(CLAUDE_CODE_SESSION_ID=$wj $J leftovers --mine)
    printf '%s' "$out" | grep -q "pid $pj "; check "--mine lists this session's processes" $?
    ! printf '%s' "$out" | grep -q "pid $ps_self "; check "…but never the caller's own process group" $?
    CLAUDE_CODE_SESSION_ID=$wj $J leftovers --mine --stop >/dev/null; sleep 1; ! alive "$pj" && alive "$ps_self"; check "--mine --stop stops them, not the caller" $?
    env -u CLAUDE_CODE_SESSION_ID $J leftovers --mine >/dev/null 2>&1; [ $? = 1 ]; check "--mine without a Claude session refuses" $?
    [ "$($J leftovers)" = "nothing left running by any worker" ]; check "nothing left afterwards" $?

    echo "bin/jarvis lifecycle (run registry, verified close; real processes as agents)"
    echo 'JARVIS_STOP_GRACE=1' >> handoffs/jarvis.conf
    mkdir -p "$CLAUDE_CONFIG_DIR/sessions"; cwd=$(pwd -P); runs=handoffs/.jarvis/runs
    nb() { printf '# %s\nworker: claude\nmodel: claude-opus-5-5\neffort: high\n\n## Goal\nx\n' "$1" > "handoffs/briefs/$1.md"; }
    tid() { sed -n 's/^started:.*terminal: //p' "handoffs/briefs/$1.md"; }
    hof() { echo "$1" > "$1.txt"; printf '# %s\nstatus: done\nagent: claude claude-opus-5-5\nbrief: handoffs/briefs/%s.md\n## Files\n- %s.txt — created\n## Processes left running\nnone\n' "$1" "$1" "$1" > "handoffs/h$1.md"; }
    # a stand-in for a worker's claude: a real process, its session record (as Claude Code
    # writes them) and a transcript that opens with the spawn prompt for brief $1
    agent() { # $1 = brief name ("" = not a worker), $2 = session id, [$3 = procStart to record], [$4 = status] → its pid
      sleep 300 >/dev/null 2>&1 & p=$!; echo "$p" >> "$groups"
      st=${3:-$(TZ=UTC LC_ALL=C ps -o lstart= -p "$p" | tr -s ' ' | sed 's/ $//')}
      printf '{"pid":%s,"sessionId":"%s","cwd":"%s","procStart":"%s","status":"%s"}\n' "$p" "$2" "$cwd" "$st" "${4:-idle}" > "$CLAUDE_CONFIG_DIR/sessions/$p.json"
      if [ -n "$1" ]; then printf '{"type":"user","message":{"role":"user","content":"You are a Jarvis worker. Read AGENTS.md, then do the task in handoffs/briefs/%s.md. Put every question in one first handoff."}}\n' "$1"
      else echo '{"type":"user","message":{"role":"user","content":"hi"}}'; fi > "$CLAUDE_CONFIG_DIR/projects/$proj/$2.jsonl"
      echo "$p"
    }

    nb r1; $J spawn handoffs/briefs/r1.md --force >/dev/null 2>&1; r1=$(tid r1)
    [ -n "$r1" ] && sed -n 5p handoffs/briefs/r1.md | grep -q "^started: .* · terminal: $r1\$"; check "spawn adds a started: line after the header when the brief has none" $?
    grep -qx 'brief: handoffs/briefs/r1.md' "$runs/$r1" && grep -qx 'state: running' "$runs/$r1" && grep -qx 'agent: claude' "$runs/$r1"; check "…and writes the run registry" $?
    sed -i.bak '/^started:/d' handoffs/briefs/r1.md && sed -i.bak '/r1\.md/d' handoffs/OPEN.md && rm -f handoffs/briefs/r1.md.bak handoffs/OPEN.md.bak
    hof r1; out=$($J merge handoffs/hr1.md --no-push)
    printf '%s' "$out" | grep -q "closed $r1" && grep -q "terminals close --workspace ws --terminal $r1\$" "$FAKE_LOG"; check "merge closes the worker through the registry alone" $?
    grep -qx 'state: merged' "$runs/$r1" && grep -q '^outcome: closed' "$runs/$r1"; check "…and marks the run merged" $?

    nb r2; awk '{print} /^## Running workers/ {print "- 2026-10-19 10:00 · claude/claude-opus-5-5 high · term term-L2 · handoffs/briefs/r2.md"}' handoffs/OPEN.md > "$tmp/o" && cat "$tmp/o" > handoffs/OPEN.md
    hof r2; $J merge handoffs/hr2.md --no-push | grep -q 'closed term-L2'; check "a brief from before the registry closes through its OPEN.md line" $?
    grep -qx 'state: merged' "$runs/term-L2"; check "…and gets a run record" $?
    nb r0; hof r0; $J merge handoffs/hr0.md --no-push | grep -q 'no worker terminal recorded for handoffs/briefs/r0.md'; check "merge says so when no terminal is recorded" $?

    nb r3; $J spawn handoffs/briefs/r3.md --force >/dev/null 2>&1; r3=$(tid r3)
    hof r3; out=$(FAKE_CLOSE_FAIL=1 $J merge handoffs/hr3.md --no-push)
    printf '%s' "$out" | grep -q "close FAILED for $r3: Error: terminal $r3 not found"; check "a failed close is on the merge line, with the host's error" $?
    grep -q '^outcome: close FAILED' "$runs/$r3" && grep -q "close run=$r3 .*result=FAILED" handoffs/.jarvis/audit.log; check "…and kept in the run record and the audit log" $?

    nb r4; $J spawn handoffs/briefs/r4.md --force >/dev/null 2>&1; r4=$(tid r4)
    p4=$(agent r4 "$(uuid)" "" busy); pn=$(agent "" "$(uuid)" "" busy); pw=$(agent r4 "$(uuid)" "Thu Jan 1 00:00:00 2026" busy)
    [ "$($J sessions | grep -c '^  [0-9][0-9]* *busy ')" = 2 ]; check "jarvis sessions counts live Claude processes here, a stale session record left out" $?
    hof r4; out=$($J merge handoffs/hr4.md --no-push)
    printf '%s' "$out" | grep -q "worker pid $p4 didn't exit on close: stopped (TERM)"; check "merge stops a worker agent the close left running" $?
    sleep 1; ! alive "$p4"; check "…and it's gone" $?
    grep -q "signal run=$r4 brief=handoffs/briefs/r4.md pid=$p4 procstart=.* result=TERM sent" handoffs/.jarvis/audit.log; check "…with an audit line" $?
    alive "$pw" && ! grep -q "pid=$pw " handoffs/.jarvis/audit.log; check "a PID whose start time doesn't match the session record is never signalled" $?
    alive "$pn" && ! grep -q "pid=$pn " handoffs/.jarvis/audit.log; check "a non-worker session in the same checkout is never signalled" $?

    echo 'JARVIS_REAP=0' >> handoffs/jarvis.conf
    nb r5; $J spawn handoffs/briefs/r5.md --force >/dev/null 2>&1; p5=$(agent r5 "$(uuid)")
    hof r5; out=$($J merge handoffs/hr5.md --no-push)
    printf '%s' "$out" | grep -q "worker pid $p5 didn't exit on close: still running (JARVIS_REAP=0; stop it: kill $p5)" && alive "$p5"; check "JARVIS_REAP=0 names a surviving agent and leaves it" $?
    sed -i.bak '/^JARVIS_REAP=0$/d' handoffs/jarvis.conf && rm -f handoffs/jarvis.conf.bak

    nb r6; $J spawn handoffs/briefs/r6.md --force >/dev/null 2>&1; r6a=$(tid r6)
    $J spawn handoffs/briefs/r6.md --force 2>&1 | grep -q "already had a running worker ($r6a); merge closes every worker of this brief"; check "respawning a brief warns" $?
    r6b=$(tid r6); hof r6; out=$($J merge handoffs/hr6.md --no-push)
    [ "$r6a" != "$r6b" ] && printf '%s' "$out" | grep -q "closed $r6a" && printf '%s' "$out" | grep -q "closed $r6b"; check "…and merge closes both runs" $?

    nb r7; $J spawn handoffs/briefs/r7.md --force >/dev/null 2>&1; r7=$(tid r7)
    $J close "$r7" | grep -q "closed $r7 · dropped it" && grep -qx 'state: closed' "$runs/$r7" && ! grep -q 'r7\.md' handoffs/OPEN.md; check "jarvis close closes the run and marks it closed" $?
    $J close term-zz >/dev/null && grep -q 'terminal term-zz$' "$FAKE_LOG" && grep -qx 'state: closed' "$runs/term-zz"; check "…a terminal with no record too" $?
    $J close jarvis-t >/dev/null 2>&1; [ $? = 1 ]; check "…but never Jarvis's own" $?
    kill "$pn" "$pw" "$p5" 2>/dev/null

    echo "bin/jarvis doctor (census, dry run, --apply; real processes as agents)"
    rm -rf "$runs" handoffs/.jarvis/audit.log; rm -f "$CLAUDE_CONFIG_DIR"/sessions/*.json
    export JARVIS_LOCK_DIR="$tmp/locks"
    lb() { printf '# %s\nworker: claude\nmodel: claude-opus-5-5\neffort: high\nstarted: 2026-10-19 10:00 · terminal: %s\n\n## Goal\nx\n' "$1" "$2" > "handoffs/briefs/$1.md"; }
    mh() { printf '# %s\nstatus: done\nbrief: handoffs/briefs/%s.md\n## Files\n- x\n' "$1" "$1" > "handoffs/merged/h$1.md"; }
    merged() { run_f="$runs/$1"; sed 's/^state: running$/state: merged/' "$run_f" > "$tmp/r" && { cat "$tmp/r"; echo "ended: ${2:-$(date +%s)}"; } > "$run_f"; } # $2 = ended
    ago=$(( $(date +%s) - 7200 ))
    commit_ago() { git add "$1" && GIT_COMMITTER_DATE="$ago +0000" git commit -q -m "$1" -- "$1"; } # $1 = a merged handoff, added 2 h ago
    js=$(uuid); pjv=$(agent "" "$js"); printf '{"session_id":"%s"}\n' "$js" > handoffs/.jarvis/session.json
    nb d1; $J spawn handoffs/briefs/d1.md --force >/dev/null 2>&1; d1=$(tid d1); pd1=$(agent d1 "$(uuid)")           # running
    nb d2; $J spawn handoffs/briefs/d2.md --force >/dev/null 2>&1; d2=$(tid d2); pd2=$(agent d2 "$(uuid)"); merged "$d2" # finished, terminal open
    nb d3; $J spawn handoffs/briefs/d3.md --force >/dev/null 2>&1; d3=$(tid d3); pd3=$(agent d3 "$(uuid)"); merged "$d3" # finished, terminal gone
    lb d4 term-d4; mh d4; pd4=$(agent d4 "$(uuid)")                                                                   # legacy finished, terminal gone
    lb d5 term-d5; mh d5                                                                                               # legacy finished terminal, open
    nb d6; $J spawn handoffs/briefs/d6.md --force >/dev/null 2>&1; d6=$(tid d6); pd6=$(agent d6 "$(uuid)" "" busy); merged "$d6" # finished but busy
    nb d7; $J spawn handoffs/briefs/d7.md --force >/dev/null 2>&1; d7=$(tid d7)                                       # lost
    pnw=$(agent "" "$(uuid)")                                                                                          # not a worker
    # sessions resumed (claude --resume) after their brief finished: legacy, merged 2 h ago (commit, then mtime), and a registry run ended 2 h ago
    lb d8 term-d8; mh d8; commit_ago handoffs/merged/hd8.md >/dev/null; pd8=$(agent d8 "$(uuid)")
    lb d12 term-d12; mh d12; touch -t "$(date -r "$ago" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$ago" +%Y%m%d%H%M.%S)" handoffs/merged/hd12.md; pd12=$(agent d12 "$(uuid)")
    nb d9; $J spawn handoffs/briefs/d9.md --force >/dev/null 2>&1; d9=$(tid d9); merged "$d9" "$ago"; pd9=$(agent d9 "$(uuid)")
    export FAKE_OPEN="jarvis-t $d1 $d2 term-d5 $d6 term-u"
    sum() { find handoffs -type f -exec cksum {} + | sort; }
    before=$(sum); : > "$FAKE_LOG"
    out=$($J doctor); echo "$out" > "$tmp/doctor.out"
    printf '%s' "$out" | grep -q "pid $pjv .* · Jarvis\$"; check "doctor: Jarvis's process" $?
    printf '%s' "$out" | grep -q "pid $pd1 .* worker, running · d1 · run $d1 (running)"; check "doctor: a running worker" $?
    printf '%s' "$out" | grep -q "pid $pd2 .* worker, FINISHED · d2 · run $d2 (merged)" \
      && printf '%s' "$out" | grep -q "pid $pd3 .* worker, FINISHED · d3"; check "doctor: finished workers, from the registry" $?
    printf '%s' "$out" | grep -q "pid $pd4 .* worker, FINISHED · d4 · no run record, handoff merged"; check "doctor: a finished worker from before the registry" $?
    printf '%s' "$out" | grep -q "pid $pd6 .* busy .* worker, FINISHED · d6 .* busy: left alone"; check "doctor: a busy finished worker is left alone" $?
    printf '%s' "$out" | grep -q "pid $pnw .* not a worker"; check "doctor: a session that isn't a worker's" $?
    printf '%s' "$out" | grep -q "^  $d2 · FINISHED but open · d2 · merged" \
      && printf '%s' "$out" | grep -q "^  term-d5 · FINISHED but open · d5 · no run record"; check "doctor: finished terminals still open, registry and legacy" $?
    printf '%s' "$out" | grep -q '^  term-u · unknown (left alone) · "shell-term-u"'; check "doctor: an unknown terminal, with its title" $?
    printf '%s' "$out" | grep -q "^  run $d7 · lost"; check "doctor: a lost run" $?
    printf '%s' "$out" | grep -q "pid $pd8 .* resumed after its brief finished (left alone) · d8\$" \
      && printf '%s' "$out" | grep -q "pid $pd12 .* resumed after its brief finished (left alone) · d12\$"; check "doctor: a session resumed after its legacy brief was merged (commit time, else mtime)" $?
    printf '%s' "$out" | grep -q "pid $pd9 .* resumed after its brief finished (left alone) · d9\$"; check "doctor: a session resumed after its run ended" $?
    [ "$before" = "$(sum)" ] && ! grep -q 'terminals close' "$FAKE_LOG" \
      && alive "$pd1" && alive "$pd2" && alive "$pd3" && alive "$pd4" && alive "$pd6" && alive "$pnw" && alive "$pjv" && alive "$pd8" && alive "$pd9" && alive "$pd12"; check "doctor without --apply changes nothing: handoffs/ identical, no close, every process alive" $?
    q="doctor: 4 finished workers still running · 3 finished terminals open · 1 lost run — handoffs/bin/jarvis doctor"
    [ "$($J doctor --quiet)" = "$q" ]; check "doctor --quiet is one line, resumed sessions not counted" $?
    $J status | grep -qxF "$q" && $J start | grep -qxF "$q"; check "status and start print it" $?
    $J lock docker -- sleep 30 & lk=$!; echo "$lk" >> "$groups"
    for _ in 1 2 3 4 5 6 7 8 9 10; do ls "$JARVIS_LOCK_DIR"/docker.slot* >/dev/null 2>&1 && break; sleep 0.3; done; sleep 0.3
    $J doctor | grep -A1 '^  docker · machine' | grep -q "held  pid [0-9]* .* sleep 30\$"; check "doctor shows a machine-wide lease that's held" $?
    kill "$lk" 2>/dev/null; wait "$lk" 2>/dev/null

    : > "$FAKE_LOG"; out=$($J doctor --apply); echo "$out" >> "$tmp/doctor.out"
    grep -q "terminals close --workspace ws --terminal $d2\$" "$FAKE_LOG" && grep -q 'terminal term-d5$' "$FAKE_LOG"; check "--apply closes the finished terminals, registry and legacy" $?
    [ "$(grep -c 'terminals close' "$FAKE_LOG")" = 2 ]; check "…and no other terminal: running, busy, unknown and Jarvis's stay open" $?
    sleep 1; ! alive "$pd2" && ! alive "$pd3" && ! alive "$pd4"; check "--apply stops the finished workers' agents (registry and legacy)" $?
    alive "$pd1" && alive "$pd6" && alive "$pnw" && alive "$pjv"; check "…and leaves running, busy, non-worker and Jarvis alone" $?
    alive "$pd8" && alive "$pd9" && alive "$pd12" && ! grep -qE "pid=($pd8|$pd9|$pd12) " handoffs/.jarvis/audit.log; check "…and every resumed session" $?
    grep -qx 'state: lost' "$runs/$d7" && grep -qx 'state: merged' "$runs/term-d5" && grep -qx 'state: running' "$runs/$d1"; check "--apply marks the lost run, records the legacy close" $?
    [ "$(grep -vc ' cap-force ' handoffs/.jarvis/audit.log)" = 6 ] \
      && grep -q "close run=$d2 .*result=ok" handoffs/.jarvis/audit.log && grep -q "signal run=$d2 .*pid=$pd2 .*TERM sent" handoffs/.jarvis/audit.log \
      && grep -q "close run=term-d5 .*result=ok" handoffs/.jarvis/audit.log && grep -q "signal run=$d3 .*pid=$pd3 .*TERM sent" handoffs/.jarvis/audit.log \
      && grep -q "signal run=term-d4 brief=handoffs/briefs/d4.md pid=$pd4 .*TERM sent" handoffs/.jarvis/audit.log \
      && grep -q "lost run=$d7 .*result=marked lost" handoffs/.jarvis/audit.log; check "…one audit line per action" $?
    [ "$(printf '%s\n' "$out" | grep -c '^doctor: ')" -ge 5 ] && printf '%s' "$out" | grep -q "^doctor: left $d6 open: its agent is busy"; check "…and a printed line for each" $?
    kill "$pd6" 2>/dev/null; export FAKE_OPEN="jarvis-t $d1 term-u"; sleep 1
    [ -z "$($J doctor --quiet)" ] && ! $J status | grep -q '^doctor:' && ! $J start | grep -q '^doctor:'; check "clean: --quiet, status and start say nothing" $?
    # Jarvis with no prompt-hook record: the Claude process above `jarvis doctor` in Jarvis's terminal
    sh -c 'echo $PPID' > "$tmp/me"; me=$(cat "$tmp/me")
    printf '{"pid":%s,"sessionId":"%s","cwd":"%s","procStart":"%s","status":"busy"}\n' "$me" "$(uuid)" "$cwd" \
      "$(TZ=UTC LC_ALL=C ps -o lstart= -p "$me" | tr -s ' ' | sed 's/ $//')" > "$CLAUDE_CONFIG_DIR/sessions/$me.json"
    $J doctor | grep -q "pid $me .* · Jarvis\$" && SUPERSET_TERMINAL_ID=term-x $J doctor | grep -q "pid $me .* · not a worker"; check "doctor knows Jarvis as the Claude above it in Jarvis's terminal, and only there" $?
    rm -f "$CLAUDE_CONFIG_DIR/sessions/$me.json"
    # a finished terminal whose session was resumed after the brief finished may be where it runs now: left open
    nb d10; $J spawn handoffs/briefs/d10.md --force >/dev/null 2>&1; d10=$(tid d10); merged "$d10" "$ago"; pd10=$(agent d10 "$(uuid)")
    lb d11 term-d11; mh d11; commit_ago handoffs/merged/hd11.md >/dev/null; pd11=$(agent d11 "$(uuid)")
    export FAKE_OPEN="jarvis-t $d1 term-u $d10 term-d11"; out=$($J doctor)
    printf '%s' "$out" | grep -q "^  $d10 · FINISHED but open · d10 · merged · a session resumed there after the brief finished (left alone)\$" \
      && printf '%s' "$out" | grep -q "^  term-d11 · FINISHED but open · d11 · no run record, handoff merged · a session resumed there after the brief finished (left alone)\$"; check "doctor: a finished terminal with a resumed session, registry and legacy" $?
    [ -z "$($J doctor --quiet)" ]; check "…isn't counted by --quiet" $?
    : > "$FAKE_LOG"; na=$(wc -l < handoffs/.jarvis/audit.log); out=$($J doctor --apply)
    printf '%s' "$out" | grep -qx "doctor: skipped $d10: a session resumed there after the brief finished" \
      && printf '%s' "$out" | grep -qx "doctor: skipped term-d11: a session resumed there after the brief finished"; check "--apply skips a finished terminal with a resumed session, saying so" $?
    ! grep -q 'terminals close' "$FAKE_LOG" && [ "$(wc -l < handoffs/.jarvis/audit.log)" = "$na" ] && [ ! -f "$runs/term-d11" ] && alive "$pd10" && alive "$pd11"; check "…closing nothing, auditing nothing, both sessions alive" $?
    $J close "$d10" | grep -q "closed $d10" && sleep 1 && alive "$pd10" && ! grep -q "pid=$pd10 " handoffs/.jarvis/audit.log; check "stop_run (jarvis close) on an ended run leaves a session resumed after it alone" $?
    # leftovers: what a resumed session runs is its own, never a finished worker's leftover
    s13=$(uuid); nb d13; $J spawn handoffs/briefs/d13.md --force >/dev/null 2>&1; d13=$(tid d13); merged "$d13" "$ago"; pd13=$(agent d13 "$s13"); pg13=$(fixture "$s13")
    s15=$(uuid); lb d15 term-d15; mh d15; commit_ago handoffs/merged/hd15.md >/dev/null; pd15=$(agent d15 "$s15"); pg15=$(fixture "$s15")
    s14=$(uuid); nb d14; $J spawn handoffs/briefs/d14.md --force >/dev/null 2>&1; d14=$(tid d14); pd14=$(agent d14 "$s14"); merged "$d14"; pg14=$(fixture "$s14") # ended after it started
    sleep 1; out=$($J leftovers)
    ! printf '%s' "$out" | grep -q 'briefs/d13\.md' && ! printf '%s' "$out" | grep -q 'briefs/d15\.md' \
      && ! $J status | grep -qE 'briefs/d1[35]\.md'; check "leftovers and status don't list a resumed session's processes (registry and legacy)" $?
    printf '%s' "$out" | grep -q 'briefs/d14\.md (worker terminal closed)'; check "…but still list a finished worker's that started before the end" $?
    $J leftovers handoffs/briefs/d13.md --stop | grep -qx 'nothing left running by handoffs/briefs/d13.md' \
      && $J leftovers handoffs/briefs/d15.md --stop >/dev/null && alive "$pg13" && alive "$pg15"; check "leftovers --stop leaves them running" $?
    hof d13; out=$($J merge handoffs/hd13.md --no-push)
    ! printf '%s' "$out" | grep -q 'the worker left these running' && sleep 1 && alive "$pg13"; check "…and so does merge's reap" $?
    $J leftovers handoffs/briefs/d14.md --stop | grep -q 'stopped 2' && sleep 1 && ! alive "$pg14"; check "…which still stops the finished worker's" $?
    kill "$pd1" "$pnw" "$pjv" "$pd8" "$pd9" "$pd10" "$pd11" "$pd12" "$pd13" "$pd14" "$pd15" 2>/dev/null
    kill -- "-$pg13" "-$pg15" 2>/dev/null
  ) | tee "$tmp/jarvis.out"
  n=$(grep -c '^  FAIL' "$tmp/jarvis.out"); fails=$((fails + n))
else
  echo "bin/jarvis: skipped (jq not installed)"
fi

# The tmux host, on a tmux server of its own (its own socket), with a stand-in
# agent that echoes its launch and each line typed into it. The user's tmux
# sessions are never touched.
if command -v tmux >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  echo "tmux host"
  tb="$tmp/tb"; mkdir -p "$tb"
  (
    cd "$tb" || exit 1
    git init -q && git commit -q --allow-empty -m init
    cp -R "$tpl/handoffs" . && sed -e 's/{{MAX_CLAUDE}}/3/' -e 's/{{AMBER}}/50/' -e 's/{{RED}}/75/' "$tpl/handoffs/jarvis.conf" > handoffs/jarvis.conf
    rm -f handoffs/bin/jev.sh
    # shellcheck disable=SC2016
    printf '%s\n' 'JARVIS_PUSH=0' \
      'JARVIS_AGENT_fake='"'"'echo "fake model=$JARVIS_MODEL effort=$JARVIS_EFFORT"; echo "prompt=$JARVIS_PROMPT"; while read -r l; do echo "got: $l"; done'"'" \
      >> handoffs/jarvis.conf
    printf '# t\nworker: fake\nmodel: m1\neffort: low\nstarted: <x>\n' > handoffs/briefs/2026-10-20-1200-tw.md
    git add -A && git commit -q -m setup
    sock="jarvis-selftest-$$"
    env -u SUPERSET_WORKSPACE_ID -u SUPERSET_TERMINAL_ID -u TMUX -u TMUX_PANE tmux -L "$sock" new-session -d -c "$tb" -x 160 -y 40
    tenv=$(tmux -L "$sock" display-message -p '#{socket_path},#{pid},0')
    T() { env -u SUPERSET_WORKSPACE_ID -u SUPERSET_TERMINAL_ID TMUX="$tenv" TMUX_PANE=%0 handoffs/bin/jarvis "$@"; }

    T start >/dev/null && grep -qx 'Jarvis session: %0' handoffs/OPEN.md; check "start records the tmux pane" $?
    echo hi > note.txt
    T spawn handoffs/briefs/2026-10-20-1200-tw.md --attach note.txt | grep -q '^spawned %1 fake/m1 low'; check "spawn opens a window for any configured agent" $?
    [ "$(tmux -L "$sock" display-message -p -t %1 '#{window_name} #{@jarvis}')" = "tw tw" ]; check "…named after the brief and tagged" $?
    grep -q '^started:.*terminal: %1' handoffs/briefs/2026-10-20-1200-tw.md && grep -q '· term %1 ·' handoffs/OPEN.md; check "…and recorded in the brief and OPEN.md" $?
    sleep 1
    T read %1 10 | grep -q '^fake model=m1 effort=low'; check "read shows the screen; model and effort reach the agent" $?
    T read %1 10 | grep -q 'Read this attached file first: note.txt'; check "--attach names the file in the prompt" $?
    T send %1 "Answers: 1. yes
2. no" && sleep 1 && T read %1 5 | grep -qx 'got: Answers: 1. yes 2. no'; check "send types one line and presses Enter" $?
    T send %1 --keys "a,b,enter" && sleep 1 && T read %1 5 | grep -qx 'got: ab'; check "send --keys presses keys" $?
    T close %0 >/dev/null 2>&1; [ $? = 1 ] && tmux -L "$sock" list-panes -a -F '#{pane_id}' | grep -qx %0; check "close refuses a pane Jarvis didn't open" $?
    T send %1 --keys ctrl+d && sleep 1 && T read %1 3 | grep -q 'exited (0)'; check "an agent that exits leaves its window up" $?
    printf '# done\nstatus: done\nbrief: handoffs/briefs/2026-10-20-1200-tw.md\nagent: fake m1\n\n## Files\n- note.txt\n' > handoffs/htw.md
    T watch --once | grep -q 'woke Jarvis: handoff handoffs/htw.md'; check "the watcher wakes Jarvis's pane" $?
    T merge handoffs/htw.md --no-push | grep -q 'closed %1' && ! tmux -L "$sock" list-panes -a -F '#{pane_id}' | grep -qx %1; check "merge closes the worker's window" $?
    env -u SUPERSET_WORKSPACE_ID -u TMUX -u TMUX_PANE handoffs/bin/jarvis read %1 >/dev/null 2>&1; [ $? = 1 ]; check "with no host, jarvis says so" $?
    tmux -L "$sock" kill-server
    rm -f "${tenv%%,*}"
  ) | tee "$tmp/tmux.out"
  n=$(grep -c '^  FAIL' "$tmp/tmux.out"); fails=$((fails + n))
else
  echo "tmux host: skipped (tmux or jq not installed)"
fi

# The Ultron host, on a daemon of its own (its own ULTRON_HOME and socket) with a
# stand-in `claude` first on its PATH. A running Ultron is never touched. Needs an
# `ultron` binary: on PATH, or ULTRON_BIN=<path>.
ub=${ULTRON_BIN:-$(command -v ultron 2>/dev/null)}
if [ -n "$ub" ] && command -v jq >/dev/null 2>&1; then
  echo "ultron host"
  ux="$tmp/ux"; mkdir -p "$ux/home/bin" "$ux/shim" "$ux/repo"
  (
    cp "$ub" "$ux/home/bin/ultron"
    # shellcheck disable=SC2016
    printf '%s\n' '#!/bin/sh' 'm=""; p=""; while [ $# -gt 0 ]; do [ "$1" = --model ] && m=$2; p=$1; shift; done' \
      'echo "fake model=$m"; echo "prompt=$p"; while read -r l; do echo "got: $l"; done' > "$ux/shim/claude"
    chmod +x "$ux/shim/claude"
    export ULTRON_HOME="$ux/home" ULTRON_SOCKET="$ux/u.sock" PATH="$ux/home/bin:$ux/shim:$PATH"
    cd "$ux/repo" || exit 1
    git init -q && git commit -q --allow-empty -m init
    cp -R "$tpl/handoffs" . && sed -e 's/{{MAX_CLAUDE}}/3/' -e 's/{{AMBER}}/50/' -e 's/{{RED}}/75/' "$tpl/handoffs/jarvis.conf" > handoffs/jarvis.conf
    rm -f handoffs/bin/jev.sh; echo 'JARVIS_PUSH=0' >> handoffs/jarvis.conf
    printf '# u\nworker: claude\nmodel: claude-haiku-5-5\neffort: low\nstarted: <x>\n' > handoffs/briefs/2026-10-20-1200-uw.md
    git add -A && git commit -q -m setup
    ultron daemon run > "$ux/daemon.log" 2>&1 &
    for _ in $(seq 40); do ultron daemon status --json 2>/dev/null | grep -q '"pid"' && break; sleep 0.25; done
    ultron project add . --json >/dev/null
    J=$(ultron agent spawn --agent claude --role jarvis --transport pty --title jarvis --prompt "be jarvis" --json | jq -r .id)
    U() { env -u SUPERSET_WORKSPACE_ID -u SUPERSET_TERMINAL_ID -u TMUX -u TMUX_PANE ULTRON_SESSION_ID="$J" handoffs/bin/jarvis "$@"; }

    U start >/dev/null && grep -qx "Jarvis session: $J" handoffs/OPEN.md; check "start records the Ultron session" $?
    echo hi > note.txt
    U spawn handoffs/briefs/2026-10-20-1200-uw.md --attach note.txt >/dev/null
    W=$(grep -o 'term s_[0-9a-f]*' handoffs/OPEN.md | head -n 1 | cut -d' ' -f2)
    [ -n "$W" ] && [ "$(ultron term get "$W" --json | jq -r '.title + " " + .role')" = "uw worker" ]; check "spawn starts a worker session titled after the brief" $?
    sleep 1
    U read "$W" 20 | grep -q '^fake model=claude-haiku-5-5'; check "read shows the screen; the model reaches the agent" $?
    U read "$W" 40 | grep -q 'note.txt'; check "--attach hands the file over" $?
    U send "$W" "Answers: 1. yes
2. no" && sleep 1 && U read "$W" 5 | grep -q '^got: Answers: 1. yes 2. no *$'; check "send types one line and presses Enter" $?
    U send "$W" --keys "a,b,enter" && sleep 1 && U read "$W" 5 | grep -q '^got: ab *$'; check "send --keys presses keys" $?
    printf '# done\nstatus: done\nbrief: handoffs/briefs/2026-10-20-1200-uw.md\nagent: claude\n\n## Files\n- note.txt\n' > handoffs/hu.md
    U watch --once | grep -q 'woke Jarvis: handoff handoffs/hu.md' && sleep 1 && U read "$J" 5 | grep -q 'got: \[jarvis watch\] handoff'; check "the watcher wakes Jarvis's session" $?
    touch -t 202601010000 "$ux/old.jsonl"
    printf '{"transcript_path":"%s"}' "$ux/old.jsonl" > handoffs/.jarvis/session.json
    printf '# b\nstatus: blocked\nbrief: handoffs/briefs/x.md\n' > handoffs/hb.md
    U watch --once | grep -q 'cleared Jarvis' && ultron events --json 2>/dev/null | grep -q 'session.cleared'; check "after a long idle the watcher clears Jarvis with term clear" $?
    rm -f handoffs/hb.md
    U merge handoffs/hu.md --no-push | grep -q 'closed' && [ "$(ultron term get "$W" --json | jq -r .state)" = exited ]; check "merge closes the worker's session" $?
    ultron daemon stop --json >/dev/null 2>&1
  ) | tee "$tmp/ultron.out"
  n=$(grep -c '^  FAIL' "$tmp/ultron.out"); fails=$((fails + n))
else
  echo "ultron host: skipped (no ultron binary: put it on PATH or set ULTRON_BIN; jq needed too)"
fi

echo "jarvis lock (eval/locktest.sh)"; "$BASH" "$here/locktest.sh" 2>&1 | tee "$tmp/lock.out"; grep -q '^locktest: all passed' "$tmp/lock.out" || { n=$(grep -c '^  FAIL' "$tmp/lock.out"); fails=$((fails + (n > 0 ? n : 1))); }
echo "fable gate (eval/fabletest.sh)"; "$BASH" "$here/fabletest.sh" 2>&1 | tee "$tmp/fable.out"; grep -q '^fabletest: all passed' "$tmp/fable.out" || { n=$(grep -c '^  FAIL' "$tmp/fable.out"); fails=$((fails + (n > 0 ? n : 1))); }
echo "claude caps and band (eval/captest.sh)"; "$BASH" "$here/captest.sh" 2>&1 | tee "$tmp/cap.out"; grep -q '^captest: all passed' "$tmp/cap.out" || { n=$(grep -c '^  FAIL' "$tmp/cap.out"); fails=$((fails + (n > 0 ? n : 1))); }
echo "jarvis usage (eval/usagetest.sh)"; "$BASH" "$here/usagetest.sh" 2>&1 | tee "$tmp/usage.out"; grep -q '^usagetest: all passed' "$tmp/usage.out" || { n=$(grep -c '^  FAIL' "$tmp/usage.out"); fails=$((fails + (n > 0 ? n : 1))); }
rm -rf "$tmp"
echo; [ "$fails" = 0 ] && echo "selftest: all passed" || { echo "selftest: $fails failed"; exit 1; }
