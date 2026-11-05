# shellcheck shell=bash
# Sourced by bin/jarvis; not run on its own.
# ---------------------------------------------------------------- lock

# Three workers each ran a repo's Docker test suite at once and the Docker VM sat at
# 264% CPU: no worker can know about another's heavy command. A repo wraps its heavy
# scripts instead ("test:docker": "handoffs/bin/jarvis lock docker -- vitest run
# --project docker"), so every caller (any agent, the human, CI) queues for the same
# lease, shared by every process on the machine. A class is JARVIS_LOCK_<class>=
# "<scope> <capacity>", scope host (machine-wide) or checkout (this checkout only).
# The lease is a kernel flock held by the command and everything it starts, so it
# ends exactly when the last of them does; bin/jarvis-lock.pl has the details. No
# flag skips it. Needs only perl (macOS ships it; there is no flock(1) here) and
# works with no OPEN.md, outside any host. Exit 75 when --wait runs out, 2 for a
# usage or class error, else the command's own status (128+signal when signalled).

lock_die() { echo "jarvis lock: $*" >&2; exit 2; }

lock_spec() { # $1 = class: its "<scope> <capacity>" from jarvis.conf, else the built-in
  local v
  eval "v=\${JARVIS_LOCK_$1:-}"
  [ -n "$v" ] || case "$1" in
    docker) v="host 1" ;;    # one Docker suite on the whole machine
    suite) v="checkout 1" ;; # one full test suite per checkout
  esac
  printf '%s' "$v"
}

lock_pl() { # the lease helper beside this script, wherever it was called from
  local d
  d=$(dirname "$0")
  case "$d" in /*) ;; *) d="$JARVIS_CALLER_PWD/$d" ;; esac
  [ -f "$d/jarvis-lock.pl" ] || lock_die "no $d/jarvis-lock.pl — re-run jarvis:setup (the command was not run)"
  printf '%s/jarvis-lock.pl' "$d"
}

cmd_lock() {
  local class="${1:-}" wait="${JARVIS_LOCK_WAIT:-3600}" reuse=0 spec scope cap pl
  local usage="usage: jarvis lock <class> [--wait <sec>] [--reuse] -- <command…>"
  case "$class" in ""|-*) lock_die "$usage" ;; esac
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --wait) [ $# -ge 2 ] || lock_die "--wait needs seconds. $usage"; wait=$2; shift 2 ;;
      --reuse) reuse=1; shift ;;
      --) shift; break ;;
      -*) lock_die "unknown option $1. $usage" ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || lock_die "no command to run. $usage"
  case "$wait" in ""|*[!0-9]*) lock_die "--wait takes whole seconds, not '$wait'" ;; esac
  lock_class "$class"
  if ! have perl; then
    # a CI runner has no other agents to queue behind, and minimal images have no perl
    case "${CI:-}" in ""|0|false) ;; *)
      echo "jarvis lock $class: no perl on this CI runner (CI=$CI), so running without the lease" >&2
      cd "$JARVIS_CALLER_PWD" && exec "$@" ;;
    esac
    lock_die "needs perl for the kernel lock, and there's none on PATH; install perl (the command was not run)"
  fi
  pl=$(lock_pl) || exit 2
  JARVIS_CALLER_PWD="$JARVIS_CALLER_PWD" JARVIS_LOCK_DIR="${JARVIS_LOCK_DIR:-$HOME/.jarvis/locks}" \
    JARVIS_LOCK_POLL="${JARVIS_LOCK_POLL:-1}" JARVIS_REUSE_MAX_AGE="${JARVIS_REUSE_MAX_AGE:-7200}" \
    JARVIS_REUSE_ENV="${JARVIS_REUSE_ENV:-}" \
    exec perl "$pl" run "$class" "$scope" "$cap" "$ROOT" "$wait" "$reuse" "$@"
}

lock_class() { # $1 = class: sets the caller's spec, scope and cap from jarvis.conf, else exits 2
  local extra
  case "$1" in ""|*[!a-z0-9_]*) lock_die "class names are a-z, 0-9 and _, not '$1'" ;; esac
  [ "$1" = verify ] && lock_die "'verify' is merge --verify's own lease (one verification per checkout); give your class another name"
  [ "$1" = spawn ] && lock_die "'spawn' is jarvis spawn's own lease (one spawn at a time per checkout, and machine-wide for the caps); give your class another name"
  class=$1
  spec=$(lock_spec "$class")
  [ -n "$spec" ] || lock_die "no lock class '$class'. Add one to $H/jarvis.conf, e.g. JARVIS_LOCK_$class=\"host 1\" (host = machine-wide, checkout = this checkout only; then how many at once)"
  read -r scope cap extra <<< "$spec"
  case "$scope $cap $extra" in
    "host "[1-9]*" "|"checkout "[1-9]*" ") case "$cap" in *[!0-9]*) scope="" ;; esac ;;
    *) scope="" ;;
  esac
  [ -n "$scope" ] || lock_die "JARVIS_LOCK_$class=\"$spec\" in $H/jarvis.conf isn't \"<host|checkout> <capacity>\", e.g. JARVIS_LOCK_$class=\"host 1\""
}

cmd_resources() {
  local pl
  case "${1:-}" in ""|--json) ;; *) lock_die "usage: jarvis resources [--json]" ;; esac
  have perl || lock_die "needs perl"
  pl=$(lock_pl) || exit 2
  JARVIS_LOCK_DIR="${JARVIS_LOCK_DIR:-$HOME/.jarvis/locks}" JARVIS_REUSE_MAX_AGE="${JARVIS_REUSE_MAX_AGE:-7200}" \
    exec perl "$pl" resources "$@"
}
