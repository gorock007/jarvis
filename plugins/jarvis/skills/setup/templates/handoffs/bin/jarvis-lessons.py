#!/usr/bin/env python3
"""Reviewed, repository-local lessons. Stdlib only; invoke with python3 -I.

Single writer (Jarvis): intentionally no lease, journal, or automatic retries.
Only apply advances collection; proposal output is data, never executable code.
"""
import argparse
import datetime as dt
import difflib
import fnmatch
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time

MODEL = "claude-sonnet-5-5"
BUNDLE_CAP = 160000
FILE_CAP = 12288
DELIVERY_CAP = 3072
ACTIVE_KEYS = ("id", "date", "checked_at", "scope", "trigger", "lesson", "evidence", "supersedes")
RETIRE_KEYS = ("id", "action", "replacement", "reason", "evidence")
LESSON_ID = re.compile(r"L[0-9]{6}\Z")
SOURCE_ID = re.compile(r"S[0-9a-f]{64}\Z")
HASH = re.compile(r"[0-9a-f]{64}\Z")
REDACTED = "[REDACTED]"


class Failure(Exception):
    pass


def require(condition, message):
    if not condition:
        raise Failure(message)


def dump(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False)


def sha(value):
    return hashlib.sha256(value if isinstance(value, bytes) else value.encode("utf-8")).hexdigest()


def utcdate():
    return dt.datetime.now(dt.timezone.utc).date().isoformat()


def stamp():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def scrub(text):
    """Jev's credential net, plus home paths and session/terminal UUIDs.

    Apply to text BEFORE JSON serialization, so line-based PEM handling works.
    This cannot recognize arbitrary personal prose or unrelated project names.
    """
    text = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", text)
    text = re.sub(r"-----BEGIN [A-Z ]*(?:PRIVATE KEY|CERTIFICATE)-----.*?(?:-----END [A-Z ]+-----|\Z)",
                  REDACTED, text, flags=re.S)
    for name, value in os.environ.items():
        if len(value) >= 8 and re.search(r"KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL", name, re.I):
            text = text.replace(value, REDACTED)
    patterns = (
        r"eyJ[A-Za-z0-9_-]{8,}(?:\.[A-Za-z0-9._-]+)?",
        r"(?:sk|pk|rk)[-_][A-Za-z0-9_-]{12,}",
        r"(?:gh[pousr]|xox[abprs]|glpat|github_pat|hf)[-_][A-Za-z0-9_-]{12,}",
        r"AIza[A-Za-z0-9_-]{30,}", r"(?:AKIA|ASIA|AGPA|AIDA|AROA)[A-Z0-9]{16}",
        r"(?i)\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b",
        r"(?:/Users/|/home/|/root/)[^\s\"'<>`]+", r"[A-Za-z]:[\\/]Users[\\/][^\s\"'<>`]+",
    )
    for pattern in patterns:
        text = re.sub(pattern, REDACTED, text)
    credential = (r"((?<![A-Za-z])(?i:key|token|secret|passwo?r?d|credential)"
                  r"s?(?:[_.-][A-Za-z0-9_.-]{0,40}|[A-Z0-9_]{0,40})?[\"']?[ \t]*[:=][ \t]*)"
                  r"(\"[^\"\n]*\"|'[^'\n]*'|[^\s\[\],;}]{4,})")
    text = re.sub(credential, lambda m: m[1] + REDACTED, text)
    text = re.sub(r"([a-z](?:Key|Token|Secret|Password|Credential)[\"']?[ \t]*[:=][ \t]*)"
                  r"(\"[^\"\n]*\"|'[^'\n]*'|[^\s\[\],;}]{4,})", lambda m: m[1] + REDACTED, text)
    text = re.sub(r"((?:Set-)?Cookie: *[A-Za-z0-9_.-]+=)[^;\s]+", lambda m: m[1] + REDACTED, text, flags=re.I)
    text = re.sub(r"((?:Bearer|Basic) +)[A-Za-z0-9._~+/=-]{8,}", lambda m: m[1] + REDACTED, text, flags=re.I)
    return re.sub(r"(?<![A-Za-z0-9+.-])([A-Za-z][A-Za-z0-9+.-]*://)[^\s/@:]+:[^\s/@]+@", lambda m: m[1] + REDACTED + "@", text)


def clean(value):
    if isinstance(value, str):
        return scrub(value)
    if isinstance(value, list):
        return [clean(v) for v in value]
    if isinstance(value, dict):
        return {scrub(k): clean(v) for k, v in value.items()}
    return value


def loads(text):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, "duplicate JSON key")
            result[key] = value
        return result
    try:
        return json.loads(text, object_pairs_hook=pairs,
                          parse_constant=lambda _: (_ for _ in ()).throw(Failure("nonfinite JSON number")))
    except (ValueError, TypeError):
        raise Failure("invalid JSON") from None


def relative(value, glob=False):
    require(isinstance(value, str) and value and not re.search(r"[\x00-\x1f\x7f\\]", value), "invalid relative path")
    require(not value.startswith("/") and not re.match(r"^[A-Za-z]:", value), "absolute path refused")
    parts = value.split("/")
    require(".." not in parts and "." not in parts and "" not in parts, "non-normalized path refused")
    require(glob or not any(c in value for c in "*?[]"), "expected literal path")
    return str(PurePosixPath(value))


def checked_path(root, rel):
    """Reject symlinks in every component, including dangling links."""
    path = root
    for part in relative(rel, glob=True).split("/"):
        path = path / part
        require(not path.is_symlink(), "symlink path refused")
    return path


def read(root, rel, missing=None):
    path = checked_path(root, rel)
    if not path.exists():
        return missing
    require(path.is_file(), "expected a regular file")
    # O_NOFOLLOW closes the final-component replacement window on supported hosts.
    fd = os.open(str(path), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as handle:
        require(stat.S_ISREG(os.fstat(handle.fileno()).st_mode), "expected a regular file")
        return handle.read().decode("utf-8")


def atomic(root, rel, content):
    path = checked_path(root, rel)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp = tempfile.mkstemp(prefix=".lessons-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        checked_path(root, rel)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def keys(value, expected):
    require(isinstance(value, dict) and set(value) == set(expected), "unknown or missing object keys")


def line(value, limit, empty=False):
    require(isinstance(value, str) and (empty or bool(value.strip())) and len(value) <= limit
            and not any(ord(c) < 32 or ord(c) == 127 or c in "\u2028\u2029" for c in value), "invalid or overlong single-line string")
    require(scrub(value) == value, "sensitive output refused")


def date(value):
    require(isinstance(value, str) and bool(re.fullmatch(r"\d{4}-\d{2}-\d{2}", value)), "invalid date")
    try:
        return dt.date.fromisoformat(value)
    except ValueError:
        raise Failure("invalid date") from None


def evidence(value, available=None, empty=False):
    require(isinstance(value, list) and (empty or bool(value)) and len(value) <= 3, "invalid evidence count")
    require(all(isinstance(v, str) and SOURCE_ID.fullmatch(v) for v in value), "invalid evidence ID")
    require(len(set(value)) == len(value), "duplicate evidence")
    if available is not None:
        require(set(value) <= available, "unknown evidence ID")


def entry(value, as_of, available=None):
    keys(value, ACTIVE_KEYS)
    require(isinstance(value["id"], str) and LESSON_ID.fullmatch(value["id"]) and value["id"] != "L000000", "invalid lesson ID")
    require(date(value["date"]) <= date(value["checked_at"]) <= date(as_of), "invalid lesson chronology")
    require(isinstance(value["scope"], list) and 1 <= len(value["scope"]) <= 4, "invalid scope count")
    for scope in value["scope"]:
        line(scope, 400)
        relative(scope, glob=True)
    require(len(set(value["scope"])) == len(value["scope"]), "duplicate scope")
    line(value["trigger"], 160)
    line(value["lesson"], 400)
    evidence(value["evidence"], available)
    require(value["supersedes"] is None or (isinstance(value["supersedes"], str)
            and LESSON_ID.fullmatch(value["supersedes"])), "invalid supersedes ID")


def render(response, proposal):
    text = "# Lessons\n\n<!-- schema: 1; accepted-proposal: " + proposal + " -->\n"
    for key, heading in (("review", "For Jarvis review"), ("briefs", "For worker briefs")):
        text += "\n## " + heading + "\n\n```jsonl\n"
        text += "".join(dump({k: row[k] for k in ACTIVE_KEYS}) + "\n" for row in response[key])
        text += "```\n"
    require(len(text.encode()) <= FILE_CAP, "rendered lessons exceed 12,288 bytes")
    return text


def parse_lessons(text, as_of):
    if text is None:
        return {"review": [], "briefs": []}
    require(len(text.encode()) <= FILE_CAP, "lessons file exceeds 12,288 bytes")
    pattern = (r"# Lessons\n\n<!-- schema: 1; accepted-proposal: ([0-9a-f]{64}) -->\n"
               r"\n## For Jarvis review\n\n```jsonl\n(.*?)```\n"
               r"\n## For worker briefs\n\n```jsonl\n(.*?)```\n")
    match = re.fullmatch(pattern, text, re.S)
    require(match is not None, "invalid lessons file format; delivery refused")
    result = {key: [loads(row) for row in block.splitlines()] for key, block in zip(("review", "briefs"), match.groups()[1:])}
    rows = result["review"] + result["briefs"]
    require(len(rows) <= 24, "more than 24 lessons")
    for row in rows:
        entry(row, as_of)
    require(len({r["id"] for r in rows}) == len(rows), "duplicate active ID")
    return result


def validate(response, bundle):
    keys(response, ("review", "briefs", "retired", "review_notes"))
    require(all(isinstance(v, list) for v in response.values()), "response fields must be arrays")
    require(len(response["review_notes"]) <= 12, "too many review notes")
    for note in response["review_notes"]:
        line(note, 400)
    current = parse_lessons(bundle["current_lessons"], bundle["as_of"])
    old = {r["id"]: r for r in current["review"] + current["briefs"]}
    available = {s["id"] for s in bundle["sources"]}
    # Missing archived evidence may be retained unchanged, but cannot renew an entry.
    known = available | {s for row in old.values() for s in row["evidence"]}
    active = response["review"] + response["briefs"]
    require(len(active) <= 24, "more than 24 active lessons")
    ids = []
    new_ids = []
    next_number = int(bundle["next_id"][1:])
    retired_before = set(bundle["manifest"]["retired_ids"])
    for row in active:
        entry(row, bundle["as_of"], known)
        ident = row["id"]
        require(ident not in retired_before, "retired ID cannot reappear")
        ids.append(ident)
        if ident in old:
            prior = old[ident]
            require(row["date"] == prior["date"], "creation date changed")
            require(all(row[k] == prior[k] for k in ("scope", "trigger", "lesson", "supersedes")), "substantive correction requires a new ID")
            require(row["checked_at"] in (prior["checked_at"], bundle["as_of"]), "invalid revalidation date")
            if not set(row["evidence"]) <= available:
                require(row == prior, "unavailable evidence cannot renew or change a lesson")
        else:
            new_ids.append(ident)
            require(row["date"] == row["checked_at"] == bundle["as_of"], "new lesson must use as_of date")
            require(set(row["evidence"]) <= available, "new lesson needs available evidence")
    require(len(ids) == len(set(ids)), "duplicate active ID")
    require(sorted(new_ids) == ["L%06d" % n for n in range(next_number, next_number + len(new_ids))], "new IDs must be sequential")
    removed = {}
    for row in response["retired"]:
        keys(row, RETIRE_KEYS)
        require(isinstance(row["id"], str) and row["id"] in old and row["id"] not in removed, "invalid retirement ID")
        require(row["id"] not in ids and row["action"] in ("superseded", "removed", "expired"), "invalid retirement action")
        line(row["reason"], 400)
        evidence(row["evidence"], available, empty=True)
        if not row["evidence"]:
            require(row["action"] == "expired" or re.search(r"unavailable|missing", row["reason"], re.I), "empty retirement evidence needs an explanation")
        if row["action"] == "expired":
            require(expired(old[row["id"]], bundle["as_of"]), "premature expiry")
        if row["action"] == "superseded":
            require(isinstance(row["replacement"], str) and row["replacement"] in new_ids, "superseded lesson needs a new replacement")
        else:
            require(row["replacement"] is None, "unexpected retirement replacement")
        removed[row["id"]] = row
    require(set(old) - set(ids) == set(removed), "missing retirement for omitted current lesson")
    for row in active:
        if row["id"] in new_ids and row["supersedes"] is not None:
            retire = removed.get(row["supersedes"])
            require(retire is not None and retire["action"] == "superseded" and retire["replacement"] == row["id"], "supersedes/retirement mismatch")
    for row in removed.values():
        if row["action"] == "superseded":
            require(any(a["id"] == row["replacement"] and a["supersedes"] == row["id"] for a in active), "replacement must name supersedes")
    render(response, "0" * 64)
    return next_number + len(new_ids)


def expired(row, as_of):
    return (date(as_of) - date(row["checked_at"])).days >= 90


def matches(scopes, path):
    return any(scope == "**" or fnmatch.fnmatchcase(path, scope) for scope in scopes)


class Lessons:
    base = "handoffs/.jarvis/lessons"

    def __init__(self, root):
        self.root = root
        self.as_of = utcdate()
        self.text = read(root, "handoffs/LESSONS.md")
        self.current = parse_lessons(self.text, self.as_of)
        self.rows = self.current["review"] + self.current["briefs"]
        saved = read(root, self.base + "/state.json")
        self.state = loads(saved) if saved is not None else {
            "schema": 1, "initialized": False, "processed": {}, "seen_logs": [],
            "briefs": [], "next_id": 1, "retired_ids": [], "scope_snapshot": {}, "accepted": None,
        }
        require(isinstance(self.state, dict) and self.state.get("schema") == 1, "invalid lessons state")
        require(type(self.state["next_id"]) is int and 1 <= self.state["next_id"] <= 1000000, "invalid next ID")
        if self.rows:
            self.state["next_id"] = max(self.state["next_id"], max(int(r["id"][1:]) for r in self.rows) + 1)

    def files(self, directory, suffix):
        path = checked_path(self.root, directory)
        if not path.exists():
            return []
        require(path.is_dir(), "expected directory")
        return sorted(p.relative_to(self.root).as_posix() for p in path.iterdir()
                      if p.name.endswith(suffix) and not p.is_symlink() and p.is_file())

    def scope_snapshot(self):
        """Inspect only literal/glob-matching repository paths; never follow links."""
        result = {}
        scopes = [scope for row in self.rows for scope in row["scope"]]
        # Avoid recursively walking the private evidence store or arbitrary trees.
        proc = subprocess.run(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                              cwd=str(self.root), capture_output=True, timeout=15)
        paths = set(proc.stdout.decode("utf-8").split("\0")) if proc.returncode == 0 else set()
        for scope in scopes:
            if not any(c in scope for c in "*?["):
                paths.add(scope)
        for path in sorted(paths - {""}):
            if path.startswith(self.base + "/") or path == "handoffs/LESSONS.md":
                continue
            if not matches(scopes, path):
                continue
            try:
                target = checked_path(self.root, path)
                if target.is_file():
                    result[path] = sha(target.read_bytes())
            except Failure:
                continue
        return result, proc.returncode == 0

    def scope_changes(self):
        snapshot, git_available = self.scope_snapshot()
        report = []
        for row in self.rows:
            previous = self.state["scope_snapshot"].get(row["id"])
            present = {p: h for p, h in snapshot.items() if matches(row["scope"], p)}
            report.append({"id": row["id"], "git_available": git_available,
                           "baseline_available": previous is not None,
                           "missing_scopes": [s for s in row["scope"] if s != "**" and not any(matches([s], p) for p in present)],
                           "changed_paths": sorted(p for p in set(previous or {}) | set(present)
                                                   if (previous or {}).get(p) != present.get(p)) if previous is not None else []})
        return clean(report)

    def collect(self):
        warnings = []
        sources = {}
        records = {}

        def source(kind, text, path, brief=None, location=None, **extra):
            safe = scrub(text)
            ident = "S" + sha(kind + "\n" + safe)
            sources[ident] = {"id": ident, "kind": kind, "provenance": "local-unverified", "text": safe}
            records[ident] = clean({"id": ident, "kind": kind, "path": path,
                                    "sha256": sha(text), "brief": brief, "location": location,
                                    "provenance": "local-unverified", "reason": "included", **extra})
            return ident

        handoffs = []
        for path in self.files("handoffs/merged", ".md"):
            text = read(self.root, path)
            brief_match = re.search(r"^brief:[ \t]*(.+)$", text, re.M)
            brief = relative(brief_match[1].strip()) if brief_match else None
            handoffs.append({"path": path, "sha256": sha(text), "brief": brief,
                             "id": source("handoff", text, path, brief)})
        unseen = [h for h in handoffs if self.state["processed"].get(h["path"]) != h["sha256"]]
        skipped = unseen[:-10] if not self.state["initialized"] else []
        candidates = unseen[-10:] if not self.state["initialized"] else unseen[:10]
        log_ids = []
        raw = read(self.root, "handoffs/.jev/log.jsonl", "")
        for number, row in enumerate(raw.splitlines(keepends=True), 1):
            if not row.endswith("\n"):
                warnings.append("incomplete final Jev line deferred")
                continue
            try:
                obj = loads(row)
                require(isinstance(obj, dict), "invalid Jev row")
                if obj.get("kind") != "outcome":
                    continue
                require(obj.get("outcome") in ("clean", "corrected", "escalated", "respawned"), "invalid outcome")
                brief = relative(obj["brief"])
                require(isinstance(obj.get("ts"), str), "invalid outcome time")
                require(obj.get("reason") in (None, "checks", "scope", "logic", "other"), "invalid outcome reason")
                normalized = {k: obj.get(k) for k in ("ts", "kind", "brief", "outcome", "reason")}
                ident = source("outcome", dump(normalized), "handoffs/.jev/log.jsonl", brief, number, timestamp=obj["ts"])
                log_ids.append(ident)
            except (Failure, KeyError, TypeError):
                warnings.append("malformed Jev line %d" % number)
        all_briefs = set(self.state["briefs"]) | {h["brief"] for h in handoffs if h["brief"]}
        for number, row in enumerate(read(self.root, "handoffs/.jarvis/shadow-review.log", "").splitlines(), 1):
            fields = row.split("\t", 4)
            if len(fields) != 5 or not fields[3].isdigit():
                warnings.append("malformed shadow line %d" % number)
                continue
            timestamp, commit, label, count, notes = fields
            matches_brief = [b for b in all_briefs if label in (b, PurePosixPath(b).stem)]
            brief = matches_brief[0] if len(matches_brief) == 1 else None
            ident = source("shadow", dump({"ts": timestamp, "commit": commit, "brief_or_slug": label,
                           "blocking_misses": int(count), "notes": notes}), "handoffs/.jarvis/shadow-review.log",
                           brief, number, timestamp=timestamp, association="exact" if brief else "unresolved")
            log_ids.append(ident)
        for path in ["handoffs/OPEN.md"] + self.files("handoffs/log", ".md"):
            text = read(self.root, path, "")
            # Top-level or nested bullets include their indented continuation lines.
            lines = text.splitlines(keepends=True)
            for index, row in enumerate(lines):
                bullet = re.match(r"^(\s*)(?:[-+*]|\d+[.)])\s+", row)
                if not bullet:
                    continue
                end = index + 1
                indent = len(bullet[1])
                while end < len(lines):
                    following = lines[end]
                    if following.strip() and len(following) - len(following.lstrip()) <= indent:
                        break
                    end += 1
                block = "".join(lines[index:end]).rstrip()
                if re.search(r"security[ -]review|security-guidance", block, re.I):
                    commits = re.findall(r"\b[0-9a-f]{7,40}\b", block)
                    log_ids.append(source("security", block, path, location=index + 1, commits=commits))
        log_ids = sorted(set(log_ids), key=lambda i: (records[i].get("timestamp", ""), i))
        included = []
        missing = []
        for ident in sorted({i for row in self.rows for i in row["evidence"]}):
            if ident not in sources:
                saved = read(self.root, self.base + "/sources/" + ident[1:] + ".json")
                if saved is None:
                    missing.append(ident)
                    continue
                item = loads(saved)
                keys(item, ("source", "record"))
                require(item["source"]["id"] == ident and "S" + sha(item["source"]["kind"] + "\n" + item["source"]["text"]) == ident,
                        "corrupt evidence snapshot")
                sources[ident], records[ident] = clean(item["source"]), clean(item["record"])
            included.append(ident)
        manifest = {"schema": 1, "observed_at": stamp(), "retired_ids": self.state["retired_ids"],
                    "baseline_skipped": clean([{**h, "reason": "baseline-skipped"} for h in skipped]),
                    "missing_evidence": missing, "security_evidence": "recorded" if any(records[i]["kind"] == "security" for i in log_ids) else "not-recorded",
                    "records": [], "warnings": warnings}
        bundle = {"as_of": self.as_of, "next_id": "L%06d" % self.state["next_id"], "manifest": manifest,
                  "current_lessons": scrub(self.text) if self.text is not None else None,
                  "sources": [], "scope_changes": self.scope_changes()}

        def pack(ids):
            bundle["sources"] = [sources[i] for i in ids]
            manifest["records"] = [records[i] for i in ids]
            return len(dump(bundle).encode())

        require(pack(included) <= BUNDLE_CAP, "mandatory current lessons/evidence exceed bundle cap")
        selected = []
        deferred_groups = set()
        seen = set(self.state["seen_logs"])

        def associated(handoff):
            commits = set(re.findall(r"\b[0-9a-f]{7,40}\b", sources[handoff["id"]]["text"]))
            return [i for i in log_ids if (handoff["brief"] and records[i].get("brief") == handoff["brief"])
                    or (records[i]["kind"] == "security" and commits.intersection(records[i].get("commits", [])))]

        for handoff in candidates:
            group = [handoff["id"]] + associated(handoff)
            trial = list(dict.fromkeys(included + group))
            if pack(trial) > BUNDLE_CAP:
                deferred_groups.update(group)
                # Keep oldest-first processing; later handoffs wait too.
                break
            included = trial
            selected.append(handoff)
        selected_paths = {h["path"] for h in selected}
        queued_handoffs = [h for h in unseen if h not in skipped and h["path"] not in selected_paths]
        queued_briefs = {h["brief"] for h in queued_handoffs if h["brief"]}
        for handoff in queued_handoffs:
            deferred_groups.update(associated(handoff))
        for ident in log_ids:
            rec = records[ident]
            if ident in included or ident in seen or ident in deferred_groups or rec.get("brief") in queued_briefs:
                continue
            if rec["kind"] == "outcome" and rec.get("brief") not in set(self.state["briefs"]) | {h["brief"] for h in selected}:
                continue
            if pack(included + [ident]) <= BUNDLE_CAP:
                included.append(ident)
        size = pack(included)
        cursor = {**self.state, "initialized": True, "processed": dict(self.state["processed"]),
                  "briefs": sorted(set(self.state["briefs"]) | {h["brief"] for h in selected if h["brief"]}),
                  "seen_logs": sorted(seen | (set(included) & set(log_ids)))}
        for handoff in skipped + selected:
            cursor["processed"][handoff["path"]] = handoff["sha256"]
        summary = {"selected_handoffs": [h["path"] for h in selected], "baseline_skipped": len(skipped),
                   "queued_handoffs": len(queued_handoffs), "new_handoffs": len(unseen) - len(skipped),
                   "queued_evidence": len(set(log_ids) - seen - set(included)),
                   "new_evidence": len(set(log_ids) - seen), "source_ids": included,
                   "bundle_bytes": size, "warnings": warnings, "model": MODEL,
                   "estimated_input_tokens": math.ceil(size / 3),
                   "estimated_cost_usd": round(math.ceil(size / 3) * 2 / 1000000 + 8000 * 10 / 1000000, 4),
                   "estimate_note": "planning estimate; excludes prompt/CLI overhead; budget threshold $0.50 may overshoot"}
        work = bool(selected or set(included) & (set(log_ids) - seen) or any(expired(r, self.as_of) for r in self.rows)
                    or any(c["changed_paths"] or c["missing_scopes"] for c in bundle["scope_changes"]))
        return clean(bundle), clean(cursor), clean(summary), work

    def band(self):
        executable = checked_path(self.root, "handoffs/bin/jarvis")
        try:
            result = subprocess.run([str(executable), "band"], cwd=str(self.root), capture_output=True, timeout=15)
            words = result.stdout.decode("utf-8").split()
            require(result.returncode == 0 and words, "cannot read jarvis band; proposal refused")
            band = words[0].lower()
            require(band in ("green", "amber", "red", "unknown", "stale"), "unreadable jarvis band; proposal refused")
            require(band != "red", "red band; proposal refused")
            return band
        except (OSError, subprocess.TimeoutExpired, UnicodeError):
            raise Failure("cannot read jarvis band; proposal refused") from None

    def propose(self, dry_run):
        band = self.band()
        bundle, cursor, summary, work = self.collect()
        summary["band"] = band
        if dry_run or not work:
            summary["no_work"] = not work
            print(dump(summary))
            return
        prompt_path = Path(__file__).resolve().with_name("lessons-prompt.txt")
        require(not prompt_path.is_symlink() and prompt_path.is_file(), "trusted prompt missing or symlinked")
        prompt = prompt_path.read_text(encoding="utf-8")
        executable = shutil.which("claude")
        require(executable is not None, "claude not found")
        executable = str(Path(executable).resolve())
        started = time.monotonic()
        run = {"model": MODEL, "effort": "high", "started_at": stamp(), "duration_seconds": 0,
               "total_cost_usd": None, "usage": {}, "exit_state": "failed",
               "prompt_sha256": sha(prompt), "bundle_sha256": sha(dump(bundle))}
        print("lessons: generating one isolated proposal with " + MODEL, file=sys.stderr, flush=True)
        try:
            with tempfile.TemporaryDirectory(prefix="jarvis-lessons-") as directory:
                workdir = Path(directory)
                require(not workdir.resolve().is_relative_to(self.root.resolve()), "generation temp directory must be outside checkout")
                (workdir / "cwd").mkdir(mode=0o700)
                (workdir / "mcp.json").write_text('{"mcpServers":{}}', encoding="utf-8")
                (workdir / "system.txt").write_text(prompt, encoding="utf-8")
                command = [executable, "-p", "--model", MODEL, "--effort", "high", "--output-format", "json",
                           "--setting-sources", "", "--strict-mcp-config", "--mcp-config", str(workdir / "mcp.json"),
                           "--disable-slash-commands", "--tools", "", "--disallowedTools", "mcp__*",
                           "--no-session-persistence", "--max-turns", "1", "--max-budget-usd", "0.50",
                           "--system-prompt-file", str(workdir / "system.txt")]
                # run() kills and reaps only its own child on timeout. Never signal
                # a discovered PID, process pattern, or unrelated session.
                try:
                    result = subprocess.run(command, input=dump(bundle), cwd=str(workdir / "cwd"),
                                            text=True, capture_output=True, timeout=300)
                except subprocess.TimeoutExpired:
                    run["exit_state"] = "timeout"
                    raise Failure("generation timed out after 300 seconds; own child stopped") from None
            # Keep returned accounting even when schema validation subsequently
            # fails. Raw result/error text and session identifiers are never saved.
            outer = loads(result.stdout) if result.stdout.strip() else {}
            require(isinstance(outer, dict), "invalid generation envelope")
            cost = outer.get("total_cost_usd")
            require(cost is None or (type(cost) in (int, float) and math.isfinite(cost) and cost >= 0), "invalid returned cost")
            run["total_cost_usd"] = cost
            usage = outer.get("usage", {})
            require(isinstance(usage, dict), "invalid returned usage")

            def numeric(obj):
                return {k: numeric(v) if isinstance(v, dict) else v for k, v in obj.items()
                        if isinstance(v, dict) or (type(v) in (int, float) and math.isfinite(v) and v >= 0)}

            run["usage"] = numeric(usage)
            require(result.returncode == 0, "generation failed (including unsupported flags); no retry or apply")
            require(outer.get("is_error") is not True and outer.get("subtype", "success") == "success", "generation returned an error")
            response = loads(outer.get("result"))
            next_number = validate(response, bundle)
            run["exit_state"] = "success"
        finally:
            run["duration_seconds"] = round(time.monotonic() - started, 3)
            run = clean(run)
            atomic(self.root, self.base + "/runs/" + sha(dump(run)) + ".json", dump(run) + "\n")
        manifest = clean({"schema": 1, "created_at": stamp(), "base_lessons_sha256": sha(self.text) if self.text is not None else None,
                          "bundle": bundle, "cursor": cursor, "run": run})
        ident = sha(dump(manifest) + "\n" + dump(response))
        rendered = render(response, ident)
        directory = self.base + "/proposals/" + ident
        for src, rec in zip(bundle["sources"], bundle["manifest"]["records"]):
            rel = self.base + "/sources/" + src["id"][1:] + ".json"
            if read(self.root, rel) is None:
                atomic(self.root, rel, dump({"source": src, "record": rec}) + "\n")
        atomic(self.root, directory + "/manifest.json", dump(manifest) + "\n")
        atomic(self.root, directory + "/response.json", dump(response) + "\n")
        atomic(self.root, directory + "/LESSONS.md", rendered)
        diff = "".join(difflib.unified_diff((bundle["current_lessons"] or "").splitlines(True), rendered.splitlines(True),
                                            fromfile="accepted/LESSONS.md", tofile="proposed/LESSONS.md"))
        atomic(self.root, directory + "/changes.diff", diff)
        print(dump({"proposal": ident, "path": directory, "next_id": "L%06d" % next_number, **manifest["run"]}))

    def proposal(self, ident):
        require(bool(HASH.fullmatch(ident)), "invalid proposal ID")
        directory = self.base + "/proposals/" + ident
        manifest = loads(read(self.root, directory + "/manifest.json"))
        response = loads(read(self.root, directory + "/response.json"))
        require(sha(dump(manifest) + "\n" + dump(response)) == ident, "proposal content hash mismatch")
        validate(response, manifest["bundle"])
        rendered = render(response, ident)
        require(read(self.root, directory + "/LESSONS.md") == rendered, "proposal rendered file changed")
        return directory, manifest, response, rendered

    def apply(self, ident):
        directory, manifest, response, rendered = self.proposal(ident)
        require(read(self.root, directory + "/rejected.json") is None, "proposal was rejected")
        require((sha(self.text) if self.text is not None else None) == manifest["base_lessons_sha256"], "LESSONS.md changed since proposal; apply refused")
        state = manifest["cursor"]
        state["next_id"] = validate(response, manifest["bundle"])
        state["retired_ids"] = sorted(set(state["retired_ids"]) | {r["id"] for r in response["retired"]})
        state["accepted"] = ident
        self.rows = response["review"] + response["briefs"]
        snapshot, _ = self.scope_snapshot()
        state["scope_snapshot"] = {row["id"]: {p: h for p, h in snapshot.items() if matches(row["scope"], p)} for row in self.rows}
        # Two atomic files, deliberately no transaction journal (single-writer
        # contract). File first: a crash cannot consume unseen input silently.
        atomic(self.root, "handoffs/LESSONS.md", rendered)
        atomic(self.root, self.base + "/state.json", dump(clean(state)) + "\n")
        print("applied " + ident)

    def reject(self, ident, reason):
        directory, _, _, _ = self.proposal(ident)
        require(self.state["accepted"] != ident, "cannot reject accepted proposal; retire an entry instead")
        reason = scrub(reason)
        line(reason, 400)
        atomic(self.root, directory + "/rejected.json", dump({"reason": reason, "at": stamp()}) + "\n")
        print("rejected " + ident)

    def retire(self, ident, reason):
        require(any(r["id"] == ident for r in self.rows), "unknown active lesson ID")
        reason = scrub(reason)
        line(reason, 400)
        record = {"id": ident, "reason": reason, "at": stamp(), "previous_sha256": sha(self.text)}
        marker = sha(dump(record))
        current = {k: [r for r in v if r["id"] != ident] for k, v in self.current.items()}
        self.state["retired_ids"] = sorted(set(self.state["retired_ids"]) | {ident})
        self.state["scope_snapshot"].pop(ident, None)
        atomic(self.root, self.base + "/retirements/" + marker + ".json", dump(record) + "\n")
        atomic(self.root, "handoffs/LESSONS.md", render(current, marker))
        atomic(self.root, self.base + "/state.json", dump(clean(self.state)) + "\n")
        print("retired " + ident)

    def status(self):
        bundle, _, summary, _ = self.collect()
        summary["expired_ids"] = [r["id"] for r in self.rows if expired(r, self.as_of)]
        summary["active_entries"] = len(self.rows)
        summary["scope_changes"] = bundle["scope_changes"]
        summary["missing_evidence"] = bundle["manifest"]["missing_evidence"]
        summary["accepted"] = self.state["accepted"]
        runs = [loads(read(self.root, path)) for path in self.files(self.base + "/runs", ".json")]
        summary["recorded_cost_usd"] = round(sum(r["total_cost_usd"] for r in runs if r.get("total_cost_usd") is not None), 6)
        summary["runs_with_unknown_cost"] = sum(r.get("total_cost_usd") is None for r in runs)
        print(dump(summary))

    def show(self, ident):
        if ident is None:
            print(self.text or render(self.current, "0" * 64), end="")
            print(dump({"expired_ids": [r["id"] for r in self.rows if expired(r, self.as_of)],
                        "scope_changes": self.scope_changes()}), file=sys.stderr)
            return
        directory, manifest, response, rendered = self.proposal(ident)
        print(dump({"proposal": ident, "run": manifest["run"], "retired": response["retired"],
                    "review_notes": response["review_notes"],
                    "rejected": read(self.root, directory + "/rejected.json") is not None}))
        print("".join(difflib.unified_diff((manifest["bundle"]["current_lessons"] or "").splitlines(True),
                                          rendered.splitlines(True), fromfile="accepted/LESSONS.md",
                                          tofile="proposed/LESSONS.md")), end="")

    def select(self, audience, paths_file):
        supplied = Path(paths_file)
        # This is an explicitly supplied input file, never a model-supplied path.
        require(not any(p.is_symlink() for p in [supplied] + list(supplied.parents)), "symlink paths file refused")
        paths = [relative(p) for p in supplied.read_text(encoding="utf-8").splitlines() if p]
        expanded = set(paths)
        for path in paths:
            target = checked_path(self.root, path)
            if target.is_dir():
                for directory, dirs, files in os.walk(target, followlinks=False):
                    dirs[:] = sorted(d for d in dirs if not (Path(directory) / d).is_symlink() and d != ".git")
                    expanded.update((Path(directory) / name).relative_to(self.root).as_posix() for name in files
                                    if not (Path(directory) / name).is_symlink())
        scoped, _ = self.scope_snapshot()
        rows = self.current["review" if audience == "review" else "briefs"]
        eligible = []
        for row in rows:
            if expired(row, self.as_of) or not any(matches(row["scope"], p) for p in expanded):
                continue
            # A listed deleted diff path still matches, but entries whose every
            # specific scope is gone are no longer delivered.
            if "**" not in row["scope"] and not any(matches(row["scope"], p) for p in scoped):
                continue
            eligible.append(row)
        eligible.sort(key=lambda r: (-date(r["checked_at"]).toordinal(), r["id"]))
        output = ""
        omitted = []
        count = 0
        for row in eligible:
            rendered = dump({k: row[k] for k in ("id", "scope", "trigger", "lesson", "checked_at", "evidence")}) + "\n"
            if count >= 6 or len((output + rendered).encode()) > DELIVERY_CAP:
                omitted.append(row["id"])
            else:
                output += rendered
                count += 1
        print(output, end="")
        if omitted:
            print(dump({"omitted_count": len(omitted), "omitted_ids": omitted}), file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description="Propose, review and explicitly apply repository-local lessons.",
                                     epilog="Jarvis is the only writer. Check `jarvis sessions` before propose: one short Claude call, no child-lifetime reservation. Unknown/stale band is amber; unreadable/red refuses. Select uses whole-path fnmatchcase globs (including deleted diff paths), capped at 6 entries / 3,072 bytes.",
                                     allow_abbrev=False)
    subs = parser.add_subparsers(dest="command", required=True)
    subs.add_parser("status", allow_abbrev=False)
    sub = subs.add_parser("propose", allow_abbrev=False)
    sub.add_argument("--dry-run", action="store_true")
    sub = subs.add_parser("show", allow_abbrev=False)
    sub.add_argument("id", nargs="?")
    sub = subs.add_parser("apply", allow_abbrev=False)
    sub.add_argument("id")
    for cmd in ("reject", "retire"):
        sub = subs.add_parser(cmd, allow_abbrev=False)
        sub.add_argument("id")
        sub.add_argument("--reason", required=True)
    sub = subs.add_parser("select", allow_abbrev=False)
    sub.add_argument("--audience", choices=("review", "brief"), required=True)
    sub.add_argument("--paths-from", required=True)
    args = parser.parse_args()
    root = Path.cwd()
    while not (root / "handoffs").exists() and root != root.parent:
        root = root.parent
    require((root / "handoffs").is_dir(), "run inside a repository with handoffs/")
    lessons = Lessons(root)
    if args.command == "propose":
        lessons.propose(args.dry_run)
    elif args.command in ("apply", "show"):
        getattr(lessons, args.command)(args.id)
    elif args.command in ("reject", "retire"):
        getattr(lessons, args.command)(args.id, args.reason)
    elif args.command == "select":
        lessons.select(args.audience, args.paths_from)
    else:
        lessons.status()


if __name__ == "__main__":
    try:
        main()
    except (Failure, OSError, UnicodeError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        # Never echo raw CLI output or a path-bearing OS exception.
        message = str(error) if isinstance(error, Failure) else "invalid data or local I/O failure"
        print("lessons: " + scrub(message), file=sys.stderr)
        sys.exit(1)
