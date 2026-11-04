#!/usr/bin/env python3
# jarvis-scope.py — does a new brief's May-touch scope meet a running worker's?
# bin/jarvis spawn calls this inside the checkout's spawn lease; nothing else should.
#
#   python3 -I jarvis-scope.py overlap <root> <new brief>
#       stdin: "<terminal>\t<brief>" for each running worker (no brief: its scope is unknown)
#       stdout: one line per conflicting brief; exit 0 = none, 1 = some, 2 = usage, 3 = a bug
#
# A scope is the brief's one "- May touch:" row under its one "## Scope" section:
# comma-separated paths, each bare or in backticks (a backticked one may hold spaces),
# each optionally followed by a "(note)". "none" alone is the empty scope. A trailing /
# is a directory, existing or not; a bare path is a file unless it is an existing
# directory, or a proper prefix of another entry's path. Globs: * ? and [classes] within
# a component ([^..] negates like [!..]), ** as a whole component.
# Anything else (braces, extglobs, $, negation, prose around a path, absolute or ..
# paths, a symlink out of the checkout) makes the scope unknown, never empty: spawn
# treats unknown as overlapping. This is a collision warning, not a permission check:
# Must-not-touch rows aren't subtracted, and doubt comes out as "possible overlap".
import os
import re
import sys
from fnmatch import fnmatchcase

SHOWN = 3            # entries named per side in a message
GLOB = set("*?[")
SHELL = set("{}()$|;&<>\"'\\!")   # brace expansion, extglobs, substitution, negation: not scope grammar


class Unknown(Exception):
    pass


class Entry:
    def __init__(self, text, comps, directory, root):
        self.text = text
        self.directory = directory
        g = next((i for i, c in enumerate(comps) if GLOB & set(c)), None)
        self.glob = g is not None
        fixed = comps if g is None else comps[:g]
        # the existing part of the fixed prefix as the filesystem resolves it
        real = os.path.realpath(os.path.join(root, *fixed)) if fixed else root
        if os.path.commonpath([root, real]) != root:
            raise Unknown("'%s' resolves outside the checkout through a symlink" % text)
        rel = os.path.relpath(real, root)
        resolved = tuple(() if rel == "." else rel.split(os.sep)) + tuple(comps[len(fixed):])
        self.variants = [tuple(comps)] + ([resolved] if resolved != tuple(comps) else [])
        if not self.glob and not directory and os.path.isdir(real):
            self.directory = True


def check_component(c, text):
    if "**" in c and c != "**":
        raise Unknown("'%s': ** must be a whole path component" % text)
    i = 0
    while i < len(c):
        ch = c[i]
        if ch == "[":
            j = i + 1
            if j < len(c) and c[j] in "!^":
                j += 1
            if j < len(c) and c[j] == "]":
                j += 1
            while j < len(c) and c[j] != "]":
                if c[j] in SHELL - set("!") or c[j] == "[":
                    raise Unknown("'%s' has shell syntax in a [class]" % text)
                j += 1
            if j >= len(c):
                raise Unknown("'%s' has an unclosed [" % text)
            i = j + 1
            continue
        if ch in SHELL:
            raise Unknown("'%s' uses %s, which isn't scope grammar (no braces, extglobs, $, "
                          "quotes or negation)" % (text, ch))
        i += 1


def parse_path(text, root):
    if not text:
        raise Unknown("an empty entry")
    if text.startswith(("/", "~")):
        raise Unknown("'%s' is absolute: name paths relative to the checkout" % text)
    directory = text.endswith("/")
    comps = []
    for c in text.split("/"):
        if c in ("", "."):
            continue
        if c == "..":
            raise Unknown("'%s' climbs out with .." % text)
        check_component(c, text)
        comps.append(c.replace("[^", "[!"))   # fnmatch reads [^..] as a literal ^; the shell negates
    if not comps:   # "./": the whole checkout
        directory = True
    return Entry(text, comps, directory, root)


def split_row(row):
    """Commas outside backticks and (notes) separate entries."""
    parts, cur, tick, depth = [], "", False, 0
    for ch in row:
        if ch == "`":
            tick = not tick
        elif not tick and ch == "(":
            depth += 1
        elif not tick and ch == ")":
            depth -= 1
            if depth < 0:
                raise Unknown("an unmatched )")
        if ch == "," and not tick and depth == 0:
            parts.append(cur)
            cur = ""
        else:
            cur += ch
    if tick:
        raise Unknown("an unclosed backtick")
    if depth:
        raise Unknown("an unclosed (")
    return parts + [cur]


ENTRY = re.compile(r"(?:`([^`]*)`|([^\s`()]+))(?:\s+\([^`()]*\))?")


def parse_entry(raw, root):
    e = raw.strip()
    m = ENTRY.fullmatch(e)
    if not m:
        raise Unknown("entry '%s' isn't a path (an optional note goes after it in parentheses; "
                      "no other prose)" % e)
    path = m.group(1) if m.group(1) is not None else m.group(2)
    if "," in path or "\n" in path:
        raise Unknown("'%s' has a comma in it" % path)
    return parse_path(path.strip() if m.group(1) is not None else path, root)


def scope_of(brief, root):
    """The brief's May-touch entries ([] = none); raises Unknown with the reason."""
    try:
        with open(brief, encoding="utf-8") as f:
            content = f.read()
    except FileNotFoundError:
        raise Unknown("the brief is gone")
    except (OSError, UnicodeError) as e:
        raise Unknown("can't read the brief (%s)" % e.__class__.__name__)
    heads = [m.start() for m in re.finditer(r"(?m)^## Scope[ \t]*$", content)]
    if len(heads) != 1:
        raise Unknown("no '## Scope' section" if not heads else "%d '## Scope' sections" % len(heads))
    m = re.search(r"(?ms)^## Scope[ \t]*\n(.*?)(?=^## |\Z)", content)
    rows = list(re.finditer(r"(?m)^- May touch:(.*)$", m.group(1)))
    if len(rows) != 1:
        raise Unknown("no '- May touch:' row under ## Scope" if not rows
                      else "%d '- May touch:' rows under ## Scope" % len(rows))
    line = content.count("\n", 0, m.start(1) + rows[0].start()) + 1
    row = rows[0].group(1).strip()
    try:
        if not row:
            raise Unknown("the row is empty (list the paths on that line)")
        if re.fullmatch(r"`?none`?(\s+\([^`()]*\))?", row, re.I):
            return []
        return [parse_entry(p, root) for p in split_row(row)]
    except Unknown as e:
        raise Unknown("line %d: %s" % (line, e))


# ---------------------------------------------------------------- comparison

def states(comps, pat):
    """Pattern positions reachable after matching comps; ** takes zero or more components."""
    def closure(s):
        out, todo = set(s), list(s)
        while todo:
            j = todo.pop()
            if j < len(pat) and pat[j] == "**" and j + 1 not in out:
                out.add(j + 1)
                todo.append(j + 1)
        return out
    cur = closure({0})
    for c in comps:
        nxt = set()
        for j in cur:
            if j == len(pat):
                continue
            if pat[j] == "**":
                nxt.add(j)
            elif fnmatchcase(c, pat[j]):
                nxt.add(j + 1)
        cur = closure(nxt)
        if not cur:
            break
    return cur


def fixed_of(pat):
    return tuple(c for c in pat[:next((i for i, c in enumerate(pat) if GLOB & set(c)), len(pat))])


def under(a, b):   # path a is b or below it
    return a[:len(b)] == b


def compare(a, ad, ag, b, bd, bg):
    """None, "possible" or "overlap" for one variant of each entry."""
    if not ag and not bg:   # a path under the other's makes that one a folder, on disk or not
        if under(b, a) or under(a, b):
            return "overlap"
        return None
    if ag and bg:   # two globs: disjoint fixed prefixes prove disjoint; else maybe
        fa, fb = fixed_of(a), fixed_of(b)
        return "possible" if under(fa, fb) or under(fb, fa) else None
    if ag:
        a, ad, b, bd = b, bd, a, ad   # a literal, b the glob
    if len(b) in states(a, b):
        return "overlap"   # the glob names the literal path itself
    prefix = len(b) > len(a) and "**" not in b[:len(a)] and all(map(fnmatchcase, a, b))
    if (ad or prefix) and states(a, b):
        # it names something under the directory (a bare path the glob's own path runs through
        # is one): certainly so when all it can name is there
        return "overlap" if under(fixed_of(b), a) else "possible"
    if any(len(b) in states(a[:k], b) for k in range(len(a))):
        return "overlap" if bd else "possible"   # it names a folder above the literal path
    return None


def meet(x, y):
    best = None
    for fold in (False, True):
        for a in x.variants:
            for b in y.variants:
                if fold:
                    a2, b2 = tuple(c.casefold() for c in a), tuple(c.casefold() for c in b)
                else:
                    a2, b2 = a, b
                r = compare(a2, x.directory, x.glob, b2, y.directory, y.glob)
                if r and fold:
                    r = "possible"   # only a case variant: another name for it on some filesystems
                if r == "overlap":
                    return r
                best = best or r
        if best:
            return best
    return best


def shown(texts):
    texts = list(dict.fromkeys(texts))
    more = len(texts) - SHOWN
    return ", ".join(texts[:SHOWN]) + (" +%d more" % more if more > 0 else "")


def key_of(path, root):
    p = os.path.realpath(os.path.join(root, path))
    return os.path.normcase(p)


def rel(path, root):
    p = os.path.realpath(os.path.join(root, path))
    if os.path.commonpath([root, p]) == root:
        return os.path.relpath(p, root)
    return path


def overlap(root, new):
    running, blank = {}, []
    for line in sys.stdin.read().splitlines():
        if not line.strip():
            continue
        term, _, brief = line.partition("\t")
        if not brief.strip():
            blank.append(term.strip())
            continue
        running.setdefault(key_of(brief, root), (brief, []))[1].append(term)
    if not running and not blank:
        return 0
    out = []
    nk, nshow = key_of(new, root), rel(new, root)
    for term in dict.fromkeys(blank):
        out.append("unknown overlap: running term %s has no brief on record, so its scope can't be read — "
                   "treat it as overlapping %s: queue %s under To-do until it is handed off, or close it "
                   "(handoffs/bin/jarvis close %s)." % (term, nshow, nshow, term))
    if nk in running:
        terms = running.pop(nk)[1]
        out.append("overlap: %s is already running (term %s) — close that worker first "
                   "(handoffs/bin/jarvis close %s), or wait for its handoff."
                   % (nshow, ", ".join(terms), terms[0]))
    try:
        mine = scope_of(new, root)
    except Unknown as e:
        if running or blank:
            out.append("unknown overlap: %s's scope can't be read (%s), so it can't be compared with "
                       "running %s — give it a '- May touch:' row of paths, or queue it under To-do "
                       "until they are handed off."
                       % (nshow, e, shown([rel(b, root) for b, _ in running.values()]
                                          + ["term %s" % t for t in dict.fromkeys(blank)])))
        if out:
            print("\n".join(out))
        return 1 if out else 0
    for brief, terms in running.values():
        other = rel(brief, root)
        try:
            theirs = scope_of(brief, root)
        except Unknown as e:
            out.append("unknown overlap: running %s (term %s) has a scope that can't be read (%s) — "
                       "treat it as overlapping %s: queue %s under To-do until %s is handed off, or "
                       "fix its Scope." % (other, ", ".join(terms), e, nshow, nshow, other))
            continue
        pairs = [(x, y, meet(x, y)) for x in mine for y in theirs]
        pairs = [p for p in pairs if p[2]]
        if not pairs:
            continue
        kind = "overlap" if any(k == "overlap" for _, _, k in pairs) else "possible overlap"
        out.append("%s: %s [%s] with running %s [%s] — queue %s under To-do until %s is handed off, "
                   "or narrow the scopes." % (kind, nshow, shown(x.text for x, _, _ in pairs), other,
                                              shown(y.text for _, y, _ in pairs), nshow, other))
    if out:
        print("\n".join(out))
    return 1 if out else 0


def main(argv):
    if len(argv) != 4 or argv[1] != "overlap":
        print("usage: jarvis-scope.py overlap <root> <new brief>  "
              "(stdin: <terminal>\\t<brief> per running worker)", file=sys.stderr)
        return 2
    root = os.path.realpath(argv[2])
    return overlap(root, argv[3])


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as e:  # a bug: exit 3, which spawn reads as an unknown overlap
        print("jarvis-scope.py: %s: %s" % (e.__class__.__name__, e), file=sys.stderr)
        sys.exit(3)
