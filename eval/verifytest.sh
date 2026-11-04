#!/usr/bin/env bash
# Offline test of `jarvis merge <handoff> --check --verify` (bin/jarvis-verify.py): two
# workers' dirty edits verified apart, failure tails, timeouts, signals and a killed
# verifier, leases keyed to the original checkout, the strict ## Files reading, and
# the plain --check left as it was. Throwaway checkouts with the template's bin files,
# a throwaway HOME and lock dir, and processes of its own, all stopped before it exits.
#
#   eval/verifytest.sh
# `[ … ]; check "…" $?` reads the test's own status, and the single-quoted scripts
# expand in the shell they're written for, not this one.
# shellcheck disable=SC2016,SC2154,SC2319
set -u
# One brace group ending in exit, so bash reads the whole file before running any of it:
# it reads a script as it goes, and an edit made mid-run (another worker's, in a shared
# checkout) resumes it at a stale offset, in the caller's directory, outside every `cd`.
{
here=$(cd "$(dirname "$0")" && pwd)
tpl="$here/../plugins/jarvis/skills/setup/templates"
tmp=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/jarvis-verifytest.XXXXXX")" && pwd -P)
groups="$tmp/groups"; kids="$tmp/kids"
# groups: what bg_in started; kids: PIDs checks wrote down, each stopped only while its
# command line still names this test's folder
trap 'for g in $(cat "$groups" 2>/dev/null); do kill -9 -- "-$g" "$g" 2>/dev/null; done
  for k in $(cat "$kids" 2>/dev/null); do ps -o command= -p "$k" 2>/dev/null | grep -qF "$tmp/" && kill -9 "$k" 2>/dev/null; done
  rm -rf "$tmp"' EXIT
export HOME="$tmp/home" JARVIS_HOME="$tmp/jh" CLAUDE_CONFIG_DIR="$tmp/cc" JARVIS_LOCK_DIR="$tmp/locks" JARVIS_LOCK_POLL=0.05
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
unset JARVIS_LOCKS_HELD JARVIS_LOCK_WAIT JARVIS_VERIFY_CONTEXT JARVIS_REUSE_ENV SUPERSET_WORKSPACE_ID SUPERSET_TERMINAL_ID TMUX TMUX_PANE ULTRON_SESSION_ID CLAUDE_PROJECT_DIR
mkdir -p "$HOME"
fails=0
ok() { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; fails=$((fails + 1)); }
check() { if [ "$2" = 0 ]; then ok "$1"; else bad "$1"; fi; }

waitfor() { # $1 = seconds, then a test: poll until it holds
  local n=$(($1 * 20))
  shift
  while [ $n -gt 0 ]; do "$@" && return 0; sleep 0.05; n=$((n - 1)); done
  return 1
}
bg_in() { # $1 = dir, then a command: start it there in the background, in a process group of its own
  local d=$1
  shift
  perl -e 'chdir(shift) or die "chdir: $!"; setpgrp(0, 0); exec { $ARGV[0] } @ARGV or die "exec: $!"' "$d" "$@" 2>>"$tmp/bg.err" &
  bgpid=$!
  echo "$bgpid" >> "$groups"
}
stop() { kill -9 -- "-$1" "$1" 2>/dev/null; wait "$1" 2>/dev/null; } # a group bg_in started
alive() { kill -0 "$1" 2>/dev/null && ! ps -o stat= -p "$1" 2>/dev/null | grep -q '^Z'; }
gone() { ! alive "$1"; }
# sleeper: runs until stopped; its command line names this test's folder
printf '%s\n' '#!/bin/sh' 'while :; do sleep 1; done' > "$tmp/sleeper"
# hold <flag> <seconds>: says it has the lease, then holds it
printf '%s\n' '#!/bin/sh' 'touch "$1"; sleep "$2"' > "$tmp/hold"
chmod +x "$tmp/sleeper" "$tmp/hold"

mkrepo() { # $1 = dir, $2 = ignored | tracked: whether handoffs/ itself is committed
  mkdir -p "$1/handoffs/bin" "$1/handoffs/briefs" "$1/src" "$1/tests" && (
    cd "$1" && git init -q
    cp "$tpl/handoffs/bin/jarvis" "$tpl/handoffs/bin/jarvis-lock.pl" "$tpl/handoffs/bin/jarvis-verify.py" handoffs/bin/
    sed -e 's/{{MAX_CLAUDE}}/3/' -e 's/{{AMBER}}/50/' -e 's/{{RED}}/75/' "$tpl/handoffs/jarvis.conf" > handoffs/jarvis.conf
    echo 'JARVIS_STOP_GRACE=1' >> handoffs/jarvis.conf
    printf '# Open\n' > handoffs/OPEN.md
    if [ "$2" = ignored ]; then printf 'handoffs/\nfixtures/\n' > .gitignore
    else printf 'handoffs/.jarvis/\nhandoffs/briefs/\nhandoffs/*.md\nfixtures/\n' > .gitignore; fi
    printf 'a() { echo a; }\n' > src/a.sh
    printf 'b() { echo b; }\n' > src/b.sh
    printf 'c() { echo c; }\n' > src/c.sh
    printf 'old\n' > src/old.txt
    printf '%s\n' 'set -e' 'for f in src/*.sh; do bash -n "$f"; done' 'echo suite ok' > tests/suite.sh
    printf '{"name":"x"}\n' > package.json; printf '{"lock":1}\n' > package-lock.json
    git add -A && git commit -qm init
  )
}
brief() { # $1 = name, stdin = its ## Checks body
  { printf '# %s\nworker: claude\n## Goal\nx\n## Checks\n' "$1"; cat; printf '## Phase\none\n'; } > "handoffs/briefs/$1.md"
}
handoff() { # $1 = name, $2 = brief name, $3 = status, then ## Files lines
  local n=$1 b=$2 s=$3
  shift 3
  { printf '# %s\nstatus: %s\nagent: claude test\nbrief: handoffs/briefs/%s.md\n## What changed\nx\n## Files\n' "$n" "$s" "$b"
    for l in "$@"; do printf -- '- %s\n' "$l"; done
    printf '## Checks run\nnone\n'; } > "handoffs/$n.md"
}
suite_brief() { # $1 = name: one suite-class block running the tracked suite
  brief "$1" <<EOF
Prose the verifier leaves alone: \`touch "$tmp/prose-ran"\` stays prose.

\`\`\`bash
touch "$tmp/prose-ran"
\`\`\`

\`\`\`bash verify class=suite timeout=60
bash tests/suite.sh 2>&1 | tail -40
\`\`\`
EOF
}
V() { handoffs/bin/jarvis merge "$1" --check --verify; } # $1 = handoff
leftover() { # nothing of a verification is left: no second worktree, no attempt directory
  [ "$(git worktree list --porcelain | grep -c '^worktree ')" = 1 ] || return 1
  [ -z "$(find handoffs/.jarvis/verify -mindepth 1 2>/dev/null)" ]
}
snap() { # the state verification must not change
  { git rev-parse HEAD; git ls-files -s | shasum; git diff | shasum; git diff --cached | shasum
    git status --porcelain -uall; shasum src/* tests/* handoffs/*.md handoffs/OPEN.md 2>/dev/null; } | shasum
}

r="$tmp/r"; mkrepo "$r" ignored
cd "$r" || exit 1

echo "1. two workers' dirty edits, verified apart"
printf 'a() { echo A; }\n' > src/a.sh                 # worker A: valid
printf 'b() { echo b\n' > src/b.sh                    # worker B: a syntax error
printf 'other worker\n' > src/untracked.txt
suite_brief bA; suite_brief bB
handoff hA bA done 'src/a.sh — modified'
handoff hB bB done '`src/b.sh` — modified (broke it)'
! bash tests/suite.sh >/dev/null 2>&1; check "the suite fails in the dirty checkout itself" $?
before=$(snap)
out=$(V handoffs/hA.md 2>&1); rc=$?
[ $rc = 0 ]; check "A's verify passes though B's error is in the checkout (exit $rc)" $?
printf '%s' "$out" | grep -q '^verify: passed 1/1 checks at HEAD [0-9a-f]\{7\} · tree [0-9a-f]\{7\} · isolated listed changes · handoffs/.jarvis/verify-results/'
check "…and says passed, HEAD, tree and its result" $?
printf '%s' "$out" | grep -q "isn't run: that review is still yours" && [ ! -e "$tmp/prose-ran" ]
check "…runs neither prose nor an unmarked fence, and says so" $?
out=$(V handoffs/hB.md 2>&1); rc=$?
[ $rc = 1 ]; check "B's verify fails (exit $rc)" $?
printf '%s' "$out" | grep -q 'check 1/1 · suite · 60s · FAILED (exit [0-9]*' && printf '%s' "$out" | grep -q 'src/b.sh'
check "…naming the block, its exit and the error" $?
[ "$(snap)" = "$before" ]; check "HEAD, index, diffs, untracked files and handoffs are unchanged" $?
leftover; check "no worktree or attempt directory left after a pass and a fail" $?
[ "$(find handoffs/.jarvis/verify-results -name result | wc -l | tr -d ' ')" = 2 ] \
  && grep -qx 'status: passed' $(grep -l 'handoff: handoffs/hA.md' handoffs/.jarvis/verify-results/*/result) \
  && grep -qx 'status: failed' $(grep -l 'handoff: handoffs/hB.md' handoffs/.jarvis/verify-results/*/result)
check "each attempt keeps its result outside the removed directory" $?
grep -q '^run: -' handoffs/.jarvis/verify-results/*/result; check "…a standalone one, with no run record" $?
printf 'c() { echo c\n' > src/c.sh; git add src/c.sh  # an unrelated staged edit, broken
before=$(snap)
V handoffs/hA.md >/dev/null 2>&1; check "A still passes with a broken staged edit elsewhere: the real index isn't used" $?
[ "$(snap)" = "$before" ]; check "…and the staged index is untouched" $?
git reset -q -- src/c.sh; git checkout -q -- src/c.sh

echo "2. plain --check is as it was"
out=$(handoffs/bin/jarvis merge handoffs/hA.md --check); rc=$?
[ $rc = 0 ] && [ "$(printf '%s\n' "$out" | head -n 1)" = "handoffs/hA.md · status: done · brief: handoffs/briefs/bA.md" ] \
  && printf '%s' "$out" | grep -q '^    src/b.sh$'; check "it lists the other worker's changes, exit 0" $?
handoff hN bA done 'src/c.sh — modified'
out=$(handoffs/bin/jarvis merge handoffs/hN.md --check); rc=$?
[ $rc = 1 ] && printf '%s' "$out" | grep -q '✗ listed but not changed: src/c.sh'; check "a listed file that didn't change: ✗ and exit 1" $?
n=$(find handoffs/.jarvis/verify-results -name result | wc -l)
handoffs/bin/jarvis merge handoffs/hA.md --check >/dev/null
[ "$(find handoffs/.jarvis/verify-results -name result | wc -l)" = "$n" ] && leftover; check "it runs nothing and records nothing" $?
out=$(V handoffs/hN.md 2>&1); rc=$?
[ $rc = 1 ] && printf '%s' "$out" | grep -q '✗ listed but not changed: src/c.sh' && printf '%s' "$out" | grep -q 'nothing run'
check "--verify refuses the same mismatch before running anything (exit $rc)" $?

echo "3. options"
handoffs/bin/jarvis merge handoffs/hA.md --verify >/dev/null 2>&1; [ $? = 2 ]; check "--verify without --check: exit 2" $?
out=$(handoffs/bin/jarvis merge handoffs/hA.md --check --reuse 2>&1); [ $? = 2 ] && printf '%s' "$out" | grep -q "goes with --check --verify"
check "--reuse without --verify: exit 2" $?
out=$(JARVIS_REUSE_MAX_AGE=soon handoffs/bin/jarvis merge handoffs/hA.md --check --verify --reuse 2>&1); [ $? = 2 ] && printf '%s' "$out" | grep -q "JARVIS_REUSE_MAX_AGE takes whole seconds"
check "a malformed JARVIS_REUSE_MAX_AGE: exit 2" $?
handoffs/bin/jarvis merge handoffs/hA.md --check --verify -m x >/dev/null 2>&1; [ $? = 2 ]; check "-m with --verify: exit 2" $?
handoffs/bin/jarvis merge handoffs/hA.md --check --verify --no-push >/dev/null 2>&1; [ $? = 2 ]; check "--no-push with --verify: exit 2" $?
handoff hBl bA blocked 'src/a.sh — modified'
out=$(V handoffs/hBl.md 2>&1); [ $? = 2 ] && printf '%s' "$out" | grep -q 'blocked'; check "a blocked handoff: exit 2" $?

echo "4. briefs without verify blocks"
brief bP <<'EOF'
Done when `bash tests/suite.sh` passes and `bash -n src/a.sh` is clean.

```bash
bash tests/suite.sh
```
EOF
handoff hP bP done 'src/a.sh — modified'
n=$(find handoffs/.jarvis/verify-results -name result | wc -l)
out=$(V handoffs/hP.md 2>&1); rc=$?
[ $rc = 2 ] && printf '%s' "$out" | grep -q 'no executable Checks blocks; add a bash verify block to handoffs/briefs/bP.md' \
  && printf '%s' "$out" | grep -q '```bash verify class=light timeout=300'
check "prose and unmarked fences: exit 2 with conversion guidance (exit $rc)" $?
[ "$(find handoffs/.jarvis/verify-results -name result | wc -l)" = "$n" ] && leftover; check "…before any worktree or result" $?
brief bE <<'EOF'
```bash verify class=light
true
```
EOF
handoff hE bE done 'src/a.sh — modified'
V handoffs/hE.md >/dev/null 2>&1; [ $? = 2 ]; check "a block without timeout=: exit 2" $?
brief bE <<'EOF'
```bash verify class=light timeout=5 color=red
true
```
EOF
V handoffs/hE.md >/dev/null 2>&1; [ $? = 2 ]; check "an unknown attribute: exit 2" $?
brief bE <<'EOF'
```bash verify class=light timeout=5
```
EOF
V handoffs/hE.md >/dev/null 2>&1; [ $? = 2 ]; check "an empty block: exit 2" $?
brief bE <<'EOF'
```bash verify class=light timeout=5
true
EOF
V handoffs/hE.md >/dev/null 2>&1; [ $? = 2 ]; check "an unclosed fence: exit 2" $?
brief bE <<'EOF'
```bash verify class=nosuch timeout=5
true
```
EOF
out=$(V handoffs/hE.md 2>&1); [ $? = 2 ] && printf '%s' "$out" | grep -q "no lock class 'nosuch'"; check "an unknown lock class: exit 2" $?
leftover; check "…none of them left anything" $?

echo "5. failures, tails, pipelines, blocks"
brief bF <<'EOF'
```bash verify class=light timeout=30
for i in $(seq 1 100); do echo "line $i"; done
exit 3
```
EOF
handoff hF bF done 'src/a.sh — modified'
out=$(V handoffs/hF.md 2>&1); rc=$?
[ $rc = 1 ] && printf '%s' "$out" | grep -q 'FAILED (exit 3' && printf '%s' "$out" | grep -q '^    line 100$' \
  && printf '%s' "$out" | grep -q '^    line 61$' && ! printf '%s' "$out" | grep -q '^    line 60$'
check "a failing check: exit 1, its own exit 3, its last 40 lines" $?
printf '%s' "$out" | grep -q 'full log: handoffs/.jarvis/verify-results/[^/]*/check-1.log' \
  && [ "$(grep -c '^line' handoffs/.jarvis/verify-results/*/check-1.log | awk -F: '$2 == 100' | wc -l | tr -d ' ')" -ge 1 ]
check "…and the full log is kept" $?
brief bF <<'EOF'
```bash verify class=light timeout=30
false | tail -n 1
```
EOF
V handoffs/hF.md >/dev/null 2>&1; [ $? = 1 ]; check "a pipeline failing before its tail fails" $?
brief bF <<EOF
\`\`\`bash verify class=light timeout=30
cd src
cat <<'DOC' > "$tmp/heredoc"
it's "quoted" \$HOME
DOC
\`\`\`

\`\`\`bash verify class=light timeout=30
test -f tests/suite.sh && test ! -e src/old.txt && test -f src/new.txt
\`\`\`

\`\`\`bash verify class=light timeout=30
exit 9
\`\`\`

\`\`\`bash verify class=light timeout=30
touch "$tmp/ran-4"
\`\`\`
EOF
printf 'new\n' > src/new.txt; rm src/old.txt
handoff hF bF done 'src/a.sh — modified' 'src/old.txt — deleted' 'src/new.txt — created'
out=$(V handoffs/hF.md 2>&1); rc=$?
[ "$(cat "$tmp/heredoc" 2>/dev/null)" = "it's \"quoted\" \$HOME" ]; check "block bytes, quotes and here-documents run as written" $?
printf '%s' "$out" | grep -q 'check 2/4 · light · 30s · passed'; check "each block starts at the worktree root; created and deleted files applied" $?
[ $rc = 1 ] && printf '%s' "$out" | grep -q 'check 3/4.*FAILED (exit 9' && [ ! -e "$tmp/ran-4" ]; check "the first failure stops the rest" $?
printf 'old\n' > src/old.txt; rm src/new.txt

echo "6. timeouts kill only the check's own process group"
bg_in "$r" "$tmp/sleeper"; outsider=$bgpid
brief bT <<EOF
\`\`\`bash verify class=light timeout=1
"$tmp/sleeper" & echo \$! >> "$kids"; echo \$! > "$tmp/kid-T"
wait
\`\`\`
EOF
handoff hT bT done 'src/a.sh — modified'
t0=$(date +%s)
out=$(V handoffs/hT.md 2>&1); rc=$?
[ $rc = 124 ] && printf '%s' "$out" | grep -q 'TIMED OUT'; check "a timeout exits 124 (exit $rc)" $?
[ $(( $(date +%s) - t0 )) -le 10 ]; check "…promptly" $?
waitfor 3 gone "$(cat "$tmp/kid-T")"; check "…its process group is stopped" $?
alive "$outsider"; check "…and a process outside it is not" $?
leftover; check "…and nothing is left" $?
grep -qx 'status: timeout' $(grep -l 'handoff: handoffs/hT.md' handoffs/.jarvis/verify-results/*/result); check "…recorded as timeout" $?
brief bT <<EOF
\`\`\`bash verify class=light timeout=30
"$tmp/sleeper" & echo \$! >> "$kids"; echo \$! > "$tmp/kid-L"
echo done
\`\`\`
EOF
V handoffs/hT.md >/dev/null 2>&1; check "a check that leaves a process behind still passes" $?
waitfor 3 gone "$(cat "$tmp/kid-L")"; check "…and what it left is stopped" $?

echo "7. a stopped or killed verifier cleans up"
brief bS <<EOF
\`\`\`bash verify class=light timeout=60
"$tmp/sleeper" & echo \$! >> "$kids"; echo \$! > "$tmp/kid-S"
touch "$tmp/running-S"
wait
\`\`\`
EOF
handoff hS bS done 'src/a.sh — modified'
for sig in TERM INT HUP KILL; do
  rm -f "$tmp/running-S" "$tmp/kid-S"
  bg_in "$r" sh -c 'exec handoffs/bin/jarvis merge "$1" --check --verify > "$2" 2>&1' _ handoffs/hS.md "$tmp/out-$sig"
  sup=$bgpid
  waitfor 10 test -e "$tmp/running-S"
  kill -"$sig" "$sup"; wait "$sup" 2>/dev/null; rc=$?
  case $sig in TERM) want=143 ;; INT) want=130 ;; HUP) want=129 ;; KILL) want=137 ;; esac
  [ $rc = $want ]; check "$sig: exit $want (got $rc)" $?
  waitfor 10 leftover; check "$sig: no worktree or attempt directory left" $?
  waitfor 10 gone "$(cat "$tmp/kid-S")"; check "$sig: the check's processes are stopped" $?
done
alive "$outsider"; check "the outside process survived all of it" $?
stop "$outsider"

echo "8. leases are the original checkout's"
brief bL <<'EOF'
```bash verify class=suite timeout=30
handoffs/bin/jarvis lock suite -- true
handoffs/bin/jarvis lock docker --wait 0 -- echo nested-docker
```
EOF
handoff hL bL done 'src/a.sh — modified'
out=$(V handoffs/hL.md 2>&1); rc=$?
[ $rc = 0 ] && printf '%s' "$out" | grep -q 'passed'; check "a nested lock of the held class runs at once; another class through the shim (exit $rc)" $?
bg_in "$r" handoffs/bin/jarvis lock suite -- "$tmp/hold" "$tmp/held" 30; holder=$bgpid
waitfor 5 test -e "$tmp/held"
out=$(JARVIS_LOCK_WAIT=1 V handoffs/hA.md 2>&1); rc=$?
[ $rc = 75 ] && printf '%s' "$out" | grep -q 'lease wait ran out'; check "the suite lease held in the checkout queues the verification: exit 75 (exit $rc)" $?
stop "$holder"
leftover; check "…and nothing is left" $?
brief bL <<'EOF'
```bash verify class=light timeout=30
handoffs/bin/jarvis status
```
EOF
out=$(V handoffs/hL.md 2>&1); [ $? = 1 ] && printf '%s' "$out" | grep -q 'only lock and resources work'
check "the worktree's shim refuses anything but lock and resources" $?
out=$(cd src && JARVIS_VERIFY_CONTEXT="$tmp/nope" ../handoffs/bin/jarvis lock suite -- true 2>&1); [ $? = 2 ] && printf '%s' "$out" | grep -q 'no live verification'
check "a lock with a dead context is refused" $?

echo "9. ## Files, strictly"
handoff hX bA done 'src/*.sh — modified'
V handoffs/hX.md >/dev/null 2>&1; [ $? = 2 ]; check "a glob: exit 2" $?
handoff hX bA done '../outside — created'
V handoffs/hX.md >/dev/null 2>&1; [ $? = 2 ]; check "a parent path: exit 2" $?
handoff hX bA done 'src — modified'
V handoffs/hX.md >/dev/null 2>&1; [ $? = 2 ]; check "a directory: exit 2" $?
handoff hX bA done 'src/a.sh — modified' 'src/a.sh — deleted'
V handoffs/hX.md >/dev/null 2>&1; [ $? = 2 ]; check "contradictory entries: exit 2" $?
handoff hX bA done 'src/a.sh — created'
out=$(V handoffs/hX.md 2>&1); [ $? = 1 ] && printf '%s' "$out" | grep -q 'listed as created, but HEAD has it'; check "a wrong action: exit 1" $?
mkdir -p fixtures; printf 'gen\n' > fixtures/gen.json
handoff hX bA done 'fixtures/gen.json — created'
out=$(V handoffs/hX.md 2>&1); [ $? = 2 ] && printf '%s' "$out" | grep -q 'listed source is gitignored'; check "a gitignored source: exit 2" $?
ln -s ../../outside src/link
handoff hX bA done 'src/a.sh — modified' 'src/link — created'
out=$(V handoffs/hX.md 2>&1); [ $? = 2 ] && printf '%s' "$out" | grep -q 'leaves the checkout'; check "a symlink out of the checkout: exit 2" $?
rm src/link; ln -s a.sh src/link
V handoffs/hX.md >/dev/null 2>&1; check "a relative symlink inside it is copied as a link" $?
rm src/link
ln -s y/y/../.. src/x; ln -s . src/y   # x leaves only once y is placed after it
handoff hX bA done 'src/x — created' 'src/y — created'
out=$(V handoffs/hX.md 2>&1); [ $? = 2 ] && printf '%s' "$out" | grep -q 'src/x is a symlink that leaves the checkout'
check "a link that leaves through a link listed after it: exit 2" $?
rm src/x src/y
git mv -k src/old.txt src/renamed.txt
handoff hX bF done 'src/old.txt — deleted' 'src/renamed.txt — created' 'handoffs/hX.md — created'
brief bF <<'EOF'
```bash verify class=light timeout=30
test ! -e src/old.txt && test "$(cat src/renamed.txt)" = old
```
EOF
V handoffs/hX.md >/dev/null 2>&1; check "a rename as a deleted and a created entry; the handoff's own entry is left out" $?
git mv -k src/renamed.txt src/old.txt
leftover; check "…none of them left anything" $?

echo "10. inputs"
brief bI <<'EOF'
```json verify-inputs
{"requires": ["fixtures/gen.json"], "copy": [], "dependencies": []}
```

```bash verify class=light timeout=30
cat fixtures/gen.json
```
EOF
handoff hI bI done 'src/a.sh — modified'
out=$(V handoffs/hI.md 2>&1); [ $? = 1 ] && printf '%s' "$out" | grep -q 'depends on an unlisted file: fixtures/gen.json (required by Checks); add the source change to ## Files or declare a non-source verification input'
check "a required file only in the checkout: exit 1, the dependency message" $?
rm fixtures/gen.json
out=$(V handoffs/hI.md 2>&1); [ $? = 1 ] && printf '%s' "$out" | grep -q 'required input missing: fixtures/gen.json'
check "a required file nowhere: exit 1, a different message" $?
printf 'gen\n' > fixtures/gen.json
brief bI <<'EOF'
```json verify-inputs
{"requires": ["fixtures/gen.json"], "copy": ["fixtures/gen.json"], "dependencies": []}
```

```bash verify class=light timeout=30
test "$(cat fixtures/gen.json)" = gen && echo changed > fixtures/gen.json
```
EOF
V handoffs/hI.md >/dev/null 2>&1 && [ "$(cat fixtures/gen.json)" = gen ]; check "a declared copy is private to the worktree" $?
mkdir -p node_modules/x; printf 'x\n' > node_modules/x/index.js; printf 'node_modules/\n' >> .git/info/exclude
brief bI <<'EOF'
```json verify-inputs
{"requires": ["node_modules/x/index.js"], "copy": [], "dependencies": [{"path": "node_modules", "kind": "node", "lockfiles": ["package-lock.json"], "manifests": ["package.json"]}]}
```

```bash verify class=light timeout=30
echo touched > node_modules/x/index.js
```
EOF
V handoffs/hI.md >/dev/null 2>&1 && [ "$(cat node_modules/x/index.js)" = x ]; check "a node dependency is a private copy" $?
printf '{"lock":2}\n' > package-lock.json
out=$(V handoffs/hI.md 2>&1); [ $? = 2 ] && printf '%s' "$out" | grep -q 'isolated setup block'; check "…refused when its lockfile changed" $?
git checkout -q -- package-lock.json
brief bI <<'EOF'
```json verify-inputs
{"requires": [], "copy": [], "dependencies": [{"path": ".venv", "kind": "venv", "lockfiles": [], "manifests": []}]}
```

```bash verify class=light timeout=30
true
```
EOF
out=$(V handoffs/hI.md 2>&1); [ $? = 2 ] && printf '%s' "$out" | grep -q 'virtualenv requires an isolated setup check'; check "a virtualenv is never borrowed" $?
brief bI <<EOF
\`\`\`bash verify class=light timeout=30
echo moved >> "$r/src/a.sh"
\`\`\`
EOF
out=$(V handoffs/hI.md 2>&1); [ $? = 75 ] && printf '%s' "$out" | grep -q 'inputs changed during verification; rerun (src/a.sh)'
check "a listed file that moves during the run: exit 75, not a pass" $?
printf 'a() { echo A; }\n' > src/a.sh
leftover; check "…none of them left anything" $?

echo "11. a checkout whose handoffs/bin is tracked"
r2="$tmp/r2"; mkrepo "$r2" tracked
cd "$r2" || exit 1
printf 'a() { echo A; }\n' > src/a.sh
brief bL <<'EOF'
```bash verify class=suite timeout=30
handoffs/bin/jarvis lock suite -- true
```
EOF
handoff hL bL done 'src/a.sh — modified'
V handoffs/hL.md >/dev/null 2>&1; check "its own tracked jarvis honours the context: the nested lock runs at once" $?
leftover; check "…and nothing is left" $?
cd "$r" || exit 1

echo "12. --reuse, the run record and the verify lease"
VR() { handoffs/bin/jarvis merge "$1" --check --verify --reuse; } # $1 = handoff
brief bR <<EOF
\`\`\`bash verify class=light timeout=2
echo ran >> "$tmp/ran-R"
if [ -e "$tmp/fail-R" ]; then exit 4; fi
if [ -e "$tmp/slow-R" ]; then sleep 30; fi
\`\`\`
EOF
handoff hR bR done 'src/a.sh — modified'
mkdir -p handoffs/.jarvis/runs
printf 'run: term-R\nbrief: handoffs/briefs/bR.md\nagent: claude test\nspawned: 100\nstate: running\ncustom: kept\n' > handoffs/.jarvis/runs/term-R
ran() { cat "$tmp/ran-R" 2>/dev/null | wc -l | tr -d ' '; }
rk() { sed -n "s/^$1: //p" handoffs/.jarvis/runs/term-R; } # $1 = key of the run record
res() { sed -n "s/^$2: //p" "handoffs/.jarvis/verify-results/$1/result"; } # $1 = attempt, $2 = key
out=$(VR handoffs/hR.md 2>&1); rc=$?
[ $rc = 0 ] && [ "$(ran)" = 1 ] && printf '%s' "$out" | grep -q 'not reusing: no earlier attempt on this exact candidate; running the checks'
check "--reuse with no earlier pass runs the checks (exit $rc)" $?
[ "$(rk verify_status)" = passed ] && [ "$(rk verify_reused)" = 0 ] && [ "$(rk verify_exit)" = 0 ] && [ "$(rk verify_check)" = 1 ] \
  && rk verify_key | grep -qx '[0-9a-f]\{64\}' && rk verify_tree | grep -qx '[0-9a-f]\{40\}' && [ "$(rk verify_head)" = "$(git rev-parse HEAD)" ] \
  && [ -f "$(rk verify_log)" ] && [ "$(rk state)" = running ] && [ "$(rk custom)" = kept ] && [ "$(rk spawned)" = 100 ]
check "the run record gets the verify_* keys and keeps its own" $?
first=$(rk verify_attempt); first_done=$(rk verify_finished)
[ "$(res "$first" key)" = "$(rk verify_key)" ]; check "…and the result keeps the same verify_key" $?
out=$(VR handoffs/hR.md 2>&1); rc=$?
[ $rc = 0 ] && [ "$(ran)" = 1 ] && printf '%s' "$out" | grep -q "^verify: reused pass from .* · tree [0-9a-f]\{7\} · handoffs/.jarvis/verify-results/$first$"
check "the same candidate again: the pass is reused, not re-run (exit $rc)" $?
[ "$(rk verify_reused)" = 1 ] && [ "$(rk verify_finished)" = "$first_done" ] && [ "$(rk verify_status)" = passed ]
check "…recorded as reused, with the pass's own finish time" $?
VR handoffs/hR.md >/dev/null 2>&1
[ "$(ran)" = 1 ] && [ "$(res "$(rk verify_attempt)" reused_from)" = "$first" ] && [ "$(res "$(rk verify_attempt)" status)" = reused ]
check "…and a reuse of a reuse still points at the pass: reusing never extends it" $?
V handoffs/hR.md >/dev/null 2>&1; [ "$(ran)" = 2 ]; check "without --reuse the checks run" $?
printf 'started: 2026-11-04 21:15\n' >> handoffs/briefs/bR.md
VR handoffs/hR.md >/dev/null 2>&1; [ "$(ran)" = 2 ]; check "a brief's started: line doesn't count" $?
printf 'More prose.\n' >> handoffs/briefs/bR.md
VR handoffs/hR.md >/dev/null 2>&1; [ "$(ran)" = 3 ]; check "a brief edit: no reuse" $?
printf 'a() { echo AA; }\n' > src/a.sh
VR handoffs/hR.md >/dev/null 2>&1; [ "$(ran)" = 4 ]; check "a listed-file edit: no reuse" $?
printf 'a() { echo A; }\n' > src/a.sh
printf 'other\n' > src/unrelated.txt
VR handoffs/hR.md >/dev/null 2>&1; [ "$(ran)" = 4 ]; check "…back to the passed bytes, with an unrelated dirty file: reused" $?
rm src/unrelated.txt
git commit -q --allow-empty -m 'head moves'
VR handoffs/hR.md >/dev/null 2>&1; [ "$(ran)" = 5 ]; check "a HEAD change: no reuse" $?
JARVIS_REUSE_ENV=VERIFYTEST_X VERIFYTEST_X=1 VR handoffs/hR.md >/dev/null 2>&1; [ "$(ran)" = 6 ]; check "a JARVIS_REUSE_ENV value: no reuse" $?
touch "$tmp/fail-R"; V handoffs/hR.md >/dev/null 2>&1; rc=$?; rm -f "$tmp/fail-R"
out=$(VR handoffs/hR.md 2>&1); [ $rc = 1 ] && [ "$(ran)" = 8 ] && printf '%s' "$out" | grep -q 'latest attempt on this exact candidate ended failed'
check "after a failed attempt on the same candidate: no reuse of the older pass" $?
touch "$tmp/slow-R"; V handoffs/hR.md >/dev/null 2>&1; rc=$?; rm -f "$tmp/slow-R"
out=$(VR handoffs/hR.md 2>&1); [ $rc = 124 ] && [ "$(ran)" = 10 ] && printf '%s' "$out" | grep -q 'ended timeout'
check "after a timed-out attempt: no reuse" $?
# the run's whole history 8000 s back, so its pass is still the newest attempt
perl -pi -e 's/^(started|finished): (\d+)$/"$1: " . ($2 - 8000)/e; s/^ended_ns: (\d+)(\d{9})$/"ended_ns: " . ($1 - 8000) . $2/e' \
  $(grep -l '^run: term-R$' handoffs/.jarvis/verify-results/*/result)
out=$(VR handoffs/hR.md 2>&1); [ "$(ran)" = 11 ] && printf '%s' "$out" | grep -q 'JARVIS_REUSE_MAX_AGE=7200'
check "a pass older than JARVIS_REUSE_MAX_AGE: no reuse" $?
att=$(rk verify_attempt)
perl -pi -e 's/^finished: \d+/"finished: " . (time + 3600)/e; s/^ended_ns: \d+/"ended_ns: " . (time + 3600) . "000000000"/e' "handoffs/.jarvis/verify-results/$att/result"
out=$(VR handoffs/hR.md 2>&1); [ "$(ran)" = 12 ] && printf '%s' "$out" | grep -q 'in the future'
check "a pass stamped in the future: no reuse" $?
JARVIS_REUSE_MAX_AGE=0 VR handoffs/hR.md >/dev/null 2>&1; [ "$(ran)" = 13 ]; check "JARVIS_REUSE_MAX_AGE=0: no reuse" $?
brief bR <<EOF
\`\`\`bash verify class=light timeout=5 reuse=never
echo ran >> "$tmp/ran-R"
\`\`\`
EOF
VR handoffs/hR.md >/dev/null 2>&1; out=$(VR handoffs/hR.md 2>&1); [ "$(ran)" = 15 ] && printf '%s' "$out" | grep -q 'says reuse=never'
check "a reuse=never block: never reused" $?
VR handoffs/hA.md >/dev/null 2>&1; out=$(VR handoffs/hA.md 2>&1)
[ $? = 0 ] && printf '%s' "$out" | grep -q '^verify: reused pass from' && printf '%s' "$out" | grep -q 'no run record'
check "a standalone handoff's pass is reused too" $?
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do handoffs/bin/jarvis _run-set term-R "k$i" "v$i" & done; wait
n=0; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do [ "$(rk "k$i")" = "v$i" ] && n=$((n + 1)); done
[ $n = 12 ] && [ "$(rk state)" = running ] && [ "$(rk custom)" = kept ] && [ "$(rk verify_status)" = passed ]
check "twelve writers at once: no update lost, lifecycle keys kept ($n/12)" $?
[ -e handoffs/.jarvis/run-locks/term-R.write-lock ] && [ ! -e handoffs/.jarvis/runs/term-R.write-lock ] \
  && [ -z "$(ls -A handoffs/.jarvis/runs | grep -v '^term-R$')" ]; check "…its lock lives outside runs/, and no temp file is left" $?
handoffs/bin/jarvis _run-set --if verify_attempt nosuch term-R verify_status failed; rc=$?
[ $rc = 3 ] && [ "$(rk verify_status)" = passed ]; check "an older attempt's final write is refused (exit $rc)" $?
handoffs/bin/jarvis _run-set nosuch k v; [ $? = 4 ] && [ ! -e handoffs/.jarvis/runs/nosuch ]; check "_run-set never creates a record" $?
rm -f "$tmp/running-S" "$tmp/kid-S"
bg_in "$r" sh -c 'exec handoffs/bin/jarvis merge "$1" --check --verify > "$2" 2>&1' _ handoffs/hS.md "$tmp/out-lease"; sup=$bgpid
waitfor 10 test -e "$tmp/running-S"
out=$(JARVIS_LOCK_WAIT=1 V handoffs/hA.md 2>&1); rc=$?
[ $rc = 75 ] && printf '%s' "$out" | grep -q 'another verification of this checkout held the verify lease'
check "one verification at a time per checkout: a second one waits, then exits 75 (exit $rc)" $?
kill -TERM "$sup"; wait "$sup" 2>/dev/null
waitfor 10 leftover; check "…and nothing is left" $?
V handoffs/hA.md >/dev/null 2>&1; check "…and the lease is free again once it ends" $?

echo "13. doctor: what a killed verifier left, and only that"
D() { handoffs/bin/jarvis doctor "$@" 2>&1; }
registered() { git worktree list --porcelain | grep -q "^worktree .*$1"; } # $1 = the end of a worktree path
oldstart=Thu_Jan__1_00:00:00_1970
printf 'run: term-S\nbrief: handoffs/briefs/bS.md\nagent: claude test\nspawned: 100\nstate: running\n' > handoffs/.jarvis/runs/term-S
rm -f "$tmp/running-S" "$tmp/kid-S"
bg_in "$r" sh -c 'exec handoffs/bin/jarvis merge "$1" --check --verify > "$2" 2>&1' _ handoffs/hS.md "$tmp/out-D"; sup=$bgpid
waitfor 10 test -e "$tmp/running-S"
att=$(sed -n 's/^verify_attempt: //p' handoffs/.jarvis/runs/term-S)
wd=$(sed -n 's/^watchdog: //p' "handoffs/.jarvis/verify/term-S/$att/owner")
out=$(D --apply)
printf '%s' "$out" | grep -q "verify/term-S/$att · run term-S · running: its verifier (pid $sup) is running (left alone)" \
  && printf '%s' "$out" | grep -q "verify lease is held (pid $sup)" && registered "term-S/$att/tree" && alive "$(cat "$tmp/kid-S")"
check "a live verifier's attempt is left alone" $?
out=$(JARVIS_LOCK_DIR="$tmp/otherlocks" D --apply)
! printf '%s' "$out" | grep -q 'doctor: orphaned' && registered "term-S/$att/tree" && alive "$(cat "$tmp/kid-S")"
check "…also by a doctor reading another lock dir: the verifier's PID and start time say it's alive" $?
[ -n "$wd" ] && ps -o command= -p "$wd" | grep -qF "$tmp/" && kill -9 "$wd"; kill -9 "$sup"; wait "$sup" 2>/dev/null
registered "term-S/$att/tree" && alive "$(cat "$tmp/kid-S")"; check "a verifier killed with its watchdog leaves its worktree and its check running" $?
out=$(D)
printf '%s' "$out" | grep -q "^  handoffs/.jarvis/verify/term-S/$att · run term-S · ORPHANED: its verifier (pid $sup) and watchdog are gone · a registered worktree · its check left [0-9]* process.* running" \
  && printf '%s' "$out" | grep -q 'act on the FINISHED, lost and ORPHANED ones'
check "doctor reports it orphaned" $?
registered "term-S/$att/tree" && alive "$(cat "$tmp/kid-S")"; check "…and touches nothing" $?
out=$(handoffs/bin/jarvis doctor --quiet); [ "$out" = "doctor: 1 orphaned verification worktree — handoffs/bin/jarvis doctor" ]
check "--quiet counts it ($out)" $?
out=$(D --apply)
printf '%s' "$out" | grep -q "^doctor: orphaned verification handoffs/.jarvis/verify/term-S/$att: stopped [0-9]* process.* of its check; removed its worktree; result marked interrupted; run term-S verify_status stale$"
check "--apply stops its check and removes it" $?
waitfor 5 gone "$(cat "$tmp/kid-S")" && leftover; check "…nothing of it is left" $?
[ "$(res "$att" status)" = interrupted ] && [ "$(sed -n 's/^verify_status: //p' handoffs/.jarvis/runs/term-S)" = stale ] \
  && grep -q "verify-orphan run=term-S brief=handoffs/briefs/bS.md attempt=$att pgid=[0-9]* result=removed$" handoffs/.jarvis/audit.log
check "…its result is interrupted, its run's verify_status stale, and it's audited" $?
out=$(D --apply); ! printf '%s' "$out" | grep -q '^doctor: orphaned' && [ -z "$(handoffs/bin/jarvis doctor --quiet)" ]
check "a second --apply has nothing to do" $?
printf 'run: term-Z\nbrief: handoffs/briefs/bZ.md\nstate: running\nverify_status: running\nverify_attempt: 20260101T000000Z-1-abcdef\n' > handoffs/.jarvis/runs/term-Z
out=$(D); printf '%s' "$out" | grep -q '^  run term-Z · verify_status running, but no verification of it is alive'
check "a run record stuck at verify_status: running is reported" $?
D --apply >/dev/null; [ "$(sed -n 's/^verify_status: //p' handoffs/.jarvis/runs/term-Z)" = stale ] && grep -q 'verify-stale run=term-Z .* result=stale$' handoffs/.jarvis/audit.log
check "…and --apply marks it stale" $?
lst=$(TZ=UTC LC_ALL=C ps -o lstart= -p $$ | awk '{print $1 "_" $2 "_" $3 "_" $4 "_" $5}'); mkdir -p handoffs/.jarvis/verify-results
printf 'owner: %s\nowner_start: %s\n' $$ "$lst" | tee handoffs/.jarvis/result handoffs/.jarvis/verify-results/result >/dev/null
nok=0; for a in .. .; do   # a live owner in the result these would name mustn't hide the record
  printf 'run: term-Z\nbrief: handoffs/briefs/bZ.md\nstate: running\nverify_status: running\nverify_attempt: %s\n' "$a" > handoffs/.jarvis/runs/term-Z
  D | grep -q '^  run term-Z · verify_status running, but no verification of it is alive' || nok=1
done; check "an attempt named .. or . is no attempt: its record is still stale" $nok
rm handoffs/.jarvis/runs/term-Z handoffs/.jarvis/result handoffs/.jarvis/verify-results/result
git worktree add -q --detach handoffs/.jarvis/verify/standalone-x/manual/tree HEAD
out=$(D --apply)
printf '%s' "$out" | grep -q '^  handoffs/.jarvis/verify/standalone-x/manual · no ownership manifest · a registered worktree: left alone' \
  && registered standalone-x/manual/tree; check "a registered tree with no manifest is reported, never removed" $?
git worktree remove --force handoffs/.jarvis/verify/standalone-x/manual/tree; rm -rf handoffs/.jarvis/verify/standalone-x
common=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
dead=$(sh -c 'echo $$')
manifest() { # $1 = checkout, $2 = attempt folder, $3 = PID it names as owner and group
  printf '%s\n' "schema: jarvis-verify-1" "root: $1" "common: $common" "head: $(git rev-parse HEAD)" "tree: $2/tree" \
    "attempt: ${2##*/}" "run: -" "handoff: handoffs/h3.md" "brief: handoffs/briefs/b3.md" "owner: $3" "owner_start: $oldstart" \
    "phase: check 1" "pgid: $3" "pgid_start: $oldstart" "admin: " "watchdog: $dead" "watchdog_start: $oldstart" > "$2/owner"
}
ai="$r/handoffs/.jarvis/verify/standalone-hI/20260101T000000Z-2-bbbbbb"; mkdir -p "$ai"; manifest "$r" "$ai" "$dead"
out=$(D --apply); printf '%s' "$out" | grep -q "^doctor: orphaned verification handoffs/.jarvis/verify/standalone-hI/${ai##*/}: removed its folder$" && [ ! -e "$ai" ]
check "an add interrupted before it registered: its owned folder is removed" $?
r3="$tmp/r3"; git worktree add -q --detach "$r3" HEAD   # another checkout of the same repository
mkdir -p "$r3/handoffs/bin" && cp handoffs/bin/jarvis handoffs/bin/jarvis-lock.pl handoffs/bin/jarvis-verify.py "$r3/handoffs/bin/" \
  && cp handoffs/jarvis.conf "$r3/handoffs/"
bg_in "$r" "$tmp/sleeper"; fake=$bgpid   # alive, with a PID its manifest names but another start time
a3="$r3/handoffs/.jarvis/verify/standalone-h3/20260101T000000Z-3-cccccc"
mkdir -p "$a3" && git -C "$r3" worktree add -q --detach "$a3/tree" HEAD && manifest "$r3" "$a3" "$fake"
mkdir -p "handoffs/.jarvis/verify/standalone-h3/${a3##*/}" && cp "$a3/owner" "handoffs/.jarvis/verify/standalone-h3/${a3##*/}/"
out=$(D --apply)
printf '%s' "$out" | grep -q "^  handoffs/.jarvis/verify/standalone-h3/${a3##*/} · its manifest names another checkout: left alone" \
  && [ -e "handoffs/.jarvis/verify/standalone-h3/${a3##*/}/owner" ] && ! printf '%s' "$out" | grep -q "r3/handoffs" \
  && registered "standalone-h3/${a3##*/}/tree"
check "another checkout's verification worktree, and a manifest naming it, are left alone" $?
rm -rf handoffs/.jarvis/verify/standalone-h3
out=$(cd "$r3" && handoffs/bin/jarvis doctor --apply 2>&1)
printf '%s' "$out" | grep -q "^doctor: orphaned verification handoffs/.jarvis/verify/standalone-h3/${a3##*/}: removed its worktree$" \
  && ! registered standalone-h3 && alive "$fake"
check "…its own checkout's doctor removes it, and never signals a reused PID its manifest names" $?
stop "$fake"; git worktree remove --force "$r3"
leftover; check "…and nothing is left" $?

echo "14. result records that don't add up aren't reused"
brief bQ <<EOF
\`\`\`bash verify class=light timeout=5
echo ran >> "$tmp/ran-Q"
\`\`\`
EOF
handoff hQ bQ done 'src/a.sh — modified'
ranQ() { cat "$tmp/ran-Q" 2>/dev/null | wc -l | tr -d ' '; }
VR handoffs/hQ.md >/dev/null 2>&1; q=$(grep -l 'handoff: handoffs/hQ.md' handoffs/.jarvis/verify-results/*/result)
perl -pi -e "s/^ended_ns: \\d+/ended_ns: $(( $(date +%s) + 86400 ))000000000/" "$q"
out=$(VR handoffs/hQ.md 2>&1); [ "$(ranQ)" = 2 ] && printf '%s' "$out" | grep -q "end time that doesn't match its finish time"
check "a pass whose ended_ns is a day ahead: no reuse" $?
rm -r "$(dirname "$q")"
VR handoffs/hQ.md >/dev/null 2>&1; [ "$(ranQ)" = 2 ]; check "…with that record gone, the real pass is reused" $?
q=$(grep -l '^status: passed' $(grep -l 'handoff: handoffs/hQ.md' handoffs/.jarvis/verify-results/*/result))
perl -pi -e "s/^ended_ns: \\d+/ended_ns: $(( $(sed -n 's/^finished: //p' "$q") - 3600 ))000000000/" "$q"
out=$(VR handoffs/hQ.md 2>&1); [ "$(ranQ)" = 3 ] && printf '%s' "$out" | grep -q "end time that doesn't match its finish time"
check "a pass whose ended_ns is an hour off its finished: no reuse" $?

echo "15. _run-set and the verify class name"
printf 'run: term-X\nstate: running\n' > handoffs/.jarvis/runs/term-X
bg_in "$r" perl -e 'use Fcntl ":flock"; open(my $l, ">>", $ARGV[0]) or die; flock($l, LOCK_EX) or die; open(my $t, ">", $ARGV[1]) or die; close $t; sleep 30' \
  "$r/handoffs/.jarvis/run-locks/term-X.write-lock" "$tmp/locked-X"; holder=$bgpid
waitfor 5 test -e "$tmp/locked-X"
handoffs/bin/jarvis _run-set term-X verify_status running & w=$!
waitfor 5 sh -c '[ "$(ps -ww -A -o command= | grep -c "[r]un-locks/term-X.write-lock")" -ge 2 ]'
rm -f handoffs/.jarvis/runs/term-X
stop "$holder"
wait "$w"; rc=$?
[ $rc = 4 ] && [ ! -e handoffs/.jarvis/runs/term-X ]; check "a record removed while _run-set waits for its lock isn't recreated (exit $rc)" $?
echo 'JARVIS_LOCK_verify="checkout 1"' >> handoffs/jarvis.conf
out=$(handoffs/bin/jarvis lock verify -- true 2>&1); [ $? = 2 ] && printf '%s' "$out" | grep -q "'verify' is merge --verify's own lease"
check "a lock class named verify is refused, even one jarvis.conf defines" $?
brief bV <<'EOF'
```bash verify class=verify timeout=5
true
```
EOF
handoff hV bV done 'src/a.sh — modified'
out=$(V handoffs/hV.md 2>&1); [ $? = 2 ] && printf '%s' "$out" | grep -q "'verify' is merge --verify's own lease"
check "…and so is a verify block of that class" $?
perl -ni -e 'print unless /JARVIS_LOCK_verify/' handoffs/jarvis.conf

echo "16. every process this test started has exited"
none_left() { ! ps -A -o command= | grep -F "$tmp/" | grep -v grep >/dev/null; }
waitfor 5 none_left; check "none left" $?

if [ $fails = 0 ]; then echo "verifytest: all passed"; exit 0; fi
echo "verifytest: $fails failed"; exit 1
}
