#!/usr/bin/env bash
# Simulates the real `claude --print` CLI's stdin-timeout diagnostic
# (bd-79s7i1): if stdin is left open with no data delivered within the
# timeout, print the warning to stderr before proceeding. If stdin is
# already closed (e.g. redirected from /dev/null), the read returns
# immediately and no warning is printed.
start_ns=$(date +%s%N)
read -t 0.3 -r _unused <&0
end_ns=$(date +%s%N)
elapsed_ms=$((( end_ns - start_ns ) / 1000000))

if [ "$elapsed_ms" -ge 200 ]; then
  echo "Warning: no stdin data received in 3s, proceeding without it. If piping from a slow command, redirect stdin explicitly: < /dev/null to skip, or wait longer." >&2
fi

echo "This is the composed reply body."
