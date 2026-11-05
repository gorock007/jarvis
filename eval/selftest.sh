#!/usr/bin/env bash
# Offline self-test of jev.sh (fail-open paths, request shape, secret masking)
# and of bin/jarvis (spawn cap and band, merge, the idle guard, the watcher,
# the statusline tap, leftover processes, the tmux host), against a throwaway repo, a fake
# `superset` and real processes of its own, all stopped before it exits.
# No API key, no network, no cost — run it after any change to either script.
#
#   eval/selftest.sh
set -u
# One brace group ending in exit, so bash reads the whole file before running any of it:
# it reads a script as it goes, and an edit made mid-run (another worker's, in a shared
# checkout) resumes it at a stale offset, in the caller's directory, outside every `cd`.
{
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
  "agents create") [ -z "${FAKE_SPAWN_SLEEP:-}" ] || sleep "$FAKE_SPAWN_SLEEP"   # the spawn-overlap race
    [ -z "${FAKE_SPAWN_BG:-}" ] || { sleep 20 </dev/null >/dev/null 2>&1 & echo $! > "$FAKE_SPAWN_BG"; }  # a host's daemon
    n=$(( $(cat "$FAKE_LOG.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_LOG.n"
    printf '{"kind":"terminal","sessionId":"term-%s"}\n' "$n" ;;
  "terminals close") [ -z "${FAKE_CLOSE_FAIL:-}" ] || { echo "Error: terminal $6 not found" >&2; exit 1; } ;;
  "terminals read") jq -n --arg t "${FAKE_SCREEN:-Working… esc to interrupt}" '{text: $t}' ;;
  "terminals send") [ -z "${FAKE_SEND_FAIL:-}" ] || [ "$6" = jarvis-t ] ;;
  "terminals list") printf '{"sessions":[%s]}\n' "$(printf '%s' "${FAKE_OPEN:-}" | sed -E 's/([^ ]+)/{"terminalId":"\1","exited":false,"title":"shell-\1"}/g; s/ /,/g')" ;;
esac
EOT
  chmod +x "$tmp/fake/superset"
  # Make env-bash shebangs (including jarvis) use this suite's interpreter too.
  ln -s "$BASH" "$tmp/fake/bash"
  (
    cd "$sb" || exit 1
    export PATH="$tmp/fake:$PATH" FAKE_LOG="$tmp/fake.log" SUPERSET_WORKSPACE_ID=ws SUPERSET_TERMINAL_ID=jarvis-t
    unset TYPESAFE_API_KEY
    git init -q && git remote add origin "$tmp/origin.git"
    cp -R "$tpl/handoffs" . && sed -e 's/{{MAX_CLAUDE}}/3/' -e 's/{{AMBER}}/50/' -e 's/{{RED}}/75/' "$tpl/handoffs/jarvis.conf" > handoffs/jarvis.conf
    echo 'JARVIS_BATCH_SEC=0' >> handoffs/jarvis.conf   # the watcher tests below expect a send on the tick; the batch tests set their own
    echo a > app.txt && git add -A && git commit -qm init && git push -q -u origin HEAD 2>/dev/null
    J=handoffs/bin/jarvis
    mk() { printf '# %s\nworker: %s\nmodel: %s\neffort: %s\nstarted: <x> · terminal: <x>\n\n## Goal\nx\n' "$1" "$2" "$3" "$4" > "handoffs/briefs/$1.md"; }
    mk b1 claude claude-opus-5-5 high; mk b2 claude sonnet medium; mk b3 claude claude-opus-5-5 medium; mk b4 opencode "" ""; mk b5 claude fable high

    $J start >/dev/null; grep -q '^Jarvis session: jarvis-t' handoffs/OPEN.md; check "start records this terminal in OPEN.md" $?
    $J spawn handoffs/briefs/b1.md >/dev/null 2>&1 && $J spawn handoffs/briefs/b2.md >/dev/null 2>&1; check "spawns two Claude workers under the cap" $?
    grep -q 'terminal: term-1' handoffs/briefs/b1.md; check "spawn writes the terminal into the brief" $?
    grep -q -- '--model claude-opus-5-5 --effort high' "$FAKE_LOG"; check "spawn passes model and effort from the header" $?
    # Superset's launch takes no env: the worker's hooks find its brief through the run record
    (unset JARVIS_ROLE JARVIS_BRIEF; SUPERSET_TERMINAL_ID=term-1 $J hook event stop </dev/null)
    ! grep 'agents create' "$FAKE_LOG" | grep -q JARVIS_ && grep -q '"kind":"stop"' handoffs/.jarvis/events/b1.jsonl; check "spawn on Superset: the worker's hook event lands in its brief's event file" $?
    rm -rf handoffs/.jarvis/events
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
    [ "$(git show --name-only --format= HEAD | LC_ALL=C sort | tr '\n' ' ')" = "app.txt handoffs/OPEN.md handoffs/briefs/b1.md handoffs/merged/h1.md src/new.txt " ]; check "commit holds exactly the listed files, the handoff, the brief and OPEN.md" $?
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
    wl() { tail -n 1 handoffs/.jarvis/watch.log | awk -F'\t' '{print $2 " " $3 " " $4}'; } # the last wake: how, reasons, events
    [ "$(wc -l < handoffs/.jarvis/watch.log | tr -d ' ')" = 1 ] && [ "$(wl)" = "cleared handoff 1" ] \
      && tail -n 1 handoffs/.jarvis/watch.log | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z'$'\t'; check "…and logs one watch.log line: UTC time, cleared, handoff, 1 event" $?
    : > "$FAKE_LOG"; $J watch --once >/dev/null; ! grep -q 'terminals send' "$FAKE_LOG"; check "watch stays quiet when nothing changed" $?
    [ "$(wc -l < handoffs/.jarvis/watch.log | tr -d ' ')" = 1 ]; check "…and a quiet tick logs nothing" $?

    # batching: events wait JARVIS_BATCH_SEC after the first, then go out as one message
    echo 'JARVIS_BATCH_SEC=600' >> handoffs/jarvis.conf
    pend=handoffs/.jarvis/watch.pending; wn() { wc -l < handoffs/.jarvis/watch.log | tr -d ' '; }
    printf '# a\nstatus: done\n## Files\n- x\n' > handoffs/hba.md
    : > "$FAKE_LOG"; $J watch --once >/dev/null
    ! grep -q 'terminals send' "$FAKE_LOG" && grep -q 'hba.md' "$pend" && [ "$(wn)" = 1 ]; check "batch: a handoff tick sends nothing, logs nothing, leaves a pending batch" $?
    printf '# b\nstatus: blocked\n## Files\n- x\n' > handoffs/hbb.md
    $J watch --once >/dev/null
    ! grep -q 'terminals send' "$FAKE_LOG" && grep -q 'hba.md.*hbb.md' "$pend" && grep -qx 'kinds:  handoff handoff' "$pend"; check "batch: a second handoff on the next tick joins it" $?
    $J watch --once >/dev/null; [ "$(grep -o 'hba.md' "$pend" | wc -l | tr -d ' ')" = 1 ]; check "batch: an event already pending isn't added twice" $?
    sed -i.bak 's/^opened: .*/opened: 1000/' "$pend" && rm -f "$pend.bak"
    cp handoffs/OPEN.md "$tmp/OPEN.keep"; sed -i.bak '/^Jarvis session:/d' handoffs/OPEN.md && rm -f handoffs/OPEN.md.bak
    $J watch --once >/dev/null; $J watch --once >/dev/null
    ! grep -q 'terminals send' "$FAKE_LOG" && [ -f "$pend" ] && [ "$(wn)" = 2 ] && [ "$(wl)" = "nojarvis handoff 2" ]; check "batch: with no Jarvis session it survives, nojarvis logged once" $?
    cp "$tmp/OPEN.keep" handoffs/OPEN.md
    $J watch --once >/dev/null
    [ "$(grep -c 'send .*hba.md' "$FAKE_LOG")" = 1 ] && grep 'send .*hba.md' "$FAKE_LOG" | grep -q 'hbb.md' && [ ! -e "$pend" ]; check "batch: past the window one message names both handoffs, the batch is gone" $?
    [ "$(wn)" = 3 ] && wl | grep -Eqx '(woke|cleared) handoff 2'; check "…and one watch.log line: handoff, 2 events" $?
    : > "$FAKE_LOG"; $J watch --once >/dev/null; ! grep -q 'terminals send' "$FAKE_LOG" && [ "$(wn)" = 3 ]; check "…and the next quiet tick sends nothing" $?
    rm -f handoffs/hba.md handoffs/hbb.md; echo 'JARVIS_BATCH_SEC=0' >> handoffs/jarvis.conf

    export CODEX_HOME="$tmp/codex"; mk b6 codex gpt-5.6-sol high
    $J spawn handoffs/briefs/b6.md >/dev/null 2>&1; check "spawns a Codex worker" $?
    grep -qxF "[projects.\"$(pwd -P)\"]" "$CODEX_HOME/config.toml"; check "Codex spawn pre-trusts the checkout in Codex's config" $?
    $J spawn handoffs/briefs/b6.md >/dev/null 2>&1
    [ "$(grep -c '^\[projects\.' "$CODEX_HOME/config.toml")" = 1 ]; check "…once, however many Codex workers follow" $?
    echo 'JARVIS_FASTPATH=""' >> handoffs/jarvis.conf   # retain the legacy prompt/stall tests with all fast paths off
    : > "$FAKE_LOG"; FAKE_SCREEN="  Trust this folder? › 1. Yes, continue  2. No, quit" $J watch --once >/dev/null
    grep -q 'send .*waiting at a prompt' "$FAKE_LOG"; check "watch wakes Jarvis for a worker at a trust prompt" $?
    wl | grep -Eq '^(woke|cleared) prompt [1-9]'; check "…and logs the wake with reason prompt" $?
    : > "$FAKE_LOG"; FAKE_SCREEN="  Trust this folder? › 1. Yes, continue  2. No, quit" $J watch --once >/dev/null
    ! grep -q 'terminals send' "$FAKE_LOG"; check "…once per prompt" $?
    echo 'JARVIS_STALL_MIN=0' >> handoffs/jarvis.conf
    FAKE_SCREEN="frozen" $J watch --once >/dev/null; : > "$FAKE_LOG"; FAKE_SCREEN="frozen" $J watch --once >/dev/null
    grep -q "send .*screen hasn't changed" "$FAKE_LOG"; check "watch wakes Jarvis for a frozen worker with no handoff" $?
    wl | grep -Eq '^(woke|cleared) stall [1-9]'; check "…and logs the wake with reason stall" $?
    # one fake screen for every worker, so prompt and stall can't share a tick: a new
    # handoff's tick logs handoff alone, the next tick (same screen) logs stall
    printf '# t8\nstatus: done\n## Files\n- x\n' > handoffs/h8.md
    : > "$FAKE_LOG"; FAKE_SCREEN="frozen again" $J watch --once >/dev/null; FAKE_SCREEN="frozen again" $J watch --once >/dev/null
    grep -v "$(printf '\tsource\t')" handoffs/.jarvis/watch.log | tail -n 2 | awk -F'\t' '{print $3}' | grep -qx 'handoff' \
      && wl | grep -Eq '^(woke|cleared) stall [1-9]'; check "…a handoff alone logs handoff, the next frozen tick stall" $?
    rm -f handoffs/h8.md
    b4t=$(sed -n 's/.*terminal: //p' handoffs/briefs/b4.md)
    [ -n "$b4t" ] && ! grep -q "$b4t's screen" "$FAKE_LOG"; check "…but not for one that already handed off" $?

    # Fast paths use a separate throwaway checkout and the fake host above. No
    # real terminal is read or sent anything; each case has one synthetic run.
    (
      mkdir -p "$tmp/fastpaths" && cd "$tmp/fastpaths" || exit 1
      git init -q; cp -R "$tpl/handoffs" .
      mkdir -p src config .claude .git/info "$tmp/outside"
      touch src/widget.py src/private.py config/settings.py
      ln -s "$tmp/outside" src/escape
      ln -s "$(pwd -P)/src" "$tmp/outside/back"
      ln -s ../.claude src/hidden
      ln -s ../config/settings.py src/alias.py
      fp_setup() { # agent, May touch, Must not touch
        rm -rf handoffs/.jarvis; rm -f handoffs/fp-handoff.md
        mkdir -p handoffs/.jarvis/runs
        printf 'JARVIS_BATCH_SEC=0\nJARVIS_STALL_MIN=1\nJARVIS_FASTPATH="trust edit nudge"\n' > handoffs/jarvis.conf
        printf '# fast path\nworker: %s\n\n## Scope\n- May touch: %s\n- Must not touch: %s\n' "$1" "$2" "${3:-none}" > handoffs/briefs/fp.md
        printf 'brief: handoffs/briefs/fp.md\nagent: %s\nspawned: %s\nstate: running\n' "$1" "$(date +%s)" > handoffs/.jarvis/runs/fp
        printf '# Open\nJarvis session: jarvis-t\n## Running workers\n- now · %s/model · term fp · handoffs/briefs/fp.md\n' "$1" > handoffs/OPEN.md
        : > "$FAKE_LOG"
      }
      fp_tick() { : > "$FAKE_LOG"; FAKE_SCREEN="$1" $J watch --once >/dev/null; }
      # The live Claude Code 2.1.311 layout (eval/terminals/41-46), at 80 columns.
      fp_rule='────────────────────────────────────────────────────────────────────────────────'
      fp_dash='╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌'
      fp_box() { # header line or '', path row, question, raw rows before the diff, title, option 1 row
        [ -z "$1" ] || printf '%s\n\n' "$1"
        printf '%s\n %s\n %s\n%s\n' "$fp_rule" "${5:-Edit file}" "$2" "$fp_dash"
        [ -z "${4:-}" ] || printf '%s\n' "$4"
        printf ' 1 -old = 1\n 1 +new = 1\n%s\n %s\n%s\n' "$fp_dash" "$3" "${6:- ❯ 1. Yes}"
        printf '   2. Yes, and switch to accept edits (auto-approve file edits and common file\n      commands) for this session (shift+tab)\n   3. No\n\n Esc to cancel · Tab to amend\n'
      }
      fp_edit() { fp_box "⏺ Update($1)" "$1" "Do you want to make this edit to ${2:-${1##*/}}?"; }
      fp_cap() { cat "$here/terminals/$1"-*.txt; }
      # The live Codex 0.157.1 trust screen (eval/terminals/47-48); $1 replaces the folder rows.
      fp_trust() {
        printf '\n  Folder access\n%s\n\n' "${1:-  $(pwd -P)}"
        printf '  Trust this folder? Codex can read, edit, and run files here, subject to your permission\n'
        printf '  settings. Folder settings can run code automatically, even without a model request. Continue\n'
        printf '  only if you trust these files. Your trust decision will be saved.\n\n%s\n  2. Quit\n\n  enter continue · esc quit\n' "${2:-› 1. Trust and continue}"
      }
      fp_woke() { grep -q 'terminal jarvis-t --text .*waiting at a prompt' "$FAKE_LOG" && ! grep -q -- '--keys' "$FAKE_LOG"; }
      fp_approved() { grep -q 'terminal fp --keys enter$' "$FAKE_LOG" && ! grep -q 'terminal jarvis-t --text' "$FAKE_LOG" && [ ! -f handoffs/.jarvis/watch.pending ]; }
      fp_age() { touch -t "$(date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$1" +%Y%m%d%H%M.%S)" handoffs/.jarvis/screen-fp; }
      fp_nudged() { sed -i.bak '/^nudged:/d' handoffs/.jarvis/runs/fp; rm -f handoffs/.jarvis/runs/fp.bak; printf 'nudged: %s\n' "$1" >> handoffs/.jarvis/runs/fp; }

      fp_setup claude '`src/widget.py`, `config/settings.py`'
      fp_tick "$(fp_edit src/widget.py)"
      fp_approved && [ "$(wl)" = 'auto edit 1' ] && grep -q 'auto-edit run=fp brief=handoffs/briefs/fp.md path=src/widget.py key=enter result=sent' handoffs/.jarvis/audit.log
      check "fast edit: in-scope file gets single-edit Yes, both logs, no wake or pending batch" $?
      grep -q 'terminal fp --max-lines 80' "$FAKE_LOG"; check "fast edit: reads enough lines for the header above a full diff" $?
      fp_tick "$(fp_edit src/widget.py)"
      grep -q 'terminal jarvis-t --text .*waiting at a prompt (the automatic answer did not take)' "$FAKE_LOG" && ! grep -q -- '--keys' "$FAKE_LOG" \
        && [ "$(wl)" = 'woke prompt 1' ]; check "fast edit: the same prompt one tick after the answer wakes Jarvis, never re-sent" $?
      fp_tick "$(fp_edit src/widget.py)"; ! grep -q 'terminals send' "$FAKE_LOG"; check "fast edit: …and only once" $?

      fp_setup claude '`src/`'
      echo 'JARVIS_BATCH_SEC=600' >> handoffs/jarvis.conf
      fp_tick "$(fp_edit src/new.py)"; fp_approved; check "fast edit: a new file inside a listed directory is approved immediately, outside batching" $?
      fp_setup claude '`src/`'; fp_tick "$(fp_box '⏺ Write(src/new.py)' src/new.py 'Do you want to create new.py?' '' 'Create file')"
      fp_approved; check "fast edit: recognizes a Write header on a Create-file dialog" $?
      fp_setup claude '`src/`'; fp_tick "$(fp_box '' src/new.py 'Do you want to make this edit to new.py?')"
      fp_approved; check "fast edit: a dialog whose header scrolled off uses the row under its title" $?
      # Live captures (eval/terminals/41-48): Claude Code 2.1.311 and Codex 0.157.1.
      for c in 41 43 44 46 49; do
        fp_setup claude '`src/`'; fp_tick "$(fp_cap $c)"
        case $c in 43) f=helpers ;; 49) f=long ;; *) f=widget ;; esac
        fp_approved && grep -q "path=src/$f.py key=enter" handoffs/.jarvis/audit.log
        check "fast edit: live capture $c is approved for the file it names" $?
      done
      fp_setup claude '`src/widget.py`'; fp_tick "$(fp_cap 43)"; fp_woke; check "fast edit: live Create capture for an unlisted file wakes Jarvis" $?
      fp_setup claude '`src/`' '`src/widget.py`'; fp_tick "$(fp_cap 41)"; fp_woke; check "fast edit: live Edit capture of an excluded file wakes Jarvis" $?
      fp_setup claude '`src/`'; fp_tick "$(fp_cap 42)"; fp_woke; check "fast edit: live capture with a shortened …path wakes Jarvis" $?
      fp_setup claude '`src/`'; fp_tick "$(fp_cap 45)"; fp_woke; check "fast edit: live Bash command capture wakes Jarvis" $?
      # Claude Code's own folder trust (eval/terminals/50): never answered, even for the checkout itself.
      for a in claude codex; do
        fp_setup "$a" '`src/`'; fp_tick "$(fp_cap 50)"; fp_woke; check "fast trust: live Claude folder-trust capture wakes Jarvis ($a)" $?
      done
      fp_setup claude '`src/`'; fp_tick "$(fp_cap 50 | awk -v p=" $(pwd -P)" 'NR == 5 {print p; next} NR == 6 {next} {print}')"
      fp_woke; check "fast trust: Claude folder trust naming the checkout still wakes Jarvis" $?
      fp_setup claude '`src/`'; fp_tick "$(fp_cap 50 | grep -v 'trust this folder')"
      fp_woke; check "fast trust: Claude folder trust is seen by its question alone" $?
      fp_setup claude '`src/`'; fp_tick "$(fp_cap 44 | sed 's/⏺ Write(/⏺ Update(/')"; fp_woke; check "fast edit: an Update header over an Overwrite dialog wakes Jarvis" $?
      fp_setup claude '`src/`'; fp_tick "$(fp_box '⏺ Update(src/new.py)' src/new.py 'Do you want to create new.py?' '' 'Create file')"
      fp_woke; check "fast edit: an Update header over a Create dialog wakes Jarvis" $?
      fp_setup claude '`src/`'; fp_tick "$(fp_box '⏺ Update(src/new.py)' src/new.py 'Do you want to create new.py?')"
      fp_woke; check "fast edit: a question that doesn't match the title wakes Jarvis" $?
      fp_setup claude '`src/`'
      fp_tick "$(sed 's#config/settings\.py#src/widget.py#; s#settings\.py#widget.py#' "$here/terminals/20-permission-claude-edit-settings-file.txt")"
      fp_woke; check "fast edit: the hand-written boxed layout (fixture 20, retargeted to src/) is no longer accepted" $?
      fp_setup claude '`src/`'; fp_tick "$(fp_box '⏺ Update(src/widget.py)' src/widget.py 'Do you want to make this edit to widget.py?' '' '' ' ❯ 1. Yes, allow all edits during this session')"
      fp_woke; check "fast edit: an allow-all first option wakes Jarvis" $?
      fp_setup claude '`src/`'; fp_tick "$(fp_edit src/widget.py | sed 's/switch to accept edits/allow all edits/')"
      fp_woke; check "fast edit: an unknown second option wakes Jarvis" $?
      fp_setup claude '`src/`'; fp_tick "$(fp_edit src/widget.py | sed 's/^ ❯ 1\. Yes$/   1. Yes/; s/^   3\. No$/ ❯ 3. No/')"
      fp_woke; check "fast edit: Yes not highlighted wakes Jarvis" $?
      fp_setup claude '`src/`'; fp_tick "$(fp_edit src/widget.py | sed 's/^ src\/widget\.py$/ src\/widget.py\
 src\/other.py/')"
      fp_woke; check "fast edit: an extra row between title and diff wakes Jarvis" $?
      fp_setup claude '`src/`'; fp_tick "$(fp_edit src/widget.py | sed '1,5d')"
      fp_woke; check "fast edit: a dialog whose title scrolled off wakes Jarvis" $?
      fp_setup claude '`src/`'; fp_tick "$(fp_edit src/widget.py | sed 's/^\( 1 +new = 1\)$/\1\
 continued text/')"
      fp_woke; check "fast edit: an unnumbered diff row with less than a wrap indent wakes Jarvis" $?
      fp_setup claude '`src/`'; fp_tick 'Edit file: src/new.py
Do you want to make this edit to new.py?
❯ 1. Yes'; fp_woke; check "fast edit: a prompt outside an Edit-file dialog wakes Jarvis" $?
      fp_setup claude '`src/`'
      fp_tick "$(fp_edit "$(pwd -P)/src/widget.py")"; fp_approved; check "fast edit: absolute path inside the checkout is allowed" $?
      for path in other.py src/../src/widget.py .claude/rules.md .git/info/exclude config/settings.py config/settings.local.json config/.env.local config/server.pem config/server.key config/jarvis.conf handoffs/OPEN.md src/escape/new.py src/escape/back/widget.py src/hidden/new.py src/alias.py "$tmp/outside/new.py"; do
        fp_setup claude '`src/`, `.claude/`, `.git/`, `config/`, `handoffs/`'
        fp_tick "$(fp_edit "$path")"
        fp_woke; check "fast edit: excluded or out-of-scope $path wakes Jarvis" $?
      done
      fp_setup claude '`src/`' '`src/widget.py`'
      fp_tick "$(fp_edit src/widget.py)"; fp_woke; check "fast edit: exact Must not touch wins" $?
      fp_setup claude '`src/`' '`src/`'
      fp_tick "$(fp_edit src/widget.py)"; fp_woke; check "fast edit: directory Must not touch wins" $?
      fp_setup claude '`src/widget.py`'
      fp_tick "$(fp_edit src/widget.py other.py)"; fp_woke; check "fast edit: basename mismatch wakes Jarvis" $?
      fp_setup claude '`src/widget.py`'
      fp_tick 'Do you want to make this edit to widget.py?
❯ 1. Yes'; fp_woke; check "fast edit: truncated path header wakes Jarvis" $?
      fp_setup claude '`src/`'
      fp_tick "$(fp_box '⏺ Update(src/widget.py)' src/private.py 'Do you want to make this edit to private.py?')"; fp_woke; check "fast edit: conflicting headers wake Jarvis" $?
      fp_setup claude '`src/`'
      fp_tick '⏺ Update(src/widget.py)
⏺ Bash(echo hello)
Do you want to proceed?
❯ 1. Yes'; fp_woke; check "fast edit: Bash approval wakes Jarvis" $?
      for agent in codex opencode; do
        fp_setup "$agent" '`src/`'; fp_tick "$(fp_edit src/widget.py)"; fp_woke; check "fast edit: never answers a $agent edit prompt" $?
      done
      fp_setup claude '`handoffs/fp-handoff.md`'
      printf '# phase\nstatus: blocked\nbrief: handoffs/briefs/fp.md\n' > handoffs/fp-handoff.md
      # Learn the handoff before presenting its edit prompt.
      fp_tick working
      fp_tick "$(fp_edit handoffs/fp-handoff.md)"; fp_approved; check "fast edit: explicitly listed, identified handoff from this run is allowed" $?
      fp_setup claude '`src/`'
      FAKE_SEND_FAIL=1 fp_tick "$(fp_edit src/widget.py)"
      grep -q 'terminal jarvis-t --text .*waiting at a prompt' "$FAKE_LOG" && ! grep -q 'auto' handoffs/.jarvis/watch.log \
        && [ ! -f handoffs/.jarvis/audit.log ]; check "fast edit: failed key send falls back to Jarvis without an auto log" $?
      fp_setup claude '`src/`'
      echo '- May touch: `src/`' >> handoffs/briefs/fp.md
      fp_tick "$(fp_edit src/widget.py)"; fp_woke; check "fast edit: ambiguous scope lists fail closed" $?
      # Review of ad5b044, finding 1: diff text inside the dialog must never name the file.
      q='Do you want to make this edit to foo.sh?'
      fp_setup claude '`src/`' '`scripts/foo.sh`'
      fp_tick "$(fp_box '⏺ Update(scripts/foo.sh)' scripts/foo.sh "$q" '⏺ Update(src/foo.sh)')"
      fp_woke; check "fast edit: a diff row reading ⏺ Update(src/foo.sh) can't redirect a scripts/foo.sh edit" $?
      fp_setup claude '`src/`' '`scripts/foo.sh`'
      fp_tick "$(fp_box '⏺ Update(scripts/foo.sh)' scripts/foo.sh "$q" ' 3 +⏺ Update(src/foo.sh)')"
      fp_woke; check "fast edit: a numbered diff row carrying a tool header fails closed" $?
      fp_setup claude '`src/`' '`scripts/foo.sh`'
      fp_tick "$(fp_box '⏺ Update(scripts/foo.sh)' scripts/foo.sh "$q" "⏺ Update(src/foo.sh)

$fp_rule
 Edit file
 src/foo.sh
$fp_dash")"
      fp_woke; check "fast edit: a second dialog staged inside the real one's diff fails closed" $?
      fp_setup claude '`src/`' '`scripts/foo.sh`'
      fp_tick "$(fp_box '⏺ Update(scripts/foo.sh)' scripts/foo.sh "$q" "$(printf ' %s +x\n' 3 4 5 6)
$fp_dash
 Do you want to make this edit to foo.sh?
 ❯ 1. Yes")"
      fp_woke; check "fast edit: a question and Yes staged in the diff fail closed" $?
      fp_setup claude '`src/`'; fp_tick "$(fp_edit src/widget.py)
  some text below the dialog"
      fp_woke; check "fast edit: text after the dialog fails closed" $?
      # Finding 2: case variants (and hard links) of exclusions stay excluded on any filesystem.
      touch src/secret.py; ln -f src/private.py src/hard.py
      fp_setup claude '`src/`' '`src/secret.py`'
      fp_tick "$(fp_edit src/Secret.py)"; fp_woke; check "fast edit: src/Secret.py is excluded by Must not touch src/secret.py" $?
      fp_setup claude '`src/`' '`SRC/`'
      fp_tick "$(fp_edit src/widget.py)"; fp_woke; check "fast edit: a directory exclusion matches regardless of case" $?
      fp_setup claude '`src/widget.py`'
      fp_tick "$(fp_edit src/Widget.py)"; fp_woke; check "fast edit: an allow entry that differs only by case grants nothing" $?
      fp_setup claude '`src/`' '`src/private.py`'
      fp_tick "$(fp_edit src/hard.py)"; fp_woke; check "fast edit: a hard link to an excluded file is excluded" $?
      rm -f src/secret.py src/hard.py
      # Scope entries written as prose around one backticked path.
      fp_setup claude '`src/`' 'root `handoffs/`, `README.md`'
      fp_tick "$(fp_edit src/widget.py)"; fp_approved; check "fast edit: Must not touch root \`handoffs/\` reads as handoffs/, not a denial" $?
      fp_setup claude '`src/`' 'anything in `src/private.py`'
      fp_tick "$(fp_edit src/private.py)"; fp_woke; check "fast edit: a prose exclusion still excludes its backticked path" $?
      fp_setup claude '`src/`' 'root handoffs'
      fp_tick "$(fp_edit src/widget.py)"; fp_woke; check "fast edit: an entry with spaces and no backticks fails closed" $?
      fp_setup claude '`src/`' '`src/a.py` or `src/b.py`'
      fp_tick "$(fp_edit src/widget.py)"; fp_woke; check "fast edit: an entry with two backticked paths fails closed" $?
      fp_setup claude '`src/widget.py`, new files in `src/`'
      fp_tick "$(fp_edit src/widget.py)"; fp_approved; check "fast edit: a plain grant still works next to a prose one" $?
      fp_setup claude '`src/widget.py`, new files in `src/`'
      fp_tick "$(fp_edit src/private.py)"; fp_woke; check "fast edit: a prose grant (new files in \`src/\`) grants nothing" $?
      # Finding 3: the checker runs isolated, so modules planted in the checkout never load.
      printf 'open(%s, "w").close()\nraise SystemExit(0)\n' "'$tmp/planted'" > re.py
      fp_setup claude '`src/`'; fp_tick "$(fp_edit src/widget.py)"
      fp_approved && [ ! -e "$tmp/planted" ]; check "fast edit: a planted re.py in the checkout is not imported" $?
      rm -f re.py

      trust=$(fp_trust)
      fp_setup codex '`src/`'; fp_tick "$trust"
      fp_approved && [ "$(wl)" = 'auto trust 1' ] && grep -q 'auto-trust run=fp brief=handoffs/briefs/fp.md path=trust key=enter result=sent' handoffs/.jarvis/audit.log
      check "fast trust: Codex gets Trust and continue, both logs, no Jarvis wake" $?
      fp_tick "$trust"; fp_woke && grep -q 'did not take' "$FAKE_LOG"; check "fast trust: unchanged prompt is not answered twice, it wakes Jarvis" $?
      fp_setup codex '`src/`'; FAKE_SEND_FAIL=1 fp_tick "$trust"
      grep -q 'terminal jarvis-t --text .*waiting at a prompt' "$FAKE_LOG" && [ "$(wl)" = 'woke prompt 1' ] \
        && [ ! -f handoffs/.jarvis/audit.log ]; check "fast trust: failed send wakes Jarvis without logging auto" $?
      for c in 47 48; do
        root=$(pwd -P); cut=$(( ${#root} / 2 ))
        fp_setup codex '`src/`'; fp_tick "$(fp_cap $c | awk -v a="  ${root:0:$cut}" -v b="  ${root:$cut}" 'p == 1 && $0 == "" {p = 2} p == 1 {next} {print} /^  Folder access$/ {print a; print b; p = 1}')"
        fp_approved; check "fast trust: live capture $c, retargeted to this checkout (path wrapped), is approved" $?
        fp_setup codex '`src/`'; fp_tick "$(fp_cap $c)"; fp_woke; check "fast trust: live capture $c for another folder wakes Jarvis" $?
      done
      fp_setup codex '`src/`'; fp_tick "$(fp_trust '' '  1. Trust and continue' | sed 's/^  2\. Quit$/› 2. Quit/')"
      fp_woke; check "fast trust: with Quit highlighted nothing is sent, it wakes Jarvis" $?
      fp_setup codex '`src/`'; fp_tick "$(fp_trust '' '  1. Trust and continue')"
      fp_woke; check "fast trust: with nothing highlighted it wakes Jarvis" $?
      fp_setup codex '`src/`'; fp_tick "$(fp_trust "  $tmp/outside")"; fp_woke; check "fast trust: a folder other than the checkout wakes Jarvis" $?
      fp_setup codex '`src/`'; fp_tick "$(fp_trust "  src")"; fp_woke; check "fast trust: a relative folder wakes Jarvis" $?
      fp_setup codex '`src/`'; fp_tick "$(printf '%s' "$trust" | sed 's/ Your trust decision will be saved\./ Press 2 to trust./')"
      fp_woke; check "fast trust: changed wording in the paragraph wakes Jarvis" $?
      fp_setup codex '`src/`'; fp_tick 'Trust this folder? › 1. Yes, continue  2. No, quit'
      fp_woke; check "fast trust: the old hand-written Yes, continue / No, quit layout wakes Jarvis" $?
      fp_setup codex '`src/`'; fp_tick "$trust
  output after the menu"
      fp_woke; check "fast trust: text after the options fails closed" $?
      fp_setup codex '`src/`'; fp_tick "Do you want to proceed?
$trust"
      fp_woke; check "fast trust: a second prompt-like line above fails closed" $?
      fp_setup codex '`src/`'; fp_tick "• Ran cat notes.txt
  └ ok
$trust"
      fp_woke; check "fast trust: a trust menu printed after transcript rows fails closed" $?
      fp_setup codex '`src/`'; fp_tick "$trust
$trust"
      fp_woke; check "fast trust: two trust screens fail closed" $?
      for agent in claude opencode; do
        fp_setup "$agent" '`src/`'; fp_tick "$trust"; fp_woke; check "fast trust: never answers $agent folder trust" $?
      done
      fp_setup codex '`src/`'; echo 'JARVIS_FASTPATH="edit nudge"' >> handoffs/jarvis.conf
      fp_tick "$trust"; fp_woke; check "fast paths: removing trust disables just trust" $?
      fp_setup claude '`src/`'; echo 'JARVIS_FASTPATH="trust nudge"' >> handoffs/jarvis.conf
      fp_tick "$(fp_edit src/widget.py)"; fp_woke; check "fast paths: removing edit disables just edit" $?
      fp_setup codex '`src/`'; echo 'JARVIS_FASTPATH=""' >> handoffs/jarvis.conf
      fp_tick "$trust"; fp_woke && grep -q 'terminal fp --max-lines 15' "$FAKE_LOG"; check "fast paths: empty restores prompt wake and the original tail size" $?
      fp_tick frozen; fp_age $(( $(date +%s) - 120 )); fp_tick frozen
      grep -q "terminal jarvis-t --text .*screen hasn't changed" "$FAKE_LOG" && ! grep -q '^nudged:' handoffs/.jarvis/runs/fp; check "fast paths: empty restores immediate stall wake" $?
      fp_setup claude '`src/`'; echo 'JARVIS_FASTPATH="trust edit"' >> handoffs/jarvis.conf
      fp_tick frozen; fp_age $(( $(date +%s) - 120 )); fp_tick frozen
      grep -q "terminal jarvis-t --text .*screen hasn't changed" "$FAKE_LOG" && ! grep -q '^nudged:' handoffs/.jarvis/runs/fp; check "fast paths: removing nudge disables just nudge" $?

      fp_setup codex '`src/`'; fp_tick frozen
      fp_age $(( $(date +%s) - 120 )); fp_tick frozen
      grep -q 'terminal fp --text Finish the phase or write your handoff now.' "$FAKE_LOG" && ! grep -q 'terminal jarvis-t --text' "$FAKE_LOG" \
        && grep -Eq '^nudged: [0-9]+$' handoffs/.jarvis/runs/fp && [ "$(wl)" = 'auto nudge 1' ] \
        && grep -q 'auto-nudge run=fp brief=handoffs/briefs/fp.md prompt=stall key=enter result=sent' handoffs/.jarvis/audit.log \
        && [ ! -f handoffs/.jarvis/watch.pending ]; check "fast nudge: first stall nudges once, records the epoch and both logs, no batch" $?
      fp_tick frozen; ! grep -q 'terminals send' "$FAKE_LOG"; check "fast nudge: no wake during the second interval" $?
      fp_nudged $(( $(date +%s) - 120 )); fp_tick frozen
      grep -q "terminal jarvis-t --text .*screen hasn't changed" "$FAKE_LOG" && [ "$(wl)" = 'woke stall 1' ]; check "fast nudge: still frozen after the second interval wakes Jarvis" $?
      fp_tick frozen; ! grep -q 'terminals send' "$FAKE_LOG"; check "fast nudge: the same stall wake is deduplicated" $?
      fp_tick 'new frozen screen'; fp_age $(( $(date +%s) - 120 )); fp_tick 'new frozen screen'
      grep -q "terminal jarvis-t --text .*screen hasn't changed" "$FAKE_LOG" && [ "$(grep -c 'auto-nudge' handoffs/.jarvis/audit.log)" = 1 ]; check "fast nudge: a different frozen screen wakes without a second nudge" $?
      fp_setup claude '`src/`'; fp_tick frozen; fp_age $(( $(date +%s) - 120 ))
      FAKE_SEND_FAIL=1 fp_tick frozen
      grep -q "terminal jarvis-t --text .*screen hasn't changed" "$FAKE_LOG" && ! grep -q '^nudged:' handoffs/.jarvis/runs/fp \
        && [ "$(wl)" = 'woke stall 1' ]; check "fast nudge: failed send wakes Jarvis without recording a nudge" $?
      fp_setup claude '`src/`'; fp_tick frozen; fp_age $(( $(date +%s) - 120 )); fp_tick frozen
      printf '# phase\nstatus: done\nbrief: handoffs/briefs/fp.md\n' > handoffs/fp-handoff.md
      fp_nudged $(( $(date +%s) - 120 )); fp_tick frozen
      ! grep -q 'Finish the phase\|screen hasn' "$FAKE_LOG" && [ "$(wl)" = 'woke handoff 1' ]; check "fast nudge: handoff after the nudge suppresses the stall wake" $?

      count=0
      for fixture in "$here"/terminals/[0-3][0-9]-*.txt "$here"/terminals/40-*.txt; do
        name=${fixture##*/}
        case "$name" in *-claude-*) agent=claude ;; *-codex-*) agent=codex ;; *-opencode-*) agent=opencode ;; *) bad "fixture has no agent label: $name"; continue ;; esac
        fp_setup "$agent" '`src/`, `config/settings.py`, `app/`, `tests/`, `pages/`'
        fp_tick "$(cat "$fixture")"
        ! grep -q -- '--keys' "$FAKE_LOG" && ! grep -q 'auto' handoffs/.jarvis/watch.log 2>/dev/null
        check "fast fixture: $name does not qualify for automatic approval" $?
        case "$name" in 19-*|20-*|21-*|22-*|23-*|24-*) fp_woke; check "fast fixture: $name wakes Jarvis at its permission prompt" $? ;; esac
        count=$((count + 1))
      done
      if [ "$count" = 40 ]; then ok "fast fixtures: replayed all 40 labelled terminal tails"; else bad "fast fixtures: expected 40 tails, got $count"; fi
      count=0
      for fixture in "$here"/terminals/4[1-9]-*.txt "$here"/terminals/50-*.txt; do
        name=${fixture##*/}
        case "$name" in *-claude-*) agent=claude ;; *-codex-*) agent=codex ;; *) bad "capture has no agent label: $name"; continue ;; esac
        fp_setup "$agent" '`src/`'; echo 'JARVIS_FASTPATH=""' >> handoffs/jarvis.conf
        fp_tick "$(cat "$fixture")"; fp_woke; check "fast fixture: live capture $name wakes Jarvis with the fast paths off" $?
        count=$((count + 1))
      done
      if [ "$count" = 10 ]; then ok "fast fixtures: replayed all 10 live captures"; else bad "fast fixtures: expected 10 live captures, got $count"; fi
    )

    # Worker hook events (jarvis hook event) and the watcher reading them before the
    # screen: a throwaway checkout of its own and the fake host above. Each watcher case
    # has one synthetic run (term ev) whose event lines are written by hand.
    (
      mkdir -p "$tmp/events" "$tmp/nojq" && cd "$tmp/events" || exit 1
      git init -q; cp -R "$tpl/handoffs" .
      unset JARVIS_ROLE JARVIS_BRIEF ULTRON_SESSION_ID
      exec </dev/null   # stop, notification and ended read stdin: never the caller's, which may stay open
      for c in git awk sed head tail tr cut date mkdir cat; do ln -s "$(command -v "$c")" "$tmp/nojq/$c"; done
      evf=handoffs/.jarvis/events/ev.jsonl
      W() { JARVIS_ROLE=worker JARVIS_BRIEF=handoffs/briefs/ev.md JARVIS_RUN=%7 "$BASH" handoffs/bin/jarvis hook event "$@"; }
      evn() { cat "$evf" 2>/dev/null | wc -l | tr -d ' '; }
      evlast() { tail -n 1 "$evf" 2>/dev/null | grep -Eqx "[{]\"t\":[0-9]+,\"kind\":\"$1\",\"run\":\"%7\",\"detail\":\"$2\"[}]"; } # kind, detail

      out=$("$BASH" handoffs/bin/jarvis hook event working </dev/null 2>&1); rc=$?
      [ $rc = 0 ] && [ -z "$out" ] && [ ! -e handoffs/.jarvis/events ]; check "hook event: no worker env, in Jarvis's terminal (no run record): nothing, silent, exit 0" $?
      out=$(JARVIS_ROLE=worker "$BASH" handoffs/bin/jarvis hook event stop 2>&1; JARVIS_BRIEF=handoffs/briefs/ev.md "$BASH" handoffs/bin/jarvis hook event stop 2>&1)
      [ -z "$out" ] && [ ! -e handoffs/.jarvis/events ]; check "hook event: JARVIS_ROLE or JARVIS_BRIEF alone does nothing" $?
      # payloads shaped like Claude Code 2.1.311's (p3b's eval/hook-payloads), inline
      ups='{"session_id":"s","transcript_path":"/t.jsonl","cwd":"/c","permission_mode":"bypassPermissions","hook_event_name":"UserPromptSubmit","prompt":"do it"}'
      for k in working permission waiting; do
        n=$(evn); out=$(printf '%s' "$ups" | W "$k" 2>&1); rc=$?
        [ $rc = 0 ] && [ -z "$out" ] && [ "$(evn)" = $((n + 1)) ] && evlast "$k" ""; check "hook event $k: exit 0, silent, one line {t, kind $k, empty detail}" $?
      done
      xs=$(printf '%0250d' 0 | tr 0 x)
      stp='{"session_id":"s","transcript_path":"/t.jsonl","cwd":"/c","permission_mode":"bypassPermissions","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"Done: \"ok\" in a\\b\nnext line '"$xs"'"}'
      want=$(printf 'Done: "ok" in a\\b next line %s' "$xs"); want=${want:0:200}
      for p in "$PATH" "$tmp/nojq"; do
        n=$(evn); out=$(printf '%s\n' "$stp" | PATH="$p" W stop 2>&1); rc=$?
        [ $rc = 0 ] && [ -z "$out" ] && [ "$(evn)" = $((n + 1)) ] && [ "$(tail -n 1 "$evf" | jq -r 'select(.kind == "stop") | .detail')" = "$want" ]
        check "hook event stop: its last_assistant_message, one line, 200 chars, as the detail ($( [ "$p" = "$PATH" ] && echo jq || echo 'no jq'))" $?
      done
      n=$(evn); out=$(W stop </dev/null 2>&1); rc=$?
      [ $rc = 0 ] && [ -z "$out" ] && [ "$(evn)" = $((n + 1)) ] && evlast stop ""; check "hook event stop: no message, an empty detail" $?
      for r in '' 'a"b' '../x' 'a b' .; do JARVIS_RUN=$r JARVIS_ROLE=worker JARVIS_BRIEF=handoffs/briefs/ev.md "$BASH" handoffs/bin/jarvis hook event working; done
      [ "$(tail -n 5 "$evf" | jq -r '.run' | tr '\n' ,)" = ',,,,,' ]; check "hook event: no JARVIS_RUN, or one outside the run-id charset: an empty run (the line counts for no run)" $?
      for c in 'prompt_input_exit prompt_input_exit' 'logout logout' 'other other' 'clear -' 'resume -'; do
        set -- $c
        for p in "$PATH" "$tmp/nojq"; do
          n=$(evn); out=$(printf '{"session_id":"s","transcript_path":"/t.jsonl","cwd":"/c","hook_event_name":"SessionEnd","reason":"%s"}' "$1" | PATH="$p" W ended 2>&1); rc=$?
          if [ "$2" = - ]; then [ $rc = 0 ] && [ -z "$out" ] && [ "$(evn)" = "$n" ]
          else [ $rc = 0 ] && [ -z "$out" ] && [ "$(evn)" = $((n + 1)) ] && evlast ended "$1"; fi
          check "hook event ended: reason $1 → $( [ "$2" = - ] && echo 'no event (the terminal goes on)' || echo "ended, detail $1") ($( [ "$p" = "$PATH" ] && echo jq || echo 'no jq'))" $?
        done
      done
      echo '{"session_id":"s","hook_event_name":"SessionEnd"}' | W ended; evlast ended ""; check "hook event ended: no reason → ended, empty detail" $?
      for c in 'permission_prompt permission' 'idle_prompt waiting' 'agent_needs_input waiting' 'elicitation_dialog waiting' 'elicitation_url_dialog waiting' \
               'auth_success -' 'elicitation_complete -' 'elicitation_response -' 'agent_completed -' 'quota_auto_resume_scheduled -' 'plugin_notification -' 'brand_new_type -'; do
        set -- $c
        for p in "$PATH" "$tmp/nojq"; do
          n=$(evn)
          printf '{\n  "session_id": "s",\n  "hook_event_name": "Notification",\n  "message": "m",\n  "notification_type": "%s"\n}\n' "$1" | PATH="$p" W notification >/dev/null 2>&1
          if [ "$2" = - ]; then [ "$(evn)" = "$n" ]; else [ "$(evn)" = $((n + 1)) ] && evlast "$2" "$1"; fi
          check "hook event notification: $1 → $( [ "$2" = - ] && echo 'no event' || echo "$2") ($( [ "$p" = "$PATH" ] && echo jq || echo 'no jq'))" $?
        done
      done
      n=$(evn); echo 'not json {"' | W notification >/dev/null 2>&1; echo '{"message":"m"}' | W notification >/dev/null 2>&1
      [ "$(evn)" = "$n" ]; check "hook event notification: bad JSON or no type → no event" $?
      jq -c . "$evf" >/dev/null 2>&1 && [ "$(jq -s length "$evf")" = "$(evn)" ]; check "…and every line written parses as JSON" $?
      n=$(evn); out=$(W stop <&- 2>&1; W notification <&- 2>&1); rc=$?
      [ $rc = 0 ] && [ -z "$out" ] && [ "$(evn)" = $((n + 1)) ] && evlast stop ""; check "hook event: no stdin at all: stop still writes, notification doesn't, exit 0" $?
      n=$(evn); out=$(W bogus 2>&1; W 2>&1); rc=$?
      [ $rc = 0 ] && [ -z "$out" ] && [ "$(evn)" = "$n" ]; check "hook event: an unknown or missing kind does nothing, exit 0" $?
      chmod 500 handoffs/.jarvis/events
      out=$(JARVIS_ROLE=worker JARVIS_BRIEF=handoffs/briefs/ro.md "$BASH" handoffs/bin/jarvis hook event stop 2>&1); rc=$?
      chmod 700 handoffs/.jarvis/events
      [ $rc = 0 ] && [ -z "$out" ] && [ ! -e handoffs/.jarvis/events/ro.jsonl ]; check "hook event: an unwritable events dir: silent, exit 0" $?
      chmod 400 "$evf"; out=$(W stop 2>&1); rc=$?; chmod 600 "$evf"
      [ $rc = 0 ] && [ -z "$out" ] && [ "$(evn)" = "$n" ]; check "hook event: an unwritable event file: silent, exit 0" $?
      out=$(mkdir -p "$tmp/rodir/handoffs" && chmod 500 "$tmp/rodir/handoffs" && cd "$tmp/rodir" && CLAUDE_PROJECT_DIR="$tmp/rodir" JARVIS_ROLE=worker JARVIS_BRIEF=x.md "$BASH" "$tmp/events/handoffs/bin/jarvis" hook event stop 2>&1); rc=$?
      chmod 700 "$tmp/rodir/handoffs"; [ $rc = 0 ] && [ -z "$out" ] && [ ! -e "$tmp/rodir/handoffs/.jarvis" ]; check "hook event: a checkout where handoffs/.jarvis can't be made: silent, exit 0" $?
      out=$(cd "$tmp" && JARVIS_ROLE=worker JARVIS_BRIEF=x.md "$BASH" "$tmp/events/handoffs/bin/jarvis" hook event stop 2>&1); rc=$?
      [ $rc = 0 ] && [ -z "$out" ]; check "hook event: outside any checkout: silent, exit 0" $?
      (cd / && CLAUDE_PROJECT_DIR="$tmp/events" JARVIS_ROLE=worker JARVIS_BRIEF=handoffs/briefs/ev2.md "$BASH" "$tmp/events/handoffs/bin/jarvis" hook event stop)
      grep -q '"kind":"stop"' handoffs/.jarvis/events/ev2.jsonl; check "hook event: the checkout comes from CLAUDE_PROJECT_DIR" $?
      mkdir -p handoffs/bin/hosts
      printf 'touch "%s/conf-loaded"\nJARVIS_HOST=probe\n' "$tmp" > handoffs/jarvis.conf
      printf 'touch "%s/host-loaded"\n' "$tmp" > handoffs/bin/hosts/probe.sh
      W working; evlast working "" && [ ! -e "$tmp/conf-loaded" ] && [ ! -e "$tmp/host-loaded" ]; check "hook event: the fast path loads no config and no host" $?
      echo '{}' | "$BASH" handoffs/bin/jarvis hook prompt >/dev/null 2>&1; [ -e "$tmp/conf-loaded" ] && [ -e "$tmp/host-loaded" ]; check "…while hook prompt loads both (the probe works)" $?
      rm -rf handoffs/bin/hosts "$tmp/conf-loaded" "$tmp/host-loaded"
      # Superset and Ultron launch the agent themselves: the hook finds a worker's brief in
      # the run record named after its terminal
      rec() { printf 'run: %s\nbrief: handoffs/briefs/%s.md\nagent: %s\nspawned: 1\nstate: %s\n' "$1" "$2" "$3" "$4" > "handoffs/.jarvis/runs/$1"; }
      mkdir -p handoffs/.jarvis/runs
      rec term-s sf claude running; rec term-c sc codex running; rec term-m sm claude merged; rec s_u1 su claude running
      SUPERSET_TERMINAL_ID=term-s "$BASH" handoffs/bin/jarvis hook event stop
      [ "$(grep -c '"kind":"stop","run":"term-s"' handoffs/.jarvis/events/sf.jsonl 2>/dev/null)" = 1 ]; check "hook event: on Superset, no env: the run record of \$SUPERSET_TERMINAL_ID names the brief, and the terminal is the run" $?
      SUPERSET_TERMINAL_ID=term-c "$BASH" handoffs/bin/jarvis hook event stop; SUPERSET_TERMINAL_ID=term-m "$BASH" handoffs/bin/jarvis hook event stop
      [ ! -e handoffs/.jarvis/events/sc.jsonl ] && [ ! -e handoffs/.jarvis/events/sm.jsonl ]; check "…not a Codex run's, nor a finished one's" $?
      SUPERSET_TERMINAL_ID='../runs/term-s' "$BASH" handoffs/bin/jarvis hook event stop; SUPERSET_TERMINAL_ID='term-s/' "$BASH" handoffs/bin/jarvis hook event stop
      [ "$(grep -c . handoffs/.jarvis/events/sf.jsonl)" = 1 ]; check "…an id outside the run-id charset is ignored" $?
      env -u SUPERSET_TERMINAL_ID ULTRON_SESSION_ID=s_u1 "$BASH" handoffs/bin/jarvis hook event working
      grep -q '"kind":"working","run":"s_u1"' handoffs/.jarvis/events/su.jsonl; check "…on Ultron, the run record of \$ULTRON_SESSION_ID" $?
      rm -rf handoffs/.jarvis

      ev_setup() { # $1 = agent: one running run, term ev, spawned 10 minutes ago
        rm -rf handoffs/.jarvis; rm -f handoffs/ev-handoff.md
        mkdir -p handoffs/.jarvis/runs handoffs/.jarvis/events src
        printf 'JARVIS_BATCH_SEC=0\nJARVIS_STALL_MIN=1\nJARVIS_FASTPATH="trust edit nudge"\n' > handoffs/jarvis.conf
        printf '# ev\nworker: %s\n\n## Scope\n- May touch: `src/`\n- Must not touch: none\n' "$1" > handoffs/briefs/ev.md
        printf 'brief: handoffs/briefs/ev.md\nagent: %s\nspawned: %s\nstate: running\n' "$1" "$(( $(date +%s) - 600 ))" > handoffs/.jarvis/runs/ev
        printf '# Open\nJarvis session: jarvis-t\n## Running workers\n- now · %s/model · term ev · handoffs/briefs/ev.md\n' "$1" > handoffs/OPEN.md
      }
      ev_at() { printf '{"t":%s,"kind":"%s","run":"%s","detail":"%s"}\n' "$(( $(date +%s) - $1 ))" "$2" "${R-ev}" "${3:-}" >> "$evf"; } # seconds ago, kind, detail; $R = the writer (ev)
      ev_tick() { : > "$FAKE_LOG"; FAKE_SCREEN="${1:-Working… esc to interrupt}" "$BASH" handoffs/bin/jarvis watch --once >/dev/null; }
      ev_woke() { grep -q "terminal jarvis-t --text .*$1" "$FAKE_LOG"; }
      ev_quiet() { ! grep -q 'terminals send' "$FAKE_LOG"; }
      ev_nudge() { grep -q 'terminal ev --text Finish the phase or write your handoff now.' "$FAKE_LOG" && ! grep -q 'terminal jarvis-t --text' "$FAKE_LOG"; }
      ev_src() { grep -q "$(printf '\tsource\t%s\t1$' "$1")" handoffs/.jarvis/watch.log; } # the watch.log source tag
      ev_age() { touch -t "$(date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$1" +%Y%m%d%H%M.%S)" "$2"; } # epoch, file
      ev_handoff() { printf '# phase\nstatus: blocked\nbrief: %s\n' "${1:-handoffs/briefs/ev.md}" > handoffs/ev-handoff.md; }
      ev_frozen() { ev_tick "$@"; ev_age $(( $(date +%s) - 120 )) handoffs/.jarvis/screen-ev; } # a first look at the screen, then that look made 2 min old

      ev_setup claude; ev_at 30 working; ev_at 0 ended prompt_input_exit; ev_tick
      ev_woke 'ended without a handoff' && [ "$(wl)" = 'woke ended 1' ] && ev_src ended:event; check "events: ended without a handoff wakes Jarvis on the first tick (source ended:event)" $?
      ev_tick; ev_quiet; check "…once: the next tick is deduplicated" $?
      ev_setup claude; ev_at 30 working; ev_handoff; ev_at 0 ended; ev_tick
      ! grep -q 'ended without' "$FAKE_LOG" && ev_woke 'handoff handoffs/ev-handoff.md'; check "events: ended after writing its handoff doesn't (the handoff wakes Jarvis)" $?
      ev_setup claude; ev_handoff; ev_age $(( $(date +%s) - 120 )) handoffs/ev-handoff.md; ev_at 30 working; ev_at 0 ended; ev_tick
      ev_woke 'ended without a handoff'; check "events: a handoff from before its last turn doesn't count" $?

      ev_setup claude; ev_at 0 permission permission_prompt
      ev_tick && ev_woke 'waiting at a prompt' && [ "$(wl)" = 'woke prompt 1' ] && ev_src prompt:event; check "events: a permission event raises the prompt event on a screen PROMPT_RE doesn't match" $?
      ev_tick; ev_quiet; check "…once" $?
      ev_tick 'still working'; ev_quiet; check "…after which the screen decides" $?
      touch src/widget.py
      ev_setup claude; ev_at 0 permission permission_prompt; ev_tick "$(cat "$here"/terminals/41-*.txt)"
      grep -q 'terminal ev --keys enter$' "$FAKE_LOG" && [ "$(wl)" = 'auto edit 1' ] && ev_src edit:event; check "events: …and goes through the fast edit path (source edit:event)" $?

      ev_setup claude; ev_at 180 working; ev_at 120 stop; ev_tick; ev_quiet; check "events: an old stop on a screen not seen before: nothing yet (the first look is a change)" $?
      ev_age $(( $(date +%s) - 120 )) handoffs/.jarvis/screen-ev; ev_tick
      ev_nudge && [ "$(wl)" = 'auto nudge 1' ] && ev_src nudge:event && grep -Eq '^nudged: [0-9]+$' handoffs/.jarvis/runs/ev; check "events: stop older than JARVIS_STALL_MIN nudges once (source nudge:event)" $?
      ev_tick; ev_quiet; check "…no wake during the next interval" $?
      sed -i.bak 's/^nudged: .*/nudged: '"$(( $(date +%s) - 120 ))"'/' handoffs/.jarvis/runs/ev && rm -f handoffs/.jarvis/runs/ev.bak; ev_tick
      ev_woke 'finished its turn 2 min ago (hook event: stop) and has no handoff' && [ "$(wl)" = 'woke stall 1' ] && ev_src stall:event; check "…then wakes Jarvis (source stall:event)" $?
      ev_tick; ev_quiet; check "…once" $?
      ev_setup claude; ev_at 120 waiting idle_prompt; ev_frozen; ev_tick; ev_nudge; check "events: waiting older than JARVIS_STALL_MIN nudges too" $?
      # a worker that ended its turn to wait on a background job, then got back to work: no
      # prompt hook fires for that, but its screen moves
      ev_setup claude; ev_at 180 working; ev_at 120 stop; ev_frozen 'waiting on the job'; ev_tick 'job done, running tests 1'; ev_tick 'running tests 2'
      ev_quiet && ! grep -q '^nudged:' handoffs/.jarvis/runs/ev; check "events: a stop followed by a changing screen raises nothing (the worker is at work)" $?
      ev_age $(( $(date +%s) - 120 )) handoffs/.jarvis/screen-ev; ev_tick 'running tests 2'
      ev_nudge && ev_src nudge:event; check "…until that screen too has been frozen JARVIS_STALL_MIN" $?
      ev_setup claude; ev_at 180 working; ev_at 120 waiting idle_prompt; ev_frozen; ev_tick 'output moved'; ev_quiet; check "…the same after waiting" $?
      ev_setup claude; ev_at 0 stop; ev_tick frozen; ev_age $(( $(date +%s) - 120 )) handoffs/.jarvis/screen-ev; ev_tick frozen
      ev_quiet && ! grep -q '^nudged:' handoffs/.jarvis/runs/ev; check "events: a fresh stop doesn't, even on a screen frozen past JARVIS_STALL_MIN" $?
      ev_setup claude; ev_at 180 working; ev_handoff; ev_at 120 stop; ev_tick; ev_tick; ! grep -q 'Finish the phase\|finished its turn' "$FAKE_LOG"; check "events: a stop after a handoff written this turn doesn't" $?
      ev_setup claude; ev_at 120 working; ev_tick frozen; ev_age $(( $(date +%s) - 120 )) handoffs/.jarvis/screen-ev; ev_tick frozen
      ev_nudge && ev_src nudge:screen; check "events: working falls back to the frozen-screen check (source nudge:screen)" $?
      ev_setup claude; ev_tick frozen; ev_age $(( $(date +%s) - 120 )) handoffs/.jarvis/screen-ev; ev_tick frozen
      ev_nudge && ev_src nudge:screen; check "events: no events file: today's screen check" $?
      for a in codex opencode; do
        ev_setup $a; ev_at 30 working; ev_at 0 ended; ev_tick
        ev_woke 'ended without a handoff' && ev_src ended:event; check "events: a $a run's events are read too (tmux writes them)" $?
        ev_setup $a; ev_at 180 working; ev_at 120 stop; ev_frozen; ev_tick; ev_nudge && ev_src nudge:event; check "…its stop drives the stall path" $?
      done
      ev_setup fake; ev_at 0 ended; ev_at 0 permission; ev_tick frozen; ev_age $(( $(date +%s) - 120 )) handoffs/.jarvis/screen-ev; ev_tick frozen
      ev_nudge && ev_src nudge:screen && ! grep -q 'ended without\|waiting at a prompt' "$FAKE_LOG"; check "events: another agent's events file is ignored" $?
      ev_setup claude; ev_at 900 ended; ev_at 700 permission; ev_tick; ev_quiet; check "events: lines older than the run's spawn are ignored" $?
      ev_setup claude; ev_at 900 working; ev_at 700 stop; ev_tick frozen; ev_age $(( $(date +%s) - 120 )) handoffs/.jarvis/screen-ev; ev_tick frozen
      ev_nudge && ev_src nudge:screen; check "…so the screen decides, as with no events" $?
      # a respawn: the old worker (term old) of the same brief writes into the same file
      # after the new run was spawned, e.g. its SessionEnd once jarvis close stops it
      ev_setup claude; R=old ev_at 30 working; R=old ev_at 0 ended prompt_input_exit; R=old ev_at 0 stop; ev_tick
      ev_quiet && ! grep -q 'ended without\|finished its turn' "$FAKE_LOG"; check "events: another run's lines of the same brief (a respawned brief's old worker) are ignored" $?
      ev_frozen frozen; ev_tick frozen; ev_nudge && ev_src nudge:screen; check "…so the screen decides" $?
      ev_setup claude; R=old ev_at 0 ended; ev_at 30 working; ev_at 120 stop; ev_frozen; ev_tick; ev_nudge && ev_src nudge:event && ! grep -q 'ended without' "$FAKE_LOG"
      check "…while its own lines still count" $?
      ev_setup claude; R='' ev_at 0 ended; printf '{"t":%s,"kind":"ended","detail":""}\n' "$(date +%s)" >> "$evf"; ev_tick; ev_quiet; check "events: a line with no run (or an older file's, with no run field) counts for no run" $?
      ev_setup claude; ev_at 30 working; ev_at 0 ended; ev_tick "$(printf 'You have hit your limit · resets 5pm\n> ')"
      ev_woke 'usage limit in worker' && ev_woke 'ended without a handoff'; check "events: ended still raises a usage limit on its final screen" $?
      for b in ./handoffs/briefs/ev.md 'handoffs/briefs/ev.md (rev 2, after the ruling)' '`handoffs/briefs/ev.md`'; do
        ev_setup claude; ev_at 30 working; ev_handoff "$b"; ev_at 0 ended; ev_tick
        ! grep -q 'ended without' "$FAKE_LOG" && ev_woke 'handoff handoffs/ev-handoff.md'; check "events: a handoff whose brief: is '$b' counts" $?
      done
      ev_setup claude; ev_handoff ./handoffs/briefs/ev.md; ev_frozen frozen; ev_tick frozen; ev_quiet; check "…and the frozen-screen check matches it the same way" $?
      ev_setup claude; ev_at 30 working; ev_handoff handoffs/briefs/ev.md.old; ev_at 0 ended; ev_tick; ev_woke 'ended without a handoff'; check "…while another brief's (ev.md.old) doesn't" $?
    )

    echo s > self.txt
    printf '# Self-listing\nstatus: done\nagent: codex gpt-5.6-sol\n## Files\n- self.txt — created\n- handoffs/h7.md — this handoff\n' > handoffs/h7.md
    $J merge handoffs/h7.md --no-push >/dev/null 2>&1; check "merge takes a handoff that lists itself" $?
    git show --name-only --format= HEAD | grep -qx 'handoffs/merged/h7.md' && [ ! -e handoffs/h7.md ]; check "…and commits it at its merged path only" $?

    mk b7 opencode "" ""; $J spawn handoffs/briefs/b7.md >/dev/null 2>&1
    b7t=$(sed -n 's/.*terminal: //p' handoffs/briefs/b7.md)
    echo c > corr.txt
    printf '# Corrected\nstatus: done\nagent: opencode x\nbrief: handoffs/briefs/b7.md\n## Files\n- corr.txt — created\n' > handoffs/h9.md
    head=$(git rev-parse HEAD)
    $J merge handoffs/h9.md --no-push --outcome corrected >/dev/null 2>&1; [ $? != 0 ] && [ -f handoffs/h9.md ] && [ "$(git rev-parse HEAD)" = "$head" ]
    check "merge --outcome corrected without --reason is refused, nothing merged" $?
    $J merge handoffs/h9.md --no-push --outcome bogus >/dev/null 2>&1; [ $? != 0 ] && [ -f handoffs/h9.md ]; check "merge --outcome bogus is refused" $?
    $J merge handoffs/h9.md --no-push --outcome clean --reason checks >/dev/null 2>&1; [ $? != 0 ] && [ -f handoffs/h9.md ]; check "merge --reason with an outcome other than corrected is refused" $?
    $J merge handoffs/h9.md --no-push --outcome corrected --reason checks >/dev/null 2>&1 \
      && grep -qx 'merge_outcome: corrected' "handoffs/.jarvis/runs/$b7t" && grep -qx 'merge_reason: checks' "handoffs/.jarvis/runs/$b7t"
    check "merge --outcome corrected --reason checks records both on the run" $?
    grep -q "merge-outcome run=$b7t brief=handoffs/briefs/b7.md outcome=corrected reason=checks result=" handoffs/.jarvis/audit.log; check "…and one audit line" $?

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

# Spawn overlap: a throwaway repo of its own, with its own JARVIS_HOME (lease, pending
# spawns) and fake-superset log. Running workers are run records and OPEN.md lines
# written by hand; the new brief is spawned for real.
if command -v jq >/dev/null 2>&1 && command -v perl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  echo "spawn overlap"
  (
    ov="$tmp/ov"; mkdir -p "$ov" && cd "$ov" || exit 1
    export PATH="$tmp/fake:$PATH" FAKE_LOG="$tmp/fake-ov.log" SUPERSET_WORKSPACE_ID=ws SUPERSET_TERMINAL_ID=jarvis-ov \
      JARVIS_HOME="$tmp/jh-ov" CODEX_HOME="$tmp/codex-ov"
    unset TYPESAFE_API_KEY
    git init -q && cp -R "$tpl/handoffs" . && sed -e 's/{{MAX_CLAUDE}}/3/' -e 's/{{AMBER}}/50/' -e 's/{{RED}}/75/' "$tpl/handoffs/jarvis.conf" > handoffs/jarvis.conf
    mkdir -p src/a docs && echo a > src/a/x.ts && git add -A && git commit -qm init
    J=handoffs/bin/jarvis
    $J start >/dev/null; cp handoffs/OPEN.md "$tmp/OPEN.ov"
    mkb() { # $1 name, $2 the May-touch row ("-" = no Scope section), $3 worker (opencode), $4 model
      { printf '# %s\nworker: %s\nmodel: %s\neffort: \n\n## Goal\nx\n\n' "$1" "${3:-opencode}" "${4:-}"
        [ "$2" = - ] || printf '## Scope\n- May touch: %s\n- Must not touch: research/\n\n' "$2"
        printf '## Checks\nx\n'; } > "handoffs/briefs/$1.md"; }
    fresh() { rm -rf handoffs/.jarvis/runs "$JARVIS_HOME/spawning"; cp "$tmp/OPEN.ov" handoffs/OPEN.md; : > "$FAKE_LOG"; }
    running() { # $1 run, $2 brief name, $3 state (running)
      mkdir -p handoffs/.jarvis/runs
      printf 'run: %s\nbrief: handoffs/briefs/%s.md\nagent: opencode\nspawned: %s\nstate: %s\n' "$1" "$2" "$(date +%s)" "${3:-running}" > "handoffs/.jarvis/runs/$1"
      printf -- '- 2026-11-04 10:00 · opencode/default · term %s · handoffs/briefs/%s.md\n' "$1" "$2" > "$tmp/ov.line"
      awk -v l="$(cat "$tmp/ov.line")" '{print} /^## Running workers/ {print l}' handoffs/OPEN.md > "$tmp/ov.o" && cat "$tmp/ov.o" > handoffs/OPEN.md; }
    conf() { sed -i.bak '/^JARVIS_OVERLAP=/d' handoffs/jarvis.conf && rm -f handoffs/jarvis.conf.bak; [ -z "$1" ] || echo "JARVIS_OVERLAP=$1" >> handoffs/jarvis.conf; }
    prep() { fresh; mkb ovn "$1"; mkb ovr "$2"; running r1 ovr; } # $1 new scope, $2 running scope
    pair() { prep "$@"; out=$($J spawn handoffs/briefs/ovn.md 2>&1); rc=$?; } # spawn ovn beside a running ovr; $out, $rc
    quiet() { [ $rc = 0 ] && ! printf '%s' "$out" | grep -q 'overlap'; }
    said() { [ $rc = 0 ] && printf '%s\n' "$out" | grep -q "^jarvis spawn: $1"; }

    pair '`src/x.ts`' '`src/x.ts`'
    said 'overlap: handoffs/briefs/ovn.md \[src/x.ts\] with running handoffs/briefs/ovr.md \[src/x.ts\] — queue handoffs/briefs/ovn.md under To-do until handoffs/briefs/ovr.md is handed off' \
      && grep -q 'agents create' "$FAKE_LOG"; check "warn: the same file → overlap, names the other brief, and spawns" $?
    pair 'src/x.ts' 'src/y.ts'; quiet; check "two different files: no overlap" $?
    pair 'src/a/' 'src/a/new/deep.ts'; said 'overlap: .*\[src/a/\] with running .*\[src/a/new/deep.ts\]'; check "a directory and a file below it (not yet created) → overlap" $?
    pair 'src/a' 'src/a/x.ts'; said 'overlap: '; check "an existing directory without its / is still a directory" $?
    pair 'src/a/' 'src/ab'; quiet; check "src/a/ and src/ab: no overlap (a / boundary)" $?
    pair 'src/x.ts' 'src/*.ts'; said 'overlap: .*\[src/x.ts\] .*\[src/\*.ts\]'; check "a literal file a glob matches → overlap" $?
    pair 'docs/x.ts' 'src/*.ts'; quiet; check "…one it doesn't match: none" $?
    pair 'src/**/*.ts' 'docs/**'; quiet; check "two globs with disjoint prefixes: none" $?
    pair 'src/*.ts' 'src/*.css'; said 'possible overlap: '; check "two globs with a shared prefix → possible overlap" $?
    pair 'none' 'src/'; quiet; check "none overlaps nothing" $?
    pair 'Src/X.ts' 'src/x.ts'; said 'possible overlap: '; check "a case variant → possible overlap" $?
    pair 'src/' 'all of `src/` except tests'; said 'unknown overlap: running handoffs/briefs/ovr.md (term r1) has a scope that can.t be read (line 10: entry'; check "a running brief with prose for a scope → unknown, with its line" $?
    pair 'src/' '-'; said "unknown overlap: running handoffs/briefs/ovr.md (term r1) has a scope that can.t be read (no '## Scope' section)"; check "…a running brief with no Scope section: unknown, not empty" $?
    fresh; mkb ovn 'src/'; running r1 gone; out=$($J spawn handoffs/briefs/ovn.md 2>&1); rc=$?
    said 'unknown overlap: running handoffs/briefs/gone.md (term r1) .*the brief is gone'; check "…a running brief that's gone: unknown" $?
    pair 'src/{a,b}' 'docs/'; said "unknown overlap: handoffs/briefs/ovn.md's scope can.t be read"; check "the new brief's unreadable scope (braces) → unknown" $?
    fresh; mkb ovn 'src/'; running r1 ovn; out=$($J spawn handoffs/briefs/ovn.md 2>&1); rc=$?
    said 'overlap: handoffs/briefs/ovn.md is already running (term r1)'; check "the same brief already running → overlap" $?
    fresh; mkb ovn 'src/'; mkb ovr 'src/'; running r1 ovr merged; running r2 ovr closed; running r3 ovr lost
    out=$($J spawn handoffs/briefs/ovn.md 2>&1); rc=$?; quiet; check "merged, closed and lost runs are ignored (OPEN.md lines too)" $?
    fresh; mkb ovn 'src/'; mkb ovr 'src/'; running r1 ovr; rm -f handoffs/.jarvis/runs/r1
    out=$($J spawn handoffs/briefs/ovn.md 2>&1); rc=$?; said 'overlap: .*with running handoffs/briefs/ovr.md'; check "a legacy OPEN.md line with no record counts" $?
    pair 'src/x.ts' 'src/[^x]*.ts'; quiet && pair 'src/y.ts' 'src/[^x]*.ts' && said 'overlap: ' && pair 'src/x.ts' 'src/[!x]*.ts' && quiet
    check "a [^..] class negates like [!..]" $?
    pair 'src/new' 'src/new/deep.ts'; said 'overlap: .*\[src/new\] with running .*\[src/new/deep.ts\]' && pair 'src/new/deep.ts' 'src/new' && said 'overlap: ' \
      && pair 'src/new' 'src/new/*.ts' && said 'overlap: '; check "a bare path the other entry's path runs through is a folder, not yet on disk or not" $?
    pair 'src/new' 'src/newer/x.ts'; quiet && pair 'docs/x.md' '**/*.ts' && quiet; check "…but not across a / boundary, nor for a ** glob" $?
    fresh; mkb ovn 'src/'; mkdir -p handoffs/.jarvis/runs; printf 'run: r9\nagent: opencode\nstate: running\n' > handoffs/.jarvis/runs/r9
    out=$($J spawn handoffs/briefs/ovn.md 2>&1); rc=$?
    said 'unknown overlap: running term r9 has no brief on record' && grep -q 'agents create' "$FAKE_LOG"; check "a running record with no brief: unknown, not dropped" $?

    conf refuse
    prep 'src/' 'src/a/x.ts'; o=$(cksum < handoffs/OPEN.md); b=$(cksum < handoffs/briefs/ovn.md); runs=$(ls handoffs/.jarvis/runs)
    out=$($J spawn handoffs/briefs/ovn.md 2>&1); rc=$?
    [ $rc = 1 ] && printf '%s\n' "$out" | grep -q '^jarvis spawn: refused (JARVIS_OVERLAP=refuse): overlap: handoffs/briefs/ovn.md \[src/\] with running handoffs/briefs/ovr.md'
    check "refuse: exit 1, names the other brief" $?
    ! grep -q 'agents create' "$FAKE_LOG" && [ "$(cksum < handoffs/OPEN.md)" = "$o" ] && [ "$(cksum < handoffs/briefs/ovn.md)" = "$b" ] \
      && [ "$(ls handoffs/.jarvis/runs)" = "$runs" ]; check "…before any launch, started: line, OPEN.md or run-record change" $?
    $J spawn handoffs/briefs/ovn.md --force >/dev/null 2>&1; [ $? = 1 ] && ! grep -q 'agents create' "$FAKE_LOG"; check "…and --force doesn't pass it" $?
    pair 'src/' 'docs/'; [ $rc = 0 ] && grep -q 'agents create' "$FAKE_LOG"; check "refuse: disjoint scopes still spawn" $?
    fresh; mkb ovn 'src/'; mkdir -p handoffs/.jarvis/runs; printf 'run: r9\nbrief: \nstate: running\n' > handoffs/.jarvis/runs/r9
    out=$($J spawn handoffs/briefs/ovn.md 2>&1); rc=$?
    [ $rc = 1 ] && printf '%s' "$out" | grep -q 'refused (JARVIS_OVERLAP=refuse): unknown overlap: running term r9' && ! grep -q 'agents create' "$FAKE_LOG"
    check "refuse: a running record with an empty brief → refused" $?
    conf bogus; out=$($J spawn handoffs/briefs/ovn.md 2>&1); [ $? = 2 ] && printf '%s' "$out" | grep -q "JARVIS_OVERLAP='bogus'"; check "an invalid JARVIS_OVERLAP exits 2" $?

    conf ""; mv handoffs/bin/jarvis-scope.py "$tmp/scope.keep"
    pair 'src/' 'docs/'; said 'unknown overlap: no handoffs/bin/jarvis-scope.py' && printf '%s' "$out" | grep -q 'spawning anyway'; check "warn: no jarvis-scope.py → a note, and it spawns" $?
    conf refuse; pair 'src/' 'docs/'; [ $rc = 1 ] && printf '%s' "$out" | grep -q 'refused (JARVIS_OVERLAP=refuse): unknown overlap: no handoffs/bin/jarvis-scope.py' \
      && ! grep -q 'agents create' "$FAKE_LOG"; check "refuse: no jarvis-scope.py → refused" $?
    mv "$tmp/scope.keep" handoffs/bin/jarvis-scope.py
    farm="$tmp/nopy"; mkdir -p "$farm"   # PATH without python: every other command of PATH, linked
    printf '%s\n' "$PATH" | tr ':' '\n' | while IFS= read -r d; do [ -d "$d" ] && ln -s "$d"/* "$farm"/ 2>/dev/null; done; rm -f "$farm"/python*
    prep 'src/' 'docs/'; out=$(PATH="$farm" $J spawn handoffs/briefs/ovn.md 2>&1); rc=$?
    [ $rc = 1 ] && printf '%s' "$out" | grep -q 'refused (JARVIS_OVERLAP=refuse): unknown overlap: no python3 on PATH'; check "refuse: no python3 → refused" $?
    conf ""; prep 'src/' 'docs/'; out=$(PATH="$farm" $J spawn handoffs/briefs/ovn.md 2>&1); rc=$?
    said 'unknown overlap: no python3 on PATH' && grep -q 'agents create' "$FAKE_LOG"; check "warn: no python3 → a note, and it spawns" $?
    fresh; mkb ovn 'src/'; out=$(PATH="$farm" $J spawn handoffs/briefs/ovn.md 2>&1); rc=$?; quiet; check "…nothing running: no python needed, no note" $?

    # two spawns at once, overlapping, the host slow to launch: the second waits for the
    # checkout's spawn lease, then sees the first running
    race() { # $1 $2: the first brief's worker and model, $3 $4 the second's
      fresh; mkb rca 'src/' "$1" "$2"; mkb rcb 'src/a/' "$3" "$4"
      (FAKE_SPAWN_SLEEP=2 $J spawn handoffs/briefs/rca.md > "$tmp/rca" 2>&1; echo $? > "$tmp/rca.rc") & pa=$!
      (FAKE_SPAWN_SLEEP=2 $J spawn handoffs/briefs/rcb.md > "$tmp/rcb" 2>&1; echo $? > "$tmp/rcb.rc") & pb=$!
      wait "$pa" "$pb"; r="$(cat "$tmp/rca.rc")$(cat "$tmp/rcb.rc")"
      { [ "$r" = 01 ] || [ "$r" = 10 ]; } && [ "$(grep -c 'agents create' "$FAKE_LOG")" = 1 ] \
        && cat "$tmp/rca" "$tmp/rcb" | grep -q 'refused (JARVIS_OVERLAP=refuse): overlap: '; }
    conf refuse
    race codex gpt-5.6-sol opencode ""; check "refuse: Codex and OpenCode spawned at once, overlapping: exactly one passes" $?
    race claude sonnet claude sonnet; check "…two Claude workers at once: exactly one passes" $?

    conf ""; fresh; mkb ovn 'src/'; bgp="$tmp/ov.bg"
    FAKE_SPAWN_BG="$bgp" $J spawn handoffs/briefs/ovn.md >/dev/null 2>&1; mkb ovm 'docs/'
    JARVIS_SPAWN_WAIT=3 $J spawn handoffs/briefs/ovm.md >/dev/null 2>&1; check "a process the host leaves running doesn't hold the spawn lease" $?
    [ -s "$bgp" ] && kill "$(cat "$bgp")" 2>/dev/null
    $J lock spawn -- true >/dev/null 2>&1; [ $? = 2 ]; check "lock class 'spawn' is reserved" $?
    # the leased part's own exit (the conf line runs only in it) vs a lease never taken
    fresh; mkb ovn 'docs/'; cp handoffs/jarvis.conf "$tmp/conf.ov"; nok=0
    for c in 2 7; do
      cp "$tmp/conf.ov" handoffs/jarvis.conf; echo "[ -z \"\${JARVIS_SPAWN_LEASE:-}\" ] || { echo 'leased part: no' >&2; exit $c; }" >> handoffs/jarvis.conf
      out=$($J spawn handoffs/briefs/ovn.md 2>&1); rc=$?
      [ $rc = $c ] && printf '%s' "$out" | grep -qx 'leased part: no' && ! printf '%s' "$out" | grep -q 'spawn lease' || nok=1
    done; check "the leased part exiting 2 or more: its message and code, no lease error" $nok
    cp "$tmp/conf.ov" handoffs/jarvis.conf
    out=$(JARVIS_LOCK_DIR=/dev/null/locks $J spawn handoffs/briefs/ovn.md 2>&1); rc=$?
    [ $rc = 1 ] && printf '%s' "$out" | grep -q "can't take the spawn lease of this checkout in /dev/null/locks (exit [0-9]*): spawn refused" && ! grep -q 'agents create' "$FAKE_LOG"
    check "…a lease that can't be taken still says so" $?
  ) | tee "$tmp/ov.out"
  n=$(grep -c '^  FAIL' "$tmp/ov.out"); fails=$((fails + n))
else
  echo "spawn overlap: skipped (jq, perl or python3 not installed)"
fi

# Two helpers of bin/jarvis, run on their own from the template's source: the OpenCode
# plugin's URL in a launch line (a checkout path with a space, # ? and %), and which
# handoffs count for a run's brief.
echo "launch URL and handoff_since"
fn() { awk -v n="$1" 'index($0, n "() {") == 1 {p=1; one = /\}( *#.*)?$/} p {print} p && (one || /^}$/) {exit}' "$jbin" "${jbin%/*}/lib"/*.sh; }  # a function of the script or its lib/, whole
jbin="$here/../plugins/jarvis/skills/setup/templates/handoffs/bin/jarvis"
if command -v node >/dev/null 2>&1; then
  # shellcheck disable=SC2034 # the variables are read by the functions eval'd inside
  (
    ROOT="$tmp/we ird#q?p%25/repo"; H=handoffs; STATE=$H/.jarvis; BIN=$H/bin; SPAWN_BRIEF=handoffs/briefs/x.md
    mkdir -p "$ROOT/$STATE/launch" && cd "$ROOT" || exit 1
    eval "$(fn tmux_sq)"; eval "$(fn url_path)"; eval "$(fn tmux_opencode_plugin)"; eval "$(fn tmux_event_lines)"
    tmux_event_lines opencode > "$tmp/oc-line.sh"
    unset OPENCODE_CONFIG_CONTENT; . "$tmp/oc-line.sh"
    got=$(node --input-type=module -e '
      import { fileURLToPath } from "node:url";
      const u = JSON.parse(process.env.OPENCODE_CONFIG_CONTENT).plugin[0];
      const m = await import(u);
      console.log(fileURLToPath(u) + "|" + typeof m.JarvisEvents);')
    [ "$got" = "$ROOT/$STATE/launch/opencode-events.js|function" ]
    check "opencode plugin URL: a checkout path with a space, #, ? and % loads the plugin file" $?
  ) | tee "$tmp/ocurl.out"
  n=$(grep -c '^  FAIL' "$tmp/ocurl.out"); fails=$((fails + n))
else
  echo "  (plugin URL check skipped: no node)"
fi
(
  eval "$(fn url_path)"
  tb=$(printf '\t'); cr=$(printf '\r'); lf='
'
  [ "$(url_path "/a${tb}b")" = "/a%09b" ] && [ "$(url_path "/a${cr}b")" = "/a%0Db" ] \
    && [ "$(url_path "/a${lf}b")" = "/a%0Ab" ] && [ "$(url_path "/a b#c?d%e")" = "/a%20b%23c%3Fd%25e" ]
  check "url_path: a tab, CR and LF are percent-encoded, % first (no %25 of the new %0A)" $?
) | tee "$tmp/up.out"
n=$(grep -c '^  FAIL' "$tmp/up.out"); fails=$((fails + n))
# shellcheck disable=SC2034 # the variables are read by the functions eval'd inside
(
  ROOT="$tmp/hs/repo"; ROOTP=$ROOT; H=handoffs
  mkdir -p "$ROOT/$H" && cd "$ROOT" || exit 1
  eval "$(fn field)"; eval "$(fn mtime)"; eval "$(fn handoff_since)"
  hs() { # $1 = the handoff's brief: value; true when it counts for handoffs/briefs/x.md
    printf '# t\nstatus: done\nbrief: %s\n' "$1" > "$H/2026-10-20-1200-h.md"; handoff_since handoffs/briefs/x.md 0
  }
  hs handoffs/briefs/x.md && hs ./handoffs/briefs/x.md && hs "\`handoffs/briefs/x.md\` (rerun)"
  check "handoff_since: the repo-relative path, with ./ or a note, counts" $?
  hs "$ROOT/handoffs/briefs/x.md" && hs "$ROOT/handoffs/briefs/x.md (rerun)" && hs "/handoffs/briefs/x.md"
  check "…an absolute path under the checkout counts, and a leading / alone" $?
  ! hs handoffs/briefs/x.md.old && ! hs "$ROOT/handoffs/briefs/x.md.old" && ! hs handoffs/briefs/y.md \
    && ! hs "$ROOT/handoffs/briefs/y.md" && ! hs "$tmp/other/repo/handoffs/briefs/x.md"
  check "…x.md.old, another brief and another checkout's path don't" $?
  hs "//handoffs/briefs/x.md" && hs "//handoffs/briefs/x.md (rerun)"
  check "…a doubled leading // counts like a single one" $?
  # ROOT is a symlink to the real directory; ROOTP, as pwd -P names it, is the real one
  ln -s "$ROOT" "$tmp/hs/link" && ROOT="$tmp/hs/link" && ROOTP=$(cd "$tmp/hs/repo" && pwd -P)
  hs "$ROOTP/handoffs/briefs/x.md" && hs "$ROOTP/handoffs/briefs/x.md (rerun)" && ! hs "$ROOTP/handoffs/briefs/x.md.old" \
    && ! hs "$ROOTP/handoffs/briefs/y.md" && hs "$ROOT/handoffs/briefs/x.md"
  check "…where ROOT and ROOTP differ, the ROOTP spelling counts on its own" $?
) | tee "$tmp/hs.out"
n=$(grep -c '^  FAIL' "$tmp/hs.out"); fails=$((fails + n))

# bin/jarvis sources lib/ from beside its real file: called through symlinks that live
# elsewhere (no lib/ next to them) and by a relative path, it still finds it; with no
# lib/ at all, commands stop with a pointer to setup and the hooks' fast paths stay silent.
echo "lib/ beside bin/jarvis"
(
  tpl="$here/../plugins/jarvis/skills/setup/templates"; lr="$tmp/lr/repo"; export JARVIS_HOME="$tmp/lr/jh"
  mkdir -p "$lr/sub" "$tmp/lr/links" "$JARVIS_HOME" && cd "$lr" || exit 1
  git init -q && cp -R "$tpl/handoffs" . \
    && sed -e 's/{{MAX_CLAUDE}}/3/' -e 's/{{AMBER}}/50/' -e 's/{{RED}}/75/' "$tpl/handoffs/jarvis.conf" > handoffs/jarvis.conf
  now=$(date +%s)
  echo "{\"five_hour\":{\"used_percentage\":30,\"resets_at\":$((now + 2 * 3600))},\"ts\":$now}" > "$JARVIS_HOME/usage.json"
  ln -s ../repo/handoffs/bin/jarvis "$tmp/lr/links/rel"; ln -s "$lr/handoffs/bin/jarvis" "$tmp/lr/links/abs"
  ln -s rel "$tmp/lr/links/rel2"
  for l in rel abs rel2; do
    out=$(cd sub && "$BASH" "$tmp/lr/links/$l" band 2>&1); rc=$?
    [ $rc = 0 ] && printf '%s' "$out" | grep -Eq '^(green|amber|red) '; check "band through the $l symlink, from a subdirectory: lib/ found beside the real file" $?
  done
  out=$(cd handoffs && "$BASH" bin/jarvis band 2>&1); rc=$?
  [ $rc = 0 ] && printf '%s' "$out" | grep -Eq '^(green|amber|red) '; check "band as bin/jarvis from handoffs/" $?
  rm -rf handoffs/bin/lib
  out=$("$BASH" handoffs/bin/jarvis status 2>&1); rc=$?
  [ $rc = 1 ] && [ "$out" = "jarvis: no $PWD/handoffs/bin/lib/ beside bin/jarvis — re-run jarvis:setup" ]
  check "no lib/: status exits 1, pointing at jarvis:setup" $?
  out=$(echo '{"hook_event_name":"Stop"}' | JARVIS_ROLE=worker JARVIS_BRIEF=handoffs/briefs/x.md "$BASH" handoffs/bin/jarvis hook event stop 2>&1); rc=$?
  [ $rc = 0 ] && [ -z "$out" ]; check "no lib/: hook event stop exits 0, silent" $?
  out=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"app.txt"}}' | "$BASH" handoffs/bin/jarvis hook pretool 2>&1); rc=$?
  [ $rc = 0 ] && [ -z "$out" ]; check "no lib/: hook pretool on other input exits 0, silent" $?
  err=$(echo '{"prompt":"hi"}' | "$BASH" handoffs/bin/jarvis hook prompt 2>&1 >/dev/null); rc=$?
  [ $rc = 1 ] && printf '%s' "$err" | grep -q 're-run jarvis:setup$'; check "no lib/: hook prompt exits 1, the message on stderr" $?
) | tee "$tmp/lib.out"
n=$(grep -c '^  FAIL' "$tmp/lib.out"); fails=$((fails + n))

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
    printf '%s\n' 'JARVIS_PUSH=0' 'JARVIS_BATCH_SEC=0' \
      'JARVIS_AGENT_fake='"'"'echo "fake model=$JARVIS_MODEL effort=$JARVIS_EFFORT"; echo "prompt=$JARVIS_PROMPT"; while read -r l; do echo "got: $l"; done'"'" \
      >> handoffs/jarvis.conf
    printf '# t\nworker: fake\nmodel: m1\neffort: low\nstarted: <x>\n' > handoffs/briefs/2026-10-20-1200-tw.md
    git add -A && git commit -q -m setup
    sock="jarvis-selftest-$$"
    env -u SUPERSET_WORKSPACE_ID -u SUPERSET_TERMINAL_ID -u TMUX -u TMUX_PANE tmux -L "$sock" new-session -d -c "$tb" -x 160 -y 40
    tenv=$(tmux -L "$sock" display-message -p '#{socket_path},#{pid},0')
    T() { env -u SUPERSET_WORKSPACE_ID -u SUPERSET_TERMINAL_ID TMUX="$tenv" TMUX_PANE=%0 handoffs/bin/jarvis "$@"; }
    shows() { T read %1 "$1" | grep -q -- "$2"; } # the worker's last $1 lines match $2
    shows_t() { T read "$1" 10 | grep -q -- "$2"; } # terminal $1's last 10 lines match $2
    poll() { for _ in $(seq 40); do "$@" && return 0; sleep 0.25; done; return 1; } # up to 10 s, not a fixed sleep

    T start >/dev/null && grep -qx 'Jarvis session: %0' handoffs/OPEN.md; check "start records the tmux pane" $?
    echo hi > note.txt
    T spawn handoffs/briefs/2026-10-20-1200-tw.md --attach note.txt | grep -q '^spawned %1 fake/m1 low'; check "spawn opens a window for any configured agent" $?
    [ "$(tmux -L "$sock" display-message -p -t %1 '#{window_name} #{@jarvis}')" = "tw tw" ]; check "…named after the brief and tagged" $?
    grep -q '^started:.*terminal: %1' handoffs/briefs/2026-10-20-1200-tw.md && grep -q '· term %1 ·' handoffs/OPEN.md; check "…and recorded in the brief and OPEN.md" $?
    poll shows 10 '^fake model=m1 effort=low'; check "read shows the screen; model and effort reach the agent" $?
    poll shows 10 'Read this attached file first: note.txt'; check "--attach names the file in the prompt" $?
    T send %1 "Answers: 1. yes
2. no" && poll shows 5 '^got: Answers: 1\. yes 2\. no$'; check "send types one line and presses Enter" $?
    T send %1 --keys "a,b,enter" && poll shows 5 '^got: ab$'; check "send --keys presses keys" $?
    T close %0 >/dev/null 2>&1; [ $? = 1 ] && tmux -L "$sock" list-panes -a -F '#{pane_id}' | grep -qx %0; check "close refuses a pane Jarvis didn't open" $?
    T send %1 --keys ctrl+d && poll shows 3 'exited (0)'; check "an agent that exits leaves its window up" $?
    printf '# done\nstatus: done\nbrief: handoffs/briefs/2026-10-20-1200-tw.md\nagent: fake m1\n\n## Files\n- note.txt\n' > handoffs/htw.md
    T watch --once | grep -q 'woke Jarvis: handoff handoffs/htw.md'; check "the watcher wakes Jarvis's pane" $?
    T merge handoffs/htw.md --no-push | grep -q 'closed %1' && ! tmux -L "$sock" list-panes -a -F '#{pane_id}' | grep -qx %1; check "merge closes the worker's window" $?
    env -u SUPERSET_WORKSPACE_ID -u TMUX -u TMUX_PANE handoffs/bin/jarvis read %1 >/dev/null 2>&1; [ $? = 1 ]; check "with no host, jarvis says so" $?
    # a Claude worker's launch script gives its hooks JARVIS_ROLE and JARVIS_BRIEF; others' don't
    # shellcheck disable=SC2016
    printf '%s\n' 'JARVIS_AGENT_claude='"'"'echo "role=$JARVIS_ROLE brief=$JARVIS_BRIEF run=$JARVIS_RUN"'"'" >> handoffs/jarvis.conf
    printf '# c\nworker: claude\nmodel: claude-haiku-5-5\neffort: low\nstarted: <x>\n' > handoffs/briefs/2026-10-20-1200-tc.md
    # a JARVIS_HOME of its own: the pending spawns of the sections above would fill the amber caps
    tc=$(JARVIS_HOME="$tmp/jh-tc" T spawn handoffs/briefs/2026-10-20-1200-tc.md 2>/dev/null | sed -n 's/^spawned \([^ ]*\) .*/\1/p')
    grep -qx "export JARVIS_ROLE=worker JARVIS_BRIEF='handoffs/briefs/2026-10-20-1200-tc.md'" handoffs/.jarvis/launch/tc.sh \
      && grep -q '^unset .*JARVIS_ROLE JARVIS_BRIEF' handoffs/.jarvis/launch/tw.sh && ! grep -q 'export JARVIS_ROLE' handoffs/.jarvis/launch/tw.sh
    check "spawn on tmux: a Claude worker's launch script sets JARVIS_ROLE=worker and JARVIS_BRIEF; another agent's only unsets them" $?
    [ -n "$tc" ] && poll shows_t "$tc" "^role=worker brief=handoffs/briefs/2026-10-20-1200-tc.md run=$tc\$"; check "…and the worker sees them, with JARVIS_RUN its pane (the run id)" $?
    # Codex and OpenCode workers get per-run hooks: stand-in binaries, with the
    # captured payloads, run what the launch script hands them. The agent lines set PATH
    # themselves (the user's shell startup files can reset the server's) and refuse to
    # run anything but the stand-in, so a real agent never starts here.
    fb="$tmp/tb-bin"; mkdir -p "$fb"
    # shellcheck disable=SC2016
    for a in codex opencode; do
      printf 'JARVIS_AGENT_%s='"'"'export PATH="%s:$PATH"; [ -x "%s/%s" ] && %s'"'"'\n' \
        "$a" "$fb" "$fb" "$a" "$(sed -n "s/^JARVIS_AGENT_$a='\\(.*\\)'\$/\\1/p" "$tpl/handoffs/bin/lib/defaults.sh")"
    done >> handoffs/jarvis.conf
    evs() { jq -r '.kind + ":" + .detail' "handoffs/.jarvis/events/$1.jsonl" 2>/dev/null | tr '\n' ' '; }
    if python3 -c 'import tomllib' 2>/dev/null; then
      # fake codex: each -c hooks.<Event> parsed as TOML, its commands run with the event's payload
      cat > "$fb/codex" <<EOF
#!/usr/bin/env python3
import json, subprocess, sys, tomllib
hooks, a = {}, sys.argv[1:]
for i, x in enumerate(a[:-1]):
    if x == "-c" and a[i + 1].startswith("hooks."):
        k, v = a[i + 1][6:].split("=", 1)
        hooks[k] = tomllib.loads("v = " + v)["v"]
print("fake codex hooks: " + " ".join(sorted(hooks)) + " | " + " ".join(x for x in a if x.startswith("--dangerously-bypass-hook")))
for ev, f in (("UserPromptSubmit", "user-prompt-submit"), ("Stop", "stop"), ("PermissionRequest", ""), ("SessionEnd", "session-end")):
    stdin = open("$here/hook-payloads/codex-%s.json" % f).read() if f else "{}"
    for g in hooks.get(ev, []):
        for h in g["hooks"]:
            subprocess.run(h["command"], shell=True, input=stdin, text=True, timeout=h.get("timeout", 10))
print("fake codex done")
EOF
      chmod +x "$fb/codex"
      printf '# x\nworker: codex\nmodel: gpt-5.6-terra\neffort: low\nstarted: <x>\n' > handoffs/briefs/2026-10-20-1200-tx.md
      tx=$(JARVIS_HOME="$tmp/jh-tx" CODEX_HOME="$tmp/codex-tx" T spawn handoffs/briefs/2026-10-20-1200-tx.md 2>/dev/null | sed -n 's/^spawned \([^ ]*\) .*/\1/p')
      grep -qx "export JARVIS_ROLE=worker JARVIS_BRIEF='handoffs/briefs/2026-10-20-1200-tx.md'" handoffs/.jarvis/launch/tx.sh \
        && grep -q "^codex() { command codex -c 'hooks.UserPromptSubmit=" "handoffs/.jarvis/launch/tx.sh"
      check "spawn on tmux: a Codex worker's launch script sets its role and wraps codex with -c hooks" $?
      [ -n "$tx" ] && poll shows_t "$tx" '^fake codex done'
      shows_t "$tx" '^fake codex hooks: PermissionRequest SessionEnd Stop UserPromptSubmit | --dangerously-bypass-hook-trust$' \
        && [ "$(evs 2026-10-20-1200-tx)" = 'working: stop:ok permission: ended:other ' ] \
        && [ "$(jq -r .run "handoffs/.jarvis/events/2026-10-20-1200-tx.jsonl" | sort -u)" = "$tx" ]
      check "…its hooks reach jarvis hook event with Codex's payloads: working, stop, permission, ended" $?
    else
      echo "  (Codex hook checks skipped: python3 has no tomllib)"
    fi
    if command -v node >/dev/null 2>&1; then
      # fake opencode: loads the plugin OPENCODE_CONFIG_CONTENT names, feeds it the events
      cat > "$fb/oc-driver.mjs" <<EOF
import { readFileSync } from "node:fs";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const url = JSON.parse(process.env.OPENCODE_CONFIG_CONTENT).plugin[0];
const hooks = await (await import(url)).JarvisEvents({});
console.log("fake opencode plugin: " + (hooks.event ? "on" : "off"));
for (const l of readFileSync("$here/hook-payloads/opencode-events.jsonl", "utf8").split("\n").filter(Boolean)) {
  await hooks.event?.({ event: JSON.parse(l) }); await sleep(400);
}
console.log("fake opencode done");
EOF
      printf '#!/bin/sh\nexec node "%s/oc-driver.mjs"\n' "$fb" > "$fb/opencode"; chmod +x "$fb/opencode"
      printf '# o\nworker: opencode\nmodel: \neffort: \nstarted: <x>\n' > handoffs/briefs/2026-10-20-1200-to.md
      to=$(JARVIS_HOME="$tmp/jh-to" T spawn handoffs/briefs/2026-10-20-1200-to.md 2>/dev/null | sed -n 's/^spawned \([^ ]*\) .*/\1/p')
      grep -q '^\[ -n "${OPENCODE_CONFIG_CONTENT:-}" \] || export OPENCODE_CONFIG_CONTENT=' handoffs/.jarvis/launch/to.sh \
        && [ -f handoffs/.jarvis/launch/opencode-events.js ] && grep -q "jarvis' hook event ended </dev/null$" handoffs/.jarvis/launch/to.sh
      check "spawn on tmux: an OpenCode worker gets the events plugin through OPENCODE_CONFIG_CONTENT, and ended after it exits" $?
      oc_done() { [ "$(evs 2026-10-20-1200-to)" = 'working: stop: working: permission: waiting: stop: ended: ' ]; }
      [ -n "$to" ] && poll oc_done && shows_t "$to" '^fake opencode plugin: on' \
        && [ "$(jq -r .run "handoffs/.jarvis/events/2026-10-20-1200-to.jsonl" | sort -u)" = "$to" ]
      check "…the plugin maps busy, idle, permission and question (a subagent's ignored) and the exit is ended" $?
      ! grep -q 'export JARVIS_ROLE\|OPENCODE_CONFIG_CONTENT\|^codex()' handoffs/.jarvis/launch/tw.sh; check "…another agent gets neither" $?
    else
      echo "  (OpenCode plugin checks skipped: no node)"
    fi
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
    rm -f handoffs/bin/jev.sh; printf '%s\n' 'JARVIS_PUSH=0' 'JARVIS_BATCH_SEC=0' >> handoffs/jarvis.conf
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

echo "brief template"
body=$(awk '/^```bash verify/ {on = 1; next} on && /^```/ {exit} on' "$here/../plugins/jarvis/skills/setup/templates/handoffs/briefs/TEMPLATE.md")
printf '%s\n' "$body" | grep -qx '<.*>' && ! "$BASH" -n -c "$body" 2>/dev/null; check "its verify block is a placeholder bash won't run" $?

echo "jarvis lock (eval/locktest.sh)"; "$BASH" "$here/locktest.sh" 2>&1 | tee "$tmp/lock.out"; grep -q '^locktest: all passed' "$tmp/lock.out" || { n=$(grep -c '^  FAIL' "$tmp/lock.out"); fails=$((fails + (n > 0 ? n : 1))); }
echo "merge --verify (eval/verifytest.sh)"; "$BASH" "$here/verifytest.sh" 2>&1 | tee "$tmp/verify.out"; grep -q '^verifytest: all passed' "$tmp/verify.out" || { n=$(grep -c '^  FAIL' "$tmp/verify.out"); fails=$((fails + (n > 0 ? n : 1))); }
echo "fable gate (eval/fabletest.sh)"; "$BASH" "$here/fabletest.sh" 2>&1 | tee "$tmp/fable.out"; grep -q '^fabletest: all passed' "$tmp/fable.out" || { n=$(grep -c '^  FAIL' "$tmp/fable.out"); fails=$((fails + (n > 0 ? n : 1))); }
echo "claude caps and band (eval/captest.sh)"; "$BASH" "$here/captest.sh" 2>&1 | tee "$tmp/cap.out"; grep -q '^captest: all passed' "$tmp/cap.out" || { n=$(grep -c '^  FAIL' "$tmp/cap.out"); fails=$((fails + (n > 0 ? n : 1))); }
echo "worker budgets (eval/budgettest.sh)"; "$BASH" "$here/budgettest.sh" 2>&1 | tee "$tmp/budget.out"; grep -q '^budgettest: all passed' "$tmp/budget.out" || { n=$(grep -c '^  FAIL' "$tmp/budget.out"); fails=$((fails + (n > 0 ? n : 1))); }
echo "jarvis usage (eval/usagetest.sh)"; "$BASH" "$here/usagetest.sh" 2>&1 | tee "$tmp/usage.out"; grep -q '^usagetest: all passed' "$tmp/usage.out" || { n=$(grep -c '^  FAIL' "$tmp/usage.out"); fails=$((fails + (n > 0 ? n : 1))); }
rm -rf "$tmp"
echo; [ "$fails" = 0 ] && echo "selftest: all passed" || { echo "selftest: $fails failed"; exit 1; }
exit # inside the group: bash never reads past it
}
