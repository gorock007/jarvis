#!/usr/bin/env python3
"""jarvis-verify.py: the engine behind `jarvis merge <handoff> --check --verify`.
bin/jarvis prints the usual review summary, then execs this with `python3 -I`;
nothing else should call it.

  jarvis-verify.py run --root <checkout> --handoff <file> --runner <bin/jarvis>
                       --bash <path> [--max-sec N] [--lock-wait N] [--grace N]
                       [--reuse=0|1] [--max-age N] [--reuse-env "NAMES"] [--lock-dir DIR]
  jarvis-verify.py doctor --root <checkout> --runner <bin/jarvis> [--lock-dir DIR] [--grace N]
                          [--apply | --quiet]      `jarvis doctor`'s verification worktrees

It runs the brief's ```bash verify``` blocks under ## Checks against HEAD plus
exactly the handoff's listed changes, in a detached worktree of its own:

  handoffs/.jarvis/verify/<run | standalone-…>/<attempt>/   0700, removed at the end
      owner      ownership manifest, written before `git worktree add`: checkout, git
                 common dir, tree, PID and start time of the verifier, its watchdog and
                 the running check's group, the lease; also the context a nested
                 `jarvis lock` reads (JARVIS_VERIFY_CONTEXT)
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

One attempt at a time per checkout: the internal `verify` lease (checkout 1, the
slot format of jarvis-lock.pl, so `jarvis resources` shows it). Each attempt's
verify_key is a SHA-256 over HEAD, the candidate tree, the checked-out bytes, the
listed changes, the brief without started:, the blocks, inputs, dependencies, the
runner/helper/shim bytes, lock settings, bash, OS and an environment digest. With
--reuse, a pass is reported instead of re-run only when the newest finished attempt
with that key, for the same run (or standalone handoff), passed and cleaned up,
under --max-age seconds ago, and no block says reuse=never. The selected run record
gets verify_* keys through `bin/jarvis _run-set`, under that record's write lock.

Exit 0 passed · 1 file list mismatch, missing input or a failed check · 2 bad
brief/handoff/config or setup/cleanup failure · 75 lease wait ran out or the
inputs moved · 124 a check timed out · 129/130/143 HUP/INT/TERM.
Python 3.8+, standard library only.
"""
import argparse, fcntl, hashlib, json, os, re, shutil, signal, stat, subprocess, sys, time

SCHEMA = "jarvis-verify-1"
KEY_SCHEMA = "jarvis-verify-key-1"
SKEW = 60                  # a result stamped further in the future than this is never reused
ENDED_SLACK = 5            # seconds a result's ended_ns may differ from its finished
# environment values that count toward a verify_key, with $JARVIS_REUSE_ENV and every LC_*;
# only their digest is kept
KEY_ENV = ("PATH", "HOME", "SHELL", "LANG", "TZ", "CI", "NODE_ENV", "NODE_OPTIONS", "PYTHONHASHSEED",
           "PYTHONUTF8", "PYTHONDONTWRITEBYTECODE", "PERL5LIB", "PERL5OPT", "RUBYOPT", "RUBYLIB", "GEM_HOME",
           "GEM_PATH", "JAVA_HOME", "CLASSPATH", "GOPATH", "GOFLAGS", "CARGO_HOME", "RUSTUP_TOOLCHAIN",
           "LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH")
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


def stop_group(pgid, start, grace, direct=True):
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


def backlink_ok(admin, tree):
    """Whether a git worktree admin entry still points back at this tree."""
    try:
        back = open(os.path.join(admin, "gitdir")).read().strip()
    except OSError:
        return False
    return os.path.realpath(back) == os.path.realpath(os.path.join(tree, ".git")) or back == os.path.join(tree, ".git")


def remove_attempt(root, attempt, tree, admin, parents=()):
    """Remove an attempt's worktree (only that exact registered entry, and only while it still points
    back at the tree) and its directory, then the empty parents; True when nothing is left."""
    if tree and os.path.lexists(tree):
        git(root, "worktree", "remove", "--force", "--force", tree, ok=(0, 1, 128))
    if tree and os.path.lexists(tree):
        shutil.rmtree(tree, ignore_errors=True)
    if admin and os.path.isdir(admin) and backlink_ok(admin, tree):
        shutil.rmtree(admin, ignore_errors=True)
    if os.path.lexists(attempt):
        shutil.rmtree(attempt, ignore_errors=True)
    for d in parents:
        try:
            if d:
                os.rmdir(d)
        except OSError:
            pass
    return not (os.path.lexists(attempt) or (tree and os.path.lexists(tree)) or (admin and os.path.isdir(admin)))


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
        self.run = self.lease = self.lease_path = self.key = self.reused = None
        self.class_specs = {}

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

        if self.run and not shutil.which("perl"):
            raise Fail(2, "no perl on PATH, so run %s's record can't be updated under its lock (nothing run)" % self.run)
        heavy = sorted({b["class"] for b in self.blocks if b["class"] != "light"})
        self.class_specs = {}
        for c in heavy:
            p = subprocess.run([a.runner, "_verify-class", c], cwd=self.root, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE)
            if p.returncode:
                raise Fail(2, p.stderr.decode("utf-8", "replace").strip() or "lock class %s doesn't resolve" % c)
            self.class_specs[c] = p.stdout.decode("utf-8", "replace").strip()
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

    def take_lease(self):
        """The checkout's verify lease, held until this process (and its watchdog) exits."""
        d = self.a.lock_dir
        os.makedirs(d, 0o700, exist_ok=True)
        slot = lease_slot(d, self.root)
        where = slot[:-len(".slot0")] + ".where"
        try:
            cur = open(where).read()
        except OSError:
            cur = ""
        if cur != self.root + "\n":
            write_atomic(where, self.root + "\n")
        fd = os.open(slot, os.O_RDWR | os.O_CREAT, 0o600)
        deadline, told = time.time() + self.a.lock_wait, False
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                pass
            if time.time() >= deadline:
                os.close(fd)
                raise Fail(75, "another verification of this checkout held the verify lease for %ds "
                               "(JARVIS_LOCK_WAIT); rerun later" % self.a.lock_wait)
            if not told:
                h = read_rec(slot)
                say("verify: waiting — another verification of this checkout is running%s" %
                    (" (pid %s)" % h["pid"] if h.get("pid") else ""))
                told = True
            time.sleep(0.1)
        rec = {"pid": os.getpid(), "start": int(time.time()), "cmd": "jarvis merge %s --check --verify" % self.handoff_rel,
               "cwd": self.root, "root": self.root,
               "term": os.environ.get("SUPERSET_TERMINAL_ID") or os.environ.get("TMUX_PANE")
               or os.environ.get("ULTRON_SESSION_ID") or "",
               "session": os.environ.get("CLAUDE_CODE_SESSION_ID", ""), "wrapper": os.getpid()}
        os.ftruncate(fd, 0)
        os.lseek(fd, 0, 0)
        os.write(fd, rec_text(rec).encode())
        self.lease, self.lease_path = fd, slot

    def record(self, final, kv):
        """Write verify_* keys to the run record through bin/jarvis _run-set, under its lock; a final
        write only while the record still names this attempt. 0 written, 3 a newer attempt's, else failed."""
        if not self.run:
            return 0
        argv = [self.a.runner, "_run-set"] + (["--if", "verify_attempt", self.attempt_id] if final else []) + [self.run]
        for k, v in kv:
            argv += [k, str(v)]
        env = {k: v for k, v in os.environ.items() if k != "JARVIS_VERIFY_CONTEXT"}
        try:
            return subprocess.run(argv, cwd=self.root, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL).returncode
        except OSError:
            return 2

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
            "watchdog": "", "watchdog_start": "", "lease": self.lease_path,
        }
        self.save_owner()
        self.result = {"status": "running", "attempt": self.attempt_id, "run": self.run or "-",
                       "handoff": self.handoff_rel, "brief": self.brief_rel, "head": self.head,
                       "handoff_status": self.status or "-", "started": int(time.time()),
                       "bash": a.bash, "bash_version": self.bash_version(),
                       "owner": os.getpid(), "owner_start": self.owner["owner_start"]}
        self.save_result()
        self.start_watchdog()
        self.save_owner(watchdog=self.watchdog, watchdog_start=lstart_of(self.watchdog))
        if self.record(False, [("verify_status", "running"), ("verify_attempt", self.attempt_id),
                               ("verify_head", self.head), ("verify_started", self.result["started"]),
                               ("verify_finished", ""), ("verify_exit", ""), ("verify_check", ""),
                               ("verify_tree", ""), ("verify_key", ""), ("verify_reused", "0"),
                               ("verify_log", self.results_rel)]):
            raise Fail(2, "can't write verify_status to run %s's record (handoffs/.jarvis/runs/%s)" % (self.run, self.run))

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
                    self.save_result(status="interrupted", finished=int(time.time()), ended_ns=time.time_ns(),
                                     note="the verifier died; its watchdog cleaned up")
                    self.record(True, [("verify_status", "interrupted"), ("verify_finished", int(time.time()))])
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
        self.baseline = self.baseline_digest()
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
        for s in self.snaps:   # again with everything placed: a link may leave through one placed after it
            if s["link"]:
                self.link_inside(s["path"])
        self.controls()
        self.tree_id = self.write_tree()
        self.key = self.verify_key()
        self.save_result(tree=self.tree_id, key=self.key, sources=len(self.entries),
                         inputs=len(self.inputs["copy"]) + len(self.inputs["requires"]),
                         dependencies=len(self.inputs["dependencies"]))

    def baseline_digest(self):
        """The candidate's bytes as checked out (checkout filters and line endings included), before
        inputs, dependencies and controls go in."""
        h = hashlib.sha256()
        for dirpath, dirs, files in os.walk(self.tree, followlinks=False):
            rel = os.path.relpath(dirpath, self.tree)
            if rel == ".":
                dirs[:] = [x for x in dirs if x != ".git"]
                files = [x for x in files if x != ".git"]
            dirs.sort()
            for name in sorted(files + [x for x in dirs if os.path.islink(os.path.join(dirpath, x))]):
                full = os.path.join(dirpath, name)
                rp = os.fsencode(os.path.normpath(os.path.join(rel, name)))
                st = os.lstat(full)
                if stat.S_ISLNK(st.st_mode):
                    h.update(b"L\0" + rp + b"\0" + os.fsencode(os.readlink(full)) + b"\0")
                elif stat.S_ISREG(st.st_mode):
                    with open(full, "rb") as f:
                        h.update(b"F\0" + rp + b"\0" + oct(st.st_mode & 0o777).encode() + b"\0"
                                 + hashlib.sha256(f.read()).digest())
            dirs[:] = [x for x in dirs if not os.path.islink(os.path.join(dirpath, x))]
        return h.hexdigest()

    def verify_key(self):
        a = self.a

        def fsha(path):
            try:
                with open(path, "rb") as f:
                    return sha(f.read())
            except OSError:
                return None
        env = self.check_env()
        names = sorted(set(a.reuse_env.split()) | set(KEY_ENV) | {k for k in env if k.startswith("LC_")})
        u = os.uname()
        m = {
            "schema": KEY_SCHEMA, "head": self.head, "tree": self.tree_id, "baseline": self.baseline,
            "sources": [[s["path"], s["mode"], s["sha"]] for s in self.snaps],
            "actions": [[p, act] for p, act in self.entries],
            "brief": sha(b"".join(x for x in self.bbytes.splitlines(True) if not x.startswith(b"started:"))),
            "blocks": [[b["n"], b["class"], b["timeout"], b["reuse"], b["body"]] for b in self.blocks],
            "inputs": self.inputs, "copies": self.copies, "dependencies": self.dep_digests,
            "runner": fsha(a.runner), "helper": fsha(os.path.abspath(__file__)), "lock_helper": fsha(self.lock_pl),
            "shim": self.shim, "classes": self.class_specs, "lock_wait": a.lock_wait, "grace": a.grace,
            "bash": [os.path.realpath(a.bash), self.result.get("bash_version", "")],
            "os": [u.sysname, u.release, u.machine], "cwd": ".",
            "env": sha(json.dumps([[n, env.get(n)] for n in names]).encode()), "env_policy": ["scrub-1"] + list(SCRUB),
        }
        return sha(json.dumps(m, sort_keys=True, separators=(",", ":")).encode())

    def find_pass(self):
        """(attempt id, its result) of a reusable pass of this exact candidate, or (None, why not)."""
        a = self.a
        if a.max_age <= 0:
            return None, "JARVIS_REUSE_MAX_AGE=0"
        never = [b["n"] for b in self.blocks if b["reuse"] == "never"]
        if never:
            return None, "check %d says reuse=never" % never[0]
        base = os.path.join(self.root, STATE_DIR, "verify-results")
        now = time.time()
        newest = None
        for n in sorted(os.listdir(base)):
            if n == self.attempt_id:
                continue
            r = read_rec(os.path.join(base, n, "result"))
            if r.get("key") != self.key or r.get("status") == "reused":
                continue
            if r.get("run") != (self.run or "-") or (not self.run and r.get("handoff") != self.handoff_rel):
                continue
            stamps = [int(r[k]) for k in ("started", "finished") if r.get(k, "").isdigit()]
            if not stamps or max(stamps) > now + SKEW:
                return None, "attempt %s has no time or one in the future" % n
            fin, ens = r.get("finished", ""), r.get("ended_ns", "")
            if fin or ens:   # written together; ended_ns orders attempts, so it is checked like the rest
                if not (fin.isdigit() and ens.isdigit()) or int(ens) > (now + SKEW) * 10 ** 9 \
                        or abs(int(ens) / 1e9 - int(fin)) > ENDED_SLACK:
                    return None, "attempt %s has an end time that doesn't match its finish time" % n
                order = (int(ens), n)
            else:
                order = (max(stamps) * 10 ** 9, n)
            if newest is None or order > newest[0]:
                newest = (order, n, r)
        if newest is None:
            return None, "no earlier attempt on this exact candidate"
        _, n, r = newest
        if r.get("status") != "passed" or r.get("exit") != "0" or r.get("cleanup") != "ok" \
                or not r.get("finished", "").isdigit():
            return None, "the latest attempt on this exact candidate ended %s (%s)" % (r.get("status") or "unfinished", n)
        age = now - int(r["finished"])
        if age >= a.max_age:
            return None, "its pass is %ds old (JARVIS_REUSE_MAX_AGE=%d)" % (age, a.max_age)
        return (n, r), None

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
            self.link_inside(s["path"])
        else:
            shutil.copyfile(s["file"], dest)
            os.chmod(dest, s["perm"])

    def link_inside(self, p):
        tree = os.path.realpath(self.tree)
        real = os.path.realpath(os.path.join(self.tree, p))
        if real != tree and not real.startswith(tree + os.sep):
            raise Fail(2, "## Files: %s is a symlink that leaves the checkout" % p)

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
                "exit 2 ;;\nesac\n")
        with open(shim, "w") as f:
            f.write(text % (shq(self.ctl_runner), shq(self.ctl_runner)))
        os.chmod(shim, 0o755)
        self.shim = sha(text.encode())    # its bytes but the attempt's own path

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
        stop_group(pgid, start, grace, direct)

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
        return remove_attempt(self.root, self.attempt, self.tree, self.owner.get("admin", ""),
                              (getattr(self, "keydir", None), getattr(self, "vroot", None)))

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

# ---------------------------------------------------------------- doctor

def lease_slot(lock_dir, root):
    """The checkout's verify lease: jarvis-lock.pl's slot format, so `jarvis resources` lists it."""
    return os.path.join(lock_dir, "verify@%s.slot0" % hashlib.sha1(root.encode()).hexdigest()[:12])


def lease_try(path, create):
    """(fd, None) once this process holds the lease at path; (None, holder) while another holds it;
    (None, None) when there is no such lease file and create is false."""
    try:
        fd = os.open(path, os.O_RDWR | (os.O_CREAT if create else 0) | getattr(os, "O_NOFOLLOW", 0), 0o600)
    except FileNotFoundError:
        return None, None
    except OSError as e:
        return None, "unreadable: %s" % e.strerror
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        h = read_rec(path)
        return None, "pid %s" % h["pid"] if h.get("pid") else "another process"
    return fd, None


def same_proc(pid, start):
    return bool(pid) and str(pid).isdigit() and bool(start) and lstart_of(int(pid)) == start


def plural(n, word, many=None):
    return "%d %s" % (n, word if n == 1 else many or word + "s")


class Doctor:
    """`jarvis doctor`'s verification worktrees: what a verifier killed with its watchdog left behind.
    An attempt under handoffs/.jarvis/verify/ is an orphan only when its ownership manifest is this
    checkout's (canonical paths, git common dir, run, tree), its verifier and watchdog are gone (PID
    and start time) and the verify lease is free. --apply rechecks each under that lease, stops
    only its check's process group while the group's leader is still the recorded one, removes only
    that registered worktree (or the folder of an add that never registered), marks the pending
    result interrupted and a run record stuck at verify_status: running stale, and audits it.
    Anything it can't account for is reported and left alone."""

    def __init__(self, a):
        self.a = a
        self.root = os.path.realpath(a.root)
        self.state = os.path.join(self.root, STATE_DIR)
        self.vroot = os.path.join(self.state, "verify")
        self.slot = lease_slot(a.lock_dir, self.root)
        c = git(self.root, "rev-parse", "--git-common-dir").stdout.decode().strip()
        self.common = os.path.realpath(os.path.join(self.root, c))

    def rel(self, p):
        return os.path.relpath(p, self.root)

    def registered(self):
        p = git(self.root, "worktree", "list", "--porcelain", "-z", ok=(0, 128, 129))
        sep = "\0"
        if p.returncode:      # git before 2.36: no -z
            p, sep = git(self.root, "worktree", "list", "--porcelain"), "\n"
        return {os.path.realpath(x[9:]) for x in p.stdout.decode("utf-8", "surrogateescape").split(sep)
                if x.startswith("worktree ")}

    def survey(self):
        """(attempts, odd): each attempt examined; odd = (path, why) of entries left alone."""
        self.reg = self.registered()
        attempts, odd = [], []
        if os.path.lexists(self.vroot):
            if os.path.islink(self.vroot) or not os.path.isdir(self.vroot) or os.path.realpath(self.vroot) != self.vroot:
                return [], [(self.vroot, "isn't a plain directory of this checkout")]
            for k in sorted(os.listdir(self.vroot)):
                kd = os.path.join(self.vroot, k)
                if os.path.islink(kd):
                    odd.append((kd, "a symlink"))
                    continue
                if not os.path.isdir(kd):
                    continue
                for n in sorted(os.listdir(kd)):
                    ad = os.path.join(kd, n)
                    if os.path.islink(ad):
                        odd.append((ad, "a symlink"))
                    elif os.path.isdir(ad):
                        attempts.append(self.examine(k, n))
        trees = {t["tree"] for t in attempts}
        for p in sorted(self.reg):
            if p.startswith(self.vroot + "/") and p not in trees:
                odd.append((p, "a registered worktree with no ownership manifest"))
        return attempts, odd

    def examine(self, key, name):
        ad = os.path.join(self.vroot, key, name)
        t = {"key": key, "name": name, "dir": ad, "tree": os.path.join(ad, "tree"), "m": {}, "admin": "",
             "why": None, "live": None, "group": None, "fds": []}
        t["registered"] = t["tree"] in self.reg
        t["why"] = self.distrust(t)
        if t["why"]:
            t["kind"] = "manual"
            return t
        m = t["m"]
        if same_proc(m.get("owner"), m.get("owner_start")):
            t["live"] = "its verifier (pid %s) is running" % m["owner"]
        elif same_proc(m.get("watchdog"), m.get("watchdog_start")):
            t["live"] = "its watchdog (pid %s) is still cleaning up" % m["watchdog"]
        elif m.get("lease") and m["lease"] != self.slot:   # a verifier with another JARVIS_LOCK_DIR
            fd, holder = lease_try(m["lease"], False)
            if holder:
                t["live"] = "its lease is held (%s)" % holder
            elif fd is not None:
                t["fds"].append(fd)
        if t["live"]:
            t["kind"] = "live"
            return t
        pg = m.get("pgid")
        members = group_members(int(pg)) if pg else []
        if members:
            leader = lstart_of(int(pg))
            if leader and leader == m.get("pgid_start"):
                t["group"] = ("ours", len(members))
            elif leader and m.get("pgid_start"):
                t["group"] = ("reused", len(members))
            else:
                t["kind"] = "stuck"
                t["why"] = ("%s in its check's process group %s remain%s, but its leader %s, so they can't be "
                            "told from someone else's" % (plural(len(members), "process", "processes"), pg,
                                                          "s" if len(members) == 1 else "",
                                                          "is gone" if not leader else "has no recorded start"))
                return t
        t["kind"] = "orphan"
        return t

    def distrust(self, t):
        """Why this attempt's ownership can't be trusted, or None."""
        ad, tree = t["dir"], t["tree"]
        if os.path.realpath(ad) != ad:
            return "its folder isn't a plain directory here"
        mf = os.path.join(ad, "owner")
        try:
            st = os.lstat(mf)
        except OSError:
            return "no ownership manifest"
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid():
            return "its manifest isn't a file of yours"
        m = t["m"] = read_rec(mf)
        if m.get("schema") != SCHEMA:
            return "its manifest isn't a %s one" % SCHEMA
        if m.get("root") != self.root:
            return "its manifest names another checkout"
        if m.get("common") != self.common:
            return "its manifest names another git repository"
        if m.get("attempt") != t["name"] or m.get("tree") != tree:
            return "its manifest names another attempt or tree"
        run = m.get("run", "")
        if not (run == t["key"] or (run == "-" and t["key"].startswith("standalone-"))):
            return "its manifest's run doesn't match its folder"
        if not m.get("owner", "").isdigit() or not m.get("owner_start"):
            return "its manifest has no verifier PID and start time"
        if any(m.get(k) and not m[k].isdigit() for k in ("watchdog", "pgid")):
            return "its manifest's PIDs aren't numbers"
        if m.get("lease") and os.path.basename(m["lease"]) != os.path.basename(self.slot):
            return "its manifest's lease isn't this checkout's"
        if os.path.lexists(tree) and (os.path.islink(tree) or not os.path.isdir(tree)):
            return "its tree isn't a directory"
        admin = m.get("admin", "")
        if not admin and os.path.isfile(os.path.join(tree, ".git")) and not os.path.islink(os.path.join(tree, ".git")):
            try:   # killed between `worktree add` and recording it: the tree's .git file names it
                with open(os.path.join(tree, ".git")) as f:
                    g = re.match(r"^gitdir: (.*)$", f.read().strip())
                admin = os.path.realpath(os.path.join(tree, g.group(1))) if g else ""
            except OSError:
                admin = ""
        if admin and os.path.isdir(admin):
            if os.path.dirname(admin) != os.path.join(self.common, "worktrees") or not backlink_ok(admin, tree):
                return "its git worktree entry doesn't point back at its tree"
            t["admin"] = admin
        return None

    def stuck_runs(self, attempts):
        """(run, attempt, result path) of each run record at verify_status: running whose attempt left
        no folder and whose verifier is gone."""
        runs = os.path.join(self.state, "runs")
        names = {t["name"] for t in attempts}
        out = []
        try:
            entries = sorted(os.listdir(runs))
        except OSError:
            return out
        for n in entries:
            f = os.path.join(runs, n)
            if n.startswith(".") or not re.match(r"^[A-Za-z0-9_%.-]+$", n) or os.path.islink(f) or not os.path.isfile(f):
                continue
            r = read_rec(f)
            att = r.get("verify_attempt", "")
            if r.get("verify_status") != "running" or att in names:
                continue
            res = ""
            if re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]*", att):   # never . or ..
                res = os.path.join(self.state, "verify-results", att, "result")
            rr = read_rec(res) if res else {}
            if same_proc(rr.get("owner"), rr.get("owner_start")):
                continue
            out.append((n, att, res))
        return out

    # ---- report

    def report(self, quiet):
        attempts, odd = self.survey()
        stuck = self.stuck_runs(attempts)
        fd, holder = lease_try(self.slot, False)
        if fd is not None:
            os.close(fd)
        for t in attempts:
            for x in t["fds"]:
                os.close(x)
        orphans = [t for t in attempts if t["kind"] == "orphan"]
        manual = [t for t in attempts if t["kind"] in ("manual", "stuck")] + odd
        if quiet:
            parts = []
            if orphans:
                parts.append(plural(len(orphans), "orphaned verification worktree"))
            if stuck:
                parts.append(plural(len(stuck), "stale verify record"))
            if manual:
                parts.append(plural(len(manual), "verification worktree") + " to check by hand")
            if parts:
                say(" · ".join(parts))
            return 3 if orphans or stuck else 0
        later = " · reclaimed once the running verification (%s) ends" % holder if holder else ""
        for t in attempts:
            m, head = t["m"], "  %s · " % self.rel(t["dir"])
            who = ("run " + m["run"]) if m.get("run", "-") != "-" else "standalone"
            if t["kind"] == "live":
                say(head + "%s · running: %s (left alone)" % (who, t["live"]))
            elif t["kind"] == "orphan":
                g = t["group"]
                say(head + "%s · ORPHANED: its verifier (pid %s) and watchdog are gone · %s%s%s" % (
                    who, m["owner"], "a registered worktree" if t["registered"] else
                    "no registered worktree (interrupted before or during its add)",
                    " · its check left %s running (group %s)" % (plural(g[1], "process", "processes"), m["pgid"])
                    if g and g[0] == "ours" else "", later))
            else:
                say(head + "%s%s: left alone — look, then remove it yourself" % (
                    t["why"], " · a registered worktree" if t["registered"] else ""))
        for p, why in odd:
            say("  %s · %s: left alone — look, then remove it yourself" % (self.rel(p), why))
        for run, att, res in stuck:
            say("  run %s · verify_status running, but no verification of it is alive and none of it is left: "
                "stale%s" % (run, later))
        return 3 if orphans or stuck else 0

    # ---- apply: under the checkout's verify lease, everything rechecked

    def apply(self):
        os.makedirs(self.a.lock_dir, 0o700, exist_ok=True)
        fd, holder = lease_try(self.slot, True)
        if fd is None:
            say("doctor: left verification worktrees alone: this checkout's verify lease is held (%s); "
                "run doctor --apply again once that verification ends" % holder)
            return 0
        try:
            os.ftruncate(fd, 0)
            os.write(fd, rec_text({"pid": os.getpid(), "start": int(time.time()), "cmd": "jarvis doctor --apply",
                                   "cwd": self.root, "root": self.root, "term": "", "session": "",
                                   "wrapper": os.getpid()}).encode())
            attempts, _ = self.survey()
            for t in attempts:
                try:
                    if t["kind"] == "orphan":
                        self.reclaim(t)
                finally:
                    for x in t["fds"]:
                        os.close(x)
            for run, att, res in self.stuck_runs(attempts):
                done = self.mark_stale(run, att)
                self.mark_result(res)
                self.audit("verify-stale", run, "-", "attempt=%s" % (att or "-"), "stale" if done else "unchanged")
                if done:
                    say("doctor: run %s · verify_status running → stale: no verification of it is alive" % run)
        finally:
            os.close(fd)
        return 0

    def reclaim(self, t):
        m, where = t["m"], self.rel(t["dir"])
        done = []
        g = t["group"]
        if g and g[0] == "ours":
            stop_group(m["pgid"], m["pgid_start"], self.a.grace, direct=False)
            if group_members(int(m["pgid"])):
                self.audit("verify-orphan", m["run"], m.get("brief", "-"), "attempt=%s pgid=%s" % (t["name"], m["pgid"]),
                           "check processes didn't stop")
                say("doctor: left %s: its check's processes (group %s) didn't stop" % (where, m["pgid"]))
                return
            done.append("stopped %s of its check" % plural(g[1], "process", "processes"))
        ok = remove_attempt(self.root, t["dir"], t["tree"], t["admin"], (os.path.join(self.vroot, t["key"]),))
        if ok and t["tree"] in self.registered():
            ok = False
        done.append("removed its worktree" if t["registered"] else "removed its folder")
        res = os.path.join(self.state, "verify-results", t["name"], "result")
        if self.mark_result(res, ok):
            done.append("result marked interrupted")
        if m["run"] != "-" and self.mark_stale(m["run"], t["name"]):
            done.append("run %s verify_status stale" % m["run"])
        self.audit("verify-orphan", m["run"], m.get("brief", "-"), "attempt=%s pgid=%s" % (t["name"], m.get("pgid") or "-"),
                   "removed" if ok else "cleanup failed")
        if ok:
            say("doctor: orphaned verification %s: %s" % (where, "; ".join(done)))
        else:
            say("doctor: orphaned verification %s: cleanup FAILED, something is left there or registered "
                "(git worktree list); %s" % (where, "; ".join(done[:-1]) or "nothing else done"))

    def mark_result(self, res, ok=True):
        """An attempt's result still at status: running → interrupted."""
        if not res or os.path.islink(res) or not os.path.isfile(res):
            return False
        r = read_rec(res)
        if r.get("status") != "running":
            return False
        now = time.time_ns()
        r.update(status="interrupted", finished=now // 10 ** 9, ended_ns=now, cleanup="ok" if ok else "failed",
                 note="the verifier and its watchdog died; jarvis doctor --apply cleaned up")
        write_atomic(res, rec_text(r))
        return True

    def mark_stale(self, run, att):
        """verify_status: running → stale on a run record still naming this attempt."""
        r = read_rec(os.path.join(self.state, "runs", run))
        if r.get("verify_status") != "running" or r.get("verify_attempt", "") != att:
            return False
        env = {k: v for k, v in os.environ.items() if k != "JARVIS_VERIFY_CONTEXT"}
        try:
            return subprocess.run([self.a.runner, "_run-set", "--if", "verify_attempt", att, run,
                                   "verify_status", "stale", "verify_finished", str(int(time.time()))],
                                  cwd=self.root, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL).returncode == 0
        except OSError:
            return False

    def audit(self, action, run, brief, target, result):
        """A line in bin/jarvis's audit format."""
        line = "%s %s run=%s brief=%s %s result=%s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), action,
                                                          run or "-", brief or "-", target, result.replace(" ", "_"))
        with open(os.path.join(self.state, "audit.log"), "a") as f:
            f.write(line)


def ago(s):
    s = max(0, int(s))
    if s < 60:
        return "%ds" % s
    if s < 3600:
        return "%dm%02ds" % (s // 60, s % 60)
    return "%dh%02dm" % (s // 3600, (s % 3600) // 60)


def shq(s):
    return "'" + s.replace("'", "'\\''") + "'"


def main():
    ap = argparse.ArgumentParser(prog="jarvis-verify.py")
    ap.add_argument("op", choices=["run", "doctor"])
    ap.add_argument("--root", required=True)
    ap.add_argument("--handoff")
    ap.add_argument("--runner", required=True)
    ap.add_argument("--bash")
    ap.add_argument("--max-sec", type=int, default=7200)
    ap.add_argument("--lock-wait", type=int, default=3600)
    ap.add_argument("--grace", type=int, default=10)
    ap.add_argument("--reuse", choices=["0", "1"], default="0")
    ap.add_argument("--max-age", type=int, default=7200)
    ap.add_argument("--reuse-env", default="")
    ap.add_argument("--lock-dir", default=os.path.join(os.path.expanduser("~"), ".jarvis", "locks"))
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()
    if a.op == "doctor":
        try:
            d = Doctor(a)
            sys.exit(d.apply() if a.apply else d.report(a.quiet))
        except Fail as e:
            print("jarvis doctor: %s" % e.msg, file=sys.stderr)
            sys.exit(2)
    if not a.handoff or not a.bash:
        ap.error("run needs --handoff and --bash")
    v = Verify(a)
    for s in SIGCODE:
        signal.signal(s, v.on_signal)
    code, msg = 0, ""
    try:
        v.preflight()
        v.take_lease()
        v.start()
        v.materialize()
        v.requires()
        say("verify: HEAD %s · %d listed change%s · %d input%s · %d dependenc%s · %s" % (
            v.head[:7], len(v.entries), "" if len(v.entries) == 1 else "s",
            len(v.inputs["copy"]) + len(v.inputs["requires"]),
            "" if len(v.inputs["copy"]) + len(v.inputs["requires"]) == 1 else "s",
            len(v.inputs["dependencies"]), "y" if len(v.inputs["dependencies"]) == 1 else "ies",
            "run " + v.run if v.run else "no run record; result stored separately"))
        if a.reuse == "1":
            v.reused, why = v.find_pass()
            if not v.reused:
                say("verify: not reusing: %s; running the checks" % why)
        if v.reused:
            v.recheck()
        else:
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
    reused = v.reused if code == 0 else None
    if v.results and os.path.isdir(v.results):
        n = v.result.get("check")
        if reused:
            orig, r = reused
            kv = [("verify_status", "passed"), ("verify_finished", r["finished"]), ("verify_exit", 0),
                  ("verify_check", r.get("check", "")), ("verify_reused", "1"),
                  ("verify_log", os.path.join(STATE_DIR, "verify-results", orig, "check-%s.log" % r.get("check", "1")))]
        else:
            log = os.path.join(v.results_rel, "check-%s.log" % n) if n else v.results_rel
            kv = [("verify_status", status), ("verify_finished", int(time.time())), ("verify_exit", code),
                  ("verify_check", n or ""), ("verify_reused", "0"), ("verify_log", log)]
        kv += [("verify_tree", getattr(v, "tree_id", "")), ("verify_key", v.key or "")]
        rc = v.record(True, kv)
        if rc == 3:
            say("verify: a newer attempt has started on run %s; its record is left as it is" % v.run)
        elif rc:
            say("verify: can't write the result to run %s's record (handoffs/.jarvis/runs/%s)" % (v.run, v.run))
            if code == 0:
                code, status, reused, msg = 2, "error", None, "the pass couldn't be recorded"
        extra = {"reused_from": reused[0], "pass_finished": reused[1]["finished"]} if reused else {}
        v.save_result(status="reused" if reused else status, exit=code, finished=int(time.time()),
                      ended_ns=time.time_ns(), cleanup="ok" if clean else "failed", message=msg.split("\n")[0], **extra)
    where = (" · " + v.results_rel) if v.results else ""
    if reused:
        orig, r = reused
        t = int(r["finished"])
        say("verify: reused pass from %s (%s ago) · tree %s · %s" % (
            time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t)), ago(time.time() - t), v.tree_id[:7],
            os.path.join(STATE_DIR, "verify-results", orig)))
        say("  not re-run: HEAD, the listed changes, the brief, inputs, runner and environment are the same as "
            "that pass's; run without --reuse to run the checks again")
        if v.status == "partial":
            say("  the handoff says partial: checked, not done")
    elif code == 0:
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
