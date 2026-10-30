#!/usr/bin/env bash
# Synthetic, offline coverage for cc_usage_audit.py and `jarvis usage`.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tpl="$here/../plugins/jarvis/skills/setup/templates"
audit="$tpl/handoffs/bin/cc_usage_audit.py"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/jarvis-usagetest.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
fails=0
ok() { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; fails=$((fails + 1)); }
check() { if [ "$2" = 0 ]; then ok "$1"; else bad "$1"; fi; }

repo="$tmp/repo"
home="$tmp/home"
mkdir -p "$repo" "$home/.claude/projects"
repo=$(cd "$repo" && pwd -P)
(
  cd "$repo" || exit 1
  git init -q
  cp -R "$tpl/handoffs" .
  mkdir -p handoffs/.jarvis/runs
  printf '# alpha done\nstatus: done\nbrief: handoffs/briefs/alpha.md\n' > handoffs/merged/alpha-handoff.md
  printf '# delta awaiting merge\nstatus: done\nbrief: handoffs/briefs/delta.md\n' > handoffs/delta-handoff.md
  printf 'brief: handoffs/briefs/gamma.md\nagent: claude\nmodel: claude-sonnet-4-6\nspawned: 1\nstate: lost\n' > handoffs/.jarvis/runs/gamma-run
  now=$(date +%s)
  printf '{"five_hour":{"used_percentage":42},"seven_day":{"used_percentage":61},"ts":%s}\n' "$((now - 300))" > handoffs/.jarvis/usage.json
  git add -A && git commit -qm fixture
)

proj=$(printf '%s' "$repo" | sed 's#[^A-Za-z0-9]#-#g')
pdir="$home/.claude/projects/$proj"
other="$home/.claude/projects/-another-project"
mkdir -p "$pdir" "$other"
mkdir -p "$home/.claude/sessions"
printf '{"sessionId":"beta","status":"idle"}\n' > "$home/.claude/sessions/beta.json"

python3 - "$pdir" "$other" "$repo" <<'PY'
import datetime as dt, json, os, sys
pdir, other, repo = sys.argv[1:]
now = dt.datetime.now(dt.timezone.utc)

def stamp(hours=0, minutes=0):
    return (now - dt.timedelta(hours=hours, minutes=minutes)).isoformat().replace("+00:00", "Z")

def user(prompt, when):
    return {"type": "user", "timestamp": when, "cwd": repo,
            "message": {"content": prompt}}

def assistant(rid, when, ctx, tool=None):
    content = []
    if tool:
        content.append({"type": "tool_use", "id": tool[0], "name": "Bash", "input": {"command": tool[1]}})
    return {"type": "assistant", "timestamp": when, "requestId": rid, "entrypoint": "cli", "cwd": "",
            "message": {"model": "claude-sonnet-4-6", "content": content,
                        "usage": {"input_tokens": 1000, "output_tokens": 100,
                                  "cache_read_input_tokens": ctx - 1000,
                                  "cache_creation_input_tokens": 0}}}

def result(tool_id, when, failed=True):
    return {"type": "user", "timestamp": when,
            "message": {"content": [{"type": "tool_result", "tool_use_id": tool_id,
                                      "is_error": failed,
                                      "content": "Exit code 1\nfailed" if failed else "ok"}]}}

def write(path, records):
    with open(path, "w") as f:
        for record in records:
            f.write(json.dumps(record) + "\n")

prompt_a = "You are a Jarvis worker. Read AGENTS.md, then do the task in handoffs/briefs/alpha.md."
records = [user(prompt_a, stamp(minutes=50))]
for i, (mins, ctx, cmd) in enumerate(((49, 12000, "bash eval/selftest.sh"),
                                      (45, 160000, "pytest -q"),
                                      (40, 175000, "npm test"))):
    tid = "tool-a-%s" % i
    records += [assistant("req-a-%s" % i, stamp(minutes=mins), ctx, (tid, cmd)),
                result(tid, stamp(minutes=mins - 1))]
write(os.path.join(pdir, "alpha-one.jsonl"), records)

write(os.path.join(pdir, "alpha-two.jsonl"), [
    user(prompt_a, stamp(minutes=35)),
    assistant("req-a2", stamp(minutes=34), 40000)])

prompt_b = "You are a Jarvis worker. Read AGENTS.md, then do the task in handoffs/briefs/beta.md."
write(os.path.join(pdir, "beta.jsonl"), [
    user(prompt_b, stamp(hours=9, minutes=1)),
    assistant("req-b1", stamp(hours=9), 20000),
    assistant("req-b2", stamp(hours=2), 155000)])

prompt_g = "You are a Jarvis worker. Read AGENTS.md, then do the task in handoffs/briefs/gamma.md."
write(os.path.join(pdir, "gamma.jsonl"), [user(prompt_g, stamp(minutes=30)),
                                          assistant("req-g", stamp(minutes=29), 30000)])
prompt_d = "You are a Jarvis worker. Read AGENTS.md, then do the task in handoffs/briefs/delta.md."
write(os.path.join(pdir, "delta.jsonl"), [user(prompt_d, stamp(minutes=25)),
                                          assistant("req-d", stamp(minutes=24), 25000)])

write(os.path.join(other, "interactive.jsonl"), [
    user("ordinary interactive work", stamp(minutes=45)),
    assistant("req-i", stamp(minutes=44), 30000)])
PY

json="$tmp/report.json"
python3 "$audit" --root "$home/.claude/projects" --project="$proj" --repo-root "$repo" \
  --usage-file "$repo/handoffs/.jarvis/usage.json" --days 2 --top 1 \
  --role worker='^You are a Jarvis worker' --json > "$json"

python3 - "$json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert len(r["workers"]) == 5
alpha = next(x for x in r["briefs"] if x["brief"] == "alpha")
assert alpha["sessions"] == 2 and alpha["outcome"] == "merged"
assert len(r["top_briefs"]) == 1
assert r["abandoned"]["sessions"] == 2 and r["abandoned"]["usd"] > 0
assert next(x for x in r["workers"] if x["brief"] == "gamma")["outcome"] == "lost"
assert not next(x for x in r["workers"] if x["brief"] == "delta")["abandoned"]
assert r["repeated_attempts"]["briefs"] == 1 and r["repeated_attempts"]["extra_sessions"] == 1
assert r["repeated_attempts"]["extra_usd"] > 0
assert r["failed_test_runs"] == [{"brief": "alpha", "session": "alpha-on", "count": 3}]
assert r["context_growth"]["worker_usd_above_150k_share"] > 0
assert r["context_growth"]["peak_ctx_p90"] == 175000
assert any(x["name"] == "beta" for x in r["stale_open_sessions"])
assert r["subscription_usage"]["five_hour_pct"] == 42
PY
check "JSON has workers, brief outcomes, waste and context aggregates" $?

out=$(python3 "$audit" --root "$home/.claude/projects" --project="$proj" --repo-root "$repo" \
  --usage-file "$repo/handoffs/.jarvis/usage.json" --days 2 --role worker='^You are a Jarvis worker')
printf '%s' "$out" | grep -q 'API-equivalent estimate at list prices (not your subscription usage)' \
  && printf '%s' "$out" | grep -q 'Subscription usage: 5h 42% · 7d 61%' \
  && printf '%s' "$out" | grep -q 'WORKERS / BRIEFS' \
  && printf '%s' "$out" | grep -q 'abandoned worker sessions: 2'; check "text audit labels estimates and reports worker waste" $?

python3 "$audit" --root "$home/.claude/projects" --project="$proj" --all-projects --repo-root "$repo" \
  --days 2 --role worker='^You are a Jarvis worker' --json > "$tmp/all.json"
jq -e '.machine_peak_concurrent_sessions_10min >= 2 and (.by_role.interactive.sessions == 1)' "$tmp/all.json" >/dev/null
check "--all-projects includes non-Jarvis sessions and machine peak" $?

out=$(
  cd "$repo" || exit 1
  HOME="$home" handoffs/bin/jarvis usage --days 2 --top 2
)
printf '%s' "$out" | grep -q '^API-equivalent estimate at list prices (not your subscription usage):' \
  && printf '%s' "$out" | grep -q '^subscription usage: 5h 42% · 7d 61%' \
  && printf '%s' "$out" | grep -q 'Most expensive briefs:' \
  && printf '%s' "$out" | grep -q 'failed test runs (workers with 3+): alpha 3'; check "jarvis usage is the labelled one-screen report" $?

echo
if [ "$fails" = 0 ]; then echo "usagetest: all passed"; else echo "usagetest: $fails failed"; exit 1; fi
