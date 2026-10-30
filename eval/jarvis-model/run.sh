#!/usr/bin/env bash
# Offline evaluation: which model should Jarvis itself run on?
#
#   eval/jarvis-model/run.sh [options]
#     --configs LIST   name:model:effort,… (default: the three candidates below)
#     --tasks LIST     routing,review (default: both)
#     --limit N        first N fixtures per task (default: all — 40 routing, 8 review)
#     --only REGEX     fixtures whose name matches
#     --repeat R       run every fixture R times (default 1; single runs are noisy)
#     --jobs J         runs in parallel (default 3)
#     --out DIR        results directory (default results/<timestamp>)
#     --dry-run        print what would run and the first prompt; spend nothing
#
# Each run is one headless Claude Code call (`claude -p`) in an empty temp
# directory, with no user/project settings, plugins' skills, MCP servers or
# tools, so every config pays the same fixed overhead and only the model and
# effort differ. Raw JSON (result text, total_cost_usd, usage, duration_ms)
# lands in the results dir; score it with score.py.
#
# This spends real usage. Fable at high on all 48 fixtures is most of it; see
# README.md for the estimate before running without --limit.
set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
refs="$repo/plugins/jarvis/skills"

CONFIGS="opus55-high:claude-opus-5-5:high,opus55-xhigh:claude-opus-5-5:xhigh"
TASKS="routing,review"
LIMIT=0 ONLY="" REPEAT=1 JOBS=3 OUT="" DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --configs) CONFIGS="$2"; shift 2 ;;
    --tasks) TASKS="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --repeat) REPEAT="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
command -v jq >/dev/null || { echo "needs jq" >&2; exit 2; }
command -v claude >/dev/null || { echo "needs claude on PATH" >&2; exit 2; }
[ -n "$OUT" ] || OUT="$here/results/$(date +%Y%m%d-%H%M%S)"
work=$(mktemp -d "${TMPDIR:-/tmp}/jarvis-model.XXXXXX")
trap 'rm -rf "$work"' EXIT

# ------------------------------------------------------------ system prompts
# What Jarvis would have loaded for the job: the plugin's own reference text,
# read live so the eval follows the plugin. Its hash goes into every record.

section() { # $1 file, $2 heading regex; prints that "## " section, or the whole file if absent
  local s
  s=$(awk -v h="$2" '$0 ~ "^## " { if (p) exit; if ($0 ~ h) p = 1 } p' "$1")
  [ -n "$s" ] && printf '%s\n' "$s" || cat "$1"
}

{ echo "You are Jarvis, the coordinating agent of a Superset workspace. This is your routing guide (jarvis:run references/model-routing.md):"
  echo; cat "$refs/run/references/model-routing.md"; } > "$work/sys-routing.txt"

{ echo "You are Jarvis, the coordinating agent of a Superset workspace. These are your rules for reviewing a worker's handoff before you commit it."
  echo; echo "=== jarvis:run SKILL.md — reviewing ==="; section "$refs/run/SKILL.md" "Reviewing and merging"
  echo; echo "=== references/handoffs.md ==="; cat "$refs/run/references/handoffs.md"
  echo; echo "=== AGENTS.md (the worker contract) — worker rules ==="; section "$refs/setup/templates/AGENTS.md" "Worker rules"
  echo; echo "=== .claude/agents/diff-reviewer.md ==="; awk 'f; /^---$/ && ++n == 2 { f = 1 }' "$refs/setup/templates/.claude/agents/diff-reviewer.md"
} > "$work/sys-review.txt"

sha() { shasum -a 256 "$1" | cut -c1-12; }

# ------------------------------------------------------------ prompts

routing_prompt() { # $1 brief file
  # Same stripping as jev.sh: title line + sections, minus the header Jarvis
  # filled in (worker/model/effort) and the boilerplate "Questions first".
  local body
  body=$( { sed -n '1p' "$1"; awk '/^## Questions first/{exit} /^## /{p=1} p' "$1"; } )
  cat <<EOF
Route the task brief below exactly as your routing guide says.

Current state:
- Usage band: green (31%, 10:05)
- Claude sessions running: Jarvis + 1 worker (fleet not busy)
- Codex and OpenCode are both configured on this machine.

Brief (header with worker/model/effort removed):
<<<
$body
>>>

Answer with only one JSON object, no prose and no code fence:
{"tier": "top|workhorse|light|trivial", "agent": "claude|codex|opencode", "model": "<model id, or null for opencode>", "effort": "<low|medium|high|xhigh, or null for opencode>", "reason": "<one sentence>"}
"tier" is the tier the task's decision content earns by the test in the guide, whichever agent you send it to.
EOF
}

review_prompt() { # $1 fixture dir
  local d="$1"
  cat <<EOF
Review this worker's handoff as Jarvis, before committing it. You cannot run
commands; everything you would have looked at is below.
EOF
  [ -f "$d/context.txt" ] && { echo; cat "$d/context.txt"; }
  cat <<EOF

=== the brief the worker was given ===
$(cat "$d/brief.md")

=== the handoff ===
$(cat "$d/handoff.md")

=== git status --porcelain ===
$(cat "$d/status.txt")

=== git diff of every changed file (including untracked ones) ===
$(cat "$d/diff.patch")

Answer with only one JSON object, no prose and no code fence:
{"verdict": "commit|send_back", "findings": [{"file": "<path or null>", "kind": "file_list_incomplete|unlisted_shared_edit|scope_violation|bug|checks_missing|git_violation|secret|nit", "note": "<one sentence>"}]}
"commit" means you would commit exactly the handoff's file list now. List every
problem that should stop or change the commit; use kind "nit" for anything that
wouldn't. An empty findings list is fine.
EOF
}

# ------------------------------------------------------------ the run list

fixtures() { # $1 task → prints one fixture path per line
  local list
  case "$1" in
    routing) list=$(ls "$repo"/eval/briefs/*.md) ;;
    review) list=$(ls -d "$here"/review/*/) ;;
    *) echo "unknown task: $1" >&2; return ;;
  esac
  [ -n "$ONLY" ] && list=$(printf '%s\n' "$list" | grep -E "$ONLY")
  [ "$LIMIT" -gt 0 ] && list=$(printf '%s\n' "$list" | head -n "$LIMIT")
  printf '%s\n' "$list" | sed 's:/$::'
}

one() { # config-name model effort task fixture rep
  local name="$1" model="$2" effort="$3" task="$4" fx="$5" rep="$6"
  local fname dest dir prompt out err rc
  fname=$(basename "$fx" .md)
  dest="$OUT/$name/$task/$fname.r$rep.json"
  [ -s "$dest" ] && return 0   # resumable: finished runs are kept
  prompt="$work/p.$name.$task.$fname.$rep"
  if [ "$task" = routing ]; then routing_prompt "$fx" > "$prompt"; else review_prompt "$fx" > "$prompt"; fi
  dir=$(mktemp -d "$work/cwd.XXXXXX")
  out="$dir/out.json"; err="$dir/err.txt"
  ( cd "$dir" && claude -p --model "$model" --effort "$effort" --output-format json \
      --setting-sources "" --strict-mcp-config --disable-slash-commands --tools "" \
      --no-session-persistence --append-system-prompt "$(cat "$work/sys-$task.txt")" \
      < "$prompt" > "$out" 2> "$err" ); rc=$?
  mkdir -p "$(dirname "$dest")"
  if [ $rc = 0 ] && jq -e . "$out" >/dev/null 2>&1; then
    jq --arg c "$name" --arg m "$model" --arg e "$effort" --arg t "$task" --arg f "$fname" \
       --argjson r "$rep" --arg ps "$(sha "$prompt")" --arg ss "$(sha "$work/sys-$task.txt")" \
       '. + {eval: {config: $c, model: $m, effort: $e, task: $t, fixture: $f, rep: $r, prompt_sha: $ps, system_sha: $ss}}' \
       "$out" > "$dest"
    printf '%-13s %-8s %-45s $%s\n' "$name" "$task" "$fname" "$(jq -r '.total_cost_usd // "?"' "$dest")"
  else
    echo "FAILED $name $task $fname (rc $rc): $(head -c 300 "$err")" >&2
  fi
  rm -rf "$dir" "$prompt"
}

runs="$work/runs"; : > "$runs"
IFS=, read -r -a cfgs <<< "$CONFIGS"
IFS=, read -r -a tasks <<< "$TASKS"
for c in "${cfgs[@]}"; do
  IFS=: read -r name model effort <<< "$c"
  for t in "${tasks[@]}"; do
    for fx in $(fixtures "$t"); do
      r=1; while [ "$r" -le "$REPEAT" ]; do printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$model" "$effort" "$t" "$fx" "$r" >> "$runs"; r=$((r + 1)); done
    done
  done
done
total=$(wc -l < "$runs" | tr -d ' ')

if [ "$DRY" = 1 ]; then
  echo "would run $total calls into $OUT:"
  cut -f1-4 "$runs" | sort | uniq -c
  echo; echo "system prompt sizes: routing $(wc -c < "$work/sys-routing.txt") bytes, review $(wc -c < "$work/sys-review.txt") bytes"
  first=$(head -n 1 "$runs")
  echo; echo "--- first prompt ($(printf '%s' "$first" | cut -f4) / $(basename "$(printf '%s' "$first" | cut -f5)")) ---"
  if [ "$(printf '%s' "$first" | cut -f4)" = routing ]; then routing_prompt "$(printf '%s' "$first" | cut -f5)"; else review_prompt "$(printf '%s' "$first" | cut -f5)"; fi
  exit 0
fi

mkdir -p "$OUT"
cp "$work/sys-routing.txt" "$work/sys-review.txt" "$OUT/"
# one line per invocation, so a resumed or extended run keeps its history
jq -nc --arg configs "$CONFIGS" --arg tasks "$TASKS" --argjson limit "$LIMIT" --argjson repeat "$REPEAT" \
  --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg claude "$(claude --version 2>/dev/null)" \
  --arg plugin "$(git -C "$repo" rev-parse --short HEAD 2>/dev/null)$(git -C "$repo" diff --quiet -- plugins 2>/dev/null || echo '+dirty')" \
  '{configs: $configs, tasks: $tasks, limit: $limit, repeat: $repeat, started: $started, claude: $claude, plugin: $plugin}' >> "$OUT/runs.jsonl"
echo "running $total calls, $JOBS at a time → $OUT"

n=0
while IFS=$'\t' read -r name model effort t fx r; do
  one "$name" "$model" "$effort" "$t" "$fx" "$r" &
  n=$((n + 1))
  [ $((n % JOBS)) = 0 ] && wait
done < "$runs"
wait
echo; echo "done. score it: python3 $here/score.py $OUT"
