#!/usr/bin/env bash
# Blind judging of a run's writing answers: a lineup of every model's draft per
# task (the default), or A/B pairs.
#
#   eval/models/blind.sh <out> make [--seed N] [--force] [--kind k1,k2]
#       per task, every model's answer as Draft 1..N in an order shuffled per
#       task. Writes lineup.json (tasks, prompts, draft files, the verdicts and
#       the suite's tags; no model names) and lineup-key.json (draft -> model).
#       Writing tasks only unless --kind says otherwise.
#   eval/models/blind.sh <out> vote
#       shows each task not yet judged with all its drafts, then asks per draft
#       a verdict (ship as-is / light edit / rewrite), tags from the suite's
#       tags.txt and an optional note, then one top pick. Appends a line per
#       task to lineup-votes.jsonl, so it resumes where you quit.
#   eval/models/blind.sh <out> reveal
#       per model, and per model and task group: top-pick rate, ship-or-light-
#       edit rate, the most common tags; the top pick of each task; label bias
#   eval/models/blind.sh <out> [status]
#   eval/models/blind.sh <out> pairs make|vote|reveal|status [--seed N] [--force]
#       the same as A/B pairs: pairs.json, pairs-key.json, pairs-votes.jsonl;
#       vote asks a / b / t (tie) / s (skip) / q (quit)
#
# Don't open a *-key.json before you are done voting.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$here/lib.sh"

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ $# -ge 1 ] || usage
out=$1; shift
cmd=${1:-status}; [ $# -gt 0 ] && shift
[ -f "$out/run.json" ] || die "$out has no run.json (is it a run.sh --out folder?)"
command -v jq >/dev/null || die "needs jq"
pairs="$out/pairs.json" key="$out/pairs-key.json" votes="$out/pairs-votes.jsonl"
lineup="$out/lineup.json" lkey="$out/lineup-key.json" lvotes="$out/lineup-votes.jsonl"
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
leaky() { LC_ALL=C grep -qiE 'claude|anthropic|gemini|google|deepmind|openai|chatgpt|gpt-|codex|opus|sonnet|haiku|neon|argon' "$1"; }

pairs_make() {
  local seed force=0 t name m a n=0 id
  seed=$(date +%s)
  while [ $# -gt 0 ]; do
    case "$1" in
      --seed) [ $# -ge 2 ] || die "--seed needs a value"; seed=$2; shift 2 ;;
      --force) force=1; shift ;;
      *) die "unknown option $1" ;;
    esac
  done
  case "$seed" in ''|*[!0-9]*) die "--seed wants a whole number" ;; esac
  if [ -s "$votes" ] && [ "$force" = 0 ]; then
    die "$votes already has votes for the current pairs; --force makes new pairs and moves the votes aside"
  fi
  work=$(mktemp -d "${TMPDIR:-/tmp}/eval-models-blind.XXXXXX") || die "mktemp failed"
  trap 'rm -rf "$work"' EXIT
  : > "$work/cand"
  for t in "$out"/tasks/*.json; do
    [ -e "$t" ] || continue
    [ "$(jq -r .kind "$t")" = writing ] || continue
    name=$(basename "$t" .json)
    : > "$work/have"
    for m in $(jq -r '.models[]' "$out/run.json"); do
      parse_model "$m"
      a="$out/answers/$name/$m_slug.txt"
      [ -s "$a" ] && printf '%s\t%s\n' "$m_id" "$a" >> "$work/have"
    done
    # every unordered pair of models that answered this task
    awk -F'\t' -v task="$name" '{ m[NR] = $1; f[NR] = $2 }
      END { for (i = 1; i <= NR; i++) for (j = i + 1; j <= NR; j++) printf "%s\t%s\t%s\t%s\t%s\n", task, m[i], f[i], m[j], f[j] }' \
      "$work/have" >> "$work/cand"
  done
  [ -s "$work/cand" ] || die "no writing task has answers from two models yet"
  # random order of pairs and random sides, reproducible from the seed
  awk -F'\t' -v seed="$seed" 'BEGIN { srand(seed); OFS = "\t" }
    { if (rand() < 0.5) print rand(), $1, $2, $3, $4, $5; else print rand(), $1, $4, $5, $2, $3 }' "$work/cand" \
    | sort -n | cut -f2- > "$work/order"

  if [ -s "$votes" ]; then mv "$votes" "$votes.$(date +%Y%m%d-%H%M%S).old"; fi
  rm -rf "$out/blind"; mkdir -p "$out/blind"
  : > "$work/pairs.jsonl"; : > "$work/key.jsonl"
  while IFS="$(printf '\t')" read -r name ma fa mb fb; do
    n=$((n + 1)); id=$(printf 'p%02d' "$n")
    cp "$fa" "$out/blind/$id-A.txt"; cp "$fb" "$out/blind/$id-B.txt"
    jq -nc --arg id "$id" --arg task "$name" --slurpfile t "$out/tasks/$name.json" '
      {id: $id, task: $task, title: ($t[0].title // ""), prompt: "prompts/\($task).txt",
       a: "blind/\($id)-A.txt", b: "blind/\($id)-B.txt"}' >> "$work/pairs.jsonl"
    jq -nc --arg id "$id" --arg a "$ma" --arg b "$mb" '{($id): {A: $a, B: $b}}' >> "$work/key.jsonl"
    for side in A B; do
      if leaky "$out/blind/$id-$side.txt"; then
        echo "warning: $id side $side names a model or vendor; it may give its author away (edit $out/blind/$id-$side.txt if so)"
      fi
    done
  done < "$work/order"
  jq -s --arg at "$(now)" '{version: 1, created: $at, pairs: .}' "$work/pairs.jsonl" > "$pairs"
  jq -s --arg at "$(now)" --argjson seed "$seed" 'add + {created: $at, seed: $seed}' "$work/key.jsonl" > "$key"
  echo "$n pairs from $(cut -f1 "$work/order" | sort -u | wc -l | tr -d ' ') writing tasks: $pairs"
  echo "next: eval/models/blind.sh $out pairs vote"
}

voted() { [ -s "$votes" ] && jq -e --arg id "$1" 'select(.pair == $id)' "$votes" >/dev/null 2>&1; }

pairs_vote() {
  [ -f "$pairs" ] || die "no pairs yet: eval/models/blind.sh $out pairs make"
  local total id task prompt a b lines ans left
  total=$(jq '.pairs | length' "$pairs")
  left=0
  for id in $(jq -r '.pairs[].id' "$pairs"); do voted "$id" || left=$((left + 1)); done
  [ "$left" -gt 0 ] || { echo "all $total pairs are voted: eval/models/blind.sh $out pairs reveal"; return 0; }
  echo "$left of $total pairs to vote. a = A is better, b = B is better, t = tie, s = skip, q = quit"
  for id in $(jq -r '.pairs[].id' "$pairs"); do
    voted "$id" && continue
    task=$(jq -r --arg id "$id" '.pairs[] | select(.id == $id) | .task' "$pairs")
    prompt="$out/$(jq -r --arg id "$id" '.pairs[] | select(.id == $id) | .prompt' "$pairs")"
    a="$out/$(jq -r --arg id "$id" '.pairs[] | select(.id == $id) | .a' "$pairs")"
    b="$out/$(jq -r --arg id "$id" '.pairs[] | select(.id == $id) | .b' "$pairs")"
    lines=$(wc -l < "$prompt" | tr -d ' ')
    printf '\n==================== %s · task %s ====================\n' "$id" "$task"
    echo "--- prompt ---"
    sed -n '1,40p' "$prompt"
    [ "$lines" -le 40 ] || echo "… $((lines - 40)) more lines in $prompt"
    printf '\n--- A ---\n'; cat "$a"
    printf '\n--- B ---\n'; cat "$b"
    echo
    while :; do
      printf '%s: better? [a/b/t/s/q] ' "$id"
      IFS= read -r ans || { echo; return 0; }
      case "$ans" in
        a|A) ans=A ;; b|B) ans=B ;; t|T) ans=tie ;;
        s|S) ans=skip ;; q|Q) return 0 ;;
        *) echo "a, b, t, s or q"; continue ;;
      esac
      break
    done
    [ "$ans" = skip ] && continue
    jq -nc --arg id "$id" --arg v "$ans" --arg at "$(now)" '{pair: $id, vote: $v, at: $at}' >> "$votes"
  done
  echo "done: eval/models/blind.sh $out pairs reveal"
}

pairs_reveal() {
  [ -f "$pairs" ] && [ -f "$key" ] || die "no pairs yet: eval/models/blind.sh $out pairs make"
  [ -s "$votes" ] || die "no votes yet: eval/models/blind.sh $out pairs vote"
  jq -rs --slurpfile k "$key" --slurpfile p "$pairs" '
    def pad(n): tostring | if length >= n then . else . + (" " * (n - length)) end;
    def pct(a; b): if b == 0 then "n/a" else "\(a * 100 / b | round)%" end;
    $k[0] as $key
    | (group_by(.pair) | map(last)) as $v
    | [$v[] | . as $x | $key[$x.pair] as $s | ($p[0].pairs[] | select(.id == $x.pair)) as $pp
       | {pair: .pair, task: $pp.task, vote, A: $s.A, B: $s.B,
          winner: (if .vote == "tie" then null else $s[.vote] end),
          loser: (if .vote == "tie" then null elif .vote == "A" then $s.B else $s.A end)}] as $r
    | ([$r[] | .A, .B] | unique) as $models
    | ([$models[] | length] | max) as $w
    | "== blind writing: \($r | length) of \($p[0].pairs | length) pairs voted",
      "",
      "== per model (win rate counts a tie as half)",
      ($models[] as $m | ($r | map(select(.A == $m or .B == $m))) as $mine
       | ($mine | map(select(.winner == $m)) | length) as $won
       | ($mine | map(select(.loser == $m)) | length) as $lost
       | ($mine | map(select(.vote == "tie")) | length) as $tied
       | "  \($m | pad($w))  \(pct($won * 2 + $tied; ($mine | length) * 2))  won \($won) lost \($lost) tied \($tied) of \($mine | length)"),
      "",
      "== head to head",
      ([$r[] | [.A, .B] | sort] | unique[] as [$x, $y]
       | ($r | map(select([.A, .B] | sort == [$x, $y]))) as $h
       | "  \($x) vs \($y): \($h | map(select(.winner == $x)) | length)–\($h | map(select(.winner == $y)) | length)"
         + (($h | map(select(.vote == "tie")) | length) as $t | if $t > 0 then " (\($t) tied)" else "" end)),
      "",
      "== per pair",
      ($r[] | "  \(.pair)  \(.task)  " + (if .winner then "\(.winner) beat \(.loser)" else "tie: \(.A) and \(.B)" end)),
      "",
      "side bias: A chosen \($r | map(select(.vote == "A")) | length), B chosen \($r | map(select(.vote == "B")) | length), tied \($r | map(select(.vote == "tie")) | length)"
  ' "$votes"
}

pairs_status() {
  if [ ! -f "$pairs" ]; then echo "no pairs yet: eval/models/blind.sh $out pairs make"; return 0; fi
  local total done_n=0 id
  total=$(jq '.pairs | length' "$pairs")
  for id in $(jq -r '.pairs[].id' "$pairs"); do voted "$id" && done_n=$((done_n + 1)); done
  echo "pairs: $total, $done_n voted"
}

# --- lineup: every model's draft per task under shuffled labels -------------

lineup_make() {
  local seed force=0 kinds=writing t name kind m a n=0 i k suite
  seed=$(date +%s)
  while [ $# -gt 0 ]; do
    case "$1" in
      --seed) [ $# -ge 2 ] || die "--seed needs a value"; seed=$2; shift 2 ;;
      --kind) [ $# -ge 2 ] || die "--kind needs a value"; kinds=$2; shift 2 ;;
      --force) force=1; shift ;;
      *) die "unknown option $1" ;;
    esac
  done
  case "$seed" in ''|*[!0-9]*) die "--seed wants a whole number" ;; esac
  if [ -s "$lvotes" ] && [ "$force" = 0 ]; then
    die "$lvotes already has judgements for the current lineup; --force makes a new lineup and moves them aside"
  fi
  work=$(mktemp -d "${TMPDIR:-/tmp}/eval-models-lineup.XXXXXX") || die "mktemp failed"
  trap 'rm -rf "$work"' EXIT
  suite=$(jq -r .suite "$out/run.json")
  : > "$work/tags"
  [ -f "$suite/tags.txt" ] && awk '{ sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "") } NF && !/^#/' "$suite/tags.txt" > "$work/tags"
  : > "$work/tasks.jsonl"; : > "$work/key.jsonl"
  for t in "$out"/tasks/*.json; do
    [ -e "$t" ] || continue
    kind=$(jq -r .kind "$t")
    case ",$kinds," in *,"$kind",*) ;; *) continue ;; esac
    name=$(basename "$t" .json)
    : > "$work/have"
    for m in $(jq -r '.models[]' "$out/run.json"); do
      parse_model "$m"
      a="$out/answers/$name/$m_slug.txt"
      [ -s "$a" ] && printf '%s\t%s\n' "$m_id" "$a" >> "$work/have"
    done
    k=$(wc -l < "$work/have" | tr -d ' ')
    [ "$k" -ge 2 ] || { echo "skipped $name: $k answer(s), a lineup needs two"; continue; }
    n=$((n + 1))
    # a fresh order per task, reproducible from the seed
    awk -v seed=$((seed + n)) 'BEGIN { srand(seed) } { print rand() "\t" $0 }' "$work/have" | sort -n | cut -f2- > "$work/order"
    mkdir -p "$work/lineup/$name"
    : > "$work/drafts.jsonl"; : > "$work/map.jsonl"
    i=0
    while IFS="$(printf '\t')" read -r m a; do
      i=$((i + 1))
      cp "$a" "$work/lineup/$name/draft-$i.txt"
      jq -nc --arg l "Draft $i" --arg f "lineup/$name/draft-$i.txt" '{label: $l, file: $f}' >> "$work/drafts.jsonl"
      jq -nc --arg l "Draft $i" --arg m "$m" '{($l): $m}' >> "$work/map.jsonl"
      if leaky "$a"; then
        echo "warning: $name Draft $i names a model or vendor; it may give its author away (edit $out/lineup/$name/draft-$i.txt if so)"
      fi
    done < "$work/order"
    jq -nc --slurpfile t "$t" --slurpfile d "$work/drafts.jsonl" '$t[0] as $t
      | {task: $t.name, title: ($t.title // ""), kind: $t.kind, group: ($t.group // $t.kind), prompt: $t.prompt, drafts: $d}' >> "$work/tasks.jsonl"
    jq -sc --arg task "$name" '{($task): add}' "$work/map.jsonl" >> "$work/key.jsonl"
  done
  [ "$n" -gt 0 ] || die "no task of kind $kinds has answers from two models yet"
  if [ -s "$lvotes" ]; then mv "$lvotes" "$lvotes.$(date +%Y%m%d-%H%M%S).old"; fi
  rm -rf "$out/lineup" && mv "$work/lineup" "$out/lineup"
  jq -n --slurpfile tasks "$work/tasks.jsonl" --rawfile tags "$work/tags" --arg at "$(now)" '
    {version: 1, created: $at, verdicts: ["ship as-is", "light edit", "rewrite"],
     tags: ($tags | split("\n") | map(select(length > 0))), tasks: $tasks}' > "$lineup"
  jq -s --arg at "$(now)" --argjson seed "$seed" '{created: $at, seed: $seed, tasks: add}' "$work/key.jsonl" > "$lkey"
  echo "$n tasks, $(jq '[.tasks[].drafts[]] | length' "$lineup") drafts, $(jq '.tags | length' "$lineup") tags: $lineup"
  [ -s "$work/tags" ] || echo "  (no tags: list them one per line in $suite/tags.txt)"
  echo "next: eval/models/blind.sh $out vote"
}

judged() { [ -s "$lvotes" ] && jq -e --arg t "$1" 'select(.task == $t)' "$lvotes" >/dev/null 2>&1; }
ask() { printf '%s ' "$1"; IFS= read -r reply || { echo; return 1; }; }

# Interview for one task. Returns 0 when saved, 1 when skipped, 2 to quit.
judge_task() { # $1 task
  local task=$1 prompt lines nd i v nums tok bad tagsjson note top rec='[]' f ntags tagmenu
  ntags=$(jq '.tags | length' "$lineup")
  tagmenu=$(jq -r '.tags | to_entries | map("\(.key + 1) \(.value)") | join(" · ")' "$lineup")
  prompt="$out/$(jq -r --arg t "$task" '.tasks[] | select(.task == $t) | .prompt' "$lineup")"
  nd=$(jq --arg t "$task" '.tasks[] | select(.task == $t) | .drafts | length' "$lineup")
  lines=$(wc -l < "$prompt" | tr -d ' ')
  printf '\n==================== task %s · %d drafts ====================\n' "$task" "$nd"
  echo "--- prompt ---"
  sed -n '1,40p' "$prompt"
  [ "$lines" -le 40 ] || echo "… $((lines - 40)) more lines in $prompt"
  i=1
  while [ "$i" -le "$nd" ]; do
    f="$out/$(jq -r --arg t "$task" --argjson i "$i" '.tasks[] | select(.task == $t) | .drafts[$i - 1].file' "$lineup")"
    printf '\n---------- Draft %d ----------\n' "$i"; cat "$f"
    i=$((i + 1))
  done
  echo
  i=1
  while [ "$i" -le "$nd" ]; do
    while :; do
      ask "Draft $i: [s] ship as-is, [l] light edit, [r] rewrite >" || return 2
      case "$reply" in
        s|S) v="ship as-is" ;; l|L) v="light edit" ;; r|R) v=rewrite ;;
        q|Q) return 2 ;; x|X) return 1 ;;
        *) echo "s, l or r (q quits, x skips this task)"; continue ;;
      esac
      break
    done
    tagsjson='[]'
    if [ "$ntags" -gt 0 ]; then
      while :; do
        ask "Draft $i tags, numbers or blank ($tagmenu) >" || return 2
        case "$reply" in q|Q) return 2 ;; x|X) return 1 ;; esac
        nums=$(printf '%s' "$reply" | tr ',' ' ')
        bad=0
        for tok in $nums; do
          case "$tok" in ''|*[!0-9]*) bad=1 ;; *) { [ "$tok" -ge 1 ] && [ "$tok" -le "$ntags" ]; } || bad=1 ;; esac
        done
        [ "$bad" = 0 ] && break
        echo "tag numbers from 1 to $ntags, separated by spaces or commas"
      done
      tagsjson=$(jq -c --arg sel "$nums" '.tags as $t | [$sel | split(" ")[] | select(length > 0) | tonumber | $t[. - 1]] | unique' "$lineup")
    fi
    ask "Draft $i note, or blank >" || return 2
    case "$reply" in q|Q) return 2 ;; x|X) return 1 ;; esac
    note=$reply
    rec=$(jq -c --arg l "Draft $i" --arg v "$v" --argjson tags "$tagsjson" --arg note "$note" \
      '. + [{label: $l, verdict: $v, tags: $tags, note: (if $note == "" then null else $note end)}]' <<< "$rec")
    i=$((i + 1))
  done
  while :; do
    ask "Top pick, 1 to $nd >" || return 2
    case "$reply" in q|Q) return 2 ;; x|X) return 1 ;; esac
    case "$reply" in ''|*[!0-9]*) ;; *) [ "$reply" -ge 1 ] && [ "$reply" -le "$nd" ] && break ;; esac
    echo "a draft number from 1 to $nd"
  done
  top=$reply
  jq -nc --arg t "$task" --arg top "Draft $top" --argjson d "$rec" --arg at "$(now)" \
    '{task: $t, top: $top, drafts: $d, at: $at}' >> "$lvotes"
  return 0
}

lineup_vote() {
  [ -f "$lineup" ] || die "no lineup yet: eval/models/blind.sh $out make"
  local total left=0 task rc
  total=$(jq '.tasks | length' "$lineup")
  for task in $(jq -r '.tasks[].task' "$lineup"); do judged "$task" || left=$((left + 1)); done
  [ "$left" -gt 0 ] || { echo "all $total tasks are judged: eval/models/blind.sh $out reveal"; return 0; }
  echo "$left of $total tasks to judge. Any question takes q (quit; this task is not saved) or x (skip this task)."
  for task in $(jq -r '.tasks[].task' "$lineup"); do
    judged "$task" && continue
    judge_task "$task"; rc=$?
    [ "$rc" = 2 ] && return 0
  done
  echo "done: eval/models/blind.sh $out reveal"
}

lineup_reveal() {
  [ -f "$lineup" ] && [ -f "$lkey" ] || die "no lineup yet: eval/models/blind.sh $out make"
  [ -s "$lvotes" ] || die "no judgements yet: eval/models/blind.sh $out vote"
  jq -rs --slurpfile k "$lkey" --slurpfile L "$lineup" '
    def pad(n): tostring | if length >= n then . else . + (" " * (n - length)) end;
    def pct(a; b): if b == 0 then "n/a" else "\(a * 100 / b | round)%" end;
    def stats: {n: length, top: (map(select(.top)) | length),
      ok: (map(select(.verdict != "rewrite")) | length), ship: (map(select(.verdict == "ship as-is")) | length),
      tags: ([.[].tags[]] | group_by(.) | map({tag: .[0], n: length}) | sort_by(-.n, .tag) | .[0:3])};
    def line: "top pick \(pct(.top; .n)) (\(.top)/\(.n)) · ship or light edit \(pct(.ok; .n)) · ship as-is \(pct(.ship; .n))"
      + (if (.tags | length) > 0 then " · tags " + (.tags | map("\(.tag) ×\(.n)") | join(", ")) else "" end);
    $k[0].tasks as $key | $L[0] as $lu
    | (group_by(.task) | map(last)) as $v
    | [$v[] | . as $x | ($lu.tasks[] | select(.task == $x.task)) as $t | $x.drafts[]
       | {task: $x.task, group: $t.group, label, verdict, tags, model: $key[$x.task][.label], top: (.label == $x.top)}] as $r
    | ($r | map(.model) | unique) as $models | ([$models[] | length] | max) as $w
    | ($r | map(.group) | unique) as $groups
    | "== blind lineup: \($v | length) of \($lu.tasks | length) tasks judged",
      "",
      "== per model",
      ($models[] as $m | "  \($m | pad($w))  \($r | map(select(.model == $m)) | stats | line)"),
      "",
      "== per model and task group",
      ($groups[] as $g | "  \($g)",
        ($models[] as $m | ($r | map(select(.group == $g and .model == $m))) as $mine | select($mine | length > 0)
         | "    \($m | pad($w))  \($mine | stats | line)")),
      "",
      "== top pick per task",
      ($v[] | . as $x | "  \(.task): \($key[$x.task][$x.top]) (\(.top))"),
      "",
      "label bias, top picks by label: " + ($v | group_by(.top) | map("\(.[0].top) ×\(length)") | join(", "))
  ' "$lvotes"
}

lineup_status() {
  if [ ! -f "$lineup" ]; then echo "no lineup yet: eval/models/blind.sh $out make"; return 0; fi
  local total done_n=0 task
  total=$(jq '.tasks | length' "$lineup")
  for task in $(jq -r '.tasks[].task' "$lineup"); do judged "$task" && done_n=$((done_n + 1)); done
  echo "lineup: $total tasks, $done_n judged"
}

case "$cmd" in
  make) lineup_make "$@" ;;
  vote) lineup_vote ;;
  reveal) lineup_reveal ;;
  status) lineup_status; [ ! -f "$pairs" ] || pairs_status ;;
  pairs)
    sub=${1:-status}; [ $# -gt 0 ] && shift
    case "$sub" in
      make) pairs_make "$@" ;; vote) pairs_vote ;; reveal) pairs_reveal ;; status) pairs_status ;;
      *) die "unknown pairs command '$sub' (make, vote, reveal or status)" ;;
    esac ;;
  -h|--help) usage ;;
  *) die "unknown command '$cmd' (make, vote, reveal, status or pairs)" ;;
esac
