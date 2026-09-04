#!/usr/bin/env bash
# Measure the Loop analyser's *finding residue* — reviewer findings that match
# none of `Arbiter.Loop.Analysis`'s `@finding_buckets` regexes and are therefore
# dropped by `finding_categories/1` (analysis.ex:246) without being counted.
#
# This is the empirical measure of the deterministic pass's ceiling, and the
# number the discovery-pass decision (docs/design/loop-inference-discovery-pass.md,
# bd-5oh1lc) is calibrated against. It is a throwaway instrument: the permanent
# version is the Stage 0 residue counter filed as an implementation issue, which
# measures the full corpus in Elixir instead of a sample over HTTP.
#
# Method: take the task ids the analyser's own report names for a window, pull
# their `review_gate_rounds` over the API, re-implement `Corpus.split_findings/1`
# and `Analysis.bucket_finding/1` in Python, and count the units that bucket to
# nil. Sampling is biased *towards* tasks the report already surfaced, so the
# rate it reports is a lower bound on the full corpus.
#
# Side effect: it shells out to `arb loop analyze`, which inserts one
# `usage_events` row for the analysis pass's own cost. That is the pass's normal
# behaviour, not something this script adds — but it is a write, so the script
# is not strictly read-only.
#
# Usage: scripts/measure_loop_finding_residue.sh [since] [base_url]
#   e.g. scripts/measure_loop_finding_residue.sh 30d http://localhost:4848
set -euo pipefail

SINCE="${1:-30d}"
BASE="${2:-http://localhost:4848}"
WORK="$(mktemp -d)"
export BASE_URL="$BASE"
trap 'rm -rf "$WORK"' EXIT

arb loop analyze --since "$SINCE" --json > "$WORK/analysis.json"

python3 - "$WORK" <<'PY'
import json, os, re, sys, urllib.request, collections

work = sys.argv[1]
base = os.environ.get("BASE_URL", "http://localhost:4848")
md = json.load(open(f"{work}/analysis.json"))["markdown"]
task_ids = sorted(set(re.findall(r"\b[a-z]+-[a-z0-9]{6}\b", md)))

# Mirrors Arbiter.Loop.Corpus.finding_line?/1 + split_findings/1 (corpus.ex:279-293).
LINE = [re.compile(r"^\d+\.\s"), re.compile(r"^\*\*\["), re.compile(r"^-\s+\*\*")]

def split_findings(text):
    items = [l.strip() for l in text.split("\n")]
    items = [l for l in items if any(r.match(l) for r in LINE)]
    return items or [text]

# Mirrors Arbiter.Loop.Analysis.@finding_buckets (analysis.ex:222-228).
BUCKETS = [
    (re.compile(r"inert|never (?:executed|called|invoked|run|wired)|not (?:wired|reachable)|green tests? but|passes? but .*runtime", re.I), "plausible code, green tests, inert at runtime"),
    (re.compile(r"no test|missing test|untested|test coverage|without a test", re.I), "missing test coverage"),
    (re.compile(r"secret|credential|token leaked", re.I), "secret / credential exposure"),
    (re.compile(r"regression|breaks? existing|broke ", re.I), "regression in existing behaviour"),
]

total = residue = 0
tasks_with_rounds = set()
bucketed = collections.Counter()
residue_tasks = set()

for tid in task_ids:
    url = f"{base}/api/review_gate_rounds?task_id={tid}"
    try:
        rounds = json.load(urllib.request.urlopen(url, timeout=15))["data"]
    except Exception as e:                     # a task with no rounds is normal
        print(f"  ! {tid}: {e}", file=sys.stderr)
        continue
    if rounds:
        tasks_with_rounds.add(tid)
    for r in rounds:
        if r.get("role") != "review" or not r.get("findings"):
            continue
        if "approve" in (r.get("verdict") or "").lower():
            continue                           # only rounds that requested changes
        for unit in split_findings(r["findings"]):
            if re.match(r"(?i)^\W*verdict:\s*approve", unit):
                continue                       # disposition preamble, not a finding
            total += 1
            hit = next((name for rx, name in BUCKETS if rx.search(unit)), None)
            if hit:
                bucketed[hit] += 1
            else:
                residue += 1
                residue_tasks.add(tid)

print(f"candidate ids in the report : {len(task_ids)}")
print(f"tasks with review rounds : {len(tasks_with_rounds)}")
print(f"finding units (request_changes rounds) : {total}")
print(f"bucketed : {total - residue}")
for name, n in bucketed.most_common():
    print(f"    {n:4d}  {name}")
if total:
    print(f"residue (matched no bucket, dropped uncounted) : {residue}"
          f"  ({residue / total:.1%} of units, across {len(residue_tasks)} tasks)")
else:
    print("no finding units in this window")
PY
