#!/bin/sh
# Fixture: a ReviewGate reviewer that prints bd-aro53b's round-2
# REQUEST_CHANGES verbatim (bd-80talz) — the round where the reviewer found
# mockup "screenshots" on files.catbox.moe and an unverified citation. Every
# pass says the same thing. A counter (kept in `.git`, like the other reviewer
# fixtures) records how many reviewing passes ran.
git_dir="$(git rev-parse --git-dir)"
counter_file="$git_dir/review_fabricated_evidence_pass"
pass=0
[ -f "$counter_file" ] && pass="$(cat "$counter_file")"
echo $((pass + 1)) > "$counter_file"

cat "$(dirname "$0")/review_findings_bd_aro53b_round2.md"
exit 0
