#!/usr/bin/env python3
"""Score a jarvis-model eval run.

    python3 eval/jarvis-model/score.py <results-dir> [--detail]

Reads the raw `claude -p --output-format json` records run.sh wrote, pulls the
JSON answer out of each, grades it against eval/labels.json (routing) and
review/*/expected.json (review), and prints one Markdown table per config.
Python 3.8+, stdlib only.
"""
import glob, json, os, re, statistics, sys

HERE = os.path.dirname(os.path.abspath(__file__))
LABELS = os.path.join(HERE, "..", "labels.json")
RANK = {"trivial": 0, "light": 1, "workhorse": 2, "top": 3}
BLOCKING = {"file_list_incomplete", "unlisted_shared_edit", "scope_violation", "bug",
            "checks_missing", "git_violation", "secret"}


def answer(rec):
    """The candidate's JSON answer, or None when it didn't give parseable JSON."""
    text = rec.get("result") or ""
    text = re.sub(r"^```(?:json)?\s*|\s*```$", "", text.strip())
    try:
        return json.loads(text)
    except ValueError:
        m = re.search(r"\{.*\}", text, re.S)
        if m:
            try:
                return json.loads(m.group(0))
            except ValueError:
                pass
    return None


def expected_route(lab):
    """(acceptable agents, codex model or None) the routing guide requires."""
    if lab.get("media") or lab.get("computer_use"):
        return {"codex"}, "gpt-6-astra"
    if lab.get("security"):
        return {"codex"}, "gpt-5.6-sol"
    if lab["tier"] == "top":
        return {"codex"}, "gpt-6-astra"  # since 0.7.0 top tier is astra unless Fable is allowed
    ok = {"claude"}
    if lab["tier"] in ("light", "trivial") and not lab.get("touches_secrets"):
        ok.add("opencode")
    return ok, None


def grade_routing(ans, lab):
    g = {"parsed": ans is not None, "tier_ok": False, "delta": None, "agent_ok": False}
    if not ans:
        return g
    tier = str(ans.get("tier", "")).lower()
    ok_tiers = [lab["tier"]] + lab.get("accept", [])
    g["tier_ok"] = tier in ok_tiers
    if tier in RANK and not g["tier_ok"]:
        g["delta"] = RANK[tier] - RANK[lab["tier"]]
    agents, codex_model = expected_route(lab)
    agent = str(ans.get("agent", "")).lower()
    g["agent_ok"] = agent in agents and (codex_model is None or str(ans.get("model", "")) == codex_model)
    g["got"] = f"{tier}/{agent}/{ans.get('model')}/{ans.get('effort')}"
    return g


def norm(path):
    return (path or "").strip().strip("`").lstrip("./")


def grade_review(ans, exp):
    g = {"parsed": ans is not None, "verdict_ok": False, "found": 0, "defects": len(exp["defects"]),
         "false_alarms": 0}
    if not ans:
        return g
    verdict = str(ans.get("verdict", "")).lower()
    g["verdict_ok"] = verdict in exp.get("accept_verdicts", [exp["verdict"]])
    findings = [f for f in ans.get("findings") or [] if isinstance(f, dict)]
    blocking = [f for f in findings if str(f.get("kind", "")).lower() in BLOCKING]
    for d in exp["defects"]:
        for f in blocking:
            kind_ok = str(f.get("kind", "")).lower() == d["kind"]
            file_ok = d["file"] is None or norm(f.get("file")) == d["file"]
            if kind_ok and file_ok:
                g["found"] += 1
                break
    if not exp["defects"]:
        g["false_alarms"] = len(blocking)
    g["got"] = f"{verdict} · " + ", ".join(f"{f.get('kind')}:{norm(f.get('file')) or '-'}" for f in findings)
    return g


def tokens(rec):
    u = rec.get("usage") or {}
    return sum(u.get(k, 0) or 0 for k in ("input_tokens", "cache_creation_input_tokens",
                                           "cache_read_input_tokens", "output_tokens"))


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    detail = "--detail" in sys.argv
    if not args:
        sys.exit(__doc__)
    root = args[0]
    labels = json.load(open(LABELS))["briefs"]
    by_config = {}
    for path in sorted(glob.glob(os.path.join(root, "*", "*", "*.json"))):
        rec = json.load(open(path))
        ev = rec.get("eval")
        if not ev:
            continue
        ans = answer(rec)
        if ev["task"] == "routing":
            g = grade_routing(ans, labels[ev["fixture"] + ".md"])
        else:
            g = grade_review(ans, json.load(open(os.path.join(HERE, "review", ev["fixture"], "expected.json"))))
        g.update(fixture=ev["fixture"], rep=ev["rep"], cost=rec.get("total_cost_usd") or 0.0,
                 tokens=tokens(rec), output=(rec.get("usage") or {}).get("output_tokens", 0),
                 seconds=(rec.get("duration_ms") or 0) / 1000, error=rec.get("is_error"))
        c = by_config.setdefault(ev["config"], {"model": ev["model"], "effort": ev["effort"],
                                                "routing": [], "review": []})
        c[ev["task"]].append(g)

    if not by_config:
        sys.exit(f"no results under {root}")

    def pct(n, d):
        return f"{100 * n / d:.0f}% ({n}/{d})" if d else "n/a"

    def mean(xs):
        return statistics.mean(xs) if xs else 0.0

    rows = []
    for name, c in sorted(by_config.items()):
        ro, rv = c["routing"], c["review"]
        allg = ro + rv
        correct = sum(g["tier_ok"] for g in ro) + sum(g["verdict_ok"] for g in rv)
        cost = sum(g["cost"] for g in allg)
        rows.append([
            f"`{name}`", f"{c['model']} / {c['effort']}",
            pct(sum(g["tier_ok"] for g in ro), len(ro)),
            str(sum(1 for g in ro if (g["delta"] or 0) < 0)),
            str(sum(1 for g in ro if (g["delta"] or 0) > 0)),
            pct(sum(g["agent_ok"] for g in ro), len(ro)),
            pct(sum(g["verdict_ok"] for g in rv), len(rv)),
            pct(sum(g["found"] for g in rv), sum(g["defects"] for g in rv)),
            str(sum(g["false_alarms"] for g in rv)),
            str(sum(1 for g in allg if not g["parsed"])),
            f"${mean([g['cost'] for g in allg]):.3f}",
            f"{mean([g['tokens'] for g in allg]) / 1000:.1f}k",
            f"{mean([g['output'] for g in allg]):.0f}",
            f"{mean([g['seconds'] for g in allg]):.0f}s",
            f"${cost / correct:.3f}" if correct else "n/a",
            f"${cost:.2f}",
        ])
    head = ["config", "model / effort", "routing tier ok", "too low", "too high", "agent ok",
            "review verdict ok", "defect recall", "false alarms", "unparsed",
            "$/task", "tokens/task", "output tok/task", "s/task", "$ per correct", "total $"]
    print("| " + " | ".join(head) + " |")
    print("|" + "|".join("---" for _ in head) + "|")
    for r in rows:
        print("| " + " | ".join(r) + " |")
    print("\n\"too low\" is the costly miss (a failed worker and a respawn); \"too high\" only costs tokens.")

    if detail:
        for name, c in sorted(by_config.items()):
            print(f"\n### {name}")
            for g in c["routing"]:
                mark = "ok" if g["tier_ok"] else f"off {g['delta']:+d}" if g["delta"] is not None else "??"
                want = labels[g["fixture"] + ".md"]["tier"]
                print(f"- routing {g['fixture']} r{g['rep']}: {mark} (want {want}; got {g.get('got')}) "
                      f"agent {'ok' if g['agent_ok'] else 'WRONG'} · ${g['cost']:.3f}")
            for g in c["review"]:
                print(f"- review {g['fixture']} r{g['rep']}: verdict {'ok' if g['verdict_ok'] else 'WRONG'}, "
                      f"found {g['found']}/{g['defects']}, false alarms {g['false_alarms']} "
                      f"({g.get('got')}) · ${g['cost']:.3f}")


if __name__ == "__main__":
    main()
