#!/usr/bin/env bash
# Run one task suite through several models, headless, and keep every answer.
#
#   eval/models/run.sh <suite> [--models m1,m2] [--out DIR] [--only t1,t2] [--kind k1,k2]
#                      [--max-usd N] [--timeout SEC] [--dry-run]
#
# <suite> is a folder with tasks/*.md, or the name of one under
# $EVAL_MODELS_HOME/suites (default handoffs/.jarvis/eval/models, git-excluded).
# Models are cli:model[@effort]: claude:claude-opus-5-5@medium (claude:x means
# claude:x@high), agy:gemini-4-neon-high, codex:<model>[@effort]. The default is
# the first comparison: Neon and Argon at high and medium, Opus 5.5 at high and
# medium. Every call runs in an empty temp dir with tools off (claude) or a
# read-only sandbox (agy, codex). A rerun with the same --out only makes the
# calls that have no answer yet, so it also adds a model to an earlier run.
# See README.md for the task format and blind.sh / score.sh for the results.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$here/lib.sh"

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

models=agy:gemini-4-neon-high,agy:gemini-4-neon-medium,agy:gemini-4-argon-high,agy:gemini-4-argon-medium,claude:claude-opus-5-5@high,claude:claude-opus-5-5@medium
out='' dry=0 max_usd=0.50 only='' kinds='' timeout=900 suite=''
while [ $# -gt 0 ]; do
  case "$1" in
    --models|--out|--only|--kind|--max-usd|--timeout)
      [ $# -ge 2 ] || die "$1 needs a value"
      case "$1" in
        --models) models=$2 ;; --out) out=$2 ;; --only) only=$2 ;; --kind) kinds=$2 ;;
        --max-usd) max_usd=$2 ;; --timeout) timeout=$2 ;;
      esac
      shift 2 ;;
    --dry-run) dry=1; shift ;;
    -h|--help) usage ;;
    -*) die "unknown option $1" ;;
    *) [ -z "$suite" ] || die "one suite at a time"; suite=$1; shift ;;
  esac
done
[ -n "$suite" ] || usage
case "$max_usd" in ''|*[!0-9.]*) die "--max-usd wants a number" ;; esac
case "$timeout" in ''|*[!0-9]*) die "--timeout wants whole seconds" ;; esac
command -v jq >/dev/null || die "needs jq"
command -v perl >/dev/null || die "needs perl (for the call timeout)"

home=$(models_home)
if [ ! -d "$suite" ] && [ -d "$home/suites/$suite" ]; then suite="$home/suites/$suite"; fi
[ -d "$suite/tasks" ] || die "$suite has no tasks/ folder"
suite=$(cd "$suite" && pwd)
sname=$(basename "$suite")
[ -n "$out" ] || out="$home/runs/$sname-$(date +%Y%m%d-%H%M%S)"
case "$out" in /*) ;; *) out="$PWD/$out" ;; esac   # calls run from another dir

# The model sees this as its system prompt (claude) and as the prompt's first line (all).
PREAMBLE="You are being evaluated on a single task. Answer from this prompt alone: you have no tools, and no files beyond what is quoted here."

IFS=, read -r -a model_list <<< "$models"
[ ${#model_list[@]} -gt 0 ] || die "--models is empty"
# canonical ids (a claude id always names its effort), each once
canon=
for m in "${model_list[@]}"; do
  parse_model "$m"
  case ",$canon," in *,"$m_id",*) ;; *) canon="${canon:+$canon,}$m_id" ;; esac
done
models=$canon
IFS=, read -r -a model_list <<< "$models"

work=$(mktemp -d "${TMPDIR:-/tmp}/eval-models.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$work"' EXIT

trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; printf '%s' "$s"; }
sha() { { shasum -a 256 "$1" 2>/dev/null || sha256sum "$1"; } | cut -d' ' -f1; }
listed() { # listed <name> <comma list of shell patterns>
  local p rest=$2,
  while [ -n "$rest" ]; do
    p=${rest%%,*}; rest=${rest#*,}
    # shellcheck disable=SC2254
    [ -n "$p" ] && case "$1" in $p) return 0 ;; esac
  done
  return 1
}

# Files a task's context globs name, one "display<TAB>path" line each. Relative
# globs resolve in the suite; a directory stands for every file under it.
expand_context() { # $1 globs; writes $work/files
  local g m f found base
  : > "$work/files.raw"
  # Split the globs on spaces without expanding them yet.
  set -f
  # shellcheck disable=SC2086
  set -- $1
  set +f
  for g in "$@"; do
    found=0
    case "$g" in /*) base= ;; *) base="$suite/" ;; esac
    for m in "$base"$g; do
      [ -e "$m" ] || continue
      found=1
      if [ -d "$m" ]; then
        (cd "$m" && find . -type f ! -path '*/.*' | LC_ALL=C sort) | while IFS= read -r f; do
          printf '%s\n' "${m%/}/${f#./}"
        done >> "$work/files.raw"
      else
        printf '%s\n' "$m" >> "$work/files.raw"
      fi
    done
    [ "$found" = 1 ] || { echo "context '$g' matches nothing"; return 1; }
  done
  awk '!seen[$0]++' "$work/files.raw" | while IFS= read -r f; do
    if LC_ALL=C grep -qI '' "$f" 2>/dev/null; then
      printf '%s\t%s\n' "${f#"$suite/"}" "$f"
    else
      echo "  skipped $f (empty or binary)" >&2
    fi
  done > "$work/files"
}

# Parse tasks/<name>.md and build its prompt: $work/t/<name>.json and .txt
parse_task() { # $1 task file
  local f=$1 name n=0 state=start line key val
  local kind='' ctx='' bugs='' answers='' tol=2 numbered='' title='' outtok='' group=''
  name=$(basename "$f" .md)
  : > "$work/body"
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    if [ "$state" = body ]; then printf '%s\n' "$line" >> "$work/body"; continue; fi
    if [ "$line" = "---" ]; then
      if [ "$state" = start ] && [ "$n" = 1 ]; then state=header; continue; fi
      state=body; continue
    fi
    state=header
    case "$line" in ''|'#'*) continue ;; esac
    key=$(trim "${line%%:*}"); val=$(trim "${line#*:}")
    [ "$key" != "$line" ] || die "$f:$n: header line is not 'key: value' (a --- line ends the header)"
    case "$key" in
      kind) kind=$val ;;
      context) ctx="$ctx $val" ;;
      bug) bugs="$bugs$val"$'\n' ;;
      answer) answers="$answers$val"$'\n' ;;
      tolerance) tol=$val ;;
      numbered) numbered=$val ;;
      title) title=$val ;;
      group) group=$val ;;
      output_tokens) outtok=$val ;;
      *) die "$f:$n: unknown header key '$key'" ;;
    esac
  done < "$f"
  [ "$state" = body ] || die "$f: no --- line ends the header"
  case "$kind" in
    writing) [ -z "$bugs$answers" ] || die "$f: a writing task has no bug: or answer: lines" ;;
    review) [ -n "$bugs" ] || die "$f: a review task needs bug: lines" ;;
    longctx) [ -n "$answers" ] || die "$f: a longctx task needs answer: lines" ;;
    *) die "$f: kind is '$kind' (writing, review or longctx)" ;;
  esac
  case "$tol" in ''|*[!0-9]*) die "$f: tolerance wants a whole number" ;; esac
  if [ -z "$numbered" ]; then
    numbered=no
    [ "$kind" = review ] && numbered=yes
  fi
  case "$numbered" in yes|no) ;; *) die "$f: numbered is yes or no" ;; esac
  [ -n "$outtok" ] || outtok=$(expect_out_tokens "$kind")
  case "$outtok" in *[!0-9]*) die "$f: output_tokens wants a whole number" ;; esac

  : > "$work/files"
  if [ -n "$(trim "$ctx")" ]; then
    expand_context "$ctx" > "$work/ctxerr" || die "$f: $(cat "$work/ctxerr")"
  fi

  local p="$work/t/$name.txt" disp path
  {
    echo "$PREAMBLE"
    if [ -s "$work/files" ]; then
      echo
      if [ "$numbered" = yes ]; then echo "The files below are quoted in full, with line numbers at the left."
      else echo "The files below are quoted in full."; fi
      while IFS="$(printf '\t')" read -r disp path; do
        echo
        echo "=== FILE $disp ==="
        if [ "$numbered" = yes ]; then awk '{ printf "%5d  %s\n", NR, $0 }' "$path"; else awk '{ print }' "$path"; fi
        echo "=== END FILE $disp ==="
      done < "$work/files"
    fi
    echo
    awk 'NF { started = 1 } started' "$work/body" | awk '{ a[NR] = $0 } NF { last = NR } END { for (i = 1; i <= last; i++) print a[i] }'
    case "$kind" in
      review) printf '\n%s\n%s\n%s\n' \
        "Report every bug you find on its own line, in exactly this form:" \
        "BUG: <path>:<line> — <one-line reason>" \
        "Use the paths from the FILE headers and the line numbers at the left. You may explain after those lines. If you find no bugs, write: NO BUGS" ;;
      longctx) printf '\n%s\n%s\n%s\n' \
        "Answer each question on its own line, in exactly this form:" \
        "<question id>: <answer>" \
        "Give the shortest exact answer (a number, a name or a word) and nothing else on that line." ;;
    esac
  } > "$p"

  local bytes tokens
  bytes=$(wc -c < "$p" | tr -d ' ')
  tokens=$(est_tokens "$bytes")
  cut -f1 "$work/files" > "$work/ctxlist"
  printf '%s' "$bugs" > "$work/bugs"; printf '%s' "$answers" > "$work/answers"
  jq -n --arg name "$name" --arg kind "$kind" --arg title "$title" --arg group "${group:-$kind}" --argjson tol "$tol" \
     --arg numbered "$numbered" --argjson bytes "$bytes" --argjson tokens "$tokens" --argjson outtok "$outtok" \
     --arg sha "$(sha "$p")" --rawfile ctx "$work/ctxlist" --rawfile bugs "$work/bugs" --rawfile answers "$work/answers" '
    def lines: split("\n") | map(select(test("\\S")));
    {name: $name, kind: $kind, group: $group, title: $title, prompt: "prompts/\($name).txt", prompt_sha256: $sha,
     prompt_bytes: $bytes, prompt_tokens_est: $tokens, output_tokens_est: $outtok,
     numbered: ($numbered == "yes"), tolerance: $tol, context: ($ctx | lines),
     bugs: ($bugs | lines | map(. as $l
       | ([capture("^(?<id>\\S+)\\s+(?<path>[^\\s:]+):(?<lo>[0-9]+)(-(?<hi>[0-9]+))?\\s*$")] | first)
         // error("bug: line is not \"<id> <path>:<line>[-<line>]\": \($l)")
       | {id, path, lo: (.lo | tonumber), hi: ((.hi // .lo) | tonumber)})),
     answers: ($answers | lines | map(. as $l
       | ([capture("^(?<id>[^=\\s]+)\\s*=\\s*(?<alts>.*\\S)\\s*$")] | first)
         // error("answer: line is not \"<id> = <answer> | <alternative>\": \($l)")
       | {id, accept: (.alts | split("|") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)))}))}
    ' > "$work/t/$name.json" 2> "$work/jqerr" || die "$f: $(sed 's/^jq: error[^:]*: //' "$work/jqerr" | head -1)"
}

mkdir -p "$work/t"
ntasks=0
for f in "$suite"/tasks/*.md; do
  [ -e "$f" ] || continue
  name=$(basename "$f" .md)
  [ -z "$only" ] || listed "$name" "$only" || continue
  parse_task "$f"
  kind=$(jq -r .kind "$work/t/$name.json")
  [ -z "$kinds" ] || listed "$kind" "$kinds" || { rm -f "$work/t/$name.json" "$work/t/$name.txt"; continue; }
  ntasks=$((ntasks + 1))
done
[ "$ntasks" -gt 0 ] || die "no tasks in $suite/tasks match"

# A task whose prompt changed since answers were recorded in this --out is not
# comparable with them any more.
if [ -f "$out/run.json" ]; then
  [ "$(jq -r .suite "$out/run.json")" = "$suite" ] || die "$out holds a run of another suite ($(jq -r .suite "$out/run.json"))"
  for j in "$work"/t/*.json; do
    name=$(basename "$j" .json)
    [ -f "$out/tasks/$name.json" ] || continue
    [ "$(jq -r .prompt_sha256 "$j")" = "$(jq -r .prompt_sha256 "$out/tasks/$name.json")" ] \
      || die "task $name changed since $out recorded answers for it; use a new --out"
  done
fi

# The plan: one line per task, then every call not yet answered.
plural=s; [ "$ntasks" = 1 ] && plural=
echo "suite $suite · $ntasks task$plural · out $out"
for j in "$work"/t/*.json; do
  jq -r '"  \(.name)  \(.kind)  ≈\(.prompt_tokens_est) tokens in (\(.prompt_bytes) bytes\(if (.context | length) > 0 then ", \(.context | length) file\(if (.context | length) > 1 then "s" else "" end)" else "" end))"' "$j"
done
: > "$work/plan"
for j in "$work"/t/*.json; do
  name=$(basename "$j" .json)
  for m in "${model_list[@]}"; do
    parse_model "$m"
    [ -s "$out/answers/$name/$m_slug.txt" ] && continue
    printf '%s\t%s\n' "$name" "$m" >> "$work/plan"
  done
done
ncalls=$(wc -l < "$work/plan" | tr -d ' ')
n_claude=0 n_agy=0 n_codex=0 est_total=0 over_cap=
while IFS="$(printf '\t')" read -r name m; do
  parse_model "$m"
  case "$m_cli" in
    claude)
      n_claude=$((n_claude + 1))
      e=$(est_usd "$m_model" "$(jq -r '.prompt_tokens_est + 800' "$work/t/$name.json")" "$(jq -r .output_tokens_est "$work/t/$name.json")")
      est_total=$(awk -v a="$est_total" -v b="$e" 'BEGIN { printf "%.4f", a + b }')
      gt "$e" "$max_usd" && over_cap="$over_cap  $name × $m: estimated \$$e passes the \$$max_usd per-call cap"$'\n'
      ;;
    agy) n_agy=$((n_agy + 1)) ;;
    codex) n_codex=$((n_codex + 1)) ;;
  esac
done < "$work/plan"
echo "$ncalls calls to make: claude $n_claude (estimated \$$est_total, cap \$$max_usd a call, prompt cache off)"
echo "  agy $n_agy calls (each one request from the Google AI Pro daily pool) · codex $n_codex calls (ChatGPT plan)"
for m in "${model_list[@]}"; do
  parse_model "$m"
  [ "$m_cli" = claude ] || continue
  case "$(claude_price "$m_model")" in *unknown) echo "  note: no price known for $m_model; estimated at \$5/\$25 per MTok" ;; esac
done
[ -z "$over_cap" ] || printf 'over the per-call cap (the run stops before these):\n%s' "$over_cap"
if [ "$dry" = 1 ]; then
  echo "dry run: no calls made, nothing written"
  exit 0
fi
[ "$ncalls" -gt 0 ] || { echo "nothing to do: every call already has an answer"; exit 0; }
if [ -n "$over_cap" ]; then
  echo "stopping before any call: a claude call's estimate passes the \$$max_usd per-call cap (--max-usd)" >&2
  exit 4
fi

# Record the run, then make the calls one at a time.
mkdir -p "$out/prompts" "$out/tasks" "$out/answers" "$out/raw" || die "cannot create $out"
for j in "$work"/t/*.json; do
  name=$(basename "$j" .json)
  cp "$j" "$out/tasks/$name.json"; cp "$work/t/$name.txt" "$out/prompts/$name.txt"
done
versions='{}'
for c in claude agy codex; do
  case ",$models" in *,"$c":*)
    command -v "$c" >/dev/null || die "$c is not on PATH"
    [ "$c" = agy ] && continue   # agy has no --version
    versions=$(jq -c --arg c "$c" --arg v "$("$c" --version 2>/dev/null | head -n 1)" '. + {($c): $v}' <<< "$versions") ;;
  esac
done
prev_models='[]'
[ -f "$out/run.json" ] && prev_models=$(jq -c '.models // []' "$out/run.json")
jq -n --arg suite "$suite" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson prev "$prev_models" \
   --arg models "$models" --argjson cap "$max_usd" --argjson versions "$versions" --argjson timeout "$timeout" \
   --arg effort "${EVAL_CLAUDE_EFFORT:-high}" '
  {suite: $suite, updated: $at, models: ($prev + ($models | split(",")) | unique),
   max_usd_per_call: $cap, timeout_sec: $timeout, claude_default_effort: $effort,
   prompt_cache: "off for claude -p (DISABLE_PROMPT_CACHING=1): each prompt is sent once, so a cache write would only add cost",
   tools: "claude --tools \"\" and no MCP; agy --sandbox; codex --sandbox read-only; each call in an empty temp dir",
   cli_versions: $versions}' > "$out/run.json.tmp" && mv "$out/run.json.tmp" "$out/run.json"

ledger="$out/calls.jsonl"
seq=0 failed=0
while IFS="$(printf '\t')" read -r name m <&3; do
  seq=$((seq + 1))
  parse_model "$m"
  t="$work/t/$name.json" p="$work/t/$name.txt"
  kind=$(jq -r .kind "$t")
  tok=$(jq -r .prompt_tokens_est "$t")
  mkdir -p "$out/answers/$name" "$out/raw/$name"
  raw="$out/raw/$name/$m_slug.out" err="$out/raw/$name/$m_slug.err" ans="$work/answer"
  rm -f "$ans"
  cwd=$(mktemp -d "$work/cwd.XXXXXX")
  e=null
  if [ "$m_cli" = claude ]; then
    e=$(est_usd "$m_model" "$((tok + 800))" "$(jq -r .output_tokens_est "$t")")
    if gt "$e" "$max_usd"; then
      echo "stopping before $name × $m: estimated \$$e passes the \$$max_usd per-call cap (--max-usd)" >&2
      exit 4
    fi
  fi
  printf '[%d/%d] %s × %s … ' "$seq" "$ncalls" "$name" "$m"
  started=$(date +%s)
  : > "$raw"; : > "$err"
  case "$m_cli" in
    claude)
      ( cd "$cwd" && DISABLE_PROMPT_CACHING=1 perl -e 'alarm shift; exec @ARGV' "$timeout" \
          claude -p --model "$m_model" --effort "$m_effort" --output-format json \
          --setting-sources "" --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
          --disable-slash-commands --tools "" --no-session-persistence --max-turns 1 \
          --max-budget-usd "$max_usd" --system-prompt "$PREAMBLE" < "$p" > "$raw" 2> "$err" )
      rc=$?
      if [ "$rc" = 0 ] && jq -e '(.is_error // false) == false and (.result | type == "string" and test("\\S"))' "$raw" >/dev/null 2>&1; then
        jq -r .result "$raw" > "$ans"
      fi ;;
    agy)
      if [ "$(wc -c < "$p")" -gt 900000 ]; then
        echo "prompt is over 900000 bytes, too long to pass to agy as an argument" > "$err"; rc=7
      else
        ( cd "$cwd" && perl -e 'alarm shift; exec @ARGV' "$((timeout + 30))" \
            agy --print-timeout "${timeout}s" --model "$m_model" --sandbox --disable-slash-commands \
            -p "$(cat "$p")" < /dev/null > "$raw" 2> "$err" )
        rc=$?
        [ "$rc" = 0 ] && grep -q '[^[:space:]]' "$raw" && cp "$raw" "$ans"
      fi ;;
    codex)
      extra=()
      [ -n "$m_effort" ] && extra=(-c "model_reasoning_effort=\"$m_effort\"")
      ( cd "$cwd" && perl -e 'alarm shift; exec @ARGV' "$timeout" \
          codex exec -m "$m_model" ${extra[@]+"${extra[@]}"} --sandbox read-only --skip-git-repo-check \
          --ephemeral -C "$cwd" -o "$work/codex-last" - < "$p" > "$raw" 2> "$err" )
      rc=$?
      [ "$rc" = 0 ] && [ -f "$work/codex-last" ] && grep -q '[^[:space:]]' "$work/codex-last" && mv "$work/codex-last" "$ans"
      rm -f "$work/codex-last" ;;
  esac
  secs=$(( $(date +%s) - started ))
  dirty=false
  [ -z "$(ls -A "$cwd" 2>/dev/null)" ] || dirty=true
  rm -rf "$cwd"
  ok=false
  [ -s "$ans" ] && ok=true
  usage='{}'
  if [ "$m_cli" = claude ]; then
    usage=$(jq -c '{actual_usd: (.total_cost_usd // null), input_tokens: (.usage.input_tokens // null),
      output_tokens: (.usage.output_tokens // null), cache_read: (.usage.cache_read_input_tokens // null),
      cache_write: (.usage.cache_creation_input_tokens // null), subtype: (.subtype // null)}' "$raw" 2>/dev/null) || usage='{}'
    [ -n "$usage" ] || usage='{}'
  fi
  jq -nc --arg task "$name" --arg kind "$kind" --arg model "$m" --arg cli "$m_cli" --argjson ok "$ok" --arg effort "$m_effort" \
     --argjson rc "$rc" --argjson secs "$secs" --argjson tok "$tok" --argjson est "$e" --argjson dirty "$dirty" \
     --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson usage "$usage" '
    {at: $at, task: $task, kind: $kind, model: $model, cli: $cli, effort: (if $effort == "" then null else $effort end),
     ok: $ok, rc: $rc, seconds: $secs,
     prompt_tokens_est: $tok, est_usd: $est, cwd_written: $dirty} + $usage' >> "$ledger"
  if [ "$ok" = true ]; then
    mv "$ans" "$out/answers/$name/$m_slug.txt"
    extra_note=
    [ "$m_cli" = claude ] && extra_note=" \$$(jq -r '.actual_usd // "?"' <<< "$usage") (est \$$e)"
    echo "ok ${secs}s$extra_note"
  else
    failed=$((failed + 1))
    echo "FAILED rc $rc after ${secs}s: $(head -c 200 "$err" | tr '\n' ' ')"
  fi
  [ "$dirty" = true ] && echo "  warning: the model wrote files into its empty work dir" >&2
  if [ "$m_cli" = claude ] && [ "$(jq -r '.subtype // ""' <<< "$usage")" = error_max_budget_usd ]; then
    echo "stopping: $name × $m hit the \$$max_usd per-call cap" >&2
    exit 4
  fi
done 3< "$work/plan"

echo "done: $((seq - failed)) answered, $failed failed · out $out"
echo "cost (this out dir, all runs):"
cost_summary "$ledger"
[ "$failed" = 0 ] || { echo "rerun the same command with --out $out to retry the failed calls"; exit 1; }
