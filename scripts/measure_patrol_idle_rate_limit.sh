#!/usr/bin/env bash
#
# measure_patrol_idle_rate_limit.sh — bd-7tr11p acceptance gate.
#
# Samples the GitHub REST rate-limit *used* counter over an idle window and
# asserts that background (patrol) consumption is near zero. This is the live
# measurement the task's acceptance criteria require and that `bd-4brb2j` asked
# for but could not satisfy:
#
#   > with the fleet idle and no engagements open, `gh api rate_limit` sampled
#   > over >=5 minutes shows background consumption near zero. Report the actual
#   > samples.
#
# It MUST be run against a running deployment (staging or prod) — it cannot run
# from an isolated worker worktree, which has no server, credentials, or
# wall-clock window. Run it as a post-deploy step, or as a ReviewGate/operator
# deploy-time gate, with the fleet idle:
#
#   * 0 workers in both workspaces (`arb worker list` / `arb prime` empty),
#   * no open review engagements,
#   * no fleet-authored open PRs.
#
# `gh api rate_limit` is itself exempt from the rate limit, so the sampler does
# not perturb what it measures — any increase in `.resources.core.used` during
# the window is background traffic (patrols, sync, anything else the server
# does), not the sampler.
#
# Pre-#1036 signature to compare against (from the incident): a ~30-call burst
# roughly once per minute plus a smaller inter-sweep trickle — i.e. ~37/min,
# ~2,200/hr, fleet fully idle. This gate passes only if the window is *near
# zero*, not merely lower than that.
#
# Usage:
#   scripts/measure_patrol_idle_rate_limit.sh [DURATION_SECONDS] [INTERVAL_SECONDS] [THRESHOLD]
#
# Defaults: DURATION=330 (5.5 min, > the 5-min criterion), INTERVAL=15, THRESHOLD=5
#
# THRESHOLD is the max background core+search calls tolerated across the whole
# window. "Near zero" — a handful of calls from unrelated housekeeping is fine;
# a per-minute burst is not. Exit 0 = pass (near zero), exit 1 = fail (patrols
# or something else are still polling), exit 2 = misuse / gh error.

set -euo pipefail

DURATION="${1:-330}"
INTERVAL="${2:-15}"
THRESHOLD="${3:-5}"

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh CLI not found on PATH" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq not found on PATH" >&2
  exit 2
fi

# One sample of the used counters. Echoes: "<epoch> <core_used> <search_used>".
sample() {
  local json
  if ! json="$(gh api rate_limit 2>/dev/null)"; then
    echo "error: 'gh api rate_limit' failed — is gh authenticated?" >&2
    exit 2
  fi
  # `/rate_limit` is exempt, so this call itself does not move the counters.
  printf '%s %s %s\n' \
    "$(date -u +%s)" \
    "$(jq -r '.resources.core.used' <<<"$json")" \
    "$(jq -r '.resources.search.used' <<<"$json")"
}

echo "== patrol idle rate-limit measurement (bd-7tr11p) =="
echo "duration=${DURATION}s interval=${INTERVAL}s threshold=${THRESHOLD} calls"
echo "Fleet MUST be idle: 0 workers, no open engagements, no fleet-authored open PRs."
echo
printf '%-22s %10s %12s\n' "timestamp(UTC)" "core.used" "search.used"

start_epoch=""
start_core=""
start_search=""
prev_core=""
prev_search=""
core_consumed=0
search_consumed=0

deadline=$(( $(date -u +%s) + DURATION ))
while :; do
  read -r ts core search <<<"$(sample)"

  if [[ -z "$start_epoch" ]]; then
    start_epoch="$ts"; start_core="$core"; start_search="$search"
    prev_core="$core"; prev_search="$search"
  else
    # Sum positive deltas only. A negative delta means the hourly window reset
    # (used dropped to ~0); we don't count that as consumption. This slightly
    # under-counts across a reset boundary — acceptable, since the assertion is
    # "near zero" and an under-count can only make a truly-noisy result look
    # better, which the operator will still see call-by-call in the samples.
    dc=$(( core - prev_core ))
    if (( dc > 0 )); then core_consumed=$(( core_consumed + dc )); fi
    ds=$(( search - prev_search ))
    if (( ds > 0 )); then search_consumed=$(( search_consumed + ds )); fi
    prev_core="$core"; prev_search="$search"
  fi

  printf '%-22s %10s %12s\n' "$(date -u -d "@$ts" +%Y-%m-%dT%H:%M:%SZ)" "$core" "$search"

  now=$(date -u +%s)
  (( now >= deadline )) && break
  remaining=$(( deadline - now ))
  (( remaining < INTERVAL )) && sleep "$remaining" || sleep "$INTERVAL"
done

elapsed=$(( $(date -u +%s) - start_epoch ))
total_consumed=$(( core_consumed + search_consumed ))

echo
echo "== result =="
echo "window:           ${elapsed}s (${start_epoch} .. $(date -u +%s))"
echo "core consumed:    ${core_consumed}"
echo "search consumed:  ${search_consumed}"
echo "total consumed:   ${total_consumed} (threshold ${THRESHOLD})"
if (( elapsed < 300 )); then
  echo "FAIL: window shorter than the required 5 minutes (300s)." >&2
  exit 1
fi
if (( total_consumed <= THRESHOLD )); then
  echo "PASS: background consumption is near zero — patrols are lazy."
  exit 0
else
  rate_per_min=$(( total_consumed * 60 / (elapsed > 0 ? elapsed : 1) ))
  echo "FAIL: ${total_consumed} background calls over ${elapsed}s (~${rate_per_min}/min)." >&2
  echo "      Something is still polling while idle. Check patrol start/stop logs" >&2
  echo "      (grep the journal for the per-repo patrol start/stop lines)." >&2
  exit 1
fi
