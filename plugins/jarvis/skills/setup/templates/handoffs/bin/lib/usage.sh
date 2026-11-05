# shellcheck shell=bash
# Sourced by bin/jarvis; not run on its own.
# ---------------------------------------------------------------- usage

cmd_usage() {
  local audit since_arg json merged over r wakes
  have python3 || die "python3 is needed for jarvis usage"
  have jq || die "jq is needed for jarvis usage"
  audit="$(cd "$(dirname "$0")" && pwd)/cc_usage_audit.py"
  [ -f "$audit" ] || die "no $audit — re-run jarvis:setup"
  set -- --project="$PROJ" --repo-root="$ROOT" --usage-file="$STATE/usage.json" --top=5 \
    --role worker='^You are a Jarvis worker' \
    --role-tool orchestrator='superset agents create|ultron agent spawn|handoffs/bin/jarvis (start|status|spawn|merge|send|read|close)' \
    --bash-category coordination='terminals (read|send|list|close)|term (read|send|list|close)|chat send|tmux |handoffs/|OPEN\.md|jev\.sh|bin/jarvis' \
    "$@"
  json=$(python3 "$audit" "$@" --json) || exit 1
  since_arg=$(printf '%s' "$json" | jq -r '.period[0]')
  merged=$(git log --since="$since_arg" --diff-filter=A --name-only --format= -- "$H/merged/*.md" 2>/dev/null | grep -c '\.md$')
  # this checkout's runs that reached a budget (spawn epoch, paused or not), from the run registry
  over=$(for r in "$RUNS"/*; do
    [ -f "$r" ] && r=${r##*/} && [ -n "$(run_get "$r" budget)$(run_get "$r" budget_was)" ] || continue
    printf '{"t":%s,"p":%s}\n' "$(run_get "$r" spawned | grep -Ex '[0-9]+' || echo 0)" "$([ -n "$(run_get "$r" paused)" ] && echo true || echo false)"
  done | jq -s -c . 2>/dev/null)
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
  printf '%s' "$json" | jq -r --argjson merged "$merged" --argjson over "${over:-[]}" --arg wakes "$wakes" '
    def usd: "$" + ((. * 100 | round) / 100 | tostring);
    def age:
      if . < 3600 then ((. / 60 | floor | tostring) + "m")
      else ((. / 3600 | floor | tostring) + "h" + (((. % 3600) / 60 | floor) | tostring) + "m") end;
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
      "  merged handoffs: \($merged_count) · cost per merged handoff: \(if $merged_count > 0 then (($coord + $build) / $merged_count) | usd else "n/a" end)",
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
        | "    \(.model): \(.turns) turns · \(.usd | usd) · $\((.usd / .turns * 1000 | round) / 1000)/turn · avg ctx \((.ctx / .turns / 1000) | round)k")'
}
