#!/usr/bin/env bash
# Offline test of the Fable gate in bin/jarvis: model_canon on every alias, the
# single-use authorization (`jarvis fable allow` fed from a pty this test opens), the
# final check in host(), the tmux launch script, the PreToolUse hook, the settings
# that re-open Fable, and the backstop helper. A throwaway repo with the template's
# handoffs/, a fake superset and tmux, and a throwaway JARVIS_HOME and
# CLAUDE_CONFIG_DIR: ~/.jarvis and ~/.claude are never touched. Nothing launches a model.
#
#   eval/fabletest.sh
# `[ … ]; check "…" $?` reads the test's own status, and the single-quoted scripts
# expand in the shell they're written for, not this one.
# shellcheck disable=SC2016,SC2319,SC2012
set -u
here=$(cd "$(dirname "$0")" && pwd)
tpl="$here/../plugins/jarvis/skills/setup/templates"
tmp=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/jarvis-fgate.XXXXXX")" && pwd -P)
trap 'for p in $(cat "$tmp"/pty/*/*.pid 2>/dev/null); do kill -9 "$p" 2>/dev/null; done; chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
case "$tmp" in *[Ff][Aa][Bb][Ll][Ee]*) echo "fabletest: TMPDIR names fable, which would hide the hook cases: set TMPDIR elsewhere" >&2; exit 2 ;; esac
fails=0
ok() { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; fails=$((fails + 1)); }
check() { if [ "$2" = 0 ]; then ok "$1"; else bad "$1"; fi; }
command -v jq >/dev/null 2>&1 || { echo "fabletest: skipped (jq not installed)"; echo "fabletest: all passed"; exit 0; }

export JARVIS_HOME="$tmp/jh" CLAUDE_CONFIG_DIR="$tmp/cc" CODEX_HOME="$tmp/codex" SUPERSET_HOME_DIR="$tmp/sshome"
export FAKE_LOG="$tmp/fake.log" SUPERSET_WORKSPACE_ID=ws SUPERSET_TERMINAL_ID=jarvis-t PATH="$tmp/fake:$PATH"
unset TYPESAFE_API_KEY TMUX TMUX_PANE ULTRON_SESSION_ID JARVIS_HOST ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL \
  ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_SMALL_FAST_MODEL CLAUDE_CODE_SUBAGENT_MODEL
mkdir -p "$tmp/fake" "$tmp/cc" "$tmp/pty" "$tmp/sshome/state"
cat > "$tmp/fake/superset" <<'EOT'
#!/bin/bash
echo "superset $*" >> "$FAKE_LOG"
case "$1 $2" in
  "agents create") n=$(( $(cat "$FAKE_LOG.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_LOG.n"
    printf '{"kind":"terminal","sessionId":"term-%s"}\n' "$n" ;;
  "terminals list") printf '{"sessions":[]}\n' ;;
esac
EOT
chmod +x "$tmp/fake/superset"

# ptyrun <out> <input|-> <command…>: runs the command detached from this test (double
# fork + setsid, so no agent is among its parents) on a pty of its own, types <input>
# when it prompts, and leaves the screen in <out> and the exit status in <out>.rc.
# Input "-" = no pty at all: the command has no terminal to open.
cat > "$tmp/ptyrun.pl" <<'EOT'
use strict; use POSIX ();
my ($out, $input, @cmd) = @ARGV;
my $p = fork() // die; if ($p) { waitpid($p, 0); exit 0 }
POSIX::setsid(); $p = fork() // die; POSIX::_exit(0) if $p;
open(my $pf, '>', "$out.pid"); print $pf "$$\n"; close $pf;
my ($buf, $rc) = ('', 0);
if ($input eq '-') {
  my $kid = fork() // die;
  if (!$kid) { open STDIN, '<', '/dev/null'; open STDOUT, '>', "$out.tmp"; open STDERR, '>&', \*STDOUT; exec @cmd or POSIX::_exit(127) }
  waitpid($kid, 0); $rc = $? >> 8; rename "$out.tmp", $out;
} else {
  require IO::Pty; my $pty = IO::Pty->new;
  my $kid = fork() // die;
  if (!$kid) { $pty->make_slave_controlling_terminal; my $s = $pty->slave; close $pty;
    open STDIN, '<&', $s; open STDOUT, '>&', $s; open STDERR, '>&', $s; exec @cmd or POSIX::_exit(127) }
  $pty->close_slave; my $sent = 0; my $end = time + 20;
  while (time < $end) {
    my $rin = ''; vec($rin, fileno($pty), 1) = 1;
    my $n = select(my $r = $rin, undef, undef, 0.2);
    if ($n > 0) { my $got = sysread($pty, my $chunk, 4096); last unless $got; $buf .= $chunk }
    if (!$sent && $buf =~ /> $/) { syswrite($pty, "$input\n"); $sent = 1 }
  }
  kill 9, $kid if time >= $end; waitpid($kid, 0); $rc = $? >> 8;
  open(my $o, '>', $out); print $o $buf; close $o;
}
open(my $f, '>', "$out.rc"); print $f "$rc\n"; close $f;
EOT
agent_free() { # the environment minus every agent variable under_agent looks for
  local v
  set -- env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_PID -u OPENCODE
  for v in $(env | sed -n 's/^\(CODEX_[A-Z0-9_]*\)=.*/\1/p' | grep -vx CODEX_HOME); do set -- "$@" -u "$v"; done
  printf '%s\n' "$@"
}
IFS=$'\n' read -r -d '' -a CLEAN < <(agent_free; printf '\0')
pty() { # <input|-> <command…>: run it as above, wait, print the screen; status = its exit status
  local o
  o=$(mktemp -d "$tmp/pty/r.XXXXXX")/out   # callers run this in $(…): no counter survives
  "${CLEAN[@]}" perl "$tmp/ptyrun.pl" "$o" "$@"
  local n=250; while [ ! -f "$o.rc" ] && [ $n -gt 0 ]; do sleep 0.1; n=$((n - 1)); done
  cat "$o" 2>/dev/null
  return "$(cat "$o.rc" 2>/dev/null || echo 99)"
}
havepty=0; perl -MIO::Pty -e1 2>/dev/null && havepty=1

sb="$tmp/sb"; mkdir -p "$sb"
cd "$sb" || exit 1
git init -q
cp -R "$tpl/handoffs" . && sed -e 's/{{MAX_CLAUDE}}/50/' -e 's/{{AMBER}}/50/' -e 's/{{RED}}/75/' "$tpl/handoffs/jarvis.conf" > handoffs/jarvis.conf
echo 'JARVIS_FABLE_SUPERSET_AGENT=fable-cfg' >> handoffs/jarvis.conf
echo 'JARVIS_MAX_CLAUDE_GLOBAL=50 JARVIS_MAX_OPUS=50 JARVIS_AMBER_GLOBAL=50 JARVIS_AMBER_OPUS=50' >> handoffs/jarvis.conf
echo a > app.txt && git add -A && git -c user.name=t -c user.email=t@t commit -qm init
J=handoffs/bin/jarvis
$J start >/dev/null
mk() { # <name> <model> [worker]: a brief
  printf '# Brief %s\nworker: %s\nmodel: %s\neffort: high\nstarted: <x> · terminal: <x>\n\n## Goal\nx\n' "$1" "${3:-claude}" "$2" > "handoffs/briefs/2026-10-30-1200-$1.md"
  echo "handoffs/briefs/2026-10-30-1200-$1.md"
}
band() { # green | amber | red
  local now pct; now=$(date +%s)
  case "$1" in green) pct=10 ;; amber) pct=55 ;; red) pct=80 ;; esac
  echo "{\"five_hour\":{\"used_percentage\":$pct,\"resets_at\":$((now + 3600))},\"ts\":$now}" > handoffs/.jarvis/usage.json
}
creates() { cat "$FAKE_LOG" 2>/dev/null | grep -c 'agents create'; }
FD="$JARVIS_HOME/fable"
forge() { # <brief>: a pending record written as `fable allow` writes it, for when there's no IO::Pty
  local p h; p="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"; h=$(grep -v '^started:' "$1" | shasum -a 256 | cut -d' ' -f1)
  mkdir -p "$FD/pending" && chmod 700 "$JARVIS_HOME" "$FD" "$FD/pending"
  printf 'brief: %s\nhash: %s\nroot: %s\nallowed: %s\n' "$p" "$h" "$sb" "$(date +%s)" > "$FD/pending/forged.$RANDOM" && chmod 600 "$FD"/pending/forged.*
}
authorize() { # <brief>: the user's `fable allow`, typed at a pty
  local slug; slug=$(basename "$1" .md | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}-//')
  if [ $havepty = 1 ]; then pty "$slug" "$J" fable allow "$1" >/dev/null; else forge "$1"; fi
}
band green

echo "canonical model names (no authorization)"
for m in fable Fable claude-fable-5-1 'fable[1m]' 'claude-fable-5-1[1m]' FABLE; do
  b=$(mk "a-$(printf '%s' "$m" | tr -c 'A-Za-z0-9' '-')" "$m"); c=$(creates)
  out=$($J spawn "$b" 2>&1); rc=$?
  [ $rc = 1 ] && printf '%s' "$out" | grep -q 'fable needs your authorization for this brief: run handoffs/bin/jarvis fable allow' \
    && printf '%s' "$out" | grep -q 'worker: codex, model: gpt-6-astra' && [ "$(creates)" = "$c" ]; check "$m: refused in green, pointed at Codex gpt-6-astra" $?
  out=$($J spawn "$b" --force 2>&1); rc=$?
  [ $rc = 1 ] && printf '%s' "$out" | grep -q 'fable needs your authorization' && [ "$(creates)" = "$c" ]; check "$m: refused with --force too" $?
done
for m in best default opusplan claude-next 'opus;x'; do
  b=$(mk "u-$(printf '%s' "$m" | tr -c 'A-Za-z0-9' '-')" "$m"); c=$(creates)
  out=$($J spawn "$b" --force 2>&1); rc=$?
  [ $rc = 1 ] && printf '%s' "$out" | grep -q "can't resolve" && [ "$(creates)" = "$c" ]; check "claude '$m' refused (it might resolve to Fable), --force or not" $?
done
for m in claude-opus-5-5 opus Opus 'claude-opus-5-5[1m]' sonnet claude-sonnet-5-5 haiku claude-haiku-5-5; do
  b=$(mk "ok-$(printf '%s' "$m" | tr -c 'A-Za-z0-9' '-')" "$m"); c=$(creates)
  $J spawn "$b" >/dev/null 2>&1 && [ "$(creates)" = $((c + 1)) ] && tail -n 1 "$FAKE_LOG" | grep -q -- '--agent claude ' \
    && tail -n 1 "$FAKE_LOG" | grep -qF -- "--model $m --effort high"; check "claude $m spawns unchanged" $?
done
b=$(mk cx gpt-6-astra codex); $J spawn "$b" >/dev/null 2>&1 && tail -n 1 "$FAKE_LOG" | grep -q -- '--agent codex .*--model gpt-6-astra'; check "codex gpt-6-astra spawns unchanged" $?
b=$(mk oc '' opencode); $J spawn "$b" >/dev/null 2>&1 && tail -n 1 "$FAKE_LOG" | grep -q -- '--agent opencode'; check "opencode spawns unchanged" $?
for w in codex cc; do
  for m in fable 'claude-fable-5-1[1m]' Fable; do
    b=$(mk "nf-$w-$(printf '%s' "$m" | tr -c 'A-Za-z0-9' '-')" "$m" "$w"); c=$(creates)
    out=$($J spawn "$b" --force 2>&1); rc=$?
    [ $rc = 1 ] && printf '%s' "$out" | grep -q 'fable needs your authorization' && [ "$(creates)" = "$c" ]; check "worker: $w, model: $m: refused like a Claude one, --force or not" $?
  done
done
b=$(mk cm 'm1[fable]' cc); $J spawn "$b" >/dev/null 2>&1; check "another agent's model is checked after its [..] suffix comes off" $?
band red
b=$(mk rop claude-opus-5-5); $J spawn "$b" 2>&1 | grep -q 'band is red: new workhorse-tier'; check "red band still refuses opus (tier from the canonical name)" $?
b=$(mk rop2 'claude-opus-5-5[1m]'); $J spawn "$b" 2>&1 | grep -q 'band is red: new workhorse-tier'; check "…and an opus alias, which used to skip it" $?
band green

echo "fable allow"
fb=$(mk work fable)
if [ $havepty = 1 ]; then
  out=$(pty work "$J" fable allow "$fb"); rc=$?
  [ $rc = 0 ] && printf '%s' "$out" | grep -q 'Type its slug to confirm: work' && printf '%s' "$out" | grep -q 'authorized'; check "the slug typed at a terminal authorizes" $?
  rec=$(ls "$FD"/pending/* 2>/dev/null | head -n 1)
  [ -n "$rec" ] && [ "$(stat -f %Lp "$rec" 2>/dev/null || stat -c %a "$rec")" = 600 ] && [ "$(stat -f %Lp "$FD" 2>/dev/null || stat -c %a "$FD")" = 700 ]; check "record 0600, dir 0700" $?
  grep -q ' allow root=.* brief=handoffs/briefs/2026-10-30-1200-work.md hash=[0-9a-f]\{64\} run=- ' "$FD/audit.log"; check "audit: allow line with root, brief, hash" $?
  $J fable revoke "$fb" | grep -q 'revoked 1' && [ -z "$(ls "$FD"/pending/ 2>/dev/null)" ] && grep -q ' revoke ' "$FD/audit.log"; check "revoke drops it and logs it" $?
  out=$(pty wrong "$J" fable allow "$fb"); rc=$?
  [ $rc = 1 ] && printf '%s' "$out" | grep -q "isn't the slug" && [ -z "$(ls "$FD"/pending/ 2>/dev/null)" ]; check "a wrong slug authorizes nothing" $?
  out=$(pty - "$J" fable allow "$fb"); rc=$?
  [ $rc = 1 ] && printf '%s' "$out" | grep -q 'no terminal to confirm on' && [ -z "$(ls "$FD"/pending/ 2>/dev/null)" ]; check "no terminal (detached, no pty) refuses" $?
  out=$(pty work env CLAUDECODE=1 "$J" fable allow "$fb"); rc=$?
  [ $rc = 1 ] && printf '%s' "$out" | grep -q 'CLAUDECODE is set' && [ -z "$(ls "$FD"/pending/ 2>/dev/null)" ]; check "an agent's variables refuse, even at a terminal" $?
  out=$(pty work perl -e 'exec {"/bin/sh"} "claude", "-c", "$ARGV[0] fable allow $ARGV[1]; s=\$?; exit \$s"' "$J" "$fb"); rc=$?
  [ $rc = 1 ] && printf '%s' "$out" | grep -q 'an agent is among' && [ -z "$(ls "$FD"/pending/ 2>/dev/null)" ]; check "an agent among the parents refuses, even at a terminal" $?
  grep -q ' deny .*reason=allow: no terminal' "$FD/audit.log"; check "audit: refused allows are deny lines" $?
else
  echo "  (no perl IO::Pty: the pty cases are skipped and records are written by hand below)"
fi
# only where this shell has no terminal (an agent's Bash tool, CI): at yours it would prompt
if ! { : </dev/tty; } 2>/dev/null; then
  "${CLEAN[@]}" "$J" fable allow "$fb" </dev/null >/dev/null 2>&1; rc=$?
  [ $rc = 1 ] && [ -z "$(ls "$FD"/pending/ 2>/dev/null)" ]; check "from this shell (no terminal), stdin /dev/null: refused" $?
fi
$J fable allow "$(mk notf claude-opus-5-5)" 2>&1 | grep -q "isn't a Fable brief"; check "a brief that isn't fable has nothing to authorize" $?

echo "the gate"
authorize "$fb"; c=$(creates)
out=$($J spawn "$fb" 2>&1); rc=$?
[ $rc = 0 ] && [ "$(creates)" = $((c + 1)) ] && tail -n 1 "$FAKE_LOG" | grep -q -- '--agent fable-cfg .*--model fable'; check "authorized: spawns, through the Superset Fable agent config" $?
u=$(ls "$FD"/used/*.work 2>/dev/null | head -n 1)
[ -n "$u" ] && grep -q '^run: work$' "$u" && grep -q '^consumed: ' "$u" && grep -q '^launched: ' "$u" && [ -z "$(ls "$FD"/pending/)" ]; check "the record moved to used/, run appended, consumed and launched" $?
grep -q ' consume .*run=work ' "$FD/audit.log"; check "audit: consume line" $?
c=$(creates); out=$($J spawn "$fb" --force 2>&1); rc=$?
[ $rc = 1 ] && printf '%s' "$out" | grep -q 'fable needs your authorization' && [ "$(creates)" = "$c" ]; check "single use: the second spawn is refused" $?
$J fable list | grep -q 'launched'; check "fable list shows the used record" $?

authorize "$fb"; sed -i.bak 's/^started:.*/started: 2026-10-30 99:99 · terminal: other/' "$fb" && rm -f "$fb.bak"
$J spawn "$fb" >/dev/null 2>&1; check "a rewritten started: line doesn't void it" $?
authorize "$fb"; echo "one more line" >> "$fb"; c=$(creates)
out=$($J spawn "$fb" 2>&1); rc=$?
[ $rc = 1 ] && printf '%s' "$out" | grep -q 'the brief changed after it was authorized' && [ "$(creates)" = "$c" ]; check "body edited after authorization: refused" $?
$J fable revoke "$fb" >/dev/null
authorize "$fb"; rec=$(ls "$FD"/pending/* | head -n 1)
sed -i.bak "s/^allowed: .*/allowed: $(( $(date +%s) - 121 * 60 ))/" "$rec" && rm -f "$rec.bak"
out=$($J spawn "$fb" 2>&1); rc=$?
[ $rc = 1 ] && printf '%s' "$out" | grep -q 'expired'; check "expired (JARVIS_FABLE_TTL_MIN 120): refused" $?
$J fable list | grep -q EXPIRED; check "fable list marks it EXPIRED" $?
$J fable revoke "$fb" >/dev/null
authorize "$fb"; chmod -R a-w "$JARVIS_HOME"; c=$(creates)
out=$($J spawn "$fb" 2>&1); rc=$?
chmod -R u+w "$JARVIS_HOME"
[ $rc = 1 ] && printf '%s' "$out" | grep -Eq "fable needs your authorization|can't take the spawn lease" && [ "$(creates)" = "$c" ]; check "unwritable JARVIS_HOME: refused (it can't be used up)" $?
band red; c=$(creates)
out=$($J spawn "$fb" --force 2>&1); rc=$?
[ $rc = 1 ] && printf '%s' "$out" | grep -q 'band is red: fable is off even when authorized' && [ "$(creates)" = "$c" ] && [ -n "$(ls "$FD"/pending/)" ]; check "red band refuses even an authorized one, --force or not, and leaves it unused" $?
band amber
$J spawn "$fb" >/dev/null 2>&1; check "amber allows an authorized one" $?
band green
cp handoffs/jarvis.conf "$tmp/conf"; grep -v '^JARVIS_FABLE_SUPERSET_AGENT=' "$tmp/conf" > handoffs/jarvis.conf
authorize "$fb"; c=$(creates)
out=$($J spawn "$fb" 2>&1); rc=$?
[ $rc = 1 ] && printf '%s' "$out" | grep -q "Superset can't pass --settings" && [ "$(creates)" = "$c" ] && [ -n "$(ls "$FD"/pending/)" ]; check "Superset without a Fable agent config: refused, authorization kept" $?
cp "$tmp/conf" handoffs/jarvis.conf

cb=$(mk ccw claude-fable-5-1 cc)
authorize "$cb"; band red; c=$(creates)
out=$($J spawn "$cb" --force 2>&1); rc=$?
[ $rc = 1 ] && printf '%s' "$out" | grep -q 'band is red: fable is off even when authorized' && [ "$(creates)" = "$c" ]; check "worker: cc on fable: the red band refuses even an authorized one" $?
band green
$J spawn "$cb" >/dev/null 2>&1 && tail -n 1 "$FAKE_LOG" | grep -q -- '--agent cc .*--model claude-fable-5-1' \
  && ls "$FD"/used/*.ccw >/dev/null 2>&1; check "worker: cc on fable, authorized (fable allow takes it): used up, keeps its own agent" $?
c=$(creates); $J spawn "$cb" >/dev/null 2>&1; [ $? = 1 ] && [ "$(creates)" = "$c" ]; check "…and only once" $?

echo "final check in host() (a custom host, callers that skip cmd_spawn)"
mkdir -p handoffs/bin/hosts
cat > handoffs/bin/hosts/fake.sh <<'EOT'
fake_self() { printf jarvis-t; }
fake_list() { :; }
fake_spawn() {
  echo "fake_spawn $1 $2 $5 lift=$FABLE_LIFT settings=${FABLE_SETTINGS:-}" >> "$FAKE_LOG"
  case "${FAKE_AGAIN:-}" in
    same) host spawn "$1" "$2" "$3" "$4" "$5" >/dev/null || return 1 ;;
    other) host spawn claude fable "" p other-run >/dev/null || return 1 ;;
    best) host spawn claude best "" p "$5" >/dev/null || return 1 ;;
    cc) host spawn cc 'claude-fable-5-1[1m]' "" p cc-run >/dev/null || return 1 ;;
  esac
  echo "fake-$5"
}
EOT
echo 'JARVIS_HOST=fake' >> handoffs/jarvis.conf
$J spawn "$fb" >/dev/null 2>&1 && grep -q "fake_spawn claude fable work lift=1 settings=.*fable" "$FAKE_LOG"; check "an authorized run reaches the host with FABLE_LIFT=1 and the settings to lift" $?
b=$(mk plain claude-opus-5-5); $J spawn "$b" >/dev/null 2>&1 && grep -q "fake_spawn claude claude-opus-5-5 plain lift=0" "$FAKE_LOG"; check "any other run gets FABLE_LIFT=0" $?
authorize "$fb"; out=$(FAKE_AGAIN=same $J spawn "$fb" 2>&1)
printf '%s' "$out" | grep -q 'no authorization was used up'; check "a second launch of the same run is refused by the final check" $?
authorize "$fb"; out=$(FAKE_AGAIN=other $J spawn "$fb" 2>&1)
printf '%s' "$out" | grep -q "no authorization was used up for run 'other-run'" && ! grep -q 'fake_spawn claude fable other-run' "$FAKE_LOG"; check "a caller that skips cmd_spawn can't launch Fable" $?
out=$(FAKE_AGAIN=best $J spawn "$b" 2>&1)
printf '%s' "$out" | grep -q "can't resolve" && ! grep -q 'fake_spawn claude best' "$FAKE_LOG"; check "…nor an alias the final check can't resolve" $?
out=$(FAKE_AGAIN=cc $J spawn "$b" 2>&1)
printf '%s' "$out" | grep -q "no authorization was used up for run 'cc-run'" && ! grep -q 'fake_spawn cc' "$FAKE_LOG"; check "…nor another agent on Fable" $?
grep -q ' deny .*reason=final check' "$FD/audit.log"; check "audit: the final check's deny lines" $?
cp "$tmp/conf" handoffs/jarvis.conf

echo "tmux launch script"
cat > "$tmp/fake/tmux" <<'EOT'
#!/bin/bash
echo "tmux $*" >> "$FAKE_LOG"
case "$1" in display-message) echo '$1' ;; new-window) echo '%9' ;; esac
EOT
# what the launch script runs, kept out of the PATH bin/jarvis itself sees
mkdir -p "$tmp/fake2"
printf '#!/bin/sh\necho "claude-ran $* remap=${ANTHROPIC_DEFAULT_OPUS_MODEL:-unset}"\n' > "$tmp/fake2/claude"
printf '#!/bin/sh\nexit 0\n' > "$tmp/fake2/tail"
chmod +x "$tmp/fake/tmux" "$tmp/fake2/claude" "$tmp/fake2/tail"
echo 'JARVIS_HOST=tmux' >> handoffs/jarvis.conf
b=$(mk tw claude-opus-5-5); TMUX_PANE=%1 $J spawn "$b" >/dev/null 2>&1; l=handoffs/.jarvis/launch/tw.sh
[ -f "$l" ] && grep -q "JARVIS_MODEL\" != 'claude-opus-5-5'" "$l" && ! grep -q -- '--settings' "$l"; check "the launch script pins the checked model, no lift" $?
out=$(JARVIS_AGENT=claude JARVIS_MODEL=claude-fable-5-1 JARVIS_PROMPT=p PATH="$tmp/fake2:$PATH" sh "$l" 2>&1)
printf '%s' "$out" | grep -q 'refused' && ! printf '%s' "$out" | grep -q claude-ran; check "a hand-edited JARVIS_MODEL doesn't launch" $?
out=$(JARVIS_AGENT=claude JARVIS_MODEL=claude-opus-5-5 JARVIS_PROMPT=p ANTHROPIC_DEFAULT_OPUS_MODEL=claude-fable-5-1 PATH="$tmp/fake2:$PATH" sh "$l" 2>&1)
printf '%s' "$out" | grep -q 'claude-ran' && printf '%s' "$out" | grep -q 'remap=unset'; check "an alias variable pointing at Fable is unset before claude starts" $?
authorize "$fb"; TMUX_PANE=%1 $J spawn "$fb" >/dev/null 2>&1; l=handoffs/.jarvis/launch/work.sh
out=$(JARVIS_AGENT=claude JARVIS_MODEL=fable JARVIS_PROMPT=p PATH="$tmp/fake2:$PATH" sh "$l" 2>&1)
printf '%s' "$out" | grep -q 'claude-ran --settings {"availableModels":\["opus","sonnet","haiku","fable"\]}'; check "an authorized launch adds the allowlist with Fable, that launch only" $?
echo "JARVIS_AGENT_cc='claude \${JARVIS_MODEL:+--model \"\$JARVIS_MODEL\"} \"\$JARVIS_PROMPT\"'" >> handoffs/jarvis.conf
b=$(mk tcc "m1'x" cc); TMUX_PANE=%1 $J spawn "$b" >/dev/null 2>&1; l=handoffs/.jarvis/launch/tcc.sh
out=$(JARVIS_AGENT=cc JARVIS_MODEL="m1'x" JARVIS_PROMPT=p PATH="$tmp/fake2:$PATH" sh "$l" 2>&1)
printf '%s' "$out" | grep -q "claude-ran --model m1'x p"; check "another agent's launch script pins its model too (a quote in it is quoted)" $?
out=$(JARVIS_AGENT=cc JARVIS_MODEL=claude-fable-5-1 JARVIS_PROMPT=p PATH="$tmp/fake2:$PATH" sh "$l" 2>&1)
printf '%s' "$out" | grep -q refused && ! printf '%s' "$out" | grep -q claude-ran; check "…so a hand-edited fable JARVIS_MODEL doesn't launch it" $?
authorize "$cb"; TMUX_PANE=%1 $J spawn "$cb" >/dev/null 2>&1; l=handoffs/.jarvis/launch/ccw.sh
out=$(JARVIS_AGENT=cc JARVIS_MODEL=claude-fable-5-1 JARVIS_PROMPT=p PATH="$tmp/fake2:$PATH" sh "$l" 2>&1)
printf '%s' "$out" | grep -q 'claude-ran --settings {"availableModels".* --model claude-fable-5-1 p'; check "an authorized agent wrapping claude gets the lift through the claude() wrapper" $?
cp "$tmp/conf" handoffs/jarvis.conf

echo "ultron: extra claude args after --"
cat > "$tmp/fake/ultron" <<'EOT'
#!/bin/bash
echo "ultron $*" >> "$FAKE_LOG"
case "$1 $2" in "agent spawn") echo '{"id":"s_1"}' ;; "term list") echo '[]' ;; esac
EOT
chmod +x "$tmp/fake/ultron"
echo 'JARVIS_HOST=ultron' >> handoffs/jarvis.conf
authorize "$fb"; $J spawn "$fb" >/dev/null 2>&1 \
  && grep 'ultron agent spawn' "$FAKE_LOG" | tail -n 1 | grep -qF -- '--model fable --effort high -- --settings {"availableModels":["opus","sonnet","haiku","fable"]}'; check "an authorized launch passes the allowlist with Fable to claude itself" $?
b=$(mk uo claude-opus-5-5); $J spawn "$b" >/dev/null 2>&1 && ! grep 'ultron agent spawn' "$FAKE_LOG" | tail -n 1 | grep -q -- '--settings'; check "any other launch passes none" $?
authorize "$cb"; $J spawn "$cb" >/dev/null 2>&1 && grep 'ultron agent spawn' "$FAKE_LOG" | tail -n 1 | grep -q -- '--agent cc' \
  && ! grep 'ultron agent spawn' "$FAKE_LOG" | tail -n 1 | grep -q -- '--settings'; check "…nor an authorized other agent (its CLI wouldn't take them)" $?
cp "$tmp/conf" handoffs/jarvis.conf

echo "settings that re-open Fable, alias variables"
mkdir -p .claude && echo '{"availableModels":["opus","Fable"]}' > .claude/settings.local.json
b=$(mk hole claude-opus-5-5); c=$(creates)
out=$($J spawn "$b" --force 2>&1); rc=$?
[ $rc = 1 ] && printf '%s' "$out" | grep -q '.claude/settings.local.json lists fable' && [ "$(creates)" = "$c" ]; check "a local settings allowlist with fable refuses every Claude spawn" $?
$J status 2>/dev/null | grep -q 'settings.local.json lists fable'; check "status names it" $?
$J doctor 2>/dev/null | grep -q 'settings.local.json lists fable'; check "doctor names it" $?
authorize "$cb"; out=$($J spawn "$cb" 2>&1); printf '%s' "$out" | grep -q 'settings.local.json lists fable'; check "…and an authorized other agent on Fable too" $?
$J fable revoke "$cb" >/dev/null
rm .claude/settings.local.json
echo '{"modelOverrides":{"claude-opus-5-5":"claude-fable-5-1"}}' > .claude/settings.json
$J spawn "$b" 2>&1 | grep -q 'modelOverrides entry naming Fable'; check "project modelOverrides naming Fable refuses" $?
echo '{"modelOverrides":{"claude-opus-5-5":"claude-fable-5-1"}}' > "$CLAUDE_CONFIG_DIR/settings.json"
rm .claude/settings.json
$J spawn "$b" 2>&1 | grep -q "$CLAUDE_CONFIG_DIR/settings.json has a modelOverrides entry"; check "user-level modelOverrides naming Fable refuses" $?
rm "$CLAUDE_CONFIG_DIR/settings.json"
echo '{"env":{"ANTHROPIC_DEFAULT_SONNET_MODEL":"claude-fable-5-1"}}' > .claude/settings.json
$J spawn "$b" 2>&1 | grep -q 'sets ANTHROPIC_DEFAULT_SONNET_MODEL to Fable'; check "a settings env remapping an alias to Fable refuses" $?
rm .claude/settings.json
ANTHROPIC_DEFAULT_OPUS_MODEL=claude-fable-5-1 $J spawn "$b" 2>&1 | grep -q 'ANTHROPIC_DEFAULT_OPUS_MODEL=claude-fable-5-1 points a model alias at Fable'; check "an environment variable remapping an alias to Fable refuses" $?

echo "PreToolUse hook"
hk() { printf '%s' "$1" | $J hook pretool; }
hk '{"session_id":"s1","tool_name":"Agent","tool_input":{"model":"claude-fable-5-1","prompt":"x"}}' \
  | jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | test("sonnet"))' >/dev/null; check "denies an Agent call with model claude-fable-5-1, pointing at Sonnet" $?
grep -q ' deny .*run=s1 reason=hook: Agent claude-fable-5-1' "$FD/audit.log"; check "…and logs a deny line" $?
hk '{"tool_name":"Task","tool_input":{"model":"Fable"}}' | grep -q deny; check "denies Task with Fable" $?
[ -z "$(hk '{"tool_name":"Agent","tool_input":{"model":"sonnet","prompt":"fable story"}}')" ]; check "allows sonnet (even with fable in the prompt)" $?
[ -z "$(hk '{"tool_name":"Agent","tool_input":{"model":"sonnet"}}')" ]; check "allows sonnet" $?
[ -z "$(hk 'not json, but fable')" ]; check "input that doesn't parse: allowed (the backstop covers it)" $?
hk "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$sb/.claude/settings.json\",\"content\":\"{\\\"availableModels\\\":[\\\"opus\\\",\\\"fable\\\"]}\"}}" | grep -q deny; check "denies a Write putting fable into availableModels" $?
echo '{"availableModels":["opus"]}' > .claude/settings.local.json
hk "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$sb/.claude/settings.local.json\",\"old_string\":\"\\\"opus\\\"\",\"new_string\":\"\\\"opus\\\",\\\"claude-fable-5-1\\\"\"}}" | grep -q deny; check "denies an Edit adding fable" $?
hk "{\"tool_name\":\"MultiEdit\",\"tool_input\":{\"file_path\":\"$sb/.claude/settings.local.json\",\"edits\":[{\"old_string\":\"opus\",\"new_string\":\"fable\"}]}}" | grep -q deny; check "denies a MultiEdit adding fable" $?
echo '{"availableModels":["opus","fable"]}' > .claude/settings.local.json
# JSON built outside "$(…)": bash 3.2 reads escaped quotes inside one differently
js=$(jq -nc --arg f "$sb/.claude/settings.local.json" '{tool_name: "Edit", tool_input: {file_path: $f, old_string: ",\"fable\"", new_string: ""}}')
out=$(hk "$js"); [ -z "$out" ]; check "allows an Edit taking fable out" $?
rm -f .claude/settings.local.json
js=$(jq -nc --arg f "$sb/notes.md" '{tool_name: "Write", tool_input: {file_path: $f, content: "availableModels fable"}}')
out=$(hk "$js"); [ -z "$out" ]; check "leaves other files alone" $?
js=$(jq -nc --arg f "$sb/.claude/settings.json" --arg c '{"availableModels":["opus","fab\u006ce"]}' '{tool_name: "Write", tool_input: {file_path: $f, content: $c}}')
case "$js" in *[Ff][Aa][Bb][Ll][Ee]*) false ;; esac && hk "$js" | grep -q deny; check "denies a Write spelling fable in \\u escapes (the input never says fable)" $?
echo '{"availableModels":["opus"]}' > .claude/settings.json
js=$(jq -nc --arg f "$sb/.claude/settings.json" '{tool_name: "Edit", tool_input: {file_path: $f, old_string: "\"opus\"", new_string: "\"opus\",\"fab\""}}')
out=$(hk "$js"); [ -z "$out" ]; check "allows the first of two Edits that would assemble fable" $?
echo '{"availableModels":["opus","fab"]}' > .claude/settings.json   # as the Edit tool would leave it
js=$(jq -nc --arg f "$sb/.claude/settings.json" '{tool_name: "Edit", tool_input: {file_path: $f, old_string: "b\"", new_string: "ble\""}}')
case "$js" in *[Ff][Aa][Bb][Ll][Ee]*) false ;; esac && hk "$js" | grep -q deny; check "denies the second, which completes it" $?
echo '{"availableModels":["opus"]}' > .claude/settings.json
js=$(jq -nc --arg f "$sb/.claude/settings.json" '{tool_name: "MultiEdit", tool_input: {file_path: $f, edits: [{old_string: "\"opus\"", new_string: "\"opus\",\"fab\""}, {old_string: "b\"", new_string: "ble\""}]}}')
hk "$js" | grep -q deny; check "denies a MultiEdit whose edits assemble it" $?
js=$(jq -nc --arg f "$sb/.Claude/SETTINGS.local.json" --arg c '{"availableModels":["Fable"]}' '{tool_name: "Write", tool_input: {file_path: $f, content: $c}}')
hk "$js" | grep -q deny; check "matches the path case-blind (.Claude/SETTINGS.local.json)" $?
js=$(jq -nc --arg f "$sb/.claude/settings.json" --arg c '{"modelOverrides":{"claude-opus-5-5":"claude-fab\u006ce-5-1"}}' '{tool_name: "Write", tool_input: {file_path: $f, content: $c}}')
hk "$js" | grep -q deny; check "denies modelOverrides naming fable" $?
js=$(jq -nc --arg f "$sb/.claude/settings.json" --arg c '{"env":{"ANTHROPIC_DEFAULT_OPUS_MODEL":"claude-fable-5-1"}}' '{tool_name: "Write", tool_input: {file_path: $f, content: $c}}')
hk "$js" | grep -q deny; check "denies an env alias variable naming fable" $?
js=$(jq -nc --arg f "$sb/.claude/settings.json" --arg c '{"availableModels":["opus","sonnet"],"hooks":{}}' '{tool_name: "Write", tool_input: {file_path: $f, content: $c}}')
out=$(hk "$js"); [ -z "$out" ]; check "allows an ordinary settings write" $?
rm -f .claude/settings.json
start=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
for _ in 1 2 3 4 5 6 7 8 9 10; do printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/src/a.ts","old_string":"a","new_string":"b"}}' "$sb" | (cd / && "$sb/$J" hook pretool); done
el=$(perl -MTime::HiRes=time -e "printf '%d', (time - $start) * 100")
[ "$el" -lt 300 ]; check "ordinary edits leave at once: 10 in ${el}0 ms (under 3 s), before git or jq" $?
[ -z "$(hk '{"tool_name":"Edit","tool_input":{"file_path":"x","old_string":"a","new_string":"b"}}')" ]; check "no fable in the input: nothing" $?
grep -q '"matcher": "Agent|Task|Edit|Write|MultiEdit"' "$tpl/.claude/settings.json" && grep -q 'jarvis hook pretool' "$tpl/.claude/settings.json"; check "the template's settings register it" $?

echo "backstop"
echo '{"model":"opus","theme":"dark"}' > "$CLAUDE_CONFIG_DIR/settings.json"
$J fable backstop | grep -q '^off: '; check "backstop: off without availableModels" $?
$J status 2>/dev/null | grep -q 'fable: backstop off — handoffs/bin/jarvis fable backstop --apply'; check "status says so" $?
$J doctor 2>/dev/null | grep -q 'fable: backstop off'; check "doctor says so" $?
$J fable backstop --apply | grep -q '^applied: ' \
  && jq -e '.availableModels == ["opus","sonnet","haiku"] and .model == "opus" and .theme == "dark"' "$CLAUDE_CONFIG_DIR/settings.json" >/dev/null \
  && ls "$CLAUDE_CONFIG_DIR"/settings.json.bak-jarvis-* >/dev/null 2>&1; check "--apply writes [opus,sonnet,haiku], keeps the rest, leaves a backup beside it" $?
$J status 2>/dev/null | grep -q 'fable: blocked (backstop on)'; check "status: blocked (backstop on)" $?
! $J doctor 2>/dev/null | grep -q 'fable:'; check "doctor: quiet when it's on" $?
echo '{"availableModels":["opus","claude-fable-5-1"]}' > "$CLAUDE_CONFIG_DIR/settings.json"
$J fable backstop --apply >/dev/null && jq -e '.availableModels == ["opus"]' "$CLAUDE_CONFIG_DIR/settings.json" >/dev/null; check "--apply keeps a narrowed list, minus Fable" $?
echo 'not json' > "$CLAUDE_CONFIG_DIR/settings.json"
! $J fable backstop --apply >/dev/null 2>&1 && grep -qx 'not json' "$CLAUDE_CONFIG_DIR/settings.json"; check "--apply leaves invalid JSON alone" $?
mkdir -p "$tmp/acct" && echo "$tmp/acct" > "$SUPERSET_HOME_DIR/state/default-claude-config-dir"
echo '{"availableModels":["opus"]}' > "$CLAUDE_CONFIG_DIR/settings.json"
$J fable backstop | grep -q "off: $tmp/acct/settings.json"; check "checks Superset's default account's settings too" $?
echo '{"env":{"ANTHROPIC_DEFAULT_OPUS_MODEL":"claude-fable-5-1"}}' > "$tmp/acct/settings.json"
b=$(mk acct claude-opus-5-5); $J spawn "$b" 2>&1 | grep -q "$tmp/acct/settings.json sets ANTHROPIC_DEFAULT_OPUS_MODEL to Fable"; check "preflight scans Superset's default account's settings" $?
echo '{"modelOverrides":{"opus":"fable"}}' > "$tmp/acct/settings.json"
$J spawn "$b" 2>&1 | grep -q "$tmp/acct/settings.json has a modelOverrides entry"; check "…its modelOverrides too" $?
js=$(jq -nc --arg f "$tmp/acct/settings.json" --arg c '{"availableModels":["fable"]}' '{tool_name: "Write", tool_input: {file_path: $f, content: $c}}')
hk "$js" | grep -q deny; check "the hook guards that account's settings.json too" $?

echo; [ "$fails" = 0 ] && echo "fabletest: all passed" || { echo "fabletest: $fails failed"; exit 1; }
