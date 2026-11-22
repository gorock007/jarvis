# shellcheck shell=bash disable=SC2154,SC2034
# (here is set by the caller; m_* are read by the caller.)
# Shared helpers for eval/models/*.sh. Sourced, not run. Bash 3.2 safe.

die() { echo "${0##*/}: $*" >&2; exit 2; }

# Where suites and outputs live by default. handoffs/ is git-excluded in this
# repo, so real tasks and model answers never get committed.
models_home() {
  if [ -n "${EVAL_MODELS_HOME:-}" ]; then echo "$EVAL_MODELS_HOME"; return; fi
  local top
  top=$(git -C "$here" rev-parse --show-toplevel 2>/dev/null) || top=$(cd "$here/../.." && pwd)
  echo "$top/handoffs/.jarvis/eval/models"
}

# cli:model[@effort] -> sets m_cli m_model m_effort m_id m_slug. m_id is the
# canonical id: a claude id always carries its effort (claude:x is claude:x@high),
# so the effort is part of every result's model name.
parse_model() {
  m_cli=${1%%:*}
  m_model=${1#*:}
  m_effort=
  case "$m_model" in *@*) m_effort=${m_model##*@}; m_model=${m_model%@*} ;; esac
  [ "$m_cli" != "$1" ] && [ -n "$m_model" ] || die "model '$1' is not cli:model"
  case "$m_cli" in
    claude) [ -n "$m_effort" ] || m_effort=${EVAL_CLAUDE_EFFORT:-high} ;;
    codex) ;;
    agy) [ -z "$m_effort" ] || die "agy: the effort is part of the model id ($m_model), not @$m_effort" ;;
    *) die "unknown cli '$m_cli' in '$1' (claude, agy or codex)" ;;
  esac
  case "$m_effort" in ''|low|medium|high|xhigh|max) ;; *) die "unknown effort '$m_effort' in '$1'" ;; esac
  m_id="$m_cli:$m_model${m_effort:+@$m_effort}"
  m_slug=$(printf '%s' "$m_id" | tr ':@/' '__-')
}

# $/MTok "in out" for a claude model; unknown models get Opus-tier prices and a note
claude_price() {
  case "$1" in
    claude-fable-5-1|claude-fable-5) echo "10 50" ;;
    claude-opus-5-5) echo "4 20" ;;
    claude-opus-5|claude-opus-4-8|claude-opus-4-7) echo "5 25" ;;
    claude-sonnet-5-5|claude-sonnet-5) echo "2 10" ;;
    claude-haiku-5-5) echo "0.10 0.50" ;;
    *) echo "5 25 unknown" ;;
  esac
}

# Output tokens assumed per call (answer plus thinking), by task kind
expect_out_tokens() {
  case "$1" in writing) echo 4000 ;; review) echo 4000 ;; *) echo 2000 ;; esac
}

# Tokens estimated from bytes. 3.5 bytes a token is on the high side for English
# and code, so the cost estimate errs upward.
est_tokens() { awk -v b="$1" 'BEGIN { printf "%d", (b + 3.4) / 3.5 }'; }

# est_usd <model> <in tokens> <out tokens>
est_usd() {
  # shellcheck disable=SC2046 # the price is two words on purpose
  set -- "$1" "$2" "$3" $(claude_price "$1")
  awk -v i="$2" -v o="$3" -v pi="$4" -v po="$5" 'BEGIN { printf "%.4f", (i * pi + o * po) / 1000000 }'
}

gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }

# Per-model call count and estimated vs actual cost from calls.jsonl
cost_summary() { # $1 ledger
  [ -s "$1" ] || { echo "  no calls recorded"; return; }
  jq -rs '
    group_by(.model)[] as $g | $g[0] as $f
    | ($g | map(select(.ok)) | length) as $ok
    | if $f.cli == "claude" then
        "  \($f.model): \($g | length) calls (\($ok) ok) · estimated $\($g | map(.est_usd // 0) | add * 10000 | round / 10000)"
        + " · actual $\($g | map(.actual_usd // 0) | add * 10000 | round / 10000)"
        + " · tokens in \($g | map(.input_tokens // 0) | add) out \($g | map(.output_tokens // 0) | add)"
        + " · cache read \($g | map(.cache_read // 0) | add) write \($g | map(.cache_write // 0) | add)"
      elif $f.cli == "agy" then
        "  \($f.model): \($g | length) agy calls (\($ok) ok) · Google AI Pro daily request pool, no dollar cost"
      else
        "  \($f.model): \($g | length) codex calls (\($ok) ok) · ChatGPT plan usage, no dollar cost recorded"
      end' "$1"
}
