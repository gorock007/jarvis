# shellcheck shell=bash
# Sourced by bin/jarvis; not run on its own.
# ---------------------------------------------------------------- merge

listed_files() { # the paths under "## Files" in a handoff
  awk '/^## /{on = ($0 ~ /^## Files/); next} on && /^[[:space:]]*[-*] /' "$1" \
    | sed -E -e 's/^[[:space:]]*[-*][[:space:]]+//' -e 's/`//g' \
             -e 's/[[:space:]]+(—|–|--|-|\().*$//' -e 's/[[:space:]]+$//' \
    | grep -v '^path/relative' | grep -v '^$'
}

changed_paths() { # every changed/untracked path, renames as their new path
  git status --porcelain -uall 2>/dev/null | cut -c4- | sed -e 's/.* -> //' -e 's/^"//' -e 's/"$//'
}

verify_die() { echo "jarvis merge: $*" >&2; exit 2; }

verify_exec() { # $1 = handoff, $2 = 1 for --reuse: its brief's verify blocks on HEAD + its listed changes, in a worktree of their own
  local d age="${JARVIS_REUSE_MAX_AGE:-7200}"
  have python3 || verify_die "--verify needs python3, and there's none on PATH (nothing run)"
  case "$age" in ""|*[!0-9]*) verify_die "JARVIS_REUSE_MAX_AGE takes whole seconds (0 = never reuse), not '$age'" ;; esac
  d=$(dirname "$0")
  case "$d" in /*) ;; *) d="$JARVIS_CALLER_PWD/$d" ;; esac
  [ -f "$d/jarvis-verify.py" ] || verify_die "no $d/jarvis-verify.py — re-run jarvis:setup (nothing run)"
  set -- "$1" "--reuse=$2"
  exec python3 -I "$d/jarvis-verify.py" run --root "$ROOT" --handoff "$1" --runner "$d/$(basename "$0")" \
    --bash "$BASH" --max-sec "${JARVIS_VERIFY_MAX_SEC:-7200}" --lock-wait "${JARVIS_LOCK_WAIT:-3600}" \
    --grace "$JARVIS_STOP_GRACE" "$2" --max-age "$age" --reuse-env "${JARVIS_REUSE_ENV:-}" \
    --lock-dir "${JARVIS_LOCK_DIR:-$HOME/.jarvis/locks}"
}

cmd_merge() {
  local ho="" check=0 msg="" outcome="" reason="" push="$JARVIS_PUSH" keep=0 force=0 verify=0 reuse=0 copt=""
  local status brief agent files f bad=0 other title dest trailer sha runs r frag note old_tracked=0 closed line rec
  while [ $# -gt 0 ]; do
    case "$1" in
      --check) check=1; shift ;;
      --verify) verify=1; shift ;;
      --reuse) reuse=1; shift ;;
      -m) msg="${2:-}"; copt=${copt:-$1}; shift 2 ;;
      --outcome) outcome="${2:-}"; copt=${copt:-$1}; shift 2 ;;
      --reason) reason="${2:-}"; copt=${copt:-$1}; shift 2 ;;
      --no-push) push=0; copt=${copt:-$1}; shift ;;
      --keep-open) keep=1; copt=${copt:-$1}; shift ;;
      --force) force=1; shift ;;
      *) ho="$1"; shift ;;
    esac
  done
  if [ $verify = 1 ] || [ $reuse = 1 ]; then
    [ $check = 1 ] || verify_die "--verify goes with --check: jarvis merge <handoff> --check --verify"
    [ $verify = 1 ] || verify_die "--reuse goes with --check --verify: jarvis merge <handoff> --check --verify --reuse"
    [ -z "$copt" ] || verify_die "$copt is for a merge; --check --verify commits nothing"
    [ -f "$ho" ] || verify_die "usage: jarvis merge <handoffs/file.md> --check --verify"
  fi
  [ -f "$ho" ] || die "usage: jarvis merge <handoffs/file.md> [--check] [-m msg] [--outcome clean|corrected|escalated|respawned [--reason checks|scope|logic|other]] [--no-push] [--keep-open]"
  case "$outcome" in ""|clean|corrected|escalated|respawned) ;;
    *) die "--outcome $outcome: give clean, corrected, escalated or respawned" ;; esac
  case "$reason" in ""|checks|scope|logic|other) ;;
    *) die "--reason $reason: give checks, scope, logic or other" ;; esac
  [ "$outcome" = corrected ] && [ -z "$reason" ] && die "--outcome corrected needs --reason checks|scope|logic|other"
  [ -n "$reason" ] && [ "$outcome" != corrected ] && die "--reason goes only with --outcome corrected"
  status=$(field status "$ho" | awk '{print $1}')
  brief=$(field brief "$ho" | awk '{print $1}')
  agent=$(field agent "$ho")
  files=$(listed_files "$ho")
  [ -n "$files" ] || die "$ho lists no files under ## Files"

  echo "$ho · status: $status · brief: ${brief:-none}"
  for f in $files; do
    [ $verify = 1 ] && break # the verifier's strict reading of ## Files gives the verdict
    if changed_paths | grep -qxF "$f"; then :; else
      echo "  ✗ listed but not changed: $f"; bad=1
    fi
  done
  other=$(changed_paths | grep -v "^$H/" | grep -vxF "$files")
  if [ -n "$other" ]; then
    echo "  other changes in the checkout (another worker's, or missing from this list):"
    printf '%s\n' "$other" | head -n 12 | sed 's/^/    /'
  fi
  git diff --stat -- $files 2>/dev/null | sed 's/^/  /'
  for f in $files; do
    git ls-files --error-unmatch -- "$f" >/dev/null 2>&1 || [ ! -f "$f" ] || echo "   new: $f ($(wc -l < "$f" | tr -d ' ') lines)"
  done
  [ $verify = 1 ] && verify_exec "$ho" $reuse
  [ $check = 1 ] && exit $bad

  [ "$status" = blocked ] && die "status is blocked — answer its questions first"
  [ $bad = 1 ] && [ $force = 0 ] && die "file list doesn't match git status — send it back, or --force"

  mkdir -p "$H/merged"
  dest="$H/merged/$(basename "$ho")"
  runs=""; [ -n "$brief" ] && runs=$(brief_runs "$brief")
  [ -n "$brief" ] && open_drop "$brief"
  open_drop "$(basename "$ho")"
  git ls-files --error-unmatch -- "$ho" >/dev/null 2>&1 && old_tracked=1
  mv "$ho" "$dest"
  # a handoff that lists itself would be staged at the path it just left
  # shellcheck disable=SC2046 # $files is a whitespace-separated list
  set -- $(printf '%s\n' $files | grep -vxF "$ho") "$dest"
  [ $old_tracked = 1 ] && set -- "$@" "$ho"
  [ -n "$brief" ] && [ -f "$brief" ] && set -- "$@" "$brief"
  [ -f "$OPEN" ] && set -- "$@" "$OPEN"
  git add -A -- "$@" || die "git add failed"

  title=$(sed -n '1s/^#[[:space:]]*//p' "$dest")
  [ -n "$msg" ] || msg="$title"
  trailer=""
  case "$agent" in
    claude*) trailer="Co-Authored-By: Claude Code <$(printf '%s' "$agent" | awk '{print $2}')> worker" ;;
    codex*) trailer="Co-Authored-By: Codex <$(printf '%s' "$agent" | awk '{print $2}')> worker" ;;
    opencode*) trailer="Co-Authored-By: OpenCode <$(printf '%s' "$agent" | awk '{print $2}')> worker" ;;
  esac
  if [ -n "$trailer" ]; then
    git commit -q -m "$msg" -m "$trailer" -- "$@" || die "commit failed"
  else
    git commit -q -m "$msg" -- "$@" || die "commit failed"
  fi
  sha=$(git rev-parse --short HEAD)
  line="merged $sha · $(printf '%s\n' $files | wc -l | tr -d ' ') files"

  if [ "$push" = 1 ]; then
    if [ -z "$(git remote)" ]; then line="$line · not pushed (no remote)"
    elif git push -q 2>/dev/null; then line="$line · pushed"; else line="$line · push FAILED (run git push)"; fi
  else
    line="$line · not pushed"
  fi
  closed=0; note=""
  if [ -z "$runs" ]; then
    note="no worker terminal recorded for ${brief:-this handoff (it names no brief)}: nothing closed. If one is open: handoffs/bin/jarvis close <terminal>"
  elif [ $keep = 1 ]; then
    note="--keep-open: nothing closed; still open: $(printf "%s\n" "$runs" | tr "\n" " "). Later: handoffs/bin/jarvis close <terminal>"
  elif [ -z "$HOST" ]; then
    note="no host here, so nothing closed: $(printf "%s\n" "$runs" | tr "\n" " ")"
  else
    closed=1
    for r in $runs; do
      # a terminal from before the registry gets a record, so the close is verified and kept
      [ -f "$RUNS/$r" ] || run_set "$r" run "$r" brief "$brief" host "$HOST" state running
      frag=$(stop_run "$r" merged "merged $sha") || closed=0
      line="$line · $frag"
    done
  fi
  if [ -n "$outcome" ]; then
    rec=""
    for r in $runs; do
      [ -f "$RUNS/$r" ] || continue
      if [ -n "$reason" ]; then run_set "$r" merge_outcome "$outcome" merge_reason "$reason"
      else run_set "$r" merge_outcome "$outcome"; fi
      rec="$rec${rec:+,}$r"
    done
    audit merge-outcome "${rec:--}" "$brief" "outcome=$outcome reason=${reason:--}" "$sha"
    if [ -x "$BIN/jev.sh" ] && [ -n "$brief" ]; then
      "$BIN/jev.sh" outcome "$brief" "$outcome" ${reason:+"$reason"} >/dev/null 2>&1
    fi
  fi
  echo "$line · OPEN.md updated in the same commit"
  [ -n "$note" ] && echo "$note"
  [ -n "$brief" ] && [ -f "$brief" ] && merge_leftovers "$brief" "$dest" "$closed"
  return 0
}

# ---------------------------------------------------------------- read / send / close

cmd_read() {
  [ -n "${1:-}" ] || die "usage: jarvis read <terminal> [<lines>]"
  host read "$1" "${2:-80}"
}

cmd_send() {
  [ $# -ge 2 ] || die "usage: jarvis send <terminal> <text> | jarvis send <terminal> --keys <k,k>"
  if [ "$2" = --keys ]; then host send "$1" --keys "${3:-}"; else host send "$1" "$2"; fi
}

cmd_close() { # a worker given up on; a merged one is closed by merge
  local run=${1:-} brief="" b out
  [ -n "$run" ] || die "usage: jarvis close <terminal>"
  need_host
  [ "$run" = "$(jarvis_terminal)" ] && die "$run is Jarvis's own terminal"
  if [ ! -f "$RUNS/$run" ]; then
    # a terminal from before the registry: its brief from Running workers or a started: line
    brief=$(running_lines | grep -F "· term $run ·" | grep -o "$H/briefs/[^ ]*\.md" | head -n 1)
    if [ -z "$brief" ]; then
      for b in "$H"/briefs/*.md; do [ "$(brief_terminal "$b")" = "$run" ] && { brief=$b; break; }; done
    fi
    run_set "$run" run "$run" brief "$brief" host "$HOST" state running
  fi
  if out=$(stop_run "$run" closed "jarvis close"); then
    open_drop "term $run "
    echo "$out · dropped it from Running workers"
  else
    echo "$out"; exit 1
  fi
}
