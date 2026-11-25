# shellcheck shell=bash
# Sourced by bin/jarvis; not run on its own.
# shellcheck disable=SC2034 # every setting here is read by bin/jarvis or another lib/*.sh
JARVIS_MAX_CLAUDE=3      # Claude sessions at once in this checkout, Jarvis included (when it runs on Claude); Codex/OpenCode/agy don't count
JARVIS_MAX_CLAUDE_GLOBAL=4  # active Claude sessions on the whole machine, any repo, the user's own included; Jarvis sessions don't count
JARVIS_MAX_OPUS=2        # of those, Opus workers (or Fable, or a model that can't be told); Jarvis doesn't count
JARVIS_AMBER_GLOBAL=3    # the machine-wide cap in the amber band (Jarvis sessions don't count)
JARVIS_AMBER_OPUS=2      # the Opus cap in amber (Jarvis doesn't count)
JARVIS_RED_GLOBAL=2      # the machine-wide cap in red
JARVIS_RED_OPUS=0        # the Opus cap in red: no new Opus work
JARVIS_ACTIVE_MIN=10     # a session busy, or updated this many minutes ago, is active; idle ones don't count
JARVIS_PENDING_SEC=180   # a spawn counts this long, or until its session record appears
JARVIS_AMBER=50          # 5-hour % that turns the band amber
JARVIS_RED=75            # 5-hour % that turns it red
JARVIS_STALE_MIN=30      # a reading older than this, its window not reset, is treated as amber
JARVIS_BURN_MIN=20       # the burn rate is the 5-hour % used over this many minutes
JARVIS_BURN_AMBER=15     # points per JARVIS_BURN_MIN that turn the band amber whatever the projection
# shellcheck disable=SC2034 # read by lib/status.sh
JARVIS_OPEN_MAX_KB=16    # OPEN.md over this many KB: jarvis status says to move finished notes to jarvis log
JARVIS_IDLE_MIN=55       # minutes idle after which a big context is cheaper to clear than reload
JARVIS_GUARD_TOKENS=100000
JARVIS_WATCH_SEC=60
JARVIS_BATCH_SEC=60      # the watcher holds events this long after the first, then wakes Jarvis once; 0 = at once
JARVIS_STALL_MIN=15      # unchanged this long: nudge once, then wake after another interval
JARVIS_BUSY_STALL_MIN=45 # mid-turn (last hook event: working) and unchanged this long: wake, no nudge
JARVIS_FASTPATH="trust edit nudge"  # remove a word to disable it; empty = wake Jarvis as before
JARVIS_BUDGET_MIN=90     # a worker's working minutes (watcher ticks its screen changed in)
JARVIS_BUDGET_USD=15     # its API-equivalent estimate, subagents included
JARVIS_BUDGET_CTX=300000 # its last turn's context
JARVIS_BUDGET_TESTS=6    # its failed test runs
JARVIS_BUDGET_ATTEMPTS=2 # runs per brief before a respawn needs --after
JARVIS_BUDGET_SEC=300    # the watcher reads a worker's transcript at most this often
JARVIS_BUDGET_GRACE_MIN=10  # after the ask, minutes without a handoff before Escape
JARVIS_OVERLAP=warn      # a running worker's May-touch scope meets the new brief's: warn and spawn, or refuse (--force doesn't pass it)
JARVIS_PUSH=1
JARVIS_REAP=1            # merge stops what the closed worker left running (0 = only list it)
JARVIS_STOP_GRACE=10     # seconds merge/close wait for a closed worker's terminal and agent to go
JARVIS_HOST=""           # superset | ultron | tmux | <name> with handoffs/bin/hosts/<name>.sh; empty = detect
JARVIS_FABLE_TTL_MIN=120 # minutes a `jarvis fable allow` stays usable
JARVIS_FABLE_SUPERSET_AGENT=""  # a Superset agent config id that lifts the backstop; empty = no Fable on Superset
JARVIS_AGY_SUPERSET_AGENT=""    # a Superset agent config id (or preset) that runs agy with --dangerously-skip-permissions; empty = no agy on Superset
JARVIS_LEAD_AGENT=claude # the agent Jarvis itself runs on: claude, or agy, codex or opencode (started with `handoffs/bin/jarvis lead`)
JARVIS_LEAD_MODEL=""     # a non-Claude Jarvis's model; empty = agy gemini-4-neon-high, codex gpt-6-astra; opencode needs provider/model
JARVIS_LEAD_EFFORT=""    # a codex Jarvis's effort; empty = high. agy and opencode take none
JARVIS_LEAD_PERMISSIONS=full  # full: the lead skips its CLI's permission prompts, as workers do; ask: it asks
# Models: the tier map (`jarvis models`), one id per tier per CLI. New ids are suggested by
# `jarvis models check` and mapped only by the user's `jarvis models accept` (jarvis.conf).
# Pinned ids, not aliases: an alias would switch to a new release unseen.
JARVIS_TIER_top_claude=claude-opus-5-5         # Claude's top is Fable only with `jarvis fable allow`; Fable is never mapped
JARVIS_TIER_workhorse_claude=claude-opus-5-5
JARVIS_TIER_light_claude=claude-sonnet-5-5
JARVIS_TIER_trivial_claude=claude-haiku-5-5
JARVIS_TIER_top_codex=gpt-6-astra
JARVIS_TIER_workhorse_codex=gpt-5.6-sol
JARVIS_TIER_light_codex=gpt-5.6-terra
JARVIS_TIER_trivial_codex=gpt-5.6-luna
JARVIS_TIER_workhorse_agy=gemini-4-neon-high
# opencode: no free id pinned, the free list rotates (model-routing.md 3b); `models accept` sets one
# The ids a CLI offers when it can't be listed: Claude Code has no list command (its ids
# are read out of the installed program, this list only when that fails); codex's
# `codex debug models` needs jq.
JARVIS_MODELS_claude="claude-opus-5-5 claude-sonnet-5-5 claude-haiku-5-5 claude-fable-5-1"
JARVIS_MODELS_codex="gpt-6-astra gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna"
JARVIS_MODELS_TIMEOUT=30 # seconds one CLI gets to list its models
JARVIS_MODELS_REFRESH_H=${JARVIS_MODELS_REFRESH_H:-24}  # jarvis status re-lists them in the background at most this often (hours); 0 = never
# How a terminal host that isn't an agent launcher itself (tmux) starts each worker:
# a sh command line reading $JARVIS_MODEL, $JARVIS_EFFORT and $JARVIS_PROMPT from its
# environment. The flags are the ones Superset's agent presets launch with, so a
# worker behaves the same on either host. Any other agent CLI is one more line.
# shellcheck disable=SC2016,SC2034
JARVIS_AGENT_claude='claude --dangerously-skip-permissions ${JARVIS_MODEL:+--model "$JARVIS_MODEL"} ${JARVIS_EFFORT:+--effort "$JARVIS_EFFORT"} "$JARVIS_PROMPT"'
# shellcheck disable=SC2016,SC2034
JARVIS_AGENT_codex='codex --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust ${JARVIS_MODEL:+-m "$JARVIS_MODEL"} ${JARVIS_EFFORT:+-c model_reasoning_effort="$JARVIS_EFFORT"} -- "$JARVIS_PROMPT"'
# shellcheck disable=SC2016,SC2034
JARVIS_AGENT_opencode='opencode ${JARVIS_MODEL:+-m "$JARVIS_MODEL"} --prompt "$JARVIS_PROMPT"'
# Antigravity CLI: -i keeps the session open (its --prompt is print mode, one turn, then exit)
# shellcheck disable=SC2016,SC2034
JARVIS_AGENT_agy='agy --dangerously-skip-permissions ${JARVIS_MODEL:+--model "$JARVIS_MODEL"} ${JARVIS_EFFORT:+--effort "$JARVIS_EFFORT"} -i "$JARVIS_PROMPT"'
