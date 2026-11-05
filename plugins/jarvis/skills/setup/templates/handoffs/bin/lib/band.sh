# shellcheck shell=bash
# Sourced by bin/jarvis; not run on its own.
# ---------------------------------------------------------------- band

# Prints "<band>\t<one-line explanation>", band green | amber | red. The reading comes
# from `jarvis statusline`, which Claude Code feeds its own 5-hour and 7-day numbers;
# rate limits are per account, so one machine-wide reading serves every repo (the
# repo's own copy only when there is none yet). It fails closed: no reading, no jq or
# an unreadable one is amber, and so is a reading older than JARVIS_STALE_MIN whose
# window hasn't reset. A window that has reset since is green only while the reading
# is under 5 h old. Besides the window average (pace) it watches the burn rate from
# the history: amber when that rate would use up the window before it resets, or is
# JARVIS_BURN_AMBER or more; red when it reaches 100% within 30 minutes.
band() {
  local f burn
  have jq || { printf 'amber\tunknown band, treated as amber: jq not installed\n'; return; }
  f="$JHOME/usage.json"
  [ -s "$f" ] || f="$STATE/usage.json"
  [ -s "$f" ] || { printf 'amber\tunknown band, treated as amber: no statusline reading yet — check `/usage`\n'; return; }
  burn=$(usage_burn "$f")
  jq -r --argjson now "$(now)" --argjson amber "$JARVIS_AMBER" --argjson red "$JARVIS_RED" \
    --argjson stale "$JARVIS_STALE_MIN" --argjson bmin "$JARVIS_BURN_MIN" --argjson bamber "$JARVIS_BURN_AMBER" \
    --argjson burn "${burn:-null}" '
    def hm: (. / 60 | floor) as $m | "\($m / 60 | floor)h\($m % 60 | tostring | if length < 2 then "0" + . else . end)m";
    def worse($a; $b): if $a == "red" or $b == "red" then "red" elif $a == "amber" or $b == "amber" then "amber" else "green" end;
    (.five_hour.used_percentage // null) as $u
    | (.five_hour.resets_at // null) as $r
    | (if (.seven_day.used_percentage | type) == "number" and $now < (.seven_day.resets_at // $now + 1)
       then .seven_day.used_percentage else null end) as $w
    | (if (.ts | type) == "number" then (($now - .ts) / 60 | floor) else null end) as $age
    | (if $w == null then "green" elif $w >= 95 then "red" elif $w >= 80 then "amber" else "green" end) as $wb
    | (if $w then " · 7d \($w | round)%" else "" end) as $wt
    | if ($u | type) != "number" or ($r | type) != "number" or $age == null then
        "amber\tunknown band, treated as amber: the reading has no 5-hour window"
      elif $now >= $r then
        if $age < 300 then "\($wb)\tthe 5-hour window has reset since the last reading (\($age) min ago)\($wt)"
        else "amber\tunknown band, treated as amber: the last reading is \($age * 60 | hm) old and its window has reset since" end
      else
        (18000 - ($r - $now)) as $el
        | (($r - $now) / 60) as $left
        | (if $el >= 1800 then ($u * 18000 / $el) else null end) as $pace
        | (if $burn != null and $burn > 0 then $u + $burn * $left / $bmin else null end) as $proj
        | (if $burn != null and $burn > 0 then $u + $burn * ([30, $left] | min) / $bmin else null end) as $soon
        | (if $u >= $red or ($soon // 0) >= 100 then "red"
           elif $u >= $amber or ($pace // 0) >= 100 or ($proj // 0) >= 100 or ($burn // 0) >= $bamber then "amber"
           else "green" end) as $b5
        | ($age > $stale) as $old
        | worse(worse($b5; $wb); if $old then "amber" else "green" end) as $b
        | "\($b)\t" + (if $old then "stale reading (\($age) min old), treated as amber: " else "" end)
          + "5h \($u | round)% used, \($el | hm) into the window"
          + (if $pace then ", on pace for \($pace | round)%" else "" end)
          + (if $burn != null then ", burning \($burn | round) pts/\($bmin) min"
               + (if ($proj // 0) >= 100 then " (100% in \((100 - $u) * $bmin / $burn | floor) min)" else "" end)
             else "" end)
          + $wt
          + (if $age > 20 and ($old | not) then " · reading \($age) min old" else "" end)
      end' "$f" 2>/dev/null || printf 'amber\tunknown band, treated as amber: unreadable %s\n' "$f"
}

# $1 = the reading: 5-hour points used per JARVIS_BURN_MIN minutes, from the history
# lines of the same window; empty when the history spans under 5 minutes of it. The
# baseline is the last line at least JARVIS_BURN_MIN before the reading, else (or when
# that one is far older, after a gap) the first line since.
usage_burn() {
  local h="$JHOME/usage.hist" cur
  [ -s "$h" ] || return 0
  cur=$(jq -r '"\(.ts) \(.five_hour.used_percentage) \(.five_hour.resets_at)"' "$1" 2>/dev/null) || return 0
  tail -n 500 "$h" | awk -v cur="$cur" -v w=$((JARVIS_BURN_MIN * 60)) '
    BEGIN { split(cur, c, " "); ts = c[1] + 0; u = c[2] + 0; r = c[3] + 0 }
    NF >= 4 && $1 + 0 <= ts && $4 - r < 600 && r - $4 < 600 {
      if ($1 + 0 <= ts - w) { bt = $1; bu = $2; hb = 1 } else if (!fo) { ft = $1; fu = $2; fo = 1 }
    }
    END {
      if (hb && (!fo || ts - bt <= 2 * w || ts - ft < 300)) { t = bt; v = bu }
      else if (fo) { t = ft; v = fu }
      else exit
      if (ts - t < 300) exit
      d = u - v; if (d < 0) d = 0
      printf "%.1f\n", d * w / (ts - t)
    }'
}

cmd_band() { band | tr '\t' ' '; }
