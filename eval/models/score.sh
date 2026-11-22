#!/usr/bin/env bash
# Score a run's review and longctx answers against the keys in the task headers.
#
#   eval/models/score.sh <out>
#
# review   a reported "BUG: path:line" finds a planted bug when the file is the
#          same and the line is within the task's tolerance of the key's line
#          or range. Each bug is found at most once; a report that finds none
#          is a false positive.
# longctx  the last "<id>: <answer>" line for each question must equal one of
#          the key's answers after case, spaces, quotes, markdown and trailing
#          punctuation are dropped.
# No model judges anything. Writes <out>/scores.json; writing tasks go to blind.sh.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$here/lib.sh"

[ $# -eq 1 ] || { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
out=$1
[ -f "$out/run.json" ] || die "$out has no run.json (is it a run.sh --out folder?)"
command -v jq >/dev/null || die "needs jq"

work=$(mktemp -d "${TMPDIR:-/tmp}/eval-models-score.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$work"' EXIT
: > "$work/in.jsonl"
nwriting=0
for t in "$out"/tasks/*.json; do
  [ -e "$t" ] || continue
  name=$(basename "$t" .json)
  kind=$(jq -r .kind "$t")
  [ "$kind" = writing ] && { nwriting=$((nwriting + 1)); continue; }
  for m in $(jq -r '.models[]' "$out/run.json"); do
    parse_model "$m"
    a="$out/answers/$name/$m_slug.txt"
    [ -f "$a" ] || continue
    jq -nc --slurpfile t "$t" --rawfile a "$a" --arg m "$m_id" '{task: $t[0], model: $m, answer: $a}' >> "$work/in.jsonl"
  done
done
[ -s "$work/in.jsonl" ] || { echo "no review or longctx answers in $out"; exit 1; }

jq -s '
  def norm: ascii_downcase | gsub("[*`\"\u201c\u201d\u2018\u2019\u0027]"; "") | gsub("[,;!?]"; "") | gsub("\\s+"; " ")
    | sub("^ "; "") | sub(" $"; "") | sub("\\.$"; "");
  def samefile(a; b): a == b or (a | endswith("/" + b)) or (b | endswith("/" + a));
  def reports: [.answer | split("\n")[]
    | capture("BUG[*_]*\\s*:?[*_]*\\s*`?(?<path>[^\\s:`*]+):(?<line>[0-9]+)")
    | {path: (.path | sub("^\\./"; "")), line: (.line | tonumber)}] | unique;
  def review:
    .task as $t | reports as $r
    | (reduce $t.bugs[] as $b ({used: [], found: [], missed: []};
        . as $s
        | ([range(0; $r | length)] | map(select(. as $i
            | ($s.used | any(. == $i) | not)
            and samefile($r[$i].path; $b.path)
            and $r[$i].line >= $b.lo - $t.tolerance and $r[$i].line <= $b.hi + $t.tolerance)) | first) as $hit
        | if $hit == null then .missed += [$b.id] else .used += [$hit] | .found += [$b.id] end)) as $m
    | {task: $t.name, kind: "review", model, found: ($m.found | length), total: ($t.bugs | length),
       missed: $m.missed, reported: ($r | length),
       false_positives: [$r | to_entries[] | select(.key as $k | $m.used | any(. == $k) | not) | .value | "\(.path):\(.line)"]};
  def longctx:
    .task as $t
    | [.answer | split("\n")[]
       | capture("^[\\s*_>#-]*(?<id>[A-Za-z]+[0-9]+)[*_]*\\s*[:=)]\\s*(?<val>.*)$")] as $a
    | ($t.answers | map(. as $k
        | ([$a[] | select((.id | ascii_downcase) == ($k.id | ascii_downcase))] | last | .val) as $got
        | {id: $k.id, got: $got,
           ok: ($got != null and (($got | norm) as $g | $k.accept | map(norm) | any(. == $g)))})) as $rows
    | {task: $t.name, kind: "longctx", model, correct: ($rows | map(select(.ok)) | length),
       total: ($rows | length), wrong: ($rows | map(select(.ok | not) | {id, got}))};
  map(if .task.kind == "review" then review else longctx end)
' "$work/in.jsonl" > "$work/rows.json" || die "scoring failed"

jq -n --slurpfile rows "$work/rows.json" --slurpfile run "$out/run.json" '
  $rows[0] as $r
  | {scored_at: (now | todate), rows: $r,
     models: [$run[0].models[] as $m | ($r | map(select(.model == $m))) as $mine | select($mine | length > 0)
       | ($mine | map(select(.kind == "review"))) as $rv | ($mine | map(select(.kind == "longctx"))) as $lc
       | {model: $m,
          review: {found: ($rv | map(.found) | add // 0), total: ($rv | map(.total) | add // 0),
                   reported: ($rv | map(.reported) | add // 0), false_positives: ($rv | map(.false_positives | length) | add // 0)},
          longctx: {correct: ($lc | map(.correct) | add // 0), total: ($lc | map(.total) | add // 0)}}]}
' > "$out/scores.json"

jq -r '
  def pad(n): tostring | if length >= n then . else . + (" " * (n - length)) end;
  def pct(a; b): if b == 0 then "n/a" else "\(a * 100 / b | round)%" end;
  ([.rows[].model | length] | max) as $w | ([.rows[].task | length] | max) as $tw
  | (.rows | map(select(.kind == "review"))) as $rv | (.rows | map(select(.kind == "longctx"))) as $lc
  | (if ($rv | length) > 0 then
      "== review: planted bugs found (same file, line within tolerance)",
      ($rv[] | "  \(.task | pad($tw))  \(.model | pad($w))  \(.found)/\(.total)"
        + (if (.missed | length) > 0 then "  missed \(.missed | join(","))" else "" end)
        + (if (.false_positives | length) > 0 then "  false+ \(.false_positives | length): \(.false_positives | join(" "))" else "" end)),
      ""
    else empty end),
    (if ($lc | length) > 0 then
      "== longctx: exact answers",
      ($lc[] | "  \(.task | pad($tw))  \(.model | pad($w))  \(.correct)/\(.total)"
        + (if (.wrong | length) > 0 then "  wrong " + (.wrong | map("\(.id)=\(.got // "(none)" | tostring | .[0:40] | @json)") | join(" ")) else "" end)),
      ""
    else empty end),
    "== per model",
    (.models[] | "  \(.model | pad($w))"
      + (if .review.total > 0 then "  review recall \(pct(.review.found; .review.total)) (\(.review.found)/\(.review.total))"
         + " precision \(pct(.review.reported - .review.false_positives; .review.reported))" else "" end)
      + (if .longctx.total > 0 then "  longctx \(pct(.longctx.correct; .longctx.total)) (\(.longctx.correct)/\(.longctx.total))" else "" end))
' "$out/scores.json"
[ "$nwriting" = 0 ] || echo "  ($nwriting writing tasks are not scored here: eval/models/blind.sh $out make)"
echo
echo "== cost"
cost_summary "$out/calls.jsonl"
