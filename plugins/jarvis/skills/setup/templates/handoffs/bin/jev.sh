#!/usr/bin/env bash
# jev.sh — optional Jev (TypeSafe System One) helper for Jarvis.
#
#   jev.sh brief <brief.md>            lint the brief; log a shadow routing verdict
#   jev.sh triage <terminalId>...      one status line per worker terminal
#   jev.sh outcome <brief.md> <clean|corrected|escalated|respawned>
#   jev.sh report                      summarise handoffs/.jev/log.jsonl
#   --dry-run (anywhere)               print the request payload, send nothing
#
# Jev advises, never decides. Fail-open: no TYPESAFE_API_KEY, no jq/curl, an API
# error or a timeout prints "jev: skipped (<reason>)" and exits 0, and Jarvis
# carries on with the prose rules. Works on the stock macOS bash (3.2).
set -u

API="${TYPESAFE_API_URL:-https://api.typesafe.ai/v1/systemone}"
MODEL="${JEV_MODEL:-jev-latest}"
LOG_DIR="${JEV_LOG_DIR:-handoffs/.jev}"
LOG="$LOG_DIR/log.jsonl"
FLOOR="${JEV_CONFIDENCE_FLOOR:-0.6}"
DRY=0

# Provider limit messages are matched by rule before any model is asked: the red
# band is too important to leave to a classifier.
LIMIT_RE="(usage|rate|session|weekly|daily|hourly|5-hour) limit (was |has been )?(reached|exceeded|hit)|(hit|reached|exceeded) (your|the) [a-z0-9 -]*limit|limit reached|quota (was |has been )?(exceeded|exhausted)|out of credits|too many requests"

skip() { echo "jev: skipped ($1)"; exit 0; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log_row() { mkdir -p "$LOG_DIR" 2>/dev/null && printf '%s\n' "$1" >> "$LOG"; }

ready() { # prints the reason and returns 1 when Jev can't be used
  command -v jq >/dev/null 2>&1 || { echo "jq not installed"; return 1; }
  command -v curl >/dev/null 2>&1 || { echo "curl not installed"; return 1; }
  [ "$DRY" = 1 ] || [ -n "${TYPESAFE_API_KEY:-}" ] || { echo "TYPESAFE_API_KEY not set"; return 1; }
}

# Strip ANSI escapes and mask anything secret-shaped before it leaves the machine.
# Shapes follow auto-model-router's scrubber (MIT). A net, not a guarantee: it
# errs toward masking too much (`name: value` after a credential-like name), and text with no recognisable shape gets through.
clean() {
  sed -E $'s/\x1b\\[[0-9;?]*[A-Za-z]//g' | awk '
    BEGIN {
      for (k in ENVIRON) if (length(ENVIRON[k]) >= 8 && toupper(k) ~ /KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL/) v[++n] = ENVIRON[k]
    }
    /-----BEGIN [A-Z ]*(PRIVATE KEY|CERTIFICATE)-----/ { print "[REDACTED]"; if ($0 !~ /-----END /) pem = 1; next }
    pem { if ($0 ~ /-----END /) pem = 0; next }
    {
      for (i = 1; i <= n; i++) {
        out = ""
        while ((at = index($0, v[i])) > 0) { out = out substr($0, 1, at - 1) "[REDACTED]"; $0 = substr($0, at + length(v[i])) }
        $0 = out $0
      }
      print
    }' | sed -E \
    -e 's/(^|[^A-Za-z])([Kk][Ee][Yy]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss][Ww][Oo]?[Rr]?[Dd]|[Cc][Rr][Ee][Dd][Ee][Nn][Tt][Ii][Aa][Ll])(s?([_.-][A-Za-z0-9_.-]{0,40}|[A-Z0-9_]{0,40})?["'"'"']?[ \t]*[:=][ \t]*)("[^"]*"|'"'"'[^'"'"']*'"'"'|[^][:space:],;}]{4,})/\1\2\3[REDACTED]/g' \
    -e 's/([a-z])(Key|Token|Secret|Password|Credential)(s?([_.-][A-Za-z0-9_.-]{0,40}|[A-Z0-9_]{0,40})?["'"'"']?[ \t]*[:=][ \t]*)("[^"]*"|'"'"'[^'"'"']*'"'"'|[^][:space:],;}]{4,})/\1\2\3[REDACTED]/g' \
    -e 's/eyJ[A-Za-z0-9_-]{8,}(\.[A-Za-z0-9._-]+)?/[REDACTED]/g' \
    -e 's/(sk|pk|rk)[-_][A-Za-z0-9_-]{12,}/[REDACTED]/g' \
    -e 's/(gh[pousr]|xox[abprs]|glpat|github_pat|hf)[-_][A-Za-z0-9_-]{12,}/[REDACTED]/g' \
    -e 's/AIza[A-Za-z0-9_-]{30,}/[REDACTED]/g' \
    -e 's/(AKIA|ASIA|AGPA|AIDA|AROA)[A-Z0-9]{16}/[REDACTED]/g' \
    -e 's/((Set-)?Cookie: *[A-Za-z0-9_.-]+=)[^;[:space:]]+/\1[REDACTED]/g' \
    -e 's/(Bearer|Basic|bearer|basic) +[A-Za-z0-9._~+\/=-]{8,}/\1 [REDACTED]/g' \
    -e 's#([A-Za-z][A-Za-z0-9+.-]*://)[^[:space:]/@:]+:[^[:space:]/@]+@#\1[REDACTED]@#g'
}

# $1 = payload JSON. Prints the response JSON plus {seconds}. Returns 3 on
# --dry-run (payload printed instead), 1 on any failure.
ask() {
  local out code try
  if [ "$DRY" = 1 ]; then printf '%s' "$1" | jq .; return 3; fi
  for try in 1 2; do
    out=$(printf '%s' "$1" | curl -sS --max-time 8 -w '\n%{http_code} %{time_total}' \
      -H "Authorization: Bearer $TYPESAFE_API_KEY" -H 'Content-Type: application/json' \
      --data-binary @- "$API" 2>/dev/null) || return 1
    code=$(printf '%s\n' "$out" | tail -n 1 | cut -d' ' -f1)
    case "$code" in
      200)
        printf '%s\n' "$out" | sed '$d' | jq -c \
          --arg s "$(printf '%s\n' "$out" | tail -n 1 | cut -d' ' -f2)" \
          'select(.answers) | . + {seconds: ($s | tonumber)}' | grep . || return 1
        return 0 ;;
      429|529) [ "$try" = 1 ] && sleep 1 ;;
      *) return 1 ;;
    esac
  done
  return 1
}

# ---------------------------------------------------------------- brief

brief_payload() { # $1 = state text
  jq -n --arg model "$MODEL" --arg state "$1" '
    def noul(i; t; f): {type: "noul", instructions: i, criteria: {"true": t, "false": f}};
    {model: $model, state: $state, questions: {
      lint_files: noul(
        "Does this task brief name at least one specific file, by its path, that the worker should edit or create?";
        "A concrete file path ending in a file name (for example src/ingest/x.py) is named as a file to change or create.";
        "Only directories, globs, modules or general areas are named, or no paths at all."),
      lint_pattern: noul(
        "Does this task brief point to an existing file, function or earlier change that the worker should copy or follow as a pattern?";
        "It names existing code or a prior change to imitate (for example: follow src/ingest/x.py).";
        "No existing example to imitate is named."),
      lint_done: noul(
        "Does this task brief describe the finished result and also give at least one concrete shell command whose output proves the task is finished?";
        "Both are present: a description of the finished result and a runnable command that proves it.";
        "The finished result is not described, or no runnable proving command is given."),
      lint_fence: noul(
        "Does this task brief list both the paths the worker may touch and the paths it must not touch?";
        "Both lists are present and name real paths.";
        "One or both lists are missing, empty or left as placeholders."),
      lint_prior: noul(
        "Does this task brief either link an earlier handoff or decision document, or state outright that there is no prior context?";
        "It links an earlier handoff or decision document, or says plainly that none exists.";
        "It does neither."),
      done_verifiable: noul(
        "Could a reviewer decide whether this task was finished correctly using only this brief, by running the checks it names?";
        "The brief fixes what done means and how to verify it.";
        "The worker has to decide for itself what done means."),
      shape_undecided: noul(
        "Does this task require the worker to design or choose the shape of something that the brief leaves open, such as a schema, a subsystem, an interface, or a prompt or evaluation strategy?";
        "A design decision is left to the worker.";
        "The design is already decided in the brief."),
      cause_unknown: noul(
        "Is this task about a bug or failure whose cause the brief says is unknown or not yet found?";
        "The cause is unknown and the worker must find it.";
        "There is no bug, or its cause is already stated."),
      media_asset: noul(
        "Does this task require creating, editing or resizing images or other media assets, such as logos, icons or screenshots?";
        "Producing or changing media assets is part of the task.";
        "No media assets are produced or changed."),
      computer_use: noul(
        "Does this task require operating an application through its graphical interface, clicking and typing through it, in order to test it?";
        "The worker must drive a graphical interface.";
        "Everything can be done with code, files and shell commands."),
      security: noul(
        "Is this task primarily security work, such as an audit, hardening, a vulnerability or dependency review, or threat modelling?";
        "Security is the main purpose of the task.";
        "Security is not the main purpose of the task."),
      touches_secrets: noul(
        "Does this task require the worker to use real credentials or real user data, rather than fixtures?";
        "Real credentials or real user data are needed.";
        "Fixtures or no sensitive data are enough."),
      size: {type: "score", instructions: "How much work does this task involve?", criteria: [
        "A mechanical edit: a rename, a reformat, moving files, or a one-line fix.",
        "A small scoped change, documentation, an audit or a summary.",
        "Substantial work: a feature, or a change across several files."]}
    }}'
}

cmd_brief() {
  local f="${1:-}" reason header state resp rc row band
  [ -n "$f" ] && [ -f "$f" ] || { echo "jev: no such brief: $f" >&2; exit 2; }
  reason=$(ready) || skip "$reason"

  # The header carries Jarvis's own worker/model/effort; Jev must not see it.
  header=$(awk '/^## /{exit} {print}' "$f")
  state=$( { sed -n '1p' "$f"; awk '/^## Questions first/{exit} /^## /{p=1} p' "$f"; } | clean )
  band=$(sed -n 's/^Usage band:[[:space:]]*\([a-z]*\).*/\1/p' handoffs/OPEN.md 2>/dev/null | head -n 1)

  resp=$(ask "$(brief_payload "$state")"); rc=$?
  [ $rc = 3 ] && { printf '%s\n' "$resp"; exit 0; }
  [ $rc = 0 ] || skip "TypeSafe API unavailable"

  row=$(printf '%s' "$resp" | jq -c --arg ts "$(now)" --arg brief "$f" --arg band "$band" \
    --arg worker "$(printf '%s\n' "$header" | sed -n 's/^worker:[[:space:]]*//p' | head -n 1)" \
    --arg jmodel "$(printf '%s\n' "$header" | sed -n 's/^model:[[:space:]]*//p' | head -n 1)" \
    --arg effort "$(printf '%s\n' "$header" | sed -n 's/^effort:[[:space:]]*//p' | head -n 1)" '
    # Claude aliases by their canonical name, as bin/jarvis model_canon does
    def tier_of: if type != "string" then null else (ascii_downcase | sub("\\[.*$"; "")) as $m
      | if ($m | test("fable")) then "top"
        elif ($m | test("^(opus|claude-opus-)")) then "workhorse"
        elif ($m | test("^(sonnet|claude-sonnet-)")) then "light"
        elif ($m | test("^(haiku|claude-haiku-)")) then "trivial"
        else {"gpt-6-astra":"top","gpt-5.6-sol":"workhorse","gpt-5.6-terra":"light","gpt-5.6-luna":"trivial"}[$m] // null end end;
    def p(k): .answers[k].noul // 0;
    . as $r
    # "opus (amber band; fable-tier task)" was a fable-tier call: compare on intent.
    | (($jmodel | capture("(?<m>[a-z0-9.-]+)-tier").m) // ($jmodel | split(" ")[0])) as $intended
    | {ts: $ts, kind: "brief", brief: $brief, band: $band,
       jarvis: {worker: $worker, model: $jmodel, effort: $effort, tier: ($intended | tier_of)},
       lint: {files: p("lint_files"), pattern: p("lint_pattern"), done: p("lint_done"),
              fence: p("lint_fence"), prior: p("lint_prior")},
       route: {done_verifiable: p("done_verifiable"), shape_undecided: p("shape_undecided"),
               cause_unknown: p("cause_unknown"), media_asset: p("media_asset"),
               computer_use: p("computer_use"), security: p("security"),
               touches_secrets: p("touches_secrets"),
               size: $r.answers.size.score, size_confidence: $r.answers.size.confidence},
       # an unverifiable brief is only top-tier when the work is substantial: a typo fix
       # with no check command is a thin brief, not an undecided task
       jev_tier: (if p("shape_undecided") >= 0.5 or p("cause_unknown") >= 0.5
                     or (p("done_verifiable") < 0.5 and (($r.answers.size.score // 0) | round) == 2)
                  then "top"
                  else (["trivial","light","workhorse"][($r.answers.size.score // -1) | round] // "unknown") end),
       jev_agent: (if p("media_asset") >= 0.5 or p("computer_use") >= 0.5 then "codex/gpt-6-astra"
                   elif p("security") >= 0.5 then "codex/gpt-5.6-sol" else null end),
       input_tokens: $r.usage.input_tokens, seconds: $r.seconds}') || skip "unexpected API response"
  log_row "$row"

  # Shadow mode: the routing verdict is logged, never printed, so it can't anchor Jarvis.
  printf '%s' "$row" | jq -r '
    def why: {files: "names the exact files", pattern: "names an existing pattern to copy",
      done: "states done + the command that proves it", fence: "fences may-touch and must-not-touch",
      prior: "links the prior handoff (or says there is none)"};
    .lint as $l
    | [$l | to_entries[] | select(.value < 0.5)] as $miss
    | if ($miss | length) == 0 then "jev: brief ok (5/5)"
      else "jev: brief lint — \($miss | length) of 5 missing; sharpen the brief, or if these can'"'"'t be written it'"'"'s a fable/split case",
           ($miss[] | "  ✗ \(.key)\t\(why[.key]) (\(.value * 100 | round / 100))") end'
  # `prior` is advice only: a fresh task has no earlier handoff to link.
  printf '%s' "$row" | jq -e '[.lint.files, .lint.pattern, .lint.done, .lint.fence] | all(. >= 0.5)' >/dev/null || exit 1
}

# ---------------------------------------------------------------- triage

triage_payload() { # $1 = terminal text
  jq -n --arg model "$MODEL" --arg state "$1" '{model: $model, state: $state, questions: {state: {
    type: "choice",
    instructions: "This is the bottom of a coding agent'"'"'s terminal. Judging by the last lines, what is the agent doing right now?",
    criteria: {
      working: "Actively running: a tool call, command, edit or thinking is in progress, often with a spinner or an interrupt hint.",
      waiting_for_answer: "Idle after asking the user a question it needs answered before it can continue.",
      permission_prompt: "A dialog is asking the user to approve or deny a command, edit or tool, with options such as Yes and No.",
      usage_limit: "A usage, rate or quota limit message from the agent'"'"'s provider is stopping it.",
      finished: "Idle after completing its task and summarising it; nothing more is needed from the user.",
      looping_or_stuck: "Repeating the same failing command or edit several times without progress.",
      crashed: "The agent process has exited or errored out to a shell prompt."}},
    repeating: {type: "noul",
      instructions: "Does this terminal show the same command or the same edit failing three or more times in a row?",
      criteria: {"true": "The same command or edit appears three or more times, each time followed by the same failure.",
                 "false": "No command or edit is shown failing three or more times in a row."}}}}'
}

triage_one() { # $1 = id, $2 = file ("" = read the live terminal), $3 = jev usable (1/0)
  local id="$1" src="$2" jev="$3" text tail_ state="" conf="" source="" note="" resp rc read shown=0
  if [ -n "$src" ]; then text=$(cat "$src" 2>/dev/null)
  else
    # through jarvis, so it reads the terminal on whichever host the workers run on
    text=$("$(dirname "$0")/jarvis" read "$id" 60 2>/dev/null)
  fi
  [ -n "$text" ] || { echo "$id unreadable — check it with handoffs/bin/jarvis read $id"; return; }
  # trailing spaces off, blank runs collapsed: a TUI screen is mostly padding
  text=$(printf '%s\n' "$text" | clean | sed -e 's/[[:space:]]*$//' | awk 'NF{b=0; print; next} !b{print; b=1}')
  read=$(printf '%s\n' "$text" | wc -l | tr -d ' ')
  tail_=$(printf '%s\n' "$text" | tail -n 15)

  if printf '%s\n' "$tail_" | grep -Eiq "$LIMIT_RE"; then state=usage_limit; conf=1; source=rule; fi
  if [ "$jev" = 1 ]; then
    resp=$(ask "$(triage_payload "$text")"); rc=$?
    if [ $rc = 3 ]; then printf '%s\n' "$resp"; return; fi
    if [ $rc = 0 ]; then
      if [ -z "$state" ]; then
        state=$(printf '%s' "$resp" | jq -r '.answers.state.choice'); source=jev
        conf=$(printf '%s' "$resp" | jq -r '.answers.state.confidence')
        # "Working..." on the fourth identical failure is still a loop
        if [ "$state" = working ] && printf '%s' "$resp" | jq -e '(.answers.repeating.noul // 0) >= 0.5' >/dev/null; then
          state=looping_or_stuck; conf=$(printf '%s' "$resp" | jq -r '.answers.repeating.noul')
        fi
      else
        note=" · jev: $(printf '%s' "$resp" | jq -r '"\(.answers.state.choice) \(.answers.state.confidence * 100 | round / 100)"')"
      fi
    fi
  fi

  if [ -z "$state" ]; then # no verdict: behave as before and show the screen
    echo "$id unclassified"; printf '%s\n' "$text" | tail -n 25 | sed 's/^/    /'; shown=$((read < 25 ? read : 25))
  else
    printf '%s %s (%s%s)\n' "$id" "$state" "$(printf '%.2f' "$conf")" "$note"
    if [ "$state" != working ] || awk "BEGIN{exit !($conf < $FLOOR)}"; then
      printf '%s\n' "$tail_" | sed 's/^/    /'; shown=$((read < 15 ? read : 15))
    fi
  fi
  [ "$jev" = 1 ] && log_row "$(jq -nc --arg ts "$(now)" --arg id "$id" --arg state "${state:-unclassified}" \
    --arg conf "${conf:-0}" --arg source "${source:-none}" --argjson read "$read" --argjson shown "$shown" \
    '{ts: $ts, kind: "triage", terminal: $id, state: $state, confidence: ($conf | tonumber),
      source: $source, lines_read: $read, lines_shown: $shown}')"
}

cmd_triage() {
  local jev=1 reason tmp i=0 id src pids=""
  [ $# -gt 0 ] || { echo "usage: jev.sh triage <terminalId>... | --file <path>..." >&2; exit 2; }
  reason=$(ready) || { jev=0; echo "jev: skipped ($reason) — showing terminal tails"; }
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/jev.XXXXXX") || exit 0
  while [ $# -gt 0 ]; do
    if [ "$1" = --file ]; then src="${2:-}"; id=$(basename "$src"); shift 2 || break
    else src=""; id="$1"; shift; fi
    i=$((i + 1))
    triage_one "$id" "$src" "$jev" > "$tmp/$(printf '%04d' "$i")" 2>/dev/null &
    pids="$pids $!"
  done
  # shellcheck disable=SC2086
  wait $pids
  cat "$tmp"/* 2>/dev/null
  rm -rf "$tmp"
}

# ---------------------------------------------------------------- outcome / report

cmd_outcome() {
  local f="${1:-}" o="${2:-}"
  case "$o" in clean|corrected|escalated|respawned) ;;
    *) echo "usage: jev.sh outcome <brief.md> <clean|corrected|escalated|respawned>" >&2; exit 2 ;; esac
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  log_row "$(jq -nc --arg ts "$(now)" --arg brief "$f" --arg o "$o" '{ts: $ts, kind: "outcome", brief: $brief, outcome: $o}')"
  echo "jev: outcome recorded ($o)"
}

cmd_report() {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  [ -s "$LOG" ] || { echo "jev: nothing logged yet ($LOG)"; exit 0; }
  jq -rs '
    def rank: {"trivial": 0, "light": 1, "workhorse": 2, "top": 3}[.] // null;
    def tally(f): group_by(f) | map("\(.[0] | f): \(length)") | join(" · ");
    (map(select(.kind == "outcome")) | map({key: .brief, value: .outcome}) | from_entries) as $out
    | (map(select(.kind == "brief")) | group_by(.brief) | map(.[-1])
       | map(. + {outcome: ($out[.brief] // "open"),
                  rel: ((.jev_tier | rank) as $j | (.jarvis.tier | rank) as $k
                        | if $j == null or $k == null then "unknown"
                          elif $j < $k then "jev lower" elif $j > $k then "jev higher" else "same" end)})) as $b
    | map(select(.kind == "triage")) as $t
    | ($b | map(select(.outcome != "open")) | length) as $n
    | "Briefs: \($b | length) logged, \($n) with an outcome (graduation review needs 30)",
      "",
      "Jev vs Jarvis tier: \($b | tally(.rel))",
      ($b | group_by(.rel)[] | "  \(.[0].rel) → \(tally(.outcome))"),
      "",
      "Tier pairs (jarvis → jev): \($b | tally("\(.jarvis.tier // "?") → \(.jev_tier)"))",
      ($b | map(select(.outcome == "escalated" or .outcome == "respawned")
                | select(((.jarvis.tier | rank) // 0) - ((.jev_tier | rank) // 0) >= 2))
          | if length > 0 then "  ! Jev was two tiers too low on: \(map(.brief) | join(", "))" else empty end),
      "",
      "Lint: \($b | map(select([.lint.files, .lint.pattern, .lint.done, .lint.fence] | any(. < 0.5))) | length) of \($b | length) briefs flagged",
      ($b | group_by([.lint.files, .lint.pattern, .lint.done, .lint.fence] | any(. < 0.5))[]
          | "  \(if ([.[0].lint.files, .[0].lint.pattern, .[0].lint.done, .[0].lint.fence] | any(. < 0.5)) then "flagged" else "passed" end) → \(tally(.outcome))"),
      "",
      (if ($t | length) == 0 then "Triage: none logged"
       else "Triage: \($t | length) reads · \($t | tally(.state))",
            "  lines shown \($t | map(.lines_shown) | add) of \($t | map(.lines_read) | add) read (\((1 - (($t | map(.lines_shown) | add) / ([($t | map(.lines_read) | add), 1] | max))) * 100 | round)% kept out of Jarvis'"'"'s context)" end),
      "",
      "Spend: \([.[] | .input_tokens // 0] | add) brief input tokens logged"
  ' "$LOG"
}

# ---------------------------------------------------------------- main

ARGS=()
for a in "$@"; do if [ "$a" = --dry-run ]; then DRY=1; else ARGS+=("$a"); fi; done
set -- ${ARGS[@]+"${ARGS[@]}"}
cmd="${1:-}"
[ $# -gt 0 ] && shift

case "$cmd" in
  brief) cmd_brief "$@" ;;
  triage) cmd_triage "$@" ;;
  outcome) cmd_outcome "$@" ;;
  report) cmd_report ;;
  *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
