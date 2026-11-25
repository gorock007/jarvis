# shellcheck shell=bash
# Sourced by bin/jarvis; not run on its own.
# ---------------------------------------------------------------- models

# New model ids are spotted and suggested, never switched to: a tier changes only when
# the user runs `models accept` (user ruling, 2026-11-25). The tier map is
# JARVIS_TIER_<tier>_<cli> in lib/defaults.sh and jarvis.conf. Each CLI is asked what
# it offers in a way that calls no model and costs nothing: `agy models`, `codex debug
# models`, `opencode models`; Claude Code has no list command, so its ids are read out
# of the installed program, and JARVIS_MODELS_<cli> stands in when nothing can be read.
# $STATE/models.seen keeps "<cli> TAB <id> TAB seen|new|gone": a CLI's first listing is
# a quiet baseline (only a newer version of a mapped family is new), a `new` line is
# repeated by `check` until accepted or ignored, a `gone` one is printed once.

MODELS_CLIS="claude codex opencode agy"
MODELS_TIERS="top workhorse light trivial free"
MODELS_ID_RE='^[A-Za-z0-9][A-Za-z0-9._:/@+-]*$'

# parse(): an id's family, version and effort suffix: gpt-5.6-sol is gpt-sol 5.6,
# gemini-4-neon-high is gemini-neon 4 high, claude-opus-5-5 is claude-opus 5.5.
# suggest(): the tiers a mapped id of the same family, effort and an older version
# holds; "free" for opencode; "gated" for Fable, never a tier.
# shellcheck disable=SC2016
MODELS_AWK='
function parse(id,   s, n, a, i) {
  s = id; sub(/^.*\//, "", s); P_eff = ""
  if (match(s, /-(low|medium|high|xhigh|max)$/)) { P_eff = substr(s, RSTART + 1); s = substr(s, 1, RSTART - 1) }
  n = split(s, a, "-"); P_fam = ""; P_ver = ""
  for (i = 1; i <= n; i++)
    if (a[i] ~ /^[0-9]+(\.[0-9]+)*$/) P_ver = P_ver (P_ver == "" ? "" : ".") a[i]
    else P_fam = P_fam (P_fam == "" ? "" : "-") a[i]
}
function newer(x, y,   a, b, n, m, i, p, q) {
  if (x == "") return 0
  if (y == "") return 1
  n = split(x, a, "."); m = split(y, b, ".")
  for (i = 1; i <= (n > m ? n : m); i++) {
    p = (i <= n) ? a[i] + 0 : 0; q = (i <= m) ? b[i] + 0 : 0
    if (p > q) return 1
    if (p < q) return 0
  }
  return 0
}
function family(cli, id,   fam, ver, eff, nt, ts, i, out) {
  parse(id); fam = P_fam; ver = P_ver; eff = P_eff; out = ""
  nt = split(TIERS, ts, " ")
  for (i = 1; i <= nt; i++) {
    if (!((cli, ts[i]) in TIER)) continue
    parse(TIER[cli, ts[i]])
    if (P_fam == fam && P_eff == eff && newer(ver, P_ver)) out = out (out == "" ? "" : ",") ts[i]
  }
  return out
}
function suggest(cli, id,   f) {
  if (tolower(id) ~ /fable/) return "gated"
  f = family(cli, id)
  if (f != "") return f
  return cli == "opencode" ? "free" : ""
}
function mapped(cli, id,   nt, ts, i, out) {
  out = ""; nt = split(TIERS, ts, " ")
  for (i = 1; i <= nt; i++) if (((cli, ts[i]) in TIER) && TIER[cli, ts[i]] == id) out = out (out == "" ? "" : ", ") ts[i]
  return out
}
function note(cli, id, st,   m, s) {
  if (tolower(id) ~ /fable/) return "gated: jarvis fable allow"
  m = mapped(cli, id)
  if (m != "") return m
  if (st != "new") return "unmapped"
  s = suggest(cli, id)
  return s == "" ? "new — suggest ignore? (no mapped family)" : "new — suggest tier " s "?"
}
'

models_run() { # a CLI listing, cut off after JARVIS_MODELS_TIMEOUT seconds
  if command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift; exec @ARGV or exit 127' "${JARVIS_MODELS_TIMEOUT:-30}" "$@" </dev/null
  else "$@" </dev/null; fi
}

models_ids() { # one id per line, only well-formed ones
  awk -F '\t' -v re="$MODELS_ID_RE" '$1 ~ re && length($1) <= 100 && !seen[$1]++ {print $1}'
}

models_claude_bin() { # the ids an installed Claude Code ships with, from the first `claude` on PATH that has them
  local f l
  type -ap claude 2>/dev/null | while IFS= read -r f; do
    while [ -L "$f" ]; do l=$(readlink "$f"); case "$l" in /*) f=$l ;; *) f=$(dirname "$f")/$l ;; esac; done
    [ -f "$f" ] && [ -r "$f" ] || continue
    l=$(LC_ALL=C grep -aoE '"claude-[a-z]+-[0-9]{1,2}(-[0-9]{1,2})?"' "$f" 2>/dev/null | tr -d '"' | LC_ALL=C sort -u)
    [ -n "$l" ] && { printf '%s\n' "$l"; break; }
  done
}

# models_list <dir>: <dir>/now gets "<cli> TAB <id>" for each CLI it could list, <dir>/listed
# those CLIs, <dir>/notes "<cli> TAB <how it was listed or why it wasn't>". Not installed: skipped.
# shellcheck disable=SC2086 # $static is a space-separated list of ids, split on purpose
models_list() {
  local d=$1 c out how static
  : > "$d/now"; : > "$d/listed"; : > "$d/notes"
  for c in $MODELS_CLIS; do
    command -v "$c" >/dev/null 2>&1 || continue
    out=""; how=""
    eval "static=\${JARVIS_MODELS_$c:-}"
    case $c in
      claude) out=$(models_claude_bin | models_ids); how="ids found in the installed Claude Code; nothing called"
        [ -n "$out" ] || { out=$(printf '%s\n' $static | models_ids)
          how="can't be checked automatically: ids from JARVIS_MODELS_claude; add new Claude ids there by hand (jarvis.conf)"; } ;;
      codex) if command -v jq >/dev/null 2>&1; then
          out=$(models_run codex debug models 2>/dev/null | jq -r '.models[]? | select((.visibility // "list") == "list") | .slug // empty' 2>/dev/null | models_ids)
          how="codex debug models"
        fi
        [ -n "$out" ] || { out=$(printf '%s\n' $static | models_ids)
          how="can't be checked automatically (codex debug models$(command -v jq >/dev/null 2>&1 || echo ' needs jq')): ids from JARVIS_MODELS_codex"; } ;;
      agy|opencode) out=$(models_run "$c" models 2>/dev/null | models_ids); how="$c models"
        [ -n "$out" ] || { out=$(printf '%s\n' $static | models_ids)
          how="couldn't list now ($c models failed); last saved list kept"
          [ -z "$out" ] || how="couldn't list ($c models failed): ids from JARVIS_MODELS_$c"; } ;;
    esac
    printf '%s\t%s\n' "$c" "$how" >> "$d/notes"
    [ -n "$out" ] || continue
    echo "$c" >> "$d/listed"
    printf '%s\n' "$out" | awk -v c="$c" '{print c "\t" $0}' >> "$d/now"
  done
}

models_tiers() { # "<cli> TAB <tier> TAB <id>" for every JARVIS_TIER_<tier>_<cli> set
  local c t v
  for c in $MODELS_CLIS; do for t in $MODELS_TIERS; do
    eval "v=\${JARVIS_TIER_${t}_$c:-}"
    [ -n "$v" ] && printf '%s\t%s\t%s\n' "$c" "$t" "$v"
  done; done
}

models_lock() { # a mkdir lease on models.seen; a lock older than 2 minutes is stale
  local i=0
  mkdir -p "$STATE" 2>/dev/null || return 1
  until mkdir "$STATE/models.lock" 2>/dev/null; do
    [ -n "$(find "$STATE/models.lock" -maxdepth 0 -mmin +2 2>/dev/null)" ] && { rmdir "$STATE/models.lock" 2>/dev/null; continue; }
    i=$((i + 1)); [ $i -le 50 ] || return 1
    sleep 0.2
  done
}
models_unlock() { rmdir "$STATE/models.lock" 2>/dev/null; return 0; }

# models_refresh <dir>: list, then fold the listing into models.seen under the lock.
models_refresh() {
  local d=$1
  models_list "$d"
  models_tiers > "$d/tiers"
  models_lock || { echo "jarvis models: $STATE/models.lock is held; try again" >&2; return 1; }
  touch "$STATE/models.seen"
  awk -F '\t' -v OFS='\t' -v TIERS="$MODELS_TIERS" "$MODELS_AWK"'
    FILENAME == ARGV[1] { TIER[$1, $2] = $3; next }
    FILENAME == ARGV[2] { LISTED[$1] = 1; next }
    FILENAME == ARGV[3] { if (!(($1, $2) in NOW)) { NOW[$1, $2] = 1; nn++; NC[nn] = $1; NI[nn] = $2 }; next }
    { if (!(($1, $2) in SEEN)) { ns++; SC[ns] = $1; SI[ns] = $2 }; SEEN[$1, $2] = $3; HAS[$1] = 1 }
    END {
      for (i = 1; i <= nn; i++) {
        c = NC[i]; id = NI[i]
        if ((c, id) in SEEN) st = (SEEN[c, id] == "gone") ? "seen" : SEEN[c, id]
        else if (!(c in HAS)) st = (family(c, id) != "" && tolower(id) !~ /fable/) ? "new" : "seen"  # a first listing: the baseline
        else st = "new"
        if (mapped(c, id) != "") st = "seen"
        print c, id, st
      }
      for (i = 1; i <= ns; i++) {
        c = SC[i]; id = SI[i]
        if ((c, id) in NOW) continue
        print c, id, (c in LISTED) ? "gone" : SEEN[c, id]
      }
    }' "$d/tiers" "$d/listed" "$d/now" "$STATE/models.seen" > "$d/seen" \
    && cat "$d/seen" > "$STATE/models.seen"
  local rc=$?
  touch "$STATE/models.checked"
  models_unlock
  return $rc
}

models_mark() { # models_mark <cli> <id>: seen, whatever it was
  models_lock || { echo "jarvis models: $STATE/models.lock is held; try again" >&2; return 1; }
  touch "$STATE/models.seen"
  awk -F '\t' -v OFS='\t' -v c="$1" -v id="$2" '
    $1 == c && $2 == id { if (!done) print c, id, "seen"; done = 1; next } { print }
    END { if (!done) print c, id, "seen" }' "$STATE/models.seen" > "$STATE/models.seen.tmp" \
    && mv "$STATE/models.seen.tmp" "$STATE/models.seen"
  local rc=$?
  models_unlock
  return $rc
}

models_status_line() { # status: one line when a refresh found something; start a refresh at most every JARVIS_MODELS_REFRESH_H hours
  local h=${JARVIS_MODELS_REFRESH_H:-24} n g
  if [ -f "$STATE/models.seen" ]; then
    n=$(awk -F '\t' '$3 == "new"' "$STATE/models.seen" 2>/dev/null | wc -l | tr -d ' ')
    g=$(awk -F '\t' '$3 == "gone"' "$STATE/models.seen" 2>/dev/null | wc -l | tr -d ' ')
    if [ "${n:-0}" -gt 0 ] || [ "${g:-0}" -gt 0 ]; then
      printf 'models: %s — jarvis models check\n' \
        "$( { [ "$n" -gt 0 ] && printf '%s new' "$n"; [ "$n" -gt 0 ] && [ "$g" -gt 0 ] && printf ', '; [ "$g" -gt 0 ] && printf '%s gone' "$g"; } )"
    fi
  fi
  case "$h" in ''|*[!0-9]*|0) return 0 ;; esac
  [ -f "$STATE/models.checked" ] && [ -z "$(find "$STATE/models.checked" -mmin +$((h * 60)) 2>/dev/null)" ] && return 0
  [ -d "$STATE/models.lock" ] && return 0
  mkdir -p "$STATE" 2>/dev/null && touch "$STATE/models.checked" 2>/dev/null || return 0
  # in the background, detached from status's output, so it never waits on a CLI
  ( "$BIN/jarvis" models _refresh </dev/null >>"$STATE/models.log" 2>&1 & ) 2>/dev/null
  return 0
}

cmd_models() {
  local sub=${1:-list} d rc
  [ $# -gt 0 ] && shift
  case "$sub" in
    list|check|_refresh)
      d=$(mktemp -d "${TMPDIR:-/tmp}/jarvis-models.XXXXXX") || die "models: no temp dir"
      models_refresh "$d"; rc=$?
      if [ "$sub" = list ]; then models_print_list "$d"
      elif [ "$sub" = check ] && [ $rc = 0 ]; then models_print_check "$d"; fi
      rm -rf "$d"
      [ "$sub" = list ] || return 0
      return $rc ;;
    accept) models_accept "$@" ;;
    ignore)
      [ $# = 2 ] || { echo "usage: jarvis models ignore <cli> <model>" >&2; return 2; }
      models_valid "$1" "$2" || return 2
      models_mark "$1" "$2" && echo "ignored: $1 $2 (seen, not mapped)" ;;
    *) echo "usage: jarvis models [check | accept <cli> <model> --tier <tier> | ignore <cli> <model>]" >&2; return 2 ;;
  esac
}

models_valid() { # <cli> <model>: names jarvis can write into jarvis.conf
  case " $MODELS_CLIS " in *" $1 "*) ;; *) echo "jarvis models: unknown CLI '$1' (one of: $MODELS_CLIS)" >&2; return 1 ;; esac
  printf '%s\n' "$2" | grep -Eq "$MODELS_ID_RE" && [ ${#2} -le 100 ] \
    || { echo "jarvis models: '$2' isn't a model id" >&2; return 1; }
}

models_print_list() { # every model each CLI offers now, its tier or new/unmapped, then mapped ids it no longer offers
  local d=$1
  [ -s "$d/notes" ] || { echo "no agent CLI found (looked for: $MODELS_CLIS)"; return 0; }
  awk -F '\t' -v TIERS="$MODELS_TIERS" "$MODELS_AWK"'
    FILENAME == ARGV[1] { TIER[$1, $2] = $3; next }
    FILENAME == ARGV[2] { ST[$1, $2] = $3; next }
    FILENAME == ARGV[3] { n[$1]++; ID[$1, n[$1]] = $2; NOW[$1, $2] = 1; next }
    {
      c = $1; printf "%s — %s\n", c, $2
      if (!(c in n)) next
      for (i = 1; i <= n[c]; i++) printf "  %-38s %s\n", ID[c, i], note(c, ID[c, i], ST[c, ID[c, i]])
      nt = split(TIERS, ts, " ")
      for (i = 1; i <= nt; i++) {
        if (!((c, ts[i]) in TIER) || ((c, TIER[c, ts[i]]) in NOW)) continue
        m = TIER[c, ts[i]]
        printf "  %-38s %s — not offered now\n", m, ts[i]
      }
    }' "$d/tiers" "$STATE/models.seen" "$d/now" "$d/notes"
}

models_print_check() { # the changes: new ones (until accepted or ignored), gone ones once
  local d=$1
  awk -F '\t' -v TIERS="$MODELS_TIERS" "$MODELS_AWK"'
    FILENAME == ARGV[1] { TIER[$1, $2] = $3; next }
    $3 == "new" {
      s = suggest($1, $2)
      if (s == "gated") printf "new: %s %s — gated: jarvis fable allow\n", $1, $2
      else if (s == "") printf "new: %s %s — suggest ignore? (no mapped family)\n", $1, $2
      else printf "new: %s %s — suggest tier %s?\n", $1, $2, s
    }
    $3 == "gone" {
      m = mapped($1, $2)
      printf "gone: %s %s%s\n", $1, $2, (m == "" ? "" : " — still mapped to " m " in jarvis.conf; accept a replacement")
    }' "$d/tiers" "$STATE/models.seen"
  awk -F '\t' '$2 ~ /^couldn.t list now/ {printf "note: %s: %s\n", $1, $2}' "$d/notes" >&2
  # a gone line is said once
  models_lock || return 0
  awk -F '\t' '$3 != "gone"' "$STATE/models.seen" > "$STATE/models.seen.tmp" && mv "$STATE/models.seen.tmp" "$STATE/models.seen"
  models_unlock
}

models_accept() { # <cli> <model> --tier <t>[,<t>…]: write JARVIS_TIER_<t>_<cli>=<model> into jarvis.conf, mark it seen
  local c="" m="" tiers="" t old conf="$H/jarvis.conf" a
  while [ $# -gt 0 ]; do
    case "$1" in
      --tier) tiers=${2:-}; shift; [ $# -gt 0 ] && shift ;;
      --tier=*) tiers=${1#--tier=}; shift ;;
      *) if [ -z "$c" ]; then c=$1; elif [ -z "$m" ]; then m=$1; else a=x; fi; shift ;;
    esac
  done
  [ -n "$c" ] && [ -n "$m" ] && [ -n "$tiers" ] && [ -z "${a:-}" ] \
    || { echo "usage: jarvis models accept <cli> <model> --tier <$(echo "$MODELS_TIERS" | tr ' ' '|')>" >&2; return 2; }
  models_valid "$c" "$m" || return 2
  case "$m" in *[Ff][Aa][Bb][Ll][Ee]*)
    echo "jarvis models: $m is Fable: never mapped to a tier. The user authorizes one brief with: handoffs/bin/jarvis fable allow <brief>" >&2
    return 1 ;;
  esac
  for t in $(printf '%s' "$tiers" | tr ',' ' '); do
    case " $MODELS_TIERS " in *" $t "*) ;; *) echo "jarvis models: unknown tier '$t' (one of: $MODELS_TIERS)" >&2; return 2 ;; esac
  done
  awk -F '\t' -v c="$c" -v id="$m" '$1 == c && $2 == id && $3 != "gone" {f = 1} END {exit !f}' "$STATE/models.seen" 2>/dev/null \
    || echo "note: $c $m isn't in the last listing (jarvis models); mapping it anyway" >&2
  [ -f "$conf" ] || : > "$conf"
  for t in $(printf '%s' "$tiers" | tr ',' ' '); do
    eval "old=\${JARVIS_TIER_${t}_$c:-}"
    awk -v k="JARVIS_TIER_${t}_$c" -v v="$m" '
      index($0, k "=") == 1 { if (!done) print k "=" v; done = 1; next } { print }
      END { if (!done) print k "=" v }' "$conf" > "$conf.tmp.$$" && cat "$conf.tmp.$$" > "$conf"
    rm -f "$conf.tmp.$$"
    echo "JARVIS_TIER_${t}_$c=$m in $conf${old:+ (was $old)}"
    for a in "$H/jarvis.local.conf" "$STATE/local.conf"; do
      [ -f "$a" ] && grep -q "^[[:space:]]*JARVIS_TIER_${t}_$c=" "$a" && echo "note: $a sets JARVIS_TIER_${t}_$c too, and wins for whoever uses it" >&2
    done
  done
  models_mark "$c" "$m"
}
