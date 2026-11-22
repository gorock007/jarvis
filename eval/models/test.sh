#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2010,SC2012,SC2016 # ok/bad never fail; the fakes name files we made
# Offline tests for eval/models: fake claude, agy and codex binaries first on
# PATH, the bundled example suite, throwaway output folders. No real model calls.
#
#   bash eval/models/test.sh        (also run it with /bin/bash, stock 3.2)
set -u
here=$(cd "$(dirname "$0")" && pwd)
sh=${BASH:-bash}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/eval-models-test.XXXXXX") || exit 2
trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; [ $# -lt 2 ] || printf '%s\n' "$2" | sed 's/^/     /' | head -20; }
check() { # check <name> <command...>
  local n=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi
}
has() { printf '%s' "$1" | grep -qF -- "$2"; }

# --- fake model CLIs -------------------------------------------------------
# Each call logs its argv (one per line), cwd, cwd entry count and cache env
# under $FAKE_LOG/<cli>.<n>.*, then answers by which example file the prompt quotes.
mkdir -p "$tmp/bin" "$tmp/log"
cat > "$tmp/bin/fake-common" <<'EOF'
log_call() { # $1 cli, $2 prompt text; remaining args are the argv
  local cli=$1 prompt=$2 n; shift 2
  n=$(ls "$FAKE_LOG" | grep -c "^$cli\..*\.args$")
  n=$((n + 1))
  printf '%s\n' "$@" > "$FAKE_LOG/$cli.$n.args"
  printf '%s' "$prompt" > "$FAKE_LOG/$cli.$n.prompt"
  { pwd; ls -A | wc -l | tr -d ' '; echo "${DISABLE_PROMPT_CACHING:-unset}"; } > "$FAKE_LOG/$cli.$n.env"
  [ -z "${FAKE_WRITE:-}" ] || touch stray-file
}
answer() { # $1 who (good|weak), $2 prompt
  case "$2" in
    *"=== FILE files/cart.py ==="*)
      if [ "$1" = good ]; then printf 'BUG: files/cart.py:14 — add() replaces qty\n**BUG:** `files/cart.py:25` — discount is a fraction\n'
      else printf 'BUG: cart.py:13 — overwrites qty\nBUG: files/cart.py:20 — sum may overflow\n'; fi ;;
    *"=== FILE files/backup.sh ==="*)
      if [ "$1" = good ]; then printf 'BUG: files/backup.sh:13 — unquoted\nBUG: ./files/backup.sh:18 — deletes the newest\nBUG: files/backup.sh:18 — same again\n'
      else printf 'NO BUGS\n'; fi ;;
    *"=== FILE files/handbook/oncall.md ==="*)
      if [ "$1" = good ]; then printf 'Q1: 9\nQ2: **120 euros**\nQ3: Heron.\n'
      else printf 'Q1: How many days?\nQ1: 10\nQ2: 120\nQ3: heron\n'; fi ;;
    *"=== FILE files/changelog.md ==="*)
      if [ "$1" = good ]; then printf 'Q1: 5.0.0\nQ2: 4.2.0\n'; else printf 'Q1: 4.1.0\nQ2: 4.2\n'; fi ;;
    *) if [ "$1" = good ]; then echo "A clear note from the good writer."
       else echo "As a Gemini model, here is my note."; fi ;;
  esac
}
EOF
cat > "$tmp/bin/claude" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/fake-common"
[ "${1:-}" = --version ] && { echo "9.9.9 (fake claude)"; exit 0; }
prompt=$(cat)
log_call claude "$prompt" "$@"
if [ -n "${FAKE_CLAUDE_FAIL:-}" ]; then
  echo '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"","total_cost_usd":0.001}'; exit 1
fi
jq -n --arg r "$(answer good "$prompt")" '{type: "result", subtype: "success", is_error: false, result: $r,
  total_cost_usd: 0.0125, usage: {input_tokens: 700, output_tokens: 300, cache_read_input_tokens: 0, cache_creation_input_tokens: 0}}'
EOF
cat > "$tmp/bin/agy" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/fake-common"
# the prompt must be the argument right after -p, and the last one
prompt= prev= last=
for a in "$@"; do [ "$prev" = -p ] && prompt=$a; prev=$a; done
last=$prev
log_call agy "$prompt" "$@"
n=$(ls "$FAKE_LOG" | grep -c '^agy\..*\.args$')
ls -A > "$FAKE_LOG/agy.$n.ls"
[ -n "$prompt" ] && [ "$last" = "$prompt" ] && echo yes > "$FAKE_LOG/agy.$n.plast"
[ -n "$prompt" ] || { echo "agy: -p has no prompt" >&2; exit 3; }
# a pointer to prompt.md: read it, as the real agy does with its file tool
case "$prompt" in *prompt.md*) [ -f prompt.md ] && { cp prompt.md "$FAKE_LOG/agy.$n.file"; prompt=$(cat prompt.md); } ;; esac
answer weak "$prompt"
EOF
cat > "$tmp/bin/codex" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/fake-common"
[ "${1:-}" = --version ] && { echo "codex-cli 0.0.0-fake"; exit 0; }
prompt=$(cat)
log_call codex "$prompt" "$@"
o=
while [ $# -gt 0 ]; do [ "$1" = -o ] && o=$2; shift; done
echo "codex event stream"
answer good "$prompt" > "$o"
EOF
chmod +x "$tmp/bin/claude" "$tmp/bin/agy" "$tmp/bin/codex"
export PATH="$tmp/bin:$PATH" FAKE_LOG="$tmp/log" EVAL_MODELS_HOME="$tmp/home"
unset FAKE_CLAUDE_FAIL FAKE_WRITE EVAL_CLAUDE_EFFORT 2>/dev/null || true
calls() { ls "$FAKE_LOG" | grep -c "^$1\..*\.args$"; }
reset_log() { rm -f "$FAKE_LOG"/*; }
ex="$here/examples"
three=claude:claude-opus-5-5,agy:gemini-4-neon-high,codex:gpt-test@low

# --- run.sh ----------------------------------------------------------------
o=$("$sh" "$here/run.sh" "$ex" --dry-run 2>&1); rc=$?
has "$o" "claude 12" && ok "default models: Neon and Argon at high and medium, Opus at high and medium" || bad "default models" "$o"
if [ "$rc" = 0 ] && has "$o" "36 calls to make" && has "$o" "claude 12 (estimated \$" && has "$o" "agy 24 calls" \
   && has "$o" "r1-cart  review  ≈" && has "$o" "prompt cache off" && [ "$(ls "$FAKE_LOG" | wc -l | tr -d ' ')" = 0 ] \
   && [ ! -e "$tmp/home" ]; then ok "dry run counts calls, estimates cost, makes no call, writes nothing"
else bad "dry run" "$o"; fi

o=$("$sh" "$here/run.sh" "$ex" --dry-run --max-usd 0.01 2>&1)
has "$o" "over the per-call cap" && ok "dry run lists the calls over --max-usd" || bad "dry run over-cap list" "$o"

out="$tmp/run1"
o=$("$sh" "$here/run.sh" "$ex" --models "$three" --out "$out" 2>&1); rc=$?
if [ "$rc" = 0 ] && [ "$(find "$out/answers" -name '*.txt' | wc -l | tr -d ' ')" = 18 ] \
   && [ "$(wc -l < "$out/calls.jsonl" | tr -d ' ')" = 18 ] && jq -se 'all(.ok)' "$out/calls.jsonl" >/dev/null; then
  ok "full run with three fake CLIs answers all 18 calls"
else bad "full run" "$o"; fi
has "$o" "claude-opus-5-5@high: 6 calls (6 ok) · estimated \$" && has "$o" "actual \$0.075" \
  && has "$o" "gemini-4-neon-high: 6 agy calls" && ok "run prints actual vs estimated cost and the agy call count" \
  || bad "cost summary" "$o"

a=$(cat "$FAKE_LOG/claude.1.args")
e=$(cat "$FAKE_LOG/claude.1.env")
if has "$a" $'--tools\n\n' && has "$a" $'--effort\nhigh' && has "$a" $'--max-budget-usd\n0.50' \
   && has "$a" "--no-session-persistence" && has "$a" $'--setting-sources\n\n' && has "$a" "--system-prompt" \
   && [ "$(sed -n 3p <<< "$e")" = 1 ]; then ok "claude: tools off, no settings, effort high, budget cap, prompt cache off"
else bad "claude flags" "$a"$'\n'"$e"; fi
bad_cwd=0
for f in "$FAKE_LOG"/*.env; do
  d=$(sed -n 1p "$f"); c=$(sed -n 2p "$f")
  [ "$c" = 0 ] || bad_cwd=1
  case "$d" in "$here"*|"$out"*) bad_cwd=1 ;; esac
done
[ "$bad_cwd" = 0 ] && ok "every call ran in an empty temp dir" || bad "call cwd"
a=$(cat "$FAKE_LOG/agy.1.args")
if [ -f "$FAKE_LOG/agy.1.plast" ] && has "$a" $'--model\ngemini-4-neon-high' && has "$a" "--sandbox" \
   && has "$a" $'--print-timeout\n900s' && has "$(cat "$FAKE_LOG/agy.1.prompt")" "=== FILE files/handbook/oncall.md ==="; then
  ok "agy: prompt is the argument right after -p, with --model, --sandbox and --print-timeout"
else bad "agy flags" "$a"; fi
a=$(cat "$FAKE_LOG/codex.1.args")
has "$a" $'--sandbox\nread-only' && has "$a" 'model_reasoning_effort="low"' && has "$a" $'-m\ngpt-test' \
  && ok "codex: read-only sandbox, model and effort passed" || bad "codex flags" "$a"
p=$(cat "$out/prompts/r1-cart.txt")
has "$p" "   14          self.items[sku] = (price, qty)" && has "$p" "BUG: <path>:<line>" \
  && ! has "$(cat "$out/prompts/w1-release-note.txt")" "=== FILE" && ok "review prompts are line-numbered with a BUG: format line" \
  || bad "prompt build" "$p"
has "$(cat "$out/prompts/l1-handbook.txt")" "=== FILE files/handbook/expenses.md ===" \
  && ok "a directory in context: inlines every file under it" || bad "directory context"
jq -e '.prompt_cache | startswith("off")' "$out/run.json" >/dev/null && jq -e '.cli_versions.claude | test("fake")' "$out/run.json" >/dev/null \
  && ok "run.json records the cache setting and CLI versions" || bad "run.json" "$(cat "$out/run.json")"

reset_log
o=$("$sh" "$here/run.sh" "$ex" --models "$three" --out "$out" 2>&1)
has "$o" "nothing to do" && [ "$(ls "$FAKE_LOG" | wc -l | tr -d ' ')" = 0 ] && ok "a rerun makes no call that already has an answer" \
  || bad "rerun" "$o"
o=$("$sh" "$here/run.sh" "$ex" --models agy:gemini-4-argon-high --out "$out" 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(calls agy)" = 6 ] && [ "$(jq '.models | length' "$out/run.json")" = 4 ] \
  && ok "a later run with another model adds it to the same out" || bad "add model" "$o"

reset_log
o=$("$sh" "$here/run.sh" "$ex" --out "$tmp/cap" --max-usd 0.01 2>&1); rc=$?
[ "$rc" = 4 ] && has "$o" "passes the \$0.01 per-call cap" && [ "$(calls claude)" = 0 ] && [ "$(calls agy)" = 0 ] \
  && [ ! -e "$tmp/cap/calls.jsonl" ] && ok "--max-usd stops before any call when one claude estimate passes it" || bad "per-call cap ($rc)" "$o"

reset_log
o=$(FAKE_CLAUDE_FAIL=1 "$sh" "$here/run.sh" "$ex" --models claude:claude-opus-5-5 --only 'w*' --out "$tmp/fail" 2>&1); rc=$?
[ "$rc" = 1 ] && has "$o" "FAILED" && [ ! -e "$tmp/fail/answers/w1-release-note/claude_claude-opus-5-5_high.txt" ] \
  && jq -se 'map(.ok) == [false, false]' "$tmp/fail/calls.jsonl" >/dev/null && ok "a failed call is logged, leaves no answer, exits 1" \
  || bad "failure ($rc)" "$o"
o=$("$sh" "$here/run.sh" "$ex" --models claude:claude-opus-5-5 --only 'w*' --out "$tmp/fail" 2>&1); rc=$?
[ "$rc" = 0 ] && [ -s "$tmp/fail/answers/w1-release-note/claude_claude-opus-5-5_high.txt" ] && has "$o" "2 calls to make" \
  && ok "rerunning retries only the failed calls" || bad "retry" "$o"

reset_log
o=$("$sh" "$here/run.sh" "$ex" --models agy:gemini-4-neon-high --kind review,longctx --only 'r1*,l2*' --out "$tmp/only" 2>&1)
[ "$(calls agy)" = 2 ] && ok "--only and --kind pick the tasks" || bad "--only/--kind" "$o"

o=$(cd "$tmp" && "$sh" "$here/run.sh" "$ex" --models claude:claude-opus-5-5,agy:gemini-4-neon-high --only w1-release-note --out rel 2>&1); rc=$?
[ "$rc" = 0 ] && [ -s "$tmp/rel/answers/w1-release-note/agy_gemini-4-neon-high.txt" ] && ok "a relative --out works" || bad "relative --out" "$o"

o=$(FAKE_WRITE=1 "$sh" "$here/run.sh" "$ex" --models claude:claude-opus-5-5 --only w1-release-note --out "$tmp/dirty" 2>&1)
has "$o" "wrote files into its empty work dir" && jq -se '.[0].cwd_written' "$tmp/dirty/calls.jsonl" >/dev/null \
  && ok "a model that writes files is flagged" || bad "cwd_written" "$o"

# agy prompts over EVAL_AGY_INLINE_MAX go as prompt.md in the work dir
jq -se 'all(.delivery == "inline")' "$out/calls.jsonl" >/dev/null \
  && ok "prompts under the agy threshold (default 150000 bytes) go inline; every call records delivery" || bad "default delivery"
reset_log
o=$(EVAL_AGY_INLINE_MAX=1000 "$sh" "$here/run.sh" "$ex" --models agy:gemini-4-neon-high,claude:claude-opus-5-5 --dry-run 2>&1)
has "$o" "4 get the prompt as a file, being over 1000 bytes" && ok "dry run counts the agy calls that will get a file" || bad "dry-run file count" "$o"
o=$(EVAL_AGY_INLINE_MAX=1000 "$sh" "$here/run.sh" "$ex" --models agy:gemini-4-neon-high,claude:claude-opus-5-5 --out "$tmp/file" 2>&1); rc=$?
L="$tmp/file/calls.jsonl"
if [ "$rc" = 0 ] && jq -se '
     (map(select(.cli == "agy" and (.task | test("^[lr]")))) | length == 4 and all(.delivery == "file"))
     and (map(select(.cli == "agy" and (.task | test("^w")))) | length == 2 and all(.delivery == "inline"))
     and (map(select(.cli == "claude")) | all(.delivery == "inline"))
     and all(.cwd_written == false) and all(.ok)' "$L" >/dev/null \
   && ! has "$o" "wrote files"; then
  ok "agy: a prompt over the threshold goes as a file, under it inline; claude stays inline; prompt.md is not flagged"
else bad "file delivery ($rc)" "$o"$'\n'"$(cat "$L" 2>/dev/null)"; fi
fileok=1 inlineok=1
for f in "$FAKE_LOG"/agy.*.args; do
  n=${f%.args}; n=${n##*.}
  pr=$(cat "$FAKE_LOG/agy.$n.prompt")
  if [ -f "$FAKE_LOG/agy.$n.file" ]; then
    task=
    for t in "$tmp/file/prompts"/*.txt; do cmp -s "$t" "$FAKE_LOG/agy.$n.file" && task=$t; done
    { [ -n "$task" ] && [ "$(cat "$FAKE_LOG/agy.$n.ls")" = prompt.md ] && [ -f "$FAKE_LOG/agy.$n.plast" ] \
      && has "$pr" "Read all of prompt.md" && ! has "$pr" "=== FILE" && [ "${#pr}" -lt 1000 ]; } || fileok=0
  else
    { [ -z "$(cat "$FAKE_LOG/agy.$n.ls")" ] && has "$pr" "You are being evaluated"; } || inlineok=0
  fi
done
[ "$fileok" = 1 ] && [ "$(ls "$FAKE_LOG" | grep -c '^agy\..*\.file$')" = 4 ] \
  && ok "agy file delivery: -p is a short pointer, the work dir holds only prompt.md, byte for byte the saved prompt" \
  || bad "file delivery argv/cwd" "$(cat "$FAKE_LOG"/agy.1.args)"
[ "$inlineok" = 1 ] && ok "agy inline delivery: whole prompt after -p, empty work dir" || bad "inline delivery argv/cwd"
s=$("$sh" "$here/score.sh" "$tmp/file" 2>&1)
has "$s" "longctx 60% (3/5)" && ok "an agy model that got its prompt as a file is scored on it" || bad "score after file delivery" "$s"
o=$(FAKE_WRITE=1 EVAL_AGY_INLINE_MAX=1000 "$sh" "$here/run.sh" "$ex" --models agy:gemini-4-neon-high --only l2-changelog --out "$tmp/filedirty" 2>&1)
has "$o" "wrote files into its empty work dir" && jq -se '.[0].delivery == "file" and .[0].cwd_written == true' "$tmp/filedirty/calls.jsonl" >/dev/null \
  && ok "with file delivery, anything besides prompt.md is still flagged" || bad "file delivery dirty" "$o"
o=$(EVAL_AGY_INLINE_MAX=lots "$sh" "$here/run.sh" "$ex" --dry-run 2>&1); rc=$?
[ "$rc" = 2 ] && has "$o" "EVAL_AGY_INLINE_MAX wants a whole number" && ok "rejects a non-numeric EVAL_AGY_INLINE_MAX" || bad "bad threshold" "$o"

# the token estimate: 2 bytes a token, below every measured Claude ratio (2.08 the lowest)
o=$("$sh" -c '. "$1/lib.sh"; est_tokens 575000; echo; est_tokens 3; echo; est_tokens 0' _ "$here" 2>&1)
[ "$o" = $'287500\n2\n0' ] && ok "est_tokens: bytes ÷ 2, rounded up, so dense input is not undershot" || bad "est_tokens" "$o"
o=$("$sh" "$here/run.sh" "$ex" --dry-run 2>&1)
has "$o" "l1-handbook  longctx  ≈1032 tokens in (2063 bytes" && ok "dry run shows the ÷ 2 estimate" || bad "dry-run estimate" "$o"

reset_log
o=$("$sh" "$here/run.sh" "$ex" --models claude:claude-opus-5-5,claude:claude-opus-5-5@high,claude:claude-opus-5-5@medium \
  --only w1-release-note --out "$tmp/eff" 2>&1); rc=$?
if [ "$rc" = 0 ] && [ "$(calls claude)" = 2 ] && has "$(cat "$FAKE_LOG/claude.1.args")" $'--effort\nhigh' \
   && has "$(cat "$FAKE_LOG/claude.2.args")" $'--effort\nmedium' \
   && jq -se 'map(.effort) == ["high", "medium"] and map(.model) == ["claude:claude-opus-5-5@high", "claude:claude-opus-5-5@medium"]' "$tmp/eff/calls.jsonl" >/dev/null \
   && [ -s "$tmp/eff/answers/w1-release-note/claude_claude-opus-5-5_medium.txt" ] && [ "$(jq '.models | length' "$tmp/eff/run.json")" = 2 ]; then
  ok "claude@effort: one model per effort, --effort passed, effort recorded; claude:x is claude:x@high"
else bad "claude effort" "$o"; fi

# suites by name and the default out folder, both under EVAL_MODELS_HOME
mkdir -p "$tmp/home/suites" && cp -R "$ex" "$tmp/home/suites/mine"
o=$("$sh" "$here/run.sh" mine --models agy:gemini-4-neon-high --only w1-release-note 2>&1); rc=$?
[ "$rc" = 0 ] && ls -d "$tmp/home/runs/mine-"* >/dev/null 2>&1 && ok "a suite name resolves under EVAL_MODELS_HOME/suites; out defaults to …/runs" \
  || bad "default paths" "$o"
d=$(ls -d "$tmp/home/runs/mine-"* | head -n 1)
printf '\nOne more sentence.\n' >> "$tmp/home/suites/mine/tasks/w1-release-note.md"
o=$("$sh" "$here/run.sh" mine --models agy:gemini-4-neon-high --only w1-release-note --out "$d" 2>&1); rc=$?
[ "$rc" = 2 ] && has "$o" "changed since" && ok "a task edited after its answers refuses the old out" || bad "changed task" "$o"

# malformed tasks
bt() { # bt <name> <expected message> <task text>
  rm -rf "$tmp/bad"; mkdir -p "$tmp/bad/tasks"; printf '%s\n' "$3" > "$tmp/bad/tasks/t.md"
  o=$("$sh" "$here/run.sh" "$tmp/bad" --dry-run 2>&1); rc=$?
  [ "$rc" = 2 ] && has "$o" "$2" && ok "rejects $1" || bad "rejects $1" "$o"
}
bt "a header line that is not key: value" "is not 'key: value'" $'kind: writing\nwrite a poem'
bt "an unknown header key" "unknown header key 'kinds'" $'kinds: review\n---\nx'
bt "a header with no --- line" "no --- line" $'kind: writing\ntitle: a poem'
bt "a review task with no key" "needs bug: lines" $'kind: review\n---\nreview it'
bt "a malformed bug line" "is not \"<id> <path>:<line>" $'kind: review\nbug: B1 cart.py\n---\nx'
bt "a context glob that matches nothing" "matches nothing" $'kind: writing\ncontext: nope/*.md\n---\nx'
bt "a bad kind" "kind is 'essay'" $'kind: essay\n---\nx'

o=$("$sh" "$here/run.sh" "$ex" --models agy:gemini-4-neon-high@high --dry-run 2>&1)
has "$o" "the effort is part of the model id" && ok "agy refuses an @effort suffix" || bad "agy @effort" "$o"

# --- score.sh --------------------------------------------------------------
o=$("$sh" "$here/score.sh" "$out" 2>&1); rc=$?
s="$out/scores.json"
if [ "$rc" = 0 ] && jq -e '
  (.rows | map(select(.model == "claude:claude-opus-5-5@high" and .kind == "review")) | map(.found) == [2, 2])
  and (.rows | map(select(.model == "claude:claude-opus-5-5@high" and .task == "r2-backup"))[0] | .false_positives == [] and .reported == 2)
  and (.rows | map(select(.model == "agy:gemini-4-neon-high" and .task == "r1-cart"))[0] | .found == 1 and .false_positives == ["files/cart.py:20"])
  and (.rows | map(select(.model == "agy:gemini-4-neon-high" and .task == "r2-backup"))[0] | .found == 0 and .reported == 0)
  ' "$s" >/dev/null; then ok "review: file:line within tolerance, path suffixes, duplicates and false positives"
else bad "review scoring" "$o"; fi
if jq -e '
  (.models[] | select(.model == "claude:claude-opus-5-5@high") | .longctx == {correct: 5, total: 5})
  and (.models[] | select(.model == "agy:gemini-4-neon-high") | .longctx == {correct: 3, total: 5})
  and (.rows | map(select(.model == "agy:gemini-4-neon-high" and .task == "l1-handbook"))[0].wrong == [{id: "Q1", got: "10"}])
  ' "$s" >/dev/null; then ok "longctx: last answer line counts; case, markdown and trailing dots ignored"
else bad "longctx scoring" "$o"; fi
has "$o" "review recall 100% (4/4) precision 100%" && has "$o" "longctx 60% (3/5)" && has "$o" "== cost" \
  && ok "score prints per-model recall, precision, longctx and cost" || bad "score output" "$o"

# --- blind.sh --------------------------------------------------------------
o=$("$sh" "$here/blind.sh" "$out" pairs make --seed 7 2>&1); rc=$?
if [ "$rc" = 0 ] && [ "$(jq '.pairs | length' "$out/pairs.json")" = 12 ] && [ "$(jq 'del(.created, .seed) | length' "$out/pairs-key.json")" = 12 ]; then
  ok "make: every model pair on each writing task (2 tasks × 6 pairs)"
else bad "blind make" "$o"; fi
if ! grep -qiE 'claude|gemini|codex|agy|opus|neon|argon' "$out/pairs.json" && ! ls "$out/blind" | grep -qiE 'claude|gemini|codex'; then
  ok "pairs.json and the side files name no model"
else bad "pairs leak model names" "$(cat "$out/pairs.json")"; fi
has "$o" "names a model or vendor" && ok "make warns when an answer names a model" || bad "leak warning" "$o"
jq -e '.version == 1 and (.pairs[0] | has("id") and has("task") and has("prompt") and has("a") and has("b"))' "$out/pairs.json" >/dev/null \
  && ok "pairs.json is plain {version, pairs: [{id, task, prompt, a, b}]}" || bad "pairs.json shape"
cp "$out/pairs.json" "$tmp/pairs.7"
"$sh" "$here/blind.sh" "$out" pairs make --seed 7 --force >/dev/null 2>&1
cmp -s "$out/pairs.json" "$tmp/pairs.7" || jq -e --slurpfile a "$tmp/pairs.7" '.pairs == $a[0].pairs' "$out/pairs.json" >/dev/null \
  && ok "the same seed gives the same pairs" || bad "seeded order"
side_of() { jq -r --arg id "$1" --arg m "$2" '.[$id] | if .A == $m then "a" elif .B == $m then "b" else "t" end' "$out/pairs-key.json"; }
# vote for claude whenever it is in the pair, a tie otherwise; first a bad key, then quit halfway
: > "$tmp/votes.in"
n=0
for id in $(jq -r '.pairs[].id' "$out/pairs.json"); do
  n=$((n + 1)); [ "$n" = 1 ] && echo x >> "$tmp/votes.in"
  side_of "$id" claude:claude-opus-5-5@high >> "$tmp/votes.in"
  [ "$n" = 5 ] && echo q >> "$tmp/votes.in"
done
o=$("$sh" "$here/blind.sh" "$out" pairs vote < "$tmp/votes.in" 2>&1)
[ "$(wc -l < "$out/pairs-votes.jsonl" | tr -d ' ')" = 5 ] && has "$o" "a, b, t, s or q" && has "$o" "--- A ---" \
  && ok "vote: shows the prompt and both sides, re-asks a bad key, q stops" || bad "vote" "$o"
o=$("$sh" "$here/blind.sh" "$out" pairs status 2>&1)
has "$o" "pairs: 12, 5 voted" && ok "status counts votes" || bad "status" "$o"
sed -n '/^q$/,$p' "$tmp/votes.in" | sed 1d > "$tmp/votes.rest"
"$sh" "$here/blind.sh" "$out" pairs vote < "$tmp/votes.rest" >/dev/null 2>&1
[ "$(wc -l < "$out/pairs-votes.jsonl" | tr -d ' ')" = 12 ] && ok "vote resumes at the first unvoted pair" || bad "vote resume"
o=$("$sh" "$here/blind.sh" "$out" pairs reveal 2>&1); rc=$?
[ "$rc" = 0 ] && has "$o" "100%  won 6 lost 0 tied 0 of 6" \
  && has "$o" "33%  won 0 lost 2 tied 4 of 6" \
  && has "$o" "agy:gemini-4-neon-high vs claude:claude-opus-5-5@high: 0–2" && has "$o" "12 of 12 pairs voted" \
  && ok "reveal: win rate per model (tie = half), head to head, per pair" || bad "reveal" "$o"
o=$("$sh" "$here/blind.sh" "$out" pairs make 2>&1); rc=$?
[ "$rc" = 2 ] && has "$o" "already has votes" && ok "make refuses to replace voted pairs without --force" || bad "make guard" "$o"

# --- blind.sh lineup ------------------------------------------------------
o=$("$sh" "$here/blind.sh" "$out" make --seed 3 2>&1); rc=$?
L="$out/lineup.json" K="$out/lineup-key.json"
if [ "$rc" = 0 ] && jq -e '.version == 1 and (.tasks | length) == 2 and all(.tasks[]; (.drafts | length) == 4)
     and .verdicts == ["ship as-is", "light edit", "rewrite"] and (.tags | length) == 6 and .tags[3] == "sounds like AI/hype"
     and (.tasks[0] | has("task") and has("prompt") and has("group")) and (.tasks[0].drafts[0] | .label == "Draft 1" and has("file"))' "$L" >/dev/null \
   && jq -e 'all(.tasks[]; [.[]] | unique | length == 4)' "$K" >/dev/null; then
  ok "lineup make: every model's draft per task as Draft 1..N, tags from the suite's tags.txt"
else bad "lineup make" "$o"; fi
! grep -qiE 'claude|gemini|codex|agy|opus|neon|argon' "$L" && ! find "$out/lineup" | grep -qiE 'claude|gemini|codex' \
  && has "$o" "Draft" && has "$o" "names a model or vendor" && ok "lineup.json and draft files name no model; leaks are flagged" \
  || bad "lineup leaks" "$o"
label_of() { jq -r --arg t "$1" --arg m "$2" '.tasks[$t] | to_entries[] | select(.value == $m) | .key | ltrimstr("Draft ")' "$K"; }
interview() { # answers for one task: claude ships and wins, neon rewrite + 2 tags, argon light edit + a bad tag first
  local task=$1 i m
  for i in 1 2 3 4; do
    m=$(jq -r --arg t "$task" --arg l "Draft $i" '.tasks[$t][$l]' "$K")
    case "$m" in
      claude:*) printf 's\n\ngreat opening\n' ;;
      *neon*) printf 'r\n4 6\n\n' ;;
      *argon*) printf 'maybe\nl\n1,99\n1\n\n' ;;
      *) printf 'l\n\n\n' ;;
    esac
  done
  label_of "$task" claude:claude-opus-5-5@high
}
{ interview w1-release-note; echo q; } > "$tmp/lineup.in"
o=$("$sh" "$here/blind.sh" "$out" vote < "$tmp/lineup.in" 2>&1)
if [ "$(wc -l < "$out/lineup-votes.jsonl" | tr -d ' ')" = 1 ] && has "$o" "---------- Draft 4 ----------" && has "$o" "s, l or r" \
   && has "$o" "tag numbers from 1 to 6" && jq -e --arg top "Draft $(label_of w1-release-note claude:claude-opus-5-5@high)" '
     .task == "w1-release-note" and .top == $top and (.drafts | length) == 4
     and ([.drafts[] | select(.note == "great opening")] | length) == 1
     and ([.drafts[] | select(.tags == ["overclaims", "sounds like AI/hype"])] | length) == 1' "$out/lineup-votes.jsonl" >/dev/null; then
  ok "lineup vote: all drafts shown, verdict + tags + note per draft, one top pick, bad input re-asked, q stops"
else bad "lineup vote" "$o"; fi
interview w2-error-message > "$tmp/lineup2.in"
"$sh" "$here/blind.sh" "$out" vote < "$tmp/lineup2.in" >/dev/null 2>&1
o=$("$sh" "$here/blind.sh" "$out" status 2>&1)
has "$o" "lineup: 2 tasks, 2 judged" && has "$o" "pairs: 12, 12 voted" && ok "lineup vote resumes; status shows both modes" || bad "lineup status" "$o"
o=$("$sh" "$here/blind.sh" "$out" reveal 2>&1); rc=$?
if [ "$rc" = 0 ] && has "$o" "2 of 2 tasks judged" \
   && grep -q 'claude:claude-opus-5-5@high .* top pick 100% (2/2) · ship or light edit 100% · ship as-is 100%$' <<< "$o" \
   && grep -q 'agy:gemini-4-neon-high .* top pick 0% (0/2) · ship or light edit 0% · ship as-is 0% · tags overclaims ×2, sounds like AI/hype ×2' <<< "$o" \
   && grep -q 'agy:gemini-4-argon-high .* ship or light edit 100% · ship as-is 0% · tags too long ×2' <<< "$o" \
   && has "$o" "== per model and task group" && has "$o" "w1-release-note: claude:claude-opus-5-5@high" && has "$o" "label bias"; then
  ok "lineup reveal: top-pick rate, ship-or-light-edit rate and top tags per model and per group"
else bad "lineup reveal" "$o"; fi
o=$("$sh" "$here/blind.sh" "$out" make 2>&1); rc=$?
[ "$rc" = 2 ] && has "$o" "already has judgements" && ok "lineup make refuses to replace judged lineups without --force" || bad "lineup guard" "$o"

echo
echo "$pass passed, $fail failed ($("$sh" -c 'echo $BASH_VERSION'))"
[ "$fail" = 0 ]
