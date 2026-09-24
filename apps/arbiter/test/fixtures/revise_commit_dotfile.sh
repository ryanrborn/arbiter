#!/bin/sh
# Fixture: bd-bm6bfs (emr-8fqbng, MR !294) companion to
# `review_unaddressed_finding.sh DOTFILE`. Commits a real change to a
# DOTFILE — `.gitlab-ci.yml`, not `guard.txt` — so the mechanical backstop's
# `git diff --name-only` output includes a leading-dot filename, the exact
# shape that tripped the `@path` regex's dropped-leading-dot bug. Never
# invokes the paid CLI.
git_dir="$(git rev-parse --git-dir)"
counter_file="$git_dir/revise_commit_dotfile_pass"
pass=0
[ -f "$counter_file" ] && pass="$(cat "$counter_file")"
pass=$((pass + 1))
echo "$pass" > "$counter_file"

echo "implementer: addressing the reviewer's findings on this branch"
echo "changes: [\"**/*\", \".gitlab-ci.yml\"] # pass $pass" >> .gitlab-ci.yml
git add .gitlab-ci.yml >/dev/null 2>&1
git -c user.email=fixture@example.com -c user.name=Fixture \
  commit -q -m "address reviewer finding F1.1 (pass $pass)" >/dev/null 2>&1
echo "FIXED: added .gitlab-ci.yml to the changes: glob"
echo "arb done"
exit 0
