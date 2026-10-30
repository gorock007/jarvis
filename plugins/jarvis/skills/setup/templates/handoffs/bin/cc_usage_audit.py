#!/usr/bin/env python3
"""cc-usage-audit: see where your Claude Code usage actually goes.

Reads the session transcripts Claude Code keeps on this machine
(~/.claude/projects/**/*.jsonl), prices every request at API rates, and
reports what drove the spend: models, long context, cache reloads after idle
gaps, subagents, headless/hook sessions, what each turn was doing, and your
peak 5-hour burn.

Local only: no network calls, nothing leaves your machine. Python 3.8+, no
dependencies.

Vendored into Jarvis from https://github.com/gorock007/cc-usage-audit (MIT), with
Jarvis role, worker/brief, run-outcome and subscription-reading aggregates.
"""
import argparse, collections, datetime as dt, glob, json, os, re, statistics, sys

# USD per million tokens: input, output, cache read, cache write 5m, cache write 1h.
# Check https://docs.claude.com/en/docs/about-claude/pricing and override with
# --prices FILE (same shape, JSON) if anything here is out of date.
PRICES = {
    "claude-fable-5-1":  (10.0, 50.0, 0.25, 12.50, 20.0),
    "claude-fable-5":    (10.0, 50.0, 1.00, 12.50, 20.0),
    "claude-mythos-5":   (10.0, 50.0, 1.00, 12.50, 20.0),
    "claude-opus-5-5":   (4.0,  20.0, 0.20,  5.00,  8.0),
    "claude-opus-5":     (5.0,  25.0, 0.50,  6.25, 10.0),
    "claude-opus-4-8":   (5.0,  25.0, 0.50,  6.25, 10.0),
    "claude-opus-4-7":   (5.0,  25.0, 0.50,  6.25, 10.0),
    "claude-opus-4-6":   (5.0,  25.0, 0.50,  6.25, 10.0),
    "claude-opus-4-5":   (5.0,  25.0, 0.50,  6.25, 10.0),
    "claude-sonnet-5":   (2.0,  10.0, 0.20,  2.50,  4.0),
    "claude-sonnet-4-6": (3.0,  15.0, 0.30,  3.75,  6.0),
    "claude-sonnet-4-5": (3.0,  15.0, 0.30,  3.75,  6.0),
    "claude-haiku-4-5":  (1.0,   5.0, 0.10,  1.25,  2.0),
}
LONG_CTX = 150_000      # the threshold /usage calls out
RELOAD_TOKENS = 40_000  # a cache write this big mid-session means the context was rewritten
CACHE_TTL_MIN = 60      # subscription prompt cache TTL (5 min on API keys / usage credits)
WINDOW_H = 5
DEFAULT_TEST_RE = r"test|pytest|vitest|jest|selftest|cargo test|go test"
WORKER_PROMPT_RE = re.compile(r"^You are a Jarvis worker")
BRIEF_RE = re.compile(r"handoffs/briefs/([^\s\"'`]+\.md)")

BASH_CATEGORIES = [
    ("wait/sleep loop", r"\bsleep\b|\buntil\b|while .*;\s*do|fswatch|inotifywait"),
    ("git inspect",     r"\bgit\s+(status|diff|log|show|branch)\b"),
    ("git write",       r"\bgit\s+(add|commit|push|mv|rm|merge|rebase|checkout|switch)\b"),
    ("tests/build",     r"pytest|\bnpm (test|run)|pnpm|yarn|cargo (test|build)|go test|swift (build|test)|xcodebuild|\bmake\b|tsc\b"),
    ("read/search",     r"^\s*(cat|head|tail|sed -n|less|ls|find|grep|rg|wc)\b"),
]

def model_price(model, prices):
    m = re.sub(r"-\d{8}$", "", model or "")
    for key in sorted(prices, key=len, reverse=True):
        if m.startswith(key):
            return key, prices[key]
    return m, None

def ts(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))

def first_prompt(rec):
    c = rec.get("message", {}).get("content")
    if isinstance(c, list):
        c = " ".join(x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text")
    if not isinstance(c, str) or not c.strip():
        return None
    if c.startswith("<local-command") or c.startswith("<command-name>") or c.startswith("Caveat:"):
        return None
    return c

def load_file(path, since, prices):
    """Return (meta, requests) for one transcript. Requests are deduped by requestId (last record wins:
    streamed messages repeat the same usage block per content chunk)."""
    reqs = {}
    meta = {"path": path, "entrypoint": None, "prompt": "", "tool_text": [], "cwd": "",
            "tool_uses": {}, "tool_results": {}, "first_t": None, "last_t": None}
    try:
        fh = open(path, errors="ignore")
    except OSError:
        return meta, []
    with fh:
        for line in fh:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            meta["entrypoint"] = meta["entrypoint"] or d.get("entrypoint")
            meta["cwd"] = meta["cwd"] or d.get("cwd", "")
            t = d.get("type")
            if t == "user" and not meta["prompt"] and not d.get("isMeta"):
                meta["prompt"] = first_prompt(d) or ""
            if t == "user":
                for c in (d.get("message") or {}).get("content") or []:
                    if isinstance(c, dict) and c.get("type") == "tool_result" and c.get("tool_use_id"):
                        result = c.get("content", "")
                        meta["tool_results"][c["tool_use_id"]] = bool(c.get("is_error")) or bool(
                            re.search(r"(?:exit(?:ed)?(?: with)?(?: code)?\s*[1-9]\d*|command failed)",
                                      str(result), re.I))
            if t != "assistant":
                continue
            m = d.get("message") or {}
            u = m.get("usage")
            if not u or m.get("model") in (None, "<synthetic>") or not d.get("timestamp"):
                continue
            rid = d.get("requestId") or m.get("id")
            tools = []
            for c in m.get("content") or []:
                if isinstance(c, dict) and c.get("type") == "tool_use":
                    inp = c.get("input") or {}
                    name = c.get("name")
                    cmd = inp.get("command", "") if name == "Bash" else ""
                    tools.append((name, cmd))
                    if c.get("id"):
                        meta["tool_uses"][c["id"]] = {"name": name, "command": cmd,
                                                          "t": ts(d["timestamp"])}
                    meta["tool_text"].append(json.dumps(inp)[:2000])
            prev = reqs.get(rid)
            if prev:
                tools = prev["tools"] + tools
            reqs[rid] = {"t": ts(d["timestamp"]), "model": m.get("model"), "u": u, "tools": tools,
                         "sidechain": bool(d.get("isSidechain"))}
    out = []
    for r in sorted(reqs.values(), key=lambda r: r["t"]):
        u = r["u"]
        cc = u.get("cache_creation") or {}
        w5, w1 = cc.get("ephemeral_5m_input_tokens", 0), cc.get("ephemeral_1h_input_tokens", 0)
        if not cc:
            w1 = u.get("cache_creation_input_tokens", 0) or 0
        inp, outp, cr = u.get("input_tokens", 0) or 0, u.get("output_tokens", 0) or 0, u.get("cache_read_input_tokens", 0) or 0
        key, p = model_price(r["model"], prices)
        cost = {"in": 0, "out": 0, "read": 0, "write": 0}
        if p:
            cost = {"in": inp * p[0] / 1e6, "out": outp * p[1] / 1e6, "read": cr * p[2] / 1e6,
                    "write": (w5 * p[3] + w1 * p[4]) / 1e6}
        r.update(model_key=key, priced=bool(p), ctx=inp + cr + w5 + w1, write_tokens=w5 + w1,
                 cost=cost, usd=sum(cost.values()))
        out.append(r)
    if out:
        meta["first_t"], meta["last_t"] = out[0]["t"], out[-1]["t"]
    meta["bash_calls"] = [{**v, "failed": bool(meta["tool_results"].get(k))}
                          for k, v in meta["tool_uses"].items() if v["name"] == "Bash"]
    # mark reloads before filtering by date so the gap before the first in-range request is known
    prev = None
    for i, r in enumerate(out):
        gap = (r["t"] - prev).total_seconds() / 60 if prev else None
        r["gap_min"] = gap
        if i == 0:
            r["reload"] = None
        elif r["write_tokens"] >= RELOAD_TOKENS:
            r["reload"] = "after idle" if gap is not None and gap > CACHE_TTL_MIN else "other"
        else:
            r["reload"] = None
        prev = r["t"]
    out = [r for r in out if r["t"] >= since]
    return meta, out

def brief_key(value):
    """Canonical relative brief path used by prompts, runs and handoffs."""
    value = (value or "").strip().replace("\\", "/")
    m = re.search(r"(?:^|/)(handoffs/briefs/[^/\s]+\.md)$", value)
    return m.group(1) if m else value

def brief_from_prompt(prompt):
    m = BRIEF_RE.search(prompt or "")
    return brief_key("handoffs/briefs/" + m.group(1)) if m else ""

def read_repo_state(root):
    """Return merged/completed brief names and run records for a checkout, if available."""
    merged, handoffs, runs = set(), set(), collections.defaultdict(list)
    if not root:
        return merged, handoffs, runs
    paths = glob.glob(os.path.join(root, "handoffs", "merged", "*.md"))
    paths += glob.glob(os.path.join(root, "handoffs", "*.md"))
    for path in paths:
        try:
            for line in open(path, errors="ignore"):
                if line.startswith("brief:"):
                    key = brief_key(line.split(":", 1)[1])
                    handoffs.add(key)
                    if os.path.basename(os.path.dirname(path)) == "merged":
                        merged.add(key)
                    break
        except OSError:
            pass
    for path in glob.glob(os.path.join(root, "handoffs", ".jarvis", "runs", "*")):
        rec = {}
        try:
            for line in open(path, errors="ignore"):
                if ":" in line:
                    key, value = line.rstrip("\n").split(":", 1)
                    rec[key] = value.strip()
        except OSError:
            continue
        key = brief_key(rec.get("brief"))
        if key:
            rec["run"] = os.path.basename(path)
            runs[key].append(rec)
    for values in runs.values():
        values.sort(key=lambda x: int(x.get("spawned", "0")) if x.get("spawned", "").isdigit() else 0)
    return merged, handoffs, runs

def checkout_root(cwd):
    """Find the nearest parent with handoffs/ without invoking git."""
    path = os.path.abspath(cwd) if cwd else ""
    while path and path != os.path.dirname(path):
        if os.path.isdir(os.path.join(path, "handoffs")):
            return path
        path = os.path.dirname(path)
    return ""

def percentile(values, proportion):
    if not values:
        return None
    values = sorted(values)
    return values[max(0, int((len(values) - 1) * proportion + 0.999999))]

def subscription_reading(path, now):
    try:
        d = json.load(open(path))
        stamp = float(d.get("ts"))
    except (OSError, ValueError, TypeError):
        return None
    return {"five_hour_pct": (d.get("five_hour") or {}).get("used_percentage"),
            "seven_day_pct": (d.get("seven_day") or {}).get("used_percentage"),
            "age_seconds": max(0, int(now.timestamp() - stamp))}

def open_session_ids(transcript_root):
    """Session ids Claude Code currently advertises in its sibling sessions registry."""
    out = set()
    config_dir = os.path.dirname(os.path.abspath(transcript_root))
    for path in glob.glob(os.path.join(config_dir, "sessions", "*.json")):
        try:
            rec = json.load(open(path))
        except (OSError, ValueError):
            continue
        if rec.get("sessionId") and rec.get("status") not in ("closed", "exited"):
            out.add(str(rec["sessionId"]))
    return out

def bash_category(cmd, extra):
    for name, rx in extra + BASH_CATEGORIES:
        if re.search(rx, cmd, re.M):
            return name
    return "bash: other"

def turn_category(r, extra):
    if not r["tools"]:
        return "reply / end of turn"
    name, cmd = r["tools"][0]
    if name == "Bash":
        return bash_category(cmd, extra)
    if name in ("Agent", "Task"):
        return "launch subagent"
    if name and name.startswith("mcp__"):
        return "mcp: " + name.split("__")[1]
    return name or "?"

def parse_kv(items, what):
    out = []
    for s in items or []:
        if "=" not in s:
            sys.exit(f"{what} expects NAME=REGEX, got {s!r}")
        k, v = s.split("=", 1)
        out.append((k, v))
    return out

def fmt_usd(x):
    return f"${x:,.2f}"

def pct(a, b):
    return f"{(a / b * 100 if b else 0):.0f}%"

def fmt_age(seconds):
    minutes = max(0, int(seconds // 60))
    if minutes < 60:
        return f"{minutes}m"
    hours = minutes // 60
    return f"{hours}h{minutes % 60:02d}m"

def table(rows, headers, right=()):
    widths = [max(len(str(h)), *(len(str(r[i])) for r in rows)) if rows else len(str(h)) for i, h in enumerate(headers)]
    def line(vals):
        return "  ".join(str(v).rjust(widths[i]) if i in right else str(v).ljust(widths[i]) for i, v in enumerate(vals))
    print("  " + line(headers))
    print("  " + "  ".join("-" * w for w in widths))
    for r in rows:
        print("  " + line(r))

FAIL_RE = re.compile(r"(?:exit(?:ed)?(?: with)?(?: code)?\s*[1-9]\d*|command failed)", re.I)
BUDGET_KEEP_RIDS = 64   # a streamed request's records are adjacent; this many recent ones are plenty

def budget_read(path, st, prices, test_re):
    """Add what was appended to one transcript since st["off"] to its running totals. Only
    whole lines are taken; a request seen again replaces its earlier price (last record
    wins, as in load_file), and a test call whose result hasn't arrived yet is kept."""
    try:
        size = os.path.getsize(path)
    except OSError:
        return st
    if size < st.get("off", 0):   # rewritten: start that file over
        st = {}
    st.setdefault("off", 0); st.setdefault("usd", 0.0); st.setdefault("fails", 0)
    st.setdefault("rids", []); st.setdefault("tests", [])
    with open(path, "rb") as fh:
        fh.seek(st["off"])
        data = fh.read(size - st["off"])
    end = data.rfind(b"\n") + 1
    st["off"] += end
    rids = collections.OrderedDict((r, u) for r, u in st["rids"])
    tests = set(st["tests"])
    main_thread = os.sep + "subagents" + os.sep not in path
    for line in data[:end].decode("utf-8", "ignore").splitlines():
        try:
            d = json.loads(line)
        except ValueError:
            continue
        t = d.get("type")
        if t == "user" and main_thread:
            for c in (d.get("message") or {}).get("content") or []:
                if isinstance(c, dict) and c.get("type") == "tool_result" and c.get("tool_use_id") in tests:
                    tests.discard(c["tool_use_id"])
                    if c.get("is_error") or FAIL_RE.search(str(c.get("content", ""))):
                        st["fails"] += 1
        if t != "assistant":
            continue
        m = d.get("message") or {}
        u = m.get("usage")
        if not u or m.get("model") in (None, "<synthetic>") or not d.get("timestamp"):
            continue
        for c in m.get("content") or []:
            if (main_thread and isinstance(c, dict) and c.get("type") == "tool_use" and c.get("name") == "Bash"
                    and c.get("id") and test_re.search((c.get("input") or {}).get("command", ""))):
                tests.add(c["id"])
        cc = u.get("cache_creation") or {}
        w5, w1 = cc.get("ephemeral_5m_input_tokens", 0), cc.get("ephemeral_1h_input_tokens", 0)
        if not cc:
            w1 = u.get("cache_creation_input_tokens", 0) or 0
        inp, outp, cr = u.get("input_tokens", 0) or 0, u.get("output_tokens", 0) or 0, u.get("cache_read_input_tokens", 0) or 0
        _, p = model_price(m.get("model"), prices)
        usd = (inp * p[0] + outp * p[1] + cr * p[2] + w5 * p[3] + w1 * p[4]) / 1e6 if p else 0.0
        rid = d.get("requestId") or m.get("id")
        st["usd"] += usd - rids.pop(rid, 0.0)
        rids[rid] = usd
        while len(rids) > BUDGET_KEEP_RIDS:
            rids.popitem(last=False)
        if main_thread and not d.get("isSidechain"):
            st["ctx"], st["ctx_t"] = inp + cr + w5 + w1, d["timestamp"]
    st["rids"], st["tests"] = list(rids.items()), sorted(tests)
    return st

def budget_main(argv):
    """jarvis's budget meter: cc_usage_audit.py --budget STATE TRANSCRIPT... prints
    "<usd> <context of the newest main-thread turn> <failed test runs>" over the given
    transcripts (a worker's sessions and their subagents), reading only what each gained
    since the last call. STATE (JSON) keeps each file's byte offset and running totals."""
    ap = argparse.ArgumentParser(prog="cc_usage_audit.py --budget", description=budget_main.__doc__)
    ap.add_argument("state")
    ap.add_argument("files", nargs="*")
    ap.add_argument("--prices", help="JSON file of {model_prefix: [in, out, cache_read, write_5m, write_1h]} to merge in")
    ap.add_argument("--test-regex", default=DEFAULT_TEST_RE)
    a = ap.parse_args(argv)
    prices = dict(PRICES)
    if a.prices:
        prices.update({k: tuple(v) for k, v in json.load(open(a.prices)).items()})
    test_re = re.compile(a.test_regex, re.I)
    try:
        state = json.load(open(a.state))
    except (OSError, ValueError):
        state = {}
    files = state.get("files", {})
    for f in a.files:
        files[f] = budget_read(f, files.get(f, {}), prices, test_re)
    usd = sum(s.get("usd", 0) for s in files.values())
    fails = sum(s.get("fails", 0) for s in files.values())
    newest = max((s for s in files.values() if s.get("ctx_t")), key=lambda s: s["ctx_t"], default={})
    tmp = a.state + ".tmp.%d" % os.getpid()
    with open(tmp, "w") as fh:
        json.dump({"files": files}, fh)
    os.replace(tmp, a.state)
    print(f"{usd:.4f} {newest.get('ctx', 0)} {fails}")

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=os.path.expanduser("~/.claude/projects"), help="transcript root (default ~/.claude/projects)")
    ap.add_argument("--days", type=float, default=7, help="look back this many days (default 7)")
    ap.add_argument("--since", help="ISO date/time to start from; overrides --days")
    ap.add_argument("--until", help="ISO date/time to stop at")
    ap.add_argument("--project", action="append", help="only projects whose folder name contains this (repeatable)")
    ap.add_argument("--all-projects", action="store_true", help="include every project under the transcript root")
    ap.add_argument("--repo-root", help="checkout containing handoffs/ (for run and merge outcomes)")
    ap.add_argument("--usage-file", help="latest statusline rate-limit reading (kept separate from estimates)")
    ap.add_argument("--role", action="append", metavar="NAME=REGEX",
                    help="label sessions whose first prompt matches REGEX (repeatable, first match wins)")
    ap.add_argument("--role-tool", action="append", metavar="NAME=REGEX",
                    help="label sessions where any tool call input matches REGEX, e.g. orchestrator='agents create'")
    ap.add_argument("--bash-category", action="append", metavar="NAME=REGEX",
                    help="extra category for Bash turns, checked before the built-in ones")
    ap.add_argument("--prices", help="JSON file of {model_prefix: [in, out, cache_read, write_5m, write_1h]} to merge in")
    ap.add_argument("--redact", action="store_true", help="hide project names and prompt text (for screenshots)")
    ap.add_argument("--top", type=int, default=10, help="rows in top-N tables (default 10)")
    ap.add_argument("--test-regex", default=DEFAULT_TEST_RE,
                    help="regex identifying test commands whose failed results are counted")
    ap.add_argument("--json", action="store_true", help="print the aggregates as JSON instead of text")
    a = ap.parse_args()

    prices = dict(PRICES)
    if a.prices:
        prices.update({k: tuple(v) for k, v in json.load(open(a.prices)).items()})
    now = dt.datetime.now(dt.timezone.utc)
    since = ts(a.since) if a.since else now - dt.timedelta(days=a.days)
    if since.tzinfo is None:
        since = since.replace(tzinfo=dt.timezone.utc)
    until = ts(a.until) if a.until else now
    if until.tzinfo is None:
        until = until.replace(tzinfo=dt.timezone.utc)
    roles = parse_kv(a.role, "--role")
    role_tools = parse_kv(a.role_tool, "--role-tool")
    bash_extra = parse_kv(a.bash_category, "--bash-category")
    try:
        test_re = re.compile(a.test_regex, re.I)
    except re.error as e:
        sys.exit(f"--test-regex is invalid: {e}")

    if not os.path.isdir(a.root):
        sys.exit(f"No transcripts at {a.root}")

    sessions, reqs = [], []
    cutoff = since.timestamp() - 3600
    proj_alias = {}
    for proj in sorted(os.listdir(a.root)):
        pdir = os.path.join(a.root, proj)
        if not os.path.isdir(pdir) or (a.project and not a.all_projects and
                                      not any(p.lower() in proj.lower() for p in a.project)):
            continue
        pname = proj_alias.setdefault(proj, f"project-{len(proj_alias) + 1}") if a.redact else re.sub(r"^-Users-[^-]+-?", "", proj) or proj
        for f in glob.glob(os.path.join(pdir, "*.jsonl")):
            if os.path.getmtime(f) < cutoff:
                continue
            sid = os.path.basename(f)[:-6]
            meta, rs = load_file(f, since, prices)
            rs = [r for r in rs if r["t"] <= until]
            subs = []
            for sf in glob.glob(os.path.join(pdir, sid, "subagents", "*.jsonl")):
                agent_type = "?"
                try:
                    agent_type = json.load(open(sf[:-6] + ".meta.json")).get("agentType", "?")
                except (OSError, ValueError):
                    pass
                _, srs = load_file(sf, since, prices)
                for r in srs:
                    if r["t"] <= until:
                        r["agent_type"] = agent_type
                        r["agent_id"] = os.path.basename(sf)[:-6]
                        subs.append(r)
            if not rs and not subs:
                continue
            ep = meta["entrypoint"] or "?"
            headless = ep.startswith("sdk")
            role = None
            for name, rx in roles:
                if re.search(rx, meta["prompt"]):
                    role = name
                    break
            if role is None:
                for name, rx in role_tools:
                    if any(re.search(rx, t) for t in meta["tool_text"]):
                        role = name
                        break
            if role is None:
                role = "headless (sdk / -p / hooks)" if headless else "interactive"
            s = {"id": sid, "project": pname, "entrypoint": ep, "role": role,
                 "prompt": "" if a.redact else re.sub(r"\s+", " ", meta["prompt"])[:80],
                 "raw_prompt": re.sub(r"\s+", " ", meta["prompt"]), "cwd": meta["cwd"],
                 "brief": brief_from_prompt(meta["prompt"]), "first_t": meta["first_t"],
                 "last_t": meta["last_t"],
                 "failed_tests": sum(1 for c in meta["bash_calls"]
                                     if c["t"] >= since and c["t"] <= until and c["failed"] and
                                     test_re.search(c["command"]))}
            for r in rs:
                r["session"] = s
                r["kind"] = "subagent" if r["sidechain"] else "main"
                r["agent_type"] = "(inline)" if r["sidechain"] else None
                r["agent_id"] = "(inline)" if r["sidechain"] else ""
            for r in subs:
                r["session"] = s
                r["kind"] = "subagent"
            s["reqs"] = rs + subs
            sessions.append(s)
            reqs.extend(s["reqs"])

    if not reqs:
        sys.exit("No requests in that period.")
    reqs.sort(key=lambda r: r["t"])
    total = sum(r["usd"] for r in reqs)
    unpriced = collections.Counter(r["model"] for r in reqs if not r["priced"])
    R = {}

    # 1. by model and cost component
    bymodel = collections.defaultdict(lambda: collections.Counter())
    comp = collections.Counter()
    for r in reqs:
        b = bymodel[r["model_key"]]
        b["usd"] += r["usd"]; b["turns"] += 1
        for k, v in r["cost"].items():
            comp[k] += v
    long_usd = sum(r["usd"] for r in reqs if r["ctx"] > LONG_CTX)
    R["total_usd"] = total
    R["by_model"] = {k: dict(v) for k, v in bymodel.items()}
    R["components"] = dict(comp)
    R["long_context_share"] = long_usd / total if total else 0

    # 2. by role / kind
    byrole = collections.defaultdict(lambda: collections.Counter())
    for r in reqs:
        key = r["session"]["role"] + (" > subagents" if r["kind"] == "subagent" else "")
        b = byrole[key]
        b["usd"] += r["usd"]; b["turns"] += 1; b["ctx"] += r["ctx"]
        b["sessions_" + r["session"]["id"]] = 1
        for k, v in r["cost"].items():
            b[k] += v
    brm = collections.defaultdict(lambda: collections.Counter())
    for r in reqs:
        if r["kind"] == "main":
            b = brm[(r["session"]["role"], r["model_key"])]
            b["usd"] += r["usd"]; b["turns"] += 1; b["ctx"] += r["ctx"]
    R["by_role_model"] = [{"role": k[0], "model": k[1], **v} for k, v in brm.items()]
    R["by_role"] = {k: {"usd": v["usd"], "turns": v["turns"], "sessions": sum(1 for x in v if x.startswith("sessions_")),
                        "avg_ctx": v["ctx"] / v["turns"], "write_share": v["write"] / v["usd"] if v["usd"] else 0,
                        "read_share": v["read"] / v["usd"] if v["usd"] else 0,
                        "out_share": v["out"] / v["usd"] if v["usd"] else 0} for k, v in byrole.items()}

    # 3. cache reloads
    rel = collections.defaultdict(lambda: [0, 0.0])
    for r in reqs:
        if r["reload"]:
            key = (r["session"]["role"] + (" > subagents" if r["kind"] == "subagent" else ""), r["reload"])
            rel[key][0] += 1
            rel[key][1] += r["usd"]
    R["reloads"] = [{"role": k[0], "cause": k[1], "turns": v[0], "usd": v[1]} for k, v in rel.items()]

    # 4. subagents
    sa = collections.defaultdict(lambda: collections.Counter())
    for r in reqs:
        if r["kind"] == "subagent":
            b = sa[(r["agent_type"], r["model_key"])]
            b["usd"] += r["usd"]; b["turns"] += 1
    R["subagents"] = [{"agent": k[0], "model": k[1], **v} for k, v in sa.items()]

    # 5. headless sessions grouped by prompt start (finds hooks and scripts calling claude)
    hl = collections.defaultdict(lambda: collections.Counter())
    for s in sessions:
        if s["entrypoint"].startswith("sdk"):
            key = (s["entrypoint"], s["raw_prompt"][:48])
            hl[key]["runs"] += 1
            hl[key]["usd"] += sum(r["usd"] for r in s["reqs"])
            hl[key]["turns"] += len(s["reqs"])
    R["headless"] = [{"entrypoint": k[0], "prompt_start": f"(prompt {i + 1})" if a.redact else k[1], **v}
                     for i, (k, v) in enumerate(sorted(hl.items(), key=lambda kv: -kv[1]["usd"]))]

    # 6. what turns were doing (main-session turns only)
    tc = collections.defaultdict(lambda: collections.Counter())
    for r in reqs:
        if r["kind"] == "main":
            b = tc[(r["session"]["role"], turn_category(r, bash_extra))]
            b["usd"] += r["usd"]; b["turns"] += 1
    R["turns"] = [{"role": k[0], "doing": k[1], **v} for k, v in tc.items()]

    # 7. burn rate: worst rolling 5-hour window, concurrency
    best, j, run, best_span = 0.0, 0, 0.0, None
    for i, r in enumerate(reqs):
        run += r["usd"]
        while reqs[j]["t"] < r["t"] - dt.timedelta(hours=WINDOW_H):
            run -= reqs[j]["usd"]; j += 1
        if run > best:
            best, best_span = run, (reqs[j]["t"], r["t"])
    buckets = collections.defaultdict(set)
    for r in reqs:
        buckets[r["t"].replace(minute=r["t"].minute // 10 * 10, second=0, microsecond=0)].add(
            r["session"]["id"] + (r.get("agent_id") or ""))
    peak_conc = max(len(v) for v in buckets.values())
    R["peak_window_usd"] = best
    R["peak_window"] = [best_span[0].isoformat(), best_span[1].isoformat()] if best_span else None
    R["peak_concurrent_sessions_10min"] = peak_conc
    if a.all_projects:
        R["machine_peak_concurrent_sessions_10min"] = peak_conc

    # 8. Jarvis worker attempts joined to run records and merged handoffs.
    state_cache = {}
    worker_rows = []
    redacted_briefs = {}
    for s in sessions:
        if not WORKER_PROMPT_RE.search(s["raw_prompt"]):
            continue
        main_reqs = sorted((r for r in s["reqs"] if r["kind"] == "main"), key=lambda r: r["t"])
        if not main_reqs:
            continue
        root = checkout_root(s["cwd"]) if a.all_projects else (a.repo_root or checkout_root(s["cwd"]))
        root = os.path.abspath(root) if root else ""
        if root not in state_cache:
            state_cache[root] = read_repo_state(root)
        merged, handoffs, runs = state_cache[root]
        brief = s["brief"]
        records = runs.get(brief, [])
        state = records[-1].get("state", "") if records else ""
        outcome = "merged" if brief in merged else (state or "unmerged")
        label = os.path.basename(brief)[:-3] if brief else "unknown-brief"
        if a.redact:
            key = (s["project"], brief)
            label = redacted_briefs.setdefault(key, f"brief-{len(redacted_briefs) + 1}")
        session_usd = sum(r["usd"] for r in s["reqs"])
        first, last = min(r["t"] for r in s["reqs"]), max(r["t"] for r in s["reqs"])
        worker_rows.append({"project": s["project"], "session": s["id"][:8], "brief": label,
                            "brief_path": "" if a.redact else brief,
                            "model": main_reqs[0]["model_key"], "turns": len(main_reqs),
                            "usd": session_usd, "start_ctx": main_reqs[0]["ctx"],
                            "peak_ctx": max(r["ctx"] for r in main_reqs),
                            "turns_above_150k": sum(1 for r in main_reqs if r["ctx"] > LONG_CTX),
                            "usd_above_150k": sum(r["usd"] for r in s["reqs"] if r["ctx"] > LONG_CTX),
                            "wall_seconds": max(0, int((last - first).total_seconds())),
                            "start": first.isoformat(), "end": last.isoformat(),
                            "outcome": outcome, "run_state": state or None,
                            "failed_test_runs": s["failed_tests"],
                            "abandoned": brief not in merged and
                                         (state in ("closed", "lost") or (not records and brief not in handoffs))})

    grouped = collections.defaultdict(list)
    for row in worker_rows:
        grouped[(row["project"], row["brief"])].append(row)
    brief_rows = []
    repeated_extra = 0.0
    for (project, brief), rows in grouped.items():
        rows.sort(key=lambda x: x["start"])
        repeated_extra += sum(x["usd"] for x in rows[1:])
        outcomes = [x["outcome"] for x in rows]
        outcome = "merged" if "merged" in outcomes else outcomes[-1]
        brief_rows.append({"project": project, "brief": brief, "sessions": len(rows),
                           "usd": sum(x["usd"] for x in rows), "outcome": outcome})
    brief_rows.sort(key=lambda x: -x["usd"])
    worker_total = sum(x["usd"] for x in worker_rows)
    worker_long = sum(x["usd_above_150k"] for x in worker_rows)
    peaks = [x["peak_ctx"] for x in worker_rows]
    R["workers"] = sorted(worker_rows, key=lambda x: -x["usd"])
    R["briefs"] = brief_rows
    R["top_briefs"] = brief_rows[:a.top]
    R["abandoned"] = {"sessions": sum(1 for x in worker_rows if x["abandoned"]),
                       "usd": sum(x["usd"] for x in worker_rows if x["abandoned"])}
    R["repeated_attempts"] = {"briefs": sum(1 for x in brief_rows if x["sessions"] > 1),
                              "extra_sessions": sum(max(0, x["sessions"] - 1) for x in brief_rows),
                              "extra_usd": repeated_extra}
    R["failed_test_runs"] = [{"brief": x["brief"], "session": x["session"],
                               "count": x["failed_test_runs"]}
                              for x in worker_rows if x["failed_test_runs"] >= 3]
    R["context_growth"] = {"worker_usd_above_150k_share": worker_long / worker_total if worker_total else 0,
                           "peak_ctx_p50": percentile(peaks, .50), "peak_ctx_p90": percentile(peaks, .90)}

    stale = []
    open_ids = open_session_ids(a.root)
    for s in sessions:
        if s["id"] not in open_ids or not s["first_t"] or not s["last_t"]:
            continue
        age = (now - s["first_t"]).total_seconds()
        idle = (now - s["last_t"]).total_seconds()
        if age > 8 * 3600 and idle > 3600:
            name = os.path.basename(s["brief"])[:-3] if s["brief"] else (s["prompt"] or s["id"][:8])
            if a.redact:
                name = f"session-{len(stale) + 1}"
            stale.append({"name": name, "role": s["role"], "age_seconds": int(age),
                          "idle_seconds": int(idle)})
    R["stale_open_sessions"] = stale
    R["subscription_usage"] = subscription_reading(a.usage_file, now) if a.usage_file else None

    # 9. startup weight
    starts = [s["reqs"][0]["ctx"] for s in sessions if s["reqs"] and s["reqs"][0]["kind"] == "main" and s["entrypoint"] == "cli"]
    R["median_startup_ctx"] = statistics.median(starts) if starts else None

    # 10. top sessions
    top = sorted(sessions, key=lambda s: -sum(r["usd"] for r in s["reqs"]))[: a.top]
    R["top_sessions"] = [{"project": s["project"], "session": s["id"][:8], "role": s["role"],
                          "usd": sum(r["usd"] for r in s["reqs"]), "turns": len(s["reqs"]),
                          "max_ctx": max(r["ctx"] for r in s["reqs"]), "prompt": s["prompt"]} for s in top]
    R["unpriced_models"] = dict(unpriced)
    R["period"] = [since.isoformat(), until.isoformat()]

    if a.json:
        print(json.dumps(R, indent=2, default=str))
        return
    report(R, reqs, sessions, a)

def report(R, reqs, sessions, a):
    total = R["total_usd"]
    loc = lambda s: ts(s).astimezone().strftime("%a %d %b %H:%M")
    print(f"\ncc-usage-audit  ·  {loc(R['period'][0])} → {loc(R['period'][1])}")
    print(f"API-equivalent estimate at list prices (not your subscription usage): "
          f"{len(sessions)} sessions, {len(reqs):,} requests, {fmt_usd(total)}")
    sub = R["subscription_usage"]
    if sub:
        five = "?" if sub["five_hour_pct"] is None else f"{sub['five_hour_pct']:g}%"
        seven = "?" if sub["seven_day_pct"] is None else f"{sub['seven_day_pct']:g}%"
        print(f"Subscription usage: 5h {five} · 7d {seven} · reading {fmt_age(sub['age_seconds'])} old\n")
    else:
        print("Subscription usage: no reading — check /usage\n")

    print("WHERE IT GOES")
    c = R["components"]
    print(f"  output (incl. thinking) {pct(c.get('out', 0), total):>4}   cache writes {pct(c.get('write', 0), total):>4}   "
          f"cache reads {pct(c.get('read', 0), total):>4}   uncached input {pct(c.get('in', 0), total):>4}")
    print(f"  spent at >{LONG_CTX // 1000}k context: {R['long_context_share']:.0%}\n")
    rows = sorted(R["by_model"].items(), key=lambda kv: -kv[1]["usd"])
    table([(k, fmt_usd(v["usd"]), pct(v["usd"], total), f"{v['turns']:,}", f"${v['usd'] / v['turns']:.3f}") for k, v in rows],
          ("model", "cost", "share", "turns", "$/turn"), right=(1, 2, 3, 4))

    print("\nBY SESSION TYPE")
    rows = sorted(R["by_role"].items(), key=lambda kv: -kv[1]["usd"])
    table([(k, v["sessions"], fmt_usd(v["usd"]), pct(v["usd"], total), f"${v['usd'] / v['turns']:.3f}",
            f"{v['avg_ctx'] / 1000:.0f}k", f"{v['write_share']:.0%}", f"{v['read_share']:.0%}", f"{v['out_share']:.0%}")
           for k, v in rows],
          ("type", "sessions", "cost", "share", "$/turn", "avg ctx", "writes", "reads", "output"), right=tuple(range(1, 9)))

    print("\nWORKERS / BRIEFS")
    if R["workers"]:
        table([(x["brief"], x["model"], x["turns"], fmt_usd(x["usd"]),
                f"{x['start_ctx'] / 1000:.0f}k→{x['peak_ctx'] / 1000:.0f}k", fmt_age(x["wall_seconds"]), x["outcome"])
               for x in R["workers"][:a.top]],
              ("brief", "model", "turns", "cost", "context", "wall", "outcome"), right=(2, 3, 4, 5))
        print("  most expensive briefs:")
        table([(x["brief"], x["sessions"], fmt_usd(x["usd"]), x["outcome"]) for x in R["top_briefs"]],
              ("brief", "attempts", "cost", "outcome"), right=(1, 2))
    else:
        print("  none")

    abandoned, repeated, growth = R["abandoned"], R["repeated_attempts"], R["context_growth"]
    print("\nWASTE SIGNALS")
    print(f"  abandoned worker sessions: {abandoned['sessions']} · {fmt_usd(abandoned['usd'])}")
    print(f"  repeated attempts: {repeated['briefs']} briefs · {repeated['extra_sessions']} extra sessions · "
          f"{fmt_usd(repeated['extra_usd'])} extra")
    if R["failed_test_runs"]:
        print("  workers with 3+ failed test runs: " + ", ".join(
            f"{x['brief']} ({x['count']})" for x in R["failed_test_runs"]))
    else:
        print("  workers with 3+ failed test runs: none")
    p50 = growth["peak_ctx_p50"] or 0
    p90 = growth["peak_ctx_p90"] or 0
    print(f"  worker cost above {LONG_CTX // 1000}k context: {growth['worker_usd_above_150k_share']:.0%} · "
          f"peak context p50 {p50 / 1000:.0f}k · p90 {p90 / 1000:.0f}k")
    if R["stale_open_sessions"]:
        print("  stale open sessions (>8h, idle >1h): " + ", ".join(x["name"] for x in R["stale_open_sessions"]))
    else:
        print("  stale open sessions (>8h, idle >1h): none")

    print("\nCACHE RELOADS  (a mid-session cache write of 40k+ tokens: the whole context written again)")
    if R["reloads"]:
        rows = sorted(R["reloads"], key=lambda x: -x["usd"])
        table([(x["role"], x["cause"], x["turns"], fmt_usd(x["usd"]), pct(x["usd"], total)) for x in rows],
              ("type", "cause", "turns", "cost", "of total"), right=(2, 3, 4))
        print(f"  'after idle' = more than {CACHE_TTL_MIN} min since the previous turn, so the cache had expired.")
        print("  'other' = compaction, a /model switch, or anything else that changed the cached prefix.")
    else:
        print("  none")

    print("\nSUBAGENTS")
    if R["subagents"]:
        rows = sorted(R["subagents"], key=lambda x: -x["usd"])[: a.top]
        table([(x["agent"], x["model"], x["turns"], fmt_usd(x["usd"]), pct(x["usd"], total)) for x in rows],
              ("agent", "model", "turns", "cost", "share"), right=(2, 3, 4))
    else:
        print("  none")

    print("\nHEADLESS SESSIONS  (Agent SDK, claude -p, plugin hooks; grouped by how the prompt starts)")
    if R["headless"]:
        rows = sorted(R["headless"], key=lambda x: -x["usd"])[: a.top]
        table([(x["entrypoint"], x["prompt_start"], x["runs"], fmt_usd(x["usd"]), pct(x["usd"], total)) for x in rows],
              ("entry", "prompt starts with", "runs", "cost", "share"), right=(2, 3, 4))
    else:
        print("  none")

    print("\nWHAT MAIN-SESSION TURNS WERE DOING  (cost of the turn that made the call)")
    roles = sorted({x["role"] for x in R["turns"]}, key=lambda k: -sum(y["usd"] for y in R["turns"] if y["role"] == k))
    for role in roles[:4]:
        rows = sorted([x for x in R["turns"] if x["role"] == role], key=lambda x: -x["usd"])
        sub = sum(x["usd"] for x in rows)
        print(f"  [{role}]  {fmt_usd(sub)}")
        table([(x["doing"], x["turns"], fmt_usd(x["usd"]), pct(x["usd"], sub), f"${x['usd'] / x['turns']:.3f}") for x in rows[:8]],
              ("doing", "turns", "cost", "share", "$/turn"), right=(1, 2, 3, 4))

    print("\nBURN RATE")
    if R["peak_window"]:
        print(f"  worst {WINDOW_H}-hour window: {fmt_usd(R['peak_window_usd'])} ({loc(R['peak_window'][0])} → {loc(R['peak_window'][1])})")
    print(f"  most sessions active in one 10-minute slot: {R['peak_concurrent_sessions_10min']}")
    if R.get("machine_peak_concurrent_sessions_10min") is not None:
        print(f"  machine-wide peak across all projects: {R['machine_peak_concurrent_sessions_10min']}")
    if R["median_startup_ctx"]:
        print(f"  median context before the first reply (system prompt, tools, skills, CLAUDE.md): {R['median_startup_ctx'] / 1000:.0f}k tokens")

    print("\nTOP SESSIONS")
    table([(x["project"][:28], x["session"], x["role"][:20], fmt_usd(x["usd"]), x["turns"], f"{x['max_ctx'] / 1000:.0f}k", x["prompt"][:40])
           for x in R["top_sessions"]],
          ("project", "session", "type", "cost", "turns", "max ctx", "first prompt"), right=(3, 4, 5))

    if R["unpriced_models"]:
        print(f"\nNot priced (add them with --prices): {dict(R['unpriced_models'])}")
    print()

if __name__ == "__main__":
    if sys.argv[1:2] == ["--budget"]:
        budget_main(sys.argv[2:])
    else:
        main()
