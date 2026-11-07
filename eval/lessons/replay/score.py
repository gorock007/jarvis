#!/usr/bin/env python3
"""Validate the m5 replay files, then apply the frozen pass bar to Jarvis's annotations.

  python3 -I score.py --check     structure, hashes, completeness, disclosure scan (no annotations needed)
  python3 -I score.py             verdict from results/annotations.json (blind, written by Jarvis)

annotations.json: {"<output id>": {"caught": ["A1", ...], "false_blocking": 0, "new_genuine": 0, "note": ""}}
  caught          label ids (labels.json) the output catches: the mechanism and its cause, not a file name
  false_blocking  blocking findings the annotator judged wrong (on a control, any blocking finding that is not
                  a real defect; on a defective fixture, blocking findings that are false)
  new_genuine     real defects found that no label covers (reported, never added to the denominator)

Pass bar (frozen before any result): treatment catches >= baseline + 4 of the 36 defect opportunities
(12 labels x 3); no label caught fewer times in treatment than in baseline by more than 1; the p5f
bypass (label P1) caught in >= 2 of 3 treatment runs; zero false blocking findings in the 6 treatment
control runs. Any missing fixture, call or annotation: incomplete. Otherwise: fail ("no demonstrated benefit").
"""
import hashlib
import json
from pathlib import Path
import re
import sys

HERE = Path(__file__).resolve().parent
RES = HERE / "results"
MIN_GAIN = 4
MAX_LOSS = 1
BYPASS = "P1"
UNVERIFIED = "B1"
SECRETS = [
    (r"(?i)\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b", "uuid / session id"),
    (r"/Users/|/home/[a-z]", "home path"),
    (r"\b(?:sk|pk|rk)[-_][A-Za-z0-9_-]{16,}", "api key"),
    (r"\b(?:gh[pousr]|xox[abprs]|glpat|github_pat)[-_][A-Za-z0-9_-]{16,}", "token"),
    (r"\bAKIA[A-Z0-9]{16}\b", "aws key"),
    (r"-----BEGIN [A-Z ]*PRIVATE KEY-----", "private key"),
]
# hook-payload code in the packets legitimately names a session_id field; in model output it would be a real one
RAW_ONLY = [(r"\"session_id\"\s*:", "session_id field")]


def sha(data):
    return hashlib.sha256(data if isinstance(data, bytes) else data.encode()).hexdigest()


def load(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def check():
    """Return (problems, facts). Problems make the replay incomplete or invalid."""
    problems = []
    labels = load(HERE / "labels.json")["fixtures"]
    cases = load(HERE / "cases.json")
    reps = cases["repetitions"]
    ids = [x["id"] for x in labels]
    if [c["id"] for c in cases["cases"]] != ids:
        problems.append("cases.json fixtures differ from labels.json")
    n_labels = sum(len(x["labels"]) for x in labels)
    if len(ids) != 10 or n_labels != 12 or sum(x["kind"] == "control" for x in labels) != 2:
        problems.append("expected 10 fixtures (8 defective + 2 controls) and 12 labels")
    if sha((HERE / "prompts/reviewer.txt").read_text()) != cases["prompt_sha256"]:
        problems.append("reviewer prompt differs from the frozen hash")
    for c in cases["cases"]:
        d = HERE / "fixtures" / c["id"]
        try:
            base = (d / "packet.baseline.txt").read_text()
            treat = (d / "packet.treatment.txt").read_text()
            lessons = (d / "LESSONS.md").read_text()
            selected = (d / "select.txt").read_text()
        except OSError as error:
            problems.append("%s: missing frozen file (%s)" % (c["id"], error.filename))
            continue
        if sha(base) != c["packet"]["baseline_sha256"] or sha(treat) != c["packet"]["treatment_sha256"]:
            problems.append("%s: packet hash differs from cases.json" % c["id"])
        if sha(lessons) != c["lessons"]["sha256"] or sha(selected) != c["lessons"]["selected_sha256"]:
            problems.append("%s: lessons hash differs from cases.json" % c["id"])
        if not treat.startswith(base) or treat[len(base):] != selected:
            problems.append("%s: arms differ by more than the selected lessons" % c["id"])
    raw = RES / "raw"
    outputs = {}
    for c in cases["cases"]:
        for arm in ("baseline", "treatment"):
            for rep in range(1, reps + 1):
                p = raw / ("%s.%s.r%d.json" % (c["id"], arm, rep))
                if not p.is_file():
                    problems.append("missing output %s" % p.name)
                    continue
                try:
                    data = load(p)
                    out = data["structured_output"]
                    assert out["verdict"] in ("commit", "send_back") and isinstance(out["findings"], list)
                    for f in out["findings"]:
                        assert set(f) == {"file", "location", "blocking", "mechanism", "evidence"} and isinstance(f["blocking"], bool)
                    assert data["eval"]["packet_sha256"] == c["packet"]["%s_sha256" % arm]
                except (OSError, ValueError, KeyError, AssertionError, TypeError):
                    problems.append("malformed output %s" % p.name)
                    continue
                outputs[(c["id"], arm, rep)] = data
    key = {}
    if (RES / "key.json").is_file() and (RES / "blind.md").is_file():
        key = load(RES / "key.json")
        blind = (RES / "blind.md").read_text()
        want = {(c["id"], a, r) for c in cases["cases"] for a in ("baseline", "treatment") for r in range(1, reps + 1)}
        got = {(v["fixture"], v["arm"], v["rep"]) for v in key.values()}
        if got != want or len(key) != len(want):
            problems.append("key.json does not cover each output exactly once")
        for ident in key:
            if blind.count("### Output %s\n" % ident) != 1:
                problems.append("blind.md lacks output %s" % ident)
        # only the scaffolding: finding text may use "baseline" as a code term
        if re.search(r"(?im)^(?:#+ .*|verdict:.*)\b(baseline|treatment)\b", blind):
            problems.append("blind.md names an arm")
    else:
        problems.append("results/blind.md or key.json missing")
    scanned = [p for p in (HERE / "fixtures").rglob("*") if p.is_file()] + list(raw.glob("*.json")) \
        + [HERE / "cases.json", HERE / "labels.json", RES / "blind.md", RES / "key.json", RES / "ledger.jsonl"]
    for p in scanned:
        if not p.is_file():
            continue
        text = p.read_text(encoding="utf-8", errors="replace")
        for pattern, name in SECRETS + (RAW_ONLY if p.parent == raw else []):
            if re.search(pattern, text):
                problems.append("disclosure scan: %s in %s" % (name, p.relative_to(HERE)))
    ledger = []
    if (RES / "ledger.jsonl").is_file():
        ledger = [json.loads(x) for x in (RES / "ledger.jsonl").read_text().splitlines() if x]
    return problems, {"labels": labels, "cases": cases, "outputs": outputs, "key": key, "ledger": ledger}


def verdict(facts):
    labels, cases, key = facts["labels"], facts["cases"], facts["key"]
    reps = cases["repetitions"]
    annotations = load(RES / "annotations.json") if (RES / "annotations.json").is_file() else None
    if annotations is None:
        return "incomplete", ["results/annotations.json missing: Jarvis has not scored yet"], {}
    reasons = []
    if set(annotations) != set(key):
        reasons.append("annotations cover %d of %d outputs" % (len(set(annotations) & set(key)), len(key)))
        return "incomplete", reasons, {}
    by_label = {x["id"]: [] for f in labels for x in f["labels"]}
    owner = {x["id"]: f["id"] for f in labels for x in f["labels"]}
    caught = {(a, l): 0 for a in ("baseline", "treatment") for l in by_label}
    false_block = {a: {"control": 0, "defective": 0} for a in ("baseline", "treatment")}
    new = {"baseline": 0, "treatment": 0}
    kind = {f["id"]: f["kind"] for f in labels}
    for ident, ann in annotations.items():
        k = key[ident]
        for l in ann["caught"]:
            if owner.get(l) != k["fixture"]:
                reasons.append("output %s claims label %s of another fixture" % (ident, l))
        for l in set(ann["caught"]) & {l for l in by_label if owner[l] == k["fixture"]}:
            caught[(k["arm"], l)] += 1
        false_block[k["arm"]]["control" if kind[k["fixture"]] == "control" else "defective"] += int(ann["false_blocking"])
        new[k["arm"]] += int(ann.get("new_genuine", 0))
    if reasons:
        return "incomplete", reasons, {}

    def totals(skip=()):
        return {a: sum(caught[(a, l)] for l in by_label if l not in skip) for a in ("baseline", "treatment")}
    full, without = totals(), totals((UNVERIFIED,))
    opportunities = len(by_label) * reps
    table = {l: (caught[("baseline", l)], caught[("treatment", l)]) for l in by_label}
    checks = [
        ("treatment >= baseline + %d of %d" % (MIN_GAIN, opportunities), full["treatment"] >= full["baseline"] + MIN_GAIN,
         "baseline %d, treatment %d" % (full["baseline"], full["treatment"])),
        ("no label lost by more than %d" % MAX_LOSS, all(b - t <= MAX_LOSS for b, t in table.values()),
         ", ".join("%s %d>%d" % (l, b, t) for l, (b, t) in table.items() if b - t > MAX_LOSS) or "none"),
        ("p5f bypass (%s) caught in >= 2 of %d treatment runs" % (BYPASS, reps), table[BYPASS][1] >= 2, "%d of %d" % (table[BYPASS][1], reps)),
        ("zero false blocking findings in the %d treatment control runs" % (2 * reps), false_block["treatment"]["control"] == 0,
         str(false_block["treatment"]["control"])),
    ]
    detail = {"per_label_baseline_treatment": table, "totals_with_351ab83": full,
              "totals_without_351ab83": without, "opportunities": opportunities,
              "opportunities_without_351ab83": opportunities - reps,
              "false_blocking": false_block, "new_genuine_defects": new, "checks": checks}
    return ("pass" if all(c[1] for c in checks) else "fail"), [], detail


def report(problems, facts, result):
    status, reasons, detail = result
    spent = sum(x.get("cost") or 0 for x in facts["ledger"])
    lessons = sum(x.get("cost") or 0 for x in facts["ledger"] if x["kind"] == "lessons")
    print("VERDICT: %s" % status.upper())
    for r in reasons:
        print("  -", r)
    if detail:
        print("per label (baseline caught, treatment caught of %d):" % facts["cases"]["repetitions"])
        for l, (b, t) in detail["per_label_baseline_treatment"].items():
            print("  %-3s %d %d%s" % (l, b, t, "  (unverified)" if l == UNVERIFIED else ""))
        print("totals with 351ab83:    ", detail["totals_with_351ab83"], "of", detail["opportunities"])
        print("totals without 351ab83: ", detail["totals_without_351ab83"], "of", detail["opportunities_without_351ab83"])
        print("false blocking:", json.dumps(detail["false_blocking"]), "· new genuine defects:", json.dumps(detail["new_genuine_defects"]))
        for name, ok, info in detail["checks"]:
            print("  [%s] %s (%s)" % ("ok" if ok else "FAIL", name, info))
    print("cost: $%.4f total, $%.4f of it lesson passes" % (spent, lessons))
    for p in problems:
        print("PROBLEM:", p)


def main():
    problems, facts = check()
    if "--check" in sys.argv[1:]:
        print("check: %d problem(s); %d of %d outputs present" % (len(problems), len(facts["outputs"]),
              2 * facts["cases"]["repetitions"] * len(facts["cases"]["cases"])))
        for p in problems:
            print("PROBLEM:", p)
        sys.exit(1 if problems else 0)
    if problems:
        report(problems, facts, ("incomplete", ["validity problems above"], {}))
        sys.exit(2)
    result = verdict(facts)
    report(problems, facts, result)
    sys.exit({"pass": 0, "fail": 1, "incomplete": 2}[result[0]])


if __name__ == "__main__":
    main()
