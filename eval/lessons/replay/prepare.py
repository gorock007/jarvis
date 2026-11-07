#!/usr/bin/env python3
"""Freeze the m5 replay: time-filtered history repos, lessons, review packets.

  python3 -I prepare.py --dry-run --work DIR   estimate only: builds the throwaway
                                               repos and runs `propose --dry-run`
                                               (no model call), prints the table
  python3 -I prepare.py --work DIR             generate lessons (paid, Sonnet), freeze
                                               fixtures/, cases.json, results/order.tsv
  python3 -I prepare.py --blind                after run.sh: blind.md, key.json

Read-only git only. Every model call is `jarvis-lessons.py propose`, unchanged.
"""
import argparse
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import random
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
from zoneinfo import ZoneInfo

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
SCRIPT = REPO / "plugins/jarvis/skills/setup/templates/handoffs/bin/jarvis-lessons.py"
BIN = "plugins/jarvis/skills/setup/templates/handoffs/bin"
SYDNEY = ZoneInfo("Australia/Sydney")
REPS = 3
BUDGET = 20.0
REVIEW_MODEL = "claude-opus-5-5"
# Exclusion boundary from the brief: anything from here on lists the targets.
CUTOFF_LOCAL = dt.datetime(2026, 11, 7, 21, 0, tzinfo=SYDNEY)
M2_DESIGN = "2026-11-07-2127-m2-lessons-pass-design.md"
POLICY = ["plugins/jarvis/skills/run/SKILL.md", "plugins/jarvis/skills/run/references/handoffs.md"]

# Chronological. extra = whole files at C, identical in both arms (the brief's two exceptions).
TARGETS = [
    {"id": "ad5b044", "handoff": "2026-11-03-0118-p1b-watch-fast-paths.md"},
    {"id": "351ab83", "handoff": "2026-11-03-0148-p1b-hardening.md"},
    {"id": "c7df456", "handoff": "2026-11-04-2051-p2a1-verify-engine.md"},
    {"id": "3b1ab75", "handoff": "2026-11-04-2134-p2a2-verify-reuse.md"},
    {"id": "5569a05", "handoff": "2026-11-04-2211-p2a3-verify-doctor.md"},
    {"id": "f319d18", "handoff": "2026-11-05-1108-p3a-events-core.md"},
    {"id": "9c72433", "handoff": "2026-11-05-1230-p3c-codex-opencode-events.md"},
    {"id": "c8f8e5d", "handoff": "2026-11-05-1317-p3e-docs.md", "extra": [BIN + "/jarvis"]},
    {"id": "6a3438e", "handoff": "2026-11-06-0100-p4e-watch-window-fix.md"},
    {"id": "1131ecd", "handoff": "2026-11-07-2015-p5f-jarvis-permission-rule.md",
     "extra": [BIN + "/jarvis", BIN + "/lib/lock.sh", BIN + "/lib/defaults.sh", BIN + "/jarvis-lock.pl"]},
]

REVIEW_SCHEMA = {
    "type": "object", "additionalProperties": False, "required": ["verdict", "findings"],
    "properties": {
        "verdict": {"enum": ["commit", "send_back"]},
        "findings": {"type": "array", "items": {
            "type": "object", "additionalProperties": False,
            "required": ["file", "location", "blocking", "mechanism", "evidence"],
            "properties": {"file": {"type": "string"}, "location": {"type": "string"}, "blocking": {"type": "boolean"},
                           "mechanism": {"type": "string"}, "evidence": {"type": "string"}}}}},
}


def git(*args):
    """Read-only git in the shared checkout."""
    assert args[0] in ("log", "show", "diff", "rev-parse", "ls-tree", "status"), args
    out = subprocess.run(["git", "-C", str(REPO)] + list(args), capture_output=True, check=True)
    return out.stdout.decode("utf-8")


def sha(data):
    return hashlib.sha256(data if isinstance(data, bytes) else data.encode()).hexdigest()


def redact(text):
    """Packets are public fixtures: drop session/terminal UUIDs and home paths, nothing else (code must stay code)."""
    text, n1 = re.subn(r"(?i)\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b", "[ID]", text)
    text, n2 = re.subn(r"(?:/Users/|/home/|/root/)[^\s\"'<>`)\]]+", "[HOME]", text)
    return text, n1 + n2


def local_time(date, hhmm):
    return dt.datetime(int(date[:4]), int(date[5:7]), int(date[8:10]), int(hhmm[:2]), int(hhmm[2:]), tzinfo=SYDNEY)


def handoff_time(name):
    m = re.match(r"(\d{4}-\d{2}-\d{2})-(\d{4})-", name)
    if not m:
        raise SystemExit("handoff name without a timestamp: " + name)
    return local_time(m[1], m[2])


def utc(ts):
    return dt.datetime.fromisoformat(ts.replace("Z", "+00:00"))


def bullets(text):
    """Top-level bullets with their indented continuation lines: (first line number, text)."""
    lines = text.splitlines(keepends=True)
    out = []
    for i, row in enumerate(lines):
        if not re.match(r"^[-+*]\s+", row):
            continue
        end = i + 1
        while end < len(lines) and not (lines[end].strip() and not lines[end][0].isspace()):
            end += 1
        out.append((i + 1, "".join(lines[i:end]).rstrip()))
    return out


def bullet_time(block):
    m = re.match(r"^[-+*]\s+(\d{4}-\d{2}-\d{2})(?:[ T](\d{2}):(\d{2}))?", block)
    if not m:
        return None
    if m[2]:
        return local_time(m[1], m[2] + m[3])
    # a date alone could be any hour of that day: only a whole earlier day is provably before
    return local_time(m[1], "2359") + dt.timedelta(seconds=59)


def band_line():
    out = subprocess.run([str(REPO / "handoffs/bin/jarvis"), "band"], capture_output=True, text=True, timeout=30)
    line = out.stdout.strip().splitlines()[0] if out.stdout.strip() else ""
    if out.returncode != 0 or not line or line.split()[0].lower() == "red":
        raise SystemExit("band is red or unreadable: " + (line or out.stderr.strip()[:100]))
    return line


def target_facts(t):
    full = git("rev-parse", t["id"] + "^{commit}").strip()
    parent = git("rev-parse", full + "^").strip()
    ct = int(git("log", "-1", "--format=%ct", full).strip())
    handoff_path = REPO / "handoffs/merged" / t["handoff"]
    htext = handoff_path.read_text(encoding="utf-8")
    brief_rel = re.search(r"(?m)^brief:[ \t]*(\S+)", htext)[1]
    brief_path = REPO / brief_rel
    changed = [p for p in git("diff", "--name-only", parent, full).splitlines() if p]
    return {"id": t["id"], "commit": full, "parent": parent, "ct": ct,
            "ct_iso": dt.datetime.fromtimestamp(ct, dt.timezone.utc).isoformat(),
            "handoff": "handoffs/merged/" + t["handoff"], "brief": brief_rel,
            "brief_exists": brief_path.is_file(), "changed": changed, "extra": t.get("extra", [])}


def build_history(f, work):
    """A throwaway repo holding only what was knowable before the target commit."""
    ct = dt.datetime.fromtimestamp(f["ct"], dt.timezone.utc)
    root = work / "hist" / f["id"]
    if root.exists():
        shutil.rmtree(root)
    for d in ("handoffs/merged", "handoffs/.jev", "handoffs/.jarvis", "handoffs/log", "handoffs/bin"):
        (root / d).mkdir(parents=True)
    counts = {"handoffs": 0, "outcomes": 0, "shadow": 0, "security": 0}
    skipped = {"own_brief_or_handoff": 0, "after_cutoff": 0}
    stem = Path(f["brief"]).stem
    for p in sorted((REPO / "handoffs/merged").glob("*.md")):
        text = p.read_text(encoding="utf-8")
        hb = re.search(r"(?m)^brief:[ \t]*(\S+)", text)
        if p.name == M2_DESIGN or handoff_time(p.name) >= CUTOFF_LOCAL:
            skipped["after_cutoff"] += 1
            continue
        if handoff_time(p.name) >= ct:
            skipped["after_cutoff"] += 1
            continue
        if "handoffs/merged/" + p.name == f["handoff"] or (hb and hb[1] == f["brief"]):
            skipped["own_brief_or_handoff"] += 1
            continue
        for needle in (f["commit"], f["id"], stem):
            if needle in text:
                raise SystemExit("eligible handoff %s mentions target %s (%s)" % (p.name, f["id"], needle))
        shutil.copyfile(p, root / "handoffs/merged" / p.name)
        counts["handoffs"] += 1
    rows = []
    for line in (REPO / "handoffs/.jev/log.jsonl").read_text(encoding="utf-8").splitlines():
        o = json.loads(line)
        if o.get("kind") == "outcome" and utc(o["ts"]) < ct and o["brief"] != f["brief"] and utc(o["ts"]) < CUTOFF_LOCAL:
            rows.append(line)
    (root / "handoffs/.jev/log.jsonl").write_text("".join(r + "\n" for r in rows), encoding="utf-8")
    counts["outcomes"] = len(rows)
    rows = []
    for line in (REPO / "handoffs/.jarvis/shadow-review.log").read_text(encoding="utf-8").splitlines():
        ts, commit, label = line.split("\t", 4)[:3]
        if utc(ts) < ct and not f["commit"].startswith(commit) and label not in (f["brief"], stem, stem.split("-", 3)[-1]) \
                and utc(ts) < CUTOFF_LOCAL:
            if f["id"] in line or f["commit"] in line:
                raise SystemExit("eligible shadow row mentions target " + f["id"])
            rows.append(line)
    (root / "handoffs/.jarvis/shadow-review.log").write_text("".join(r + "\n" for r in rows), encoding="utf-8")
    counts["shadow"] = len(rows)
    kept = []
    for name in ("handoffs/OPEN.md", "handoffs/log/2026-11.md"):
        src = REPO / name
        if not src.is_file():
            continue
        for number, block in bullets(src.read_text(encoding="utf-8")):
            if not re.search(r"security[ -]review|security-guidance", block, re.I):
                continue
            when = bullet_time(block)
            if when is None or when >= ct or when >= CUTOFF_LOCAL or f["id"] in block or f["commit"] in block or stem in block:
                continue
            kept.append(block)
    (root / "handoffs/log/2026-11.md").write_text("\n".join(kept) + ("\n" if kept else ""), encoding="utf-8")
    counts["security"] = len(kept)
    stub = root / "handoffs/bin/jarvis"
    stub.write_text("#!/bin/sh\necho '%s'\n" % band_line().replace("'", ""), encoding="utf-8")
    stub.chmod(0o755)
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    return root, counts, skipped


def lessons_cmd(root, *args, timeout=420, work=None):
    env = {**os.environ, "TMPDIR": str(work)}
    return subprocess.run([sys.executable, "-I", str(SCRIPT)] + list(args), cwd=str(root), capture_output=True,
                          text=True, timeout=timeout, env=env)


def run_records(root):
    d = root / "handoffs/.jarvis/lessons/runs"
    return [json.loads(p.read_text()) for p in sorted(d.glob("*.json"))] if d.is_dir() else []


def review_cost(nbytes, extra=0):
    tokens = math.ceil((nbytes + extra + len(open(HERE / "prompts/reviewer.txt").read())) / 2.2) + 500
    return tokens * 4 / 1e6 + 4000 * 20 / 1e6


def policy_and_files(f):
    parts = []
    for rel in POLICY:
        parts.append("=== HISTORICAL REVIEW POLICY: %s (as at the commit before the change) ===\n%s" % (rel, git("show", f["parent"] + ":" + rel)))
    return parts


def packet(f, lessons_text):
    redactions = 0
    parts = policy_and_files(f)
    parts.append("=== BRIEF the worker was given: %s ===\n%s" % (f["brief"], (REPO / f["brief"]).read_text(encoding="utf-8")))
    parts.append("=== HANDOFF the worker wrote: %s ===\n%s" % (f["handoff"], (REPO / f["handoff"]).read_text(encoding="utf-8")))
    parts.append("=== git diff %s %s ===\n%s" % (f["parent"][:7], f["id"], git("diff", f["parent"], f["commit"])))
    for rel in f["extra"]:
        parts.append("=== WHOLE FILE at %s: %s ===\n%s" % (f["id"], rel, git("show", f["commit"] + ":" + rel)))
    body = "\n\n".join(parts)
    body, redactions = redact(body)
    # one fixed trailer; the baseline arm's lessons field is simply empty
    return body + "\n\n=== LESSONS (optional context, subordinate to policy and code) ===\n" + lessons_text, redactions


def cmd_main(args):
    work = Path(args.work).resolve() if args.work else Path(tempfile.mkdtemp(prefix="lessons-replay-"))
    work.mkdir(parents=True, exist_ok=True)
    assert not str(work).startswith(str(REPO)), "work dir must be outside the checkout"
    facts = [target_facts(t) for t in TARGETS]
    labels = json.loads((HERE / "labels.json").read_text())
    assert [x["id"] for x in labels["fixtures"]] == [t["id"] for t in TARGETS], "labels/targets mismatch"
    for f in facts:
        if not f["brief_exists"]:
            raise SystemExit("brief missing for " + f["id"])
    print("fixture   packet_B  elig(h/o/s/sec)  lessons_bundle_B  lesson$   reviews(6)$")
    total_review = total_lessons = 0.0
    summaries = {}
    for f in facts:
        root, counts, skipped = build_history(f, work)
        proc = lessons_cmd(root, "propose", "--dry-run", work=work)
        if proc.returncode != 0:
            raise SystemExit("propose --dry-run failed for %s: %s" % (f["id"], proc.stderr.strip()[:300]))
        summary = json.loads(proc.stdout)
        base, _ = packet(f, "")
        size = len(base.encode())
        est = review_cost(size) * 3 + review_cost(size, 3072) * 3
        total_review += est
        total_lessons += summary["estimated_cost_usd"]
        summaries[f["id"]] = {"counts": counts, "skipped": skipped, "dry": summary, "packet_bytes": size}
        print("%-8s %8d  %3d/%3d/%3d/%3d  %16d  %7.3f  %9.3f" % (
            f["id"], size, counts["handoffs"], counts["outcomes"], counts["shadow"], counts["security"],
            summary["bundle_bytes"], summary["estimated_cost_usd"], est))
    total = total_review + total_lessons
    print("estimate: 60 Opus reviews $%.2f + 10 Sonnet lesson passes $%.2f = $%.2f (budget $%.2f; uncached, bytes/2.2 tokens, 4000 output tokens)"
          % (total_review, total_lessons, total, BUDGET))
    if args.dry_run:
        print("dry run: nothing frozen, no model call made")
        return 0
    if total > BUDGET:
        print("estimate exceeds the budget: stop, spend nothing", file=sys.stderr)
        return 2
    return freeze(args, work, facts, summaries, labels)


def freeze(args, work, facts, summaries, labels):
    fx = HERE / "fixtures"
    res = HERE / "results"
    res.mkdir(exist_ok=True)
    ledger = res / "ledger.jsonl"
    cases = []
    spent = 0.0
    for f in facts:
        root = Path(work / "hist" / f["id"])
        band = band_line()
        print("lessons %s (band: %s)" % (f["id"], band), flush=True)
        info = {"status": "empty", "reason": None, "attempts": []}
        for attempt in (1, 2):
            proc = lessons_cmd(root, "propose", work=work)
            runs = run_records(root)
            cost = sum(r.get("total_cost_usd") or 0 for r in runs)
            info["attempts"].append({"returncode": proc.returncode, "stderr": proc.stderr.strip()[:300],
                                     "exit_state": runs[-1].get("exit_state") if runs else None})
            if proc.returncode == 0:
                prop = json.loads(proc.stdout.strip().splitlines()[-1])
                ap = lessons_cmd(root, "apply", prop["proposal"], work=work)
                if ap.returncode == 0:
                    info.update(status="applied", proposal=prop["proposal"])
                else:
                    info.update(status="empty", reason="apply failed: " + ap.stderr.strip()[:300])
                break
            transient = runs and not runs[-1].get("raw_result")
            info["reason"] = "propose failed: " + proc.stderr.strip()[:300]
            if not (transient and attempt == 1):
                break
            print("  transient failure, one retry", flush=True)
        cost = sum(r.get("total_cost_usd") or 0 for r in run_records(root))
        spent += cost
        with ledger.open("a") as h:
            h.write(json.dumps({"kind": "lessons", "fixture": f["id"], "cost": cost, "status": info["status"]}) + "\n")
        if spent > BUDGET * 0.2:
            raise SystemExit("lesson passes alone passed 20%% of the budget (%.2f): stop" % spent)
        lessons_file = root / "handoffs/LESSONS.md"
        lessons = lessons_file.read_text(encoding="utf-8") if info["status"] == "applied" and lessons_file.exists() else ""
        # selection staging: the target's changed paths exist as empty placeholders, after generation
        for rel in f["changed"]:
            p = root / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            if not p.exists():
                p.touch()
        paths = work / ("paths-%s.txt" % f["id"])
        paths.write_text("\n".join(f["changed"]) + "\n")
        if lessons:
            sel = lessons_cmd(root, "select", "--audience", "review", "--paths-from", str(paths), work=work)
            if sel.returncode != 0:
                raise SystemExit("select failed for %s: %s" % (f["id"], sel.stderr.strip()[:300]))
            selected, omitted = sel.stdout, sel.stderr.strip()
        else:
            selected, omitted = "", ""
        d = fx / f["id"]
        d.mkdir(parents=True, exist_ok=True)
        base, redactions = packet(f, "")
        treat, _ = packet(f, selected)
        assert treat.startswith(base), "arms must differ only after the lessons marker"
        (d / "packet.baseline.txt").write_text(base, encoding="utf-8")
        (d / "packet.treatment.txt").write_text(treat, encoding="utf-8")
        (d / "LESSONS.md").write_text(lessons, encoding="utf-8")
        (d / "select.txt").write_text(selected, encoding="utf-8")
        (d / "paths.txt").write_text(paths.read_text())
        runs = run_records(root)
        (d / "lessons-run.json").write_text(json.dumps({"info": info, "runs": runs, "select_stderr": omitted,
                                                       "dry_run": summaries[f["id"]]["dry"]}, indent=1) + "\n")
        resp = root / "handoffs/.jarvis/lessons/proposals" / info.get("proposal", "-") / "response.json"
        if resp.is_file():
            shutil.copyfile(resp, d / "proposal-response.json")
        cases.append({
            "id": f["id"], "commit": f["commit"], "parent": f["parent"], "commit_time_utc": f["ct_iso"],
            "handoff": f["handoff"], "brief": f["brief"], "changed_paths": f["changed"], "whole_files": f["extra"],
            "eligible_sources": summaries[f["id"]]["counts"], "excluded": summaries[f["id"]]["skipped"],
            "lessons": {"status": info["status"], "reason": info["reason"], "cost_usd": cost,
                        "sha256": sha(lessons), "selected_sha256": sha(selected), "selected_bytes": len(selected.encode()),
                        "selected_entries": len([x for x in selected.splitlines() if x])},
            "packet": {"baseline_sha256": sha(base), "treatment_sha256": sha(treat),
                       "baseline_bytes": len(base.encode()), "treatment_bytes": len(treat.encode()), "redactions": redactions},
        })
    # run order: chronological fixtures; per rep, odd = baseline first, even = treatment first
    order = []
    for c in cases:
        est = review_cost(c["packet"]["treatment_bytes"])
        cap = max(0.50, round(est * 1.5, 2))
        for rep in range(1, REPS + 1):
            arms = ("baseline", "treatment") if rep % 2 == 1 else ("treatment", "baseline")
            for arm in arms:
                order.append("\t".join([c["id"], str(rep), arm, "fixtures/%s/packet.%s.txt" % (c["id"], arm), "%.2f" % cap, "%.3f" % est]))
    (res / "order.tsv").write_text("\n".join(order) + "\n")
    (HERE / "cases.json").write_text(json.dumps({
        "reviewer_model": REVIEW_MODEL, "effort": "high", "repetitions": REPS, "budget_usd": BUDGET,
        "prompt_sha256": sha((HERE / "prompts/reviewer.txt").read_text()), "schema": REVIEW_SCHEMA,
        "lessons_script_sha256": sha(SCRIPT.read_bytes()), "cases": cases}, indent=1) + "\n")
    print("frozen: %d fixtures, lessons spent $%.4f" % (len(cases), spent))
    return 0


def blind():
    cases = json.loads((HERE / "cases.json").read_text())
    raw = HERE / "results/raw"
    rng = random.SystemRandom()
    key, out, used = {}, ["# Blind review outputs", "",
                          "Arms are hidden. For each output, list which labels in labels.json it catches (mechanism and causal",
                          "failure, not just the file) in results/annotations.json, then run score.py.", ""], set()
    template = {}
    for c in cases["cases"]:
        files = sorted(raw.glob("%s.*.json" % c["id"]))
        if len(files) != 2 * cases["repetitions"]:
            raise SystemExit("%s: %d raw outputs, expected %d" % (c["id"], len(files), 2 * cases["repetitions"]))
        rng.shuffle(files)
        out += ["## Fixture %s" % c["id"], ""]
        for p in files:
            _, arm, rep = p.stem.split(".")
            ident = secrets.token_hex(4)
            while ident in used:
                ident = secrets.token_hex(4)
            used.add(ident)
            key[ident] = {"fixture": c["id"], "arm": arm, "rep": int(rep[1:])}
            template[ident] = {"caught": [], "false_blocking": 0, "new_genuine": 0, "note": ""}
            data = json.loads(p.read_text())["structured_output"]
            out += ["### Output %s" % ident, "", "verdict: %s" % data["verdict"], ""]
            if not data["findings"]:
                out += ["(no findings)", ""]
            for i, fd in enumerate(data["findings"], 1):
                out += ["%d. [%s] %s — %s" % (i, "BLOCKING" if fd["blocking"] else "note", fd["file"], fd["location"]),
                        "   mechanism: " + fd["mechanism"].replace("\n", " "), "   evidence: " + fd["evidence"].replace("\n", " "), ""]
    res = HERE / "results"
    (res / "blind.md").write_text("\n".join(out) + "\n")
    (res / "key.json").write_text(json.dumps(key, indent=1, sort_keys=True) + "\n")
    (res / "annotations.template.json").write_text(json.dumps(template, indent=1, sort_keys=True) + "\n")
    print("wrote blind.md (%d outputs), key.json, annotations.template.json" % len(key))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--blind", action="store_true")
    ap.add_argument("--work", help="scratch directory outside the checkout")
    args = ap.parse_args()
    sys.exit(blind() if args.blind else cmd_main(args))


if __name__ == "__main__":
    main()
