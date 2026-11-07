#!/usr/bin/env bash
# Sequential, isolated Opus review calls for the m5 replay (one at a time).
#
#   run.sh [--dry-run] [--only <fixture>] [--cap <usd>]
#
# Reads results/order.tsv (written by prepare.py): fixture, rep, arm, packet, per-call cap, estimate.
# Resumable: a finished output in results/raw/ is kept. Stops on a red band, on a call that would
# take the ledger past the aggregate cap, or on a failure that is not transient. Every claude child
# is this script's own, ended by its own alarm. Raw outputs lose their session ids before they are
# saved.
set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
res="$here/results"
raw="$res/raw"
ledger="$res/ledger.jsonl"
DRY=0; ONLY=""; CAP=20
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --only) ONLY=${2:-}; shift ;;
    --cap) CAP=${2:-}; shift ;;
    *) echo "usage: run.sh [--dry-run] [--only <fixture>] [--cap <usd>]" >&2; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null || { echo "run.sh: needs jq" >&2; exit 2; }
claude_bin=$(command -v claude) || { echo "run.sh: claude not found" >&2; exit 2; }
[ -s "$res/order.tsv" ] || { echo "run.sh: results/order.tsv missing; run prepare.py first" >&2; exit 2; }
model=$(jq -r .reviewer_model "$here/cases.json")
effort=$(jq -r .effort "$here/cases.json")
want=$(jq -r .prompt_sha256 "$here/cases.json")
have=$(shasum -a 256 "$here/prompts/reviewer.txt" | cut -d' ' -f1)
[ "$want" = "$have" ] || { echo "run.sh: reviewer prompt changed since the freeze" >&2; exit 2; }

work=$(mktemp -d "${TMPDIR:-/tmp}/lessons-replay-run.XXXXXX") || exit 2
trap 'rm -rf "$work"' EXIT
printf '{"mcpServers":{}}' > "$work/mcp.json"
cp "$here/prompts/reviewer.txt" "$work/system.txt"
jq -c .schema "$here/cases.json" > "$work/schema.json"
mkdir -p "$raw"
cli_version=$("$claude_bin" --version 2>/dev/null | head -n 1)

spent() { [ -s "$ledger" ] && jq -s 'map(.cost // 0) | add // 0' "$ledger" || echo 0; }
over() { awk -v a="$1" -v b="$2" -v c="$3" 'BEGIN { exit !(a + b > c) }'; }

if [ "$DRY" = 1 ]; then
  total=$(wc -l < "$res/order.tsv" | tr -d ' ')
  todo=0
  while IFS=$'\t' read -r fx rep arm packet capi est; do
    [ -n "$ONLY" ] && [ "$fx" != "$ONLY" ] && continue
    [ -s "$raw/$fx.$arm.r$rep.json" ] || todo=$((todo + 1))
    printf '%-8s r%s %-9s cap $%s est $%s %s bytes\n' "$fx" "$rep" "$arm" "$capi" "$est" "$(wc -c < "$here/$packet" | tr -d ' ')"
  done < "$res/order.tsv"
  echo "$total calls in order, $todo not yet done; ledger so far \$$(spent); aggregate cap \$$CAP"
  exit 0
fi

# one attempt: prints nothing, leaves $work/out.json, $work/err.txt; returns the claude exit status
attempt() { # $1 packet, $2 per-call cap
  rm -f "$work/out.json" "$work/err.txt"
  mkdir -p "$work/cwd"
  ( cd "$work/cwd" && perl -e 'alarm shift; exec @ARGV' 900 "$claude_bin" -p --model "$model" --effort "$effort" \
      --output-format json --setting-sources "" --strict-mcp-config --mcp-config "$work/mcp.json" \
      --disable-slash-commands --tools "" --disallowedTools 'mcp__*' --no-session-persistence --max-turns 1 \
      --max-budget-usd "$2" --system-prompt-file "$work/system.txt" --json-schema "$(cat "$work/schema.json")" \
      < "$here/$1" > "$work/out.json" 2> "$work/err.txt" )
}

good() { jq -e '((.is_error // false) == false) and (.structured_output | type == "object")
  and (.structured_output.verdict | IN("commit", "send_back")) and (.structured_output.findings | type == "array")' "$work/out.json" >/dev/null 2>&1; }

scrub_id='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
seq=0
while IFS=$'\t' read -r fx rep arm packet capi est; do
  [ -n "$ONLY" ] && [ "$fx" != "$ONLY" ] && continue
  seq=$((seq + 1))
  dest="$raw/$fx.$arm.r$rep.json"
  [ -s "$dest" ] && continue
  band=$("$repo/handoffs/bin/jarvis" band 2>/dev/null | awk 'NR == 1 { print tolower($1) }')
  case "$band" in
    green|amber) ;;
    *) echo "run.sh: band is '${band:-unreadable}': stopping before $fx r$rep $arm" >&2; exit 3 ;;
  esac
  reserve=$(awk -v e="$est" -v c="$capi" 'BEGIN { r = e * 1.3; if (r > c) r = c; printf "%.3f", r }')
  if over "$(spent)" "$reserve" "$CAP"; then
    echo "run.sh: ledger \$$(spent) + reserve \$$reserve would pass the \$$CAP cap: stopping before $fx r$rep $arm" >&2
    exit 4
  fi
  retries=0
  while :; do
    started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    attempt "$packet" "$capi"; rc=$?
    cost=$(jq -r '.total_cost_usd // 0' "$work/out.json" 2>/dev/null || echo 0)
    [ -n "$cost" ] || cost=0
    if [ "$rc" = 0 ] && good; then break; fi
    sub=$(jq -r '.subtype // "none"' "$work/out.json" 2>/dev/null || echo none)
    jq -nc --arg f "$fx" --arg a "$arm" --argjson r "$rep" --argjson c "$cost" --arg s "$sub" --argjson rc "$rc" \
      --arg e "$(head -c 300 "$work/err.txt" 2>/dev/null | tr '\n\t' '  ' | sed -E "s/$scrub_id/[ID]/g; s#/Users/[^ ]*#[HOME]#g")" \
      '{kind: "review_failed", fixture: $f, arm: $a, rep: $r, cost: $c, subtype: $s, rc: $rc, stderr: $e}' >> "$ledger"
    case "$sub" in
      error_max_budget_usd|error_max_turns|error_during_execution)
        echo "run.sh: $fx r$rep $arm failed with $sub (not transient): stopping" >&2; exit 5 ;;
    esac
    if [ "$retries" -ge 1 ]; then echo "run.sh: $fx r$rep $arm failed twice: stopping" >&2; exit 5; fi
    retries=$((retries + 1)); echo "transient failure ($fx r$rep $arm, rc $rc): one retry in 20s" >&2; sleep 20
  done
  jq --arg f "$fx" --arg a "$arm" --argjson r "$rep" --arg m "$model" --arg e "$effort" --arg p "$packet" \
     --arg ps "$(shasum -a 256 "$here/$packet" | cut -d' ' -f1)" --argjson n "$seq" --argjson rt "$retries" \
     --arg t "$started" --arg v "$cli_version" --arg cap "$capi" \
     "del(.session_id, .uuid) | walk(if type == \"string\" then gsub(\"$scrub_id\"; \"[ID]\") else . end)
      | . + {eval: {fixture: \$f, arm: \$a, rep: \$r, model: \$m, effort: \$e, packet: \$p, packet_sha256: \$ps,
                    request_order: \$n, retries: \$rt, started: \$t, cli: \$v, per_call_cap_usd: (\$cap | tonumber)}}" \
     "$work/out.json" > "$dest.tmp" && mv "$dest.tmp" "$dest"
  jq -nc --arg f "$fx" --arg a "$arm" --argjson r "$rep" --argjson c "$cost" --argjson rt "$retries" \
    '{kind: "review", fixture: $f, arm: $a, rep: $r, cost: $c, retries: $rt}' >> "$ledger"
  printf '%-8s r%s %-9s $%s  (ledger $%s)\n' "$fx" "$rep" "$arm" "$cost" "$(spent)"
done < "$res/order.tsv"
echo "done: $(find "$raw" -name '*.json' | wc -l | tr -d ' ') raw outputs, ledger \$$(spent)"
