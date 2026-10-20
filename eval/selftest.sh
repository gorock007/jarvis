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
  "agents create") n=$(grep -c 'agents create' "$FAKE_LOG"); printf '{"kind":"terminal","sessionId":"term-%s"}\n' "$n" ;;
  "terminals read") printf '{"text":"%s"}\n' "${FAKE_SCREEN:-Working… esc to interrupt}" ;;
  "terminals list") printf '{"sessions":[%s]}\n' "$(printf '%s' "${FAKE_OPEN:-}" | sed -E 's/([^ ]+)/{"terminalId":"\1","exited":false}/g; s/ /,/g')" ;;
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
    echo "{\"five_hour\":{\"used_percentage\":30,\"resets_at\":$((now + 2 * 3600))},\"ts\":$now}" > handoffs/.jarvis/usage.json
    $J band | grep -q '^green'; check "30% three hours in is green" $?
    echo "{\"five_hour\":{\"used_percentage\":80,\"resets_at\":$((now + 3600))},\"ts\":$now}" > handoffs/.jarvis/usage.json
    $J band | grep -q '^red'; check "80% is red" $?
    echo "{\"five_hour\":{\"used_percentage\":55,\"resets_at\":$((now + 3600))},\"ts\":$now}" > handoffs/.jarvis/usage.json
    sed -i.bak '/b2.md/d' handoffs/OPEN.md && rm -f handoffs/OPEN.md.bak
    $J spawn handoffs/briefs/b5.md 2>&1 | grep -q 'fable is off'; check "amber refuses a fable worker" $?

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

rm -rf "$tmp"
echo; [ "$fails" = 0 ] && echo "selftest: all passed" || { echo "selftest: $fails failed"; exit 1; }
