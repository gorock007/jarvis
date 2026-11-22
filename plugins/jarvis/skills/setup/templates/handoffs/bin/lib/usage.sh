# shellcheck shell=bash
# Sourced by bin/jarvis; not run on its own.
# ---------------------------------------------------------------- usage

cmd_usage() {
  local audit since_arg until_arg json merged ignored over r wakes reading wruns whos
  have python3 || die "python3 is needed for jarvis usage"
  have jq || die "jq is needed for jarvis usage"
  audit="$(cd "$(dirname "$0")" && pwd)/cc_usage_audit.py"
  [ -f "$audit" ] || die "no $audit — re-run jarvis:setup"
  # Match band's account-wide reading, with the same repo-local fallback.
  reading="$JHOME/usage.json"
  [ -s "$reading" ] || reading="$STATE/usage.json"
  set -- --project="$PROJ" --repo-root="$ROOT" --usage-file="$reading" --top=5 \
    --role worker='^You are a Jarvis worker' \
    --role-tool orchestrator='superset agents create|ultron agent spawn|handoffs/bin/jarvis (start|status|spawn|merge|send|read|close)' \
    --bash-category coordination='terminals (read|send|list|close)|term (read|send|list|close)|chat send|tmux |handoffs/|OPEN\.md|jev\.sh|bin/jarvis' \
    "$@"
  json=$(python3 "$audit" "$@" --json) || exit 1
  since_arg=$(printf '%s' "$json" | jq -r '.period[0]')
  until_arg=$(printf '%s' "$json" | jq -r '.period[1]')
  merged=$(git log --since="$since_arg" --until="$until_arg" --diff-filter=A --name-only --format= -- "$H/merged/*.md" 2>/dev/null | grep -c '\.md$')
  # Ignored, untracked handoffs have no merge commit: approximate with file mtime.
  # Keep the Git count intact, and never count tracked handoffs a second time.
  ignored=$(git ls-files -z --others --ignored --exclude-standard -- "$H/merged/*.md" | python3 -c '
import datetime as dt, os, sys
start, end = (dt.datetime.fromisoformat(t).timestamp() for t in sys.argv[1:])
count = 0
for path in sys.stdin.buffer.read().split(b"\0"):
    if path and os.path.isfile(path) and start <= os.path.getmtime(path) <= end:
        count += 1
print(count)
' "$since_arg" "$until_arg") || exit 1
  merged=$((merged + ignored))
  # this checkout's runs that reached a budget (spawn epoch, paused or not), from the run registry
  over=$(for r in "$RUNS"/*; do
    [ -f "$r" ] && r=${r##*/} && [ -n "$(run_get "$r" budget)$(run_get "$r" budget_was)" ] || continue
    printf '{"t":%s,"p":%s}\n' "$(run_get "$r" spawned | grep -Ex '[0-9]+' || echo 0)" "$([ -n "$(run_get "$r" paused)" ] && echo true || echo false)"
  done | jq -s -c . 2>/dev/null)
  # every run record, and each archived handoff with when it was merged, for Workers by agent/model
  wruns=$(for r in "$RUNS"/*; do [ -f "$r" ] && printf '%s\n' "$r"; done | while IFS= read -r r; do
    awk -v id="${r##*/}" '
      { i = index($0, ": ") } i { v[substr($0, 1, i - 1)] = substr($0, i + 2) }
      END { printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", id, v["agent"], v["model"], v["brief"], v["spawned"], v["ended"],
              v["merge_outcome"], v["merge_reason"], (v["budget"] v["budget_was"] != "" ? 1 : 0) }' "$r"
  done | jq -R -s -c '[split("\n")[] | select(length > 0) | split("\t")
    | {run: .[0], agent: (if .[1] == "" then "?" else .[1] end), model: (if .[2] == "" then "?" else .[2] end), brief: .[3],
       spawned: (.[4] | tonumber? // null), ended: (.[5] | tonumber? // null), outcome: .[6], reason: .[7], budget: (.[8] == "1")}]')
  whos=$(for f in "$H"/merged/*.md; do
    [ -f "$f" ] && printf '%s\t%s\t%s\n' "$(field brief "$f" | awk '{print $1}')" "$(field status "$f" | awk '{print $1}')" "$(merged_at "$f")"
  done | jq -R -s -c '[split("\n")[] | select(length > 0) | split("\t") | {brief: .[0], status: .[1], t: (.[2] | tonumber? // null)}]')
  # watcher wake-ups in the report's window, from watch.log (UTC times compare as text)
  if [ -f "$STATE/watch.log" ]; then
    wakes=$(awk -F'\t' -v t0="$(printf '%s' "$json" | jq -r '.period[0][0:19]')" \
      -v t1="$(printf '%s' "$json" | jq -r '.period[1][0:19]')" -v m="$merged" '
      { t = substr($1, 1, 19) } t < t0 || t > t1 { next }
      $2 == "auto" { a[$3]++; next }
      $2 != "woke" && $2 != "cleared" { next }
      { n++; k = split($3, r, ","); for (i = 1; i <= k; i++) c[r[i]]++ }
      END {
        printf "wake-ups (this repo): %d · per merged handoff %s", n, (m > 0 ? sprintf("%.2f", n / m) : "n/a")
        printf " · handoff %d, prompt %d, stall %d, limit %d, budget %d", c["handoff"], c["prompt"], c["stall"], c["limit"], c["budget"]
        printf " · auto-handled: trust %d, edit %d, nudge %d\n", a["trust"], a["edit"], a["nudge"]
      }' "$STATE/watch.log")
  else
    wakes="wake-ups (this repo): no watcher log yet"
  fi
  printf '%s' "$json" | jq -r --argjson merged "$merged" --argjson ignored "$ignored" --argjson over "${over:-[]}" --arg wakes "$wakes" \
    --argjson wruns "${wruns:-[]}" --argjson whos "${whos:-[]}" '
    def usd: "$" + ((. * 100 | round) / 100 | tostring);
    def age:
      if . < 3600 then ((. / 60 | floor | tostring) + "m")
      else ((. / 3600 | floor | tostring) + "h" + (((. % 3600) / 60 | floor) | tostring) + "m") end;
    def epoch: sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601? // 0;
    # the run a handoff or transcript belongs to: the latest run of its brief spawned by then
    def owner($b; $t): [$wruns[] | select(.brief == $b and .spawned != null and .spawned <= $t)] | max_by(.spawned) | .run?;
    def count(f): [.[] | select(f)] | length;
    def role(r): [.by_role | to_entries[] | select(.key == r or .key == (r + " > subagents")) | .value.usd] | add // 0;
    (role("orchestrator")) as $coord | (role("worker")) as $build
    | (if has("machine_peak_concurrent_sessions_10min") then "all projects" else "this repo" end) as $scope
    | (if $scope == "all projects" then ([.briefs[] | select(.outcome == "merged")] | length) else $merged end) as $merged_count
    | "jarvis usage · \(.period[0][0:16]) → \(.period[1][0:16])",
      "API-equivalent estimate at list prices (not your subscription usage): \(.total_usd | usd) in \($scope)",
      (if .subscription_usage then
         "subscription usage: 5h \(.subscription_usage.five_hour_pct // "?")% · 7d \(.subscription_usage.seven_day_pct // "?")% · reading \(.subscription_usage.age_seconds | age) old"
       else "subscription usage: no reading — check /usage" end),
      "",
      "  coordinating (Jarvis + its subagents): \($coord | usd)",
      "  building (workers + their subagents):  \($build | usd)",
      "  coordinating ÷ building: \(if $build > 0 then ($coord / $build * 100 | round) / 100 else "n/a" end)   (target ≤ 0.3)",
      "  merged handoffs: \($merged_count)\(if $scope == "this repo" and $ignored > 0 then " (\($ignored) by file mtime)" else "" end) · cost per merged handoff: \(if $merged_count > 0 then (($coord + $build) / $merged_count) | usd else "n/a" end)",
      "  worst 5-hour window: \(.peak_window_usd | usd) · most sessions in one 10-min slot: \(.peak_concurrent_sessions_10min)",
      (if has("machine_peak_concurrent_sessions_10min") then "  machine-wide peak across all projects: \(.machine_peak_concurrent_sessions_10min) sessions / 10 min" else empty end),
      "  cache reloads after idle (Jarvis): \([.reloads[] | select(.role == "orchestrator" and .cause == "after idle")] | "\(map(.turns) | add // 0) turns, \(map(.usd) | add // 0 | usd)")",
      "",
      "  Workers (top 5 by API-equivalent cost):",
      (.workers[:5][]? | "    \(.brief) · \(.model) · \(.turns) turns · \(.usd | usd) · context \((.start_ctx / 1000) | round)k→\((.peak_ctx / 1000) | round)k · \((.wall_seconds / 60) | round)m · \(.outcome)"),
      "  Most expensive briefs:",
      (.top_briefs[]? | "    \(.brief) · \(.sessions) attempt\(if .sessions == 1 then "" else "s" end) · \(.usd | usd) · \(.outcome)"),
      "",
      "  Waste signals:",
      "    abandoned: \(.abandoned.sessions) sessions · \(.abandoned.usd | usd)",
      "    repeated attempts: \(.repeated_attempts.briefs) briefs · \(.repeated_attempts.extra_sessions) extra sessions · \(.repeated_attempts.extra_usd | usd) extra",
      ((.period[0] | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601? // 0) as $t0 | [$over[] | select(.t >= $t0)]
        | "    over budget (this repo): \(length) run\(if length == 1 then "" else "s" end) asked for a partial handoff · \([.[] | select(.p)] | length) paused"),
      "    \($wakes)",
      "    failed test runs (workers with 3+): \(if (.failed_test_runs | length) == 0 then "none" else [.failed_test_runs[] | "\(.brief) \(.count)"] | join(", ") end)",
      "    stale open >8h and idle >1h: \(if (.stale_open_sessions | length) == 0 then "none" else [.stale_open_sessions[].name] | join(", ") end)",
      "    worker cost above 150k context: \((.context_growth.worker_usd_above_150k_share * 100) | round)% · peak p50 \(((.context_growth.peak_ctx_p50 // 0) / 1000) | round)k · p90 \(((.context_growth.peak_ctx_p90 // 0) / 1000) | round)k",
      "",
      "  Jarvis by model (for comparing coordinator configs):",
      ([.by_role_model[]? | select(.role == "orchestrator")] | sort_by(-.usd)[]
        | "    \(.model): \(.turns) turns · \(.usd | usd) · $\((.usd / .turns * 1000 | round) / 1000)/turn · avg ctx \((.ctx / .turns / 1000) | round)k"),
      "",
      "  Workers by agent/model (this repo, runs spawned in the window):",
      ((.period[0] | epoch) as $t0 | (.period[1] | epoch) as $t1
        | [$whos[] | . + {run: (if .t then owner(.brief; .t) else null end)}] as $hos
        | [.workers[]? | . + {run: owner(.brief_path; (.start | epoch) + 60)}] as $wcs
        | [$wruns[] | select(.spawned != null and .spawned >= $t0 and .spawned <= $t1)]
        | if length == 0 then "    none" else
          group_by([.agent, .model]) | map(
            (map(.run)) as $ids
            | [$hos[] | select(.run as $r | $ids | index([$r]))] as $h
            | ($h | map(.run) | unique) as $done
            | [.[] | select(.outcome != "" or (.run as $r | $done | index([$r])))] as $m
            | [$wcs[] | select(.run as $r | $ids | index([$r]))] as $c
            | ([.[] | select(.spawned != null and .ended != null) | .ended - .spawned] | sort) as $w
            | (map(.brief) | unique | length) as $nb
            | {agent: .[0].agent, model: .[0].model, runs: length, briefs: $nb, merged: ($h | map(.brief) | unique | length),
               respawns: (if $nb > 0 then ((length - $nb) / $nb * 100 | round) / 100 else 0 end),
               wall: (if ($w | length) == 0 then null else ($w | length) as $n
                      | if $n % 2 == 1 then $w[($n - 1) / 2] else ($w[$n / 2 - 1] + $w[$n / 2]) / 2 end end),
               budget: count(.budget),
               clean: ($m | count(.outcome == "clean")), corrected: ($m | count(.outcome == "corrected")),
               reasons: ([$m[] | select(.outcome == "corrected") | if .reason == "" then "?" else .reason end] | group_by(.) | map("\(.[0]) \(length)") | join(", ")),
               escalated: ($m | count(.outcome == "escalated")), respawned: ($m | count(.outcome == "respawned")),
               unrecorded: ($m | count(.outcome == "")),
               done: ($h | count(.status == "done")), partial: ($h | count(.status == "partial")), blocked: ($h | count(.status == "blocked")),
               usd: ($c | map(.usd) | add // 0), priced: ($c | map(.run) | unique | length)})
          | sort_by(-.runs, .agent, .model)[]
          | "    \(.agent) · \(.model): \(.runs) run\(if .runs == 1 then "" else "s" end) · \(.briefs) brief\(if .briefs == 1 then "" else "s" end), \(.merged) merged · respawns per brief \(.respawns) · median wall \(if .wall == null then "n/a" else (.wall | age) end) · hit budget \(.budget) · \(if .agent != "claude" then "n/a" elif .priced == 0 then "n/a (no transcripts)" elif .priced < .runs then "\(.usd | usd) (\(.priced)/\(.runs) runs priced)" else (.usd | usd) end)",
            "      merges: clean \(.clean) · corrected \(.corrected)\(if .reasons != "" then " (\(.reasons))" else "" end) · escalated \(.escalated) · respawned \(.respawned) · unrecorded \(.unrecorded) · handoffs: done \(.done), partial \(.partial), blocked \(.blocked)"
          end)'
}
