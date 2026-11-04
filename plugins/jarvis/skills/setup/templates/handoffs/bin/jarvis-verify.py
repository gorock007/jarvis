#!/usr/bin/env python3
"""jarvis-verify.py: the engine behind `jarvis merge <handoff> --check --verify`.
bin/jarvis prints the usual review summary, then execs this with `python3 -I`;
nothing else should call it.

  jarvis-verify.py run --root <checkout> --handoff <file> --runner <bin/jarvis>
                       --bash <path> [--max-sec N] [--lock-wait N] [--grace N]

It runs the brief's ```bash verify``` blocks under ## Checks against HEAD plus
exactly the handoff's listed changes, in a detached worktree of its own:

  handoffs/.jarvis/verify/<run | standalone-…>/<attempt>/   0700, removed at the end
      owner      ownership manifest, written before `git worktree add`; also the
                 context a nested `jarvis lock` reads (JARVIS_VERIFY_CONTEXT)
      tree/      the worktree: HEAD, the listed changes, declared inputs
      control/   private copies of bin/jarvis and jarvis-lock.pl for the lock shim
      checks/    each block's script, byte for byte
  handoffs/.jarvis/verify-results/<attempt>/                  kept: result, check-N.log

Each block runs in a fresh `bash --noprofile --norc -e -o pipefail` at the
worktree root, in a process group of its own; a class other than light runs under
that class's lease of the original checkout (`jarvis lock`), its timer starting
once the lease is held. One cleanup path, for pass, failure, timeout, INT, TERM
and HUP, stops what is left of the check's group and removes the worktree; a
watchdog in its own session does the same if this process dies without it.

Exit 0 passed · 1 file list mismatch, missing input or a failed check · 2 bad
brief/handoff/config or setup/cleanup failure · 75 lease wait ran out or the
inputs moved · 124 a check timed out · 129/130/143 HUP/INT/TERM.
Python 3.8+, standard library only.
"""
import argparse, hashlib, json, os, re, shutil, signal, stat, subprocess, sys, time

SCHEMA = "jarvis-verify-1"
TAIL = 40
ACTIONS = ("created", "modified", "deleted")
STATE_DIR = "handoffs/.jarvis"
SIGCODE = {signal.SIGINT: 130, signal.SIGTERM: 143, signal.SIGHUP: 129}
WAITID = hasattr(os, "waitid") and hasattr(os, "WNOWAIT")   # not on macOS before Python 3.13
# what a check must not inherit: another checkout's git, a profile, a dependency path
SCRUB = ("BASH_ENV", "ENV", "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR",
         "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_PREFIX", "GIT_NAMESPACE",
         "PYTHONPATH", "PYTHONHOME", "NODE_PATH", "VIRTUAL_ENV", "JARVIS_LOCKS_HELD",
         "JARVIS_CALLER_PWD", "JARVIS_VERIFY_CONTEXT", "CLAUDE_PROJECT_DIR", "OLDPWD")
CONVERT = """Mark each command the brief's ## Checks should run, for example:

```bash verify class=light timeout=300
bash -n src/tool.sh
```

class=light runs at once; any other class (suite, docker, one in jarvis.conf) runs under
that class's `jarvis lock` lease. Prose around the blocks stays yours to review."""


class Fail(Exception):
    def __init__(self, code, msg):
        Exception.__init__(self, msg)
        self.code, self.msg = code, msg


class Interrupted(Exception):
    pass


def say(msg=""):
    print(msg, flush=True)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def git_env():
    env = dict(os.environ)
    for k in list(env):
        if k.startswith("GIT_") and k not in ("GIT_CONFIG_NOSYSTEM",):
            del env[k]
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["LC_ALL"] = "C"
    return env


def git(root, *args, inp=None, env=None, ok=(0,), literal=True):
    pre = ["--literal-pathspecs"] if literal else []    # check-ignore takes no pathspec magic
    p = subprocess.run(["git", "-C", root] + pre + ["-c", "core.hooksPath=/dev/null"] + list(args),
                       input=inp, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env or git_env())
    if p.returncode not in ok:
        raise Fail(2, "git %s failed: %s" % (args[0], p.stderr.decode("utf-8", "replace").strip()[:400]))
    return p


def lstart_of(pid):
    """A process's start time as bin/jarvis's lstart_of prints it; empty if gone or a zombie."""
    try:
        out = subprocess.run(["ps", "-o", "stat=,lstart=", "-p", str(pid)], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, env=dict(os.environ, TZ="UTC", LC_ALL="C")).stdout.decode()
    except OSError:
        return ""
    f = out.split()
    if len(f) < 6 or f[0].startswith("Z"):
        return ""
    return "_".join(f[1:6])


def group_members(pgid):
    """Live (non-zombie) processes in a process group."""
    try:
        out = subprocess.run(["ps", "-A", "-o", "pid=,pgid=,stat="], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL).stdout.decode()
    except OSError:
        return []
    pids = []
    for line in out.splitlines():
        f = line.split()
        if len(f) >= 3 and f[1] == str(pgid) and not f[2].startswith("Z"):
            pids.append(int(f[0]))
    return pids


def write_atomic(path, text, mode=0o600):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def rec_text(d):
    return "".join("%s: %s\n" % (k, str(v).replace("\n", " ")) for k, v in d.items())


def read_rec(path):
    d = {}
    try:
        with open(path) as f:
            for line in f:
                m = re.match(r"^(\w+): ?(.*)$", line.rstrip("\n"))
                if m:
                    d[m.group(1)] = m.group(2)
    except OSError:
        pass
    return d


# ---------------------------------------------------------------- paths

def path_problem(p):
    """Why a manifest path is unusable, or None. p has had a leading ./ removed."""
    if not p:
        return "empty path"
    if any(ord(c) < 32 or ord(c) == 127 for c in p):
        return "control character in path"
    if p.startswith("/") or p.startswith("~"):
        return "absolute path"
    if p.endswith("/"):
        return "a directory (list each file)"
    if re.search(r"[*?\[]", p):
        return "a glob (list each file)"
    parts = p.split("/")
    if any(x in ("", ".", "..") for x in parts):
        return "not a plain relative path (., .. or //)"
    if any(x.lower() == ".git" for x in parts):
        return "inside .git"
    if p == STATE_DIR or p.startswith(STATE_DIR + "/"):
        return "verifier state (handoffs/.jarvis)"
    return None


def norm(p):
    while p.startswith("./"):
        p = p[2:]
    return p


def ancestors(p):
    parts = p.split("/")
    return ["/".join(parts[:i]) for i in range(1, len(parts))]


def symlinked_ancestor(base, p):
    for a in ancestors(p):
        try:
            st = os.lstat(os.path.join(base, a))
        except FileNotFoundError:
            return None
        if stat.S_ISLNK(st.st_mode):
            return a
        if not stat.S_ISDIR(st.st_mode):
            return None
    return None


# ---------------------------------------------------------------- documents

FENCE = re.compile(r"^( {0,3})(`{3,}|~{3,})(.*)$")


def header_field(text, key):
    m = re.search(r"^%s:[ \t]*(.*)$" % re.escape(key), text, re.M)
    return m.group(1).split()[0] if m and m.group(1).split() else ""


def sections(lines, title):
    """[(start, end)] line ranges of the level-two sections named title, fences respected."""
    out, cur, fence = [], None, None
    for i, line in enumerate(lines):
        m = FENCE.match(line)
        if fence:
            if m and m.group(2)[0] == fence[0] and len(m.group(2)) >= len(fence) and not m.group(3).strip():
                fence = None
            continue
        if m:
            fence = m.group(2)
            continue
        if re.match(r"^## ", line):
            if cur is not None:
                out.append((cur, i))
                cur = None
            if line[3:].strip() == title:
                cur = i + 1
    if fence:
        raise Fail(2, "unclosed ``` fence")
    if cur is not None:
        out.append((cur, len(lines)))
    return out


def parse_checks(text, brief, max_sec):
    lines = text.split("\n")
    try:
        secs = sections(lines, "Checks")
    except Fail as e:
        raise Fail(2, "%s: %s" % (brief, e.msg))
    if len(secs) > 1:
        raise Fail(2, "%s has %d ## Checks sections; keep one" % (brief, len(secs)))
    blocks, inputs = [], None
    if secs:
        a, b = secs[0]
        i = a
        while i < b:
            m = FENCE.match(lines[i])
            if not m:
                i += 1
                continue
            indent, mark, info = m.group(1), m.group(2), m.group(3).strip()
            j = i + 1
            while j < b:
                c = FENCE.match(lines[j])
                if c and c.group(2)[0] == mark[0] and len(c.group(2)) >= len(mark) and not c.group(3).strip():
                    break
                j += 1
            if j >= b:
                raise Fail(2, "%s: unclosed ``` fence in ## Checks (line %d)" % (brief, i + 1))
            body = "\n".join(lines[i + 1:j])
            words = info.split()
            where = "%s line %d" % (brief, i + 1)
            if words[:2] == ["bash", "verify"]:
                if indent:
                    raise Fail(2, "%s: an indented bash verify block; verify blocks start in column 1" % where)
                attrs = {}
                for w in words[2:]:
                    k, eq, v = w.partition("=")
                    if not eq or k not in ("class", "timeout", "reuse"):
                        raise Fail(2, "%s: unknown verify attribute '%s' (class=, timeout=, reuse=)" % (where, w))
                    if k in attrs:
                        raise Fail(2, "%s: %s= given twice" % (where, k))
                    attrs[k] = v
                if "class" not in attrs or "timeout" not in attrs:
                    raise Fail(2, "%s: a verify block needs class=<name> and timeout=<seconds>" % where)
                if not re.match(r"^[a-z0-9_]+$", attrs["class"]):
                    raise Fail(2, "%s: class names are a-z, 0-9 and _, not '%s'" % (where, attrs["class"]))
                if not re.match(r"^[1-9][0-9]*$", attrs["timeout"]):
                    raise Fail(2, "%s: timeout= takes whole seconds above 0, not '%s'" % (where, attrs["timeout"]))
                if int(attrs["timeout"]) > max_sec:
                    raise Fail(2, "%s: timeout=%s is over JARVIS_VERIFY_MAX_SEC=%d" % (where, attrs["timeout"], max_sec))
                if attrs.get("reuse", "tree") not in ("tree", "never"):
                    raise Fail(2, "%s: reuse= takes tree or never" % where)
                if not body.strip():
                    raise Fail(2, "%s: an empty verify block" % where)
                blocks.append({"n": len(blocks) + 1, "line": i + 1, "class": attrs["class"],
                               "timeout": int(attrs["timeout"]), "reuse": attrs.get("reuse", "tree"),
                               "body": body + "\n"})
            elif words[:1] == ["json"] and words[1:] == ["verify-inputs"]:
                if indent:
                    raise Fail(2, "%s: an indented verify-inputs block" % where)
                if inputs is not None:
                    raise Fail(2, "%s: a second verify-inputs block; keep one" % where)
                inputs = parse_inputs(body, where)
            elif "verify" in words or "verify-inputs" in words:
                raise Fail(2, "%s: only ```bash verify``` and ```json verify-inputs``` blocks run, not '%s'" % (where, info))
            i = j + 1
    if not blocks:
        raise Fail(2, "no executable Checks blocks; add a bash verify block to %s\n\n%s" % (brief, CONVERT))
    return blocks, inputs or {"requires": [], "copy": [], "dependencies": []}


def parse_inputs(body, where):
    try:
        d = json.loads(body)
    except ValueError as e:
        raise Fail(2, "%s: verify-inputs isn't valid JSON: %s" % (where, e))
    if not isinstance(d, dict) or set(d) - {"requires", "copy", "dependencies"}:
        raise Fail(2, "%s: verify-inputs is an object with requires, copy and dependencies only" % where)
    out = {"requires": [], "copy": [], "dependencies": []}
    for k in ("requires", "copy"):
        v = d.get(k, [])
        if not isinstance(v, list) or not all(isinstance(x, str) for x in v):
            raise Fail(2, "%s: verify-inputs %s is a list of paths" % (where, k))
        for x in v:
            p = norm(x)
            why = path_problem(p)
            if why:
                raise Fail(2, "%s: verify-inputs %s '%s': %s" % (where, k, x, why))
            if p not in out[k]:
                out[k].append(p)
    deps = d.get("dependencies", [])
    if not isinstance(deps, list):
        raise Fail(2, "%s: verify-inputs dependencies is a list" % where)
    for dep in deps:
        if not isinstance(dep, dict) or set(dep) - {"path", "kind", "lockfiles", "manifests"} \
                or not isinstance(dep.get("path"), str) or not isinstance(dep.get("kind"), str):
            raise Fail(2, "%s: a dependency is {\"path\", \"kind\", \"lockfiles\", \"manifests\"}" % where)
        p = norm(dep["path"].rstrip("/"))
        why = path_problem(p)
        if why:
            raise Fail(2, "%s: dependency '%s': %s" % (where, dep["path"], why))
        files = {}
        for k in ("lockfiles", "manifests"):
            v = dep.get(k, [])
            if not isinstance(v, list) or not all(isinstance(x, str) for x in v):
                raise Fail(2, "%s: dependency %s is a list of paths" % (where, k))
            files[k] = [norm(x) for x in v]
            for x in files[k]:
                if path_problem(x):
                    raise Fail(2, "%s: dependency %s '%s': %s" % (where, k, x, path_problem(x)))
        out["dependencies"].append({"path": p, "kind": dep["kind"], "lockfiles": files["lockfiles"],
                                    "manifests": files["manifests"]})
    return out


def parse_files(text, handoff_rel):
    """The ## Files entries: [(path, action or None)], the handoff's own entry left out."""
    lines = text.split("\n")
    secs = sections(lines, "Files")
    if not secs:
        raise Fail(1, "the handoff has no ## Files section")
    if len(secs) > 1:
        raise Fail(2, "the handoff has %d ## Files sections; keep one" % len(secs))
    a, b = secs[0]
    entries, seen, fence = [], {}, None
    for i in range(a, b):
        line = lines[i]
        m = FENCE.match(line)
        if fence:
            if m and m.group(2)[0] == fence[0] and not m.group(3).strip():
                fence = None
            continue
        if m:
            fence = m.group(2)
            continue
        if re.match(r"^\s+[-*+] ", line):
            raise Fail(2, "## Files line %d: a nested list item; list each file at the top level" % (i + 1))
        if not re.match(r"^[-*+] ", line):
            continue
        item = line[2:].strip()
        if item.startswith("`"):
            end = item.find("`", 1)
            if end < 0:
                raise Fail(2, "## Files line %d: unclosed backtick" % (i + 1))
            path, rest = item[1:end], item[end + 1:]
        else:
            m = re.match(r"^(\S+)(.*)$", item)
            path, rest = (m.group(1), m.group(2)) if m else ("", "")
            if "`" in path:
                raise Fail(2, "## Files line %d: a backtick inside the path; wrap the whole path in backticks" % (i + 1))
        path = norm(path)
        if path.startswith("path/relative"):
            continue
        action = None
        if rest.strip():
            r = re.match(r"^\s+(?:—|–|--|-|:)\s*(.*)$", rest) or re.match(r"^\s+(\(.*)$", rest)
            if not r:
                raise Fail(2, "## Files line %d: can't tell the path from the rest: %s" % (i + 1, line.strip()))
            w = re.match(r"^\(?([A-Za-z]+)", r.group(1))
            if w and w.group(1).lower() in ACTIONS:
                action = w.group(1).lower()
        why = path_problem(path)
        if why:
            raise Fail(2, "## Files line %d: %s: %s" % (i + 1, why, path))
        if path == handoff_rel:
            continue
        if path in seen:
            if seen[path] != action and seen[path] and action:
                raise Fail(2, "## Files lists %s as both %s and %s" % (path, seen[path], action))
            continue
        seen[path] = action
        entries.append([path, action])
    return entries


# ---------------------------------------------------------------- the attempt

class Verify:
    def __init__(self, a):
        self.a = a
        self.root = os.path.realpath(a.root)
        self.attempt = self.results = self.tree = self.admin = None
        self.watchdog = self.wd_w = None
        self.child = None          # (Popen, pgid, start) of the running check
        self.cleaned = False
        self.sig = None
        self.result = {}

    # ---- signals: one cleanup path

    def on_signal(self, signum, frame):
        if self.sig is None:
            self.sig = signum
        if not self.cleaned:
            raise Interrupted()

    def quiet_signals(self):
        for s in SIGCODE:
            signal.signal(s, lambda n, f: setattr(self, "sig", self.sig or n))

    # ---- preflight: nothing written yet

    def preflight(self):
        a = self.a
        hpath = os.path.realpath(a.handoff)
        if not os.path.isfile(hpath):
            raise Fail(2, "no handoff %s" % a.handoff)
        self.handoff_rel = os.path.relpath(hpath, self.root)
        if self.handoff_rel.startswith(".."):
            raise Fail(2, "the handoff isn't inside this checkout")
        self.hbytes = open(hpath, "rb").read()
        try:
            htext = self.hbytes.decode("utf-8")
        except UnicodeDecodeError:
            raise Fail(2, "the handoff isn't UTF-8")
        self.status = header_field(htext, "status")
        if self.status == "blocked":
            raise Fail(2, "status is blocked — answer its questions first; nothing run")
        brief = header_field(htext, "brief")
        if not brief:
            raise Fail(2, "the handoff names no brief: (its brief's ## Checks are what --verify runs)")
        self.brief_rel = norm(brief)
        bpath = os.path.join(self.root, self.brief_rel)
        if path_problem(self.brief_rel):
            raise Fail(2, "brief: %s isn't a path inside this checkout" % brief)
        if not os.path.isfile(bpath) or os.path.islink(bpath):
            raise Fail(2, "brief: %s isn't a file here" % brief)
        self.bbytes = open(bpath, "rb").read()
        try:
            btext = self.bbytes.decode("utf-8")
        except UnicodeDecodeError:
            raise Fail(2, "%s isn't UTF-8" % self.brief_rel)
        self.blocks, self.inputs = parse_checks(btext, self.brief_rel, a.max_sec)

        p = git(self.root, "rev-parse", "--verify", "-q", "HEAD^{commit}", ok=(0, 1))
        if p.returncode:
            raise Fail(2, "HEAD has no commit yet; verify needs one to start from")
        self.head = p.stdout.decode().strip()
        if git(self.root, "ls-files", "-u", "-z").stdout:
            raise Fail(2, "the checkout has unmerged paths; resolve them first")
        self.run = self.pick_run()

        heavy = sorted({b["class"] for b in self.blocks if b["class"] != "light"})
        for c in heavy:
            p = subprocess.run([a.runner, "_verify-class", c], cwd=self.root, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE)
            if p.returncode:
                raise Fail(2, p.stderr.decode("utf-8", "replace").strip() or "lock class %s doesn't resolve" % c)
        self.lock_pl = os.path.join(os.path.dirname(a.runner), "jarvis-lock.pl")
        if heavy and not os.path.isfile(self.lock_pl):
            raise Fail(2, "no %s beside bin/jarvis for the %s lease — re-run jarvis:setup"
                       % (os.path.basename(self.lock_pl), heavy[0]))

        self.entries = parse_files(htext, self.handoff_rel)
        self.classify()
        self.check_inputs()

    def pick_run(self):
        """The newest registered run of the brief, or None (a standalone result)."""
        runs = os.path.join(self.root, STATE_DIR, "runs")
        best = None
        try:
            names = os.listdir(runs)
        except OSError:
            return None
        for n in names:
            if n.startswith(".") or not re.match(r"^[A-Za-z0-9_%.-]+$", n):
                continue
            r = read_rec(os.path.join(runs, n))
            if r.get("brief") != self.brief_rel:
                continue
            sp = int(r.get("spawned", "0")) if r.get("spawned", "0").isdigit() else 0
            if best is None or sp >= best[0]:
                best = (sp, n)
        return best[1] if best else None

    def head_entries(self, paths):
        """{path: (mode, type, oid)} for the paths HEAD has."""
        out = {}
        if not paths:
            return out
        raw = git(self.root, "ls-tree", "-z", "--full-tree", self.head, "--", *paths).stdout
        for rec in raw.split(b"\0"):
            if not rec:
                continue
            meta, _, name = rec.partition(b"\t")
            mode, typ, oid = meta.decode().split()
            out[name.decode("utf-8", "surrogateescape")] = (mode, typ, oid)
        return out

    def changed_set(self):
        raw = git(self.root, "status", "--porcelain=v1", "-z", "-uall").stdout.split(b"\0")
        out, i = set(), 0
        while i < len(raw):
            rec = raw[i]
            i += 1
            if len(rec) < 4:
                continue
            out.add(rec[3:].decode("utf-8", "surrogateescape"))
            if rec[0:1] in (b"R", b"C"):
                if i < len(raw):
                    out.add(raw[i].decode("utf-8", "surrogateescape"))
                i += 1
        return out

    def classify(self):
        paths = [e[0] for e in self.entries]
        anc = sorted({x for p in paths for x in ancestors(p)})
        head = self.head_entries(paths + anc)
        for x in anc:
            if x in head and head[x][0] == "160000":
                raise Fail(2, "%s is a submodule; changes inside one can't be verified" % x)
        changed = self.changed_set()
        listed = set(paths)
        created = []
        bad = []
        for e in self.entries:
            p, action = e
            if p in head and head[p][1] == "tree":
                raise Fail(2, "## Files lists a directory: %s (list each file)" % p)
            if p in head and head[p][0] == "160000":
                raise Fail(2, "## Files lists a submodule: %s (not supported)" % p)
            link = symlinked_ancestor(self.root, p)
            if link:
                raise Fail(2, "## Files: %s is under a symlinked directory (%s)" % (p, link))
            full = os.path.join(self.root, p)
            try:
                st = os.lstat(full)
            except FileNotFoundError:
                st = None
            except NotADirectoryError:
                st = None
            if st is not None and not (stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode)):
                raise Fail(2, "## Files: %s is %s, not a file or a symlink" %
                           (p, "a directory" if stat.S_ISDIR(st.st_mode) else "a special file"))
            in_head, here = p in head, st is not None
            want = action or ("modified" if in_head and here else "created" if here else "deleted" if in_head else None)
            if want is None:
                bad.append("  ✗ listed but not changed: %s (not at HEAD, not here)" % p)
                continue
            if want == "created" and in_head:
                bad.append("  ✗ listed as created, but HEAD has it: %s" % p)
            elif want == "modified" and not in_head:
                bad.append("  ✗ listed as modified, but HEAD doesn't have it: %s" % p)
            elif want in ("created", "modified") and not here:
                bad.append("  ✗ listed as %s, but it isn't here: %s" % (want, p))
            elif want == "deleted" and here:
                bad.append("  ✗ listed as deleted, but it's still here: %s" % p)
            elif want == "deleted" and not in_head:
                bad.append("  ✗ listed as deleted, but HEAD doesn't have it: %s" % p)
            elif p not in changed:
                bad.append("  ✗ listed but not changed: %s" % p)
            e[1] = want
            if want == "created":
                created.append(p)
        if created:
            p = git(self.root, "check-ignore", "-z", "--stdin", inp="".join("./%s\0" % x for x in created).encode(),
                    ok=(0, 1), literal=False)
            ign = [norm(x.decode()) for x in p.stdout.split(b"\0") if x]
            if ign:
                raise Fail(2, "listed source is gitignored; make it commit-eligible or classify it as a "
                              "verification input: %s" % ", ".join(ign[:5]))
        if bad:
            say("\n".join(bad))
            raise Fail(1, "file list doesn't match the checkout — nothing run")
        self.head_info = head
        self.listed = listed
        self.unlisted = sorted(x for x in changed
                               if x not in listed and x != self.handoff_rel and not x.startswith("handoffs/"))

    def check_inputs(self):
        inp = self.inputs
        everything = inp["copy"] + [f for d in inp["dependencies"] for f in d["lockfiles"] + d["manifests"]] \
            + [d["path"] for d in inp["dependencies"]]
        head = self.head_entries(everything)
        changed = self.changed_set()
        for p in inp["copy"]:
            if p in self.listed or p in head:
                raise Fail(2, "verify-inputs copy %s is source (tracked or listed); copy is for untracked inputs" % p)
            if symlinked_ancestor(self.root, p):
                raise Fail(2, "verify-inputs copy %s is under a symlinked directory" % p)
            full = os.path.join(self.root, p)
            if os.path.islink(full):
                raise Fail(2, "verify-inputs copy %s is a symlink; copy takes files" % p)
            if not os.path.isfile(full):
                raise Fail(1, "verification input missing: %s (verify-inputs copy)" % p)
        for d in inp["dependencies"]:
            if d["kind"] == "venv":
                raise Fail(2, "virtualenv requires an isolated setup check; create it in the verification "
                              "worktree (%s)" % d["path"])
            if d["kind"] != "node":
                raise Fail(2, "dependency %s: kind %s isn't supported (node; a venv is built by a setup block)"
                           % (d["path"], d["kind"]))
            if not d["lockfiles"] or not d["manifests"]:
                raise Fail(2, "dependency %s needs its lockfiles and manifests listed" % d["path"])
            if d["path"] in head or d["path"] in self.listed:
                raise Fail(2, "dependency %s is tracked source, not an installed directory" % d["path"])
            for f in d["lockfiles"] + d["manifests"]:
                if f not in head or head[f][1] != "blob":
                    raise Fail(2, "dependency %s: %s isn't tracked at HEAD" % (d["path"], f))
                if f in self.listed or f in changed:
                    raise Fail(2, "dependency %s: %s changed, so the installed copy may not match; install it "
                                  "in an isolated setup block (reuse=never) instead of borrowing it"
                               % (d["path"], f))
            full = os.path.join(self.root, d["path"])
            if os.path.islink(full) or not os.path.isdir(full) or symlinked_ancestor(self.root, d["path"]):
                raise Fail(2, "dependency %s isn't a directory here" % d["path"])

    # ---- side effects start here

    def start(self):
        a = self.a
        key = self.run or ("standalone-" + re.sub(r"[^A-Za-z0-9_.-]", "_",
                                                   os.path.basename(self.handoff_rel))[:80])
        self.attempt_id = "%s-%d-%s" % (time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()), os.getpid(),
                                        os.urandom(3).hex())
        self.vroot = os.path.join(self.root, STATE_DIR, "verify")
        self.keydir = os.path.join(self.vroot, key)
        self.attempt = os.path.join(self.keydir, self.attempt_id)
        self.results = os.path.join(self.root, STATE_DIR, "verify-results", self.attempt_id)
        self.results_rel = os.path.relpath(self.results, self.root)
        for d in (self.vroot, self.keydir, os.path.dirname(self.results)):
            os.makedirs(d, mode=0o700, exist_ok=True)
        os.mkdir(self.attempt, 0o700)
        os.mkdir(self.results, 0o700)
        self.tree = os.path.join(self.attempt, "tree")
        self.owner = {
            "schema": SCHEMA, "root": self.root, "common": self.common_dir(), "head": self.head,
            "tree": self.tree, "attempt": self.attempt_id, "run": self.run or "-",
            "handoff": self.handoff_rel, "brief": self.brief_rel,
            "owner": os.getpid(), "owner_start": lstart_of(os.getpid()),
            "phase": "preparing", "pgid": "", "pgid_start": "", "admin": "",
        }
        self.save_owner()
        self.result = {"status": "running", "attempt": self.attempt_id, "run": self.run or "-",
                       "handoff": self.handoff_rel, "brief": self.brief_rel, "head": self.head,
                       "handoff_status": self.status or "-", "started": int(time.time()),
                       "bash": a.bash, "bash_version": self.bash_version()}
        self.save_result()
        self.start_watchdog()

    def common_dir(self):
        c = git(self.root, "rev-parse", "--git-common-dir").stdout.decode().strip()
        return os.path.realpath(os.path.join(self.root, c))

    def bash_version(self):
        try:
            return subprocess.run([self.a.bash, "-c", "echo $BASH_VERSION"], stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, env={"PATH": os.environ.get("PATH", "")}
                                  ).stdout.decode().strip()
        except OSError:
            raise Fail(2, "can't run %s" % self.a.bash)

    def save_owner(self, **kv):
        self.owner.update(kv)
        write_atomic(os.path.join(self.attempt, "owner"), rec_text(self.owner))

    def save_result(self, **kv):
        self.result.update(kv)
        if self.results and os.path.isdir(self.results):
            write_atomic(os.path.join(self.results, "result"), rec_text(self.result))

    # ---- watchdog: tears the attempt down if this process dies without doing it

    def start_watchdog(self):
        r, w = os.pipe()
        pid = os.fork()
        if pid == 0:
            try:
                os.close(w)
                os.setsid()
                for s in SIGCODE:
                    signal.signal(s, signal.SIG_IGN)
                devnull = os.open(os.devnull, os.O_RDWR)
                os.dup2(devnull, 0)
                os.dup2(devnull, 1)
                data = b""
                while True:
                    chunk = os.read(r, 64)
                    if not chunk:
                        break
                    data += chunk
                if b"done" not in data:
                    self.watchdog = None
                    self.owner = read_rec(os.path.join(self.attempt, "owner")) or self.owner
                    self.stop_group(self.owner.get("pgid"), self.owner.get("pgid_start"), self.a.grace, direct=False)
                    self.remove_attempt()
                    self.save_result(status="interrupted", finished=int(time.time()),
                                     note="the verifier died; its watchdog cleaned up")
            finally:
                os._exit(0)
        os.close(r)
        self.watchdog, self.wd_w = pid, w

    def end_watchdog(self):
        if self.wd_w is not None:
            try:
                os.write(self.wd_w, b"done")
                os.close(self.wd_w)
            except OSError:
                pass
            self.wd_w = None
        if self.watchdog:
            for _ in range(50):
                try:
                    if os.waitpid(self.watchdog, os.WNOHANG)[0]:
                        break
                except ChildProcessError:
                    break
                time.sleep(0.02)
            self.watchdog = None

    # ---- the candidate tree

    def materialize(self):
        g = git(self.root, "worktree", "add", "--detach", "-q", self.tree, self.head, ok=(0, 1, 128))
        if g.returncode:
            raise Fail(2, "git worktree add failed: %s" % g.stderr.decode("utf-8", "replace").strip()[:400])
        dotgit = os.path.join(self.tree, ".git")
        admin = ""
        try:
            with open(dotgit) as f:
                m = re.match(r"^gitdir: (.*)$", f.read().strip())
                admin = os.path.realpath(os.path.join(self.tree, m.group(1))) if m else ""
        except OSError:
            pass
        self.save_owner(phase="tree", admin=admin)
        snap = os.path.join(self.attempt, "snapshot")
        os.mkdir(snap, 0o700)
        self.snaps = []
        for p, action in self.entries:
            if action == "deleted":
                continue
            self.snaps.append(self.snapshot(p, snap, len(self.snaps)))
        for p, action in self.entries:     # deletions first: a file may become a directory
            if action == "deleted":
                full = os.path.join(self.tree, p)
                if os.path.isdir(full) and not os.path.islink(full):
                    raise Fail(2, "%s is a directory in the worktree; can't delete it as a file" % p)
                if os.path.lexists(full):
                    os.unlink(full)
                self.prune_empty(os.path.dirname(p))
        for s in self.snaps:
            self.place(s)
        self.copies = {}
        for p in self.inputs["copy"]:
            data, mode, _ = self.read_stable(os.path.join(self.root, p), p)
            dest = self.dest(p)
            if os.path.lexists(dest):
                raise Fail(2, "verify-inputs copy %s would replace a file in the candidate" % p)
            with open(dest, "wb") as f:
                f.write(data)
            os.chmod(dest, mode & 0o777)
            self.copies[p] = sha(data)
        self.dep_digests = {}
        for d in self.inputs["dependencies"]:
            self.dep_digests[d["path"]] = self.copy_dependency(d)
        self.controls()
        self.tree_id = self.write_tree()
        self.save_result(tree=self.tree_id, sources=len(self.entries),
                         inputs=len(self.inputs["copy"]) + len(self.inputs["requires"]),
                         dependencies=len(self.inputs["dependencies"]))

    def read_stable(self, full, p):
        for _ in range(2):
            try:
                st1 = os.lstat(full)
                if stat.S_ISLNK(st1.st_mode):
                    data = os.fsencode(os.readlink(full))
                else:
                    fd = os.open(full, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
                    with os.fdopen(fd, "rb") as f:
                        data = f.read()
                st2 = os.lstat(full)
            except OSError as e:
                raise Fail(75, "inputs changed during verification; rerun (%s: %s)" % (p, e.strerror))
            same = (st1.st_ino, st1.st_size, st1.st_mtime_ns, st1.st_mode) == \
                   (st2.st_ino, st2.st_size, st2.st_mtime_ns, st2.st_mode)
            if same and (stat.S_ISLNK(st1.st_mode) or len(data) == st1.st_size):
                return data, st1.st_mode, stat.S_ISLNK(st1.st_mode)
            time.sleep(0.05)
        raise Fail(75, "inputs changed during verification; rerun (%s kept changing while read)" % p)

    def snapshot(self, p, snapdir, n):
        data, mode, link = self.read_stable(os.path.join(self.root, p), p)
        f = os.path.join(snapdir, str(n))
        with open(f, "wb") as out:
            out.write(data)
        gmode = "120000" if link else ("100755" if mode & 0o111 else "100644")
        return {"path": p, "file": f, "mode": gmode, "perm": mode & 0o777, "link": link, "sha": sha(data),
                "target": data if link else None}

    def dest(self, p):
        """A path in the tree, its parent directories real directories inside it."""
        cur = self.tree
        for part in p.split("/")[:-1]:
            cur = os.path.join(cur, part)
            try:
                st = os.lstat(cur)
            except FileNotFoundError:
                os.mkdir(cur)
                continue
            if not stat.S_ISDIR(st.st_mode):
                raise Fail(2, "%s: %s in the candidate is %s, not a directory" %
                           (p, os.path.relpath(cur, self.tree), "a symlink" if stat.S_ISLNK(st.st_mode) else "a file"))
        return os.path.join(self.tree, p)

    def place(self, s):
        dest = self.dest(s["path"])
        if os.path.lexists(dest):
            if os.path.isdir(dest) and not os.path.islink(dest):
                raise Fail(2, "%s is a directory in the candidate" % s["path"])
            os.unlink(dest)
        if s["link"]:
            target = os.fsdecode(s["target"])
            if target.startswith("/"):
                raise Fail(2, "## Files: %s is a symlink to an absolute path; only relative links inside the "
                              "checkout are verified" % s["path"])
            os.symlink(target, dest)
            tree = os.path.realpath(self.tree)
            real = os.path.realpath(dest)
            if real != tree and not real.startswith(tree + os.sep):
                raise Fail(2, "## Files: %s is a symlink that leaves the checkout" % s["path"])
        else:
            shutil.copyfile(s["file"], dest)
            os.chmod(dest, s["perm"])

    def prune_empty(self, d):
        while d:
            full = os.path.join(self.tree, d)
            try:
                if os.path.islink(full) or os.listdir(full):
                    return
                os.rmdir(full)
            except OSError:
                return
            d = os.path.dirname(d)

    def dep_manifest(self, base):
        """A digest of a dependency directory: path, kind, mode, bytes or link target of everything in it."""
        h = hashlib.sha256()
        rbase = os.path.realpath(base)
        for dirpath, dirs, files in os.walk(base, followlinks=False):
            dirs.sort()
            rel = os.path.relpath(dirpath, base)
            for name in sorted(files + [x for x in dirs if os.path.islink(os.path.join(dirpath, x))]):
                full = os.path.join(dirpath, name)
                st = os.lstat(full)
                rp = os.path.normpath(os.path.join(rel, name))
                if stat.S_ISLNK(st.st_mode):
                    t = os.readlink(full)
                    real = os.path.realpath(full)
                    if t.startswith("/") or (real != rbase and not real.startswith(rbase + os.sep)):
                        raise Fail(2, "dependency %s: %s links outside it (%s); install it in a setup block "
                                      "instead" % (os.path.relpath(base, self.root), rp, t))
                    h.update(b"L\0" + os.fsencode(rp) + b"\0" + os.fsencode(t) + b"\0")
                elif stat.S_ISREG(st.st_mode):
                    with open(full, "rb") as f:
                        h.update(b"F\0" + os.fsencode(rp) + b"\0" + oct(st.st_mode & 0o777).encode()
                                 + b"\0" + hashlib.sha256(f.read()).digest())
                else:
                    raise Fail(2, "dependency %s: %s is a special file" % (os.path.relpath(base, self.root), rp))
            dirs[:] = [x for x in dirs if not os.path.islink(os.path.join(dirpath, x))]
        return h.hexdigest()

    def copy_dependency(self, d):
        src = os.path.join(self.root, d["path"])
        dest = self.dest(d["path"])
        if os.path.lexists(dest):
            raise Fail(2, "dependency %s already exists in the candidate" % d["path"])
        for attempt in (1, 2):
            before = self.dep_manifest(src)

            def ignore_nothing(dirpath, names):
                return []
            shutil.copytree(src, dest, symlinks=True, ignore=ignore_nothing, copy_function=shutil.copyfile)
            for dirpath, dirs, files in os.walk(src, followlinks=False):  # copyfile drops modes; set them
                for name in files:
                    full = os.path.join(dirpath, name)
                    if not os.path.islink(full):
                        os.chmod(os.path.join(dest, os.path.relpath(full, src)), os.lstat(full).st_mode & 0o777)
            if self.dep_manifest(src) == before == self.dep_manifest(dest):
                return before
            shutil.rmtree(dest)
        raise Fail(2, "dependency %s kept changing while it was copied; rerun when nothing installs into it"
                   % d["path"])

    def controls(self):
        ctl = os.path.join(self.attempt, "control")
        os.mkdir(ctl, 0o700)
        self.ctl_runner = os.path.join(ctl, "jarvis")
        shutil.copyfile(self.a.runner, self.ctl_runner)
        os.chmod(self.ctl_runner, 0o700)
        if os.path.isfile(self.lock_pl):
            shutil.copyfile(self.lock_pl, os.path.join(ctl, "jarvis-lock.pl"))
            os.chmod(os.path.join(ctl, "jarvis-lock.pl"), 0o700)
        shim = os.path.join(self.tree, "handoffs/bin/jarvis")
        if os.path.lexists(shim):
            real = os.path.realpath(shim)
            try:
                data = open(real, "rb").read() if os.path.isfile(real) else b""
            except OSError:
                data = b""
            if b"JARVIS_VERIFY_CONTEXT" not in data:
                raise Fail(2, "handoffs/bin/jarvis in the candidate predates verification contexts, so a "
                              "`jarvis lock` in a check would lease the worktree instead of this checkout; "
                              "upgrade it (jarvis:setup) first")
            self.shim = None
            return
        self.dest("handoffs/bin/jarvis")
        text = ("#!/bin/sh\n# jarvis merge --verify: lock and resources only, through the verifier's own copy\n"
                "case \"${1:-}\" in\n  lock) shift; exec %s _verify-lock \"$@\" ;;\n"
                "  resources) exec %s \"$@\" ;;\n"
                "  *) echo \"jarvis: only lock and resources work in a verification worktree, not '${1:-}'\" >&2; "
                "exit 2 ;;\nesac\n") % (shq(self.ctl_runner), shq(self.ctl_runner))
        with open(shim, "w") as f:
            f.write(text)
        os.chmod(shim, 0o755)
        self.shim = sha(text.encode())

    def write_tree(self):
        """The tree object of HEAD plus the listed changes, through a private index."""
        env = git_env()
        env["GIT_INDEX_FILE"] = os.path.join(self.attempt, "index")
        git(self.root, "read-tree", self.head, env=env)
        info = []
        if self.snaps:
            oids = git(self.root, "hash-object", "-w", "--no-filters", "--stdin-paths",
                       inp="".join(s["file"] + "\n" for s in self.snaps).encode(), env=env).stdout.decode().split()
            for s, oid in zip(self.snaps, oids):
                info.append("%s %s\t%s" % (s["mode"], oid, s["path"]))
        zero = "0" * len(self.head)
        for p, action in self.entries:
            if action == "deleted":
                info.append("0 %s\t%s" % (zero, p))
        if info:
            git(self.root, "update-index", "-z", "--index-info", inp=("\0".join(info) + "\0").encode(), env=env)
        return git(self.root, "write-tree", env=env).stdout.decode().strip()

    # ---- checks

    def requires(self):
        for p in self.inputs["requires"]:
            if os.path.lexists(os.path.join(self.tree, p)):
                continue
            if os.path.lexists(os.path.join(self.root, p)):
                raise Fail(1, "depends on an unlisted file: %s (required by Checks); add the source change to "
                              "## Files or declare a non-source verification input" % p)
            raise Fail(1, "required input missing: %s" % p)

    def check_env(self):
        env = {k: v for k, v in os.environ.items() if k not in SCRUB}
        env["PWD"] = self.tree
        env["JARVIS_VERIFY_CONTEXT"] = os.path.join(self.attempt, "owner")
        return env

    def run_checks(self):
        cdir = os.path.join(self.attempt, "checks")
        os.mkdir(cdir, 0o700)
        n = len(self.blocks)
        env = self.check_env()
        for b in self.blocks:
            script = os.path.join(cdir, "block-%d.sh" % b["n"])
            with open(script, "w", encoding="utf-8", newline="") as f:
                f.write(b["body"])
            marker = os.path.join(cdir, "started-%d" % b["n"])
            argv = [self.a.bash, "--noprofile", "--norc", "-c", ': > "$1"; shift; exec "$@"', "jarvis-verify",
                    marker, self.a.bash, "--noprofile", "--norc", "-e", "-o", "pipefail", script]
            if b["class"] != "light":
                argv = [self.ctl_runner, "_verify-lock", b["class"], "--"] + argv
            log = os.path.join(self.results, "check-%d.log" % b["n"])
            label = "  check %d/%d · %s · %ds" % (b["n"], n, b["class"], b["timeout"])
            t0 = time.time()
            code, how, ran = self.supervise(argv, env, log, marker, b)
            took = int(time.time() - t0)
            self.save_result(check=b["n"])
            if how == "ok" and code == 0:
                say("%s · passed (%ds)" % (label, ran))
                continue
            if how == "queue":
                say("%s · lease wait ran out (exit %d)" % (label, code))
                self.show_tail(log)
                raise Fail(75, "the %s lease wait ran out before check %d/%d started (JARVIS_LOCK_WAIT); "
                               "rerun later" % (b["class"], b["n"], n), )
            if how == "nolease":
                say("%s · the lease wrapper failed (exit %d)" % (label, code))
                self.show_tail(log)
                raise Fail(2, "check %d/%d: `jarvis lock %s` failed before the check started" % (b["n"], n, b["class"]))
            if how == "timeout":
                say("%s · TIMED OUT after %ds; its process group was stopped" % (label, b["timeout"]))
                self.show_tail(log)
                self.save_result(child_exit="-")
                raise Fail(124, "check %d/%d timed out after %ds (timeout=%d)" % (b["n"], n, took, b["timeout"]))
            say("%s · FAILED (exit %d, %ds) — last %d lines:" % (label, code, ran, TAIL))
            tail = self.show_tail(log)
            self.save_result(child_exit=code)
            self.dependency_hints(tail)
            raise Fail(1, "check %d/%d failed (exit %d)" % (b["n"], n, code))

    def supervise(self, argv, env, log, marker, b):
        """(exit code, ok | timeout | queue | nolease, seconds run) of one check in its own process group."""
        with open(log, "wb") as out:
            p = subprocess.Popen(argv, cwd=self.tree, env=env, stdin=subprocess.DEVNULL, stdout=out,
                                 stderr=subprocess.STDOUT, start_new_session=True)
        self.child = (p, p.pid)
        self.save_owner(phase="check %d" % b["n"], pgid=p.pid, pgid_start=lstart_of(p.pid))
        started = None
        queue_limit = time.time() + self.a.lock_wait + 30
        while True:
            if WAITID:   # see it exit without reaping it, so its group ID stays ours
                done = os.waitid(os.P_PID, p.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None
            else:
                done = p.poll() is not None
            if started is None and os.path.exists(marker):
                started = time.time()
            if done:
                break
            now = time.time()
            if started is not None and now - started >= b["timeout"]:
                self.stop_group(p.pid, None, self.a.grace)
                self.reap()
                return None, "timeout", int(now - started)
            if started is None and now > queue_limit:
                self.stop_group(p.pid, None, self.a.grace)
                self.reap()
                return 75, "queue", 0
            time.sleep(0.05)
        if started is None and os.path.exists(marker):
            started = time.time()
        ran = int(time.time() - started) if started else 0
        # the check is over: whatever it left running in its group goes with it
        left = group_members(p.pid)
        if left:
            self.stop_group(p.pid, None, self.a.grace)
            say("  (stopped %d process%s check %d left running)" % (len(left), "" if len(left) == 1 else "es", b["n"]))
        code = self.reap()
        if started is None and b["class"] != "light":
            return code, ("queue" if code == 75 else "nolease"), 0
        return code, "ok", ran

    def reap(self):
        if not self.child:
            return None
        p = self.child[0]
        p.wait()
        self.child = None
        self.save_owner(phase="between checks", pgid="", pgid_start="")
        rc = p.returncode
        return 128 - rc if rc < 0 else rc

    def stop_group(self, pgid, start, grace, direct=True):
        """TERM, then KILL after grace, a check's process group, and only while it is still ours:
        our unreaped child (direct), or a leader whose start time still matches."""
        if not pgid:
            return
        pgid = int(pgid)
        if not direct:
            leader = lstart_of(pgid)
            if leader and start and leader != start:
                return                    # the PID is someone else's now
            if not leader and not group_members(pgid):
                return
        for sig, wait in ((signal.SIGTERM, grace), (signal.SIGKILL, 2)):
            if not group_members(pgid):   # a group with live members still has its ID: it is the one we started
                return
            try:
                os.killpg(pgid, sig)
            except (ProcessLookupError, PermissionError):
                return
            end = time.time() + wait
            while time.time() < end:
                if not group_members(pgid):
                    return
                time.sleep(0.05)

    def show_tail(self, log):
        try:
            with open(log, "rb") as f:
                lines = f.read().decode("utf-8", "replace").splitlines()
        except OSError:
            lines = []
        tail = lines[-TAIL:]
        for line in tail:
            say("    " + line[:400])
        say("  full log: %s" % os.path.relpath(log, self.root))
        return "\n".join(tail)

    def dependency_hints(self, tail):
        hints = [p for p in self.unlisted[:200]
                 if p in tail and not os.path.lexists(os.path.join(self.tree, p))
                 and os.path.lexists(os.path.join(self.root, p))]
        for p in hints[:12]:
            say("  possible dependency on an unlisted file: %s" % p)
        rest = [p for p in self.unlisted if p not in hints]
        if rest:
            say("  changed here but not listed (possible dependencies, not proven causes): %s%s"
                % (", ".join(rest[:12]), " …" if len(rest) > 12 else ""))

    # ---- after the checks

    def recheck(self):
        p = git(self.root, "rev-parse", "--verify", "-q", "HEAD^{commit}", ok=(0, 1))
        moved = []
        if p.stdout.decode().strip() != self.head:
            moved.append("HEAD")

        def digest(rel):
            full = os.path.join(self.root, rel)
            try:
                if os.path.islink(full):
                    return sha(os.fsencode(os.readlink(full)))
                with open(full, "rb") as f:
                    return sha(f.read())
            except OSError:
                return None
        for s in self.snaps:
            if digest(s["path"]) != s["sha"]:
                moved.append(s["path"])
        for q, action in self.entries:
            if action == "deleted" and os.path.lexists(os.path.join(self.root, q)):
                moved.append(q)
        if digest(self.brief_rel) != sha(self.bbytes):
            moved.append(self.brief_rel)
        if digest(self.handoff_rel) != sha(self.hbytes):
            moved.append(self.handoff_rel)
        for q, h in self.copies.items():
            if digest(q) != h:
                moved.append(q)
        for q, h in self.dep_digests.items():
            try:
                if self.dep_manifest(os.path.join(self.root, q)) != h:
                    moved.append(q + "/")
            except Fail:
                moved.append(q + "/")
        if moved:
            raise Fail(75, "inputs changed during verification; rerun (%s)" % ", ".join(moved[:8]))

    # ---- cleanup: the one path out

    def remove_attempt(self):
        """Remove the worktree and the attempt directory; True when nothing is left."""
        if not self.attempt:
            return True
        ok = True
        tree = self.tree
        if tree and os.path.lexists(tree):
            git(self.root, "worktree", "remove", "--force", "--force", tree, ok=(0, 1, 128))
        if tree and os.path.lexists(tree):
            shutil.rmtree(tree, ignore_errors=True)
        admin = self.owner.get("admin", "")
        if admin and os.path.isdir(admin):
            # only the exact entry, and only while it still points back at our tree
            try:
                back = open(os.path.join(admin, "gitdir")).read().strip()
            except OSError:
                back = ""
            if os.path.realpath(back) == os.path.realpath(os.path.join(tree, ".git")) or \
                    back == os.path.join(tree, ".git"):
                shutil.rmtree(admin, ignore_errors=True)
        if os.path.lexists(self.attempt):
            shutil.rmtree(self.attempt, ignore_errors=True)
        for d in (getattr(self, "keydir", None), getattr(self, "vroot", None)):
            try:
                if d:
                    os.rmdir(d)
            except OSError:
                pass
        if os.path.lexists(self.attempt) or (tree and os.path.lexists(tree)) or (admin and os.path.isdir(admin)):
            ok = False
        return ok

    def cleanup(self):
        if self.cleaned:
            return True
        self.quiet_signals()
        if self.child:
            self.stop_group(self.child[1], None, self.a.grace)
            self.reap()
        ok = self.remove_attempt()
        self.cleaned = True
        self.end_watchdog()
        return ok


def shq(s):
    return "'" + s.replace("'", "'\\''") + "'"


def main():
    ap = argparse.ArgumentParser(prog="jarvis-verify.py")
    ap.add_argument("op", choices=["run"])
    ap.add_argument("--root", required=True)
    ap.add_argument("--handoff", required=True)
    ap.add_argument("--runner", required=True)
    ap.add_argument("--bash", required=True)
    ap.add_argument("--max-sec", type=int, default=7200)
    ap.add_argument("--lock-wait", type=int, default=3600)
    ap.add_argument("--grace", type=int, default=10)
    a = ap.parse_args()
    v = Verify(a)
    for s in SIGCODE:
        signal.signal(s, v.on_signal)
    code, msg = 0, ""
    try:
        v.preflight()
        v.start()
        v.materialize()
        v.requires()
        say("verify: HEAD %s · %d listed change%s · %d input%s · %d dependenc%s · %s" % (
            v.head[:7], len(v.entries), "" if len(v.entries) == 1 else "s",
            len(v.inputs["copy"]) + len(v.inputs["requires"]),
            "" if len(v.inputs["copy"]) + len(v.inputs["requires"]) == 1 else "s",
            len(v.inputs["dependencies"]), "y" if len(v.inputs["dependencies"]) == 1 else "ies",
            "run " + v.run if v.run else "no run record; result stored separately"))
        v.run_checks()
        v.recheck()
    except Fail as e:
        code, msg = e.code, e.msg
    except Interrupted:
        code = SIGCODE.get(v.sig, 130)
        msg = "interrupted (%s); the check's processes were stopped" % signal.Signals(v.sig).name
    except Exception as e:  # a bug or an OS error: still clean up
        code, msg = 2, "verification error: %s: %s" % (type(e).__name__, e)
    clean = v.cleanup()
    if v.sig is not None and code not in SIGCODE.values():
        code = SIGCODE.get(v.sig, 130)
        msg = "interrupted (%s) during cleanup" % signal.Signals(v.sig).name
    if not clean:
        say("verify: cleanup FAILED; left behind: %s" % os.path.relpath(v.attempt, v.root))
        if code in (0, 1, 75, 124):
            code, msg = 2, msg or "cleanup failed"
    status = {0: "passed", 1: "failed", 124: "timeout", 75: "error"}.get(code, "interrupted" if code in SIGCODE.values() else "error")
    if v.results and os.path.isdir(v.results):
        v.save_result(status=status, exit=code, finished=int(time.time()), cleanup="ok" if clean else "failed",
                      message=msg.split("\n")[0])
    where = (" · " + v.results_rel) if v.results else ""
    if code == 0:
        say("verify: passed %d/%d checks at HEAD %s · tree %s · isolated listed changes%s" % (
            len(v.blocks), len(v.blocks), v.head[:7], v.tree_id[:7], where))
        if v.status == "partial":
            say("  the handoff says partial: checked, not done")
        say("  ## Checks prose outside the verify blocks isn't run: that review is still yours")
    else:
        print("verify: %s%s" % (msg, where if v.results else ""), file=sys.stdout if code in (1, 124, 75) else sys.stderr,
              flush=True)
    sys.exit(code)


if __name__ == "__main__":
    main()
